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
    /// Editor backdrop level (`EditorBackdropLevel.rawValue`). A working
    /// preference, not a per-photo one — the surround you judge colour against
    /// should not change as you move between photos.
    static let editorBackdropKey = "editorBackdrop"
    static let showStarsOnGridKey = "showStarsOnGrid"
    static let colorsCardExpandedKey = "heroColorsCardExpanded"
    static let feedbackCardExpandedKey = "heroFeedbackCardExpanded"
    static let editorZebraHighKey = "editorZebraHigh"
    static let editorZebraLowKey = "editorZebraLow"
    /// The one-time "Smarter Search" offer has been shown. Set on ANY dismissal
    /// — declining once must never nag again.
    static let clipOfferSeenKey = "clipOfferSeen"
    static let announcementsEnabledKey = "announcementsEnabled"
    /// Remembered color-label mapping choices, keyed by the RAW source value.
    /// A JSON blob of `[String: LabelMapping.Choice]`.
    static let importLabelChoicesKey = "importLabelChoices"
    /// Also import Lightroom adjustments during a metadata run. Default true.
    static let importLREditsKey = "importLightroomEdits"
    /// The user has paused background analysis. PERSISTS across relaunch — a
    /// pause that silently clears itself reads as broken. This is SCHEDULING,
    /// not an off switch (DECIDED #22): markers and data paths are untouched.
    static let analysisPausedKey = "analysisPaused"

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

    /// Show the star-rating badge on tiles in the MAIN (folder) grid. Default
    /// true. Off hides the badge only in the folder grid — it still shows inside
    /// a collection and in the hero viewer. Unset → treated as on.
    static var showStarsOnGrid: Bool {
        UserDefaults.standard.object(forKey: showStarsOnGridKey) as? Bool ?? true
    }

    /// Fetch the announcements feed at launch. OFF disables the FETCH itself,
    /// not just the display — no request is made at all. Default true.
    /// Unset → treated as on.
    static var announcementsEnabled: Bool {
        UserDefaults.standard.object(forKey: announcementsEnabledKey) as? Bool ?? true
    }

    /// Import Lightroom adjustments alongside keywords/ratings. Default true.
    static var importLREdits: Bool {
        get { UserDefaults.standard.object(forKey: importLREditsKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: importLREditsKey) }
    }

    /// Background analysis paused by the user. Default false.
    static var analysisPaused: Bool {
        get { UserDefaults.standard.object(forKey: analysisPausedKey) as? Bool ?? false }
        set { UserDefaults.standard.set(newValue, forKey: analysisPausedKey) }
    }

    /// Hero viewer COLORS card: expanded (swatches visible) vs collapsed. This
    /// is a GLOBAL choice — the user's last expand/collapse becomes the default
    /// for every file (unlike the note, whose expansion is per-file). Default
    /// true (open). Unset → treated as open.
    static var colorsCardExpanded: Bool {
        UserDefaults.standard.object(forKey: colorsCardExpandedKey) as? Bool ?? true
    }

    /// "Why it looks this way" card — same global last-choice rule as the
    /// colors card, and @State-seeded for the same reason (an @AppStorage
    /// publish lands outside a withAnimation transaction).
    static var feedbackCardExpanded: Bool {
        UserDefaults.standard.object(forKey: feedbackCardExpandedKey) as? Bool ?? true
    }

    /// Highlight-clipping threshold, 0…1 of full scale. Default 0.98.
    ///
    /// The zebra kernel, the editor's live clipping percentages and the Scopes
    /// messages ALL read this one value — their agreement is structural, not a
    /// coincidence to be maintained. Never fork it. (The capture statistics
    /// stored in `photo_traits` deliberately do NOT read it: a stored row must
    /// not change meaning when a slider moves.)
    static var editorZebraHigh: Double {
        let v = UserDefaults.standard.object(forKey: editorZebraHighKey) as? Double ?? 0.98
        return min(max(v, 0.90), 1.00)
    }

    /// Shadow-crush threshold, 0…1 of full scale. Default 0.02.
    static var editorZebraLow: Double {
        let v = UserDefaults.standard.object(forKey: editorZebraLowKey) as? Double ?? 0.02
        return min(max(v, 0.00), 0.10)
    }

    // Google Drive share — remembered Muse-root folder id + last form text.
    static var driveRootFolderID: String? {
        get { UserDefaults.standard.string(forKey: "driveRootFolderID") }
        set { UserDefaults.standard.set(newValue, forKey: "driveRootFolderID") }
    }
    static var driveShareName: String {
        get { UserDefaults.standard.string(forKey: "driveShareName") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "driveShareName") }
    }
    static var driveShareLabel: String {
        get { UserDefaults.standard.string(forKey: "driveShareLabel") ?? String(localized: "Sent by") }
        set { UserDefaults.standard.set(newValue, forKey: "driveShareLabel") }
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

    /// Global image layout for every grid. Default `.columns`. Unset → columns;
    /// legacy `masonry` → columns, legacy `r*` ratios → grid (see
    /// `ImageLayout.resolve`).
    static var imageLayout: ImageLayout {
        get { ImageLayout.resolve(UserDefaults.standard.string(forKey: imageLayoutKey)) }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: imageLayoutKey) }
    }

    static let gridSpacingKey = "gridSpacing"

    /// Gap between grid tiles, in points. Default 14 (the value that was
    /// hardcoded before this became a control). The floor is a real gap, NOT
    /// zero: flush-packed images read as one continuous picture rather than a
    /// grid, so the tightest setting still separates them.
    static let defaultGridSpacing: Double = 14
    /// Upper bound raised 28 → 40 (owner call, 2026-07-29) for people who want
    /// the images to breathe. The grid's side MARGIN tracks this same value
    /// (`GridView.horizontalInset`), so a wide setting spaces the tiles from the
    /// window edges by exactly as much as it spaces them from each other.
    static let gridSpacingRange: ClosedRange<Double> = 4...40

    /// Bound a stored or slider-supplied gutter to the usable range. A value
    /// outside it doesn't just look wrong — a negative gutter overlaps tiles.
    static func clampGridSpacing(_ raw: Double) -> Double {
        min(gridSpacingRange.upperBound, max(gridSpacingRange.lowerBound, raw))
    }

    static let gridCornerRadiusKey = "gridCornerRadius"

    /// Corner radius for images, in points. Default 0 (square — the shipped
    /// look). Applies to grid tiles AND the hero viewer, so a photo keeps its
    /// shape when you open it.
    static let defaultGridCornerRadius: Double = 0
    static let gridCornerRadiusRange: ClosedRange<Double> = 0...20

    static func clampGridCornerRadius(_ raw: Double) -> Double {
        min(gridCornerRadiusRange.upperBound, max(gridCornerRadiusRange.lowerBound, raw))
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

    /// Show the Collections section in the sidebar. Default true. Unset → on.
    static var showCollectionsInSidebar: Bool {
        UserDefaults.standard.object(forKey: showCollectionsInSidebarKey) as? Bool ?? true
    }

    static let showLibraryInSidebarKey = "showLibraryInSidebar"

    /// Show the LIBRARY section (Places / On This Day / Rarely Seen / Shuffle)
    /// in the sidebar. Default true. Unset → on.
    static var showLibraryInSidebar: Bool {
        UserDefaults.standard.object(forKey: showLibraryInSidebarKey) as? Bool ?? true
    }

    static let showICloudFolderInSidebarKey = "showICloudFolderInSidebar"

    /// Show the app-managed iCloud "Muse" folder in the sidebar. Default true.
    /// Only ever honored when the folder is EMPTY — a non-empty iCloud folder
    /// always shows regardless of this flag. Unset → on.
    static var showICloudFolderInSidebar: Bool {
        UserDefaults.standard.object(forKey: showICloudFolderInSidebarKey) as? Bool ?? true
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
