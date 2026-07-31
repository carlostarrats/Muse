//
//  SimilarTermTests.swift
//  MuseTests
//

import XCTest
import GRDB
@testable import Muse

final class SimilarTermTests: XCTestCase {
    func testCodableRoundTripIncludingPromptVector() throws {
        let term = SimilarTerm(anchorIDs: ["f1", "f2"], prompt: "beach sunset",
                               promptVector: [0.1, 0.2, 0.3], promptGeneration: 1,
                               threshold: 0.6)
        let data = try JSONEncoder().encode(term)
        XCTAssertEqual(try JSONDecoder().decode(SimilarTerm.self, from: data), term)
    }

    func testIsValidRequiresAnchorsOrPrompt() {
        var term = SimilarTerm(anchorIDs: [], prompt: nil, promptVector: nil,
                               promptGeneration: nil, threshold: SimilarTerm.defaultThreshold)
        XCTAssertFalse(term.isValid)
        term.anchorIDs = ["f1"]
        XCTAssertTrue(term.isValid)
        term.anchorIDs = []
        term.prompt = "beach"
        XCTAssertTrue(term.isValid)
    }

    func testIsValidRequiresThresholdInRange() {
        var term = SimilarTerm(anchorIDs: ["f1"], prompt: nil, promptVector: nil,
                               promptGeneration: nil, threshold: 0.1)
        XCTAssertFalse(term.isValid, "threshold below range must be invalid")
        term.threshold = 0.99
        XCTAssertFalse(term.isValid, "threshold above range must be invalid")
        term.threshold = SimilarTerm.defaultThreshold
        XCTAssertTrue(term.isValid)
    }

    func testBlankPromptIsNotValidOnItsOwn() {
        let term = SimilarTerm(anchorIDs: [], prompt: "   ", promptVector: nil,
                               promptGeneration: nil, threshold: SimilarTerm.defaultThreshold)
        XCTAssertFalse(term.isValid)
    }

    func testRuleSetRoundTripsThroughEncodedJSON() {
        let set = SmartRuleSet(match: .all, rules: [
            .similar(SimilarTerm(anchorIDs: ["a"], prompt: nil, promptVector: nil,
                                 promptGeneration: nil, threshold: 0.55))
        ])
        let json = set.encodedJSON()
        XCTAssertNotNil(json)
        XCTAssertEqual(SmartRuleSet.decode(json!), set)
    }
}

final class SmartRuleSimilarResolverTests: XCTestCase {

    private func makeQueue() throws -> DatabaseQueue {
        let q = try DatabaseQueue()
        try Database.makeMigrator().migrate(q)
        return q
    }

    private func insertVector(_ db: GRDB.Database, id: String, vector: [Float],
                              generation: Int = ClipModel.current.generation) throws {
        try db.execute(sql: "INSERT INTO files (id, content_hash, kind, last_seen_at) VALUES (?, ?, 'image', 0)",
                        arguments: [id, id + "-hash"])
        var row = ClipEmbeddingRow(file_id: id, embedded_hash: id + "-hash",
                                    model_generation: generation,
                                    vector: ClipVectors.toData(vector))
        try row.insert(db)
    }

    func testAnchorPathResolvesOverFixtureVectors() throws {
        let q = try makeQueue()
        try q.write { db in
            try insertVector(db, id: "anchor1", vector: [1, 0, 0])
            try insertVector(db, id: "close-match", vector: [0.99, 0.14, 0])
            try insertVector(db, id: "far", vector: [0, 1, 0])
        }
        let ruleSet = SmartRuleSet(match: .all, rules: [
            .similar(SimilarTerm(anchorIDs: ["anchor1"], prompt: nil, promptVector: nil,
                                 promptGeneration: nil, threshold: 0.5))
        ])
        let ids = try q.read { db in try SmartCollectionResolver.memberIDs(ruleSet, db: db) }
        XCTAssertTrue(ids.contains("close-match"))
        XCTAssertFalse(ids.contains("far"))
    }

    func testStalePromptGenerationResolvesEmpty() throws {
        let q = try makeQueue()
        try q.write { db in try insertVector(db, id: "any", vector: [1, 0, 0]) }
        let ruleSet = SmartRuleSet(match: .all, rules: [
            .similar(SimilarTerm(anchorIDs: [], prompt: "beach", promptVector: [1, 0, 0],
                                 promptGeneration: ClipModel.current.generation - 1,
                                 threshold: 0.5))
        ])
        let ids = try q.read { db in try SmartCollectionResolver.memberIDs(ruleSet, db: db) }
        XCTAssertTrue(ids.isEmpty, "a stale-generation prompt vector must not be used")
    }

    func testThresholdBoundary() throws {
        let q = try makeQueue()
        try q.write { db in
            try insertVector(db, id: "anchor1", vector: [1, 0, 0])
            try insertVector(db, id: "orthogonal", vector: [0, 1, 0])
        }
        let ruleSet = SmartRuleSet(match: .all, rules: [
            .similar(SimilarTerm(anchorIDs: ["anchor1"], prompt: nil, promptVector: nil,
                                 promptGeneration: nil, threshold: 0.8))
        ])
        let ids = try q.read { db in try SmartCollectionResolver.memberIDs(ruleSet, db: db) }
        XCTAssertFalse(ids.contains("orthogonal"))
    }

    func testNoResolvableVectorProducesEmptySet() throws {
        let q = try makeQueue()
        let ruleSet = SmartRuleSet(match: .all, rules: [
            .similar(SimilarTerm(anchorIDs: ["does-not-exist"], prompt: nil, promptVector: nil,
                                 promptGeneration: nil, threshold: 0.5))
        ])
        let ids = try q.read { db in try SmartCollectionResolver.memberIDs(ruleSet, db: db) }
        XCTAssertTrue(ids.isEmpty)
    }

    func testStaleGenerationAnchorIsIgnored() throws {
        let q = try makeQueue()
        try q.write { db in
            try insertVector(db, id: "anchor1", vector: [1, 0, 0],
                             generation: ClipModel.current.generation - 1)
            try insertVector(db, id: "close-match", vector: [1, 0, 0])
        }
        let ruleSet = SmartRuleSet(match: .all, rules: [
            .similar(SimilarTerm(anchorIDs: ["anchor1"], prompt: nil, promptVector: nil,
                                 promptGeneration: nil, threshold: 0.5))
        ])
        let ids = try q.read { db in try SmartCollectionResolver.memberIDs(ruleSet, db: db) }
        XCTAssertTrue(ids.isEmpty, "an anchor from another model generation resolves to no vector")
    }
}
