import XCTest
import ImageIO
import UniformTypeIdentifiers
@testable import Muse

/// `FileMetadata.load` end-to-end against REAL files written to a temp dir.
///
/// The rest of FileMetadata is covered by pure-function tests (FileMetadataTests),
/// and the CG/PDFKit/AVFoundation readers are deliberately not unit-tested. These
/// two cases are the exceptions, because both are properties of the IO path that
/// no pure test can see: the dimensions row has to come out ORIENTED, and a file
/// that has vanished must not have facts invented for it from its path.
final class FileMetadataLoadTests: XCTestCase {

    /// A real JPEG carrying an EXIF orientation, so the loader has something to
    /// resolve dimensions from.
    private func writeJPEG(width: Int, height: Int, orientation: Int) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("muse-metadata-\(UUID().uuidString).jpg")
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                            bytesPerRow: 0, space: space,
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let dest = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!,
                                   [kCGImagePropertyOrientation: orientation] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return url
    }

    func testDimensionsRowIsOriented() async throws {
        // Orientation 6 stores a landscape buffer that DISPLAYS portrait. The
        // INFO card must report what the photo shows — the same single
        // orientation truth the grid and the hero flight read.
        let url = try writeJPEG(width: 4000, height: 3000, orientation: 6)
        defer { try? FileManager.default.removeItem(at: url) }
        ImageHeaderSizeCache.invalidate(url)

        let rows = await FileMetadata.load(url: url, kind: .image).rows
        XCTAssertEqual(rows.first { $0.label == "Dimensions" }?.value, "3000 × 4000")
        XCTAssertEqual(rows.first { $0.label == "MP" }?.value, "12")
        XCTAssertEqual(rows.first { $0.label == "Format" }?.value,
                       FileMetadata.formatFileKind(extension: "jpg"))
        XCTAssertNotNil(rows.first { $0.label == "Size" })
    }

    func testMissingFileInventsNothing() async throws {
        // A viewer can outlive the file it's showing (external delete, the
        // burn-delete undo window). Format is derived from the path's extension,
        // so without the stat guard the card would still assert a file type for
        // a file that isn't there.
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("muse-metadata-missing-\(UUID().uuidString).jpg")
        let rows = await FileMetadata.load(url: url, kind: .image).rows
        XCTAssertTrue(rows.isEmpty,
                      "expected no rows for a missing file, got \(rows.map(\.label))")
    }
}
