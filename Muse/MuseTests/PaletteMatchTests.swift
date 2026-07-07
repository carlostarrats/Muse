import XCTest
@testable import Muse

final class PaletteMatchTests: XCTestCase {

    private let red   = LabColor(rgb: RGB(r: 1, g: 0, b: 0))
    private let green = LabColor(rgb: RGB(r: 0, g: 1, b: 0))
    private let blue  = LabColor(rgb: RGB(r: 0, g: 0, b: 1))
    private let threshold = ColorDistance.nearThreshold

    func testSingleColorPresentMatches() {
        XCTAssertTrue(PaletteMatch.matches(query: [red],
                                           palette: [red, green], threshold: threshold))
    }

    func testSingleColorAbsentFails() {
        XCTAssertFalse(PaletteMatch.matches(query: [blue],
                                            palette: [red, green], threshold: threshold))
    }

    func testAllColorsPresentMatches() {
        XCTAssertTrue(PaletteMatch.matches(query: [red, blue],
                                           palette: [red, green, blue], threshold: threshold))
    }

    func testOneColorMissingFailsAND() {
        // red present, blue absent → AND fails.
        XCTAssertFalse(PaletteMatch.matches(query: [red, blue],
                                            palette: [red, green], threshold: threshold))
    }

    func testEmptyPaletteNeverMatches() {
        XCTAssertFalse(PaletteMatch.matches(query: [red],
                                            palette: [], threshold: threshold))
    }

    func testNearButNotExactStillMatches() {
        // A slightly-off red is within threshold.
        let nearRed = LabColor(rgb: RGB(r: 0.95, g: 0.05, b: 0.05))
        XCTAssertTrue(PaletteMatch.matches(query: [red],
                                           palette: [nearRed], threshold: threshold))
    }

    func testScoreRanksCloserPaletteFirst() {
        let exact = PaletteMatch.score(query: [red], palette: [red, green])
        let off = PaletteMatch.score(
            query: [red],
            palette: [LabColor(rgb: RGB(r: 0.8, g: 0.1, b: 0.1)), green])
        XCTAssertLessThan(exact, off)
    }

    func testScoreEmptyPaletteIsInfinite() {
        XCTAssertEqual(PaletteMatch.score(query: [red], palette: []), .infinity)
    }
}
