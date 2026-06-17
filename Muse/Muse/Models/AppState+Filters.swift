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

extension AppState {

    // MARK: - Collections (AI brain)

    /// Open/close the Collections page. Always clears any active collection
    /// filter so opening lands on the card grid (not inside a collection).
    /// The crossfade is driven by the view layer (ContentView animates on
    /// `isCollectionsPage`), so this just flips the flags.
    func toggleCollectionsPage() {
        showingCollections.toggle()
        setActiveCollection(nil)
    }

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
    func setActiveCollection(_ id: String?) {
        clearSelection()
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
                // Honor the same stale-pick guard as the success path below —
                // a newer pick that landed while this ran must not be clobbered.
                guard token == collectionRequestToken else { return }
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
            }, reversed: sortReversed)
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
            }
            clearSelection()
        }
    }

    /// Set (or clear, with nil) the tag chip filter — same single-transaction
    /// animated swap as the collection filter.
    func setActiveTag(_ label: String?) {
        clearSelection()
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
}
