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
            let stranded = try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM notes n
                JOIN paths p ON p.file_id = n.file_id AND p.is_alive = 1
                WHERE n.parent_dir <> rtrim(p.absolute_path, replace(p.absolute_path, '/', ''))
                       || ''
                  AND n.parent_dir NOT IN ('/A', '/B')
                """)
            XCTAssertEqual(stranded, 0)
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
