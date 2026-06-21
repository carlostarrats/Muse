//
//  AppState+Indexing.swift
//  Muse
//
//  Active-folder indexing, thumbnail prewarm, the automatic analyze pass, and
//  the duplicates scan. Extracted from AppState.swift in the 2026-06-20
//  code-health refactor (methods only; the `indexingTask` handle and the
//  `markContentChanged` helper stay in the core AppState file because the
//  core folder-load / removeRoot paths also touch them).
//

import Foundation

@MainActor
extension AppState {
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

    /// - verifyICloud: run the background content-verify pass over the iCloud
    ///   files (catches edits made while the app was closed — iCloud
    ///   size/mtime oscillates so the normal fast path can't notice). Only the
    ///   FRESH folder selection asks for this; live FSEvents reloads handle
    ///   their specific changed files directly and must not re-hash the whole
    ///   iCloud folder on every event.
    func scheduleIndexing(for url: URL, verifyICloud: Bool = false) {
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
}
