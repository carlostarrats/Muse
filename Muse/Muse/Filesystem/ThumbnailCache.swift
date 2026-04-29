//
//  ThumbnailCache.swift
//  Muse
//
//  Generates and caches thumbnails via QuickLookThumbnailing.
//  Two-tier cache: in-memory NSCache for hot thumbnails (small + fast),
//  on-disk PNG cache for cold thumbnails (survives launch).
//
//  Eviction: in-memory by NSCache cost limit; on-disk by LRU when total
//  cache size exceeds the configured cap (default 2GB, configurable via
//  Preferences in Phase 6).
//

import AppKit
import QuickLookThumbnailing
import CryptoKit

@MainActor
final class ThumbnailCache: ObservableObject {
    static let shared = ThumbnailCache()

    private let memCache = NSCache<NSString, NSImage>()
    private let diskRoot: URL
    private let fileManager = FileManager.default

    /// Total on-disk cache size cap in bytes. Defaults to 2GB.
    var diskCapBytes: Int64 = 2 * 1024 * 1024 * 1024

    private init() {
        memCache.countLimit = 2000
        let appSupport = (try? fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? URL(fileURLWithPath: NSTemporaryDirectory())
        diskRoot = appSupport
            .appendingPathComponent("Muse", isDirectory: true)
            .appendingPathComponent("ThumbnailCache", isDirectory: true)
        try? fileManager.createDirectory(at: diskRoot, withIntermediateDirectories: true)
    }

    /// Async fetch. Returns memory hit, then disk hit, then generates.
    func thumbnail(for url: URL, size: CGSize, scale: CGFloat = 2.0) async -> NSImage? {
        let key = cacheKey(url: url, size: size, scale: scale)
        if let hit = memCache.object(forKey: key as NSString) {
            return hit
        }
        let diskURL = diskPath(for: key)
        if fileManager.fileExists(atPath: diskURL.path), let img = NSImage(contentsOf: diskURL) {
            memCache.setObject(img, forKey: key as NSString)
            return img
        }
        guard let generated = await generate(url: url, size: size, scale: scale) else { return nil }
        memCache.setObject(generated, forKey: key as NSString)
        writeToDisk(image: generated, at: diskURL)
        return generated
    }

    // MARK: - Private

    private func cacheKey(url: URL, size: CGSize, scale: CGFloat) -> String {
        let raw = "\(url.absoluteString)|\(Int(size.width))x\(Int(size.height))@\(scale)"
        let hash = SHA256.hash(data: Data(raw.utf8))
        return hash.map { String(format: "%02x", $0) }.joined()
    }

    private func diskPath(for key: String) -> URL {
        diskRoot.appendingPathComponent(key + ".png")
    }

    private func generate(url: URL, size: CGSize, scale: CGFloat) async -> NSImage? {
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

    private func writeToDisk(image: NSImage, at url: URL) {
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let data = bitmap.representation(using: .png, properties: [:]) else { return }
        try? data.write(to: url, options: .atomic)
    }

    /// Public entry to enforce the size cap. Call periodically (e.g. on launch
    /// idle) — LRU prune by access date.
    func enforceDiskCap() {
        Task.detached(priority: .background) { [diskRoot, fileManager, diskCapBytes] in
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
