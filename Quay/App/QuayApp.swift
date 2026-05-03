import GhosttyKit
import SwiftUI

@main
struct QuayApp: App {
    init() {
        // ghostty_init must be called once before any other libghostty entry
        // points. We pass the real argc/argv so libghostty can detect CLI
        // actions, although Quay doesn't use them — Ghostty's own +cli
        // dispatch is harmless when no `+action` is present.
        let rc = ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv)
        precondition(rc == GHOSTTY_SUCCESS, "ghostty_init failed (\(rc))")
    }

    var body: some Scene {
        WindowGroup("Quay") {
            ContentView()
                .frame(minWidth: 900, minHeight: 600)
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified(showsTitle: true))
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}
