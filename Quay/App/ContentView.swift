import AppKit
import ComposableArchitecture
import SwiftData
import SwiftUI

struct ContentView: View {
    private static let terminalTabBarHeight: CGFloat = 37

    let store: StoreOf<AppFeature>
    @State private var selectedConnectionID: UUID?
    @State private var columnVisibility: NavigationSplitViewVisibility
    @State private var editorTarget: SidebarView.EditorTarget?
    @State private var ghosttyConfigChangeToken = 0
    @State private var exportRequested = false
    @State private var importRequested = false
    @State private var searchQuery: String
    @FocusState private var toolbarSearchFocused: Bool
    private let tabManager = TerminalTabManager.shared

    init(store: StoreOf<AppFeature>) {
        self.store = store
        _columnVisibility = State(initialValue: Self.savedColumnVisibility)
        _searchQuery = State(initialValue: UserDefaults.standard.string(forKey: "sidebar.searchQuery") ?? "")
    }

    var body: some View {
        splitView
            .toolbar {
                ToolbarItem(placement: .principal) { toolbarSearchField }
                ToolbarItem(placement: .primaryAction) { newItemMenu }
            }
            .onAppear {
                store.send(.onAppear)
                restoreSavedSidebarVisibility()
            }
            .onReceive(NotificationCenter.default.publisher(for: .toggleSidebar)) { _ in
                let shouldShowSidebar = columnVisibility == .detailOnly
                columnVisibility = shouldShowSidebar ? .all : .detailOnly
                SidebarLayoutState.saveSidebarVisible(shouldShowSidebar)
            }
            .onReceive(NotificationCenter.default.publisher(for: .ghosttyRuntimeConfigDidChange)) { _ in
                ghosttyConfigChangeToken &+= 1
            }
            .onChange(of: columnVisibility) { _, visibility in
                SidebarLayoutState.saveSidebarVisible(visibility != .detailOnly)
            }
            .onReceive(NotificationCenter.default.publisher(for: .startExportSettings)) { _ in
                exportRequested = true
            }
            .onReceive(NotificationCenter.default.publisher(for: .startImportSettings)) { _ in
                importRequested = true
            }
            .onReceive(NotificationCenter.default.publisher(for: .focusSearch)) { _ in
                toolbarSearchFocused = true
            }
            .onChange(of: searchQuery) { _, query in
                UserDefaults.standard.set(query, forKey: "sidebar.searchQuery")
            }
            .sheet(item: $editorTarget) { target in
                ConnectionEditor(target: target) { editorTarget = nil }
            }
            .settingsImportExportFlow(
                triggerExport: $exportRequested,
                triggerImport: $importRequested
            )
    }

    private var splitView: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView(
                searchQuery: $searchQuery,
                selection: $selectedConnectionID,
                onOpenConnectionInNewTab: { tabManager.openNewTab(for: $0) },
                onOpenSFTPConnection: { tabManager.openSFTPTab(for: $0) },
                onCreateConnection: { editorTarget = .create(folderID: $0?.id) },
                onEditConnection: { editorTarget = .edit($0) }
            )
        } detail: {
            detail
        }
        .navigationTitle(tabManager.selectedTab?.displayTitle ?? "Quay")
    }

    private static var savedColumnVisibility: NavigationSplitViewVisibility {
        SidebarLayoutState.loadSidebarVisible() ? .all : .detailOnly
    }

    private func restoreSavedSidebarVisibility() {
        scheduleAfterSwiftUILayout {
            self.columnVisibility = Self.savedColumnVisibility
        }
    }

    private var toolbarSearchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .imageScale(.small)
            TextField("Search connections (⌘L)", text: $searchQuery)
                .textFieldStyle(.plain)
                .focused($toolbarSearchFocused)
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
        .frame(minWidth: 180, maxWidth: 300)
    }

    private var newItemMenu: some View {
        Menu {
            Button("New Connection…") { editorTarget = .create() }
            Button("New Group Folder") {
                NotificationCenter.default.post(name: .createFolder, object: nil)
            }
        } label: {
            Image(systemName: "plus")
        }
        .help("New…")
    }

    @ViewBuilder
    private var detail: some View {
        if tabManager.tabs.isEmpty {
            ContentUnavailableView {
                Label("Pick a connection", systemImage: "terminal")
            } description: {
                Text("Or hit ⌘L to search.")
            }
        } else {
            VStack(spacing: 0) {
                TerminalTabBar(
                    tabManager: tabManager,
                    onEditConnection: { profile in
                        editorTarget = .edit(profile)
                    },
                    onOpenSFTP: { tab in
                        tabManager.openSFTPTab(
                            for: tab.profile,
                            localDirectoryOverride: tab.currentWorkingDirectory
                        )
                    }
                )
                .frame(height: Self.terminalTabBarHeight - 1)
                Divider()
                tabSurfaces
            }
        }
    }

    private var tabSurfaces: some View {
        ZStack {
            terminalBackgroundColor

            // Single container that keeps every surface view as a direct NSView
            // subview at all times. Visibility is toggled via isHidden rather
            // than removing from the hierarchy, so libghostty never loses its
            // render target and background sessions stay alive.
            TerminalSurfaceHostsView(
                tabs: tabManager.tabs,
                selectedTabID: tabManager.selectedTabID,
                backgroundColor: selectedTerminalBackgroundColor,
                backgroundOpacity: selectedTerminalBackgroundOpacity
            )

            // Status overlay for the selected tab only.
            if let tab = tabManager.selectedTab {
                statusOverlay(for: tab)
            }
        }
        .background(terminalBackgroundColor)
        .background(
            TerminalWindowBackgroundSync(
                color: selectedTerminalBackgroundColor,
                opacity: selectedTerminalBackgroundOpacity
            )
        )
    }

    private var selectedTerminalBackgroundColor: NSColor {
        // Force SwiftUI to re-evaluate when the Ghostty config changes.
        // GhosttyRuntime.config is not @Observable, so we use a token that
        // is incremented via notification and read here to create a dependency.
        _ = ghosttyConfigChangeToken
        return tabManager.selectedTab?.terminalBackgroundColor
            ?? GhosttyResolvedAppearance.backgroundColor(from: GhosttyRuntime.shared.config)
    }

    private var selectedTerminalBackgroundOpacity: Double {
        _ = ghosttyConfigChangeToken
        return tabManager.selectedTab?.terminalBackgroundOpacity
            ?? GhosttyResolvedAppearance.backgroundOpacity(from: GhosttyRuntime.shared.config)
    }

    private var terminalBackgroundColor: Color {
        Color(nsColor: selectedTerminalBackgroundColor)
            .opacity(selectedTerminalBackgroundOpacity)
    }

    @ViewBuilder
    private func statusOverlay(for tab: TerminalTabItem) -> some View {
        switch tab.phase {
        case .idle:
            terminalBackgroundColor
        case .starting:
            terminalBackgroundColor
                .overlay { ProgressView("Connecting…") }
        case .running:
            EmptyView()
        case .disconnected:
            EmptyView()
        case .failed(let message):
            terminalBackgroundColor
                .overlay {
                    ContentUnavailableView {
                        Label("Connection lost", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(message)
                    } actions: {
                        Button("Reconnect") { tab.reconnect() }
                            .keyboardShortcut(.return, modifiers: .command)
                    }
                }
        }
    }
}

