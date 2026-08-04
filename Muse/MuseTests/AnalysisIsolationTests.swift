//
//  AnalysisIsolationTests.swift
//  MuseTests
//
//  The analysis pass's per-image post-processing must not run on the main actor.
//
//  The project builds with `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, so a
//  pure helper that simply forgets the `nonisolated` marker is main-actor
//  isolated — silently, with nothing at the call site to show it. That is what
//  had happened to the whole tail of `VisionTagger.analyze`: `VisionServices`
//  is `nonisolated` and did its decode/classify/OCR off-main, and then every
//  line AFTER the `await` resumed on the main thread. The palette step alone
//  measured 22 ms per 4096×2731 raster, once per analyzed photo.
//
//  These tests are COMPILE-TIME assertions. Each body calls the helper from a
//  `nonisolated` context with no `await`; if any of them regains main-actor
//  isolation, this file stops compiling. That is deliberately a harder failure
//  than an assertion — the defect has no runtime symptom to assert on, only a
//  stutter, which is exactly why it survived unnoticed.
//

import XCTest
@testable import Muse

final class AnalysisIsolationTests: XCTestCase {

    /// Not `@MainActor`, and nothing here may `await` — that is the test.
    nonisolated private func callEveryPostVisionHelper() -> Bool {
        let pixels: [(Double, Double, Double)] = [(0.1, 0.2, 0.3), (0.9, 0.8, 0.7)]
        _ = PaletteExtractor.kmeansWeighted(pixels: pixels, k: 2, seed: 7)
        _ = PaletteExtractor.kmeansHex(pixels: pixels, k: 2, seed: 7)
        _ = ClassificationCuration.curate(["dog": 0.9])
        _ = ColorTagger.tags(fromWeighted: [("#ff0000", 0.8)])
        _ = StyleKind.classify(labels: ["dog": 0.9], width: 100, height: 100,
                               ocrLength: 0, faceCount: 0)
        return true
    }

    func testPostVisionHelpersAreCallableOffTheMainActor() {
        XCTAssertTrue(callEveryPostVisionHelper())
    }

    /// The same guarantee for the tagger itself, and for the protocol it
    /// satisfies — a `@MainActor` protocol requirement would drag every
    /// conformance back on-main no matter how the types are marked.
    nonisolated private func makeTagger() -> any Tagger { VisionTagger() }

    func testTaggerIsUsableOffTheMainActor() {
        XCTAssertEqual(makeTagger().modelVersion, "vision-v1")
    }

    /// `VisionResult` is `nonisolated`, but an EXTENSION takes the module
    /// default on its own — which is how `caption()` ended up main-isolated
    /// while the struct it extends was not.
    nonisolated private func callCaption() -> String {
        VisionResult().caption()
    }

    func testVisionResultCaptionIsCallableOffTheMainActor() {
        XCTAssertFalse(callCaption().isEmpty)
    }

    /// A whole-library archive is tens of MB of JSON. `BackupDocument` had no
    /// marker either, so both the export encode and the restore decode were
    /// pinned to the main thread however far off-main the caller believed it
    /// had moved them.
    nonisolated private func roundTripArchive() throws -> Int {
        let archive = BackupArchive(schema: 1, created_at: 0, app_version: nil,
                                    roots: [], files: [], collections: [], stars: [])
        return try BackupDocument.decode(BackupDocument.encode(archive)).schema
    }

    func testBackupDocumentCodecIsUsableOffTheMainActor() throws {
        XCTAssertEqual(try roundTripArchive(), 1)
    }
}
