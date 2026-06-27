//
//  AppState.swift
//  Muse
//
//  Phase 0.5 — filesystem-native top-level state. Holds:
//  - Roots (user-selected folders, persisted via security-scoped bookmarks)
//  - Folder tree per active root
//  - Currently selected folder + its files
//  - Currently selected file (for preview)
//  - FSEvents watcher for live disk sync (Q3)
//  - Show-subfolders toggle (Q2 Adobe Bridge style)
//  - Show-hidden-files toggle (Q33)
//  - Water shader toggle (Q25)
//

import Foundation
import Combine
import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// A pending sidebar collection-rename modal: the target collection id plus its
/// current name, used only to seed the rename field's draft (mirrors how
/// `folderRenameRequest` carries a `FolderNode`).
struct CollectionRenameAlertRequest: Identifiable, Equatable {
    let id: String
    let currentName: String
}

@MainActor
final class AppState: ObservableObject {

    // MARK: - Roots & stars

    let bookmarks = BookmarkStore()
    let stars = StarStore()
    /// Live per-top-level-folder stats for the sidebar counts + sort.
    let folderStats = FolderStatCache()

    /// Currently active root (the one whose tree is in the sidebar).
    @Published var activeRoot: Root?

    /// Root nodes for the sidebar tree, one per active root.
    @Published var rootNodes: [FolderNode] = []

    /// The auto-discovered iCloud zone folder URL, resolved off-main at launch.
    /// nil when the user isn't signed into iCloud. Surfaced as a sidebar root.
    @Published var iCloudFolderURL: URL?

    // MARK: - Active folder + grid contents

    @Published var selectedFolder: FolderNode?

    /// Files in the selected folder (or, if recursive, including subfolders).
    @Published var currentFiles: [FileNode] = [] {
        didSet { _visibleFilesValid = false }
    }

    /// Per-path content version, bumped when a file's bytes change in place
    /// (crop, edit-and-save, iCloud sync-in). The grid tile keys its
    /// thumbnail-load task on this, so a bump re-decodes the now-fresh bytes —
    /// the cache having already been invalidated for that path. Path-based
    /// (not node id) so it survives the FileNode being rebuilt by a reload.
    @Published private(set) var contentVersion: [String: Int] = [:]

    /// Cache-busting token the grid folds into its tile-load task id.
    func contentToken(for file: FileNode) -> Int {
        contentVersion[file.url.standardizedFileURL.path] ?? 0
    }

    /// Mark files whose CONTENT changed in place: drop their cached thumbnails
    /// (memory + disk, synchronously) and bump their version so any visible
    /// tile re-decodes. Re-analysis is handled separately (the indexer cleared
    /// `analyzed_hash`, so the analyze pass regenerates tags/colors/dimensions).
    /// Not `private`: called by `scheduleIndexing` (AppState+Indexing.swift)
    /// and `handleFolderEvent` (AppState+Watcher.swift).
    func markContentChanged(_ paths: [String]) {
        guard !paths.isEmpty else { return }
        for raw in paths {
            let url = URL(fileURLWithPath: raw)
            let std = url.standardizedFileURL.path
            ThumbnailCache.shared.invalidate(url)
            contentVersion[std, default: 0] += 1
        }
    }

    /// True while a freshly-selected folder is being enumerated off-main, so
    /// the grid can show a skeleton instead of a frozen click.
    @Published var isLoadingFolder = false

    /// Gate that holds the grid's images during a FRESH folder load until the
    /// chips are computed, so a tagged folder reveals its chips and images
    /// together (no render-at-top-then-shove-down). It is false ONLY during that
    /// brief window: `reloadCurrentFiles(showLoading:)` sets it false, and the
    /// inline chip computation sets it back true in the SAME publish as the files.
    /// Default true, so every other context — collections, a cold launch before a
    /// folder is picked, leaving search — renders immediately (never stuck blank).
    @Published var tagRowReady = true

    /// Tag-chip labels (with counts) for the files currently in view — the model
    /// owns this; `TagChipsRow` only renders it. Computed off-main by the folder
    /// load (inline, so it publishes with `currentFiles`), `setActiveCollection`,
    /// and the `tagsVersion` sink (tag edits). See `reloadTagChips`.
    @Published var tagChipRows: [(label: String, count: Int)] = []
    /// Monotonic token so a slow chip load can't clobber a newer scope.
    /// Not `private`: the tag-chip methods live in AppState+TagChips.swift.
    var tagChipToken = 0
    /// Reloads the chips whenever a tag is added / removed / renamed.
    private var tagsVersionCancellable: AnyCancellable?
    /// Tag-chip sort order (Most Used / A→Z). Persisted in AppSettings; a change
    /// re-orders the chip row in place via the sink in init.
    @Published var tagSortMode: TagSortMode = AppSettings.tagSortMode
    private var tagSortModeCancellable: AnyCancellable?

    /// Sidebar top-level folder sort (Manual / Name / Date / Size). Persisted in
    /// AppSettings. Lives here (not just in SidebarView) so the Edit-menu
    /// Move Up/Down items can reactively gate on Manual mode — see MuseApp.
    @Published var folderSortMode: FolderSortMode = AppSettings.folderSortMode
    private var folderSortModeCancellable: AnyCancellable?
    private var collectionSortModeCancellable: AnyCancellable?
    private var collectionSortReversedCancellable: AnyCancellable?

