import XCTest
@testable import Muse

/// The Symbol & Color modal's two tabs are one control and must occupy one box.
/// These pin that: they fail the moment a catalog entry or a cell size makes the
/// card change size when you switch tabs.
final class CollectionPickerLayoutTests: XCTestCase {

    private typealias L = CollectionPickerLayout

    /// The usable width must account for the presenter's scrollbar channel.
    /// Sizing against card-minus-padding alone is what let both tabs overflow.
    func testContentWidthAccountsForTheScrollBarChannel() {
        XCTAssertEqual(L.contentWidth,
                       L.cardWidth - ModalChrome.scrollBarChannel - L.cardPadding * 2)
        XCTAssertEqual(L.contentWidth, 408)
    }

    func testBothTabsFitTheCardWidth() {
        XCTAssertLessThanOrEqual(L.symbolsTabWidth, L.contentWidth,
                                 "the Symbols tab overflows the card")
        XCTAssertLessThanOrEqual(L.emojiTabWidth, L.contentWidth,
                                 "the Emoji tab overflows the card")
    }

    /// The whole point: switching tabs must not resize the card.
    func testTabsAreTheSameSize() {
        XCTAssertLessThanOrEqual(L.widthDelta, 8,
                                 "tabs differ in width by \(L.widthDelta)pt")
        XCTAssertLessThanOrEqual(L.heightDelta, 8,
                                 "tabs differ in height by \(L.heightDelta)pt")
    }

    /// A ragged last row makes a tab shorter or taller than its partner, which
    /// is how the two drifted apart before.
    func testEveryGridFillsItsRows() {
        XCTAssertTrue(L.colorGrid.isEven, "colour grid ends on a ragged row")
        XCTAssertTrue(L.symbolGrid.isEven, "symbol grid ends on a ragged row")
        XCTAssertTrue(L.emojiGrid.isEven, "emoji grid ends on a ragged row")
    }

    /// The reserved area must be at least as tall as the tallest tab. When it
    /// wasn't, the taller tab's grid spilled over the buttons underneath — which
    /// reads as the card resizing even though its frame never moved.
    func testReservedHeightClipsNeither() {
        XCTAssertGreaterThanOrEqual(L.pickerHeight, L.symbolsTabHeight)
        XCTAssertGreaterThanOrEqual(L.pickerHeight, L.emojiTabHeight)
    }

    /// The layout constants must describe the catalogs the view actually draws —
    /// otherwise these tests pass while the real grids disagree.
    func testLayoutMatchesTheRealCatalogs() {
        XCTAssertEqual(L.emojiGrid.count, CollectionAppearance.emojiCatalog.count)
        XCTAssertEqual(L.symbolGrid.count, CollectionAppearance.symbols.count)
        XCTAssertEqual(L.colorGrid.count, CollectionAppearance.colorTokens.count + 1,
                       "the colour grid also holds the Default swatch")
    }

    func testRowMath() {
        XCTAssertEqual(L.colorGrid.rows, 7)
        XCTAssertEqual(L.symbolGrid.rows, 6)
        XCTAssertEqual(L.emojiGrid.rows, 6)
    }
}
