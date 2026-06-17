//
//  Indexer.swift
//  Muse
//
//  Background queue that walks the active folder, hashes files, and
//  applies the identity reconciliation matrix from the rewrite plan §4.
//
//  Active folder runs on a high-priority queue; other roots are
//  best-effort background (Q29 indexer priority). Vision pipeline is
//  out of scope here — it only fires on user click ("Analyze") in
//  Phase 3.
//

import Foundation
import GRDB

/// Observable indexing progress for the bottom-center pill: how many files
/// of the current batch (or overlapping batches) have been reconciled.
@MainActor
final class IndexProgress: ObservableObject {
    static let shared = IndexProgress()
    @Published private(set) var total = 0
    @Published private(set) var completed = 0
    var isActive: Bool { total > 0 }

    func begin(_ count: Int) { total += count }
    func step() {
        completed += 1
        if completed >= total { total = 0; completed = 0 }
    }
}

actor Indexer {
    static let shared = Indexer()

    private var inFlightHashes: Set<String> = []

    /// Index a single file synchronously (call site decides priority via dispatch).
    /// Performs hashing + identity reconciliation per the matrix.
    ///
    /// Returns `true` when the file's CONTENT changed in place (the path was
    /// already known but now hashes differently) — the signal AppState uses to
    /// drop stale thumbnails and re-run analysis. A brand-new file or a fresh
    /// path returns `false` (nothing cached to invalidate).
    @discardableResult
    func indexFile(at url: URL, kind: AssetKind) -> Bool {
        let absPath = url.standardizedFileURL.path
        if inFlightHashes.contains(absPath) { return false }
        inFlightHashes.insert(absPath)
        defer { inFlightHashes.remove(absPath) }

        // Dataless iCloud placeholders have no local bytes — hashing them
        // reads empty and corrupts identity. Skip until downloaded.
        if Self.isDataless(url) { return false }

        guard let queue = Database.shared.dbQueue else { return false }

        // The fast-path skip for already-known, unchanged files lives in
        // `indexBatch`'s discovery pass now — so the progress pill never
        // counts skipped files. Reaching here means the file genuinely
        // needs (re)hashing.
        let now = Int64(Date().timeIntervalSince1970)
        let attrs = try? FileManager.default.attributesOfItem(atPath: absPath)
        let sizeBytes = (attrs?[.size] as? NSNumber)?.int64Value
        let modifiedAt = (attrs?[.modificationDate] as? Date).map { Int64($0.timeIntervalSince1970) }
        let createdAt = (attrs?[.creationDate] as? Date).map { Int64($0.timeIntervalSince1970) }

        // Hash on caller's thread (we're already on a background actor)
        guard let hash = HashService.sha256(of: url) else { return false }

        do {
            return try queue.write { db in
                try Self.reconcile(
                    db: db,
                    absPath: absPath,
                    hash: hash,
                    kind: kind,
                    sizeBytes: sizeBytes,
                    createdAt: createdAt,
                    modifiedAt: modifiedAt,
                    now: now
                )
            }
        } catch {
            print("[Indexer] write failed for \(absPath): \(error)")
            return false
        }
    }

    /// Identity reconciliation matrix from the plan §4. Anchored at "moment
    /// hashing completes for a previously-enumerated path."
    ///
    /// Returns `true` when an already-known alive path now hashes to different
    /// content (a genuine in-place edit) — so the caller can drop stale
    /// thumbnails and re-run analysis. New files / new paths return `false`.
    @discardableResult
    private static func reconcile(
        db: GRDB.Database,
        absPath: String,
        hash: String,
        kind: AssetKind,
        sizeBytes: Int64?,
        createdAt: Int64?,
        modifiedAt: Int64?,
        now: Int64
    ) throws -> Bool {

        // 1. Look up alive path.
        let alivePath = try PathRow
            .filter(PathRow.Columns.absolute_path == absPath)
            .filter(PathRow.Columns.is_alive == 1)
            .fetchOne(db)

        // 2. Look up file by hash.
        let existingFileByHash = try FileRow
            .filter(FileRow.Columns.content_hash == hash)
            .fetchOne(db)

        if var path = alivePath {
            // Known alive path
            guard let fileID = path.file_id,
                  var file = try FileRow.filter(FileRow.Columns.id == fileID).fetchOne(db) else {
                // Path exists but file missing — treat as new file.
                var newFile = makeFile(hash: hash, kind: kind, size: sizeBytes,
                                       created: createdAt, modified: modifiedAt, now: now)
                try newFile.insert(db)
                path.file_id = newFile.id
                try path.update(db)
                return false
            }

            if file.content_hash == hash {
                // Same content — but REFRESH the stored size/mtime to what the
                // filesystem reports now. iCloud rewrites size/mtime on sync,
                // so a stale stored value makes the size+mtime fast path miss
                // forever and re-hash the same file on every visit (the cause
                // of the recurring "indexing 920" + UI freeze on the iCloud
                // folder). Persisting current values lets the next pass skip it.
                file.size_bytes = sizeBytes
                file.modified_at = modifiedAt
                file.last_seen_at = now
                try file.update(db)
                return false
            }

            // Hash changed — edit-in-place
            if let target = existingFileByHash, target.id != file.id {
                // Hash collision: re-link path to the matching files row,
                // union tags, prune previous file row if orphaned.
                try unionTags(db: db, fromFileID: file.id, toFileID: target.id)
                path.file_id = target.id
                try path.update(db)
                try pruneIfOrphaned(db: db, fileID: file.id)

                var refreshed = target
                refreshed.last_seen_at = now
                try refreshed.update(db)
            } else {
                // Pure edit-in-place: update hash on the existing file row.
                // Reset analyzed_hash so the analyze pass re-runs Vision — a
                // crop/edit can change colors, dimensions, and OCR'd text, so
                // the old tags/palette must not stick. (analyzed_hash != the
                // new content_hash also makes analyzePending pick it up.)
                file.content_hash = hash
                file.size_bytes = sizeBytes
                file.modified_at = modifiedAt
                file.last_seen_at = now
                file.analyzed_hash = nil
                try file.update(db)
            }
            return true
        }

        // No alive path. Check for a dead path with the same absolute_path.
        let deadPaths = try PathRow
            .filter(PathRow.Columns.absolute_path == absPath)
            .filter(PathRow.Columns.is_alive == 0)
            .fetchAll(db)

        if let target = existingFileByHash {
            // New alive path of known content — copy/hardlink
            if var deadPath = deadPaths.first(where: { $0.file_id == target.id }) {
                // Path-resurrection: same hash matches the dead row's file.
                deadPath.is_alive = 1
                try deadPath.update(db)
                var refreshed = target
                refreshed.last_seen_at = now
                try refreshed.update(db)
                try inheritVisionTags(db: db, fileID: target.id,
                                      toDir: TagScope.parentDir(ofPath: absPath))
                return false
            }
            // Otherwise: brand-new path pointing at known content
            var newPath = PathRow(
                id: UUID().uuidString,
                file_id: target.id,
                absolute_path: absPath,
                bookmark_data: nil,
                is_alive: 1
            )
            try newPath.insert(db)
            var refreshed = target
            refreshed.last_seen_at = now
            try refreshed.update(db)
            try inheritVisionTags(db: db, fileID: target.id,
                                  toDir: TagScope.parentDir(ofPath: absPath))
            return false
        }

        // No file with this hash. Brand new file (or path was reused with new content).
        // If there's a dead path at this absolute_path with a different hash, leave it
        // alone (will be pruned after grace window).
        var newFile = makeFile(hash: hash, kind: kind, size: sizeBytes,
                               created: createdAt, modified: modifiedAt, now: now)
        try newFile.insert(db)
        var newPath = PathRow(
            id: UUID().uuidString,
            file_id: newFile.id,
            absolute_path: absPath,
            bookmark_data: nil,
            is_alive: 1
        )
        try newPath.insert(db)
        return false
    }

    private static func makeFile(
        hash: String,
        kind: AssetKind,
        size: Int64?,
        created: Int64?,
        modified: Int64?,
        now: Int64
    ) -> FileRow {
        FileRow(
            id: UUID().uuidString,
            content_hash: hash,
            kind: kind.rawValue,
            size_bytes: size,
            width: nil,
            height: nil,
            duration_seconds: nil,
            created_at: created,
            modified_at: modified,
            last_seen_at: now,
            caption: nil,
            dominant_color: nil,
            feature_print: nil,
            palette: nil,
            analyzed_hash: nil
        )
    }

    /// Q32: manual beats vision on conflict. Union semantics: copy tags from
    /// `from` to `to`; on (file_id, label) conflict keep the existing row if
    /// it's manual, or replace it with the manual incoming row, otherwise
    /// ignore the incoming.
    // internal (not private) so MuseTests can exercise the per-folder merge.
    static func unionTags(db: GRDB.Database, fromFileID: String, toFileID: String) throws {
        let fromTags = try TagRow.filter(TagRow.Columns.file_id == fromFileID).fetchAll(db)
        for var t in fromTags {
            // Conflict is per (file_id, parent_dir): the same physical file at
            // the same path keeps its folder scope when it re-links to `to`.
            if let existing = try TagRow
                .filter(TagRow.Columns.file_id == toFileID)
                .filter(TagRow.Columns.parent_dir == t.parent_dir)
                .filter(TagRow.Columns.label == t.label)
                .fetchOne(db) {
                if t.source == "manual" && existing.source != "manual" {
                    // Replace with manual
                    var updated = existing
                    updated.source = "manual"
                    updated.confidence = nil
                    updated.model_version = nil
                    try updated.update(db)
                }
                // Else keep existing
            } else {
                t.id = UUID().uuidString
                t.file_id = toFileID
                // parent_dir preserved — the folder didn't change.
                try t.insert(db)
            }
        }
        // Delete the originals once unioned
        try TagRow.filter(TagRow.Columns.file_id == fromFileID).deleteAll(db)
    }

    /// A brand-new path of already-known content inherits the file's VISION
    /// tags for ITS folder (identical pixels → identical vision tags), so a
    /// duplicate copied into a new folder isn't blank even though the file is
    /// already analyzed (the analyze pass skips it on analyzed_hash). Manual
    /// tags are per-folder and are NOT inherited. No-op if this folder already
    /// has tags, or if the content was never analyzed (the analyze pass will
    /// then write to every alive folder).
    // internal (not private) so MuseTests can exercise the inheritance rule.
    static func inheritVisionTags(db: GRDB.Database, fileID: String, toDir: String) throws {
        let hasHere = try TagRow
            .filter(TagRow.Columns.file_id == fileID)
            .filter(TagRow.Columns.parent_dir == toDir)
            .fetchCount(db)
        if hasHere > 0 { return }
        let visionTags = try TagRow
            .filter(TagRow.Columns.file_id == fileID)
            .filter(TagRow.Columns.source != "manual")
            .fetchAll(db)
        var seen = Set<String>()
        for var t in visionTags {
            guard seen.insert(t.label).inserted else { continue }
            t.id = UUID().uuidString
            t.parent_dir = toDir
            try t.insert(db)
        }
    }

    private static func pruneIfOrphaned(db: GRDB.Database, fileID: String) throws {
        let aliveCount = try PathRow
            .filter(PathRow.Columns.file_id == fileID)
            .filter(PathRow.Columns.is_alive == 1)
            .fetchCount(db)
        if aliveCount == 0 {
            // Mark orphaned by leaving the row but with no alive paths; an
            // explicit prune pass after the 30-day grace window deletes it.
            // For now, no-op — deletion is post-v1 housekeeping.
        }
    }

    // MARK: - Fast-path helpers

    /// Dataless iCloud placeholder — no local bytes to hash yet.
    private static func isDataless(_ url: URL) -> Bool {
        if let status = (try? url.resourceValues(
                forKeys: [.ubiquitousItemDownloadingStatusKey]))?
                .ubiquitousItemDownloadingStatus,
           status == .notDownloaded {
            return true
        }
        return false
    }

    /// True if the file is already indexed and can be treated as unchanged —
    /// the fast path that makes re-opening a known folder near-instant. Touches
    /// last_seen_at at most daily for 180-day retention. Files that return true
    /// do NO hashing and are NOT counted by the indexing progress pill.
    ///
    /// - Local files: matched by size + mtime (a reliable change signal).
    /// - iCloud files (`isUbiquitous`): size/mtime are NOT reliable — iCloud
    ///   rewrites them on sync and they oscillate between values on successive
    ///   reads, so the size+mtime proxy can never converge and would re-hash
    ///   the whole folder on every visit. An already-hashed iCloud file is
    ///   trusted as unchanged instead. (Genuine edits arrive via sync and the
    ///   folder watcher, not by polling metadata here.)
    private static func isUnchanged(absPath: String, sizeBytes: Int64?,
                                    modifiedAt: Int64?, isUbiquitous: Bool,
                                    now: Int64, queue: DatabaseQueue) -> Bool {
        struct Known { let fileID: String; let lastSeen: Int64 }
        let known: Known? = (try? queue.read { db -> Known? in
            guard let path = try PathRow
                    .filter(PathRow.Columns.absolute_path == absPath)
                    .filter(PathRow.Columns.is_alive == 1)
                    .fetchOne(db),
                  let fid = path.file_id,
                  let file = try FileRow.filter(FileRow.Columns.id == fid).fetchOne(db),
                  file.content_hash != nil
            else { return nil }
            // iCloud: trust the existing hash (metadata is unreliable).
            if isUbiquitous {
                return Known(fileID: fid, lastSeen: file.last_seen_at)
            }
            // Local: require an exact size + mtime match.
            guard file.size_bytes == sizeBytes, file.modified_at == modifiedAt
            else { return nil }
            return Known(fileID: fid, lastSeen: file.last_seen_at)
        }) ?? nil
        guard let known else { return false }
        if now - known.lastSeen > 86_400 {
            try? queue.write { db in
                try db.execute(sql: "UPDATE files SET last_seen_at = ? WHERE id = ?",
                               arguments: [now, known.fileID])
            }
        }
        return true
    }

    // MARK: - Active folder pass

    /// Public entry: hash all enumerated files in `urls`. Work is windowed
    /// (a couple of files in flight, the rest queued) at utility/background
    /// priority — an unbounded fan-out of userInitiated hashing tasks made
    /// the UI stutter on large libraries.
    ///
    /// Returns the URLs whose CONTENT changed in place (so the caller can drop
    /// stale thumbnails + re-analyze).
    ///
    /// - `force`: re-hash every file, skipping the size/mtime/known-hash
    ///   discovery shortcut. Used to (a) re-verify files an FSEvents change
    ///   flagged and (b) catch iCloud edits made while the app was closed —
    ///   iCloud size/mtime oscillates so the normal fast path trusts the
    ///   stored hash and would never notice. Pair `force` with `silent` so the
    ///   verify pass doesn't flash the "Indexing N of M" pill on every visit.
    /// - `silent`: don't drive the progress pill (background verification).
    @discardableResult
    func indexBatch(_ urls: [(URL, AssetKind)], priority: Priority,
                    force: Bool = false, silent: Bool = false) async -> [URL] {
        guard !urls.isEmpty else { return [] }
        guard let queue = Database.shared.dbQueue else { return [] }
        let now = Int64(Date().timeIntervalSince1970)

        // Discovery: skip already-known, unchanged files up front (touching
        // last_seen for retention). Only files that genuinely need
        // (re)hashing survive — so a fully indexed folder does zero work and
        // shows NO progress pill on relaunch. `force` re-hashes everything
        // (still skipping dataless placeholders, which have no bytes).
        var work: [(URL, AssetKind)] = []
        work.reserveCapacity(urls.count)
        for (url, kind) in urls {
            if Self.isDataless(url) { continue }
            if force { work.append((url, kind)); continue }
            // An iCloud item reports a downloading status; a plain local file
            // reports nil. iCloud size/mtime can't be trusted as a change
            // signal (it oscillates on sync), so isUnchanged trusts the hash.
            let isUbiquitous = (try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey]))?
                .ubiquitousItemDownloadingStatus != nil
            let absPath = url.standardizedFileURL.path
            let rv = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            let sizeBytes = rv?.fileSize.map { Int64($0) }
            let modifiedAt = rv?.contentModificationDate.map { Int64($0.timeIntervalSince1970) }
            if Self.isUnchanged(absPath: absPath, sizeBytes: sizeBytes,
                                modifiedAt: modifiedAt, isUbiquitous: isUbiquitous,
                                now: now, queue: queue) {
                continue
            }
            work.append((url, kind))
        }
        guard !work.isEmpty else { return [] }

        if !silent { await IndexProgress.shared.begin(work.count) }
        let taskPriority: TaskPriority = (priority == .high) ? .utility : .background

        var changed: [URL] = []
        await withTaskGroup(of: URL?.self) { group in
            var iterator = work.makeIterator()
            var inFlight = 0
            func enqueueNext() -> Bool {
                guard let (url, kind) = iterator.next() else { return false }
                group.addTask(priority: taskPriority) {
                    let didChange = await self.indexFile(at: url, kind: kind)
                    if !silent { await IndexProgress.shared.step() }
                    return didChange ? url : nil
                }
                return true
            }
            while inFlight < 2, enqueueNext() { inFlight += 1 }
            while let result = await group.next() {
                if let u = result { changed.append(u) }
                _ = enqueueNext()
            }
        }
        return changed
    }

    enum Priority { case high, background }
}
