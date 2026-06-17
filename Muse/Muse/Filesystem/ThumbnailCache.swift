//
//  ThumbnailCache.swift
//  Muse
//
//  Generates and caches thumbnails via QuickLookThumbnailing.
//  Two-tier cache: in-memory NSCache for hot thumbnails (small + fast),
//  on-disk PNG cache for cold thumbnails (survives launch).
//
//  All disk I/O and generation runs OFF the main actor, capped at a few
//  concurrent jobs — a big folder fires a thumbnail request per tile, and
//  doing reads/PNG-encodes on main was the open/close jank.
//
//  Eviction: in-memory by NSCache cost limit; on-disk by LRU when total
//  cache size exceeds the configured cap (default 2GB).
//

import AppKit
import QuickLookThumbnailing
import CryptoKit
import AVFoundation
import ImageIO
import UniformTypeIdentifiers

/// Observable thumbnail-load progress; drives the bottom-center pill when
/// a folder's tiles are streaming in. Small bursts (a viewer open) stay
/// under the threshold and never flash the pill.
@MainActor
final class ThumbProgress: ObservableObject {
    static let shared = ThumbProgress()
    @Published private(set) var total = 0
    @Published private(set) var completed = 0
    /// Hysteresis: engages once a real batch builds up (≥4 pending) and
    /// then STAYS up until the batch fully drains — no vanishing at 95%.
    private var engaged = false
    var isActive: Bool { engaged }

    func begin() {
        total += 1
        if total - completed >= 4 { engaged = true }
    }
    func step() {
        completed += 1
        if completed >= total { total = 0; completed = 0; engaged = false }
    }
}

/// Ordered concurrency gate: lowest `order` waits the shortest. Grid tiles
/// pass their visual index, so thumbnails fill top-to-bottom; the viewer
/// passes 0 and jumps the queue. The body runs OUTSIDE the actor
/// (nonisolated), so the limit really is `limit`, not 1.
private actor ThumbnailGate {
    private var available: Int
    private struct Waiter {
        let order: Int
        let id: UInt64
        let cont: CheckedContinuation<Void, Error>
    }
    private var waiters: [Waiter] = []
    private var nextID: UInt64 = 0
    init(limit: Int) { available = limit }

    /// Acquire a permit, honoring cancellation. Throws `CancellationError` if
    /// the task is cancelled while queued — which is exactly what happens when
    /// a grid tile scrolls off-screen before it reached the front of the line.
    /// That waiter is then removed instead of being served, so the gate spends
    /// its slots on tiles that are STILL visible, not on the hundreds the user
    /// already scrolled past.
    private func acquire(order: Int) async throws {
        if available > 0 { available -= 1; return }
        let id = nextID; nextID += 1
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { cont in
                waiters.append(Waiter(order: order, id: id, cont: cont))
            }
        } onCancel: {
            Task { await self.dropWaiter(id) }
        }
    }

    /// Remove a still-queued waiter (cancelled before it got a permit) and fail
    /// its continuation. It never held a permit, so `available` is untouched.
    private func dropWaiter(_ id: UInt64) {
        guard let idx = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: idx).cont.resume(throwing: CancellationError())
    }

    private func releaseNow() {
        guard let next = waiters.indices.min(by: { waiters[$0].order < waiters[$1].order })
        else { available += 1; return }
        waiters.remove(at: next).cont.resume()
    }

    /// Returns `nil` if cancelled while queued (or before the body ran) — the
    /// caller treats that as "no thumbnail needed anymore" and moves on.
    nonisolated func withSlot<T: Sendable>(order: Int,
                                           _ body: @Sendable () async -> T?) async -> T? {
        // Already cancelled before we even queue? Don't enqueue a waiter — it
        // avoids the already-cancelled-at-entry window in the cancellation
        // handler entirely.
        if Task.isCancelled { return nil }
        do {
            try await acquire(order: order)
        } catch {
            return nil   // cancelled while waiting → drop the work entirely
        }
        if Task.isCancelled { await releaseNow(); return nil }
        let result = await body()
        await releaseNow()
        return result
    }
}

@MainActor
final class ThumbnailCache: ObservableObject {
    static let shared = ThumbnailCache()

