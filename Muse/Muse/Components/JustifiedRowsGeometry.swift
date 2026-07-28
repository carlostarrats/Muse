//
//  JustifiedRowsGeometry.swift
//  Muse
//
//  Pure justified-rows packing — the "Rows" image layout. Every row shares one
//  height, each item keeps its own shape, and a closed row spans the content
//  width exactly. Sibling of MasonryGeometry (which packs vertical columns for
//  the "Columns" layout): stateless, O(n), no SwiftUI, unit-tested.
//
//  The trailing partial row is deliberately NOT justified. Stretching it would
//  blow a single leftover image up to a full-width panorama.
//

import CoreGraphics

enum JustifiedRowsGeometry {

    /// One item's placement within its row (x is derived when laying out).
    struct Item: Equatable {
        let index: Int
        let width: CGFloat
    }

    /// A run of items sharing one height.
    struct Row: Equatable {
        var items: [Item]
        var height: CGFloat
    }

    struct Result {
        /// Frame of each item in content coordinates (origin top-left),
        /// positionally matching the input `aspects`.
        var frames: [CGRect]
        /// Total scrollable content height.
        var totalHeight: CGFloat
    }

    /// Layout-only clamp on a single item's aspect. A pathological panorama
    /// (a few thousand pixels wide, a dozen tall) would otherwise force a
    /// sub-pixel row height and swallow the whole row. This bounds PACKING
    /// only — the image is still drawn at its true shape inside its frame.
    static let minAspect: CGFloat = 0.1
    static let maxAspect: CGFloat = 10

    private static func clamped(_ aspect: CGFloat) -> CGFloat {
        let a = aspect > 0 ? aspect : 1
        return min(maxAspect, max(minAspect, a))
    }

    /// Group `aspects` (height ÷ width) into rows.
    ///
    /// A row accumulates items until justifying it to the full width would make
    /// it no taller than `targetHeight`; at that point it closes at exactly the
    /// height that fills the width. Any leftover items form a final row at
    /// `targetHeight`, left-aligned and unstretched.
    static func rows(aspects: [CGFloat],
                     targetHeight: CGFloat,
                     width: CGFloat,
                     spacing: CGFloat) -> [Row] {
        guard !aspects.isEmpty, width > 0, targetHeight > 0 else { return [] }

        var out: [Row] = []
        var current: [Int] = []
        // Σ (1 / aspect) — the row's total width at a height of 1.
        var inverseSum: CGFloat = 0

        /// Close `current` at `height`, laying its items out left to right.
        func close(at height: CGFloat) {
            out.append(Row(items: current.map {
                Item(index: $0, width: height / clamped(aspects[$0]))
            }, height: height))
            current = []
            inverseSum = 0
        }

        for (i, raw) in aspects.enumerated() {
            // Very tall images add almost no width, so in a narrow container at
            // a wide gutter a row can accumulate until the GUTTERS ALONE exceed
            // the row width — justifying then divides by a negative usable width
            // and collapses the whole row to a 1pt sliver. Close what we have
            // before that can happen.
            if !current.isEmpty, spacing * CGFloat(current.count) >= width {
                close(at: max(1, (width - spacing * CGFloat(current.count - 1)) / inverseSum))
            }

            current.append(i)
            inverseSum += 1 / clamped(raw)

            let gaps = spacing * CGFloat(current.count - 1)
            let fitted = max(1, (width - gaps) / inverseSum)
            guard fitted <= targetHeight else { continue }
            close(at: fitted)
        }

        if !current.isEmpty { close(at: targetHeight) }
        return out
    }

    /// Lay the rows out into content-coordinate frames.
    ///
    /// - Parameters:
    ///   - targetHeight: the row height to aim for. `GridView` derives this
    ///     from the images-per-row slider so one control drives every mode.
    ///   - captionHeight: a fixed strip added to every tile's height (for an
    ///     under-tile filename caption). 0 = no caption.
    static func compute(aspects: [CGFloat],
                        targetHeight: CGFloat,
                        width: CGFloat,
                        spacing: CGFloat,
                        captionHeight: CGFloat = 0) -> Result {
        let packed = rows(aspects: aspects, targetHeight: targetHeight,
                          width: width, spacing: spacing)
        guard !packed.isEmpty else { return Result(frames: [], totalHeight: 0) }

        var frames = [CGRect](repeating: .zero, count: aspects.count)
        var y: CGFloat = 0
        for row in packed {
            var x: CGFloat = 0
            let tileHeight = row.height + captionHeight
            for item in row.items {
                frames[item.index] = CGRect(x: x, y: y,
                                            width: item.width, height: tileHeight)
                x += item.width + spacing
            }
            y += tileHeight + spacing
        }
        // Strip the trailing spacing added after the last row.
        return Result(frames: frames, totalHeight: max(0, y - spacing))
    }
}
