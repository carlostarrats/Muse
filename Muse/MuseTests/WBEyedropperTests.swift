//
//  WBEyedropperTests.swift
//  MuseTests
//
//  Was CanvasPointMathTests. The CanvasPointMath cases went with that enum in
//  the editor canvas refactor (2026-08-02) — see EditorCanvasGeometryTests for
//  the geometry that replaced it.
//

import XCTest
@testable import Muse

final class WBEyedropperTests: XCTestCase {
    /// A neutral gray sample means "this is already correct" — the solve must
    /// leave both sliders alone rather than nudging them.
    func testNeutralGrayResolvesToNoOffset() {
        let solved = WBEyedropper.solve(sampledColor: (r: 0.5, g: 0.5, b: 0.5))
        XCTAssertEqual(solved.temperature, 0, accuracy: 0.01)
        XCTAssertEqual(solved.tint, 0, accuracy: 0.01)
    }

    /// A sample that's too WARM (red-heavy) has to pull temperature DOWN —
    /// getting this sign wrong doubles the cast instead of removing it.
    func testWarmSampleCoolsTheImage() {
        let solved = WBEyedropper.solve(sampledColor: (r: 0.8, g: 0.5, b: 0.3))
        XCTAssertLessThan(solved.temperature, 0)
    }

    func testCoolSampleWarmsTheImage() {
        let solved = WBEyedropper.solve(sampledColor: (r: 0.3, g: 0.5, b: 0.8))
        XCTAssertGreaterThan(solved.temperature, 0)
    }

    func testMagentaSampleMovesTintTowardGreen() {
        let solved = WBEyedropper.solve(sampledColor: (r: 0.7, g: 0.4, b: 0.7))
        XCTAssertLessThan(solved.tint, 0)
    }

    func testResultIsAlwaysInSliderRange() {
        for sample in [(r: 1.0, g: 0.001, b: 0.001), (r: 0.0, g: 0.0, b: 0.0),
                       (r: 0.001, g: 1.0, b: 0.001)] {
            let solved = WBEyedropper.solve(sampledColor: sample)
            XCTAssertTrue((-1...1).contains(solved.temperature))
            XCTAssertTrue((-1...1).contains(solved.tint))
        }
    }
}
