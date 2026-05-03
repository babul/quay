import SwiftData
import SwiftUI

/// The connection-tree sidebar.
///
/// v0.1 is intentionally simple: flat list of connections grouped by their
/// parent folder, with a search field at the top (⌘L). Real drag-to-reorder
/// + recursive folder nesting + context menus are v0.3 polish.
struct SidebarView: View {
    @Environment(\.modelContext) private var ctx

    @Query(sort: [SortDescriptor(\Folder.sortIndex), SortDescriptor(\Folder.name)])
    private var folders: [Folder]

    @Query(sort: [SortDescriptor(\ConnectionProfile.sortIndex), SortDescriptor(\ConnectionProfile.name)])
    private var allConnections: [ConnectionProfile]

    @Binding var selection: UUID?

    @State private var query: String = ""
    @State private var editorTarget: EditorTarget?
    @FocusState private var searchFocused: Bool

    enum EditorTarget: Identifiable {
        case create
        case edit(ConnectionProfile)
        var id: String {
            switch self {
            case .create: return "create"
            case .edit(let p): return "edit-\(p.id)"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            searchField
            Divider()
            list
            Divider()
            footer
        }
        .frame(minWidth: 240)
        .navigationTitle("Quay")
        .sheet(item: $editorTarget) { target in
            ConnectionEditor(target: target) {
                editorTarget = nil
            }
            .frame(minWidth: 480, minHeight: 420)
        }
    }

    private var filtered: [ConnectionProfile] {
        FuzzySearch.rank(allConnections, query: query) { profile in
            [profile.name, profile.hostname]
        }
    }

    private var searchField: some View {
        HStack {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search hosts (⌘L)", text: $query)
                .textFieldStyle(.plain)
                .focused($searchFocused)
                .onAppear {
                    NotificationCenter.default.addObserver(
                        forName: .focusSearch, object: nil, queue: .main
                    ) { _ in searchFocused = true }
                }
            if !query.isEmpty {
                Button {
                    query = ""
                    searchFocused = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var list: some View {
        List(selection: $selection) {
            if query.isEmpty {
                groupedByFolder
            } else {
                ForEach(filtered, id: \.id) { profile in
                    connectionRow(profile)
                }
            }
        }
        .listStyle(.sidebar)
    }

    @ViewBuilder
    private var groupedByFolder: some View {
        let grouped: [(Folder?, [ConnectionProfile])] = {
            // Group connections by folder, preserving folder sort order.
            var byFolder: [UUID: [ConnectionProfile]] = [:]
            var unfiled: [ConnectionProfile] = []
            for c in allConnections {
                if let f = c.parent {
                    byFolder[f.id, default: []].append(c)
                } else {
                    unfiled.append(c)
                }
            }
            var out: [(Folder?, [ConnectionProfile])] = []
            for f in folders {
                if let cs = byFolder[f.id], !cs.isEmpty {
                    out.append((f, cs))
                }
            }
            if !unfiled.isEmpty { out.append((nil, unfiled)) }
            return out
        }()

        if grouped.isEmpty {
            Text("No connections yet")
                .foregroundStyle(.secondary)
                .padding(.vertical, 8)
        } else {
            ForEach(grouped, id: \.0?.id) { folder, items in
                Section(folder?.name ?? "Other") {
                    ForEach(items, id: \.id) { connectionRow($0) }
                }
            }
        }
    }

    private func connectionRow(_ profile: ConnectionProfile) -> some View {
        HStack {
            Image(systemName: "terminal.fill")
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 0) {
                Text(profile.name)
                Text(profile.sshTarget?.hostname ?? profile.hostname)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .tag(profile.id)
        .contextMenu {
            Button("Edit…") { editorTarget = .edit(profile) }
            Button("Delete", role: .destructive) {
                ctx.delete(profile)
            }
        }
    }

    private var footer: some View {
        HStack {
            Menu {
                Button("New Connection…") { editorTarget = .create }
                Button("New Folder") { newFolder() }
            } label: {
                Image(systemName: "plus")
            }
            .menuStyle(.borderlessButton)
            .frame(width: 28)
            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }

    private func newFolder() {
        let nextIdx = (folders.map(\.sortIndex).max() ?? -1) + 1
        ctx.insert(Folder(name: "New Folder", sortIndex: nextIdx))
    }
}

extension Notification.Name {
    /// Posted by the ⌘L menu command to focus the sidebar's search field.
    static let focusSearch = Notification.Name("com.montopolis.quay.focusSearch")
}
