import AppKit
import GhosttyKit

/// Scrollback position reported by libghostty, in rows.
struct TerminalScrollbar: Equatable {
    /// Rows in scrollback plus the active screen.
    var total: UInt64
    /// First visible row, counted from the top of scrollback.
    var offset: UInt64
    /// Visible rows.
    var len: UInt64
}

extension TerminalScrollbar {
    init(_ c: ghostty_action_scrollbar_s) {
        self.init(total: c.total, offset: c.offset, len: c.len)
    }
}

/// Converts between terminal rows (counted down from the top of scrollback)
/// and the scroll view's document coordinates (AppKit, counted up from the
/// bottom).
struct TerminalScrollGeometry {
    let scrollbar: TerminalScrollbar
    /// Row height in points.
    let cellHeight: CGFloat
    /// Height of the visible area in points.
    let contentHeight: CGFloat

    /// The whole of scrollback, plus the padding the visible area has around
    /// its grid. Without the padding the surface drifts out of line with the
    /// rows it is drawing.
    var documentHeight: CGFloat {
        let padding = contentHeight - CGFloat(scrollbar.len) * cellHeight
        return CGFloat(scrollbar.total) * cellHeight + padding
    }

    /// Clip-view origin that shows `scrollbar.offset` at the top.
    var clipOriginY: CGFloat {
        let rowsBelow = scrollbar.total.subtractingReportingOverflow(scrollbar.offset + scrollbar.len)
        return rowsBelow.overflow ? 0 : CGFloat(rowsBelow.partialValue) * cellHeight
    }

    /// The row at the top of the visible area when the clip view's origin is
    /// at `originY` — what a scroller drag asks libghostty to scroll to.
    func row(atClipOriginY originY: CGFloat) -> Int {
        let fromTop = documentHeight - originY - contentHeight
        return max(0, Int(fromTop / cellHeight))
    }
}

/// Hosts a `GhosttySurfaceView` inside an overlay `NSScrollView` so the
/// terminal gets a native scroller.
///
/// libghostty owns scrollback; nothing here is really scrolled. The document
/// view is a blank view as tall as scrollback, the surface is pinned to the
/// visible rect and keeps rendering just the viewport, and the scroller is
/// kept in step with `GHOSTTY_ACTION_SCROLLBAR`. Dragging the scroller goes
/// the other way, as a `scroll_to_row` binding action. Scroll-wheel events
/// still go straight to the surface.
///
/// Adapted from Ghostty's own `SurfaceScrollView`.
@MainActor
final class TerminalScrollView: NSView {
    let surfaceView: GhosttySurfaceView
    private let scrollView = NSScrollView()
    private let documentView = NSView()
    private var observers: [NSObjectProtocol] = []
    private var isLiveScrolling = false
    /// Last row sent as `scroll_to_row`, so a drag within one row sends nothing.
    private var lastSentRow: Int?

