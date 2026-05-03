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
        if let id = selectedConnectionID,
           let profile = lookup(id: id) {
            // Step 8 will replace this with a real per-tab session view that
            // resolves secrets, starts an AskpassServer, and runs ssh inside
            // the libghostty surface. For Step 7 we just confirm selection
            // wiring works by showing the profile details.
            ConnectionDetailPlaceholder(profile: profile)
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

private struct ConnectionDetailPlaceholder: View {
    let profile: ConnectionProfile

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(profile.name).font(.title)
            Group {
                Text("hostname: \(profile.hostname)")
                Text("port: \(profile.port.map(String.init) ?? "(default)")")
                Text("user: \(profile.username ?? "(current)")")
                Text("auth: \(profile.authMethod?.rawValue ?? "?")")
                if let cmd = previewCommand {
                    Divider()
                    Text(cmd).font(.system(.caption, design: .monospaced))
                }
            }
            .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var previewCommand: String? {
        guard let target = profile.sshTarget else { return nil }
        return SSHCommandBuilder.build(target).command
    }
}

#Preview {
    ContentView()
        .modelContainer(for: [Folder.self, ConnectionProfile.self], inMemory: true)
}
