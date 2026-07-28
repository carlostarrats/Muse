import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import Muse

/// Colour extraction must not depend on whatever colour space the decoder
/// happened to return. RAW decodes as ITU-R 2100 PQ; before this suite's fix,
/// `dominantColor` rendered with colour management disabled and read those
/// HDR component values as if they were sRGB.
final class ColorSpaceTests: XCTestCase {

    /// A solid image of one colour, tagged with the given colour space.
    private func solid(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat,
                       space: CGColorSpace) throws -> CGImage {
        let ctx = try XCTUnwrap(CGContext(data: nil, width: 64, height: 64,
                                          bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        ctx.setFillColor(red: r, green: g, blue: b, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        return try XCTUnwrap(ctx.makeImage())
    }

    private func hexToRGB(_ hex: String) -> (Int, Int, Int)? {
        var s = hex
        guard s.hasPrefix("#") else { return nil }
        s.removeFirst()
        guard s.count == 6, let v = Int(s, radix: 16) else { return nil }
        return ((v >> 16) & 0xff, (v >> 8) & 0xff, v & 0xff)
    }

    func testDominantColorOfSRGBImageIsThatColor() throws {
        let img = try solid(0.5, 0.25, 0.75, space: XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB)))
        let hex = try XCTUnwrap(VisionServices.dominantColorHex(cgImage: img))
        let (r, g, b) = try XCTUnwrap(hexToRGB(hex))
        XCTAssertEqual(Double(r), 128, accuracy: 3)
        XCTAssertEqual(Double(g), 64, accuracy: 3)
        XCTAssertEqual(Double(b), 191, accuracy: 3)
    }

    /// The regression this task exists for: a colour authored in a wide-gamut
    /// space must be CONVERTED to sRGB, not reinterpreted as if its components
    /// were already sRGB. Pure P3 red is outside sRGB, so it must clamp toward
    /// sRGB red rather than land somewhere unrelated.
    func testDominantColorConvertsWideGamutToSRGB() throws {
        let p3 = try XCTUnwrap(CGColorSpace(name: CGColorSpace.displayP3))
        let img = try solid(1.0, 0.0, 0.0, space: p3)
        let hex = try XCTUnwrap(VisionServices.dominantColorHex(cgImage: img))
        let (r, g, b) = try XCTUnwrap(hexToRGB(hex))
        XCTAssertGreaterThan(r, 240, "P3 red must map to near-max sRGB red, got \(hex)")
        XCTAssertLessThan(g, 60, "got \(hex)")
        XCTAssertLessThan(b, 60, "got \(hex)")
    }

    /// Neutral grey is identical in sRGB and P3, so both must give the same hex.
    /// Under the old unmanaged render they did not.
    func testMidGrayRoundTripsAcrossSpaces() throws {
        let srgb = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let p3 = try XCTUnwrap(CGColorSpace(name: CGColorSpace.displayP3))
        let a = try XCTUnwrap(VisionServices.dominantColorHex(cgImage: solid(0.5, 0.5, 0.5, space: srgb)))
        let b = try XCTUnwrap(VisionServices.dominantColorHex(cgImage: solid(0.5, 0.5, 0.5, space: p3)))
        let (ar, _, _) = try XCTUnwrap(hexToRGB(a))
        let (br, _, _) = try XCTUnwrap(hexToRGB(b))
        XCTAssertEqual(Double(ar), Double(br), accuracy: 4,
                       "neutral grey must not depend on the tagged space (\(a) vs \(b))")
    }

    /// Write a solid image to a TIFF, preserving its tagged colour space.
    private func writeTIFF(_ img: CGImage) throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("muse-cs-\(UUID().uuidString).tif")
        let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(
            url as CFURL, UTType.tiff.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, img, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    /// The palette path must agree with the dominant-colour path — both are
    /// user-visible and both feed colour tagging/search, so they cannot disagree.
    /// Exercised through the URL overload, which is what the app calls today.
    func testPaletteAgreesWithDominantColorOnASolidImage() throws {
        let p3 = try XCTUnwrap(CGColorSpace(name: CGColorSpace.displayP3))
        let img = try solid(0.2, 0.6, 0.4, space: p3)
        let dominant = try XCTUnwrap(VisionServices.dominantColorHex(cgImage: img))
        let palette = PaletteExtractor.weightedPalette(for: try writeTIFF(img))
        let top = try XCTUnwrap(palette.first?.0)
        let (dr, dg, db) = try XCTUnwrap(hexToRGB(dominant))
        let (pr, pg, pb) = try XCTUnwrap(hexToRGB(top))
        XCTAssertEqual(Double(dr), Double(pr), accuracy: 6, "\(dominant) vs \(top)")
        XCTAssertEqual(Double(dg), Double(pg), accuracy: 6, "\(dominant) vs \(top)")
        XCTAssertEqual(Double(db), Double(pb), accuracy: 6, "\(dominant) vs \(top)")
    }
}