    private let memCache = NSCache<NSString, NSImage>()
    private nonisolated let diskRoot: URL
    // ImageIO image decodes are light and thread-safe (an isolated test ran
    // 8-wide over 300 files in 1.7s), so the viewport keeps up with fast deep
    // scrolling instead of draining 4-at-a-time behind the prewarm front.
    private static let gate = ThumbnailGate(limit: 8)

    /// Background prewarm work is enqueued at `prewarmOrderBase + index`, which
    /// is strictly higher than any live request's order (grid tiles pass their
    /// file index 0…N; the hero viewer passes 0). The gate serves the lowest
    /// order first, so the user's actual viewport — and the viewer — always
    /// preempt the top-to-bottom prewarm sweep. Without this, scrolling ahead
    /// of the prewarm front leaves visible tiles grey for seconds while the
    /// gate drains hundreds of lower-numbered prewarm jobs first.
    private nonisolated static let prewarmOrderBase = 1_000_000

    /// Total on-disk cache size cap in bytes. Defaults to 2GB.
    var diskCapBytes: Int64 = 2 * 1024 * 1024 * 1024

    /// Every (size, scale) the app actually renders. `invalidate(_:)` must
    /// drop EVERY variant — the cache key is path-based, so a file edited in
    /// place (crop / Photoshop save / iCloud sync) would otherwise serve its
    /// old thumbnail forever, including across launches (the on-disk PNG
    /// persists) and folder remove/re-add (same URL → same key). Keep this in
    /// sync with the sizes requested in GridView / HeroStage / prewarmToDisk.
    static let renderedVariants: [(size: CGSize, scale: CGFloat)] = [
        (CGSize(width: 320, height: 320), 2.0),
        (CGSize(width: 160, height: 160), 2.0),
    ]

