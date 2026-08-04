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

    /// Claim a path for hashing. Actor-isolated so the check and the insert are
    /// one indivisible step; returns false when another in-flight task already
    /// holds it (the same file arriving from both the folder pass and an
    /// FSEvents re-verify).
    private func claim(_ absPath: String) -> Bool {
        inFlightHashes.insert(absPath).inserted
    }

    private func release(_ absPath: String) {
        inFlightHashes.remove(absPath)
    }

    /// Index a single file: hashing + identity reconciliation per the matrix.
    ///
    /// Returns `true` when the file's CONTENT changed in place (the path was
    /// already known but now hashes differently) — the signal AppState uses to
    /// drop stale thumbnails and re-run analysis. A brand-new file or a fresh
    /// path returns `false` (nothing cached to invalidate).
    ///
    /// **The body is deliberately `nonisolated`.** It used to be an isolated
    /// synchronous method, which meant it never suspended and so ran to
    /// completion under the actor's lock: `hashConcurrency` bought nothing and
    /// every file's SHA-256 was serialized behind the previous one (measured
    /// peak concurrency: 1, against the 4 the window advertises). It also made
    /// `inFlightHashes` unreachable — set and cleared with no suspension point
    /// between, so it could never observe a duplicate. Only the claim/release
    /// bookkeeping needs isolation; the hash is pure I/O over one file, and the
    /// reconcile's atomicity comes from GRDB's serialized `queue.write`
    /// transaction, not from the actor.
    @discardableResult
    nonisolated func indexFile(at url: URL, kind: AssetKind) async -> Bool {
        let absPath = url.standardizedFileURL.path
        guard await claim(absPath) else { return false }
        // Released inline, not via `defer` + an unstructured Task: the claim
        // must be gone before this call returns, or the next pass over the same
        // file races the release and is skipped for no reason. Nothing between
        // here and the release throws or suspends, so the claim can't leak.
        let didChange = Self.indexFileBody(url: url, absPath: absPath, kind: kind)
        await release(absPath)
        return didChange
    }

    private nonisolated static func indexFileBody(url: URL, absPath: String,
                                                  kind: AssetKind) -> Bool {
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

            // Hash changed — edit in place. That is the ONLY thing that can
            // happen here now.
            //
            // This used to be two more branches, both of which existed purely
            // because a `files` row could be SHARED by several byte-identical
            // paths:
            //
            //   * a hash-COLLISION branch, when the new bytes matched a
            //     different existing row, which re-linked the path and carried
            //     tags/notes/edits/memberships across — with a same-folder
            //     sibling rule deciding copy-vs-move;
            //   * a SPLIT branch, when the row had other alive paths, which
            //     forked a fresh row so editing one copy did not corrupt its
            //     untouched twin.
            //
            // Under per-file identity a row has at most one alive path, so
            // there is nothing to split, and two rows may legally share a
            // content_hash, so a collision is not a conflict. Both branches are
            // deleted; this is what is left.
            //
            // analyzed_hash is reset because a crop or an edit changes colours,
            // dimensions and OCR'd text — the old tags and palette must not
            // stick. Clearing it is also what makes `analyzePending` pick the
            // file up.
            file.content_hash = hash
            file.size_bytes = sizeBytes
            file.modified_at = modifiedAt
            file.last_seen_at = now
            file.analyzed_hash = nil
            try file.update(db)
            return true
        }

        // No alive path. Check for a dead path with the same absolute_path.
        let deadPaths = try PathRow
            .filter(PathRow.Columns.absolute_path == absPath)
            .filter(PathRow.Columns.is_alive == 0)
            .fetchAll(db)

        // Path-resurrection: THIS exact path is back with the same bytes, so
        // its own row is still sitting there. Revive it; nothing is inherited
        // because nothing was ever lost.
        if let target = existingFileByHash,
           var deadPath = deadPaths.first(where: { $0.file_id == target.id }) {
            deadPath.is_alive = 1
            try deadPath.update(db)
            var refreshed = target
            refreshed.last_seen_at = now
            try refreshed.update(db)
            // A file that was dead at v9-backfill time has no FTS row —
            // seed the basename one now so it's name-searchable again.
            try ensureBasenameFTS(db: db, fileID: target.id, absPath: absPath)
            return false
        }

        // RENAME or MOVE: some row already holds these bytes and has NO alive
        // path — its file left the name it used to have. Adopt that row rather
        // than minting a new one, so the edit stack, tags, note and collection
        // memberships follow the file to its new name. This is the distinction
        // that makes renaming safe under per-file identity: an orphaned
        // identity is the SAME file, an identity that is still alive elsewhere
        // is a COPY.
        if let orphanID = try orphanedFileID(db: db, hash: hash) {
            var newPath = PathRow(id: UUID().uuidString, file_id: orphanID,
                                  absolute_path: absPath, bookmark_data: nil, is_alive: 1)
            try newPath.insert(db)
            if var orphan = try FileRow.filter(FileRow.Columns.id == orphanID).fetchOne(db) {
                orphan.last_seen_at = now
                try orphan.update(db)
            }
            // The FTS basename was written under the OLD name; refresh it or
            // "everywhere" search misses the file by the name it now has.
            try db.execute(sql: "UPDATE files_fts SET basename = ? WHERE file_id = ?",
                           arguments: [(absPath as NSString).lastPathComponent, orphanID])
            try ensureBasenameFTS(db: db, fileID: orphanID, absPath: absPath)
            return false
        }

        // A genuine COPY: these bytes are already alive somewhere else. It gets
        // its OWN row — that is the whole point of per-file identity — and
        // inherits the donor's edits, tags, note and memberships, then
        // diverges. Before this change the path was simply attached to the
        // existing row, which is what made twelve copies share one edit stack.
        if existingFileByHash != nil {
            var newFile = makeFile(hash: hash, kind: kind, size: sizeBytes,
                                   created: createdAt, modified: modifiedAt, now: now)
            try newFile.insert(db)
            var newPath = PathRow(id: UUID().uuidString, file_id: newFile.id,
                                  absolute_path: absPath, bookmark_data: nil, is_alive: 1)
            try newPath.insert(db)
            try insertBasenameFTS(db: db, fileID: newFile.id, absPath: absPath)
            let dir = TagScope.parentDir(ofPath: absPath)
            if let donorID = try pickDonor(db: db, hash: hash,
                                           excluding: newFile.id, targetDir: dir) {
                try inherit(db: db, from: donorID, to: newFile.id, targetDir: dir)
            }
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

    // MARK: - Per-file identity

    /// A row holding these bytes that has NO alive path — an identity whose
    /// file left the name it used to have. Adopting it is what makes a rename
    /// or a move carry its edits along instead of forking a blank copy.
    ///
    /// Deterministic (`ORDER BY id`) so two orphans of the same content can't
    /// be adopted in a different order on a different run.
    static func orphanedFileID(db: GRDB.Database, hash: String) throws -> String? {
        try String.fetchOne(db, sql: """
            SELECT f.id FROM files f
            WHERE f.content_hash = ?
              AND NOT EXISTS (SELECT 1 FROM paths p
                              WHERE p.file_id = f.id AND p.is_alive = 1)
            ORDER BY f.id LIMIT 1
            """, arguments: [hash])
    }

    /// The already-alive copy a NEW copy should inherit from. See
    /// `InheritDonor` for the ordering and why it has to be total.
    static func pickDonor(db: GRDB.Database, hash: String,
                          excluding newID: String, targetDir: String) throws -> String? {
        let rows = try Row.fetchAll(db, sql: """
            SELECT f.id AS fid, p.absolute_path AS path, e.updated_at AS edited
            FROM files f
            JOIN paths p ON p.file_id = f.id AND p.is_alive = 1
            LEFT JOIN edits e ON e.file_id = f.id
            WHERE f.content_hash = ? AND f.id <> ?
            """, arguments: [hash, newID])
        let candidates = rows.compactMap { row -> InheritDonor.Candidate? in
            guard let fid: String = row["fid"], let path: String = row["path"] else { return nil }
            return InheritDonor.Candidate(fileID: fid,
                                          parentDir: TagScope.parentDir(ofPath: path),
                                          absolutePath: path,
                                          editUpdatedAt: row["edited"])
        }
        return InheritDonor.pick(candidates: candidates, targetDir: targetDir)
    }

    /// Give a brand-new row the donor's analysis AND user data.
    ///
    /// The derived half is copied rather than recomputed because identical
    /// bytes give identical answers — re-running Vision per duplicate would
    /// cost N passes over the same pixels, and leaving it out would make every
    /// copy look unanalyzed and queue exactly that work.
    ///
    /// The user half is copied because the owner's rule is that a copy
    /// INHERITS: duplicating a photo that already carries edits starts from
    /// those edits and diverges.
    ///
    /// **Keep in sync with migration `v24_per_file_identity`**, which does the
    /// same copying for rows that already existed. A migration is frozen at its
    /// historical shape so the two cannot share code; each is covered by its
    /// own test (`testDerivedAnalysisIsCopiedToEveryRow` there,
    /// `testNewCopyIsNotMarkedUnanalyzed` here).
    static func inherit(db: GRDB.Database, from donorID: String,
                        to newID: String, targetDir: String) throws {
        // Analysis columns on the row itself — including analyzed_hash, which
        // is what stops the copy being queued for a redundant Vision pass.
        try db.execute(sql: """
            UPDATE files SET
                width = d.width, height = d.height, caption = d.caption,
                dominant_color = d.dominant_color, feature_print = d.feature_print,
                palette = d.palette, analyzed_hash = d.analyzed_hash,
                intent = d.intent, intent_model_version = d.intent_model_version,
                lat = d.lat, lon = d.lon, coords_scanned_hash = d.coords_scanned_hash
            FROM (SELECT * FROM files WHERE id = ?) AS d
            WHERE files.id = ?
            """, arguments: [donorID, newID])

        try db.execute(sql: """
            INSERT OR IGNORE INTO photo_meta SELECT ?, exif_scanned_hash, capture_date,
                capture_md, camera_make, camera_model, lens, iso, f_number,
                exposure_seconds, focal_length, focal_length_35mm, flash_fired
            FROM photo_meta WHERE file_id = ?
            """, arguments: [newID, donorID])
        try db.execute(sql: """
            INSERT OR IGNORE INTO photo_traits SELECT ?, traits_scanned_hash, traits_version,
                face_count, largest_face_frac, face_quality, pet_count, sharpness,
                clip_high_r, clip_high_g, clip_high_b, clip_low, noise_sigma
            FROM photo_traits WHERE file_id = ?
            """, arguments: [newID, donorID])
        try db.execute(sql: """
            INSERT OR IGNORE INTO places SELECT ?, geocoded_hash, dataset_version,
                city, admin, country, place_key
            FROM places WHERE file_id = ?
            """, arguments: [newID, donorID])
        try db.execute(sql: """
            INSERT OR IGNORE INTO embeddings SELECT ?, vector, model_version, updated_at
            FROM embeddings WHERE file_id = ?
            """, arguments: [newID, donorID])
        try db.execute(sql: """
            INSERT OR IGNORE INTO clip_embeddings SELECT ?, embedded_hash, model_generation, vector
            FROM clip_embeddings WHERE file_id = ?
            """, arguments: [newID, donorID])

        // The OCR text and caption the donor's analysis produced. The basename
        // row was already seeded from THIS path, so keep that name and only
        // fill in the content-derived columns.
        try db.execute(sql: """
            UPDATE files_fts SET
                ocr_text = (SELECT ocr_text FROM files_fts WHERE file_id = ?),
                caption = (SELECT caption FROM files_fts WHERE file_id = ?)
            WHERE file_id = ?
            """, arguments: [donorID, donorID, newID])

        // User-authored data. Tags and the note and the edit stack are stored
        // per (file_id, parent_dir); the new row's folder is the target dir, so
        // take the donor's rows for ITS folder and re-key them to this one.
        try db.execute(sql: """
            INSERT OR IGNORE INTO tags (id, file_id, parent_dir, label, source, confidence, model_version)
            SELECT lower(hex(randomblob(16))), ?, ?, label, source, confidence, model_version
            FROM tags WHERE file_id = ?
            """, arguments: [newID, targetDir, donorID])
        try db.execute(sql: """
            INSERT OR IGNORE INTO notes (file_id, parent_dir, body, updated_at)
            SELECT ?, ?, body, updated_at FROM notes WHERE file_id = ?
            """, arguments: [newID, targetDir, donorID])
        try db.execute(sql: """
            INSERT OR IGNORE INTO edits (file_id, parent_dir, stack, stack_hash,
                                         process_version, updated_at)
            SELECT ?, ?, stack, stack_hash, process_version, updated_at
            FROM edits WHERE file_id = ?
            """, arguments: [newID, targetDir, donorID])
        try db.execute(sql: """
            INSERT OR IGNORE INTO edit_versions (id, file_id, parent_dir, kind, name, stack, created_at)
            SELECT lower(hex(randomblob(16))), ?, ?, kind, name, stack, created_at
            FROM edit_versions WHERE file_id = ?
            """, arguments: [newID, targetDir, donorID])

        // Manual membership only — auto membership is regenerated by the
        // recluster, and copying it would fight the engine.
        try db.execute(sql: """
            INSERT OR IGNORE INTO collection_members (collection_id, file_id, added_by)
            SELECT collection_id, ?, added_by FROM collection_members
            WHERE file_id = ? AND added_by = 'manual'
            """, arguments: [newID, donorID])
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


    /// Enforce one-rating-per-(file_id, parent_dir) after rows from two scopes
    /// land on one. Ratings are manual tags with distinct labels ("★★" vs
    /// "★★★★"), so a merge that keys conflicts on the exact label leaves two of
    /// them. TagRow carries no timestamp, so the tiebreak is the same
    /// deterministic one the sidecar seam uses (Sidecar.collapsingRatings): the
    /// highest run wins. `parentDir` nil scopes across every folder the
    /// identity touches, so the collapse groups by parent_dir internally.
    ///
    /// Its other caller, `Indexer.unionTags`, went with the hash-collision
    /// branch under per-file identity (2026-08-03); `FileMoveMigration` — an
    /// in-app move, where one file's rows genuinely change folder — is what
    /// still needs it.
    static func collapseRatings(db: GRDB.Database, fileID: String, parentDir: String?) throws {
        var query = TagRow.filter(TagRow.Columns.file_id == fileID)
        if let parentDir { query = query.filter(TagRow.Columns.parent_dir == parentDir) }
        let ratingRows = try query.fetchAll(db).filter { StarRating.isRating($0.label) }
        for (_, rows) in Dictionary(grouping: ratingRows, by: { $0.parent_dir }) where rows.count > 1 {
            guard let keep = rows.max(by: { $0.label.count < $1.label.count }) else { continue }
            for row in rows where row.id != keep.id { try row.delete(db) }
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
            // Frozen before the @Sendable write closure captures it.
            let stale = staleFileIDs
            try? await queue.write { db in
                for start in stride(from: 0, to: stale.count, by: 800) {
                    let chunk = Array(stale[start..<min(start + 800, stale.count)])
                    let marks = databaseQuestionMarks(count: chunk.count)
                    try db.execute(sql: "UPDATE files SET last_seen_at = ? WHERE id IN (\(marks))",
                                   arguments: StatementArguments([now] + chunk))
                }
            }
        }
        guard !work.isEmpty else { return [] }

        PhaseTrace.mark("index.begin", "n=\(work.count) force=\(force) silent=\(silent)")
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
            // `inFlight` only primes the initial window; the drain loop below
            // maintains it by enqueueing one replacement per completion.
            while inFlight < Self.hashConcurrency, enqueueNext() { inFlight += 1 }
            while let result = await group.next() {
                if let u = result { changed.append(u) }
                _ = enqueueNext()
            }
        }
        PhaseTrace.mark("index.end", "changed=\(changed.count)")
        return changed
    }

    enum Priority { case high, background }

    /// Files hashed at once. SHA-256 here is I/O bound, so a slightly wider
    /// window helps import throughput for large files on an SSD. Deliberately
    /// still small: an unbounded fan-out of userInitiated hashing tasks was the
    /// original large-library UI-stutter bug.
    static let hashConcurrency = 4
}
