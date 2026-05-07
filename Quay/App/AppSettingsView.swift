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
    @Environment(\.dismiss) private var dismiss
    @State private var selectedPage: SettingsPage = .appearance
    @State private var exportRequested = false
    @State private var importRequested = false

    init(updater: SPUUpdater) {
        self.updater = updater
        _automaticallyChecksForUpdates = State(initialValue: updater.automaticallyChecksForUpdates)
        _automaticallyDownloadsUpdates = State(initialValue: updater.automaticallyDownloadsUpdates)
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebarColumn
            Divider()
            detailColumn
        }
        .frame(minWidth: 480, idealWidth: 560, maxWidth: .infinity,
               minHeight: 380, idealHeight: 460, maxHeight: .infinity)
        .onExitCommand { dismiss() }
        .settingsImportExportFlow(
            triggerExport: $exportRequested,
            triggerImport: $importRequested
        )
    }

    // MARK: - Layout

    private var sidebarColumn: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(SettingsPage.allCases) { page in
                Button { selectedPage = page } label: {
                    Label(page.label, systemImage: page.symbol)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(selectedPage == page
                              ? Color.accentColor.opacity(0.15)
                              : Color.clear)
                )
                .foregroundStyle(selectedPage == page ? Color.accentColor : Color.primary)
            }
            Spacer()
        }
        .padding(8)
        .frame(width: 160)
        .background(.bar)
    }

    private var detailColumn: some View {
        Group {
            switch selectedPage {
            case .appearance: appearancePage
            case .tabs:       tabsPage
            case .sftp:       sftpPage
            case .updates:    updatesPage
            case .data:       dataPage
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Pages

    private var appearancePage: some View {
        Form {
            Section("Appearance") {
                Toggle("Show host color bars in tabs", isOn: $showTabColorBars)
            }
        }
        .formStyle(.grouped)
    }

    private var tabsPage: some View {
        Form {
            Section("Tabs") {
                Toggle("Confirm before closing active tabs", isOn: $confirmCloseActiveSessions)
            }
        }
        .formStyle(.grouped)
    }

    private var sftpPage: some View {
        Form {
            Section("SFTP") {
                Picker("Client", selection: $sftpClientRaw) {
                    ForEach(SFTPClient.allCases) { client in
                        Text(client.label).tag(client.rawValue)
                    }
                }
                Text(selectedSFTPClient.helpText)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack {
                    TextField(
                        "Default local folder",
                        text: $sftpDefaultLocalDirectory,
                        prompt: Text("~/Downloads")
                    )
                    Button("Choose…") { pickDefaultLocalDirectory() }
                }
                Text("Used when a connection doesn't specify a local directory.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var updatesPage: some View {
        Form {
            Section("Updates") {
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
        .formStyle(.grouped)
    }

    private var dataPage: some View {
        Form {
            Section("Data") {
                Button("Export Settings…") { exportRequested = true }
                Button("Import Settings…") { importRequested = true }
            }
        }
        .formStyle(.grouped)
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

private enum SettingsPage: String, CaseIterable, Identifiable {
    case appearance, tabs, sftp, updates, data

    var id: String { rawValue }

    var label: String {
        switch self {
        case .appearance: "Appearance"
        case .tabs:       "Tabs"
        case .sftp:       "SFTP"
        case .updates:    "Updates"
        case .data:       "Data"
        }
    }

    var symbol: String {
        switch self {
        case .appearance: "paintpalette"
        case .tabs:       "rectangle.3.group"
        case .sftp:       "externaldrive"
        case .updates:    "arrow.triangle.2.circlepath"
        case .data:       "archivebox"
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
