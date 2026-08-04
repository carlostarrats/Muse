import XCTest
import GRDB
@testable import Muse

/// Migration v24 — identity becomes the FILE ON DISK, not its bytes.
///
/// The bug this closes, from the owner's library: twelve byte-identical `.ARW`
/// files in one folder shared ONE `files` row (content_hash was UNIQUE), so
/// they shared one edit stack, one tag set, one note and one set of collection
/// memberships. Editing one changed all twelve.
final class PerFileIdentityMigrationTests: XCTestCase {

    /// One `files` row shared by `paths`, migrated only as far as v23 — the
    /// state every existing library is in before this change.
    private func seededQueue(paths: [String],
                             hash: String = "abc123") throws -> DatabaseQueue {
        let queue = try DatabaseQueue()
        try Database.makeMigrator().migrate(queue, upTo: "v23_edit_luts")
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO files (id, content_hash, kind, last_seen_at, analyzed_hash)
                VALUES ('F', ?, 'image', 0, ?)
                """, arguments: [hash, hash])
            for (i, p) in paths.enumerated() {
                try db.execute(sql: """
                    INSERT INTO paths (id, file_id, absolute_path, is_alive)
                    VALUES (?, 'F', ?, 1)
                    """, arguments: ["P\(i)", p])
            }
            try db.execute(sql: """
                INSERT INTO files_fts (file_id, basename, ocr_text, caption)
                VALUES ('F', ?, '', '')
                """, arguments: [(paths[0] as NSString).lastPathComponent])
        }
        return queue
    }

    private func migrate(_ queue: DatabaseQueue) throws {
        try Database.makeMigrator().migrate(queue)
    }

    // MARK: - The reported bug

    /// Twelve copies in ONE folder must end up as twelve independent rows,
    /// each carrying a copy of what they were sharing.
    func testSameFolderCopiesSplitIntoOneRowEach() throws {
        let dir = "/Lib/Raw Files"
        let paths = (0..<12).map { "\(dir)/copy\($0).ARW" }
        let queue = try seededQueue(paths: paths)
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO edits (file_id, parent_dir, stack, stack_hash, process_version, updated_at)
                VALUES ('F', ?, '{"v":1}', 'h1', 1, 99)
                """, arguments: [dir])
            try db.execute(sql: """
                INSERT INTO tags (id, file_id, parent_dir, label, source, confidence, model_version)
                VALUES ('T1', 'F', ?, 'autumn', 'manual', 1.0, 'v1')
                """, arguments: [dir])
            try db.execute(sql: """
                INSERT INTO notes (file_id, parent_dir, body, updated_at)
                VALUES ('F', ?, 'my note', 5)
                """, arguments: [dir])
        }

        try migrate(queue)

        try queue.read { db in
            let fileIDs = try String.fetchAll(db, sql:
                "SELECT DISTINCT file_id FROM paths WHERE is_alive = 1")
            XCTAssertEqual(fileIDs.count, 12, "each file on disk needs its own row")
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM edits"), 12)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM tags"), 12)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM notes"), 12)
            // Every copy findable by its OWN name — eleven of twelve were not.
            for p in paths {
                let base = (p as NSString).lastPathComponent
                let n = try Int.fetchOne(db, sql:
                    "SELECT COUNT(*) FROM files_fts WHERE basename = ?", arguments: [base])
                XCTAssertEqual(n, 1, "\(base) not searchable")
            }
        }
    }

    /// The structural invariant that REPLACES `content_hash UNIQUE`. SQLite
    /// cannot enforce it, so this test is the enforcement.
    func testNoFileRowKeepsTwoAlivePaths() throws {
        let queue = try seededQueue(paths: ["/A/x.jpg", "/A/y.jpg", "/B/x.jpg"])
        try migrate(queue)
        try queue.read { db in
            let worst = try Int.fetchOne(db, sql: """
                SELECT COALESCE(MAX(n), 0) FROM
                  (SELECT COUNT(*) AS n FROM paths WHERE is_alive = 1 GROUP BY file_id)
                """)
            XCTAssertEqual(worst, 1)
        }
    }

    /// Per-FOLDER user data must land on the row for its own folder.
    func testCrossFolderDataLandsOnItsOwnFolderRow() throws {
        let queue = try seededQueue(paths: ["/A/x.jpg", "/B/x.jpg"])
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO notes (file_id, parent_dir, body, updated_at)
                VALUES ('F', '/A', 'note A', 1), ('F', '/B', 'note B', 2)
                """)
        }
        try migrate(queue)
        try queue.read { db in
            func noteFor(_ path: String) throws -> String? {
                try String.fetchOne(db, sql: """
                    SELECT n.body FROM notes n
                    JOIN paths p ON p.file_id = n.file_id AND p.is_alive = 1
                    WHERE p.absolute_path = ?
                    """, arguments: [path])
            }
            XCTAssertEqual(try noteFor("/A/x.jpg"), "note A")
            XCTAssertEqual(try noteFor("/B/x.jpg"), "note B")
        }
    }

    // MARK: - Derived analysis is copied, never recomputed

    /// No copy may come out of the migration looking unanalyzed — that would
    /// queue a redundant Vision pass per duplicate.
    func testDerivedAnalysisIsCopiedToEveryRow() throws {
        let queue = try seededQueue(paths: ["/A/x.jpg", "/A/y.jpg"])
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO photo_meta (file_id, capture_date, camera_make)
                VALUES ('F', 1700000000, 'Sony')
                """)
            try db.execute(sql: """
                INSERT INTO embeddings (file_id, vector, model_version, updated_at)
                VALUES ('F', x'00', 'm1', 1)
                """)
        }
        try migrate(queue)
        try queue.read { db in
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM photo_meta"), 2)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM embeddings"), 2)
            let unanalyzed = try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM files
                WHERE analyzed_hash IS NULL OR analyzed_hash <> content_hash
                """)
            XCTAssertEqual(unanalyzed, 0)
        }
    }

    /// Every copy is a collection member today; keep it that way.
    func testCollectionMembershipCopiedToEveryRow() throws {
        let queue = try seededQueue(paths: ["/A/x.jpg", "/A/y.jpg"])
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO collections (id, name, is_hidden, model_version,
                                         created_at, updated_at, sort_order)
                VALUES ('C', 'Faves', 0, 'v1', 0, 0, 0)
                """)
            try db.execute(sql: """
                INSERT INTO collection_members (collection_id, file_id, added_by)
                VALUES ('C', 'F', 'manual')
                """)
        }
        try migrate(queue)
        try queue.read { db in
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM collection_members"), 2)
        }
    }

    // MARK: - Things that must NOT change

    /// Dead paths are how a re-appearing file is revived; they stay on the
    /// surviving original row.
    func testDeadPathsStayOnTheKeptRow() throws {
        let queue = try seededQueue(paths: ["/A/x.jpg", "/A/y.jpg"])
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO paths (id, file_id, absolute_path, is_alive)
                VALUES ('PD', 'F', '/A/gone.jpg', 0)
                """)
        }
        try migrate(queue)
        try queue.read { db in
            let owner = try String.fetchOne(db, sql: "SELECT file_id FROM paths WHERE id = 'PD'")
            XCTAssertEqual(owner, "F")
        }
    }

    /// The overwhelmingly common case: one file, one path, nothing to do.
    func testSolePathFileIsUntouched() throws {
        let queue = try seededQueue(paths: ["/A/only.jpg"])
        try migrate(queue)
        try queue.read { db in
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM files"), 1)
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT id FROM files"), "F")
        }
    }

    /// The rebuild of `files` must preserve every column, including the ones
    /// added by later ALTER TABLE migrations.
    func testFileRowColumnsSurviveTheRebuild() throws {
        let queue = try seededQueue(paths: ["/A/x.jpg", "/A/y.jpg"])
        try queue.write { db in
            try db.execute(sql: """
                UPDATE files SET width = 4000, height = 3000, caption = 'a caption',
                    palette = '#ff0000', intent = 'screenshot', lat = 37.7, lon = -122.4,
                    coords_scanned_hash = 'abc123', last_viewed_at = 42,
                    dominant_color = '#00ff00', intent_model_version = 'iv1',
                    size_bytes = 123, duration_seconds = NULL, created_at = 7,
                    modified_at = 8, feature_print = x'0102'
                WHERE id = 'F'
                """)
        }
        try migrate(queue)
        let rows = try queue.read { db in try FileRow.fetchAll(db) }
        XCTAssertEqual(rows.count, 2)
        for row in rows {
            XCTAssertEqual(row.width, 4000)
            XCTAssertEqual(row.height, 3000)
            XCTAssertEqual(row.caption, "a caption")
            XCTAssertEqual(row.palette, "#ff0000")
            XCTAssertEqual(row.intent, "screenshot")
            XCTAssertEqual(row.intent_model_version, "iv1")
            XCTAssertEqual(row.lat, 37.7)
            XCTAssertEqual(row.lon, -122.4)
            XCTAssertEqual(row.coords_scanned_hash, "abc123")
            XCTAssertEqual(row.last_viewed_at, 42)
            XCTAssertEqual(row.dominant_color, "#00ff00")
            XCTAssertEqual(row.size_bytes, 123)
            XCTAssertEqual(row.created_at, 7)
            XCTAssertEqual(row.modified_at, 8)
            XCTAssertEqual(row.feature_print, Data([0x01, 0x02]))
        }
    }

    /// A cross-folder split leaves the ORIGINAL row holding rows for a folder
    /// it no longer occupies. Unreachable today, but the moment `parent_dir` is
    /// dropped two such rows collapse onto one primary key — so they are swept.
    func testStrandedCrossFolderRowsAreSwept() throws {
        let queue = try seededQueue(paths: ["/A/x.jpg", "/B/x.jpg"])
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO notes (file_id, parent_dir, body, updated_at)
                VALUES ('F', '/A', 'note A', 1), ('F', '/B', 'note B', 2)
                """)
            try db.execute(sql: """
                INSERT INTO tags (id, file_id, parent_dir, label, source)
                VALUES ('tA', 'F', '/A', 'a', 'manual'), ('tB', 'F', '/B', 'b', 'manual')
                """)
        }
        try migrate(queue)
        try queue.read { db in
            // Exactly one note and one tag per file, each in its own folder.
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM notes"), 2)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM tags"), 2)
            // Every surviving row sits in ITS OWN file's folder. Checked in
            // Swift rather than SQL: the first draft of this assertion did the
            // dirname in SQLite and then excluded '/A' and '/B', which is every
            // folder in the fixture — so it counted zero by construction and
            // could not have failed.
            let rows = try Row.fetchAll(db, sql: """
                SELECT n.parent_dir AS dir, p.absolute_path AS path FROM notes n
                JOIN paths p ON p.file_id = n.file_id AND p.is_alive = 1
                """)
            XCTAssertEqual(rows.count, 2)
            for row in rows {
                let dir: String = row["dir"]
                let path: String = row["path"]
                XCTAssertEqual(dir, (path as NSString).deletingLastPathComponent)
            }
            // Each file's note matches its own folder.
            for (path, body) in [("/A/x.jpg", "note A"), ("/B/x.jpg", "note B")] {
                XCTAssertEqual(try String.fetchOne(db, sql: """
                    SELECT n.body FROM notes n
                    JOIN paths p ON p.file_id = n.file_id AND p.is_alive = 1
                    WHERE p.absolute_path = ?
                    """, arguments: [path]), body)
            }
        }
    }

    /// The v13 partial coordinate index must survive the rebuild of `files` —
    /// DROP TABLE takes every index with it, including ones added by LATER
    /// migrations, and losing this one turns every geo query into a full scan
    /// with nothing failing loudly.
    func testIndexesOnFilesSurviveTheRebuild() throws {
        let queue = try seededQueue(paths: ["/A/x.jpg"])
        try migrate(queue)
        try queue.read { db in
            let names = try db.indexes(on: "files").map(\.name)
            XCTAssertTrue(names.contains("files_coords_idx"), "geo index lost: \(names)")
            XCTAssertTrue(names.contains("files_content_hash_idx"), "hash index lost: \(names)")
        }
    }

    // MARK: - v25 repairs

    /// The KEPT row must end up searchable by its OWN name.
    ///
    /// v24 wrote correct basenames for the new rows but left the kept row
    /// carrying whatever name the shared row had been analyzed under. In the
    /// owner's library `RAW_SONY_ILCA-77M2 copy 2 2 2.ARW` — which sorts first,
    /// so it kept the row — was searchable only as `RAW_SONY_ILCA-77M2.ARW`.
    func testKeptRowIsSearchableByItsOwnName() throws {
        let queue = try DatabaseQueue()
        try Database.makeMigrator().migrate(queue, upTo: "v23_edit_luts")
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO files (id, content_hash, kind, last_seen_at, analyzed_hash)
                VALUES ('F', 'h', 'image', 0, 'h')
                """)
            try db.execute(sql: """
                INSERT INTO paths (id, file_id, absolute_path, is_alive)
                VALUES ('p1', 'F', '/A/a.jpg', 1), ('p2', 'F', '/A/z.jpg', 1)
                """)
            // The shared row was analyzed under the OTHER copy's name.
            try db.execute(sql: """
                INSERT INTO files_fts (file_id, basename, ocr_text, caption)
                VALUES ('F', 'z.jpg', '', '')
                """)
        }
        try migrate(queue)
        try queue.read { db in
            for (path, name) in [("/A/a.jpg", "a.jpg"), ("/A/z.jpg", "z.jpg")] {
                let fid = try String.fetchOne(db, sql:
                    "SELECT file_id FROM paths WHERE absolute_path = ?", arguments: [path])!
                XCTAssertEqual(try String.fetchOne(db, sql:
                    "SELECT basename FROM files_fts WHERE file_id = ?", arguments: [fid]),
                    name, "\(path) must be searchable by its own name")
            }
        }
    }

    /// v24's table rebuild dropped v13's partial coordinate index. v25 restores
    /// it for databases that already ran the intermediate migration.
    func testCoordinateIndexIsRestoredWhenMissing() throws {
        // Stop at v24 and drop the index — exactly the state a database
        // migrated by the intermediate build is in. Then let v25 run.
        //
        // The first draft of this test dropped the index and ran the CREATE
        // statement by hand, which asserted that SQLite works, not that the
        // MIGRATION repairs anything. Stopping at v24 is what makes it able
        // to fail.
        let queue = try DatabaseQueue()
        try Database.makeMigrator().migrate(queue, upTo: "v24_per_file_identity")
        try queue.write { db in
            try db.execute(sql: "DROP INDEX IF EXISTS files_coords_idx")
        }
        try queue.read { db in
            XCTAssertFalse(try db.indexes(on: "files").contains { $0.name == "files_coords_idx" },
                           "precondition: the index really is gone before v25 runs")
        }

        try migrate(queue)

        try queue.read { db in
            XCTAssertTrue(try db.indexes(on: "files").contains { $0.name == "files_coords_idx" },
                          "v25 must restore the index v24's table rebuild destroyed")
        }
    }

    /// A split whose ORIGINAL had no FTS row must still end up searchable.
    ///
    /// v24 copies the FTS entry with INSERT…SELECT, which yields nothing when
    /// there is nothing to select — and `backfillBasenameFTS` runs only inside
    /// v9, so nothing would ever heal it. Every copy would be unfindable by
    /// name, permanently and silently.
    func testSplitOfAnFTSlessRowStillGetsSearchableNames() throws {
        let queue = try DatabaseQueue()
        try Database.makeMigrator().migrate(queue, upTo: "v23_edit_luts")
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO files (id, content_hash, kind, last_seen_at, analyzed_hash)
                VALUES ('F', 'h', 'image', 0, 'h')
                """)
            try db.execute(sql: """
                INSERT INTO paths (id, file_id, absolute_path, is_alive)
                VALUES ('p1', 'F', '/A/a.jpg', 1), ('p2', 'F', '/A/b.jpg', 1)
                """)
            // Deliberately NO files_fts row — the v9-era gap.
        }
        try migrate(queue)
        try queue.read { db in
            for (path, name) in [("/A/a.jpg", "a.jpg"), ("/A/b.jpg", "b.jpg")] {
                let fid = try String.fetchOne(db, sql:
                    "SELECT file_id FROM paths WHERE absolute_path = ?", arguments: [path])!
                XCTAssertEqual(try String.fetchOne(db, sql:
                    "SELECT basename FROM files_fts WHERE file_id = ?", arguments: [fid]),
                    name, "\(path) has no searchable name")
            }
        }
    }

    // MARK: - What the stranded-row sweep must NOT delete

    /// v24 ends by DELETEing per-location rows whose `parent_dir` is not the
    /// folder their file occupies. Its safety rested on two claims made only in
    /// a comment, and a DELETE is the worst place to leave a claim untested.
    ///
    /// Claim 1: a file with NO alive path is skipped entirely — that is v7's
    /// deliberate NULL-scope orphan, whose lifecycle belongs to housekeeping.
    func testSweepLeavesRowsOnAFileWithNoAlivePath() throws {
        let queue = try DatabaseQueue()
        try Database.makeMigrator().migrate(queue, upTo: "v23_edit_luts")
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO files (id, content_hash, kind, last_seen_at)
                VALUES ('ghost', 'gh', 'image', 0)
                """)
            try db.execute(sql: """
                INSERT INTO tags (id, file_id, parent_dir, label, source)
                VALUES ('t1', 'ghost', '/somewhere', 'precious', 'manual')
                """)
        }
        try migrate(queue)
        try queue.read { db in
            XCTAssertEqual(try Int.fetchOne(db, sql:
                "SELECT COUNT(*) FROM tags WHERE file_id = 'ghost'"), 1,
                "a file with no alive path must keep its rows")
        }
    }

    /// Claim 2: a NULL `parent_dir` row survives even on a file that IS alive.
    /// v7 stores orphaned tags with a NULL scope on purpose.
    ///
    /// This pins the BEHAVIOUR, not the mechanism — and the distinction was
    /// found by running the negative. Deleting the sweep's `parent_dir IS NOT
    /// NULL` clause leaves this test passing, because SQL's three-valued logic
    /// already spares the row: `NULL <> '/A'` is NULL, not true, so the DELETE
    /// never matches it. The clause is deliberate belt-and-braces. What this
    /// test would actually catch is a rewrite that reaches for `IS NOT` or
    /// `COALESCE` and starts matching NULLs — which is the failure worth
    /// guarding, since it silently destroys user tags.
    func testSweepLeavesNullScopedRowsAlone() throws {
        let queue = try DatabaseQueue()
        try Database.makeMigrator().migrate(queue, upTo: "v23_edit_luts")
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO files (id, content_hash, kind, last_seen_at, analyzed_hash)
                VALUES ('F', 'h', 'image', 0, 'h')
                """)
            try db.execute(sql: """
                INSERT INTO paths (id, file_id, absolute_path, is_alive)
                VALUES ('p1', 'F', '/A/x.jpg', 1)
                """)
            try db.execute(sql: """
                INSERT INTO tags (id, file_id, parent_dir, label, source)
                VALUES ('own', 'F', '/A', 'kept', 'manual'),
                       ('nul', 'F', NULL, 'unscoped', 'manual')
                """)
        }
        try migrate(queue)
        try queue.read { db in
            let labels = try String.fetchAll(db, sql:
                "SELECT label FROM tags WHERE file_id = 'F' ORDER BY label")
            XCTAssertEqual(labels, ["kept", "unscoped"],
                           "the NULL-scoped tag must survive the sweep")
        }
    }

    /// And the sweep must still do its job: a row for a folder the file does
    /// not occupy is removed, so `parent_dir` can be dropped later without two
    /// rows collapsing onto one primary key.
    func testSweepDoesRemoveARowForAFolderTheFileDoesNotOccupy() throws {
        let queue = try DatabaseQueue()
        try Database.makeMigrator().migrate(queue, upTo: "v23_edit_luts")
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO files (id, content_hash, kind, last_seen_at, analyzed_hash)
                VALUES ('F', 'h', 'image', 0, 'h')
                """)
            try db.execute(sql: """
                INSERT INTO paths (id, file_id, absolute_path, is_alive)
                VALUES ('p1', 'F', '/A/x.jpg', 1)
                """)
            try db.execute(sql: """
                INSERT INTO notes (file_id, parent_dir, body, updated_at)
                VALUES ('F', '/A', 'mine', 1), ('F', '/GONE', 'stale', 1)
                """)
        }
        try migrate(queue)
        try queue.read { db in
            let dirs = try String.fetchAll(db, sql:
                "SELECT parent_dir FROM notes WHERE file_id = 'F'")
            XCTAssertEqual(dirs, ["/A"])
        }
    }

    /// The repair must not disturb a name that is already correct.
    func testRepairLeavesCorrectBasenamesAlone() throws {
        let queue = try seededQueue(paths: ["/A/only.jpg"])
        try migrate(queue)
        try queue.read { db in
            XCTAssertEqual(try String.fetchOne(db, sql:
                "SELECT basename FROM files_fts WHERE file_id = 'F'"), "only.jpg")
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM files_fts"), 1)
        }
    }

    /// Two rows sharing a content_hash must now be LEGAL — that is the whole
    /// change. A surviving UNIQUE would make the split fail at insert.
    func testContentHashIsNoLongerUnique() throws {
        let queue = try seededQueue(paths: ["/A/x.jpg", "/A/y.jpg"])
        try migrate(queue)
        try queue.read { db in
            let n = try Int.fetchOne(db, sql:
                "SELECT COUNT(*) FROM files WHERE content_hash = 'abc123'")
            XCTAssertEqual(n, 2)
        }
    }
}
