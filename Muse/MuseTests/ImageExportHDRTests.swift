//
//  ImageExportHDRTests.swift
//  MuseTests
//
//  Export had three separate defects: `.sameAsOriginal` re-encoded a file it
//  was only asked to copy (destroying the gain map), everything else
//  hard-clipped instead of tone-mapping, and HEIC never carried HDR at all.
//

import XCTest
import CoreGraphics
@testable import Muse

final class ImageExportHDRTests: XCTestCase {

    private func freshDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("export-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func passthroughSettings() -> ExportSettings {
        ExportSettings(format: .sameAsOriginal, resize: .original,
                       includeEXIF: true, includeLocation: true)
    }

    /// The whole point of the passthrough: bytes in, same bytes out, gain map
    /// and all.
    func testUneditedSameAsOriginalCopiesBytes() throws {
        let source = try HDRTestFixtures.hdrHEIC(value: 4.0)
        let dir = try freshDirectory()
        let result = try ImageExportRender.export(
            .init(sourceURL: source, settings: passthroughSettings()), to: dir)
        XCTAssertEqual(try Data(contentsOf: result.url), try Data(contentsOf: source),
                       "an unedited same-as-original export must not re-encode")
    }

    /// Stripping metadata is a CHANGE, so it must not take the copy path —
    /// otherwise "don't include EXIF" would silently ship the EXIF anyway.
    func testMetadataStrippingDoesNotTakeTheCopyPath() throws {
        let source = try HDRTestFixtures.hdrHEIC(value: 4.0)
        var settings = passthroughSettings()
        settings.includeEXIF = false
        let dir = try freshDirectory()
        let result = try ImageExportRender.export(
            .init(sourceURL: source, settings: settings), to: dir)
        XCTAssertNotEqual(try Data(contentsOf: result.url), try Data(contentsOf: source))
    }

    /// A resize is a change too.
    func testResizeDoesNotTakeTheCopyPath() throws {
        let source = try HDRTestFixtures.hdrHEIC(value: 4.0)
        var settings = passthroughSettings()
        settings.resize = .longEdge(8)
        let dir = try freshDirectory()
        let result = try ImageExportRender.export(
            .init(sourceURL: source, settings: settings), to: dir)
        XCTAssertNotEqual(try Data(contentsOf: result.url), try Data(contentsOf: source))
        XCTAssertLessThanOrEqual(max(result.pixelSize.width, result.pixelSize.height), 8)
    }

    /// A PNG export of an HDR source must ROLL OFF the highlights. A clip
    /// collapses two different bright values onto the same white; a tone map
    /// keeps them apart, and that difference is the only observable one.
    func testPNGExportOfHDRSourceDoesNotFlatClip() throws {
        let source = try HDRTestFixtures.hdrGradient(low: 1.5, high: 4.0)
        var settings = passthroughSettings()
        settings.format = .png
        let dir = try freshDirectory()
        let result = try ImageExportRender.export(
            .init(sourceURL: source, settings: settings), to: dir)
        XCTAssertGreaterThan(try HDRTestFixtures.distinctLuminanceCount(of: result.url), 1,
                             "a hard clip would collapse both values onto the same white")
    }

    // MARK: - Which formats carry HDR

    func testOnlyHEICCarriesHDR() {
        XCTAssertFalse(ImageExportRender.wantsHDR(headroom: 4.0, format: .png))
        XCTAssertFalse(ImageExportRender.wantsHDR(headroom: 4.0, format: .jpeg))
        XCTAssertFalse(ImageExportRender.wantsHDR(headroom: 4.0, format: .tiff))
        XCTAssertFalse(ImageExportRender.wantsHDR(headroom: 4.0, format: .webp))
    }

    func testAnSDRSourceNeverWritesHDREvenAsHEIC() {
        XCTAssertFalse(ImageExportRender.wantsHDR(headroom: 1.0, format: .heic))
    }

    @available(macOS 15.0, *)
    func testHEICFromAnHDRSourceWritesHDR() {
        XCTAssertTrue(ImageExportRender.wantsHDR(headroom: 4.0, format: .heic))
    }
}
