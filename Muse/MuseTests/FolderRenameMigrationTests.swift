//
//  FolderRenameMigrationTests.swift
//  MuseTests
//
//  The pure path-prefix rewrite used by a folder rename.
//

import XCTest
import GRDB
@testable import Muse

final class FolderRenameMigrationTests: XCTestCase {
    func testExactFolderMatchRewrites() {
        // tags.parent_dir of a file directly in the renamed folder.
        XCTAssertEqual(
            FolderRenameMigration.rewrite(path: "/a/Old", old: "/a/Old", new: "/a/New"),
            "/a/New")
    }
    func testNestedChildRewrites() {
        XCTAssertEqual(
            FolderRenameMigration.rewrite(path: "/a/Old/sub/p.png", old: "/a/Old", new: "/a/New"),
            "/a/New/sub/p.png")
    }
    func testSiblingPrefixIsNotMatched() {
        // "/a/Old" must not catch "/a/OldStuff".
        XCTAssertNil(
            FolderRenameMigration.rewrite(path: "/a/OldStuff/p.png", old: "/a/Old", new: "/a/New"))
    }
    func testUnrelatedPathIsNil() {
        XCTAssertNil(
            FolderRenameMigration.rewrite(path: "/b/x.png", old: "/a/Old", new: "/a/New"))
    }
    func testPathWithSqlWildcardsRewrites() {
        XCTAssertEqual(
            FolderRenameMigration.rewrite(path: "/a/Old/100%_off/p_1.png", old: "/a/Old", new: "/a/New"),
            "/a/New/100%_off/p_1.png")
    }
}

/// Exercises the ACTUAL SQL in `FolderRenameMigration.apply` against a real
/// (in-memory) GRDB database — the pure `rewrite` above mirrors the rule, but
/// this is the data-mutating code path that could corrupt rows.
final class FolderRenameMigrationSQLTests: XCTestCase {

    private func freshQueue() throws -> DatabaseQueue {
        let q = try DatabaseQueue()
        try Database.makeMigrator().migrate(q)
        return q
    }

    func testApplyRewritesPathsTagsStarredAndSpan() throws {
        let q = try freshQueue()
        try q.write { db in
            // A file under the renamed folder, and a SIBLING under "/a/OldStuff".
            try db.execute(sql: "INSERT INTO files (id, content_hash, kind, last_seen_at) VALUES ('f1','h1','image',0)")
            try db.execute(sql: "INSERT INTO paths (id, file_id, absolute_path, is_alive) VALUES ('p1','f1','/a/Old/x.png',1)")
            try db.execute(sql: "INSERT INTO files (id, content_hash, kind, last_seen_at) VALUES ('f2','h2','image',0)")
            try db.execute(sql: "INSERT INTO paths (id, file_id, absolute_path, is_alive) VALUES ('p2','f2','/a/OldStuff/y.png',1)")

            try db.execute(sql: "INSERT INTO tags (id, file_id, label, source, confidence, parent_dir) VALUES ('t1','f1','blue','manual',NULL,'/a/Old')")
            try db.execute(sql: "INSERT INTO tags (id, file_id, label, source, confidence, parent_dir) VALUES ('t2','f2','red','manual',NULL,'/a/OldStuff')")

            // Pins: the renamed folder itself, a nested pin, and a sibling.
            try db.execute(sql: "INSERT INTO starred_folders (id, absolute_path, display_name, added_at) VALUES ('s1','/a/Old','Old',0)")
            try db.execute(sql: "INSERT INTO starred_folders (id, absolute_path, display_name, added_at) VALUES ('s2','/a/Old/sub','sub',0)")
            try db.execute(sql: "INSERT INTO starred_folders (id, absolute_path, display_name, added_at) VALUES ('s3','/a/OldStuff','OldStuff',0)")

            try FolderRenameMigration.apply(db, old: "/a/Old", new: "/a/New", newName: "New")
        }
        try q.read { db in
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT absolute_path FROM paths WHERE id='p1'"), "/a/New/x.png")
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT absolute_path FROM paths WHERE id='p2'"), "/a/OldStuff/y.png")  // sibling untouched
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT parent_dir FROM tags WHERE id='t1'"), "/a/New")
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT parent_dir FROM tags WHERE id='t2'"), "/a/OldStuff")  // sibling untouched
            // Renamed folder's own pin: path AND label updated.
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT absolute_path FROM starred_folders WHERE id='s1'"), "/a/New")
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT display_name FROM starred_folders WHERE id='s1'"), "New")
            // Nested pin: path updated, label kept.
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT absolute_path FROM starred_folders WHERE id='s2'"), "/a/New/sub")
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT display_name FROM starred_folders WHERE id='s2'"), "sub")
            // Sibling pin untouched.
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT absolute_path FROM starred_folders WHERE id='s3'"), "/a/OldStuff")
        }
    }

