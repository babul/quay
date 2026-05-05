import AppKit
import ComposableArchitecture
import SwiftData
import SwiftUI

struct ContentView: View {
    let store: StoreOf<AppFeature>
    @State private var selectedConnectionID: UUID?
    private let tabManager = TerminalTabManager.shared

    var body: some View {
        NavigationSplitView {
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
            ForEach(tabManager.tabs) { tab in
                tabContent(for: tab)
                    .opacity(tab.id == tabManager.selectedTabID ? 1 : 0)
                    .allowsHitTesting(tab.id == tabManager.selectedTabID)
            }
        }
    }

    @ViewBuilder
    private func tabContent(for tab: TerminalTabItem) -> some View {
        switch tab.phase {
        case .idle, .starting:
            ProgressView("Connecting…")
        case .running:
            if let surface = tab.surfaceView {
                TerminalSurfaceHostView(surfaceView: surface)
            } else {
                ProgressView("Connecting…")
            }
        case .failed(let message):
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

    @Environment(\.modelContext) private var ctx
    private func lookup(id: UUID) -> ConnectionProfile? {
        let descriptor = FetchDescriptor<ConnectionProfile>(
            predicate: #Predicate { $0.id == id }
        )
        return try? ctx.fetch(descriptor).first
    }
}

/// Wraps an existing `GhosttySurfaceView` for SwiftUI without recreating it.
/// `makeNSView` returns the already-live view; `updateNSView` is a no-op
/// because config changes are broadcast via `GhosttyRuntime.reloadConfig()`.
private struct TerminalSurfaceHostView: NSViewRepresentable {
    let surfaceView: GhosttySurfaceView

    func makeNSView(context: Context) -> GhosttySurfaceView { surfaceView }
    func updateNSView(_ nsView: GhosttySurfaceView, context: Context) {}
}

#Preview {
    ContentView(store: Store(initialState: AppFeature.State()) { AppFeature() })
        .modelContainer(for: [Folder.self, ConnectionProfile.self], inMemory: true)
}
