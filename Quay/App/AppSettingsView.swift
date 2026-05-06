import SwiftUI

struct AppSettingsView: View {
    @AppStorage("appearance.showTabColorBars") private var showTabColorBars = true
    @AppStorage("tabs.confirmCloseActiveSessions") private var confirmCloseActiveSessions = true
    @AppStorage(SFTPClient.defaultsKey) private var sftpClientRaw = SFTPClient.macOSOpenSSH.rawValue

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
            }
        }
        .formStyle(.grouped)
        .padding(20)
        .frame(width: 520, height: 320)
    }

    private var selectedSFTPClient: SFTPClient {
        SFTPClient(rawValue: sftpClientRaw) ?? .macOSOpenSSH
    }
}
