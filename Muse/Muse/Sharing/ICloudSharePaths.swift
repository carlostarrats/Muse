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
    /// and reserved characters become hyphens, trimmed, collapsed. Empty OR a
    /// path-special component (`.`/`..`/all-dots) → "Collection" so we never
    /// produce a nameless or escaping path.
    static func sanitizedFolderName(_ raw: String) -> String {
        let illegal = CharacterSet(charactersIn: "/\\:")
        let mapped = String(raw.unicodeScalars.map { illegal.contains($0) ? "-" : Character($0) })
        let collapsed = mapped
            .split(separator: "-", omittingEmptySubsequences: true).joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // `.` and `..` are NOT illegal characters, so a name like ".." survives
        // the mapping above and would make `appendingPathComponent("..")` escape
        // the share root — the clean-and-recopy `removeItem` would then delete the
        // PARENT (the whole iCloud Documents zone). Treat any all-dots result as
        // nameless. (Empty is the all-dots check on "" — kept explicit for clarity.)
        if collapsed.isEmpty || collapsed.allSatisfy({ $0 == "." }) {
            return String(localized: "Collection")
        }
        return collapsed
    }

    static func shareRoot(zoneDocuments: URL) -> URL {
        zoneDocuments.appendingPathComponent(subfolder, isDirectory: true)
    }

    static func shareFolder(zoneDocuments: URL, collectionName: String) -> URL {
        shareRoot(zoneDocuments: zoneDocuments)
            .appendingPathComponent(sanitizedFolderName(collectionName), isDirectory: true)
    }

    /// The leaf folder name for a share, disambiguated so a DIFFERENT collection
    /// can never reuse (and thus clobber/repoint) another's folder. `owners`
    /// maps an already-used leaf name → the collection that owns it. The SAME
    /// collection reuses its name (re-share refreshes in place); a different
    /// collection that sanitizes to the same name gets `-2`, `-3`, … Two
    /// collections whose names differ only by sanitized characters (e.g.
    /// "Trip/Italy" vs "Trip-Italy") would otherwise collide on one folder —
    /// sharing the second would delete the first's copies and silently repoint
    /// its already-distributed iCloud link at the second's images. Pure (no I/O).
    static func uniqueFolderName(for collectionName: String, owners: [String: String]) -> String {
        let base = sanitizedFolderName(collectionName)
        func free(_ name: String) -> Bool {
            guard let owner = owners[name] else { return true }   // unused
            return owner == collectionName                        // already ours
        }
        if free(base) { return base }
        var n = 2
        while !free("\(base)-\(n)") { n += 1 }
        return "\(base)-\(n)"
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
