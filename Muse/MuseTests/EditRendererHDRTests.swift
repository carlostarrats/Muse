//
//  EditRendererHDRTests.swift
//  MuseTests
//
//  The edit chain's two ends. `RenderContexts` already worked in extended
//  linear, so the interior was never the problem — the clamps were the decode
//  (no `expandToHDR`) and the two `createCGImage(colorSpace: sRGB)` calls.
//

import XCTest
import CoreImage
import CoreGraphics
@testable import Muse

final class EditRendererHDRTests: XCTestCase {

    func testSourceHeadroomReadsAnHDRFile() throws {
        let url = try HDRTestFixtures.hdrHEIC(value: 4.0)
        XCTAssertGreaterThan(EditRenderer.sourceHeadroom(url: url), 1.0)
    }

    func testSourceHeadroomReadsAnSDRFileAsOne() throws {
        let url = try HDRTestFixtures.sdrPNG(value: 0.5)
        XCTAssertEqual(EditRenderer.sourceHeadroom(url: url), 1.0, accuracy: 0.01)
    }

    /// The regression this whole task exists to prevent: an HDR photo going
    /// flat the moment it passes through the editor.
    func testHDRSourceRendersWithoutClamping() throws {
        let url = try HDRTestFixtures.hdrHEIC(value: 4.0)
        let cg = try XCTUnwrap(EditRenderer.render(url: url, stack: .fresh(), maxPixel: 256))
        let px = HDRTestFixtures.firstPixel(CIImage(cgImage: cg))
        XCTAssertGreaterThan(px.r, 2.0, "the edit chain must not clamp an HDR source")
    }

    /// An ordinary photo must not start paying for a deep render just because
    /// the HDR path exists.
    func testSDRSourceStaysEightBit() throws {
        let url = try HDRTestFixtures.sdrPNG(value: 0.5)
        let cg = try XCTUnwrap(EditRenderer.render(url: url, stack: .fresh(), maxPixel: 256))
        XCTAssertEqual(cg.bitsPerComponent, 8)
    }

    /// `exportFile` deliberately writes SDR — but by tone-mapping, never by
    /// clipping. Two different bright values must stay different.
    func testExportFileTonemapsRatherThanClipping() throws {
        let url = try HDRTestFixtures.hdrGradient(low: 1.5, high: 4.0)
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("export-\(UUID().uuidString).png")
        try EditRenderer.exportFile(url: url, stack: .fresh(), to: dest, format: .png)
        let distinct = try HDRTestFixtures.distinctLuminanceCount(of: dest)
        XCTAssertGreaterThan(distinct, 1,
                             "a hard clip would collapse both values onto the same white")
    }
}
