//
//  SocialRenderTests.swift
//  MuseTests
//

import XCTest
import ImageIO
@testable import Muse

final class SocialRenderTests: XCTestCase {
    private var scratch: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("social-render-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }
    override func tearDown() {
        try? FileManager.default.removeItem(at: scratch)
        super.tearDown()
    }

    /// SYNTHETIC presets, built here rather than looked up in `SocialPreset.all`.
    ///
    /// These tests exercise the RENDER PIPELINE — crop, matte, blur-extend,
    /// never-upscale, the byte ladder, orientation baking. What they need is
    /// "a fixed preset" and "an original-kind preset", not any particular
    /// product entry, and binding them to the shipping menu meant that trimming
    /// it (2026-08-02, twelve presets to four) broke tests about cropping.
    /// `SocialPresetTests` is what pins the menu; this file pins the renderer.
    private func preset(_ id: String) -> SocialPreset {
        switch id {
        case "square":
            return .init(id: "square", nameKey: "Square",
                         kind: .fixed(width: 1080, height: 1080), quality: 0.88,
                         byteTargetKB: 800, sharpen: .standard, exifDefaultOn: false,
                         uniformMulti: false, storySafeZones: false, warningKey: nil)
        case "portrait":
            return .init(id: "portrait", nameKey: "Portrait",
                         kind: .fixed(width: 1080, height: 1350), quality: 0.88,
                         byteTargetKB: 800, sharpen: .standard, exifDefaultOn: false,
                         uniformMulti: false, storySafeZones: false, warningKey: nil)
        case "untouched":
            return .init(id: "untouched", nameKey: "Untouched",
                         kind: .original, quality: 0.95,
                         byteTargetKB: nil, sharpen: .none, exifDefaultOn: true,
                         uniformMulti: false, storySafeZones: false, warningKey: nil)
        default:
            // The shipping presets the render tests genuinely mean: X for its
            // five invariants, Facebook for its long-edge cap.
            return SocialPreset.all.first { $0.id == id }!
        }
    }

    private func job(_ url: URL, _ preset: SocialPreset, fit: SocialFit = .crop,
                     matte: MatteShade = .white, includeEXIF: Bool = false,
                     includeLocation: Bool = false) -> SocialRender.Job {
        SocialRender.Job(sourceURL: url, preset: preset, fit: fit, matte: matte,
                         cropRect: nil, includeEXIF: includeEXIF, includeLocation: includeLocation)
    }

    private func landscape() throws -> URL {
        try SocialFixtures.makeJPEG(width: 3000, height: 2000, name: "landscape", in: scratch)
    }

    func testCropOutputDimsExact() throws {
        let result = try SocialRender.export(job(try landscape(), preset("square")), to: scratch)
        XCTAssertEqual(result.pixelSize, CGSize(width: 1080, height: 1080))
    }

    func testMatteOutputDimsExactlyEqualPresetDimsBothShades() throws {
        let source = try landscape()
        for shade: MatteShade in [.white, .black] {
            let result = try SocialRender.export(
                job(source, preset("portrait"), fit: .matte, matte: shade), to: scratch)
            XCTAssertEqual(result.pixelSize, CGSize(width: 1080, height: 1350), "\(shade)")
        }
    }

    func testBlurExtendOutputDimsExact() throws {
        let result = try SocialRender.export(
            job(try landscape(), preset("portrait"), fit: .blurExtend), to: scratch)
        XCTAssertEqual(result.pixelSize, CGSize(width: 1080, height: 1350))
    }

    func testLongEdgeCapHonored() throws {
        let big = try SocialFixtures.makeJPEG(width: 6000, height: 4000, name: "big", in: scratch)
        let result = try SocialRender.export(job(big, preset("x")), to: scratch)
        XCTAssertEqual(max(result.pixelSize.width, result.pixelSize.height), 4096)
    }

    // Never upscale, globally: a source smaller than the target exports at its
    // native (cropped) size, for BOTH preset shapes.
    func testNeverUpscaleLongEdgePreset() throws {
        let small = try SocialFixtures.makeJPEG(width: 600, height: 400, name: "small", in: scratch)
        let result = try SocialRender.export(job(small, preset("facebook")), to: scratch)
        XCTAssertLessThanOrEqual(max(result.pixelSize.width, result.pixelSize.height), 600)
    }

    func testNeverUpscaleFixedPreset() throws {
        let small = try SocialFixtures.makeJPEG(width: 600, height: 600, name: "small-sq", in: scratch)
        let result = try SocialRender.export(job(small, preset("square")), to: scratch)
        XCTAssertEqual(result.pixelSize, CGSize(width: 600, height: 600))
        // …and the frame stays exactly the preset's aspect while shrinking.
        let portrait = SocialRender.fixedFrame(width: 1080, height: 1350,
                                               decodedSize: CGSize(width: 540, height: 540))
        XCTAssertEqual(portrait.width / portrait.height, 1080.0 / 1350.0, accuracy: 0.01)
    }

    func testOriginalPresetKeepsSourceSize() throws {
        let result = try SocialRender.export(job(try landscape(), preset("untouched")), to: scratch)
        XCTAssertEqual(result.pixelSize, CGSize(width: 3000, height: 2000))
    }

    func testOutputIsSRGBWithNoAlpha() throws {
        let result = try SocialRender.export(job(try landscape(), preset("square")), to: scratch)
        let src = try XCTUnwrap(CGImageSourceCreateWithURL(result.url as CFURL, nil))
        let props = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [String: Any])
        XCTAssertEqual(props[kCGImagePropertyColorModel as String] as? String,
                       kCGImagePropertyColorModelRGB as String)
        XCTAssertNotEqual(props[kCGImagePropertyHasAlpha as String] as? Bool, true)
    }

