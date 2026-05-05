import AppKit

// MARK: - Autoscroll while drag-selecting outside the view
//
// AppKit stops firing mouseDragged when the cursor is held still — even
// outside the view's bounds. To let users drag-select past the visible
// scrollback, we keep a timer running for the duration of the press. Each
// tick: re-send the cursor's current position to libghostty (so its
// selection extends) and, if the cursor is above/below the view, push a
// synthetic scroll event so libghostty advances the viewport.

extension GhosttySurfaceView {
    func startAutoscrollIfNeeded(event: NSEvent) {
        // We start the timer eagerly on mouseDown. It only does work when
        // the cursor is actually outside the view, so the cost while the
        // user clicks-without-dragging is one no-op timer fire.
        stopAutoscroll()
        let timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.autoscrollTick() }
        }
        RunLoop.current.add(timer, forMode: .eventTracking)
        autoscrollState = AutoscrollState(timer: timer, lastEvent: event)
    }

    func updateAutoscroll(event: NSEvent) {
        autoscrollState?.lastEvent = event
    }

    func stopAutoscroll() {
        autoscrollState?.timer.invalidate()
        autoscrollState = nil
    }

    @MainActor
    private func autoscrollTick() {
        guard let state = autoscrollState else { return }
        let local = convert(state.lastEvent.locationInWindow, from: nil)
        // AppKit's local.y measures from the *bottom* of the view. The
        // visible region is local.y in [0, bounds.height]; below the view
        // gives local.y < 0, above the view (toward top of screen) gives
        // local.y > bounds.height.
        let belowBottom = max(0, -local.y)
        let aboveTop = max(0, local.y - bounds.height)
        guard belowBottom > 0 || aboveTop > 0 else { return }
        // Lines per tick scales with how far past the edge the cursor is.
        // ~16 px ≈ one terminal row; cap so a flick at full velocity doesn't
        // teleport across the whole scrollback.
        let pixels = max(belowBottom, aboveTop)
        let lines = max(1, min(8, Int(pixels / 16)))
        // scroll_page_lines:+N scrolls toward newer content (down/bottom);
        // scroll_page_lines:-N scrolls toward older content (up/top).
        let signedLines = belowBottom > 0 ? lines : -lines
        _ = performBindingAction("scroll_page_lines:\(signedLines)")
        // Re-send the cursor position so libghostty extends the selection
        // through the freshly-exposed rows.
        sendMousePos(state.lastEvent)
    }
}
