//
//  MetadataImportModel.swift
//  Muse
//
//  One run of File > Import > Metadata & Lightroom Edits.
//
//  Enumerate the folder (always recursive — the user picked THIS folder, the
//  grid's subfolder toggle is irrelevant here), index it so writes have
//  (file_id, parent_dir) rows to land on, then per file read metadata OFF-MAIN
//  and apply through the tested seams:
//
//    1. keywords → manual tags (insert-or-promote)
//    2. rating   → gap-fill only
//    3. note     → title/caption/creator, fill-gaps only
//    4. GPS      → ImportSupplement (header wins, external fills gaps)
//    5. label    → accumulated, applied after the mapping decision
//    6. Lightroom adjustments → an approximated, badged EditStack
//
//  Idempotent throughout: re-running finishes what a cancel interrupted and
//  changes nothing already done. Nothing here is a NEW writer — every leg goes
//  through a seam that already existed.
//

import Foundation
import CoreImage
import GRDB
import SwiftUI

@MainActor
final class MetadataImportModel: ObservableObject {

    enum Phase: Equatable {
        /// Pre-scan. Choices made here shape what the report can honestly say,
        /// so they are locked once the run begins.
        case options
        case running(done: Int, total: Int)
        case done(report: ImportReport)
    }

    /// Everything one file's write transaction needs to report back.
    ///
    /// Returned FROM the `queue.write` closure rather than assigned into
    /// captured `var`s: the closure is `@Sendable`, so writing to locals across
    /// that boundary is a data race — a warning today, an error under the
    /// Swift 6 language mode.
    nonisolated private struct FileOutcome {
        var rowMissing = false
        var ratingToSet: Int?
        var wroteNote = false
        var appliedFields = ImportSupplement.AppliedFields()
        var hasExistingEdit = false
    }

    @Published private(set) var phase: Phase = .options
    /// Bound by the run card before the scan starts; the toggle is only shown
    /// pre-scan because flipping it mid-run would make the report a lie.
    @Published var importLREdits: Bool = AppSettings.importLREdits
    @Published private(set) var started = false

    private var task: Task<Void, Never>?

    func start(folder: URL, appState: AppState) {
        guard task == nil else { return }
        started = true
        AppSettings.importLREdits = importLREdits
        let wantsEdits = importLREdits
        task = Task { [weak self, weak appState] in
            guard let self else { return }
            await self.run(folder: folder, appState: appState, wantsEdits: wantsEdits)
        }
    }

    func cancel() {
        task?.cancel()
    }

    // MARK: - Run

