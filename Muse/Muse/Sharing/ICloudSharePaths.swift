//
//  ICloudSharePaths.swift
//  Muse
//
//  Pure path math for iCloud collection shares: turn a collection name into
//  a safe, deterministic folder under the app's iCloud zone. No I/O.
//

import Foundation

nonisolated enum ICloudSharePaths {
    static let subfolder = "Shared Collections"

    /// Collection name → a single-path-component folder name: path separators
    /// and reserved characters become hyphens, trimmed, collapsed. Empty →
    /// "Collection" so we never produce a nameless or escaping path.
    static func sanitizedFolderName(_ raw: String) -> String {
        let illegal = CharacterSet(charactersIn: "/\\:")
        let mapped = String(raw.unicodeScalars.map { illegal.contains($0) ? "-" : Character($0) })
        let collapsed = mapped
            .split(separator: "-", omittingEmptySubsequences: true).joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return collapsed.isEmpty ? String(localized: "Collection") : collapsed
    }

    static func shareRoot(zoneDocuments: URL) -> URL {
        zoneDocuments.appendingPathComponent(subfolder, isDirectory: true)
    }

    static func shareFolder(zoneDocuments: URL, collectionName: String) -> URL {
        shareRoot(zoneDocuments: zoneDocuments)
            .appendingPathComponent(sanitizedFolderName(collectionName), isDirectory: true)
    }

    /// A file name not already in `taken`: on collision, append `-2`, `-3`, …
    /// before the extension. Pure (no I/O) so the copy loop's de-collision is
    /// unit-testable.
    static func uniqueName(_ desired: String, taken: Set<String>) -> String {
        guard taken.contains(desired) else { return desired }
        let url = URL(fileURLWithPath: desired)
        let base = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        var n = 2
        var candidate: String
        repeat {
            candidate = ext.isEmpty ? "\(base)-\(n)" : "\(base)-\(n).\(ext)"
            n += 1
        } while taken.contains(candidate)
        return candidate
    }
}
