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
        XCTAssertEqual(AppSettings.clampGridSpacing(-5), 4)
    }

    func testClampsAboveRange() {
        XCTAssertEqual(AppSettings.clampGridSpacing(999), 28)
    }

    /// Images must never touch. The floor is a real gap, not zero — a flush
    /// pack reads as one continuous image, not a grid.
    func testMinimumIsAVisibleGapNotZero() {
        XCTAssertEqual(AppSettings.gridSpacingRange.lowerBound, 4)
        XCTAssertEqual(AppSettings.clampGridSpacing(0), 4)
        XCTAssertEqual(AppSettings.clampGridSpacing(3), 4)
    }

    func testRangeUpperBound() {
        XCTAssertEqual(AppSettings.gridSpacingRange.upperBound, 28)
    }
}

/// Rounded image corners are user-set and persisted, and carry from the grid
/// into the viewer so opening a photo doesn't change its shape.
final class GridCornerRadiusTests: XCTestCase {

    func testDefaultIsSquare() {
        // Square corners are the shipped look; rounding is opt-in.
        XCTAssertEqual(AppSettings.defaultGridCornerRadius, 0)
    }

    func testClampsBelowRange() {
        XCTAssertEqual(AppSettings.clampGridCornerRadius(-5), 0)
    }

    func testClampsAboveRange() {
        XCTAssertEqual(AppSettings.clampGridCornerRadius(999), 20)
    }

    func testRangeBounds() {
        XCTAssertEqual(AppSettings.gridCornerRadiusRange.lowerBound, 0)
        XCTAssertEqual(AppSettings.gridCornerRadiusRange.upperBound, 20)
    }

    func testInRangeValuePassesThrough() {
        XCTAssertEqual(AppSettings.clampGridCornerRadius(9), 9)
    }
}
