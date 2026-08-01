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
        stack.adjustments = [.tone(tone), .color(color), .presence(presence),
                             .curve(curve), .vignette(vignette), .toneZone(toneZone), .lut(lut)]
        return stack
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
