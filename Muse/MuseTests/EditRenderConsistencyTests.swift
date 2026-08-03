import XCTest
import CoreImage
@testable import Muse

/// THE gate on any renderer change.
///
/// One stack with every group non-neutral, two fixtures (landscape and an
/// EXIF-rotated portrait), rendered at three decode resolutions and compared
/// after downsampling to a common size. They must agree.
///
/// What this catches, and nothing else does: a scale-dependent parameter
/// expressed in PIXELS rather than as a fraction of the long edge. A 3px blur
/// is a heavy effect on a 256px thumbnail and invisible on a 4096px export, so
/// the grid stops matching what the user edited — a bug that looks like a
/// caching problem and isn't.
final class EditRenderConsistencyTests: XCTestCase {
    /// JPEG quantization plus three different decode scales put a real floor
    /// under this; the gate is "the same effect at every size", not bit
    /// equality. A pixel-radius regression moves it far past this.
    let tolerance = 6.0 / 255.0

    /// A tiny fixture LUT, resolvable without touching the user's library:
    /// `LutRegistry`'s cache is the render path's own lookup, so preloading it
    /// is exactly what an import does.
    private static let fixtureLut: (id: String, size: Int, rgb: [Float]) = {
        let size = 2
        var rgb: [Float] = []
        for b in 0..<size { for g in 0..<size { for r in 0..<size {
            rgb.append(Float(r) * 0.9); rgb.append(Float(g) * 0.85); rgb.append(Float(b) * 0.95)
        }}}
        let lut = CubeLUT(size: size, data: rgb)
        return (CubeLUT.hash(lut), size, rgb)
    }()

    override func setUp() {
        super.setUp()
        LutRegistry.preload(id: Self.fixtureLut.id, size: Self.fixtureLut.size,
                            rgb: Self.fixtureLut.rgb)
    }

    func allGroupsStack() -> EditStack {
        var stack = EditStack.fresh()
        var tone = ToneParams.neutral
        tone.exposureEV = 0.5; tone.contrast = 0.2
        tone.highlights = -0.3; tone.shadows = 0.3
        var color = ColorParams.neutral
        color.vibrance = 0.3; color.saturation = 0.1; color.temperature = 0.2
        var presence = PresenceParams.neutral
        presence.clarity = 0.3; presence.texture = 0.2; presence.sharpen = 0.4
        var curve = CurveParams.neutral
        curve.rgb = [CurveParams.Point(x: 0, y: 0.05),
                     CurveParams.Point(x: 0.5, y: 0.55),
                     CurveParams.Point(x: 1, y: 0.95)]
        var vignette = VignetteParams.neutral
        vignette.amount = -0.3
        // Spec 05: EVERY renderable group belongs in this fixture, current and
        // future — a new chain stage lands inside this 3-resolution gate in
        // the same commit that adds it, or a scale-dependent radius ships
        // unnoticed. (`lut` joins via `lutFixtureStack()`, which needs a
        // registered LUT row and so can't live in the shared fixture.)
        var toneZone = ToneZoneParams.neutral
        toneZone.gains[1] = -0.4      // pull the deep shadows
        toneZone.gains[7] = 0.3       // lift the highlights
        let lut = LutParams(lutHash: Self.fixtureLut.id, name: "Fixture", strength: 0.6)
        // Stage B joins the gate in the same commit that added the stages, per
        // the rule above — with ONE deliberate exception, `grain`, explained
        // below `allGroupsStack`.
        var hsl = HSLParams.neutral
        hsl.saturation[5] = -0.5      // blue
        hsl.luminance[2] = 0.3        // yellow
        var split = SplitToneParams.neutral
        split.shadowHue = 0.6; split.shadowSaturation = 0.35
        split.highlightHue = 0.1; split.highlightSaturation = 0.2
        stack.adjustments = [.tone(tone), .color(color), .presence(presence),
                             .curve(curve), .vignette(vignette), .toneZone(toneZone),
                             .lut(lut), .hsl(hsl), .splitTone(split)]
        return stack
    }

    // MARK: - Why grain is not in the fixture above
    //
    // It is the one stage that CANNOT be gated by pixel equality, and leaving a
    // note rather than an omission because the rule above says every renderable
    // group belongs in the fixture.
    //
    // `assertAgreesAcrossResolutions` renders at 256/1024/2048 and downsamples
    // all three to a 128px grid — so it averages 2x, 8x and 16x respectively.
    // Box-averaging high-frequency noise by 8x smooths it far harder than by
    // 2x, so two CORRECT grain renders land at different residual amplitudes
    // and the comparison fails (measured 0.0274 against a 0.0235 tolerance).
    // That is a property of measuring noise through unequal downsampling, not a
    // scale-dependent radius — verified by bisection: with grain removed and
    // `.hsl`/`.splitTone` still present, the fixture passes.
    //
    // Grain gets `testGrainStrengthAgreesAcrossResolutions` instead, which asks
    // the question that actually applies to noise: is the grain the same
    // STRENGTH relative to the image at every size.
    //
    // DO NOT "fix" this by adding grain here and raising `tolerance`. The
    // tolerance is what makes this file catch a pixel-radius regression in
    // every OTHER stage; loosening it to accommodate noise would blind the gate
    // that matters.