    private init() {
        memCache.countLimit = 2000
        memCache.totalCostLimit = 512 * 1024 * 1024   // ~512MB of decoded pixels
        let appSupport = (try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? URL(fileURLWithPath: NSTemporaryDirectory())
        diskRoot = appSupport
            .appendingPathComponent("Muse", isDirectory: true)
            .appendingPathComponent("ThumbnailCache", isDirectory: true)
        try? FileManager.default.createDirectory(at: diskRoot, withIntermediateDirectories: true)
    }

    /// Synchronous memory-cache peek — no disk read, no generation. Lets the
    /// hero viewer start its open flight instantly with the grid's tile image.
    func cachedThumbnail(for url: URL, size: CGSize, scale: CGFloat = 2.0) -> NSImage? {
        memCache.object(forKey: Self.cacheKey(url: url, size: size, scale: scale) as NSString)
    }

    /// Drop every cached representation (memory + disk) of `url` so the next
    /// request regenerates from the file's CURRENT bytes. Called when a file's
    /// content changed in place (crop, edit-and-save, iCloud sync-in).
    ///
    /// The disk PNGs are removed SYNCHRONOUSLY before this returns: a caller
    /// typically bumps a version that immediately re-triggers the tile's load,
    /// so an async delete could lose the race and the re-fetch would read the
    /// stale PNG right back. It's only a couple of tiny `unlink`s per file.
    func invalidate(_ url: URL) {
        for v in Self.renderedVariants {
            let key = Self.cacheKey(url: url, size: v.size, scale: v.scale)
            memCache.removeObject(forKey: key as NSString)
            try? FileManager.default.removeItem(at: diskPath(for: key))
        }
    }

    /// Async fetch. Returns memory hit, then disk hit, then generates —
    /// everything past the memory peek runs off-main through the gate.
    /// `order` is the caller's visual position (grid tiles pass their index)
    /// so a cold folder fills top-to-bottom; 0 jumps the queue.
    func thumbnail(for url: URL, size: CGSize, scale: CGFloat = 2.0,
                   order: Int = 0) async -> NSImage? {
        let key = Self.cacheKey(url: url, size: size, scale: scale)
        if let hit = memCache.object(forKey: key as NSString) {
            return hit
        }
        let diskURL = diskPath(for: key)
        // The progress pill is for *generation* only. A disk hit (already
        // prewarmed) is a fast read — counting it made scrolling a warm
        // folder flash the pill for no real work. So only cold thumbnails
        // (no PNG on disk yet) drive the pill.
        let isCold = !FileManager.default.fileExists(atPath: diskURL.path)
        if isCold { ThumbProgress.shared.begin() }
        let img = await Self.loadOrGenerate(url: url, diskURL: diskURL,
                                            size: size, scale: scale, order: order)
        if isCold { ThumbProgress.shared.step() }
        if let img {
            let cost = Int(img.size.width * img.size.height * 4 * scale * scale)
            memCache.setObject(img, forKey: key as NSString, cost: cost)
        }
        return img
    }

    /// Generate every missing thumbnail for `urls` straight to the on-disk
    /// cache, in the background. Called after a folder loads so the user
    /// never waits on (or sees a progress pill for) thumbnail generation
    /// while scrolling — by the time they reach the bottom, the disk cache
    /// is already warm and a tile just reads its PNG. Already-cached files
    /// (this launch or a prior one) are skipped. Bypasses the progress pill
    /// entirely; this is silent up-front work.
    nonisolated func prewarmToDisk(_ urls: [URL],
                                   size: CGSize = CGSize(width: 320, height: 320),
                                   scale: CGFloat = 2.0) {
        guard !urls.isEmpty else { return }
        let root = diskRoot
        Task.detached(priority: .utility) {
            await withTaskGroup(of: Void.self) { group in
                let maxInFlight = 6
                var next = 0
                func addNext() {
                    guard next < urls.count else { return }
                    let url = urls[next]
                    // Strictly higher than any live request, so a visible tile
                    // always jumps ahead of the background prewarm sweep.
                    let order = Self.prewarmOrderBase + next
                    next += 1
                    group.addTask {
                        await Self.ensureDisk(url: url, diskRoot: root,
                                              size: size, scale: scale, order: order)
                    }
                }
                for _ in 0..<min(maxInFlight, urls.count) { addNext() }
                for await _ in group { addNext() }
            }
        }
    }

    /// Ensure a single thumbnail exists on disk, generating it if missing.
    /// Skips the in-memory cache and progress pill — prewarm-only path.
    private nonisolated static func ensureDisk(url: URL, diskRoot: URL,
                                               size: CGSize, scale: CGFloat,
                                               order: Int) async {
        let key = cacheKey(url: url, size: size, scale: scale)
        let diskURL = diskRoot.appendingPathComponent(key + ".png")
        if FileManager.default.fileExists(atPath: diskURL.path) { return }
        _ = await loadOrGenerate(url: url, diskURL: diskURL,
                                 size: size, scale: scale, order: order)
    }

    // MARK: - Off-main pipeline

    private nonisolated static func loadOrGenerate(
        url: URL, diskURL: URL, size: CGSize, scale: CGFloat, order: Int
    ) async -> NSImage? {
        await gate.withSlot(order: order) {
            if FileManager.default.fileExists(atPath: diskURL.path),
               let img = NSImage(contentsOf: diskURL) {
                return img
            }
            // Scrolled off-screen while queued? Skip the decode entirely.
            if Task.isCancelled { return nil }
            guard let generated = await generate(url: url, size: size, scale: scale) else {
                return nil
            }
            // Persist in the background; the caller doesn't wait on the encode.
            Task.detached(priority: .background) {
                writePNG(generated, to: diskURL)
            }
            return generated
        }
    }

    private nonisolated static func cacheKey(url: URL, size: CGSize, scale: CGFloat) -> String {
        // Standardized path (NOT absoluteString) so the key is independent of
        // how the URL was constructed — a tile's enumerated URL and an
        // invalidate()/reconstructed-from-path URL must hash to the SAME key,
        // or stale thumbnails survive an edit. (Changing this orphans the old
        // absoluteString-keyed PNGs; they regenerate once, then LRU-evict.)
        let raw = "\(url.standardizedFileURL.path)|\(Int(size.width))x\(Int(size.height))@\(scale)"
        let hash = SHA256.hash(data: Data(raw.utf8))
        return hash.map { String(format: "%02x", $0) }.joined()
    }

    private nonisolated func diskPath(for key: String) -> URL {
        diskRoot.appendingPathComponent(key + ".png")
    }

    private nonisolated static func generate(url: URL, size: CGSize, scale: CGFloat) async -> NSImage? {
        let kind = AssetKind.detect(at: url)

        // Videos: grab a frame ~1s in (10% of duration for short clips)
        // instead of QuickLook's first frame — openings are so often black
        // or mid-fade. QuickLook remains the fallback if extraction fails.
        if kind == .video,
           let frame = await videoFrame(url: url, size: size, scale: scale) {
            return frame
        }

        // Plain raster images (incl. RAW/PSD, which CGImageSource handles)
        // decode straight through ImageIO. This is the load-bearing path —
        // the vast majority of a library — and ImageIO never returns nil for a
        // valid image, decodes faster than QuickLook, and avoids the single
        // shared QLThumbnailGenerator that, under the app's real concurrent
        // load (Vision + indexing + prewarm), intermittently returned nil and
        // left tiles permanently grey. SVG is excluded (not a raster source).
        if kind == .image || kind == .raw || kind == .psd,
           let io = imageIOThumbnail(url: url, size: size, scale: scale) {
            return io
        }

        // Everything else (PDF, SVG, fonts, 3D, office, archives) → QuickLook.
        let request = QLThumbnailGenerator.Request(
            fileAt: url,
            size: size,
            scale: scale,
            representationTypes: .thumbnail
        )
        return await withCheckedContinuation { continuation in
            QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { rep, _ in
                continuation.resume(returning: rep?.nsImage)
            }
        }
    }

    /// Downsampled thumbnail via ImageIO — honors EXIF orientation and forces
    /// the decode now (off-main), so the main thread never lazily decodes on
    /// first draw. Returns nil only for a genuinely unreadable/non-image file.
    private nonisolated static func imageIOThumbnail(url: URL, size: CGSize,
                                                     scale: CGFloat) -> NSImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let maxPixel = Int(max(size.width, size.height) * scale)
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary)
        else { return nil }
        return NSImage(cgImage: cg,
                       size: NSSize(width: CGFloat(cg.width) / scale,
                                    height: CGFloat(cg.height) / scale))
    }

    /// Representative video frame: min(1s, duration × 0.1) in, never earlier
    /// (zero tolerance before; a black frame 0 must not sneak back in).
    private nonisolated static func videoFrame(url: URL, size: CGSize,
                                               scale: CGFloat) async -> NSImage? {
        let asset = AVURLAsset(url: url)
        guard let duration = try? await asset.load(.duration) else { return nil }
        let seconds = CMTimeGetSeconds(duration)
        guard seconds.isFinite, seconds > 0 else { return nil }
        let target = min(1.0, seconds * 0.1)

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: size.width * scale,
                                       height: size.height * scale)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = CMTime(seconds: 1, preferredTimescale: 600)

        let time = CMTime(seconds: target, preferredTimescale: 600)
        guard let cg = try? await generator.image(at: time).image else { return nil }
        return NSImage(cgImage: cg,
                       size: NSSize(width: CGFloat(cg.width) / scale,
                                    height: CGFloat(cg.height) / scale))
    }

    private nonisolated static func writePNG(_ image: NSImage, to url: URL) {
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let data = bitmap.representation(using: .png, properties: [:]) else { return }
        try? data.write(to: url, options: .atomic)
    }

    /// Public entry to enforce the size cap. Call periodically (e.g. on launch
    /// idle) — LRU prune by access date.
    func enforceDiskCap() {
        Task.detached(priority: .background) { [diskRoot, diskCapBytes] in
            let fileManager = FileManager.default
            guard let entries = try? fileManager.contentsOfDirectory(
                at: diskRoot,
                includingPropertiesForKeys: [.fileSizeKey, .contentAccessDateKey],
                options: [.skipsHiddenFiles]
            ) else { return }
            let info = entries.compactMap { url -> (URL, Int64, Date)? in
                let v = try? url.resourceValues(forKeys: [.fileSizeKey, .contentAccessDateKey])
                guard let size = v?.fileSize, let access = v?.contentAccessDate else { return nil }
                return (url, Int64(size), access)
            }
            let total = info.reduce(Int64(0)) { $0 + $1.1 }
            guard total > diskCapBytes else { return }
            let sorted = info.sorted { $0.2 < $1.2 } // oldest first
            var remaining = total
            for (url, size, _) in sorted {
                if remaining <= diskCapBytes { break }
                try? fileManager.removeItem(at: url)
                remaining -= size
            }
        }
    }
}
