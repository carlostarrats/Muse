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

    // MARK: - Write policy
    //
    // A rating IS a manual tag, which means every generic tag-write path can
    // reach it — and none of them enforce one-rating-per-photo. These two
    // predicates are that enforcement, kept pure here beside the rules they
    // protect and applied at TagStore's write seam (not per caller, so a future
    // fourth entry point is safe by default).

    /// Whether a free-text label may be added as an ordinary manual tag.
    /// A glyph run must not be: `addManualTag` has no mutual exclusion, so it
    /// would leave a file carrying two ratings and break `resolution`.
    /// Ratings are `TagStore.setRating`'s alone.
    static func allowsManualTag(_ label: String) -> Bool { !isRating(label) }

    /// Whether a library-wide label rename may proceed.
    /// FROM a rating is data loss (every file's rating at that level is
    /// destroyed in one write); TO a rating mints a duplicate rating on files
    /// that already have one.
    static func allowsRename(from old: String, to new: String) -> Bool {
        !isRating(old) && !isRating(new)
    }

    /// All five canonical rating labels, ascending: ["★", …, "★★★★★"].
    static let allLabels: [String] = (1...maxStars).map { String(repeating: glyph, count: $0) }

    /// The labels a "≥ N stars" match covers. Empty for an out-of-range N —
    /// an unparseable rating matches nothing rather than crashing on a
    /// reversed range (the same guard SmartCollectionResolver applies).
    static func labels(atLeast stars: Int) -> [String] {
        guard (1...maxStars).contains(stars) else { return [] }
        return (stars...maxStars).compactMap { label(for: $0) }
    }

    // MARK: - Grid badge sizing
    //
    // The grid tile's rating badge draws `label(for:)` — a run of up to five
    // stars. On a narrow tile that run wraps to a second line and the badge
    // stops reading as a badge, so below a threshold it collapses to a digit
    // plus one star ("5★"). These helpers are the pure decision; the tile just
    // draws whatever `badgeLabel` returns.

    /// Compact badge form: the count followed by a single star, e.g. "5★".
    /// nil outside 1...maxStars, matching `label(for:)`.
    static func compactLabel(for stars: Int) -> String? {
        guard (1...maxStars).contains(stars) else { return nil }
        return "\(stars)\(glyph)"
    }

    /// Rendered width of one ★ in the badge's font (10pt semibold system),
    /// MEASURED via `NSAttributedString.size(withAttributes:)` rather than
    /// guessed. Hard-coded so these helpers stay pure (no AppKit, unit-testable
    /// off-main). If the badge's font ever changes, re-measure.
    static let badgeStarGlyphWidth: CGFloat = 10.4559
    /// Rendered width of the compact form in the same font. It's dominated by
    /// the digit, so it varies by under half a point across 1...5; the widest
    /// (17.284, at "4★") stands in for all of them, so the decision can't flip
    /// between adjacent ratings at the same tile size.
    static let badgeCompactWidth: CGFloat = 17.284
    /// The badge capsule's own horizontal padding, per side.
    static let badgeHorizontalPadding: CGFloat = 5

    /// Which string the badge should draw for `stars`, given the width it may
    /// occupy (the capsule's outer width, its padding included).
    ///
    /// Compact is chosen ONLY when it actually helps: the full run must not fit
    /// AND the compact form must be narrower than it. At one star the compact
    /// form ("1★", 17.3pt) is WIDER than the run itself ("★", 10.5pt), so a
    /// one-star badge never collapses — doing so would make the overflow worse.
    static func badgeLabel(for stars: Int, availableWidth: CGFloat) -> String? {
        guard let full = label(for: stars) else { return nil }
        let fullWidth = CGFloat(stars) * badgeStarGlyphWidth + badgeHorizontalPadding * 2
        if fullWidth <= availableWidth { return full }
        let compactWidth = badgeCompactWidth + badgeHorizontalPadding * 2
        guard compactWidth < fullWidth else { return full }
        return compactLabel(for: stars)
    }

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
