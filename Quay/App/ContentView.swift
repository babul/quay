import Foundation
import GhosttyKit
import SwiftUI

struct ContentView: View {
    private let ghosttyVersion: String = {
        let info = ghostty_info()
        guard let ptr = info.version else { return "(unknown)" }
        let data = Data(bytes: ptr, count: Int(info.version_len))
        return String(data: data, encoding: .utf8) ?? "(invalid utf-8)"
    }()

    var body: some View {
        NavigationSplitView {
            List {
                Text("No connections yet")
                    .foregroundStyle(.secondary)
            }
            .navigationTitle("Quay")
            .frame(minWidth: 220)
        } detail: {
            ContentUnavailableView {
                Label("Pick a connection", systemImage: "terminal")
            } description: {
                VStack(spacing: 4) {
                    Text("Connection manager + libghostty wiring lands in subsequent steps.")
                    Text("libghostty linked: \(ghosttyVersion)")
                        .font(.caption.monospaced())
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }
}

#Preview {
    ContentView()
}
