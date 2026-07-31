//
//  FeaturePrintsTests.swift
//  MuseTests
//
//  Raw VNFeaturePrintObservation.data element-buffer comparison — the fix for
//  the shipped dead "visually similar" mode (NSKeyedUnarchiver on a raw
//  buffer always returned nil).
//

import XCTest
@testable import Muse

final class FeaturePrintsTests: XCTestCase {
    func testFloatsParsesAlignedBuffer() {
        let values: [Float] = [1.0, 2.0, 3.0, 4.0]
        let data = values.withUnsafeBufferPointer { Data(buffer: $0) }
        XCTAssertEqual(FeaturePrints.floats(data), values)
    }

    func testFloatsRejectsMisalignedBuffer() {
        // 6 bytes is not a multiple of 4 (Float32 stride) — must not crash,
        // must not silently truncate.
        let data = Data([0, 1, 2, 3, 4, 5])
        XCTAssertNil(FeaturePrints.floats(data))
    }

    func testFloatsRejectsEmptyBuffer() {
        XCTAssertNil(FeaturePrints.floats(Data()))
    }

    func testDistanceIsZeroForIdenticalVectors() {
        let a: [Float] = [1, 2, 3, 4]
        XCTAssertEqual(FeaturePrints.distance(a, a) ?? -1, 0, accuracy: 0.0001)
    }

    func testDistanceMatchesManualEuclidean() {
        let a: [Float] = [0, 0, 0]
        let b: [Float] = [3, 4, 0]
        // sqrt(3^2 + 4^2) = 5
        XCTAssertEqual(FeaturePrints.distance(a, b) ?? -1, 5.0, accuracy: 0.0001)
    }

    func testDistanceReturnsNilForMismatchedLengths() {
        // Prints from different Vision revisions must never pair — a
        // dimension mismatch is a silent-nonsense pair, not a value to score.
        XCTAssertNil(FeaturePrints.distance([1, 2, 3], [1, 2]))
    }

    func testDistanceReturnsNilForEmptyVectors() {
        XCTAssertNil(FeaturePrints.distance([], []))
    }

    // MARK: - Shipped-bug pin: the duplicate finder's visual grouping

    private func item(_ id: String, _ floats: [Float]) -> DuplicateFinder.VisualItem {
        DuplicateFinder.VisualItem(id: id, floats: floats, area: 4_000_000, colorPrefix: "#aab")
    }

    func testVisualGroupsFormFromRawDataPrints() {
        // Near-identical prints (perturbation well under the 0.45 threshold)
        // must land in one group. Before the fix this path unarchived the raw
        // buffer, got nil for every row, and returned no groups at all.
        let base: [Float] = (0..<64).map { Float($0) * 0.01 }
        let nudged = base.map { $0 + 0.001 }
        let groups = DuplicateFinder.visualGroupIndices([item("a", base), item("b", nudged)])
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups.first.map { Set($0) }, Set([0, 1]))
    }

    func testVisualGroupsRejectDistantPrints() {
        let a: [Float] = (0..<64).map { _ in 0 }
        let b: [Float] = (0..<64).map { _ in 1 }   // distance = 8, far over 0.45
        XCTAssertTrue(DuplicateFinder.visualGroupIndices([item("a", a), item("b", b)]).isEmpty)
    }

    func testVisualGroupsSeparateByResolutionBucket() {
        // Identical prints but wildly different pixel areas stay unpaired —
        // the bucketing pre-filter is unchanged by the fix.
        let p: [Float] = (0..<64).map { Float($0) * 0.01 }
        let small = DuplicateFinder.VisualItem(id: "a", floats: p, area: 10_000, colorPrefix: "#aab")
        let big = DuplicateFinder.VisualItem(id: "b", floats: p, area: 40_000_000, colorPrefix: "#aab")
        XCTAssertTrue(DuplicateFinder.visualGroupIndices([small, big]).isEmpty)
    }
}