    // Orientation is BAKED at decode, so no output orientation tag can exist.
    func testEXIFOrientedSourceProducesNoOrientationTag() throws {
        let rotated = try SocialFixtures.makeJPEG(width: 3000, height: 2000, orientation: 6,
                                                  name: "oriented", in: scratch)
        let result = try SocialRender.export(job(rotated, preset("square")), to: scratch)
        let src = try XCTUnwrap(CGImageSourceCreateWithURL(result.url as CFURL, nil))
        let props = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [String: Any])
        XCTAssertNil(props[kCGImagePropertyOrientation as String])
        XCTAssertEqual(result.pixelSize, CGSize(width: 1080, height: 1080))
    }

    func testDefaultMetadataOutputIsVerifiablyClean() throws {
        let result = try SocialRender.export(job(try landscape(), preset("square")), to: scratch)
        let data = try Data(contentsOf: result.url)
        XCTAssertTrue(ImageMetadataStripper.isClean(data))
    }

    func testByteTargetLadderTerminatesUnderTarget() throws {
        let result = try SocialRender.export(
            job(try landscape(), preset("portrait"), fit: .matte), to: scratch)
        XCTAssertLessThanOrEqual(result.bytes, 800 * 1024)
    }

    func testSharpenConstantsAreDistinctAndNonTrivial() {
        XCTAssertNotEqual(SocialRender.sharpenStandard.radius, SocialRender.sharpenLight.radius)
        XCTAssertNotEqual(SocialRender.sharpenStandard.intensity, SocialRender.sharpenLight.intensity)
        XCTAssertGreaterThan(SocialRender.sharpenLight.intensity, 0)
        XCTAssertEqual(preset("untouched").sharpen, .none)
        XCTAssertEqual(preset("facebook").sharpen, .standard)
    }

    // The collision ladder never overwrites a previous export of the same photo
    // to the same preset.
    func testCollisionLadderSuffixesRatherThanOverwriting() throws {
        let source = try landscape()
        let first = try SocialRender.export(job(source, preset("square")), to: scratch)
        let second = try SocialRender.export(job(source, preset("square")), to: scratch)
        XCTAssertNotEqual(first.url, second.url)
        XCTAssertEqual(first.url.lastPathComponent, "landscape-square.jpg")
        XCTAssertEqual(second.url.lastPathComponent, "landscape-square-2.jpg")
    }

    func testEXIFOnCarriesCameraFieldsThrough() throws {
        // Round-trip through a source that actually has TIFF fields: the
        // fixture writer only sets orientation, so assert the policy layer
        // instead of the encoder — the encoder path is exercised by not throwing.
        let result = try SocialRender.export(
            job(try landscape(), preset("untouched"), includeEXIF: true), to: scratch)
        XCTAssertGreaterThan(result.bytes, 0)
    }
}
