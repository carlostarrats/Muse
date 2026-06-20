//
//  AppState+Filters.swift
//  Muse
//
//  Collection + tag-chip filtering: which files the grid shows, the active
//  collection/tag filters, and the add/remove mutations behind them. Split
//  out of AppState for readability; the stored @Published filter state (and
//  the request tokens) live in AppState.
//

import Foundation
import SwiftUI
import GRDB

extension AppState {

    // MARK: - Collections (AI brain)

    /// Open/close the Collections page. Always clears any active collection
    /// filter so opening lands on the card grid (not inside a collection).
    /// The crossfade is driven by the view layer (ContentView animates on
    /// `isCollectionsPage`), so this just flips the flags.
    func toggleCollectionsPage() {
        // Drives the page fade (ContentView.pageReveal) now that there's no
        // ambient animation on isCollectionsPage.
        withAnimation(.easeInOut(duration: AppState.navTransition)) {
            showingCollections.toggle()
        }
        setActiveCollection(nil)
    }

    /// Files the grid should show: the active collection's members when
    /// inside a collection, else the current folder's files; the tag chip
    /// filter narrows either.
    var visibleFiles: [FileNode] {
        // Memoized: recomputed only after one of the inputs changes (they
        // invalidate the cache via didSet in AppState: currentFiles,
        // isSearchActive, activeCollectionFiles, activeTagPaths, gridFilter).
        // The grid reads this many times per render; without the cache the tag
        // filter below re-standardized every path on every read. The date
        // window's `now` is captured fresh per recompute (not at first read), so
        // a filter change re-windows correctly; the only stale-`now` edge is the
        // app sitting idle across a day/week/month/year rollover with NO input
        // change, which the next interaction corrects (accepted). See
        // `_visibleFilesCache`.
        if _visibleFilesValid { return _visibleFilesCache }
        // search results are global; collection/tag filters apply to browsing only
        var base: [FileNode]
        if isSearchActive {
            base = currentFiles
        } else {
            base = activeCollectionFiles ?? currentFiles
            if let tagPaths = activeTagPaths {
                base = base.filter { tagPaths.contains($0.url.standardizedFileURL.path) }
            }
        }
        // Facet filter: the final narrowing step, applied to ALL branches
        // (search included). Reads the values FileNode already carries — no
        // extra resourceValues hit; the memo means this runs only when an input
        // actually changed, not on every grid render.
        //
        // Folder grid cards (the one-level browse view, feat/next-41) are
        // NAVIGATION, not content: they are always kept regardless of the facet
        // filter. Otherwise a Kind filter excluding "Other" — or any date/size
        // facet (a folder's size/mtime is nil-ish) — would hide subfolders and
        // strand drill-in. This is the explicit folder decision feat/next-41's
        // rule requires (collection/search branches carry no folders anyway).
        let result: [FileNode]
        if gridFilter.isActive {
            let now = Date()
            result = base.filter {
                $0.kind == .folder ||
                gridFilter.matches(kind: $0.kind,
                                   sizeBytes: $0.sizeBytes,
                                   modified: $0.modifiedAt,
                                   now: now)
            }
        } else {
            result = base
        }
        _visibleFilesCache = result
        _visibleFilesValid = true
        return result
    }

    /// Files the tag chips derive their labels from: the active collection's
    /// members (library-wide) when inside a collection, else the current
    /// folder's files. Deliberately the UNFILTERED set, so selecting a tag
    /// doesn't collapse the chip list down to just that tag.
    var tagSourceFiles: [FileNode] {
        activeCollectionFiles ?? currentFiles
    }

