//
//  CollectionReorderStoreTests.swift
//  MuseTests
//

import XCTest
import GRDB
@testable import Muse

final class CollectionReorderStoreTests: XCTestCase {
    private func makeDB() throws -> DatabaseQueue {
        let q = try DatabaseQueue()
        try Database.makeMigrator().migrate(q)
        return q
    }

    func testNewManualCollectionAppendsAtBottom() async throws {
        let q = try makeDB()
        try await q.write { db in
            try db.execute(sql: """
                INSERT INTO collections (id, name, is_hidden, model_version, created_at, updated_at, sort_order)
                VALUES ('x', 'X', 0, 'manual', 1, 1, 0)
                """)
        }
        let newID = try await CollectionStore.createManual(queue: q)
        let order = try await q.read { db in
            try Int.fetchOne(db, sql: "SELECT sort_order FROM collections WHERE id = ?",
                             arguments: [newID])
        }
        XCTAssertEqual(order, 1)        // max(0)+1
    }

    func testPersistOrderWritesPositions() async throws {
        let q = try makeDB()
        try await q.write { db in
            for (id, order) in [("a", 0), ("b", 1), ("c", 2)] {
                try db.execute(sql: """
                    INSERT INTO collections (id, name, is_hidden, model_version, created_at, updated_at, sort_order)
                    VALUES (?, ?, 0, 'manual', 1, 1, ?)
                    """, arguments: [id, id, order])
            }
        }
        try await CollectionStore.persistOrder(queue: q, orderedIDs: ["c", "a", "b"])
        let rows = try await q.read { db in
            try Row.fetchAll(db, sql: "SELECT id, sort_order FROM collections ORDER BY sort_order")
                .map { ($0["id"] as String, $0["sort_order"] as Int) }
        }
        XCTAssertEqual(rows.map(\.0), ["c", "a", "b"])
        XCTAssertEqual(rows.map(\.1), [0, 1, 2])
    }
}
