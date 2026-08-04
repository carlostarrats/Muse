import XCTest
import GRDB
@testable import Muse

/// Identical bytes give identical answers, so Vision must run ONCE per distinct
/// content no matter how many copies of it exist.
///
/// The indexer's `inherit` covers a copy discovered while an original is
/// already analyzed. This covers the other door: a file that was indexed while
/// its twin was still unanalyzed, and is now sitting in the analyze queue
/// behind it.
final class AnalysisReuseTests: XCTestCase {

    private func migrated() throws -> DatabaseQueue {
        let q = try DatabaseQueue()
        try Database.makeMigrator().migrate(q)
        return q
    }

    /// Seeds an analyzed donor and an unanalyzed twin sharing `hash`.
    private func seedPair(_ q: DatabaseQueue, hash: String = "h1",
                          donorAnalyzed: Bool = true) throws {
        try q.write { db in
            try db.execute(sql: """
                INSERT INTO files (id, content_hash, kind, last_seen_at, analyzed_hash,
                                   caption, palette, width, height)
                VALUES ('donor', ?, 'image', 0, ?, 'a caption', '#ff0000', 800, 600)
                """, arguments: [hash, donorAnalyzed ? hash : nil])
            try db.execute(sql: """
                INSERT INTO files (id, content_hash, kind, last_seen_at)
                VALUES ('twin', ?, 'image', 0)
                """, arguments: [hash])
            try db.execute(sql: """
                INSERT INTO paths (id, file_id, absolute_path, is_alive)
                VALUES ('pd', 'donor', '/a/one.jpg', 1), ('pt', 'twin', '/a/two.jpg', 1)
                """)
            try db.execute(sql: """
                INSERT INTO files_fts (file_id, basename, ocr_text, caption)
                VALUES ('donor', 'one.jpg', 'scanned words', 'a caption'),
                       ('twin', 'two.jpg', '', '')
                """)
            if donorAnalyzed {
                try db.execute(sql: """
                    INSERT INTO photo_traits (file_id, traits_scanned_hash, traits_version,
                                              face_count, sharpness)
                    VALUES ('donor', ?, 1, 2, 0.9)
                    """, arguments: [hash])
                try db.execute(sql: """
                    INSERT INTO clip_embeddings (file_id, embedded_hash, model_generation, vector)
                    VALUES ('donor', ?, 1, x'0102')
                    """, arguments: [hash])
                try db.execute(sql: """
                    INSERT INTO tags (id, file_id, parent_dir, label, source, confidence)
                    VALUES ('t1', 'donor', '/a', 'autumn', 'vision', 0.8)
                    """)
            }
        }
    }

    func testAdoptsAnAlreadyAnalyzedTwinsResults() throws {
        let q = try migrated()
        try seedPair(q)
        let adopted = try q.write { db in
            try AnalysisReuse.adopt(db: db, fileID: "twin", hash: "h1")
        }
        XCTAssertTrue(adopted)
        try q.read { db in
            XCTAssertEqual(try String.fetchOne(db, sql:
                "SELECT analyzed_hash FROM files WHERE id = 'twin'"), "h1")
            XCTAssertEqual(try String.fetchOne(db, sql:
                "SELECT caption FROM files WHERE id = 'twin'"), "a caption")
            XCTAssertEqual(try String.fetchOne(db, sql:
                "SELECT palette FROM files WHERE id = 'twin'"), "#ff0000")
            XCTAssertEqual(try Int.fetchOne(db, sql:
                "SELECT width FROM files WHERE id = 'twin'"), 800)
            XCTAssertEqual(try Int.fetchOne(db, sql:
                "SELECT face_count FROM photo_traits WHERE file_id = 'twin'"), 2)
            XCTAssertEqual(try Int.fetchOne(db, sql:
                "SELECT COUNT(*) FROM clip_embeddings WHERE file_id = 'twin'"), 1)
            // Vision tags land in the twin's OWN folder scope.
            XCTAssertEqual(try String.fetchOne(db, sql:
                "SELECT label FROM tags WHERE file_id = 'twin'"), "autumn")
            // The OCR text and caption come across; the basename does NOT —
            // the twin keeps the name it has on disk.
            XCTAssertEqual(try String.fetchOne(db, sql:
                "SELECT ocr_text FROM files_fts WHERE file_id = 'twin'"), "scanned words")
            XCTAssertEqual(try String.fetchOne(db, sql:
                "SELECT basename FROM files_fts WHERE file_id = 'twin'"), "two.jpg")
        }
    }

