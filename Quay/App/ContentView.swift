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
            sidebar
        } detail: {
            // Smoke test for Step 3: a libghostty surface running the user's
            // shell. Replace with the connection-driven session view in Step 8.
            GhosttyTerminalView(config: .localShell())
                .frame(minWidth: 600, minHeight: 360)
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 8) {
            List {
                Text("No connections yet")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text("libghostty \(ghosttyVersion)")
                .font(.caption2.monospaced())
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
        }
        .frame(minWidth: 220)
        .navigationTitle("Quay")
    }
}

private extension GhosttySurfaceConfig {
    /// Convenience for the smoke-test view: spawn the user's shell as a
    /// login shell with no extra environment.
    static func localShell() -> GhosttySurfaceConfig {
        var c = GhosttySurfaceConfig()
        c.command = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        return c
    }
}

#Preview {
    ContentView()
}
