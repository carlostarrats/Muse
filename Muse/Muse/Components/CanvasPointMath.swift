//
//  CanvasPointMath.swift
//  Muse
//
//  Canvas point → unit image-space point, under fit/zoom/pan. Pure, so the
//  eyedropper's coordinate maths is testable without a canvas.
//
//  Returns nil OUT of the image rather than clamping: sampling a click that
//  landed on the backdrop would set white balance from the backdrop colour,
//  which reads as the eyedropper being broken.
//

import CoreGraphics

nonisolated enum CanvasPointMath {
    static func imagePoint(fromCanvasPoint point: CGPoint, fit: CGRect,
                           zoom: CGFloat, pan: CGSize) -> CGPoint? {
        guard fit.width > 0, fit.height > 0, zoom > 0 else { return nil }
        // Zoom is about the fitted rect's CENTRE, which is what the canvas
        // does — scaling about the origin instead would drift the sample point
        // further off as the user zooms in.
        let center = CGPoint(x: fit.midX + pan.width, y: fit.midY + pan.height)
        let scaled = CGRect(x: center.x - fit.width * zoom / 2,
                            y: center.y - fit.height * zoom / 2,
                            width: fit.width * zoom, height: fit.height * zoom)
        let u = (point.x - scaled.minX) / scaled.width
        let v = (point.y - scaled.minY) / scaled.height
        guard (0...1).contains(u), (0...1).contains(v) else { return nil }
        return CGPoint(x: u, y: v)
    }
}

/// Solve a temperature/tint slider pair from a pixel the user declared
/// neutral. Pure and testable, unlike the RAW path (which asks CIRAWFilter for
/// the answer via `neutralLocation`).
///
/// The stack stays DECLARATIVE either way: what's stored is the resulting
/// slider offsets, never the click location. A stored location would have to
/// be re-sampled on every render and would break the moment a crop moved it.
nonisolated enum WBEyedropper {
    /// Green is the reference channel: a neutral pixel is one where red and
    /// blue match green. Excess red = the image is too warm and temperature
    /// must come DOWN; excess blue the other way. Same for magenta/green tint.
    static func solve(sampledColor c: (r: Double, g: Double, b: Double))
    -> (temperature: Double, tint: Double) {
        let g = max(c.g, 1e-6)
        let rRatio = c.r / g
        let bRatio = c.b / g
        // log2 so a doubling in either direction is a symmetric step, matching
        // the mired mapping's own symmetry.
        let warmth = log2(max(rRatio, 1e-6) / max(bRatio, 1e-6))
        let magenta = log2(max((c.r + c.b) / 2, 1e-6) / g)
        return (temperature: clampUnit(-warmth / 2), tint: clampUnit(-magenta / 2))
    }

    private static func clampUnit(_ v: Double) -> Double {
        v.isFinite ? min(max(v, -1), 1) : 0
    }
}
