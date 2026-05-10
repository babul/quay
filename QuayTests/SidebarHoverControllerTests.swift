import Testing
@testable import Quay

// MARK: - Test clock

/// A clock whose sleep checks cancellation and returns immediately.
/// Non-cancelled tasks complete as soon as the executor runs them.
struct ImmediateClock: Clock {
    struct Instant: InstantProtocol {
        typealias Duration = Swift.Duration
        var offset: Swift.Duration = .zero
        func advanced(by duration: Swift.Duration) -> Self { .init(offset: offset + duration) }
        func duration(to other: Self) -> Swift.Duration { other.offset - offset }
        static func < (lhs: Self, rhs: Self) -> Bool { lhs.offset < rhs.offset }
    }

    var now: Instant { .init() }
    var minimumResolution: Swift.Duration { .nanoseconds(1) }
    func sleep(until deadline: Instant, tolerance: Swift.Duration? = nil) async throws {
        try Task.checkCancellation()
    }
}

// MARK: - Test helpers

private extension SidebarHoverController {
    /// Yield up to `max` times, returning as soon as `isVisible == target`.
    /// Handles queue noise (infrastructure tasks, prior-test leftovers) by polling.
    func settle(visible target: Bool, max: Int = 20) async {
        for _ in 0..<max {
            if isVisible == target { return }
            await Task.yield()
        }
    }

    /// Drain pending tasks without waiting for a specific state (e.g. after cancellation).
    func drain(yields: Int = 5) async {
        for _ in 0..<yields { await Task.yield() }
    }
}

// MARK: - Tests

@MainActor
@Suite("SidebarHoverController", .serialized)
struct SidebarHoverControllerTests {

    // MARK: Hysteresis

    @Test("Cursor at width+1 stays visible — exit threshold is width+24, not width")
    func hysteresisExitThreshold() async {
        let ctrl = SidebarHoverController(clock: ImmediateClock())
        ctrl.cursorMoved(localX: 4)
        await ctrl.settle(visible: true)
        ctrl.cursorMoved(localX: ctrl.width + 1)    // still ≤ width+24 → no hide
        await ctrl.drain()
        #expect(ctrl.isVisible)
    }

    @Test("Cursor outside width+24 schedules hide")
    func exitThresholdTriggersHide() async {
        let ctrl = SidebarHoverController(clock: ImmediateClock())
        ctrl.cursorMoved(localX: 4)
        await ctrl.settle(visible: true)
        #expect(ctrl.isVisible)

        ctrl.cursorMoved(localX: ctrl.width + 25)
        await ctrl.settle(visible: false)
        #expect(!ctrl.isVisible)
    }

    // MARK: Entry delay

    @Test("Entry delay: cursor leaves before task runs — sidebar stays hidden")
    func entryDelayCancel() async {
        let ctrl = SidebarHoverController(clock: ImmediateClock())
        ctrl.cursorMoved(localX: 4)
        ctrl.cursorMoved(localX: nil)               // cancels showTask before it runs
        await ctrl.drain()
        #expect(!ctrl.isVisible)
    }

    // MARK: Exit delay

    @Test("Exit delay: cursor returns before task runs — hide cancelled")
    func exitDelayCancel() async {
        let ctrl = SidebarHoverController(clock: ImmediateClock())
        ctrl.cursorMoved(localX: 4)
        await ctrl.settle(visible: true)
        #expect(ctrl.isVisible)

        ctrl.cursorMoved(localX: ctrl.width + 25)   // schedules hideTask
        ctrl.cursorMoved(localX: ctrl.width)         // cancels hideTask (still ≤ width+24)
        await ctrl.drain()
        #expect(ctrl.isVisible)
    }

    // MARK: Pin (⌘B)

    @Test("manualToggle when hidden: sidebar shows and is pinned")
    func pinShow() async {
        let ctrl = SidebarHoverController(clock: ImmediateClock())
        ctrl.manualToggle()
        #expect(ctrl.isVisible)
        #expect(ctrl.pinned)

        ctrl.cursorMoved(localX: nil)               // pinned — cursor ignored
        await ctrl.drain()
        #expect(ctrl.isVisible)
    }

    @Test("manualToggle twice: unpin and hide")
    func pinHide() {
        let ctrl = SidebarHoverController(clock: ImmediateClock())
        ctrl.manualToggle()
        ctrl.manualToggle()
        #expect(!ctrl.isVisible)
        #expect(!ctrl.pinned)
    }

    @Test("manualToggle when visible (not pinned): hides without pinning")
    func toggleVisibleUnpinned() async {
        let ctrl = SidebarHoverController(clock: ImmediateClock())
        ctrl.cursorMoved(localX: 4)
        await ctrl.settle(visible: true)
        #expect(ctrl.isVisible)
        #expect(!ctrl.pinned)

        ctrl.manualToggle()
        #expect(!ctrl.isVisible)
        #expect(!ctrl.pinned)
    }

    // MARK: Tabs empty

