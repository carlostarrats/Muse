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
    // internal (not private) so MuseTests can exercise the identity-reconcile
    // edge cases (e.g. the shared-row split on edit-in-place).
    @discardableResult
    static func reconcile(
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
                try insertBasenameFTS(db: db, fileID: newFile.id, absPath: absPath)
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
                // Hash collision: the edited path's new bytes match a DIFFERENT
                // existing row — re-link the path to it. The old row may be
                // SHARED (other alive paths in other folders): unioning ALL its
                // tags would strip the untouched siblings' tags off their
                // identity (same defect class the split branch below guards
                // against), so when the row is shared, scope the carry to THIS
                // path's folder — copy-vs-move by the same same-dir-sibling
                // rule as the split branch.
                let dir = TagScope.parentDir(ofPath: absPath)
                let otherAlive = try PathRow
                    .filter(PathRow.Columns.file_id == file.id)
                    .filter(PathRow.Columns.is_alive == 1)
                    .filter(PathRow.Columns.absolute_path != absPath)
                    .fetchAll(db)
                if otherAlive.isEmpty {
                    // Sole alive path — the old identity is done for; union
                    // everything as before.
                    try unionTags(db: db, fromFileID: file.id, toFileID: target.id)
                    // Notes follow tags: copy every note onto the target; the old
                    // row's remaining note rows cascade-delete when it's pruned.
                    try NoteStore.carryAll(fromFileID: file.id, toFileID: target.id, db: db)
                } else {
                    let keepsSiblingInDir = otherAlive
                        .contains { TagScope.parentDir(ofPath: $0.absolute_path) == dir }
                    try unionTags(db: db, fromFileID: file.id, toFileID: target.id,
                                  parentDir: dir, deleteOriginals: !keepsSiblingInDir)
                    try NoteStore.carry(fromFileID: file.id, fromDir: dir,
                                        toFileID: target.id, toDir: dir,
                                        deleteOriginal: !keepsSiblingInDir, db: db)
                }
                // Manual collection membership is precious user data keyed on
                // the old identity — copy it to the new one, mirroring the
                // split branch (COPY, not move: a surviving sibling still
                // resolves via the old file_id and legitimately stays a member).
                try db.execute(sql: """
                    INSERT OR IGNORE INTO collection_members (collection_id, file_id, added_by)
                    SELECT collection_id, ?, added_by FROM collection_members
                    WHERE file_id = ? AND added_by = 'manual'
                    """, arguments: [target.id, file.id])
                path.file_id = target.id
                try path.update(db)
                try pruneIfOrphaned(db: db, fileID: file.id)

                var refreshed = target
                refreshed.last_seen_at = now
                try refreshed.update(db)
            } else {
                // The new content is genuinely new (no existing row has this
                // hash). But this files row may be SHARED by more than one alive
                // path: two byte-identical files in different folders dedupe onto
                // a single content_hash row (the "brand-new path pointing at known
                // content" branch below). Editing ONE copy must not rewrite the
                // shared row — that welds the new hash/size/dims onto the untouched
                // sibling and marks it unanalyzed, and on the sibling's next index
                // pass its real (old) bytes hash differently again, flipping the
                // row's content_hash back: the two copies then ping-pong the shared
                // row and re-hash/re-Vision forever.
                let aliveCount = try PathRow
                    .filter(PathRow.Columns.file_id == file.id)
                    .filter(PathRow.Columns.is_alive == 1)
                    .fetchCount(db)
                if aliveCount > 1 {
                    // SPLIT: move only this edited path onto a fresh row for the new
                    // content, carrying its location's tags (manual tags are
                    // precious; vision tags regenerate since analyzed_hash is nil).
                    // The original row, its other paths, and their tags are left
                    // intact for the unedited sibling(s).
                    var newFile = makeFile(hash: hash, kind: kind, size: sizeBytes,
                                           created: createdAt, modified: modifiedAt, now: now)
                    try newFile.insert(db)
                    try insertBasenameFTS(db: db, fileID: newFile.id, absPath: absPath)
                    let dir = TagScope.parentDir(ofPath: absPath)
                    // Tags are keyed (file_id, parent_dir). If the original row KEEPS
                    // another alive path in THIS SAME folder (a byte-identical
                    // same-folder copy), its (file_id, dir) tag rows are shared with
                    // that still-present sibling — COPY them to the new identity so
                    // neither copy loses them. Otherwise the original no longer
                    // surfaces this folder's tags (its remaining paths are in other
                    // folders), so MOVE them, which also avoids orphan rows.
                    let keepsSiblingInDir = try PathRow
                        .filter(PathRow.Columns.file_id == file.id)
                        .filter(PathRow.Columns.is_alive == 1)
                        .filter(PathRow.Columns.absolute_path != absPath)
                        .fetchAll(db)
                        .contains { TagScope.parentDir(ofPath: $0.absolute_path) == dir }
                    if keepsSiblingInDir {
                        try db.execute(sql: """
                            INSERT OR IGNORE INTO tags (id, file_id, parent_dir, label, source, confidence, model_version)
                            SELECT lower(hex(randomblob(16))), ?, parent_dir, label, source, confidence, model_version
                            FROM tags WHERE file_id = ? AND parent_dir = ?
                            """, arguments: [newFile.id, file.id, dir])
                    } else {
                        try db.execute(sql:
                            "UPDATE tags SET file_id = ? WHERE file_id = ? AND parent_dir = ?",
                            arguments: [newFile.id, file.id, dir])
                    }
                    // The (file_id, dir) note follows its tags onto the new
                    // identity — COPY when a same-folder sibling still surfaces
                    // it, MOVE otherwise. Skipping this dropped the edited copy's
                    // note when a shared row split.
                    try NoteStore.carry(fromFileID: file.id, fromDir: dir,
                                        toFileID: newFile.id, toDir: dir,
                                        deleteOriginal: !keepsSiblingInDir, db: db)
                    // Manual collection membership is content-identity (file_id)
                    // keyed and is precious user data — carry it to the edited
                    // copy's new identity so an edit doesn't silently eject the
                    // file from collections the user added it to. COPY (not move):
                    // the unedited sibling still resolves via the old file_id and
                    // legitimately stays a member. Auto membership is regenerated by
                    // the recluster, so it's intentionally left alone.
                    try db.execute(sql: """
                        INSERT OR IGNORE INTO collection_members (collection_id, file_id, added_by)
                        SELECT collection_id, ?, added_by FROM collection_members
                        WHERE file_id = ? AND added_by = 'manual'
                        """, arguments: [newFile.id, file.id])
                    path.file_id = newFile.id
                    try path.update(db)
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
                // A file that was dead at v9-backfill time has no FTS row —
                // seed the basename one now so it's name-searchable again.
                try ensureBasenameFTS(db: db, fileID: target.id, absPath: absPath)
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
            // An external RENAME lands here (old path dies, same content
            // reappears under a new name). The FTS basename was written at
            // analyze time and content didn't change, so it would keep the OLD
            // name forever — "everywhere" search then misses the file by its
            // current name. Refresh it when this is now the file's sole alive
            // path (with several paths the one FTS basename is ambiguous —
            // leave it).
            let aliveNow = try PathRow
                .filter(PathRow.Columns.file_id == target.id)
                .filter(PathRow.Columns.is_alive == 1)
                .fetchCount(db)
            if aliveNow == 1 {
                try db.execute(sql: "UPDATE files_fts SET basename = ? WHERE file_id = ?",
                               arguments: [(absPath as NSString).lastPathComponent, target.id])
            }
            // The UPDATE above no-ops when the row is missing (a file dead at
            // v9-backfill time) — make sure a basename row exists either way.
            try ensureBasenameFTS(db: db, fileID: target.id, absPath: absPath)
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
        try insertBasenameFTS(db: db, fileID: newFile.id, absPath: absPath)
        return false
    }

    /// Seed a basename-only FTS row for a NEW file identity, whatever its
    /// kind. Historically only analyzed images got an FTS row (`analyzeOne`
    /// writes the full basename+OCR+caption one), so "All folders" search
    /// could never find a PDF/video/archive by name. `analyzeOne` replaces
    /// this row wholesale when it runs; non-analyzed kinds keep it.
    private static func insertBasenameFTS(db: GRDB.Database, fileID: String, absPath: String) throws {
        try db.execute(sql: """
            INSERT INTO files_fts(file_id, basename, ocr_text, caption)
            VALUES (?, ?, '', '')
            """, arguments: [fileID, (absPath as NSString).lastPathComponent])
    }

    /// Insert-if-missing variant for RESURRECTED identities: never clobbers an
    /// existing (possibly analyzed, OCR-bearing) row, only fills the gap left
    /// for files that were dead when the v9 backfill ran.
    private static func ensureBasenameFTS(db: GRDB.Database, fileID: String, absPath: String) throws {
        let has = (try Int.fetchOne(db, sql:
            "SELECT COUNT(*) FROM files_fts WHERE file_id = ?", arguments: [fileID]) ?? 0) > 0
        if !has { try insertBasenameFTS(db: db, fileID: fileID, absPath: absPath) }
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
    /// `parentDir` scopes the union to one folder's tag rows (nil = all —
    /// correct only when the source identity has no other alive paths).
    /// `deleteOriginals: false` copies instead of moving, for when a
    /// same-folder sibling still surfaces the source rows.
    static func unionTags(db: GRDB.Database, fromFileID: String, toFileID: String,
                          parentDir: String? = nil, deleteOriginals: Bool = true) throws {
        var query = TagRow.filter(TagRow.Columns.file_id == fromFileID)
        if let parentDir { query = query.filter(TagRow.Columns.parent_dir == parentDir) }
        let fromTags = try query.fetchAll(db)
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
        // Delete the originals once unioned (scoped the same way as the read).
        if deleteOriginals {
            var doomed = TagRow.filter(TagRow.Columns.file_id == fromFileID)
            if let parentDir { doomed = doomed.filter(TagRow.Columns.parent_dir == parentDir) }
            try doomed.deleteAll(db)
        }
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

    // MARK: - Discovery decision (pure)

    /// The discovery-time decision for a single enumerated file. There is
    /// deliberately no `.changed` case — whether edited bytes are genuinely new
    /// content is not knowable at discovery (it needs the hash); that belongs to
    /// `reconcile`, AFTER hashing. Discovery is skip / hash / skip-dataless only.
    enum IndexDecision: Equatable {
        case unchanged      // known + alive + hash present + (iCloud OR local size&mtime match) → no hashing
        case needsHashing   // unknown path / missing file row / NULL content_hash / local size|mtime mismatch → hash
        case skipDataless   // dataless iCloud placeholder — no local bytes to hash yet
    }

    /// The stored identity of an alive path, read from the DB. Packaged as a
    /// pure value so `decideIndexAction` needs no queue and is exhaustively
    /// unit-testable. A `nil` StoredIdentity means "no alive path / null
    /// file_id / missing file row" — the old read guards that returned nil.
    struct StoredIdentity: Equatable {
        let fileID: String
        let contentHash: String?
        let size: Int64?
        let mtime: Int64?
        let lastSeen: Int64
    }

    /// Pure discovery decision — replicates the old `isUnchanged` + the
    /// discovery loop's dataless/force pre-checks EXACTLY, with NO side effects
    /// (the `last_seen` touch is handled by the caller so it can be batched).
    ///
    /// Ordering is load-bearing:
    ///   1. dataless FIRST (skipped before force, before any compare)
    ///   2. force → hash (ignores stored metadata)
    ///   3. no stored identity → hash
    ///   4. NULL content_hash → hash (iCloud AND local, BEFORE the iCloud trust)
    ///   5. iCloud (isUbiquitous) → trust the stored hash; size/mtime IGNORED
    ///   6. local → require EXACT size AND mtime match, else hash
    static func decideIndexAction(
        isDataless: Bool,
        force: Bool,
        isUbiquitous: Bool,
        stored: StoredIdentity?,
        onDiskSize: Int64?,
        onDiskMtime: Int64?
    ) -> IndexDecision {
        if isDataless { return .skipDataless }
        if force { return .needsHashing }
        guard let stored else { return .needsHashing }
        guard stored.contentHash != nil else { return .needsHashing }
        if isUbiquitous { return .unchanged }
        guard stored.size == onDiskSize, stored.mtime == onDiskMtime else { return .needsHashing }
        return .unchanged
    }

    /// Batched fast-path read: the stored identity of every enumerated path in
    /// ONE chunked `IN (...)` join per ~800 paths, instead of a read transaction
    /// per file. Returns absPath → StoredIdentity for alive paths that have a
    /// file row (the join `ON f.id = p.file_id` excludes null-file_id / missing
    /// rows — the old read's nil guards). Fail-safe: a chunk whose read throws
    /// contributes nothing, so those paths fall through to `.needsHashing`.
    static func loadStoredIdentities(absPaths: [String],
                                     queue: DatabaseQueue) -> [String: StoredIdentity] {
        var map: [String: StoredIdentity] = [:]
        map.reserveCapacity(absPaths.count)
        for start in stride(from: 0, to: absPaths.count, by: 800) {
            let chunk = Array(absPaths[start..<min(start + 800, absPaths.count)])
            let rows = (try? queue.read { db -> [Row] in
                let marks = databaseQuestionMarks(count: chunk.count)
                return try Row.fetchAll(db, sql: """
                    SELECT p.absolute_path AS ap, f.id AS fid, f.content_hash AS ch,
                           f.size_bytes AS sz, f.modified_at AS mt, f.last_seen_at AS ls
                    FROM paths p JOIN files f ON f.id = p.file_id
                    WHERE p.is_alive = 1 AND p.absolute_path IN (\(marks))
                    """, arguments: StatementArguments(chunk))
            }) ?? []
            for r in rows {
                guard let ap: String = r["ap"], let fid: String = r["fid"] else { continue }
                let ls: Int64 = r["ls"]   // files.last_seen_at is INTEGER NOT NULL
                map[ap] = StoredIdentity(fileID: fid, contentHash: r["ch"],
                                         size: r["sz"], mtime: r["mt"], lastSeen: ls)
            }
        }
        return map
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
    /// Delegates the decision to the pure `decideIndexAction` (shared with the
    /// batched discovery in `indexBatch`, so the two can never diverge) and owns
    /// only the DB read + the `last_seen_at` retention touch. Callers reach here
    /// only for non-dataless, non-force files. `internal` (not `private`) so the
    /// DB-backed wrapper tests can exercise it directly.
    static func isUnchanged(absPath: String, sizeBytes: Int64?,
                            modifiedAt: Int64?, isUbiquitous: Bool,
                            now: Int64, queue: DatabaseQueue) -> Bool {
        let stored: StoredIdentity? = (try? queue.read { db -> StoredIdentity? in
            guard let path = try PathRow
                    .filter(PathRow.Columns.absolute_path == absPath)
                    .filter(PathRow.Columns.is_alive == 1)
                    .fetchOne(db),
                  let fid = path.file_id,
                  let file = try FileRow.filter(FileRow.Columns.id == fid).fetchOne(db)
            else { return nil }
            return StoredIdentity(fileID: fid, contentHash: file.content_hash,
                                  size: file.size_bytes, mtime: file.modified_at,
                                  lastSeen: file.last_seen_at)
        }) ?? nil

        let decision = decideIndexAction(
            isDataless: false, force: false, isUbiquitous: isUbiquitous,
            stored: stored, onDiskSize: sizeBytes, onDiskMtime: modifiedAt)
        guard decision == .unchanged else { return false }

        if let stored, now - stored.lastSeen > 86_400 {
            try? queue.write { db in
                try db.execute(sql: "UPDATE files SET last_seen_at = ? WHERE id = ?",
                               arguments: [now, stored.fileID])
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

        // One batched read of the whole folder's stored identities (skipped in
        // force mode, which re-hashes everything regardless of stored metadata).
        let storedByPath: [String: StoredIdentity] = force
            ? [:]
            : Self.loadStoredIdentities(absPaths: urls.map { $0.0.standardizedFileURL.path },
                                        queue: queue)

        var staleFileIDs: [String] = []
        for (url, kind) in urls {
            let dataless = Self.isDataless(url)
            // An iCloud item reports a downloading status; a plain local file
            // reports nil. iCloud size/mtime can't be trusted as a change
            // signal (it oscillates on sync), so decideIndexAction trusts the hash.
            // Skipped in force mode (→ needsHashing regardless), matching the old
            // loop's force short-circuit so the iCloud verify pass does no extra reads.
            let isUbiquitous = force ? false
                : (try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey]))?
                    .ubiquitousItemDownloadingStatus != nil
            let absPath = url.standardizedFileURL.path
            let rv = force ? nil : try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            let sizeBytes = rv?.fileSize.map { Int64($0) }
            let modifiedAt = rv?.contentModificationDate.map { Int64($0.timeIntervalSince1970) }
            let stored = storedByPath[absPath]

            switch Self.decideIndexAction(isDataless: dataless, force: force,
                                          isUbiquitous: isUbiquitous, stored: stored,
                                          onDiskSize: sizeBytes, onDiskMtime: modifiedAt) {
            case .skipDataless:
                continue
            case .needsHashing:
                work.append((url, kind))
            case .unchanged:
                if let stored, now - stored.lastSeen > 86_400 { staleFileIDs.append(stored.fileID) }
                continue
            }
        }

        // One batched last_seen touch for every unchanged-but-stale file.
        if !staleFileIDs.isEmpty {
            try? await queue.write { db in
                for start in stride(from: 0, to: staleFileIDs.count, by: 800) {
                    let chunk = Array(staleFileIDs[start..<min(start + 800, staleFileIDs.count)])
                    let marks = databaseQuestionMarks(count: chunk.count)
                    try db.execute(sql: "UPDATE files SET last_seen_at = ? WHERE id IN (\(marks))",
                                   arguments: StatementArguments([now] + chunk))
                }
            }
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
