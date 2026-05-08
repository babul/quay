import AppKit
import ComposableArchitecture
import SwiftData
import SwiftUI

struct ContentView: View {
    private static let terminalTabBarHeight: CGFloat = 37
    private static let sidebarAnimation = Animation.easeInOut(duration: 0.22)

    let store: StoreOf<AppFeature>
    @Environment(\.openWindow) private var openWindow
    @AppStorage(AppDefaultsKeys.autoHideSidebar) private var autoHideSidebar = true
    @State private var selectedConnectionID: UUID?
    @SceneStorage("rightSidebarOpen") private var rightSidebarOpen = false
    @State private var columnVisibility: NavigationSplitViewVisibility
    @State private var ghosttyConfigChangeToken = 0
    @State private var exportRequested = false
    @State private var importRequested = false
    @State private var searchQuery: String
    @State private var searchFocusTrigger = false
    @State private var mainWindow: NSWindow?
    @State private var isHoveringLeadingEdge = false
    @State private var isHoveringSidebar = false
    @State private var sidebarHideTask: Task<Void, Never>?
    private let tabManager = TerminalTabManager.shared

    init(store: StoreOf<AppFeature>) {
        self.store = store
        _columnVisibility = State(initialValue: Self.savedColumnVisibility)
        _searchQuery = State(initialValue: UserDefaults.standard.string(forKey: "sidebar.searchQuery") ?? "")
    }

