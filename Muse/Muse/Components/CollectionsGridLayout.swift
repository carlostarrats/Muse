//
//  CollectionsGridLayout.swift
//  Muse
//
//  Pure geometry for the Collections page's card grid: given the viewport
//  width, how wide is a card and how much gutter sits outside the outer
//  columns?
//
//  The gutter is NOT decorative. A hovered pile fans its cards OUTSIDE its
//  own cell (StackScatter.maxFanHalfWidth exceeds half the cell width), so a
//  small fixed inset let the leftmost column's fan draw over the sidebar and
//  the rightmost one run into the window edge. The inset is therefore solved
//  from the fan's worst-case overhang: cards give back exactly the width the
//  fan needs, and no more (the minimum inset still wins when the overhang is
//  smaller than it, e.g. very narrow cards).
//
//  No SwiftUI here; unit-tested in CollectionsGridLayoutTests.
//

import CoreGraphics
import Foundation

enum CollectionsGridLayout {

    struct Result: Equatable {
        /// Width of one card cell.
        var cardWidth: CGFloat
        /// Horizontal inset outside the outer columns.
        var inset: CGFloat
    }

    /// Solve card width + gutter so a fanned pile never crosses the page's
    /// bounds.
    ///
    /// - Parameters:
    ///   - width: the page viewport width.
    ///   - columns: cards per row.
    ///   - gap: spacing between columns.
    ///   - minInset: the inset to use when the fan needs less than this.
    ///   - coverAspect: cell height ÷ cell width (the pile's cell is
    ///     square-ish, so its SHORT side — which drives the fan — is the
    ///     width times `min(1, coverAspect)`).
    ///   - shadowBleed: soft-shadow allowance beyond the card's own rect.
    static func solve(width: CGFloat,
                      columns: Int,
                      gap: CGFloat,
                      minInset: CGFloat,
                      coverAspect: CGFloat,
                      shadowBleed: CGFloat) -> Result {
        let n = CGFloat(max(columns, 1))
        let gaps = gap * (n - 1)

        // Overhang past the cell edge, per point of card width.
        let shortSide = min(1, max(coverAspect, 0))
        let a = max(0, CGFloat(StackScatter.fanHalfWidthFactor) * shortSide - 0.5)

        // Case 1: the minimum inset already absorbs the overhang.
        let minInsetWidth = max(0, width - minInset * 2 - gaps) / n
        if a * minInsetWidth + shadowBleed <= minInset {
            return Result(cardWidth: minInsetWidth, inset: minInset)
        }

        // Case 2: inset == a·cardWidth + shadowBleed. Substituting into
        // width = 2·inset + n·cardWidth + gaps and solving for cardWidth.
        let cardWidth = max(0, width - shadowBleed * 2 - gaps) / (n + 2 * a)
        return Result(cardWidth: cardWidth,
                      inset: max(minInset, a * cardWidth + shadowBleed))
    }
}
