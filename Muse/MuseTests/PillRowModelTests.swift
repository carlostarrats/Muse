import XCTest
@testable import Muse

final class PillRowModelTests: XCTestCase {
    // container 230, gap 6
    func testRowAssignmentWraps() {
        let rows = PillRowModel.rows(naturals: [100, 100, 100], container: 230, gap: 6)
        XCTAssertEqual(rows, [0, 0, 1])   // third wraps
    }
    func testHoverStealsFromSlackFirst() {
        // one row with plenty of slack: no shrink needed
        let w = PillRowModel.widths(naturals: [60, 60], container: 230, gap: 6,
                                    hovered: 0, grow: 17, floor: 26)
        XCTAssertEqual(w[0], 77)          // grew fully
        XCTAssertEqual(w[1], 60)          // untouched
    }
    func testHoverShrinksFollowingSameRowOnly() {
        // row0: [100, 100] (slack 230-206=24 ≥ 17+3 → no shrink), force tight:
        let w = PillRowModel.widths(naturals: [120, 104], container: 230, gap: 6,
                                    hovered: 0, grow: 17, floor: 26)
        // slack = 230 - (120+6+104) = 0 → deficit 17+3=20 → shrink pill1 by 20
        XCTAssertEqual(w[0], 137)
        XCTAssertEqual(w[1], 84)
    }
    func testHoverNeverMovesEarlierPillsOrOtherRows() {
        let naturals: [CGFloat] = [100, 100, 100, 100]   // rows [0,0,1,1]
        let w = PillRowModel.widths(naturals: naturals, container: 230, gap: 6,
                                    hovered: 2, grow: 17, floor: 26)
        XCTAssertEqual(w[0], 100); XCTAssertEqual(w[1], 100)   // row 0 untouched
        // hovered grew; row partner unchanged (slack 24 >= grow 17 + buffer 3)
        XCTAssertEqual(w[2], 117)
        XCTAssertEqual(w[3], 100)   // slack 24 → deficit 0 → no shrink
        // row width never exceeds container
        XCTAssertLessThanOrEqual(w[2] + 6 + w[3], 230)
    }
    func testSelfTruncateWhenSiblingsCantGive() {
        // hovered is last in a full row with no following siblings
        let w = PillRowModel.widths(naturals: [120, 104], container: 230, gap: 6,
                                    hovered: 1, grow: 17, floor: 26)
        // slack 0, no following pills → self-truncate: total width must still fit
        XCTAssertLessThanOrEqual(w[0] + 6 + w[1], 230)
        XCTAssertEqual(w[0], 120)         // earlier pill never moves
    }
}