    private func run(folder: URL, appState: AppState?, wantsEdits: Bool) async {
        var report = ImportReport(sourceName: String(localized: "Metadata & Lightroom Edits"))

        let files = await Task.detached(priority: .userInitiated) {
            AppState.enumerateRecursive(at: folder, showHidden: false)
                .filter { $0.kind == .image || $0.kind == .raw || $0.kind == .psd }
        }.value
        if Task.isCancelled { return }
        phase = .running(done: 0, total: files.count)

        // Index first: every write below silently no-ops on an unknown path.
        _ = await Indexer.shared.indexBatch(files.map { ($0.url, $0.kind) }, priority: .high)
        if Task.isCancelled { return }

        guard let queue = Database.shared.dbQueue else {
            report.filesSkipped = files.count
            finish(report, appState: appState)
            return
        }

        var touched: [URL] = []
        /// raw label value → alive absolute paths. Paths only, so 100k files
        /// cost a few MB rather than a copy of the library.
        var labelPaths: [String: [String]] = [:]
        var appliedSupplement = false

        for (index, file) in files.enumerated() {
            if Task.isCancelled { break }
            phase = .running(done: index, total: files.count)
            let url = file.url
            let kind = file.kind
            let isRAW = kind == .raw

            let read: (extracted: MetadataKeywordReader.Extracted, lightroom: LightroomEdits?)
            do {
                read = try await Task.detached(priority: .userInitiated) {
                    try MetadataKeywordReader.readFull(url: url, includingLightroom: wantsEdits)
                }.value
            } catch {
                report.filesSkipped += 1
                continue
            }
            let extracted = read.extracted
            let lightroom = wantsEdits ? read.lightroom : nil
            if extracted.isEmpty && lightroom == nil { report.filesWithNone += 1; continue }

            let absPath = url.standardizedFileURL.path
            // One header read per file, shared by the supplement leg. Read
            // OUTSIDE the transaction — it touches the filesystem.
            let coordinate = extracted.coordinate
            let header: PhotoHeader = coordinate == nil
                ? PhotoHeader()
                : await PhotoHeaderReader.read(url: url, kind: kind)

            // What the transaction found, RETURNED rather than written back
            // into captured `var`s. The write closure is `@Sendable`, so
            // mutating captured locals from inside it is a data race the
            // compiler can only warn about today and rejects outright under the
            // Swift 6 language mode.
            let outcome: FileOutcome
            do {
                outcome = try await queue.write { db -> FileOutcome in
                    var out = FileOutcome()
                    guard let scope = try MetadataImportApply.scope(db: db, absPath: absPath) else {
                        out.rowMissing = true
                        return out
                    }
                    if !extracted.keywords.isEmpty {
                        try MetadataImportApply.applyKeywords(
                            db: db, scope: scope, labels: extracted.keywords)
                    }
                    let has = try MetadataImportApply.hasRating(db: db, scope: scope)
                    out.ratingToSet = MetadataImportRules.ratingToApply(
                        imported: extracted.rating, existingHasRating: has)

                    // Note: fill-gaps. An import never overwrites what the user
                    // typed in Muse.
                    if let composed = ImportedText.note(title: extracted.title,
                                                        caption: extracted.caption,
                                                        creator: extracted.creator) {
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

                    // GPS supplement — the metadata scan has no capture-date
                    // source, so only coordinates travel this leg.
                    if let coordinate,
                       let row = try FileRow.filter(FileRow.Columns.id == scope.fileID).fetchOne(db),
                       let hash = row.content_hash {
                        out.appliedFields = try ImportSupplement.apply(
                            db: db, fileID: scope.fileID, contentHash: hash,
                            header: header,
                            external: .init(lat: coordinate.lat, lon: coordinate.lon))
                    }

                    if lightroom != nil {
                        out.hasExistingEdit = try EditRecordStore.read(
                            fileID: scope.fileID, parentDir: scope.dir, db: db) != nil
                    }
                    return out
                }
            } catch {
                report.filesSkipped += 1
                continue
            }
            if outcome.rowMissing { report.filesSkipped += 1; continue }

            if !extracted.keywords.isEmpty { report.keywords += extracted.keywords.count }
            if outcome.wroteNote { report.notes += 1 }
            if outcome.appliedFields.coordinates { report.coordinates += 1; appliedSupplement = true }
            if outcome.appliedFields.captureDate { report.captureDates += 1; appliedSupplement = true }
            if let stars = outcome.ratingToSet {
                // The one rating write seam — mutual exclusion, manual tier and
                // the sidecar export all come with it.
                await TagStore.shared.setRating(stars, forURLs: [url])
                report.ratings += 1
            }
            if let label = extracted.label?.trimmingCharacters(in: .whitespacesAndNewlines),
               !label.isEmpty {
                labelPaths[label, default: []].append(absPath)
            }
            if let lightroom {
                for name in lightroom.unsupported {
                    report.unsupportedSliders[name, default: 0] += 1
                }
                await applyLightroom(lightroom, url: url, isRAW: isRAW,
                                     hasExistingEdit: outcome.hasExistingEdit, report: &report)
            }
            report.filesTouched += 1
            touched.append(url)
        }

        if !touched.isEmpty {
            AnalyzePipeline.shared.exportSidecarsAfterTagEdit(for: touched)
            appState?.tagsVersion += 1
        }
        if appliedSupplement {
            // Fresh coordinates mean fresh places; fresh places mean stale
            // autocomplete facets. The Spec 02 completion chain, verbatim.
            Task {
                await GeocodeBackfill.run()
                await SearchFacets.shared.refresh()
            }
        }

        if !labelPaths.isEmpty, !Task.isCancelled {
            await resolveLabels(labelPaths, queue: queue, appState: appState, report: &report)
        }
        if report.editsApproximated > 0 {
            report.notices.append(String(localized: "Lightroom adjustments are approximated — Muse maps crop, white balance, exposure, contrast, vibrance, saturation and tone curves. Everything else is listed above and was not translated."))
        }
        finish(report, appState: appState)
    }

    private func finish(_ report: ImportReport, appState: AppState?) {
        phase = .done(report: report)
        appState?.importModal = .report(report)
    }

    // MARK: - Lightroom edits

    private func applyLightroom(_ lr: LightroomEdits, url: URL, isRAW: Bool,
                                hasExistingEdit: Bool, report: inout ImportReport) async {
        guard !lr.isEmpty else { return }
        // NEVER clobber a Muse edit — and this is also what makes a re-run
        // idempotent: the stack we wrote last time is now "existing".
        guard !hasExistingEdit else { report.editsSkippedExisting += 1; return }

        var context = LightroomEditMapper.Context(isRAW: isRAW)
        if isRAW, lr.temperatureKelvin != nil {
            // The run's most expensive per-file step, so it's gated to exactly
            // the RAW files whose sidecar actually moves white balance.
            let neutral = await Task.detached(priority: .userInitiated) {
                RawAsShot.neutral(for: url)
            }.value
            context.asShotKelvin = neutral?.kelvin
            context.asShotTint = neutral?.tint
            if neutral == nil {
                let notice = String(localized: "White balance was skipped for some RAW files — their as-shot reference could not be read.")
                if !report.notices.contains(notice) { report.notices.append(notice) }
            }
        }
        guard let stack = LightroomEditMapper.map(lr, context: context) else { return }
        // The full Spec 04 save sequence: row write, provider index,
        // markContentChanged, generation bump, sidecar export.
        await EditStore.shared.save(stack, for: url)
        report.editsApproximated += 1
    }

    // MARK: - Color labels

    /// Apply the remembered choices silently when every value is known;
    /// otherwise raise the mapping card and wait for it (DECIDED #12 — never
    /// merged silently into color semantics).
    private func resolveLabels(_ labelPaths: [String: [String]],
                               queue: DatabaseQueue,
                               appState: AppState?,
                               report: inout ImportReport) async {
        let remembered = LabelMapping.loadChoices()
        let values = Array(labelPaths.keys).sorted()
        var choices: [String: LabelMapping.Choice] = [:]
        if values.allSatisfy({ remembered[$0] != nil }) {
            for value in values { choices[value] = remembered[value] }
        } else if let appState {
            choices = await withCheckedContinuation { continuation in
                let request = LabelMappingRequest(
                    values: values,
                    counts: labelPaths.mapValues(\.count),
                    onResolve: { continuation.resume(returning: $0) })
                appState.importModal = .labelMapping(request)
            }
        } else {
            return
        }

        for value in values {
            let choice = choices[value] ?? .skip
            let paths = labelPaths[value] ?? []
            report.labelCounts.append(
                LabelOutcome(label: value, count: paths.count, choice: choice))
            guard let resolved = LabelMapping.resolvedLabel(value: value, choice: choice),
                  !paths.isEmpty else { continue }
            try? await queue.write { db in
                for path in paths {
                    guard let scope = try MetadataImportApply.scope(db: db, absPath: path)
                    else { continue }
                    try MetadataImportApply.applyKeywords(db: db, scope: scope,
                                                          labels: [resolved])
                }
            }
        }
    }
}

/// The camera's as-shot neutral, read from `CIRAWFilter` without decoding.
/// Lives here rather than in `Editing/` because it exists for the importer —
/// the renderer reads the filter's own live value and never needs it hoisted.
nonisolated enum RawAsShot {
    static func neutral(for url: URL) -> (kelvin: Double, tint: Double)? {
        guard let filter = CIRAWFilter(imageURL: url) else { return nil }
        let kelvin = Double(filter.neutralTemperature)
        guard kelvin > 0, kelvin.isFinite else { return nil }
        return (kelvin, Double(filter.neutralTint))
    }
}
