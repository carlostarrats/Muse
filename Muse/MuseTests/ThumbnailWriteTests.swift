import XCTest
import AppKit
import ImageIO
import UniformTypeIdentifiers
@testable import Muse

final class ThumbnailWriteTests: XCTestCase {
    private func makeImage(width: Int, height: Int) -> NSImage {
        let cs = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(data: nil, width: width, height: height,
                            bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let cg = ctx.makeImage()!
        return NSImage(cgImage: cg, size: NSSize(width: width, height: height))
    }

    func testEncodePNGProducesValidPNGAtExpectedSize() {
        let image = makeImage(width: 12, height: 9)
        guard let data = ThumbnailCache.encodePNG(image) else {
            return XCTFail("encodePNG returned nil")
        }
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else {
            return XCTFail("bytes were not a decodable image")
        }
        XCTAssertEqual(CGImageSourceGetType(src), UTType.png.identifier as CFString)
        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        XCTAssertEqual(props?[kCGImagePropertyPixelWidth] as? Int, 12)
        XCTAssertEqual(props?[kCGImagePropertyPixelHeight] as? Int, 9)
    }
}
