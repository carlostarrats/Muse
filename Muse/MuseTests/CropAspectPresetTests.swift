//
//  CropAspectPresetTests.swift
//  MuseTests
//

import XCTest
@testable import Muse

final class CropAspectPresetTests: XCTestCase {

    func testOriginalAndFreeformCarryNoRatio() {
        XCTAssertNil(CropAspectPreset.original.ratio)
        XCTAssertNil(CropAspectPreset.freeform.ratio)
    }

    func testRatiosAreCorrect() {
        XCTAssertEqual(CropAspectPreset.square.ratio!, 1.0, accuracy: 1e-9)
        XCTAssertEqual(CropAspectPreset.igPost.ratio!, 4.0 / 5.0, accuracy: 1e-9)
        XCTAssertEqual(CropAspectPreset.story.ratio!, 9.0 / 16.0, accuracy: 1e-9)
        XCTAssertEqual(CropAspectPreset.print4x6.ratio!, 3.0 / 2.0, accuracy: 1e-9)
        XCTAssertEqual(CropAspectPreset.print8x10.ratio!, 5.0 / 4.0, accuracy: 1e-9)
        XCTAssertEqual(CropAspectPreset.cameraDefault.ratio!, 4.0 / 3.0, accuracy: 1e-9)
        XCTAssertEqual(CropAspectPreset.widescreen.ratio!, 16.0 / 9.0, accuracy: 1e-9)
    }

    /// The LABEL follows the orientation toggle. Showing "4:3" after pressing
    /// Portrait made the button look like it had done nothing.
    func testRatioLabelSwapsWithOrientation() {
        XCTAssertEqual(CropAspectPreset.cameraDefault.ratioLabel(), "4:3")
        XCTAssertEqual(CropAspectPreset.cameraDefault.ratioLabel(portrait: true), "3:4")
        XCTAssertEqual(CropAspectPreset.widescreen.ratioLabel(), "16:9")
        XCTAssertEqual(CropAspectPreset.widescreen.ratioLabel(portrait: true), "9:16")
        XCTAssertEqual(CropAspectPreset.story.ratioLabel(), "9:16")
        XCTAssertEqual(CropAspectPreset.story.ratioLabel(portrait: true), "16:9")
        XCTAssertEqual(CropAspectPreset.square.ratioLabel(portrait: true), "1:1")
    }

    /// And the label always agrees with the ratio actually applied.
    func testLabelAgreesWithTheAppliedRatio() {
        for p in CropAspectPreset.shapes {
            for portrait in [false, true] {
                let parts = p.ratioLabel(portrait: portrait).split(separator: ":")
                let fromLabel = Double(parts[0])! / Double(parts[1])!
                XCTAssertEqual(p.ratio(portrait: portrait)!, fromLabel, accuracy: 1e-9,
                               "\(p.id) portrait=\(portrait)")
            }
        }
    }

    /// The portrait toggle swaps w:h, so each shape is ONE row not two.
    func testPortraitInvertsTheRatio() {
        XCTAssertEqual(CropAspectPreset.widescreen.ratio(portrait: true)!,
                       9.0 / 16.0, accuracy: 1e-9)
        XCTAssertEqual(CropAspectPreset.story.ratio(portrait: true)!,
                       16.0 / 9.0, accuracy: 1e-9)
        XCTAssertNil(CropAspectPreset.original.ratio(portrait: true))
    }

    /// Orientation is meaningless for these three, so the button disables.
    func testOrientationIsDisabledWhereItHasNoMeaning() {
        XCTAssertFalse(CropAspectPreset.original.supportsOrientation)
        XCTAssertFalse(CropAspectPreset.freeform.supportsOrientation)
        XCTAssertFalse(CropAspectPreset.square.supportsOrientation)
        XCTAssertTrue(CropAspectPreset.print4x6.supportsOrientation)
        XCTAssertTrue(CropAspectPreset.widescreen.supportsOrientation)
    }

    /// Every shape row shows BOTH a purpose and a ratio — that is the whole
    /// point of the labelling, and a row missing either half fails the brief.
    func testEveryShapeRowNamesBothPurposeAndRatio() {
        for p in CropAspectPreset.shapes {
            XCTAssertFalse(p.label.isEmpty, "\(p.id) has no purpose name")
            XCTAssertFalse(p.ratioLabel().isEmpty, "\(p.id) has no ratio")
            XCTAssertTrue(p.menuTitle().contains(p.label))
            XCTAssertTrue(p.menuTitle().contains(p.ratioLabel()))
        }
    }

    /// The two modes are shapeless by design and show no ratio.
    func testModeRowsShowNoRatio() {
        for p in CropAspectPreset.modes {
            XCTAssertTrue(p.ratioLabel().isEmpty)
            XCTAssertTrue(p.ratioLabel(portrait: true).isEmpty)
            XCTAssertEqual(p.menuTitle(), p.label)
        }
    }

    /// The social rows share their NAME with the export card so the vocabulary
    /// cannot drift. The geometry is deliberately NOT shared.
    func testSocialRowsReuseTheExportPresetNames() {
        let storyKey = SocialPreset.preset(id: "ig-story")!.nameKey
        XCTAssertEqual(CropAspectPreset.story.label,
                       String(localized: String.LocalizationValue(storyKey)))
        let igKey = SocialPreset.preset(id: "instagram")!.nameKey
        XCTAssertEqual(CropAspectPreset.igPost.label,
                       String(localized: String.LocalizationValue(igKey)))
    }

    func testMenuOrderMatchesTheSpec() {
        XCTAssertEqual(CropAspectPreset.all.map(\.id),
                       ["original", "freeform", "square", "ig-post", "ig-story",
                        "print-4x6", "print-8x10", "camera-default", "widescreen"])
    }

    /// Each preset fits into a real photo shape without leaving the frame.
    func testEveryPresetFitsInsideACommonPhotoShape() {
        for p in CropAspectPreset.shapes {
            for portrait in [false, true] {
                guard let ratio = p.ratio(portrait: portrait) else { continue }
                let r = CropDragMath.fit(aspect: ratio, into: 1.5)
                XCTAssertGreaterThan(r.w, 0, "\(p.id)")
                XCTAssertLessThanOrEqual(r.x + r.w, 1 + 1e-9, "\(p.id)")
                XCTAssertLessThanOrEqual(r.y + r.h, 1 + 1e-9, "\(p.id)")
            }
        }
    }
}
