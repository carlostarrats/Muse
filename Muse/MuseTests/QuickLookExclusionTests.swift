//
//  QuickLookExclusionTests.swift
//  MuseTests
//
//  QuickLook previews out-of-process in an AVFoundation instance Muse cannot
//  constrain, so any kind AVFoundation opens must never reach it: a QuickTime
//  reference movie — or an .m4a, the same ISO-BMFF container family — can carry
//  an `rdrf` remote data reference, and resolving it beacons the viewer's IP on
//  mere FOLDER OPEN (thumbnail prewarm), with no click. `AVURLAsset.noNetwork`
//  closes that for Muse's own opens; this rule keeps the file away from the one
//  component that ignores the restriction.
//

import XCTest
@testable import Muse

final class QuickLookExclusionTests: XCTestCase {

    func testAVFoundationBackedKindsAreExcludedFromQuickLook() {
        XCTAssertFalse(ThumbnailCache.mayUseQuickLook(.video))
        XCTAssertFalse(ThumbnailCache.mayUseQuickLook(.audio))
    }

    /// Everything else still uses QuickLook — it is what draws the type icon /
    /// content preview for PDFs, docs and archives, so over-excluding would
    /// regress every non-image tile to a blank.
    func testNonAVKindsStillUseQuickLook() {
        for kind: AssetKind in [.pdf, .svg, .text, .markdown, .code, .office,
                                .model3d, .font, .archive, .unknown] {
            XCTAssertTrue(ThumbnailCache.mayUseQuickLook(kind),
                          "\(kind) should still render via QuickLook")
        }
    }

    /// The audio extensions that make this reachable. `.m4a` is the one that
    /// matters — an MPEG-4 container, same family as the reference movie — but
    /// the rule is applied by KIND, so every audio extension is covered.
    func testAudioContainerExtensionsClassifyAsAudio() {
        for ext in ["m4a", "mp3", "aac", "aiff", "wav", "flac"] {
            let url = URL(fileURLWithPath: "/tmp/probe.\(ext)")
            XCTAssertEqual(AssetKind.classify(url: url, fallback: .unknown), .audio)
            XCTAssertFalse(ThumbnailCache.mayUseQuickLook(
                AssetKind.classify(url: url, fallback: .unknown)))
        }
    }
}
