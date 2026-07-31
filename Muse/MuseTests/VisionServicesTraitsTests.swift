//
//  VisionServicesTraitsTests.swift
//  MuseTests
//

import XCTest
@testable import Muse

final class VisionServicesTraitsTests: XCTestCase {
    func testPetConfidenceFloorIsNamedConstant() {
        XCTAssertEqual(VisionServices.petConfidenceFloor, 0.5)
    }

    func testVisionResultCarriesTraitFields() {
        var result = VisionResult()
        result.largestFaceFrac = 0.12
        result.faceQuality = 0.8
        result.petCount = 2
        result.sharpness = 3.1
        XCTAssertEqual(result.largestFaceFrac, 0.12)
        XCTAssertEqual(result.faceQuality, 0.8)
        XCTAssertEqual(result.petCount, 2)
        XCTAssertEqual(result.sharpness, 3.1)
    }
}
