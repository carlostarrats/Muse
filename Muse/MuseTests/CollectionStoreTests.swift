//
//  CollectionStoreTests.swift
//  MuseTests
//
//  CRUD coverage for CollectionStore: upsert/fetch, hide, member replacement.
//

import XCTest
import GRDB
@testable import Muse

final class CollectionStoreTests: XCTestCase {
    private func makeQueue() throws -> DatabaseQueue {
        let q = try DatabaseQueue()
        try Database.makeMigrator().migrate(q)
        try q.write { db in
            for id in ["f1", "f2", "f3", "f4"] {
                try db.execute(sql: "INSERT INTO files (id, kind, last_seen_at) VALUES (?, 'image', 0)",
                               arguments: [id])
            }
        }
        return q
    }

    func testUpsertAndFetch() async throws {
        let q = try makeQueue()
        try await CollectionStore.upsert(queue: q, id: "c1", name: "Dogs",
                                         memberIDs: ["f1", "f2"], modelVersion: "t")
        let all = try await CollectionStore.fetchAll(queue: q)
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all[0].collection.name, "Dogs")
        XCTAssertEqual(Set(all[0].memberIDs), Set(["f1", "f2"]))
    }

    func testHideExcludesFromFetch() async throws {
        let q = try makeQueue()
        try await CollectionStore.upsert(queue: q, id: "c1", name: "Dogs",
                                         memberIDs: ["f1"], modelVersion: "t")
        try await CollectionStore.setHidden(queue: q, id: "c1", hidden: true)
        let all = try await CollectionStore.fetchAll(queue: q)
        XCTAssertTrue(all.isEmpty)
    }

    func testUpsertReplacesMembers() async throws {
        let q = try makeQueue()
        try await CollectionStore.upsert(queue: q, id: "c1", name: "Dogs",
                                         memberIDs: ["f1", "f2"], modelVersion: "t")
        try await CollectionStore.upsert(queue: q, id: "c1", name: "Dogs",
                                         memberIDs: ["f3", "f4"], modelVersion: "t")
        let all = try await CollectionStore.fetchAll(queue: q)
        XCTAssertEqual(Set(all[0].memberIDs), Set(["f3", "f4"]))
    }
}
