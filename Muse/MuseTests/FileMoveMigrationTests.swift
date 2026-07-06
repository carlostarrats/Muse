//
//  FileMoveMigrationTests.swift
//  MuseTests
//
//  DB follow-through for an in-app move: the alive path row repoints and the
//  location's tags — MANUAL included — follow the file (unlike an external
//  move, where the indexer can only inherit vision tags). Copy-vs-move by the
//  same same-dir-sibling rule as the Indexer's split/collision branches.
//

import XCTest
import GRDB
@testable import Muse

final class FileMoveMigrationTests: XCTestCase {

    private func freshQueue() throws -> DatabaseQueue {
        let q = try DatabaseQueue()
        try Database.makeMigrator().migrate(q)
        return q
    }

    func testMoveRepointsPathAndCarriesManualTags() throws {
        let q = try freshQueue()
        try q.write { db in
            try db.execute(sql: "INSERT INTO files (id, content_hash, kind, last_seen_at) VALUES ('f1','h1','image',0)")
            try db.execute(sql: "INSERT INTO paths (id, file_id, absolute_path, is_alive) VALUES ('p1','f1','/a/x.png',1)")
            try db.execute(sql: "INSERT INTO tags (id, file_id, label, source, confidence, parent_dir) VALUES ('t1','f1','blue','manual',NULL,'/a')")
            try db.execute(sql: "INSERT INTO tags (id, file_id, label, source, confidence, parent_dir) VALUES ('t2','f1','sea','vision',0.9,'/a')")

            try FileMoveMigration.apply(db, moves: [(from: "/a/x.png", to: "/b/x.png")])
        }
        try q.read { db in
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT absolute_path FROM paths WHERE id='p1'"), "/b/x.png")
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM tags WHERE file_id='f1' AND parent_dir='/b' AND label='blue' AND source='manual'"), 1)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM tags WHERE file_id='f1' AND parent_dir='/b' AND label='sea'"), 1)
            // MOVED, not copied — no sibling remained in /a to surface them.
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM tags WHERE parent_dir='/a'"), 0)
        }
    }

    func testMoveCopiesTagsWhenSiblingStaysInSourceFolder() throws {
        let q = try freshQueue()
        try q.write { db in
            // Byte-identical sibling stays behind in /a — the (f1, /a) tag rows
            // are shared with it, so the move must COPY, not strip it.
            try db.execute(sql: "INSERT INTO files (id, content_hash, kind, last_seen_at) VALUES ('f1','h1','image',0)")
            try db.execute(sql: "INSERT INTO paths (id, file_id, absolute_path, is_alive) VALUES ('p1','f1','/a/x.png',1)")
            try db.execute(sql: "INSERT INTO paths (id, file_id, absolute_path, is_alive) VALUES ('p2','f1','/a/y.png',1)")
            try db.execute(sql: "INSERT INTO tags (id, file_id, label, source, confidence, parent_dir) VALUES ('t1','f1','blue','manual',NULL,'/a')")

            try FileMoveMigration.apply(db, moves: [(from: "/a/x.png", to: "/b/x.png")])
        }
        try q.read { db in
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM tags WHERE file_id='f1' AND parent_dir='/b' AND label='blue'"), 1)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM tags WHERE file_id='f1' AND parent_dir='/a' AND label='blue'"), 1,
                           "the staying sibling keeps its tag")
        }
    }

    func testMoveMergesWithDestinationTagsManualWins() throws {
        let q = try freshQueue()
        try q.write { db in
            // A byte-identical copy already lives in /b with a VISION 'blue';
            // the moved file carries a MANUAL 'blue' — the survivor must be
            // manual (Q32), and no UNIQUE violation may abort the move.
            try db.execute(sql: "INSERT INTO files (id, content_hash, kind, last_seen_at) VALUES ('f1','h1','image',0)")
            try db.execute(sql: "INSERT INTO paths (id, file_id, absolute_path, is_alive) VALUES ('p1','f1','/a/x.png',1)")
            try db.execute(sql: "INSERT INTO paths (id, file_id, absolute_path, is_alive) VALUES ('p2','f1','/b/x2.png',1)")
            try db.execute(sql: "INSERT INTO tags (id, file_id, label, source, confidence, parent_dir) VALUES ('tA','f1','blue','manual',NULL,'/a')")
            try db.execute(sql: "INSERT INTO tags (id, file_id, label, source, confidence, parent_dir) VALUES ('tB','f1','blue','vision',0.8,'/b')")

            try FileMoveMigration.apply(db, moves: [(from: "/a/x.png", to: "/b/x.png")])
        }
        try q.read { db in
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM tags WHERE file_id='f1' AND parent_dir='/b' AND label='blue'"), 1)
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT source FROM tags WHERE file_id='f1' AND parent_dir='/b' AND label='blue'"), "manual")
        }
    }

    func testMoveKillsStaleAliveRowAtDestination() throws {
        let q = try freshQueue()
        try q.write { db in
            // A stale ALIVE row occupies the destination path (its file was
            // deleted outside Muse); the repoint must not trip
            // paths_alive_unique and roll the transaction back.
            try db.execute(sql: "INSERT INTO files (id, content_hash, kind, last_seen_at) VALUES ('f1','h1','image',0)")
            try db.execute(sql: "INSERT INTO files (id, content_hash, kind, last_seen_at) VALUES ('f2','h2','image',0)")
            try db.execute(sql: "INSERT INTO paths (id, file_id, absolute_path, is_alive) VALUES ('p1','f1','/a/x.png',1)")
            try db.execute(sql: "INSERT INTO paths (id, file_id, absolute_path, is_alive) VALUES ('p2','f2','/b/x.png',1)")

            try FileMoveMigration.apply(db, moves: [(from: "/a/x.png", to: "/b/x.png")])
        }
        try q.read { db in
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT absolute_path FROM paths WHERE id='p1'"), "/b/x.png")
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT is_alive FROM paths WHERE id='p2'"), 0)
        }
    }

    func testSameDirRenameRepointsPathAndKeepsTagsInPlace() throws {
        let q = try freshQueue()
        try q.write { db in
            try db.execute(sql: "INSERT INTO files (id, content_hash, kind, last_seen_at) VALUES ('f1','h1','image',0)")
            try db.execute(sql: "INSERT INTO paths (id, file_id, absolute_path, is_alive) VALUES ('p1','f1','/a/old.png',1)")
            try db.execute(sql: "INSERT INTO tags (id, file_id, label, source, confidence, parent_dir) VALUES ('t1','f1','blue','manual',NULL,'/a')")

            // A rename is a move whose destination dir equals the source dir.
            try FileMoveMigration.apply(db, moves: [(from: "/a/old.png", to: "/a/new.png")])
        }
        try q.read { db in
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT absolute_path FROM paths WHERE id='p1'"), "/a/new.png")
            // Same parent dir -> the tag row is untouched (not duplicated, not moved).
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM tags WHERE file_id='f1' AND parent_dir='/a' AND label='blue' AND source='manual'"), 1)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM tags WHERE file_id='f1'"), 1)
        }
    }

    func testUnindexedFileIsSkipped() throws {
        let q = try freshQueue()
        try q.write { db in
            // No DB row for the source — apply must be a clean no-op.
            try FileMoveMigration.apply(db, moves: [(from: "/a/new.png", to: "/b/new.png")])
        }
        try q.read { db in
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM paths"), 0)
        }
    }
}
