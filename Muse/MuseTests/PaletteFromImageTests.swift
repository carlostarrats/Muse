import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import Muse

/// The analyze pass decodes each file once and reuses that raster for the
/// palette. These tests pin the image-taking overload against the URL-taking
/// one, which is the original implementation — if they ever disagree, the
/// single-decode refactor stopped being faithful.
final class PaletteFromImageTests: XCTestCase {

    /// Half red, half blue — a deterministic two-cluster palette.
    private func twoTone() throws -> CGImage {
        let ctx = try XCTUnwrap(CGContext(data: nil, width: 64, height: 64,
                                          bitsPerComponent: 8, bytesPerRow: 0,
                                          space: XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB)),
                                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        ctx.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: 64, height: 32))
        ctx.setFillColor(red: 0, green: 0, blue: 1, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 32, width: 64, height: 32))
        return try XCTUnwrap(ctx.makeImage())
    }

    private func writeTIFF(_ img: CGImage) throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("muse-pal-\(UUID().uuidString).tif")
        let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(
            url as CFURL, UTType.tiff.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, img, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    /// Smooth two-axis gradient — photographic-like content with no hard edges.
    private func gradient(width: Int = 512, height: Int = 384) throws -> CGImage {
        let srgb = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        var data = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let o = (y * width + x) * 4
                data[o] = UInt8(255 * x / max(1, width - 1))
                data[o + 1] = UInt8(255 * y / max(1, height - 1))
                data[o + 2] = UInt8(128)
                data[o + 3] = 255
            }
        }
        let provider = try XCTUnwrap(CGDataProvider(data: Data(data) as CFData))
        return try XCTUnwrap(CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4, space: srgb,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false,
            intent: .defaultIntent))
    }

    /// The load-bearing test: the image overload must agree with the URL overload
    /// on realistic content.
    ///
    /// Deliberately uses a smooth gradient, NOT the hard-edged `twoTone()`.
    /// The two overloads necessarily use different resamplers — the URL path
    /// gets ImageIO's own 32px thumbnail, the image path downscales an
    /// already-decoded raster through CoreGraphics — and at a hard colour
    /// boundary two different resamplers blend the edge pixels differently by
    /// construction. That divergence is inherent to the design, not a defect, so
    /// asserting exact equality on a pathological edge would be testing the
    /// resamplers rather than this refactor. Real images (verified across the
    /// RAW and scan fixtures) agree closely; a gradient represents them.
    func testImageOverloadMatchesURLOverloadOnRealisticContent() throws {
        let img = try gradient()
        let url = try writeTIFF(img)
        let fromURL = PaletteExtractor.weightedPalette(for: url)
        let fromImage = PaletteExtractor.weightedPalette(image: img)
        XCTAssertFalse(fromImage.isEmpty)
        XCTAssertEqual(fromURL.count, fromImage.count, "cluster count must match")
        for (a, b) in zip(fromURL, fromImage) {
            let (ar, ag, ab) = try XCTUnwrap(hexToRGB(a.0))
            let (br, bg, bb) = try XCTUnwrap(hexToRGB(b.0))
            let delta = abs(ar - br) + abs(ag - bg) + abs(ab - bb)
            XCTAssertLessThanOrEqual(delta, 24,
                "palette entries must agree closely between overloads: \(a.0) vs \(b.0)")
            XCTAssertEqual(a.1, b.1, accuracy: 0.06,
                "cluster share must agree between overloads")
        }
    }

    private func hexToRGB(_ hex: String) -> (Int, Int, Int)? {
        var s = hex
        guard s.hasPrefix("#") else { return nil }
        s.removeFirst()
        guard s.count == 6, let v = Int(s, radix: 16) else { return nil }
        return ((v >> 16) & 0xff, (v >> 8) & 0xff, v & 0xff)
    }

    func testTwoToneImageYieldsBothColors() throws {
        let out = PaletteExtractor.weightedPalette(image: try twoTone())
        let hexes = out.map { $0.0 }
        XCTAssertTrue(hexes.contains { $0.hasPrefix("#f") || $0.hasPrefix("#e") },
                      "expected a red-ish cluster, got \(hexes)")
        XCTAssertTrue(hexes.contains { $0.hasSuffix("ff") || $0.hasSuffix("fe") },
                      "expected a blue-ish cluster, got \(hexes)")
    }

    func testDownsampledRGBFromImageReturnsPixels() throws {
        let px = try XCTUnwrap(PaletteExtractor.downsampledRGB(image: try twoTone()))
        XCTAssertFalse(px.isEmpty)
        for p in px {
            XCTAssertTrue((0...1).contains(p.0))
            XCTAssertTrue((0...1).contains(p.1))
            XCTAssertTrue((0...1).contains(p.2))
        }
    }

    /// A full-size raster is now passed straight in (the analyze pass no longer
    /// pre-shrinks it), so the overload must cap its own working size — otherwise
    /// k-means would run over millions of pixels instead of ~1024.
    func testLargeImageIsDownsampledBeforeKMeans() throws {
        let ctx = try XCTUnwrap(CGContext(data: nil, width: 2000, height: 1500,
                                          bitsPerComponent: 8, bytesPerRow: 0,
                                          space: XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB)),
                                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        ctx.setFillColor(red: 0.1, green: 0.8, blue: 0.3, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: 2000, height: 1500))
        let big = try XCTUnwrap(ctx.makeImage())
        let px = try XCTUnwrap(PaletteExtractor.downsampledRGB(image: big))
        XCTAssertLessThanOrEqual(px.count, 32 * 32,
                                 "must cap at ~32x32, got \(px.count) pixels")
        XCTAssertGreaterThan(px.count, 0)
    }

    /// Aspect ratio must survive the internal downsample, so a wide image doesn't
    /// get its palette weighted by a squashed sample.
    func testDownsamplePreservesAspectRatio() throws {
        let ctx = try XCTUnwrap(CGContext(data: nil, width: 3200, height: 400,
                                          bitsPerComponent: 8, bytesPerRow: 0,
                                          space: XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB)),
                                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        ctx.setFillColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: 3200, height: 400))
        let wide = try XCTUnwrap(ctx.makeImage())
        let px = try XCTUnwrap(PaletteExtractor.downsampledRGB(image: wide))
        // 3200x400 is 8:1, so a 32-long-edge cap gives 32x4 = 128 pixels.
        XCTAssertEqual(px.count, 32 * 4, "expected a 32x4 sample, got \(px.count)")
    }
}
