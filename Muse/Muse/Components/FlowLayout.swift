//
//  FlowLayout.swift
//  Muse
//
//  Created by Carlos Tarrats on 3/19/26.
//

import SwiftUI

/// A SwiftUI `Layout` that arranges subviews horizontally, wrapping to the
/// next line when items would exceed the available width.
@available(macOS 13.0, *)
struct FlowLayout: Layout {

    /// Spacing between items, both horizontally and vertically.
    var spacing: CGFloat

    init(spacing: CGFloat = 8) {
        self.spacing = spacing
    }

    // MARK: - Layout Protocol

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout Cache
    ) -> CGSize {
        let availableWidth = proposal.width ?? .infinity
        let rows = computeRows(subviews: subviews, availableWidth: availableWidth)
        let totalHeight = rows.reduce(0) { acc, row in
            acc + row.height
        } + max(0, CGFloat(rows.count - 1)) * spacing
        return CGSize(width: availableWidth, height: totalHeight)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout Cache
    ) {
        let rows = computeRows(subviews: subviews, availableWidth: bounds.width)
        var y = bounds.minY

        for row in rows {
            var x = bounds.minX
            for item in row.items {
                item.subview.place(
                    at: CGPoint(x: x, y: y),
                    anchor: .topLeading,
                    proposal: ProposedViewSize(width: item.size.width, height: item.size.height)
                )
                x += item.size.width + spacing
            }
            y += row.height + spacing
        }
    }

    // MARK: - Cache

    struct Cache {}

    func makeCache(subviews: Subviews) -> Cache {
        Cache()
    }

    // MARK: - Helpers

    private struct RowItem {
        let subview: LayoutSubview
        let size: CGSize
    }

    private struct Row {
        var items: [RowItem] = []
        var height: CGFloat = 0

        mutating func append(_ item: RowItem) {
            items.append(item)
            height = max(height, item.size.height)
        }
    }

    private func computeRows(subviews: Subviews, availableWidth: CGFloat) -> [Row] {
        var rows: [Row] = []
        var currentRow = Row()
        var currentRowWidth: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            let neededWidth = currentRow.items.isEmpty
                ? size.width
                : currentRowWidth + spacing + size.width

            if !currentRow.items.isEmpty && neededWidth > availableWidth {
                // Wrap: commit the current row and start a new one
                rows.append(currentRow)
                currentRow = Row()
                currentRowWidth = 0
            }

            currentRow.append(RowItem(subview: subview, size: size))
            currentRowWidth = currentRow.items.count == 1
                ? size.width
                : currentRowWidth + spacing + size.width
        }

        if !currentRow.items.isEmpty {
            rows.append(currentRow)
        }

        return rows
    }
}
