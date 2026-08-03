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
    /// Which of the editor panels' cards are open, by section id. A GLOBAL
    /// working preference like the backdrop: the panel you opened for the last
    /// photo is the one you want for the next.
    /// Versioned: the section ids changed meaningfully (Scopes became
    /// Histogram, Tone Zones split out), so a stored v1 set would leave the new
    /// cards shut with no way to tell that from a deliberate choice.
    static let editorExpandedSectionsKey = "editorExpandedSections2"
    /// Styles browser: thumbnails as a grid, or a compact list. A working
    /// preference — a library of fifty LUTs is a list, five is a grid. Read
    /// via @AppStorage in EditorView; no accessor, nothing off-view needs it.
    static let editorStylesListModeKey = "editorStylesListMode"
    /// Which Styles sub-sections (presets, luts) are showing their thumbnails.
    static let editorStylesOpenKey = "editorStylesOpen"
    static let editorZebraHighKey = "editorZebraHigh"
    static let editorZebraLowKey = "editorZebraLow"
    /// The editor's panel workspace — which cards, in what order, on which
    /// side, and which are hidden. A GLOBAL working preference like the
    /// backdrop and the expanded set, stored as JSON because it is structured.
    /// Not library data: it does not go in the database and does not ride a
    /// backup.
    static let editorWorkspaceKey = "editorWorkspace"
    /// The one-time "Smarter Search" offer has been shown. Set on ANY dismissal
    /// — declining once must never nag again.
    static let clipOfferSeenKey = "clipOfferSeen"
    static let announcementsEnabledKey = "announcementsEnabled"
    /// Remembered color-label mapping choices, keyed by the RAW source value.
    /// A JSON blob of `[String: LabelMapping.Choice]`.
    nonisolated static let importLabelChoicesKey = "importLabelChoices"
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

    /// Which Styles sub-sections are expanded. Unset → both open.
    static var editorStylesOpen: Set<String> {
        get {
            guard let ids = UserDefaults.standard.array(forKey: editorStylesOpenKey)
                    as? [String] else { return ["presets", "luts"] }
            return Set(ids)
        }
        set { UserDefaults.standard.set(Array(newValue), forKey: editorStylesOpenKey) }
    }

    /// Open editor panel cards. Unset (never touched) → nil, so the editor can
    /// tell "no preference yet" from "the user closed everything" and apply its
    /// own opening set only in the first case.
    static var editorExpandedSections: Set<String>? {
        get {
            guard let ids = UserDefaults.standard.array(forKey: editorExpandedSectionsKey)
                    as? [String] else { return nil }
            return Set(ids)
        }
        set {
            UserDefaults.standard.set(newValue.map(Array.init) ?? [],
                                      forKey: editorExpandedSectionsKey)
        }
    }

    /// The saved editor workspace. Unset, malformed, or the wrong type all
    /// read as the standard layout — a preference that cannot be parsed must
    /// never leave the user with an editor that has no controls. The repair of
    /// a workspace that parses but disagrees with this build (an id we no
    /// longer have, a card we just added) lives in `EditorWorkspace.init(dto:)`.
    static var editorWorkspace: EditorWorkspace {
        get {
            guard let data = UserDefaults.standard.data(forKey: editorWorkspaceKey),
                  let dto = try? JSONDecoder().decode(EditorWorkspaceDTO.self, from: data)
            else { return .standard }
            return EditorWorkspace(dto: dto)
        }
        set {
            guard let data = try? JSONEncoder().encode(EditorWorkspaceDTO(newValue)) else {
                return
            }
            UserDefaults.standard.set(data, forKey: editorWorkspaceKey)
        }
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
    /// Last share-page layout chosen at publish time. The intro paragraph is
    /// per-collection prose and is deliberately NOT remembered.
    static var driveShareLayout: String {
        get { UserDefaults.standard.string(forKey: "driveShareLayout") ?? DriveShareLayout.grid.rawValue }
        set { UserDefaults.standard.set(newValue, forKey: "driveShareLayout") }
    }
    /// Social export: the EXIF choice is remembered per preset id (photography
    /// platforms default on, everything else off). The location (GPS) sub-toggle
    /// is deliberately never remembered — it always reverts to OFF.
    static var socialExifChoices: [String: Bool] {
        get { (UserDefaults.standard.dictionary(forKey: "socialExifChoices") as? [String: Bool]) ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: "socialExifChoices") }
    }
    static var socialMatteShade: String {
        get { UserDefaults.standard.string(forKey: "socialMatteShade") ?? MatteShade.white.rawValue }
        set { UserDefaults.standard.set(newValue, forKey: "socialMatteShade") }
    }
    /// Saved export presets, JSON. Defaults rather than a table: a preset is a
    /// working preference like the editor backdrop, not library data — so it
    /// needs no migration and doesn't belong in a backup.
    static var exportPresets: Data? {
        get { UserDefaults.standard.data(forKey: "exportPresets") }
        set { UserDefaults.standard.set(newValue, forKey: "exportPresets") }
    }
    /// The last settings the export card was used with, so it reopens where you
    /// left it. Separate from the presets on purpose: this one is implicit and
    /// always overwritten, those are explicit and never touched behind your back.
    static var lastExportSettings: Data? {
        get { UserDefaults.standard.data(forKey: "lastExportSettings") }
        set { UserDefaults.standard.set(newValue, forKey: "lastExportSettings") }
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
    nonisolated static let gridSpacingRange: ClosedRange<Double> = 4...40

    /// Bound a stored or slider-supplied gutter to the usable range. A value
    /// outside it doesn't just look wrong — a negative gutter overlaps tiles.
    nonisolated static func clampGridSpacing(_ raw: Double) -> Double {
        min(gridSpacingRange.upperBound, max(gridSpacingRange.lowerBound, raw))
    }

    static let gridCornerRadiusKey = "gridCornerRadius"

    /// Corner radius for images, in points. Default 0 (square — the shipped
    /// look). Applies to grid tiles AND the hero viewer, so a photo keeps its
    /// shape when you open it.
    static let defaultGridCornerRadius: Double = 0
    nonisolated static let gridCornerRadiusRange: ClosedRange<Double> = 0...20

    nonisolated static func clampGridCornerRadius(_ raw: Double) -> Double {
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
