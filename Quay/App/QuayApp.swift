import SwiftUI

@main
struct QuayApp: App {
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
