import SwiftData
import SwiftUI

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
    @State private var testStatus: TestStatus = .idle
    @State private var testTask: Task<Void, Never>?

    private enum TestStatus: Equatable {
        case idle, running, success
        case failure(String)
    }

    var body: some View {
        TabView {
            Tab("Connection", systemImage: "network")           { connectionPage }
            Tab("Scripts",    systemImage: "terminal")          { scriptsPage }
            Tab("Appearance", systemImage: "paintpalette.fill") { appearancePage }
            Tab("Notes",      systemImage: "square.and.pencil") { notesPage }
        }
        .tabViewStyle(.sidebarAdaptable)
        .frame(minWidth: 500, idealWidth: 680, maxWidth: .infinity,
               minHeight: 400, idealHeight: 540, maxHeight: .infinity)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { close() }
                    .keyboardShortcut(.escape, modifiers: [])
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { save() }
                    .disabled(!canSave)
            }
        }
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

    // MARK: - Pages

    private var connectionPage: some View {
        Form {
            Section("Identity") {
                TextField("Display name", text: $name)
                groupPicker
                revealableField("Hostname", text: $hostname,
                               isRevealed: $hostnameIsRevealed,
                               isDisabled: authMethod == .sshConfigAlias)
                revealableField("Port", text: $port, isRevealed: $portIsRevealed, prompt: "22")
                revealableField("Username", text: $username, isRevealed: $usernameIsRevealed)
            }

            Section("Authentication") {
                Picker("Method", selection: $authMethod) {
                    Text("OpenSSH defaults").tag(ConnectionProfile.AuthMethod.sshAgent)
                    Text("Private key").tag(ConnectionProfile.AuthMethod.privateKey)
                    Text("Private key + passphrase").tag(ConnectionProfile.AuthMethod.privateKeyWithPassphrase)
                    Text("Password").tag(ConnectionProfile.AuthMethod.password)
                    Text("ssh.config alias").tag(ConnectionProfile.AuthMethod.sshConfigAlias)
                }
                switch authMethod {
                case .sshAgent:
                    captionText("Uses ~/.ssh/config, default identity files, and keys loaded into ssh-agent.")
                case .privateKey:
                    keyPathField
                case .privateKeyWithPassphrase:
                    keyPathField
                    secretRefField(label: "Passphrase reference", placeholder: "keychain://service/account")
                case .password:
                    secretRefField(label: "Password reference", placeholder: "keychain://service/account")
                case .sshConfigAlias:
                    revealableField("Host alias", text: $sshConfigAlias,
                                   isRevealed: $sshConfigAliasIsRevealed,
                                   prompt: "Host alias from ~/.ssh/config")
                }
                HStack(spacing: 8) {
                    Button("Test connection") { runTest() }
                        .disabled(!canTest)
                    testStatusView
                }
            }

            Section("Terminal") {
                Picker("Remote TERM", selection: $remoteTerminalType) {
                    ForEach(RemoteTerminalType.allCases) { type in
                        Text(type.label).tag(type)
                    }
                }
                captionText(remoteTerminalType.helpText)
            }

            Section("SFTP") {
                revealableField(
                    "Local directory",
                    text: $localDirectory,
                    isRevealed: $localDirectoryIsRevealed,
                    prompt: "Uses global default if empty"
                ) {
                    Button("Choose…") { pickLocalDirectory() }
                }
                revealableField(
                    "Remote directory",
                    text: $remoteDirectory,
                    isRevealed: $remoteDirectoryIsRevealed,
                    prompt: "/path/on/server"
                )
            }
        }
        .formStyle(.grouped)
    }

    private var scriptsPage: some View {
        Form {
            Section("Login Scripts") {
                if loginScriptSteps.isEmpty {
                    Text("No login scripts.")
                        .foregroundStyle(.secondary)
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
                    }
                }
                Button {
                    addLoginScriptStep()
                } label: {
                    Label("Add script step", systemImage: "plus")
                }
            }
        }
        .formStyle(.grouped)
    }

    private var appearancePage: some View {
        Form {
            Section("Appearance") {
                AppearanceIconPicker(
                    title: "Icon",
                    defaultSystemName: ConnectionIcon.fallback,
                    defaultHelp: "Default",
                    accessibilityLabel: "Connection icon",
                    selection: $iconName
                )
                LabeledContent("Color") {
                    HStack(spacing: 8) {
                        ForEach(ConnectionColor.tags) { tag in
                            Button { colorTag = tag.id } label: {
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
                        Button { colorTag = nil } label: {
                            ZStack {
                                Circle()
                                    .strokeBorder(.secondary, lineWidth: 1.5)
                                    .frame(width: 16, height: 16)
                                if colorTag == nil {
                                    Circle()
                                        .strokeBorder(.primary, lineWidth: 2)
                                        .frame(width: 22, height: 22)
                                }
                            }
                            .frame(width: 24, height: 24)
                        }
                        .buttonStyle(.plain)
                        .help("Default (no color)")
                    }
                    .accessibilityLabel("Connection color")
                }
            }
        }
        .formStyle(.grouped)
    }

    private var notesPage: some View {
        Form {
            Section("Notes") {
                TextEditor(text: $notes)
                    .frame(minHeight: 132)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Row builders

    @ViewBuilder
    private func revealableField<Trailing: View>(
        _ title: String,
        text: Binding<String>,
        isRevealed: Binding<Bool>,
        isDisabled: Bool = false,
        prompt: String? = nil,
        @ViewBuilder trailing: () -> Trailing = { EmptyView() }
    ) -> some View {
        let revealHelp = isRevealed.wrappedValue ? "Hide \(title)" : "Reveal \(title)"
        LabeledContent(title) {
            HStack(spacing: 6) {
                Group {
                    if isRevealed.wrappedValue {
                        TextField("", text: text, prompt: Text(prompt ?? title))
                    } else {
                        SecureField("", text: text, prompt: Text(prompt ?? title))
                    }
                }
                .textFieldStyle(.roundedBorder)
                .disabled(isDisabled)
                .opacity(isDisabled ? 0.72 : 1)
                .accessibilityLabel(title)

                Button {
                    isRevealed.wrappedValue.toggle()
                } label: {
                    Image(systemName: isRevealed.wrappedValue ? "eye.slash" : "eye")
                }
                .buttonStyle(.borderless)
                .disabled(isDisabled)
                .help(revealHelp)
                .accessibilityLabel(revealHelp)

                trailing()
            }
        }
    }

    private var keyPathField: some View {
        LabeledContent("Private key path") {
            HStack(spacing: 6) {
                TextField("", text: $privateKeyPath, prompt: Text("Path to private key"))
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Private key path")
                Button("Choose…") { pickKeyFile() }
            }
        }
    }

    private func secretRefField(label: String, placeholder: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            TextField(label, text: $secretRef, prompt: Text(placeholder))
            Text("Keychain URI — e.g. keychain://service/account")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private func captionText(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
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

    // MARK: - Logic

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
        if let url = pickURL(files: true,
                             startingAt: FileManager.default.homeDirectoryForCurrentUser.appending(path: ".ssh")) {
            privateKeyPath = url.path
        }
    }

    private func pickLocalDirectory() {
        if let url = pickURL(files: false,
                             startingAt: FileManager.default.homeDirectoryForCurrentUser) {
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
            LoginScriptStep(match: "", send: "", sortIndex: loginScriptSteps.count)
        )
    }

    private func removeLoginScriptStep(id: UUID) {
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

// MARK: - Login Script Step Row

private struct LoginScriptStepRow: View {
    @Binding var step: LoginScriptStep
    let pendingBytes: SensitiveBytes?
    let onDelete: () -> Void
    let onLockConfirmed: (UUID, SensitiveBytes) -> Void
    let onScheduleUnlock: (UUID, String) -> Void

    @State private var showingLockSheet = false
    @State private var showingUnlockConfirm = false
    @State private var lockInputText = ""

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Text("Match")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("", text: $step.match, prompt: Text("Visible text"))
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: .infinity)

            Text("Send")
                .font(.caption)
                .foregroundStyle(.secondary)

            if step.sendRef != nil {
                lockedSendView
            } else {
                TextField("", text: $step.send, prompt: Text("Command"))
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: .infinity)
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
        Text("Stored in Keychain")
            .font(.caption)
            .foregroundStyle(.tertiary)
            .italic()
            .frame(maxWidth: .infinity, alignment: .leading)
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

        if let bytes = pendingBytes, let text = bytes.unsafeUTF8String() {
            onScheduleUnlock(step.id, uri)
            step.send = text
            step.sendRef = nil
            return
        }

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

// MARK: - Lock Step Sheet

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

// MARK: - Supporting types

private extension String {
    var trimmedNonEmpty: String? {
        let t = trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}

// MARK: - Window scene support

/// Passed to `openWindow(value:)` to open the editor as a resizable standalone window.
enum ConnectionEditorSpec: Codable, Hashable {
    case create(folderID: UUID?)
    case edit(profileID: UUID)
}

/// Root view hosted inside the `WindowGroup` for connection editing.
struct ConnectionEditorWindowContent: View {
    @Environment(\.modelContext) private var ctx
    let spec: ConnectionEditorSpec
    @State private var target: SidebarView.EditorTarget?

    var body: some View {
        Group {
            if let target {
                ConnectionEditor(target: target, onClose: {})
            } else {
                Color.clear
            }
        }
        .onAppear { resolveTarget() }
    }

    private func resolveTarget() {
        switch spec {
        case .create(let folderID):
            target = .create(folderID: folderID)
        case .edit(let profileID):
            var descriptor = FetchDescriptor<ConnectionProfile>(
                predicate: #Predicate { $0.id == profileID }
            )
            descriptor.fetchLimit = 1
            target = (try? ctx.fetch(descriptor))?.first.map { .edit($0) }
        }
    }
}
