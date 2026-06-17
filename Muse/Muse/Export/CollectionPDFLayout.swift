//
//  CollectionPDFLayout.swift
//  Muse
//
//  Pure pagination of a collection's images into fixed-size PDF pages using
//  a masonry (shortest-column) pack. No I/O — deterministic and unit-tested.
//  Coordinates use a TOP-LEFT origin (y grows downward); the exporter flips
//  to PDF's bottom-left origin when drawing.
//

import CoreGraphics

enum CollectionPDFLayout {

    struct Placement: Equatable {
        let index: Int      // index into the input aspects array
        let rect: CGRect    // page coordinates, top-left origin
    }

    struct Page: Equatable {
        var placements: [Placement]
    }

    struct Geometry {
        var pageSize: CGSize                // e.g. 792 x 1008 (11x14in @ 72dpi)
        var margin: CGFloat                 // outer margin on all sides
        var columns: Int                    // tiles per row (>= 1)
        var gutter: CGFloat                 // gap between tiles
        var firstPageHeaderHeight: CGFloat  // reserved at top of page 1 only
        /// Strip reserved BELOW each image for its filename caption (0 = none).
        /// The Placement rect covers the whole tile (image + this strip); the
        /// exporter draws the image in the top portion and the caption here.
        var captionHeight: CGFloat = 0
    }

    /// Pack `aspects` (height ÷ width per image) into pages. Each tile keeps
    /// its image's shape (image height = columnWidth × aspect) so nothing is
    /// cropped, plus a `captionHeight` strip below for the filename. A tile
    /// taller than a page's content area is capped to fit one page. No tile is
    /// ever split across a page boundary.
    static func paginate(aspects: [CGFloat], geometry g: Geometry) -> [Page] {
        guard !aspects.isEmpty else { return [] }
        let cols = max(1, g.columns)
        let contentWidth = max(1, g.pageSize.width - g.margin * 2)
        let columnWidth = max(1, (contentWidth - g.gutter * CGFloat(cols - 1)) / CGFloat(cols))
        let contentBottom = g.pageSize.height - g.margin

        func contentTop(firstPage: Bool) -> CGFloat {
            g.margin + (firstPage ? g.firstPageHeaderHeight : 0)
        }
        func available(firstPage: Bool) -> CGFloat {
            max(1, contentBottom - contentTop(firstPage: firstPage))
        }

        var pages: [Page] = []
        var current = Page(placements: [])
        var colHeights = [CGFloat](repeating: 0, count: cols)
        var firstPage = true

        // Whole-tile height = the image (columnWidth × aspect) plus the
        // caption strip below it, capped so a single tile still fits one page.
        func tileHeight(aspect: CGFloat, avail: CGFloat) -> CGFloat {
            min(columnWidth * aspect + g.captionHeight, avail)
        }

        for (i, rawAspect) in aspects.enumerated() {
            let aspect = rawAspect > 0 ? rawAspect : 1
            var avail = available(firstPage: firstPage)
            var tileH = tileHeight(aspect: aspect, avail: avail)

            // Shortest column.
            var col = 0
            for c in 1..<cols where colHeights[c] < colHeights[col] { col = c }

            // New page if the tile won't fit — but never break just to place
            // the first tile of an (already empty) page.
            if !current.placements.isEmpty, colHeights[col] + tileH > avail {
                pages.append(current)
                current = Page(placements: [])
                colHeights = [CGFloat](repeating: 0, count: cols)
                firstPage = false
                col = 0
                avail = available(firstPage: firstPage)
                tileH = tileHeight(aspect: aspect, avail: avail)
            }

            let x = g.margin + CGFloat(col) * (columnWidth + g.gutter)
            let y = contentTop(firstPage: firstPage) + colHeights[col]
            current.placements.append(
                Placement(index: i, rect: CGRect(x: x, y: y, width: columnWidth, height: tileH)))
            colHeights[col] += tileH + g.gutter
        }

        if !current.placements.isEmpty { pages.append(current) }
        return pages
    }
}