    /// Currently selected file (drives preview/detail).
    @Published var selectedFile: FileNode?

    /// Multi-selection in the grid (standardized file paths). Separate from
    /// `selectedFile`, which is the image OPEN in the hero viewer.
    @Published var selectedFiles: Set<String> = []
    /// Anchor for Shift-range selection.
    @Published var selectionAnchor: String? = nil
    /// All existing tag labels (vision + manual), preloaded so the selection
    /// menu can list them synchronously — a context-menu `.task` doesn't fire
    /// reliably in the NSMenu bridge.
    @Published var allTagLabels: [String] = []

    func refreshTagLabels() {
        Task { @MainActor in allTagLabels = await TagStore.shared.allLabels() }
    }
    /// Names of files a recent move couldn't relocate (drives an alert).
    @Published var moveFailureNames: [String] = []

    // Grid multi-selection helpers (selectionOrder / applyClick /
    // clearSelection / selectAllVisible / effectiveSelectionURLs) live in
    // AppState+Selection.swift.

    /// Set true to ask the hero viewer to run its close flight (Esc path).
    /// The viewer resets it to false in onCloseFinished.
    @Published var viewerClosing = false

    /// True from the moment the hero viewer's close flight starts until the
    /// viewer is fully gone. Brings the window toolbar back during the
    /// flight (animated) instead of snapping it in after selectedFile clears.
    @Published var viewerDismissing = false

    // MARK: - Modes

    /// Q2: include subfolders in the grid contents.
    @Published var showSubfolders: Bool = false

    /// Q33: show dotfiles / hidden files. Default off.
    @Published var showHidden: Bool = false

    /// Active sort mode (default = date modified desc per Q24 generalist).
    @Published var sortMode: SortMode = .dateModified

    /// Flip the active sort mode's natural order (the toolbar direction arrow).
    /// false = each mode's default (newest/largest/A→Z first); true reverses.
    @Published var sortReversed = false

    /// Effective ascending/descending of the current mode (default XOR
    /// reversed). Drives the toolbar arrow (up = ascending) + its tooltip.
    var sortAscending: Bool {
        sortReversed ? !sortMode.defaultAscending : sortMode.defaultAscending
    }

    /// Flip sort direction and re-order the visible files in place.
    func toggleSortDirection() {
        sortReversed.toggle()
        resort()
    }

    /// Collections-page sort mode — independent of the grid `sortMode` so
    /// sorting collections never disturbs the image grid (same isolation as
    /// `tagSortMode` / `folderSortMode`). Only `SortMode.collectionCases` are
    /// ever selectable in the UI. Persisted via a sink in `init`.
    @Published var collectionSortMode: SortMode = AppSettings.collectionSortMode

    /// Flip the collections sort's natural order (the toolbar arrow, on the
    /// Collections page). Persisted via a sink in `init`.
    @Published var collectionSortReversed: Bool = AppSettings.collectionSortReversed

    /// Effective ascending/descending for the Collections page (default XOR
    /// reversed) — drives the toolbar arrow + tooltip there.
    var collectionSortAscending: Bool {
        collectionSortReversed ? !collectionSortMode.defaultAscending
                               : collectionSortMode.defaultAscending
    }

    /// Flip the collections sort direction. The card grid re-sorts reactively
    /// off the `@Published` change — no manual resort needed.
    func toggleCollectionSortDirection() {
        collectionSortReversed.toggle()
    }

    /// Whether the right-side detail panel (tags, metadata) is visible.
    /// Presents the duplicates review sheet (set by findDuplicatesInCurrentFolder).
    @Published var duplicatesSheetVisible = false

    /// Active search query. Empty when no search.
    @Published var searchQuery: String = ""

    /// True when search results, not folder contents, are showing in the grid.
    @Published var isSearchActive: Bool = false {
        didSet { _visibleFilesValid = false }
    }

    /// Search scope, chosen in the search field's magnifier menu. false = the
    /// selected folder (the default), true = the whole library. Drives both the
    /// query scope (`runSearch`) and whether the sidebar shows a folder as
    /// selected (an "All" search is cross-folder, so no folder is current).
    /// Persists across search clears, but resets to false when you navigate into
    /// a folder (`select(folder:)`) — a deliberate folder pick scopes to it.
    @Published var searchAllFolders: Bool = false


    /// Global (window) frames of grid tiles, keyed by file path. Used as the
    /// hero-transition source rect. Deliberately NOT @Published — frames
    /// update constantly during scroll and publishing would thrash the UI;
    /// the viewer reads this once at open.
    var tileFrames: [String: CGRect] = [:]

    // MARK: - Collections (AI brain)

    /// The collection the grid is filtered to, if any.
    @Published var activeCollectionID: String? = nil

    /// Alive absolute paths of the active collection's members. nil when
    /// no collection filter is active.
    @Published var activeCollectionPaths: Set<String>? = nil

    /// FileNodes for ALL of the active collection's members, across every
    /// folder — a collection is a library-wide view, not an intersection
    /// with whatever folder happens to be selected in the sidebar.
    @Published var activeCollectionFiles: [FileNode]? = nil {
        didSet { _visibleFilesValid = false }
    }

    /// True when the dedicated Collections page (grid of all collection
    /// cards) is showing. Toggled by the toolbar's collections icon. When a
    /// collection is then opened from the page, `activeCollectionID` becomes
    /// non-nil and the filtered grid takes over while this stays true, so the
    /// in-collection back arrow returns here rather than to the main grid.
    @Published var showingCollections = false

