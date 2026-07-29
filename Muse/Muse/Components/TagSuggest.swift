//
//  TagSuggest.swift
//  Muse
//
//  Pure ranking for the "which existing tag/collection did you mean?" lists
//  behind every add-a-tag and add-to-collection input. Shared by the hero
//  viewer's cards and the grid's Add Tag / New Collection modals so the three
//  can't disagree about what's offered or in what order.
//
//  Nonisolated pure value logic — no DB, no AppKit, callable from anywhere.
//

import Foundation

nonisolated enum TagSuggest {

    /// One candidate.
    ///
    /// - `label` is the CANONICAL text: what gets matched (after `displaying`)
    ///   and what gets written.
    /// - `id` is stable identity. For a tag that's the label itself; for a
    ///   collection it's the collection's id, because two collections may
    ///   legitimately share a name and matching on text must not merge them.
    /// - `count` is the popularity signal that orders an unfiltered list. A
    ///   caller with no counts can pass a descending index to preserve whatever
    ///   order it handed in.
    struct Candidate: Equatable, Identifiable {
        let id: String
        let label: String
        let count: Int

        init(id: String? = nil, label: String, count: Int) {
            self.id = id ?? label
            self.label = label
            self.count = count
        }
    }

    /// Filter + rank candidates against what the user has typed.
    ///
    /// - Empty query: the most-used `limit` candidates — the "here's what you
    ///   already use" list, which is what these inputs showed before they could
    ///   filter at all.
    /// - Non-empty query: candidates whose DISPLAY term matches, case- and
    ///   diacritic-insensitively. Prefix matches rank above mid-string ones,
    ///   then by count, then alphabetically — a stable TOTAL order, so equal
    ///   counts can't shuffle between keystrokes.
    ///
    /// Matching runs on the display term because that's what the user sees and
    /// types (a French user types "chien", not "dog"), while the returned
    /// `label` stays the canonical English key that gets stored — the app's
    /// localize-at-display-time rule.
    ///
    /// Always drops `exclude` (labels the file already carries) and any star
    /// rating. The rating exclusion is load-bearing, not cosmetic: a rating IS
    /// a manual tag, `addManualTag` enforces no mutual exclusion, so offering
    /// "★★★" here would let a file end up with two ratings and break
    /// `StarRating.resolution`.
    static func rank(_ all: [Candidate],
                     query: String,
                     exclude: Set<String> = [],
                     displaying: (String) -> String = { $0 },
                     limit: Int) -> [Candidate] {
        let pool = all.filter { !exclude.contains($0.label) && !StarRating.isRating($0.label) }

        let needle = normalize(query)
        guard !needle.isEmpty else {
            return Array(pool.sorted(by: byCountThenName).prefix(limit))
        }

        // Rank 0 = the display term starts with what was typed, 1 = it merely
        // contains it. Non-matches drop out.
        let scored = pool.compactMap { candidate -> (rank: Int, candidate: Candidate)? in
            let hay = normalize(displaying(candidate.label))
            if hay.hasPrefix(needle) { return (rank: 0, candidate: candidate) }
            if hay.contains(needle) { return (rank: 1, candidate: candidate) }
            return nil
        }

        return Array(scored.sorted { a, b in
            if a.rank != b.rank { return a.rank < b.rank }
            return byCountThenName(a.candidate, b.candidate)
        }.map { $0.candidate }.prefix(limit))
    }

    /// Most-used first, ties broken alphabetically so the order is total and
    /// therefore stable across calls (Swift's sort is not stable on its own).
    private static func byCountThenName(_ a: Candidate, _ b: Candidate) -> Bool {
        if a.count != b.count { return a.count > b.count }
        return a.label.localizedCaseInsensitiveCompare(b.label) == .orderedAscending
    }

    /// Case- and diacritic-folded, whitespace-trimmed — so "cafe" finds "Café".
    private static func normalize(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive],
                     locale: .current)
    }
}
