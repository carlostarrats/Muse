//
//  TagSortMode.swift
//  Muse
//
//  How the tag chips above the grid are ordered. `.count` = most-used first
//  (the default / historical behavior, alphabetical tiebreak); `.alphabetical`
//  = A→Z. The actual ordering lives in TagChipLoader.ordered(_:sortMode:).
//

import Foundation

enum TagSortMode: String, CaseIterable, Identifiable {
    case count, alphabetical

    var id: String { rawValue }

    var label: String {
        switch self {
        case .count: return "Most Used"
        case .alphabetical: return "A → Z"
        }
    }
}
