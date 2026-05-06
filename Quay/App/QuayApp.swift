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
            guard NSAlert.confirmation(
                title: "Close Active Tab?",
                message: "\"\(tab.displayTitle)\" is still active. Closing Quay will disconnect this session.",
                confirmTitle: "Close Tab and Quit",
                cancelTitle: "Cancel Quit"
            ) else {
                return .terminateCancel
            }
            return .terminateNow
        case .multiple(let count):
            guard NSAlert.confirmation(
                title: "Close Active Connections?",
                message: "Quay has \(count) active connections. Quitting will disconnect all of them.",
                confirmTitle: "Quit All",
                cancelTitle: "Cancel Quit"
            ) else {
                return .terminateCancel
            }
            return .terminateNow
        }
    }

    private var confirmCloseActiveSessions: Bool {
        UserDefaults.standard.object(forKey: AppDefaultsKeys.confirmCloseActiveSessions) as? Bool ?? true
    }
}

extension NSAlert {
    @discardableResult
    static func confirmation(
        title: String,
        message: String,
        confirmTitle: String,
        cancelTitle: String = "Cancel"
    ) -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: confirmTitle)
        let cancel = alert.addButton(withTitle: cancelTitle)
        cancel.keyEquivalent = "\u{1b}"
        cancel.keyEquivalentModifierMask = []
        return alert.runModal() == .alertFirstButtonReturn
    }
}

/// Runs `action` twice — once after a layout yield and once 150 ms later —
/// to work around SwiftUI overwriting restored state during initial placement.
@MainActor
func scheduleAfterSwiftUILayout(
    action: @escaping @MainActor () -> Void,
    completion: (@MainActor () -> Void)? = nil
) {
    Task { @MainActor in
        await Task.yield()
        action()
        try? await Task.sleep(for: .milliseconds(150))
        action()
        completion?()
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
            scheduleAfterSwiftUILayout(action: { [weak self] in self?.restoreSavedFrame() }) { [weak self] in
                self?.isRestoringFrame = false
                self?.saveFrame()
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
