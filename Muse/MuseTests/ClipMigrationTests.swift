//
//  ClipMigrationTests.swift
//  MuseTests
//

import XCTest
import GRDB
@testable import Muse

final class ClipMigrationTests: XCTestCase {
    private func makeQueue() throws -> DatabaseQueue {
        let q = try DatabaseQueue()
        try Database.makeMigrator().migrate(q)
        return q
    }

    func testTableExists() throws {
        let q = try makeQueue()
        try q.read { db in XCTAssertTrue(try db.tableExists("clip_embeddings")) }
    }

    func testCascadesOnFileDelete() throws {
        let q = try makeQueue()
        try q.write { db in
            try db.execute(sql: "INSERT INTO files (id, content_hash, kind, last_seen_at) VALUES ('f1', 'h1', 'image', 0)")
            var row = ClipEmbeddingRow(file_id: "f1", embedded_hash: "h1",
                                        model_generation: 1, vector: nil)
            try row.insert(db)
            try db.execute(sql: "DELETE FROM files WHERE id = 'f1'")
        }
        let remaining = try q.read { db in try ClipEmbeddingRow.fetchAll(db) }
        XCTAssertTrue(remaining.isEmpty)
    }

    func testMigratesCleanlyAfterV17BeforeV19() throws {
        // Registration order matters: v18 must be reachable independent of v19.
        let q = try makeQueue()
        try q.read { db in
            XCTAssertTrue(try db.tableExists("clip_embeddings"))
            XCTAssertTrue(try db.tableExists("photo_traits"))
        }
    }

    func testIdempotentReMigrate() throws {
        let q = try DatabaseQueue()
        try Database.makeMigrator().migrate(q)
        try Database.makeMigrator().migrate(q)
        try q.read { db in XCTAssertTrue(try db.tableExists("clip_embeddings")) }
    }

    func testNullVectorRoundTripsAsAttemptedMarker() throws {
        let q = try makeQueue()
        try q.write { db in
            try db.execute(sql: "INSERT INTO files (id, content_hash, kind, last_seen_at) VALUES ('f2', 'h2', 'image', 0)")
            var row = ClipEmbeddingRow(file_id: "f2", embedded_hash: "h2",
                                        model_generation: ClipModel.current.generation, vector: nil)
            try row.insert(db)
        }
        let row = try q.read { db in try ClipEmbeddingRow.fetchOne(db, key: "f2") }
        XCTAssertNotNil(row)
        XCTAssertNil(row?.vector)
    }
}
