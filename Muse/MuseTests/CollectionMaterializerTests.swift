//
//  CollectionMaterializerTests.swift
//  MuseTests
//

import XCTest
@testable import Muse

final class CollectionMaterializerTests: XCTestCase {
    private func coll(_ id: String, _ model: String, members: [String], cover: String? = nil)
        -> BackupCollection {
        BackupCollection(id: id, name: id, sort_order: 0, model_version: model,
                         is_hidden: 0, cover_hash: cover,
                         members: members.map { BackupMember(content_hash: $0, added_by: "auto") },
                         excluded_hashes: [])
    }

    func testAutoEmptyCollectionDropped() {
        let result = CollectionMaterializer.materialize(
            [coll("c1", "v1", members: ["h_missing"])],
            fileIDForHash: [:])
        XCTAssertTrue(result.isEmpty)
    }

    func testManualEmptyCollectionPreserved() {
        let result = CollectionMaterializer.materialize(
            [coll("c1", "manual", members: [])],
            fileIDForHash: [:])
        XCTAssertEqual(result.count, 1)
        XCTAssertTrue(result[0].memberFileIDs.isEmpty)
    }

    func testHiddenEmptyAutoCollectionPreservedAsTombstone() {
        // A user-deleted auto collection (is_hidden=1) with no reconnected members
        // must survive so re-clustering can't resurrect it under its stable id.
        let c = BackupCollection(id: "c1", name: "c1", sort_order: 0, model_version: "v1",
                                 is_hidden: 1, cover_hash: nil, members: [], excluded_hashes: [])
        let result = CollectionMaterializer.materialize([c], fileIDForHash: [:])
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].isHidden, 1)
        XCTAssertTrue(result[0].memberFileIDs.isEmpty)
    }

    func testPartialCollectionKeepsOnlyReconnectedMembers() {
        let result = CollectionMaterializer.materialize(
            [coll("c1", "v1", members: ["h1", "h2", "h3"], cover: "h2")],
            fileIDForHash: ["h1": "f1", "h3": "f3"])
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].memberFileIDs.map(\.fileID).sorted(), ["f1", "f3"])
        XCTAssertNil(result[0].coverFileID)
    }
}
