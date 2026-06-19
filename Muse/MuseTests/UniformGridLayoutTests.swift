import XCTest
import CoreGraphics
@testable import Muse

/// The fixed-ratio Image Layout reuses MasonryGeometry by feeding every tile
/// the same aspect. These tests lock the invariant that equal aspects pack
/// into an exact, aligned, row-major grid (what the feature depends on).
final class UniformGridLayoutTests: XCTestCase {

    func testUniformAspectsFormAlignedRows() {
        // 7 items, 3 columns, square tiles.
        let aspects = [CGFloat](repeating: 1, count: 7)
        let r = MasonryGeometry.compute(aspects: aspects, columns: 3,
                                        width: 320, spacing: 10)
        XCTAssertEqual(r.frames.count, 7)

        // All tiles share one width and one height.
        let w = r.frames[0].width
        let h = r.frames[0].height
        for f in r.frames {
            XCTAssertEqual(f.width, w, accuracy: 0.5)
            XCTAssertEqual(f.height, h, accuracy: 0.5)
        }

        // First row sits at y == 0; row-major fill (item i in column i % 3).
        XCTAssertEqual(r.frames[0].minY, 0, accuracy: 0.5)
        XCTAssertEqual(r.frames[1].minY, 0, accuracy: 0.5)
        XCTAssertEqual(r.frames[2].minY, 0, accuracy: 0.5)
        // Item 3 starts the second row, back in column 0 (same x as item 0).
        XCTAssertEqual(r.frames[3].minX, r.frames[0].minX, accuracy: 0.5)
        XCTAssertGreaterThan(r.frames[3].minY, 0)
    }

    func testTallAspectMakesTallerTiles() {
        let square = MasonryGeometry.compute(aspects: [1, 1], columns: 2,
                                             width: 200, spacing: 0)
        let tall = MasonryGeometry.compute(aspects: [16.0/9, 16.0/9], columns: 2,
                                           width: 200, spacing: 0)
        XCTAssertGreaterThan(tall.frames[0].height, square.frames[0].height)
    }
}
