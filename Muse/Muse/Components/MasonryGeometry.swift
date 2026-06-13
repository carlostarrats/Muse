//
//  MasonryGeometry.swift
//  Muse
//
//  Pure masonry packing. Given a per-item aspect ratio (height ÷ width),
//  computes the frame of every tile plus the total content height for a
//  fixed column count and container width.
//
//  This replaces the SwiftUI `MasonryLayout: Layout` for large libraries:
//  a custom Layout forces SwiftUI to materialize *every* subview (no
//  windowing), so a 1700-image folder kept 1700 live tiles and re-measured
//  all of them on every layout pass. Computing the packing here — stateless,
//  O(n), sub-millisecond over thousands of items — lets `GridView` lay the
//  whole grid out once and render only the tiles inside the viewport.
//

import CoreGraphics

enum MasonryGeometry {

    struct Result {
        /// Frame of each item in content coordinates (origin top-left).
        var frames: [CGRect]
        /// Height of the tallest column (the scrollable content height).
        var totalHeight: CGFloat
    }

    /// - Parameters:
    ///   - aspects: height ÷ width for each item (1 = square). Its count is
    ///     the item count.
    ///   - columns: number of columns (clamped to ≥ 1).
    ///   - width: total available width for the grid.
    ///   - spacing: gap between tiles, horizontally and vertically.
    static func compute(aspects: [CGFloat],
                        columns: Int,
                        width: CGFloat,
                        spacing: CGFloat) -> Result {
        let cols = max(1, columns)
        guard !aspects.isEmpty, width > 0 else {
            return Result(frames: [], totalHeight: 0)
        }

        let totalSpacing = CGFloat(cols - 1) * spacing
        let columnWidth = max(1, (width - totalSpacing) / CGFloat(cols))

        var columnHeights = [CGFloat](repeating: 0, count: cols)
        var frames = [CGRect]()
        frames.reserveCapacity(aspects.count)

        for aspect in aspects {
            // Place into the shortest column — the masonry pack.
            var col = 0
            var minHeight = columnHeights[0]
            for c in 1..<cols where columnHeights[c] < minHeight {
                minHeight = columnHeights[c]
                col = c
            }

            let height = max(1, columnWidth * (aspect > 0 ? aspect : 1))
            let x = CGFloat(col) * (columnWidth + spacing)
            let y = columnHeights[col]
            frames.append(CGRect(x: x, y: y, width: columnWidth, height: height))
            columnHeights[col] += height + spacing
        }

        let maxHeight = columnHeights.max() ?? 0
        // Strip the trailing spacing added after the last tile in a column.
        let totalHeight = maxHeight > 0 ? maxHeight - spacing : 0
        return Result(frames: frames, totalHeight: totalHeight)
    }
}
