//
//  TagFolderScopeTests.swift
//  MuseTests
//
//  The per-folder tag behaviors that were the point of the de-welding:
//  a new duplicate inherits VISION (not manual) tags for its own folder, and
//  the manual-beats-vision merge (Q32) is scoped per (file_id, parent_dir).
//

import XCTest
import GRDB
@testable import Muse

final class TagFolderScopeTests: XCTestCase {

    private func migrated() throws -> DatabaseQueue {
        let q = try DatabaseQueue()
        try Database.makeMigrator().migrate(q)
        return q
    }

    // MARK: inheritVisionTags

    func testNewDuplicateInheritsVisionButNotManualTags() throws {
        let q = try migrated()
        try q.write { db in
            try db.execute(sql: "INSERT INTO files (id, kind, last_seen_at) VALUES ('f1','image',0)")
            try db.execute(sql: "INSERT INTO paths (id, file_id, absolute_path, is_alive) VALUES ('pA','f1','/A/x.jpg',1)")
            // /A has a vision tag and a manual tag.
            try db.execute(sql: "INSERT INTO tags (id, file_id, parent_dir, label, source, confidence) VALUES ('t1','f1','/A','dog','vision',0.9)")
            try db.execute(sql: "INSERT INTO tags (id, file_id, parent_dir, label, source) VALUES ('t2','f1','/A','favorite','manual')")

            // A duplicate appears in /B → it inherits vision tags only.
            try Indexer.inheritVisionTags(db: db, fileID: "f1", toDir: "/B")
        }
        try q.read { db in
            let bTags = try String.fetchAll(db, sql:
                "SELECT label FROM tags WHERE file_id='f1' AND parent_dir='/B' ORDER BY label")
            XCTAssertEqual(bTags, ["dog"])   // 'favorite' (manual) is NOT inherited
            let bSources = try String.fetchAll(db, sql:
                "SELECT source FROM tags WHERE file_id='f1' AND parent_dir='/B'")
            XCTAssertEqual(bSources, ["vision"])
        }
    }

    func testInheritIsIdempotentAndSkipsFoldersWithTags() throws {
        let q = try migrated()
        try q.write { db in
            try db.execute(sql: "INSERT INTO files (id, kind, last_seen_at) VALUES ('f1','image',0)")
            try db.execute(sql: "INSERT INTO tags (id, file_id, parent_dir, label, source, confidence) VALUES ('t1','f1','/A','dog','vision',0.9)")
            // /B already has a (manual) tag → inheritance must be a no-op there.
            try db.execute(sql: "INSERT INTO tags (id, file_id, parent_dir, label, source) VALUES ('t2','f1','/B','cat','manual')")

            try Indexer.inheritVisionTags(db: db, fileID: "f1", toDir: "/B")
            try Indexer.inheritVisionTags(db: db, fileID: "f1", toDir: "/B")   // twice
        }
        try q.read { db in
            let bTags = try String.fetchAll(db, sql:
                "SELECT label FROM tags WHERE file_id='f1' AND parent_dir='/B' ORDER BY label")
            XCTAssertEqual(bTags, ["cat"])   // untouched — not overwritten, not duplicated
        }
    }

    // MARK: unionTags (edit-in-place hash collision re-home)

    func testUnionTagsMergesPerFolderManualWins() throws {
        let q = try migrated()
        try q.write { db in
            try db.execute(sql: "INSERT INTO files (id, kind, last_seen_at) VALUES ('from','image',0)")
            try db.execute(sql: "INSERT INTO files (id, kind, last_seen_at) VALUES ('to','image',0)")
            // 'from' (the edited file's old row) carries a MANUAL 'blue' in /A.
            try db.execute(sql: "INSERT INTO tags (id, file_id, parent_dir, label, source) VALUES ('f1','from','/A','blue','manual')")
            // 'to' (the collided target) has a VISION 'blue' in /A and a vision 'sky' in /B.
            try db.execute(sql: "INSERT INTO tags (id, file_id, parent_dir, label, source, confidence) VALUES ('t1','to','/A','blue','vision',0.7)")
            try db.execute(sql: "INSERT INTO tags (id, file_id, parent_dir, label, source, confidence) VALUES ('t2','to','/B','sky','vision',0.8)")

            try Indexer.unionTags(db: db, fromFileID: "from", toFileID: "to")
        }
        try q.read { db in
            // 'from' rows are gone.
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM tags WHERE file_id='from'"), 0)
            // /A 'blue' was promoted to manual (manual beats vision, same scope).
            let blueSource = try String.fetchOne(db, sql:
                "SELECT source FROM tags WHERE file_id='to' AND parent_dir='/A' AND label='blue'")
            XCTAssertEqual(blueSource, "manual")
            // /B 'sky' untouched — different folder scope.
            XCTAssertEqual(try String.fetchOne(db, sql:
                "SELECT source FROM tags WHERE file_id='to' AND parent_dir='/B' AND label='sky'"), "vision")
        }
    }

