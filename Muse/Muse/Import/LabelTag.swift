//
//  LabelTag.swift
//  Muse
//
//  The color-label namespace (DECIDED #12 — the semantic collision fix).
//
//  Lightroom's red *label* is a workflow marker ("second pass"); Muse's red is
//  a CONTENT attribute (the palette / color search). Merging them silently
//  poisons color semantics, so an imported label lands as an ordinary manual
//  tag carrying a canonical-English prefix — visually distinct, collision-proof
//  and, crucially, EXCLUDED from the free-text tag-search leg unless the query
//  itself targets labels.
//

import Foundation

nonisolated enum LabelTag {
    /// Canonical-English, stored verbatim (storage stays canonical; display-time
    /// localization is a rendering concern, like every other tag label).
    static let prefix = "Label: "

    static func isLabel(_ tagLabel: String) -> Bool { tagLabel.hasPrefix(prefix) }

    static func make(_ value: String) -> String {
        prefix + value.trimmingCharacters(in: .whitespaces)
    }

    /// A free-text query only reaches label tags when it names them. "red" must
    /// never match `Label: Red`; "label: red" must.
    static func queryTargetsLabels(_ query: String) -> Bool {
        query.lowercased().contains("label")
    }
}
