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
    func indexFile(at url: URL, kind: AssetKind) {
        let absPath = url.standardizedFileURL.path
        if inFlightHashes.contains(absPath) { return }
        inFlightHashes.insert(absPath)
        defer { inFlightHashes.remove(absPath) }

        // Dataless iCloud placeholders have no local bytes — hashing them
        // reads empty and corrupts identity. Skip until downloaded; the
        // next pass after download reconciles them normally.
        if let status = (try? url.resourceValues(
                forKeys: [.ubiquitousItemDownloadingStatusKey]))?
                .ubiquitousItemDownloadingStatus,
           status == .notDownloaded {
            return
        }

        guard let queue = Database.shared.dbQueue else { return }

        let now = Int64(Date().timeIntervalSince1970)
        let attrs = try? FileManager.default.attributesOfItem(atPath: absPath)
        let sizeBytes = (attrs?[.size] as? NSNumber)?.int64Value
        let modifiedAt = (attrs?[.modificationDate] as? Date).map { Int64($0.timeIntervalSince1970) }
        let createdAt = (attrs?[.creationDate] as? Date).map { Int64($0.timeIntervalSince1970) }

        // Hash on caller's thread (we're already on a background actor)
        guard let hash = HashService.sha256(of: url) else { return }

        do {
            try queue.write { db in
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
        }
    }

    /// Identity reconciliation matrix from the plan §4. Anchored at "moment
    /// hashing completes for a previously-enumerated path."
    private static func reconcile(
        db: GRDB.Database,
        absPath: String,
        hash: String,
        kind: AssetKind,
        sizeBytes: Int64?,
        createdAt: Int64?,
        modifiedAt: Int64?,
        now: Int64
    ) throws {

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
                return
            }

            if file.content_hash == hash {
                // Unchanged — touch last_seen_at
                file.last_seen_at = now
                try file.update(db)
                return
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
                // Pure edit-in-place: update hash on the existing file row
                file.content_hash = hash
                file.size_bytes = sizeBytes
                file.modified_at = modifiedAt
                file.last_seen_at = now
                try file.update(db)
            }
            return
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
                return
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
            return
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
            palette: nil
        )
    }

    /// Q32: manual beats vision on conflict. Union semantics: copy tags from
    /// `from` to `to`; on (file_id, label) conflict keep the existing row if
    /// it's manual, or replace it with the manual incoming row, otherwise
    /// ignore the incoming.
    private static func unionTags(db: GRDB.Database, fromFileID: String, toFileID: String) throws {
        let fromTags = try TagRow.filter(TagRow.Columns.file_id == fromFileID).fetchAll(db)
        for var t in fromTags {
            // Does target already have this label?
            if let existing = try TagRow
                .filter(TagRow.Columns.file_id == toFileID)
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
                try t.insert(db)
            }
        }
        // Delete the originals once unioned
        try TagRow.filter(TagRow.Columns.file_id == fromFileID).deleteAll(db)
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

    // MARK: - Active folder pass

    /// Public entry: hash all enumerated files in `urls`. Work is windowed
    /// (a couple of files in flight, the rest queued) at utility/background
    /// priority — an unbounded fan-out of userInitiated hashing tasks made
    /// the UI stutter on large libraries.
    func indexBatch(_ urls: [(URL, AssetKind)], priority: Priority) async {
        guard !urls.isEmpty else { return }
        await IndexProgress.shared.begin(urls.count)
        let taskPriority: TaskPriority = (priority == .high) ? .utility : .background

        await withTaskGroup(of: Void.self) { group in
            var iterator = urls.makeIterator()
            var inFlight = 0
            func enqueueNext() -> Bool {
                guard let (url, kind) = iterator.next() else { return false }
                group.addTask(priority: taskPriority) {
                    await self.indexFile(at: url, kind: kind)
                    await IndexProgress.shared.step()
                }
                return true
            }
            while inFlight < 2, enqueueNext() { inFlight += 1 }
            while await group.next() != nil {
                _ = enqueueNext()
            }
        }
    }

    enum Priority { case high, background }
}
