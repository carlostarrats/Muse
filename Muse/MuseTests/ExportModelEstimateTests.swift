//
//  ExportModelEstimateTests.swift
//  MuseTests
//
//  The card's "Est. file size" read "—" forever in the running app, which the
//  GUI drive caught and no unit test could have: every piece underneath it was
//  green. These drive `ExportModel` directly, between the renderer (already
//  covered by ImageExportRenderTests) and the view, which is where the fault
//  actually was.
//

import XCTest
import ImageIO
import UniformTypeIdentifiers
@testable import Muse

@MainActor
final class ExportModelEstimateTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("export-model-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func preview(_ url: URL) throws -> CGImage {
        let src = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        return try XCTUnwrap(CGImageSourceCreateThumbnailAtIndex(src, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 2048,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ] as CFDictionary))
    }

    /// The whole chain the card relies on: a preview arrives, the estimate runs,
    /// a number lands. This is what was silently producing nil.
    func testEstimateResolvesOnceThePreviewArrives() async throws {
        let src = try SocialFixtures.makeJPEG(width: 1600, height: 1200,
                                              name: "model", in: dir)
        let model = ExportModel(urls: [src])
        model.settings.format = .jpeg

        // No preview yet — the card's opening state.
        await model.refreshEstimate(outputPixelCount: 1600 * 1200)
        XCTAssertNil(model.estimatedBytes, "no preview should mean no number, not a wrong one")

        model.previewImage = try preview(src)
        await model.refreshEstimate(outputPixelCount: 1600 * 1200)
        XCTAssertNotNil(model.estimatedBytes,
                        "the estimate never resolved even with a preview — this is the '—' bug")
        XCTAssertGreaterThan(model.estimatedBytes ?? 0, 0)
    }

    /// The estimate must track the quality slider, or the readout is decoration.
    func testEstimateFollowsQuality() async throws {
        let src = try SocialFixtures.makeJPEG(width: 1600, height: 1200, content: .noise,
                                              name: "modelq", in: dir)
        let model = ExportModel(urls: [src])
        model.settings.format = .jpeg
        model.previewImage = try preview(src)

        model.settings.quality = 0.3
        await model.refreshEstimate(outputPixelCount: 1600 * 1200)
        let low = try XCTUnwrap(model.estimatedBytes)

        model.settings.quality = 0.95
        await model.refreshEstimate(outputPixelCount: 1600 * 1200)
        let high = try XCTUnwrap(model.estimatedBytes)

        XCTAssertLessThan(low, high)
    }

    /// A social preset has no estimate — its own size row states the output —
    /// and asking for one must clear the number rather than leave a stale one.
    func testSelectingASocialPresetClearsTheEstimate() async throws {
        let src = try SocialFixtures.makeJPEG(width: 800, height: 600,
                                              name: "modelsocial", in: dir)
        let model = ExportModel(urls: [src])
        model.previewImage = try preview(src)
        await model.refreshEstimate(outputPixelCount: 800 * 600)
        XCTAssertNotNil(model.estimatedBytes)

        model.selectPreset(SocialPreset.all[0])
        await model.refreshEstimate(outputPixelCount: 800 * 600)
        XCTAssertNil(model.estimatedBytes, "a stale format estimate survived into the social branch")
    }

    /// Zero is what the card passes before the photo's dimensions resolve.
    /// It must produce no number, never a divide-by-zero or a bogus one.
    func testZeroOutputPixelsProducesNoNumber() async throws {
        let src = try SocialFixtures.makeJPEG(width: 400, height: 300,
                                              name: "modelzero", in: dir)
        let model = ExportModel(urls: [src])
        model.previewImage = try preview(src)
        await model.refreshEstimate(outputPixelCount: 0)
        XCTAssertNil(model.estimatedBytes)
    }
}
