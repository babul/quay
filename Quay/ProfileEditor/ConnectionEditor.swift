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
    @State private var hostnameIsRevealed = false
    @State private var portIsRevealed = false
    @State private var usernameIsRevealed = false
    @State private var sshConfigAliasIsRevealed = false
    @State private var selectedEditorPage: ConnectionEditorPage = .connection

    var body: some View {
        VStack(spacing: 0) {
            Picker("Editor section", selection: $selectedEditorPage) {
                ForEach(ConnectionEditorPage.allCases) { page in
                    Text(page.label).tag(page)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 12)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    editorPage
                }
                    .frame(width: ConnectionEditorLayout.contentWidth, alignment: .topLeading)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 18)
            }

            Divider()

            HStack(spacing: 12) {
                Spacer()
                Button("Cancel") { close() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .frame(width: ConnectionEditorLayout.sheetWidth)
        .frame(minHeight: 420)
        .fixedSize(horizontal: true, vertical: false)
        .onAppear { loadIfNeeded() }
    }

    @ViewBuilder
    private var editorPage: some View {
        switch selectedEditorPage {
        case .connection:
            connectionPage
        case .scripts:
            scriptsPage
        case .appearance:
            appearancePage
        case .notes:
            notesPage
        }
    }

    private var connectionPage: some View {
        VStack(alignment: .leading, spacing: 18) {
            EditorSection("Identity") {
                FormTextField(title: "Display name", text: $name)
                EditorDivider()
                groupPicker
                EditorDivider()
                FormPrivateTextField(
                    title: "Hostname",
                    text: $hostname,
                    isRevealed: $hostnameIsRevealed,
                    isDisabled: authMethod == .sshConfigAlias
                )
                EditorDivider()
                HStack {
                    FormPrivateTextField(
                        title: "Port",
                        text: $port,
                        isRevealed: $portIsRevealed,
                        width: 124,
                        labelWidth: 48
                    )
                    FormPrivateTextField(
                        title: "Username",
                        text: $username,
                        isRevealed: $usernameIsRevealed,
                        width: 190,
                        labelWidth: 78
                    )
                }
            }

            EditorSection("Authentication") {
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
                        .frame(width: ConnectionEditorLayout.rowWidth, alignment: .leading)
                case .privateKey:
                    EditorDivider()
                    keyPathField
                case .privateKeyWithPassphrase:
                    EditorDivider()
                    keyPathField
                    EditorDivider()
                    secretRefField(label: "Passphrase reference",
                                   placeholder: "keychain://service/account")
                case .password:
                    EditorDivider()
                    secretRefField(label: "Password reference",
                                   placeholder: "keychain://service/account")
                case .sshConfigAlias:
                    EditorDivider()
                    FormPrivateTextField(
                        title: "Host alias",
                        text: $sshConfigAlias,
                        isRevealed: $sshConfigAliasIsRevealed,
                        prompt: "Host alias from ~/.ssh/config"
                    )
                }
            }

            EditorSection("Terminal") {
                Picker("Remote TERM", selection: $remoteTerminalType) {
                    ForEach(RemoteTerminalType.allCases) { type in
                        Text(type.label).tag(type)
                    }
                }
                EditorDivider()
                Text(remoteTerminalType.helpText)
                    .foregroundStyle(.secondary)
                    .font(.caption)
                    .frame(width: ConnectionEditorLayout.rowWidth, alignment: .leading)
            }
        }
    }

    private var scriptsPage: some View {
        EditorSection("Login Scripts") {
            if loginScriptSteps.isEmpty {
                Text("No login scripts.")
                    .foregroundStyle(.secondary)
                    .frame(width: ConnectionEditorLayout.rowWidth, alignment: .leading)
            } else {
                ForEach($loginScriptSteps) { $step in
                    LoginScriptStepRow(
                        step: $step,
                        onDelete: { removeLoginScriptStep(id: step.id) }
                    )
                    if step.id != loginScriptSteps.last?.id {
                        EditorDivider()
                    }
                }
            }

            EditorDivider()

            Button {
                addLoginScriptStep()
            } label: {
                Label("Add script step", systemImage: "plus")
            }
        }
    }

    private var appearancePage: some View {
        EditorSection("Appearance") {
            AppearanceIconPicker(
                title: "Icon",
                defaultSystemName: ConnectionIcon.fallback,
                defaultHelp: "Default",
                accessibilityLabel: "Connection icon",
                selection: $iconName
            )
            EditorDivider()
            colorPicker
        }
    }

    private var notesPage: some View {
        EditorSection("Notes") {
            FormTextEditor(title: "Notes", text: $notes, minHeight: 132)
        }
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
            if selectedFolderID == nil {
                Text("Default").tag(Optional<UUID>.none)
            }
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
                prompt: "Path to private key",
                width: 360
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
        resetPrivacyReveals()
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

    private func resetPrivacyReveals() {
        hostnameIsRevealed = false
        portIsRevealed = false
        usernameIsRevealed = false
        sshConfigAliasIsRevealed = false
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
    @State private var matchIsRevealed = false
    @State private var sendIsRevealed = false

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            FormPrivateTextField(
                title: "Match",
                text: $step.match,
                isRevealed: $matchIsRevealed,
                prompt: "Visible text",
                width: 170,
                labelWidth: 46
            )
            FormPrivateTextField(
                title: "Send",
                text: $step.send,
                isRevealed: $sendIsRevealed,
                prompt: "Command",
                width: 210,
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
        .frame(width: width == nil ? ConnectionEditorLayout.rowWidth : nil, alignment: .leading)
    }
}

enum ConnectionEditorPrivacy {
    enum Field: CaseIterable {
        case hostname
        case port
        case username
        case sshConfigAlias
        case loginScriptMatch
        case loginScriptSend
    }

    static func isSensitive(_ field: Field) -> Bool {
        switch field {
        case .hostname, .port, .username, .sshConfigAlias,
             .loginScriptMatch, .loginScriptSend:
            return true
        }
    }
}

private enum ConnectionEditorPage: String, CaseIterable, Identifiable {
    case connection
    case scripts
    case appearance
    case notes

    var id: Self { self }

    var label: String {
        switch self {
        case .connection: return "Connection"
        case .scripts: return "Scripts"
        case .appearance: return "Appearance"
        case .notes: return "Notes"
        }
    }
}

private enum ConnectionEditorLayout {
    static let sheetWidth: CGFloat = 680
    static let contentWidth: CGFloat = 620
    static let rowWidth: CGFloat = 596
}

private struct EditorSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    init(_ title: String, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
            VStack(spacing: 10) {
                content()
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(nsColor: .controlBackgroundColor).opacity(0.55))
            )
        }
        .frame(width: ConnectionEditorLayout.contentWidth, alignment: .leading)
    }
}

