//
//  IndexerReconcileTests.swift
//  MuseTests
//
//  Identity-reconcile edge cases that mutate real rows.
//
//  **Rewritten 2026-08-03 for per-file identity.** This file used to pin the
//  opposite behaviour: byte-identical files deduped onto ONE `files` row, and
//  nine tests here guarded the machinery that compensated for the sharing —
//  the split-on-edit-in-place branch, the hash-collision carry, and their
//  same-folder-sibling copy-vs-move rules. All of that is deleted. A copy is
//  now its own file, so there is no shared row to split, nothing to carry, and
//  two rows may legally hold the same `content_hash`.
//
//  What replaces them is the isolation the owner actually asked for: editing
//  one copy must not touch its twin.
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

    /// Index a file the way a real pass would, through `reconcile`.
    @discardableResult
    private func index(_ db: GRDB.Database, _ path: String, hash: String,
                       kind: AssetKind = .image, now: Int64 = 1) throws -> Bool {
        try Indexer.reconcile(db: db, absPath: path, hash: hash, kind: kind,
                              sizeBytes: 1, createdAt: 0, modifiedAt: 1, now: now)
    }

    private func fileID(_ db: GRDB.Database, forPath path: String) throws -> String {
        try String.fetchOne(db, sql:
            "SELECT file_id FROM paths WHERE absolute_path = ? AND is_alive = 1",
            arguments: [path])!
    }

    // MARK: - Per-file identity

    /// THE REPORTED BUG at the indexer level. A second copy of the same bytes
    /// in the same folder is its own file, not another name for the first.
    func testSameFolderCopyBecomesItsOwnRow() throws {
        let q = try freshQueue()
        try q.write { db in
            try index(db, "/a/one.arw", hash: "h1")
            try index(db, "/a/two.arw", hash: "h1")
        }
        try q.read { db in
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM files"), 2)
            let one = try fileID(db, forPath: "/a/one.arw")
            let two = try fileID(db, forPath: "/a/two.arw")
            XCTAssertNotEqual(one, two)
            // The invariant that replaced content_hash UNIQUE.
            let worst = try Int.fetchOne(db, sql: """
                SELECT COALESCE(MAX(n), 0) FROM
                  (SELECT COUNT(*) AS n FROM paths WHERE is_alive = 1 GROUP BY file_id)
                """)
            XCTAssertEqual(worst, 1)
        }
    }

    /// Each copy is findable by its OWN name. Before per-file identity one FTS
    /// row held one basename, so the second copy was unfindable.
    func testEachCopyIsSearchableByItsOwnName() throws {
        let q = try freshQueue()
        try q.write { db in
            try index(db, "/a/one.arw", hash: "h1")
            try index(db, "/a/two.arw", hash: "h1")
        }
        try q.read { db in
            for name in ["one.arw", "two.arw"] {
                XCTAssertEqual(try Int.fetchOne(db, sql:
                    "SELECT COUNT(*) FROM files_fts WHERE basename = ?", arguments: [name]),
                    1, "\(name) not searchable")
            }
        }
    }

    /// The owner's inherit rule: a new copy starts from the donor's edit, tag
    /// and note — and then diverges.
    func testNewCopyInheritsTheDonorsEditTagAndNote() throws {
        let q = try freshQueue()
        try q.write { db in
            try index(db, "/a/one.arw", hash: "h1")
            let one = try self.fileID(db, forPath: "/a/one.arw")
            try db.execute(sql: """
                INSERT INTO edits (file_id, parent_dir, stack, stack_hash, process_version, updated_at)
                VALUES (?, '/a', '{"v":1}', 'sh', 1, 7)
                """, arguments: [one])
            try db.execute(sql: """
                INSERT INTO tags (id, file_id, parent_dir, label, source, confidence)
                VALUES ('t1', ?, '/a', 'autumn', 'manual', NULL)
                """, arguments: [one])
            try db.execute(sql: """
                INSERT INTO notes (file_id, parent_dir, body, updated_at)
                VALUES (?, '/a', 'keeper', 3)
                """, arguments: [one])

            try index(db, "/a/two.arw", hash: "h1")
        }
        try q.read { db in
            let two = try fileID(db, forPath: "/a/two.arw")
            XCTAssertEqual(try String.fetchOne(db, sql:
                "SELECT stack FROM edits WHERE file_id = ?", arguments: [two]), "{\"v\":1}")
            XCTAssertEqual(try String.fetchOne(db, sql:
                "SELECT label FROM tags WHERE file_id = ?", arguments: [two]), "autumn")
            XCTAssertEqual(try String.fetchOne(db, sql:
                "SELECT body FROM notes WHERE file_id = ?", arguments: [two]), "keeper")
        }
    }

    /// Inheritance is a COPY at creation, never a live link — the whole point
    /// is that the two copies can then hold different edits.
    func testEditingOneCopyLeavesTheOtherAlone() throws {
        let q = try freshQueue()
        try q.write { db in
            try index(db, "/a/one.arw", hash: "h1")
            let one = try self.fileID(db, forPath: "/a/one.arw")
            try db.execute(sql: """
                INSERT INTO edits (file_id, parent_dir, stack, stack_hash, process_version, updated_at)
                VALUES (?, '/a', '{"warm":1}', 'sh', 1, 7)
                """, arguments: [one])
            try index(db, "/a/two.arw", hash: "h1")

            // Now push the COPY somewhere else entirely.
            let two = try self.fileID(db, forPath: "/a/two.arw")
            try db.execute(sql: """
                UPDATE edits SET stack = '{"cool":1}', stack_hash = 'sh2', updated_at = 9
                WHERE file_id = ?
                """, arguments: [two])
        }
        try q.read { db in
            let one = try fileID(db, forPath: "/a/one.arw")
            let two = try fileID(db, forPath: "/a/two.arw")
            XCTAssertEqual(try String.fetchOne(db, sql:
                "SELECT stack FROM edits WHERE file_id = ?", arguments: [one]), "{\"warm\":1}")
            XCTAssertEqual(try String.fetchOne(db, sql:
                "SELECT stack FROM edits WHERE file_id = ?", arguments: [two]), "{\"cool\":1}")
        }
    }

    /// Inheriting must not queue a redundant Vision pass: identical bytes have
    /// identical answers, so the copy adopts the donor's analysis outright.
    func testNewCopyIsNotMarkedUnanalyzed() throws {
        let q = try freshQueue()
        try q.write { db in
            try index(db, "/a/one.arw", hash: "h1")
            let one = try self.fileID(db, forPath: "/a/one.arw")
            try db.execute(sql: """
                UPDATE files SET analyzed_hash = 'h1', caption = 'a caption', palette = '#fff'
                WHERE id = ?
                """, arguments: [one])
            try db.execute(sql: """
                INSERT INTO photo_meta (file_id, capture_date, camera_make)
                VALUES (?, 1700000000, 'Sony')
                """, arguments: [one])

            try index(db, "/a/two.arw", hash: "h1")
        }
        try q.read { db in
            let two = try fileID(db, forPath: "/a/two.arw")
            XCTAssertEqual(try String.fetchOne(db, sql:
                "SELECT analyzed_hash FROM files WHERE id = ?", arguments: [two]), "h1")
            XCTAssertEqual(try String.fetchOne(db, sql:
                "SELECT caption FROM files WHERE id = ?", arguments: [two]), "a caption")
            XCTAssertEqual(try String.fetchOne(db, sql:
                "SELECT camera_make FROM photo_meta WHERE file_id = ?", arguments: [two]), "Sony")
        }
    }

    /// Manual collection membership rides along, so a duplicate does not
    /// silently drop out of the collections its original belongs to.
    func testNewCopyInheritsCollectionMembership() throws {
        let q = try freshQueue()
        try q.write { db in
            try index(db, "/a/one.arw", hash: "h1")
            let one = try self.fileID(db, forPath: "/a/one.arw")
            try db.execute(sql: """
                INSERT INTO collections (id, name, is_hidden, model_version,
                                         created_at, updated_at, sort_order)
                VALUES ('C', 'Faves', 0, 'v1', 0, 0, 0)
                """)
            try db.execute(sql: """
                INSERT INTO collection_members (collection_id, file_id, added_by)
                VALUES ('C', ?, 'manual')
                """, arguments: [one])

            try index(db, "/a/two.arw", hash: "h1")
        }
        try q.read { db in
            XCTAssertEqual(try Int.fetchOne(db, sql:
                "SELECT COUNT(*) FROM collection_members WHERE collection_id = 'C'"), 2)
        }
    }

    /// Donor selection reaches across folders when it has to, but the copy is
    /// still its own row.
    func testCrossFolderCopyAlsoGetsItsOwnRow() throws {
        let q = try freshQueue()
        try q.write { db in
            try index(db, "/a/x.png", hash: "h1")
            try index(db, "/b/x.png", hash: "h1")
        }
        try q.read { db in
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM files"), 2)
            XCTAssertNotEqual(try fileID(db, forPath: "/a/x.png"),
                              try fileID(db, forPath: "/b/x.png"))
        }
    }

    // MARK: - Edit in place

    /// An edit rewrites the row in place. There is no sharing left, so there
    /// is no split branch and no collision branch — this is the only path.
    func testEditingAFileRewritesItsRowInPlace() throws {
        let q = try freshQueue()
        try q.write { db in
            try db.execute(sql: "INSERT INTO files (id, content_hash, kind, last_seen_at, analyzed_hash) VALUES ('f1','h1','image',0,'h1')")
            try db.execute(sql: "INSERT INTO paths (id, file_id, absolute_path, is_alive) VALUES ('pA','f1','/a/x.png',1)")

            try index(db, "/a/x.png", hash: "h2", now: 2)
        }
        try q.read { db in
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT file_id FROM paths WHERE id='pA'"), "f1")
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT content_hash FROM files WHERE id='f1'"), "h2")
            XCTAssertNil(try String.fetchOne(db, sql: "SELECT analyzed_hash FROM files WHERE id='f1'"),
                         "changed bytes must re-analyze")
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM files"), 1)
        }
    }

    /// Editing a file so its bytes match ANOTHER file used to be the
    /// "hash collision" branch, with a whole re-linking dance. Two rows may
    /// now share a hash, so it is an ordinary in-place edit and the other file
    /// is not touched at all.
    func testEditingIntoAnotherFilesBytesIsAnOrdinaryEdit() throws {
        let q = try freshQueue()
        try q.write { db in
            try index(db, "/a/x.png", hash: "h1")
            try index(db, "/b/y.png", hash: "h2")
            // /a/x.png is edited and now hashes to h2, same as /b/y.png.
            try index(db, "/a/x.png", hash: "h2", now: 5)
        }
        try q.read { db in
            let x = try fileID(db, forPath: "/a/x.png")
            let y = try fileID(db, forPath: "/b/y.png")
            XCTAssertNotEqual(x, y, "the edited file keeps its own identity")
            XCTAssertEqual(try String.fetchOne(db, sql:
                "SELECT content_hash FROM files WHERE id = ?", arguments: [x]), "h2")
            XCTAssertEqual(try String.fetchOne(db, sql:
                "SELECT content_hash FROM files WHERE id = ?", arguments: [y]), "h2")
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM files"), 2)
        }
    }

    // MARK: - FTS basename (unchanged behaviour)

    func testNewNonImageFileGetsBasenameFTSRow() throws {
        // Historically only analyzeOne wrote files_fts rows (images only), so
        // library-wide search could never find a PDF/video by name.
        let q = try freshQueue()
        try q.write { db in
            try index(db, "/a/report.pdf", hash: "h1", kind: .pdf, now: 2)
        }
        try q.read { db in
            let fid = try fileID(db, forPath: "/a/report.pdf")
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

    // MARK: - Rename and move (orphan adoption)

    /// The distinction per-file identity turns on: an ORPHANED row — holds
    /// these bytes, has no alive path — is the SAME file under a new name, so
    /// it is adopted rather than forked. Without this a rename would mint a
    /// fresh row and strand the original.
    func testExternalRenameAdoptsTheOrphanedRowAndKeepsItsEdit() throws {
        let q = try freshQueue()
        try q.write { db in
            try index(db, "/a/before.jpg", hash: "h1")
            let fid = try self.fileID(db, forPath: "/a/before.jpg")
            try db.execute(sql: """
                INSERT INTO edits (file_id, parent_dir, stack, stack_hash, process_version, updated_at)
                VALUES (?, '/a', '{"warm":1}', 'sh', 1, 7)
                """, arguments: [fid])
            // The folder pass marks the vanished name dead BEFORE indexing the
            // new one (PathReconciler.reconcile runs ahead of scheduleIndexing).
            try db.execute(sql: "UPDATE paths SET is_alive = 0 WHERE absolute_path = '/a/before.jpg'")
            try index(db, "/a/after.jpg", hash: "h1", now: 9)
        }
        try q.read { db in
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM files"), 1,
                           "a rename must not fork a second row")
            let fid = try fileID(db, forPath: "/a/after.jpg")
            XCTAssertEqual(try String.fetchOne(db, sql:
                "SELECT stack FROM edits WHERE file_id = ?", arguments: [fid]), "{\"warm\":1}")
            // Searchable under the name it has NOW, not the one it had.
            XCTAssertEqual(try String.fetchOne(db, sql:
                "SELECT basename FROM files_fts WHERE file_id = ?", arguments: [fid]), "after.jpg")
        }
    }

    /// A move across folders is the same case — the row travels with the file.
    func testExternalMoveAdoptsTheOrphanedRow() throws {
        let q = try freshQueue()
        try q.write { db in
            try index(db, "/a/x.jpg", hash: "h1")
            try db.execute(sql: "UPDATE paths SET is_alive = 0 WHERE absolute_path = '/a/x.jpg'")
            try index(db, "/b/x.jpg", hash: "h1", now: 9)
        }
        try q.read { db in
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM files"), 1)
            XCTAssertEqual(try Int.fetchOne(db, sql:
                "SELECT COUNT(*) FROM paths WHERE is_alive = 1"), 1)
        }
    }

    /// The contrast that makes adoption safe: while the original is still
    /// ALIVE, the same bytes appearing elsewhere are a COPY, not a rename — so
    /// they must NOT take over its row.
    func testLiveOriginalMeansCopyNotAdoption() throws {
        let q = try freshQueue()
        try q.write { db in
            try index(db, "/a/x.jpg", hash: "h1")
            try index(db, "/b/x.jpg", hash: "h1")
        }
        try q.read { db in
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM files"), 2)
            XCTAssertNotEqual(try fileID(db, forPath: "/a/x.jpg"),
                              try fileID(db, forPath: "/b/x.jpg"))
        }
    }

    /// Several orphans can hold the same bytes (two copies deleted, one file
    /// restored). The choice must be deterministic, or the same restore adopts
    /// a different identity — and a different edit stack — run to run.
    func testAdoptionIsDeterministicAmongSeveralOrphans() throws {
        func run() throws -> String {
            let q = try freshQueue()
            return try q.write { db in
                try db.execute(sql: """
                    INSERT INTO files (id, content_hash, kind, last_seen_at)
                    VALUES ('bbb', 'h1', 'image', 0), ('aaa', 'h1', 'image', 0)
                    """)
                try db.execute(sql: """
                    INSERT INTO paths (id, file_id, absolute_path, is_alive)
                    VALUES ('p1', 'bbb', '/a/gone1.jpg', 0), ('p2', 'aaa', '/a/gone2.jpg', 0)
                    """)
                try self.index(db, "/a/back.jpg", hash: "h1", now: 9)
                return try self.fileID(db, forPath: "/a/back.jpg")
            }
        }
        XCTAssertEqual(try run(), "aaa", "lowest id wins")
        XCTAssertEqual(try run(), try run(), "and does so every time")
    }

    /// A file that comes back at the same path is revived on its dead path,
    /// not forked into a second row.
    func testResurrectedPathReusesItsOwnRow() throws {
        let q = try freshQueue()
        try q.write { db in
            try index(db, "/a/x.png", hash: "h1")
            try db.execute(sql: "UPDATE paths SET is_alive = 0 WHERE absolute_path = '/a/x.png'")
            try index(db, "/a/x.png", hash: "h1", now: 9)
        }
        try q.read { db in
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM files"), 1)
            XCTAssertEqual(try Int.fetchOne(db, sql:
                "SELECT COUNT(*) FROM paths WHERE absolute_path = '/a/x.png' AND is_alive = 1"), 1)
        }
    }
}
