//
//  SidecarHydrateNonImageTests.swift
//  MuseTests
//
//  `SidecarHydrator` skips a file whose `analyzed_hash` already equals its
//  content hash — "already analyzed at this content, nothing to import".
//
//  That shortcut is only sound for the kinds the analysis pass DESCRIBES. Once
//  non-image kinds are stamped too (so `analyzePending` stops re-queuing a PDF
//  on every folder visit), the stamp says nothing about whether a sidecar
//  carries something new — and treating it as "nothing to import" permanently
//  blocks a note, rating, manual tag or edit made on another device from ever
//  arriving for a PDF, video, archive or document.
//
//  Silent, and it only shows up as "my note didn't sync", so it is pinned here.
//

import XCTest
@testable import Muse

final class SidecarHydrateNonImageTests: XCTestCase {

    func testPhotoKindsAreExactlyTheAnalyzedOnes() {
        XCTAssertTrue(AssetKind.image.isPhotoKind)
        XCTAssertTrue(AssetKind.raw.isPhotoKind)
        XCTAssertTrue(AssetKind.psd.isPhotoKind)
        for kind in [AssetKind.pdf, .markdown, .office, .archive, .video,
                     .audio, .text, .code, .svg, .font, .model3d] {
            XCTAssertFalse(kind.isPhotoKind,
                           "\(kind.rawValue) never reaches Vision, so its stamp describes nothing")
        }
    }

    /// The gate itself, as the hydrator applies it.
    func testStampedNonImageStillHydrates() {
        XCTAssertFalse(
            SidecarHydrator.alreadyDescribed(kind: "pdf", analyzedHash: "h1", contentHash: "h1"),
            "a stamped PDF must still accept a sidecar carrying a note or rating")
    }

    func testStampedImageStillSkips() {
        XCTAssertTrue(
            SidecarHydrator.alreadyDescribed(kind: "image", analyzedHash: "h1", contentHash: "h1"),
            "an image analyzed at these bytes has nothing to import — unchanged")
    }

    func testUnstampedImageHydrates() {
        XCTAssertFalse(
            SidecarHydrator.alreadyDescribed(kind: "image", analyzedHash: nil, contentHash: "h1"))
    }

    func testImageAnalyzedAtDifferentBytesHydrates() {
        XCTAssertFalse(
            SidecarHydrator.alreadyDescribed(kind: "image", analyzedHash: "old", contentHash: "new"))
    }
}
