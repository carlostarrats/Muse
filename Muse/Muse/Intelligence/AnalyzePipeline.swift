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
        isRunning = true
        current = url.lastPathComponent
        defer { isRunning = false; current = ""; progress = 0 }
        await analyzeOne(fileID: id, url: url)
        if shouldStop { return }
        await CollectionsEngine.shared.recluster()
    }

    /// The automatic pass: of `urls`, analyze only those whose stored
    /// analyzed_hash is missing or stale (new or edited images). Runs
    /// after every index pass — analyzing twice is a provable no-op.
    func analyzePending(in urls: [URL]) async {
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

    func analyze(folder urls: [URL]) async {
        guard !urls.isEmpty else { return }
        guard let queue = Database.shared.dbQueue else { return }
        cancelRequested = false
        isRunning = true
        progress = 0
        completed = 0
        defer { isRunning = false; current = ""; progress = 0; completed = 0; total = 0 }

        // Resolve to unique file IDs first, so duplicate content (the same
        // bytes under several paths) is analyzed ONCE — and the count reflects
        // real files, not path count.
        var pairs: [(id: String, url: URL)] = []
        var seen = Set<String>()
        for url in urls {
            if shouldStop { return }
            let absPath = url.standardizedFileURL.path
            let fileID: String? = (try? await queue.read { db -> String? in
                try PathRow
                    .filter(PathRow.Columns.absolute_path == absPath)
                    .filter(PathRow.Columns.is_alive == 1)
                    .fetchOne(db)?.file_id
            }) ?? nil
            if let id = fileID, !seen.contains(id) {
                seen.insert(id)
                pairs.append((id, url))
            }
        }
        total = pairs.count
        guard !pairs.isEmpty else { return }

        for (idx, pair) in pairs.enumerated() {
            // Folder removed (or the pass otherwise cancelled) → stop now
            // rather than analyzing files that are no longer reachable.
            if shouldStop { break }
            current = pair.url.lastPathComponent
            await analyzeOne(fileID: pair.id, url: pair.url)
            completed = idx + 1
            progress = Double(idx + 1) / Double(pairs.count)
        }
        isRunning = false; current = ""; progress = 0; completed = 0; total = 0
        // Skip the (non-trivial) recluster if the pass was cancelled — e.g. the
        // folder was removed out from under us; there's nothing new to cluster.
        if shouldStop { return }
        await CollectionsEngine.shared.recluster()
    }

    // MARK: - Per-file

    /// If `url` is in the iCloud zone, export the file's current metadata to a
    /// `.muse/<hash>.json` sidecar so it syncs to other devices. No-op for
    /// local-zone files / when iCloudFolder is nil. Reads the freshly-written
    /// FileRow + tags back out; does the file write off the main actor.
    private func writeSidecarIfICloud(fileID: String, url: URL) async {
        guard ICloudZone.contains(url, folder: iCloudFolder) else { return }
        guard let queue = Database.shared.dbQueue else { return }
        let now = Int64(Date().timeIntervalSince1970)
        let dir = TagScope.parentDir(of: url)
        let bundle: (FileRow, [TagRow])? = try? await queue.read { db -> (FileRow, [TagRow])? in
            guard let file = try FileRow.filter(FileRow.Columns.id == fileID).fetchOne(db)
            else { return nil }
            // Sidecar lives in this file's folder → carry only this folder's tags.
            let tags = try TagRow
                .filter(TagRow.Columns.file_id == fileID)
                .filter(TagRow.Columns.parent_dir == dir)
                .fetchAll(db)
            return (file, tags)
        }
        guard let (file, tags) = bundle,
              let sidecar = Sidecar.build(from: file, tags: tags, updatedAt: now) else { return }
        // Sidecar + URL are Sendable; write off-main so the (tiny) coordinated
        // disk write never blocks the main actor. Log on failure — a silent
        // write failure would silently defeat the "no re-Vision on sync" promise.
        await Task.detached {
            do { try SidecarStore.write(sidecar, forAsset: url) }
            catch { print("[AnalyzePipeline] sidecar write failed for \(url.lastPathComponent): \(error)") }
        }.value
    }

    private func analyzeOne(fileID: String, url: URL) async {
        // Skip non-image kinds; Vision pipeline only handles images
        let kind = AssetKind.detect(at: url)
        guard kind == .image || kind == .raw || kind == .psd else { return }

        let registry = IntelligenceRegistry.shared
        guard let out = await registry.tagger.analyze(url: url) else { return }

        guard let queue = Database.shared.dbQueue else { return }
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

        do {
            try await queue.write { db in
                // Update files row
                if var file = try FileRow.filter(FileRow.Columns.id == fileID).fetchOne(db) {
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
                    file.analyzed_hash = file.content_hash
                    file.intent = finalIntentKey
                    file.intent_model_version = finalIntentVersion
                    try file.update(db)
                }

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

                // FTS5 — keyed by files.id (immutable). Replace the row.
                try db.execute(sql: "DELETE FROM files_fts WHERE file_id = ?", arguments: [fileID])
                try db.execute(sql: """
                    INSERT INTO files_fts(file_id, basename, ocr_text, caption)
                    VALUES (?, ?, ?, ?)
                """, arguments: [fileID, basename, out.ocrText, caption])
            }
        } catch {
            print("[AnalyzePipeline] write failed: \(error)")
        }

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
            }
        }

        await writeSidecarIfICloud(fileID: fileID, url: url)
    }
}
