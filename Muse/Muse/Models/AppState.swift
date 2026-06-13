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

    // MARK: - Active folder + grid contents

    @Published var selectedFolder: FolderNode?

    /// Files in the selected folder (or, if recursive, including subfolders).
    @Published var currentFiles: [FileNode] = []

    /// Currently selected file (drives preview/detail).
    @Published var selectedFile: FileNode?

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

    /// Files the grid should show: the active collection's members when
    /// inside a collection, else the current folder's files; the tag chip
    /// filter narrows either.
    var visibleFiles: [FileNode] {
        // search results are global; collection/tag filters apply to browsing only
        if isSearchActive { return currentFiles }
        var files = activeCollectionFiles ?? currentFiles
        if let tagPaths = activeTagPaths {
            files = files.filter { tagPaths.contains($0.url.standardizedFileURL.path) }
        }
        return files
    }

    /// Set (or clear, with nil) the active collection filter. Loads the
    /// member path set asynchronously; always go through this method
    /// rather than setting `activeCollectionID` directly.
    func setActiveCollection(_ id: String?) {
        // ID and member paths land in ONE animated transaction, so the grid
        // cross-fades once to the filtered set — no intermediate frame where
        // the header swapped but the grid hasn't (the old "flash").
        let curve = Animation.easeInOut(duration: 0.28)
        collectionRequestToken += 1
        guard let id else {
            withAnimation(curve) {
                activeCollectionID = nil
                activeCollectionPaths = nil
                activeCollectionFiles = nil
            }
            return
        }
        let token = collectionRequestToken
        Task { @MainActor in
            guard let q = Database.shared.dbQueue else {
                activeCollectionID = id
                activeCollectionPaths = []
                activeCollectionFiles = []
                return
            }
            let paths = (try? await CollectionStore.alivePaths(
                queue: q, collectionID: id
            )) ?? []
            // Members that still exist on disk, library-wide, sorted by
            // the active sort mode.
            let nodes = SmartSorter.apply(sortMode, to: paths.compactMap { path in
                FileManager.default.fileExists(atPath: path)
                    ? FileNode(url: URL(fileURLWithPath: path)) : nil
            })
            // Don't clobber a newer selection that landed while loading.
            if token == collectionRequestToken {
                withAnimation(curve) {
                    activeCollectionID = id
                    activeCollectionPaths = Set(paths)
                    activeCollectionFiles = nodes
                }
            }
        }
    }

    /// Monotonic token so a slow collection load can't clobber a newer pick.
    private var collectionRequestToken = 0

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
    private var tagRequestToken = 0

    /// Set (or clear, with nil) the tag chip filter — same single-transaction
    /// animated swap as the collection filter.
    func setActiveTag(_ label: String?) {
        let curve = Animation.easeInOut(duration: 0.28)
        tagRequestToken += 1
        guard let label else {
            withAnimation(curve) {
                activeTagLabel = nil
                activeTagPaths = nil
            }
            return
        }
        let token = tagRequestToken
        Task { @MainActor in
            guard let q = Database.shared.dbQueue else { return }
            let paths: [String] = (try? await q.read { db in
                try String.fetchAll(db, sql: """
                    SELECT p.absolute_path FROM paths p
                    JOIN tags t ON t.file_id = p.file_id
                    WHERE p.is_alive = 1 AND t.label = ?
                    """, arguments: [label])
            }) ?? []
            if token == tagRequestToken {
                withAnimation(curve) {
                    activeTagLabel = label
                    activeTagPaths = Set(paths)
                }
            }
        }
    }

    // MARK: - Water shader

    @Published var fluidEnabled: Bool = false {
        didSet {
            // The CPU sim ticks at 60fps — only while the effect is on.
            if fluidEnabled { fluidSim.start() } else { fluidSim.stop() }
        }
    }
    @Published var fluidViewportSize: CGSize = .zero
    let fluidSim = FluidSim()
    @Published var fluidDispImage: Image = FluidSim.neutralImage
    private var fluidCancellable: AnyCancellable?

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
            Task { @MainActor in
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

    init() {
        updateAutoMoodTimer()

        // Forward fluid sim displacement, throttled
        fluidCancellable = fluidSim.$dispImage
            .throttle(for: .milliseconds(33), scheduler: RunLoop.main, latest: true)
            .assign(to: \.fluidDispImage, on: self)

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
            .sink { [weak self] _ in self?.rebuildRootNodes() }

        // App Intents wiring
        NotificationCenter.default.addObserver(
            forName: .museOpenFolder, object: nil, queue: .main
        ) { [weak self] note in
            guard let url = note.userInfo?["url"] as? URL else { return }
            Task { @MainActor in
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

    private func rebuildRootNodes() {
        let nodes: [FolderNode] = bookmarks.roots.compactMap { root in
            guard let url = bookmarks.url(for: root) else { return nil }
            return FolderNode(url: url, displayName: root.displayName, isRoot: true)
        }
        rootNodes = nodes
        if activeRoot == nil, let first = bookmarks.roots.first {
            select(rootForFirstFolder: first)
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
            activeRoot = bookmarks.roots.first
            selectedFolder = nil
            currentFiles = []
            selectedFile = nil
        }
        rebuildRootNodes()
    }

    // MARK: - Folder selection

    func select(folder: FolderNode) {
        selectedFolder = folder
        selectedFile = nil
        // A tag filter from the previous folder mustn't empty the new one.
        if activeTagLabel != nil { setActiveTag(nil) }
        reloadCurrentFiles()
        startWatching(folder.url)
        scheduleIndexing(for: folder.url)
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
    private func scheduleIndexing(for url: URL) {
        let files = currentFiles
        Task.detached(priority: .userInitiated) {
            let pairs = files.compactMap { f -> (URL, AssetKind)? in
                guard f.kind != .folder, f.kind.hasNativeViewer || f.kind == .archive else { return nil }
                return (f.url, f.kind)
            }
            await Indexer.shared.indexBatch(pairs, priority: .high)
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
            await AnalyzePipeline.shared.analyzePending(in: imageURLs)
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

    private func reloadCurrentFiles() {
        guard let folder = selectedFolder else {
            currentFiles = []
            return
        }
        let raw: [FileNode]
        if showSubfolders {
            raw = recursiveFiles(at: folder.url)
        } else {
            raw = FolderReader.files(in: folder.url, showHidden: showHidden)
        }
        // Reloads rebuild FileNodes with fresh UUIDs; reuse the existing
        // node when the file is unchanged so tile identity (and @State —
        // thumbnails, in-flight animations) survives FSEvents reloads.
        let existing = Dictionary(currentFiles.map { ($0.url, $0) },
                                  uniquingKeysWith: { a, _ in a })
        let merged = raw.map { fresh in
            if let old = existing[fresh.url],
               old.modifiedAt == fresh.modifiedAt,
               old.sizeBytes == fresh.sizeBytes {
                return old
            }
            return fresh
        }
        currentFiles = SmartSorter.apply(sortMode, to: merged)
    }

    func resort() {
        // Don't re-sort search results; they maintain relevance ranking
        guard !isSearchActive else { return }
        currentFiles = SmartSorter.apply(sortMode, to: currentFiles)
        if let collectionFiles = activeCollectionFiles {
            activeCollectionFiles = SmartSorter.apply(sortMode, to: collectionFiles)
        }
    }

    // MARK: - Search

    func runSearch(_ query: String) async {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            clearSearch()
            return
        }
        // Search always scopes to the folder selected in the sidebar;
        // with nothing selected, fall back to the whole indexed library.
        let scope: SearchScope
        if let folder = selectedFolder {
            scope = .currentFolder(folder.url)
        } else {
            scope = .everywhere
        }
        let results = await SearchService.search(query: trimmed, scope: scope)
        isSearchActive = true
        // search results keep relevance rank; sort modes apply to folder browsing only
        currentFiles = results
    }

    func clearSearch() {
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

    private func recursiveFiles(at url: URL) -> [FileNode] {
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
        return nodes.sorted { ($0.modifiedAt ?? .distantPast) > ($1.modifiedAt ?? .distantPast) }
    }

    func toggleSubfolders() {
        showSubfolders.toggle()
        reloadCurrentFiles()
    }

    // MARK: - Watcher

    private func startWatching(_ url: URL) {
        if watcher == nil {
            watcher = FolderWatcher { [weak self] in
                // Search results aren't folder contents — a disk event must
                // not replace them with the watched folder's listing.
                guard let self, !self.isSearchActive else { return }
                self.reloadCurrentFiles()
            }
        }
        watcher?.watch(url: url, recursive: showSubfolders)
    }
}
