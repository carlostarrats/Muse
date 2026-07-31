import XCTest
@testable import Muse

final class EditStackNormalizeTests: XCTestCase {
    func testFreshStackIsNeutral() {
        let stack = EditStack.fresh()
        XCTAssertTrue(stack.isNeutral)
        XCTAssertEqual(stack.schemaVersion, EditStack.currentSchemaVersion)
        XCTAssertEqual(stack.processVersion, EditStack.currentProcessVersion)
        XCTAssertEqual(stack.masks, [])
    }

    func testDuplicateAdjustmentCaseKeepsLastOnNormalize() {
        var stack = EditStack.fresh()
        var a = ToneParams.neutral; a.exposureEV = 1
        var b = ToneParams.neutral; b.exposureEV = 2
        stack.adjustments = [.tone(a), .tone(b)]
        let normalized = stack.normalized()
        let toneCases = normalized.adjustments.filter {
            if case .tone = $0 { return true }; return false
        }
        XCTAssertEqual(toneCases.count, 1)
        if case .tone(let p) = toneCases[0] { XCTAssertEqual(p.exposureEV, 2) }
        else { XCTFail("expected .tone") }
    }

    func testNormalizeEnforcesCanonicalDeclarationOrder() {
        var stack = EditStack.fresh()
        stack.adjustments = [.vignette(.neutral), .tone(.neutral), .curve(.neutral)]
        let order = stack.normalized().adjustments.map(\.canonicalIndex)
        XCTAssertEqual(order, order.sorted())
    }

    func testStackIsNeutralOnlyWhenEveryGroupAndRawParamsAreNeutral() {
        var stack = EditStack.fresh()
        stack.rawParams = RawParams(lensCorrection: false)
        XCTAssertFalse(stack.isNeutral)
    }

    func testPresentButNeutralAdjustmentStillCountsAsNeutralStack() {
        var stack = EditStack.fresh()
        stack.adjustments = [.tone(.neutral), .color(.neutral)]
        XCTAssertTrue(stack.isNeutral)
    }

    func testToneParamsClampedBoundsExposure() {
        var p = ToneParams.neutral
        p.exposureEV = 99
        XCTAssertLessThanOrEqual(p.clamped().exposureEV, 5)
        p.exposureEV = -99
        XCTAssertGreaterThanOrEqual(p.clamped().exposureEV, -5)
    }

    func testSetterFindsOrInsertsAndKeepsCanonicalOrder() {
        var stack = EditStack.fresh()
        stack.setVignette { $0.amount = -0.5 }
        stack.setTone { $0.exposureEV = 1 }
        XCTAssertEqual(stack.adjustments.map(\.canonicalIndex), [0, 5])
        stack.setTone { $0.contrast = 0.2 }
        XCTAssertEqual(stack.adjustments.count, 2)
        XCTAssertEqual(stack.toneParams?.exposureEV, 1)
        XCTAssertEqual(stack.toneParams?.contrast, 0.2)
    }
}