    @Test("setTabsEmpty(true): shows sidebar and suppresses cursor-driven hide")
    func tabsEmptyShows() async {
        let ctrl = SidebarHoverController(clock: ImmediateClock())
        ctrl.setTabsEmpty(true)
        #expect(ctrl.isVisible)

        ctrl.cursorMoved(localX: nil)               // tabsEmpty suppresses hide
        await ctrl.drain()
        #expect(ctrl.isVisible)
    }

    @Test("setTabsEmpty(false) with cursor outside: re-evaluates and hides")
    func tabsNonEmptyHides() async {
        let ctrl = SidebarHoverController(clock: ImmediateClock())
        ctrl.setTabsEmpty(true)
        ctrl.cursorMoved(localX: nil)

        ctrl.setTabsEmpty(false)                    // reEvaluate → schedules hideTask
        await ctrl.settle(visible: false)
        #expect(!ctrl.isVisible)
    }

    @Test("manualToggle while tabsEmpty: no-op, stays visible")
    func manualToggleSuppressedByTabsEmpty() async {
        let ctrl = SidebarHoverController(clock: ImmediateClock())
        ctrl.setTabsEmpty(true)
        #expect(ctrl.isVisible)

        ctrl.manualToggle()
        await ctrl.drain()
        #expect(ctrl.isVisible)
        #expect(!ctrl.pinned)
    }

    @Test("manualToggle while tabsEmpty and pinned: still no-op")
    func manualToggleSuppressedByTabsEmptyEvenWhenPinned() async {
        let ctrl = SidebarHoverController(clock: ImmediateClock())
        ctrl.manualToggle()                         // pin first
        #expect(ctrl.pinned)
        ctrl.setTabsEmpty(true)

        ctrl.manualToggle()                         // would normally unpin+hide
        await ctrl.drain()
        #expect(ctrl.isVisible)
        #expect(ctrl.pinned)                        // pin preserved
    }

    @Test("setTabsEmpty with same value: no-op")
    func tabsEmptyIdempotent() {
        let ctrl = SidebarHoverController(clock: ImmediateClock())
        ctrl.setTabsEmpty(true)
        let visibleBefore = ctrl.isVisible
        ctrl.setTabsEmpty(true)
        #expect(ctrl.isVisible == visibleBefore)
    }

    // MARK: Soft-hide on connection

    @Test("connectionDidConnect: hides when cursor is in terminal area")
    func softHideOnConnect() async {
        let ctrl = SidebarHoverController(clock: ImmediateClock())
        ctrl.cursorMoved(localX: 4)
        await ctrl.settle(visible: true)
        #expect(ctrl.isVisible)

        ctrl.cursorMoved(localX: ctrl.width + 50)   // cursor in terminal → schedules hideTask
        ctrl.connectionDidConnect()                 // no-op (hideTask already scheduled)
        await ctrl.settle(visible: false)
        #expect(!ctrl.isVisible)
    }

    @Test("connectionDidConnect: no hide when cursor is still over sidebar")
    func noHideOnConnectWhenCursorOverSidebar() async {
        let ctrl = SidebarHoverController(clock: ImmediateClock())
        ctrl.cursorMoved(localX: 4)
        await ctrl.settle(visible: true)
        #expect(ctrl.isVisible)

        ctrl.connectionDidConnect()                 // cursor still at x=4 (≤ width+24) → no hide
        await ctrl.drain()
        #expect(ctrl.isVisible)
    }

    @Test("connectionDidConnect cancels a pending show task")
    func connectCancelsPendingShow() async {
        let ctrl = SidebarHoverController(clock: ImmediateClock())
        ctrl.cursorMoved(localX: ctrl.width + 50)   // cursor in terminal, not in show zone
        ctrl.cursorMoved(localX: 4)                 // enters show zone → showTask scheduled
        ctrl.connectionDidConnect()                 // cancels showTask
        await ctrl.drain()
        #expect(!ctrl.isVisible)
    }

    // MARK: Window resign key

    @Test("windowDidResignKey: schedules hide")
    func resignKeyHides() async {
        let ctrl = SidebarHoverController(clock: ImmediateClock())
        ctrl.cursorMoved(localX: 4)
        await ctrl.settle(visible: true)
        #expect(ctrl.isVisible)

        ctrl.windowDidResignKey()
        await ctrl.settle(visible: false)
        #expect(!ctrl.isVisible)
    }

    @Test("windowDidResignKey while pinned: no hide")
    func resignKeyRespectsPinned() async {
        let ctrl = SidebarHoverController(clock: ImmediateClock())
        ctrl.manualToggle()                         // synchronous pin + show
        ctrl.windowDidResignKey()
        await ctrl.drain()
        #expect(ctrl.isVisible)                     // pinned — resign key does not hide
    }

    // MARK: Interaction bump

    @Test("userDidInteract: cancels in-flight hide task")
    func interactionBumpCancelsHide() async {
        let ctrl = SidebarHoverController(clock: ImmediateClock())
        ctrl.cursorMoved(localX: 4)
        await ctrl.settle(visible: true)
        #expect(ctrl.isVisible)

        ctrl.cursorMoved(localX: ctrl.width + 50)   // schedules hideTask
        ctrl.userDidInteract()                      // cancels hideTask
        await ctrl.drain()
        #expect(ctrl.isVisible)                     // hide was suppressed
    }
}
