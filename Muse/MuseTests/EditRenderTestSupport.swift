import XCTest
import CoreImage
import ImageIO
import UniformTypeIdentifiers
@testable import Muse

/// Shared fixtures + pixel readback for the render tests.
///
/// Fixtures are GENERATED into the temp directory rather than bundled: the
/// test host is the sandboxed app, so a resource read from the repo is denied
/// on a checkout under ~/Documents, and a fixture that can't be read is a
/// consistency gate that silently never runs.
enum EditRenderTestSupport {

    // MARK: - Fixtures

    /// A deterministic gradient + detail image, so a render difference is a
    /// real difference and not decoder noise. `orientation` writes the EXIF
    /// tag without transposing the pixels — that's what makes the portrait
    /// fixture exercise the orientation path.
    static func writeFixture(width: Int, height: Int, orientation: Int,
                             named name: String) throws -> URL {
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil, width: width, height: height,
                                  bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw Failure.contextFailed }
        guard let buffer = ctx.data else { throw Failure.contextFailed }
        let rowBytes = ctx.bytesPerRow
        let pixels = buffer.bindMemory(to: UInt8.self, capacity: rowBytes * height)
        for y in 0..<height {
            for x in 0..<width {
                let i = y * rowBytes + x * 4
                // Smooth diagonal ramp + a fine checker so local-contrast
                // stages have something to bite on.
                let ramp = Double(x + y) / Double(width + height)
                let checker = ((x / 4 + y / 4) % 2 == 0) ? 0.08 : -0.08
                let v = min(max(ramp + checker, 0), 1)
                pixels[i] = UInt8(v * 255)
                pixels[i + 1] = UInt8(min(max(ramp * 0.7 + 0.15, 0), 1) * 255)
                pixels[i + 2] = UInt8(min(max(1 - ramp, 0), 1) * 255)
                pixels[i + 3] = 255
            }
        }
        guard let image = ctx.makeImage() else { throw Failure.contextFailed }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("muse-edit-fixtures", isDirectory: true)
            .appendingPathComponent("\(name).jpg")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        guard let dest = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
        else { throw Failure.encodeFailed }
        let props: [CFString: Any] = [
            kCGImagePropertyOrientation: orientation,
            kCGImageDestinationLossyCompressionQuality: 1.0,
        ]
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw Failure.encodeFailed }
        return url
    }

    enum Failure: Error { case contextFailed, encodeFailed, readbackFailed }

    // MARK: - Readback

    /// Straight RGBA8 bytes at a known row stride, so two images can be
    /// compared without worrying about the source's alignment.
    static func rgbaBytes(_ image: CGImage) throws -> (bytes: [UInt8], width: Int, height: Int) {
        let w = image.width, h = image.height
        var buffer = [UInt8](repeating: 0, count: w * h * 4)
        let cs = CGColorSpaceCreateDeviceRGB()
        try buffer.withUnsafeMutableBytes { raw in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h,
                                      bitsPerComponent: 8, bytesPerRow: w * 4, space: cs,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { throw Failure.readbackFailed }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        return (buffer, w, h)
    }

    /// Resamples to an EXACT square grid, deliberately ignoring aspect: the
    /// consistency comparison needs two buffers of identical dimensions, and
    /// aspect-preserving rounding at three different decode scales lands on
    /// off-by-one heights that make the comparison unusable.
    static func downsample(_ image: CGImage, toGrid side: Int) throws -> CGImage {
        let w = side, h = side
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw Failure.contextFailed }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let out = ctx.makeImage() else { throw Failure.contextFailed }
        return out
    }

    /// Mean absolute per-channel difference, normalized to 0…1. Alpha is
    /// excluded — it's constant here and would dilute the signal.
    static func meanChannelError(_ a: CGImage, _ b: CGImage) throws -> Double {
        let lhs = try rgbaBytes(a), rhs = try rgbaBytes(b)
        guard lhs.width == rhs.width, lhs.height == rhs.height else { return .infinity }
        var total = 0.0
        var count = 0
        for i in stride(from: 0, to: lhs.bytes.count, by: 4) {
            for c in 0..<3 {
                total += abs(Double(lhs.bytes[i + c]) - Double(rhs.bytes[i + c]))
                count += 1
            }
        }
        return count > 0 ? (total / Double(count)) / 255.0 : 0
    }

    /// Render a CIImage to a CGImage through the shared preview context —
    /// the same path the app uses, so a context misconfiguration shows up in
    /// tests rather than only on screen.
    static func render(_ image: CIImage) -> CGImage? {
        let extent = image.extent
        guard extent.width >= 1, extent.height >= 1, extent.width.isFinite else { return nil }
        return RenderContexts.preview.createCGImage(
            image, from: extent, format: .RGBA8,
            colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
    }

    /// Mean linear luminance of a rendered image, 0…1.
    static func meanLuminance(_ image: CGImage) throws -> Double {
        let (bytes, _, _) = try rgbaBytes(image)
        var total = 0.0
        var count = 0
        for i in stride(from: 0, to: bytes.count, by: 4) {
            total += 0.2126 * Double(bytes[i]) + 0.7152 * Double(bytes[i + 1])
                   + 0.0722 * Double(bytes[i + 2])
            count += 1
        }
        return count > 0 ? total / Double(count) / 255.0 : 0
    }
}
