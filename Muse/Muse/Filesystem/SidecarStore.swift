//
//  SidecarStore.swift
//  Muse
//
//  Reads/writes a Sidecar to a hidden `.muse/<content_hash>.json` file
//  beside the asset, coordinated with NSFileCoordinator so it plays nice
//  with the iCloud sync daemon. Never holds a live SQLite handle in iCloud.
//

import Foundation

nonisolated enum SidecarStore {
    /// `<asset's folder>/.muse/<content_hash>__<basename>.json`
    ///
    /// The name used to be `<content_hash>.json`. Under per-file identity that
    /// COLLIDES: two byte-identical files in one folder are two different
    /// photos with their own tags, note and edits, and they would share a
    /// single sidecar — so whichever synced last silently overwrote the other,
    /// and per-file data could not round-trip through iCloud at all.
    ///
    /// The hash stays in the name because it is the freshness check the
    /// hydrator makes (a sidecar whose hash no longer matches the file's bytes
    /// is stale and ignored); the basename is what makes it per-FILE.
    static func sidecarURL(forAsset assetURL: URL, contentHash: String) -> URL {
        assetURL.deletingLastPathComponent()
            .appendingPathComponent(".muse", isDirectory: true)
            .appendingPathComponent("\(contentHash)__\(assetURL.lastPathComponent).json",
                                    isDirectory: false)
    }

    /// The pre-per-file-identity name. READ as a fallback so a library that is
    /// already synced keeps hydrating — without it, upgrading would look like
    /// every sidecar in iCloud had vanished. Never written.
    ///
    /// A rename orphans a sidecar under either scheme; sidecars are a
    /// regenerable sync artifact, and housekeeping prunes `.muse` entries with
    /// no matching asset.
    static func legacySidecarURL(forAsset assetURL: URL, contentHash: String) -> URL {
        assetURL.deletingLastPathComponent()
            .appendingPathComponent(".muse", isDirectory: true)
            .appendingPathComponent("\(contentHash).json", isDirectory: false)
    }

    static func write(_ sidecar: Sidecar, forAsset assetURL: URL) throws {
        let target = sidecarURL(forAsset: assetURL, contentHash: sidecar.content_hash)
        let museDir = target.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: museDir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(sidecar)

        var coordError: NSError?
        var writeError: Error?
        NSFileCoordinator().coordinate(writingItemAt: target, options: .forReplacing,
                                       error: &coordError) { url in
            do { try data.write(to: url, options: .atomic) }
            catch { writeError = error }
        }
        if let coordError { throw coordError }
        if let writeError { throw writeError }
    }

    /// Returns the sidecar if present and decodable, else nil.
    ///
    /// The per-file name wins; the legacy hash-only name is the fallback, so an
    /// already-synced library keeps hydrating after the rename. Where both
    /// exist the per-file one is the truth and the legacy file is a stale
    /// shared leftover from before the split.
    static func read(forAsset assetURL: URL, contentHash: String) -> Sidecar? {
        let candidates = [sidecarURL(forAsset: assetURL, contentHash: contentHash),
                          legacySidecarURL(forAsset: assetURL, contentHash: contentHash)]
        for target in candidates {
            guard FileManager.default.fileExists(atPath: target.path) else { continue }
            var result: Sidecar?
            var coordError: NSError?
            NSFileCoordinator().coordinate(readingItemAt: target, options: [],
                                           error: &coordError) { url in
                guard let data = try? Data(contentsOf: url) else { return }
                result = try? JSONDecoder().decode(Sidecar.self, from: data)
            }
            if let result { return result }
        }
        return nil
    }
}
