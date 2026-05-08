import SwiftData
import SwiftUI

struct SnippetEditorSpec: Codable, Hashable {
    enum Mode: Codable, Hashable {
        case edit(snippetID: UUID)
    }
    let mode: Mode

    static func edit(snippetID: UUID) -> SnippetEditorSpec {
        SnippetEditorSpec(mode: .edit(snippetID: snippetID))
    }
}

struct SnippetEditorWindowContent: View {
    @Environment(\.modelContext) private var ctx
    let spec: SnippetEditorSpec

    var body: some View {
        if let snippet = lookup() {
            SnippetEditor(snippet: snippet, activeTab: TerminalTabManager.shared.selectedTab)
        } else {
            ContentUnavailableView("Snippet not found", systemImage: "scissors")
        }
    }

    private func lookup() -> Snippet? {
        guard case .edit(let snippetID) = spec.mode else { return nil }
        var descriptor = FetchDescriptor<Snippet>(predicate: #Predicate { $0.id == snippetID })
        descriptor.fetchLimit = 1
        return try? ctx.fetch(descriptor).first
    }
}
