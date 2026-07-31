//
//  PhotoSearchSimilarTests.swift
//  MuseTests
//

import XCTest
import GRDB
@testable import Muse

final class SimilarityRegistryTests: XCTestCase {
    func testStashReturnsDistinctHandles() {
        let registry = SimilarityRegistry()
        let h1 = registry.stash(vector: [1, 0], label: "photo")
        let h2 = registry.stash(vector: [0, 1], label: "region")
        XCTAssertNotEqual(h1, h2)
        XCTAssertTrue(h1.hasPrefix("s"))
        XCTAssertTrue(h2.hasPrefix("s"))
    }

    func testEntryLookupRoundTrips() {
        let registry = SimilarityRegistry()
        let handle = registry.stash(vector: [1, 0, 0], label: "region")
        let entry = registry.entry(for: handle)
        XCTAssertEqual(entry?.vector, [1, 0, 0])
        XCTAssertEqual(entry?.label, "region")
    }

    func testUnknownHandleReturnsNil() {
        XCTAssertNil(SimilarityRegistry().entry(for: "s999"))
    }

    func testSnapshotReflectsAllStashedEntries() {
        let registry = SimilarityRegistry()
        let h1 = registry.stash(vector: [1, 0], label: "a")
        let h2 = registry.stash(vector: [0, 1], label: "b")
        let snapshot = registry.snapshot
        XCTAssertEqual(snapshot[h1], [1, 0])
        XCTAssertEqual(snapshot[h2], [0, 1])
    }
}

final class PhotoSearchSimilarTests: XCTestCase {

    private func makeQueue() throws -> DatabaseQueue {
        let q = try DatabaseQueue()
        try Database.makeMigrator().migrate(q)
        return q
    }

    private func insertVector(_ db: GRDB.Database, id: String, vector: [Float]) throws {
        try db.execute(sql: "INSERT INTO files (id, content_hash, kind, last_seen_at) VALUES (?, ?, 'image', 0)",
                        arguments: [id, id + "-hash"])
        var row = ClipEmbeddingRow(file_id: id, embedded_hash: id + "-hash",
                                    model_generation: ClipModel.current.generation,
                                    vector: ClipVectors.toData(vector))
        try row.insert(db)
    }

    func testSimilarityOrderingWinsWhenTokenPresent() throws {
        let q = try makeQueue()
        try q.write { db in
            try insertVector(db, id: "closest", vector: [1, 0, 0])
            try insertVector(db, id: "farther", vector: [0.6, 0.8, 0])
        }
        let result = try q.read { db in
            try PhotoSearch.filter(tokens: [.similar(handle: "s1")],
                                   context: .init(similarVectors: ["s1": [1, 0, 0]]), db: db)
        }
        XCTAssertEqual(result?.ids.first, "closest",
                       "score-descending must be the result order when similar: is present")
        XCTAssertEqual(result?.idSet, ["closest", "farther"])
    }

    func testUnresolvableHandleMatchesNothingNotUnfiltered() throws {
        let q = try makeQueue()
        try q.write { db in try insertVector(db, id: "anything", vector: [1, 0, 0]) }
        let result = try q.read { db in
            try PhotoSearch.filter(tokens: [.similar(handle: "s999")],
                                   context: .init(similarVectors: [:]), db: db)
        }
        XCTAssertEqual(result?.idSet, [],
                       "an unresolvable handle must match nothing, never fall back to unfiltered")
    }

    func testIntersectsWithOtherTokens() throws {
        let q = try makeQueue()
        try q.write { db in try insertVector(db, id: "match", vector: [1, 0, 0]) }
        let result = try q.read { db in
            try PhotoSearch.filter(tokens: [.similar(handle: "s1"), .rating(atLeast: 5)],
                                   context: .init(similarVectors: ["s1": [1, 0, 0]]), db: db)
        }
        // No rating tag exists on "match" in this fixture, so the intersection is
        // empty — proving the two token types genuinely intersect.
        XCTAssertEqual(result?.idSet, [])
    }

    func testBelowImageFloorIsExcluded() throws {
        let q = try makeQueue()
        try q.write { db in try insertVector(db, id: "orthogonal", vector: [0, 1, 0]) }
        let result = try q.read { db in
            try PhotoSearch.filter(tokens: [.similar(handle: "s1")],
                                   context: .init(similarVectors: ["s1": [1, 0, 0]]), db: db)
        }
        XCTAssertEqual(result?.idSet, [])
    }
}
