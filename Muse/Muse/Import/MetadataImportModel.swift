//
//  MetadataImportModel.swift
//  Muse
//
//  Orchestrates one run of File > Import Keywords & Ratings…: enumerate the
//  folder (always recursive — the user picked THIS folder, the grid's
//  subfolder toggle is irrelevant here), index it so tags have (file_id,
//  parent_dir) rows to land on, then per file read metadata OFF-MAIN and
//  apply through the tested seams. Idempotent: tags insert-or-promote,
//  ratings fill gaps only. Cancel-safe: work already applied stays (a
//  re-run finishes the rest and changes nothing already done).
//

import Foundation
import SwiftUI

@MainActor
final class MetadataImportModel: ObservableObject {

    enum Phase: Equatable {
        case running(done: Int, total: Int)
        case done(imported: Int, none: Int, skipped: Int)
    }

    @Published private(set) var phase: Phase = .running(done: 0, total: 0)

    private var task: Task<Void, Never>?

    func start(folder: URL, appState: AppState) {
        guard task == nil else { return }
        task = Task { [weak self, weak appState] in
            guard let self else { return }

            // 1. Enumerate (off-main), image kinds only — the kinds that
            //    carry IPTC/XMP. Always recursive; hidden files excluded.
            let files = await Task.detached(priority: .userInitiated) {
                AppState.enumerateRecursive(at: folder, showHidden: false)
                    .filter { $0.kind == .image || $0.kind == .raw || $0.kind == .psd }
            }.value
            if Task.isCancelled { return }
            self.phase = .running(done: 0, total: files.count)

            // 2. Index first: tag writes silently no-op on unknown paths.
            //    indexBatch skips dataless placeholders itself.
            let pairs = files.map { ($0.url, $0.kind) }
            _ = await Indexer.shared.indexBatch(pairs, priority: .high)
            if Task.isCancelled { return }

            guard let queue = Database.shared.dbQueue else {
                self.phase = .done(imported: 0, none: 0, skipped: files.count)
                return
            }

            var imported = 0, none = 0, skipped = 0
            var touched: [URL] = []

            for (index, file) in files.enumerated() {
                if Task.isCancelled { break }
                self.phase = .running(done: index, total: files.count)
                let url = file.url

                let extracted: MetadataKeywordReader.Extracted
                do {
                    extracted = try await Task.detached(priority: .userInitiated) {
                        try MetadataKeywordReader.read(url: url)
                    }.value
                } catch {
                    skipped += 1
                    continue
                }
                if extracted.isEmpty { none += 1; continue }

                let absPath = url.standardizedFileURL.path
                do {
                    var rowMissing = false
                    var ratingToSet: Int? = nil
                    try await queue.write { db in
                        guard let scope = try MetadataImportApply.scope(db: db, absPath: absPath) else {
                            rowMissing = true
                            return
                        }
                        if !extracted.keywords.isEmpty {
                            try MetadataImportApply.applyKeywords(
                                db: db, scope: scope, labels: extracted.keywords)
                        }
                        let has = try MetadataImportApply.hasRating(db: db, scope: scope)
                        ratingToSet = MetadataImportRules.ratingToApply(
                            imported: extracted.rating, existingHasRating: has)
                    }
                    if rowMissing { skipped += 1; continue }
                    if let stars = ratingToSet {
                        // The one rating write seam — mutual exclusion,
                        // manual tier, sidecar export all come with it.
                        await TagStore.shared.setRating(stars, forURLs: [url])
                    }
                    imported += 1
                    touched.append(url)
                } catch {
                    skipped += 1
                }
            }

            // One sidecar re-export for everything touched (iCloud-zone
            // no-op otherwise) + the standard post-tag-edit UI refresh.
            if !touched.isEmpty {
                AnalyzePipeline.shared.exportSidecarsAfterTagEdit(for: touched)
                appState?.tagsVersion += 1
            }
            self.phase = .done(imported: imported, none: none, skipped: skipped)
        }
    }

    func cancel() {
        task?.cancel()
    }
}
