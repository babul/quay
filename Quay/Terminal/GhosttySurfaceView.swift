import AppKit
import GhosttyKit

/// `NSView` that hosts a single `ghostty_surface_t`.
///
/// libghostty owns the Metal layer, the PTY, and the rendering loop. We just
/// give it an `NSView` to draw into and forward events.
@MainActor
final class GhosttySurfaceView: NSView {
    private let runtime: GhosttyRuntime
    /// Exposed `internal` so libghostty's runtime callbacks (clipboard,
    /// close, etc.) can recover the surface from a `GhosttySurfaceView`
    /// fished out of userdata. Don't mutate from outside the view.
    private(set) var surface: ghostty_surface_t?
    private let surfaceConfig: GhosttySurfaceConfig

    init(runtime: GhosttyRuntime, config: GhosttySurfaceConfig) {
        self.runtime = runtime
        self.surfaceConfig = config
        super.init(frame: .zero)

        // libghostty installs a CAMetalLayer on this NSView at surface_new time.
        wantsLayer = true

        // We participate in first-responder + key-event routing.
        canDrawConcurrently = false
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    isolated deinit {
        // The surface owns a Metal layer + PTY tied to the main thread, so
        // freeing must happen here on @MainActor (SE-0371 isolated deinit).
        if let surface {
            ghostty_surface_free(surface)
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil, surface == nil else { return }

        let nsViewPtr = Unmanaged.passUnretained(self).toOpaque()
        surface = surfaceConfig.withCConfig(nsView: nsViewPtr) { cfg in
            ghostty_surface_new(runtime.app, &cfg)
        }
        if surface == nil {
            GhosttyRuntime.logger.error("ghostty_surface_new returned nil")
        }

        if let scale = window?.backingScaleFactor, let surface {
            ghostty_surface_set_content_scale(surface, scale, scale)
        }
        pushSize()
    }

    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if let surface { ghostty_surface_set_focus(surface, true) }
        return ok
    }

    override func resignFirstResponder() -> Bool {
        let ok = super.resignFirstResponder()
        if let surface { ghostty_surface_set_focus(surface, false) }
        return ok
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        pushSize()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        guard let surface, let scale = window?.backingScaleFactor else { return }
        ghostty_surface_set_content_scale(surface, scale, scale)
    }

    private func pushSize() {
        guard let surface else { return }
        let pixels = convertToBacking(bounds.size)
        ghostty_surface_set_size(
            surface,
            UInt32(max(1, pixels.width)),
            UInt32(max(1, pixels.height))
        )
    }

    // MARK: Keyboard

    override func keyDown(with event: NSEvent) {
        sendKey(event, action: GHOSTTY_ACTION_PRESS)
        // ghostty_surface_text covers IME-free direct input. We send it
        // alongside the key so plain ASCII characters reach the PTY before
        // we layer in NSTextInputClient (deferred to v0.2).
        if let chars = event.charactersIgnoringModifiers, !chars.isEmpty,
           let surface {
            chars.withCString { ptr in
                ghostty_surface_text(surface, ptr, UInt(strlen(ptr)))
            }
        }
    }

    override func keyUp(with event: NSEvent) {
        sendKey(event, action: GHOSTTY_ACTION_RELEASE)
    }

    override func flagsChanged(with event: NSEvent) {
        sendKey(event, action: GHOSTTY_ACTION_PRESS)
    }

    private func sendKey(_ event: NSEvent, action: ghostty_input_action_e) {
        guard let surface else { return }
        var key = ghostty_input_key_s()
        key.action = action
        key.keycode = UInt32(event.keyCode)
        key.mods = ghosttyMods(event.modifierFlags)
        key.consumed_mods = key.mods
        key.unshifted_codepoint = 0
        key.composing = false
        key.text = nil
        _ = ghostty_surface_key(surface, key)
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        // Position must be sent before the button so libghostty knows where
        // the click started — this is what the selection system anchors on.
        sendMousePos(event)
        sendMouseButton(event, state: GHOSTTY_MOUSE_PRESS, button: GHOSTTY_MOUSE_LEFT)
        window?.makeFirstResponder(self)
        startAutoscrollIfNeeded(event: event)
    }

    override func mouseUp(with event: NSEvent) {
        stopAutoscroll()
        sendMousePos(event)
        sendMouseButton(event, state: GHOSTTY_MOUSE_RELEASE, button: GHOSTTY_MOUSE_LEFT)
    }

    override func rightMouseDown(with event: NSEvent) {
        sendMousePos(event)
        sendMouseButton(event, state: GHOSTTY_MOUSE_PRESS, button: GHOSTTY_MOUSE_RIGHT)
    }

    override func rightMouseUp(with event: NSEvent) {
        sendMousePos(event)
        sendMouseButton(event, state: GHOSTTY_MOUSE_RELEASE, button: GHOSTTY_MOUSE_RIGHT)
    }

    override func otherMouseDown(with event: NSEvent) {
        sendMousePos(event)
        sendMouseButton(event, state: GHOSTTY_MOUSE_PRESS, button: GHOSTTY_MOUSE_MIDDLE)
    }

    override func otherMouseUp(with event: NSEvent) {
        sendMousePos(event)
        sendMouseButton(event, state: GHOSTTY_MOUSE_RELEASE, button: GHOSTTY_MOUSE_MIDDLE)
    }

    override func mouseMoved(with event: NSEvent) { sendMousePos(event) }
    override func mouseDragged(with event: NSEvent) {
        sendMousePos(event)
        updateAutoscroll(event: event)
    }
    override func rightMouseDragged(with event: NSEvent) { sendMousePos(event) }
    override func otherMouseDragged(with event: NSEvent) { sendMousePos(event) }

    override func scrollWheel(with event: NSEvent) {
        guard let surface else { return }
        var x = event.scrollingDeltaX
        var y = event.scrollingDeltaY
        // For mice with discrete (non-precise) scroll wheels, NSEvent
        // reports tiny deltas (often 1.0). libghostty expects the same
        // pixel-equivalents Apple sends for trackpads, so scale up.
        if !event.hasPreciseScrollingDeltas {
            x *= 10
            y *= 10
        }
        var mods: Int32 = 0
        if event.hasPreciseScrollingDeltas { mods |= 1 }
        if event.momentumPhase != [] { mods |= 2 }
        ghostty_surface_mouse_scroll(surface, x, y, ghostty_input_scroll_mods_t(mods))
    }

    private func sendMouseButton(
        _ event: NSEvent,
        state: ghostty_input_mouse_state_e,
        button: ghostty_input_mouse_button_e
    ) {
        guard let surface else { return }
        _ = ghostty_surface_mouse_button(surface, state, button, ghosttyMods(event.modifierFlags))
    }

    private func sendMousePos(_ event: NSEvent) {
        guard let surface else { return }
        let local = convert(event.locationInWindow, from: nil)
        // libghostty uses top-left origin; AppKit gives us bottom-left. Flip Y.
        let flippedY = bounds.height - local.y
        ghostty_surface_mouse_pos(surface, local.x, flippedY, ghosttyMods(event.modifierFlags))
    }

    // MARK: Tracking area for mouseMoved

    private var trackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeInActiveApp, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
        trackingArea = area
    }

