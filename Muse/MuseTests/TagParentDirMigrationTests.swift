//
//  TagParentDirMigrationTests.swift
//  MuseTests
//
//  Verifies v7_tag_parent_dir: tags gain a parent_dir, existing tags fan out
//  across the distinct alive parent folders of their file_id (so nothing
//  currently visible is lost), and uniqueness becomes (file_id, parent_dir,
//  label) so the same label can exist independently in two folders.
//

import XCTest
import GRDB
@testable import Muse

final class TagParentDirMigrationTests: XCTestCase {

    /// Migrate to v6, populate a welded duplicate (one file_id at two paths in
    /// two folders) with a single shared tag, then migrate to v7.
    private func migratedQueue() throws -> DatabaseQueue {
        let q = try DatabaseQueue()
        let migrator = Database.makeMigrator()
        try migrator.migrate(q, upTo: "v6_collection_cover")
        try q.write { db in
            // f1: byte-identical duplicate living in /A and /B.
            try db.execute(sql: "INSERT INTO files (id, content_hash, kind, last_seen_at) VALUES ('f1','h1','image',0)")
            try db.execute(sql: "INSERT INTO paths (id, file_id, absolute_path, is_alive) VALUES ('p1','f1','/A/x.png',1)")
            try db.execute(sql: "INSERT INTO paths (id, file_id, absolute_path, is_alive) VALUES ('p2','f1','/B/x.png',1)")
            try db.execute(sql: "INSERT INTO tags (id, file_id, label, source, confidence) VALUES ('t1','f1','blue','vision',0.9)")

            // f2: single folder /A.
            try db.execute(sql: "INSERT INTO files (id, content_hash, kind, last_seen_at) VALUES ('f2','h2','image',0)")
            try db.execute(sql: "INSERT INTO paths (id, file_id, absolute_path, is_alive) VALUES ('p3','f2','/A/y.png',1)")
            try db.execute(sql: "INSERT INTO tags (id, file_id, label, source, confidence) VALUES ('t2','f2','red','manual',NULL)")

            // f3: tag but NO alive path (orphan) → NULL scope, preserved.
            try db.execute(sql: "INSERT INTO files (id, content_hash, kind, last_seen_at) VALUES ('f3','h3','image',0)")
            try db.execute(sql: "INSERT INTO tags (id, file_id, label, source, confidence) VALUES ('t3','f3','green','vision',0.5)")
        }
        try migrator.migrate(q)   // up to v7
        return q
    }

    func testTagsTableGainsParentDir() throws {
        let q = try migratedQueue()
        try q.read { db in
            XCTAssertTrue(try db.columns(in: "tags").map(\.name).contains("parent_dir"))
        }
    }

    func testWeldedTagFansOutAcrossBothFolders() throws {
        let q = try migratedQueue()
        try q.read { db in
            let dirs = try String.fetchAll(db, sql:
                "SELECT parent_dir FROM tags WHERE file_id='f1' AND label='blue' ORDER BY parent_dir")
            XCTAssertEqual(dirs, ["/A", "/B"])   // the duplicate now carries its own copy
        }
    }

    func testSingleFolderTagGetsItsFolder() throws {
        let q = try migratedQueue()
        try q.read { db in
            let dirs = try String.fetchAll(db, sql:
                "SELECT parent_dir FROM tags WHERE file_id='f2'")
            XCTAssertEqual(dirs, ["/A"])
        }
    }

    func testOrphanTagKeptWithNullScope() throws {
        let q = try migratedQueue()
        try q.read { db in
            let rows = try Row.fetchAll(db, sql:
                "SELECT parent_dir FROM tags WHERE file_id='f3'")
            XCTAssertEqual(rows.count, 1)
            XCTAssertNil(rows[0]["parent_dir"] as String?)
        }
    }

    func testNoTagsLostInMigration() throws {
        let q = try migratedQueue()
        try q.read { db in
            // 1 welded (→2) + 1 single (→1) + 1 orphan (→1) = 4 rows.
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM tags"), 4)
        }
    }

    func testSameLabelIndependentPerFolder() throws {
        let q = try migratedQueue()
        // Deleting 'blue' in /A must NOT touch /B (independent rows now).
        try q.write { db in
            try db.execute(sql: "DELETE FROM tags WHERE file_id='f1' AND parent_dir='/A' AND label='blue'")
        }
        try q.read { db in
            let dirs = try String.fetchAll(db, sql:
                "SELECT parent_dir FROM tags WHERE file_id='f1' AND label='blue'")
            XCTAssertEqual(dirs, ["/B"])
        }
    }

    func testUniqueConstraintIsPerFolder() throws {
        let q = try migratedQueue()
        try q.write { db in
            // Same (file_id, parent_dir, label) is a duplicate → must fail.
            XCTAssertThrowsError(try db.execute(sql:
                "INSERT INTO tags (id, file_id, parent_dir, label, source) VALUES ('dup','f1','/A','blue','vision')"))
            // Same label, DIFFERENT folder → allowed.
            XCTAssertNoThrow(try db.execute(sql:
                "INSERT INTO tags (id, file_id, parent_dir, label, source) VALUES ('ok','f2','/C','blue','vision')"))
        }
    }
}