    /// Set (or clear, with nil) the active collection filter. Loads the
    /// member path set asynchronously; always go through this method
    /// rather than setting `activeCollectionID` directly.
    func setActiveCollection(_ id: String?, animated: Bool = true) {
        clearSelection()
        // ID and member paths land in ONE animated transaction, so the grid
        // cross-fades once to the filtered set — no intermediate frame where
        // the header swapped but the grid hasn't (the old "flash").
        let curve = Animation.easeInOut(duration: AppState.navTransition)
        collectionRequestToken += 1
        guard let id else {
            // Clearing as part of a folder switch is INSTANT (animated: false) so
            // the collection view doesn't tear down in a visible step before the
            // new folder fades in; a normal back-out animates.
            if animated {
                withAnimation(curve) {
                    activeCollectionID = nil
                    activeCollectionPaths = nil
                    activeCollectionFiles = nil
                }
                // Backed out of a collection (the grid returns to the folder) —
                // re-scope the chips to the folder. The folder's grid is already
                // loaded, so no gate.
                reloadTagChips()
            } else {
                activeCollectionID = nil
                activeCollectionPaths = nil
                activeCollectionFiles = nil
                // animated:false means a folder SELECT is in progress; that load
                // computes the chips inline, so don't double-load here.
            }
            return
        }
        let token = collectionRequestToken
        Task { @MainActor in
            guard let q = Database.shared.dbQueue else {
                // Honor the same stale-pick guard as the success path below —
                // a newer pick that landed while this ran must not be clobbered.
                guard token == collectionRequestToken else { return }
                activeCollectionID = id
                activeCollectionPaths = []
                activeCollectionFiles = []
                reloadTagChips()
                return
            }
            let paths = (try? await CollectionStore.alivePaths(
                queue: q, collectionID: id
            )) ?? []
            // Narrow to members under an active root FIRST, using the SAME rule
            // as the badge count (CollectionStore.isUnderAnyRoot) — so the grid
            // and the count agree. A member outside every root (e.g. a stray
            // ~/Downloads file) can't be shown by the sandbox, so it must not
            // appear here or inflate the count. Empty roots → no filter, matching
            // fetchAll's fallback. See the 2026-06-19 count-vs-contents fix.
            let rootPaths = rootNodes.map { $0.url.standardizedFileURL.path }
            let reachable = rootPaths.isEmpty
                ? paths
                : paths.filter { CollectionStore.isUnderAnyRoot($0, roots: rootPaths) }
            // Members that still exist on disk, sorted by the active sort mode.
            let nodes = SmartSorter.apply(sortMode, to: reachable.compactMap { path in
                FileManager.default.fileExists(atPath: path)
                    ? FileNode(url: URL(fileURLWithPath: path)) : nil
            }, reversed: sortReversed)
            // Don't clobber a newer selection that landed while loading.
            if token == collectionRequestToken {
                withAnimation(curve) {
                    activeCollectionID = id
                    activeCollectionPaths = Set(reachable)
                    activeCollectionFiles = nodes
                }
                // Re-scope the chips to the collection's members (library-wide).
                reloadTagChips()
            }
        }
    }

    /// Whether the bulk-tag menu commands (Delete All / Regenerate) may fire.
    /// Their confirmation alerts live on TagChipsRow, which is unmounted during
    /// search and on the Collections card page — firing a request there would
    /// be a silent no-op that pops a ghost alert later when the row remounts.
    /// Gate the menu items to exactly where TagChipsRow is mounted (a real
    /// folder grid or inside a collection) with files present.
    var bulkTagCommandsAvailable: Bool {
        !currentFiles.isEmpty
            && !isSearchActive
            && !(showingCollections && activeCollectionID == nil)
    }

    /// Set the active collection's cover to the given file (right-click on a
    /// tile, or the Edit-menu command). One cover per collection; replaces any
    /// previous choice. No-op outside a collection or for an unindexed file.
    func setCollectionCover(_ file: FileNode) {
        guard let cid = activeCollectionID,
              let q = Database.shared.dbQueue else { return }
        let path = file.url.path
        Task { @MainActor in
            guard let fid = try? await CollectionStore.fileID(queue: q, path: path) else { return }
            try? await CollectionStore.setCover(queue: q, id: cid, fileID: fid)
            await CollectionsEngine.shared.reload()
        }
    }

    // MARK: - Tag chip filter (main grid)

    /// Remove `label` from `urls` (the right-clicked tile or the whole
    /// selection). Tags are auto-generated, but this leaves the files marked
    /// analyzed — same as Delete All Tags — so the pipeline never regenerates
    /// the tag. If the grid is filtered to this tag, the affected tiles drop
    /// out immediately and the chip counts refresh.
    func removeTag(_ label: String, fromURLs urls: [URL]) {
        guard !urls.isEmpty else { return }
        let removed = Set(urls.map { $0.standardizedFileURL.path })
        Task { @MainActor in
            await TagStore.shared.removeLabel(label, fromURLs: urls)
            tagsVersion &+= 1
            if activeTagLabel == label {
                // If nothing here would still carry the tag, the chip is gone
                // and the grid would be stranded empty — go straight back to
                // "All" in ONE transaction (same crossfade as switching tags),
                // rather than emptying the grid first and then repopulating.
                let anyLeft = visibleFiles.contains {
                    !removed.contains($0.url.standardizedFileURL.path)
                }
                if !anyLeft {
                    setActiveTag(nil)
                    return
                }
                activeTagPaths?.subtract(removed)
            }
            clearSelection()
        }
    }

