//
//  ImageMetadataStripperTests.swift
//  MuseTests
//
//  Drive-share privacy: every image is metadata-stripped BEFORE it's uploaded
//  (and made anyone-readable), so a recipient who downloads the original can't
//  read GPS coordinates, capture time, camera serial, etc. These tests build a
//  JPEG carrying GPS + EXIF + camera make at a known orientation, strip it, and
//  assert the private metadata is gone while the pixels + display orientation
//  survive.
//

import XCTest
import ImageIO
import UniformTypeIdentifiers
@testable import Muse

final class ImageMetadataStripperTests: XCTestCase {

    /// Build a small JPEG that embeds GPS, an EXIF capture date, a TIFF camera
    /// make, and a non-default orientation (6 = rotated 90°). Returns a temp URL.
    private func makeTaggedJPEG(orientation: UInt32 = 6,
                                width: Int = 24, height: Int = 16) throws -> URL {
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: width, height: height,
                            bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let cg = ctx.makeImage()!

        let props: [CFString: Any] = [
            kCGImagePropertyOrientation: orientation,
            kCGImagePropertyGPSDictionary: [
                kCGImagePropertyGPSLatitude: 37.7749,
                kCGImagePropertyGPSLatitudeRef: "N",
                kCGImagePropertyGPSLongitude: 122.4194,
                kCGImagePropertyGPSLongitudeRef: "W",
            ],
            kCGImagePropertyExifDictionary: [
                kCGImagePropertyExifDateTimeOriginal: "2024:01:02 03:04:05",
                kCGImagePropertyExifUserComment: "secret note",
            ],
            kCGImagePropertyTIFFDictionary: [
                kCGImagePropertyTIFFMake: "ACME Cameras",
                kCGImagePropertyTIFFModel: "SpyCam 9000",
            ],
        ]

        let data = NSMutableData()
        let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, cg, props as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(dest))

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("muse-strip-\(UUID().uuidString).jpg")
        try (data as Data).write(to: url)
        return url
    }

    private func properties(of data: Data) -> [CFString: Any] {
        let src = CGImageSourceCreateWithData(data as CFData, nil)!
        return (CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]) ?? [:]
    }

    func testStripRemovesGPSExifAndCameraMake() throws {
        let url = try makeTaggedJPEG()
        defer { try? FileManager.default.removeItem(at: url) }

        // Sanity: the source really does carry the private metadata.
        let before = properties(of: try Data(contentsOf: url))
        XCTAssertNotNil(before[kCGImagePropertyGPSDictionary], "fixture should embed GPS")
        XCTAssertNotNil(before[kCGImagePropertyExifDictionary], "fixture should embed EXIF")

        let out = try ImageMetadataStripper.strip(url: url, mime: "image/jpeg")
        let after = properties(of: out.data)

        XCTAssertNil(after[kCGImagePropertyGPSDictionary], "GPS must be stripped")
        let exif = after[kCGImagePropertyExifDictionary] as? [CFString: Any]
        XCTAssertNil(exif?[kCGImagePropertyExifDateTimeOriginal], "EXIF capture date must be stripped")
        XCTAssertNil(exif?[kCGImagePropertyExifUserComment], "EXIF user comment must be stripped")
        let tiff = after[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        XCTAssertNil(tiff?[kCGImagePropertyTIFFMake], "camera make must be stripped")
        XCTAssertNil(tiff?[kCGImagePropertyTIFFModel], "camera model must be stripped")
    }

    func testStripPreservesPixelsAndOrientation() throws {
        let url = try makeTaggedJPEG(orientation: 6, width: 24, height: 16)
        defer { try? FileManager.default.removeItem(at: url) }

        let out = try ImageMetadataStripper.strip(url: url, mime: "image/jpeg")
        let after = properties(of: out.data)

        XCTAssertEqual(after[kCGImagePropertyPixelWidth] as? Int, 24, "pixel width preserved")
        XCTAssertEqual(after[kCGImagePropertyPixelHeight] as? Int, 16, "pixel height preserved")
        // Orientation is not private; it must survive so photos don't display rotated.
        XCTAssertEqual(after[kCGImagePropertyOrientation] as? UInt32, 6, "display orientation preserved")
        XCTAssertEqual(out.mime, "image/jpeg", "format/mime preserved for a writable type")
    }

    /// Build a small N-frame animated GIF (with a loop count) and return a temp URL.
    private func makeAnimatedGIF(frames: Int) throws -> URL {
        let w = 12, h = 12
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("muse-anim-\(UUID().uuidString).gif")
        let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString, frames, nil)!
        CGImageDestinationSetProperties(dest, [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]
        ] as CFDictionary)
        for f in 0..<frames {
            let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                space: cs, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
            ctx.setFillColor(CGColor(red: CGFloat(f) / CGFloat(frames), green: 0.4, blue: 0.6, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            CGImageDestinationAddImage(dest, ctx.makeImage()!, [
                kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.1]
            ] as CFDictionary)
        }
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return url
    }

    func testStripPreservesAllFramesOfAnimatedGIF() throws {
        let url = try makeAnimatedGIF(frames: 3)
        defer { try? FileManager.default.removeItem(at: url) }

        let out = try ImageMetadataStripper.strip(url: url, mime: "image/gif")
        let src = CGImageSourceCreateWithData(out.data as CFData, nil)!
        // Regression guard: a multi-frame image must NOT be collapsed to a still.
        XCTAssertEqual(CGImageSourceGetCount(src), 3, "all animation frames must survive stripping")
        XCTAssertEqual(out.mime, "image/gif", "animated GIF keeps its format")
    }

    /// Build a JPEG whose XMP packet carries a recognizable secret string
    /// (location data is often duplicated into XMP, not just the EXIF IFD).
    private func makeJPEGWithXMP(secret: String) throws -> URL {
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: 16, height: 16, bitsPerComponent: 8, bytesPerRow: 0,
                            space: cs, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0.3, green: 0.6, blue: 0.2, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
        let cg = ctx.makeImage()!

        let meta = CGImageMetadataCreateMutable()
        CGImageMetadataRegisterNamespaceForPrefix(meta, "http://muse.test/ns/1.0/" as CFString, "muse" as CFString, nil)
        XCTAssertTrue(CGImageMetadataSetValueWithPath(meta, nil, "muse:Secret" as CFString, secret as CFString))

        let data = NSMutableData()
        let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImageAndMetadata(dest, cg, meta, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("muse-xmp-\(UUID().uuidString).jpg")
        try (data as Data).write(to: url)
        return url
    }

    func testStripRemovesXMP() throws {
        let secret = "MUSE-XMP-LOCATION-SECRET"
        let url = try makeJPEGWithXMP(secret: secret)
        defer { try? FileManager.default.removeItem(at: url) }
        let needle = Data(secret.utf8)

        // Sanity: the original really embeds the secret in its XMP packet.
        XCTAssertNotNil(try Data(contentsOf: url).range(of: needle), "fixture should embed the XMP secret")

        let out = try ImageMetadataStripper.strip(url: url, mime: "image/jpeg")
        XCTAssertNil(out.data.range(of: needle), "XMP metadata (location etc.) must be stripped")
    }

    func testStripThrowsOnNonImage() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("muse-notimage-\(UUID().uuidString).bin")
        try Data("not an image".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        // Fail closed: a file we can't decode must NOT pass through unstripped.
        XCTAssertThrowsError(try ImageMetadataStripper.strip(url: url, mime: "application/octet-stream"))
    }
}
