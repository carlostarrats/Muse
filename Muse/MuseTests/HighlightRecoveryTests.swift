import XCTest
import CoreImage
@testable import Muse

/// The scene-referred pin.
///
/// If any stage clamps to 0…1 before the display transform, every value above
/// white collapses to white and pulling exposure down just makes flat grey —
/// "highlight recovery does nothing" is the symptom, and it's the single
/// easiest thing to break by inserting a well-meaning clamp mid-chain.
final class HighlightRecoveryTests: XCTestCase {
    /// Built from a FLOAT bitmap, not `CIImage(color:)` — the latter clamps
    /// its components to 0…1, which would make this whole file pass
    /// vacuously (both "hot" fixtures collapse to white before the render even
    /// starts, so of course they come out equal).
    private func hotImage(_ value: Float) -> LinearImage {
        let side = 8
        var pixels = [Float](repeating: 0, count: side * side * 4)
        for i in stride(from: 0, to: pixels.count, by: 4) {
            pixels[i] = value; pixels[i + 1] = value; pixels[i + 2] = value
            pixels[i + 3] = 1
        }
        let data = pixels.withUnsafeBufferPointer { Data(buffer: $0) }
        let ci = CIImage(bitmapData: data, bytesPerRow: side * 4 * MemoryLayout<Float>.size,
                         size: CGSize(width: side, height: side), format: .RGBAf,
                         colorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!)
        return LinearImage.alreadyDecodedFromFile(ci)
    }

    func testNegativeExposureRecoversClippedHighlightDetail() throws {
        var stack = EditStack.fresh()
        stack.setTone { $0.exposureEV = -2 }

        // Two regions that BOTH display as white before the edit (2.0 and 4.0
        // are equally clipped on screen). After −2 EV they must separate —
        // that separation IS the recovered detail.
        let dim = EditRenderer.apply(stack, to: hotImage(2), sourceLongEdge: 8)
        let bright = EditRenderer.apply(stack, to: hotImage(4), sourceLongEdge: 8)

        let dimLuma = try EditRenderTestSupport.meanLuminance(
            try XCTUnwrap(EditRenderTestSupport.render(dim.ciImage)))
        let brightLuma = try EditRenderTestSupport.meanLuminance(
            try XCTUnwrap(EditRenderTestSupport.render(bright.ciImage)))

        XCTAssertGreaterThan(brightLuma - dimLuma, 0.05,
                             "highlight headroom was clamped somewhere in the chain")
        XCTAssertLessThan(dimLuma, 0.99, "−2 EV on 2.0 should no longer be clipped white")
    }

    func testUneditedHotDataStillDisplaysAsWhite() throws {
        let rendered = try XCTUnwrap(EditRenderTestSupport.render(hotImage(2).ciImage))
        XCTAssertGreaterThan(try EditRenderTestSupport.meanLuminance(rendered), 0.99)
    }
}
