import AppKit
import Darwin
import Foundation
import SwiftData
import SwiftUI

/// The connection-tree sidebar.
///
/// v0.1 is intentionally simple: flat groups of connections with a search
/// field at the top (⌘L). Real drag-to-reorder + recursive folder nesting are
/// v0.3 polish.
struct SidebarView: View {
    @Environment(\.modelContext) private var ctx

    @Query(sort: [SortDescriptor(\Folder.sortIndex), SortDescriptor(\Folder.name)])
    private var folders: [Folder]

    @Query(sort: [SortDescriptor(\ConnectionProfile.sortIndex), SortDescriptor(\ConnectionProfile.name)])
    private var allConnections: [ConnectionProfile]

    @Binding var selection: UUID?
    var onOpenConnection: (ConnectionProfile) -> Void = { _ in }
    var onOpenConnectionInNewTab: (ConnectionProfile) -> Void = { _ in }
    var onCreateConnection: () -> Void = {}
    var onEditConnection: (ConnectionProfile) -> Void = { _ in }

    @State private var query: String = ""
    @State private var groupEditTarget: Folder?
    @State private var collapsedFolderIDs = SidebarCollapseState.load()
    @State private var lastConnectionClick: (id: UUID, time: Date)?
    @State private var discoveredSSHHosts: [DiscoveredSSHHost] = []
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
            identityHeader
            Divider()
            searchField
            Divider()
            list
            Divider()
            footer
        }
        .frame(minWidth: 240)
        .navigationSplitViewColumnWidth(
            min: SidebarLayoutState.minimumWidth,
            ideal: SidebarLayoutState.loadWidth(),
            max: SidebarLayoutState.maximumWidth
        )
        .background(SidebarWidthObserver())
        .navigationTitle("Quay")
        .sheet(isPresented: groupEditorIsPresented) {
            if let groupEditTarget {
                GroupEditor(folder: groupEditTarget) {
                    self.groupEditTarget = nil
                }
                .frame(minWidth: 440, minHeight: 220)
            }
        }
        .onAppear {
            bootstrapFolders()
            refreshDiscoveredSSHHosts()
        }
        .onChange(of: folders.map(\.id)) { _, ids in
            SidebarCollapseState.prune(
                &collapsedFolderIDs,
                keeping: Set(ids)
            )
        }
    }

    private var identityHeader: some View {
        HStack(spacing: 9) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 24, height: 24)
                .cornerRadius(5)

            VStack(alignment: .leading, spacing: 1) {
                Text("Quay")
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Text(localHostname)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var filtered: [ConnectionProfile] {
        FuzzySearch.rank(allConnections, query: query) { profile in
            [profile.name, profile.hostname]
        }
    }

    private var visibleDiscoveredSSHHosts: [DiscoveredSSHHost] {
        let savedAliases = Set(
            allConnections.compactMap { profile -> String? in
                guard profile.authMethod == .sshConfigAlias,
                      let alias = profile.sshConfigAlias,
                      !alias.isEmpty
                else { return nil }
                return alias.lowercased()
            }
        )
        return discoveredSSHHosts.filter { !savedAliases.contains($0.alias.lowercased()) }
    }

    private var filteredDiscoveredSSHHosts: [DiscoveredSSHHost] {
        FuzzySearch.rank(visibleDiscoveredSSHHosts, query: query) { host in
            [host.displayName, host.alias]
        }
    }

    private var topLevelFolders: [Folder] {
        folders.filter { $0.parent == nil }
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
                    ) { _ in
                        Task { @MainActor in
                            searchFocused = true
                        }
                    }
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
                sshConfigHostsSection
            } else {
                ForEach(filtered, id: \.id) { profile in
                    connectionRow(profile)
                }
                ForEach(filteredDiscoveredSSHHosts, id: \.id) { host in
                    sshConfigHostRow(host)
                }
            }
        }
        .listStyle(.sidebar)
    }

    @ViewBuilder
    private var groupedByFolder: some View {
        let grouped: [(Folder, [ConnectionProfile])] = {
            // Group connections by folder, preserving folder sort order.
            var byFolder: [UUID: [ConnectionProfile]] = [:]
            for c in allConnections {
                if let f = c.parent {
                    byFolder[f.id, default: []].append(c)
                }
            }
            var out: [(Folder, [ConnectionProfile])] = []
            for f in topLevelFolders {
                let items = byFolder[f.id] ?? []
                if shouldHideFolder(f, connectionCount: items.count) {
                    continue
                }
                out.append((f, items))
            }
            return out
        }()

        if grouped.isEmpty {
            Text("No groups yet")
                .foregroundStyle(.secondary)
                .padding(.vertical, 8)
        } else {
            ForEach(grouped, id: \.0.id) { folder, items in
                DisclosureGroup(isExpanded: folderIsExpandedBinding(folder)) {
                    ForEach(items, id: \.id) { connectionRow($0) }
                } label: {
                    folderLabel(folder, count: items.count)
                        .contextMenu { folderContextMenu(folder) }
                }
            }
        }
    }

    private func shouldHideFolder(_ folder: Folder, connectionCount: Int) -> Bool {
        folder.name == FolderStore.defaultFolderName && connectionCount == 0
    }

    private func folderLabel(_ folder: Folder, count: Int) -> some View {
        HStack(spacing: 6) {
            Image(systemName: FolderIcon.systemName(for: folder.iconName))
                .foregroundStyle(.secondary)
                .frame(width: 16)
            Text(folder.name)
                .lineLimit(1)
            Spacer()
            if count > 0 {
                Text("\(count)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func folderContextMenu(_ folder: Folder) -> some View {
        Button("Edit…") { beginEditingGroup(folder) }
        Button("Delete", role: .destructive) {
            deleteFolder(folder)
        }
        .disabled(folder.name == FolderStore.defaultFolderName
            || !folder.connections.isEmpty
            || !folder.children.isEmpty)
    }

    private func connectionRow(_ profile: ConnectionProfile) -> some View {
        HStack {
            Image(systemName: ConnectionIcon.systemName(for: profile.iconName))
                .foregroundStyle(ConnectionColor.color(for: profile.colorTag) ?? Color.accentColor)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 0) {
                Text(profile.name)
                if let subtitle = SidebarDisplayText.connectionSubtitle(for: profile) {
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .tag(profile.id)
        .contentShape(Rectangle())
        .onTapGesture { handleConnectionClick(profile) }
        .contextMenu {
            Button("Connect New Tab") {
                selection = profile.id
                onOpenConnectionInNewTab(profile)
            }
            Button("Edit…") { onEditConnection(profile) }
            Button("Duplicate") { duplicateConnection(profile) }
            Button("Delete", role: .destructive) {
                ctx.delete(profile)
            }
        }
    }

    @ViewBuilder
    private var sshConfigHostsSection: some View {
        if !visibleDiscoveredSSHHosts.isEmpty {
            DisclosureGroup {
                ForEach(visibleDiscoveredSSHHosts, id: \.id) { host in
                    sshConfigHostRow(host)
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "terminal")
                        .foregroundStyle(.secondary)
                        .frame(width: 16)
                    Text("SSH Config")
                        .lineLimit(1)
                    Spacer()
                    Text("\(visibleDiscoveredSSHHosts.count)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func sshConfigHostRow(_ host: DiscoveredSSHHost) -> some View {
        HStack {
            Image(systemName: "terminal")
                .foregroundStyle(.secondary)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 0) {
                Text(SidebarDisplayText.sshConfigHostTitle(for: host))
                Text("~/.ssh/config")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .tag(host.id)
        .contentShape(Rectangle())
        .onTapGesture { handleSSHConfigHostClick(host) }
        .contextMenu {
            Button("Connect New Tab") {
                selection = host.id
                onOpenConnectionInNewTab(transientProfile(for: host))
            }
            Button("Save as Quay Connection") {
                saveSSHConfigHost(host)
            }
            Button("Save and Edit…") {
                saveSSHConfigHost(host, editAfterSave: true)
            }
        }
        .help(sshConfigHostHelp(host))
    }

    private func handleConnectionClick(_ profile: ConnectionProfile) {
        let now = Date()
        let isSecondClick = lastConnectionClick?.id == profile.id
            && now.timeIntervalSince(lastConnectionClick?.time ?? .distantPast) <= NSEvent.doubleClickInterval

        selection = profile.id
        lastConnectionClick = (profile.id, now)

        if isSecondClick {
            lastConnectionClick = nil
            onOpenConnection(profile)
        }
    }

    private func handleSSHConfigHostClick(_ host: DiscoveredSSHHost) {
        let now = Date()
        let isSecondClick = lastConnectionClick?.id == host.id
            && now.timeIntervalSince(lastConnectionClick?.time ?? .distantPast) <= NSEvent.doubleClickInterval

        selection = host.id
        lastConnectionClick = (host.id, now)

        if isSecondClick {
            lastConnectionClick = nil
            onOpenConnection(transientProfile(for: host))
        }
    }

    private func transientProfile(for host: DiscoveredSSHHost) -> ConnectionProfile {
        ConnectionProfile(
            id: host.id,
            name: host.displayName,
            hostname: host.alias,
            authMethod: .sshConfigAlias,
            sshConfigAlias: host.alias
        )
    }

    private func sshConfigHostHelp(_ host: DiscoveredSSHHost) -> String {
        if let lineNumber = host.lineNumber {
            return "\(host.sourceFile):\(lineNumber)"
        }
        return host.sourceFile
    }

    private func saveSSHConfigHost(_ host: DiscoveredSSHHost, editAfterSave: Bool = false) {
        guard let profile = try? FolderStore.saveSSHConfigHost(host, in: ctx) else {
            return
        }
        selection = profile.id
        if editAfterSave {
            onEditConnection(profile)
        }
    }

    private var footer: some View {
        HStack {
            Menu {
                Button("New Connection…") { onCreateConnection() }
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
        let existingNames = Set(topLevelFolders.map(\.name))
        let folder = Folder(
            name: FolderStore.uniqueFolderName(
                baseName: "New Folder",
                existingNames: existingNames
            ),
            sortIndex: FolderStore.nextFolderSortIndex(from: topLevelFolders)
        )
        ctx.insert(folder)
        try? ctx.save()
        beginEditingGroup(folder)
    }

    private func folderIsExpandedBinding(_ folder: Folder) -> Binding<Bool> {
        Binding {
            !collapsedFolderIDs.contains(folder.id)
        } set: { isExpanded in
            SidebarCollapseState.setFolder(
                folder.id,
                expanded: isExpanded,
                in: &collapsedFolderIDs
            )
        }
    }

    private var groupEditorIsPresented: Binding<Bool> {
        Binding {
            groupEditTarget != nil
        } set: { isPresented in
            if !isPresented {
                groupEditTarget = nil
            }
        }
    }

    private func beginEditingGroup(_ folder: Folder) {
        groupEditTarget = folder
    }

    private func deleteFolder(_ folder: Folder) {
        guard folder.name != FolderStore.defaultFolderName,
              folder.connections.isEmpty,
              folder.children.isEmpty
        else { return }
        collapsedFolderIDs.remove(folder.id)
        SidebarCollapseState.save(collapsedFolderIDs)
        ctx.delete(folder)
        try? ctx.save()
    }

    private func duplicateConnection(_ profile: ConnectionProfile) {
        guard let duplicate = try? FolderStore.duplicateConnection(profile, in: ctx) else {
            return
        }
        selection = duplicate.id
    }

    private func bootstrapFolders() {
        try? FolderStore.bootstrapDefaultFolder(in: ctx)
    }

    private func refreshDiscoveredSSHHosts() {
        discoveredSSHHosts = SSHConfigHostProvider.loadHosts()
    }

    private var localHostname: String {
        Host.current().localizedName ?? ProcessInfo.processInfo.hostName
    }
}

enum SidebarDisplayText {
    static func connectionSubtitle(for profile: ConnectionProfile) -> String? {
        if profile.authMethod == .sshConfigAlias {
            return redactedHost(profile.sshConfigAlias ?? profile.hostname)
        }

        return redactedHost(profile.sshTarget?.hostname ?? profile.hostname)
    }

    static func sshConfigHostTitle(for host: DiscoveredSSHHost) -> String {
        redactedHost(host.displayName) ?? "SSH Config Host"
    }

    static func redactedHost(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return isIPAddress(trimmed) ? nil : trimmed
    }

    static func isIPAddress(_ value: String) -> Bool {
        var candidate = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if candidate.hasPrefix("["), candidate.hasSuffix("]") {
            candidate = String(candidate.dropFirst().dropLast())
        }
        if let zoneIndex = candidate.firstIndex(of: "%") {
            candidate = String(candidate[..<zoneIndex])
        }

        var ipv4 = in_addr()
        if candidate.withCString({ inet_pton(AF_INET, $0, &ipv4) }) == 1 {
            return true
        }

        var ipv6 = in6_addr()
        return candidate.withCString { inet_pton(AF_INET6, $0, &ipv6) } == 1
    }
}

private struct GroupEditor: View {
    @Environment(\.modelContext) private var ctx
    @Environment(\.dismiss) private var dismiss

    let folder: Folder
    let onClose: () -> Void

    @State private var name: String = ""
    @State private var iconName: String?
    @State private var didLoad = false

    var body: some View {
        Form {
            Section("Group") {
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
                    .disabled(!canSave)
            }
        }
        .onAppear { loadIfNeeded() }
    }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func loadIfNeeded() {
        guard !didLoad else { return }
        didLoad = true
        name = folder.name
        iconName = folder.iconName
    }

    private func save() {
        folder.name = name.trimmingCharacters(in: .whitespaces)
        folder.iconName = iconName
        try? ctx.save()
        close()
    }

    private func close() {
        onClose()
        dismiss()
    }
}

extension Notification.Name {
    /// Posted by the ⌘L menu command to focus the sidebar's search field.
    static let focusSearch = Notification.Name("com.montopolis.quay.focusSearch")
    /// Posted by the ⌘B menu command to show or hide the sidebar.
    static let toggleSidebar = Notification.Name("com.montopolis.quay.toggleSidebar")
}

@MainActor
private struct SidebarWidthObserver: NSViewRepresentable {
    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        view.isHidden = true
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.attach(from: view)
    }

    @MainActor
    final class Coordinator {
        private weak var splitView: NSSplitView?
        private var frameObserver: NSObjectProtocol?
        private var isRestoringWidth = false

        func attach(from view: NSView) {
            Task { @MainActor [weak self, weak view] in
                guard let self, let view, let splitView = view.enclosingSplitView else { return }
                guard self.splitView !== splitView else { return }

                self.detach()
                self.splitView = splitView
                self.restoreWidth(in: splitView)
                self.observeSidebarFrame(in: splitView)
            }
        }

        private func detach() {
            if let frameObserver {
                NotificationCenter.default.removeObserver(frameObserver)
            }
            frameObserver = nil
            splitView = nil
        }

        private func restoreWidth(in splitView: NSSplitView) {
            guard SidebarLayoutState.loadSidebarVisible(),
                  splitView.arrangedSubviews.count > 1
            else { return }

            isRestoringWidth = true
            Task { @MainActor [weak self, weak splitView] in
                guard let self, let splitView else { return }
                await Task.yield()
                splitView.setPosition(SidebarLayoutState.loadWidth(), ofDividerAt: 0)

                try? await Task.sleep(for: .milliseconds(100))
                self.isRestoringWidth = false
            }
        }

        private func observeSidebarFrame(in splitView: NSSplitView) {
            guard let sidebarView = splitView.arrangedSubviews.first else { return }

            sidebarView.postsFrameChangedNotifications = true
            frameObserver = NotificationCenter.default.addObserver(
                forName: NSView.frameDidChangeNotification,
                object: sidebarView,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self, weak sidebarView] in
                    guard let self,
                          let sidebarView,
                          !self.isRestoringWidth
                    else { return }

                    SidebarLayoutState.saveWidth(sidebarView.frame.width)
                }
            }
        }
    }
}

private extension NSView {
    var enclosingSplitView: NSSplitView? {
        if let splitView = self as? NSSplitView {
            return splitView
        }
        return superview?.enclosingSplitView
    }
}
