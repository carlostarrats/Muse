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
    private func markContentChanged(_ paths: [String]) {
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
    private var tagChipToken = 0
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

    // Collection filtering (toggleCollectionsPage / visibleFiles /
    // tagSourceFiles / setActiveCollection / setCollectionCover) and the tag
    // filter (setActiveTag / removeTag / removeFromCollection) live in
    // AppState+Filters.swift.

    /// Monotonic token so a slow collection load can't clobber a newer pick.
    /// Not `private`: read/written by `setActiveCollection` in AppState+Filters.swift.
    var collectionRequestToken = 0

    // MARK: - Tag chip filter (main grid)

    /// Active tag-chip filter; nil = "All". Set via `setActiveTag`.
    @Published var activeTagLabel: String?
    /// Alive paths of files carrying `activeTagLabel`; nil = no filter.
    @Published var activeTagPaths: Set<String>? {
        didSet { _visibleFilesValid = false }
    }
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
    @Published var deleteAllTagsRequest = false
    @Published var regenerateTagsRequest = false

    /// Folder-management dialogs (shared by the sidebar context menu and the
    /// menu-bar Edit menu). New Subfolder is allowed on any folder incl. the
    /// iCloud home; Rename is gated to non-iCloud folders by the callers.
    @Published var newSubfolderRequest: FolderNode?
    @Published var folderRenameRequest: FolderNode?
    /// Shared text-field draft for the create/rename dialogs, seeded by the
    /// request helpers below (one dialog is open at a time). Seeding here — not
    /// via a view `.onChange` on node identity — means re-targeting the SAME
    /// folder still resets the field correctly.
    @Published var folderNameDraft = ""
    /// Set to a message to surface a folder-op failure alert.
    @Published var folderOpError: String?

    /// Presentation flag for the "Name Collection" modal (new-collection-from-
    /// selection). The collection is created only on confirm — see
    /// confirmNewCollection() in AppState+Filters.
    @Published var newCollectionRequest = false
    /// Bound to the modal's TextField; starts empty (placeholder shown).
    @Published var newCollectionNameDraft = ""
    /// File paths captured at right-click time, created into a collection on
    /// confirm. Stored (not @Published) — extensions can't add stored props.
    var pendingNewCollectionPaths: [String] = []

    /// Present the New Subfolder dialog for `node` (empty draft).
    func requestNewSubfolder(_ node: FolderNode) {
        folderNameDraft = ""
        newSubfolderRequest = node
    }

    /// Present the Rename dialog for `node` (draft pre-filled with its name).
    func requestRenameFolder(_ node: FolderNode) {
        folderNameDraft = node.displayName
        folderRenameRequest = node
    }
    /// Monotonic token so a slow tag-filter load can't clobber a newer pick.
    /// Not `private`: read/written by `setActiveTag` in AppState+Filters.swift.
    var tagRequestToken = 0

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
    @Published private(set) var autoMoodIsDay = Mood.isDaytime()
    private var autoMoodTimer: Timer?

    var moodPalette: MoodPalette {
        switch mood {
        case .ink:    return Mood.fallbackPalette
        case .paper:  return Mood.paperPalette
        case .auto:   return autoMoodIsDay ? Mood.paperPalette : Mood.fallbackPalette
        case .custom: return Mood.customPalette(hue: customHue,
                                                saturation: customSaturation,
                                                brightness: customBrightness)
        }
    }

    func setMood(_ m: Mood) {
        withAnimation(.easeInOut(duration: 0.35)) { mood = m }
        m.save()
        updateAutoMoodTimer()
    }

    /// Runs only while the mood is Auto; flips the palette at the
    /// day/night boundary with a slow fade.
    func updateAutoMoodTimer() {
        autoMoodTimer?.invalidate()
        autoMoodTimer = nil
        guard mood == .auto else { return }
        autoMoodIsDay = Mood.isDaytime()
        autoMoodTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.mood == .auto else { return }
                let day = Mood.isDaytime()
                if day != self.autoMoodIsDay {
                    withAnimation(.easeInOut(duration: 0.6)) { self.autoMoodIsDay = day }
                }
            }
        }
    }

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

    /// The resolved tile backdrop for the current mood + selection.
    var tileFill: Color { tileBackground.fill(for: moodPalette) }

    // MARK: - Watcher

    private var watcher: FolderWatcher?
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
            if url.path.hasPrefix(node.url.path) {
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
        if activeTagLabel != nil { setActiveTag(nil, animated: false) }
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

    /// Scan the current folder's images for duplicates, then present the
    /// review sheet. Lives here so the menu bar can trigger it.
    func findDuplicatesInCurrentFolder() {
        let urls = currentFiles
            .filter { $0.kind == .image || $0.kind == .raw || $0.kind == .psd }
            .map { $0.url }
        Task { @MainActor in
            await DuplicateFinder.shared.scan(in: urls)
            duplicatesSheetVisible = true
        }
    }

    /// Kick off active-folder indexing, then the automatic analysis pass
    /// over whatever images are new or changed (stale analyzed_hash) —
    /// already-analyzed files are provably skipped.
    /// In-flight index/prewarm/analyze work for the active folder. Held so
    /// removing the folder can cancel it — otherwise the detached task keeps
    /// analyzing files that are no longer reachable (the user-reported "kept
    /// analyzing after I removed the folder", which also drove a Vision
    /// failure mid-pass). A new selection supersedes via `folderLoadToken`;
    /// the previous folder's pass is deliberately allowed to finish, so this
    /// is cancelled only on explicit removal, not on every switch.
    private var indexingTask: Task<Void, Never>?

    /// - verifyICloud: run the background content-verify pass over the iCloud
    ///   files (catches edits made while the app was closed — iCloud
    ///   size/mtime oscillates so the normal fast path can't notice). Only the
    ///   FRESH folder selection asks for this; live FSEvents reloads handle
    ///   their specific changed files directly and must not re-hash the whole
    ///   iCloud folder on every event.
    private func scheduleIndexing(for url: URL, verifyICloud: Bool = false) {
        let files = currentFiles
        let icloud = iCloudFolderURL
        indexingTask = Task.detached(priority: .userInitiated) {
            let pairs = files.compactMap { f -> (URL, AssetKind)? in
                guard f.kind != .folder, f.kind.hasNativeViewer || f.kind == .archive else { return nil }
                return (f.url, f.kind)
            }
            // Local edits made while closed surface here (size/mtime changed),
            // as do brand-new files. Drop stale art for the ones that changed.
            let changed = await Indexer.shared.indexBatch(pairs, priority: .high)
            await MainActor.run { self.markContentChanged(changed.map { $0.path }) }
            if Task.isCancelled { return }
            let imageURLs = files
                .filter { $0.kind == .image || $0.kind == .raw || $0.kind == .psd }
                .map { $0.url }
            // Warm the whole folder's thumbnails to disk up front (background),
            // so scrolling anywhere later is an instant cache read — no
            // generation, no progress pill. Runs concurrently with analysis.
            let thumbURLs = files
                .filter { $0.kind == .image || $0.kind == .raw || $0.kind == .psd || $0.kind == .svg }
                .map { $0.url }
            await ThumbnailCache.shared.prewarmToDisk(thumbURLs)
            if Task.isCancelled { return }
            await SidecarHydrator.hydrate(urls: imageURLs, folder: icloud)
            if Task.isCancelled { return }
            await AnalyzePipeline.shared.analyzePending(in: imageURLs)
            if Task.isCancelled { return }

            // iCloud cold-start parity: re-hash the iCloud-zone files to catch
            // edits/syncs that landed while Muse was closed. Background +
            // silent (no pill) and content-hash based — NOT size/mtime, which
            // oscillates on iCloud. Only the files that truly changed get their
            // art dropped + a re-analyze; an unchanged folder is just reads.
            guard verifyICloud, let icloud else { return }
            let icloudPairs = pairs.filter {
                $0.0.standardizedFileURL.path.hasPrefix(icloud.standardizedFileURL.path + "/")
            }
            guard !icloudPairs.isEmpty else { return }
            let icloudChanged = await Indexer.shared.indexBatch(
                icloudPairs, priority: .background, force: true, silent: true)
            if Task.isCancelled || icloudChanged.isEmpty { return }
            await MainActor.run { self.markContentChanged(icloudChanged.map { $0.path }) }
            await ThumbnailCache.shared.prewarmToDisk(icloudChanged)
            await AnalyzePipeline.shared.analyzePending(in: icloudChanged)
        }
    }

    // MARK: - Starring

    func toggleStar(folder: FolderNode) {
        if stars.isStarred(folder.url) {
            stars.unstar(folder: folder.url)
        } else {
            stars.star(folder: folder.url)
        }
    }

    func openStarred(_ star: StarStore.StarredFolder) {
        guard let url = stars.resolveURL(for: star) else { return }
        _ = url.startAccessingSecurityScopedResource()
        let node = FolderNode(url: url, displayName: star.displayName)
        select(folder: node)
    }

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

    // MARK: - Folder management

    /// Create a subfolder inside `node` on disk, then refresh the tree and
    /// drill into the new folder. Surfaces failures via `folderOpError`.
    func createSubfolder(named name: String, in node: FolderNode) {
        switch FolderOps.createSubfolder(named: name, in: node.url) {
        case .failure(let e):
            folderOpError = Self.message(for: e, verb: "create")
        case .success:
            // Reveal the new folder in the sidebar but DON'T navigate into it —
            // the user stays on whatever they're currently viewing.
            node.reloadChildren()
            node.isExpanded = true
        }
    }

    /// Rename `node`'s folder on disk and migrate the index + tags + pins so
    /// nothing is orphaned. Roots repoint their bookmark; subfolders reload from
    /// their parent. The iCloud home is never renamed (callers gate it).
    func renameFolder(_ node: FolderNode, to name: String) {
        let oldURL = node.url
        switch FolderOps.rename(oldURL, to: name) {
        case .failure(let e):
            folderOpError = Self.message(for: e, verb: "rename")
        case .success(let newURL):
            // No-op rename (same name) — FolderOps returns the original URL.
            guard newURL.standardizedFileURL != oldURL.standardizedFileURL else { return }
            let oldPath = oldURL.standardizedFileURL.path
            let newPath = newURL.standardizedFileURL.path

            // Sidebar refresh (disk already moved; these are synchronous).
            if node.isRoot, let root = bookmarks.roots.first(where: {
                bookmarks.url(for: $0) == oldURL
            }) {
                // rootRenamed mutates bookmarks.roots → the $roots sink rebuilds
                // rootNodes with the new URL/name.
                if !bookmarks.rootRenamed(root, to: newURL) {
                    folderOpError = "Couldn’t finish renaming the folder."
                }
            } else {
                node.parent?.reloadChildren()
            }

            // Does the active selection sit AT or UNDER the renamed folder?
            // (renaming an ancestor of the open folder must follow it, not
            // strand the grid on a now-nonexistent path).
            let selPath = selectedFolder?.url.standardizedFileURL.path
            let selectedWasRoot = selectedFolder?.isRoot ?? false
            let newSelPath: String? = selPath.flatMap {
                FolderRenameMigration.rewrite(path: $0, old: oldPath, new: newPath)
            }

            // Migrate the DB FIRST, then reselect — the reselect triggers a
            // re-index of the new location, which must not run before the
            // path/tag rows are rewritten (a half-migrated state loses tags and
            // could collide on the alive-path unique index).
            Task { [weak self] in
                let ok = await Self.migratePaths(old: oldPath, new: newPath,
                                                 newName: newURL.lastPathComponent)
                guard let self else { return }
                if !ok {
                    self.folderOpError = "The folder was renamed, but updating its tags failed."
                }
                self.tagsVersion &+= 1
                self.stars.load()   // refresh pin paths/labels after migration
                if let newSelPath {
                    let url = URL(fileURLWithPath: newSelPath)
                    let node = self.findNode(withURL: url)
                        ?? FolderNode(url: url, isRoot: selectedWasRoot && newSelPath == newPath)
                    self.select(folder: node)
                }
            }
        }
    }

    /// Find a loaded node by URL across all root trees (best-effort; only walks
    /// already-loaded children). Used to reselect after a rename.
    private func findNode(withURL url: URL) -> FolderNode? {
        let target = url.standardizedFileURL
        func walk(_ n: FolderNode) -> FolderNode? {
            if n.url.standardizedFileURL == target { return n }
            for c in n.children { if let hit = walk(c) { return hit } }
            return nil
        }
        for r in rootNodes { if let hit = walk(r) { return hit } }
        return nil
    }

    /// Rewrite stored path prefixes after a folder rename (paths.absolute_path,
    /// tags.parent_dir, starred_folders) in one transaction. Off the main actor;
    /// returns false on failure so the caller can surface it. The actual SQL
    /// lives in `FolderRenameMigration.apply` so it is unit-testable.
    private static func migratePaths(old: String, new: String, newName: String) async -> Bool {
        guard let queue = Database.shared.dbQueue else { return false }
        do {
            try await queue.write { db in
                try FolderRenameMigration.apply(db, old: old, new: new, newName: newName)
            }
            return true
        } catch {
            return false
        }
    }

    /// User-facing folder-op error copy.
    private static func message(for error: FolderOps.OpError, verb: String) -> String {
        switch error {
        case .emptyName:   return "Please enter a folder name."
        case .invalidName: return "A folder name can’t contain “/” or “:”."
        case .collision:   return "A folder with that name already exists here."
        case .ioError:     return "Couldn’t \(verb) the folder. You may not have permission."
        }
    }

    private func reloadCurrentFiles(showLoading: Bool = false, thenIndex: Bool = false,
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
                : FolderReader.files(in: folderURL, showHidden: showHid)
            let merged = raw.map { fresh -> FileNode in
                if let old = existing[fresh.url],
                   old.modifiedAt == fresh.modifiedAt,
                   old.sizeBytes == fresh.sizeBytes {
                    return old
                }
                return fresh
            }
            let sorted = SmartSorter.apply(mode, to: merged, reversed: reversed)
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
                    // in one animated transaction.
                    self.bumpTagChipToken()
                    withAnimation(.easeInOut(duration: AppState.navTransition)) {
                        self.tagChipRows = chipRows
                        self.tagRowReady = true
                    }
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

    /// Recompute the tag-chip labels for the CURRENT scope (the active
    /// collection's members, else the selected folder) off the main thread, then
    /// publish them. The shared entry point for collection changes, tag edits,
    /// and live folder reloads. A fresh folder SELECT instead computes the chips
    /// inline in `reloadCurrentFiles`, so files + chips reveal together (and that
    /// path, not this one, manages the `tagRowReady` gate).
    /// `sortModeOverride` is supplied by the `$tagSortMode` sink: `@Published`
    /// fires in `willSet`, so when the sink runs `self.tagSortMode` still holds
    /// the OLD value — reading it here would order the chips one selection
    /// behind (the "backwards" bug). The sink passes the delivered new value;
    /// every other caller reads the (already-committed) property.
    func reloadTagChips(sortModeOverride: TagSortMode? = nil) {
        tagChipToken &+= 1
        let token = tagChipToken
        let scope = tagSourceFiles
        let recursive = showSubfolders
        let inCollection = activeCollectionID != nil
        guard let queue = Database.shared.dbQueue, !scope.isEmpty else {
            tagChipRows = []
            return
        }
        let paths = scope.map { $0.url.standardizedFileURL.path }
        let simpleDir = (!inCollection && !recursive) ? TagScope.parentDir(ofPath: paths[0]) : nil
        let tagSort = sortModeOverride ?? tagSortMode
        Task.detached(priority: .userInitiated) {
            let rows = TagChipLoader.ordered(
                TagChipLoader.counts(paths: paths, simpleFolderDir: simpleDir, queue: queue),
                sortMode: tagSort)
            await MainActor.run {
                guard token == self.tagChipToken else { return }
                withAnimation(.easeInOut(duration: AppState.navTransition)) {
                    self.tagChipRows = rows
                }
            }
        }
    }

    private func bumpTagChipToken() { tagChipToken &+= 1 }

    func resort() {
        // Don't re-sort search results; they maintain relevance ranking
        guard !isSearchActive else { return }
        currentFiles = SmartSorter.apply(sortMode, to: currentFiles, reversed: sortReversed)
        if let collectionFiles = activeCollectionFiles {
            activeCollectionFiles = SmartSorter.apply(sortMode, to: collectionFiles, reversed: sortReversed)
        }
    }

    // MARK: - Search

    /// Monotonic token so a slow search can't clobber a newer search — or a
    /// dismissal that landed while it was in flight.
    private var searchRequestToken = 0

    func runSearch(_ query: String) async {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            clearSearch()
            return
        }
        searchRequestToken += 1
        let token = searchRequestToken
        // Scope follows the magnifier menu: "All" searches the whole indexed
        // library; "This folder" (default) scopes to the selected folder, and
        // falls back to everywhere when nothing is selected.
        let scope: SearchScope
        if !searchAllFolders, let folder = selectedFolder {
            scope = .currentFolder(folder.url)
        } else {
            scope = .everywhere
        }
        let results = await SearchService.search(query: trimmed, scope: scope)
        // A newer search — or clearSearch() — invalidates this stale result.
        guard token == searchRequestToken else { return }
        isSearchActive = true
        // search results keep relevance rank; sort modes apply to folder browsing only
        currentFiles = results
    }

    func clearSearch() {
        searchRequestToken += 1   // cancel any in-flight search result
        searchQuery = ""
        isSearchActive = false
        reloadCurrentFiles()
    }

    func analyzeCurrentFolder() async {
        let urls = currentFiles
            .filter { $0.kind == .image || $0.kind == .raw || $0.kind == .psd }
            .map { $0.url }
        await AnalyzePipeline.shared.analyze(folder: urls)
        // Re-sort in case visual signals just landed
        resort()
    }

    func analyzeSelected() async {
        guard let url = selectedFile?.url else { return }
        await AnalyzePipeline.shared.analyze(file: url)
    }

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

    // MARK: - Watcher

    private func startWatching(_ url: URL) {
        if watcher == nil {
            watcher = FolderWatcher { [weak self] changedPaths in
                // Search results aren't folder contents — a disk event must
                // not replace them with the watched folder's listing.
                guard let self, !self.isSearchActive else { return }
                self.handleFolderEvent(changedPaths: changedPaths)
            }
        }
        watcher?.watch(url: url, recursive: showSubfolders)
    }

    /// A live disk change landed. Two jobs: (1) refresh the specific media
    /// files that changed — re-hash them (forced, so iCloud's oscillating
    /// metadata can't hide a real edit), drop their stale thumbnails, and
    /// re-analyze new/edited ones; (2) reflect adds/removes/renames in the
    /// grid listing. No folder-wide reindex — only the touched files do work.
    private func handleFolderEvent(changedPaths: [String]) {
        guard let folder = selectedFolder else { return }
        let media = FolderEventFilter.mediaChanges(
            paths: changedPaths, folder: folder.url, recursive: showSubfolders)
        let existing = media.filter { FileManager.default.fileExists(atPath: $0) }
        if !existing.isEmpty {
            Task.detached(priority: .userInitiated) {
                let pairs = existing.map { p -> (URL, AssetKind) in
                    let u = URL(fileURLWithPath: p)
                    return (u, AssetKind.detect(at: u))
                }
                // force: a same-path edit (and every iCloud edit) wouldn't be
                // caught by the size/mtime fast path. silent: no progress pill
                // for a handful of files.
                let changed = await Indexer.shared.indexBatch(
                    pairs, priority: .high, force: true, silent: true)
                await MainActor.run { self.markContentChanged(changed.map { $0.path }) }
                let urls = existing.map { URL(fileURLWithPath: $0) }
                // prewarm covers brand-new files; analyzePending self-gates on
                // a stale analyzed_hash, so it re-tags new + edited only.
                await ThumbnailCache.shared.prewarmToDisk(urls)
                await AnalyzePipeline.shared.analyzePending(in: urls)
            }
        }
        reloadCurrentFiles()
    }
}
