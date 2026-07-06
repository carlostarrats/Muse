//
//  GridScrollReveal.swift
//  Muse
//
//  Pure math for keyboard-driven "scroll the highlighted tile into view": given
//  the current clip-view origin, the viewport + document heights, and the tile's
//  top in viewport coordinates, compute the new clip origin so the tile is fully
//  visible with a small margin. Flipped coordinates (0 at top, growing downward),
//  matching PageScroll and the hosted scroll content. No I/O — unit tested; the
//  AppKit catcher (PageScrollCatcher) feeds it live values.
//

import CoreGraphics

enum GridScrollReveal {
    /// New clip-view origin.y so the highlighted tile is on screen with `margin`
    /// clearance. Returns `clipOriginY` unchanged when the tile is already in
    /// view. `tileTopInViewport` = the tile top relative to the viewport
    /// (canvasMinY + frames[i].minY); 0 = viewport top, negative = above it.
    static func newOriginY(clipOriginY: CGFloat,
                           viewportHeight: CGFloat,
                           documentHeight: CGFloat,
                           tileTopInViewport: CGFloat,
                           tileHeight: CGFloat,
                           margin: CGFloat) -> CGFloat {
        let maxY = max(0, documentHeight - viewportHeight)
        let top = tileTopInViewport
        let bottom = tileTopInViewport + tileHeight

        var newY = clipOriginY
        if top < margin {
            newY = clipOriginY + (top - margin)
        } else if bottom > viewportHeight - margin {
            newY = clipOriginY + (bottom - (viewportHeight - margin))
        }
        return min(maxY, max(0, newY))
    }
}
