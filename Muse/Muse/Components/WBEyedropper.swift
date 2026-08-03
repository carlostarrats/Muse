//
//  WBEyedropper.swift
//  Muse
//
//  Was CanvasPointMath.swift. That enum mapped a canvas point back through
//  fit/zoom/pan to unit image space, and it went with the editor canvas
//  refactor (2026-08-02): the Metal view is now SIZED to the image's rect, so
//  the mapping is a division — `EditorCanvasGeometry.unitPoint`. Re-deriving
//  the fit in a second place is what let the eyedropper sample against the
//  whole window while the renderer fitted into the window minus the panels.
//

import CoreGraphics

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
