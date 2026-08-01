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
//  The stored size is the DISPLAY size — EXIF orientation applied. A rotated
//  photo (orientations 5–8) is stored landscape but shown portrait, and the
//  grid, the hero flight and `files.width`/`height` all read this table, so the
//  swap has to happen once, here, or they disagree.
//

import Foundation
import ImageIO
import CoreGraphics

// `nonisolated`: this table is populated by the off-main thumbnail pass and
// read from decode workers and layout code alike. It is already internally
// thread-safe (its own NSLock), and the whole design note above is about being
// callable from a view body AND from background workers.
nonisolated enum ImageHeaderSizeCache {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var sizes: [String: CGSize] = [:]

    /// Entries are ~a path plus two doubles, so this table is small — but it is
    /// populated for every file the thumbnail pass touches and never evicts, so
    /// a very large library browsed across a long session would grow it without
    /// bound. Past the cap the whole table is dropped rather than trimmed: it
    /// is a pure cache with no authority, it refills off-main as folders are
    /// browsed, and a full clear is O(1) with no LRU bookkeeping to get wrong.
    private static let maxEntries = 20_000

    private static func key(_ url: URL) -> String { url.standardizedFileURL.path }

    /// Display dimensions for a stored pixel buffer under an EXIF orientation.
    /// Orientations 5–8 are the 90°/270° rotations, where the buffer is stored
    /// with width and height swapped relative to how the image is shown.
    ///
    /// This is the single place the swap happens: the grid's layout aspect, the
    /// hero flight's take-off rect, and `files.width`/`height` all derive from
    /// this cache, and they must not disagree (a mismatch between the grid's
    /// drawn rect and the flight's rect makes the photo visibly jump on open).
    static func displaySize(width: Int, height: Int, orientation: Int) -> CGSize {
        let rotated = (5...8).contains(orientation)
        return rotated
            ? CGSize(width: CGFloat(height), height: CGFloat(width))
            : CGSize(width: CGFloat(width), height: CGFloat(height))
    }

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
        lock.lock()
        if sizes.count >= maxEntries { sizes.removeAll(keepingCapacity: false) }
        sizes[key(url)] = size
        lock.unlock()
    }

    /// Cached value, else a header read. May do file I/O — call off-main.
    /// Returns DISPLAY dimensions (EXIF orientation applied).
    static func resolve(_ url: URL) -> CGSize? {
        if let hit = cached(url) { return hit }
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let h = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              w > 0, h > 0 else { return nil }
        let orientation = (props[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        let size = displaySize(width: w, height: h, orientation: orientation)
        record(url, width: Int(size.width), height: Int(size.height))
        return size
    }

    /// Forget one entry (an in-place edit can change an image's dimensions).
    static func invalidate(_ url: URL) {
        lock.lock(); sizes.removeValue(forKey: key(url)); lock.unlock()
    }
}
