//
//  ClipVectorsTests.swift
//  MuseTests
//

import XCTest
@testable import Muse

private func assertVectorsEqual(_ a: [Float], _ b: [Float], accuracy: Float,
                                file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertEqual(a.count, b.count, file: file, line: line)
    for (x, y) in zip(a, b) {
        XCTAssertEqual(x, y, accuracy: accuracy, file: file, line: line)
    }
}

final class ClipVectorsTests: XCTestCase {
    func testRoundTripWithinFloat16Tolerance() {
        let original: [Float] = (0..<512).map { Float($0) / 512.0 - 0.5 }
        let data = ClipVectors.toData(original)
        XCTAssertEqual(data.count, 512 * 2, "512 x Float16 LE = 1024 bytes")
        let back = ClipVectors.fromData(data)
        XCTAssertNotNil(back)
        assertVectorsEqual(original, back!, accuracy: 0.01)
    }

    func testOddLengthBlobReturnsNil() {
        XCTAssertNil(ClipVectors.fromData(Data(repeating: 0, count: 101)))
    }

    func testEmptyDataReturnsNil() {
        XCTAssertNil(ClipVectors.fromData(Data()))
    }

    func testNormalizationSurvivesRoundTrip() {
        var v: [Float] = (0..<512).map { _ in Float.random(in: -1...1) }
        let norm = (v.reduce(0) { $0 + $1 * $1 }).squareRoot()
        v = v.map { $0 / norm }
        let back = ClipVectors.fromData(ClipVectors.toData(v))!
        let backNorm = (back.reduce(0) { $0 + $1 * $1 }).squareRoot()
        XCTAssertEqual(backNorm, 1.0, accuracy: 0.01)
    }
}

final class ClipCentroidTests: XCTestCase {
    func testSingleAnchorIdentity() {
        let v: [Float] = [0.6, 0.8] // already unit-length
        let centroid = ClipCentroid.centroid([v])
        XCTAssertNotNil(centroid)
        assertVectorsEqual(centroid!, v, accuracy: 0.001)
    }

    func testMeanThenRenormalize() {
        let centroid = ClipCentroid.centroid([[1, 0], [0, 1]])!
        XCTAssertEqual(centroid[0], centroid[1], accuracy: 0.001)
        let norm = (centroid.reduce(0) { $0 + $1 * $1 }).squareRoot()
        XCTAssertEqual(norm, 1.0, accuracy: 0.001)
    }

    func testEmptyReturnsNil() {
        XCTAssertNil(ClipCentroid.centroid([]))
    }

    func testMismatchedDimensionsAreSkipped() {
        // A vector from another model generation must never contribute.
        let centroid = ClipCentroid.centroid([[1, 0], [1, 0, 0]])!
        assertVectorsEqual(centroid, [1, 0], accuracy: 0.001)
    }
}
