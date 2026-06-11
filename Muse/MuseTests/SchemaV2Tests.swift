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
}