    /// Drives the View-menu "Manage Drive Shares…" sheet.
    @Published var driveSharesShown = false

    // Collection filtering (toggleCollectionsPage / visibleFiles /
    // tagSourceFiles / setActiveCollection / setCollectionCover) and the tag
    // filter (setActiveTag / removeTag / removeFromCollection) live in
    // AppState+Filters.swift.

    /// Monotonic token so a slow collection load can't clobber a newer pick.
    /// Not `private`: read/written by `setActiveCollection` in AppState+Filters.swift.
    var collectionRequestToken = 0

    // MARK: - Tag chip filter (main grid)

    /// Active tag-chip filter as an ORDERED set; empty = "All". Insertion order
    /// drives the banner wording. Mutated via `setActiveTags` / `setActiveTag` /
    /// `toggleActiveTag` in AppState+Filters; the grid filters by the
    /// INTERSECTION of these labels' path sets (`activeTagPaths`).
    @Published var activeTagLabels: [String] = []

    /// The lone selected tag, or nil when 0 or 2+ are selected. Drives the
    /// single-tag menu commands (Rename/Delete/Remove) which are ambiguous for a
    /// multi-tag selection.
    var singleActiveTag: String? {
        activeTagLabels.count == 1 ? activeTagLabels.first : nil
    }

    /// Alive paths in the INTERSECTION of `activeTagLabels` (files carrying ALL
    /// selected tags); nil = no filter.
    @Published var activeTagPaths: Set<String>? {
        didSet {
            _visibleFilesValid = false
            // Bumps in lockstep with the RESOLVED filter (not the synchronously
            // committed `activeTagLabels`). The grid keys its cross-fade `.id` on
            // this so the swap fires when the new path set actually lands — keying
            // on `activeTagLabels` rebuilt the grid a frame early, rendering the
            // OLD tag's files until the async query returned (the switch flicker).
            tagFilterGeneration &+= 1
        }
    }
    /// Monotonic counter advanced whenever `activeTagPaths` is committed. See its
    /// didSet — drives the grid's tag-switch cross-fade identity.
    @Published var tagFilterGeneration = 0
    /// Bumped after any tag mutation (add/rename/delete) so the chip row
    /// and other tag-derived UI reload.
    @Published var tagsVersion = 0
    /// Set to a label to present the rename/delete tag dialogs (shared by
    /// the chip context menu and the menu-bar Tags menu).
    @Published var tagRenameRequest: String?
    @Published var tagDeleteRequest: String?

    /// Menu-bar triggers for the in-collection header's rename/delete.
    @Published var collectionRenameRequest = false
    @Published var collectionDeleteRequest = false

    /// Sidebar collection-rename MODAL request (carries the id + current name to
    /// seed the field). Distinct from `collectionRenameRequest`, the in-page
    /// inline-edit trigger: the sidebar right-click renames via an alert that
    /// mirrors folder rename and must NOT navigate into the collection first.
    @Published var collectionRenameAlertRequest: CollectionRenameAlertRequest?
    @Published var deleteAllTagsRequest = false
    @Published var regenerateTagsRequest = false

    /// Presents the Settings modal (an in-app sheet, not the native Preferences
    /// window). Set from the app menu (⌘,); ContentView owns the `.sheet`.
    @Published var settingsShown = false

    /// The loaded backup archive's reconnect session + its presentation flag.
    /// Set by `beginRestorePicker()`; ContentView owns the `.sheet`. See the
    /// 2026-06-20 library-backup spec.
    @Published var reconnectModel: ReconnectModel?
    @Published var reconnectShown = false

    /// Folder-management dialogs (shared by the sidebar context menu and the
    /// menu-bar Edit menu). New Subfolder is allowed on any folder incl. the
    /// iCloud home; Rename is gated to non-iCloud folders by the callers.
    @Published var newSubfolderRequest: FolderNode?
    @Published var folderRenameRequest: FolderNode?
    /// Set to a message to surface a folder-op failure alert.
    @Published var folderOpError: String?

    /// Presentation flag for the "Name Collection" modal (new-collection-from-
    /// selection). The collection is created only on confirm — see
    /// confirmNewCollection() in AppState+Filters.
    @Published var newCollectionRequest = false
    /// File paths captured at right-click time, created into a collection on
    /// confirm. Stored (not @Published) — extensions can't add stored props.
    var pendingNewCollectionPaths: [String] = []

    // MARK: - Derived: visibleFiles cache

    /// Memoized backing for `visibleFiles` (computed in AppState+Filters.swift).
    /// The grid reads `visibleFiles` several times per render and on every
    /// layout recompute; re-running the tag filter — which standardizes the
    /// path of every file in the folder (~1700 in a big library) — each time
    /// put an O(n) hitch on the main thread right as a switch was animating.
    /// These are invalidated via `didSet` on the four inputs (currentFiles,
    /// activeCollectionFiles, activeTagPaths, isSearchActive), so the filter
    /// runs once per change and every read after is O(1). Internal (not
    /// private) because the computed property lives in the extension file.
    var _visibleFilesCache: [FileNode] = []
    var _visibleFilesValid = false

    /// Shared duration for navigation crossfades — the Collections page⇄grid
    /// swap, the collection/tag filter swaps, and search enter/exit. Kept short
    /// so the brief moment where two image-heavy grids composite at once (the
    /// crossfade) is over quickly and switching pages feels near-instant.
    static let navTransition: Double = 0.2

