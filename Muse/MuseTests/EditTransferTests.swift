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
