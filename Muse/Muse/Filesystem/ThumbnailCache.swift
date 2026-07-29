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

/// Ordered concurrency gate: lowest `order` waits the shortest. Grid tiles
/// pass their visual index, so thumbnails fill top-to-bottom; the viewer
/// passes 0 and jumps the queue. The body runs OUTSIDE the actor
/// (nonisolated), so the limit really is `limit`, not 1.
private actor ThumbnailGate {
    private var available: Int
    private let limit: Int
    private struct Waiter {
        let order: Int
        let id: UInt64
        let cost: Int
        let cont: CheckedContinuation<Void, Error>
    }
    private var waiters: [Waiter] = []
    private var nextID: UInt64 = 0
    init(limit: Int) { available = limit; self.limit = limit }

    /// Permits one request may hold, clamped to `1...limit`. A request that
    /// asked for more than the gate can ever grant would wait forever.
    /// `limit` is an immutable `let`, so this needs no actor hop.
    nonisolated func permits(for cost: Int) -> Int { min(max(1, cost), limit) }

    /// Acquire a permit, honoring cancellation. Throws `CancellationError` if
    /// the task is cancelled while queued — which is exactly what happens when
    /// a grid tile scrolls off-screen before it reached the front of the line.
    /// That waiter is then removed instead of being served, so the gate spends
    /// its slots on tiles that are STILL visible, not on the hundreds the user
    /// already scrolled past.
    /// `need` is pre-clamped by `withSlot` via `permits(for:)`.
    private func acquire(order: Int, need: Int) async throws {
        if available >= need { available -= need; return }
        let id = nextID; nextID += 1
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { cont in
                waiters.append(Waiter(order: order, id: id, cost: need, cont: cont))
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

    /// Return `cost` permits, then serve as many lowest-order waiters as now fit.
    ///
    /// The loop is load-bearing: returning a multi-permit release can unblock
    /// SEVERAL single-permit waiters, and serving only one would leak
    /// concurrency on every large-image release until the gate starved.
    private func releaseNow(need: Int) {
        available = min(limit, available + need)
        while let next = waiters.indices
            .filter({ waiters[$0].cost <= available })
            .min(by: { waiters[$0].order < waiters[$1].order }) {
            let w = waiters.remove(at: next)
            available -= w.cost
            w.cont.resume()
        }
    }

    /// Returns `nil` if cancelled while queued (or before the body ran) — the
    /// caller treats that as "no thumbnail needed anymore" and moves on.
    nonisolated func withSlot<T: Sendable>(order: Int, cost: Int = 1,
                                           _ body: @Sendable () async -> T?) async -> T? {
        // Already cancelled before we even queue? Don't enqueue a waiter — it
        // avoids the already-cancelled-at-entry window in the cancellation
        // handler entirely.
        if Task.isCancelled { return nil }
        // Clamp ONCE, here, so acquire and release can never disagree. They
        // used to clamp independently — acquire to `limit`, release not at all —
        // so a cost above the limit took `limit` permits and credited back
        // `cost`, over-subscribing the gate by the difference. `DecodePermit`
        // caps at 2 against a limit of 8, so it was unreachable in practice;
        // this makes it unreachable by construction for the next caller too.
        let need = permits(for: cost)
        do {
            try await acquire(order: order, need: need)
        } catch {
            return nil   // cancelled while waiting → drop the work entirely
        }
        if Task.isCancelled { await releaseNow(need: need); return nil }
        let result = await body()
        await releaseNow(need: need)
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
    private static let gateLimit = 8
    private static let gate = ThumbnailGate(limit: gateLimit)

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
    /// The hero viewer's undecodable-format fallback needs a LARGE thumbnail,
    /// and its natural size is the viewport — a continuous runtime value, which
    /// would generate variants no enumeration could ever list. It is quantized
    /// to this ladder instead, so the set stays finite and `invalidate` can
    /// still drop every one.
    static let heroFallbackSizes: [CGFloat] = [1600, 2048, 3072, 4096]

    /// Smallest ladder step at or above `maxDimension` (the top step past it).
    nonisolated static func heroFallbackSize(forMaxDimension d: CGFloat) -> CGFloat {
        heroFallbackSizes.first { $0 >= d } ?? heroFallbackSizes[heroFallbackSizes.count - 1]
    }

    /// Duplicates-modal tile edge. Lives HERE, beside the enumeration that has
    /// to cover it, rather than as a private constant in the view — that is how
    /// it drifted off the list in the first place.
    static let duplicateTileSize: CGFloat = 140

    static let renderedVariants: [(size: CGSize, scale: CGFloat)] = [
        (CGSize(width: 320, height: 320), 2.0),
        (CGSize(width: 160, height: 160), 2.0),
        (CGSize(width: duplicateTileSize, height: duplicateTileSize), 2.0),
    ] + heroFallbackSizes.map { (CGSize(width: $0, height: $0), CGFloat(1.0)) }

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
        // An in-place edit can change the image's dimensions, so the memoized
        // header size has to go with the thumbnails.
        ImageHeaderSizeCache.invalidate(url)
        // The variant list grew from 2 to 7 (the Duplicates tile + the hero
        // fallback ladder), and this runs on the MAIN actor once per changed
        // file — `markContentChanged` loops it over a whole batch, so a bulk
        // iCloud sync-in pays the cost per file. Most of the added variants are
        // absent for any given file, and `removeItem` on a missing path costs
        // ~7µs (it constructs an NSError) against ~1.5µs for the existence
        // check — measured, not assumed. So probe first and only pay for real
        // deletions. Same race window as the unconditional delete had: a PNG
        // written after the check survives either way.
        let fm = FileManager.default
        for v in Self.renderedVariants {
            let key = Self.cacheKey(url: url, size: v.size, scale: v.scale)
            memCache.removeObject(forKey: key as NSString)
            let path = diskPath(for: key)
            if fm.fileExists(atPath: path.path) { try? fm.removeItem(at: path) }
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
        // Thumbnails no longer drive the status pill. This path is INTERACTIVE
        // — a visible tile asking for its image — so reporting it made the pill
        // appear, fill and vanish on every scroll into un-prewarmed tiles. The
        // tile's own shimmer already says "this one is loading"; the pill is for
        // background work over the whole library. See WorkProgress's shares.
        let img = await Self.loadOrGenerate(url: url, diskURL: diskURL,
                                            size: size, scale: scale, order: order)
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
        // Header-only read (no decode) so a huge image takes a bigger share of
        // the gate than a snapshot does. Cheap enough to do before queueing.
        let cost = DecodePermit.cost(forDeclaredPixels: declaredPixelCount(url: url),
                                     limit: gateLimit)
        return await gate.withSlot(order: order, cost: cost) {
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

    /// Declared pixel count from the image header, or nil if unreadable / not an
    /// image. Header-only — never decodes.
    private nonisolated static func declaredPixelCount(url: URL) -> Int? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let h = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue
        else { return nil }
        // Free prewarm: the hero flight needs this exact value from its first
        // frame, and resolving it here (off-main, before any click) keeps the
        // main thread out of the filesystem entirely. See ImageHeaderSizeCache.
        // DISPLAY dimensions, not the raw buffer's — a rotated photo is stored
        // landscape and shown portrait, and every consumer of this table wants
        // the shape the user sees. (The pixel COUNT below is orientation-
        // invariant, so the decode budget is unaffected either way.)
        let orientation = (props[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        let display = ImageHeaderSizeCache.displaySize(width: w, height: h,
                                                       orientation: orientation)
        ImageHeaderSizeCache.record(url, width: Int(display.width),
                                    height: Int(display.height))
        let (product, overflow) = w.multipliedReportingOverflow(by: h)
        return overflow ? nil : product
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
        // or mid-fade. `videoFrame` uses the reference-RESTRICTED asset.
        if kind == .video {
            if let frame = await videoFrame(url: url, size: size, scale: scale) {
                return frame
            }
            // Do NOT fall through to QuickLook for a video whose frame extraction
            // failed. QuickLook thumbnails it in its OWN unrestricted, out-of-
            // process AVFoundation instance Muse can't constrain — which would
            // reopen the reference-movie remote-fetch egress that `.noNetwork`
            // closes (a crafted pure-remote reference movie fails the restricted
            // extractor, then QuickLook would resolve it). A video AVFoundation
            // can't frame is one the app can't play anyway (every player uses
            // AVFoundation), so the honest, egress-free result is the static type
            // icon — no content decode, no network.
            let icon = NSWorkspace.shared.icon(forFile: url.path)
            icon.size = size
            return icon
        }

        // Audio: same rule as video, for the same reason. `.m4a` (and the rest
        // of the MPEG-4 family) is an ISO-BMFF/QuickTime container, so it can
        // carry the very same `rdrf` remote data reference a reference MOVIE
        // does — and QuickLook would open it in its own UNRESTRICTED,
        // out-of-process AVFoundation, reopening the egress `.noNetwork` closes.
        // Thumbnails run on mere folder open, so that would beacon with no click.
        // Album art is read HERE instead, through the reference-restricted asset,
        // so the artwork tile survives without handing the file to QuickLook;
        // an audio file with no embedded art gets the static type icon.
        if kind == .audio {
            if let art = await audioArtwork(url: url, size: size, scale: scale) {
                return art
            }
            let icon = NSWorkspace.shared.icon(forFile: url.path)
            icon.size = size
            return icon
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
        // Enforced, not merely intended: an AVFoundation-backed kind that slipped
        // past the branches above must never reach QuickLook's unrestricted,
        // out-of-process AVFoundation.
        guard mayUseQuickLook(kind) else {
            let icon = NSWorkspace.shared.icon(forFile: url.path)
            icon.size = size
            return icon
        }
        // `.all` (not just `.thumbnail`) so QuickLook returns its best available
        // representation: a real CONTENT preview when one exists (PDF first page,
        // text/office doc render) AND falls back to the native macOS TYPE ICON
        // when there isn't (zip, dmg, generic binary) — those system icons are
        // vector-backed multi-res assets, so they stay crisp at any tile size.
        // Without the icon fallback these files returned nil → permanently grey
        // tiles. generateBestRepresentation still prefers a content thumbnail
        // over the icon, so files that DID render are unchanged.
        let request = QLThumbnailGenerator.Request(
            fileAt: url,
            size: size,
            scale: scale,
            representationTypes: .all
        )
        return await withCheckedContinuation { continuation in
            QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { rep, _ in
                continuation.resume(returning: rep?.nsImage)
            }
        }
    }

    /// Whether a kind may be handed to QuickLook at all.
    ///
    /// QuickLook previews out-of-process in AVFoundation that Muse cannot
    /// constrain, so anything AVFoundation opens must be excluded: a QuickTime
    /// reference movie — or an `.m4a`, same ISO-BMFF container family — can
    /// carry an `rdrf` remote data reference, and resolving it beacons the
    /// viewer's IP on mere folder open. `.noNetwork` closes that for Muse's own
    /// asset opens; this keeps the file from reaching the one component that
    /// ignores the restriction. Both thumbnail paths (grid + PDF export) route
    /// these kinds to a restricted frame/artwork read, then the static type icon.
    ///
    /// A NEW AVFoundation-backed kind must be added here.
    nonisolated static func mayUseQuickLook(_ kind: AssetKind) -> Bool {
        kind != .video && kind != .audio
    }

    /// Generous ceiling (300 megapixels) on the pixel count Muse will hand to an
    /// ImageIO decode. No consumer photo — even a large scan — approaches this;
    /// it exists purely to refuse a decompression bomb.
    nonisolated static let maxDecodePixels = 300_000_000

    /// Decompression-bomb guard: a tiny file can DECLARE enormous dimensions
    /// (e.g. a few-KB PNG at 40000×40000 ≈ 1.6 Gpx), and for formats ImageIO
    /// can't stream-downsample (PNG/TIFF/BMP) even a thumbnail request first
    /// materializes the FULL raster — multi-GB — OOM-killing the process. Because
    /// thumbnailing runs on mere folder open (prewarm), a planted file would
    /// crash on open with no click. Read ONLY the header dimensions (cheap, no
    /// decode) and refuse past the ceiling. Missing dims → allow (can't pre-judge;
    /// the bomb formats always declare them). Overflow-safe.
    nonisolated static func withinDecodeBudget(_ src: CGImageSource) -> Bool {
        guard let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let h = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue
        else { return true }
        let (product, overflow) = w.multipliedReportingOverflow(by: h)
        return !overflow && product <= maxDecodePixels
    }

    /// Downsampled thumbnail via ImageIO — honors EXIF orientation and forces
    /// the decode now (off-main), so the main thread never lazily decodes on
    /// first draw. Returns nil only for a genuinely unreadable/non-image file.
    private nonisolated static func imageIOThumbnail(url: URL, size: CGSize,
                                                     scale: CGFloat) -> NSImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              withinDecodeBudget(src) else { return nil }
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

    /// Same bounded ImageIO downsample, over bytes already in memory (embedded
    /// audio cover art). Shares `withinDecodeBudget`, so an absurdly large
    /// embedded cover is refused rather than materialized.
    private nonisolated static func imageIOThumbnail(data: Data, size: CGSize,
                                                     scale: CGFloat) -> NSImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              withinDecodeBudget(src) else { return nil }
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
        let asset = AVURLAsset.noNetwork(url: url)
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

    /// Embedded cover art from an audio file, read through the
    /// reference-RESTRICTED asset so a crafted container can't resolve a remote
    /// data reference. nil when the file carries no artwork (caller falls back
    /// to the static type icon) — never a QuickLook call.
    private nonisolated static func audioArtwork(url: URL, size: CGSize,
                                                 scale: CGFloat) async -> NSImage? {
        let asset = AVURLAsset.noNetwork(url: url)
        guard let metadata = try? await asset.load(.commonMetadata) else { return nil }
        let artwork = AVMetadataItem.metadataItems(from: metadata,
                                                   filteredByIdentifier: .commonIdentifierArtwork)
        for item in artwork {
            guard let data = try? await item.load(.dataValue), !data.isEmpty else { continue }
            // Downsample through the same bounded ImageIO path the grid uses, so
            // an absurdly large embedded cover can't materialize a full raster.
            if let image = imageIOThumbnail(data: data, size: size, scale: scale) { return image }
        }
        return nil
    }

    /// Encode an NSImage to PNG bytes via CGImageDestination — no TIFF round-trip.
    /// Returns nil (fail-closed) if the image has no CGImage or encoding fails.
    nonisolated static func encodePNG(_ image: NSImage) -> Data? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            out as CFMutableData, UTType.png.identifier as CFString, 1, nil
        ) else { return nil }
        CGImageDestinationAddImage(dest, cg, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }

    private nonisolated static func writePNG(_ image: NSImage, to url: URL) {
        guard let data = encodePNG(image) else { return }
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
