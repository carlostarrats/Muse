//
//  MetadataImportApplyTests.swift
//  MuseTests
//
//  The import's DB half: manual-tag insert-or-promote per (file_id,
//  parent_dir), rating presence check, unknown-path nil scope, and
//  idempotency (running the same import twice changes nothing — no UNIQUE
//  violation, no duplicate rows).
//

import XCTest
import GRDB
@testable import Muse

final class MetadataImportApplyTests: XCTestCase {

    private func migrated() throws -> DatabaseQueue {
        let q = try DatabaseQueue()
        try Database.makeMigrator().migrate(q)
        return q
    }

    private func seed(_ db: GRDB.Database) throws {
        try db.execute(sql: "INSERT INTO files (id, kind, last_seen_at) VALUES ('f1','image',0)")
        try db.execute(sql: "INSERT INTO paths (id, file_id, absolute_path, is_alive) VALUES ('p1','f1','/A/x.jpg',1)")
    }

    func testScopeResolvesAlivePathAndNilForUnknown() throws {
        let q = try migrated()
        try q.write { db in
            try seed(db)
            let scope = try MetadataImportApply.scope(db: db, absPath: "/A/x.jpg")
            XCTAssertEqual(scope?.fileID, "f1")
            XCTAssertEqual(scope?.dir, "/A")
            XCTAssertNil(try MetadataImportApply.scope(db: db, absPath: "/A/nope.jpg"))
        }
    }

    func testScopeIgnoresDeadPaths() throws {
        let q = try migrated()
        try q.write { db in
            try db.execute(sql: "INSERT INTO files (id, kind, last_seen_at) VALUES ('f1','image',0)")
            try db.execute(sql: "INSERT INTO paths (id, file_id, absolute_path, is_alive) VALUES ('p1','f1','/A/x.jpg',0)")
            XCTAssertNil(try MetadataImportApply.scope(db: db, absPath: "/A/x.jpg"))
        }
    }

    func testApplyKeywordsInsertsManualAndPromotesVision() throws {
        let q = try migrated()
        try q.write { db in
            try seed(db)
            // Existing vision tag with the same label → promoted to manual.
            try db.execute(sql: """
                INSERT INTO tags (id, file_id, parent_dir, label, source, confidence)
                VALUES ('t1','f1','/A','dog','vision',0.9)
                """)
            let scope = try MetadataImportApply.scope(db: db, absPath: "/A/x.jpg")!
            try MetadataImportApply.applyKeywords(db: db, scope: scope, labels: ["dog", "park"])
            let rows = try Row.fetchAll(db, sql:
                "SELECT label, source, confidence FROM tags WHERE file_id='f1' AND parent_dir='/A' ORDER BY label")
            XCTAssertEqual(rows.map { $0["label"] as String }, ["dog", "park"])
            XCTAssertEqual(rows.map { $0["source"] as String }, ["manual", "manual"])
            XCTAssertTrue(rows.allSatisfy { ($0["confidence"] as Double?) == nil })
        }
    }

    func testApplyKeywordsTwiceIsIdempotent() throws {
        let q = try migrated()
        try q.write { db in
            try seed(db)
            let scope = try MetadataImportApply.scope(db: db, absPath: "/A/x.jpg")!
            try MetadataImportApply.applyKeywords(db: db, scope: scope, labels: ["dog"])
            try MetadataImportApply.applyKeywords(db: db, scope: scope, labels: ["dog"])
            let count = try Int.fetchOne(db, sql:
                "SELECT COUNT(*) FROM tags WHERE file_id='f1' AND parent_dir='/A' AND label='dog'")
            XCTAssertEqual(count, 1)
        }
    }

    func testHasRatingSeesRatingGlyphRunsOnly() throws {
        let q = try migrated()
        try q.write { db in
            try seed(db)
            let scope = try MetadataImportApply.scope(db: db, absPath: "/A/x.jpg")!
            XCTAssertFalse(try MetadataImportApply.hasRating(db: db, scope: scope))
            try db.execute(sql: """
                INSERT INTO tags (id, file_id, parent_dir, label, source)
                VALUES ('t2','f1','/A','★★★','manual')
                """)
            XCTAssertTrue(try MetadataImportApply.hasRating(db: db, scope: scope))
        }
    }

    func testHasRatingIgnoresOrdinaryTags() throws {
        let q = try migrated()
        try q.write { db in
            try seed(db)
            try db.execute(sql: """
                INSERT INTO tags (id, file_id, parent_dir, label, source)
                VALUES ('t3','f1','/A','starfish','manual')
                """)
            let scope = try MetadataImportApply.scope(db: db, absPath: "/A/x.jpg")!
            XCTAssertFalse(try MetadataImportApply.hasRating(db: db, scope: scope))
        }
    }
}