    // The tag/collection filter logic and bulkTagCommandsAvailable /
    // setCollectionCover live in AppState+Filters.swift.

    // MARK: - Burn-up delete (polish spec §4)

    let deletion = DeleteCoordinator()

    // MARK: - Background mood

    @Published var mood: Mood = Mood.load()

    /// Custom-mood HSB components (0–1), persisted. The mood popover's
    /// sliders write these (and switch the mood to .custom).
    @Published var customHue: Double =
        UserDefaults.standard.object(forKey: "muse.customHue") as? Double ?? 0.61 {
        didSet { UserDefaults.standard.set(customHue, forKey: "muse.customHue") }
    }
    @Published var customSaturation: Double =
        UserDefaults.standard.object(forKey: "muse.customSaturation") as? Double ?? 0.25 {
        didSet { UserDefaults.standard.set(customSaturation, forKey: "muse.customSaturation") }
    }
    @Published var customBrightness: Double =
        UserDefaults.standard.object(forKey: "muse.customBrightness") as? Double ?? 0.18 {
        didSet { UserDefaults.standard.set(customBrightness, forKey: "muse.customBrightness") }
    }

    /// Day/night flag for the Auto mood; a minute timer keeps it honest.
    /// Mutated only by the mood code in AppState+Mood.swift (hence internal-set,
    /// not private(set) — the setter must be reachable from that extension).
    @Published var autoMoodIsDay = Mood.isDaytime()
    /// Not `private`: `updateAutoMoodTimer` lives in AppState+Mood.swift.
    var autoMoodTimer: Timer?

    // MARK: - Image layout

    /// Global image layout for every grid (masonry default + fixed ratios).
    /// Persisted; GridView watches it and re-lays-out instantly.
    @Published var imageLayout: ImageLayout = AppSettings.imageLayout {
        didSet { AppSettings.imageLayout = imageLayout }
    }

    // MARK: - Tile background

    /// Global backdrop behind grid content (None / Auto / Light / Dark Grey /
    /// Black). Persisted; GridView reads `tileFill`.
    @Published var tileBackground: TileBackground = AppSettings.tileBackground {
        didSet { AppSettings.tileBackground = tileBackground }
    }

    // MARK: - Grid filter

    /// The grid faceted filter (kind / date / size). Persisted to AppSettings;
    /// its didSet invalidates the visibleFiles memo exactly like the other
    /// filter inputs (currentFiles / activeCollectionFiles / activeTagPaths).
    @Published var gridFilter: GridFilter = AppSettings.gridFilter {
        didSet {
            AppSettings.gridFilter = gridFilter
            _visibleFilesValid = false
            // Deselect anything the new filter hides so a filter-hidden file
            // can't ride along into a selection action (see pruneSelectionToVisible).
            pruneSelectionToVisible()
        }
    }

    // MARK: - Sidebar collections

    /// How the sidebar's COLLECTIONS section is ordered. Persisted; INDEPENDENT
    /// of the Collections-page sort (`collectionSortMode`). Manual = the user's
    /// drag arrangement (collections.sort_order). See SidebarCollectionSort.
    @Published var sidebarCollectionSortMode: SidebarCollectionSortMode =
        AppSettings.sidebarCollectionSortMode {
        didSet { AppSettings.sidebarCollectionSortMode = sidebarCollectionSortMode }
    }

    /// Masonry has no letterbox, so it always uses Auto; only fixed ratios honor
    /// the user's pick. The stored `tileBackground` is preserved while in masonry
    /// so switching back to a ratio restores the choice.
    var effectiveTileBackground: TileBackground {
        imageLayout == .masonry ? .auto : tileBackground
    }

    /// The resolved tile backdrop for the current mood + layout + selection.
    var tileFill: Color { effectiveTileBackground.fill(for: moodPalette) }

    // MARK: - Watcher

    /// Not `private`: `startWatching` lives in AppState+Watcher.swift.
    var watcher: FolderWatcher?
    private var bookmarksCancellable: AnyCancellable?
    private var starsCancellable: AnyCancellable?
    private var folderStatsCancellable: AnyCancellable?

    init() {
        updateAutoMoodTimer()

        deletion.onRemove = { [weak self] url in
            guard let self else { return }
            self.currentFiles.removeAll { $0.url == url }
            if self.selectedFile?.url == url { self.selectedFile = nil }
            // The in-view file set shrank — refresh the chip counts (a tag that
            // only lived on the deleted file should drop out).
            self.reloadTagChips()
        }
        deletion.onRestore = { [weak self] node in
            guard let self else { return }
            // The disk restore already happened; only resurface the tile
            // if the current scope still contains it.
            if self.isSearchActive {
                // Re-rank instead of appending into unrelated results.
                Task { await self.runSearch(self.searchQuery) }
                return
            }
            guard let folder = self.selectedFolder else { return }
            let inScope = self.showSubfolders
                ? node.url.path.hasPrefix(folder.url.path + "/")
                : node.url.deletingLastPathComponent().path == folder.url.path
            guard inScope,
                  !self.currentFiles.contains(where: { $0.url == node.url }) else { return }
            self.currentFiles.append(node)
            self.resort()
            // A restored file may bring its tags back into view — refresh chips.
            self.reloadTagChips()
        }

        rebuildRootNodes()
        // Keep this a plain synchronous sink (no `.receive(on:)`): the sidebar's
        // reorder commit clears its drag offsets in the SAME transaction that
        // mutates `bookmarks.roots`, relying on `rootNodes` rebuilding synchronously
        // so the new order and the cleared offsets land together (no one-frame
        // snap-back). See SidebarView.commitReorder.
        bookmarksCancellable = bookmarks.$roots
            .sink { [weak self] newRoots in self?.rebuildRootNodes(roots: newRoots) }
        // `stars` is a nested ObservableObject; without forwarding its changes,
        // views observing AppState (the sidebar) don't refresh when a folder is
        // pinned/unpinned until some other AppState change republishes. Forward
        // it so Pin/Unpin shows immediately.
        starsCancellable = stars.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
        folderStatsCancellable = folderStats.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }

