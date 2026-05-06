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

    @Query(sort: [SortDescriptor(\Folder.sortIndex), SortDescriptor(\Folder.name)])
    private var folders: [Folder]

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
    @State private var remoteTerminalType: RemoteTerminalType = .defaultValue
    @State private var colorTag: String?
    @State private var iconName: String?
    @State private var notes: String = ""
    @State private var loginScriptSteps: [LoginScriptStep] = []
    @State private var selectedFolderID: UUID?
    @State private var didLoad = false

    var body: some View {
        Form {
            Section("Identity") {
                FormTextField(title: "Display name", text: $name)
                groupPicker
                FormTextField(
                    title: "Hostname",
                    text: $hostname,
                    isDisabled: authMethod == .sshConfigAlias
                )
                HStack {
                    FormTextField(title: "Port", text: $port, width: 90, labelWidth: 48)
                    FormTextField(title: "Username", text: $username, labelWidth: 78)
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
                    FormTextField(
                        title: "Host alias",
                        text: $sshConfigAlias,
                        prompt: "Host alias from ~/.ssh/config"
                    )
                }
            }

            Section("Terminal") {
                Picker("Remote TERM", selection: $remoteTerminalType) {
                    ForEach(RemoteTerminalType.allCases) { type in
                        Text(type.label).tag(type)
                    }
                }
                Text(remoteTerminalType.helpText)
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }

            Section("Login Scripts") {
                if loginScriptSteps.isEmpty {
                    Text("No login scripts.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach($loginScriptSteps) { $step in
                        LoginScriptStepRow(
                            step: $step,
                            onDelete: { removeLoginScriptStep(id: step.id) }
                        )
                    }
                    .onMove(perform: moveLoginScriptSteps)
                }

                Button {
                    addLoginScriptStep()
                } label: {
                    Label("Add script step", systemImage: "plus")
                }
            }

            Section("Appearance") {
                AppearanceIconPicker(
                    title: "Icon",
                    defaultSystemName: ConnectionIcon.fallback,
                    defaultHelp: "Default",
                    accessibilityLabel: "Connection icon",
                    selection: $iconName
                )
                colorPicker
            }

            Section("Notes") {
                FormTextEditor(title: "Notes", text: $notes, minHeight: 72)
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

    private var topLevelFolders: [Folder] {
        folders.filter { $0.parent == nil }
    }

    private var selectedFolder: Folder? {
        if let selectedFolderID,
           let folder = topLevelFolders.first(where: { $0.id == selectedFolderID }) {
            return folder
        }
        return topLevelFolders.first(where: { $0.name == FolderStore.defaultFolderName })
            ?? topLevelFolders.first
    }

    private var groupPicker: some View {
        Picker("Group", selection: $selectedFolderID) {
            ForEach(topLevelFolders, id: \.id) { folder in
                Text(folder.name).tag(Optional(folder.id))
            }
        }
        .onAppear { ensureDefaultFolderSelection() }
    }

    private var keyPathField: some View {
        HStack {
            FormTextField(
                title: "Private key path",
                text: $privateKeyPath,
                prompt: "Path to private key"
            )
            Button("Choose…") { pickKeyFile() }
        }
    }

    private func secretRefField(label: String, placeholder: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            FormTextField(title: label, text: $secretRef, prompt: placeholder)
            Text("URI to the secret in your vault. v0.1 supports keychain://")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var colorPicker: some View {
        LabeledContent("Color") {
            HStack(spacing: 8) {
                Button {
                    colorTag = nil
                } label: {
                    Image(systemName: colorTag == nil ? "circle.inset.filled" : "circle")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Default")

                ForEach(ConnectionColor.tags) { tag in
                    Button {
                        colorTag = tag.id
                    } label: {
                        ZStack {
                            Circle()
                                .fill(tag.color)
                                .frame(width: 16, height: 16)
                            if colorTag == tag.id {
                                Circle()
                                    .strokeBorder(.primary, lineWidth: 2)
                                    .frame(width: 22, height: 22)
                            }
                        }
                        .frame(width: 24, height: 24)
                    }
                    .buttonStyle(.plain)
                    .help(tag.label)
                }
            }
            .accessibilityLabel("Connection color")
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
            remoteTerminalType = p.remoteTerminalType
            colorTag = ConnectionColor.isKnown(p.colorTag) ? p.colorTag : nil
            iconName = p.iconName
            notes = p.notes ?? ""
            loginScriptSteps = p.loginScriptSteps
            selectedFolderID = p.parent?.id
            ensureDefaultFolderSelection()
        } else {
            ensureDefaultFolderSelection()
        }
    }

    private func save() {
        let portInt = Int(port.trimmingCharacters(in: .whitespaces))
        let user = username.isEmpty ? nil : username
        let secret = secretRef.isEmpty ? nil : secretRef
        let keyPath = privateKeyPath.isEmpty ? nil : privateKeyPath
        let alias = sshConfigAlias.isEmpty ? nil : sshConfigAlias
        let folder = selectedFolder ?? (try? FolderStore.ensureDefaultFolder(in: ctx))
        let scripts = loginScriptSteps.normalizedLoginScriptSteps

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
                remoteTerminalType: remoteTerminalType,
                colorTag: colorTag,
                iconName: iconName,
                notes: notes.isEmpty ? nil : notes,
                loginScriptSteps: scripts,
                sortIndex: folder.map(FolderStore.nextConnectionSortIndex(in:)) ?? 0,
                parent: folder
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
            p.remoteTerminalType = remoteTerminalType
            p.colorTag = colorTag
            p.iconName = iconName
            p.notes = notes.isEmpty ? nil : notes
            p.loginScriptSteps = scripts
            p.parent = folder
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

    private func ensureDefaultFolderSelection() {
        if selectedFolderID != nil { return }
        if let defaultFolder = topLevelFolders.first(where: { $0.name == FolderStore.defaultFolderName }) {
            selectedFolderID = defaultFolder.id
            return
        }
        if let folder = try? FolderStore.ensureDefaultFolder(in: ctx) {
            selectedFolderID = folder.id
        }
    }

    private func addLoginScriptStep() {
        loginScriptSteps.append(
            LoginScriptStep(
                match: "",
                send: "",
                sortIndex: loginScriptSteps.count
            )
        )
    }

    private func removeLoginScriptStep(id: UUID) {
        loginScriptSteps.removeAll { $0.id == id }
        renumberLoginScriptSteps()
    }

    private func moveLoginScriptSteps(from source: IndexSet, to destination: Int) {
        loginScriptSteps.move(fromOffsets: source, toOffset: destination)
        renumberLoginScriptSteps()
    }

    private func renumberLoginScriptSteps() {
        for index in loginScriptSteps.indices {
            loginScriptSteps[index].sortIndex = index
        }
    }
}

private struct LoginScriptStepRow: View {
    @Binding var step: LoginScriptStep
    let onDelete: () -> Void

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            FormTextField(
                title: "Match",
                text: $step.match,
                prompt: "Visible text",
                labelWidth: 46
            )
            FormTextField(
                title: "Send",
                text: $step.send,
                prompt: "Command",
                labelWidth: 38
            )
            Button(role: .destructive, action: onDelete) {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .frame(width: 28, height: 28)
            .help("Remove script step")
            .accessibilityLabel("Remove login script step")
        }
    }
}

private struct FormTextField: View {
    let title: String
    @Binding var text: String
    var prompt: String?
    var width: CGFloat?
    var isDisabled: Bool = false
    var labelWidth: CGFloat = 128

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: labelWidth, alignment: .leading)
            TextField("", text: $text, prompt: Text(prompt ?? title))
                .textFieldStyle(.roundedBorder)
                .controlSize(.regular)
                .disabled(isDisabled)
                .opacity(isDisabled ? 0.72 : 1)
                .accessibilityLabel(title)
                .frame(width: width)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct FormTextEditor: View {
    let title: String
    @Binding var text: String
    var minHeight: CGFloat

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 128, alignment: .leading)
            TextEditor(text: $text)
                .frame(minHeight: minHeight)
                .padding(4)
                .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 6))
                .overlay {
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(.quaternary, lineWidth: 1)
                }
                .accessibilityLabel(title)
        }
    }
}
