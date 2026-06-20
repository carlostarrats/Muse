//
//  CollectionSortOrderMigrationTests.swift
//  MuseTests
//

import XCTest
import GRDB
@testable import Muse

final class CollectionSortOrderMigrationTests: XCTestCase {
    func testBackfillAssignsAscendingByCreatedThenName() throws {
        let queue = try DatabaseQueue()                 // in-memory
        try Database.makeMigrator().migrate(queue)      // runs v1…v8

        try queue.write { db in
            // Insert three rows out of order; created_at drives the order.
            for (id, name, created) in [("c", "Gamma", 30), ("a", "Alpha", 10), ("b", "Beta", 20)] {
                try db.execute(sql: """
                    INSERT INTO collections (id, name, is_hidden, model_version, created_at, updated_at, sort_order)
                    VALUES (?, ?, 0, 'manual', ?, ?, 0)
                    """, arguments: [id, name, created, created])
            }
        }

        // Re-run the back-fill helper deterministically.
        try queue.write { db in try Database.backfillCollectionSortOrder(db) }

        let order = try queue.read { db in
            try String.fetchAll(db, sql: "SELECT id FROM collections ORDER BY sort_order ASC")
        }
        XCTAssertEqual(order, ["a", "b", "c"])
    }
}