        // Any tag edit (add / remove / rename / regenerate, from anywhere) bumps
        // tagsVersion — re-derive the chip labels from one place instead of each
        // call site doing it. dropFirst so the initial value doesn't fire a load
        // before a folder is even selected.
        tagsVersionCancellable = $tagsVersion
            .dropFirst()
            .sink { [weak self] _ in self?.reloadTagChips() }

        // Tag-sort-mode change → persist + re-order the chip row in place.
        tagSortModeCancellable = $tagSortMode
            .dropFirst()
            .sink { [weak self] mode in
                AppSettings.tagSortMode = mode
                // Pass `mode` explicitly: $tagSortMode fires in willSet, so
                // self.tagSortMode is still the old value at this point.
                self?.reloadTagChips(sortModeOverride: mode)
            }

        // Folder-sort-mode change → persist. The sidebar re-renders off the
        // @Published change; nothing else to recompute here.
        folderSortModeCancellable = $folderSortMode
            .dropFirst()
            .sink { mode in AppSettings.folderSortMode = mode }

        // Collections-page sort → persist. CollectionsPage re-renders off the
        // @Published change; nothing else to recompute here.
        collectionSortModeCancellable = $collectionSortMode
            .dropFirst()
            .sink { mode in AppSettings.collectionSortMode = mode }
        collectionSortReversedCancellable = $collectionSortReversed
            .dropFirst()
            .sink { reversed in AppSettings.collectionSortReversed = reversed }

        // App Intents wiring
        NotificationCenter.default.addObserver(
            forName: .museOpenFolder, object: nil, queue: .main
        ) { [weak self] note in
            guard let url = note.userInfo?["url"] as? URL else { return }
            Task { @MainActor [weak self] in
                self?.openFromIntent(url: url)
            }
        }
        NotificationCenter.default.addObserver(
            forName: .museRunDuplicates, object: nil, queue: .main
        ) { [weak self] note in
            guard let url = note.userInfo?["url"] as? URL else { return }
            Task { @MainActor in
                self?.openFromIntent(url: url)
                let urls = self?.currentFiles
                    .filter { $0.kind == .image || $0.kind == .raw || $0.kind == .psd }
                    .map { $0.url } ?? []
                await DuplicateFinder.shared.scan(in: urls)
            }
        }
        NotificationCenter.default.addObserver(
            forName: .museRunAnalyze, object: nil, queue: .main
        ) { [weak self] note in
            guard let url = note.userInfo?["url"] as? URL else { return }
            Task { @MainActor in
                self?.openFromIntent(url: url)
                await self?.analyzeCurrentFolder()
            }
        }

        // Load persisted collections so the overlay is warm on first open.
        Task { await CollectionsEngine.shared.reload() }