    func testUnionTagsMovesScopeWhenNoConflict() throws {
        let q = try migrated()
        try q.write { db in
            try db.execute(sql: "INSERT INTO files (id, kind, last_seen_at) VALUES ('from','image',0)")
            try db.execute(sql: "INSERT INTO files (id, kind, last_seen_at) VALUES ('to','image',0)")
            try db.execute(sql: "INSERT INTO tags (id, file_id, parent_dir, label, source) VALUES ('f1','from','/A','unique','manual')")
            try Indexer.unionTags(db: db, fromFileID: "from", toFileID: "to")
        }
        try q.read { db in
            // The non-conflicting tag re-homes to 'to', keeping its /A scope.
            let dir = try String.fetchOne(db, sql:
                "SELECT parent_dir FROM tags WHERE file_id='to' AND label='unique'")
            XCTAssertEqual(dir, "/A")
        }
    }

    // MARK: rating exclusivity survives a tag merge

    func testUnionTagsCollapsesRatingToHighest() throws {
        let q = try migrated()
        try q.write { db in
            try db.execute(sql: "INSERT INTO files (id, kind, last_seen_at) VALUES ('from','image',0)")
            try db.execute(sql: "INSERT INTO files (id, kind, last_seen_at) VALUES ('to','image',0)")
            // Both scopes carry a DIFFERENT manual rating in /A. A rating is a
            // manual tag with a distinct label, so the exact-label conflict check
            // never fires — the union would keep both without the collapse.
            try db.execute(sql: "INSERT INTO tags (id, file_id, parent_dir, label, source) VALUES ('r1','from','/A','\u{2605}\u{2605}','manual')")
            try db.execute(sql: "INSERT INTO tags (id, file_id, parent_dir, label, source) VALUES ('r2','to','/A','\u{2605}\u{2605}\u{2605}\u{2605}','manual')")

            try Indexer.unionTags(db: db, fromFileID: "from", toFileID: "to")
        }
        try q.read { db in
            let ratings = try String.fetchAll(db, sql:
                "SELECT label FROM tags WHERE file_id='to' AND parent_dir='/A' ORDER BY label")
            // Exactly one rating survives, and it's the higher run.
            XCTAssertEqual(ratings, ["\u{2605}\u{2605}\u{2605}\u{2605}"])
        }
    }

    func testCollapseRatingsIsPerFolderAndLeavesNonRatings() throws {
        let q = try migrated()
        try q.write { db in
            try db.execute(sql: "INSERT INTO files (id, kind, last_seen_at) VALUES ('f','image',0)")
            // /A has two ratings + a real tag; /B has a single rating.
            try db.execute(sql: "INSERT INTO tags (id, file_id, parent_dir, label, source) VALUES ('a1','f','/A','\u{2605}','manual')")
            try db.execute(sql: "INSERT INTO tags (id, file_id, parent_dir, label, source) VALUES ('a2','f','/A','\u{2605}\u{2605}\u{2605}','manual')")
            try db.execute(sql: "INSERT INTO tags (id, file_id, parent_dir, label, source) VALUES ('a3','f','/A','dog','manual')")
            try db.execute(sql: "INSERT INTO tags (id, file_id, parent_dir, label, source) VALUES ('b1','f','/B','\u{2605}\u{2605}','manual')")

            try Indexer.collapseRatings(db: db, fileID: "f", parentDir: nil)
        }
        try q.read { db in
            // /A collapses to the highest rating, non-rating tag untouched.
            XCTAssertEqual(try String.fetchAll(db, sql:
                "SELECT label FROM tags WHERE file_id='f' AND parent_dir='/A' ORDER BY label"),
                ["dog", "\u{2605}\u{2605}\u{2605}"])
            // /B's lone rating is left alone.
            XCTAssertEqual(try String.fetchAll(db, sql:
                "SELECT label FROM tags WHERE file_id='f' AND parent_dir='/B'"),
                ["\u{2605}\u{2605}"])
        }
    }
}
