import XCTest
@testable import Muse

final class CubeLUTParserTests: XCTestCase {

    /// A minimal identity 2×2×2 cube in the spec's R-fastest-varying order.
    private func identity2Cube(title: String? = "Identity") -> String {
        var lines: [String] = []
        if let title { lines.append("TITLE \"\(title)\"") }
        lines.append("# a comment line")
        lines.append("LUT_3D_SIZE 2")
        for b in 0..<2 { for g in 0..<2 { for r in 0..<2 {
            lines.append("\(Double(r)) \(Double(g)) \(Double(b))")
        }}}
        return lines.joined(separator: "\n")
    }

    func testSize2Parses() throws {
        let (lut, title) = try CubeLUTParser.parse(identity2Cube())
        XCTAssertEqual(lut.size, 2)
        XCTAssertEqual(lut.data.count, 2 * 2 * 2 * 3)
        XCTAssertEqual(title, "Identity")
    }

    /// An ASYMMETRIC fixture: only (r=1,g=0,b=0) carries the marker, so any
    /// axis-order mixup fails here rather than producing a plausible-looking
    /// but wrong grade.
    func testRFastestVaryingOrderPinnedByAsymmetricFixture() throws {
        var lines = ["LUT_3D_SIZE 2"]
        let marker = 0.777
        var index = 0
        var markerIndex = -1
        for b in 0..<2 { for g in 0..<2 { for r in 0..<2 {
            if r == 1 && g == 0 && b == 0 {
                lines.append("\(marker) 0.0 0.0"); markerIndex = index
            } else {
                lines.append("0.0 0.0 0.0")
            }
            index += 1
        }}}
        let (lut, _) = try CubeLUTParser.parse(lines.joined(separator: "\n"))
        XCTAssertEqual(lut.data[markerIndex * 3], Float(marker))
    }

    func testMissingTitleReturnsNilTitle() throws {
        XCTAssertNil(try CubeLUTParser.parse(identity2Cube(title: nil)).title)
    }

    func testDefaultDomainIsAccepted() {
        let text = "DOMAIN_MIN 0.0 0.0 0.0\nDOMAIN_MAX 1.0 1.0 1.0\n" + identity2Cube()
        XCTAssertNoThrow(try CubeLUTParser.parse(text))
    }

    /// Refused rather than resampled: a resampled look is a different look
    /// presented under the original's name.
    func testNonDefaultDomainThrowsUnsupportedDomain() {
        let text = "DOMAIN_MIN 0.0 0.0 0.0\nDOMAIN_MAX 2.0 2.0 2.0\nLUT_3D_SIZE 2\n"
            + String(repeating: "0.0 0.0 0.0\n", count: 8)
        XCTAssertThrowsError(try CubeLUTParser.parse(text)) {
            XCTAssertEqual($0 as? CubeLUTParser.ParseError, .unsupportedDomain)
        }
    }

    func testLut1DSizeThrowsNotA3DLUT() {
        let text = "LUT_1D_SIZE 16\n" + String(repeating: "0.0 0.0 0.0\n", count: 16)
        XCTAssertThrowsError(try CubeLUTParser.parse(text)) {
            XCTAssertEqual($0 as? CubeLUTParser.ParseError, .notA3DLUT)
        }
    }

    func testWrongDataLineCountThrowsWrongCount() {
        let text = "LUT_3D_SIZE 2\n" + String(repeating: "0.0 0.0 0.0\n", count: 3)
        XCTAssertThrowsError(try CubeLUTParser.parse(text)) { error in
            guard case .wrongCount(let expected, let got) = error as? CubeLUTParser.ParseError
            else { return XCTFail("expected wrongCount") }
            XCTAssertEqual(expected, 8)
            XCTAssertEqual(got, 3)
        }
    }

    func testBadValueThrowsWithLineNumber() {
        let text = "LUT_3D_SIZE 2\n0.0 0.0 0.0\nNOTANUMBER 0.0 0.0\n"
            + String(repeating: "0.0 0.0 0.0\n", count: 6)
        XCTAssertThrowsError(try CubeLUTParser.parse(text)) { error in
            guard case .badValue(let line) = error as? CubeLUTParser.ParseError
            else { return XCTFail("expected badValue") }
            XCTAssertEqual(line, 3)
        }
    }

    func testSizeAboveMaxSizeThrowsBadSize() {
        XCTAssertThrowsError(try CubeLUTParser.parse("LUT_3D_SIZE 129\n")) {
            XCTAssertEqual($0 as? CubeLUTParser.ParseError, .badSize)
        }
    }

    func testFileAboveMaxBytesThrowsTooLarge() {
        let huge = String(repeating: "x", count: CubeLUTParser.maxFileBytes + 1)
        XCTAssertThrowsError(try CubeLUTParser.parse(huge)) {
            XCTAssertEqual($0 as? CubeLUTParser.ParseError, .tooLarge)
        }
    }

    /// The hash IS the primary key, so stability across runs is the whole
    /// value guarantee behind a `lutHash` reference.
    func testHashIsStableAndSHA256Shaped() throws {
        let (lut, _) = try CubeLUTParser.parse(identity2Cube())
        let hash = CubeLUT.hash(lut)
        XCTAssertEqual(hash, CubeLUT.hash(lut))
        XCTAssertEqual(hash.count, 64)
    }

    func testDifferentDataHashesDifferently() throws {
        let (a, _) = try CubeLUTParser.parse(identity2Cube())
        var lines = ["LUT_3D_SIZE 2"]
        for _ in 0..<8 { lines.append("0.5 0.5 0.5") }
        let (b, _) = try CubeLUTParser.parse(lines.joined(separator: "\n"))
        XCTAssertNotEqual(CubeLUT.hash(a), CubeLUT.hash(b))
    }

    /// Names never enter the hash — re-importing the same file under a new
    /// name must dedupe, not fork.
    func testTitleDoesNotAffectTheHash() throws {
        let (a, _) = try CubeLUTParser.parse(identity2Cube(title: "First"))
        let (b, _) = try CubeLUTParser.parse(identity2Cube(title: "Second"))
        XCTAssertEqual(CubeLUT.hash(a), CubeLUT.hash(b))
    }

    func testSize33ParsesSuccessfully() throws {
        var lines = ["LUT_3D_SIZE 33"]
        for _ in 0..<(33 * 33 * 33) { lines.append("0.5 0.5 0.5") }
        XCTAssertEqual(try CubeLUTParser.parse(lines.joined(separator: "\n")).lut.size, 33)
    }
}
