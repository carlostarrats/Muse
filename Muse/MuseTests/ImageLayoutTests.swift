import XCTest
@testable import Muse

final class ImageLayoutTests: XCTestCase {

    func testThreeModesInOrder() {
        XCTAssertEqual(ImageLayout.allCases.map(\.displayName),
                       ["Columns", "Rows", "Grid"])
    }

    func testColumnsAndRowsHaveNoFixedAspect() {
        XCTAssertNil(ImageLayout.columns.aspect)
        XCTAssertNil(ImageLayout.rows.aspect)
    }

    func testGridIsSquare() {
        XCTAssertEqual(ImageLayout.grid.aspect, 1)
    }

    func testIconKinds() {
        XCTAssertEqual(ImageLayout.columns.iconKind, .columns)
        XCTAssertEqual(ImageLayout.rows.iconKind, .rows)
        XCTAssertEqual(ImageLayout.grid.iconKind, .grid)
    }

    func testResolveDefaultsToColumns() {
        XCTAssertEqual(ImageLayout.resolve(nil), .columns)
        XCTAssertEqual(ImageLayout.resolve("bogus"), .columns)
    }

    func testResolveRoundTripsTheNewRawValues() {
        for layout in ImageLayout.allCases {
            XCTAssertEqual(ImageLayout.resolve(layout.rawValue), layout)
        }
    }

    /// A user persisted on the old masonry default must land on Columns —
    /// the same layout under a new name, not a silent change.
    func testLegacyMasonryMigratesToColumns() {
        XCTAssertEqual(ImageLayout.resolve("masonry"), .columns)
    }

    /// A user persisted on any of the ten deleted fixed ratios must land on
    /// Grid — the mode that kept the aligned-lattice feel. Falling through to
    /// the unknown-value default would silently drop them into Columns.
    func testLegacyRatiosMigrateToGrid() {
        for raw in ["r1x1", "r9x16", "r16x9", "r4x5", "r5x4",
                    "r6x7", "r7x6", "r2x3", "r3x2", "r3x4", "r4x3"] {
            XCTAssertEqual(ImageLayout.resolve(raw), .grid, "raw: \(raw)")
        }
    }
}
