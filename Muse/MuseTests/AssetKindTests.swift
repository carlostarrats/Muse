import XCTest
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers
@testable import Muse

final class AssetKindTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AssetKindTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
    }

    /// Encodes a real 2×2 image as `type` and writes it to `name` (no extension
    /// unless `name` carries one). Returns the file URL.
    private func writeImage(_ type: UTType, name: String) throws -> URL {
        let cs = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let ctx = try XCTUnwrap(CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8,
                                          bytesPerRow: 0, space: cs,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        let image = try XCTUnwrap(ctx.makeImage())
        let url = tempDir.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: url)
        let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL,
                                                                 type.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return url
    }

    // Sanity: the normal, extension-bearing case must keep working.
    func testJPEGWithExtensionIsImage() throws {
        let url = try writeImage(.jpeg, name: "photo.jpg")
        XCTAssertEqual(AssetKind.detect(at: url), .image)
    }

    // The bug: an image whose extension was truncated off (a long Instagram
    // alt-text filename that overran the 255-byte limit) loses its ".jpg".
    // macOS then reports it as public.data, so it classified as .unknown —
    // rendering as a file card and opening in the fallback viewer instead of
    // the hero. A content sniff reveals it's really an image.
    func testExtensionlessJPEGClassifiesAsImage() throws {
        let url = try writeImage(.jpeg, name: "no-extension-jpeg")
        XCTAssertEqual(AssetKind.detect(at: url), .image)
    }

    func testExtensionlessPNGClassifiesAsImage() throws {
        let url = try writeImage(.png, name: "no-extension-png")
        XCTAssertEqual(AssetKind.detect(at: url), .image)
    }

    // Mirrors the real filename shape: trailing " BROOK…" gives Foundation an
    // empty pathExtension (stray dots + spaces aren't a valid extension).
    func testTruncatedInstagramStyleNameIsImage() throws {
        let name = "Photo by Kokoroko. May be an image of poster that says NORTH AMERICAN .TOUR OCT11. BROOK…"
        let url = try writeImage(.jpeg, name: name)
        XCTAssertTrue(url.pathExtension.isEmpty, "precondition: name yields no usable extension")
        XCTAssertEqual(AssetKind.detect(at: url), .image)
    }

    // A genuinely non-image extensionless file must NOT be promoted to .image.
    func testExtensionlessNonImageStaysUnknown() throws {
        let url = tempDir.appendingPathComponent("no-extension-text")
        try XCTUnwrap("just some words, not an image".data(using: .utf8)).write(to: url)
        XCTAssertEqual(AssetKind.detect(at: url), .unknown)
    }

    // Unrecognized-but-non-empty extension that is really an image — e.g.
    // Twitter/X's ".jpg_large" downloads. The content sniff applies here too.
    func testUnrecognizedExtensionImageClassifiesAsImage() throws {
        let url = try writeImage(.jpeg, name: "downloaded.jpg_large")
        XCTAssertFalse(url.pathExtension.isEmpty, "precondition: has a (non-mapped) extension")
        XCTAssertNil(AssetKind.byExtension["jpg_large"], "precondition: extension is not pre-mapped")
        XCTAssertEqual(AssetKind.detect(at: url), .image)
    }

    // Unrecognized-but-non-empty extension that is NOT an image stays unknown.
    func testUnrecognizedExtensionNonImageStaysUnknown() throws {
        let url = tempDir.appendingPathComponent("payload.weirdext")
        try XCTUnwrap("definitely not an image".data(using: .utf8)).write(to: url)
        XCTAssertEqual(AssetKind.detect(at: url), .unknown)
    }

    // Every camera-RAW extension we ship (one per brand on rawsamples.ch, plus
    // phone/action-cam DNG variants) must register as `.raw` so it sorts under
    // the RAW filter facet. This is classification ONLY — whether the pixels
    // decode is gated by Apple's camera-RAW codec, which this list can't change.
    // Detection here is a pure extension-map lookup (no bytes read), so an empty
    // placeholder file with the extension is enough to assert the mapping.
    func testCameraRawExtensionsClassifyAsRaw() throws {
        let rawExtensions = [
            "cr2", "cr3", "crw",          // Canon
            "nef", "nrw",                 // Nikon
            "arw", "sr2", "srf",          // Sony
            "dng", "gpr",                 // Adobe DNG (iPhone ProRAW / Android) + GoPro
            "orf",                        // Olympus
            "rw2", "raw",                 // Panasonic
            "raf",                        // Fujifilm
            "srw",                        // Samsung
            "pef",                        // Pentax
            "rwl",                        // Leica
            "3fr", "fff",                 // Hasselblad / Imacon
            "iiq", "cap",                 // Phase One
            "mef",                        // Mamiya
            "mos",                        // Leaf
            "x3f",                        // Sigma / Foveon
            "erf",                        // Epson
            "dcr", "kdc", "k25",          // Kodak
            "mrw",                        // Minolta
            "bay",                        // Casio
        ]
        for ext in rawExtensions {
            XCTAssertEqual(AssetKind.byExtension[ext], .raw,
                           "extension .\(ext) should map to .raw")
            let url = tempDir.appendingPathComponent("sample.\(ext)")
            FileManager.default.createFile(atPath: url.path, contents: Data())
            XCTAssertEqual(AssetKind.detect(at: url), .raw,
                           "a .\(ext) file should classify as .raw")
        }
    }
}