    // MARK: Selection helpers

    /// Read libghostty's current selection as a Swift `String`. Returns
    /// `nil` if there's no selection. Caller doesn't need to free anything.
    fileprivate func currentSelectionText() -> String? {
        guard let surface, ghostty_surface_has_selection(surface) else { return nil }
        var text = ghostty_text_s()
        guard ghostty_surface_read_selection(surface, &text), text.text != nil, text.text_len > 0
        else { return nil }
        defer { ghostty_surface_free_text(surface, &text) }
        let buffer = UnsafeBufferPointer(
            start: UnsafeRawPointer(text.text!).assumingMemoryBound(to: UInt8.self),
            count: Int(text.text_len)
        )
        return String(decoding: buffer, as: UTF8.self)
    }

    /// Inject `text` into the surface as if pasted. libghostty echoes the
    /// bytes through its IME-aware path (handles bracketed paste, etc.).
    fileprivate func injectPasteText(_ text: String) {
        guard let surface, !text.isEmpty else { return }
        text.withCString { ptr in
            ghostty_surface_text(surface, ptr, UInt(strlen(ptr)))
        }
    }

    /// Trigger a libghostty binding action by name (e.g. `select_all`).
    fileprivate func performBindingAction(_ name: String) -> Bool {
        guard let surface else { return false }
        return name.withCString { ptr in
            ghostty_surface_binding_action(surface, ptr, UInt(strlen(ptr)))
        }
    }
}

// MARK: - Edit-menu / responder-chain actions
//
// `selectAll(_:)`, `cut`, `copy`, `paste` are NSResponder informal methods
// surfaced via @objc selectors — not Swift overrides. validateMenuItem
// comes from NSMenuItemValidation which we conform to below.

