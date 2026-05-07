import SwiftData
import SwiftUI

/// Modal sheet for creating or editing a `ConnectionProfile`.
///
/// Auth picker swaps the visible secondary fields. Users paste the Keychain
/// URI directly — no inline picker sheet.
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
    @State private var localDirectory: String = ""
    @State private var remoteDirectory: String = ""
    @State private var remoteTerminalType: RemoteTerminalType = .defaultValue
    @State private var colorTag: String?
    @State private var iconName: String?
    @State private var notes: String = ""
    @State private var loginScriptSteps: [LoginScriptStep] = []
    @State private var pendingLocks: [UUID: SensitiveBytes] = [:]
    @State private var pendingDeletes: Set<String> = []
    @State private var saveError: String?
    @State private var selectedFolderID: UUID?
    @State private var didLoad = false
    @State private var hostnameIsRevealed = false
    @State private var portIsRevealed = false
    @State private var usernameIsRevealed = false
    @State private var sshConfigAliasIsRevealed = false
    @State private var localDirectoryIsRevealed = false
    @State private var remoteDirectoryIsRevealed = false
    @State private var selectedEditorPage: ConnectionEditorPage = .connection
    @State private var testStatus: TestStatus = .idle
    @State private var testTask: Task<Void, Never>?

    private enum TestStatus: Equatable {
        case idle, running, success
        case failure(String)
    }

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
        .onDisappear {
            pendingLocks = [:]
            pendingDeletes = []
            testTask?.cancel()
            testTask = nil
        }
        .onChange(of: authMethod) { testStatus = .idle }
        .alert(
            "Could not save",
            isPresented: Binding(get: { saveError != nil }, set: { _ in saveError = nil })
        ) {
            Button("OK") { saveError = nil }
        } message: {
            Text(saveError ?? "")
        }
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
                Divider()
                groupPicker
                Divider()
                FormTextField(
                    title: "Hostname",
                    text: $hostname,
                    isRevealed: $hostnameIsRevealed,
                    isDisabled: authMethod == .sshConfigAlias
                )
                Divider()
                HStack {
                    FormTextField(
                        title: "Port",
                        text: $port,
                        isRevealed: $portIsRevealed,
                        width: 124,
                        labelWidth: 48
                    )
                    FormTextField(
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
                    Text("OpenSSH defaults").tag(ConnectionProfile.AuthMethod.sshAgent)
                    Text("Private key").tag(ConnectionProfile.AuthMethod.privateKey)
                    Text("Private key + passphrase").tag(ConnectionProfile.AuthMethod.privateKeyWithPassphrase)
                    Text("Password").tag(ConnectionProfile.AuthMethod.password)
                    Text("ssh.config alias").tag(ConnectionProfile.AuthMethod.sshConfigAlias)
                }

                switch authMethod {
                case .sshAgent:
                    Text("Uses ~/.ssh/config, default identity files, and keys loaded into ssh-agent.")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                        .frame(width: ConnectionEditorLayout.rowWidth, alignment: .leading)
                case .privateKey:
                    Divider()
                    keyPathField
                case .privateKeyWithPassphrase:
                    Divider()
                    keyPathField
                    Divider()
                    secretRefField(label: "Passphrase reference",
                                   placeholder: "keychain://service/account")
                case .password:
                    Divider()
                    secretRefField(label: "Password reference",
                                   placeholder: "keychain://service/account")
                case .sshConfigAlias:
                    Divider()
                    FormTextField(
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
                Divider()
                Text(remoteTerminalType.helpText)
                    .foregroundStyle(.secondary)
                    .font(.caption)
                    .frame(width: ConnectionEditorLayout.rowWidth, alignment: .leading)
            }

            EditorSection("SFTP") {
                HStack {
                    FormTextField(
                        title: "Local directory",
                        text: $localDirectory,
                        isRevealed: $localDirectoryIsRevealed,
                        prompt: "Uses global default if empty",
                        width: 360
                    )
                    Button("Choose…") { pickLocalDirectory() }
                }
                Divider()
                FormTextField(
                    title: "Remote directory",
                    text: $remoteDirectory,
                    isRevealed: $remoteDirectoryIsRevealed,
                    prompt: "/path/on/server"
                )
            }

            EditorSection("Test") {
                VStack(alignment: .leading, spacing: 8) {
                    Button("Test connection") { runTest() }
                        .disabled(!canTest)
                    testStatusView
                }
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
                        pendingBytes: pendingLocks[step.id],
                        onDelete: { removeLoginScriptStep(id: step.id) },
                        onLockConfirmed: { id, bytes in pendingLocks[id] = bytes },
                        onScheduleUnlock: { id, uri in
                            pendingLocks.removeValue(forKey: id)
                            pendingDeletes.insert(uri)
                        }
                    )
                    if step.id != loginScriptSteps.last?.id {
                        Divider()
                    }
                }
            }

            Divider()

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
            Divider()
            colorPicker
        }
    }

    private var notesPage: some View {
        EditorSection("Notes") {
            FormTextEditor(title: "Notes", text: $notes, minHeight: 132)
        }
    }

    private var topLevelFolders: [Folder] {
        SidebarOrdering.foldersByName(folders.filter { $0.parent == nil })
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
            Text("Keychain URI — e.g. keychain://service/account")
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

    @ViewBuilder
    private var testStatusView: some View {
        switch testStatus {
        case .idle:
            EmptyView()
        case .running:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Testing…").foregroundStyle(.secondary)
            }
        case .success:
            Label("Connected", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failure(let msg):
            Label(msg, systemImage: "xmark.octagon.fill")
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func draftSSHTarget() -> SSHTarget? {
        let host = hostname.trimmingCharacters(in: .whitespaces)
        let portInt = Int(port.trimmingCharacters(in: .whitespaces))
        let user = username.isEmpty ? nil : username

        switch authMethod {
        case .sshAgent:
            guard !host.isEmpty else { return nil }
            return SSHTarget(hostname: host, port: portInt, username: user, auth: .sshAgent,
                             remoteTerminalType: remoteTerminalType)
        case .privateKey:
            guard !host.isEmpty, !privateKeyPath.isEmpty else { return nil }
            return SSHTarget(hostname: host, port: portInt, username: user,
                             auth: .privateKey(path: privateKeyPath),
                             remoteTerminalType: remoteTerminalType)
        case .privateKeyWithPassphrase:
            guard !host.isEmpty, !privateKeyPath.isEmpty, !secretRef.isEmpty else { return nil }
            return SSHTarget(hostname: host, port: portInt, username: user,
                             auth: .privateKeyWithPassphrase(path: privateKeyPath, passphraseRef: secretRef),
                             remoteTerminalType: remoteTerminalType)
        case .password:
            guard !host.isEmpty, !secretRef.isEmpty else { return nil }
            return SSHTarget(hostname: host, port: portInt, username: user,
                             auth: .password(passwordRef: secretRef),
                             remoteTerminalType: remoteTerminalType)
        case .sshConfigAlias:
            let alias = sshConfigAlias.trimmingCharacters(in: .whitespaces)
            guard !alias.isEmpty else { return nil }
            return SSHTarget(hostname: "", port: nil, username: nil,
                             auth: .sshConfigAlias(alias: alias),
                             remoteTerminalType: remoteTerminalType)
        }
    }

    private var canTest: Bool { draftSSHTarget() != nil && testStatus != .running }

    private func runTest() {
        guard let target = draftSSHTarget() else { return }
        testTask?.cancel()
        testStatus = .running
        testTask = Task { @MainActor in
            let result = await ConnectionProbe.run(target: target)
            guard !Task.isCancelled else { return }
            switch result {
            case .success:
                testStatus = .success
            case .failure(let msg, _):
                testStatus = .failure(msg)
            }
        }
    }

    private var canSave: Bool {
        guard name.trimmedNonEmpty != nil else { return false }
        switch authMethod {
        case .sshConfigAlias:
            return sshConfigAlias.trimmedNonEmpty != nil
        default:
            return hostname.trimmedNonEmpty != nil
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
            localDirectory = p.localDirectory ?? ""
            remoteDirectory = p.remoteDirectory ?? ""
            remoteTerminalType = p.remoteTerminalType
            colorTag = ConnectionColor.isKnown(p.colorTag) ? p.colorTag : nil
            iconName = p.iconName
            notes = p.notes ?? ""
            loginScriptSteps = p.loginScriptSteps
            selectedFolderID = p.parent?.id
            ensureDefaultFolderSelection()
        } else if case .create(let folderID) = target {
            if let folderID { selectedFolderID = folderID }
            ensureDefaultFolderSelection()
        }
    }

    private func resetPrivacyReveals() {
        hostnameIsRevealed = false
        portIsRevealed = false
        usernameIsRevealed = false
        sshConfigAliasIsRevealed = false
        localDirectoryIsRevealed = false
        remoteDirectoryIsRevealed = false
    }

    private func save() {
        // Apply Keychain mutations first — abort if a write fails so the
        // on-disk profile can never reference a missing Keychain entry.
        for uri in pendingDeletes {
            guard let pair = SecretReference.keychainPair(forURI: uri) else { continue }
            try? KeychainStore.delete(service: pair.service, account: pair.account)
        }
        for (stepID, value) in pendingLocks {
            do {
                try KeychainStore.write(
                    service: SecretReference.loginScriptKeychainService,
                    account: stepID.uuidString,
                    value: value
                )
            } catch {
                saveError = "Could not lock step: \(error.localizedDescription)"
                return
            }
        }
        pendingLocks = [:]
        pendingDeletes = []

        let portInt = Int(port.trimmingCharacters(in: .whitespaces))
        let user = username.isEmpty ? nil : username
        let secret = secretRef.isEmpty ? nil : secretRef
        let keyPath = privateKeyPath.isEmpty ? nil : privateKeyPath
        let alias = sshConfigAlias.isEmpty ? nil : sshConfigAlias
        let localDir = localDirectory.trimmedNonEmpty
        let remoteDir = remoteDirectory.trimmedNonEmpty
        let folder = selectedFolder ?? (try? FolderStore.ensureDefaultFolder(in: ctx))
        let scripts = loginScriptSteps.normalizedLoginScriptSteps

        switch target {
        case .create(_):
            let profile = ConnectionProfile(
                name: name.trimmingCharacters(in: .whitespaces),
                hostname: hostname.trimmingCharacters(in: .whitespaces),
                port: portInt,
                username: user,
                authMethod: authMethod,
                secretRef: secret,
                privateKeyPath: keyPath,
                sshConfigAlias: alias,
                localDirectory: localDir,
                remoteDirectory: remoteDir,
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
            p.localDirectory = localDir
            p.remoteDirectory = remoteDir
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
        if let url = pickURL(files: true, startingAt: FileManager.default.homeDirectoryForCurrentUser.appending(path: ".ssh")) {
            privateKeyPath = url.path
        }
    }

    private func pickLocalDirectory() {
        if let url = pickURL(files: false, startingAt: FileManager.default.homeDirectoryForCurrentUser) {
            localDirectory = url.path
        }
    }

    private func pickURL(files: Bool, startingAt startURL: URL) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = files
        panel.canChooseDirectories = !files
        panel.allowsMultipleSelection = false
        panel.directoryURL = startURL
        return panel.runModal() == .OK ? panel.url : nil
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
        // Drop any pending in-memory lock for this step. If the step had a
        // *saved* lock (no pending bytes), schedule its Keychain entry for
        // deletion on save.
        if let step = loginScriptSteps.first(where: { $0.id == id }), let uri = step.sendRef {
            if pendingLocks.removeValue(forKey: id) == nil {
                pendingDeletes.insert(uri)
            }
        }
        loginScriptSteps.removeAll { $0.id == id }
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
    /// Non-nil while the lock is pending save (bytes held in memory, not yet in Keychain).
    let pendingBytes: SensitiveBytes?
    let onDelete: () -> Void
    let onLockConfirmed: (UUID, SensitiveBytes) -> Void
    let onScheduleUnlock: (UUID, String) -> Void

    @State private var showingLockSheet = false
    @State private var showingUnlockConfirm = false
    @State private var lockInputText = ""

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            FormTextField(
                title: "Match",
                text: $step.match,
                prompt: "Visible text",
                width: 170,
                labelWidth: 46
            )

            if step.sendRef != nil {
                lockedSendView
            } else {
                FormTextField(
                    title: "Send",
                    text: $step.send,
                    prompt: "Command",
                    width: 210,
                    labelWidth: 38
                )
            }

            Button(action: handleLockTap) {
                Image(systemName: step.sendRef != nil ? "lock.fill" : "lock.open")
            }
            .buttonStyle(.borderless)
            .frame(width: 20, height: 28)
            .help(step.sendRef != nil ? "Unlock step" : "Lock step value in Keychain")

            Button(role: .destructive, action: onDelete) {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .frame(width: 28, height: 28)
            .help("Remove script step")
            .accessibilityLabel("Remove login script step")
        }
        .sheet(isPresented: $showingLockSheet) {
            LockStepSheet(inputText: $lockInputText) {
                commitLock(text: lockInputText)
                showingLockSheet = false
            } onCancel: {
                lockInputText = ""
                showingLockSheet = false
            }
        }
        .confirmationDialog(
            "Unlock this step?",
            isPresented: $showingUnlockConfirm,
            titleVisibility: .visible
        ) {
            Button("Reveal & Edit") { revealAndEdit() }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("The value will be retrieved from your Keychain.")
        }
    }

    private var lockedSendView: some View {
        HStack(spacing: 12) {
            Text("Send")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 38, alignment: .leading)
            Text("Stored in Keychain")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .italic()
                .frame(width: 160, alignment: .leading)
        }
        .frame(width: 210, alignment: .leading)
    }

    private func handleLockTap() {
        if step.sendRef != nil {
            showingUnlockConfirm = true
        } else if step.send.isEmpty {
            lockInputText = ""
            showingLockSheet = true
        } else {
            commitLock(text: step.send)
        }
    }

    private func commitLock(text: String) {
        guard !text.isEmpty else { return }
        let value = SensitiveBytes(Data(text.utf8))
        let uri = SecretReference.loginScriptStepURI(stepID: step.id)
        step.send = ""
        step.sendRef = uri
        lockInputText = ""
        onLockConfirmed(step.id, value)
    }

    private func revealAndEdit() {
        guard let uri = step.sendRef else { return }

        // Pending lock: bytes are still in memory — no Keychain read needed.
        if let bytes = pendingBytes, let text = bytes.unsafeUTF8String() {
            onScheduleUnlock(step.id, uri)
            step.send = text
            step.sendRef = nil
            return
        }

        // Saved lock: resolve from Keychain (Touch ID prompt).
        Task { @MainActor in
            do {
                let bytes = try await ReferenceResolver().resolve(uri)
                if let text = bytes.unsafeUTF8String() {
                    onScheduleUnlock(step.id, uri)
                    step.send = text
                    step.sendRef = nil
                }
            } catch {
                // Touch ID cancelled or item missing — leave step locked.
            }
        }
    }
}

private struct LockStepSheet: View {
    @Binding var inputText: String
    let onConfirm: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Lock Step")
                .font(.headline)

            SecureField("Secret value", text: $inputText)
                .textFieldStyle(.roundedBorder)
                .onSubmit { if !inputText.isEmpty { onConfirm() } }

            Text("The value will be stored in your Keychain and resolved when Quay runs this script.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.escape, modifiers: [])
                Spacer()
                Button("Lock", action: onConfirm)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(inputText.isEmpty)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 300)
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

private struct FormTextField: View {
    let title: String
    @Binding var text: String
    var isRevealed: Binding<Bool>? = nil
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

            if let isRevealed {
                HStack(spacing: 6) {
                    Group {
                        if isRevealed.wrappedValue {
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
                        isRevealed.wrappedValue.toggle()
                    } label: {
                        Image(systemName: isRevealed.wrappedValue ? "eye.slash" : "eye")
                    }
                    .buttonStyle(.borderless)
                    .frame(width: 28, height: 28)
                    .disabled(isDisabled)
                    .help(isRevealed.wrappedValue ? "Hide \(title)" : "Reveal \(title)")
                    .accessibilityLabel(isRevealed.wrappedValue ? "Hide \(title)" : "Reveal \(title)")
                }
                .frame(width: width)
            } else {
                TextField("", text: $text, prompt: Text(prompt ?? title))
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.regular)
                    .disabled(isDisabled)
                    .opacity(isDisabled ? 0.72 : 1)
                    .accessibilityLabel(title)
                    .frame(width: width)
            }
        }
        .frame(width: width == nil ? ConnectionEditorLayout.rowWidth : nil, alignment: .leading)
    }
}

private extension String {
    var trimmedNonEmpty: String? {
        let t = trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
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
