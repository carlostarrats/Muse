import XCTest
@testable import Muse

/// The grid gutter is user-set and persisted. The default must stay today's
/// hardcoded 14 (so nobody's grid changes on upgrade), and an out-of-range
/// stored value must clamp rather than produce a broken layout.
final class GridSpacingTests: XCTestCase {

    func testDefaultIsTodaysHardcodedValue() {
        XCTAssertEqual(AppSettings.defaultGridSpacing, 14)
    }

    func testDefaultPassesThroughTheClampUnchanged() {
        XCTAssertEqual(AppSettings.clampGridSpacing(AppSettings.defaultGridSpacing), 14)
    }

    func testClampsBelowRange() {
        XCTAssertEqual(AppSettings.clampGridSpacing(-5), 0)
    }

    func testClampsAboveRange() {
        XCTAssertEqual(AppSettings.clampGridSpacing(999), 28)
    }

    func testZeroIsAllowed() {
        // Flush packing is the point of the control — 0 is a valid choice.
        XCTAssertEqual(AppSettings.clampGridSpacing(0), 0)
    }

    func testRangeBounds() {
        XCTAssertEqual(AppSettings.gridSpacingRange.lowerBound, 0)
        XCTAssertEqual(AppSettings.gridSpacingRange.upperBound, 28)
    }
}
