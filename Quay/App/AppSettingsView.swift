import SwiftUI

enum AppDefaultsKeys {
    static let showTabColorBars = "appearance.showTabColorBars"
    static let confirmCloseActiveSessions = "tabs.confirmCloseActiveSessions"
    static let sftpDefaultLocalDirectory = "sftp.defaultLocalDirectory"
}

struct AppSettingsView: View {
    @AppStorage(AppDefaultsKeys.showTabColorBars) private var showTabColorBars = true
    @AppStorage(AppDefaultsKeys.confirmCloseActiveSessions) private var confirmCloseActiveSessions = true
    @AppStorage(SFTPClient.defaultsKey) private var sftpClientRaw = SFTPClient.macOSOpenSSH.rawValue
    @AppStorage(AppDefaultsKeys.sftpDefaultLocalDirectory) private var sftpDefaultLocalDirectory = ""

    @State private var exportRequested = false
    @State private var importRequested = false

    var body: some View {
        Form {
            Section("Appearance") {
                Toggle("Show host color bars in tabs", isOn: $showTabColorBars)

                HStack(spacing: 8) {
                    ForEach(ConnectionColor.tags) { tag in
                        VStack(spacing: 4) {
                            Circle()
                                .fill(tag.color)
                                .frame(width: 16, height: 16)
                            Text(tag.label)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .frame(width: 48)
                    }
                }
                .padding(.top, 2)
            }

            Section("Tabs") {
                Toggle("Confirm before closing active tabs", isOn: $confirmCloseActiveSessions)
            }

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

            Section("Data") {
                Button("Export Settings…") { exportRequested = true }
                Button("Import Settings…") { importRequested = true }
            }
        }
        .formStyle(.grouped)
        .padding(20)
        .frame(width: 520, height: 500)
        .settingsImportExportFlow(
            triggerExport: $exportRequested,
            triggerImport: $importRequested
        )
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
