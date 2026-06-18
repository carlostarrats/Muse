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
