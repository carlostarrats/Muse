import XCTest
@testable import Muse

final class ClassificationCurationTests: XCTestCase {
    private func labels(_ raw: [String: Float], max: Int = 5) -> [String] {
        ClassificationCuration.curate(raw, max: max).map { $0.label }
    }

    func testDropsSensitiveDemographics() {
        let out = labels(["adult": 0.9, "female": 0.8, "people": 0.7])
        XCTAssertEqual(out, ["people"])
    }

    func testDropsAbstractLabels() {
        let out = labels(["material": 0.9, "structure": 0.85, "conveyance": 0.8,
                          "container": 0.8, "vehicle": 0.7])
        XCTAssertEqual(out, ["vehicle"])
    }

    func testRemapsUglyCompounds() {
        XCTAssertEqual(labels(["wood_processed": 0.9]), ["wood"])
        XCTAssertEqual(labels(["blue_sky": 0.9]), ["sky"])
        XCTAssertEqual(labels(["footwear": 0.9]), ["shoes"])
    }

    func testUnderscoreBecomesSpace() {
        XCTAssertEqual(labels(["potted_plant": 0.9]), ["potted plant"])
    }

    func testConfidenceFloor() {
        let out = labels(["sign": 0.9, "book": 0.30])  // book below floor
        XCTAssertEqual(out, ["sign"])
    }

    func testDedupAfterRemap() {
        // illustrations -> illustration, collapses with an existing illustration
        let out = labels(["illustrations": 0.9, "illustration": 0.8])
        XCTAssertEqual(out, ["illustration"])
    }

    func testCapsCount() {
        let out = labels(["a_one": 0.9, "b_two": 0.85, "c_three": 0.8,
                          "d_four": 0.75, "e_five": 0.7, "f_six": 0.65], max: 3)
        XCTAssertEqual(out.count, 3)
    }

    func testKeepsConcreteNouns() {
        let out = labels(["people": 0.9, "sky": 0.8, "plant": 0.7, "clothing": 0.6])
        XCTAssertEqual(Set(out), ["people", "sky", "plant", "clothing"])
    }
}
