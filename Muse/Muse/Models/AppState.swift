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
    @Published var currentFiles: [FileNode] = []

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

    /// Whether the right-side detail panel (tags, metadata) is visible.
    /// Presents the duplicates review sheet (set by findDuplicatesInCurrentFolder).
    @Published var duplicatesSheetVisible = false

    /// Active search query. Empty when no search.
    @Published var searchQuery: String = ""

    /// True when search results, not folder contents, are showing in the grid.
    @Published var isSearchActive: Bool = false


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
    @Published var activeCollectionFiles: [FileNode]? = nil

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
    @Published var activeTagPaths: Set<String>?
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
    /// Monotonic token so a slow tag-filter load can't clobber a newer pick.
    /// Not `private`: read/written by `setActiveTag` in AppState+Filters.swift.
    var tagRequestToken = 0

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

    // MARK: - Watcher

    private var watcher: FolderWatcher?
    private var bookmarksCancellable: AnyCancellable?
    private var starsCancellable: AnyCancellable?

    init() {
        updateAutoMoodTimer()

        deletion.onRemove = { [weak self] url in
            guard let self else { return }
            self.currentFiles.removeAll { $0.url == url }
            if self.selectedFile?.url == url { self.selectedFile = nil }
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
        }

        rebuildRootNodes()
        bookmarksCancellable = bookmarks.$roots
            .sink { [weak self] newRoots in self?.rebuildRootNodes(roots: newRoots) }
        // `stars` is a nested ObservableObject; without forwarding its changes,
        // views observing AppState (the sidebar) don't refresh when a folder is
        // pinned/unpinned until some other AppState change republishes. Forward
        // it so Pin/Unpin shows immediately.
        starsCancellable = stars.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }

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
        // A tag filter from the previous folder mustn't empty the new one.
        if activeTagLabel != nil { setActiveTag(nil) }
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

        // Reuse unchanged nodes so live reloads keep tile @State (thumbnails,
        // in-flight animations). A fresh selection clears instead — nothing to
        // reuse — and shows the skeleton while it loads.
        let existing: [URL: FileNode]
        if showLoading {
            existing = [:]
            currentFiles = []
            isLoadingFolder = true
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
            await MainActor.run {
                // A newer selection started while we were loading — drop this.
                guard token == self.folderLoadToken else { return }
                self.currentFiles = sorted
                self.isLoadingFolder = false
                if thenIndex { self.scheduleIndexing(for: folderURL, verifyICloud: verifyICloud) }
            }
        }
    }

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
        // Search always scopes to the folder selected in the sidebar;
        // with nothing selected, fall back to the whole indexed library.
        let scope: SearchScope
        if let folder = selectedFolder {
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
            nodes.append(FileNode(url: child))
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
