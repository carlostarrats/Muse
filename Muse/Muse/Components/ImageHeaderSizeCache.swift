//
//  ImageHeaderSizeCache.swift
//  Muse
//
//  An image's true pixel dimensions, read from the header once and remembered.
//
//  The hero flight needs the file's real aspect ratio from its FIRST frame:
//  a tile letterboxes the image inside a differently-shaped cell, and the
//  flight has to take off from — and land on — the rect the tile actually
//  draws into, not the raw tile rect. The decoded image isn't available that
//  early, so the aspect has to come from the header.
//
//  A header read is cheap on ordinary photos (~0.2 ms) but costs ~18 ms on a
//  659 MB scanner TIFF (measured). That is far too expensive to do from a
//  SwiftUI computed property, which is re-evaluated on every frame of an
//  animating body — and it MUST NOT live in an `NSCache`, whose whole purpose
//  is to evict under memory pressure, i.e. exactly when a giant image is open.
//  An evicted entry mid-flight meant a fresh 18 ms file open per frame on the
//  main thread: dropped frames, a stall with the backdrop still up, and on the
//  largest file the close flight skipping outright.
//
//  So: a plain table that never evicts (two doubles per path — negligible),
//  populated off-main by the thumbnail pass long before any click, and read
//  synchronously as a dictionary lookup thereafter.
//

import Foundation
import ImageIO
import CoreGraphics

enum ImageHeaderSizeCache {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var sizes: [String: CGSize] = [:]

    private static func key(_ url: URL) -> String { url.standardizedFileURL.path }

    /// In-memory lookup only. Never touches the filesystem — safe from a view
    /// body or any other main-thread hot path.
    static func cached(_ url: URL) -> CGSize? {
        lock.lock(); defer { lock.unlock() }
        return sizes[key(url)]
    }

    /// Record a size resolved elsewhere (the thumbnail pass already opens an
    /// image source for every file it touches, so the read is free there).
    static func record(_ url: URL, width: Int, height: Int) {
        guard width > 0, height > 0 else { return }
        let size = CGSize(width: width, height: height)
        lock.lock(); sizes[key(url)] = size; lock.unlock()
    }

    /// Cached value, else a header read. May do file I/O — call off-main.
    static func resolve(_ url: URL) -> CGSize? {
        if let hit = cached(url) { return hit }
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let h = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              w > 0, h > 0 else { return nil }
        record(url, width: w, height: h)
        return CGSize(width: w, height: h)
    }

    /// Forget one entry (an in-place edit can change an image's dimensions).
    static func invalidate(_ url: URL) {
        lock.lock(); sizes.removeValue(forKey: key(url)); lock.unlock()
    }
}
