import AppKit
import Observation
import SwiftUI

/// State machine for the auto-hiding left sidebar.
///
/// All properties and methods are main-actor–isolated. The controller is
/// injected into the environment so child views can call `userDidInteract()`.
///
/// Hysteresis: expand threshold is `x ≤ enterPad`; collapse threshold is
/// `x > width + exitPad`. This prevents oscillation at any single boundary.
@Observable
@MainActor
final class SidebarHoverController {
    // MARK: - Tunables

    /// Cursor x ≤ this triggers show when sidebar is hidden.
    private static let enterPad: CGFloat = 8
    /// Cursor x > width + this triggers hide when sidebar is visible.
    private static let exitPad: CGFloat = 24
    /// Delay before scheduled show takes effect.
    private static let showDelay: Duration = .milliseconds(120)
    /// Delay before scheduled hide takes effect.
    private static let hideDelay: Duration = .milliseconds(350)
    /// Window after a sidebar click during which hides are suppressed.
    private static let interactionBumpDuration: Duration = .milliseconds(600)

    // MARK: - State

    private(set) var isVisible = false
    var width: CGFloat
    private(set) var pinned = false
    private(set) var autoHideEnabled = true

    var tabsEmpty = false

    // Right sidebar state: set by ContentView so the click monitor can correctly
    // identify terminal-area clicks vs right-sidebar clicks without importing SwiftUI state.
    var rightSidebarOpen = false
    var rightSidebarWidth: CGFloat = SidebarLayoutState.rightDefaultWidth

    // Read-side only — intentionally not injected via `clock` so tests can't control the wall time.
    private var interactionBumpUntil: ContinuousClock.Instant?
    private var showTask: Task<Void, Never>?
    private var hideTask: Task<Void, Never>?
    private let clock: any Clock<Duration>
    private var lastLocalX: CGFloat?
    private var clickMonitor: Any?
    private var keyDownMonitor: Any?
    private weak var mainWindow: NSWindow?

    init(clock: any Clock<Duration> = ContinuousClock()) {
        self.width = SidebarLayoutState.loadWidth()
        self.clock = clock
    }

    // MARK: - Lifecycle

    func start(mainWindow: NSWindow) {
        self.mainWindow = mainWindow
        installClickMonitor()
        installKeyDownMonitor()
    }

    func stop() {
        removeClickMonitor()
        removeKeyDownMonitor()
        mainWindow = nil
    }

    // MARK: - Public API

    func cursorMoved(localX: CGFloat?) {
        lastLocalX = localX
        reEvaluate()
    }

    /// Called when `tabManager.tabs.isEmpty` changes.
    /// When tabs become empty the sidebar is shown and kept open; when non-empty, cursor position re-evaluated.
    func setTabsEmpty(_ empty: Bool) {
        guard tabsEmpty != empty else { return }
        tabsEmpty = empty
        if empty {
            cancelTasks()
            isVisible = true
        } else {
            reEvaluate()
        }
    }

    /// ⌘B: if sidebar is open, close and unpin; if closed, open and pin.
    func manualToggle() {
        guard !tabsEmpty else { return }
        cancelTasks()
        if isVisible {
            pinned = false
            isVisible = false
        } else {
            pinned = true
            isVisible = true
        }
    }

    /// Shows the sidebar without pinning — used by ⌘L so cursor-leave still auto-hides.
    func ensureVisible() {
        guard !tabsEmpty else { return }
        cancelTasks()
        isVisible = true
    }

    /// Called when a connection succeeds. Soft-hide: cancels any pending show, then
    /// hides on the standard delay only if the cursor is not currently over the sidebar.
    func connectionDidConnect() {
        cancelShow()
        guard isVisible, !cursorWithinExitZone, canAutoHide else { return }
        scheduleHide()
    }

    /// Called when `autoHideSidebar` changes. Resets suppression state; monitors stay
    /// installed throughout the window's lifetime so Escape handling works in both modes.
    func setAutoHide(_ enabled: Bool) {
        autoHideEnabled = enabled
        cancelTasks()
        pinned = false
        if !enabled {
            isVisible = false
        }
    }

    /// Called when the main window resigns key status.
    func windowDidResignKey() {
        // Cancel any pending show — sidebar shouldn't pop open in a deactivated window.
        cancelShow()
        lastLocalX = nil
        guard isVisible, canAutoHide else { return }
        scheduleHide()
    }

    /// Called on every left-mouse-down inside the sidebar (from the click monitor).
    /// Suppresses an in-flight hide for the duration of the interaction bump.
    func userDidInteract() {
        interactionBumpUntil = ContinuousClock().now.advanced(by: Self.interactionBumpDuration)
        cancelHide()
    }