private struct EditorDivider: View {
    var body: some View {
        Divider()
    }
}

private struct FormPrivateTextField: View {
    let title: String
    @Binding var text: String
    @Binding var isRevealed: Bool
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

            HStack(spacing: 6) {
                Group {
                    if isRevealed {
                        TextField("", text: $text, prompt: Text(prompt ?? title))
                    } else {
                        SecureField("", text: $text, prompt: Text(prompt ?? title))
                    }
                }
                .textFieldStyle(.roundedBorder)
                .controlSize(.regular)
                .disabled(isDisabled)
                .opacity(isDisabled ? 0.72 : 1)
                .accessibilityLabel(title)

                Button {
                    isRevealed.toggle()
                } label: {
                    Image(systemName: isRevealed ? "eye.slash" : "eye")
                }
                .buttonStyle(.borderless)
                .frame(width: 28, height: 28)
                .disabled(isDisabled)
                .help(isRevealed ? "Hide \(title)" : "Reveal \(title)")
                .accessibilityLabel(isRevealed ? "Hide \(title)" : "Reveal \(title)")
            }
            .frame(width: width)
        }
        .frame(width: width == nil ? ConnectionEditorLayout.rowWidth : nil, alignment: .leading)
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
                .frame(width: ConnectionEditorLayout.rowWidth - 140)
                .frame(minHeight: minHeight)
                .padding(4)
                .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 6))
                .overlay {
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(.quaternary, lineWidth: 1)
                }
                .accessibilityLabel(title)
        }
        .frame(width: ConnectionEditorLayout.rowWidth, alignment: .leading)
    }
}
