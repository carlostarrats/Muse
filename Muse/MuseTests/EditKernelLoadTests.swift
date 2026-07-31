import XCTest
import CoreImage
@testable import Muse

/// A real build-phase smoke test: if `EditKernels.metal` isn't in the target's
/// Compile Sources phase, or the stitchable functions were renamed, these fail
/// here instead of silently degrading to "clarity does nothing" for users.
final class EditKernelLoadTests: XCTestCase {
    func testToneBandsKernelLoadsFromDefaultMetallib() {
        XCTAssertNotNil(EditKernels.toneBands, "toneBands missing from the default metallib")
    }

    func testClarityTextureKernelLoadsFromDefaultMetallib() {
        XCTAssertNotNil(EditKernels.clarityTexture,
                        "clarityTexture missing from the default metallib")
    }

    /// All-zero params must be an EXACT identity, not approximately one —
    /// otherwise merely having a tone case present shifts the image.
    func testToneBandsIsIdentityAtZero() throws {
        let kernel = try XCTUnwrap(EditKernels.toneBands)
        let source = CIImage(color: CIColor(red: 0.4, green: 0.5, blue: 0.6))
            .cropped(to: CGRect(x: 0, y: 0, width: 8, height: 8))
        let out = try XCTUnwrap(kernel.apply(extent: source.extent,
                                             arguments: [source, Float(0), Float(0),
                                                         Float(0), Float(0)]))
        let a = try XCTUnwrap(EditRenderTestSupport.render(source))
        let b = try XCTUnwrap(EditRenderTestSupport.render(out))
        XCTAssertEqual(try EditRenderTestSupport.meanChannelError(a, b), 0, accuracy: 0.002)
    }

    /// Hue preservation is the whole reason this is one multiplicative gain
    /// rather than per-channel curves: recovering a blown sky must not drag it
    /// toward cyan.
    func testToneBandsPreservesChannelRatios() throws {
        let kernel = try XCTUnwrap(EditKernels.toneBands)
        let source = CIImage(color: CIColor(red: 0.2, green: 0.4, blue: 0.8))
            .cropped(to: CGRect(x: 0, y: 0, width: 8, height: 8))
        let out = try XCTUnwrap(kernel.apply(extent: source.extent,
                                             arguments: [source, Float(0), Float(0.8),
                                                         Float(0), Float(0)]))
        let (bytes, _, _) = try EditRenderTestSupport.rgbaBytes(
            try XCTUnwrap(EditRenderTestSupport.render(out)))
        let r = Double(bytes[0]), g = Double(bytes[1]), b = Double(bytes[2])
        XCTAssertGreaterThan(g, r)
        XCTAssertGreaterThan(b, g)
    }
}
