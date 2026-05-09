import AppKit
import ComposableArchitecture
import SwiftData
import SwiftUI

struct ContentView: View {
    private static let terminalTabBarHeight: CGFloat = 37
    private static let splitViewAnimation = Animation.easeInOut(duration: 0.22)

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
    @State private var hoverController = SidebarHoverController()
    @State private var rightSidebarWidth = SidebarLayoutState.loadRightWidth()
    private let tabManager = TerminalTabManager.shared

    init(store: StoreOf<AppFeature>) {
        self.store = store
        _columnVisibility = State(initialValue: Self.savedColumnVisibility)
        _searchQuery = State(initialValue: UserDefaults.standard.string(forKey: SidebarLayoutState.searchQueryStorageKey) ?? "")
    }

    var body: some View {
        Group {
            rootContent
                .background(MainWindowCapture { mainWindow = $0 })
                .toolbar { toolbarContent }
                .onAppear { onAppear() }
                .onReceive(NotificationCenter.default.publisher(for: .toggleSidebar)) { _ in onToggleSidebar() }
                .onReceive(NotificationCenter.default.publisher(for: .connectionConnected)) { _ in onConnectionConnected() }
                .onReceive(NotificationCenter.default.publisher(for: .ghosttyRuntimeConfigDidChange)) { _ in ghosttyConfigChangeToken &+= 1 }
        }
        .onChange(of: columnVisibility) { _, visibility in
            guard !autoHideSidebar else { return }
            SidebarLayoutState.saveSidebarVisible(visibility != .detailOnly)
        }
        .onChange(of: tabManager.tabs.isEmpty) { _, isEmpty in onTabsEmptyChanged(isEmpty) }
        .onChange(of: autoHideSidebar) { _, enabled in onAutoHideChanged(enabled) }
        .onChange(of: mainWindow) { _, window in onMainWindowChanged(window) }
        .onChange(of: rightSidebarOpen) { _, open in hoverController.rightSidebarOpen = open }
        .onChange(of: rightSidebarWidth) { _, w in hoverController.rightSidebarWidth = w }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { note in
            guard (note.object as? NSWindow) === mainWindow else { return }
            hoverController.windowDidResignKey()
        }
        .onReceive(NotificationCenter.default.publisher(for: .startExportSettings)) { _ in exportRequested = true }
        .onReceive(NotificationCenter.default.publisher(for: .startImportSettings)) { _ in importRequested = true }
        .onReceive(NotificationCenter.default.publisher(for: .focusSearch)) { _ in onFocusSearch() }
        .onReceive(NotificationCenter.default.publisher(for: .focusSearchSnippets)) { _ in onFocusSearchSnippets() }
        .onReceive(NotificationCenter.default.publisher(for: .toggleSnippetsSidebar)) { _ in
            mainWindow?.makeKeyAndOrderFront(nil)
            rightSidebarOpen.toggle()
        }
        .onChange(of: searchQuery) { _, query in
            UserDefaults.standard.set(query, forKey: SidebarLayoutState.searchQueryStorageKey)
        }
        .settingsImportExportFlow(triggerExport: $exportRequested, triggerImport: $importRequested)
    }

    // MARK: - Event handlers

    private func onAppear() {
        store.send(.onAppear)
        restoreSavedSidebarVisibility()
        hoverController.setTabsEmpty(tabManager.tabs.isEmpty)
    }

    private func onToggleSidebar() {
        if autoHideSidebar {
            hoverController.manualToggle()
        } else {
            guard !tabManager.tabs.isEmpty else { return }
            let shouldShow = columnVisibility == .detailOnly
            withAnimation(Self.splitViewAnimation) {
                columnVisibility = shouldShow ? .all : .detailOnly
            }
            SidebarLayoutState.saveSidebarVisible(shouldShow)
        }
    }

    private func onConnectionConnected() {
        if autoHideSidebar {
            hoverController.connectionDidConnect()
        } else {
            withAnimation(Self.splitViewAnimation) { columnVisibility = .detailOnly }
        }
    }

    private func onTabsEmptyChanged(_ isEmpty: Bool) {
        if autoHideSidebar {
            hoverController.setTabsEmpty(isEmpty)
        } else if isEmpty {
            withAnimation(Self.splitViewAnimation) { columnVisibility = .all }
        }
    }

    private func onAutoHideChanged(_ enabled: Bool) {
        hoverController.setAutoHide(enabled)
        if !enabled, !tabManager.tabs.isEmpty {
            withAnimation(Self.splitViewAnimation) { columnVisibility = .detailOnly }
        }
    }

    private func onMainWindowChanged(_ window: NSWindow?) {
        if let window { hoverController.start(mainWindow: window) }
        else { hoverController.stop() }
    }

    private func onFocusSearch() {
        mainWindow?.makeKeyAndOrderFront(nil)
        searchFocusTrigger = true
    }

