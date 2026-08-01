import XCTest
import CoreImage
@testable import Muse

final class EditRenderNeutralityTests: XCTestCase {
    private func gray(_ value: Double, size: CGFloat = 16) -> LinearImage {
        let ci = CIImage(color: CIColor(red: value, green: value, blue: value))
            .cropped(to: CGRect(x: 0, y: 0, width: size, height: size))
        return LinearImage.alreadyDecodedFromFile(ci)
    }

    /// A fully neutral stack must be a pixel identity, not "close enough" —
    /// otherwise merely OPENING the editor and closing it again shifts every
    /// photo slightly, and the shift compounds across saves.
    func testAllNeutralStackIsPixelIdentity() throws {
        let source = gray(0.5)
        let result = EditRenderer.apply(.fresh(), to: source, sourceLongEdge: 16)
        let before = try XCTUnwrap(EditRenderTestSupport.render(source.ciImage))
        let after = try XCTUnwrap(EditRenderTestSupport.render(result.ciImage))
        XCTAssertEqual(try EditRenderTestSupport.meanChannelError(before, after), 0,
                       accuracy: 0.0001)
    }

    /// Present-but-neutral cases must also be identity — the editor creates a
    /// case the moment a slider is touched, so this is the state a photo is
    /// left in after a slider is moved and returned to zero.
    func testPresentButNeutralAdjustmentsAreAlsoIdentity() throws {
        var stack = EditStack.fresh()
        stack.adjustments = [.tone(.neutral), .color(.neutral), .presence(.neutral),
                             .curve(.neutral), .geometry(.neutral), .vignette(.neutral)]
        let source = gray(0.5)
        let result = EditRenderer.apply(stack, to: source, sourceLongEdge: 16)
        let before = try XCTUnwrap(EditRenderTestSupport.render(source.ciImage))
        let after = try XCTUnwrap(EditRenderTestSupport.render(result.ciImage))
        XCTAssertEqual(try EditRenderTestSupport.meanChannelError(before, after), 0,
                       accuracy: 0.0001)
    }

    /// The unrenderable-blob rule: a stack from a newer renderer renders as
    /// the ORIGINAL, never as a partial application of the half we understand.
    func testStackBeyondProcessVersionRendersTheOriginal() throws {
        var stack = EditStack.fresh()
        stack.processVersion = EditStack.currentProcessVersion + 1
        var tone = ToneParams.neutral; tone.exposureEV = 3
        stack.adjustments = [.tone(tone)]
        XCTAssertFalse(EditRenderer.canRender(stack))

        let source = gray(0.4)
        let result = EditRenderer.apply(stack, to: source, sourceLongEdge: 16)
        let before = try XCTUnwrap(EditRenderTestSupport.render(source.ciImage))
        let after = try XCTUnwrap(EditRenderTestSupport.render(result.ciImage))
        XCTAssertEqual(try EditRenderTestSupport.meanChannelError(before, after), 0,
                       accuracy: 0.0001)
    }

    func testPositiveExposureBrightens() throws {
        var stack = EditStack.fresh()
        stack.setTone { $0.exposureEV = 1 }
        let source = gray(0.2)
        let result = EditRenderer.apply(stack, to: source, sourceLongEdge: 16)
        let before = try XCTUnwrap(EditRenderTestSupport.render(source.ciImage))
        let after = try XCTUnwrap(EditRenderTestSupport.render(result.ciImage))
        XCTAssertGreaterThan(try EditRenderTestSupport.meanLuminance(after),
                             try EditRenderTestSupport.meanLuminance(before))
    }

    func testGeometryCropChangesExtent() {
        var stack = EditStack.fresh()
        stack.setGeometry { $0.crop = CropRect(x: 0.25, y: 0.25, w: 0.5, h: 0.5) }
        let source = gray(0.5, size: 100)
        let result = EditRenderer.apply(stack, to: source, sourceLongEdge: 100)
        XCTAssertEqual(result.ciImage.extent.width, 50, accuracy: 1)
        XCTAssertEqual(result.ciImage.extent.height, 50, accuracy: 1)
    }

    func testQuarterTurnSwapsExtent() {
        var stack = EditStack.fresh()
        stack.setGeometry { $0.quarterTurns = 1 }
        let ci = CIImage(color: .gray).cropped(to: CGRect(x: 0, y: 0, width: 40, height: 20))
        let result = EditRenderer.apply(stack, to: LinearImage.alreadyDecodedFromFile(ci),
                                        sourceLongEdge: 40)
        XCTAssertEqual(result.ciImage.extent.width, 20, accuracy: 1)
        XCTAssertEqual(result.ciImage.extent.height, 40, accuracy: 1)
    }
}

