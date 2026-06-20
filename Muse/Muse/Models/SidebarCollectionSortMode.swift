//
//  SidebarCollectionSortMode.swift
//  Muse
//
//  How the sidebar's COLLECTIONS section is ordered — independent of the
//  Collections PAGE sort. Manual = the user's hand arrangement (persisted
//  collections.sort_order, drag-to-reorder). The other modes are read-only
//  sorted displays. `SidebarCollectionSort.order` is a pure comparator, so
//  it's unit-testable. Mirrors FolderSort / CollectionSort.
//

import Foundation

enum SidebarCollectionSortMode: String, CaseIterable, Identifiable {
    case manual, name, dateCreated, dateModified

    var id: String { rawValue }

    var label: String {
        switch self {
        case .manual: return "Manual"
        case .name: return "Name"
        case .dateCreated: return "Date Created"
        case .dateModified: return "Date Modified"
        }
    }
}

nonisolated enum SidebarCollectionSort {
    struct Item: Equatable {
        let id: String
        let name: String
        let createdAt: Int64
        let updatedAt: Int64
        let sortOrder: Int
    }

    /// Ordered ids for `items` under `mode`. Manual → ascending `sortOrder`
    /// (name tiebreak); Name A→Z; dates newest-first with a name tiebreak.
    static func order(_ items: [Item], by mode: SidebarCollectionSortMode) -> [String] {
        switch mode {
        case .manual:
            return items.sorted(by: manualOrder).map(\.id)
        case .name:
            return items.sorted(by: nameAscending).map(\.id)
        case .dateCreated:
            return items.sorted { tie($0, $1, $0.createdAt, $1.createdAt) }.map(\.id)
        case .dateModified:
            return items.sorted { tie($0, $1, $0.updatedAt, $1.updatedAt) }.map(\.id)
        }
    }

    private static func manualOrder(_ a: Item, _ b: Item) -> Bool {
        a.sortOrder != b.sortOrder ? a.sortOrder < b.sortOrder : nameAscending(a, b)
    }

    private static func nameAscending(_ a: Item, _ b: Item) -> Bool {
        a.name.localizedStandardCompare(b.name) == .orderedAscending
    }

    private static func tie(_ a: Item, _ b: Item, _ da: Int64, _ db: Int64) -> Bool {
        da != db ? da > db : nameAscending(a, b)
    }
}
