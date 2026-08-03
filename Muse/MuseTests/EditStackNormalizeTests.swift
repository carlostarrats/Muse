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

// MARK: - Spec 05: toneZone + lut

extension EditStackNormalizeTests {

    func testToneZoneParamsNeutralIsAllZeroGains() {
        XCTAssertTrue(ToneZoneParams.neutral.isNeutral)
        XCTAssertEqual(ToneZoneParams.neutral.gains.count, ToneZoneParams.zoneCount)
        XCTAssertTrue(ToneZoneParams.neutral.gains.allSatisfy { $0 == 0 })
    }

    /// A hand-edited or future-shaped sidecar must not index out of bounds in
    /// the renderer — hence pad/truncate rather than trust the array.
    func testToneZoneParamsClampedPadsShortArray() {
        let clamped = ToneZoneParams(gains: [0.5, -0.5]).clamped()
        XCTAssertEqual(clamped.gains.count, ToneZoneParams.zoneCount)
        XCTAssertEqual(clamped.gains[0], 0.5)
        XCTAssertEqual(clamped.gains[1], -0.5)
        XCTAssertEqual(clamped.gains[2], 0)
    }

    func testToneZoneParamsClampedTruncatesLongArray() {
        XCTAssertEqual(ToneZoneParams(gains: Array(repeating: 0.3, count: 20)).clamped()
            .gains.count, ToneZoneParams.zoneCount)
    }

    func testToneZoneParamsClampedBoundsEachGain() {
        var p = ToneZoneParams.neutral
        p.gains[0] = 99
        p.gains[1] = -99
        let clamped = p.clamped()
        XCTAssertEqual(clamped.gains[0], 1)
        XCTAssertEqual(clamped.gains[1], -1)
    }

    func testLutParamsNeutralAtZeroStrength() {
        XCTAssertTrue(LutParams(lutHash: "abc", name: "Kodak 2383", strength: 0).isNeutral)
    }

    func testLutParamsNonNeutralAtNonZeroStrength() {
        XCTAssertFalse(LutParams(lutHash: "abc", name: "Kodak 2383", strength: 0.5).isNeutral)
    }

    func testLutParamsClampedBoundsStrength() {
        XCTAssertLessThanOrEqual(LutParams(lutHash: "a", name: "x", strength: 5).clamped().strength, 1)
        XCTAssertGreaterThanOrEqual(LutParams(lutHash: "a", name: "x", strength: -5).clamped().strength, 0)
    }

    /// The canonical order is DECLARATION order and the two new cases APPEND —
    /// inserting either mid-list would re-key every pre-existing edited
    /// thumbnail's `stack_hash` in every library.
    func testToneZoneAndLutSortAfterVignetteInNormalizedOrder() {
        var stack = EditStack.fresh()
        var tz = ToneZoneParams.neutral; tz.gains[0] = 0.4
        stack.adjustments = [.lut(LutParams(lutHash: "deadbeef", name: "Look", strength: 0.8)),
                             .vignette(.neutral), .toneZone(tz), .tone(.neutral)]
        let order = stack.normalized().adjustments.map(\.canonicalIndex)
        XCTAssertEqual(order, order.sorted())
        XCTAssertEqual(order, [0, 5, 6, 7])
    }

    func testStackToneZoneParamsAccessorExtractsCase() {
        var stack = EditStack.fresh()
        var tz = ToneZoneParams.neutral; tz.gains[3] = -0.2
        stack.adjustments = [.toneZone(tz)]
        XCTAssertEqual(stack.toneZoneParams?.gains[3], -0.2)
    }

    func testStackLutParamsAccessorExtractsCase() {
        var stack = EditStack.fresh()
        stack.adjustments = [.lut(LutParams(lutHash: "hash1", name: "Warm Film", strength: 0.6))]
        XCTAssertEqual(stack.lutParams?.lutHash, "hash1")
    }

    func testSetToneZoneCreatesTheCaseOnFirstWrite() {
        var stack = EditStack.fresh()
        XCTAssertNil(stack.toneZoneParams)
        stack.setToneZone { $0 = ToneZoneParams(gains: [0.5] + Array(repeating: 0, count: 8)) }
        XCTAssertEqual(stack.toneZoneParams?.gains[0], 0.5)
    }

    /// A stack carries at most ONE LUT, and "no LUT" is the ABSENCE of the
    /// case — never a zero-strength one left behind for the codec to encode.
    func testSetLutNilRemovesTheCaseEntirely() {
        var stack = EditStack.fresh()
        stack.setLut(LutParams(lutHash: "a", name: "x", strength: 1))
        stack.setLut(nil)
        XCTAssertNil(stack.lutParams)
        XCTAssertTrue(stack.adjustments.allSatisfy { if case .lut = $0 { false } else { true } })
    }

    func testSetLutReplacesRatherThanStacking() {
        var stack = EditStack.fresh()
        stack.setLut(LutParams(lutHash: "a", name: "A", strength: 1))
        stack.setLut(LutParams(lutHash: "b", name: "B", strength: 0.5))
        XCTAssertEqual(stack.adjustments.filter { if case .lut = $0 { true } else { false } }.count, 1)
        XCTAssertEqual(stack.lutParams?.lutHash, "b")
    }

    /// Present-but-neutral must still leave the stack neutral: the editor
    /// creates a case the moment a control is touched, and returning it to
    /// zero has to delete the row rather than store a no-op.
    func testNeutralToneZoneAndLutLeaveTheStackNeutral() {
        var stack = EditStack.fresh()
        stack.adjustments = [.toneZone(.neutral),
                             .lut(LutParams(lutHash: "a", name: "x", strength: 0))]
        XCTAssertTrue(stack.isNeutral)
    }

    /// The contract the EFFECTS card leans on. Vignette shipped with a full
    /// model and renderer and nothing that could write it, so until that card
    /// existed no code path in the app could produce this state at all.
    func testVignetteRoundTripsAtItsCanonicalIndex() {
        var stack = EditStack.fresh()
        stack.setVignette { $0.amount = -0.4; $0.midpoint = 0.3; $0.feather = 0.8 }
        XCTAssertFalse(stack.isNeutral)

        let normalized = stack.normalized()
        XCTAssertEqual(normalized.vignetteParams?.amount, -0.4)
        XCTAssertEqual(normalized.vignetteParams?.midpoint, 0.3)
        XCTAssertEqual(normalized.vignetteParams?.feather, 0.8)

        // Amount back to zero is neutral REGARDLESS of midpoint and feather.
        // This is what stops the card from persisting a no-op blob after the
        // user has nudged the shape sliders and then backed the effect out.
        stack.setVignette { $0.amount = 0 }
        XCTAssertTrue(stack.isNeutral)
    }
}
