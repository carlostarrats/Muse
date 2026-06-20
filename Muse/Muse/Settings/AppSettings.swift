//
//  AppSettings.swift
//  Muse
//
//  User preferences for automatic organization. Both default ON. Turning one
//  off only affects folders processed AFTER the change — Muse stops auto-
//  tagging / auto-clustering newly indexed files. Nothing already tagged or
//  collected is removed or redone, and the manual paths still work (Analyze /
//  Regenerate Tags for tags; building your own collections by hand).
//
//  Read from non-UI code (AnalyzePipeline, CollectionsEngine) via these
//  accessors; the SettingsView binds @AppStorage to the same keys.
//

import Foundation

enum AppSettings {
    static let autoTagKey = "autoTagNewImages"
    static let autoCollectionsKey = "autoOrganizeCollections"
    static let showFileNamesKey = "showFileNames"

    /// Automatically run the Vision pass (tags/caption/colors/OCR) on newly
    /// indexed images. Default true. Unset → treated as on.
    static var autoTag: Bool {
        UserDefaults.standard.object(forKey: autoTagKey) as? Bool ?? true
    }

    /// Automatically cluster files into collections. Default true. Unset → on.
    static var autoCollections: Bool {
        UserDefaults.standard.object(forKey: autoCollectionsKey) as? Bool ?? true
    }

    /// Show each file's name beneath its thumbnail in the grid. Default false.
    /// Unset → treated as off.
    static var showFileNames: Bool {
        UserDefaults.standard.object(forKey: showFileNamesKey) as? Bool ?? false
    }

    static let folderSortModeKey = "folderSortMode"

    /// Sidebar top-level folder sort mode. Default `.manual`. Unset → manual.
    static var folderSortMode: FolderSortMode {
        get {
            (UserDefaults.standard.string(forKey: folderSortModeKey))
                .flatMap(FolderSortMode.init(rawValue:)) ?? .manual
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: folderSortModeKey) }
    }

    static let tagSortModeKey = "tagSortMode"

    /// Tag-chip row sort order. Default `.count` (most-used first). Unset → count.
    static var tagSortMode: TagSortMode {
        get {
            (UserDefaults.standard.string(forKey: tagSortModeKey))
                .flatMap(TagSortMode.init(rawValue:)) ?? .count
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: tagSortModeKey) }
    }

    static let collectionSortModeKey = "collectionSortMode"

    /// Collections-page sort mode. Default `.name` (A→Z), matching the page's
    /// original hardcoded order. Unset → name.
    static var collectionSortMode: SortMode {
        get {
            (UserDefaults.standard.string(forKey: collectionSortModeKey))
                .flatMap(SortMode.init(rawValue:)) ?? .name
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: collectionSortModeKey) }
    }

    static let collectionSortReversedKey = "collectionSortReversed"

    /// Whether the Collections-page sort is flipped from its mode's natural
    /// direction. Default false. Unset → false.
    static var collectionSortReversed: Bool {
        get { UserDefaults.standard.bool(forKey: collectionSortReversedKey) }
        set { UserDefaults.standard.set(newValue, forKey: collectionSortReversedKey) }
    }

    static let imageLayoutKey = "imageLayout"

    /// Global image layout for every grid. Default `.masonry`. Unset → masonry.
    static var imageLayout: ImageLayout {
        get { ImageLayout.resolve(UserDefaults.standard.string(forKey: imageLayoutKey)) }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: imageLayoutKey) }
    }

    static let tileBackgroundKey = "tileBackground"

    /// Global grid tile backdrop. Default `.auto` (follows the mood). Unset → auto.
    static var tileBackground: TileBackground {
        get { TileBackground.resolve(UserDefaults.standard.string(forKey: tileBackgroundKey)) }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: tileBackgroundKey) }
    }

    static let gridFilterKey = "muse.gridFilter"

    /// Global grid faceted filter (kind / date / size). Default `.none` (off).
    /// Persisted as a JSON string (GridFilter is Codable, not a single rawValue
    /// like imageLayout/tileBackground). Unset/invalid → none.
    static var gridFilter: GridFilter {
        get { GridFilter.resolve(UserDefaults.standard.string(forKey: gridFilterKey)) }
        set {
            if let data = try? JSONEncoder().encode(newValue),
               let json = String(data: data, encoding: .utf8) {
                UserDefaults.standard.set(json, forKey: gridFilterKey)
            }
        }
    }

    static let showCollectionsInSidebarKey = "showCollectionsInSidebar"

    /// Show the Collections section in the sidebar. Default false. Unset → off.
    static var showCollectionsInSidebar: Bool {
        UserDefaults.standard.object(forKey: showCollectionsInSidebarKey) as? Bool ?? false
    }

    static let sidebarCollectionSortModeKey = "sidebarCollectionSortMode"

    /// Sidebar Collections-section sort. Default `.manual`. Independent of the
    /// Collections-page sort. Unset → manual.
    static var sidebarCollectionSortMode: SidebarCollectionSortMode {
        get {
            (UserDefaults.standard.string(forKey: sidebarCollectionSortModeKey))
                .flatMap(SidebarCollectionSortMode.init(rawValue:)) ?? .manual
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: sidebarCollectionSortModeKey) }
    }
}
