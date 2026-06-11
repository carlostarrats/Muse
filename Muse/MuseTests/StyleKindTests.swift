import XCTest
@testable import Muse

final class StyleKindTests: XCTestCase {
    func testScreenshot() {
        XCTAssertEqual(StyleKind.classify(labels: ["computer screen": 0.7],
                                          width: 2880, height: 1800,
                                          ocrLength: 900, faceCount: 0), "screenshot")
    }
    func testPoster() {
        XCTAssertEqual(StyleKind.classify(labels: ["poster": 0.8],
                                          width: 800, height: 1200,
                                          ocrLength: 60, faceCount: 0), "poster")
    }
    func testIllustration() {
        XCTAssertEqual(StyleKind.classify(labels: ["illustration": 0.6, "drawing": 0.5],
                                          width: 1000, height: 1000,
                                          ocrLength: 0, faceCount: 0), "illustration")
    }
    func testDiagram() {
        XCTAssertEqual(StyleKind.classify(labels: ["diagram": 0.5],
                                          width: 1400, height: 900,
                                          ocrLength: 400, faceCount: 0), "diagram")
    }
    func testDefaultPhoto() {
        XCTAssertEqual(StyleKind.classify(labels: ["dog": 0.9, "grass": 0.5],
                                          width: 4000, height: 3000,
                                          ocrLength: 0, faceCount: 0), "photo")
    }
}
