//
//  IndexerReconcileTests.swift
//  MuseTests
//
//  Identity-reconcile edge cases that mutate real rows. The load-bearing one
//  here: editing one of two byte-identical files (which dedupe onto a single
//  content_hash row) must SPLIT the row, not rewrite it — otherwise the
//  untouched sibling is corrupted and the two copies ping-pong the shared row.
//

import XCTest
import GRDB
@testable import Muse

final class IndexerReconcileTests: XCTestCase {

    private func freshQueue() throws -> DatabaseQueue {
        let q = try DatabaseQueue()
        try Database.makeMigrator().migrate(q)
        return q
    }

    func testEditingOneSharedCopySplitsRowAndPreservesSibling() throws {
        let q = try freshQueue()
        try q.write { db in
            // Two byte-identical files in two folders share ONE files row (h1).
            try db.execute(sql: "INSERT INTO files (id, content_hash, kind, last_seen_at, analyzed_hash) VALUES ('f1','h1','image',0,'h1')")
            try db.execute(sql: "INSERT INTO paths (id, file_id, absolute_path, is_alive) VALUES ('pA','f1','/a/x.png',1)")
            try db.execute(sql: "INSERT INTO paths (id, file_id, absolute_path, is_alive) VALUES ('pB','f1','/b/x.png',1)")
            // A manual tag at each location (per (file_id, parent_dir)).
            try db.execute(sql: "INSERT INTO tags (id, file_id, label, source, confidence, parent_dir) VALUES ('tA','f1','blue','manual',NULL,'/a')")
            try db.execute(sql: "INSERT INTO tags (id, file_id, label, source, confidence, parent_dir) VALUES ('tB','f1','red','manual',NULL,'/b')")

            // Edit the copy in /a — its bytes now hash to h2.
            let changed = try Indexer.reconcile(db: db, absPath: "/a/x.png", hash: "h2",
                                                kind: .image, sizeBytes: 123,
                                                createdAt: 0, modifiedAt: 99, now: 100)
            XCTAssertTrue(changed, "an in-place edit reports a change (re-thumbnail/re-analyze)")
        }

        try q.read { db in
            // The edited path moved to a NEW files row carrying the new hash.
            let aFileID = try String.fetchOne(db, sql: "SELECT file_id FROM paths WHERE id='pA'")!
            XCTAssertNotEqual(aFileID, "f1", "edited path must leave the shared row")
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT content_hash FROM files WHERE id=?", arguments: [aFileID]), "h2")
            XCTAssertNil(try String.fetchOne(db, sql: "SELECT analyzed_hash FROM files WHERE id=?", arguments: [aFileID]),
                         "new identity is unanalyzed so Vision re-runs")

            // The sibling is completely untouched — still on f1 / h1, still analyzed.
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT file_id FROM paths WHERE id='pB'"), "f1")
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT content_hash FROM files WHERE id='f1'"), "h1")
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT analyzed_hash FROM files WHERE id='f1'"), "h1")

            // The /a tag followed the edited file to its new identity; the /b tag stayed.
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT file_id FROM tags WHERE id='tA'"), aFileID)
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT file_id FROM tags WHERE id='tB'"), "f1")
        }
    }

    func testEditingSoleCopyStillRewritesInPlace() throws {
        // The regression guard: when the row is NOT shared, an edit must still
        // rewrite the existing row in place (no spurious split).
        let q = try freshQueue()
        try q.write { db in
            try db.execute(sql: "INSERT INTO files (id, content_hash, kind, last_seen_at, analyzed_hash) VALUES ('f1','h1','image',0,'h1')")
            try db.execute(sql: "INSERT INTO paths (id, file_id, absolute_path, is_alive) VALUES ('pA','f1','/a/x.png',1)")

            _ = try Indexer.reconcile(db: db, absPath: "/a/x.png", hash: "h2",
                                      kind: .image, sizeBytes: 1, createdAt: 0, modifiedAt: 1, now: 2)
        }
        try q.read { db in
            // Same row, new hash, reset analyzed_hash, no new files row.
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT file_id FROM paths WHERE id='pA'"), "f1")
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT content_hash FROM files WHERE id='f1'"), "h2")
            XCTAssertNil(try String.fetchOne(db, sql: "SELECT analyzed_hash FROM files WHERE id='f1'"))
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM files"), 1)
        }
    }
}
