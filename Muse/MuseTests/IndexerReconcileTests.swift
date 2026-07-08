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

    // MARK: Note carry on split / collision (per (file_id, parent_dir), like tags)

    func testSplitMovesNoteToEditedIdentity() throws {
        // Editing one of two byte-identical copies in DIFFERENT folders splits the
        // row; the /a note must follow the edited copy to its new identity (MOVE —
        // no same-folder sibling), leaving the /b sibling's note intact.
        let q = try freshQueue()
        try q.write { db in
            try db.execute(sql: "INSERT INTO files (id, content_hash, kind, last_seen_at, analyzed_hash) VALUES ('f1','h1','image',0,'h1')")
            try db.execute(sql: "INSERT INTO paths (id, file_id, absolute_path, is_alive) VALUES ('pA','f1','/a/x.png',1)")
            try db.execute(sql: "INSERT INTO paths (id, file_id, absolute_path, is_alive) VALUES ('pB','f1','/b/x.png',1)")
            try db.execute(sql: "INSERT INTO notes (file_id, parent_dir, body, updated_at) VALUES ('f1','/a','a note',100)")
            try db.execute(sql: "INSERT INTO notes (file_id, parent_dir, body, updated_at) VALUES ('f1','/b','b note',100)")

            _ = try Indexer.reconcile(db: db, absPath: "/a/x.png", hash: "h2",
                                      kind: .image, sizeBytes: 1, createdAt: 0, modifiedAt: 1, now: 2)
        }
        try q.read { db in
            let aFileID = try String.fetchOne(db, sql: "SELECT file_id FROM paths WHERE id='pA'")!
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT body FROM notes WHERE file_id=? AND parent_dir='/a'", arguments: [aFileID]), "a note")
            XCTAssertNil(try String.fetchOne(db, sql: "SELECT body FROM notes WHERE file_id='f1' AND parent_dir='/a'"), "moved off the old identity")
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT body FROM notes WHERE file_id='f1' AND parent_dir='/b'"), "b note", "sibling note intact")
        }
    }

    func testSplitCopiesNoteWhenSameFolderSiblingShares() throws {
        // Two byte-identical copies in the SAME folder share the (file_id, /a) note
        // key. Editing one must COPY the note to the edited copy's new identity —
        // the unedited same-folder sibling still resolves via the old row.
        let q = try freshQueue()
        try q.write { db in
            try db.execute(sql: "INSERT INTO files (id, content_hash, kind, last_seen_at, analyzed_hash) VALUES ('f1','h1','image',0,'h1')")
            try db.execute(sql: "INSERT INTO paths (id, file_id, absolute_path, is_alive) VALUES ('pA','f1','/a/x.png',1)")
            try db.execute(sql: "INSERT INTO paths (id, file_id, absolute_path, is_alive) VALUES ('pB','f1','/a/y.png',1)")
            try db.execute(sql: "INSERT INTO notes (file_id, parent_dir, body, updated_at) VALUES ('f1','/a','shared',100)")

            _ = try Indexer.reconcile(db: db, absPath: "/a/x.png", hash: "h2",
                                      kind: .image, sizeBytes: 1, createdAt: 0, modifiedAt: 1, now: 2)
        }
        try q.read { db in
            let aFileID = try String.fetchOne(db, sql: "SELECT file_id FROM paths WHERE id='pA'")!
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT body FROM notes WHERE file_id=? AND parent_dir='/a'", arguments: [aFileID]), "shared")
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT body FROM notes WHERE file_id='f1' AND parent_dir='/a'"), "shared", "same-folder sibling keeps its note")
        }
    }

    func testCollisionSoleCopyCarriesNoteToTarget() throws {
        // The edited path's new bytes match a DIFFERENT existing row (h2/f2) and
        // this is f1's sole alive path: the note carries onto the target identity.
        let q = try freshQueue()
        try q.write { db in
            try db.execute(sql: "INSERT INTO files (id, content_hash, kind, last_seen_at, analyzed_hash) VALUES ('f1','h1','image',0,'h1')")
            try db.execute(sql: "INSERT INTO files (id, content_hash, kind, last_seen_at, analyzed_hash) VALUES ('f2','h2','image',0,'h2')")
            try db.execute(sql: "INSERT INTO paths (id, file_id, absolute_path, is_alive) VALUES ('pA','f1','/a/x.png',1)")
            try db.execute(sql: "INSERT INTO paths (id, file_id, absolute_path, is_alive) VALUES ('pC','f2','/c/z.png',1)")
            try db.execute(sql: "INSERT INTO notes (file_id, parent_dir, body, updated_at) VALUES ('f1','/a','carry me',100)")

            _ = try Indexer.reconcile(db: db, absPath: "/a/x.png", hash: "h2",
                                      kind: .image, sizeBytes: 1, createdAt: 0, modifiedAt: 1, now: 2)
        }
        try q.read { db in
            // pA now points at f2; the note carried to (f2, /a) and the old
            // identity's note row is gone (mirrors unionTags deleting its source).
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT file_id FROM paths WHERE id='pA'"), "f2")
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT body FROM notes WHERE file_id='f2' AND parent_dir='/a'"), "carry me")
            XCTAssertNil(try String.fetchOne(db, sql: "SELECT body FROM notes WHERE file_id='f1' AND parent_dir='/a'"))
        }
    }

    // MARK: FTS basename coverage (every kind, not just analyzed images)

    func testNewNonImageFileGetsBasenameFTSRow() throws {
        // Historically only analyzeOne wrote files_fts rows (images only), so
        // library-wide search could never find a PDF/video by name.
        let q = try freshQueue()
        try q.write { db in
            _ = try Indexer.reconcile(db: db, absPath: "/a/report.pdf", hash: "h1",
                                      kind: .pdf, sizeBytes: 1, createdAt: 0, modifiedAt: 1, now: 2)
        }
        try q.read { db in
            let fid = try String.fetchOne(db, sql: "SELECT file_id FROM paths WHERE absolute_path='/a/report.pdf'")!
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT basename FROM files_fts WHERE file_id=?", arguments: [fid]),
                           "report.pdf")
        }
    }

    func testBasenameFTSBackfillCoversExistingRows() throws {
        let q = try freshQueue()
        try q.write { db in
            // A pre-v9 row: file + alive path, no FTS row.
            try db.execute(sql: "INSERT INTO files (id, content_hash, kind, last_seen_at) VALUES ('f1','h1','pdf',0)")
            try db.execute(sql: "INSERT INTO paths (id, file_id, absolute_path, is_alive) VALUES ('p1','f1','/a/notes.pdf',1)")
            try db.execute(sql: "DELETE FROM files_fts WHERE file_id='f1'")
            try Database.backfillBasenameFTS(db)
        }
        try q.read { db in
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT basename FROM files_fts WHERE file_id='f1'"), "notes.pdf")
            // Idempotent — a second run must not duplicate.
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM files_fts WHERE file_id='f1'"), 1)
        }
    }

    // MARK: hash-collision edit branch (new bytes match a DIFFERENT existing row)

    func testCollisionEditOnSharedRowKeepsSiblingTags() throws {
        // f1 is SHARED by /a and /b; editing /a's copy so its bytes match f2
        // must carry only /a's tags to f2 — the untouched /b sibling keeps its
        // tags on f1 (the unscoped union moved EVERY folder's tags off f1).
        let q = try freshQueue()
        try q.write { db in
            try db.execute(sql: "INSERT INTO files (id, content_hash, kind, last_seen_at, analyzed_hash) VALUES ('f1','h1','image',0,'h1')")
            try db.execute(sql: "INSERT INTO files (id, content_hash, kind, last_seen_at, analyzed_hash) VALUES ('f2','h2','image',0,'h2')")
            try db.execute(sql: "INSERT INTO paths (id, file_id, absolute_path, is_alive) VALUES ('pA','f1','/a/x.png',1)")
            try db.execute(sql: "INSERT INTO paths (id, file_id, absolute_path, is_alive) VALUES ('pB','f1','/b/x.png',1)")
            try db.execute(sql: "INSERT INTO paths (id, file_id, absolute_path, is_alive) VALUES ('pC','f2','/c/y.png',1)")
            try db.execute(sql: "INSERT INTO tags (id, file_id, label, source, confidence, parent_dir) VALUES ('tA','f1','blue','manual',NULL,'/a')")
            try db.execute(sql: "INSERT INTO tags (id, file_id, label, source, confidence, parent_dir) VALUES ('tB','f1','red','manual',NULL,'/b')")

            _ = try Indexer.reconcile(db: db, absPath: "/a/x.png", hash: "h2",
                                      kind: .image, sizeBytes: 1, createdAt: 0, modifiedAt: 1, now: 2)
        }
        try q.read { db in
            // The edited path re-linked to the colliding row.
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT file_id FROM paths WHERE id='pA'"), "f2")
            // /a's tag followed it, scoped to /a.
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM tags WHERE file_id='f2' AND parent_dir='/a' AND label='blue'"), 1)
            // The /b sibling's tag stayed on f1, and f1 itself is untouched.
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM tags WHERE file_id='f1' AND parent_dir='/b' AND label='red'"), 1)
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT content_hash FROM files WHERE id='f1'"), "h1")
            // No /b tags leaked onto f2.
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM tags WHERE file_id='f2' AND parent_dir='/b'"), 0)
        }
    }

    func testCollisionEditCopiesTagsWhenSameFolderSiblingShares() throws {
        // Same-folder byte-identical sibling: the (f1, /a) tag rows are shared
        // with the still-present sibling, so the collision carry must COPY
        // them to f2, not move them.
        let q = try freshQueue()
        try q.write { db in
            try db.execute(sql: "INSERT INTO files (id, content_hash, kind, last_seen_at, analyzed_hash) VALUES ('f1','h1','image',0,'h1')")
            try db.execute(sql: "INSERT INTO files (id, content_hash, kind, last_seen_at, analyzed_hash) VALUES ('f2','h2','image',0,'h2')")
            try db.execute(sql: "INSERT INTO paths (id, file_id, absolute_path, is_alive) VALUES ('pA','f1','/a/x.png',1)")
            try db.execute(sql: "INSERT INTO paths (id, file_id, absolute_path, is_alive) VALUES ('pB','f1','/a/y.png',1)")
            try db.execute(sql: "INSERT INTO paths (id, file_id, absolute_path, is_alive) VALUES ('pC','f2','/c/y.png',1)")
            try db.execute(sql: "INSERT INTO tags (id, file_id, label, source, confidence, parent_dir) VALUES ('t1','f1','blue','manual',NULL,'/a')")

            _ = try Indexer.reconcile(db: db, absPath: "/a/x.png", hash: "h2",
                                      kind: .image, sizeBytes: 1, createdAt: 0, modifiedAt: 1, now: 2)
        }
        try q.read { db in
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT file_id FROM paths WHERE id='pA'"), "f2")
            // Edited copy got the tag on its new identity …
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM tags WHERE file_id='f2' AND parent_dir='/a' AND label='blue'"), 1)
            // … and the unedited same-folder sibling KEPT it on f1.
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM tags WHERE file_id='f1' AND parent_dir='/a' AND label='blue'"), 1)
        }
    }

    func testCollisionEditSoleCopyUnionsAllTagsAndCarriesMembership() throws {
        // Sole alive path: the old identity is finished — everything unions to
        // the colliding row (pre-existing behavior), and manual collection
        // membership follows the edited file to its new identity.
        let q = try freshQueue()
        try q.write { db in
            try db.execute(sql: "INSERT INTO files (id, content_hash, kind, last_seen_at, analyzed_hash) VALUES ('f1','h1','image',0,'h1')")
            try db.execute(sql: "INSERT INTO files (id, content_hash, kind, last_seen_at, analyzed_hash) VALUES ('f2','h2','image',0,'h2')")
            try db.execute(sql: "INSERT INTO paths (id, file_id, absolute_path, is_alive) VALUES ('pA','f1','/a/x.png',1)")
            try db.execute(sql: "INSERT INTO paths (id, file_id, absolute_path, is_alive) VALUES ('pC','f2','/c/y.png',1)")
            try db.execute(sql: "INSERT INTO tags (id, file_id, label, source, confidence, parent_dir) VALUES ('t1','f1','blue','manual',NULL,'/a')")
            try db.execute(sql: "INSERT INTO collections (id, name, is_hidden, model_version, created_at, updated_at, sort_order) VALUES ('cManual','Faves',0,'manual',0,0,0)")
            try db.execute(sql: "INSERT INTO collection_members (collection_id, file_id, added_by) VALUES ('cManual','f1','manual')")

            _ = try Indexer.reconcile(db: db, absPath: "/a/x.png", hash: "h2",
                                      kind: .image, sizeBytes: 1, createdAt: 0, modifiedAt: 1, now: 2)
        }
        try q.read { db in
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT file_id FROM paths WHERE id='pA'"), "f2")
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM tags WHERE file_id='f2' AND parent_dir='/a' AND label='blue'"), 1)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM tags WHERE file_id='f1'"), 0)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM collection_members WHERE collection_id='cManual' AND file_id='f2'"), 1)
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
