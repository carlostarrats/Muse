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

    /// A grid that FILLS the width it's given: the columns are flexible, so the
    /// cell size falls out of the available width rather than being fixed.
    ///
    /// Fixed columns were the mistake here. A fixed-column grid can only be as
    /// wide as its cells happen to add up to, so it left a ragged gap on the
    /// right — and when it didn't fit, it silently overflowed the card instead.
    /// Flexible columns make "spans the full width" structural: it's true at any
    /// card width, for any column count, with no number to keep in sync.
    struct Grid: Equatable {
        /// Width the grid is laid out in.
        var available: CGFloat
        var gap: CGFloat
        var columns: Int
        var count: Int
        /// Row height, when the cell isn't square. The colour swatches are
        /// fixed-diameter circles, so widening their column makes the grid wider
        /// but not taller — deriving row height from cell width would overstate
        /// it badly.
        var rowHeight: CGFloat?

        /// The resulting cell size — derived, never set.
        var cell: CGFloat {
            guard columns > 0 else { return 0 }
            return (available - CGFloat(columns - 1) * gap) / CGFloat(columns)
        }
        var rows: Int {
            columns > 0 ? Int((Double(count) / Double(columns)).rounded(.up)) : 0
        }
        /// Always the full available width — that's the point.
        var width: CGFloat { available }
        var height: CGFloat {
            let h = rowHeight ?? cell
            return CGFloat(rows) * h + CGFloat(max(0, rows - 1)) * gap
        }
        /// True when the cells fill every row — a ragged last row makes the tab
        /// shorter or taller than its partner.
        var isEven: Bool { columns > 0 && count % columns == 0 }
    }

    // MARK: - Card

    /// The modal's width, and what's actually left to lay out in.
    ///
    /// The presenter lays the card's content out at the FULL card width (the
    /// reserved scrollbar strip is gone — see ModalChrome), so what's usable is
    /// simply card-minus-padding. Both grids must be sized against this exact
    /// number: when they weren't, they overflowed by DIFFERENT amounts per tab,
    /// which is what made the modal look like it changed width when you
    /// switched. Derive it, never restate it.
    static let cardWidth: CGFloat = 480
    static let cardPadding: CGFloat = 28
    static var contentWidth: CGFloat {
        cardWidth - cardPadding * 2
    }

    /// Height of a column's "Color" / "Icon" heading plus the 10pt gap under it.
    /// Both tabs draw exactly one such heading row, so it cancels out of the
    /// tab-vs-tab comparison — it's here so `pickerHeight` is derived rather
    /// than guessed.
    ///
    /// The heading measures 14pt (11pt semibold), so 24 = 14 + 10 exactly. Two
    /// points of slack on top of that: `pickerHeight` is a RESERVE, and
    /// over-reserving costs a couple of blank points while under-reserving
    /// clips the grid into the buttons below — the failure this whole type
    /// exists to prevent.
    static let headingBlock: CGFloat = 26

    /// Gap on each side of the Symbols tab's divider.
    static let columnGap: CGFloat = 14
    static let dividerWidth: CGFloat = 1

    // MARK: - The two tabs

    /// Width of the Symbols tab's colour column. Fixed, so the symbol grid can
    /// take exactly the rest — that's what makes the two gaps around the divider
    /// equal and leaves nothing spare on the right.
    static let colorColumnWidth: CGFloat = 140
    /// What's left for the symbol grid once the colour column, the divider and
    /// its two gaps are taken out.
    static var symbolColumnWidth: CGFloat {
        contentWidth - colorColumnWidth - columnGap * 2 - dividerWidth
    }

    /// 28 cells (Default + 27 tokens) in 4 columns = 7 rows.
    static let colorGrid = Grid(available: colorColumnWidth, gap: 10, columns: 4,
                                count: 28, rowHeight: 24)
    /// 42 cells in 7 columns = 6 rows.
    static let symbolGrid = Grid(available: symbolColumnWidth, gap: 7, columns: 7, count: 42)
    /// 66 emoji in 11 columns = 6 rows. More columns than the symbol grid on
    /// purpose: emoji read fine smaller, so the extra width buys more choice.
    static let emojiGrid = Grid(available: contentWidth, gap: 8, columns: 11, count: 66)

    /// Both tabs span the full content width by construction.
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
