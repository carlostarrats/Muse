//
//  AnalyzePipeline.swift
//  Muse
//
//  Orchestrates "Analyze this file/folder" — runs Vision pipeline,
//  writes results to the DB, populates FTS5. Runs automatically after
//  indexing for files whose analyzed_hash is stale (supersedes Q10's
//  manual-only rule); the ✨ button forces a full re-run. Manual tags
//  always beat vision tags (Q32), so re-analysis never undoes the user.
//

import Foundation
import GRDB

@MainActor
final class AnalyzePipeline: ObservableObject {
    static let shared = AnalyzePipeline()

    @Published var isRunning: Bool = false
    @Published var progress: Double = 0
    @Published var current: String = ""
    /// Count of files in the active pass (for the "N of M" pill — no filename).
    @Published var completed: Int = 0
    @Published var total: Int = 0

    /// Set by AppState.discoverICloudZone() when the iCloud zone resolves at
    /// launch (nil for local-only users / not signed into iCloud). AnalyzePipeline
    /// is a real singleton; AppState is not, so AppState pushes the value here
    /// rather than the pipeline reaching back into AppState.
    var iCloudFolder: URL?

    /// Asks the in-flight pass to stop at the next file boundary. Checked
    /// alongside `Task.isCancelled` so BOTH the automatic path (a cancellable
    /// `indexingTask`) and the manual menu / App-Intent paths (which launch
    /// from un-stored `Task {}` blocks the caller can't cancel) can be halted
    /// when the folder being analyzed is removed. Reset at the start of every
    /// pass, so a later pass over a still-valid folder runs normally.
    private var cancelRequested = false

    /// Embedding rows written by the pass in flight. Drives the recluster gate:
    /// a pass that embedded nothing cannot change the clustering, and clustering
    /// costs scale with LIBRARY size rather than pass size.
    private(set) var embeddingsWritten = 0

    /// How many files analyze at once. Vision already parallelizes its five
    /// requests WITHIN one image, so this is deliberately modest — it fills the
    /// gaps between those requests rather than trying to saturate the machine,
    /// and keeps peak memory to a few bounded rasters rather than many.
    /// `nonisolated`: read by ThrottlePolicy from off-main backfills.
    nonisolated static let analyzeConcurrency = 3

    /// True when the active pass should stop — either its owning task was
    /// cancelled or `cancelActivePass()` was called.
    private var shouldStop: Bool { cancelRequested || Task.isCancelled }

    /// Synchronous claim guarding the queue-and-wait gate. The old gate only
    /// looked at `isRunning`, so when a pass ended every sleeping waiter woke,
    /// all saw `isRunning == false`, and all proceeded — two passes ran at once,
    /// clobbering progress and letting `cancelActivePass()` hit the wrong pass.
    /// A waiter now ALSO claims this flag, and because there's no `await`
    /// between the gate check and the claim, only the first woken waiter on the
    /// main actor can take it; the rest see it set and keep waiting.
    private var passClaimed = false

