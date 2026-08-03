//
//  EditorCanvasGeometry.swift
//  Muse
//
//  Where the editor's canvas view SITS, in points. Pure, so the geometry that
//  used to be split between a SwiftUI layout and a Core Image transform is one
//  testable function.
//
//  The point of the split: the Metal view is sized to the CONTENT — the image's
//  own fitted rect — exactly the way the Preview page lays out its `Image`.
//  Everything geometric then happens here, in points, and the renderer's only
//  job is to fill whatever drawable it is handed.
//
//  Why that matters, and it is not a tidiness argument. The canvas used to span
//  the whole window and re-fit internally, converting `fitInsets` from points to
//  drawable pixels with a `pixelScale` read off the drawable. During a live
//  resize the drawable lags the bounds, so that scale was wrong on a large
//  fraction of frames (measured: 3.32 instead of 2.0, fitting the photo to a
//  third of its width) and the photo jumped. With the view sized to the content:
//
//    * there is no point→pixel conversion left to get wrong;
//    * the view's ASPECT equals the image's aspect and never changes during a
//      resize, so a drawable that lags is a correctly-shaped texture on a
//      correctly-shaped view — `contentsGravity = .resizeAspect` maps it exactly
//      onto the new bounds, and the only difference is resolution, which is
//      invisible for one frame.
//
//  Zoom is applied to the FRAME rather than inside the renderer, which keeps the
//  "zoom pushes the photo under the panels" behaviour: the view simply grows
//  past the free rect, and the panels are drawn over it.
//

import CoreGraphics
import SwiftUI

nonisolated enum EditorCanvasGeometry {
    /// Gap between the two panes in side-by-side compare, as a fraction of ONE
    /// image's width. Proportional rather than a point constant so it survives
    /// being expressed as an aspect ratio.
    static let sideBySideGapFraction: CGFloat = 0.02

    /// The width ÷ height the canvas VIEW should have.
    ///
    /// Side-by-side shows two whole images with a gap, so the content is wider
    /// than the photo — the view has to match, or the two panes would be fitted
    /// into a box shaped for one.
    static func contentAspect(imageSize: CGSize, sideBySide: Bool) -> CGFloat {
        guard imageSize.width > 0, imageSize.height > 0 else { return 1 }
        let single = imageSize.width / imageSize.height
        return sideBySide ? single * (2 + sideBySideGapFraction) : single
    }

    /// The free space inside the panels, in points.
    static func freeRect(canvas: CGSize, insets: EdgeInsets) -> CGRect {
        CGRect(x: insets.leading, y: insets.top,
               width: max(1, canvas.width - insets.leading - insets.trailing),
               height: max(1, canvas.height - insets.top - insets.bottom))
    }

    /// The content's size at zoom 1 — aspect-fitted into the free rect. This is
    /// what the pan clamp measures against, so the photo can never be dragged
    /// off its own canvas.
    static func fittedSize(canvas: CGSize, insets: EdgeInsets, aspect: CGFloat) -> CGSize {
        let free = freeRect(canvas: canvas, insets: insets)
        guard aspect > 0, free.width > 0, free.height > 0 else { return free.size }
        let byWidth = CGSize(width: free.width, height: free.width / aspect)
        return byWidth.height <= free.height
            ? byWidth
            : CGSize(width: free.height * aspect, height: free.height)
    }

    /// Where the canvas view goes: the fitted size scaled by zoom, centred in
    /// the free rect and moved by the pan.
    ///
    /// Deliberately NOT clamped to the free rect — a zoomed photo is supposed to
    /// grow past it and run under the panels, matching the Preview page.
    static func contentRect(canvas: CGSize, insets: EdgeInsets,
                            aspect: CGFloat, zoom: CGFloat, pan: CGSize) -> CGRect {
        let free = freeRect(canvas: canvas, insets: insets)
        let fitted = fittedSize(canvas: canvas, insets: insets, aspect: aspect)
        let z = max(zoom, 0.001)
        let size = CGSize(width: fitted.width * z, height: fitted.height * z)
        return CGRect(x: free.midX + pan.width - size.width / 2,
                      y: free.midY + pan.height - size.height / 2,
                      width: size.width, height: size.height)
    }

    /// A point in the canvas VIEW's own coordinates → unit image space.
    ///
    /// Trivial now, and that is the point: the view IS the image's rect, so the
    /// mapping is a division rather than a re-derivation of fit, zoom and pan.
    /// The old path rebuilt that rect from the full window size while the
    /// renderer used the window MINUS the panels, so the eyedropper sampled the
    /// wrong pixel whenever the panels were showing — a bug that could only
    /// exist because the same geometry was computed in two places.
    ///
    /// Returns nil outside the content, so a click on the backdrop is refused
    /// rather than clamped to an edge pixel.
    static func unitPoint(inContentOfSize size: CGSize, at point: CGPoint) -> CGPoint? {
        guard size.width > 0, size.height > 0 else { return nil }
        let u = point.x / size.width
        let v = point.y / size.height
        guard (0...1).contains(u), (0...1).contains(v) else { return nil }
        return CGPoint(x: u, y: v)
    }
}
