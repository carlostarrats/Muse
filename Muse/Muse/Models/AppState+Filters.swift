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
            // Search results are global, but the tag chips now narrow WITHIN the
            // result set (AND). activeTagPaths is library-wide for the selected
            // labels, so it filters correctly across This-Folder and All scope.
            base = currentFiles
            if let tagPaths = activeTagPaths {
                base = base.filter { tagPaths.contains($0.url.standardizedFileURL.path) }
            }
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
        // Facet filter narrows by leaf: each file maps to exactly one KindFacet
        // (image formats break out into JPEG/PNG/…/imageOther; folders are the
        // `.folder` leaf). The file extension picks the image-format leaf and
        // comes from the URL the node already holds — no extra IO.
        let result: [FileNode]
        if gridFilter.isActive {
            result = base.filter {
                gridFilter.matches(kind: $0.kind, ext: $0.url.pathExtension)
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
        // During search the chips derive from the search RESULT set so the
        // offered tags are relevant (and the per-folder fast path is skipped
        // since results can span folders — see reloadTagChips).
        if isSearchActive { return currentFiles }
        return activeCollectionFiles ?? currentFiles
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
            let paths = (try? await CollectionStore.alivePathsResolving(
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
            // Existence sweep + FileNode stat + (for Color/Shape) SmartSorter's
            // DB read are all per-member I/O — run OFF the main actor; the
            // token guard below already covers the extra suspension.
            let mode = sortMode, rev = sortReversed
            let nodes = await Task.detached(priority: .userInitiated) { () -> [FileNode] in
                SmartSorter.apply(mode, to: reachable.compactMap { path in
                    FileManager.default.fileExists(atPath: path)
                        ? FileNode(url: URL(fileURLWithPath: path)) : nil
                }, reversed: rev)
            }.value
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

    /// Export-ready file URLs for ANY collection by id — not necessarily the
    /// currently OPEN one (unlike `ShareCollectionButton.exportURLs`, which
    /// reads the live `visibleFiles`). Same reachability rule as
    /// `setActiveCollection`: members must sit under a currently mounted
    /// root, so a sidebar-menu export never offers a file the sandbox can't
    /// actually read.
    func exportableURLs(forCollection id: String) async -> [URL] {
        // No folders → nothing reachable to export, matching the UI guards
        // that hide collections entirely when `rootNodes` is empty. This is
        // ALWAYS a user-initiated call (a menu tap), never the launch-race
        // window `setActiveCollection` tolerates, so — unlike there — an
        // empty-roots fallback to "unfiltered" would be wrong, not just
        // inconsistent.
        guard !rootNodes.isEmpty, let q = Database.shared.dbQueue else { return [] }
        let paths = (try? await CollectionStore.alivePathsResolving(queue: q, collectionID: id)) ?? []
        let rootPaths = rootNodes.map { $0.url.standardizedFileURL.path }
        let reachable = paths.filter { CollectionStore.isUnderAnyRoot($0, roots: rootPaths) }
        // Order the pages by the SAME active sort as the open-collection grid
        // (setActiveCollection runs SmartSorter over its reachable members). A
        // sidebar-menu export of a collection must lay out identically to
        // opening it and exporting from its header — without this the PDF /
        // Drive share come out in raw `alivePaths` (DB add-order) instead.
        // Same off-main rule as setActiveCollection: per-member existence
        // stats + the indexed sorts' DB read don't belong on the main actor.
        let mode = sortMode, rev = sortReversed
        let nodes = await Task.detached(priority: .userInitiated) { () -> [FileNode] in
            SmartSorter.apply(mode, to: reachable.compactMap { path in
                FileManager.default.fileExists(atPath: path)
                    ? FileNode(url: URL(fileURLWithPath: path)) : nil
            }, reversed: rev)
        }.value
        return nodes.map { $0.url }
    }

    /// Whether the bulk-tag menu commands (Delete All / Regenerate) may fire.
    /// Their confirmation alerts live on TagChipsRow, which is unmounted during
    /// search and on the Collections card page — firing a request there would
    /// be a silent no-op that pops a ghost alert later when the row remounts.
    /// Gate the menu items to exactly where TagChipsRow is mounted (a real
    /// folder grid or inside a collection) with files present.
    var bulkTagCommandsAvailable: Bool {
        // tagSourceFiles, not currentFiles: inside a collection the grid shows
        // the collection's members while currentFiles is still the underlying
        // FOLDER — gating on the folder wrongly disables the commands when it
        // happens to be empty (inverse of the wrong-target class the
        // tagSourceFiles rule exists for).
        !tagSourceFiles.isEmpty
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

    /// Open the rename modal for the currently-active collection (menu-bar
    /// "Collections → Rename Collection…"). Routes to the SAME dialog as the
    /// sidebar "Rename…" so every "Rename Collection…" entry point behaves
    /// alike (and like folder rename) — no-op outside a collection.
    func requestRenameActiveCollection() {
        guard let id = activeCollectionID,
              let name = CollectionsEngine.shared.collections
                  .first(where: { $0.collection.id == id })?.collection.name
        else { return }
        collectionRenameAlertRequest = CollectionRenameAlertRequest(id: id, currentName: name)
    }

    /// Persist a collection rename from the shared modal (every "Rename
    /// Collection…" entry point — sidebar, menu-bar, in-page title/Edit pill —
    /// routes here). Trims, no-ops on an empty name, writes via `CollectionStore`,
    /// then reloads the engine. Never navigates into the collection.
    func renameCollection(id: String, to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let q = Database.shared.dbQueue else { return }
        Task { @MainActor in
            try? await CollectionStore.rename(queue: q, id: id, name: trimmed)
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
            if activeTagLabels.contains(label) {
                // A multi-tag delete only comes from the chip's full-view "Delete
                // Tag…" (the partial "Remove Tag from Selection" is gated to a
                // single active tag), so the deleted label is now gone from this
                // view. Drop it from the set and recompute the remaining
                // intersection — otherwise the banner keeps naming a tag whose
                // chip has vanished, with no way to deselect it.
                if activeTagLabels.count > 1 {
                    setActiveTags(activeTagLabels.filter { $0 != label })
                    return
                }
                // Single tag: the affected files leave the intersection — subtract
                // them from activeTagPaths (a file still in the intersection must
                // carry the tag, so any that lost it is in `removed`). If nothing
                // here would still carry the tag the grid is stranded empty, so
                // fall back to "All".
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

    /// Drop a just-trashed file from the OPEN collection's view state. The grid
    /// renders `activeCollectionFiles` while a collection is on screen, so
    /// removing a deleted file only from `currentFiles` leaves a ghost tile
    /// that reappears after the burn fade and rides into "Save to…"/"Share
    /// Drive Link" (both read `visibleFiles`). Call alongside every
    /// currentFiles removal. `path` must be a standardized path.
    func dropFromActiveCollection(path: String) {
        activeCollectionPaths?.remove(path)
        activeCollectionFiles?.removeAll { $0.url.standardizedFileURL.path == path }
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
        newCollectionRequest = true
    }

    /// Create a collection under the typed name. A blank/whitespace name creates
    /// nothing. Seeds it with the captured selection when there is one.
    func confirmNewCollection(name rawName: String) {
        // Capture paths/name into locals BEFORE clearing state: setting
        // newCollectionRequest = false drives the alert's binding setter, which
        // calls cancelNewCollection() and wipes pendingNewCollectionPaths.
        // The locals are value-type copies, so the in-flight Task is unaffected.
        // The typed name arrives from the alert's local @State (see
        // NameCollectionAlert) — kept off AppState so typing doesn't republish.
        let paths = pendingNewCollectionPaths
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
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
    }

    /// Per-label alive-path query, scoped per `parent_dir` (tags are
    /// per-location: a duplicate sharing the file_id in an untagged folder must
    /// NOT be pulled in). Returns the absolute paths carrying `label` in their
    /// own folder. SYNCHRONOUS by design so `setActiveTags` resolves the filter
    /// within the click's own runloop turn (bar + grid swap commit in one
    /// render); the query is tiny and indexed.
    private func pathsForTagSync(_ label: String) -> [String] {
        guard let q = Database.shared.dbQueue else { return [] }
        return (try? q.read { db -> [String] in
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
    }

    /// Core tag-filter mutation: set the selection to exactly `labels` (ordered)
    /// and recompute `activeTagPaths` as the INTERSECTION of each label's path
    /// set (files carrying ALL of them). Empty `labels` clears the filter. One
    /// query per label (selection sizes are tiny).
    ///
    /// Both `activeTagLabels` AND `activeTagPaths` commit SYNCHRONOUSLY within the
    /// click's runloop turn (see the body for why — bar + grid swap in one render).
    /// Committing the labels synchronously also keeps two fast Cmd-clicks correct:
    /// each reads a fresh set, so neither drops the other's selection — the bug an
    /// earlier async-Task design hit (the first pick was lost; a double plain-click
    /// failed to clear).
    func setActiveTags(_ labels: [String]) {
        clearSelection()
        activeTagLabels = labels
        guard !labels.isEmpty else {
            activeTagPaths = nil
            return
        }
        // Resolve the intersection SYNCHRONOUSLY so the filter bar (driven by
        // `activeTagLabels`) and the grid swap (driven by the resolved
        // `activeTagPaths`) commit in the SAME render — one atomic snap.
        // Resolving in a Task committed the labels a frame BEFORE the paths, so
        // the bar grew the row and shoved the still-unfiltered images down, and
        // only THEN did the grid swap to the filtered set: the "slide down, then
        // replace" jag the owner saw. The per-label query is tiny and indexed; a
        // main-thread read for a user click is cheap — it only ever waits behind
        // an in-flight write on the serial queue, a few ms and rare. (No
        // `withAnimation`: the swap is `.transition(.identity)`, a hard cut, so
        // the whole filter lands as one instant change with nothing to glide.)
        var sets: [Set<String>] = []
        for label in labels {
            sets.append(Set(pathsForTagSync(label)))
        }
        activeTagPaths = sets.dropFirst().reduce(sets.first ?? Set<String>()) {
            $0.intersection($1)
        }
    }

    /// Set (or clear, with nil) a SINGLE active tag — plain-click / clear.
    func setActiveTag(_ label: String?) {
        setActiveTags(label.map { [$0] } ?? [])
    }

    /// Cmd-click toggle: add the label if absent, remove it if present;
    /// recomputes the intersection. Emptying the set clears the filter.
    func toggleActiveTag(_ label: String) {
        setActiveTags(TagSelection.toggling(activeTagLabels, label))
    }

    // MARK: - Sidebar collections (independent of the Collections page)

    /// The engine's visible collections, ordered by the sidebar's own sort mode
    /// (`sidebarCollectionSortMode`) — never the Collections-page sort. The
    /// sidebar UI reads this; it re-runs when CollectionsEngine publishes.
    var sidebarCollections: [CollectionStore.Loaded] {
        // Gate on BOTH a real root AND reachable content. Content catches the
        // always-present, empty iCloud "Muse" root (folder-existence alone missed it
        // — the shipped bug); `rootNodes` catches genuine zero-roots (the reachable
        // sentinel reads "unknown → has content" before roots are pushed, which alone
        // would show ghost collections with stale counts at zero folders). Underlying
        // rows are untouched and reappear the moment reachable images exist again.
        guard !rootNodes.isEmpty, CollectionsEngine.shared.hasReachableContent else { return [] }
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
