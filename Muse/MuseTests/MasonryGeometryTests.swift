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
