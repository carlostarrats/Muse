import Foundation
import CoreGraphics
import ImageIO

// `nonisolated`: pure arithmetic over pixels, called from the analysis pass.
// Without the marker it inherits the module's default MainActor isolation, and
// `weightedPalette(image:)` — which resamples the whole decoded raster down to
// 32×32 before clustering — measured 22 ms per 4096×2731 image ON THE MAIN
// THREAD, once per analyzed photo.
nonisolated enum PaletteExtractor {
    /// Deterministic k-means over RGB pixels; returns hex strings sorted by
    /// cluster size, capped at 6.
    static func kmeansHex(pixels: [(Double, Double, Double)], k: Int, seed: UInt64) -> [String] {
        kmeansWeighted(pixels: pixels, k: k, seed: seed).map { $0.0 }
    }

    /// As `kmeansHex`, but each entry carries its cluster's share of the
    /// pixels (0…1), sorted by share descending. Color tagging uses the share
    /// so a tiny accent cluster doesn't tag the whole image (a 5%-coverage
    /// red sliver should not make an image "red").
    static func kmeansWeighted(pixels: [(Double, Double, Double)], k: Int, seed: UInt64) -> [(String, Double)] {
        guard !pixels.isEmpty else { return [] }
        let k = min(max(1, k), 6, pixels.count)
        var rng = seed
        func nextRand() -> Int {
            rng = rng &* 6364136223846793005 &+ 1442695040888963407
            return Int(rng >> 33)
        }
        var centers = (0..<k).map { _ in pixels[nextRand() % pixels.count] }
        var assign = [Int](repeating: 0, count: pixels.count)
        for _ in 0..<24 {
            for (i, p) in pixels.enumerated() {
                var best = 0; var bestD = Double.greatestFiniteMagnitude
                for (c, ctr) in centers.enumerated() {
                    let d = pow(p.0 - ctr.0, 2) + pow(p.1 - ctr.1, 2) + pow(p.2 - ctr.2, 2)
                    if d < bestD { bestD = d; best = c }
                }
                assign[i] = best
            }
            for c in 0..<k {
                let members = pixels.indices.filter { assign[$0] == c }
                guard !members.isEmpty else { continue }
                let n = Double(members.count)
                centers[c] = (members.reduce(0) { $0 + pixels[$1].0 } / n,
                              members.reduce(0) { $0 + pixels[$1].1 } / n,
                              members.reduce(0) { $0 + pixels[$1].2 } / n)
            }
        }
        let counts = (0..<k).map { c in assign.filter { $0 == c }.count }
        let total = Double(pixels.count)
        return zip(centers, counts)
            .filter { $0.1 > 0 }
            .sorted { $0.1 > $1.1 }
            .map { ctr, count in
                (String(format: "#%02x%02x%02x",
                        Int(ctr.0 * 255), Int(ctr.1 * 255), Int(ctr.2 * 255)),
                 Double(count) / total)
            }
    }

    /// Downsample an image to ~32x32 and extract its palette as (hex, share),
    /// sorted by share descending. The stored palette is `map { $0.0 }`; color
    /// tagging uses the shares (see `ColorTagger`).
    static func weightedPalette(for url: URL, k: Int = 5) -> [(String, Double)] {
        guard let pixels = downsampledRGB(for: url) else { return [] }
        return kmeansWeighted(pixels: pixels, k: k, seed: 7)
    }

    /// As `weightedPalette(for:)`, but from an ALREADY-DECODED image.
    ///
    /// The analyze pass decodes the file once for Vision and reuses that raster
    /// here — decoding a second time cost 851 ms on a 115 MP scan and produced
    /// an identical answer. Pinned against the URL overload by
    /// `PaletteFromImageTests.testImageOverloadMatchesURLOverload`.
    static func weightedPalette(image: CGImage, k: Int = 5) -> [(String, Double)] {
        guard let pixels = downsampledRGB(image: image) else { return [] }
        return kmeansWeighted(pixels: pixels, k: k, seed: 7)
    }

    /// Decode an image, downsample to ~32x32, and return its RGB pixels in a
    /// known layout. Backs `weightedPalette(for:)`.
    private static func downsampledRGB(for url: URL) -> [(Double, Double, Double)]? {
        // Decompression-bomb guard: palette extraction runs AUTOMATICALLY on
        // index of a freshly-added file (the same no-click trigger the grid
        // thumbnail guard closes), and this thumbnail request materializes the
        // full raster for PNG/TIFF/BMP just like `imageIOThumbnail` — so refuse
        // an absurd declared pixel count before decoding.
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              ThumbnailCache.withinDecodeBudget(src),
              let thumb = CGImageSourceCreateThumbnailAtIndex(src, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceThumbnailMaxPixelSize: 32,
              ] as CFDictionary) else { return nil }
        return downsampledRGB(image: thumb)
    }

    /// Longest edge of the sample k-means runs over. ~32x32 worth of pixels is
    /// enough to characterise a palette and keeps the clustering trivial.
    static let sampleMaxEdge = 32

    /// Redraw an image into a known, small, sRGB RGBA layout and read its pixels.
    ///
    /// Two things this must keep doing:
    ///
    /// 1. **Redraw, don't read the provider.** Reading a thumbnail's raw
    ///    dataProvider assumed R,G,B at bytes 0,1,2 — ImageIO thumbnails are
    ///    typically BGRA, which swapped red and blue in every palette.
    /// 2. **sRGB, not DeviceRGB.** So the palette matches
    ///    `VisionServices.dominantColorHex` and doesn't vary with whatever space
    ///    the decoder tagged the source with. DeviceRGB is unspecified by
    ///    definition, so two files could yield different hexes for the same
    ///    visual colour — and RAW decodes as ITU-R 2100 PQ. Don't revert.
    ///
    /// Caps its own working size, because the analyze pass now hands in the
    /// FULL bounded raster (up to 4096px) rather than a pre-shrunk thumbnail —
    /// without the cap, k-means would run over millions of pixels.
    static func downsampledRGB(image: CGImage) -> [(Double, Double, Double)]? {
        let longest = max(image.width, image.height)
        guard longest > 0 else { return nil }
        let scale = longest > sampleMaxEdge ? Double(sampleMaxEdge) / Double(longest) : 1.0
        let w = max(1, Int((Double(image.width) * scale).rounded()))
        let h = max(1, Int((Double(image.height) * scale).rounded()))

        var data = [UInt8](repeating: 0, count: w * h * 4)
        let drew = data.withUnsafeMutableBytes { buf -> Bool in
            guard let srgb = CGColorSpace(name: CGColorSpace.sRGB),
                  let ctx = CGContext(data: buf.baseAddress, width: w, height: h,
                                      bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: srgb,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            // `.high` is load-bearing, not a nicety. The analyze pass hands in a
            // 4096px raster, so this is up to a 128x reduction; `.medium`
            // point-samples at that ratio and aliases badly. Measured mean
            // per-pixel error against ImageIO's own 32px thumbnail across the
            // RAW + scan fixtures: `.medium` 26-43, `.high` 2.6-12.6 (progressive
            // halving scored the same as `.high`, so it isn't worth the extra
            // passes). Don't lower this.
            ctx.interpolationQuality = .high
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drew else { return nil }
        var px: [(Double, Double, Double)] = []
        px.reserveCapacity(w * h)
        for o in stride(from: 0, to: data.count, by: 4) {
            px.append((Double(data[o]) / 255, Double(data[o + 1]) / 255, Double(data[o + 2]) / 255))
        }
        return px
    }
}
