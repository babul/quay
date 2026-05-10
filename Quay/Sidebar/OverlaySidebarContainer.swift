import SwiftUI

/// Shared overlay sidebar container for both the left (hover-driven) and right (click-driven) sidebars.
///
/// Animates visibility via `offset` (GPU-accelerated transform) rather than layout changes.
/// Owns the resize drag state internally so that drag updates don't propagate to the parent view,
/// preventing full-hierarchy re-renders on every cursor move during resize.
struct OverlaySidebarContainer<Content: View>: View {
    /// Extra padding added beyond `width` when offsetting offscreen, to ensure the shadow
    /// doesn't peek through during the hide animation.
    private static var hiddenOffsetPadding: CGFloat { 32 }
    /// Width of the invisible drag area overlapping the separator.
    private static var edgeHandleWidth: CGFloat { 9 }

    let isVisible: Bool
    @Binding var width: CGFloat
    let edge: HorizontalEdge
    let range: ClosedRange<CGFloat>
    let onCommit: (CGFloat) -> Void
    @ViewBuilder let content: () -> Content

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Local drag-in-progress width. Initialized from `width`; written back to `width` only on
    /// gesture end so the parent view doesn't re-render on every drag pixel.
    @State private var localWidth: CGFloat

    init(
        isVisible: Bool,
        width: Binding<CGFloat>,
        edge: HorizontalEdge,
        range: ClosedRange<CGFloat>,
        onCommit: @escaping (CGFloat) -> Void,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.isVisible = isVisible
        self._width = width
        self.edge = edge
        self.range = range
        self.onCommit = onCommit
        self.content = content
        self._localWidth = State(initialValue: width.wrappedValue)
    }

    private var isLeading: Bool { edge == .leading }
    private var hiddenOffset: CGFloat {
        let magnitude = localWidth + Self.hiddenOffsetPadding
        return isLeading ? -magnitude : magnitude
    }
    private var innerEdgeAlignment: Alignment { isLeading ? .trailing : .leading }
    private var outerEdgeAlignment: Alignment { isLeading ? .leading : .trailing }
    private var containerAlignment: Alignment { isLeading ? .leading : .trailing }
    private var shadowOffsetX: CGFloat { isLeading ? 4 : -4 }

    var body: some View {
        content()
            .frame(width: localWidth)
            .background(.ultraThinMaterial)
            .overlay(alignment: outerEdgeAlignment) {
                Rectangle().fill(.separator).frame(width: 1)
            }
            .overlay(alignment: innerEdgeAlignment) {
                SidebarResizeHandle(
                    edge: edge,
                    width: $localWidth,
                    range: range,
                    onCommit: { committed in
                        width = committed
                        onCommit(committed)
                    }
                )
                .frame(width: Self.edgeHandleWidth)
            }
            .compositingGroup()
            .shadow(color: .black.opacity(0.18), radius: 14, x: shadowOffsetX, y: 0)
            .frame(maxWidth: .infinity, alignment: containerAlignment)
            .offset(x: isVisible ? 0 : hiddenOffset)
            .animation(
                reduceMotion ? .linear(duration: 0.12) : .snappy(duration: 0.3),
                value: isVisible
            )
            .allowsHitTesting(isVisible)
            .accessibilityHidden(!isVisible)
            .onChange(of: width) { _, newWidth in
                guard localWidth != newWidth else { return }
                localWidth = newWidth
            }
    }
}
