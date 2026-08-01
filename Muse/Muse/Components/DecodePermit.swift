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
    /// Images at or under this cost one permit.
    ///
    /// **This was 30 MP and that was wrong** — measured, after shipping. At 30 MP
    /// a 115 MP scan cost 4 of 8 permits, so only 2 decoded concurrently instead
    /// of 8, and folder-open over big scans got **2.6x SLOWER** (592 ms -> 1562 ms
    /// for 20 large TIFFs). The memory pressure that weighting defended against
    /// was hypothesised, not measured; the reported hang was the ANALYSIS path
    /// (111 s/file), never the thumbnail gate, which handled 20 large TIFFs in
    /// 592 ms at flat 8-wide.
    ///
    /// 100 MP keeps a real ceiling on the pathological case (a handful of
    /// 100 MP+ files can still each materialise ~1 GB) while leaving every
    /// realistic image — including 65 MP medium-format scans — at full 8-wide
    /// parallelism. Don't lower it again without measuring folder-open
    /// throughput, not just peak memory.
    nonisolated static let ordinaryPixels = 100_000_000

    /// Most permits any single image may hold. Caps the worst case at
    /// `limit / maxCost` concurrent giant decodes rather than serialising to 2.
    nonisolated static let maxCost = 2

    /// Permits one image should hold, clamped to `1...limit`.
    ///
    /// `nil`/degenerate pixel counts cost 1: an unreadable header must never
    /// request more than the gate can ever grant, which would deadlock it.
    nonisolated static func cost(forDeclaredPixels pixels: Int?, limit: Int) -> Int {
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
        return min(cap, maxCost, max(1, units))
    }
}
