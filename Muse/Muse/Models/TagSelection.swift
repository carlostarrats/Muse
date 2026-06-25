//
//  TagSelection.swift
//  Muse
//
//  Pure transition + banner-text logic for the multi-tag chip filter. The grid
//  filters by the INTERSECTION (AND) of the selected tags; this type owns the
//  ordered-set mutations and the "Viewing … and …" banner wording so AppState
//  stays a thin caller and the rules are unit-tested. `nonisolated` because the
//  module's default actor isolation is MainActor (used from nonisolated tests).
//

nonisolated enum TagSelection {

    /// Cmd-click toggle: remove `label` if present, else append it at the end
    /// (insertion order drives the banner wording).
    static func toggling(_ labels: [String], _ label: String) -> [String] {
        if let idx = labels.firstIndex(of: label) {
            var out = labels
            out.remove(at: idx)
            return out
        }
        return labels + [label]
    }

    /// Per-pill removal from the active-filter bar: drop every occurrence of
    /// `label`, preserving the order of the survivors. Removing the sole label
    /// yields an empty selection (back to "All").
    static func removing(_ labels: [String], _ label: String) -> [String] {
        labels.filter { $0 != label }
    }

    /// Apply a label rename to the selection: replace every `old` with `new`,
    /// then de-duplicate (TagStore MERGES on a rename collision, so if `new` is
    /// already selected the result must not hold it twice). Order preserved.
    static func renaming(_ labels: [String], from old: String, to new: String) -> [String] {
        var seen = Set<String>()
        return labels.map { $0 == old ? new : $0 }.filter { seen.insert($0).inserted }
    }

    /// The grid-top banner shown for 2+ selected tags. nil for 0 or 1 (a single
    /// filled chip is already clear). Oxford-style "and" before the last label.
    /// Plain text — used as the banner's accessibility label (and tested);
    /// the view renders the labels as pills via `bannerSegments`.
    /// `viewing`/`and` default to English; the view passes localized connective
    /// words (via `String(localized:)`) so the VoiceOver banner reads in the
    /// user's language. The tag labels themselves are localized by the caller
    /// before they're passed in.
    static func bannerText(for labels: [String],
                           viewing: String = "Viewing",
                           and: String = "and") -> String? {
        switch labels.count {
        case 0, 1:
            return nil
        case 2:
            return "\(viewing) \(labels[0]) \(and) \(labels[1])"
        default:
            let head = labels.dropLast().joined(separator: ", ")
            return "\(viewing) \(head), \(and) \(labels.last!)"
        }
    }

    /// One renderable segment of the pill banner: a tag label drawn as a pill,
    /// with the connective punctuation around it. The view lays these after a
    /// leading "Viewing": each segment optionally gets an "and" word before its
    /// pill (the last one) and a hugging comma after it (Oxford, 3+ tags).
    struct BannerSegment: Equatable {
        let label: String
        /// "and" word rendered before this pill (the final segment, 2+ tags).
        let precededByAnd: Bool
        /// Comma hugging the pill's trailing edge (every non-last pill, 3+ tags).
        let trailingComma: Bool
    }

    /// Pill segments for the banner; empty for 0 or 1 label (no banner). Mirrors
    /// `bannerText`'s Oxford wording: "Viewing [a] and [b]" (2),
    /// "Viewing [a], [b], and [c]" (3+).
    static func bannerSegments(for labels: [String]) -> [BannerSegment] {
        guard labels.count >= 2 else { return [] }
        let n = labels.count
        return labels.enumerated().map { i, label in
            BannerSegment(label: label,
                          precededByAnd: i == n - 1,
                          trailingComma: n >= 3 && i < n - 1)
        }
    }
}
