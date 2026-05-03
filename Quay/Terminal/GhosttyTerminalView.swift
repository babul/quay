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
        // v0.1: terminal config is fixed at creation time. Live config
        // updates (font size, theme) land later via ghostty_surface_update_config.
    }
}
