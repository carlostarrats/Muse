//
//  SmartCollectionsMigrationTests.swift
//  MuseTests
//
//  v12_smart_collections adds a nullable smart_rules column to collections;
//  existing rows default to NULL, and a JSON value round-trips.
//

import XCTest
import GRDB
@testable import Muse

final class SmartCollectionsMigrationTests: XCTestCase {

    private func makeQueue() throws -> DatabaseQueue {
        let q = try DatabaseQueue()
        try Database.makeMigrator().migrate(q)
        return q
    }

    func testMigrationAddsNullableSmartRulesColumn() throws {
        let q = try makeQueue()
        try q.write { db in
            try db.execute(sql: """
                INSERT INTO collections (id, name, is_hidden, model_version, created_at, updated_at, sort_order)
                VALUES ('c1', 'Plain', 0, 'manual', 0, 0, 0)
                """)
        }
        let row = try q.read { db in try CollectionRow.fetchOne(db, sql: "SELECT * FROM collections WHERE id = 'c1'") }
        XCTAssertNil(row?.smart_rules, "existing collections default to NULL smart_rules")
    }

    func testSmartRulesRoundTrips() throws {
        let q = try makeQueue()
        try q.write { db in
            try db.execute(sql: """
                INSERT INTO collections (id, name, is_hidden, model_version, created_at, updated_at, sort_order, smart_rules)
                VALUES ('c2', 'Smart', 0, 'manual', 0, 0, 0, ?)
                """, arguments: ["{\"match\":\"all\",\"rules\":[]}"])
        }
        let row = try q.read { db in try CollectionRow.fetchOne(db, sql: "SELECT * FROM collections WHERE id = 'c2'") }
        XCTAssertEqual(row?.smart_rules, "{\"match\":\"all\",\"rules\":[]}")
    }
}