extension GhosttySurfaceView: NSMenuItemValidation {
    @objc func copy(_ sender: Any?) {
        guard let text = currentSelectionText() else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    @objc func cut(_ sender: Any?) {
        // Terminals don't really cut — it's ambiguous (do you remove from
        // scrollback?). Fall back to copy so the menu item is non-destructive.
        copy(sender)
    }

    @objc func paste(_ sender: Any?) {
        guard let text = NSPasteboard.general.string(forType: .string) else { return }
        injectPasteText(text)
    }

    override func selectAll(_ sender: Any?) {
        _ = performBindingAction("select_all")
    }

    public func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(copy(_:)), #selector(cut(_:)):
            return currentSelectionText() != nil
        case #selector(paste(_:)):
            return NSPasteboard.general.string(forType: .string) != nil
        case #selector(selectAll(_:)):
            return surface != nil
        default:
            return true
        }
    }
}

// MARK: - Services menu (used by PopClip + system services)

extension GhosttySurfaceView {
    /// Tell macOS we can produce a string for `sendType == .string` and
    /// (for paste-style services) consume one for `returnType == .string`.
    override func validRequestor(
        forSendType sendType: NSPasteboard.PasteboardType?,
        returnType: NSPasteboard.PasteboardType?
    ) -> Any? {
        let canSend = sendType == nil || (sendType == .string && currentSelectionText() != nil)
        let canReturn = returnType == nil || returnType == .string
        if canSend && canReturn { return self }
        return super.validRequestor(forSendType: sendType, returnType: returnType)
    }

    /// Write the current selection into a pasteboard for a Service to consume.
    /// `NSServicesMenuRequestor` informal-protocol method — not a Swift override.
    @objc func writeSelection(
        to pboard: NSPasteboard,
        types: [NSPasteboard.PasteboardType]
    ) -> Bool {
        guard types.contains(.string), let text = currentSelectionText() else { return false }
        pboard.clearContents()
        pboard.setString(text, forType: .string)
        return true
    }

    /// Receive a string from a Service that returns text. Treat it as a paste.
    @objc func readSelection(from pboard: NSPasteboard) -> Bool {
        guard let text = pboard.string(forType: .string) else { return false }
        injectPasteText(text)
        return true
    }
}

// MARK: - Autoscroll while drag-selecting outside the view
//
// AppKit stops firing mouseDragged when the cursor is held still — even
// outside the view's bounds. To let users drag-select past the visible
// scrollback, we keep a timer running for the duration of the press. Each
// tick: re-send the cursor's current position to libghostty (so its
// selection extends) and, if the cursor is above/below the view, push a
// synthetic scroll event so libghostty advances the viewport.

private struct AutoscrollState {
    var timer: Timer
    var lastEvent: NSEvent
}

extension GhosttySurfaceView {
    fileprivate static var autoscrollKey: UInt8 = 0

    private var autoscrollState: AutoscrollState? {
        get { objc_getAssociatedObject(self, &Self.autoscrollKey) as? AutoscrollState }
        set { objc_setAssociatedObject(self, &Self.autoscrollKey, newValue, .OBJC_ASSOCIATION_RETAIN) }
    }

    fileprivate func startAutoscrollIfNeeded(event: NSEvent) {
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

    fileprivate func updateAutoscroll(event: NSEvent) {
        autoscrollState?.lastEvent = event
    }

    fileprivate func stopAutoscroll() {
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

// MARK: - Accessibility (so PopClip's accessibility-based selection reader works)

extension GhosttySurfaceView {
    override func isAccessibilityElement() -> Bool { true }

    override func accessibilityRole() -> NSAccessibility.Role? { .textArea }

    override func accessibilitySelectedText() -> String? { currentSelectionText() }

    override func accessibilityNumberOfCharacters() -> Int {
        currentSelectionText()?.count ?? 0
    }

    override func accessibilityValue() -> Any? {
        // Returning the entire scrollback would be expensive and most
        // selection-aware tools (PopClip) only need accessibilitySelectedText.
        // Hand them just the selection so "selected text" reads identically
        // to "value".
        currentSelectionText()
    }
}

@MainActor
private func ghosttyMods(_ flags: NSEvent.ModifierFlags) -> ghostty_input_mods_e {
    var mods: UInt32 = 0
    if flags.contains(.shift)    { mods |= GHOSTTY_MODS_SHIFT.rawValue }
    if flags.contains(.control)  { mods |= GHOSTTY_MODS_CTRL.rawValue }
    if flags.contains(.option)   { mods |= GHOSTTY_MODS_ALT.rawValue }
    if flags.contains(.command)  { mods |= GHOSTTY_MODS_SUPER.rawValue }
    if flags.contains(.capsLock) { mods |= GHOSTTY_MODS_CAPS.rawValue }
    return ghostty_input_mods_e(mods)
}
