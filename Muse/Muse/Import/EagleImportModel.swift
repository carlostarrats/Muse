//
//  EagleImportModel.swift
//  Muse
//
//  Eagle library → Muse.
//
//  Copy ONCE, flat, with `FileManager.copyItem` — never `FileMover.move`. The
//  source library is read-only by contract: an Eagle user who tries Muse and
//  doesn't like it must still have their Eagle library exactly as it was.
//
//  Idempotent by destination filename: a second run over the same library
//  copies nothing and re-applies nothing, so an interrupted import is safe to
//  restart.
//
//  Eagle folders become manual collections with nested names flattened
//  ("Parent – Child"); one image in three Eagle folders becomes ONE file in
//  three collections, never three copies. Dropped per the approved design:
//  source URLs, smart folders, Eagle's palette data.
//

import Foundation
import GRDB
import SwiftUI

@MainActor
final class EagleImportModel: ObservableObject {

    enum Phase: Equatable {
        case options
        case running(done: Int, total: Int)
        case done(report: ImportReport)
    }

    @Published private(set) var phase: Phase = .options

    private var task: Task<Void, Never>?

    func start(request: EagleImportRequest, appState: AppState) {
        guard task == nil else { return }
        task = Task { [weak self, weak appState] in
            guard let self else { return }
            await self.run(request: request, appState: appState)
        }
    }

    func cancel() { task?.cancel() }