    func testApplyClearsStaleTargetPinAndStillMigrates() throws {
        // A stale pin sitting at the rename TARGET must not roll back the
        // legitimate paths/tags migration via the shared transaction.
        let q = try freshQueue()
        try q.write { db in
            try db.execute(sql: "INSERT INTO files (id, content_hash, kind, last_seen_at) VALUES ('f1','h1','image',0)")
            try db.execute(sql: "INSERT INTO paths (id, file_id, absolute_path, is_alive) VALUES ('p1','f1','/a/Old/x.png',1)")
            try db.execute(sql: "INSERT INTO tags (id, file_id, label, source, confidence, parent_dir) VALUES ('t1','f1','blue','manual',NULL,'/a/Old')")
            // stale pin already at the destination, plus the live source pin
            try db.execute(sql: "INSERT INTO starred_folders (id, absolute_path, display_name, added_at) VALUES ('stale','/a/New','New',0)")
            try db.execute(sql: "INSERT INTO starred_folders (id, absolute_path, display_name, added_at) VALUES ('s1','/a/Old','Old',0)")

            try FolderRenameMigration.apply(db, old: "/a/Old", new: "/a/New", newName: "New")
        }
        try q.read { db in
            // paths + tags migrated (transaction did NOT roll back)
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT absolute_path FROM paths WHERE id='p1'"), "/a/New/x.png")
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT parent_dir FROM tags WHERE id='t1'"), "/a/New")
            // exactly one pin at /a/New — the migrated source pin; the stale one cleared
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM starred_folders WHERE absolute_path='/a/New'"), 1)
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT id FROM starred_folders WHERE absolute_path='/a/New'"), "s1")
        }
    }

    func testApplyClearsStaleTargetTagAndStillMigrates() throws {
        // A previously-deleted folder that occupied the rename TARGET can leave a
        // durable tag row there (PathReconciler marks paths dead but tags survive).
        // The tags rewrite would then hit UNIQUE(file_id, parent_dir, label) and
        // roll back the WHOLE transaction (disk renamed, DB reverted). The
        // destination pre-clear must drop the stale tag so the rename completes.
        let q = try freshQueue()
        try q.write { db in
            try db.execute(sql: "INSERT INTO files (id, content_hash, kind, last_seen_at) VALUES ('f1','h1','image',0)")
            try db.execute(sql: "INSERT INTO paths (id, file_id, absolute_path, is_alive) VALUES ('p1','f1','/a/Old/x.png',1)")
            // The source tag we expect to migrate to /a/New …
            try db.execute(sql: "INSERT INTO tags (id, file_id, label, source, confidence, parent_dir) VALUES ('t1','f1','blue','manual',NULL,'/a/Old')")
            // … and a STALE tag for the same (file_id, label) already at /a/New —
            // would collide on rewrite without the pre-clear.
            try db.execute(sql: "INSERT INTO tags (id, file_id, label, source, confidence, parent_dir) VALUES ('stale','f1','blue','vision',0.9,'/a/New')")

            // Must NOT throw (no UNIQUE rollback).
            try FolderRenameMigration.apply(db, old: "/a/Old", new: "/a/New", newName: "New")
        }
        try q.read { db in
            // paths migrated (transaction committed)
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT absolute_path FROM paths WHERE id='p1'"), "/a/New/x.png")
            // exactly one (f1,'/a/New','blue') tag — the migrated source row; the stale one cleared
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM tags WHERE file_id='f1' AND parent_dir='/a/New' AND label='blue'"), 1)
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT id FROM tags WHERE file_id='f1' AND parent_dir='/a/New' AND label='blue'"), "t1")
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT source FROM tags WHERE file_id='f1' AND parent_dir='/a/New' AND label='blue'"), "manual")
        }
    }

    func testApplyCaseOnlyRenameMigratesSourceRows() throws {
        // A case-only rename (/a/Photos → /a/photos) on a case-insensitive
        // volume: the binary pre-clear must NOT touch the source rows, and the
        // rewrites must re-key them to the new case.
        let q = try freshQueue()
        try q.write { db in
            try db.execute(sql: "INSERT INTO files (id, content_hash, kind, last_seen_at) VALUES ('f1','h1','image',0)")
            try db.execute(sql: "INSERT INTO paths (id, file_id, absolute_path, is_alive) VALUES ('p1','f1','/a/Photos/x.png',1)")
            try db.execute(sql: "INSERT INTO tags (id, file_id, label, source, confidence, parent_dir) VALUES ('t1','f1','blue','manual',NULL,'/a/Photos')")
            try db.execute(sql: "INSERT INTO starred_folders (id, absolute_path, display_name, added_at) VALUES ('s1','/a/Photos','Photos',0)")

            try FolderRenameMigration.apply(db, old: "/a/Photos", new: "/a/photos", newName: "photos")
        }
        try q.read { db in
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT absolute_path FROM paths WHERE id='p1'"), "/a/photos/x.png")
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT is_alive FROM paths WHERE id='p1'"), 1)  // not deactivated
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT parent_dir FROM tags WHERE id='t1'"), "/a/photos")
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT absolute_path FROM starred_folders WHERE id='s1'"), "/a/photos")
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT display_name FROM starred_folders WHERE id='s1'"), "photos")
        }
    }

    func testApplyHandlesSqlWildcardsInPath() throws {
        let q = try freshQueue()
        try q.write { db in
            try db.execute(sql: "INSERT INTO files (id, content_hash, kind, last_seen_at) VALUES ('f1','h1','image',0)")
            try db.execute(sql: "INSERT INTO paths (id, file_id, absolute_path, is_alive) VALUES ('p1','f1','/a/Old/100%_off/p_1.png',1)")
            try FolderRenameMigration.apply(db, old: "/a/Old", new: "/a/New", newName: "New")
        }
        try q.read { db in
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT absolute_path FROM paths WHERE id='p1'"), "/a/New/100%_off/p_1.png")
        }
    }
}
