//
//  HeroPalette.swift
//  Muse
//
//  Shared on-open palette extraction for the hero viewers. The pure histogram
//  core (`paletteHexes`) is split out so images (ImageIO thumbnail) and videos
//  (a sampled AVAssetImageGenerator frame) share one algorithm; it's also the
//  display-only fallback when the DB has no analyzed palette yet.
//

import Foundation
import CoreGraphics
import ImageIO
import AVFoundation

enum HeroPalette {
    /// Pure: coarse RGB-bucket histogram over premultiplied-last RGBA bytes →
    /// up to 3 distinct dominant colors as "#rrggbb", ordered dark → light.
    /// `bytes` must be at least width*height*4 long (4 bytes/pixel, RGBA).
    nonisolated static func paletteHexes(fromRGBA bytes: [UInt8],
                                         width: Int, height: Int) -> [String] {
        guard width > 0, height > 0, bytes.count >= width * height * 4 else { return [] }
        let limit = width * height * 4
        var counts: [Int: Int] = [:]
        var sums: [Int: (r: Int, g: Int, b: Int)] = [:]
        for i in stride(from: 0, to: limit, by: 4) {
            let r = Int(bytes[i]), g = Int(bytes[i + 1]), b = Int(bytes[i + 2])
            let key = (r >> 4) << 8 | (g >> 4) << 4 | (b >> 4)
            counts[key, default: 0] += 1
            let s = sums[key] ?? (0, 0, 0)
            sums[key] = (s.r + r, s.g + g, s.b + b)
        }
        let top = counts.sorted { $0.value > $1.value }.prefix(12)
            .compactMap { key, c -> (Int, Int, Int)? in
                guard let s = sums[key] else { return nil }
                return (s.r / c, s.g / c, s.b / c)
            }
        var picked: [(Int, Int, Int)] = []
        for c in top where picked.count < 3 {
            if picked.allSatisfy({ abs($0.0 - c.0) + abs($0.1 - c.1) + abs($0.2 - c.2) > 60 }) {
                picked.append(c)
            }
        }
        picked.sort { ($0.0 + $0.1 + $0.2) < ($1.0 + $1.1 + $1.2) }
        return picked.map { String(format: "#%02x%02x%02x", $0.0, $0.1, $0.2) }
    }

    /// Image: a tiny ImageIO thumbnail decoded to RGBA → `paletteHexes`.
    nonisolated static func quickPalette(at url: URL) async -> [String] {
        await Task.detached(priority: .userInitiated) { () -> [String] in
            guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, [
                      kCGImageSourceCreateThumbnailFromImageAlways: true,
                      kCGImageSourceThumbnailMaxPixelSize: 48,
                  ] as CFDictionary) else { return [] }
            return hexes(from: cg)
        }.value
    }

    /// Video: one small frame ~1s in — or the clip's midpoint if it's shorter
    /// than 2s — decoded to RGBA → `paletteHexes`.
    /// Skips dataless iCloud placeholders (never forces a download just to tint
    /// the backdrop); returns [] on any failure → neutral backdrop.
    nonisolated static func videoPalette(at url: URL) async -> [String] {
        if (try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey]))?
            .ubiquitousItemDownloadingStatus == .notDownloaded {
            return []
        }
        return await Task.detached(priority: .userInitiated) { () -> [String] in
            let asset = AVURLAsset.noNetwork(url: url)
            let gen = AVAssetImageGenerator(asset: asset)
            gen.appliesPreferredTrackTransform = true
            gen.maximumSize = CGSize(width: 48, height: 48)
            var seconds = 0.0
            if let dur = try? await asset.load(.duration) {
                let total = CMTimeGetSeconds(dur)
                if total.isFinite && total > 0 { seconds = min(1.0, total / 2) }
            }
            let time = CMTime(seconds: seconds, preferredTimescale: 600)
            guard let cg = try? await gen.image(at: time).image else { return [] }
            return hexes(from: cg)
        }.value
    }

    /// Draw a CGImage into a width*height RGBA buffer and bucket it.
    nonisolated private static func hexes(from cg: CGImage) -> [String] {
        let w = cg.width, h = cg.height
        guard w > 0, h > 0 else { return [] }
        var data = [UInt8](repeating: 0, count: w * h * 4)
        let drew = data.withUnsafeMutableBytes { buf -> Bool in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h,
                                      bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drew else { return [] }
        return paletteHexes(fromRGBA: data, width: w, height: h)
    }
}