    private func onFocusSearchSnippets() {
        mainWindow?.makeKeyAndOrderFront(nil)
        rightSidebarOpen = true
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .focusSearchSnippets, object: "focus")
        }
    }

    // MARK: - Root layout

    @ViewBuilder
    private var rootContent: some View {
        ZStack(alignment: .top) {
            if autoHideSidebar {
                overlayLeftAndDetail
            } else {
                navigationSplitLayout
            }
            rightSidebarOverlay
        }
    }

    private var rightSidebarOverlay: some View {
        OverlaySidebarContainer(
            isVisible: rightSidebarOpen,
            width: rightSidebarWidth,
            edge: .trailing
        ) {
            SnippetSidebarView()
        } edgeHandle: {
            SidebarResizeHandle(
                edge: .trailing,
                width: $rightSidebarWidth,
                range: SidebarLayoutState.rightMinimumWidth...SidebarLayoutState.rightMaximumWidth,
                onCommit: { SidebarLayoutState.saveRightWidth($0) }
            )
        }
    }

    private var overlayLeftAndDetail: some View {
        ZStack(alignment: .top) {
            detail
            OverlaySidebarContainer(
                isVisible: hoverController.isVisible,
                width: hoverController.width,
                edge: .leading
            ) {
                sidebarView
            } edgeHandle: {
                SidebarResizeHandle(
                    edge: .leading,
                    width: $hoverController.width,
                    range: SidebarLayoutState.minimumWidth...SidebarLayoutState.maximumWidth,
                    onCommit: { SidebarLayoutState.saveWidth($0) }
                )
            }
        }
        .onContinuousHover(coordinateSpace: .local) { phase in
            switch phase {
            case .active(let location): hoverController.cursorMoved(localX: location.x)
            case .ended: hoverController.cursorMoved(localX: nil)
            }
        }
    }

    private var navigationSplitLayout: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebarView
        } detail: {
            detail
        }
        .navigationTitle(tabManager.selectedTab?.displayTitle ?? "Quay")
    }

    private var sidebarView: some View {
        SidebarView(
            searchQuery: $searchQuery,
            selection: $selectedConnectionID,
            onOpenConnectionInNewTab: { tabManager.openNewTab(for: $0) },
            onOpenSFTPConnection: { tabManager.openSFTPTab(for: $0) },
            onCreateConnection: { openConnectionEditor(.create(folderID: $0?.id)) },
            onEditConnection: { openConnectionEditor(.edit($0)) }
        )
    }

    // MARK: - Helpers

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
        if autoHide { return .all }
        return SidebarLayoutState.loadSidebarVisible() ? .all : .detailOnly
    }

    private func restoreSavedSidebarVisibility() {
        guard !autoHideSidebar else { return }
        scheduleAfterSwiftUILayout {
            self.columnVisibility = Self.savedColumnVisibility
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button { onToggleSidebar() } label: {
                Label("Toggle Hosts Sidebar", systemImage: "sidebar.left")
            }
            .labelStyle(.iconOnly)
            .help("Toggle Hosts Sidebar")
        }
        ToolbarItem(placement: .principal) { toolbarSearchField }
        ToolbarItem(placement: .primaryAction) { newItemMenu }
        ToolbarItem(placement: .primaryAction) {
            Button { rightSidebarOpen.toggle() } label: {
                Label("Toggle Snippets Sidebar", systemImage: "sidebar.right")
            }
            .labelStyle(.iconOnly)
            .help("Toggle Snippets Sidebar")
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
                onDidFocus: { searchFocusTrigger = false },
                onFocusChange: { focused in hoverController.setSearchFocused(focused) }
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
            Button("New Connection Group") {
                NotificationCenter.default.post(name: .createFolder, object: nil)
            }
        } label: {
            Image(systemName: "plus")
        }
        .help("New…")
    }

    // MARK: - Detail

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
            TerminalSurfaceHostsView(
                tabs: tabManager.tabs,
                selectedTabID: tabManager.selectedTabID,
                backgroundColor: selectedTerminalBackgroundColor,
                backgroundOpacity: selectedTerminalBackgroundOpacity
            )
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

// MARK: - AppKit helper views

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

        for tab in tabs {
            guard let sv = tab.surfaceView,
                  !existingIDs.contains(ObjectIdentifier(sv)) else { continue }
            sv.frame = container.bounds
            sv.autoresizingMask = [.width, .height]
            container.addSubview(sv)
        }

        let activeIDs = Set(tabs.compactMap { $0.surfaceView }.map { ObjectIdentifier($0) })
        for sv in existing where !activeIDs.contains(ObjectIdentifier(sv)) {
            sv.removeFromSuperview()
        }

        let selectedSurface = tabs.first(where: { $0.id == selectedTabID })?.surfaceView
        for sv in container.subviews { sv.isHidden = false }
        if let selectedSurface, container.subviews.last !== selectedSurface {
            container.addSubview(selectedSurface, positioned: .above, relativeTo: nil)
        }

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
    var onFocusChange: ((Bool) -> Void)?

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
        context.coordinator.parent = self
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

        func controlTextDidBeginEditing(_ obj: Notification) {
            parent.onFocusChange?(true)
        }

        func controlTextDidEndEditing(_ obj: Notification) {
            parent.onFocusChange?(false)
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
