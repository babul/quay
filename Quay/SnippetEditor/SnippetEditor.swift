import SwiftData
import SwiftUI

struct SnippetEditor: View {
    @Environment(\.modelContext) private var ctx

    @Query(sort: [SortDescriptor(\SnippetGroup.sortIndex), SortDescriptor(\SnippetGroup.name)])
    private var groups: [SnippetGroup]

    let snippet: Snippet
    let activeTab: TerminalTabItem?

    @State private var name: String = ""
    @State private var body_: String = ""
    @State private var notes_: String = ""
    @State private var appendsReturn: Bool = false
    @State private var isSecured: Bool = false
    @State private var selectedGroupID: UUID?
    @State private var isRevealed: Bool = false
    @State private var pendingLocks: [UUID: SensitiveBytes] = [:]
    @State private var pendingDeletes: Set<String> = []
    @State private var saveError: String?
    @State private var didLoad = false
    @State private var isBusy = false

    var body: some View {
        VStack(spacing: 0) {
            nameField
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    metadataChips
                    bodyCard
                    notesCard
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 18)
            }
        }
        .toolbar { editorToolbar }
        .navigationTitle(name.isEmpty ? "Snippet" : name)
        .onAppear { loadIfNeeded() }
        .onChange(of: snippet.id) { _, _ in reload() }
        .alert("Could not save", isPresented: Binding(
            get: { saveError != nil },
            set: { if !$0 { saveError = nil } }
        )) {
            Button("OK") { saveError = nil }
        } message: {
            Text(saveError ?? "")
        }
    }

    // MARK: - Name

    private var nameField: some View {
        TextField("Untitled snippet", text: $name)
            .textFieldStyle(.plain)
            .font(.system(size: 22, weight: .semibold))
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
    }

    // MARK: - Metadata chips

    private var metadataChips: some View {
        HStack(spacing: 8) {
            Picker(selection: $selectedGroupID) {
                Label("Ungrouped", systemImage: "tray").tag(Optional<UUID>.none)
                ForEach(groups) { g in
                    Label(g.name, systemImage: FolderIcon.systemName(for: g.iconName))
                        .tag(Optional(g.id))
                }
            } label: {
                Label(selectedGroupName, systemImage: selectedGroupIcon)
            }
            .pickerStyle(.menu)
            .controlSize(.small)
            .fixedSize()

            Toggle(isOn: $appendsReturn) {
                Label("Append return", systemImage: "return")
            }
            .toggleStyle(.button)
            .controlSize(.small)
            .help("Press Return after pasting")

            Toggle(isOn: securedBinding) {
                Label("Secured", systemImage: isSecured ? "lock.fill" : "lock.open")
            }
            .toggleStyle(.button)
            .controlSize(.small)
            .help("Store body in Keychain (Touch ID to use)")

            Spacer()
        }
    }

    private var selectedGroup: SnippetGroup? {
        groups.first(where: { $0.id == selectedGroupID })
    }

    private var selectedGroupName: String {
        selectedGroup?.name ?? "Ungrouped"
    }

    private var selectedGroupIcon: String {
        selectedGroup.map { FolderIcon.systemName(for: $0.iconName) } ?? "tray"
    }

    // MARK: - Body card

    private var bodyCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionLabel("COMMAND")
            ZStack(alignment: .topLeading) {
                cardBackground
                if isSecured && !isRevealed {
                    lockedBodyOverlay
                } else {
                    TextEditor(text: $body_)
                        .font(.system(.body, design: .monospaced))
                        .scrollContentBackground(.hidden)
                        .padding(10)
                        .frame(minHeight: 200, idealHeight: 280, maxHeight: 480)
                }
            }
        }
    }

    private var lockedBodyOverlay: some View {
        HStack(spacing: 10) {
            Image(systemName: "lock.fill")
                .foregroundStyle(.secondary)
            Text("Stored in Keychain")
                .foregroundStyle(.secondary)
            Spacer()
            Button("Reveal & Edit") { Task { await revealBody() } }
                .buttonStyle(.borderless)
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 200, alignment: .topLeading)
    }

    // MARK: - Notes card

    private var notesCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionLabel("NOTES")
            ZStack(alignment: .topLeading) {
                cardBackground
                TextEditor(text: $notes_)
                    .scrollContentBackground(.hidden)
                    .padding(10)
                    .frame(minHeight: 80, idealHeight: 120, maxHeight: 240)
                if notes_.isEmpty {
                    Text("Add a description…")
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 18)
                        .allowsHitTesting(false)
                }
            }
        }
    }

    // MARK: - Shared helpers

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(.quinary)
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(.separator, lineWidth: 1)
            )
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            .tracking(0.5)
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var editorToolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            toolbarActionButton(
                "Paste",
                systemImage: "arrow.right.doc.on.clipboard",
                isDisabled: activeTab == nil || isBusy,
                help: activeTab == nil ? "No active terminal" : "Paste to active terminal"
            ) {
                await SnippetActions.paste(snippet, into: activeTab, appendReturn: false)
            }

            toolbarActionButton(
                "Run",
                systemImage: "play.fill",
                isDisabled: activeTab == nil || isBusy,
                help: activeTab == nil ? "No active terminal" : "Paste and press Return"
            ) {
                await SnippetActions.paste(snippet, into: activeTab, appendReturn: true)
            }

            toolbarActionButton(
                "Copy",
                systemImage: "doc.on.doc",
                isDisabled: isBusy,
                help: "Copy to clipboard"
            ) {
                await SnippetActions.copy(snippet)
            }
        }

        ToolbarItem(placement: .confirmationAction) {
            if hasPendingChanges {
                Button("Save") { save() }
                    .keyboardShortcut("s", modifiers: .command)
            }
        }
    }

    private func toolbarActionButton(
        _ label: String,
        systemImage: String,
        isDisabled: Bool,
        help: String,
        action: @escaping () async -> Void
    ) -> some View {
        Button {
            isBusy = true
            Task {
                await action()
                isBusy = false
            }
        } label: {
            Label(label, systemImage: systemImage)
        }
        .disabled(isDisabled)
        .help(help)
    }

    // MARK: - State

    private var hasPendingChanges: Bool {
        !pendingLocks.isEmpty || !pendingDeletes.isEmpty
            || name.trimmingCharacters(in: .whitespacesAndNewlines) != snippet.name
            || body_ != snippet.body
            || notes_ != snippet.notes
            || appendsReturn != snippet.appendsReturn
            || isSecured != snippet.isSecured
            || selectedGroupID != snippet.group?.id
    }

    private var securedBinding: Binding<Bool> {
        Binding(
            get: { isSecured },
            set: { newValue in
                guard newValue != isSecured else { return }
                isSecured = newValue
                if newValue {
                    if !body_.isEmpty {
                        pendingLocks[snippet.id] = SensitiveBytes(Data(body_.utf8))
                    }
                    body_ = ""
                    isRevealed = false
                } else {
                    Task { @MainActor in await unsecure() }
                }
            }
        )
    }

    private func loadIfNeeded() {
        guard !didLoad else { return }
        reload()
        didLoad = true
    }

    private func reload() {
        name = snippet.name
        body_ = snippet.body
        notes_ = snippet.notes
        appendsReturn = snippet.appendsReturn
        isSecured = snippet.isSecured
        selectedGroupID = snippet.group?.id
        isRevealed = false
        pendingLocks = [:]
        pendingDeletes = []
    }

    private func revealBody() async {
        await unlockBody(removePendingLock: false, markForDeletion: false)
    }

    private func unsecure() async {
        await unlockBody(removePendingLock: true, markForDeletion: true)
    }

    private func unlockBody(removePendingLock: Bool, markForDeletion: Bool) async {
        // Try pending lock first
        if let pending = pendingLocks[snippet.id] {
            body_ = pending.unsafeUTF8String() ?? ""
            if removePendingLock {
                pendingLocks.removeValue(forKey: snippet.id)
            }
            isRevealed = true
            return
        }

        // Try keychain reference
        guard let uri = snippet.bodyRef else {
            body_ = ""
            isRevealed = true
            return
        }

        do {
            let bytes = try await ReferenceResolver().resolve(uri)
            body_ = bytes.unsafeUTF8String() ?? ""
            if markForDeletion {
                pendingDeletes.insert(uri)
            }
            isRevealed = true
        } catch {
            // Touch ID cancelled or unsecure failed — revert state
            if markForDeletion {
                isSecured = true
            }
        }
    }

    // MARK: - Save

    private func save() {
        for uri in pendingDeletes {
            guard let pair = SecretReference.keychainPair(forURI: uri) else { continue }
            try? KeychainStore.delete(service: pair.service, account: pair.account)
        }
        pendingDeletes = []

        if isSecured {
            let textToWrite: String
            if isRevealed {
                textToWrite = body_
            } else if let pending = pendingLocks[snippet.id] {
                textToWrite = pending.unsafeUTF8String() ?? ""
            } else {
                textToWrite = ""
            }
            if !textToWrite.isEmpty {
                do {
                    try KeychainStore.write(
                        service: SecretReference.snippetKeychainService,
                        account: snippet.id.uuidString,
                        value: SensitiveBytes(Data(textToWrite.utf8))
                    )
                } catch {
                    saveError = "Could not secure snippet: \(error.localizedDescription)"
                    return
                }
            }
        }
        pendingLocks = [:]

        snippet.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        snippet.body = isSecured ? "" : body_
        snippet.bodyRef = isSecured ? SecretReference.snippetURI(snippetID: snippet.id) : nil
        snippet.notes = notes_
        snippet.appendsReturn = appendsReturn
        snippet.group = groups.first { $0.id == selectedGroupID }
        try? ctx.save()

        if isSecured {
            body_ = ""
            isRevealed = false
        }
    }
}
