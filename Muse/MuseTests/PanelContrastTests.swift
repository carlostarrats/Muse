import XCTest
@testable import Muse

/// The editor panels must clear WCAG AA on every backdrop the user can pick.
/// The mid greys are the whole reason this type exists — a fixed
/// "light backdrop → dark ink" threshold shipped 3.6:1 white-on-grey.
final class PanelContrastTests: XCTestCase {

    /// Every shipped backdrop level.
    private let backdrops: [Double] = EditorBackdropLevel.allCases.map(\.brightness)

    func testKnownLuminanceAnchors() {
        XCTAssertEqual(PanelContrast.luminance(0), 0, accuracy: 0.0001)
        XCTAssertEqual(PanelContrast.luminance(1), 1, accuracy: 0.0001)
        // The classic reference pair: white on black is 21:1.
        XCTAssertEqual(PanelContrast.ratio(1, 0), 21, accuracy: 0.01)
        XCTAssertEqual(PanelContrast.ratio(0.5, 0.5), 1, accuracy: 0.0001)
    }

    func testBodyTextClearsAAOnEveryBackdrop() {
        for backdrop in backdrops {
            let ink = PanelContrast.resolve(backdrop: backdrop)
            let card = ink.cardGrey(on: backdrop)
            XCTAssertGreaterThanOrEqual(
                PanelContrast.ratio(ink.inkGrey, card), PanelContrast.bodyTarget - 0.001,
                "primary text fails AA on backdrop \(backdrop)")
        }
    }

    func testSecondaryTextClearsAAOnEveryBackdrop() {
        for backdrop in backdrops {
            let ink = PanelContrast.resolve(backdrop: backdrop)
            let card = ink.cardGrey(on: backdrop)
            let secondary = PanelContrast.composite(ink: ink.inkGrey, over: card,
                                                    opacity: ink.secondaryOpacity)
            XCTAssertGreaterThanOrEqual(
                PanelContrast.ratio(secondary, card), PanelContrast.bodyTarget - 0.001,
                "secondary text fails AA on backdrop \(backdrop)")
        }
    }

    /// 10pt small-caps is not "large text" — the 3:1 allowance doesn't apply,
    /// and at 3:1 these headings were a pale grey nobody could read on a light
    /// card.
    func testCardLabelsClearFullAAOnEveryBackdrop() {
        for backdrop in backdrops {
            let ink = PanelContrast.resolve(backdrop: backdrop)
            let card = ink.cardGrey(on: backdrop)
            let label = PanelContrast.composite(ink: ink.inkGrey, over: card,
                                                opacity: ink.labelOpacity)
            XCTAssertGreaterThanOrEqual(
                PanelContrast.ratio(label, card), PanelContrast.labelTarget - 0.001,
                "card label fails AA on backdrop \(backdrop)")
        }
    }

    /// Dark and near-white backdrops keep the Preview column's exact card: a
    /// 0.09 veil tinted TOWARD the ink. Only the dead zone deviates.
    func testDarkAndLightBackdropsKeepThePreviewCard() {
        for backdrop in [0.0, 0.18, 0.85, 1.0] {
            let ink = PanelContrast.resolve(backdrop: backdrop)
            XCTAssertFalse(ink.veilOpposesInk, "backdrop \(backdrop) should not need the rescue")
            XCTAssertEqual(ink.cardAlpha, 0.09, accuracy: 0.0001)
            XCTAssertEqual(ink.secondaryOpacity, 0.62, accuracy: 0.0001)
            // The label starts at the Preview column's 0.42 and is raised only
            // as far as its own target needs.
            XCTAssertGreaterThanOrEqual(ink.labelOpacity, 0.42)
        }
    }

    /// Mid grey is the case a fixed threshold got wrong: a white card there is
    /// only 3.6:1 under white text, so the veil has to flip.
    func testMidGreyFlipsTheVeilRatherThanShippingUnreadableText() {
        let mid = EditorBackdropLevel.mid.brightness
        let naive = PanelContrast.composite(ink: 1, over: mid, opacity: 0.09)
        XCTAssertLessThan(PanelContrast.ratio(1, naive), PanelContrast.bodyTarget)

        let ink = PanelContrast.resolve(backdrop: mid)
        XCTAssertFalse(ink.isDark)              // still white ink
        XCTAssertTrue(ink.veilOpposesInk)       // but a dark card under it
        XCTAssertGreaterThanOrEqual(
            PanelContrast.ratio(ink.inkGrey, ink.cardGrey(on: mid)),
            PanelContrast.bodyTarget - 0.001)
    }

    /// A SELECTED row is a SOLID fill with its own ink — one colour on every
    /// backdrop, so nothing in the editor disagrees about what selected looks
    /// like. macOS's own selected rows (white on systemBlue) are 4.0:1; this
    /// uses the darkened blue precisely so it clears AA.
    func testSelectionFillCarriesItsInkAtAA() {
        for backdrop in backdrops {
            let ink = PanelContrast.resolve(backdrop: backdrop)
            XCTAssertGreaterThanOrEqual(
                PanelContrast.ratio(ink.selectionInkGrey, ink.selectionSolidGrey),
                PanelContrast.bodyTarget,
                "selected row text fails AA on backdrop \(backdrop)")
        }
        // The colour it deliberately isn't: macOS's own white-on-systemBlue.
        XCTAssertLessThan(PanelContrast.ratio(1, PanelContrast.accentGrey),
                          PanelContrast.bodyTarget,
                          "white on plain systemBlue passes AA now? then simplify this")
    }

    /// And it has to be visibly a selection against every card it can sit on.
    func testSelectionFillStandsOutOnEveryCard() {
        for backdrop in backdrops {
            let ink = PanelContrast.resolve(backdrop: backdrop)
            XCTAssertGreaterThanOrEqual(
                PanelContrast.ratio(ink.selectionSolidGrey, ink.cardGrey), 1.5,
                "the selected row doesn't stand out on backdrop \(backdrop)")
        }
    }

    /// The delete button is a filled red control with a glyph on it, so it has
    /// the same two obligations as the selection: legible, and visible.
    func testDangerFillCarriesItsInkAndStandsOutOnEveryCard() {
        for backdrop in backdrops {
            let ink = PanelContrast.resolve(backdrop: backdrop)
            XCTAssertGreaterThanOrEqual(
                PanelContrast.ratio(ink.dangerInkGrey, ink.dangerSolidGrey),
                PanelContrast.bodyTarget,
                "the delete glyph fails AA on backdrop \(backdrop)")
            XCTAssertGreaterThanOrEqual(
                PanelContrast.ratio(ink.dangerSolidGrey, ink.cardGrey), 1.5,
                "the delete button doesn't stand out on backdrop \(backdrop)")
        }
    }

    /// Sweep the whole range, not just the five presets — the resolver must not
    /// have a hole between them.
    func testEveryBrightnessInTheRangeClearsAA() {
        for step in 0...100 {
            let backdrop = Double(step) / 100
            let ink = PanelContrast.resolve(backdrop: backdrop)
            let card = ink.cardGrey(on: backdrop)
            XCTAssertGreaterThanOrEqual(
                PanelContrast.ratio(ink.inkGrey, card), PanelContrast.bodyTarget - 0.001,
                "primary text fails AA at backdrop \(backdrop)")
        }
    }
}
