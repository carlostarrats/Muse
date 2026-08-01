//
//  TakeoutImportModel.swift
//  Muse
//
//  Google Takeout.
//
//  Google's edits live on their servers and cannot be recovered, so there is
//  nothing to translate — the edited JPEG simply IS the picture. What Takeout
//  DOES give you is the metadata it stripped out of the exported files: dates,
//  GPS, descriptions, favorites. That is the whole import.
//
//  Files are referenced IN PLACE. An extracted Takeout archive is already a
//  folder of ordinary files on the user's disk; copying them would double the
//  disk usage to achieve nothing (the no-catalog story, applied literally).
//

import Foundation
import GRDB
import SwiftUI

@MainActor
final class TakeoutImportModel: ObservableObject {

    enum PeopleChoice: String, CaseIterable, Identifiable {
        case skip, tags
        var id: String { rawValue }
    }

    enum Phase: Equatable {
        case options
        case running(done: Int, total: Int)
        case done(report: ImportReport)
    }

    @Published private(set) var phase: Phase = .options
    /// Default SKIP: a name in Google's JSON is a face identity, and turning
    /// one into a tag is a decision the user makes, not the importer.
    @Published var people: PeopleChoice = .skip
    @Published var favoritesAsTag = true

    static let favoriteTag = "Favorite"

    private var task: Task<Void, Never>?

    func start(folder: URL, appState: AppState) {
        guard task == nil else { return }
        let wantsPeople = people == .tags
        let wantsFavorites = favoritesAsTag
        task = Task { [weak self, weak appState] in
            guard let self else { return }
            await self.run(folder: folder, appState: appState,
                           wantsPeople: wantsPeople, wantsFavorites: wantsFavorites)
        }
    }

    func cancel() { task?.cancel() }

    private func run(folder: URL, appState: AppState?,
                     wantsPeople: Bool, wantsFavorites: Bool) async {
        var report = ImportReport(sourceName: String(localized: "Google Takeout"))
        report.notices.append(String(localized: "Google Photos edits are already baked into the edited files; the originals are unmodified. The individual adjustments live on Google's servers and can't be recovered."))

        let files = await Task.detached(priority: .userInitiated) {
            AppState.enumerateRecursive(at: folder, showHidden: false)
                .filter { $0.kind == .image || $0.kind == .raw
                    || $0.kind == .psd || $0.kind == .video }
        }.value
        if Task.isCancelled { return }
        phase = .running(done: 0, total: files.count)

        _ = await Indexer.shared.indexBatch(files.map { ($0.url, $0.kind) }, priority: .high)
        if Task.isCancelled { return }
        guard let queue = Database.shared.dbQueue else {
            report.filesSkipped = files.count
            finish(report, appState: appState)
            return
        }

        var appliedSupplement = false
        var touched: [URL] = []

        for (index, file) in files.enumerated() {
            if Task.isCancelled { break }
            phase = .running(done: index, total: files.count)
            let url = file.url
            let kind = file.kind

            guard let meta = await Task.detached(priority: .userInitiated, operation: {
                Self.sidecarMeta(for: url)
            }).value else { report.filesWithNone += 1; continue }

            let header = await PhotoHeaderReader.read(url: url, kind: kind)
            let absPath = url.standardizedFileURL.path
            var applied = ImportSupplement.AppliedFields()
            var wroteNote = false
            var keywords: [String] = []
            if wantsFavorites, meta.favorited { keywords.append(Self.favoriteTag) }
            if wantsPeople { keywords.append(contentsOf: meta.people) }

            do {
                try await queue.write { db in
                    guard let scope = try MetadataImportApply.scope(db: db, absPath: absPath),
                          let row = try FileRow.filter(FileRow.Columns.id == scope.fileID)
                            .fetchOne(db), let hash = row.content_hash else { return }
                    applied = try ImportSupplement.apply(
                        db: db, fileID: scope.fileID, contentHash: hash, header: header,
                        external: .init(lat: meta.lat, lon: meta.lon,
                                        captureDate: meta.photoTakenTime))
                    if let composed = ImportedText.note(title: nil, caption: meta.description,
                                                        creator: nil) {
                        let existing = try NoteStore.read(fileID: scope.fileID,
                                                          parentDir: scope.dir, db: db)
                        if existing == nil || existing!.isEmpty {
                            try NoteStore.write(composed, fileID: scope.fileID,
                                                parentDir: scope.dir,
                                                updatedAt: Int64(Date().timeIntervalSince1970),
                                                db: db)
                            wroteNote = true
                        }
                    }
                    if !keywords.isEmpty {
                        try MetadataImportApply.applyKeywords(db: db, scope: scope,
                                                              labels: keywords)
                    }
                }
            } catch {
                report.filesSkipped += 1
                continue
            }

            if applied.coordinates { report.coordinates += 1; appliedSupplement = true }
            if applied.captureDate { report.captureDates += 1; appliedSupplement = true }
            if wroteNote { report.notes += 1 }
            if !keywords.isEmpty { report.keywords += keywords.count }
            report.filesTouched += 1
            touched.append(url)
        }

        if !touched.isEmpty {
            AnalyzePipeline.shared.exportSidecarsAfterTagEdit(for: touched)
            appState?.tagsVersion += 1
        }
        if appliedSupplement {
            Task {
                await GeocodeBackfill.run()
                await SearchFacets.shared.refresh()
            }
        }
        finish(report, appState: appState)
    }

    private func finish(_ report: ImportReport, appState: AppState?) {
        phase = .done(report: report)
        appState?.importModal = .report(report)
    }

    /// The first candidate sibling that exists. An `-edited` copy resolves to
    /// the ORIGINAL's json via ladder rule 4, so both files receive the same
    /// metadata independently — no pairing, no stacking.
    nonisolated static func sidecarMeta(for url: URL) -> TakeoutMeta? {
        let directory = url.deletingLastPathComponent()
        for candidate in TakeoutJSON.jsonCandidates(for: url.lastPathComponent) {
            let sidecar = directory.appendingPathComponent(candidate)
            guard let data = try? Data(contentsOf: sidecar),
                  let meta = TakeoutJSON.parse(data), !meta.isEmpty else { continue }
            return meta
        }
        return nil
    }
}
