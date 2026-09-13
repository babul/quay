import AppKit
import Darwin
import GhosttyKit

/// `NSView` that hosts a single `ghostty_surface_t`.
///
/// libghostty owns the Metal layer, the PTY, and the rendering loop. We just
/// give it an `NSView` to draw into and forward events.
@MainActor
final class GhosttySurfaceView: NSView {
    private let runtime: GhosttyRuntime
    private(set) var surface: ghostty_surface_t?
    private let surfaceConfig: GhosttySurfaceConfig

    /// Action dispatcher and observable state. Nil until the surface is created
    /// in `viewDidMoveToWindow`. Set before `ghostty_surface_new` so userdata
    /// is valid for the first callback.
    private(set) var bridge: GhosttySurfaceBridge?

    // Autoscroll state — owned here so extensions in sibling files can access it.
    var autoscrollState: AutoscrollState?
    private var trackingArea: NSTrackingArea?

    // Observers for screen and occlusion changes, cleared in deinit.
    private var windowObservers: [NSObjectProtocol] = []
    // Last occlusion state, to avoid redundant calls to set_occlusion.
    private var lastOccluded: Bool = false

    /// Called once, right after the bridge and surface are created in
    /// `viewDidMoveToWindow`. The owning tab item uses this to wire
    /// `onCloseRequest`/`onChildExited` without a timing dependency.
    var onBridgeCreated: ((GhosttySurfaceBridge) -> Void)?

    /// Keys the surface answers on its owner's behalf once its child process
    /// has exited, instead of forwarding them to the (gone) terminal.
    enum DeadSessionKey {
        /// Space or Return — reconnect, mirroring the Cmd-R command.
        case reconnect
        /// Escape — call off an automatic retry cycle.
        case cancel
    }

    /// Called when a `DeadSessionKey` is pressed. Returns `true` if the owner
    /// acted on it, in which case the key is not forwarded to the terminal.
    var onDeadSessionKey: ((DeadSessionKey) -> Bool)?

    /// Whether a session owns the terminal right now. Between sessions the pty
    /// belongs to Quay's host shell, and anything written to it would run on
    /// this machine instead of the remote one.
    ///
    /// Defaults closed: a surface whose owner hasn't wired this up must not
    /// pass input to a host shell.
    var sessionOwnsTerminal: () -> Bool = { false }

    // IME state — owned here; modified by GhosttySurfaceView+IME.
    var markedText = NSMutableAttributedString()
    var keyTextAccumulator: [String]?

