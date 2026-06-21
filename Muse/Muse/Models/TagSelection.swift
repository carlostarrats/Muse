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

    /// The grid-top banner shown for 2+ selected tags. nil for 0 or 1 (a single
    /// filled chip is already clear). Oxford-style "and" before the last label.
    static func bannerText(for labels: [String]) -> String? {
        switch labels.count {
        case 0, 1:
            return nil
        case 2:
            return "Viewing \(labels[0]) and \(labels[1])"
        default:
            let head = labels.dropLast().joined(separator: ", ")
            return "Viewing \(head), and \(labels.last!)"
        }
    }
}
