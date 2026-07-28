import XCTest
import CoreGraphics
@testable import Muse

/// Rows mode: every row shares one height, widths follow each image's own
/// shape, and a full row spans the content width exactly. The trailing
/// partial row is deliberately NOT stretched.
final class JustifiedRowsGeometryTests: XCTestCase {

    func testEmptyInputProducesNothing() {
        let r = JustifiedRowsGeometry.compute(aspects: [], targetHeight: 200,
                                              width: 1000, spacing: 10)
        XCTAssertTrue(r.frames.isEmpty)
        XCTAssertEqual(r.totalHeight, 0)
    }

    func testZeroWidthProducesNothing() {
        let r = JustifiedRowsGeometry.compute(aspects: [1, 1], targetHeight: 200,
                                              width: 0, spacing: 10)
        XCTAssertTrue(r.frames.isEmpty)
    }

    func testFullRowSpansTheWidthExactly() {
        // Squares at target 200 in a 1000pt width: a row closes as soon as
        // justifying it would make it no taller than the target. Whichever rows
        // close must span the full width.
        let aspects = [CGFloat](repeating: 1, count: 12)
        let rows = JustifiedRowsGeometry.rows(aspects: aspects, targetHeight: 200,
                                              width: 1000, spacing: 10)
        XCTAssertGreaterThan(rows.count, 1, "12 squares should need several rows")
        // Every row except the last is justified to the full width.
        for row in rows.dropLast() {
            let widths = row.items.reduce(CGFloat(0)) { $0 + $1.width }
            let gaps = CGFloat(row.items.count - 1) * 10
            XCTAssertEqual(widths + gaps, 1000, accuracy: 0.5)
        }
    }

    func testEveryItemInARowSharesOneHeight() {
        // Mixed shapes: tall, square, wide.
        let aspects: [CGFloat] = [1.5, 1.0, 0.6, 1.2, 0.8, 1.0, 1.4, 0.7]
        let r = JustifiedRowsGeometry.compute(aspects: aspects, targetHeight: 180,
                                              width: 900, spacing: 12)
        XCTAssertEqual(r.frames.count, aspects.count)
        // Group frames by their y origin — that's a row.
        let byRow = Dictionary(grouping: r.frames.indices) { i in
            (r.frames[i].minY * 10).rounded()
        }
        for (_, indices) in byRow {
            let h = r.frames[indices[0]].height
            for i in indices {
                XCTAssertEqual(r.frames[i].height, h, accuracy: 0.5)
            }
        }
    }

    func testItemWidthFollowsItsOwnAspect() {
        // A wide image (aspect 0.5 → twice as wide as tall) must be twice the
        // width of a square at the same row height.
        let r = JustifiedRowsGeometry.compute(aspects: [0.5, 1.0],
                                              targetHeight: 100,
                                              width: 1000, spacing: 0)
        XCTAssertEqual(r.frames[0].width, r.frames[1].width * 2, accuracy: 0.5)
    }

    func testTrailingPartialRowIsNotStretched() {
        // One lone tall image can't fill a row on its own without becoming a
        // full-width panorama. It must stay at the target height.
        let rows = JustifiedRowsGeometry.rows(aspects: [3.0], targetHeight: 150,
                                              width: 1000, spacing: 10)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].height, 150, accuracy: 0.5)
        // Aspect 3 (tall) at height 150 → 50 wide, nowhere near 1000.
        XCTAssertEqual(rows[0].items[0].width, 50, accuracy: 0.5)
    }

    func testExtremeAspectsAreClampedForLayout() {
        // A pathological panorama (aspect 0.001 → 1000× wider than tall) would
        // otherwise force a sub-pixel row height.
        let rows = JustifiedRowsGeometry.rows(aspects: [0.001], targetHeight: 200,
                                              width: 1000, spacing: 0)
        XCTAssertEqual(rows.count, 1)
        // Clamped to minAspect 0.1 → width = height / 0.1 = 10 × height, and the
        // row closes justified at width 1000 → height 100.
        XCTAssertEqual(rows[0].height, 100, accuracy: 0.5)
    }

    func testZeroSpacingPacksFlush() {
        let aspects = [CGFloat](repeating: 1, count: 8)
        let r = JustifiedRowsGeometry.compute(aspects: aspects, targetHeight: 200,
                                              width: 800, spacing: 0)
        // Four squares of 200 fill 800 exactly with no gaps.
        XCTAssertEqual(r.frames[0].minX, 0, accuracy: 0.5)
        XCTAssertEqual(r.frames[1].minX, 200, accuracy: 0.5)
        XCTAssertEqual(r.frames[3].maxX, 800, accuracy: 0.5)
    }

    func testCaptionHeightAddsToEveryTile() {
        let aspects = [CGFloat](repeating: 1, count: 4)
        let plain = JustifiedRowsGeometry.compute(aspects: aspects, targetHeight: 200,
                                                  width: 800, spacing: 0)
        let capped = JustifiedRowsGeometry.compute(aspects: aspects, targetHeight: 200,
                                                   width: 800, spacing: 0,
                                                   captionHeight: 18)
        XCTAssertEqual(capped.frames[0].height - plain.frames[0].height, 18,
                       accuracy: 0.5)
        XCTAssertEqual(capped.totalHeight - plain.totalHeight, 18, accuracy: 0.5)
    }

    func testNonPositiveAspectIsTreatedAsSquare() {
        let r = JustifiedRowsGeometry.compute(aspects: [0, -1], targetHeight: 100,
                                              width: 1000, spacing: 0)
        XCTAssertEqual(r.frames[0].width, r.frames[1].width, accuracy: 0.5)
    }

    /// A narrow window at maximum spacing with very tall images: each item adds
    /// almost no width, so a row can accumulate enough items that the GUTTERS
    /// alone exceed the row width. Justifying then divides by a negative usable
    /// width and collapses the whole row to a 1pt sliver. The row must close
    /// before that instead.
    func testRowClosesBeforeGuttersSwallowTheWidth() {
        let aspects = [CGFloat](repeating: 10, count: 20)   // extremely tall
        let rows = JustifiedRowsGeometry.rows(aspects: aspects, targetHeight: 13,
                                              width: 300, spacing: 28)
        XCTAssertFalse(rows.isEmpty)
        for row in rows {
            let gaps = CGFloat(row.items.count - 1) * 28
            XCTAssertLessThan(gaps, 300, "gutters alone must not exceed the row width")
            XCTAssertGreaterThan(row.height, 1,
                                 "a row must never collapse to a sliver")
        }
        // Everything still gets placed exactly once.
        let placed = rows.flatMap { $0.items.map(\.index) }.sorted()
        XCTAssertEqual(placed, Array(0..<20))
    }

    func testTotalHeightHasNoTrailingSpacing() {
        let aspects = [CGFloat](repeating: 1, count: 8)
        let r = JustifiedRowsGeometry.compute(aspects: aspects, targetHeight: 200,
                                              width: 800, spacing: 10)
        let lastBottom = r.frames.map(\.maxY).max() ?? 0
        XCTAssertEqual(r.totalHeight, lastBottom, accuracy: 0.5)
    }
}
