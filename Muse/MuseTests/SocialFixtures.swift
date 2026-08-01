//
//  SocialFixtures.swift
//  MuseTests
//
//  Synthetic JPEG fixtures for the social-export pipeline tests, generated at
//  runtime rather than checked in. Deviation from the plan, deliberately: the
//  app target uses file-system-synchronized groups, so a checked-in binary
//  under MuseTests/ would land in the test bundle's resources by inference
//  rather than by declaration — and a 4096² noise JPEG is a multi-MB blob in
//  git for something two lines of ImageIO can produce deterministically.
//
//  Content matters as much as size here: `noise` must be genuinely
//  incompressible so the byte-target ladder has real work to do, and `gradient`
//  must be smooth so a byte target is actually reachable.
//

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum SocialFixtures {
    /// A deterministic pseudo-random source (never Double.random) so a fixture
    /// is identical run to run.
    private struct LCG {
        var state: UInt64
        mutating func next() -> UInt8 {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return UInt8truncating(state >> 33)
        }
        private func UInt8truncating(_ v: UInt64) -> UInt8 { UInt8(v & 0xFF) }
    }

    enum Content { case gradient, noise }

    /// Writes a JPEG of the given pixel size into `directory` and returns its
    /// URL. `orientation` writes an EXIF orientation tag (6 = rotate 90°) so the
    /// baked-orientation path can be exercised.
    static func makeJPEG(width: Int, height: Int, content: Content = .gradient,
                         orientation: UInt32 = 1, quality: Double = 0.95,
                         name: String, in directory: URL) throws -> URL {
        let cg = try makeImage(width: width, height: height, content: content)
        let url = directory.appendingPathComponent("\(name).jpg")
        guard let dest = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw NSError(domain: "SocialFixtures", code: 1)
        }
        var props: [String: Any] = [kCGImageDestinationLossyCompressionQuality as String: quality]
        if orientation != 1 {
            props[kCGImagePropertyOrientation as String] = orientation
            props[kCGImagePropertyTIFFDictionary as String] =
                [kCGImagePropertyTIFFOrientation as String: orientation]
        }
        CGImageDestinationAddImage(dest, cg, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else {
            throw NSError(domain: "SocialFixtures", code: 2)
        }
        return url
    }

    private static func makeImage(width: Int, height: Int, content: Content) throws -> CGImage {
        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)
        switch content {
        case .gradient:
            for y in 0..<height {
                for x in 0..<width {
                    let i = y * bytesPerRow + x * 4
                    pixels[i]     = UInt8((x * 255) / max(1, width - 1))
                    pixels[i + 1] = UInt8((y * 255) / max(1, height - 1))
                    pixels[i + 2] = 128
                    pixels[i + 3] = 255
                }
            }
        case .noise:
            var rng = LCG(state: 0x5DEECE66D)
            for i in stride(from: 0, to: pixels.count, by: 4) {
                pixels[i] = rng.next(); pixels[i + 1] = rng.next(); pixels[i + 2] = rng.next()
                pixels[i + 3] = 255
            }
        }
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: &pixels, width: width, height: height,
                                  bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                                  space: space,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue),
              let image = ctx.makeImage() else {
            throw NSError(domain: "SocialFixtures", code: 3)
        }
        return image
    }
}
