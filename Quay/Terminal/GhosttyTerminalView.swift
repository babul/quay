import AppKit
import SwiftUI

/// SwiftUI wrapper around `GhosttySurfaceView`.
///
/// Pass a `GhosttySurfaceConfig` describing the command + env to launch.
/// libghostty owns the resulting PTY and rendering for the lifetime of the view.
struct GhosttyTerminalView: NSViewRepresentable {
    let config: GhosttySurfaceConfig

    func makeNSView(context: Context) -> GhosttySurfaceView {
        GhosttySurfaceView(runtime: GhosttyRuntime.shared, config: config)
    }

    func updateNSView(_ nsView: GhosttySurfaceView, context: Context) {
        // Config changes are broadcast via GhosttyRuntime.reloadConfig(), which
        // calls ghostty_surface_update_config on every registered surface. No
        // per-update work needed here.
    }
}