    var body: some View {
        splitView
            .background(MainWindowCapture { mainWindow = $0 })
            .toolbar {
                ToolbarItem(placement: .principal) { toolbarSearchField }
                ToolbarItem(placement: .primaryAction) { newItemMenu }
                ToolbarItem(placement: .primaryAction) {
                    Button { rightSidebarOpen.toggle() } label: {
                        Image(systemName: "sidebar.right")
                    }
                    .help("Toggle Snippets Sidebar")
                }
            }
            .onAppear {
                store.send(.onAppear)
                restoreSavedSidebarVisibility()
            }
            .onReceive(NotificationCenter.default.publisher(for: .toggleSidebar)) { _ in
                let shouldShowSidebar = columnVisibility == .detailOnly
                withAnimation(Self.sidebarAnimation) {
                    columnVisibility = shouldShowSidebar ? .all : .detailOnly
                }
                SidebarLayoutState.saveSidebarVisible(shouldShowSidebar)
            }
            .onReceive(NotificationCenter.default.publisher(for: .connectionConnected)) { _ in
                guard autoHideSidebar else { return }
                withAnimation(Self.sidebarAnimation) { columnVisibility = .detailOnly }
            }
            .onReceive(NotificationCenter.default.publisher(for: .ghosttyRuntimeConfigDidChange)) { _ in
                ghosttyConfigChangeToken &+= 1
            }
            .onChange(of: columnVisibility) { _, visibility in
                guard !autoHideSidebar else { return }
                SidebarLayoutState.saveSidebarVisible(visibility != .detailOnly)
            }
            .onChange(of: tabManager.tabs.isEmpty) { _, isEmpty in
                guard autoHideSidebar, isEmpty else { return }
                withAnimation(Self.sidebarAnimation) { columnVisibility = .all }
            }
            .onChange(of: autoHideSidebar) { _, enabled in
                guard enabled, !tabManager.tabs.isEmpty else { return }
                withAnimation(Self.sidebarAnimation) { columnVisibility = .detailOnly }
            }
            .onReceive(NotificationCenter.default.publisher(for: .startExportSettings)) { _ in
                exportRequested = true
            }
            .onReceive(NotificationCenter.default.publisher(for: .startImportSettings)) { _ in
                importRequested = true
            }
            .onReceive(NotificationCenter.default.publisher(for: .focusSearch)) { _ in
                mainWindow?.makeKeyAndOrderFront(nil)
                searchFocusTrigger = true
            }
            .onReceive(NotificationCenter.default.publisher(for: .focusSearchSnippets)) { _ in
                mainWindow?.makeKeyAndOrderFront(nil)
                rightSidebarOpen = true
                DispatchQueue.main.async {
                    NotificationCenter.default.post(name: .focusSearchSnippets, object: "focus")
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .toggleSnippetsSidebar)) { _ in
                mainWindow?.makeKeyAndOrderFront(nil)
                rightSidebarOpen.toggle()
            }
            .onChange(of: searchQuery) { _, query in
                UserDefaults.standard.set(query, forKey: "sidebar.searchQuery")
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
                onCreateConnection: { openConnectionEditor(.create(folderID: $0?.id)) },
                onEditConnection: { openConnectionEditor(.edit($0)) }
            )
            .onHover { hovering in
                isHoveringSidebar = hovering
                guard !hovering, autoHideSidebar, !tabManager.tabs.isEmpty else { return }
                sidebarHideTask?.cancel()
                sidebarHideTask = Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(300))
                    guard !isHoveringSidebar, !isHoveringLeadingEdge else { return }
                    withAnimation(Self.sidebarAnimation) { columnVisibility = .detailOnly }
                }
            }
        } detail: {
            detail
                .overlay(alignment: .leading) {
                    if autoHideSidebar, columnVisibility == .detailOnly {
                        Color.clear
                            .frame(width: 6)
                            .onHover { hovering in
                                isHoveringLeadingEdge = hovering
                                if hovering {
                                    withAnimation(Self.sidebarAnimation) { columnVisibility = .all }
                                }
                            }
                    }
                }
                .inspector(isPresented: $rightSidebarOpen) {
                    SnippetSidebarView()
                        .inspectorColumnWidth(min: 240, ideal: 300, max: 480)
                }
        }
        .navigationTitle(tabManager.selectedTab?.displayTitle ?? "Quay")
    }

    private func openConnectionEditor(_ target: SidebarView.EditorTarget) {
        switch target {
        case .create(let folderID):
            openWindow(value: ConnectionEditorSpec.create(folderID: folderID))
        case .edit(let profile):
            openWindow(value: ConnectionEditorSpec.edit(profileID: profile.id))
        }
    }

    private static var savedColumnVisibility: NavigationSplitViewVisibility {
        let autoHide = UserDefaults.standard.object(forKey: AppDefaultsKeys.autoHideSidebar) as? Bool ?? true
        // When auto-hide is enabled, start with sidebar shown; manual visibility is managed by auto-hide logic
        if autoHide { return .all }
        // When disabled, respect saved preference
        return SidebarLayoutState.loadSidebarVisible() ? .all : .detailOnly
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
            FocusableTextField(
                text: $searchQuery,
                placeholder: "Search hosts (⌘L)",
                requestFocus: searchFocusTrigger,
                onDidFocus: { searchFocusTrigger = false }
            )
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
            Button("New Connection…") { openConnectionEditor(.create()) }
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
                    onEditConnection: { openConnectionEditor(.edit($0)) },
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

/// Plain NSTextField wrapper that can receive focus programmatically — needed because
/// SwiftUI's @FocusState doesn't reach into NSToolbar-hosted views on macOS.
private struct FocusableTextField: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    var requestFocus: Bool
    var onDidFocus: () -> Void

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.placeholderString = placeholder
        field.isBordered = false
        field.backgroundColor = .clear
        field.focusRingType = .none
        field.delegate = context.coordinator
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        if field.stringValue != text { field.stringValue = text }
        if requestFocus, field.window?.firstResponder !== field {
            DispatchQueue.main.async {
                field.window?.makeFirstResponder(field)
                onDidFocus()
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: FocusableTextField
        init(_ parent: FocusableTextField) { self.parent = parent }

        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSTextField else { return }
            parent.text = field.stringValue
        }
    }
}

/// Captures the NSWindow hosting this view so it can be made key programmatically.
private struct MainWindowCapture: NSViewRepresentable {
    let handler: (NSWindow?) -> Void

    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async { handler(v.window) }
        return v
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard context.coordinator.lastWindow !== nsView.window else { return }
        context.coordinator.lastWindow = nsView.window
        let window = nsView.window
        DispatchQueue.main.async { handler(window) }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        weak var lastWindow: NSWindow?
    }
}

#Preview {
    ContentView(store: Store(initialState: AppFeature.State()) { AppFeature() })
        .modelContainer(for: [Folder.self, ConnectionProfile.self, SnippetGroup.self, Snippet.self], inMemory: true)
}
