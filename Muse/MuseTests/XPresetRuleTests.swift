//
//  XPresetRuleTests.swift
//  MuseTests
//
//  The five hard invariants X's documented no-recompress rule requires, pinned
//  on their own so a future pipeline change that breaks JUST these shows up as a
//  named, obviously-X-related failure rather than as generic pipeline noise.
//  End-to-end survival (post → download `?name=orig` → byte-compare) is an owner
//  protocol, not a unit test — X's server behavior is outside the app.
//

import XCTest
import ImageIO
@testable import Muse

final class XPresetRuleTests: XCTestCase {
    private var scratch: URL!
    private var xPreset: SocialPreset { SocialPreset.all.first { $0.id == "x" }! }

    override func setUpWithError() throws {
        try super.setUpWithError()
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("x-preset-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }
    override func tearDown() {
        try? FileManager.default.removeItem(at: scratch)
        super.tearDown()
    }

    private func export(_ url: URL) throws -> SocialRender.Result {
        try SocialRender.export(
            SocialRender.Job(sourceURL: url, preset: xPreset, fit: .crop, matte: .white,
                             cropRect: nil, includeEXIF: false, includeLocation: false),
            to: scratch)
    }

    private func big() throws -> URL {
        try SocialFixtures.makeJPEG(width: 6000, height: 4000, name: "x-big", in: scratch)
    }

    func testDimsNeverExceed4096OnA6000pxSource() throws {
        let result = try export(try big())
        XCTAssertLessThanOrEqual(result.pixelSize.width, 4096)
        XCTAssertLessThanOrEqual(result.pixelSize.height, 4096)
    }

    // A full-size, detailed source must land under 5 MB — the ladder steps the
    // quality down off the invariant itself, not off a byte target (X has none).
    func testEncodedSizeUnder5MBOnAFullSizeSource() throws {
        let result = try export(try SocialFixtures.makeJPEG(
            width: 5000, height: 5000, name: "x-full", in: scratch))
        XCTAssertLessThan(result.bytes, 5 * 1024 * 1024)
        XCTAssertLessThanOrEqual(max(result.pixelSize.width, result.pixelSize.height), 4096)
    }

    // Per-pixel random noise is maximally incompressible — far beyond any real
    // photograph (measured ~11 MB at 4096² even at the 0.55 floor). The
    // documented behavior is to FAIL that file rather than ship one X would
    // recompress, so the export must throw rather than write.
    func testPathologicalSourceFailsRatherThanShippingARecompressibleFile() throws {
        let noise = try SocialFixtures.makeJPEG(width: 4096, height: 4096, content: .noise,
                                                name: "x-noise", in: scratch)
        XCTAssertThrowsError(try export(noise)) { error in
            guard case SocialRender.RenderError.xInvariantFailed = error else {
                return XCTFail("expected an X invariant failure, got \(error)")
            }
        }
        // …and nothing was written for it.
        let written = try FileManager.default.contentsOfDirectory(atPath: scratch.path)
        XCTAssertFalse(written.contains("x-noise-x.jpg"))
    }

    func testRGBNoAlpha() throws {
        let result = try export(try big())
        let src = try XCTUnwrap(CGImageSourceCreateWithURL(result.url as CFURL, nil))
        let props = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [String: Any])
        XCTAssertNotEqual(props[kCGImagePropertyHasAlpha as String] as? Bool, true)
        XCTAssertEqual(props[kCGImagePropertyColorModel as String] as? String,
                       kCGImagePropertyColorModelRGB as String)
    }

    func testNoEXIFOrientationTag() throws {
        let rotated = try SocialFixtures.makeJPEG(width: 4000, height: 3000, orientation: 6,
                                                  name: "x-oriented", in: scratch)
        let result = try export(rotated)
        let src = try XCTUnwrap(CGImageSourceCreateWithURL(result.url as CFURL, nil))
        let props = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [String: Any])
        XCTAssertNil(props[kCGImagePropertyOrientation as String])
    }

    func testBytesLessThanWidthTimesHeight() throws {
        let result = try export(try big())
        XCTAssertLessThan(Double(result.bytes),
                          Double(result.pixelSize.width * result.pixelSize.height))
    }

    // The verifier is the gate, not a comment: an output that misses any
    // invariant must throw rather than be written.
    func testVerifierRejectsAnOversizedImage() {
        XCTAssertThrowsError(try SocialRender.verifyXInvariants(
            data: Data(count: 10), pixelSize: CGSize(width: 5000, height: 100)))
        XCTAssertThrowsError(try SocialRender.verifyXInvariants(
            data: Data(count: 6 * 1024 * 1024), pixelSize: CGSize(width: 4096, height: 4096)))
    }
}
