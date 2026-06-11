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

    // MARK: - Modes

    /// Q2: include subfolders in the grid contents.
    @Published var showSubfolders: Bool = false

    /// Q33: show dotfiles / hidden files. Default off.
    @Published var showHidden: Bool = false

    /// Active sort mode (default = date modified desc per Q24 generalist).
    @Published var sortMode: SortMode = .dateModified

    /// Whether the right-side detail panel (tags, metadata) is visible.
    @Published var detailPanelVisible: Bool = false

    /// Active search query. Empty when no search.
    @Published var searchQuery: String = ""

    /// True when search results, not folder contents, are showing in the grid.
    @Published var isSearchActive: Bool = false

    /// Q21: search defaults to current folder; toggle to search everywhere.
    @Published var searchEverywhere: Bool = false

    /// Whether the chat panel is shown (only meaningful when ChatService.isAvailable).
    @Published var chatPanelVisible: Bool = false

    /// Grid vs Globe view mode for the active folder.
    enum ViewMode: String { case grid, globe }
    @Published var viewMode: ViewMode = .grid

    // MARK: - Collections (AI brain)

    /// Whether the collections overlay is showing.
    @Published var collectionsOverlayVisible = false

    /// Collection currently expanded/inspected in the overlay, if any.
    @Published var activeCollectionID: String? = nil

    /// Alive absolute paths of the active collection's members. nil when
    /// no collection filter is active (FileNode has no DB id, so the grid
    /// filter resolves membership by path).
    @Published var activeCollectionPaths: Set<String>? = nil

    /// Files the grid should show: currentFiles, optionally narrowed to
    /// the active collection's members.
    var visibleFiles: [FileNode] {
        // search results are global; collection filter applies to browsing only
        if isSearchActive { return currentFiles }
        guard let paths = activeCollectionPaths else { return currentFiles }
        return currentFiles.filter { paths.contains($0.url.standardizedFileURL.path) }
    }

    /// Set (or clear, with nil) the active collection filter. Loads the
    /// member path set asynchronously; always go through this method
    /// rather than setting `activeCollectionID` directly.
    func setActiveCollection(_ id: String?) {
        activeCollectionID = id
        guard let id else {
            activeCollectionPaths = nil
            return
        }
        Task { @MainActor in
            guard let q = Database.shared.dbQueue else {
                activeCollectionPaths = []
                return
            }
            let paths = (try? await CollectionStore.alivePaths(
                queue: q, collectionID: id
            )) ?? []
            // Don't clobber a newer selection that landed while loading.
            if activeCollectionID == id {
                activeCollectionPaths = Set(paths)
            }
        }
    }

    // MARK: - Water shader

    @Published var fluidEnabled: Bool = false
    @Published var fluidViewportSize: CGSize = .zero
    let fluidSim = FluidSim()
    @Published var fluidDispImage: Image = FluidSim.neutralImage
    private var fluidCancellable: AnyCancellable?

    // MARK: - Watcher

    private var watcher: FolderWatcher?
    private var bookmarksCancellable: AnyCancellable?

    init() {
        // Forward fluid sim displacement, throttled
        fluidCancellable = fluidSim.$dispImage
            .throttle(for: .milliseconds(33), scheduler: RunLoop.main, latest: true)
            .assign(to: \.fluidDispImage, on: self)

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
        reloadCurrentFiles()
        startWatching(folder.url)
        scheduleIndexing(for: folder.url)
    }

    /// Kick off active-folder indexing on the high-priority queue.
    private func scheduleIndexing(for url: URL) {
        let files = currentFiles
        Task.detached(priority: .userInitiated) {
            let pairs = files.compactMap { f -> (URL, AssetKind)? in
                guard f.kind != .folder, f.kind.hasNativeViewer || f.kind == .archive else { return nil }
                return (f.url, f.kind)
            }
            await Indexer.shared.indexBatch(pairs, priority: .high)
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
        currentFiles = SmartSorter.apply(sortMode, to: raw)
    }

    func resort() {
        // Don't re-sort search results; they maintain relevance ranking
        guard !isSearchActive else { return }
        currentFiles = SmartSorter.apply(sortMode, to: currentFiles)
    }

    // MARK: - Search

    func runSearch(_ query: String) async {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            clearSearch()
            return
        }
        let scope: SearchScope
        if searchEverywhere {
            scope = .everywhere
        } else if let folder = selectedFolder {
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
                self?.reloadCurrentFiles()
            }
        }
        watcher?.watch(url: url, recursive: showSubfolders)
    }
}
