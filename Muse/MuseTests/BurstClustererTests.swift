//
//  BurstClustererTests.swift
//  MuseTests
//
//  Session split at the 10s gap; no cross-session pair ever compared; union
//  within a session; nil-print and mismatched-length items never cluster;
//  oversized sessions split; deterministic output order.
//

import XCTest
@testable import Muse

final class BurstClustererTests: XCTestCase {

    private func item(_ id: String, at t: Int64, print: [Float]? = [1, 0, 0]) -> BurstClusterer.Item {
        BurstClusterer.Item(fileID: id, captureAt: t, print: print)
    }

    func testTwoCloseSimilarItemsCluster() {
        XCTAssertEqual(BurstClusterer.clusters([item("a", at: 0), item("b", at: 5)]),
                       [["a", "b"]])
    }

    func testItemsBeyondSessionGapNeverCompared() {
        XCTAssertEqual(BurstClusterer.clusters([item("a", at: 0), item("b", at: 20)]), [])
    }

    func testNilPrintItemsNeverCluster() {
        XCTAssertEqual(BurstClusterer.clusters([item("a", at: 0, print: nil),
                                                item("b", at: 1, print: nil)]), [])
    }

    func testMismatchedLengthPrintsNeverCluster() {
        XCTAssertEqual(BurstClusterer.clusters([item("a", at: 0, print: [1, 0, 0]),
                                                item("b", at: 1, print: [1, 0])]), [])
    }

    func testDissimilarItemsInSameSessionDoNotCluster() {
        // Euclidean distance sqrt(2) ≈ 1.41, well over the 0.45 threshold.
        XCTAssertEqual(BurstClusterer.clusters([item("a", at: 0, print: [1, 0, 0]),
                                                item("b", at: 1, print: [0, 1, 0])]), [])
    }

    func testUnionFindGroupsTransitively() {
        let items = [item("a", at: 0, print: [1.0, 0, 0]),
                     item("b", at: 2, print: [0.99, 0.01, 0]),
                     item("c", at: 4, print: [0.98, 0.02, 0])]
        let clusters = BurstClusterer.clusters(items)
        XCTAssertEqual(clusters.count, 1)
        XCTAssertEqual(Set(clusters[0]), ["a", "b", "c"])
    }

    func testOutputOrderedByFirstMemberCaptureAt() {
        let items = [item("late1", at: 100, print: [1, 0, 0]),
                     item("late2", at: 102, print: [1, 0, 0]),
                     item("early1", at: 0, print: [0, 1, 0]),
                     item("early2", at: 2, print: [0, 1, 0])]
        let clusters = BurstClusterer.clusters(items)
        XCTAssertEqual(clusters.count, 2)
        XCTAssertEqual(Set(clusters[0]), ["early1", "early2"])
        XCTAssertEqual(Set(clusters[1]), ["late1", "late2"])
    }

    func testSingletonsAreNotClusters() {
        XCTAssertEqual(BurstClusterer.clusters([item("a", at: 0)]), [])
    }

    func testEmptyInput() {
        XCTAssertEqual(BurstClusterer.clusters([]), [])
    }

    func testOversizedSessionIsSplit() {
        // 300 identical-print items one second apart is a single session by the
        // 10s rule; maxSessionSize (256) must split it rather than letting the
        // inner O(k²) run at n².
        let items = (0..<300).map { item("f\($0)", at: Int64($0)) }
        let clusters = BurstClusterer.clusters(items)
        XCTAssertGreaterThan(clusters.count, 1)
        XCTAssertTrue(clusters.allSatisfy { $0.count <= BurstClusterer.maxSessionSize })
    }

    func testDeterministicAcrossRuns() {
        let items = [item("b", at: 1), item("a", at: 0), item("c", at: 2)]
        XCTAssertEqual(BurstClusterer.clusters(items), BurstClusterer.clusters(items))
    }
}
