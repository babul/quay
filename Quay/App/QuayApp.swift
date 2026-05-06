import AppKit
import ComposableArchitecture
import OSLog
import SwiftUI

private let quayAppLogger = Logger(subsystem: "com.montopolis.quay", category: "app")

@main
struct QuayApp: App {
    @NSApplicationDelegateAdaptor(AppTerminationDelegate.self) private var appDelegate

    let store = Store(initialState: AppFeature.State()) { AppFeature() }

    var body: some Scene {
        WindowGroup("Quay") {
            ContentView(store: store)
                .frame(minWidth: 900, minHeight: 600)
                .modifier(GhosttyColorSchemeSyncModifier())
                .background(WindowConfigurator())
        }
        .windowStyle(.hiddenTitleBar)
        .modelContainer(PersistenceContainer.shared)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .newItem) {
                Divider()
                Button("Export Settings…") {
                    NotificationCenter.default.post(name: .startExportSettings, object: nil)
                }
                Button("Import Settings…") {
                    NotificationCenter.default.post(name: .startImportSettings, object: nil)
                }
            }
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
        .modelContainer(PersistenceContainer.shared)
    }
}

private struct GhosttyColorSchemeSyncModifier: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        content
            .task {
                GhosttyRuntime.shared.setColorScheme(colorScheme)
            }
            .onChange(of: colorScheme) { _, newValue in
                GhosttyRuntime.shared.setColorScheme(newValue)
            }
    }
}

@MainActor
private final class AppTerminationDelegate: NSObject, NSApplicationDelegate {
    private static let confirmCloseActiveSessionsKey = "tabs.confirmCloseActiveSessions"

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let tabs = TerminalTabManager.shared.tabsRequiringCloseConfirmation(
            confirmActiveSessions: confirmCloseActiveSessions
        )
        switch TerminalTabManager.appQuitConfirmation(activeTabCount: tabs.count) {
        case .none:
            return .terminateNow
        case .single:
            guard let tab = tabs.first else { return .terminateNow }
            TerminalTabManager.shared.select(tab)
            guard confirmQuitClosingTab(tab) else {
                return .terminateCancel
            }
            return .terminateNow
        case .multiple(let count):
            guard confirmQuitClosingAllTabs(activeTabCount: count) else {
                return .terminateCancel
            }
            return .terminateNow
        }
    }

    private var confirmCloseActiveSessions: Bool {
        guard let storedValue = UserDefaults.standard.object(
            forKey: Self.confirmCloseActiveSessionsKey
        ) as? Bool else {
            return true
        }
        return storedValue
    }

    private func confirmQuitClosingTab(_ tab: TerminalTabItem) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Close Active Tab?"
        alert.informativeText = """
        "\(tab.displayTitle)" is still active. Closing Quay will disconnect this session.
        """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Close Tab and Quit")
        configureEscapeCancelButton(alert.addButton(withTitle: "Cancel Quit"))

        return alert.runModal() == .alertFirstButtonReturn
    }

    private func confirmQuitClosingAllTabs(activeTabCount: Int) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Close Active Connections?"
        alert.informativeText = """
        Quay has \(activeTabCount) active connections. Quitting will disconnect all of them.
        """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Quit All")
        configureEscapeCancelButton(alert.addButton(withTitle: "Cancel Quit"))

        return alert.runModal() == .alertFirstButtonReturn
    }

    private func configureEscapeCancelButton(_ button: NSButton) {
        button.keyEquivalent = "\u{1b}"
        button.keyEquivalentModifierMask = []
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
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.styleMask.insert(.fullSizeContentView)
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
