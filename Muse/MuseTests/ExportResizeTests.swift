//
//  ExportResizeTests.swift
//  MuseTests
//
//  The resize maths for the general export. The load-bearing assertion here is
//  never-upscale: it is a GLOBAL rule (SocialRender holds it too), because
//  enlarging a photo to hit a number the user typed produces a bigger file that
//  looks worse, and no one has ever wanted that.
//

import XCTest
@testable import Muse

final class ExportResizeTests: XCTestCase {
    func testOriginalReturnsSourceSize() {
        let s = CGSize(width: 4000, height: 3000)
        XCTAssertEqual(ExportResize.original.targetSize(for: s), s)
    }

    func testLongEdgeScalesTheLongSideAndKeepsAspect() {
        let t = ExportResize.longEdge(2000).targetSize(for: CGSize(width: 4000, height: 3000))
        XCTAssertEqual(t.width, 2000, accuracy: 0.5)
        XCTAssertEqual(t.height, 1500, accuracy: 0.5)
    }

    func testLongEdgeUsesTheTallSideForAPortraitSource() {
        let t = ExportResize.longEdge(1000).targetSize(for: CGSize(width: 600, height: 1200))
        XCTAssertEqual(t.height, 1000, accuracy: 0.5)
        XCTAssertEqual(t.width, 500, accuracy: 0.5)
    }

    func testNeverUpscalesOnLongEdge() {
        let s = CGSize(width: 800, height: 600)
        XCTAssertEqual(ExportResize.longEdge(4000).targetSize(for: s), s)
    }

    func testFitWithinShrinksToTheTighterBound() {
        let t = ExportResize.fitWithin(width: 1000, height: 1000)
            .targetSize(for: CGSize(width: 4000, height: 2000))
        XCTAssertEqual(t.width, 1000, accuracy: 0.5)
        XCTAssertEqual(t.height, 500, accuracy: 0.5)
    }

    func testFitWithinIsBoundedByHeightWhenThatIsTighter() {
        let t = ExportResize.fitWithin(width: 4000, height: 500)
            .targetSize(for: CGSize(width: 2000, height: 1000))
        XCTAssertEqual(t.height, 500, accuracy: 0.5)
        XCTAssertEqual(t.width, 1000, accuracy: 0.5)
    }

    func testNeverUpscalesOnFitWithin() {
        let s = CGSize(width: 300, height: 200)
        XCTAssertEqual(ExportResize.fitWithin(width: 4000, height: 4000).targetSize(for: s), s)
    }

    /// A zero-sized source can only come from a corrupt header, and it must not
    /// divide by zero on the way to failing.
    func testDegenerateSourceDoesNotDivideByZero() {
        let t = ExportResize.longEdge(1000).targetSize(for: CGSize(width: 0, height: 0))
        XCTAssertTrue(t.width >= 1 && t.height >= 1)
        XCTAssertTrue(t.width.isFinite && t.height.isFinite)
    }

    func testResizeRoundTripsThroughCodable() throws {
        for value: ExportResize in [.original, .longEdge(2048), .fitWithin(width: 800, height: 600)] {
            let data = try JSONEncoder().encode(value)
            XCTAssertEqual(try JSONDecoder().decode(ExportResize.self, from: data), value)
        }
    }
}
