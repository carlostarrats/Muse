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
