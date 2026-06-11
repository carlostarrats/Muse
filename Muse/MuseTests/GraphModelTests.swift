//
//  GraphModelTests.swift
//  MuseTests
//

import XCTest
import GRDB
@testable import Muse

final class GraphModelTests: XCTestCase {
    /// files f1..f5 with paths /p/f<n>.png; collections c1{f1,f2},
    /// c2{f2,f3}, c3{f4}; tags: c1 files {dog,park}, c2 files {park,tree},
    /// c3 file {car}; f5 in no collection.
    private func makeQueue() throws -> DatabaseQueue {
        let q = try DatabaseQueue()
        try Database.makeMigrator().migrate(q)
        try q.write { db in
            for n in 1...5 {
                try db.execute(sql: "INSERT INTO files (id, kind, last_seen_at) VALUES (?, 'image', 0)",
                               arguments: ["f\(n)"])
                try db.execute(sql: """
                    INSERT INTO paths (id, file_id, absolute_path, is_alive)
                    VALUES (?, ?, ?, 1)
                    """, arguments: ["p\(n)", "f\(n)", "/p/f\(n).png"])
            }
            let now: Int64 = 0
            for (cid, name) in [("c1", "Dogs"), ("c2", "Parks"), ("c3", "Cars")] {
                try db.execute(sql: """
                    INSERT INTO collections (id, name, is_hidden, model_version, created_at, updated_at)
                    VALUES (?, ?, 0, 't', ?, ?)
                    """, arguments: [cid, name, now, now])
            }
            for (cid, fid) in [("c1", "f1"), ("c1", "f2"), ("c2", "f2"), ("c2", "f3"), ("c3", "f4")] {
                try db.execute(sql: """
                    INSERT INTO collection_members (collection_id, file_id, added_by)
                    VALUES (?, ?, 'auto')
                    """, arguments: [cid, fid])
            }
            let tags: [(String, String)] = [
                ("f1", "dog"), ("f1", "park"), ("f2", "dog"), ("f2", "park"),
                ("f3", "park"), ("f3", "tree"), ("f4", "car"),
            ]
            for (i, t) in tags.enumerated() {
                try db.execute(sql: """
                    INSERT INTO tags (id, file_id, label, source) VALUES (?, ?, ?, 'vision')
                    """, arguments: ["t\(i)", t.0, t.1])
            }
        }
        return q
    }

    func testBuildFiltersToScopeAndComputesEdges() async throws {
        let q = try makeQueue()
        let scope = ["/p/f1.png", "/p/f2.png", "/p/f3.png", "/p/f4.png", "/p/f5.png"]
        let data = try await GraphModel.build(queue: q, scopePaths: scope)
        XCTAssertEqual(data.clusters.count, 3)
        let byName = Dictionary(uniqueKeysWithValues: data.clusters.map { ($0.name, $0) })
        XCTAssertEqual(Set(byName["Dogs"]!.memberPaths), ["/p/f1.png", "/p/f2.png"])
        XCTAssertEqual(Set(byName["Parks"]!.memberPaths), ["/p/f2.png", "/p/f3.png"])
        // Dogs and Parks share tags via their members -> one edge; Cars shares nothing.
        XCTAssertEqual(data.edges.count, 1)
        let e = data.edges[0]
        let names = Set([data.clusters[e.a].name, data.clusters[e.b].name])
        XCTAssertEqual(names, ["Dogs", "Parks"])
        XCTAssertGreaterThanOrEqual(e.sharedTags, 1)
    }

    func testScopeNarrowsClusters() async throws {
        let q = try makeQueue()
        // Only f4 in scope: just the Cars cluster survives.
        let data = try await GraphModel.build(queue: q, scopePaths: ["/p/f4.png"])
        XCTAssertEqual(data.clusters.map(\.name), ["Cars"])
        XCTAssertTrue(data.edges.isEmpty)
    }

    func testEmptyScope() async throws {
        let q = try makeQueue()
        let data = try await GraphModel.build(queue: q, scopePaths: [])
        XCTAssertTrue(data.clusters.isEmpty)
        XCTAssertTrue(data.edges.isEmpty)
    }

    func testSharedTagEdgesPure() {
        let edges = GraphModel.sharedTagEdges(tagsByCluster: [
            ["a", "b", "c"], ["b", "c", "d"], ["x"],
        ])
        XCTAssertEqual(edges.count, 1)
        XCTAssertEqual(edges[0].a, 0)
        XCTAssertEqual(edges[0].b, 1)
        XCTAssertEqual(edges[0].sharedTags, 2)
    }

    func testDistanceMatrixHandlesNilPrints() {
        let m = GraphModel.distanceMatrix(prints: [nil, nil, nil])
        XCTAssertEqual(m.count, 3)
        XCTAssertEqual(m[0][0], 0)
        XCTAssertEqual(m[0][1], 1.0)   // unknown pairs get neutral distance
        XCTAssertEqual(m[1][2], 1.0)
    }
}
