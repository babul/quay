import AppKit
import SwiftData
import SwiftUI

struct SnippetSidebarView: View {
    @Environment(\.modelContext) private var ctx
    @Environment(\.openWindow) private var openWindow

    @Query(sort: [SortDescriptor(\SnippetGroup.sortIndex), SortDescriptor(\SnippetGroup.name)])
    private var snippetGroups: [SnippetGroup]

    @Query(sort: [SortDescriptor(\Snippet.sortIndex), SortDescriptor(\Snippet.name)])
    private var allSnippets: [Snippet]

    let isVisible: Bool
    @State private var searchQuery = ""
    @State private var selectedID: UUID?
    @State private var collapsedGroupIDs = SnippetGroupCollapseState.load()
    @State private var lastClick: (id: UUID, time: Date)?
    @State private var snippetGroupEditTarget: SnippetGroup?
    @FocusState private var searchFocused: Bool

    private static let ungroupedID = UUID(uuidString: "554E4752-4F55-0000-0000-554E47524F55")!

    var body: some View {
        VStack(spacing: 0) {
            header
            searchField
            Divider()
            snippetList
        }
        .sheet(isPresented: Binding(
            get: { snippetGroupEditTarget != nil },
            set: { if !$0 { snippetGroupEditTarget = nil } }
        )) {
            if let grp = snippetGroupEditTarget {
                SnippetGroupEditorSheet(group: grp) { snippetGroupEditTarget = nil }
                    .frame(minWidth: 440, minHeight: 220)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .focusSearchSnippets)) { notification in
            guard (notification.object as? String) == "focus" else { return }
            searchFocused = true
        }
        .onChange(of: isVisible) { _, vis in
            guard !vis else { return }
            searchFocused = false
            NSApp.keyWindow?.makeFirstResponder(nil)
        }
        .onChange(of: snippetGroups.map(\.id)) { _, ids in
            SnippetGroupCollapseState.prune(&collapsedGroupIDs, keeping: Set(ids))
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 6) {
            Text("Snippets")
                .font(.system(size: 13, weight: .semibold))
            Spacer()
            Menu {
                Button("New Snippet…") { createSnippet(in: nil) }
                Button("New Snippet Group") { newSnippetGroup() }
            } label: {
                Image(systemName: "plus")
            }
            .menuStyle(.borderlessButton)
            .frame(width: 28)
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 6)
    }

