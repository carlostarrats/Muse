//
//  DecodePermit.swift
//  Muse
//
//  How much of the thumbnail gate's concurrency budget one image consumes.
//
//  The gate granted a flat 8 permits regardless of image size. For formats
//  ImageIO cannot stream-downsample (PNG/TIFF/BMP) even a thumbnail request
//  materializes the FULL raster, so eight 115 MP scanner TIFFs decoding at once
//  is multiple GB of simultaneous rasters — on mere folder open, with no click
//  involved. That is enough to push the machine into swap and make the app look
//  hung, which is exactly what a user reported.
//
//  Weighting by declared pixel count (a header read, no decode) keeps ordinary
//  photos at full parallelism while letting a few huge scans serialize
//  themselves.
//

import Foundation

enum DecodePermit {
    /// Images at or under this cost one permit — the overwhelming majority.
    /// 30 MP is above any consumer camera, so normal libraries are unaffected.
    static let ordinaryPixels = 30_000_000

    /// Permits one image should hold, clamped to `1...limit`.
    ///
    /// `nil`/degenerate pixel counts cost 1: an unreadable header must never
    /// request more than the gate can ever grant, which would deadlock it.
    static func cost(forDeclaredPixels pixels: Int?, limit: Int) -> Int {
        let cap = max(1, limit)
        guard let pixels, pixels > ordinaryPixels else { return 1 }
        // Linear in units of `ordinaryPixels`: 65 MP -> 3, 115 MP -> 4, capped.
        //
        // Ceiling division written as divide-THEN-adjust, not the usual
        // `(pixels + ordinaryPixels - 1) / ordinaryPixels`: that idiom traps on
        // arithmetic overflow when `pixels` is near Int.max, and this value comes
        // from an image header — i.e. from a FILE, which may be hostile or simply
        // corrupt. `withinDecodeBudget` rejects such an image later, but this
        // function runs first, so it has to survive the input on its own.
        let units = pixels / ordinaryPixels + (pixels % ordinaryPixels > 0 ? 1 : 0)
        return min(cap, max(1, units))
    }
}
