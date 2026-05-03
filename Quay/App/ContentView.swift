import SwiftUI

struct ContentView: View {
    var body: some View {
        NavigationSplitView {
            List {
                Text("No connections yet")
                    .foregroundStyle(.secondary)
            }
            .navigationTitle("Quay")
            .frame(minWidth: 220)
        } detail: {
            ContentUnavailableView(
                "Pick a connection",
                systemImage: "terminal",
                description: Text("Connection manager + libghostty wiring lands in subsequent steps.")
            )
        }
    }
}

#Preview {
    ContentView()
}
