//
//  PageScroll.swift
//  Muse
//
//  Pure math for Page Up / Page Down scrolling: given the current scroll
//  position, the viewport height, and the document height, compute the new
//  scroll origin for a one-page jump. Leaves a small overlap of context (the
//  standard "page" behavior) and clamps to the valid range. No I/O — unit
//  tested; the AppKit catcher (PageScrollCatcher) feeds it live values.
//

import CoreGraphics

enum PageScroll {
    /// New clip-view origin.y after a page jump. Coordinates are flipped
    /// (0 at the top, growing downward), matching SwiftUI's hosted scroll
    /// content. `pageUp` moves toward the top; otherwise toward the bottom.
    static func newOriginY(currentY: CGFloat,
                           viewportHeight: CGFloat,
                           documentHeight: CGFloat,
                           pageUp: Bool) -> CGFloat {
        // Keep ~10% of the screen as overlap so the user retains context,
        // capped at 40pt for tall windows.
        let overlap = min(40, viewportHeight * 0.12)
        let step = max(1, viewportHeight - overlap)
        let maxY = max(0, documentHeight - viewportHeight)
        let raw = pageUp ? currentY - step : currentY + step
        return min(maxY, max(0, raw))
    }
}