// MARK: - Spec 05

extension EditRenderNeutralityTests {

    private func grayImage(_ value: Double, size: CGFloat = 16) -> LinearImage {
        let ci = CIImage(color: CIColor(red: value, green: value, blue: value))
            .cropped(to: CGRect(x: 0, y: 0, width: size, height: size))
        return LinearImage.alreadyDecodedFromFile(ci)
    }

    /// Zero gains must be an EXACT identity — the tone-zone stage runs on every
    /// photo that has ever had the strip touched, so "close enough" would drift
    /// a picture every save.
    func testZeroGainToneZoneIsPixelIdentity() throws {
        var stack = EditStack.fresh()
        stack.adjustments = [.toneZone(.neutral)]
        let source = grayImage(0.5)
        let result = EditRenderer.apply(stack, to: source, sourceLongEdge: 16)
        let before = try XCTUnwrap(EditRenderTestSupport.render(source.ciImage))
        let after = try XCTUnwrap(EditRenderTestSupport.render(result.ciImage))
        XCTAssertEqual(try EditRenderTestSupport.meanChannelError(before, after), 0,
                       accuracy: 0.0001)
    }

    /// Strength 0 never even looks the LUT up, so an unresolvable reference at
    /// zero strength can't make a stack unrenderable.
    func testStrengthZeroLutIsPixelIdentityAndStillRenderable() throws {
        var stack = EditStack.fresh()
        stack.setLut(LutParams(lutHash: "not-a-real-lut", name: "x", strength: 0))
        XCTAssertTrue(EditRenderer.canRender(stack))
        let source = grayImage(0.5)
        let result = EditRenderer.apply(stack, to: source, sourceLongEdge: 16)
        let before = try XCTUnwrap(EditRenderTestSupport.render(source.ciImage))
        let after = try XCTUnwrap(EditRenderTestSupport.render(result.ciImage))
        XCTAssertEqual(try EditRenderTestSupport.meanChannelError(before, after), 0,
                       accuracy: 0.0001)
    }

    /// An unresolvable LUT renders the ORIGINAL everywhere, never a partial
    /// stack: the look IS the LUT, and applying everything except it would be
    /// a different photo presented as the user's edit.
    func testUnresolvableLutMakesTheStackUnrenderable() {
        var stack = EditStack.fresh()
        stack.setTone { $0.exposureEV = 1 }
        stack.setLut(LutParams(lutHash: "definitely-not-imported", name: "Missing", strength: 1))
        XCTAssertFalse(EditRenderer.canRender(stack))

        let source = grayImage(0.5)
        let result = EditRenderer.apply(stack, to: source, sourceLongEdge: 16)
        // `apply` bails on !canRender, so the exposure lift never lands either.
        XCTAssertEqual(result.ciImage.extent, source.ciImage.extent)
    }

    /// A non-neutral zone gain must actually DO something — every identity
    /// test above would pass on a stage that silently skipped itself.
    ///
    /// EQUAL gains across all nine zones is the case that doesn't depend on
    /// knowing which zone a fixture's pixels land in: the weights are a
    /// partition of unity, so this is exactly a +1 EV exposure shift.
    func testEqualZoneGainsBrightenLikeAPlainExposureShift() throws {
        var stack = EditStack.fresh()
        stack.adjustments = [.toneZone(ToneZoneParams(gains: Array(repeating: 0.5, count: 9)))]
        let source = grayImage(0.35)
        let result = EditRenderer.apply(stack, to: source, sourceLongEdge: 16)

        var exposureOnly = EditStack.fresh()
        exposureOnly.setTone { $0.exposureEV = 0.5 * ToneZoneMath.maxZoneEV }
        let expected = EditRenderer.apply(exposureOnly, to: source, sourceLongEdge: 16)

        let before = try XCTUnwrap(EditRenderTestSupport.render(source.ciImage))
        let zoned = try XCTUnwrap(EditRenderTestSupport.render(result.ciImage))
        let exposed = try XCTUnwrap(EditRenderTestSupport.render(expected.ciImage))
        XCTAssertGreaterThan(try EditRenderTestSupport.meanChannelError(before, zoned), 0.05)
        XCTAssertEqual(try EditRenderTestSupport.meanChannelError(zoned, exposed), 0,
                       accuracy: 0.02)
    }
}
