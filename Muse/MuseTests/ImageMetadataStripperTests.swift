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

    // MARK: - Per-format adversarial coverage (from the security review)

    /// Encode a solid image of `type` carrying arbitrary metadata `props`. Returns
    /// nil if the host's ImageIO can't ENCODE that type (caller XCTSkips).
    private func makeImage(type: UTType, props: [CFString: Any],
                          width: Int = 40, height: Int = 28) -> URL? {
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(red: 0.4, green: 0.55, blue: 0.65, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let cg = ctx.makeImage() else { return nil }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, cg, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        let ext = type.preferredFilenameExtension ?? "img"
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("muse-fmt-\(UUID().uuidString).\(ext)")
        try? (data as Data).write(to: url)
        return url
    }

    private func gpsDict() -> [CFString: Any] {
        [kCGImagePropertyGPSLatitude: 37.7749, kCGImagePropertyGPSLatitudeRef: "N",
         kCGImagePropertyGPSLongitude: 122.4194, kCGImagePropertyGPSLongitudeRef: "W"]
    }

    /// HEIC = iPhone's native format and the most important real-world case
    /// (iPhone photos carry GPS in a separate EXIF item, not inline like JPEG).
    func testStripHEICRemovesGPSAndPrivateText() throws {
        let needle = "MUSE-HEIC-NEEDLE"
        let props: [CFString: Any] = [
            kCGImagePropertyGPSDictionary: gpsDict(),
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifUserComment: needle],
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: needle + "-MAKE"],
        ]
        guard let url = makeImage(type: .heic, props: props) else { throw XCTSkip("HEIC encode unavailable on host") }
        defer { try? FileManager.default.removeItem(at: url) }
        guard try Data(contentsOf: url).range(of: Data(needle.utf8)) != nil else {
            throw XCTSkip("host did not embed HEIC metadata; nothing to assert")
        }
        let out = try ImageMetadataStripper.strip(url: url, mime: "image/heic")
        XCTAssertNil(out.data.range(of: Data(needle.utf8)), "HEIC private text must be stripped")
        XCTAssertTrue(ImageMetadataStripper.isClean(out.data), "stripped HEIC must verify clean")
    }

    func testStripPNGRemovesEXIFGPS() throws {
        guard let url = makeImage(type: .png, props: [kCGImagePropertyGPSDictionary: gpsDict()]) else {
            throw XCTSkip("PNG encode unavailable")
        }
        defer { try? FileManager.default.removeItem(at: url) }
        let out = try ImageMetadataStripper.strip(url: url, mime: "image/png")
        let src = CGImageSourceCreateWithData(out.data as CFData, nil)!
        let p = (CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]) ?? [:]
        XCTAssertNil(p[kCGImagePropertyGPSDictionary], "PNG GPS must be stripped")
        XCTAssertTrue(ImageMetadataStripper.isClean(out.data))
    }

    func testStripTIFFRemovesGPSAndIPTC() throws {
        let needle = "MUSE-TIFF-NEEDLE"
        let props: [CFString: Any] = [
            kCGImagePropertyGPSDictionary: gpsDict(),
            kCGImagePropertyIPTCDictionary: [kCGImagePropertyIPTCCaptionAbstract: needle],
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: needle + "-MAKE"],
        ]
        guard let url = makeImage(type: .tiff, props: props) else { throw XCTSkip("TIFF encode unavailable") }
        defer { try? FileManager.default.removeItem(at: url) }
        guard try Data(contentsOf: url).range(of: Data(needle.utf8)) != nil else {
            throw XCTSkip("host did not embed TIFF metadata")
        }
        let out = try ImageMetadataStripper.strip(url: url, mime: "image/tiff")
        XCTAssertNil(out.data.range(of: Data(needle.utf8)), "TIFF private metadata must be stripped")
        XCTAssertTrue(ImageMetadataStripper.isClean(out.data))
    }

    /// A JPEG's EXIF can embed a small thumbnail JPEG. The privacy guarantee:
    /// a thumbnailed image with GPS must come out with NO GPS anywhere. (ImageIO
    /// won't let us inject independent GPS into the IFD1 thumbnail, but the strip
    /// re-encodes from decoded pixels, so any thumbnail in the OUTPUT is rebuilt
    /// from already-clean pixels and carries nothing — verified via isClean.)
    func testStripThumbnailedImageLeaksNoGPS() throws {
        let needle = "MUSE-THUMB-NEEDLE"
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: 256, height: 256, bitsPerComponent: 8, bytesPerRow: 0,
                            space: cs, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0.8, green: 0.2, blue: 0.2, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 256, height: 256))
        let cg = ctx.makeImage()!
        let data = NSMutableData()
        let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, cg, [
            kCGImageDestinationEmbedThumbnail: kCFBooleanTrue!,
            kCGImagePropertyGPSDictionary: gpsDict(),
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifUserComment: needle],
        ] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("muse-thumb-\(UUID().uuidString).jpg")
        try (data as Data).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        // Sanity: the fixture really has an embedded thumbnail AND GPS AND the needle.
        let onlyEmbedded = [kCGImageSourceCreateThumbnailFromImageIfAbsent: false] as CFDictionary
        let srcBefore = CGImageSourceCreateWithData(try Data(contentsOf: url) as CFData, nil)!
        guard CGImageSourceCreateThumbnailAtIndex(srcBefore, 0, onlyEmbedded) != nil else {
            throw XCTSkip("host did not embed a thumbnail; nothing to assert")
        }
        let beforeProps = (CGImageSourceCopyPropertiesAtIndex(srcBefore, 0, nil) as? [CFString: Any]) ?? [:]
        XCTAssertNotNil(beforeProps[kCGImagePropertyGPSDictionary], "fixture should carry GPS")
        XCTAssertNotNil(try Data(contentsOf: url).range(of: Data(needle.utf8)))

        let out = try ImageMetadataStripper.strip(url: url, mime: "image/jpeg")
        let after = (CGImageSourceCopyPropertiesAtIndex(
            CGImageSourceCreateWithData(out.data as CFData, nil)!, 0, nil) as? [CFString: Any]) ?? [:]
        XCTAssertNil(after[kCGImagePropertyGPSDictionary], "GPS must be gone on a thumbnailed image")
        XCTAssertNil(out.data.range(of: Data(needle.utf8)), "private text must be gone")
        XCTAssertTrue(ImageMetadataStripper.isClean(out.data), "thumbnailed image must verify clean")
    }

    /// Apple MakerNote can encode burst/run identifiers and location hints.
    func testStripRemovesMakerNote() throws {
        let needle = "MUSE-MAKERAPPLE-NEEDLE"
        let props: [CFString: Any] = [
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifUserComment: "x"],
            kCGImagePropertyMakerAppleDictionary: ["1": needle, "2": needle],
        ]
        guard let url = makeImage(type: .jpeg, props: props) else { throw XCTSkip("JPEG encode unavailable") }
        defer { try? FileManager.default.removeItem(at: url) }
        let out = try ImageMetadataStripper.strip(url: url, mime: "image/jpeg")
        XCTAssertNil(out.data.range(of: Data(needle.utf8)), "maker note must be stripped")
        let src = CGImageSourceCreateWithData(out.data as CFData, nil)!
        let p = (CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]) ?? [:]
        XCTAssertNil(p[kCGImagePropertyMakerAppleDictionary], "MakerApple dict must be gone")
        XCTAssertTrue(ImageMetadataStripper.isClean(out.data))
    }

    /// Multi-frame container fail-open: the multi-frame path must strip BOTH
    /// per-page AND container-level private metadata, not just GPS, while keeping
    /// every page. A multi-page TIFF reliably carries page metadata.
    func testStripMultiFrameMetadataStripped() throws {
        let needleContainer = "MUSE-MF-CONTAINER-NEEDLE"
        let needlePage = "MUSE-MF-PAGE-NEEDLE"
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.tiff.identifier as CFString, 2, nil) else {
            throw XCTSkip("TIFF encode unavailable")
        }
        CGImageDestinationSetProperties(dest, [
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: needleContainer],
        ] as CFDictionary)
        for f in 0..<2 {
            let ctx = CGContext(data: nil, width: 24, height: 24, bitsPerComponent: 8, bytesPerRow: 0,
                                space: cs, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
            ctx.setFillColor(CGColor(red: CGFloat(f), green: 0.4, blue: 0.6, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: 24, height: 24))
            CGImageDestinationAddImage(dest, ctx.makeImage()!, [
                kCGImagePropertyGPSDictionary: gpsDict(),
                kCGImagePropertyIPTCDictionary: [kCGImagePropertyIPTCCaptionAbstract: needlePage],
            ] as CFDictionary)
        }
        guard CGImageDestinationFinalize(dest) else { throw XCTSkip("multi-page TIFF finalize failed") }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("muse-mf-\(UUID().uuidString).tiff")
        try (data as Data).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let raw = try Data(contentsOf: url)
        guard raw.range(of: Data(needlePage.utf8)) != nil else {
            throw XCTSkip("host did not embed TIFF page metadata")
        }
        let out = try ImageMetadataStripper.strip(url: url, mime: "image/tiff")
        XCTAssertNil(out.data.range(of: Data(needlePage.utf8)), "per-page metadata must be stripped")
        XCTAssertNil(out.data.range(of: Data(needleContainer.utf8)), "container metadata must be stripped")
        XCTAssertTrue(ImageMetadataStripper.isClean(out.data))
        // Both pages must survive (multi-frame path must not collapse the image).
        let src = CGImageSourceCreateWithData(out.data as CFData, nil)!
        XCTAssertEqual(CGImageSourceGetCount(src), 2, "both TIFF pages preserved")
    }

    /// The reported mime must reflect the ACTUAL bytes, not the (possibly lying)
    /// file extension — or Drive stores a mislabeled file the thumbnailer can't read.
    func testMimeReflectsActualBytesNotExtension() throws {
        guard let jpegURL = makeImage(type: .jpeg, props: [:]) else { throw XCTSkip("JPEG encode unavailable") }
        defer { try? FileManager.default.removeItem(at: jpegURL) }
        let liar = FileManager.default.temporaryDirectory
            .appendingPathComponent("muse-liar-\(UUID().uuidString).png")   // .png ext, JPEG bytes
        try Data(contentsOf: jpegURL).write(to: liar)
        defer { try? FileManager.default.removeItem(at: liar) }
        let out = try ImageMetadataStripper.strip(url: liar, mime: "image/png")
        XCTAssertEqual(out.mime, "image/jpeg", "mime must come from the bytes, not the extension")
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
