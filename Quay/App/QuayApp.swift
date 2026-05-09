import AppKit
import ComposableArchitecture
import OSLog
import SwiftUI

private let quayAppLogger = Logger(subsystem: "io.github.babul.quay", category: "app")

@main
struct QuayApp: App {
    @NSApplicationDelegateAdaptor(QuayAppDelegate.self) private var appDelegate

    let store = Store(initialState: AppFeature.State()) { AppFeature() }
    @State private var updater = UpdaterViewModel()
    @AppStorage(AppDefaultsKeys.autoHideSidebar) private var autoHideSidebar = true

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
            CommandGroup(replacing: .newItem) {
                TabFileCommands()
            }
            CommandGroup(after: .newItem) {
                Divider()
                Button("Export Settings…") {
                    NotificationCenter.default.post(name: .startExportSettings, object: nil)
                }
                Button("Import Settings…") {
                    NotificationCenter.default.post(name: .startImportSettings, object: nil)
                }
            }
            CommandGroup(replacing: .sidebar) {
                Button("Toggle Hosts Sidebar") {
                    NotificationCenter.default.post(name: .toggleSidebar, object: nil)
                }
                .keyboardShortcut("b", modifiers: [.command])
                Toggle("Auto-hide Hosts Sidebar", isOn: $autoHideSidebar)
                Button("Toggle Snippets Sidebar") {
                    NotificationCenter.default.post(name: .toggleSnippetsSidebar, object: nil)
                }
                .labelStyle(.titleOnly)
                Divider()
            }
            CommandMenu("Find") {
                Button("Search Connections") {
                    NotificationCenter.default.post(name: .focusSearch, object: nil)
                }
                .keyboardShortcut("l", modifiers: [.command])
                Button("Search Snippets") {
                    NotificationCenter.default.post(name: .focusSearchSnippets, object: nil)
                }
                .keyboardShortcut("l", modifiers: [.command, .shift])
            }
            CommandMenu("Terminal") {
                Button("Open Ghostty Config") {
                    NSWorkspace.shared.open(GhosttyRuntime.userConfigURL())
                }
                Button("Reload Ghostty Config") {
                    GhosttyRuntime.shared.reloadConfig()
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
            }
            CommandMenu("Tabs") {
                ForEach(1...9, id: \.self) { number in
                    Button("Tab \(number)") {
                        TerminalTabManager.shared.select(at: number - 1)
                    }
                    .keyboardShortcut(KeyEquivalent(Character("\(number)")), modifiers: [.command])
                }
            }
            CommandGroup(replacing: .help) {
                CheckForUpdatesMenuItem(model: updater)
                Divider()
                Button("Quay on GitHub") {
                    NSWorkspace.shared.open(URL(string: "https://github.com/babul/quay")!)
                }
                Button("Report an Issue") {
                    NSWorkspace.shared.open(URL(string: "https://github.com/babul/quay/issues/new")!)
                }
                Divider()
                Button("Security Policy") {
                    NSWorkspace.shared.open(URL(string: "https://github.com/babul/quay/security/policy")!)
                }
            }
        }

        WindowGroup("Connection", id: "connection-editor", for: ConnectionEditorSpec.self) { $spec in
            if let spec {
                ConnectionEditorWindowContent(spec: spec)
            }
        }
        .modelContainer(PersistenceContainer.shared)
        .defaultSize(width: 680, height: 540)
        .windowResizability(.contentMinSize)

        WindowGroup("Snippet", id: "snippet-editor", for: SnippetEditorSpec.self) { $spec in
            if let spec {
                SnippetEditorWindowContent(spec: spec)
            }
        }
        .modelContainer(PersistenceContainer.shared)
        .defaultSize(width: 640, height: 560)
        .windowResizability(.contentMinSize)

        Settings {
            AppSettingsView(updater: updater.controller.updater)
        }
        .modelContainer(PersistenceContainer.shared)
        .windowResizability(.contentMinSize)
    }
}

private struct TabFileCommands: View {
    @State private var tabManager = TerminalTabManager.shared

    var body: some View {
        Button("New Tab") {
            tabManager.duplicateSelectedTab()
        }
        .keyboardShortcut("t", modifiers: .command)
        .disabled(tabManager.selectedTab == nil)

        Button("Close Tab") {
            tabManager.requestCloseSelectedTab()
        }
        .keyboardShortcut("w", modifiers: .command)
        .disabled(tabManager.selectedTab == nil)
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
private final class QuayAppDelegate: NSObject, NSApplicationDelegate {
    private var centeredWindowIDs = Set<ObjectIdentifier>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSWindow.allowsAutomaticWindowTabbing = false
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowDidBecomeKey(_:)),
            name: NSWindow.didBecomeKeyNotification,
            object: nil
        )
    }

    // Centers each secondary window over the main Quay window the first time it
    // becomes key. Subsequent activations (e.g. user moved the window) are skipped.
    @objc private func windowDidBecomeKey(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        guard window.styleMask.contains(.titled) else { return }
        let id = ObjectIdentifier(window)
        guard !centeredWindowIDs.contains(id) else { return }
        centeredWindowIDs.insert(id)

        // No anchor = this IS the first window (main); leave it where SwiftUI places it.
        // Picking the widest resizable window as anchor intentionally targets the main
        // Quay window, which is always wider than any secondary window.
        let anchor = NSApp.windows
            .filter { $0 !== window && $0.isVisible && !$0.isMiniaturized && $0.styleMask.contains(.resizable) }
            .max(by: { $0.frame.width < $1.frame.width })
        guard let anchor else { return }
        window.setFrameOrigin(NSPoint(
            x: anchor.frame.midX - window.frame.width / 2,
            y: anchor.frame.midY - window.frame.height / 2
        ))
    }

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
            window.titlebarAppearsTransparent = false
            window.styleMask.insert(.fullSizeContentView)
            window.tabbingMode = .disallowed
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
