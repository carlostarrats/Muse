//
//  AppState+Watcher.swift
//  Muse
//
//  FSEvents live-disk-sync wiring. Extracted from AppState.swift in the
//  2026-06-20 code-health refactor (methods only; the `watcher` handle stays
//  in the core file because it's a stored property).
//

import Foundation

@MainActor
extension AppState {
    func startWatching(_ url: URL) {
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
