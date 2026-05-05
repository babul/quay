import AppKit
import ComposableArchitecture
import GhosttyKit
import SwiftUI

@main
struct QuayApp: App {
    let store = Store(initialState: AppFeature.State()) { AppFeature() }

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
            ContentView(store: store)
                .frame(minWidth: 900, minHeight: 600)
                .background(WindowConfigurator())
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified(showsTitle: true))
        .modelContainer(PersistenceContainer.shared)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("View") {
                Button("Toggle Sidebar") {
                    NotificationCenter.default.post(name: .toggleSidebar, object: nil)
                }
                .keyboardShortcut("b", modifiers: [.command])
            }
            CommandMenu("Find") {
                Button("Search Connections") {
                    NotificationCenter.default.post(name: .focusSearch, object: nil)
                }
                .keyboardShortcut("l", modifiers: [.command])
            }
        }

        Settings {
            AppSettingsView()
        }
    }
}

private struct WindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        ConfiguringView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? ConfiguringView)?.configureWindow()
    }

    private final class ConfiguringView: NSView {
        private static let savedFrameKey = "Quay.MainWindow.SavedFrame"
        private var didConfigureWindow = false
        private var isRestoringFrame = false

        deinit {
            NotificationCenter.default.removeObserver(self)
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            configureWindow()
        }

        func configureWindow() {
            guard !didConfigureWindow, let window else { return }
            didConfigureWindow = true
            window.setFrameAutosaveName("Quay.MainWindow.Frame")

            let center = NotificationCenter.default
            center.addObserver(
                self,
                selector: #selector(windowFrameDidChange),
                name: NSWindow.didMoveNotification,
                object: window
            )
            center.addObserver(
                self,
                selector: #selector(windowFrameDidChange),
                name: NSWindow.didResizeNotification,
                object: window
            )
            center.addObserver(
                self,
                selector: #selector(windowFrameDidChange),
                name: NSWindow.willCloseNotification,
                object: window
            )

            restoreSavedFrameAfterSwiftUIPlacement()
        }

        @objc private func windowFrameDidChange() {
            saveFrame()
        }

        private func restoreSavedFrameAfterSwiftUIPlacement() {
            guard UserDefaults.standard.string(forKey: Self.savedFrameKey) != nil else { return }
            isRestoringFrame = true
            restoreSavedFrame()

            Task { @MainActor in
                await Task.yield()
                restoreSavedFrame()

                try? await Task.sleep(for: .milliseconds(150))
                restoreSavedFrame()

                isRestoringFrame = false
                saveFrame()
            }
        }

        private func restoreSavedFrame() {
            guard let window,
                  let frame = UserDefaults.standard.string(forKey: Self.savedFrameKey)
            else { return }
            window.setFrame(from: frame)
        }

        private func saveFrame() {
            guard !isRestoringFrame, let window else { return }
            UserDefaults.standard.set(window.frameDescriptor, forKey: Self.savedFrameKey)
        }
    }
}
