//
//  SearchMergeTests.swift
//  MuseTests
//
//  Pure merge logic: exact hits rank first (in their original order),
//  then semantic hits above the threshold sorted by similarity,
//  deduplicated against the exact set.
//

import XCTest
@testable import Muse

final class SearchMergeTests: XCTestCase {
    func testExactFirstThenSemanticBySimilarity() {
        let merged = SemanticSearch.merge(
            exactIDs: ["a", "b"],
            semantic: [("c", 0.9), ("a", 0.8), ("d", 0.5), ("e", 0.2)],
            threshold: 0.45)
        XCTAssertEqual(merged, ["a", "b", "c", "d"])
    }
    func testEmptyExact() {
        XCTAssertEqual(SemanticSearch.merge(exactIDs: [],
                                            semantic: [("x", 0.6)], threshold: 0.45), ["x"])
    }
}
