//
//  MasonryLayout.swift
//  Muse
//
//  Created by Carlos Tarrats on 3/19/26.
//

import SwiftUI

/// A SwiftUI `Layout` that arranges subviews in a Pinterest-style masonry grid.
/// Each subview is placed in the shortest column, allowing images of varying
/// heights to pack tightly without uniform row heights.
@available(macOS 13.0, *)
struct MasonryLayout: Layout {

    /// Number of columns in the grid.
    var columns: Int

    /// Vertical and horizontal spacing between items.
    var spacing: CGFloat

    init(columns: Int, spacing: CGFloat = 12) {
        self.columns = max(1, columns)
        self.spacing = spacing
    }

    // MARK: - Layout Protocol

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout Cache
    ) -> CGSize {
        guard !subviews.isEmpty else {
            return .zero
        }

        let availableWidth = proposal.width ?? 0
        updateCache(&cache, subviews: subviews, availableWidth: availableWidth)

        let maxHeight = cache.columnHeights.max() ?? 0
        return CGSize(width: availableWidth, height: maxHeight)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout Cache
    ) {
        guard !subviews.isEmpty else { return }

        let availableWidth = bounds.width
        updateCache(&cache, subviews: subviews, availableWidth: availableWidth)

        let columnWidth = columnWidth(for: availableWidth)

        // Reset column heights and replay placement relative to bounds origin
        var columnHeights = [CGFloat](repeating: 0, count: columns)

        for (index, subview) in subviews.enumerated() {
            let column = shortestColumnIndex(in: columnHeights)
            let subviewHeight = cache.subviewHeights[index]

            let x = bounds.minX + CGFloat(column) * (columnWidth + spacing)
            let y = bounds.minY + columnHeights[column]

            subview.place(
                at: CGPoint(x: x, y: y),
                anchor: .topLeading,
                proposal: ProposedViewSize(width: columnWidth, height: subviewHeight)
            )

            columnHeights[column] += subviewHeight + spacing
        }
    }

    // MARK: - Cache

    struct Cache {
        /// Resolved heights for each subview given the last computed column width.
        var subviewHeights: [CGFloat] = []
        /// Running column heights after placing all subviews.
        var columnHeights: [CGFloat] = []
    }

    func makeCache(subviews: Subviews) -> Cache {
        Cache()
    }

    func updateCache(_ cache: inout Cache, subviews: Subviews, availableWidth: CGFloat) {
        // Recompute every pass: a subview's height changes when its thumbnail
        // lands (square placeholder → real aspect), which width/count guards
        // can't see — gating on them packed multi-row grids with stale
        // heights. Measuring is cheap (aspect math on fixed frames).
        let colWidth = columnWidth(for: availableWidth)
        let proposal = ProposedViewSize(width: colWidth, height: nil)

        var subviewHeights: [CGFloat] = []
        var colHeights = [CGFloat](repeating: 0, count: columns)

        for subview in subviews {
            let size = subview.sizeThatFits(proposal)
            subviewHeights.append(size.height)

            let column = shortestColumnIndex(in: colHeights)
            colHeights[column] += size.height + spacing
        }

        // Remove the trailing spacing added after the last item in each column
        let finalHeights = colHeights.map { height in
            height > 0 ? height - spacing : 0
        }

        cache.subviewHeights = subviewHeights
        cache.columnHeights = finalHeights
    }

    // MARK: - Helpers

    /// Width of a single column given the total available width.
    private func columnWidth(for availableWidth: CGFloat) -> CGFloat {
        let totalSpacing = CGFloat(columns - 1) * spacing
        return (availableWidth - totalSpacing) / CGFloat(columns)
    }

    /// Returns the index of the column with the smallest accumulated height.
    private func shortestColumnIndex(in heights: [CGFloat]) -> Int {
        heights.indices.min(by: { heights[$0] < heights[$1] }) ?? 0
    }
}
