//
//  SocialPresetTests.swift
//  MuseTests
//
//  Pins the ENTIRE preset table — a changed number here is a deliberate
//  constant edit, never an accident.
//

import XCTest
@testable import Muse

final class SocialPresetTests: XCTestCase {
    private func preset(_ id: String) -> SocialPreset {
        SocialPreset.all.first { $0.id == id }!
    }

    func testExactlyTwelvePresetsWithUniqueIDs() {
        XCTAssertEqual(SocialPreset.all.count, 12)
        XCTAssertEqual(Set(SocialPreset.all.map(\.id)).count, 12)
    }

    func testIGFeedPortrait() {
        let p = preset("ig-feed-portrait")
        XCTAssertEqual(p.kind, .fixed(width: 1080, height: 1350))
        XCTAssertEqual(p.quality, 0.88)
        XCTAssertEqual(p.byteTargetKB, 800)
        XCTAssertEqual(p.sharpen, .standard)
        XCTAssertFalse(p.exifDefaultOn)
        XCTAssertFalse(p.uniformMulti)
        XCTAssertFalse(p.storySafeZones)
        XCTAssertNotNil(p.warningKey)
    }

    func testIGGrid() {
        let p = preset("ig-grid")
        XCTAssertEqual(p.kind, .fixed(width: 1080, height: 1440))
        XCTAssertEqual(p.quality, 0.88)
        XCTAssertEqual(p.byteTargetKB, 800)
        XCTAssertEqual(p.sharpen, .standard)
        XCTAssertNotNil(p.warningKey)
    }

    func testIGSquare() {
        let p = preset("ig-square")
        XCTAssertEqual(p.kind, .fixed(width: 1080, height: 1080))
        XCTAssertEqual(p.quality, 0.88)
        XCTAssertEqual(p.byteTargetKB, 800)
        XCTAssertNil(p.warningKey)
    }

    func testIGLandscape() {
        let p = preset("ig-landscape")
        XCTAssertEqual(p.kind, .fixed(width: 1080, height: 566))
        XCTAssertEqual(p.quality, 0.88)
        XCTAssertEqual(p.byteTargetKB, 800)
    }

    func testIGStory() {
        let p = preset("ig-story")
        XCTAssertEqual(p.kind, .fixed(width: 1080, height: 1920))
        XCTAssertTrue(p.storySafeZones)
        XCTAssertFalse(p.uniformMulti)
    }

    func testIGCarousel() {
        let p = preset("ig-carousel")
        XCTAssertEqual(p.kind, .fixed(width: 1080, height: 1350))
        XCTAssertTrue(p.uniformMulti)
        XCTAssertNotNil(p.warningKey)
    }

    func testThreads() {
        let p = preset("threads")
        XCTAssertEqual(p.kind, .fixed(width: 1080, height: 1350))
        XCTAssertEqual(p.quality, 0.88)
        XCTAssertFalse(p.uniformMulti)
    }

    func testX() {
        let p = preset("x")
        XCTAssertEqual(p.kind, .longEdge(4096))
        XCTAssertEqual(p.quality, 0.90)
        XCTAssertNil(p.byteTargetKB)
        XCTAssertEqual(p.sharpen, .light)
        XCTAssertFalse(p.exifDefaultOn)
        // X's hard invariants apply instead of an advisory.
        XCTAssertNil(p.warningKey)
    }

    func testFacebook() {
        let p = preset("facebook")
        XCTAssertEqual(p.kind, .longEdge(2048))
        XCTAssertEqual(p.quality, 0.85)
        XCTAssertEqual(p.byteTargetKB, 1000)
        XCTAssertEqual(p.sharpen, .standard)
    }

    func testPinterest() {
        let p = preset("pinterest")
        XCTAssertEqual(p.kind, .fixed(width: 1000, height: 1500))
        XCTAssertEqual(p.quality, 0.90)
        XCTAssertNil(p.byteTargetKB)
    }

    func testFlickr() {
        let p = preset("flickr")
        XCTAssertEqual(p.kind, .original)
        XCTAssertEqual(p.quality, 0.95)
        XCTAssertEqual(p.sharpen, .none)
        XCTAssertTrue(p.exifDefaultOn)
    }

    func testGlass() {
        let p = preset("glass")
        XCTAssertEqual(p.kind, .longEdge(4096))
        XCTAssertEqual(p.quality, 0.92)
        XCTAssertEqual(p.sharpen, .light)
        XCTAssertTrue(p.exifDefaultOn)
    }

    func testOnlyFixedPresetsReportAnAspect() {
        for p in SocialPreset.all {
            XCTAssertEqual(p.isFixed, p.targetAspect != nil, p.id)
        }
        XCTAssertEqual(preset("ig-square").targetAspect, 1)
    }
}
