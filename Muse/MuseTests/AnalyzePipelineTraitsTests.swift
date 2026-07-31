//
//  AnalyzePipelineTraitsTests.swift
//  MuseTests
//

import XCTest
@testable import Muse

final class AnalyzePipelineTraitsTests: XCTestCase {
    func testTraitFieldsConstructFromVisionResult() {
        var result = VisionResult()
        result.faceCount = 2
        result.largestFaceFrac = 0.3
        result.faceQuality = 0.9
        result.petCount = 1
        result.sharpness = 3.4

        let traits = TraitFields(from: result)
        XCTAssertEqual(traits.faceCount, 2)
        XCTAssertEqual(traits.largestFaceFrac, 0.3)
        XCTAssertEqual(traits.faceQuality, 0.9)
        XCTAssertEqual(traits.petCount, 1)
        XCTAssertEqual(traits.sharpness, 3.4)
    }

    func testTaggerOutputCarriesOptionalTraits() {
        let output = TaggerOutput(tags: [], caption: nil, ocrText: "", dominantColor: nil,
                                   palette: [], featurePrint: nil, width: nil, height: nil,
                                   traits: nil, decodedImage: nil)
        XCTAssertNil(output.traits)
        XCTAssertNil(output.decodedImage)
    }
}
