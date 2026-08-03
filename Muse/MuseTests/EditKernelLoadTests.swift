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

// MARK: - Spec 05 kernels

extension EditKernelLoadTests {
    func testZebraStripesKernelLoads() {
        XCTAssertNotNil(EditKernels.zebraStripes, "zebraStripes missing from the default metallib")
    }
    func testTzLog2LumaKernelLoads() { XCTAssertNotNil(EditKernels.tzLog2Luma) }
    func testTzSquareKernelLoads() { XCTAssertNotNil(EditKernels.tzSquare) }
    func testTzLinearCoeffsKernelLoads() { XCTAssertNotNil(EditKernels.tzLinearCoeffs) }
    func testTzApplyCoeffsKernelLoads() { XCTAssertNotNil(EditKernels.tzApplyCoeffs) }
    func testToneZoneGainKernelLoads() { XCTAssertNotNil(EditKernels.toneZoneGain) }
    func testZoneHatchKernelLoads() { XCTAssertNotNil(EditKernels.zoneHatch) }
    func testLutMixKernelLoads() { XCTAssertNotNil(EditKernels.lutMix) }

    /// All-zero gains must be an EXACT identity in the KERNEL too, not just in
    /// the Swift mirror — this is the half of the pair the goldens can't see
    /// directly.
    func testToneZoneGainIsIdentityAtZeroGains() throws {
        let kernel = try XCTUnwrap(EditKernels.toneZoneGain)
        let source = CIImage(color: CIColor(red: 0.4, green: 0.5, blue: 0.6))
            .cropped(to: CGRect(x: 0, y: 0, width: 8, height: 8))
        let ev = CIImage(color: CIColor(red: -2, green: -2, blue: -2))
            .cropped(to: source.extent)
        var arguments: [Any] = [source, ev]
        for _ in 0..<9 { arguments.append(Float(0)) }
        let out = try XCTUnwrap(kernel.apply(extent: source.extent,
                                             roiCallback: { _, r in r },
                                             arguments: arguments))
        let a = try XCTUnwrap(EditRenderTestSupport.render(source))
        let b = try XCTUnwrap(EditRenderTestSupport.render(out))
        XCTAssertEqual(try EditRenderTestSupport.meanChannelError(a, b), 0, accuracy: 0.002)
    }

    /// A gain at the zone the pixels actually occupy brightens them; a gain in
    /// a DISTANT zone leaves them alone. That separation is the whole point of
    /// a zone control, and it's what the raised-cosine weighting buys.
    ///
    /// The EV image is BLACK on purpose: `CIColor` clamps to 0…1, so a
    /// negative-EV fixture would silently become 0 and this would test nothing.
    /// 0 EV is zone 8's centre, which is a perfectly good zone to probe.
    func testToneZoneGainAffectsOnlyTheMatchingZone() throws {
        let kernel = try XCTUnwrap(EditKernels.toneZoneGain)
        let source = CIImage(color: CIColor(red: 0.25, green: 0.25, blue: 0.25))
            .cropped(to: CGRect(x: 0, y: 0, width: 8, height: 8))
        let ev = CIImage(color: CIColor(red: 0, green: 0, blue: 0)).cropped(to: source.extent)

        func luminance(gainAt index: Int) throws -> Double {
            var arguments: [Any] = [source, ev]
            for i in 0..<9 { arguments.append(Float(i == index ? 0.5 : 0)) }
            let out = try XCTUnwrap(kernel.apply(extent: source.extent,
                                                 roiCallback: { _, r in r },
                                                 arguments: arguments))
            return try EditRenderTestSupport.meanLuminance(
                try XCTUnwrap(EditRenderTestSupport.render(out)))
        }

        let base = try EditRenderTestSupport.meanLuminance(
            try XCTUnwrap(EditRenderTestSupport.render(source)))
        XCTAssertGreaterThan(try luminance(gainAt: 8), base + 0.05)
        XCTAssertEqual(try luminance(gainAt: 0), base, accuracy: 0.01)
    }

    /// Strength 1 is the LUT alone, strength 0 the base — the mix has to be
    /// exact at both ends or a "0%" look would still tint the photo.
    func testLutMixIsExactAtBothEnds() throws {
        let kernel = try XCTUnwrap(EditKernels.lutMix)
        let base = CIImage(color: CIColor(red: 0.2, green: 0.2, blue: 0.2))
            .cropped(to: CGRect(x: 0, y: 0, width: 8, height: 8))
        let lutted = CIImage(color: CIColor(red: 0.8, green: 0.8, blue: 0.8))
            .cropped(to: base.extent)
        let atZero = try XCTUnwrap(kernel.apply(extent: base.extent,
                                                roiCallback: { _, r in r },
                                                arguments: [base, lutted, Float(0)]))
        let atOne = try XCTUnwrap(kernel.apply(extent: base.extent,
                                               roiCallback: { _, r in r },
                                               arguments: [base, lutted, Float(1)]))
        XCTAssertEqual(try EditRenderTestSupport.meanChannelError(
            try XCTUnwrap(EditRenderTestSupport.render(atZero)),
            try XCTUnwrap(EditRenderTestSupport.render(base))), 0, accuracy: 0.002)
        XCTAssertEqual(try EditRenderTestSupport.meanChannelError(
            try XCTUnwrap(EditRenderTestSupport.render(atOne)),
            try XCTUnwrap(EditRenderTestSupport.render(lutted))), 0, accuracy: 0.002)
    }
}

