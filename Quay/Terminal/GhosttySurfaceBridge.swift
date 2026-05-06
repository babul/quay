import AppKit
import GhosttyKit
import OSLog
import UserNotifications

private let ghosttySurfaceBridgeLogger = Logger(
    subsystem: "com.montopolis.quay",
    category: "bridge"
)

/// Per-surface action dispatcher and state coordinator.
///
/// Owns zero C memory. The runtime's `action_cb`, `read_clipboard_cb`, and
/// `close_surface_cb` resolve a bridge from `ghostty_surface_userdata` and
/// call into it. High-frequency surface state (title, cursor, progress) is
/// written to `GhosttySurfaceState` — SwiftUI observes that directly without
/// any reducer round-trip.
///
/// Cross-feature events (child exited, close request) are exposed as optional
/// closures set by the owning tab item.
@MainActor
final class GhosttySurfaceBridge {
    /// Observable state read by SwiftUI overlays and the tab bar.
    let state: GhosttySurfaceState

    /// Weak back-reference to the view (for cursor updates and display-id).
    weak var view: GhosttySurfaceView?

    // MARK: Cross-feature closures (set by the owning tab item)

    var onTitleChange: ((String) -> Void)?
    var onCloseRequest: (() -> Void)?
    var onChildExited: ((UInt32) -> Void)?
    var onProgressReport: ((Double?) -> Void)?

    init() {
        self.state = GhosttySurfaceState()
    }

    // MARK: Action dispatch

    /// Dispatch a `ghostty_action_s` arriving from the C callback. Called on
    /// @MainActor. Returns `true` if the action was handled, `false` to let
    /// libghostty fall back to its own default (e.g. forwarding to app level).
    func handleAction(_ action: ghostty_action_s) -> Bool {
        switch action.tag {
        case GHOSTTY_ACTION_SET_TITLE, GHOSTTY_ACTION_SET_TAB_TITLE:
            let title = action.action.set_title.title.map { String(cString: $0) } ?? ""
            state.title = title
            onTitleChange?(title)
            return true

        case GHOSTTY_ACTION_PWD:
            if let ptr = action.action.pwd.pwd {
                state.pwd = URL(fileURLWithPath: String(cString: ptr))
            }
            return true

        case GHOSTTY_ACTION_MOUSE_SHAPE:
            state.mouseCursor = NSCursor.from(ghosttyShape: action.action.mouse_shape)
            view?.resetCursorRects()
            return true

        case GHOSTTY_ACTION_MOUSE_VISIBILITY:
            let visible = action.action.mouse_visibility == GHOSTTY_MOUSE_VISIBLE
            state.mouseVisible = visible
            if visible { NSCursor.unhide() } else { NSCursor.hide() }
            return true

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

        case GHOSTTY_ACTION_RING_BELL:
            NSSound.beep()
            return true

        case GHOSTTY_ACTION_DESKTOP_NOTIFICATION:
            let n = action.action.desktop_notification
            let title = n.title.map { String(cString: $0) } ?? ""
            let body = n.body.map { String(cString: $0) } ?? ""
            postDesktopNotification(title: title, body: body)
            return true

        default:
            return false
        }
    }

    // MARK: Inject text

    /// Send `text` as if pasted. Called by the owning tab item for reconnect
    /// pre-fill or scripted initial input after the surface is live.
    func sendText(_ text: String) {
        guard let surface = view?.surface, !text.isEmpty else { return }
        text.withCString { ptr in
            ghostty_surface_text(surface, ptr, UInt(strlen(ptr)))
        }
    }

    func sendReturnKey() {
        guard let surface = view?.surface else { return }
        var press = ghostty_input_key_s()
        press.action = GHOSTTY_ACTION_PRESS
        press.keycode = 36
        press.text = nil
        press.composing = false
        press.mods = GHOSTTY_MODS_NONE
        press.consumed_mods = GHOSTTY_MODS_NONE
        press.unshifted_codepoint = 13
        _ = ghostty_surface_key(surface, press)

        var release = press
        release.action = GHOSTTY_ACTION_RELEASE
        _ = ghostty_surface_key(surface, release)
    }

    /// Read the currently visible viewport text. Login scripts use this to
    /// match prompts without intercepting raw PTY output.
    func visibleText() -> String {
        guard let surface = view?.surface else { return "" }
        let selection = ghostty_selection_s(
            top_left: ghostty_point_s(
                tag: GHOSTTY_POINT_VIEWPORT,
                coord: GHOSTTY_POINT_COORD_TOP_LEFT,
                x: 0,
                y: 0
            ),
            bottom_right: ghostty_point_s(
                tag: GHOSTTY_POINT_VIEWPORT,
                coord: GHOSTTY_POINT_COORD_BOTTOM_RIGHT,
                x: 0,
                y: 0
            ),
            rectangle: true
        )
        var text = ghostty_text_s()
        guard ghostty_surface_read_text(surface, selection, &text),
              let ptr = text.text,
              text.text_len > 0 else {
            return ""
        }
        defer { ghostty_surface_free_text(surface, &text) }
        let data = Data(bytes: ptr, count: Int(text.text_len))
        return String(data: data, encoding: .utf8) ?? ""
    }

    // MARK: Private

    private func postDesktopNotification(title: String, body: String) {
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
                ghosttySurfaceBridgeLogger.debug("notification error: \(error)")
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
