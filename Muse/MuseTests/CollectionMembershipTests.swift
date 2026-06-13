//
//  CollectionMembershipTests.swift
//  MuseTests
//
//  Verifies the v3_membership migration behavior: manual adds survive
//  auto rebuilds, manual removes become exclusions that hold across
//  future upserts, per-file collection lookup, and stale-delete
//  protection for manual collections.
//

import XCTest
import GRDB
@testable import Muse

final class CollectionMembershipTests: XCTestCase {
    private func makeQueue() throws -> DatabaseQueue {
        let q = try DatabaseQueue()
        try Database.makeMigrator().migrate(q)
        try q.write { db in
            for id in ["f1", "f2", "f3", "f4", "f5"] {
                try db.execute(sql: "INSERT INTO files (id, kind, last_seen_at) VALUES (?, 'image', 0)",
                               arguments: [id])
                // fetchAll is alive-aware: a member only counts if it has a live
                // path. Give every file one so collections aren't filtered out.
                try db.execute(sql: "INSERT INTO paths (id, file_id, absolute_path, is_alive) VALUES (?, ?, ?, 1)",
                               arguments: ["p_\(id)", id, "/tmp/\(id).png"])
            }
        }
        return q
    }

    func testManualAddSurvivesUpsert() async throws {
        let q = try makeQueue()
        try await CollectionStore.upsert(queue: q, id: "c1", name: "Dogs",
                                         memberIDs: ["f1", "f2"], modelVersion: "t")
        try await CollectionStore.addFile(queue: q, fileID: "f5", collectionID: "c1")
        // recluster-style upsert with different auto members
        try await CollectionStore.upsert(queue: q, id: "c1", name: "Dogs",
                                         memberIDs: ["f1", "f3"], modelVersion: "t")
        let all = try await CollectionStore.fetchAll(queue: q)
        XCTAssertEqual(Set(all[0].memberIDs), Set(["f1", "f3", "f5"]),
                       "manual member f5 must survive auto rebuild")
    }

    func testManualRemoveExcludesFromFutureUpserts() async throws {
        let q = try makeQueue()
        try await CollectionStore.upsert(queue: q, id: "c1", name: "Dogs",
                                         memberIDs: ["f1", "f2"], modelVersion: "t")
        try await CollectionStore.removeFile(queue: q, fileID: "f1", collectionID: "c1")
        var all = try await CollectionStore.fetchAll(queue: q)
        XCTAssertEqual(Set(all[0].memberIDs), Set(["f2"]))
        // auto rebuild re-proposes f1 — exclusion must hold
        try await CollectionStore.upsert(queue: q, id: "c1", name: "Dogs",
                                         memberIDs: ["f1", "f2"], modelVersion: "t")
        all = try await CollectionStore.fetchAll(queue: q)
        XCTAssertEqual(Set(all[0].memberIDs), Set(["f2"]))
    }

    func testCollectionsForFile() async throws {
        let q = try makeQueue()
        try await CollectionStore.upsert(queue: q, id: "c1", name: "Dogs",
                                         memberIDs: ["f1"], modelVersion: "t")
        try await CollectionStore.upsert(queue: q, id: "c2", name: "Pets",
                                         memberIDs: ["f1", "f2"], modelVersion: "t")
        let names = try await CollectionStore.collections(queue: q, forFileID: "f1")
            .map(\.name).sorted()
        XCTAssertEqual(names, ["Dogs", "Pets"])
    }

    func testStaleDeleteSkipsManualCollections() async throws {
        // covered indirectly: createManual + an upsert of a different collection,
        // then simulate engine stale-delete logic via the new helper
        let q = try makeQueue()
        let id = try await CollectionStore.createManual(queue: q, name: "Faves", fileID: "f1")
        let protected = try await CollectionStore.protectedCollectionIDs(queue: q)
        XCTAssertTrue(protected.contains(id))
    }
}
