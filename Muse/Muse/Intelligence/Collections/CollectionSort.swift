//
//  CollectionSort.swift
//  Muse
//
//  Pure ordering for the Collections page, mirroring FolderSort. Only the
//  collection-applicable SortMode cases (Name / Date Created / Date Modified)
//  are handled; the base direction matches each mode's `defaultAscending`
//  (Name A→Z, dates newest-first) so the toolbar arrow + tooltip stay truthful,
//  and `reversed` flips the whole result uniformly (same strategy as
//  SmartSorter.apply).
//

import Foundation

nonisolated enum CollectionSort {
    struct Item: Equatable {
        let id: String
        let name: String
        let createdAt: Int64
        let updatedAt: Int64
    }

    /// Ordered ids for `items` under `mode`, reversed if `reversed`.
    static func order(_ items: [Item], by mode: SortMode, reversed: Bool) -> [String] {
        let base: [Item]
        switch mode {
        case .name:
            base = items.sorted(by: nameAscending)                          // A→Z
        case .dateCreated:
            base = items.sorted { tie($0, $1, $0.createdAt, $1.createdAt) }  // newest first
        case .dateModified:
            base = items.sorted { tie($0, $1, $0.updatedAt, $1.updatedAt) }  // newest first
        default:
            base = items   // unreachable; only collectionCases are selectable
        }
        let ids = base.map(\.id)
        return reversed ? ids.reversed() : ids
    }

    private static func nameAscending(_ a: Item, _ b: Item) -> Bool {
        a.name.localizedStandardCompare(b.name) == .orderedAscending
    }

    /// Newest-first with a name tiebreak (matches SmartSorter's date modes).
    private static func tie(_ a: Item, _ b: Item, _ da: Int64, _ db: Int64) -> Bool {
        da != db ? da > db : nameAscending(a, b)
    }
}
