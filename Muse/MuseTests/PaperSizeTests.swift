import XCTest
import CoreGraphics
@testable import Muse

final class PaperSizeTests: XCTestCase {
    // Portrait point dimensions @ 72 dpi (the spec's size table).
    func testPointDimensions() {
        XCTAssertEqual(PaperSize.elevenByFourteen.size, CGSize(width: 792, height: 1008))
        XCTAssertEqual(PaperSize.letter.size,           CGSize(width: 612, height: 792))
        XCTAssertEqual(PaperSize.legal.size,            CGSize(width: 612, height: 1008))
        XCTAssertEqual(PaperSize.tabloid.size,          CGSize(width: 792, height: 1224))
        XCTAssertEqual(PaperSize.a4.size,               CGSize(width: 595, height: 842))
        XCTAssertEqual(PaperSize.a3.size,               CGSize(width: 842, height: 1191))
    }

    // Every size is portrait (height ≥ width) — no landscape by design.
    func testAllSizesArePortrait() {
        for paper in PaperSize.allCases {
            XCTAssertGreaterThanOrEqual(paper.size.height, paper.size.width,
                                        "\(paper) should be portrait")
        }
    }

    // The default preserves the exporter's original hardcoded page size.
    func testDefaultIsElevenByFourteen() {
        XCTAssertEqual(PaperSize.default, .elevenByFourteen)
        XCTAssertEqual(PaperSize.default.size, CGSize(width: 792, height: 1008))
    }

    // allCases order drives both popup population and the read-back index, so
    // pin it — a reorder here would silently remap the user's selection.
    func testAllCasesOrder() {
        XCTAssertEqual(PaperSize.allCases,
                       [.elevenByFourteen, .letter, .legal, .tabloid, .a4, .a3])
    }
}
