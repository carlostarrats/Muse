import XCTest
@testable import Muse

/// `isApplied` is what lets the Styles browser show which preset is on the
/// photo — and therefore what lets "Original" mean anything.
final class EditTransferAppliedTests: XCTestCase {

    private func stack(exposure: Double? = nil, saturation: Double? = nil) -> EditStack {
        var s = EditStack.fresh()
        if let exposure { s.setTone { $0.exposureEV = exposure } }
        if let saturation { s.setColor { $0.saturation = saturation } }
        return s.normalized()
    }

    func testAppliedPresetIsRecognised() {
        let preset = stack(exposure: 0.5)
        let photo = EditTransfer.apply(groups: EditTransfer.adjustedGroups(of: preset),
                                       from: preset, onto: .fresh())
        XCTAssertTrue(EditTransfer.isApplied(preset, onto: photo))
    }

    func testDifferentValuesAreNotApplied() {
        XCTAssertFalse(EditTransfer.isApplied(stack(exposure: 0.5), onto: stack(exposure: 0.4)))
    }

    func testNeutralStackIsNeverApplied() {
        // "Original" is its own entry; a preset that changes nothing must not
        // claim to be the current look.
        XCTAssertFalse(EditTransfer.isApplied(.fresh(), onto: .fresh()))
    }

    /// The photo may carry adjustments the preset says nothing about — those
    /// don't stop the preset from being the one that's on.
    func testUntouchedGroupsOnThePhotoDoNotBreakTheMatch() {
        let preset = stack(exposure: 0.5)
        var photo = EditTransfer.apply(groups: EditTransfer.adjustedGroups(of: preset),
                                       from: preset, onto: .fresh())
        photo.setColor { $0.saturation = 0.2 }
        XCTAssertTrue(EditTransfer.isApplied(preset, onto: photo.normalized()))
    }

    func testChangingAGroupThePresetOwnsBreaksTheMatch() {
        let preset = stack(exposure: 0.5)
        var photo = EditTransfer.apply(groups: EditTransfer.adjustedGroups(of: preset),
                                       from: preset, onto: .fresh())
        photo.setTone { $0.contrast = 0.3 }
        XCTAssertFalse(EditTransfer.isApplied(preset, onto: photo.normalized()))
    }
}
