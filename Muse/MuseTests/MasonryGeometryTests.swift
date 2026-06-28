import XCTest
import CoreGraphics
@testable import Muse

final class MasonryGeometryTests: XCTestCase {

    // width 414, 2 columns, 14pt spacing → columnWidth = (414 - 14) / 2 = 200.

    func testCaptionHeightDefaultsToZero() {
        // No captionHeight argument → tile height is purely columnWidth × aspect.
        let r = MasonryGeometry.compute(aspects: [1.0], columns: 2,
                                        width: 414, spacing: 14)
        XCTAssertEqual(r.frames[0].width, 200, accuracy: 0.5)
        XCTAssertEqual(r.frames[0].height, 200, accuracy: 0.5)
    }

    func testCaptionHeightReservedPerTile() {
        let r = MasonryGeometry.compute(aspects: [1.0], columns: 2,
                                        width: 414, spacing: 14, captionHeight: 18)
        // tile = image(200 × 1.0) + 18pt caption strip.
        XCTAssertEqual(r.frames[0].width, 200, accuracy: 0.5)
        XCTAssertEqual(r.frames[0].height, 200 + 18, accuracy: 0.5)
    }

    func testTotalHeightIncludesCaption() {
        // Two square tiles, two columns → one row each. The caption adds 18pt
        // to the row's height, so totalHeight grows by exactly 18.
        let noCap = MasonryGeometry.compute(aspects: [1.0, 1.0], columns: 2,
                                            width: 414, spacing: 14)
        let withCap = MasonryGeometry.compute(aspects: [1.0, 1.0], columns: 2,
                                              width: 414, spacing: 14, captionHeight: 18)
        XCTAssertEqual(withCap.totalHeight - noCap.totalHeight, 18, accuracy: 0.5)
    }

    func testVariableAspectsPackIntoShortestColumn() {
        // 2 columns, columnWidth 200. A tall tile (aspect 2) fills column 0;
        // the next two short tiles (aspect 0.5) must both stack in the SHORTER
        // column 1, not under the tall one. This exercises the masonry pack
        // itself (the function's whole purpose), which the uniform-aspect tests
        // above never touch.
        let r = MasonryGeometry.compute(aspects: [2.0, 0.5, 0.5], columns: 2,
                                        width: 414, spacing: 14)
        // Tall tile in column 0 at the origin.
        XCTAssertEqual(r.frames[0].minX, 0, accuracy: 0.5)
        XCTAssertEqual(r.frames[0].height, 400, accuracy: 0.5)   // 200 × 2.0
        // Both short tiles land in column 1 (x = 200 + 14 = 214)…
        XCTAssertEqual(r.frames[1].minX, 214, accuracy: 0.5)
        XCTAssertEqual(r.frames[2].minX, r.frames[1].minX, accuracy: 0.5)
        // …NOT under the tall tile.
        XCTAssertNotEqual(r.frames[2].minX, r.frames[0].minX, accuracy: 0.5)
        // The 2nd short tile stacks below the 1st (50pt tile + 14pt spacing).
        XCTAssertEqual(r.frames[2].minY, r.frames[1].maxY + 14, accuracy: 0.5)
        // Content height = the tallest column (column 0's lone 400pt tile,
        // trailing spacing stripped).
        XCTAssertEqual(r.totalHeight, 400, accuracy: 0.5)
    }

    func testEmptyAspectsYieldsNoFrames() {
        let r = MasonryGeometry.compute(aspects: [], columns: 2, width: 414, spacing: 14)
        XCTAssertTrue(r.frames.isEmpty)
        XCTAssertEqual(r.totalHeight, 0, accuracy: 0.5)
    }

    func testNonPositiveWidthYieldsNoFrames() {
        let r = MasonryGeometry.compute(aspects: [1.0], columns: 2, width: 0, spacing: 14)
        XCTAssertTrue(r.frames.isEmpty)
        XCTAssertEqual(r.totalHeight, 0, accuracy: 0.5)
    }

    func testColumnCountClampsToAtLeastOne() {
        // columns ≤ 0 must clamp to a single column (no divide-by-zero, no crash);
        // both tiles stack in that one column.
        let r = MasonryGeometry.compute(aspects: [1.0, 1.0], columns: 0,
                                        width: 200, spacing: 10)
        XCTAssertEqual(r.frames.count, 2)
        XCTAssertEqual(r.frames[0].minX, 0, accuracy: 0.5)
        XCTAssertEqual(r.frames[1].minX, 0, accuracy: 0.5)      // same column
        XCTAssertEqual(r.frames[1].minY, 210, accuracy: 0.5)    // 200 tile + 10 spacing
    }

    func testCaptionedTilesDoNotOverlapWithinColumn() {
        // 6 squares, 2 columns → 3 stacked per column. Once the caption strip is
        // reserved, each tile in a column must start at/after the previous one's
        // bottom (no overlap).
        let r = MasonryGeometry.compute(aspects: Array(repeating: 1.0, count: 6),
                                        columns: 2, width: 414, spacing: 14,
                                        captionHeight: 18)
        let byColumn = Dictionary(grouping: r.frames, by: { Int($0.minX.rounded()) })
        for (_, colFrames) in byColumn {
            let sorted = colFrames.sorted { $0.minY < $1.minY }
            for i in 1..<sorted.count {
                XCTAssertGreaterThanOrEqual(sorted[i].minY, sorted[i - 1].maxY - 0.5)
            }
        }
    }
}