// MARK: - Stage B

extension EditKernelLoadTests {

    func testStageBKernelsLoadFromDefaultMetallib() {
        XCTAssertNotNil(EditKernels.hslAdjust, "hslAdjust missing from the default metallib")
        XCTAssertNotNil(EditKernels.splitTone, "splitTone missing from the default metallib")
        XCTAssertNotNil(EditKernels.grain, "grain missing from the default metallib")
    }

    /// All-zero HSL must be an EXACT identity. A "neutral" that shifts pixels
    /// means the stack is never really off, and the user cannot get back to
    /// their original by zeroing the sliders.
    func testHSLIsIdentityAtZero() throws {
        let kernel = try XCTUnwrap(EditKernels.hslAdjust)
        let source = CIImage(color: CIColor(red: 0.2, green: 0.55, blue: 0.35))
            .cropped(to: CGRect(x: 0, y: 0, width: 8, height: 8))
        var args: [Any] = [source]
        args += Array(repeating: Float(0), count: 24)
        let out = try XCTUnwrap(kernel.apply(extent: source.extent, arguments: args))
        let a = try XCTUnwrap(EditRenderTestSupport.render(source))
        let b = try XCTUnwrap(EditRenderTestSupport.render(out))
        XCTAssertEqual(try EditRenderTestSupport.meanChannelError(a, b), 0, accuracy: 0.004)
    }

    /// A grey pixel has no hue to target, so HSL must leave it alone no matter
    /// how hard the bands are pushed — otherwise a saturation move tints the
    /// neutrals, which is the classic HSL implementation bug.
    func testHSLLeavesGreyUntouched() throws {
        let kernel = try XCTUnwrap(EditKernels.hslAdjust)
        let source = CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5))
            .cropped(to: CGRect(x: 0, y: 0, width: 8, height: 8))
        var args: [Any] = [source]
        args += Array(repeating: Float(1), count: 24)
        let out = try XCTUnwrap(kernel.apply(extent: source.extent, arguments: args))
        let a = try XCTUnwrap(EditRenderTestSupport.render(source))
        let b = try XCTUnwrap(EditRenderTestSupport.render(out))
        XCTAssertEqual(try EditRenderTestSupport.meanChannelError(a, b), 0, accuracy: 0.004)
    }

    /// Split toning at zero saturation is an exact identity — the model calls
    /// that neutral, so the kernel must agree.
    func testSplitToneIsIdentityAtZeroSaturation() throws {
        let kernel = try XCTUnwrap(EditKernels.splitTone)
        let source = CIImage(color: CIColor(red: 0.3, green: 0.45, blue: 0.7))
            .cropped(to: CGRect(x: 0, y: 0, width: 8, height: 8))
        let out = try XCTUnwrap(kernel.apply(extent: source.extent, arguments: [
            source, Float(1), Float(0.5), Float(0), Float(0),
            Float(0), Float(0.5), Float(1), Float(0), Float(0),
        ]))
        let a = try XCTUnwrap(EditRenderTestSupport.render(source))
        let b = try XCTUnwrap(EditRenderTestSupport.render(out))
        XCTAssertEqual(try EditRenderTestSupport.meanChannelError(a, b), 0, accuracy: 0.004)
    }

    /// Grain at zero amount is an exact identity.
    func testGrainIsIdentityAtZeroAmount() throws {
        let kernel = try XCTUnwrap(EditKernels.grain)
        let source = CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5))
            .cropped(to: CGRect(x: 0, y: 0, width: 16, height: 16))
        let out = try XCTUnwrap(kernel.apply(extent: source.extent,
                                             arguments: [source, Float(0), Float(4),
                                                         Float(0.5), Float(0.25)]))
        let a = try XCTUnwrap(EditRenderTestSupport.render(source))
        let b = try XCTUnwrap(EditRenderTestSupport.render(out))
        XCTAssertEqual(try EditRenderTestSupport.meanChannelError(a, b), 0, accuracy: 0.004)
    }

    /// The same seed must produce the same field, and a different seed a
    /// different one. This is the property that makes the grid tile, the
    /// on-screen preview and the export agree.
    func testGrainIsDeterministicPerSeed() throws {
        let kernel = try XCTUnwrap(EditKernels.grain)
        let source = CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5))
            .cropped(to: CGRect(x: 0, y: 0, width: 32, height: 32))
        func field(seed: Float) throws -> CGImage {
            let out = try XCTUnwrap(kernel.apply(extent: source.extent,
                                                 arguments: [source, Float(1), Float(3),
                                                             Float(0.5), seed]))
            return try XCTUnwrap(EditRenderTestSupport.render(out))
        }
        let a = try field(seed: 0.25)
        let b = try field(seed: 0.25)
        let c = try field(seed: 0.75)
        XCTAssertEqual(try EditRenderTestSupport.meanChannelError(a, b), 0, accuracy: 0.0001,
                       "same seed must give the same grain")
        XCTAssertGreaterThan(try EditRenderTestSupport.meanChannelError(a, c), 0.005,
                             "a different seed must give a different grain")
    }
}
