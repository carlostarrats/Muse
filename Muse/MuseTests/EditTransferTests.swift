import XCTest
@testable import Muse

final class EditTransferTests: XCTestCase {
    func nonNeutralTone() -> EditStack {
        var s = EditStack.fresh()
        var t = ToneParams.neutral; t.exposureEV = 1
        s.adjustments = [.tone(t)]
        return s
    }

    func testAdjustedGroupsReturnsOnlyNonNeutralGroups() {
        XCTAssertEqual(EditTransfer.adjustedGroups(of: nonNeutralTone()), [.tone])
    }

    func testAdjustedGroupsIgnoresPresentButNeutralCases() {
        var s = nonNeutralTone()
        s.adjustments.append(.color(.neutral))
        XCTAssertEqual(EditTransfer.adjustedGroups(of: s), [.tone])
    }

    func testAdjustedGroupsIncludesRawWhenNonNeutral() {
        var s = EditStack.fresh()
        s.rawParams = RawParams(lensCorrection: false)
        XCTAssertEqual(EditTransfer.adjustedGroups(of: s), [.raw])
    }

    func testApplyIsCopyByValueAndNeverMutatesSource() {
        let source = nonNeutralTone()
        let target = EditStack.fresh()
        let result = EditTransfer.apply(groups: [.tone], from: source, onto: target)
        XCTAssertEqual(result.toneParams?.exposureEV, 1)
        XCTAssertEqual(EditTransfer.adjustedGroups(of: source), [.tone])
    }

    func testGroupAbsentInSourceClearsItInTarget() {
        var targetWithVignette = EditStack.fresh()
        var v = VignetteParams.neutral; v.amount = 0.5
        targetWithVignette.adjustments = [.vignette(v)]
        let neutralSource = EditStack.fresh()
        let result = EditTransfer.apply(groups: [.vignette], from: neutralSource,
                                        onto: targetWithVignette)
        XCTAssertTrue(EditTransfer.adjustedGroups(of: result).isEmpty)
    }

    func testUntouchedGroupsKeepTargetValues() {
        var target = EditStack.fresh()
        var c = ColorParams.neutral; c.saturation = 0.3
        target.adjustments = [.color(c)]
        let result = EditTransfer.apply(groups: [.tone], from: nonNeutralTone(), onto: target)
        XCTAssertTrue(EditTransfer.adjustedGroups(of: result).contains(.color))
        XCTAssertTrue(EditTransfer.adjustedGroups(of: result).contains(.tone))
    }

    func testRawGroupTransfers() {
        var source = EditStack.fresh()
        source.rawParams = RawParams(lensCorrection: false)
        let result = EditTransfer.apply(groups: [.raw], from: source, onto: .fresh())
        XCTAssertEqual(result.rawParams?.lensCorrection, false)
    }

    func testPresetApplyThenTweakNeverMutatesPresetStack() {
        let preset = nonNeutralTone()
        var photo = EditTransfer.apply(groups: [.tone], from: preset, onto: EditStack.fresh())
        photo.setTone { $0.exposureEV = 3 }
        XCTAssertEqual(preset.toneParams?.exposureEV, 1)
        XCTAssertEqual(photo.toneParams?.exposureEV, 3)
    }

    func testApplyResultIsNormalized() {
        let result = EditTransfer.apply(groups: [.tone, .vignette],
                                        from: nonNeutralTone(), onto: .fresh())
        let order = result.adjustments.map(\.canonicalIndex)
        XCTAssertEqual(order, order.sorted())
    }
}

// MARK: - Spec 05: toneZone + lut ride the same generic paths

extension EditTransferTests {

    private func nonNeutralToneZone() -> EditStack {
        var s = EditStack.fresh()
        var tz = ToneZoneParams.neutral; tz.gains[4] = 0.5
        s.adjustments = [.toneZone(tz)]
        return s
    }

    private func nonNeutralLut() -> EditStack {
        var s = EditStack.fresh()
        s.adjustments = [.lut(LutParams(lutHash: "abc123", name: "Kodak", strength: 0.7))]
        return s
    }

    func testAdjustedGroupsIncludesToneZone() {
        XCTAssertEqual(EditTransfer.adjustedGroups(of: nonNeutralToneZone()), [.toneZone])
    }

    func testAdjustedGroupsIncludesLut() {
        XCTAssertEqual(EditTransfer.adjustedGroups(of: nonNeutralLut()), [.lut])
    }

    func testApplyCopiesToneZoneGainsWholesale() {
        let result = EditTransfer.apply(groups: [.toneZone], from: nonNeutralToneZone(),
                                        onto: .fresh())
        XCTAssertEqual(result.toneZoneParams?.gains[4], 0.5)
    }

    func testApplyCopiesLutReferenceAndStrength() {
        let result = EditTransfer.apply(groups: [.lut], from: nonNeutralLut(), onto: .fresh())
        XCTAssertEqual(result.lutParams?.lutHash, "abc123")
        XCTAssertEqual(result.lutParams?.strength, 0.7)
    }

    /// Absent-in-source CLEARS in target, for the new groups exactly as for
    /// the old ones — otherwise pasting a neutral look appears to do nothing.
    func testApplyClearsALutTheSourceDoesNotHave() {
        var target = EditStack.fresh()
        target.setLut(LutParams(lutHash: "old", name: "Old", strength: 1))
        let result = EditTransfer.apply(groups: [.lut], from: .fresh(), onto: target)
        XCTAssertNil(result.lutParams)
    }

    /// Geometry remains the ONLY preset exclusion — a look is very often a LUT
    /// plus tweaks, so excluding it would gut the feature.
    func testPresetsMayCarryLutAndToneZone() throws {
        var stack = EditStack.fresh()
        stack.setLut(LutParams(lutHash: "abc", name: "Look", strength: 0.8))
        stack.setToneZone { $0 = ToneZoneParams(gains: [0.4] + Array(repeating: 0, count: 8)) }
        stack.setGeometry { $0.crop = CropRect(x: 0, y: 0, w: 0.5, h: 0.5) }
        let decoded = try XCTUnwrap(EditStackCodec.decode(EditPresetStore.presetJSON(from: stack)))
        let groups = EditTransfer.adjustedGroups(of: decoded)
        XCTAssertTrue(groups.contains(.lut))
        XCTAssertTrue(groups.contains(.toneZone))
        XCTAssertFalse(groups.contains(.geometry))
    }
}