    init(runtime: GhosttyRuntime, config: GhosttySurfaceConfig) {
        self.runtime = runtime
        self.surfaceConfig = config
        super.init(frame: .zero)
        wantsLayer = true
        canDrawConcurrently = false
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    isolated deinit {
        for obs in windowObservers { NotificationCenter.default.removeObserver(obs) }
        NSCursor.setHiddenUntilMouseMoves(false)
        if let bridge { runtime.unregisterSurface(bridge) }
        if let surface { ghostty_surface_free(surface) }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil, surface == nil else { return }

        // Bridge must exist before ghostty_surface_new so that userdata is
        // valid for the very first callback libghostty may fire during creation.
        let newBridge = GhosttySurfaceBridge(config: runtime.config)
        newBridge.view = self
        bridge = newBridge

        let nsViewPtr = Unmanaged.passUnretained(self).toOpaque()
        let bridgePtr = Unmanaged.passUnretained(newBridge).toOpaque()
        surface = surfaceConfig.withCConfig(nsView: nsViewPtr, userdata: bridgePtr) { cfg in
            ghostty_surface_new(runtime.app, &cfg)
        }
        if surface == nil {
            GhosttyRuntime.logger.error("ghostty_surface_new returned nil")
        }

        if let scale = window?.backingScaleFactor, let surface {
            ghostty_surface_set_content_scale(surface, scale, scale)
        }
        pushDisplayID()
        pushSize()

        runtime.registerSurface(newBridge)
        installWindowObservers()
        applyResolvedBackground()
        window?.makeFirstResponder(self)
        onBridgeCreated?(newBridge)
        onBridgeCreated = nil
    }

    private func installWindowObservers() {
        guard let window else { return }
        let center = NotificationCenter.default
        windowObservers = [
            center.addObserver(
                forName: .ghosttyRuntimeConfigDidChange,
                object: runtime,
                queue: .main
            ) { [weak self] _ in MainActor.assumeIsolated { self?.applyResolvedBackground() } },
            center.addObserver(
                forName: NSWindow.didChangeOcclusionStateNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in MainActor.assumeIsolated { self?.updateOcclusion() } },
            center.addObserver(
                forName: NSWindow.didChangeScreenNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in MainActor.assumeIsolated { self?.pushDisplayID() } },
        ]
    }

    func applyResolvedBackground() {
        guard let bridge else { return }
        let color = GhosttyResolvedAppearance.color(
            bridge.state.backgroundColor,
            with: bridge.state.backgroundOpacity
        )
        layer?.backgroundColor = color.cgColor

        guard let window else { return }
        window.isOpaque = GhosttyResolvedAppearance.isOpaque(bridge.state.backgroundOpacity)
        window.backgroundColor = color
    }

    private func pushDisplayID() {
        guard let surface else { return }
        let id = window?.screen?.displayID ?? 0
        ghostty_surface_set_display_id(surface, id)
    }

    private func updateOcclusion() {
        guard let surface, let window else { return }
        let occluded = !window.occlusionState.contains(.visible)
        guard occluded != lastOccluded else { return }
        lastOccluded = occluded
        ghostty_surface_set_occlusion(surface, !occluded)
    }

    /// The pty's foreground process group leader while the child is alive.
    /// libghostty names it a pid, but it is `tcgetpgrp` — see
    /// `SessionConnectionProbe`, which relies on that.
    private var liveForegroundPID: pid_t? {
        guard hasLiveHostShell, let surface else { return nil }
        let pid = pid_t(ghostty_surface_foreground_pid(surface))
        return pid > 0 ? pid : nil
    }

    /// Hangs up the session client, leaving the host shell — and with it the
    /// screen — alone. Signalling the foreground pid blindly would kill the
    /// shell whenever no session is running.
    func disconnectSessionClient(clientNames: Set<String>) {
        guard let pid = liveForegroundPID else { return }
        for member in SessionConnectionProbe.sessionProcesses(pgid: pid)
        where clientNames.contains(SessionConnectionProbe.processName(of: member) ?? "") {
            _ = Darwin.kill(member, SIGHUP)
        }
    }

    /// What the pty's foreground process group is doing. See
    /// `SessionConnectionProbe` for why the screen can't answer this.
    func foregroundSnapshot(clientNames: Set<String>) -> SessionConnectionProbe.Foreground {
        guard let pgid = liveForegroundPID else { return .init() }
        return SessionConnectionProbe.foreground(pgid: pgid, clientNames: clientNames)
    }

    /// Presence only — what the input gate needs, without the socket walk.
    func hasRunningClient(clientNames: Set<String>) -> Bool {
        guard let pgid = liveForegroundPID else { return false }
        return SessionConnectionProbe.clientIsRunning(pgid: pgid, clientNames: clientNames)
    }

    /// Writes text to the session, and only to a session. Every caller that
    /// sends on the user's behalf goes through here rather than reaching for
    /// the bridge, so the gate can't be forgotten.
    @discardableResult
    func sendUserInput(_ text: String, appendReturn: Bool = false) -> Bool {
        guard forwardsUserInput, let bridge else { return false }
        bridge.sendText(text)
        if appendReturn { bridge.sendReturnKey() }
        return true
    }

    /// True once the host shell has turned the terminal's echo off, which is
    /// the last thing its startup does — so it doubles as "ready to be typed
    /// into".
    ///
    /// Without this, a command typed while the login shell is still sourcing
    /// the user's profile is echoed by the line discipline, printing the whole
    /// ssh invocation on screen before the shell ever reads it.
    var hostShellHasQuietedTerminal: Bool {
        guard let surface else { return false }
        let name = ghostty_surface_tty_name(surface)
        defer { ghostty_string_free(name) }
        guard let ptr = name.ptr, name.len > 0 else { return false }
        return SessionConnectionProbe.echoDisabled(ttyPath: String(cString: ptr))
    }

    /// True while the tab's host shell is still running, so the next session can
    /// be typed into the screen this one leaves behind.
    var hasLiveHostShell: Bool {
        guard let surface else { return false }
        return !ghostty_surface_process_exited(surface)
    }

    /// Consumes Space/Return (reconnect) and Escape (stop retrying) whenever no
    /// session owns the terminal, letting the owner decide whether the key
    /// applies right now. While a session is live every key belongs to it — an
    /// in-flight connect may be sitting at a host-key or password prompt, where
    /// Escape is the user's answer and not ours to take.
    func handleDeadSessionKey(_ event: NSEvent) -> Bool {
        guard let onDeadSessionKey, !forwardsUserInput,
              let key = Self.deadSessionKey(
                  keyCode: event.keyCode,
                  modifiers: event.modifierFlags
              )
        else { return false }
        return onDeadSessionKey(key)
    }

    /// Whether user input may reach the terminal. Every path that writes to the
    /// pty on the user's behalf — keys, IME, paste, Services, middle-click —
    /// must check this, or that input runs in Quay's host shell instead of the
    /// session. Defaults to `true` so a surface with no owner wired up behaves
    /// like a plain terminal.
    ///
    /// The owner answers by asking the kernel *now* rather than from a polled
    /// flag: a session that exited since the last poll would otherwise leave
    /// this open for the rest of the interval.
    var forwardsUserInput: Bool {
        // Decided once per key event: the answer is a syscall, and one
        // keystroke otherwise asks four times (the dead-session check, keyDown,
        // insertText, keyUp). Memoising per event also keeps those four
        // consistent — a session dying mid-stack would otherwise decline the
        // key *and* swallow it.
        if let inputGateForCurrentEvent { return inputGateForCurrentEvent }
        return hasLiveHostShell && sessionOwnsTerminal()
    }

    /// Set for the duration of one key event. See `forwardsUserInput`.
    var inputGateForCurrentEvent: Bool?

    /// Space, Return, keypad Enter or Escape with no meaningful modifiers held.
    nonisolated static func deadSessionKey(
        keyCode: UInt16,
        modifiers: NSEvent.ModifierFlags
    ) -> DeadSessionKey? {
        let ignored: NSEvent.ModifierFlags = [.capsLock, .function, .numericPad]
        let held = modifiers.intersection(.deviceIndependentFlagsMask).subtracting(ignored)
        guard held.isEmpty else { return nil }
        switch keyCode {
        case 36, 49, 76: return .reconnect  // return, space, keypad enter
        case 53: return .cancel  // escape
        default: return nil
        }
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
        NSCursor.setHiddenUntilMouseMoves(false)
        return ok
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard mods.contains(.control), event.characters(byApplyingModifiers: []) == "\t" else {
            return super.performKeyEquivalent(with: event)
        }
        if mods.contains(.shift) {
            TerminalTabManager.shared.selectPreviousTab()
        } else {
            TerminalTabManager.shared.selectNextTab()
        }
        return true
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        pushSize()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        guard let surface, let scale = window?.backingScaleFactor else { return }
        ghostty_surface_set_content_scale(surface, scale, scale)
        pushDisplayID()
    }

    override func resetCursorRects() {
        guard let state = bridge?.state, state.mouseVisible else { return }
        addCursorRect(bounds, cursor: state.mouseCursor)
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

    // Keyboard — see GhosttySurfaceView+IME.swift

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
        super.rightMouseDown(with: event)
    }

    override func rightMouseUp(with event: NSEvent) {
        sendMousePos(event)
        sendMouseButton(event, state: GHOSTTY_MOUSE_RELEASE, button: GHOSTTY_MOUSE_RIGHT)
    }

    override func otherMouseDown(with event: NSEvent) {
        // Ghostty starts a clipboard paste on middle-click, which would land in
        // the host shell between sessions.
        guard forwardsUserInput else { return }
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
            // Discrete scroll wheels report tiny deltas (~1.0); scale to
            // pixel-equivalents that libghostty expects.
            let discreteScrollScale: Double = 10
            x *= discreteScrollScale
            y *= discreteScrollScale
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

    func sendMousePos(_ event: NSEvent) {
        guard let surface else { return }
        let local = convert(event.locationInWindow, from: nil)
        // libghostty uses top-left origin; AppKit gives us bottom-left. Flip Y.
        let flippedY = bounds.height - local.y
        ghostty_surface_mouse_pos(surface, local.x, flippedY, ghosttyMods(event.modifierFlags))
    }

    // MARK: Tracking area

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

    // MARK: Selection helpers (internal — used by +EditMenu, +Services, +Autoscroll)

    func currentSelectionText() -> String? {
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

    func injectPasteText(_ text: String) {
        guard forwardsUserInput, let surface, !text.isEmpty else { return }
        text.withCString { ptr in
            ghostty_surface_text(surface, ptr, UInt(strlen(ptr)))
        }
    }

    func performBindingAction(_ name: String) -> Bool {
        guard let surface else { return false }
        return name.withCString { ptr in
            ghostty_surface_binding_action(surface, ptr, UInt(strlen(ptr)))
        }
    }
}

// Autoscroll per-tick state — kept here so the stored property can reference it.
struct AutoscrollState {
    var timer: Timer
    var lastEvent: NSEvent
}

func ghosttyMods(_ flags: NSEvent.ModifierFlags) -> ghostty_input_mods_e {
    var mods: UInt32 = 0
    if flags.contains(.shift)    { mods |= GHOSTTY_MODS_SHIFT.rawValue }
    if flags.contains(.control)  { mods |= GHOSTTY_MODS_CTRL.rawValue }
    if flags.contains(.option)   { mods |= GHOSTTY_MODS_ALT.rawValue }
    if flags.contains(.command)  { mods |= GHOSTTY_MODS_SUPER.rawValue }
    if flags.contains(.capsLock) { mods |= GHOSTTY_MODS_CAPS.rawValue }
    return ghostty_input_mods_e(mods)
}
