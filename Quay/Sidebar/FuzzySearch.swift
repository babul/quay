import Foundation

/// Tiny subsequence-scoring fuzzy matcher.
///
/// `matches("cdr", "cmd-r-helper")` → `true` (c, d, r appear in order).
/// `score` rewards consecutive matches and matches at the start of a word
/// segment. Higher = better.
enum FuzzySearch {
    /// Returns `true` iff every character in `needle` appears in `haystack`
    /// in order, ignoring case.
    static func matches(_ needle: String, in haystack: String) -> Bool {
        score(needle, in: haystack) != nil
    }

    /// Returns a non-negative score for a successful match, or nil.
    ///
    /// Heuristics, in order of impact:
    ///   - large bonus for a match at the start of the string
    ///   - large bonus for a contiguous run (all needle chars adjacent)
    ///   - moderate bonus per consecutive-pair within a partial run
    ///   - small bonus for a match at a word boundary (after `-`, `_`, `.`, ` `)
    static func score(_ needle: String, in haystack: String) -> Int? {
        let n = needle.lowercased()
        let h = haystack.lowercased()
        if n.isEmpty { return 0 }

        var nIdx = n.startIndex
        var lastMatched: String.Index?
        var score = 0
        var atWordBoundary = true
        var firstMatchIndex: String.Index?
        var consecutiveRun = 0
        var maxConsecutiveRun = 0

        for hIdx in h.indices {
            let hc = h[hIdx]
            let isBoundary = atWordBoundary
            atWordBoundary = !hc.isLetter && !hc.isNumber

            guard nIdx < n.endIndex else { break }
            if hc == n[nIdx] {
                if firstMatchIndex == nil { firstMatchIndex = hIdx }
                var bonus = 1
                if isBoundary { bonus += 4 }
                let isConsecutive = lastMatched.map { h.index(after: $0) == hIdx } ?? false
                if isConsecutive {
                    consecutiveRun += 1
                    bonus += consecutiveRun * 6
                } else {
                    consecutiveRun = 0
                }
                maxConsecutiveRun = max(maxConsecutiveRun, consecutiveRun)
                score += bonus
                lastMatched = hIdx
                nIdx = n.index(after: nIdx)
            }
        }

        guard nIdx == n.endIndex else { return nil }

        // Big bonus for matching at the very start of the string.
        if firstMatchIndex == h.startIndex { score += 50 }
        // Big bonus when the entire needle matched contiguously
        // (consecutiveRun is needle-length minus 1 in that case).
        if maxConsecutiveRun + 1 == n.count { score += 100 }

        return score
    }

    /// Convenience for the sidebar: rank connection profiles by their
    /// `name + " " + hostname` against `query`.
    static func rank<T>(
        _ items: [T],
        query: String,
        keys: (T) -> [String]
    ) -> [T] {
        if query.isEmpty { return items }
        return items
            .compactMap { item -> (T, Int)? in
                let best = keys(item)
                    .compactMap { score(query, in: $0) }
                    .max()
                return best.map { (item, $0) }
            }
            .sorted(by: { $0.1 > $1.1 })
            .map(\.0)
    }
}
