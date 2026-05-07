import Sparkle
import SwiftUI

enum AppDefaultsKeys {
    static let showTabColorBars = "appearance.showTabColorBars"
    static let confirmCloseActiveSessions = "tabs.confirmCloseActiveSessions"
    static let sftpDefaultLocalDirectory = "sftp.defaultLocalDirectory"
}

struct AppSettingsView: View {
    let updater: SPUUpdater

    @AppStorage(AppDefaultsKeys.showTabColorBars) private var showTabColorBars = true
    @AppStorage(AppDefaultsKeys.confirmCloseActiveSessions) private var confirmCloseActiveSessions = true
    @AppStorage(SFTPClient.defaultsKey) private var sftpClientRaw = SFTPClient.macOSOpenSSH.rawValue
    @AppStorage(AppDefaultsKeys.sftpDefaultLocalDirectory) private var sftpDefaultLocalDirectory = ""

    @State private var automaticallyChecksForUpdates: Bool
    @State private var automaticallyDownloadsUpdates: Bool
    @State private var exportRequested = false
    @State private var importRequested = false
    @Environment(\.dismiss) private var dismiss

    init(updater: SPUUpdater) {
        self.updater = updater
        _automaticallyChecksForUpdates = State(initialValue: updater.automaticallyChecksForUpdates)
        _automaticallyDownloadsUpdates = State(initialValue: updater.automaticallyDownloadsUpdates)
    }

    var body: some View {
        TabView {
            Tab("Appearance", systemImage: "paintpalette")              { appearancePage }
            Tab("Tabs",       systemImage: "rectangle.3.group")         { tabsPage }
            Tab("SFTP",       systemImage: "externaldrive")             { sftpPage }
            Tab("Updates",    systemImage: "arrow.triangle.2.circlepath") { updatesPage }
            Tab("Data",       systemImage: "archivebox")                { dataPage }
        }
        .frame(minWidth: 480, idealWidth: 560, maxWidth: .infinity,
               minHeight: 380, idealHeight: 460, maxHeight: .infinity)
        // TabView consumes cancelOperation(_:) for sidebar toggle, so onExitCommand
        // never fires. A zero-opacity Button with the shortcut goes through the
        // command dispatch layer before the responder chain and reliably catches Escape.
        .background(
            Button("") { dismiss() }
                .keyboardShortcut(.escape, modifiers: [])
                .opacity(0)
                .accessibilityHidden(true)
        )
        .settingsImportExportFlow(
            triggerExport: $exportRequested,
            triggerImport: $importRequested
        )
    }

    // MARK: - Pages

    private var appearancePage: some View {
        settingsForm("Appearance") {
            Toggle("Show host color bars in tabs", isOn: $showTabColorBars)
        }
    }

    private var tabsPage: some View {
        settingsForm("Tabs") {
            Toggle("Confirm before closing active tabs", isOn: $confirmCloseActiveSessions)
        }
    }

    private var sftpPage: some View {
        settingsForm("SFTP") {
            Picker("Client", selection: $sftpClientRaw) {
                ForEach(SFTPClient.allCases) { client in
                    Text(client.label).tag(client.rawValue)
                }
            }
            captionText(selectedSFTPClient.helpText)

            HStack {
                TextField(
                    "Default local folder",
                    text: $sftpDefaultLocalDirectory,
                    prompt: Text("~/Downloads")
                )
                Button("Choose…") { pickDefaultLocalDirectory() }
            }
            captionText("Used when a connection doesn't specify a local directory.")
        }
    }

    private var updatesPage: some View {
        settingsForm("Updates") {
            UpdateToggle(
                label: "Automatically check for updates",
                binding: $automaticallyChecksForUpdates,
                setter: { updater.automaticallyChecksForUpdates = $0 }
            )
            UpdateToggle(
                label: "Automatically download updates",
                binding: $automaticallyDownloadsUpdates,
                setter: { updater.automaticallyDownloadsUpdates = $0 },
                isDisabled: !automaticallyChecksForUpdates
            )
        }
    }

    private var dataPage: some View {
        settingsForm("Data") {
            Button("Export Settings…") { exportRequested = true }
            Button("Import Settings…") { importRequested = true }
        }
    }

    // MARK: - Helpers

    @ViewBuilder
    private func settingsForm<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        Form {
            Section(title) { content() }
        }
        .formStyle(.grouped)
    }

    private func captionText(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    private var selectedSFTPClient: SFTPClient {
        SFTPClient(rawValue: sftpClientRaw) ?? .macOSOpenSSH
    }

    private func pickDefaultLocalDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
        if panel.runModal() == .OK, let url = panel.url {
            sftpDefaultLocalDirectory = url.path
        }
    }
}

private struct UpdateToggle: View {
    let label: String
    @Binding var binding: Bool
    let setter: (Bool) -> Void
    var isDisabled = false

    var body: some View {
        Toggle(label, isOn: $binding)
            .disabled(isDisabled)
            .onChange(of: binding) { _, newValue in
                setter(newValue)
            }
    }
}