    /// Remove `urls` from collection `id` (the right-clicked tile or the whole
    /// selection). Collections are manual, so the removal simply sticks (an
    /// exclusion is also recorded as a safeguard). If that collection is open,
    /// the affected tiles drop out immediately.
    func removeFromCollection(_ id: String, urls: [URL]) {
        guard !urls.isEmpty, let q = Database.shared.dbQueue else { return }
        let paths = urls.map { $0.standardizedFileURL.path }
        let removed = Set(paths)
        Task { @MainActor in
            let ids = (try? await CollectionStore.fileIDs(queue: q, paths: paths)) ?? []
            for fid in ids {
                try? await CollectionStore.removeFile(queue: q, fileID: fid, collectionID: id)
            }
            await CollectionsEngine.shared.reload()
            if activeCollectionID == id {
                // If removal empties the open collection it disappears from the
                // engine (its header stops rendering) and the grid would be
                // stranded with no back arrow — return to the library in one
                // transaction, mirroring the tag path.
                let anyLeft = (activeCollectionFiles ?? []).contains {
                    !removed.contains($0.url.standardizedFileURL.path)
                }
                if !anyLeft {
                    setActiveCollection(nil)
                    return
                }
                activeCollectionPaths?.subtract(removed)
                activeCollectionFiles?.removeAll {
                    removed.contains($0.url.standardizedFileURL.path)
                }
                // Collection membership shrank — refresh the chip counts (removing
                // from a collection doesn't bump tagsVersion, so do it explicitly).
                reloadTagChips()
            }
            clearSelection()
        }
    }

