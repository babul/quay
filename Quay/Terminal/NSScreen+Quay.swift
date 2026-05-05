import AppKit

extension NSScreen {
    /// CoreGraphics display ID for this screen (needed by `ghostty_surface_set_display_id`).
    var displayID: UInt32? {
        deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32
    }
}
