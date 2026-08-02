//
//  SocialPresetTests.swift
//  MuseTests
//
//  Pins the ENTIRE preset table — a changed number here is a deliberate
//  constant edit, never an accident.
//
//  Four presets since 2026-08-02, down from twelve. The trim is asserted, not
//  just the survivors: a test that only checked what remained would go green if
//  someone quietly re-added Glass.
//

import XCTest
@testable import Muse

final class SocialPresetTests: XCTestCase {
    private func preset(_ id: String) -> SocialPreset {
        SocialPreset.all.first { $0.id == id }!
    }

    func testExactlyFourPresetsWithUniqueIDs() {
        XCTAssertEqual(SocialPreset.all.count, 4)
        XCTAssertEqual(Set(SocialPreset.all.map(\.id)).count, 4)
    }

    func testTheTableIsExactlyTheseFourInThisOrder() {
        XCTAssertEqual(SocialPreset.all.map(\.id),
                       ["instagram", "ig-story", "x", "facebook"])
    }

    /// The dropped platforms stay dropped. Their absence is the assertion —
    /// re-adding one is a product decision, not a refactor.
    func testTheRetiredPresetsAreGone() {
        let ids = Set(SocialPreset.all.map(\.id))
        for gone in ["glass", "flickr", "pinterest", "threads",
                     "ig-feed-portrait", "ig-grid", "ig-square",
                     "ig-landscape", "ig-carousel"] {
            XCTAssertFalse(ids.contains(gone), "\(gone) came back")
        }
    }

    /// Long-edge, not a fixed box: Instagram accepts 1.91:1 through 4:5, so a
    /// 1080 long edge hands it a correctly-sized file at the photo's OWN aspect
    /// with no crop step. That's the reason the four IG variants collapsed.
    func testInstagram() {
        let p = preset("instagram")
        XCTAssertEqual(p.kind, .longEdge(1080))
        XCTAssertEqual(p.quality, 0.88)
        XCTAssertEqual(p.byteTargetKB, 800)
        XCTAssertEqual(p.sharpen, .standard)
        XCTAssertFalse(p.exifDefaultOn)
        XCTAssertFalse(p.uniformMulti)
        XCTAssertFalse(p.storySafeZones)
        XCTAssertNil(p.warningKey)
        XCTAssertFalse(p.isFixed, "a fixed Instagram preset would force a crop again")
    }

    /// Story is the one genuinely FIXED frame — the platform draws chrome over
    /// it, which is what the safe zones exist to show.
    func testInstagramStory() {
        let p = preset("ig-story")
        XCTAssertEqual(p.kind, .fixed(width: 1080, height: 1920))
        XCTAssertEqual(p.quality, 0.88)
        XCTAssertEqual(p.byteTargetKB, 800)
        XCTAssertEqual(p.sharpen, .standard)
        XCTAssertFalse(p.exifDefaultOn)
        XCTAssertTrue(p.storySafeZones)
        XCTAssertNil(p.warningKey)
    }

    func testX() {
        let p = preset("x")
        XCTAssertEqual(p.kind, .longEdge(4096))
        XCTAssertEqual(p.quality, 0.90)
        // X carries no byte TARGET — its five hard invariants apply instead.
        XCTAssertNil(p.byteTargetKB)
        XCTAssertEqual(p.sharpen, .light)
        XCTAssertFalse(p.exifDefaultOn)
        XCTAssertNil(p.warningKey)
    }

    func testFacebook() {
        let p = preset("facebook")
        XCTAssertEqual(p.kind, .longEdge(2048))
        XCTAssertEqual(p.quality, 0.85)
        XCTAssertEqual(p.byteTargetKB, 1000)
        XCTAssertEqual(p.sharpen, .standard)
        XCTAssertFalse(p.exifDefaultOn)
    }

    /// Nothing left carries EXIF by default. The two that did were the
    /// photography platforms (Flickr, Glass), and both are gone — so the
    /// default is now uniformly off and the toggle is the only way on.
    func testNoPresetShipsMetadataByDefault() {
        for p in SocialPreset.all {
            XCTAssertFalse(p.exifDefaultOn, "\(p.id) defaults to carrying EXIF")
        }
    }

    func testOnlyFixedPresetsReportAnAspect() {
        for p in SocialPreset.all {
            XCTAssertEqual(p.isFixed, p.targetAspect != nil, p.id)
        }
        XCTAssertEqual(preset("ig-story").targetAspect, 1080.0 / 1920.0)
    }
}
