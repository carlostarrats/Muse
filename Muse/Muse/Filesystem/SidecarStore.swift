//
//  SidecarStore.swift
//  Muse
//
//  Reads/writes a Sidecar to a hidden `.muse/<content_hash>.json` file
//  beside the asset, coordinated with NSFileCoordinator so it plays nice
//  with the iCloud sync daemon. Never holds a live SQLite handle in iCloud.
//

import Foundation

enum SidecarStore {
    /// `<asset's folder>/.muse/<content_hash>.json`
    static func sidecarURL(forAsset assetURL: URL, contentHash: String) -> URL {
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
    static func read(forAsset assetURL: URL, contentHash: String) -> Sidecar? {
        let target = sidecarURL(forAsset: assetURL, contentHash: contentHash)
        guard FileManager.default.fileExists(atPath: target.path) else { return nil }
        var result: Sidecar?
        var coordError: NSError?
        NSFileCoordinator().coordinate(readingItemAt: target, options: [],
                                       error: &coordError) { url in
            guard let data = try? Data(contentsOf: url) else { return }
            result = try? JSONDecoder().decode(Sidecar.self, from: data)
        }
        return result
    }
}