    /// Wait until no pass is running or claimed, then claim atomically. Returns
    /// false if the caller's task is cancelled while waiting (same bail-out the
    /// old busy-wait had). The caller MUST clear `passClaimed` (via `defer`)
    /// once its pass has fully finished. `analyze(folder:)`/`analyze(file:)`
    /// don't consult `passClaimed`, so a claiming wrapper calling into them
    /// can't deadlock.
    private func acquirePass() async -> Bool {
        while isRunning || passClaimed {
            if Task.isCancelled { return false }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        passClaimed = true   // atomic: no await between the gate check and here
        return true
    }

    /// Stop whatever pass is currently running (e.g. its folder was removed).
    /// No-op when idle, so it can't poison the next legitimate pass.
    func cancelActivePass() {
        guard isRunning else { return }
        cancelRequested = true
    }

    private init() {}

    // MARK: - Manual entry points (claim the pass gate)

    /// User-initiated "Analyze this folder" (menu / App Intent). Claims the pass
    /// gate so it can't run concurrently with the automatic `analyzePending`
    /// pass — without this it would clobber the shared progress/`isRunning` state
    /// and let `cancelActivePass()` halt the wrong pass. The inner
    /// `analyze(folder:)` stays claim-free so the already-claiming wrappers
    /// (analyzePending / regenerateTagless) don't deadlock.
    func analyzeFolderManual(_ urls: [URL]) async {
        guard await acquirePass() else { return }
        defer { passClaimed = false }
        await analyze(folder: urls)
    }

    // MARK: - File-level

    func analyze(file url: URL) async {
        guard let queue = Database.shared.dbQueue else { return }
        // Find the file row by alive path
        let absPath = url.standardizedFileURL.path
        let fileID: String? = (try? await queue.read { db -> String? in
            try PathRow
                .filter(PathRow.Columns.absolute_path == absPath)
                .filter(PathRow.Columns.is_alive == 1)
                .fetchOne(db)?.file_id
        }) ?? nil
        guard let id = fileID else { return }
        cancelRequested = false
        embeddingsWritten = 0
        isRunning = true
        current = url.lastPathComponent
        defer { isRunning = false; current = ""; progress = 0 }
        await analyzeOne(fileID: id, url: url)
        if shouldStop { return }
        // This path used to rebuild the WHOLE library after every single file.
        if ReclusterGate.shouldRecluster(embeddingsWritten: embeddingsWritten, force: false) {
            await CollectionsEngine.shared.recluster()
        }
    }

    /// The automatic pass: of `urls`, analyze only those whose stored
    /// analyzed_hash is missing or stale (new or edited images). Runs
    /// after every index pass — analyzing twice is a provable no-op.
    func analyzePending(in urls: [URL]) async {
        PhaseTrace.mark("analyzePending.call", "urls=\(urls.count)")
        // Automatic tagging is opt-out (Preferences). Off → newly indexed
        // images stay viewable but untagged; the user can still Analyze /
        // Regenerate a folder by hand.
        guard AppSettings.autoTag else { return }
        guard let queue = Database.shared.dbQueue else { return }
        // A pass may already be running (e.g. the previous folder's) — wait our
        // turn instead of silently skipping this folder. Bail if the owning task
        // is cancelled (folder removed) so we don't busy-spin. The claim is held
        // until this whole method returns so a second waiter can't slip past
        // during the `await` before `analyze(folder:)` flips `isRunning`.
        guard await acquirePass() else { return }
        defer { passClaimed = false }
        let paths = urls.map { $0.standardizedFileURL.path }
        guard !paths.isEmpty else { return }
        let pending: Set<String> = (try? await queue.read { db in
            let marks = databaseQuestionMarks(count: paths.count)
            return try Set(String.fetchAll(db, sql: """
                SELECT p.absolute_path FROM paths p
                JOIN files f ON f.id = p.file_id
                WHERE p.is_alive = 1
                  AND p.absolute_path IN (\(marks))
                  AND (f.analyzed_hash IS NULL
                       OR f.analyzed_hash != f.content_hash)
                """, arguments: StatementArguments(paths)))
        }) ?? []
        guard !pending.isEmpty else { return }
        let pendingURLs = urls.filter { pending.contains($0.standardizedFileURL.path) }
        PhaseTrace.mark("analyzePending.run", "stale=\(pendingURLs.count)")
        await analyze(folder: pendingURLs)
    }

    /// Recovery / gap-fill pass: of `urls` (the current folder), analyze only
    /// those files that currently have NO tags. This is the explicit
    /// "Regenerate Tags" command. The no-tags gate makes it both the recovery
    /// path (after a Delete All, every file qualifies) and incremental
    /// (already-tagged files are skipped, so a fully-tagged folder is a no-op).
    /// Intentionally NOT gated on analyzed_hash, so it doesn't entangle with
    /// the automatic pipeline.
    func regenerateTagless(in urls: [URL]) async {
        guard let queue = Database.shared.dbQueue else { return }
        guard await acquirePass() else { return }
        defer { passClaimed = false }
        let paths = urls.map { $0.standardizedFileURL.path }
        guard !paths.isEmpty else { return }
        // "Tagless" is per FOLDER now: a file is tagless here if it has no tag
        // scoped to (file_id, this folder), even if a duplicate in another
        // folder is tagged. Computed in Swift since SQLite has no dirname().
        let tagless: Set<String> = (try? await queue.read { db -> Set<String> in
            let marks = databaseQuestionMarks(count: paths.count)
            let rows = try Row.fetchAll(db, sql: """
                SELECT absolute_path, file_id FROM paths
                WHERE is_alive = 1 AND file_id IS NOT NULL
                  AND absolute_path IN (\(marks))
            """, arguments: StatementArguments(paths))
            let fileIDs = Array(Set(rows.compactMap { $0["file_id"] as String? }))
            var tagged = Set<String>()   // "file_id\0parent_dir" that carry a tag
            if !fileIDs.isEmpty {
                let fmarks = databaseQuestionMarks(count: fileIDs.count)
                let scopeRows = try Row.fetchAll(db, sql: """
                    SELECT DISTINCT file_id, parent_dir FROM tags
                    WHERE file_id IN (\(fmarks))
                """, arguments: StatementArguments(fileIDs))
                for r in scopeRows {
                    if let fid: String = r["file_id"], let dir: String = r["parent_dir"] {
                        tagged.insert(fid + "\u{0}" + dir)
                    }
                }
            }
            var result = Set<String>()
            for r in rows {
                guard let p: String = r["absolute_path"],
                      let fid: String = r["file_id"] else { continue }
                if !tagged.contains(fid + "\u{0}" + TagScope.parentDir(ofPath: p)) {
                    result.insert(p)
                }
            }
            return result
        }) ?? []
        guard !tagless.isEmpty else { return }
        let taglessURLs = urls.filter { tagless.contains($0.standardizedFileURL.path) }
        await analyze(folder: taglessURLs)
    }

    /// Resolve standardized absolute paths to their alive file_ids in one chunked
    /// `IN (...)` read per ~800 paths (P6 — mirrors CollectionStore.fileIDs but
    /// returns the path→id MAP so callers keep URL pairing/order). Only paths with
    /// an alive row and a non-null file_id appear. `internal static` so the
    /// resolver tests reach it directly via `@testable import Muse`.
    nonisolated static func aliveFileIDs(queue: DatabaseQueue, absPaths: [String]) async -> [String: String] {
        guard !absPaths.isEmpty else { return [:] }
        return (try? await queue.read { db -> [String: String] in
            var map: [String: String] = [:]
            for start in stride(from: 0, to: absPaths.count, by: 800) {
                let chunk = Array(absPaths[start..<min(start + 800, absPaths.count)])
                let marks = databaseQuestionMarks(count: chunk.count)
                let rows = try Row.fetchAll(db, sql: """
                    SELECT absolute_path AS ap, file_id AS fid FROM paths
                    WHERE is_alive = 1 AND file_id IS NOT NULL AND absolute_path IN (\(marks))
                    """, arguments: StatementArguments(chunk))
                for r in rows {
                    if let ap: String = r["ap"], let fid: String = r["fid"] { map[ap] = fid }
                }
            }
            return map
        }) ?? [:]
    }

    /// Dedup URLs to unique file_ids, preserving first-seen URL order (duplicate
    /// content analyzed once, paired with its FIRST occurrence). Pure.
    nonisolated static func dedupByFileID(urls: [URL], idByPath: [String: String]) -> [(id: String, url: URL)] {
        var pairs: [(id: String, url: URL)] = []
        var seen = Set<String>()
        for url in urls {
            guard let id = idByPath[url.standardizedFileURL.path], !seen.contains(id) else { continue }
            seen.insert(id)
            pairs.append((id, url))
        }
        return pairs
    }

    func analyze(folder urls: [URL]) async {
        guard !urls.isEmpty else { return }
        guard let queue = Database.shared.dbQueue else { return }
        cancelRequested = false
        embeddingsWritten = 0
        isRunning = true
        progress = 0
        completed = 0
        defer { isRunning = false; current = ""; progress = 0; completed = 0; total = 0 }

        // Resolve all URLs to alive file_ids in ONE batched read, then dedup by
        // file_id preserving first-seen URL order (duplicate content — the same
        // bytes under several paths — is analyzed ONCE, and the count reflects
        // real files, not path count).
        if shouldStop { return }
        let idByPath = await Self.aliveFileIDs(queue: queue,
                                               absPaths: urls.map { $0.standardizedFileURL.path })
        if shouldStop { return }
        let pairs = Self.dedupByFileID(urls: urls, idByPath: idByPath)
        total = pairs.count
        guard !pairs.isEmpty else { return }

        // Bounded-concurrency pass. `analyzeOne` is @MainActor and its DB writes
        // serialize on the GRDB queue regardless, so the win is overlapping the
        // off-main Vision + decode work — which is where essentially all the
        // time goes. Indexing runs 2-wide and thumbnails 8-wide; this ran 1-wide.
        var tally = AnalyzeProgress(total: pairs.count)
        var iterator = pairs.makeIterator()
        await withTaskGroup(of: Void.self) { group in
            // Prime the window. `shouldStop` (folder removed / pass cancelled)
            // stops us STARTING new work; files already in flight finish, which
            // matches the old serial loop's `break`.
            // The throttle gates BOTH spawn sites. Under `.paused` nothing new
            // starts and in-flight files finish normally — the pass keeps its
            // claim, so a pause is resumable rather than a cancel. Concurrency
            // is re-read per spawn, so a machine that heats up mid-pass narrows
            // without a restart. This is SCHEDULING: no marker, no selection
            // rule and no data path changes (DECIDED #22).
            var running = 0
            while !shouldStop {
                await WorkThrottleStore.shared.waitUntilRunnable()
                guard running < WorkThrottleStore.shared.currentConcurrency,
                      !shouldStop, let pair = iterator.next() else { break }
                current = pair.url.lastPathComponent
                group.addTask { @MainActor in
                    await self.analyzeOne(fileID: pair.id, url: pair.url)
                }
                running += 1
            }
            // One replacement per completion keeps the window full.
            while await group.next() != nil {
                let step = tally.complete()
                completed = step.completed
                progress = step.fraction
                if !shouldStop {
                    await WorkThrottleStore.shared.waitUntilRunnable()
                }
                if !shouldStop, let pair = iterator.next() {
                    current = pair.url.lastPathComponent
                    group.addTask { @MainActor in
                        await self.analyzeOne(fileID: pair.id, url: pair.url)
                    }
                }
            }
        }
        isRunning = false; current = ""; progress = 0; completed = 0; total = 0
        // End-of-pass work over exactly THIS pass's file ids: refresh the
        // search-autocomplete facets (this pass may have written new
        // cameras/lenses/dates).
        let passFileIDs = pairs.map(\.id)
        AnalysisStatusStore.shared.refresh()
        if !shouldStop && !passFileIDs.isEmpty {
            await SearchFacets.shared.refresh()
        }
        // Skip the (non-trivial) recluster if the pass was cancelled — e.g. the
        // folder was removed out from under us; there's nothing new to cluster.
        if shouldStop { return }
        // Likewise if nothing was embedded: the clustering provably cannot have
        // changed, and the rebuild's cost scales with the whole library.
        if ReclusterGate.shouldRecluster(embeddingsWritten: embeddingsWritten, force: false) {
            await CollectionsEngine.shared.recluster()
        }
    }

    // MARK: - Per-file

    /// If `url` is in the iCloud zone, export the file's current metadata to a
    /// `.muse/<hash>.json` sidecar so it syncs to other devices. No-op for
    /// local-zone files / when iCloudFolder is nil. Reads the freshly-written
    /// FileRow + tags back out; does the file write off the main actor.
    ///
    /// `mergeExisting` (the analyze path): merge with any sidecar already on
    /// disk — another device's synced record may carry MANUAL tags this device
    /// hasn't hydrated yet, and a blind overwrite would drop them from the
    /// synced record (`Sidecar.merge`: last-writer-wins scalars, tag union
    /// with manual-beats-vision). Manual tag EDITS pass false — there the
    /// local DB is authoritative (including deletions) and merging would
    /// resurrect a just-deleted tag from the old sidecar.
    private func writeSidecarIfICloud(fileID: String, url: URL, mergeExisting: Bool,
                                      noteAuthoritative: Bool = false,
                                      editAuthoritative: Bool = false,
                                      tagsAuthoritative: Bool = true) async {
        guard ICloudZone.contains(url, folder: iCloudFolder) else { return }
        guard let queue = Database.shared.dbQueue else { return }
        let now = Int64(Date().timeIntervalSince1970)
        let dir = TagScope.parentDir(of: url)
        let bundle: (FileRow, [TagRow], String?, EditRow?)? =
        try? await queue.read { db -> (FileRow, [TagRow], String?, EditRow?)? in
            guard let file = try FileRow.filter(FileRow.Columns.id == fileID).fetchOne(db)
            else { return nil }
            // Sidecar lives in this file's folder → carry only this folder's
            // tags, note and edit stack.
            let tags = try TagRow
                .filter(TagRow.Columns.file_id == fileID)
                .filter(TagRow.Columns.parent_dir == dir)
                .fetchAll(db)
            let note = try NoteStore.read(fileID: fileID, parentDir: dir, db: db)
            let edit = try EditRecordStore.read(fileID: fileID, parentDir: dir, db: db)
            return (file, tags, note, edit)
        }
        guard let (file, tags, note, edit) = bundle,
              let sidecar = Sidecar.build(
                from: file, tags: tags, updatedAt: now, note: note,
                edit: edit.map { (stack: $0.stack, updatedAt: $0.updated_at) })
        else { return }
        let hash = sidecar.content_hash
        // Sidecar + URL are Sendable; write off-main so the (tiny) coordinated
        // disk write never blocks the main actor. Log on failure — a silent
        // write failure would silently defeat the "no re-Vision on sync" promise.
        await Task.detached {
            do {
                let existing = SidecarStore.read(forAsset: url, contentHash: hash)
                let out = Sidecar.resolveForWrite(fresh: sidecar, existing: existing,
                                                  mergeExisting: mergeExisting,
                                                  noteAuthoritative: noteAuthoritative,
                                                  editAuthoritative: editAuthoritative,
                                                  tagsAuthoritative: tagsAuthoritative)
                try SidecarStore.write(out, forAsset: url)
            }
            catch {
                // Filename omitted on purpose — this print reaches the unified
                // log, and a user's filenames don't belong there. See
                // `FolderOps.createSubfolder`.
                print("[AnalyzePipeline] sidecar write failed: \(error)")
            }
        }.value
    }

    /// Re-export sidecars after a MANUAL tag edit to iCloud-zone files. The
    /// analyze pass is the only other sidecar writer and deliberately doesn't
    /// re-run on tag edits (analyzed_hash untouched), so without this a
    /// hydrate-only device keeps the pre-edit tag set forever. Fire-and-forget;
    /// non-iCloud URLs are filtered out cheaply first.
    func exportSidecarsAfterTagEdit(for urls: [URL], noteAuthoritative: Bool = false) {
        let zone = iCloudFolder
        let inZone = urls.filter { ICloudZone.contains($0, folder: zone) }
        guard !inZone.isEmpty, let queue = Database.shared.dbQueue else { return }
        Task {
            let idByPath = await Self.aliveFileIDs(queue: queue,
                                                   absPaths: inZone.map { $0.standardizedFileURL.path })
            for url in inZone {
                guard let fid = idByPath[url.standardizedFileURL.path] else { continue }
                await writeSidecarIfICloud(fileID: fid, url: url, mergeExisting: false,
                                          noteAuthoritative: noteAuthoritative)
            }
        }
    }

    /// Re-export sidecars after an edit save/reset — the ONLY caller that
    /// passes `editAuthoritative: true`, so `fresh` wins for the edit field
    /// including a CLEAR (that is how a Reset propagates instead of reading as
    /// "nothing to say"). Every other export leaves the on-disk edit alone.
    ///
    /// Awaited rather than fire-and-forget: `EditStore.save` already runs in a
    /// Task, and the caller's next action is often closing the editor.
    func exportSidecarsAfterEditChange(for urls: [URL]) async {
        let zone = iCloudFolder
        let inZone = urls.filter { ICloudZone.contains($0, folder: zone) }
        guard !inZone.isEmpty, let queue = Database.shared.dbQueue else { return }
        let idByPath = await Self.aliveFileIDs(queue: queue,
                                               absPaths: inZone.map { $0.standardizedFileURL.path })
        for url in inZone {
            guard let fid = idByPath[url.standardizedFileURL.path] else { continue }
            // NOT authoritative for tags: this write exists to publish the edit
            // stack. Taking the tag list from this device's DB wholesale would
            // wipe tags that only exist in the sidecar because this device
            // hasn't hydrated them yet — the same reason `note` is preserved
            // here rather than overwritten.
            await writeSidecarIfICloud(fileID: fid, url: url, mergeExisting: false,
                                       editAuthoritative: true,
                                       tagsAuthoritative: false)
        }
    }

    /// Stamp `analyzed_hash` without writing any tags: "we tried these exact
    /// bytes and got nothing decodable". Guarded on the hash still matching, the
    /// same rule the real commit uses — if the file changed mid-pass, leave it
    /// pending so the next pass reads the NEW content.
    /// internal for tests.
    static func markAnalysisAttempted(fileID: String, hash: String,
                                      queue: DatabaseQueue) async {
        try? await queue.write { db in
            try db.execute(sql:
                "UPDATE files SET analyzed_hash = ? WHERE id = ? AND content_hash = ?",
                arguments: [hash, fileID, hash])
        }
    }

    /// Stamp `analyzed_hash` for a kind the Vision pipeline never handles at
    /// all — everything outside `isPhotoKind` (pdf, markdown, office, archive,
    /// video, audio, text, code, svg…).
    ///
    /// Those kinds fall straight out of `analyzeOne`'s image guard, and
    /// returning without a stamp left them permanently pending: every visit to
    /// their folder re-queued them and raised the progress pill for work that
    /// was never going to happen. Same permanent-retry shape
    /// `markAnalysisAttempted` closed for an undecodable IMAGE, through the
    /// neighbouring door.
    ///
    /// Nothing is lost by stamping. A video's GPS + EXIF are written by
    /// `writePhotoHeaderOnly` before this, under their own markers, and
    /// `PhotoHeaderBackfill` selects on those markers independently of
    /// `analyzed_hash`. New bytes clear the stamp: `Indexer.reconcile` nulls
    /// `analyzed_hash` when content_hash changes.
    ///
    /// (This supersedes the note that videos are "never stamped, so
    /// analyzePending re-queues them on every folder visit". The marker check
    /// did keep the re-queue cheap, but it could not stop the pill.)
    static func stampUnanalyzableKind(fileID: String, queue: DatabaseQueue) async {
        let hash: String? = (try? await queue.read { db in
            try FileRow.filter(FileRow.Columns.id == fileID).fetchOne(db)?.content_hash
        }) ?? nil
        guard let hash else { return }
        await markAnalysisAttempted(fileID: fileID, hash: hash, queue: queue)
    }

    /// Stamp coordinates AND EXIF from one header read, under the SAME
    /// content_hash guard the main analyze write uses — a file edited mid-pass
    /// keeps its header data pending rather than being stamped from stale
    /// bytes.
    ///
    /// Both markers are written even when nothing was found: they are
    /// attempted-markers, not "has GPS"/"has EXIF" flags. Without them every
    /// GPS-less file is re-opened on every launch forever (the
    /// analyzed_hash-NULL retry-loop shape, 2026-07-28).
    ///
    /// The whole write is skipped when both markers already equal this hash —
    /// an unconditional re-write would clobber externally-supplied GPS/date
    /// (Spec 06's import supplement) with a header re-read producing NULLs.
    static func writePhotoHeader(fileID: String, hash: String,
                                 header: PhotoHeader, queue: DatabaseQueue) async {
        try? await queue.write { db in
            try writePhotoHeader(db: db, fileID: fileID, hash: hash, header: header)
        }
    }

    /// The same write, inside a caller's transaction (the analyze pass runs it
    /// in the one transaction that already guards on `analyzedHash`).
    nonisolated static func writePhotoHeader(db: GRDB.Database, fileID: String, hash: String,
                                             header: PhotoHeader) throws {
        guard var file = try FileRow.filter(FileRow.Columns.id == fileID).fetchOne(db),
              file.content_hash == hash else { return }
        var meta = (try PhotoMetaRow.filter(Column("file_id") == fileID).fetchOne(db))
            ?? PhotoMetaRow(file_id: fileID)
        let coordsCurrent = file.coords_scanned_hash == hash
        let metaCurrent = meta.exif_scanned_hash == hash
        if coordsCurrent && metaCurrent { return }

        if !coordsCurrent {
            if let coord = header.coordinate {
                file.lat = coord.lat
                file.lon = coord.long
            }
            file.coords_scanned_hash = hash
            try file.update(db)
        }

        if !metaCurrent {
            if let exif = header.exif {
                meta.capture_date = exif.captureDate
                meta.capture_md = exif.captureMD
                meta.camera_make = exif.cameraMake
                meta.camera_model = exif.cameraModel
                meta.lens = exif.lens
                meta.iso = exif.iso
                meta.f_number = exif.fNumber
                meta.exposure_seconds = exif.exposureSeconds
                meta.focal_length = exif.focalLength
                meta.focal_length_35mm = exif.focalLength35mm
                meta.flash_fired = exif.flashFired
            }
            meta.exif_scanned_hash = hash
            try meta.save(db)
        }
    }

    /// Video kinds skip the Vision pipeline entirely but still need their
    /// coordinate + capture date written — a geotagged or dated video must not
    /// be invisible to `near:`/`in:` just because Vision doesn't
    /// tag videos. A separate, smaller guarded transaction mirroring the main
    /// one's content_hash re-check.
    ///
    /// Videos are never stamped with `analyzed_hash`, so `analyzePending`
    /// re-queues them on every folder visit; the marker check here is what
    /// keeps that cheap (one indexed read, no header open).
    private static func writePhotoHeaderOnly(fileID: String, url: URL, kind: AssetKind) async {
        guard let queue = Database.shared.dbQueue else { return }
        let state: (hash: String, coordsStale: Bool, exifStale: Bool)? = (try? await queue.read { db -> (String, Bool, Bool)? in
            guard let row = try FileRow.filter(FileRow.Columns.id == fileID).fetchOne(db),
                  let hash = row.content_hash else { return nil }
            let meta = try PhotoMetaRow.filter(Column("file_id") == fileID).fetchOne(db)
            return (hash, row.coords_scanned_hash != hash, meta?.exif_scanned_hash != hash)
        }) ?? nil
        guard let state, state.coordsStale || state.exifStale else { return }
        let header = await PhotoHeaderReader.read(url: url, kind: kind)
        await writePhotoHeader(fileID: fileID, hash: state.hash, header: header, queue: queue)
    }

    private func analyzeOne(fileID: String, url: URL) async {
        // Measured per-file cost feeds the on-device estimate the import-size
        // FYI extrapolates from — never a hardcoded number.
        let startedAt = Date()
        defer { AnalysisStatusStore.shared.recordCompletion(
            duration: Date().timeIntervalSince(startedAt)) }
        let kind = AssetKind.detect(at: url)

        // The header (GPS + EXIF) is read for image AND video kinds. The video
        // branch runs before the image-only Vision guard below, since a video
        // never reaches the main write transaction.
        if kind == .video {
            await Self.writePhotoHeaderOnly(fileID: fileID, url: url, kind: kind)
        }

        guard let queue = Database.shared.dbQueue else { return }

        // Skip non-image kinds; Vision pipeline only handles images. Stamped on
        // the way out so `analyzePending` stops re-queuing them — and stops
        // raising the pill — on every visit to their folder. See
        // `stampUnanalyzableKind`.
        guard kind.isPhotoKind else {
            await Self.stampUnanalyzableKind(fileID: fileID, queue: queue)
            return
        }

        // Capture the content identity BEFORE Vision runs. The file can be
        // edited + re-indexed while a long pass is in flight; stamping
        // analyzed_hash from a commit-time re-read would mark tags/caption
        // derived from the OLD bytes as analyzed-at-the-NEW-hash — stale
        // results that analyzePending never repairs until the next edit.
        let analyzedHash: String? = (try? await queue.read { db in
            try FileRow.filter(FileRow.Columns.id == fileID).fetchOne(db)?.content_hash
        }) ?? nil
        guard let analyzedHash else { return }

        // Another file on disk may already hold exactly these bytes, fully
        // analyzed. Identical pixels give identical answers, so adopt its
        // results and skip the pass entirely — otherwise twelve byte-identical
        // RAWs each pay for classify + OCR + palette + CLIP over the same
        // image. `Indexer.inherit` closes the same hole at index time, for a
        // copy found while its original was already analyzed; this closes it
        // for a copy that was queued while its twin was still pending.
        let adopted = (try? await queue.write { db in
            try AnalysisReuse.adopt(db: db, fileID: fileID, hash: analyzedHash)
        }) ?? false
        if adopted { return }

        // Header-only GPS + EXIF read, concurrent with the Vision pass below —
        // it's a few hundred bytes off the front of the file, not a decode, so
        // it must not serialize behind classify/OCR/palette. One header pass
        // serves both coordinates and photo_meta.
        async let photoHeader = PhotoHeaderReader.read(url: url, kind: kind)

        let registry = IntelligenceRegistry.shared
        guard let out = await registry.tagger.analyze(url: url) else {
            // The image could not be DECODED — the tagger returns nil only when
            // the CGImage load failed, which is a property of these bytes, not a
            // transient hiccup (e.g. a Fuji .RAF that Apple's RAW codec doesn't
            // support: macOS itself reports no pixel dimensions for it).
            //
            // Returning without stamping left `analyzed_hash` NULL, so the file
            // stayed pending FOREVER: every visit to its folder re-queued it,
            // raised the progress pill, redid the futile decode and gave up —
            // owner-reported as a folder that "does that every time". Record the
            // attempt against this content so the automatic pass stops retrying.
            // Explicit Regenerate Tags still picks it up (it targets files with
            // no tags), so a future codec or a re-encode can still recover it.
            //
            // The GPS header is still readable when the PIXELS aren't (the
            // .RAF case above has intact EXIF), so the coordinate is stamped
            // here too rather than being lost with the rest of the pass.
            let header = await photoHeader
            await Self.markAnalysisAttempted(fileID: fileID, hash: analyzedHash,
                                             queue: queue)
            await Self.writePhotoHeader(fileID: fileID, hash: analyzedHash,
                                        header: header, queue: queue)
            return
        }
        let caption = out.caption
        let basename = url.lastPathComponent
        let now = Int64(Date().timeIntervalSince1970)
        let paletteJSON: String? = out.palette.isEmpty ? nil :
            (try? JSONEncoder().encode(out.palette)).flatMap { String(data: $0, encoding: .utf8) }
        let taggerVersion = registry.tagger.modelVersion

        // Screenshot intent typing (Option A: screenshots only). On non-AI
        // Macs the classifier is a no-op and intentKey stays nil.
        var intentKey: String? = nil
        var intentVersion: String? = nil
        if IntentInput.isScreenshot(tags: out.tags) {
            intentVersion = registry.intentModelVersion
            let bucket = await registry.intentClassifier.classify(
                ocrText: IntentInput.ocrSnippet(out.ocrText),
                visionLabels: IntentInput.visionLabels(tags: out.tags))
            intentKey = bucket?.rawValue
        }
        // Immutable copies for the @Sendable write closure (a captured var
        // would be a data race under strict concurrency).
        let finalIntentKey = intentKey
        let finalIntentVersion = intentVersion
        let finalHeader = await photoHeader

        var committed = false
        do {
            committed = try await queue.write { db -> Bool in
                // Update files row — but ONLY if the content is still the bytes
                // Vision saw. If the file was edited + re-indexed mid-pass,
                // writing would stamp stale results as analyzed-at-the-new-hash;
                // skipping leaves analyzed_hash stale so the next pass redoes it.
                guard var file = try FileRow.filter(FileRow.Columns.id == fileID).fetchOne(db),
                      file.content_hash == analyzedHash else { return false }
                file.width = out.width
                file.height = out.height
                file.caption = caption
                file.dominant_color = out.dominantColor
                file.palette = paletteJSON
                if let fp = out.featurePrint {
                    file.feature_print = fp
                }
                file.last_seen_at = now
                // Mark analyzed-at-this-content so the automatic pass
                // skips it until the file's bytes actually change.
                file.analyzed_hash = analyzedHash
                file.intent = finalIntentKey
                file.intent_model_version = finalIntentVersion
                try file.update(db)

                // Coordinates + EXIF from the header read that ran concurrent
                // with Vision. Re-fetches the (just-updated) row inside the
                // same transaction, so both markers land atomically with the
                // rest of the analysis.
                try Self.writePhotoHeader(db: db, fileID: fileID,
                                          hash: analyzedHash, header: finalHeader)

                // Vision tags apply to EVERY folder this content lives in
                // (identical pixels → identical vision tags), independently per
                // folder so a manual edit in one folder doesn't touch another.
                // Manual tags always win (Q32), scoped per (file_id, parent_dir).
                var aliveDirs = Set<String>()
                let dirRows = try Row.fetchAll(db, sql: """
                    SELECT DISTINCT absolute_path FROM paths
                    WHERE file_id = ? AND is_alive = 1
                """, arguments: [fileID])
                for row in dirRows {
                    if let p: String = row["absolute_path"] {
                        aliveDirs.insert(TagScope.parentDir(ofPath: p))
                    }
                }
                if aliveDirs.isEmpty { aliveDirs.insert(TagScope.parentDir(of: url)) }

                for dir in aliveDirs {
                    for tag in out.tags {
                        if let existing = try TagRow
                            .filter(TagRow.Columns.file_id == fileID)
                            .filter(TagRow.Columns.parent_dir == dir)
                            .filter(TagRow.Columns.label == tag.label)
                            .fetchOne(db) {
                            if existing.source != "manual" {
                                // Update confidence + provenance
                                var t = existing
                                t.confidence = tag.confidence
                                t.source = tag.source
                                t.model_version = taggerVersion
                                try t.update(db)
                            }
                            // Manual tag: leave alone
                        } else {
                            var t = TagRow(
                                id: UUID().uuidString,
                                file_id: fileID,
                                parent_dir: dir,
                                label: tag.label,
                                source: tag.source,
                                confidence: tag.confidence,
                                model_version: taggerVersion
                            )
                            try t.insert(db)
                        }
                    }
                }

                // Raster-derived traits (faces/pets/sharpness) from the SAME
                // decode Vision used. Inside the guarded transaction so a
                // mid-pass edit can't stamp stale traits at the new hash.
                if let traits = out.traits {
                    var traitsRow = PhotoTraitsRow(
                        file_id: fileID, traits_scanned_hash: analyzedHash,
                        traits_version: PhotoTraits.currentVersion,
                        face_count: traits.faceCount, largest_face_frac: traits.largestFaceFrac,
                        face_quality: traits.faceQuality, pet_count: traits.petCount,
                        sharpness: traits.sharpness,
                        clip_high_r: traits.clipHighR, clip_high_g: traits.clipHighG,
                        clip_high_b: traits.clipHighB, clip_low: traits.clipLow,
                        noise_sigma: traits.noiseSigma)
                    try traitsRow.save(db)
                }

                // FTS5 — keyed by files.id (immutable). Replace the row.
                try db.execute(sql: "DELETE FROM files_fts WHERE file_id = ?", arguments: [fileID])
                try db.execute(sql: """
                    INSERT INTO files_fts(file_id, basename, ocr_text, caption)
                    VALUES (?, ?, ?, ?)
                """, arguments: [fileID, basename, out.ocrText, caption])
                return true
            }
        } catch {
            print("[AnalyzePipeline] write failed: \(error)")
        }
        // Content changed mid-pass (or the row vanished) — the embedding and
        // sidecar would describe the OLD bytes; skip them too.
        guard committed else { return }

        // Embedding write — separate from the main transaction; embedder may be nil.
        if let embedder = registry.embedder {
            let doc = (out.tags.map(\.label) + [out.caption ?? "", String(out.ocrText.prefix(300))])
                .joined(separator: " ")
            let embedderVersion = embedder.modelVersion
            if let vec = embedder.embed(doc) {
                try? await queue.write { db in
                    var row = EmbeddingRow(file_id: fileID,
                                           vector: VectorMath.toData(vec),
                                           model_version: embedderVersion,
                                           updated_at: Int64(Date().timeIntervalSince1970))
                    try row.save(db)
                }
                embeddingsWritten += 1
            }
        }

        await writeSidecarIfICloud(fileID: fileID, url: url, mergeExisting: true)
    }
}
