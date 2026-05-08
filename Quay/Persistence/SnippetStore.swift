import Foundation
import SwiftData

@MainActor
enum SnippetStore {
    static func allGroups(in context: ModelContext) throws -> [SnippetGroup] {
        try context.fetch(FetchDescriptor<SnippetGroup>(
            sortBy: [SortDescriptor(\.sortIndex), SortDescriptor(\.name)]
        ))
    }

    static func ungroupedSnippets(in context: ModelContext) throws -> [Snippet] {
        try context.fetch(FetchDescriptor<Snippet>(
            predicate: #Predicate { $0.group == nil },
            sortBy: [SortDescriptor(\.sortIndex), SortDescriptor(\.name)]
        ))
    }

    static func snippets(in group: SnippetGroup) -> [Snippet] {
        (group.snippets ?? []).sorted {
            if $0.sortIndex != $1.sortIndex { return $0.sortIndex < $1.sortIndex }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    @discardableResult
    static func createGroup(named name: String, in context: ModelContext) throws -> SnippetGroup {
        let existing = try allGroups(in: context)
        let unique = uniqueGroupName(baseName: name, existingNames: Set(existing.map(\.name)))
        let group = SnippetGroup(name: unique, sortIndex: nextGroupSortIndex(from: existing))
        context.insert(group)
        try context.save()
        return group
    }

    @discardableResult
    static func createSnippet(
        name: String,
        in group: SnippetGroup?,
        ctx: ModelContext
    ) throws -> Snippet {
        let ungrouped = try ungroupedSnippets(in: ctx)
        let unique = uniqueSnippetName(
            baseName: name,
            existingNames: existingSnippetNames(in: group, ungrouped: ungrouped)
        )
        let snippet = Snippet(
            name: unique,
            sortIndex: nextSnippetSortIndex(in: group, ungrouped: ungrouped),
            group: group
        )
        ctx.insert(snippet)
        try ctx.save()
        return snippet
    }

    @discardableResult
    static func duplicate(_ snippet: Snippet, in context: ModelContext) throws -> Snippet {
        let group = snippet.group
        let ungrouped = (try? ungroupedSnippets(in: context)) ?? []
        let dup = Snippet(
            name: uniqueSnippetName(
                baseName: "\(snippet.name) Copy",
                existingNames: existingSnippetNames(in: group, ungrouped: ungrouped)
            ),
            body: snippet.isSecured ? "" : snippet.body,
            notes: snippet.notes,
            appendsReturn: snippet.appendsReturn,
            sortIndex: nextSnippetSortIndex(in: group, ungrouped: ungrouped),
            group: group
        )
        context.insert(dup)
        try context.save()
        return dup
    }

    static func uniqueGroupName(baseName: String, existingNames: Set<String>) -> String {
        uniqueName(base: baseName, existingNames: existingNames)
    }

    static func uniqueSnippetName(baseName: String, existingNames: Set<String>) -> String {
        uniqueName(base: baseName, existingNames: existingNames)
    }

    private static func existingSnippetNames(in group: SnippetGroup?, ungrouped: [Snippet]) -> Set<String> {
        group.map { Set(($0.snippets ?? []).map(\.name)) } ?? Set(ungrouped.map(\.name))
    }

    static func nextGroupSortIndex(from groups: [SnippetGroup]) -> Int {
        (groups.map(\.sortIndex).max() ?? -1) + 1
    }

    static func nextSnippetSortIndex(in group: SnippetGroup?, ungrouped: [Snippet]) -> Int {
        if let g = group {
            return ((g.snippets ?? []).map(\.sortIndex).max() ?? -1) + 1
        }
        return (ungrouped.map(\.sortIndex).max() ?? -1) + 1
    }

    private static func uniqueName(base: String, existingNames: Set<String>) -> String {
        guard existingNames.contains(base) else { return base }
        var index = 2
        while existingNames.contains("\(base) \(index)") { index += 1 }
        return "\(base) \(index)"
    }
}
