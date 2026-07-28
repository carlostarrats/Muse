import XCTest
import CoreGraphics
@testable import Muse

/// EXIF orientations 5–8 are the 90°/270° rotations: the stored pixel buffer is
/// landscape but the image DISPLAYS as portrait. Every shape lookup in Muse
/// must report the display shape, or an analyzed rotated photo lays out
/// differently from an unanalyzed one sitting beside it.
final class ImageOrientationTests: XCTestCase {

    func testUprightOrientationsKeepDimensions() {
        for orientation in 1...4 {
            let s = ImageHeaderSizeCache.displaySize(width: 4000, height: 3000,
                                                     orientation: orientation)
            XCTAssertEqual(s.width, 4000, "orientation \(orientation)")
            XCTAssertEqual(s.height, 3000, "orientation \(orientation)")
        }
    }

    func testRotatedOrientationsSwapDimensions() {
        for orientation in 5...8 {
            let s = ImageHeaderSizeCache.displaySize(width: 4000, height: 3000,
                                                     orientation: orientation)
            XCTAssertEqual(s.width, 3000, "orientation \(orientation)")
            XCTAssertEqual(s.height, 4000, "orientation \(orientation)")
        }
    }

    func testOutOfRangeOrientationIsTreatedAsUpright() {
        // A corrupt or absent orientation tag must not rotate anything.
        for orientation in [0, 9, -1, 99] {
            let s = ImageHeaderSizeCache.displaySize(width: 4000, height: 3000,
                                                     orientation: orientation)
            XCTAssertEqual(s.width, 4000, "orientation \(orientation)")
            XCTAssertEqual(s.height, 3000, "orientation \(orientation)")
        }
    }

    func testDisplaySizeAgreesWithTheGridAspectConvention() {
        // AspectRatioCache works in height ÷ width. A rotated 4000×3000 file
        // displays 3000×4000, i.e. aspect 4/3 — TALL.
        let s = ImageHeaderSizeCache.displaySize(width: 4000, height: 3000,
                                                 orientation: 6)
        XCTAssertGreaterThan(s.height / s.width, 1)
    }
}
