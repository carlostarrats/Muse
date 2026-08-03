//
//  AutoToneApplyTests.swift
//  MuseTests
//
//  The scoping guarantee: Auto in Light writes tone, Auto in Color writes
//  white balance, and neither touches the other. This mirrors per-card Reset,
//  which "undoes that group and nothing else".
//

import XCTest
@testable import Muse

final class AutoToneApplyTests: XCTestCase {

    private var sample: AutoToneStats.Result {
        AutoToneStats.Result(exposureEV: 1.2, contrast: 0.3, blacks: -0.2,
                             whites: 0.25, temperature: -0.4, tint: 0.1)
    }

    /// Auto in LIGHT writes tone and leaves the user's COLOR work alone.
    func testLightAutoDoesNotTouchColor() {
        var stack = EditStack.fresh()
        stack.setColor { $0.temperature = 0.75 }        // the user's own choice
        AutoToneApply.light(sample, onto: &stack)

        XCTAssertEqual(stack.toneParams?.exposureEV, 1.2)
        XCTAssertEqual(stack.toneParams?.contrast, 0.3)
        XCTAssertEqual(stack.toneParams?.blacks, -0.2)
        XCTAssertEqual(stack.toneParams?.whites, 0.25)
        XCTAssertEqual(stack.colorParams?.temperature, 0.75,
                       "Auto in Light must not touch Color")
    }

    /// And the mirror image.
    func testColorAutoDoesNotTouchTone() {
        var stack = EditStack.fresh()
        stack.setTone { $0.exposureEV = -2 }
        AutoToneApply.color(sample, onto: &stack)

        XCTAssertEqual(stack.colorParams?.temperature, -0.4)
        XCTAssertEqual(stack.colorParams?.tint, 0.1)
        XCTAssertEqual(stack.toneParams?.exposureEV, -2,
                       "Auto in Color must not touch Light")
    }

    /// Auto in Light must not disturb the OTHER tone-adjacent groups either —
    /// highlights/shadows are the user's, and so are presence and curve.
    func testLightAutoLeavesHighlightsShadowsPresenceAndCurveAlone() {
        var stack = EditStack.fresh()
        stack.setTone { $0.highlights = -0.6; $0.shadows = 0.4 }
        stack.setPresence { $0.clarity = 0.5 }
        stack.setCurve { $0.rgb = [.init(x: 0, y: 0.1), .init(x: 1, y: 0.9)] }
        AutoToneApply.light(sample, onto: &stack)

        XCTAssertEqual(stack.toneParams?.highlights, -0.6)
        XCTAssertEqual(stack.toneParams?.shadows, 0.4)
        XCTAssertEqual(stack.presenceParams?.clarity, 0.5)
        XCTAssertEqual(stack.curveParams?.rgb.count, 2)
    }

    /// Idempotence: the same stats applied twice give the same stack. The
    /// session guarantees the stats themselves always come from the ORIGINAL,
    /// which is what makes pressing the button twice a no-op.
    func testApplyingTwiceIsIdempotent() {
        var a = EditStack.fresh()
        AutoToneApply.light(sample, onto: &a)
        AutoToneApply.color(sample, onto: &a)
        var b = a
        AutoToneApply.light(sample, onto: &b)
        AutoToneApply.color(sample, onto: &b)
        XCTAssertEqual(a.normalized(), b.normalized())
    }

    /// An all-zero result leaves a fresh stack neutral — Auto on a photo that
    /// is already right stores nothing at all, rather than a no-op blob.
    func testNeutralResultLeavesStackNeutral() {
        var stack = EditStack.fresh()
        AutoToneApply.light(.none, onto: &stack)
        AutoToneApply.color(.none, onto: &stack)
        XCTAssertTrue(stack.isNeutral)
    }

    /// Auto overwrites its OWN previous values rather than accumulating them.
    func testSecondApplyOverwritesRatherThanAccumulates() {
        var stack = EditStack.fresh()
        AutoToneApply.light(sample, onto: &stack)
        AutoToneApply.light(AutoToneStats.Result(exposureEV: -1, contrast: 0,
                                                 blacks: 0, whites: 0,
                                                 temperature: 0, tint: 0),
                            onto: &stack)
        XCTAssertEqual(stack.toneParams?.exposureEV, -1)
        XCTAssertEqual(stack.toneParams?.contrast, 0)
    }
}
