import AppKit
import GhosttyKit
import OSLog
import UserNotifications

private let surfaceBridgeLog = Logger(
    subsystem: "com.montopolis.quay",
    category: "bridge"
)

@MainActor
final class GhosttySurfaceBridge {
    let state: GhosttySurfaceState

    weak var view: GhosttySurfaceView?

    var onTitleChange: ((String) -> Void)?
    var onCloseRequest: (() -> Void)?
    var onChildExited: ((UInt32) -> Void)?
    var onProgressReport: ((Double?) -> Void)?

    init(config: ghostty_config_t? = nil) {
        self.state = GhosttySurfaceState()
        self.state.updateBackground(from: config)
    }

    func handleAction(_ action: ghostty_action_s) -> Bool {
        if updateTerminalIdentity(action) { return true }
        if updatePointerState(action) { return true }
        if updateSessionState(action) { return true }
        if updateVisualState(action) { return true }
        if performHostSideEffect(action) { return true }
        return false
    }

    func sendText(_ text: String) {
        guard let surface = view?.surface, !text.isEmpty else { return }
        let byteCount = text.lengthOfBytes(using: .utf8)
        text.withCString { ptr in
            ghostty_surface_text(surface, ptr, UInt(byteCount))
        }
    }

    func sendReturnKey() {
        sendKey(code: 36, codepoint: 13)
    }

    func visibleText() -> String {
        guard let surface = view?.surface else { return "" }
        let viewport = ghostty_selection_s(
            top_left: ghostty_point_s(tag: GHOSTTY_POINT_VIEWPORT, coord: GHOSTTY_POINT_COORD_TOP_LEFT, x: 0, y: 0),
            bottom_right: ghostty_point_s(tag: GHOSTTY_POINT_VIEWPORT, coord: GHOSTTY_POINT_COORD_BOTTOM_RIGHT, x: 0, y: 0),
            rectangle: true
        )

        var text = ghostty_text_s()
        guard ghostty_surface_read_text(surface, viewport, &text),
              let bytes = text.text,
              text.text_len > 0
        else { return "" }
        defer { ghostty_surface_free_text(surface, &text) }
        return String(data: Data(bytes: bytes, count: Int(text.text_len)), encoding: .utf8) ?? ""
    }

    private func updateTerminalIdentity(_ action: ghostty_action_s) -> Bool {
        switch action.tag {
        case GHOSTTY_ACTION_SET_TITLE, GHOSTTY_ACTION_SET_TAB_TITLE:
            let title = string(action.action.set_title.title) ?? ""
            state.title = title
            onTitleChange?(title)
            return true

        case GHOSTTY_ACTION_PWD:
            if let ptr = action.action.pwd.pwd {
                state.pwd = URL(fileURLWithPath: String(cString: ptr))
            }
            return true

        default:
            return false
        }
    }

    private func updatePointerState(_ action: ghostty_action_s) -> Bool {
        switch action.tag {
        case GHOSTTY_ACTION_MOUSE_SHAPE:
            state.mouseCursor = NSCursor.from(ghosttyShape: action.action.mouse_shape)
            view?.resetCursorRects()
            return true

        case GHOSTTY_ACTION_MOUSE_VISIBILITY:
            let visible = action.action.mouse_visibility == GHOSTTY_MOUSE_VISIBLE
            state.mouseVisible = visible
            if visible { NSCursor.unhide() } else { NSCursor.hide() }
            return true

        default:
            return false
        }
    }

    private func updateSessionState(_ action: ghostty_action_s) -> Bool {
        switch action.tag {
        case GHOSTTY_ACTION_SECURE_INPUT:
            switch action.action.secure_input {
            case GHOSTTY_SECURE_INPUT_ON:     state.secureInputActive = true
            case GHOSTTY_SECURE_INPUT_OFF:    state.secureInputActive = false
            case GHOSTTY_SECURE_INPUT_TOGGLE: state.secureInputActive.toggle()
            default: break
            }
            return true

        case GHOSTTY_ACTION_SHOW_CHILD_EXITED:
            let code = action.action.child_exited.exit_code
            state.childExited = true
            onChildExited?(code)
            return true

        default:
            return false
        }
    }

