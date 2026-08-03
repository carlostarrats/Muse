//
//  HDRTestFixtures.swift
//  MuseTests
//
//  Synthetic HDR/SDR files, written once and shared by every HDR test.
//
//  Synthetic rather than a checked-in iPhone photo on purpose: the tests need
//  to assert an EXACT linear value survived the round trip, and a real capture
//  has no such value to assert. A real gain-map HEIC is still required for the
//  runtime pass — see the ledger row.
//

import XCTest
import CoreImage
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

enum HDRTestFixtures {

    static let linearSpace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
    static let pqSpace = CGColorSpace(name: CGColorSpace.itur_2100_PQ)!
    static let srgbSpace = CGColorSpace(name: CGColorSpace.sRGB)!

    static func context() -> CIContext {
        CIContext(options: [.workingColorSpace: linearSpace])
    }

    /// A 16×16 solid PQ HEIC holding `value` in linear light. Values above 1.0
    /// are the point — an SDR container would clamp them on write.
    static func hdrHEIC(value: CGFloat, name: String = "hdr") throws -> URL {
        try write(image: solid(value), space: pqSpace, format: .RGBA16,
                  type: UTType("public.heic")!, name: name)
    }

    /// A 16×16 solid 8-bit sRGB PNG — an ordinary photo.
    static func sdrPNG(value: CGFloat, name: String = "sdr") throws -> URL {
        try write(image: solid(value), space: srgbSpace, format: .RGBA8,
                  type: .png, name: name)
    }

    /// Two pixels side by side at two different HDR values. The tone-map tests
    /// need this: a CLAMP maps both onto 1.0, a roll-off keeps them apart, and
    /// that difference is the only way to tell the two apart from the output.
    static func hdrGradient(low: CGFloat, high: CGFloat) throws -> URL {
        let left = CIImage(color: color(low)).cropped(to: CGRect(x: 0, y: 0, width: 8, height: 16))
        let right = CIImage(color: color(high))
            .cropped(to: CGRect(x: 8, y: 0, width: 8, height: 16))
        return try write(image: right.composited(over: left), space: pqSpace,
                         format: .RGBA16, type: UTType("public.heic")!, name: "gradient")
    }

    // MARK: - Reading back

    /// The first pixel's LINEAR value, which is what every HDR assertion is
    /// actually about.
    static func firstPixel(_ image: CIImage) -> (r: Float, g: Float, b: Float) {
        var px = [Float](repeating: 0, count: 4)
        px.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return }
            context().render(image, toBitmap: base, rowBytes: 16,
                             bounds: CGRect(x: image.extent.minX, y: image.extent.minY,
                                            width: 1, height: 1),
                             format: .RGBAf, colorSpace: linearSpace)
        }
        return (px[0], px[1], px[2])
    }

    static func firstPixel(ofFileAt url: URL) throws -> (r: Float, g: Float, b: Float) {
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let cg = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, [
            kCGImageSourceDecodeRequest: kCGImageSourceDecodeToHDR,
        ] as CFDictionary))
        return firstPixel(CIImage(cgImage: cg))
    }

    /// How many DISTINCT luminance values a file holds. One means everything
    /// collapsed onto the same value, which is the signature of a hard clip.
    static func distinctLuminanceCount(of url: URL) throws -> Int {
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let cg = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let width = cg.width, height = cg.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let ctx = CGContext(data: &bytes, width: width, height: height,
                            bitsPerComponent: 8, bytesPerRow: width * 4,
                            space: srgbSpace,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        ctx?.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
        var seen = Set<Int>()
        for i in stride(from: 0, to: bytes.count, by: 4) {
            let r: Double = Double(bytes[i])
            let g: Double = Double(bytes[i + 1])
            let b: Double = Double(bytes[i + 2])
            let luma: Double = 0.2126 * r + 0.7152 * g + 0.0722 * b
            seen.insert(Int(luma))
        }
        return seen.count
    }

    // MARK: - Private

    private static func color(_ value: CGFloat) -> CIColor {
        CIColor(red: value, green: value, blue: value, colorSpace: linearSpace)!
    }

    private static func solid(_ value: CGFloat) -> CIImage {
        CIImage(color: color(value)).cropped(to: CGRect(x: 0, y: 0, width: 16, height: 16))
    }

    private static func write(image: CIImage, space: CGColorSpace, format: CIFormat,
                              type: UTType, name: String) throws -> URL {
        let cg = try XCTUnwrap(context().createCGImage(image, from: image.extent,
                                                       format: format, colorSpace: space))
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name)-\(UUID().uuidString)")
            .appendingPathExtension(type.preferredFilenameExtension ?? "bin")
        let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(
            url as CFURL, type.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, cg, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest), "fixture write failed for \(name)")
        return url
    }
}