    // MARK: - Core state machine

    private func reEvaluate() {
        if cursorInActiveZone {
            cancelHide()
            guard !isVisible, !pinned, !tabsEmpty else { return }
            scheduleShow()
        } else {
            cancelShow()
            guard isVisible, canAutoHide else { return }
            scheduleHide()
        }
    }

    /// True if the cursor is within the zone that should keep the sidebar showing.
    /// Uses asymmetric thresholds (hysteresis) based on current visibility.
    private var cursorInActiveZone: Bool {
        guard let x = lastLocalX else { return false }
        return isVisible ? x <= width + Self.exitPad : x <= Self.enterPad
    }

    /// True if the cursor is within the wider hysteresis zone over the visible sidebar.
    private var cursorWithinExitZone: Bool {
        guard let x = lastLocalX else { return false }
        return x <= width + Self.exitPad
    }

    /// Common guard for any auto-hide. False when something should keep the sidebar open.
    private var canAutoHide: Bool {
        !pinned && !tabsEmpty && !inInteractionWindow
    }

    private var inInteractionWindow: Bool {
        guard let until = interactionBumpUntil else { return false }
        return ContinuousClock().now < until
    }

    private func scheduleShow() {
        scheduleVisibilityTask(\.showTask, after: Self.showDelay, setting: true)
    }

    private func scheduleHide() {
        scheduleVisibilityTask(\.hideTask, after: Self.hideDelay, setting: false)
    }

    private func scheduleVisibilityTask(
        _ keyPath: ReferenceWritableKeyPath<SidebarHoverController, Task<Void, Never>?>,
        after delay: Duration,
        setting newValue: Bool
    ) {
        guard self[keyPath: keyPath] == nil else { return }
        let clock = clock
        self[keyPath: keyPath] = Task { [weak self] in
            do {
                try await clock.sleep(for: delay)
            } catch {
                return
            }
            guard let self, !Task.isCancelled else { return }
            self.isVisible = newValue
            self[keyPath: keyPath] = nil
        }
    }

    private func cancelShow() {
        showTask?.cancel()
        showTask = nil
    }

    private func cancelHide() {
        hideTask?.cancel()
        hideTask = nil
    }

    private func cancelTasks() {
        cancelShow()
        cancelHide()
    }

    // MARK: - Click monitor

    private func installClickMonitor() {
        guard clickMonitor == nil else { return }
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            self?.handleLocalMouseDown(event)
            return event
        }
    }

    private func removeClickMonitor() {
        if let monitor = clickMonitor {
            NSEvent.removeMonitor(monitor)
            clickMonitor = nil
        }
    }

    private func installKeyDownMonitor() {
        guard keyDownMonitor == nil else { return }
        keyDownMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return event } // 53 = Escape
            let consumed = self?.handleEscapeKey() == true
            return consumed ? nil : event // nil = consumed, suppresses beep
        }
    }

    private func removeKeyDownMonitor() {
        if let monitor = keyDownMonitor {
            NSEvent.removeMonitor(monitor)
            keyDownMonitor = nil
        }
    }

    /// Handles Escape key. Returns true if the event was consumed (a sidebar was dismissed).
    @discardableResult
    private func handleEscapeKey() -> Bool {
        if autoHideEnabled, isVisible, !tabsEmpty {
            cancelTasks()
            pinned = false
            isVisible = false   // SidebarView.onChange(isVisible) releases focus
            return true
        }
        if rightSidebarOpen {
            // Right sidebar visibility is owned by ContentView; post a notification to close it.
            // SnippetSidebarView.onChange(isVisible) will release focus when ContentView responds.
            mainWindow?.makeFirstResponder(nil)
            NotificationCenter.default.post(name: .closeRightSidebar, object: nil)
            return true
        }
        return false
    }

    private func handleLocalMouseDown(_ event: NSEvent) {
        guard let mainWindow, event.window === mainWindow else { return }
        guard let contentView = mainWindow.contentView else { return }
        let clickX = contentView.convert(event.locationInWindow, from: nil).x
        let containerWidth = contentView.bounds.width

        let inLeftSidebar = isVisible && clickX <= width
        let inRightSidebar = rightSidebarOpen && clickX >= containerWidth - rightSidebarWidth

        if inLeftSidebar {
            userDidInteract()
        } else if !inRightSidebar, isVisible, !tabsEmpty, autoHideEnabled {
            cancelTasks()
            pinned = false
            isVisible = false   // SidebarView.onChange(isVisible) releases focus
        }
    }
}

extension EnvironmentValues {
    @Entry var sidebarHoverController: SidebarHoverController? = nil
}
