//
//  MoodTests.swift
//  MuseTests
//
//  Background moods (polish spec §4): every named mood has a hand-tuned
//  palette; Ink matches the Graph scene; persistence round-trips.
//

import XCTest
import SwiftUI
@testable import Muse

final class MoodTests: XCTestCase {
    func testNamedMoodsHavePalettesAutoDoesNot() {
        for mood in Mood.allCases where mood != .auto {
            XCTAssertNotNil(mood.palette, "\(mood) needs a hand-tuned palette")
        }
        XCTAssertNil(Mood.auto.palette, "auto is computed, not hand-tuned")
    }

    func testInkMatchesGraphSceneBackground() {
        let p = Mood.ink.palette!
        XCTAssertEqual(p.backgroundRGB.r, 0.066, accuracy: 0.001)
        XCTAssertEqual(p.backgroundRGB.g, 0.066, accuracy: 0.001)
        XCTAssertEqual(p.backgroundRGB.b, 0.078, accuracy: 0.001)
        XCTAssertEqual(p.scheme, .dark)
    }

    func testPaperIsThePrototypedWarmBeige() {
        let p = Mood.paper.palette!
        XCTAssertEqual(p.backgroundRGB.r, 0.902, accuracy: 0.001)
        XCTAssertEqual(p.backgroundRGB.g, 0.812, accuracy: 0.001)
        XCTAssertEqual(p.backgroundRGB.b, 0.710, accuracy: 0.001)
        XCTAssertEqual(p.scheme, .light)
    }

    func testSchemes() {
        XCTAssertEqual(Mood.navy.palette!.scheme, .dark)
        XCTAssertEqual(Mood.blush.palette!.scheme, .light)
    }

    func testFallbackPaletteIsInk() {
        XCTAssertEqual(Mood.fallbackPalette, Mood.ink.palette)
    }

    func testPersistenceRoundTrip() {
        let name = "mood-tests-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        defer { d.removePersistentDomain(forName: name) }
        Mood.navy.save(to: d)
        XCTAssertEqual(Mood.load(from: d), .navy)
    }

    func testLoadDefaultsToInk() {
        let d = UserDefaults(suiteName: "mood-tests-\(UUID().uuidString)")!
        XCTAssertEqual(Mood.load(from: d), .ink)
    }
}
