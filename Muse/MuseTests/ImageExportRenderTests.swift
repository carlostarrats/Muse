//
//  ImageExportRenderTests.swift
//  MuseTests
//
//  The general export pipeline, end to end against real files. Fixtures are
//  generated at runtime via SocialFixtures rather than checked in, for the
//  reasons that file's header gives.
//
//  Two of these are guarding rules rather than behaviour: metadata-off output
//  must be PROVABLY clean, and a collision must never overwrite. Both are the
//  kind of thing that works today and quietly stops working later.
//

import XCTest
import ImageIO
import UniformTypeIdentifiers
@testable import Muse

final class ImageExportRenderTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("export-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func properties(of url: URL) throws -> [String: Any] {
        let src = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        return try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [String: Any])
    }

    // MARK: - Size

    func testOriginalSizeKeepsTheSourceDimensions() throws {
        let src = try SocialFixtures.makeJPEG(width: 1200, height: 900, name: "orig", in: dir)
        let result = try ImageExportRender.export(
            .init(sourceURL: src, settings: ExportSettings(format: .jpeg)), to: dir)
        XCTAssertEqual(result.pixelSize.width, 1200, accuracy: 0.5)
        XCTAssertEqual(result.pixelSize.height, 900, accuracy: 0.5)
    }

    func testLongEdgeProducesExactDimensions() throws {
        let src = try SocialFixtures.makeJPEG(width: 4000, height: 3000, name: "wide", in: dir)
        let result = try ImageExportRender.export(
            .init(sourceURL: src, settings: ExportSettings(format: .jpeg, resize: .longEdge(1000))),
            to: dir)
        XCTAssertEqual(result.pixelSize.width, 1000, accuracy: 0.5)
        XCTAssertEqual(result.pixelSize.height, 750, accuracy: 0.5)
    }

    func testFitWithinProducesExactDimensions() throws {
        let src = try SocialFixtures.makeJPEG(width: 4000, height: 2000, name: "pano", in: dir)
        let result = try ImageExportRender.export(
            .init(sourceURL: src,
                  settings: ExportSettings(format: .jpeg,
                                           resize: .fitWithin(width: 1000, height: 1000))),
            to: dir)
        XCTAssertEqual(result.pixelSize.width, 1000, accuracy: 0.5)
        XCTAssertEqual(result.pixelSize.height, 500, accuracy: 0.5)
    }

    func testNeverUpscales() throws {
        let src = try SocialFixtures.makeJPEG(width: 400, height: 300, name: "small", in: dir)
        let result = try ImageExportRender.export(
            .init(sourceURL: src, settings: ExportSettings(format: .jpeg, resize: .longEdge(4000))),
            to: dir)
        XCTAssertEqual(result.pixelSize.width, 400, accuracy: 0.5)
        XCTAssertEqual(result.pixelSize.height, 300, accuracy: 0.5)
    }

    // MARK: - Containers

    func testPNGOutputIsAPNG() throws {
        let src = try SocialFixtures.makeJPEG(width: 800, height: 600, name: "topng", in: dir)
        let result = try ImageExportRender.export(
            .init(sourceURL: src, settings: ExportSettings(format: .png)), to: dir)
        XCTAssertEqual(result.url.pathExtension, "png")
        let written = try XCTUnwrap(CGImageSourceCreateWithURL(result.url as CFURL, nil))
        XCTAssertEqual(CGImageSourceGetType(written) as String?, UTType.png.identifier)
    }

    func testTIFFOutputIsATIFF() throws {
        let src = try SocialFixtures.makeJPEG(width: 400, height: 300, name: "totiff", in: dir)
        let result = try ImageExportRender.export(
            .init(sourceURL: src, settings: ExportSettings(format: .tiff)), to: dir)
        XCTAssertEqual(result.url.pathExtension, "tif")
        let written = try XCTUnwrap(CGImageSourceCreateWithURL(result.url as CFURL, nil))
        XCTAssertEqual(CGImageSourceGetType(written) as String?, UTType.tiff.identifier)
    }

    func testHEICOutputIsAHEIC() throws {
        let src = try SocialFixtures.makeJPEG(width: 400, height: 300, name: "toheic", in: dir)
        let result = try ImageExportRender.export(
            .init(sourceURL: src, settings: ExportSettings(format: .heic)), to: dir)
        XCTAssertEqual(result.url.pathExtension, "heic")
        XCTAssertGreaterThan(result.bytes, 0)
    }

    // MARK: - Depth

    /// OutputFormat.tiff16 was nominal before this feature — the case existed
    /// and produced 8-bit. A depth claim the bytes don't support is worse than
    /// no option at all, so this pins the real thing.
    func testSixteenBitTIFFIsActuallySixteenBit() throws {
        let src = try SocialFixtures.makeJPEG(width: 600, height: 400, name: "deep", in: dir)
        let result = try ImageExportRender.export(
            .init(sourceURL: src, settings: ExportSettings(format: .tiff, tiff16: true)), to: dir)
        XCTAssertEqual(try properties(of: result.url)[kCGImagePropertyDepth as String] as? Int, 16)
    }

    func testEightBitTIFFIsEightBit() throws {
        let src = try SocialFixtures.makeJPEG(width: 600, height: 400, name: "shallow", in: dir)
        let result = try ImageExportRender.export(
            .init(sourceURL: src, settings: ExportSettings(format: .tiff, tiff16: false)), to: dir)
        XCTAssertEqual(try properties(of: result.url)[kCGImagePropertyDepth as String] as? Int, 8)
    }

    // MARK: - Metadata

    /// Metadata off must be PROVABLY clean, not merely constructed to be. Same
    /// rule the social and Drive paths hold.
    func testMetadataOffProducesACleanFile() throws {
        let src = try SocialFixtures.makeJPEG(width: 800, height: 600, name: "stripped", in: dir)
        let result = try ImageExportRender.export(
            .init(sourceURL: src, settings: ExportSettings(format: .jpeg, includeEXIF: false)),
            to: dir)
        XCTAssertTrue(ImageMetadataStripper.isClean(try Data(contentsOf: result.url)))
    }

    /// Orientation is BAKED at decode, so no output can carry a tag — a viewer
    /// that ignores the tag and one that honours it must agree.
    func testOutputCarriesNoOrientationTag() throws {
        // 6 = rotate 90°, so the 800×600 stored file displays as 600×800.
        let src = try SocialFixtures.makeJPEG(width: 800, height: 600, orientation: 6,
                                              name: "rot", in: dir)
        let result = try ImageExportRender.export(
            .init(sourceURL: src, settings: ExportSettings(format: .jpeg)), to: dir)
        XCTAssertNil(try properties(of: result.url)[kCGImagePropertyOrientation as String])
        XCTAssertEqual(result.pixelSize.width, 600, accuracy: 0.5)
        XCTAssertEqual(result.pixelSize.height, 800, accuracy: 0.5)
    }

    // MARK: - Naming

    /// Never overwrite. Two exports of one source into one folder produce two
    /// files — this is the only way the feature could destroy a user's data.
    func testCollisionAddsASuffixRatherThanOverwriting() throws {
        let src = try SocialFixtures.makeJPEG(width: 400, height: 300, name: "twice", in: dir)
        let job = ImageExportRender.Job(sourceURL: src, settings: ExportSettings(format: .png))
        let first = try ImageExportRender.export(job, to: dir)
        let second = try ImageExportRender.export(job, to: dir)
        XCTAssertNotEqual(first.url, second.url)
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.url.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.url.path))
        XCTAssertEqual(first.url.lastPathComponent, "twice.png")
        XCTAssertEqual(second.url.lastPathComponent, "twice-2.png")
    }

    /// Exporting a JPEG as a JPEG into the folder it already lives in must not
    /// land on top of the original.
    func testExportingIntoTheSourceFolderNeverTouchesTheSource() throws {
        let src = try SocialFixtures.makeJPEG(width: 400, height: 300, name: "self", in: dir)
        let before = try Data(contentsOf: src)
        let result = try ImageExportRender.export(
            .init(sourceURL: src, settings: ExportSettings(format: .jpeg)), to: dir)
        XCTAssertNotEqual(result.url, src)
        XCTAssertEqual(try Data(contentsOf: src), before, "the original was modified")
    }

    func testExportKeepsTheSourceStem() throws {
        let src = try SocialFixtures.makeJPEG(width: 400, height: 300, name: "my-photo", in: dir)
        let result = try ImageExportRender.export(
            .init(sourceURL: src, settings: ExportSettings(format: .png)), to: dir)
        XCTAssertEqual(result.url.deletingPathExtension().lastPathComponent, "my-photo")
    }

    // MARK: - Quality

    func testLowerQualityProducesASmallerFile() throws {
        let src = try SocialFixtures.makeJPEG(width: 1200, height: 900, content: .noise,
                                              name: "q", in: dir)
        let low = try ImageExportRender.export(
            .init(sourceURL: src, settings: ExportSettings(format: .jpeg, quality: 0.3)), to: dir)
        let high = try ImageExportRender.export(
            .init(sourceURL: src, settings: ExportSettings(format: .jpeg, quality: 0.98)), to: dir)
        XCTAssertLessThan(low.bytes, high.bytes)
    }
}