    private func run(request: EagleImportRequest, appState: AppState?) async {
        var report = ImportReport(sourceName: String(localized: "Eagle"))

        let library = request.libraryURL
        let parsed: (items: [EagleItem], folders: [EagleFolder])
        do {
            parsed = try await Task.detached(priority: .userInitiated) {
                try EagleLibrary.read(at: library)
            }.value
        } catch {
            report.notices.append(String(localized: "That folder doesn't look like an Eagle library."))
            finish(report, appState: appState)
            return
        }
        if Task.isCancelled { return }

        let flattened = EagleLibrary.flattenedNames(parsed.folders)
        phase = .running(done: 0, total: parsed.items.count)

        // 1. Copy, flat, with a collision ladder for genuinely distinct items.
        var copied: [(item: EagleItem, url: URL)] = []
        var usedNames = Set<String>()
        let destination = request.destination
        for (index, item) in parsed.items.enumerated() {
            if Task.isCancelled { break }
            phase = .running(done: index, total: parsed.items.count)
            let target = destination.appendingPathComponent(item.name)
            if FileManager.default.fileExists(atPath: target.path) {
                // Already here from a prior run — idempotent skip, and it still
                // gets its metadata applied below.
                report.filesSkipped += 1
                copied.append((item, target))
                usedNames.insert(item.name.lowercased())
                continue
            }
            let name = EagleImportModel.uniqueName(item.name, used: usedNames)
            usedNames.insert(name.lowercased())
            let finalURL = destination.appendingPathComponent(name)
            do {
                try FileManager.default.copyItem(at: item.fileURL, to: finalURL)
                report.filesImported += 1
                copied.append((item, finalURL))
            } catch {
                report.filesSkipped += 1
            }
        }
        if Task.isCancelled { return }

        // 2. Index deterministically — never wait for FSEvents.
        var batch: [(URL, AssetKind)] = []
        for entry in copied {
            batch.append((entry.url, AssetKind.detect(at: entry.url)))
            if batch.count >= 50 {
                _ = await Indexer.shared.indexBatch(batch, priority: .high)
                batch = []
            }
        }
        if !batch.isEmpty { _ = await Indexer.shared.indexBatch(batch, priority: .high) }

        guard let queue = Database.shared.dbQueue else {
            finish(report, appState: appState)
            return
        }

        // 3. Apply, through existing seams only.
        var collectionIDs: [String: String] = [:]     // flattened name → id
        var ratings: [(URL, Int)] = []
        for entry in copied {
            if Task.isCancelled { break }
            let absPath = entry.url.standardizedFileURL.path
            let item = entry.item
            // Returned FROM the @Sendable write closure rather than assigned
            // into captured `var`s — writing to locals across that boundary is
            // a data race, and an error under the Swift 6 language mode.
            nonisolated struct EntryOutcome {
                var fileID: String?
                var wroteNote = false
                var rating: Int?
            }
            let outcome: EntryOutcome = (try? await queue.write { db -> EntryOutcome in
                var out = EntryOutcome()
                guard let scope = try MetadataImportApply.scope(db: db, absPath: absPath)
                else { return out }
                out.fileID = scope.fileID
                if !item.tags.isEmpty {
                    try MetadataImportApply.applyKeywords(
                        db: db, scope: scope,
                        labels: MetadataImportRules.normalizeKeywords(item.tags))
                }
                if let annotation = item.annotation,
                   let composed = ImportedText.note(title: nil, caption: annotation,
                                                    creator: nil) {
                    let existing = try NoteStore.read(fileID: scope.fileID,
                                                      parentDir: scope.dir, db: db)
                    if existing == nil || existing!.isEmpty {
                        try NoteStore.write(composed, fileID: scope.fileID,
                                            parentDir: scope.dir,
                                            updatedAt: Int64(Date().timeIntervalSince1970),
                                            db: db)
                        out.wroteNote = true
                    }
                }
                // Gap-fill, through the shipped rule — an Eagle star never
                // overwrites a rating set in Muse.
                let has = try MetadataImportApply.hasRating(db: db, scope: scope)
                if let star = MetadataImportRules.ratingToApply(
                    imported: MetadataImportRules.normalizeRating(item.star.map(Double.init)),
                    existingHasRating: has) {
                    out.rating = star
                }
                return out
            }) ?? EntryOutcome()
            if let star = outcome.rating { ratings.append((entry.url, star)) }
            if !item.tags.isEmpty { report.keywords += item.tags.count }
            if outcome.wroteNote { report.notes += 1 }

            // Folder memberships → find-or-create manual collections.
            guard let fileID = outcome.fileID else { continue }
            for folderID in item.folderIDs {
                guard let name = flattened[folderID] else { continue }
                if let existing = collectionIDs[name] {
                    try? await CollectionStore.addFile(queue: queue, fileID: fileID,
                                                       collectionID: existing)
                } else if let resolved = try? await Self.findOrCreateCollection(
                    queue: queue, name: name, fileID: fileID) {
                    collectionIDs[name] = resolved.id
                    if resolved.created { report.collectionsCreated += 1 }
                }
            }
        }

        // The single rating write seam — mutual exclusion and the sidecar
        // export come with it, so it can't be folded into the transaction.
        for (url, stars) in ratings {
            await TagStore.shared.setRating(stars, forURLs: [url])
            report.ratings += 1
        }
        report.filesTouched = copied.count
        report.notices.append(String(localized: "Eagle's saved source links, smart folders and palette data were not imported."))

        if !copied.isEmpty {
            appState?.tagsVersion += 1
            await CollectionsEngine.shared.reload()
        }
        finish(report, appState: appState)
    }

    private func finish(_ report: ImportReport, appState: AppState?) {
        phase = .done(report: report)
        appState?.importModal = .report(report)
    }

    /// "photo.jpg" → "photo 2.jpg", case-insensitively.
    nonisolated static func uniqueName(_ name: String, used: Set<String>) -> String {
        guard used.contains(name.lowercased()) else { return name }
        let ext = (name as NSString).pathExtension
        let stem = (name as NSString).deletingPathExtension
        var index = 2
        while true {
            let candidate = ext.isEmpty ? "\(stem) \(index)" : "\(stem) \(index).\(ext)"
            if !used.contains(candidate.lowercased()) { return candidate }
            index += 1
        }
    }

    private static func findOrCreateCollection(queue: DatabaseQueue, name: String,
                                               fileID: String)
        async throws -> (id: String, created: Bool) {
        let existing = try await queue.read { db in
            try String.fetchOne(db, sql:
                "SELECT id FROM collections WHERE name = ? COLLATE NOCASE AND is_hidden = 0",
                arguments: [name])
        }
        if let existing {
            try await CollectionStore.addFile(queue: queue, fileID: fileID,
                                              collectionID: existing)
            return (existing, false)
        }
        let id = try await CollectionStore.createManual(queue: queue, name: name,
                                                        fileID: fileID)
        return (id, true)
    }
}
