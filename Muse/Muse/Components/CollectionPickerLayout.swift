//
//  CollectionPickerLayout.swift
//  Muse
//
//  Grid geometry for the Symbol & Color modal's two picker tabs.
//
//  The tabs are ONE control, so they must occupy ONE box: switching between
//  them may not change the card's size. That's easy to get wrong by eye and
//  easy to break later by adding a catalog entry, so the numbers live here as
//  pure arithmetic with a unit test that fails the moment the two tabs stop
//  matching — rather than as constants scattered through the view.
//

import CoreGraphics

nonisolated enum CollectionPickerLayout {

    /// A grid's outer size, given its cell size, gap, column count and how many
    /// cells it holds.
    struct Grid: Equatable {
        var cell: CGFloat
        var gap: CGFloat
        var columns: Int
        var count: Int

        var rows: Int {
            columns > 0 ? Int((Double(count) / Double(columns)).rounded(.up)) : 0
        }
        var width: CGFloat {
            CGFloat(columns) * cell + CGFloat(max(0, columns - 1)) * gap
        }
        var height: CGFloat {
            CGFloat(rows) * cell + CGFloat(max(0, rows - 1)) * gap
        }
        /// True when the cells fill every row — a ragged last row makes the tab
        /// shorter or taller than its partner.
        var isEven: Bool { columns > 0 && count % columns == 0 }
    }

    // MARK: - Card

    /// The modal's width, and the content width left inside its padding.
    static let cardWidth: CGFloat = 480
    static let cardPadding: CGFloat = 28
    static var contentWidth: CGFloat { cardWidth - cardPadding * 2 }

    /// Height of a column's "Color" / "Icon" heading plus the gap under it.
    /// Both tabs draw exactly one such heading row, so it cancels out of the
    /// comparison — it's here so `pickerHeight` is derived, not guessed.
    static let headingBlock: CGFloat = 24

    /// Gap on each side of the Symbols tab's divider.
    static let columnGap: CGFloat = 16
    static let dividerWidth: CGFloat = 1

    // MARK: - The two tabs

    /// 28 cells (Default + 27 tokens) in 4 columns = 7 rows.
    static let colorGrid = Grid(cell: 24, gap: 10, columns: 4, count: 28)
    /// 42 cells in 7 columns = 6 rows.
    static let symbolGrid = Grid(cell: 30, gap: 8, columns: 7, count: 42)
    /// 45 emoji in 9 columns = 5 rows.
    static let emojiGrid = Grid(cell: 38, gap: 9, columns: 9, count: 45)

    static var symbolsTabWidth: CGFloat {
        colorGrid.width + columnGap + dividerWidth + columnGap + symbolGrid.width
    }
    static var symbolsTabHeight: CGFloat {
        headingBlock + max(colorGrid.height, symbolGrid.height)
    }
    static var emojiTabWidth: CGFloat { emojiGrid.width }
    static var emojiTabHeight: CGFloat { headingBlock + emojiGrid.height }

    /// The height the picker area reserves, whichever tab is showing. Derived
    /// from the taller tab, so it can never clip: a tab whose content overflowed
    /// its reserved box spilled over the buttons below, which read as the card
    /// changing size even though the frame hadn't moved.
    static var pickerHeight: CGFloat { max(symbolsTabHeight, emojiTabHeight) }

    /// How far apart the two tabs' footprints are. Zero is ideal; the test pins
    /// it to a tolerance a viewer can't perceive.
    static var widthDelta: CGFloat { abs(symbolsTabWidth - emojiTabWidth) }
    static var heightDelta: CGFloat { abs(symbolsTabHeight - emojiTabHeight) }
}
