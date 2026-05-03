import SwiftData
import SwiftUI

/// Modal sheet for creating or editing a `ConnectionProfile`.
///
/// Auth picker swaps the visible secondary fields. v0.1 doesn't ship the
/// "Pick from Keychain" sheet — users paste the URI directly, which keeps
/// the editor scope tight while we validate the rest of the flow.
struct ConnectionEditor: View {
    @Environment(\.modelContext) private var ctx
    @Environment(\.dismiss) private var dismiss

    let target: SidebarView.EditorTarget
    let onClose: () -> Void

    @State private var name: String = ""
    @State private var hostname: String = ""
    @State private var port: String = ""
    @State private var username: String = ""
    @State private var authMethod: ConnectionProfile.AuthMethod = .sshAgent
    @State private var secretRef: String = ""
    @State private var privateKeyPath: String = ""
    @State private var sshConfigAlias: String = ""
    @State private var notes: String = ""
    @State private var didLoad = false

    var body: some View {
        Form {
            Section("Identity") {
                TextField("Display name", text: $name)
                TextField("Hostname", text: $hostname)
                    .disabled(authMethod == .sshConfigAlias)
                HStack {
                    TextField("Port", text: $port)
                        .frame(width: 80)
                    TextField("Username", text: $username)
                }
            }

            Section("Authentication") {
                Picker("Method", selection: $authMethod) {
                    Text("ssh-agent").tag(ConnectionProfile.AuthMethod.sshAgent)
                    Text("Private key").tag(ConnectionProfile.AuthMethod.privateKey)
                    Text("Private key + passphrase").tag(ConnectionProfile.AuthMethod.privateKeyWithPassphrase)
                    Text("Password").tag(ConnectionProfile.AuthMethod.password)
                    Text("ssh.config alias").tag(ConnectionProfile.AuthMethod.sshConfigAlias)
                }

                switch authMethod {
                case .sshAgent:
                    Text("Uses keys loaded into ssh-agent.")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                case .privateKey:
                    keyPathField
                case .privateKeyWithPassphrase:
                    keyPathField
                    secretRefField(label: "Passphrase reference",
                                   placeholder: "keychain://service/account")
                case .password:
                    secretRefField(label: "Password reference",
                                   placeholder: "keychain://service/account")
                case .sshConfigAlias:
                    TextField("Host alias from ~/.ssh/config", text: $sshConfigAlias)
                }
            }

            Section("Notes") {
                TextEditor(text: $notes)
                    .frame(minHeight: 60)
            }
        }
        .formStyle(.grouped)
        .padding(.bottom, 12)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { close() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { save() }
                    .disabled(!canSave)
            }
        }
        .onAppear { loadIfNeeded() }
    }

    private var keyPathField: some View {
        HStack {
            TextField("Path to private key", text: $privateKeyPath)
            Button("Choose…") { pickKeyFile() }
        }
    }

    private func secretRefField(label: String, placeholder: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            TextField(label, text: $secretRef, prompt: Text(placeholder))
            Text("URI to the secret in your vault. v0.1 supports keychain://")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var canSave: Bool {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        switch authMethod {
        case .sshConfigAlias:
            return !sshConfigAlias.trimmingCharacters(in: .whitespaces).isEmpty
        default:
            return !hostname.trimmingCharacters(in: .whitespaces).isEmpty
        }
    }

    private func loadIfNeeded() {
        guard !didLoad else { return }
        didLoad = true
        if case .edit(let p) = target {
            name = p.name
            hostname = p.hostname
            port = p.port.map(String.init) ?? ""
            username = p.username ?? ""
            authMethod = p.authMethod ?? .sshAgent
            secretRef = p.secretRef ?? ""
            privateKeyPath = p.privateKeyPath ?? ""
            sshConfigAlias = p.sshConfigAlias ?? ""
            notes = p.notes ?? ""
        }
    }

    private func save() {
        let portInt = Int(port.trimmingCharacters(in: .whitespaces))
        let user = username.isEmpty ? nil : username
        let secret = secretRef.isEmpty ? nil : secretRef
        let keyPath = privateKeyPath.isEmpty ? nil : privateKeyPath
        let alias = sshConfigAlias.isEmpty ? nil : sshConfigAlias

        switch target {
        case .create:
            let profile = ConnectionProfile(
                name: name.trimmingCharacters(in: .whitespaces),
                hostname: hostname.trimmingCharacters(in: .whitespaces),
                port: portInt,
                username: user,
                authMethod: authMethod,
                secretRef: secret,
                privateKeyPath: keyPath,
                sshConfigAlias: alias,
                notes: notes.isEmpty ? nil : notes
            )
            ctx.insert(profile)

        case .edit(let p):
            p.name = name.trimmingCharacters(in: .whitespaces)
            p.hostname = hostname.trimmingCharacters(in: .whitespaces)
            p.port = portInt
            p.username = user
            p.authMethodRaw = authMethod.rawValue
            p.secretRef = secret
            p.privateKeyPath = keyPath
            p.sshConfigAlias = alias
            p.notes = notes.isEmpty ? nil : notes
        }

        try? ctx.save()
        close()
    }

    private func close() {
        onClose()
        dismiss()
    }

    private func pickKeyFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = FileManager.default
            .homeDirectoryForCurrentUser
            .appending(path: ".ssh")
        if panel.runModal() == .OK, let url = panel.url {
            privateKeyPath = url.path
        }
    }
}
