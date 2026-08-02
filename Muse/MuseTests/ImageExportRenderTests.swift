//
//  ImageExportRenderTests.swift
//  MuseTests
//
//  The general export pipeline, end to end against real files. Fixtures are
//  generated at runtime via SocialFixtures rather than checked in, for the
//  reasons that file's header gives.
//
//  Two of these are guarding rules rather than behaviour: metadata-off output
//  must be PROVABLY clean, and a collision must never overwrite. Both are the
//  kind of thing that works today and quietly stops working later.
//

import XCTest
import ImageIO
import UniformTypeIdentifiers
@testable import Muse

final class ImageExportRenderTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("export-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func properties(of url: URL) throws -> [String: Any] {
        let src = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        return try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [String: Any])
    }

    // MARK: - Size

    func testOriginalSizeKeepsTheSourceDimensions() throws {
        let src = try SocialFixtures.makeJPEG(width: 1200, height: 900, name: "orig", in: dir)
        let result = try ImageExportRender.export(
            .init(sourceURL: src, settings: ExportSettings(format: .jpeg)), to: dir)
        XCTAssertEqual(result.pixelSize.width, 1200, accuracy: 0.5)
        XCTAssertEqual(result.pixelSize.height, 900, accuracy: 0.5)
    }

    func testLongEdgeProducesExactDimensions() throws {
        let src = try SocialFixtures.makeJPEG(width: 4000, height: 3000, name: "wide", in: dir)
        let result = try ImageExportRender.export(
            .init(sourceURL: src, settings: ExportSettings(format: .jpeg, resize: .longEdge(1000))),
            to: dir)
        XCTAssertEqual(result.pixelSize.width, 1000, accuracy: 0.5)
        XCTAssertEqual(result.pixelSize.height, 750, accuracy: 0.5)
    }

    func testFitWithinProducesExactDimensions() throws {
        let src = try SocialFixtures.makeJPEG(width: 4000, height: 2000, name: "pano", in: dir)
        let result = try ImageExportRender.export(
            .init(sourceURL: src,
                  settings: ExportSettings(format: .jpeg,
                                           resize: .fitWithin(width: 1000, height: 1000))),
            to: dir)
        XCTAssertEqual(result.pixelSize.width, 1000, accuracy: 0.5)
        XCTAssertEqual(result.pixelSize.height, 500, accuracy: 0.5)
    }

    func testNeverUpscales() throws {
        let src = try SocialFixtures.makeJPEG(width: 400, height: 300, name: "small", in: dir)
        let result = try ImageExportRender.export(
            .init(sourceURL: src, settings: ExportSettings(format: .jpeg, resize: .longEdge(4000))),
            to: dir)
        XCTAssertEqual(result.pixelSize.width, 400, accuracy: 0.5)
        XCTAssertEqual(result.pixelSize.height, 300, accuracy: 0.5)
    }

    // MARK: - Containers

    func testPNGOutputIsAPNG() throws {
        let src = try SocialFixtures.makeJPEG(width: 800, height: 600, name: "topng", in: dir)
        let result = try ImageExportRender.export(
            .init(sourceURL: src, settings: ExportSettings(format: .png)), to: dir)
        XCTAssertEqual(result.url.pathExtension, "png")
        let written = try XCTUnwrap(CGImageSourceCreateWithURL(result.url as CFURL, nil))
        XCTAssertEqual(CGImageSourceGetType(written) as String?, UTType.png.identifier)
    }

    func testTIFFOutputIsATIFF() throws {
        let src = try SocialFixtures.makeJPEG(width: 400, height: 300, name: "totiff", in: dir)
        let result = try ImageExportRender.export(
            .init(sourceURL: src, settings: ExportSettings(format: .tiff)), to: dir)
        XCTAssertEqual(result.url.pathExtension, "tif")
        let written = try XCTUnwrap(CGImageSourceCreateWithURL(result.url as CFURL, nil))
        XCTAssertEqual(CGImageSourceGetType(written) as String?, UTType.tiff.identifier)
    }

    func testHEICOutputIsAHEIC() throws {
        let src = try SocialFixtures.makeJPEG(width: 400, height: 300, name: "toheic", in: dir)
        let result = try ImageExportRender.export(
            .init(sourceURL: src, settings: ExportSettings(format: .heic)), to: dir)
        XCTAssertEqual(result.url.pathExtension, "heic")
        XCTAssertGreaterThan(result.bytes, 0)
    }

    // MARK: - Depth

    /// OutputFormat.tiff16 was nominal before this feature — the case existed
    /// and produced 8-bit. A depth claim the bytes don't support is worse than
    /// no option at all, so this pins the real thing.
    func testSixteenBitTIFFIsActuallySixteenBit() throws {
        let src = try SocialFixtures.makeJPEG(width: 600, height: 400, name: "deep", in: dir)
        let result = try ImageExportRender.export(
            .init(sourceURL: src, settings: ExportSettings(format: .tiff, tiff16: true)), to: dir)
        XCTAssertEqual(try properties(of: result.url)[kCGImagePropertyDepth as String] as? Int, 16)
    }

    func testEightBitTIFFIsEightBit() throws {
        let src = try SocialFixtures.makeJPEG(width: 600, height: 400, name: "shallow", in: dir)
        let result = try ImageExportRender.export(
            .init(sourceURL: src, settings: ExportSettings(format: .tiff, tiff16: false)), to: dir)
        XCTAssertEqual(try properties(of: result.url)[kCGImagePropertyDepth as String] as? Int, 8)
    }

    // MARK: - Metadata

    /// Metadata off must be PROVABLY clean, not merely constructed to be. Same
    /// rule the social and Drive paths hold.
    func testMetadataOffProducesACleanFile() throws {
        let src = try SocialFixtures.makeJPEG(width: 800, height: 600, name: "stripped", in: dir)
        let result = try ImageExportRender.export(
            .init(sourceURL: src, settings: ExportSettings(format: .jpeg, includeEXIF: false)),
            to: dir)
        XCTAssertTrue(ImageMetadataStripper.isClean(try Data(contentsOf: result.url)))
    }

    /// Orientation is BAKED at decode, so no output can carry a tag — a viewer
    /// that ignores the tag and one that honours it must agree.
    func testOutputCarriesNoOrientationTag() throws {
        // 6 = rotate 90°, so the 800×600 stored file displays as 600×800.
        let src = try SocialFixtures.makeJPEG(width: 800, height: 600, orientation: 6,
                                              name: "rot", in: dir)
        let result = try ImageExportRender.export(
            .init(sourceURL: src, settings: ExportSettings(format: .jpeg)), to: dir)
        XCTAssertNil(try properties(of: result.url)[kCGImagePropertyOrientation as String])
        XCTAssertEqual(result.pixelSize.width, 600, accuracy: 0.5)
        XCTAssertEqual(result.pixelSize.height, 800, accuracy: 0.5)
    }

    // MARK: - Naming

    /// Never overwrite. Two exports of one source into one folder produce two
    /// files — this is the only way the feature could destroy a user's data.
    func testCollisionAddsASuffixRatherThanOverwriting() throws {
        let src = try SocialFixtures.makeJPEG(width: 400, height: 300, name: "twice", in: dir)
        let job = ImageExportRender.Job(sourceURL: src, settings: ExportSettings(format: .png))
        let first = try ImageExportRender.export(job, to: dir)
        let second = try ImageExportRender.export(job, to: dir)
        XCTAssertNotEqual(first.url, second.url)
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.url.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.url.path))
        XCTAssertEqual(first.url.lastPathComponent, "twice.png")
        XCTAssertEqual(second.url.lastPathComponent, "twice-2.png")
    }

    /// Exporting a JPEG as a JPEG into the folder it already lives in must not
    /// land on top of the original.
    func testExportingIntoTheSourceFolderNeverTouchesTheSource() throws {
        let src = try SocialFixtures.makeJPEG(width: 400, height: 300, name: "self", in: dir)
        let before = try Data(contentsOf: src)
        let result = try ImageExportRender.export(
            .init(sourceURL: src, settings: ExportSettings(format: .jpeg)), to: dir)
        XCTAssertNotEqual(result.url, src)
        XCTAssertEqual(try Data(contentsOf: src), before, "the original was modified")
    }

    func testExportKeepsTheSourceStem() throws {
        let src = try SocialFixtures.makeJPEG(width: 400, height: 300, name: "my-photo", in: dir)
        let result = try ImageExportRender.export(
            .init(sourceURL: src, settings: ExportSettings(format: .png)), to: dir)
        XCTAssertEqual(result.url.deletingPathExtension().lastPathComponent, "my-photo")
    }

    // MARK: - Quality

    // MARK: - Background

    /// A transparent PNG stays transparent. This is the case the card had no
    /// control for at all, so it also had no test.
    func testTransparentPNGKeepsItsAlpha() throws {
        let src = try Self.makeTransparentPNG(width: 200, height: 200, name: "alpha", in: dir)
        let result = try ImageExportRender.export(
            .init(sourceURL: src,
                  settings: ExportSettings(format: .png, background: .transparent)), to: dir)
        XCTAssertEqual(try properties(of: result.url)[kCGImagePropertyHasAlpha as String] as? Bool,
                       true)
        XCTAssertEqual(try centerPixelAlpha(of: result.url), 0, accuracy: 2)
    }

    func testWhiteBackgroundFlattensAPNG() throws {
        let src = try Self.makeTransparentPNG(width: 200, height: 200, name: "alphawhite", in: dir)
        let result = try ImageExportRender.export(
            .init(sourceURL: src,
                  settings: ExportSettings(format: .png, background: .white)), to: dir)
        XCTAssertEqual(try centerPixelAlpha(of: result.url), 255, accuracy: 2)
        XCTAssertEqual(try centerPixelRed(of: result.url), 255, accuracy: 3)
    }

    func testBlackBackgroundFlattensAPNG() throws {
        let src = try Self.makeTransparentPNG(width: 200, height: 200, name: "alphablack", in: dir)
        let result = try ImageExportRender.export(
            .init(sourceURL: src,
                  settings: ExportSettings(format: .png, background: .black)), to: dir)
        XCTAssertEqual(try centerPixelAlpha(of: result.url), 255, accuracy: 2)
        XCTAssertEqual(try centerPixelRed(of: result.url), 0, accuracy: 3)
    }

    /// Transparent + JPEG is the coercion case: the container can't carry it,
    /// so it lands on white rather than on the black an uncomposited alpha
    /// channel would give.
    func testTransparentOnJPEGLandsOnWhiteNotBlack() throws {
        let src = try Self.makeTransparentPNG(width: 200, height: 200, name: "alphajpeg", in: dir)
        let result = try ImageExportRender.export(
            .init(sourceURL: src,
                  settings: ExportSettings(format: .jpeg, background: .transparent)), to: dir)
        XCTAssertEqual(try centerPixelRed(of: result.url), 255, accuracy: 4)
    }

    /// A fully transparent PNG, so the CENTRE pixel is the one under test.
    private static func makeTransparentPNG(width: Int, height: Int,
                                           name: String, in directory: URL) throws -> URL {
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let ctx = try XCTUnwrap(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.clear(CGRect(x: 0, y: 0, width: width, height: height))
        // An opaque stripe along the top edge, so the file isn't uniformly
        // empty and ImageIO still records real content.
        ctx.setFillColor(CGColor(red: 0, green: 0.6, blue: 0.2, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: 8))
        let image = try XCTUnwrap(ctx.makeImage())
        let url = directory.appendingPathComponent("\(name).png")
        let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return url
    }

    /// Reads one pixel from the middle of the written file.
    private func centerPixel(of url: URL) throws -> [UInt8] {
        let src = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(src, 0, nil))
        var px = [UInt8](repeating: 0, count: 4)
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        try px.withUnsafeMutableBytes { raw in
            let ctx = try XCTUnwrap(CGContext(
                data: raw.baseAddress, width: 1, height: 1, bitsPerComponent: 8,
                bytesPerRow: 4, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            ctx.draw(image, in: CGRect(x: -CGFloat(image.width) / 2,
                                       y: -CGFloat(image.height) / 2,
                                       width: CGFloat(image.width),
                                       height: CGFloat(image.height)))
        }
        return px
    }

    private func centerPixelAlpha(of url: URL) throws -> Double { Double(try centerPixel(of: url)[3]) }
    private func centerPixelRed(of url: URL) throws -> Double { Double(try centerPixel(of: url)[0]) }

    // MARK: - WebP

    /// Checks the CONTAINER, not the extension — writing `.webp` onto something
    /// that isn't a RIFF/WEBP file is exactly the failure worth catching.
    func testWebPExportProducesARealWebPFile() throws {
        try XCTSkipUnless(WebPEncoder.isAvailable)
        let src = try SocialFixtures.makeJPEG(width: 800, height: 600, name: "towebp", in: dir)
        let result = try ImageExportRender.export(
            .init(sourceURL: src, settings: ExportSettings(format: .webp)), to: dir)
        XCTAssertEqual(result.url.pathExtension, "webp")
        let head = try Data(contentsOf: result.url).prefix(12)
        XCTAssertEqual(head.prefix(4), Data("RIFF".utf8))
        XCTAssertEqual(head.suffix(4), Data("WEBP".utf8))
    }

    /// Lossless is a DIFFERENT encoder, not quality = 100 — so it must beat
    /// quality-100 lossy at reproducing the pixels, and cost more bytes on
    /// photographic content to prove it isn't silently the same path.
    func testWebPLosslessDiffersFromMaximumQualityLossy() throws {
        try XCTSkipUnless(WebPEncoder.isAvailable)
        let src = try SocialFixtures.makeJPEG(width: 600, height: 400, content: .noise,
                                              name: "webplossless", in: dir)
        let lossy = try ImageExportRender.export(
            .init(sourceURL: src, settings: ExportSettings(format: .webp, quality: 1.0)), to: dir)
        let lossless = try ImageExportRender.export(
            .init(sourceURL: src,
                  settings: ExportSettings(format: .webp, quality: 1.0, webpLossless: true)),
            to: dir)
        XCTAssertNotEqual(lossy.bytes, lossless.bytes)
        XCTAssertGreaterThan(lossless.bytes, lossy.bytes)
        let head = try Data(contentsOf: lossless.url).prefix(12)
        XCTAssertEqual(head.suffix(4), Data("WEBP".utf8))
    }

    func testWebPRespectsQuality() throws {
        try XCTSkipUnless(WebPEncoder.isAvailable)
        let src = try SocialFixtures.makeJPEG(width: 1200, height: 900, content: .noise,
                                              name: "webpq", in: dir)
        let low = try ImageExportRender.export(
            .init(sourceURL: src, settings: ExportSettings(format: .webp, quality: 0.3)), to: dir)
        let high = try ImageExportRender.export(
            .init(sourceURL: src, settings: ExportSettings(format: .webp, quality: 0.95)), to: dir)
        XCTAssertLessThan(low.bytes, high.bytes)
    }

    func testWebPHonoursResize() throws {
        try XCTSkipUnless(WebPEncoder.isAvailable)
        let src = try SocialFixtures.makeJPEG(width: 2000, height: 1000, name: "webpsize", in: dir)
        let result = try ImageExportRender.export(
            .init(sourceURL: src, settings: ExportSettings(format: .webp, resize: .longEdge(500))),
            to: dir)
        XCTAssertEqual(result.pixelSize.width, 500, accuracy: 0.5)
        // Round-trip through ImageIO, which READS WebP even though it can't
        // write it — so the file is decodable by something that isn't us.
        let read = try XCTUnwrap(CGImageSourceCreateWithURL(result.url as CFURL, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(read, 0, nil))
        XCTAssertEqual(image.width, 500)
        XCTAssertEqual(image.height, 250)
    }

    // MARK: - Size estimate

    /// The estimate is a real encode of the preview scaled by pixel count, so
    /// it should land near the real file. "Near" is generous on purpose —
    /// that's what the ≈ in the readout is for — but a factor-of-two miss
    /// would make the number worse than useless.
    func testEstimateIsWithinRangeOfTheRealFile() throws {
        let src = try SocialFixtures.makeJPEG(width: 2400, height: 1800, name: "est", in: dir)
        let settings = ExportSettings(format: .jpeg, quality: 0.8)
        let real = try ImageExportRender.export(.init(sourceURL: src, settings: settings), to: dir)

        // A half-size stand-in for the card's ≤2048px preview.
        let previewSrc = try XCTUnwrap(CGImageSourceCreateWithURL(src as CFURL, nil))
        let preview = try XCTUnwrap(CGImageSourceCreateThumbnailAtIndex(previewSrc, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 1200,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ] as CFDictionary))

        let estimate = try XCTUnwrap(ImageExportRender.estimatedBytes(
            preview: preview, settings: settings, for: src,
            outputPixelCount: Double(2400 * 1800)))
        let ratio = Double(estimate) / Double(real.bytes)
        XCTAssertGreaterThan(ratio, 0.5, "estimate \(estimate) vs real \(real.bytes)")
        XCTAssertLessThan(ratio, 2.0, "estimate \(estimate) vs real \(real.bytes)")
    }

    /// TIFF needs no trial encode — ImageIO writes it uncompressed, so the
    /// size is arithmetic, and 16-bit is exactly twice 8-bit.
    func testTIFFEstimateIsArithmeticAndDoublesWithDepth() throws {
        let src = try SocialFixtures.makeJPEG(width: 100, height: 100, name: "esttiff", in: dir)
        let preview = try XCTUnwrap(CGImageSourceCreateImageAtIndex(
            try XCTUnwrap(CGImageSourceCreateWithURL(src as CFURL, nil)), 0, nil))
        let eight = ImageExportRender.estimatedBytes(
            preview: preview, settings: ExportSettings(format: .tiff, tiff16: false),
            for: src, outputPixelCount: 1000)
        let sixteen = ImageExportRender.estimatedBytes(
            preview: preview, settings: ExportSettings(format: .tiff, tiff16: true),
            for: src, outputPixelCount: 1000)
        XCTAssertEqual(eight, 4000)
        XCTAssertEqual(sixteen, 8000)
    }

    func testLowerQualityEstimatesSmaller() throws {
        let src = try SocialFixtures.makeJPEG(width: 1200, height: 900, content: .noise,
                                              name: "estq", in: dir)
        let preview = try XCTUnwrap(CGImageSourceCreateImageAtIndex(
            try XCTUnwrap(CGImageSourceCreateWithURL(src as CFURL, nil)), 0, nil))
        let low = try XCTUnwrap(ImageExportRender.estimatedBytes(
            preview: preview, settings: ExportSettings(format: .jpeg, quality: 0.3),
            for: src, outputPixelCount: Double(1200 * 900)))
        let high = try XCTUnwrap(ImageExportRender.estimatedBytes(
            preview: preview, settings: ExportSettings(format: .jpeg, quality: 0.95),
            for: src, outputPixelCount: Double(1200 * 900)))
        XCTAssertLessThan(low, high)
    }

    // MARK: - Quality

    func testLowerQualityProducesASmallerFile() throws {
        let src = try SocialFixtures.makeJPEG(width: 1200, height: 900, content: .noise,
                                              name: "q", in: dir)
        let low = try ImageExportRender.export(
            .init(sourceURL: src, settings: ExportSettings(format: .jpeg, quality: 0.3)), to: dir)
        let high = try ImageExportRender.export(
            .init(sourceURL: src, settings: ExportSettings(format: .jpeg, quality: 0.98)), to: dir)
        XCTAssertLessThan(low.bytes, high.bytes)
    }
}
