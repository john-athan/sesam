import Foundation

/// The sorter. 🥇
///
/// Pure arithmetic over the merged index: no AppKit, no vault, no state, so the
/// question "why is that the first result" can be asked in a test instead of by
/// squinting at a panel.
///
/// **Typing is the only control anybody uses.** So the ranking has to make the
/// first result right after two or three characters, which means the order of
/// the rungs matters more than the cleverness of any one of them: an exact
/// title beats a prefix, a prefix beats a word inside the title, and a
/// subsequence match (the "gh" that finds "GitHub") is the last rung, worth
/// less than any real match anywhere else in the entry.
///
/// **Frecency breaks ties and never makes them.** It is added after the match
/// class is decided, and it is capped, so a password copied fifty times cannot
/// climb over a better match, it can only win against an equal one. A ranking
/// where use history outranks what you just typed is a ranking that feels
/// haunted.
///
/// The trap: matches are compared on a lowercased copy, and `lowercased()` on
/// every candidate on every keystroke is most of the cost of a search. The
/// index is small enough (a few thousand rows) that it does not matter yet, and
/// the moment it does the fix is a lowercased copy on `Item`, not a smarter
/// algorithm.
enum Ranker {

    /// How many rows the panel is willing to draw.
    static let limit = 8

    static func rank(_ items: [Item], query: String, frecency: (String) -> Int) -> [Item] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()

        if needle.isEmpty {
            return Array(items
                .sorted { a, b in
                    let fa = frecency(a.key), fb = frecency(b.key)
                    return fa == fb ? a.title.lowercased() < b.title.lowercased() : fa > fb
                }
                .prefix(limit))
        }

        var scored: [(Item, Int)] = []
        for item in items {
            guard let base = score(item, needle) else { continue }
            scored.append((item, base + min(frecency(item.key), 20) * 5))
        }
        // Three keys, and the third one exists because `sorted` is not stable:
        // two entries with the same score and the same length would otherwise
        // swap places between one keystroke and the next.
        return scored
            .sorted { a, b in
                if a.1 != b.1 { return a.1 > b.1 }
                if a.0.title.count != b.0.title.count { return a.0.title.count < b.0.title.count }
                return a.0.title.lowercased() < b.0.title.lowercased()
            }
            .prefix(limit)
            .map(\.0)
    }

    /// The match class, or nil for no match at all.
    static func score(_ item: Item, _ needle: String) -> Int? {
        let title = item.title.lowercased()

        if title == needle { return 1000 }
        if title.hasPrefix(needle) { return 800 - min(title.count, 60) }
        if wordPrefix(title, needle) { return 600 }
        if title.contains(needle) { return 400 }

        for other in [item.username, item.url, item.container].compactMap({ $0?.lowercased() }) {
            if other.hasPrefix(needle) { return 300 }
            if other.contains(needle) { return 200 }
        }

        if isSubsequence(needle, of: title) { return 100 }
        return nil
    }

    /// True when the needle starts one of the words in the haystack. The
    /// separators are the ones that actually appear in entry titles: spaces,
    /// dots, dashes, slashes, underscores, at signs.
    static func wordPrefix(_ haystack: String, _ needle: String) -> Bool {
        haystack
            .split(whereSeparator: { " .-_/@:".contains($0) })
            .contains { $0.hasPrefix(needle) }
    }

    /// True when every character of the needle appears in the haystack, in
    /// order. This is what lets "ghb" find "GitHub".
    static func isSubsequence(_ needle: String, of haystack: String) -> Bool {
        var rest = Substring(needle)
        for character in haystack where character == rest.first {
            rest = rest.dropFirst()
            if rest.isEmpty { return true }
        }
        return rest.isEmpty
    }
}