    init(surfaceView: GhosttySurfaceView) {
        self.surfaceView = surfaceView
        super.init(frame: .zero)

        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = false
        scrollView.usesPredominantAxisScrolling = true
        // Always overlay: a legacy scroller would take columns from the grid.
        scrollView.scrollerStyle = .overlay
        scrollView.drawsBackground = false
        scrollView.contentView.clipsToBounds = false
        scrollView.documentView = documentView
        documentView.addSubview(surfaceView)
        addSubview(scrollView)

        surfaceView.onScrollbarChange = { [weak self] in self?.synchronizeScrollView() }
        installObservers()
        synchronizeAppearance()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    isolated deinit {
        for obs in observers { NotificationCenter.default.removeObserver(obs) }
    }

    override var safeAreaInsets: NSEdgeInsets { NSEdgeInsetsZero }

    override func layout() {
        super.layout()
        scrollView.frame = bounds
        surfaceView.frame.size = scrollView.contentSize
        documentView.frame.size.width = scrollView.contentSize.width
        synchronizeScrollView()
        synchronizeSurfacePosition()
    }

    private func installObservers() {
        let center = NotificationCenter.default
        let clip = scrollView.contentView
        clip.postsBoundsChangedNotifications = true
        observers = [
            center.addObserver(
                forName: NSView.boundsDidChangeNotification, object: clip, queue: .main
            ) { [weak self] _ in MainActor.assumeIsolated { self?.synchronizeSurfacePosition() } },
            center.addObserver(
                forName: NSScrollView.willStartLiveScrollNotification, object: scrollView, queue: .main
            ) { [weak self] _ in MainActor.assumeIsolated { self?.isLiveScrolling = true } },
            center.addObserver(
                forName: NSScrollView.didEndLiveScrollNotification, object: scrollView, queue: .main
            ) { [weak self] _ in MainActor.assumeIsolated { self?.isLiveScrolling = false } },
            center.addObserver(
                forName: NSScrollView.didLiveScrollNotification, object: scrollView, queue: .main
            ) { [weak self] _ in MainActor.assumeIsolated { self?.handleLiveScroll() } },
            // Synchronous: overrides the style change before anything lays out with it.
            center.addObserver(
                forName: NSScroller.preferredScrollerStyleDidChangeNotification, object: nil, queue: nil
            ) { [weak self] _ in MainActor.assumeIsolated { self?.scrollView.scrollerStyle = .overlay } },
            center.addObserver(
                forName: .ghosttyRuntimeConfigDidChange, object: nil, queue: .main
            ) { [weak self] _ in MainActor.assumeIsolated { self?.synchronizeAppearance() } },
        ]
    }

    /// Honors Ghostty's `scrollbar = never`, and matches the scroller to the
    /// terminal background rather than the app's appearance.
    private func synchronizeAppearance() {
        let shows = Self.showsScrollbar(GhosttyRuntime.shared.config)
        if scrollView.hasVerticalScroller != shows {
            scrollView.hasVerticalScroller = shows
            updateTrackingAreas()
        }
        let background = surfaceView.bridge?.state.backgroundColor
            ?? GhosttyResolvedAppearance.backgroundColor(from: GhosttyRuntime.shared.config)
        scrollView.appearance = NSAppearance(named: background.isLight ? .aqua : .darkAqua)
    }

    // MARK: Hover

    /// Overlay scrollers only appear while scrolling, so with a mouse that has
    /// no wheel, or "Show scroll bars: Always" set, there would be nothing to
    /// grab. Flash the scroller when the pointer is over its strip.
    override func mouseMoved(with event: NSEvent) {
        guard NSScroller.preferredScrollerStyle == .legacy else { return }
        scrollView.flashScrollers()
    }

    override func updateTrackingAreas() {
        trackingAreas.forEach { removeTrackingArea($0) }
        super.updateTrackingAreas()
        guard scrollView.hasVerticalScroller, let scroller = scrollView.verticalScroller else { return }
        addTrackingArea(NSTrackingArea(
            rect: convert(scroller.bounds, from: scroller),
            options: [.mouseMoved, .activeInKeyWindow],
            owner: self
        ))
    }

    private var geometry: TerminalScrollGeometry? {
        guard let state = surfaceView.bridge?.state, let scrollbar = state.scrollbar else { return nil }
        // libghostty reports cell size in pixels.
        let cellHeight = surfaceView.convertFromBacking(state.cellSize).height
        guard cellHeight > 0 else { return nil }
        return TerminalScrollGeometry(
            scrollbar: scrollbar,
            cellHeight: cellHeight,
            contentHeight: scrollView.contentSize.height
        )
    }

    private func synchronizeScrollView() {
        guard let geometry else {
            documentView.frame.size.height = scrollView.contentSize.height
            return
        }
        synchronizeAppearance()
        documentView.frame.size.height = geometry.documentHeight
        // Moving the clip view mid-drag would fight the user's hand.
        if !isLiveScrolling {
            scrollView.contentView.scroll(to: CGPoint(x: 0, y: geometry.clipOriginY))
            lastSentRow = Int(geometry.scrollbar.offset)
        }
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    private func synchronizeSurfacePosition() {
        surfaceView.frame.origin = scrollView.contentView.documentVisibleRect.origin
    }

    private func handleLiveScroll() {
        guard let geometry else { return }
        let row = geometry.row(atClipOriginY: scrollView.contentView.documentVisibleRect.origin.y)
        guard row != lastSentRow else { return }
        lastSentRow = row
        _ = surfaceView.performBindingAction("scroll_to_row:\(row)")
    }

    nonisolated static func showsScrollbar(_ config: ghostty_config_t?) -> Bool {
        guard let config else { return true }
        var value: UnsafePointer<CChar>?
        let key = "scrollbar"
        let ok = key.withCString { ptr in
            ghostty_config_get(config, &value, ptr, UInt(strlen(ptr)))
        }
        guard ok, let value else { return true }
        return String(cString: value) != "never"
    }
}

private extension NSColor {
    var isLight: Bool {
        guard let rgb = usingColorSpace(.sRGB) else { return false }
        let luminance = 0.299 * rgb.redComponent + 0.587 * rgb.greenComponent + 0.114 * rgb.blueComponent
        return luminance > 0.5
    }
}
