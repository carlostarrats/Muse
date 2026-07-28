import XCTest
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers
@testable import Muse

final class VisionDecodeTests: XCTestCase {

    /// Write a solid-colour TIFF of the given size to a temp URL.
    private func makeTIFF(width: Int, height: Int,
                          rgb: (UInt8, UInt8, UInt8) = (90, 69, 35)) throws -> URL {
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = try XCTUnwrap(CGContext(data: nil, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        ctx.setFillColor(red: CGFloat(rgb.0) / 255, green: CGFloat(rgb.1) / 255,
                         blue: CGFloat(rgb.2) / 255, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let img = try XCTUnwrap(ctx.makeImage())
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("muse-test-\(UUID().uuidString).tif")
        let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(
            url as CFURL, UTType.tiff.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, img, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testBoundedDecodeCapsLongEdge() throws {
        let url = try makeTIFF(width: 6000, height: 3000)
        let img = try XCTUnwrap(VisionServices.boundedDecode(url: url, maxPixel: 4096))
        XCTAssertEqual(max(img.width, img.height), 4096,
                       "long edge must be clamped to maxPixel")
        // Aspect ratio preserved.
        XCTAssertEqual(Double(img.width) / Double(img.height), 2.0, accuracy: 0.01)
    }

    func testBoundedDecodeLeavesSmallImagesAlone() throws {
        let url = try makeTIFF(width: 800, height: 600)
        let img = try XCTUnwrap(VisionServices.boundedDecode(url: url, maxPixel: 4096))
        XCTAssertEqual(img.width, 800)
        XCTAssertEqual(img.height, 600)
    }

    func testBoundedDecodeRefusesDecompressionBomb() throws {
        // Declared pixel count over the 300 MP budget must be refused before any
        // decode happens. 20000x16000 = 320 MP — over budget, but a solid-colour
        // TIFF of that size still writes quickly and doesn't fill the disk.
        let url = try makeTIFF(width: 20_000, height: 16_000)
        XCTAssertNil(VisionServices.boundedDecode(url: url, maxPixel: 4096),
                     "withinDecodeBudget must still reject an over-budget image")
    }

    func testBoundedDecodeReturnsNilForNonImage() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("muse-test-\(UUID().uuidString).txt")
        try "not an image".write(to: url, atomically: true, encoding: .utf8)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        XCTAssertNil(VisionServices.boundedDecode(url: url, maxPixel: 4096))
    }

    func testAnalysisMaxPixelIsFourK() {
        XCTAssertEqual(VisionServices.analysisMaxPixel, 4096)
    }
}
