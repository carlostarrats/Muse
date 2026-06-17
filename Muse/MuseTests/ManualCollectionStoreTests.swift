//
//  ManualCollectionStoreTests.swift
//  MuseTests
//
//  Hand-made collections at the store level: createManual auto-names and
//  marks them 'manual'; fetchAll keeps EMPTY manual collections visible (so a
//  fresh one can be populated) while still hiding empty AUTO collections; and
//  the durable delete (setHidden) removes them from fetchAll.
//

import XCTest
import GRDB
@testable import Muse

final class ManualCollectionStoreTests: XCTestCase {

    private func migrated() throws -> DatabaseQueue {
        let q = try DatabaseQueue()
        try Database.makeMigrator().migrate(q)
        return q
    }

    func testCreateManualAutoNamesAndMarksManual() async throws {
        let q = try migrated()
        let id1 = try await CollectionStore.createManual(queue: q)
        let id2 = try await CollectionStore.createManual(queue: q)

        try await q.read { db in
            let r1 = try CollectionRow.fetchOne(db, key: id1)
            XCTAssertEqual(r1?.name, "Collection 1")
            XCTAssertEqual(r1?.model_version, "manual")
            XCTAssertEqual(r1?.is_hidden, 0)
            let r2 = try CollectionRow.fetchOne(db, key: id2)
            XCTAssertEqual(r2?.name, "Collection 2")   // increments
        }
    }

    func testEmptyManualVisible_EmptyAutoHidden() async throws {
        let q = try migrated()
        let manualID = try await CollectionStore.createManual(queue: q)
        // An empty AUTO collection (no members, not manual).
        try await q.write { db in
            try db.execute(sql: """
                INSERT INTO collections (id, name, is_hidden, model_version, created_at, updated_at)
                VALUES ('auto1', 'Sunsets', 0, 'cluster-v1', 0, 0)
                """)
        }
        let loaded = try await CollectionStore.fetchAll(queue: q)
        let ids = Set(loaded.map { $0.collection.id })
        XCTAssertTrue(ids.contains(manualID))           // empty manual → shown
        XCTAssertFalse(ids.contains("auto1"))           // empty auto → hidden
    }

    func testDurableDeleteHidesManualCollection() async throws {
        let q = try migrated()
        let id = try await CollectionStore.createManual(queue: q)
        try await CollectionStore.setHidden(queue: q, id: id, hidden: true)
        let loaded = try await CollectionStore.fetchAll(queue: q)
        XCTAssertFalse(loaded.contains { $0.collection.id == id })   // gone from the UI
        // Row still exists (the "don't rebuild" tombstone), just hidden.
        try await q.read { db in
            XCTAssertNotNil(try CollectionRow.fetchOne(db, key: id))
        }
    }
}
