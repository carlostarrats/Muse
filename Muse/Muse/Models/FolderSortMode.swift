//
//  FolderSortMode.swift
//  Muse
//
//  How the sidebar's top-level folders are ordered. Manual = the user's hand
//  arrangement (BookmarkStore.roots order, drag-to-reorder). The other modes are
//  read-only sorted displays. `FolderSort.order` is a pure comparator over names
//  + FolderStat, so it's unit-testable.
//

import Foundation

enum FolderSortMode: String, CaseIterable, Identifiable {
    case manual, name, dateModified, size

    var id: String { rawValue }

    var label: String {
        switch self {
        case .manual: return String(localized: "Manual")
        case .name: return String(localized: "Name")
        case .dateModified: return String(localized: "Date Modified")
        case .size: return String(localized: "Size")
        }
    }
}

nonisolated enum FolderSort {
    struct Item: Equatable {
        let id: UUID
        let name: String
        let stat: FolderStat?
    }

    /// Ordered ids for `items` under `mode`. Manual → input order unchanged.
    /// Name A→Z (localized, case-insensitive, numeric-aware); Date newest-first;
    /// Size largest-first. All non-Manual modes break ties by name, and items
    /// missing a stat sort after those that have one.
    static func order(_ items: [Item], by mode: FolderSortMode) -> [UUID] {
        switch mode {
        case .manual:
            return items.map(\.id)
        case .name:
            return items.sorted(by: nameAscending).map(\.id)
        case .dateModified:
            return items.sorted(by: dateNewestFirst).map(\.id)
        case .size:
            return items.sorted(by: sizeLargestFirst).map(\.id)
        }
    }

    private static func nameAscending(_ a: Item, _ b: Item) -> Bool {
        a.name.localizedStandardCompare(b.name) == .orderedAscending
    }

    private static func dateNewestFirst(_ a: Item, _ b: Item) -> Bool {
        let da = a.stat?.latestModified
        let db = b.stat?.latestModified
        if let da, let db, da != db { return da > db }
        if (da == nil) != (db == nil) { return da != nil }   // has-date before nil
        return nameAscending(a, b)
    }

    private static func sizeLargestFirst(_ a: Item, _ b: Item) -> Bool {
        let sa = a.stat?.totalSize
        let sb = b.stat?.totalSize
        if let sa, let sb, sa != sb { return sa > sb }
        if (sa == nil) != (sb == nil) { return sa != nil }
        return nameAscending(a, b)
    }
}