    /// Open the "Name Collection" prompt. With a fallback path, seed the new
    /// collection from the effective selection (grid right-click); with nil,
    /// create an empty collection (Collections-page "+"). Captures the paths now
    /// (preserves the right-clicked-but-unselected-tile case); no DB write
    /// happens until confirm.
    func requestNewCollection(fallback path: String? = nil) {
        // Ordering matters: set pendingNewCollectionPaths BEFORE the @Published
        // newCollectionRequest. The alert's message reads pendingNewCollectionPaths
        // (which isn't @Published), and it's newCollectionRequest's change that
        // drives body re-eval / presentation — so the paths must already hold their
        // final value when the message renders.
        pendingNewCollectionPaths = path.map { p in
            effectiveSelectionURLs(fallback: p)
                .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory != true }
                .map { $0.standardizedFileURL.path }
        } ?? []
        newCollectionNameDraft = ""
        newCollectionRequest = true
    }

    /// Create a collection under the typed name. A blank/whitespace name creates
    /// nothing. Seeds it with the captured selection when there is one.
    func confirmNewCollection() {
        // Capture paths/name into locals BEFORE clearing state: setting
        // newCollectionRequest = false drives the alert's binding setter, which
        // calls cancelNewCollection() and wipes pendingNewCollectionPaths/draft.
        // The locals are value-type copies, so the in-flight Task is unaffected.
        let paths = pendingNewCollectionPaths
        let name = newCollectionNameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        newCollectionRequest = false
        pendingNewCollectionPaths = []
        guard !name.isEmpty else { return }
        Task { @MainActor in
            guard let q = Database.shared.dbQueue else { return }
            guard let newID = try? await CollectionStore.createManual(queue: q) else { return }
            try? await CollectionStore.rename(queue: q, id: newID, name: name)
            if !paths.isEmpty {
                let ids = (try? await CollectionStore.fileIDs(queue: q, paths: paths)) ?? []
                for id in ids {
                    try? await CollectionStore.addFile(queue: q, fileID: id, collectionID: newID)
                }
            }
            await CollectionsEngine.shared.reload()
        }
    }

    /// Dismiss the prompt without creating anything.
    func cancelNewCollection() {
        newCollectionRequest = false
        pendingNewCollectionPaths = []
        newCollectionNameDraft = ""
    }

    /// Set (or clear, with nil) the tag chip filter — same single-transaction
    /// animated swap as the collection filter.
    func setActiveTag(_ label: String?, animated: Bool = true) {
        clearSelection()
        let curve = Animation.easeInOut(duration: AppState.navTransition)
        tagRequestToken += 1
        guard let label else {
            // Clearing as part of a folder switch is INSTANT (animated: false), so
            // the selected-tag view vanishes in one frame rather than animating
            // away before the new folder appears.
            if animated {
                withAnimation(curve) {
                    activeTagLabel = nil
                    activeTagPaths = nil
                }
            } else {
                activeTagLabel = nil
                activeTagPaths = nil
            }
            return
        }
        let token = tagRequestToken
        Task { @MainActor in
            guard let q = Database.shared.dbQueue else { return }
            let paths: [String] = (try? await q.read { db -> [String] in
                // A path matches only if the tag is scoped to ITS folder —
                // tags are per-location, so a duplicate sharing the file_id in
                // an untagged folder must not be pulled in.
                let rows = try Row.fetchAll(db, sql: """
                    SELECT p.absolute_path AS ap, t.parent_dir AS pd
                    FROM paths p JOIN tags t ON t.file_id = p.file_id
                    WHERE p.is_alive = 1 AND t.label = ?
                    """, arguments: [label])
                var out: [String] = []
                for r in rows {
                    guard let ap: String = r["ap"] else { continue }
                    let pd: String? = r["pd"]
                    if pd == TagScope.parentDir(ofPath: ap) { out.append(ap) }
                }
                return out
            }) ?? []
            if token == tagRequestToken {
                withAnimation(curve) {
                    activeTagLabel = label
                    activeTagPaths = Set(paths)
                }
            }
        }
    }

    // MARK: - Sidebar collections (independent of the Collections page)

    /// The engine's visible collections, ordered by the sidebar's own sort mode
    /// (`sidebarCollectionSortMode`) — never the Collections-page sort. The
    /// sidebar UI reads this; it re-runs when CollectionsEngine publishes.
    var sidebarCollections: [CollectionStore.Loaded] {
        let loaded = CollectionsEngine.shared.collections
        let items = loaded.map {
            SidebarCollectionSort.Item(id: $0.collection.id,
                                       name: $0.collection.name,
                                       createdAt: $0.collection.created_at,
                                       updatedAt: $0.collection.updated_at,
                                       sortOrder: $0.collection.sort_order)
        }
        let orderedIDs = SidebarCollectionSort.order(items, by: sidebarCollectionSortMode)
        let byID = Dictionary(uniqueKeysWithValues: loaded.map { ($0.collection.id, $0) })
        return orderedIDs.compactMap { byID[$0] }
    }

    /// Move a collection one slot in Manual mode (Move Up/Down). No-op otherwise
    /// or at the ends.
    func moveSidebarCollection(id: String, by delta: Int) {
        guard sidebarCollectionSortMode == .manual else { return }
        var ids = sidebarCollections.map { $0.collection.id }
        guard let from = ids.firstIndex(of: id) else { return }
        let to = from + delta
        guard ids.indices.contains(to) else { return }
        ids.swapAt(from, to)
        // Animate so menu/keyboard Move Up/Down slides like the drag (the in-memory
        // reorder in reorderSidebarCollections is synchronous, so this animates).
        withAnimation(.easeInOut(duration: 0.2)) {
            reorderSidebarCollections(ids)
        }
    }

    /// Commit a new full order (drag result or Move Up/Down). Applies the order
    /// to the in-memory engine list SYNCHRONOUSLY, then persists async.
    ///
    /// The synchronous in-memory update matters: the drag commit clears its lift
    /// offsets in a non-animated transaction expecting the list to already be in
    /// the new order (exactly how the folder reorder relies on `bookmarks.$roots`
    /// delivering synchronously). If we only did the async DB write + reload, the
    /// offsets would clear a frame before the new order arrived and the dropped
    /// row would visibly snap/flash to catch up. Updating each collection's
    /// in-memory `sort_order` reorders `sidebarCollections` (Manual sorts by it)
    /// in the same transaction.
    func reorderSidebarCollections(_ orderedIDs: [String]) {
        let rank = Dictionary(uniqueKeysWithValues:
            orderedIDs.enumerated().map { ($0.element, $0.offset) })
        for i in CollectionsEngine.shared.collections.indices {
            if let r = rank[CollectionsEngine.shared.collections[i].collection.id] {
                CollectionsEngine.shared.collections[i].collection.sort_order = r
            }
        }
        Task { @MainActor in
            guard let q = Database.shared.dbQueue else { return }
            try? await CollectionStore.persistOrder(queue: q, orderedIDs: orderedIDs)
        }
    }
}
