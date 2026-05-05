import AppKit
import ComposableArchitecture
import SwiftData
import SwiftUI

struct ContentView: View {
    let store: StoreOf<AppFeature>
    @State private var selectedConnectionID: UUID?
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    private let tabManager = TerminalTabManager.shared

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView(selection: $selectedConnectionID)
        } detail: {
            detail
        }
        .navigationTitle(tabManager.selectedTab?.displayTitle ?? "Quay")
        .navigationSubtitle(tabManager.selectedTab?.displayHost ?? "")
        .onAppear { store.send(.onAppear) }
        .onChange(of: selectedConnectionID) { _, id in
            guard let id, let profile = lookup(id: id) else { return }
            tabManager.openTab(for: profile)
        }
        .onReceive(NotificationCenter.default.publisher(for: .toggleSidebar)) { _ in
            columnVisibility = columnVisibility == .detailOnly ? .all : .detailOnly
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

    @Environment(\.modelContext) private var ctx
    private func lookup(id: UUID) -> ConnectionProfile? {
        let descriptor = FetchDescriptor<ConnectionProfile>(
            predicate: #Predicate { $0.id == id }
        )
        return try? ctx.fetch(descriptor).first
    }
}

/// Manages all live `GhosttySurfaceView` instances as direct NSView subviews
/// of a single container. SwiftUI's `opacity(0)` on macOS can remove NSViews
/// from the hierarchy, causing libghostty to lose its render target and killing
/// background sessions. Using `isHidden` keeps every view in the window so
/// sessions stay alive regardless of which tab is selected.
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

        // Toggle visibility — never remove, so libghostty keeps its render target.
        let selectedSurface = tabs.first(where: { $0.id == selectedTabID })?.surfaceView
        for sv in container.subviews {
            sv.isHidden = !(sv === selectedSurface)
        }

        // Transfer first-responder after isHidden = false. AppKit silently
        // ignores makeFirstResponder on a hidden view, so this must come last.
        if let selectedSurface, !selectedSurface.isHidden {
            container.window?.makeFirstResponder(selectedSurface)
        }
    }
}

#Preview {
    ContentView(store: Store(initialState: AppFeature.State()) { AppFeature() })
        .modelContainer(for: [Folder.self, ConnectionProfile.self], inMemory: true)
}
