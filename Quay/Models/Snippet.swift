import Foundation
import SwiftData

// Both models live in PersistenceContainer's "Snippets" store
// (cloudKitDatabase: .none today; flip to .private(...) for iCloud sync later).
// CloudKit-readiness: every property is optional or has a default — no @Attribute(.unique).

@Model
final class SnippetGroup {
    var id: UUID = UUID()
    var name: String = ""
    var iconName: String?
    var sortIndex: Int = 0

    @Relationship(deleteRule: .nullify, inverse: \Snippet.group)
    var snippets: [Snippet]? = []

    init(
        id: UUID = UUID(),
        name: String,
        iconName: String? = nil,
        sortIndex: Int = 0
    ) {
        self.id = id
        self.name = name
        self.iconName = iconName
        self.sortIndex = sortIndex
    }
}

@Model
final class Snippet {
    var id: UUID = UUID()
    var name: String = ""
    /// Plaintext body. Empty when `bodyRef` is non-nil (secured).
    var body: String = ""
    /// `keychain://com.quay.snippets/<uuid>` when secured. `nil` for plain snippets.
    var bodyRef: String?
    /// Freeform description shown in the editor only; not included in search.
    var notes: String = ""
    /// When `true`, double-click and the default Paste action append a Return after the body.
    var appendsReturn: Bool = false
    var sortIndex: Int = 0
    /// `nil` = "Ungrouped" (UI-only synthetic bucket, not a real SnippetGroup row).
    var group: SnippetGroup?

    var isSecured: Bool { bodyRef != nil }

    init(
        id: UUID = UUID(),
        name: String,
        body: String = "",
        bodyRef: String? = nil,
        notes: String = "",
        appendsReturn: Bool = false,
        sortIndex: Int = 0,
        group: SnippetGroup? = nil
    ) {
        self.id = id
        self.name = name
        self.body = body
        self.bodyRef = bodyRef
        self.notes = notes
        self.appendsReturn = appendsReturn
        self.sortIndex = sortIndex
        self.group = group
    }
}
