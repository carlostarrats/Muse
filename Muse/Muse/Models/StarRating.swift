//
//  StarRating.swift
//  Muse
//
//  Star ratings are modeled as a special MANUAL tag whose label is a run of
//  BLACK STAR glyphs (U+2605), 1...5. This pure helper is the single source of
//  truth for star<->label mapping, "is this label a rating", the chip front-sort
//  order, and the mutual-exclusion resolution (exactly one rating per photo).
//  Language-neutral: a glyph run needs no translation, so a rating label carries
//  NO VocabularyLocalizer row. Pure value type; nonisolated so it's callable from
//  any context (DB closures, views, AppState).
//

import Foundation

nonisolated enum StarRating {
    static let maxStars = 5
    static let glyph = "\u{2605}"   // ★ BLACK STAR

    /// Canonical label for a star count, or nil if out of 1...maxStars.
    static func label(for stars: Int) -> String? {
        guard (1...maxStars).contains(stars) else { return nil }
        return String(repeating: glyph, count: stars)
    }

    /// Star count for a label, or nil if the label is NOT a rating. A rating
    /// label is EXACTLY `glyph` repeated 1...maxStars times — a user tag that
    /// merely contains a star, an empty string, or 6+ stars is NOT a rating.
    static func rating(from label: String) -> Int? {
        let count = label.count
        guard (1...maxStars).contains(count),
              label == String(repeating: glyph, count: count) else { return nil }
        return count
    }

    static func isRating(_ label: String) -> Bool { rating(from: label) != nil }

    /// All five canonical rating labels, ascending: ["★", …, "★★★★★"].
    static let allLabels: [String] = (1...maxStars).map { String(repeating: glyph, count: $0) }

    /// Mutual-exclusion resolution. Given the labels a file already carries and
    /// the desired new rating (nil = remove rating), returns which rating labels
    /// to DELETE and which to ADD so the file ends with EXACTLY the desired
    /// rating and no other rating. Non-rating labels are ignored.
    static func resolution(existingLabels: [String], newRating: Int?)
        -> (remove: [String], add: [String]) {
        let desired = newRating.flatMap(label(for:))
        let existingRatings = existingLabels.filter(isRating)
        let remove = existingRatings.filter { $0 != desired }
        let add: [String]
        if let desired, !existingRatings.contains(desired) {
            add = [desired]
        } else {
            add = []
        }
        return (remove, add)
    }
}
