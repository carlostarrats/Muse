//
//  SchemaV2Tests.swift
//  MuseTests
//
//  Verifies the v2_intelligence migration: embeddings, collections,
//  collection_members tables plus provenance columns on tags/files.
//

import XCTest
import GRDB
@testable import Muse

final class SchemaV2Tests: XCTestCase {
    func testV2MigrationCreatesIntelligenceTables() throws {
        let q = try DatabaseQueue()          // in-memory
        try Database.makeMigrator().migrate(q)
        try q.read { db in
            XCTAssertTrue(try db.tableExists("embeddings"))
            XCTAssertTrue(try db.tableExists("collections"))
            XCTAssertTrue(try db.tableExists("collection_members"))
            let tagCols = try db.columns(in: "tags").map(\.name)
            XCTAssertTrue(tagCols.contains("model_version"))
            let fileCols = try db.columns(in: "files").map(\.name)
            XCTAssertTrue(fileCols.contains("palette"))
        }
    }

    func testEmbeddingRowRoundtrip() throws {
        let q = try DatabaseQueue()
        try Database.makeMigrator().migrate(q)
        try q.write { db in
            var f = FileRow(
                id: "f1",
                content_hash: nil,
                kind: "image",
                size_bytes: nil,
                width: nil,
                height: nil,
                duration_seconds: nil,
                created_at: nil,
                modified_at: nil,
                last_seen_at: 0,
                caption: nil,
                dominant_color: nil,
                feature_print: nil,
                palette: nil
            )
            try f.insert(db)
            var e = EmbeddingRow(file_id: "f1", vector: Data([1, 2, 3, 4]),
                                 model_version: "test-v1", updated_at: 0)
            try e.insert(db)
            let back = try EmbeddingRow.fetchOne(db, key: "f1")
            XCTAssertEqual(back?.vector, Data([1, 2, 3, 4]))
        }
    }

    func testUpgradeFromPopulatedV1() throws {
        let q = try DatabaseQueue()
        let migrator = Database.makeMigrator()
        try migrator.migrate(q, upTo: "v1_schema")
        try q.write { db in
            try db.execute(sql: "INSERT INTO files (id, kind, last_seen_at) VALUES ('old1', 'image', 0)")
            try db.execute(sql: """
                INSERT INTO tags (id, file_id, label, source, confidence)
                VALUES ('t1', 'old1', 'dog', 'vision', 0.9)
                """)
        }
        try migrator.migrate(q)   // up to v2
        try q.read { db in
            let f = try FileRow.fetchOne(db, key: "old1")
            XCTAssertNotNil(f)
            XCTAssertNil(f?.palette)
            let t = try TagRow.fetchOne(db, key: "t1")
            XCTAssertNotNil(t)
            XCTAssertNil(t?.model_version)
        }
    }

    func testCascadeDeletesEmbeddingAndMembership() throws {
        let q = try DatabaseQueue()
        try Database.makeMigrator().migrate(q)
        try q.write { db in
            try db.execute(sql: "INSERT INTO files (id, kind, last_seen_at) VALUES ('f1', 'image', 0)")
            var e = EmbeddingRow(file_id: "f1", vector: Data([9]), model_version: "t", updated_at: 0)
            try e.insert(db)
            var c = CollectionRow(id: "c1", name: "X", is_hidden: 0, model_version: "t",
                                  created_at: 0, updated_at: 0)
            try c.insert(db)
            var m = CollectionMemberRow(collection_id: "c1", file_id: "f1", added_by: "auto")
            try m.insert(db)
            try db.execute(sql: "DELETE FROM files WHERE id = 'f1'")
            XCTAssertEqual(try EmbeddingRow.fetchCount(db), 0)
            XCTAssertEqual(try CollectionMemberRow.fetchCount(db), 0)
        }
    }
}
