//
//  ClipIndexTests.swift
//  MuseTests
//

import XCTest
import GRDB
@testable import Muse

final class ClipIndexTests: XCTestCase {

    private func makeQueue() throws -> DatabaseQueue {
        let q = try DatabaseQueue()
        try Database.makeMigrator().migrate(q)
        return q
    }

    private func unitVector(_ dims: [Float]) -> [Float] {
        let norm = (dims.reduce(0) { $0 + $1 * $1 }).squareRoot()
        return dims.map { $0 / norm }
    }

    private func insertVector(_ db: GRDB.Database, id: String, vector: [Float]?,
                              generation: Int = ClipModel.current.generation) throws {
        try db.execute(sql: "INSERT INTO files (id, content_hash, kind, last_seen_at) VALUES (?, ?, 'image', 0)",
                        arguments: [id, id + "-hash"])
        var row = ClipEmbeddingRow(file_id: id, embedded_hash: id + "-hash",
                                    model_generation: generation,
                                    vector: vector.map { ClipVectors.toData($0) })
        try row.insert(db)
    }

    func testStreamedMatchesEqualBruteForceReference() throws {
        let q = try makeQueue()
        try q.write { db in
            for i in 0..<200 {
                try insertVector(db, id: "v\(i)",
                                 vector: unitVector((0..<512).map { _ in Float.random(in: -1...1) }))
            }
        }
        let query = unitVector((0..<512).map { _ in Float.random(in: -1...1) })
        let streamed = try q.read { db in try ClipIndex.matches(query: query, minScore: -1, db: db) }
        // Reference: pull every vector back out and score with a plain dot product.
        let all = try q.read { db in try ClipEmbeddingRow.fetchAll(db) }
        let reference = all.compactMap { row -> (String, Double)? in
            guard let v = row.vector.flatMap(ClipVectors.fromData) else { return nil }
            let dot = zip(v, query).reduce(Float(0)) { $0 + $1.0 * $1.1 }
            return (row.file_id, Double(dot))
        }.sorted { $0.1 > $1.1 }
        XCTAssertEqual(streamed.map(\.id), reference.prefix(ClipIndex.topK).map(\.0))
    }

    func testNullVectorsAreSkipped() throws {
        let q = try makeQueue()
        try q.write { db in
            try insertVector(db, id: "has-vector", vector: unitVector([1, 0, 0]))
            try insertVector(db, id: "attempted-marker", vector: nil)
        }
        let results = try q.read { db in
            try ClipIndex.matches(query: unitVector([1, 0, 0]), minScore: -1, db: db)
        }
        XCTAssertFalse(results.contains { $0.id == "attempted-marker" })
    }

    func testStaleGenerationVectorsAreSkipped() throws {
        let q = try makeQueue()
        try q.write { db in
            try insertVector(db, id: "current-gen", vector: unitVector([1, 0, 0]),
                             generation: ClipModel.current.generation)
            try insertVector(db, id: "old-gen", vector: unitVector([1, 0, 0]),
                             generation: ClipModel.current.generation - 1)
        }
        let results = try q.read { db in
            try ClipIndex.matches(query: unitVector([1, 0, 0]), minScore: -1, db: db)
        }
        XCTAssertTrue(results.contains { $0.id == "current-gen" })
        XCTAssertFalse(results.contains { $0.id == "old-gen" })
    }

    func testTopKCapIsRespected() throws {
        let q = try makeQueue()
        try q.write { db in
            for i in 0..<(ClipIndex.topK + 50) {
                try insertVector(db, id: "v\(i)", vector: unitVector([Float(i) + 1, 1, 0]))
            }
        }
        let results = try q.read { db in
            try ClipIndex.matches(query: unitVector([1, 0, 0]), minScore: -1, db: db)
        }
        XCTAssertLessThanOrEqual(results.count, ClipIndex.topK)
    }

    func testThresholdEdgeExcludesBelowFloor() throws {
        let q = try makeQueue()
        try q.write { db in
            try insertVector(db, id: "orthogonal", vector: unitVector([0, 1, 0]))
        }
        let results = try q.read { db in
            try ClipIndex.matches(query: unitVector([1, 0, 0]), minScore: 0.5, db: db)
        }
        XCTAssertTrue(results.isEmpty, "an orthogonal vector (score ~0) must not pass a 0.5 floor")
    }

    func testDimensionMismatchIsSkipped() throws {
        let q = try makeQueue()
        try q.write { db in
            try insertVector(db, id: "wrong-dims", vector: unitVector([1, 0]))
        }
        let results = try q.read { db in
            try ClipIndex.matches(query: unitVector([1, 0, 0]), minScore: -1, db: db)
        }
        XCTAssertTrue(results.isEmpty, "vectors of a different length must never pair")
    }
}
