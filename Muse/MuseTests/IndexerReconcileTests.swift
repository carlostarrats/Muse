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

    func testSplitCopiesTagsWhenSameFolderSiblingShares() throws {
        // Two byte-identical files in the SAME folder share ONE (file_id, parent_dir)
        // tag key. Editing one must COPY the shared tags to the edited copy's new
        // identity, NOT move them — the unedited same-folder sibling still points at
        // the old row and must keep its tags.
        let q = try freshQueue()
        try q.write { db in
            try db.execute(sql: "INSERT INTO files (id, content_hash, kind, last_seen_at, analyzed_hash) VALUES ('f1','h1','image',0,'h1')")
            try db.execute(sql: "INSERT INTO paths (id, file_id, absolute_path, is_alive) VALUES ('pA','f1','/a/x.png',1)")
            try db.execute(sql: "INSERT INTO paths (id, file_id, absolute_path, is_alive) VALUES ('pB','f1','/a/y.png',1)")
            try db.execute(sql: "INSERT INTO tags (id, file_id, label, source, confidence, parent_dir) VALUES ('t1','f1','blue','manual',NULL,'/a')")

            _ = try Indexer.reconcile(db: db, absPath: "/a/x.png", hash: "h2",
                                      kind: .image, sizeBytes: 1, createdAt: 0, modifiedAt: 1, now: 2)
        }
        try q.read { db in
            let aFileID = try String.fetchOne(db, sql: "SELECT file_id FROM paths WHERE id='pA'")!
            XCTAssertNotEqual(aFileID, "f1")
            // Edited copy got the tag …
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM tags WHERE file_id=? AND parent_dir='/a' AND label='blue'", arguments: [aFileID]), 1)
            // … and the unedited same-folder sibling KEPT it (still on f1).
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM tags WHERE file_id='f1' AND parent_dir='/a' AND label='blue'"), 1)
        }
    }

    func testSplitCarriesManualCollectionMembership() throws {
        let q = try freshQueue()
        try q.write { db in
            try db.execute(sql: "INSERT INTO files (id, content_hash, kind, last_seen_at, analyzed_hash) VALUES ('f1','h1','image',0,'h1')")
            try db.execute(sql: "INSERT INTO paths (id, file_id, absolute_path, is_alive) VALUES ('pA','f1','/a/x.png',1)")
            try db.execute(sql: "INSERT INTO paths (id, file_id, absolute_path, is_alive) VALUES ('pB','f1','/b/x.png',1)")
            // A manual collection the shared file belongs to, plus an AUTO one.
            try db.execute(sql: "INSERT INTO collections (id, name, is_hidden, model_version, created_at, updated_at, sort_order) VALUES ('cManual','Faves',0,'manual',0,0,0)")
            try db.execute(sql: "INSERT INTO collections (id, name, is_hidden, model_version, created_at, updated_at, sort_order) VALUES ('cAuto','Cluster',0,'cluster-v1',0,0,1)")
            try db.execute(sql: "INSERT INTO collection_members (collection_id, file_id, added_by) VALUES ('cManual','f1','manual')")
            try db.execute(sql: "INSERT INTO collection_members (collection_id, file_id, added_by) VALUES ('cAuto','f1','auto')")

            _ = try Indexer.reconcile(db: db, absPath: "/a/x.png", hash: "h2",
                                      kind: .image, sizeBytes: 1, createdAt: 0, modifiedAt: 1, now: 2)
        }
        try q.read { db in
            let aFileID = try String.fetchOne(db, sql: "SELECT file_id FROM paths WHERE id='pA'")!
            // Manual membership COPIED to the edited copy's new identity (so it stays
            // in the collection the user added it to) — and the sibling keeps it too.
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM collection_members WHERE collection_id='cManual' AND file_id=?", arguments: [aFileID]), 1)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM collection_members WHERE collection_id='cManual' AND file_id='f1'"), 1)
            // AUTO membership is NOT carried (the recluster regenerates it).
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM collection_members WHERE collection_id='cAuto' AND file_id=?", arguments: [aFileID]), 0)
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