        discoverICloudZone()
    }

    /// Used by App Intents — opens the URL as a transient root if it's not
    /// already part of an active root tree.
    func openFromIntent(url: URL) {
        // If the URL is inside an existing root, navigate there directly.
        for node in rootNodes {
            // Trailing-slash guard so a sibling root ("/a/Inspo") doesn't claim a
            // file under "/a/Inspo Extra" — the standing path-prefix containment rule.
            if url.path == node.url.path || url.path.hasPrefix(node.url.path + "/") {
                let folder = FolderNode(url: url)
                select(folder: folder)
                return
            }
        }
        // Otherwise just open as an ad-hoc folder (no persistence)
        let folder = FolderNode(url: url)
        select(folder: folder)
    }

    // MARK: - Roots wiring

    /// - Parameter roots: the source roots to rebuild from. The `$roots` sink
    ///   MUST pass the value it's handed: `@Published` fires in `willSet`, so
    ///   re-reading `bookmarks.roots` here would see the *old* array and a
    ///   reorder would silently render the previous order (the move-only bug).
    private func rebuildRootNodes(roots: [Root]? = nil) {
        let sourceRoots = roots ?? bookmarks.roots
        // Reuse existing nodes by URL so reorder / add / remove preserves each
        // folder's identity — and thus its expansion state — instead of building
        // fresh nodes that would collapse the tree and break a live drag.
        // Consume each cached node at most once: if two roots resolve to the
        // same URL (folder added twice) the second gets a fresh node so the
        // ForEach never sees duplicate ids.
        var pool = Dictionary(rootNodes.map { ($0.url, $0) },
                              uniquingKeysWith: { first, _ in first })
        var nodes: [FolderNode] = sourceRoots.compactMap { root in
            guard let url = bookmarks.url(for: root) else { return nil }
            return pool.removeValue(forKey: url)
                ?? FolderNode(url: url, displayName: root.displayName, isRoot: true)
        }
        // The single app-managed iCloud folder, when signed in, appears as a
        // root alongside local folders. Appended here so it survives every
        // rebuild (add/remove/restore of local roots).
        if let icloud = iCloudFolderURL {
            nodes.append(pool.removeValue(forKey: icloud)
                ?? FolderNode(url: icloud, displayName: "Muse", isRoot: true))
        }
        rootNodes = nodes
        if activeRoot == nil, let first = sourceRoots.first {
            select(rootForFirstFolder: first)
        }
        folderStats.update(roots: rootNodes.map(\.url))
        // Keep the collection count reachability-aware: the badge/card count is
        // narrowed to members under an active root so it matches what the grid
        // can show (Lever 1, 2026-06-19 count-vs-contents fix).
        CollectionsEngine.shared.setRoots(rootNodes.map(\.url))
    }

    /// Resolve the iCloud folder once at launch and surface it in the sidebar.
    /// Also pushes the URL onto AnalyzePipeline (a real singleton) so the analyze
    /// path can write sidecars without referencing AppState.
    func discoverICloudZone() {
        Task.detached(priority: .utility) {
            let url = ICloudZone.folderURL()
            await MainActor.run {
                self.iCloudFolderURL = url
                AnalyzePipeline.shared.iCloudFolder = url
                self.rebuildRootNodes()
            }
        }
    }

    private func select(rootForFirstFolder root: Root) {
        activeRoot = root
        if let node = rootNodes.first(where: { $0.url == bookmarks.url(for: root) }) {
            select(folder: node)
        }
    }

    func pickAndAddRoot() {
        guard let root = bookmarks.pickAndAddRoot() else { return }
        rebuildRootNodes()
        if let node = rootNodes.first(where: { $0.url == bookmarks.url(for: root) }) {
            activeRoot = root
            select(folder: node)
        }
    }

    func removeRoot(_ root: Root) {
        bookmarks.removeRoot(root)
        if activeRoot?.id == root.id {
            // Stop indexing/analyzing the folder we're tearing down — its files
            // are about to become unreachable, and continuing the pass over them
            // is both wasted work and a source of mid-pass Vision failures.
            // Cancel the automatic pass's task AND trip the pipeline's own stop
            // flag, which also halts manual/App-Intent analyze passes that run
            // in un-stored tasks this handle can't reach.
            indexingTask?.cancel()
            indexingTask = nil
            AnalyzePipeline.shared.cancelActivePass()
            activeRoot = bookmarks.roots.first
            selectedFolder = nil
            currentFiles = []
            selectedFile = nil
            reloadTagChips()
        }
        rebuildRootNodes()
    }

    // MARK: - Folder selection

    func select(folder: FolderNode) {
        // Update selection + start the loading state synchronously so the
        // click registers instantly; the heavy enumeration/sort runs off-main
        // (reloadCurrentFiles) and indexing kicks off once files land.
        selectedFolder = folder
        selectedFile = nil
        clearSelection()
        // Tapping a folder takes you INTO that folder's normal view, leaving any
        // cross-folder context behind: exit a single collection or the
        // Collections page, end any active search (and reset its scope to the
        // folder default), and drop the previous folder's tag filter so it can't
        // empty the new one. Lands on the folder's "All" tags view.
        // Tear the old view down INSTANTLY (animated: false) so it doesn't
        // animate away in visible steps — tags collapsing, content sliding up,
        // the collection/page clearing — before the new folder appears. The old
        // view vanishes in one frame; then the folder fades in (tag row first,
        // images already in place below it).
        if showingCollections { showingCollections = false }
        if activeCollectionID != nil { setActiveCollection(nil, animated: false) }
        if !activeTagLabels.isEmpty { setActiveTag(nil) }
        // Clear the search inline (not via clearSearch(), which would trigger a
        // second, skeleton-less reload on top of the one below). A stale search
        // would otherwise leave the query in the field, the grid showing search
        // results, and — for an "All" search — this folder un-highlighted.
        if isSearchActive || !searchQuery.isEmpty {
            searchRequestToken += 1   // invalidate any in-flight search result
            searchQuery = ""
            isSearchActive = false
        }
        searchAllFolders = false      // a deliberate folder pick defaults to it
        startWatching(folder.url)
        reloadCurrentFiles(showLoading: true, thenIndex: true, verifyICloud: true)
    }

    /// Resolve the sidebar `FolderNode` for a URL, expanding + loading children
    /// along the path so the returned node has a valid parent chain (folder ops
    /// like rename/new-subfolder reload via `node.parent` / `node`). Returns nil
    /// if the path isn't reachable under any root. Side effect: reveals the path
    /// in the sidebar tree (same as navigating to it).
    func resolveFolderNode(_ url: URL) -> FolderNode? {
        let target = url.standardizedFileURL.path
        guard let root = rootNodes.first(where: { r in
            let rp = r.url.standardizedFileURL.path
            return target == rp || target.hasPrefix(rp + "/")
        }) else { return nil }

        var node = root
        node.loadChildrenIfNeeded(showHidden: showHidden)
        node.isExpanded = true
        while node.url.standardizedFileURL.path != target {
            guard let next = node.children.first(where: { c in
                let cp = c.url.standardizedFileURL.path
                return target == cp || target.hasPrefix(cp + "/")
            }) else { break }
            next.loadChildrenIfNeeded(showHidden: showHidden)
            next.isExpanded = true
            node = next
        }
        return node.url.standardizedFileURL.path == target ? node : nil
    }

    /// Navigate into a subfolder chosen from a grid folder card: expand the
    /// sidebar tree down to it (so its row is visible), then select it exactly
    /// like a sidebar click. Highlight is URL-based (see SidebarView.isSelected),
    /// so even the FolderNode-build fallback lights up the right row.
    func openSubfolder(_ url: URL) {
        // Resolve (and reveal) the tree node; fall back to a detached node so
        // navigation still works — the URL-based highlight matches if the row
        // later loads.
        select(folder: resolveFolderNode(url) ?? FolderNode(url: url))
    }

    /// In-flight index/prewarm/analyze work for the active folder. Held so
    /// removing the folder can cancel it — otherwise the detached task keeps
    /// analyzing files that are no longer reachable (the user-reported "kept
    /// analyzing after I removed the folder", which also drove a Vision
    /// failure mid-pass). A new selection supersedes via `folderLoadToken`;
    /// the previous folder's pass is deliberately allowed to finish, so this
    /// is cancelled only on explicit removal, not on every switch.
    /// Not `private`: `scheduleIndexing` lives in AppState+Indexing.swift.
    var indexingTask: Task<Void, Never>?

    // MARK: - Starring

    /// Starred-folder scopes we've already begun accessing this session. Each
    /// `startAccessingSecurityScopedResource()` increments a kernel refcount with
    /// no matching stop here (the folder is meant to stay reachable while it's
    /// pinned), so without de-duping, re-opening the same pin leaks a scope every
    /// time. Bounding to one start per distinct path caps it.
    /// Not `private`: `openStarred` lives in AppState+Starring.swift.
    var startedStarredScopes = Set<String>()

    /// Monotonic token so a slow folder load can't clobber a newer selection.
    private var folderLoadToken = 0

    /// Enumerate + merge + sort the active folder OFF the main thread, then
    /// publish on main. `showLoading` clears the grid to a skeleton (fresh
    /// selection); without it the current list stays put until the new one is
    /// ready (live FSEvents reloads — no flash). `thenIndex` runs the indexing
    /// + thumbnail-prewarm + analysis pass once the files have landed.
    /// Public reload entry point (e.g. after a drag-move changes the folder).
    func reloadCurrentFilesPublic() { reloadCurrentFiles(thenIndex: true) }

    /// After a move: clear selection, reload the current folder, and (if any
    /// failed) surface a brief alert listing the unmoved files.
    func reloadAfterMove(failed: [URL]) {
        clearSelection()
        // If the open viewer's file was moved out from under it, dismiss it
        // rather than leave a broken image.
        if let open = selectedFile,
           !FileManager.default.fileExists(atPath: open.url.path) {
            selectedFile = nil
        }
        reloadCurrentFilesPublic()
        if !failed.isEmpty {
            moveFailureNames = failed.map { $0.lastPathComponent }
        }
    }

    /// Not `private`: `clearSearch` (AppState+Search.swift) calls it.
    func reloadCurrentFiles(showLoading: Bool = false, thenIndex: Bool = false,
                                    verifyICloud: Bool = false) {
        guard let folder = selectedFolder else {
            currentFiles = []
            isLoadingFolder = false
            tileFrames.removeAll()
            return
        }
        folderLoadToken += 1
        let token = folderLoadToken
        let folderURL = folder.url
        let showSub = showSubfolders
        let showHid = showHidden
        let mode = sortMode
        let reversed = sortReversed
        let tagSort = tagSortMode

        // Reuse unchanged nodes so live reloads keep tile @State (thumbnails,
        // in-flight animations). A fresh selection clears instead — nothing to
        // reuse — and shows the skeleton while it loads.
        let existing: [URL: FileNode]
        if showLoading {
            existing = [:]
            currentFiles = []
            isLoadingFolder = true
            // Hold the grid's images until the tag row loads, so a tagged folder
            // reveals its chips first and the images appear already in place.
            tagRowReady = false
            // Fresh folder: the old folder's recorded tile frames are dead
            // weight (and could mis-seed a hero open for a stale path).
            // Bounds tileFrames to roughly one folder's worth of tiles.
            tileFrames.removeAll()
            // Same rationale for the per-path content versions: they only need
            // to live as long as the folder is on screen (an edit already
            // regenerated the on-disk thumbnail under its path key), so reset
            // here rather than let the dict accumulate across a long session.
            contentVersion.removeAll()
        } else {
            existing = Dictionary(currentFiles.map { ($0.url, $0) },
                                  uniquingKeysWith: { a, _ in a })
        }

        // A fresh SELECT (showLoading) always lands on a folder with no collection
        // active — select(folder:) cleared it — so its chips come from this folder.
        // Compute them in the SAME off-main pass as enumeration and publish them
        // with currentFiles, so files + chips + the reveal land in ONE update —
        // no SwiftUI round-trip waiting for the chip row's loader to wake up.
        let freshSelect = showLoading
        let dbQueue = Database.shared.dbQueue
        Task.detached(priority: .userInitiated) {
            let raw = showSub
                ? Self.enumerateRecursive(at: folderURL, showHidden: showHid)
                : FolderReader.files(in: folderURL, showHidden: showHid, includeFolders: true)
            let merged = raw.map { fresh -> FileNode in
                if let old = existing[fresh.url],
                   old.modifiedAt == fresh.modifiedAt,
                   old.sizeBytes == fresh.sizeBytes {
                    return old
                }
                return fresh
            }
            // Folders first (Finder pattern), each group in the active sort order.
            // No-op in the recursive view (no folder nodes there).
            let sorted = FolderOrdering.foldersFirst(
                SmartSorter.apply(mode, to: merged, reversed: reversed))
            // Reconcile externally-deleted files on a fresh folder open: flip
            // DB rows for files that vanished from disk to is_alive=0, so they
            // stop leaking into search (blank tiles) + collection counts. Runs
            // BEFORE the chip counts below so those exclude the dead files too.
            var reconciledDead = 0
            if freshSelect, let dbQueue {
                let present = Set(raw.map { $0.url.standardizedFileURL.path })
                // Guard against a FAILED / not-yet-materialized enumeration:
                // FolderReader returns [] both for a genuinely empty folder AND a
                // read failure (transient permission loss, or an iCloud folder
                // whose container hasn't materialized on a cold launch). Marking
                // the WHOLE folder's rows dead on a false-empty is exactly the
                // iCloud data-loss class we guard against — so when nothing
                // enumerated, probe the directory: only a confirmed-readable
                // (genuinely empty) folder is safe to reconcile.
                let trustworthy = !present.isEmpty
                    || (try? FileManager.default.contentsOfDirectory(
                            at: folderURL, includingPropertiesForKeys: nil,
                            options: showHid ? [] : [.skipsHiddenFiles])) != nil
                if trustworthy {
                    reconciledDead = PathReconciler.reconcile(
                        folder: folderURL, recursive: showSub,
                        present: present, queue: dbQueue)
                }
            }
            var chipRows: [(label: String, count: Int)] = []
            if freshSelect, let dbQueue {
                let tagPaths = sorted.map { $0.url.standardizedFileURL.path }
                if let first = tagPaths.first {
                    let simpleDir = showSub ? nil : TagScope.parentDir(ofPath: first)
                    chipRows = TagChipLoader.ordered(
                        TagChipLoader.counts(paths: tagPaths, simpleFolderDir: simpleDir, queue: dbQueue),
                        sortMode: tagSort)
                }
            }
            await MainActor.run {
                // A newer selection started while we were loading — drop this.
                guard token == self.folderLoadToken else { return }
                self.currentFiles = sorted
                self.isLoadingFolder = false
                if freshSelect {
                    // Supersede any in-flight chip load, then reveal files + chips
                    // in one transaction. NO withAnimation: an instant cut (like
                    // the tag-switch `.transition(.identity)` swap) — folder
                    // switching should feel like switching tabs, not fade in.
                    // Files + chips still land together, so the "images appear
                    // already in place below the chips" ordering is preserved;
                    // only the opacity fade is dropped.
                    self.bumpTagChipToken()
                    self.tagChipRows = chipRows
                    self.tagRowReady = true
                } else {
                    // Live reload (FSEvents / subfolders toggle / clear search):
                    // the grid is already shown, so just refresh the chips for the
                    // current scope (no gate).
                    self.reloadTagChips()
                }
                if thenIndex { self.scheduleIndexing(for: folderURL, verifyICloud: verifyICloud) }
                // Marking ghosts dead shrinks alive-aware collection counts;
                // refresh the published cards so a stale count (e.g. "5" for a
                // collection with 1 real member) corrects immediately.
                if reconciledDead > 0 {
                    Task { await CollectionsEngine.shared.reload() }
                }
            }
        }
    }

    func resort() {
        // Don't re-sort search results; they maintain relevance ranking
        guard !isSearchActive else { return }
        currentFiles = FolderOrdering.foldersFirst(
            SmartSorter.apply(sortMode, to: currentFiles, reversed: sortReversed))
        if let collectionFiles = activeCollectionFiles {
            activeCollectionFiles = SmartSorter.apply(sortMode, to: collectionFiles, reversed: sortReversed)
        }
    }

    // MARK: - Search

    /// Monotonic token so a slow search can't clobber a newer search — or a
    /// dismissal that landed while it was in flight. Not `private`: the search
    /// methods live in AppState+Search.swift and the folder-selection path here
    /// also bumps it.
    var searchRequestToken = 0

    /// Nonisolated so it can run off the main thread during a folder load.
    /// Sorting is left to SmartSorter (the caller applies the active mode).
    private nonisolated static func enumerateRecursive(at url: URL, showHidden: Bool) -> [FileNode] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: url,
            includingPropertiesForKeys: [
                .isDirectoryKey, .isPackageKey, .fileSizeKey,
                .contentModificationDateKey, .creationDateKey
            ],
            options: showHidden ? [] : [.skipsHiddenFiles]
        ) else {
            return []
        }
        var nodes: [FileNode] = []
        for case let child as URL in enumerator {
            let v = try? child.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
            let isDir = v?.isDirectory == true
            let isPackage = v?.isPackage == true
            if isDir && !isPackage { continue }
            // Known to be a file/package — classify directly, skipping
            // AssetKind.detect's redundant per-file fileExists stat.
            nodes.append(FileNode(url: child, kind: AssetKind.classify(url: child, fallback: .unknown)))
        }
        return nodes
    }

    func toggleSubfolders() {
        showSubfolders.toggle()
        reloadCurrentFiles()
    }

}
