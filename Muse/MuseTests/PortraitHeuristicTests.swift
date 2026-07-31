//
//  PortraitHeuristicTests.swift
//  MuseTests
//

import XCTest
@testable import Muse

final class PortraitHeuristicTests: XCTestCase {
    func testPortraitWithinFaceCountAndFracFloor() {
        XCTAssertEqual(PortraitHeuristic.classify(faceCount: 1, largestFrac: 0.1), .portrait)
    }

    func testTwoFacesStillPortraitAboveFracFloor() {
        XCTAssertEqual(
            PortraitHeuristic.classify(faceCount: 2,
                                       largestFrac: PortraitHeuristic.portraitMinFaceFrac),
            .portrait)
    }

    func testBelowFracFloorIsNeitherEvenWithOneFace() {
        XCTAssertEqual(PortraitHeuristic.classify(faceCount: 1, largestFrac: 0.01), .neither)
    }

    func testGroupAtThreeFaces() {
        XCTAssertEqual(
            PortraitHeuristic.classify(faceCount: PortraitHeuristic.groupMinFaces, largestFrac: nil),
            .group)
    }

    func testZeroFacesIsNeither() {
        XCTAssertEqual(PortraitHeuristic.classify(faceCount: 0, largestFrac: nil), .neither)
    }

    func testNilFracWithFewFacesIsNeither() {
        // A portrait claim requires knowing the subject actually fills the frame.
        XCTAssertEqual(PortraitHeuristic.classify(faceCount: 1, largestFrac: nil), .neither)
    }
}
