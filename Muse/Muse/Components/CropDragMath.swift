//
//  CropDragMath.swift
//  Muse
//
//  Pure geometry for the crop frame — no View and no gesture state, so it is
//  unit-testable without a host. Modelled on Surface Camera's
//  `CropGestureState`, which splits along the same line.
//
//  Every rect here is a `CropRect`: normalized to the image, TOP-LEFT origin,
//  y down. That is exactly what `EditRenderer.applyGeometry` decodes (it flips
//  y itself for Core Image's bottom-left space), so a value from here goes
//  straight into `GeometryParams.crop` with no conversion — and the renderer's
//  own comment warns that getting this wrong "looks like an off-by-one in the
//  editor's crop handles".
//

import Foundation
import CoreGraphics

nonisolated enum CropDragMath {

    /// The smallest fraction of either axis the frame may be dragged down to.
    static let minimumSide: Double = 0.05

    enum Handle: CaseIterable {
        case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left

        var movesLeftEdge: Bool { self == .topLeft || self == .left || self == .bottomLeft }
        var movesRightEdge: Bool { self == .topRight || self == .right || self == .bottomRight }
        var movesTopEdge: Bool { self == .topLeft || self == .top || self == .topRight }
        var movesBottomEdge: Bool { self == .bottomLeft || self == .bottom || self == .bottomRight }
    }

    /// Apply a normalized drag delta to one handle. `aspect` (width ÷ height,
    /// in PIXELS) locks the shape when non-nil.
    ///
    /// `imageAspect` is required whenever `aspect` is, and it is not optional
    /// noise: a `CropRect`'s w and h are fractions of the image's width and
    /// height, which have DIFFERENT pixel scales. So a normalized 0.6 × 0.6 on
    /// a 3:2 photo is a 1.5:1 rectangle, not a square. The lock therefore has
    /// to be applied to `aspect / imageAspect` — comparing the raw ratio was a
    /// real shipped bug, and the test that "covered" it asserted `w == h`,
    /// which is the bug restated.
    ///
    /// The result is ALWAYS a valid sub-rect of the image: never inverted,
    /// never smaller than `minimumSide`, never outside 0…1. Those three are
    /// what stop a fast drag from producing a frame the renderer can't crop to.
    static func resize(_ rect: CropRect, handle: Handle, by delta: CGSize,
                       aspect: Double?, imageAspect: Double = 1) -> CropRect {
        var minX = rect.x
        var minY = rect.y
        var maxX = rect.x + rect.w
        var maxY = rect.y + rect.h

        if handle.movesLeftEdge { minX += Double(delta.width) }
        if handle.movesRightEdge { maxX += Double(delta.width) }
        if handle.movesTopEdge { minY += Double(delta.height) }
        if handle.movesBottomEdge { maxY += Double(delta.height) }

        minX = min(max(minX, 0), 1)
        minY = min(max(minY, 0), 1)
        maxX = min(max(maxX, 0), 1)
        maxY = min(max(maxY, 0), 1)

        var w = max(maxX - minX, minimumSide)
        var h = max(maxY - minY, minimumSide)

        if let aspect, aspect > 0, imageAspect > 0, aspect.isFinite, imageAspect.isFinite {
            // The lock in NORMALIZED space, which is the pixel ratio divided by
            // the image's own ratio — see the note on this function.
            let target = aspect / imageAspect
            // Shrink the over-long axis, never grow the other: growing could
            // push the frame back outside the image.
            if w / h > target { w = h * target } else { h = w / target }
            w = min(w, 1)
            h = min(h, 1)
            // Clamping one axis to 1 can break the lock; re-derive the other
            // from whichever axis actually survived.
            if w / h > target { w = h * target } else { h = w / target }
            // A very lopsided target against a very lopsided image can drive
            // one side under the floor. Honour the floor over the lock — a
            // frame too small to grab is worse than one slightly off-ratio,
            // and every other caller relies on the minimum holding.
            if w < minimumSide || h < minimumSide {
                let lift = max(minimumSide / max(w, 1e-9), minimumSide / max(h, 1e-9))
                w = min(1, w * lift)
                h = min(1, h * lift)
            }
        }

        // Re-anchor to whichever edges this handle did NOT move, so the
        // opposite corner stays put under the cursor.
        var x = handle.movesLeftEdge ? maxX - w : minX
        var y = handle.movesTopEdge ? maxY - h : minY

        x = min(max(x, 0), max(0, 1 - w))
        y = min(max(y, 0), max(0, 1 - h))

        return CropRect(x: x, y: y, w: w, h: h)
    }

    /// The largest centred rect of `aspect` (width ÷ height) that fits an image
    /// whose own aspect is `imageAspect`. Picking a preset that matches the
    /// photo's own shape must cost nothing.
    static func fit(aspect: Double, into imageAspect: Double) -> CropRect {
        guard aspect > 0, imageAspect > 0, aspect.isFinite, imageAspect.isFinite else {
            return .full
        }
        var w = 1.0, h = 1.0
        if aspect > imageAspect {
            h = imageAspect / aspect            // limited by height
        } else {
            w = aspect / imageAspect            // limited by width
        }
        return CropRect(x: (1 - w) / 2, y: (1 - h) / 2, w: w, h: h)
    }

    // MARK: - Display space vs source space
    //
    // `EditRenderer.applyGeometry` crops FIRST and then flips and quarter-turns
    // the result, so `GeometryParams.crop` is expressed in the SOURCE's
    // coordinates. The editor, meanwhile, shows the photo with those flips and
    // turns already applied — so a rect the user draws on screen is in DISPLAY
    // coordinates and has to be mapped back before it is stored.
    //
    // Without this, rotating a landscape photo 90° and cropping the top of what
    // you see stores the LEFT band of the original. That is the exact failure
    // `applyGeometry`'s own comment warns about: "crops the wrong band and looks
    // like an off-by-one in the editor's crop handles".

    /// The aspect the user is LOOKING at: the source's, transposed by an odd
    /// number of quarter turns.
    static func displayAspect(source: Double, quarterTurns: Int) -> Double {
        guard source > 0, source.isFinite else { return 1 }
        return normalizedTurns(quarterTurns) % 2 == 1 ? 1 / source : source
    }

    /// Map a rect drawn on the DISPLAY back into source coordinates, for
    /// storage in `GeometryParams.crop`.
    static func sourceRect(fromDisplay rect: CropRect, quarterTurns: Int,
                           flipH: Bool, flipV: Bool) -> CropRect {
        var r = rect
        // Undo the turns first — they were applied last.
        for _ in 0..<normalizedTurns(quarterTurns) { r = rotatedCCW(r) }
        if flipV { r = flippedV(r) }
        if flipH { r = flippedH(r) }
        return r
    }

    /// The inverse: take a stored crop and place it on the displayed image, so
    /// re-opening the card shows the frame where the user left it.
    static func displayRect(fromSource rect: CropRect, quarterTurns: Int,
                            flipH: Bool, flipV: Bool) -> CropRect {
        var r = rect
        if flipH { r = flippedH(r) }
        if flipV { r = flippedV(r) }
        for _ in 0..<normalizedTurns(quarterTurns) { r = rotatedCW(r) }
        return r
    }

    static func normalizedTurns(_ turns: Int) -> Int { ((turns % 4) + 4) % 4 }

    /// One 90° clockwise turn of the IMAGE. The source's top-left corner ends
    /// up at the display's top-right, which is what fixes the mapping.
    private static func rotatedCW(_ r: CropRect) -> CropRect {
        CropRect(x: 1 - r.y - r.h, y: r.x, w: r.h, h: r.w)
    }

    private static func rotatedCCW(_ r: CropRect) -> CropRect {
        CropRect(x: r.y, y: 1 - r.x - r.w, w: r.h, h: r.w)
    }

    private static func flippedH(_ r: CropRect) -> CropRect {
        CropRect(x: 1 - r.x - r.w, y: r.y, w: r.w, h: r.h)
    }

    private static func flippedV(_ r: CropRect) -> CropRect {
        CropRect(x: r.x, y: 1 - r.y - r.h, w: r.w, h: r.h)
    }

    /// The largest centred rect that stays inside the image after rotating by
    /// `degrees`.
    ///
    /// Without this, straightening leaves transparent wedges in the corners —
    /// `applyGeometry` rotates and then crops, with no inset of its own.
    /// Lightroom and Apple Photos both pull the crop in automatically as you
    /// rotate, and Muse follows.
    ///
    /// This is NOT destructive: it writes a `crop` value, the original file is
    /// never touched, and returning the slider to 0 restores the full frame in
    /// one gesture.
    static func straightenInset(degrees: Double, aspect: Double) -> CropRect {
        let radians = abs(degrees) * .pi / 180
        guard radians > 1e-9, aspect > 0, aspect.isFinite else { return .full }

        let c = cos(radians), s = sin(radians)
        // Largest rect of the SAME shape inscribed in the rotated source,
        // working in source-relative units where width = aspect, height = 1.
        let w0 = aspect, h0 = 1.0
        let denomW = w0 * c + h0 * s
        let denomH = w0 * s + h0 * c
        guard denomW > 1e-9, denomH > 1e-9 else { return .full }
        let scale = min(w0 / denomW, h0 / denomH)
        let side = min(max(scale, minimumSide), 1)
        return CropRect(x: (1 - side) / 2, y: (1 - side) / 2, w: side, h: side)
    }
}
