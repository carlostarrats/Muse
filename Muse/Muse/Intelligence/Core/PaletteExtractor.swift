import Foundation
import CoreGraphics
import ImageIO

enum PaletteExtractor {
    /// Deterministic k-means over RGB pixels; returns hex strings sorted by
    /// cluster size, capped at 6.
    static func kmeansHex(pixels: [(Double, Double, Double)], k: Int, seed: UInt64) -> [String] {
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
        return zip(centers, counts)
            .filter { $0.1 > 0 }
            .sorted { $0.1 > $1.1 }
            .map { ctr, _ in
                String(format: "#%02x%02x%02x",
                       Int(ctr.0 * 255), Int(ctr.1 * 255), Int(ctr.2 * 255))
            }
    }

    /// Downsample an image to ~32x32 and extract its palette.
    static func palette(for url: URL, k: Int = 5) -> [String] {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let thumb = CGImageSourceCreateThumbnailAtIndex(src, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceThumbnailMaxPixelSize: 32,
              ] as CFDictionary) else { return [] }
        // Redraw into a known RGBA layout. Reading the thumbnail's raw
        // dataProvider assumed R,G,B at bytes 0,1,2 — ImageIO thumbnails
        // are typically BGRA, which swapped red and blue in every palette.
        let w = thumb.width, h = thumb.height
        var data = [UInt8](repeating: 0, count: w * h * 4)
        let drew = data.withUnsafeMutableBytes { buf -> Bool in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h,
                                      bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            ctx.draw(thumb, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drew else { return [] }
        var px: [(Double, Double, Double)] = []
        for o in stride(from: 0, to: data.count, by: 4) {
            px.append((Double(data[o]) / 255, Double(data[o + 1]) / 255, Double(data[o + 2]) / 255))
        }
        return kmeansHex(pixels: px, k: k, seed: 7)
    }
}
