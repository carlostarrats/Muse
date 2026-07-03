import XCTest
@testable import Muse

final class SheetFitTests: XCTestCase {
    // Not yet measured → falls back to the ideal height.
    func testUnmeasuredUsesIdeal() {
        XCTAssertEqual(
            SheetFit.height(ideal: 720, windowHeight: nil, minHeight: 320, margin: 24),
            720)
    }

    // Window taller than ideal → stays at ideal (unchanged look on big windows).
    func testTallWindowKeepsIdeal() {
        XCTAssertEqual(
            SheetFit.height(ideal: 720, windowHeight: 1000, minHeight: 320, margin: 24),
            720)
    }

    // Window shorter than ideal → shrinks to window minus margin.
    func testShortWindowShrinksToFit() {
        XCTAssertEqual(
            SheetFit.height(ideal: 720, windowHeight: 600, minHeight: 320, margin: 24),
            576) // 600 - 24
    }

    // Exactly ideal + margin is the crossover: still ideal.
    func testCrossoverAtIdealPlusMargin() {
        XCTAssertEqual(
            SheetFit.height(ideal: 720, windowHeight: 744, minHeight: 320, margin: 24),
            720)
    }

    // Very short window → clamps at the minHeight floor, not below.
    func testTinyWindowClampsAtFloor() {
        XCTAssertEqual(
            SheetFit.height(ideal: 720, windowHeight: 100, minHeight: 320, margin: 24),
            320)
    }

    // The floor never pushes above the ideal.
    func testFloorNeverExceedsIdeal() {
        XCTAssertEqual(
            SheetFit.height(ideal: 300, windowHeight: 100, minHeight: 320, margin: 24),
            300)
    }
}
