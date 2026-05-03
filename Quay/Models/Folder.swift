import Foundation
import SwiftData

/// Hierarchical container for connections. The sidebar tree is built from
/// these. A folder may contain other folders and/or `ConnectionProfile`s.
///
/// `parent == nil` is the root; v0.1 bootstraps a single root on first launch.
@Model
final class Folder {
    @Attribute(.unique) var id: UUID
    var name: String
    var sortIndex: Int

    var parent: Folder?

    @Relationship(deleteRule: .cascade, inverse: \Folder.parent)
    var children: [Folder] = []

    @Relationship(deleteRule: .cascade, inverse: \ConnectionProfile.parent)
    var connections: [ConnectionProfile] = []

    init(
        id: UUID = UUID(),
        name: String,
        parent: Folder? = nil,
        sortIndex: Int = 0
    ) {
        self.id = id
        self.name = name
        self.parent = parent
        self.sortIndex = sortIndex
    }
}
