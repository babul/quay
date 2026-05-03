import Foundation
import GhosttyKit
import SwiftData
import SwiftUI

struct ContentView: View {
    @State private var selectedConnectionID: UUID?

    var body: some View {
        NavigationSplitView {
            SidebarView(selection: $selectedConnectionID)
        } detail: {
            detail
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let id = selectedConnectionID, let profile = lookup(id: id) {
            SessionView(profile: profile)
        } else {
            ContentUnavailableView {
                Label("Pick a connection", systemImage: "terminal")
            } description: {
                Text("Or hit ⌘L to search.")
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

#Preview {
    ContentView()
        .modelContainer(for: [Folder.self, ConnectionProfile.self], inMemory: true)
}
