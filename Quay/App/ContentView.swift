import AppKit
import ComposableArchitecture
import SwiftData
import SwiftUI

struct ContentView: View {
    let store: StoreOf<AppFeature>
    @State private var selectedConnectionID: UUID?
    @State private var columnVisibility: NavigationSplitViewVisibility
    private let tabManager = TerminalTabManager.shared

    init(store: StoreOf<AppFeature>) {
        self.store = store
        _columnVisibility = State(
            initialValue: Self.savedColumnVisibility
        )
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView(
                selection: $selectedConnectionID,
                onOpenConnection: { profile in
                    tabManager.openOrSelectTab(for: profile)
                },
                onOpenConnectionInNewTab: { profile in
                    tabManager.openNewTab(for: profile)
                }
            )
        } detail: {
            detail
        }
        .navigationTitle(tabManager.selectedTab?.displayTitle ?? "Quay")
        .navigationSubtitle(tabManager.selectedTab?.displayHost ?? "")
        .onAppear {
            store.send(.onAppear)
            restoreSavedSidebarVisibility()
        }
        .onReceive(NotificationCenter.default.publisher(for: .toggleSidebar)) { _ in
            let shouldShowSidebar = columnVisibility == .detailOnly
            columnVisibility = shouldShowSidebar ? .all : .detailOnly
            SidebarLayoutState.saveSidebarVisible(shouldShowSidebar)
        }
        .onChange(of: columnVisibility) { _, visibility in
            SidebarLayoutState.saveSidebarVisible(visibility != .detailOnly)
        }
    }

    private static var savedColumnVisibility: NavigationSplitViewVisibility {
        SidebarLayoutState.loadSidebarVisible() ? .all : .detailOnly
    }

    private func restoreSavedSidebarVisibility() {
        Task { @MainActor in
            await Task.yield()
            columnVisibility = Self.savedColumnVisibility

            try? await Task.sleep(for: .milliseconds(150))
            columnVisibility = Self.savedColumnVisibility
        }
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
                TerminalTabBar(tabManager: tabManager)
                Divider()
                tabSurfaces
            }
        }
    }

    private var tabSurfaces: some View {
        ZStack {
            // Single container that keeps every surface view as a direct NSView
            // subview at all times. Visibility is toggled via isHidden rather
            // than removing from the hierarchy, so libghostty never loses its
            // render target and background sessions stay alive.
            TerminalSurfaceHostsView(
                tabs: tabManager.tabs,
                selectedTabID: tabManager.selectedTabID
            )

            // Status overlay for the selected tab only.
            if let tab = tabManager.selectedTab {
                statusOverlay(for: tab)
            }
        }
    }

    @ViewBuilder
    private func statusOverlay(for tab: TerminalTabItem) -> some View {
        switch tab.phase {
        case .idle:
            Color(nsColor: .windowBackgroundColor)
        case .starting:
            Color(nsColor: .windowBackgroundColor)
                .overlay { ProgressView("Connecting…") }
        case .running:
            EmptyView()
        case .disconnected:
            EmptyView()
        case .failed(let message):
            Color(nsColor: .windowBackgroundColor)
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

/// Manages all live `GhosttySurfaceView` instances as direct NSView subviews
/// of a single container. The selected surface is ordered frontmost instead of
/// hiding non-selected Metal-backed views, avoiding synchronous renderer churn
/// during tab switching while keeping background sessions attached.
private struct TerminalSurfaceHostsView: NSViewRepresentable {
    let tabs: [TerminalTabItem]
    let selectedTabID: UUID?

    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        v.wantsLayer = true
        return v
    }

    func updateNSView(_ container: NSView, context: Context) {
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