    /// A twin that has not been analyzed yet has nothing to give — adopting
    /// from it would mark the file analyzed while producing no results at all.
    func testDoesNotAdoptFromAnUnanalyzedTwin() throws {
        let q = try migrated()
        try seedPair(q, donorAnalyzed: false)
        let adopted = try q.write { db in
            try AnalysisReuse.adopt(db: db, fileID: "twin", hash: "h1")
        }
        XCTAssertFalse(adopted)
        try q.read { db in
            XCTAssertNil(try String.fetchOne(db, sql:
                "SELECT analyzed_hash FROM files WHERE id = 'twin'"))
        }
    }

    func testDoesNotAdoptWhenNothingSharesTheHash() throws {
        let q = try migrated()
        try seedPair(q)
        let adopted = try q.write { db in
            try AnalysisReuse.adopt(db: db, fileID: "twin", hash: "someotherhash")
        }
        XCTAssertFalse(adopted)
    }

    /// A donor whose `analyzed_hash` is stale (it was edited since) must not be
    /// adopted from — its results describe different pixels.
    func testDoesNotAdoptFromADonorWhoseAnalysisIsStale() throws {
        let q = try migrated()
        try q.write { db in
            try db.execute(sql: """
                INSERT INTO files (id, content_hash, kind, last_seen_at, analyzed_hash)
                VALUES ('donor', 'h1', 'image', 0, 'OLDHASH')
                """)
            try db.execute(sql: """
                INSERT INTO files (id, content_hash, kind, last_seen_at)
                VALUES ('twin', 'h1', 'image', 0)
                """)
        }
        let adopted = try q.write { db in
            try AnalysisReuse.adopt(db: db, fileID: "twin", hash: "h1")
        }
        XCTAssertFalse(adopted)
    }

    /// Adopting must never overwrite the user's own tags on the target.
    func testDoesNotClobberTheTargetsExistingTags() throws {
        let q = try migrated()
        try seedPair(q)
        try q.write { db in
            try db.execute(sql: """
                INSERT INTO tags (id, file_id, parent_dir, label, source)
                VALUES ('mine', 'twin', '/a', 'keeper', 'manual')
                """)
            _ = try AnalysisReuse.adopt(db: db, fileID: "twin", hash: "h1")
        }
        try q.read { db in
            let labels = try String.fetchAll(db, sql:
                "SELECT label FROM tags WHERE file_id = 'twin' ORDER BY label")
            XCTAssertEqual(labels, ["autumn", "keeper"])
        }
    }

    /// Idempotent: a second pass must not duplicate rows.
    func testAdoptingTwiceIsIdempotent() throws {
        let q = try migrated()
        try seedPair(q)
        try q.write { db in
            _ = try AnalysisReuse.adopt(db: db, fileID: "twin", hash: "h1")
            _ = try AnalysisReuse.adopt(db: db, fileID: "twin", hash: "h1")
        }
        try q.read { db in
            XCTAssertEqual(try Int.fetchOne(db, sql:
                "SELECT COUNT(*) FROM tags WHERE file_id = 'twin'"), 1)
            XCTAssertEqual(try Int.fetchOne(db, sql:
                "SELECT COUNT(*) FROM photo_traits WHERE file_id = 'twin'"), 1)
        }
    }
}