    // MARK: - Search field

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .imageScale(.small)
            TextField("Search snippets", text: $searchQuery)
                .textFieldStyle(.plain)
                .focused($searchFocused)
                .onExitCommand {
                    searchFocused = false
                    NSApp.keyWindow?.makeFirstResponder(nil)
                }
            if !searchQuery.isEmpty {
                Button { searchQuery = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(.quinary, in: RoundedRectangle(cornerRadius: 7))
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    // MARK: - List

    private var snippetList: some View {
        List(selection: $selectedID) {
            snippetsSection
        }
        .listStyle(.sidebar)
    }

    private var searchIsActive: Bool {
        !searchQuery.trimmingCharacters(in: .whitespaces).isEmpty
    }

    @ViewBuilder
    private var snippetsSection: some View {
        let ungrouped: [Snippet] = {
            let items = allSnippets.filter { $0.group == nil }
            return searchIsActive
                ? FuzzySearch.rank(items, query: searchQuery) { snippetSearchKeys($0) }
                : items
        }()
        let visibleGroups: [(SnippetGroup, [Snippet])] = {
            snippetGroups.compactMap { g in
                var items = SnippetStore.snippets(in: g)
                if searchIsActive {
                    items = FuzzySearch.rank(items, query: searchQuery) { snippetSearchKeys($0) }
                    guard !items.isEmpty else { return nil }
                }
                return (g, items)
            }
        }()

        let hasContent = !visibleGroups.isEmpty || !ungrouped.isEmpty
        if hasContent {
            ForEach(visibleGroups, id: \.0.id) { group, items in
                snippetGroupHeaderRow(group, count: items.count)
                if !collapsedGroupIDs.contains(group.id) || searchIsActive {
                    ForEach(items, id: \.id) {
                        snippetRow($0).padding(.leading, 20)
                    }
                }
            }
            if !ungrouped.isEmpty {
                snippetsUngroupedHeaderRow(count: ungrouped.count)
                if !collapsedGroupIDs.contains(Self.ungroupedID) || searchIsActive {
                    ForEach(ungrouped, id: \.id) {
                        snippetRow($0).padding(.leading, 20)
                    }
                }
            }
        } else if !searchIsActive {
            ContentUnavailableView("No snippets yet", systemImage: "scissors",
                                   description: Text("Add one with the + menu."))
        }
    }

    // MARK: - Row builders

    private func snippetGroupHeaderRow(_ group: SnippetGroup, count: Int) -> some View {
        groupHeaderRowView(
            id: group.id,
            isExpanded: !collapsedGroupIDs.contains(group.id) || searchIsActive,
            onToggleState: toggleGroupExpanded(_:),
            onClickState: { handleGroupClick(id: group.id, toggle: { toggleGroupExpanded(group.id) }) },
            icon: FolderIcon.systemName(for: group.iconName),
            label: group.name,
            count: count > 0 ? count : nil,
            contextMenuContent: {
                Button { createSnippet(in: group) } label: {
                    Label("New Snippet…", systemImage: "plus")
                }
                Divider()
                Button { snippetGroupEditTarget = group } label: {
                    Label("Edit…", systemImage: "pencil")
                }
                Button(role: .destructive) {
                    deleteSnippetGroup(group)
                } label: {
                    Label("Delete", systemImage: "trash")
                }
                .disabled(!(group.snippets ?? []).isEmpty)
            }
        )
    }

    private func snippetsUngroupedHeaderRow(count: Int) -> some View {
        groupHeaderRowView(
            id: Self.ungroupedID,
            isExpanded: !collapsedGroupIDs.contains(Self.ungroupedID) || searchIsActive,
            onToggleState: toggleGroupExpanded(_:),
            onClickState: { handleGroupClick(id: Self.ungroupedID, toggle: { toggleGroupExpanded(Self.ungroupedID) }) },
            icon: "tray",
            label: "Ungrouped",
            count: count > 0 ? count : nil,
            contextMenuContent: {
                Button { createSnippet(in: nil) } label: {
                    Label("New Snippet…", systemImage: "plus")
                }
            }
        )
    }

    private func toggleGroupExpanded(_ id: UUID) {
        SnippetGroupCollapseState.setGroup(id, expanded: collapsedGroupIDs.contains(id), in: &collapsedGroupIDs)
    }

    @ViewBuilder
    private func groupHeaderRowView<ContextMenu: View>(
        id: UUID,
        isExpanded: Bool,
        onToggleState: @escaping (UUID) -> Void,
        onClickState: @escaping () -> Void,
        icon: String,
        label: String,
        count: Int?,
        @ViewBuilder contextMenuContent: @escaping () -> ContextMenu
    ) -> some View {
        HStack(spacing: 4) {
            chevronButton(isExpanded: isExpanded) { onToggleState(id) }
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
                Text(label)
                    .lineLimit(1)
                Spacer()
                if let count {
                    Text("\(count)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .tag(id)
        .contentShape(Rectangle())
        .onTapGesture(perform: onClickState)
        .contextMenu(menuItems: contextMenuContent)
    }

    private func snippetRow(_ snippet: Snippet) -> some View {
        HStack {
            Image(systemName: snippet.isSecured ? "lock.doc" : "doc.text")
                .foregroundStyle(.secondary)
                .frame(width: 16)
            Text(snippet.name)
                .lineLimit(1)
            Spacer()
            if snippet.isSecured {
                Image(systemName: "lock.fill")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .tag(snippet.id)
        .contentShape(Rectangle())
        .onTapGesture { handleSnippetClick(snippet) }
        .contextMenu {
            Button {
                Task { await SnippetActions.paste(snippet, into: TerminalTabManager.shared.selectedTab) }
            } label: {
                Label("Paste to Active Terminal", systemImage: "arrow.right.doc.on.clipboard")
            }
            .disabled(TerminalTabManager.shared.selectedTab == nil)

            Button {
                Task { await SnippetActions.paste(snippet, into: TerminalTabManager.shared.selectedTab, appendReturn: true) }
            } label: {
                Label("Paste & Run", systemImage: "play.circle")
            }
            .disabled(TerminalTabManager.shared.selectedTab == nil)

            Button {
                Task { await SnippetActions.copy(snippet) }
            } label: {
                Label("Copy", systemImage: "doc.on.doc")
            }

            Divider()

            Button {
                openWindow(value: SnippetEditorSpec.edit(snippetID: snippet.id))
            } label: {
                Label("Edit…", systemImage: "pencil")
            }
            Button { duplicateSnippet(snippet) } label: {
                Label("Duplicate", systemImage: "plus.square.on.square")
            }
            Divider()
            Button(role: .destructive) {
                deleteSnippet(snippet)
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    // MARK: - Layout helpers

    @ViewBuilder
    private func chevronButton(isExpanded: Bool, onToggle: @escaping () -> Void) -> some View {
        Button {
            guard !searchIsActive else { return }
            onToggle()
        } label: {
            Image(systemName: "chevron.right")
                .rotationEffect(.degrees(isExpanded ? 90 : 0))
                .animation(.easeInOut(duration: 0.2), value: isExpanded)
                .foregroundStyle(.secondary)
                .frame(width: 12)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Click handling

    private func handleItemClick(id: UUID, onOpen: () -> Void) {
        let now = Date()
        let isSecondClick = lastClick?.id == id
            && now.timeIntervalSince(lastClick?.time ?? .distantPast) <= NSEvent.doubleClickInterval
        selectedID = id
        lastClick = (id, now)
        if isSecondClick {
            lastClick = nil
            onOpen()
        }
    }

    private func handleGroupClick(id: UUID, toggle: @escaping () -> Void) {
        handleItemClick(id: id) {
            guard !searchIsActive else { return }
            toggle()
        }
    }

    private func handleSnippetClick(_ snippet: Snippet) {
        handleItemClick(id: snippet.id) {
            Task { await SnippetActions.paste(snippet, into: TerminalTabManager.shared.selectedTab) }
        }
    }

    // MARK: - Search

    private func snippetSearchKeys(_ snippet: Snippet) -> [String] {
        var keys = [snippet.name]
        if !snippet.isSecured && !snippet.body.isEmpty {
            keys.append(snippet.body)
        }
        return keys
    }

    // MARK: - Mutations

    private func createSnippet(in group: SnippetGroup?) {
        guard let snippet = try? SnippetStore.createSnippet(name: "New Snippet", in: group, ctx: ctx) else { return }
        selectedID = snippet.id
        openWindow(value: SnippetEditorSpec.edit(snippetID: snippet.id))
    }

    private func newSnippetGroup() {
        guard let group = try? SnippetStore.createGroup(named: "New Group", in: ctx) else { return }
        snippetGroupEditTarget = group
    }

    private func duplicateSnippet(_ snippet: Snippet) {
        guard let dup = try? SnippetStore.duplicate(snippet, in: ctx) else { return }
        selectedID = dup.id
    }

    private func deleteSnippetGroup(_ group: SnippetGroup) {
        guard (group.snippets ?? []).isEmpty else { return }
        guard NSAlert.confirmation(
            title: "Delete Snippet Group?",
            message: "\"\(group.name)\" will be removed. This cannot be undone.",
            confirmTitle: "Delete Group"
        ) else { return }
        collapsedGroupIDs.remove(group.id)
        SnippetGroupCollapseState.save(collapsedGroupIDs)
        ctx.delete(group)
        try? ctx.save()
    }

    private func deleteSnippet(_ snippet: Snippet) {
        guard NSAlert.confirmation(
            title: "Delete Snippet?",
            message: "\"\(snippet.name)\" will be removed. This cannot be undone.",
            confirmTitle: "Delete Snippet"
        ) else { return }
        if snippet.id == selectedID { selectedID = nil }
        ctx.delete(snippet)
        try? ctx.save()
    }
}

// MARK: - Collapse state (separate from folder collapse state)

private enum SnippetGroupCollapseState {
    static let storageKey = "sidebar.collapsedSnippetGroupIDs"

    static func load() -> Set<UUID> {
        let values = UserDefaults.standard.stringArray(forKey: storageKey) ?? []
        return Set(values.compactMap(UUID.init(uuidString:)))
    }

    static func save(_ ids: Set<UUID>) {
        UserDefaults.standard.set(ids.map(\.uuidString).sorted(), forKey: storageKey)
    }

    static func setGroup(_ id: UUID, expanded: Bool, in collapsedIDs: inout Set<UUID>) {
        if expanded { collapsedIDs.remove(id) } else { collapsedIDs.insert(id) }
        save(collapsedIDs)
    }

    static func prune(_ collapsedIDs: inout Set<UUID>, keeping groupIDs: Set<UUID>) {
        let pruned = collapsedIDs.intersection(groupIDs)
        guard pruned != collapsedIDs else { return }
        collapsedIDs = pruned
        save(pruned)
    }
}

// MARK: - Snippet group editor sheet

private struct SnippetGroupEditorSheet: View {
    @Environment(\.modelContext) private var ctx
    @Environment(\.dismiss) private var dismiss

    let group: SnippetGroup
    let onClose: () -> Void

    @State private var name: String = ""
    @State private var iconName: String?
    @State private var didLoad = false

    var body: some View {
        Form {
            Section("Snippet Group") {
                HStack(alignment: .center, spacing: 12) {
                    Text("Name")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 128, alignment: .leading)
                    TextField("Group name", text: $name)
                        .textFieldStyle(.roundedBorder)
                        .controlSize(.regular)
                        .accessibilityLabel("Group name")
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                AppearanceIconPicker(
                    title: "Icon",
                    defaultSystemName: FolderIcon.fallback,
                    defaultHelp: "Default",
                    accessibilityLabel: "Group icon",
                    selection: $iconName
                )
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
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .onAppear { loadIfNeeded() }
    }

    private func loadIfNeeded() {
        guard !didLoad else { return }
        didLoad = true
        name = group.name
        iconName = group.iconName
    }

    private func save() {
        group.name = name.trimmingCharacters(in: .whitespaces)
        group.iconName = iconName
        try? ctx.save()
        close()
    }

    private func close() {
        onClose()
        dismiss()
    }
}