    private func updateVisualState(_ action: ghostty_action_s) -> Bool {
        switch action.tag {
        case GHOSTTY_ACTION_PROGRESS_REPORT:
            let pr = action.action.progress_report
            switch pr.state {
            case GHOSTTY_PROGRESS_STATE_REMOVE:
                state.progress = nil
            case GHOSTTY_PROGRESS_STATE_SET:
                state.progress = pr.progress >= 0 ? Double(pr.progress) / 100.0 : nil
            default:
                break
            }
            onProgressReport?(state.progress)
            return true

        case GHOSTTY_ACTION_CELL_SIZE:
            let cs = action.action.cell_size
            state.cellSize = CGSize(width: CGFloat(cs.width), height: CGFloat(cs.height))
            return true

        case GHOSTTY_ACTION_COLOR_CHANGE:
            let change = action.action.color_change
            if change.kind == GHOSTTY_ACTION_COLOR_KIND_BACKGROUND {
                state.backgroundColor = GhosttyResolvedAppearance.backgroundColor(from: change)
                view?.applyResolvedBackground()
            }
            return true

        case GHOSTTY_ACTION_CONFIG_CHANGE:
            state.updateBackground(from: action.action.config_change.config)
            view?.applyResolvedBackground()
            return true

        default:
            return false
        }
    }

    private func performHostSideEffect(_ action: ghostty_action_s) -> Bool {
        switch action.tag {
        case GHOSTTY_ACTION_RING_BELL:
            NSSound.beep()
            return true

        case GHOSTTY_ACTION_DESKTOP_NOTIFICATION:
            let n = action.action.desktop_notification
            let title = string(n.title) ?? ""
            let body = string(n.body) ?? ""
            postDesktopNotification(title: title, body: body)
            return true

        default:
            return false
        }
    }

    private func sendKey(code: UInt16, codepoint: UInt32) {
        guard let surface = view?.surface else { return }
        let press = ghostty_input_key_s(
            action: GHOSTTY_ACTION_PRESS,
            mods: GHOSTTY_MODS_NONE,
            consumed_mods: GHOSTTY_MODS_NONE,
            keycode: UInt32(code),
            text: nil,
            unshifted_codepoint: codepoint,
            composing: false
        )
        _ = ghostty_surface_key(surface, press)

        var release = press
        release.action = GHOSTTY_ACTION_RELEASE
        _ = ghostty_surface_key(surface, release)
    }

    private func string(_ pointer: UnsafePointer<CChar>?) -> String? {
        pointer.map(String.init(cString:))
    }

    private func postDesktopNotification(title: String, body: String) {
        guard !title.isEmpty || !body.isEmpty else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                surfaceBridgeLog.debug("notification error: \(error)")
            }
        }
    }
}

// MARK: - NSCursor mapping

extension NSCursor {
    @MainActor
    static func from(ghosttyShape shape: ghostty_action_mouse_shape_e) -> NSCursor {
        switch shape {
        case GHOSTTY_MOUSE_SHAPE_DEFAULT:       return .arrow
        case GHOSTTY_MOUSE_SHAPE_POINTER:       return .pointingHand
        case GHOSTTY_MOUSE_SHAPE_CROSSHAIR,
             GHOSTTY_MOUSE_SHAPE_CELL:          return .crosshair
        case GHOSTTY_MOUSE_SHAPE_TEXT:          return .iBeam
        case GHOSTTY_MOUSE_SHAPE_VERTICAL_TEXT: return .iBeamCursorForVerticalLayout
        case GHOSTTY_MOUSE_SHAPE_ALIAS:         return .dragLink
        case GHOSTTY_MOUSE_SHAPE_COPY:          return .dragCopy
        case GHOSTTY_MOUSE_SHAPE_GRAB,
             GHOSTTY_MOUSE_SHAPE_ALL_SCROLL:    return .openHand
        case GHOSTTY_MOUSE_SHAPE_GRABBING,
             GHOSTTY_MOUSE_SHAPE_MOVE:          return .closedHand
        case GHOSTTY_MOUSE_SHAPE_NOT_ALLOWED,
             GHOSTTY_MOUSE_SHAPE_NO_DROP:       return .operationNotAllowed
        case GHOSTTY_MOUSE_SHAPE_COL_RESIZE,
             GHOSTTY_MOUSE_SHAPE_EW_RESIZE:     return .resizeLeftRight
        case GHOSTTY_MOUSE_SHAPE_ROW_RESIZE,
             GHOSTTY_MOUSE_SHAPE_NS_RESIZE:     return .resizeUpDown
        case GHOSTTY_MOUSE_SHAPE_N_RESIZE:      return .resizeUp
        case GHOSTTY_MOUSE_SHAPE_S_RESIZE:      return .resizeDown
        case GHOSTTY_MOUSE_SHAPE_E_RESIZE:      return .resizeRight
        case GHOSTTY_MOUSE_SHAPE_W_RESIZE:      return .resizeLeft
        default:                                return .arrow
        }
    }
}