    /// Grain's OWN gate, separate from the all-groups fixture because it is
    /// measured differently: the question is not "do two renders look alike"
    /// but "is the grain the same STRENGTH relative to the image at every
    /// size". A pixel-constant cell fails this by a wide margin while a
    /// long-edge fraction holds.
    ///
    /// Surface shipped a preview that dropped grain entirely rather than solve
    /// this; Muse cannot, because the grid IS the product.
    func testGrainStrengthAgreesAcrossResolutions() throws {
        let url = try EditRenderTestSupport.writeFixture(width: 2048, height: 1365,
                                                         orientation: 1, named: "grain-fixture")
        var grained = EditStack.fresh()
        grained.setGrain { $0.amount = 0.9; $0.size = 0.5; $0.roughness = 0.4 }

        func deviation(at maxPixel: Int) throws -> Double {
            let plain = try XCTUnwrap(
                EditRenderer.render(url: url, stack: .fresh(), maxPixel: maxPixel))
            let withGrain = try XCTUnwrap(
                EditRenderer.render(url: url, stack: grained, maxPixel: maxPixel))
            // Downsample BOTH to a common grid first, so the comparison is
            // about grain strength rather than about resolution.
            let a = try EditRenderTestSupport.downsample(plain, toGrid: 128)
            let b = try EditRenderTestSupport.downsample(withGrain, toGrid: 128)
            return try EditRenderTestSupport.meanChannelError(a, b)
        }

        let small = try deviation(at: 512)
        let large = try deviation(at: 2048)
        XCTAssertGreaterThan(small, 0.001, "grain did not render at 512px")
        XCTAssertGreaterThan(large, 0.001, "grain did not render at 2048px")
        // Within 2.5x across a 4x resolution change. Generous, because
        // downsampling averages a fine grain harder than a coarse one — but a
        // pixel-constant cell would differ by the full 4x factor.
        let ratio = max(small, large) / max(min(small, large), 1e-9)
        XCTAssertLessThan(ratio, 2.5,
                          "grain strength changed with resolution (\(small) vs \(large)) — "
                          + "the cell size is probably a pixel constant, not a long-edge fraction")
    }

    private func renderDownsampled(_ url: URL, decodeLongEdge: Int) throws -> CGImage {
        let stack = allGroupsStack()
        let rendered = try XCTUnwrap(
            EditRenderer.render(url: url, stack: stack, maxPixel: decodeLongEdge),
            "render failed at \(decodeLongEdge)px")
        return try EditRenderTestSupport.downsample(rendered, toGrid: 128)
    }

    private func assertAgreesAcrossResolutions(fixture url: URL,
                                               file: StaticString = #filePath,
                                               line: UInt = #line) throws {
        let small = try renderDownsampled(url, decodeLongEdge: 256)
        let medium = try renderDownsampled(url, decodeLongEdge: 1024)
        let full = try renderDownsampled(url, decodeLongEdge: 2048)
        let smallVsMedium = try EditRenderTestSupport.meanChannelError(small, medium)
        let mediumVsFull = try EditRenderTestSupport.meanChannelError(medium, full)
        XCTAssertLessThan(smallVsMedium, tolerance,
                          "256px vs 1024px disagree — a scale-dependent radius is in pixels",
                          file: file, line: line)
        XCTAssertLessThan(mediumVsFull, tolerance,
                          "1024px vs full disagree — a scale-dependent radius is in pixels",
                          file: file, line: line)
    }

    func testLandscapeFixtureAgreesAcrossResolutions() throws {
        let url = try EditRenderTestSupport.writeFixture(width: 2048, height: 1365,
                                                         orientation: 1, named: "landscape")
        try assertAgreesAcrossResolutions(fixture: url)
    }

    /// Orientation 6 stores a landscape buffer that displays portrait — the
    /// case where a decode that forgets to honour EXIF renders a transposed
    /// crop and a vignette centred on the wrong axis.
    func testPortraitExifRotatedFixtureAgreesAcrossResolutions() throws {
        let url = try EditRenderTestSupport.writeFixture(width: 2048, height: 1365,
                                                         orientation: 6, named: "portrait-exif6")
        try assertAgreesAcrossResolutions(fixture: url)
    }

    func testExifOrientationIsHonouredOnDecode() throws {
        let url = try EditRenderTestSupport.writeFixture(width: 2048, height: 1365,
                                                         orientation: 6, named: "portrait-orient")
        let rendered = try XCTUnwrap(
            EditRenderer.render(url: url, stack: .fresh(), maxPixel: 512))
        XCTAssertLessThan(rendered.width, rendered.height,
                          "orientation 6 must display portrait")
    }

    /// A crop must scale with the decode, not with a stored pixel rect.
    func testCroppedStackKeepsItsAspectAtEveryResolution() throws {
        let url = try EditRenderTestSupport.writeFixture(width: 2048, height: 1024,
                                                         orientation: 1, named: "crop-fixture")
        var stack = EditStack.fresh()
        stack.setGeometry { $0.crop = CropRect(x: 0.1, y: 0.1, w: 0.5, h: 0.5) }
        var aspects: [Double] = []
        for maxPixel in [256, 1024, 2048] {
            let img = try XCTUnwrap(EditRenderer.render(url: url, stack: stack, maxPixel: maxPixel))
            aspects.append(Double(img.width) / Double(img.height))
        }
        for a in aspects {
            XCTAssertEqual(a, aspects[0], accuracy: 0.02)
        }
    }

    func testUnrenderableStackReturnsNilRatherThanPartialPixels() throws {
        let url = try EditRenderTestSupport.writeFixture(width: 512, height: 512,
                                                         orientation: 1, named: "future-fixture")
        var stack = allGroupsStack()
        stack.processVersion = EditStack.currentProcessVersion + 1
        XCTAssertNil(EditRenderer.render(url: url, stack: stack, maxPixel: 256))
    }
}