private struct TerminalWindowBackgroundSync: NSViewRepresentable {
    let color: NSColor
    let opacity: Double

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        view.isHidden = true
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let window = nsView.window else { return }
        window.isOpaque = GhosttyResolvedAppearance.isOpaque(opacity)
        window.backgroundColor = GhosttyResolvedAppearance.color(color, with: opacity)
    }
}

/// Manages all live `GhosttySurfaceView` instances as direct NSView subviews
/// of a single container. The selected surface is ordered frontmost instead of
/// hiding non-selected Metal-backed views, avoiding synchronous renderer churn
/// during tab switching while keeping background sessions attached.
private struct TerminalSurfaceHostsView: NSViewRepresentable {
    let tabs: [TerminalTabItem]
    let selectedTabID: UUID?
    let backgroundColor: NSColor
    let backgroundOpacity: Double

    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        v.wantsLayer = true
        return v
    }

    func updateNSView(_ container: NSView, context: Context) {
        container.layer?.backgroundColor = GhosttyResolvedAppearance
            .color(backgroundColor, with: backgroundOpacity)
            .cgColor

        let existing = container.subviews.compactMap { $0 as? GhosttySurfaceView }
        let existingIDs = Set(existing.map { ObjectIdentifier($0) })

        // Add surface views for tabs not yet in the container.
        for tab in tabs {
            guard let sv = tab.surfaceView,
                  !existingIDs.contains(ObjectIdentifier(sv)) else { continue }
            sv.frame = container.bounds
            sv.autoresizingMask = [.width, .height]
            container.addSubview(sv)
        }

        // Remove surface views whose tabs have been closed.
        let activeIDs = Set(tabs.compactMap { $0.surfaceView }.map { ObjectIdentifier($0) })
        for sv in existing where !activeIDs.contains(ObjectIdentifier(sv)) {
            sv.removeFromSuperview()
        }

        let selectedSurface = tabs.first(where: { $0.id == selectedTabID })?.surfaceView
        for sv in container.subviews {
            sv.isHidden = false
        }

        if let selectedSurface {
            container.addSubview(selectedSurface, positioned: .above, relativeTo: nil)
        }

        // Transfer first-responder after AppKit has settled the subview order
        // changes for this update pass.
        if let selectedSurface, container.window?.firstResponder !== selectedSurface {
            DispatchQueue.main.async { [weak selectedSurface] in
                guard let selectedSurface,
                      selectedSurface.window?.firstResponder !== selectedSurface else { return }
                selectedSurface.window?.makeFirstResponder(selectedSurface)
            }
        }
    }
}

#Preview {
    ContentView(store: Store(initialState: AppFeature.State()) { AppFeature() })
        .modelContainer(for: [Folder.self, ConnectionProfile.self], inMemory: true)
}
