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

    /// True iff `folder` is a safe, direct, non-special child of `shareRoot` —
    /// the precondition for a destructive `removeItem` on a share folder. Used by
    /// BOTH the copy path and the Manage-delete path so every `removeItem` is
    /// guarded identically (a `.`/`..`/multi-component or escaping leaf, or a
    /// corrupted stored path, would otherwise let `removeItem` hit a parent or
    /// sibling — up to the whole iCloud Documents zone).
    static func isContainedShareFolder(_ folder: URL, shareRoot: URL) -> Bool {
        let leaf = folder.lastPathComponent
        guard leaf.isEmpty == false, leaf != ".", leaf != ".." else { return false }
        return folder.deletingLastPathComponent().standardizedFileURL.path
            == shareRoot.standardizedFileURL.path
    }

    static func shareFolder(zoneDocuments: URL, collectionName: String) -> URL {
        shareRoot(zoneDocuments: zoneDocuments)
            .appendingPathComponent(sanitizedFolderName(collectionName), isDirectory: true)
    }

    /// The leaf folder name for a share, disambiguated so a DIFFERENT collection
    /// can never reuse (and thus clobber/repoint) another's folder. `owners`
    /// maps an already-used leaf name → the STABLE IDENTITY of the collection
    /// that owns it (the collection's id, NOT its display name). The SAME
    /// collection reuses its folder (re-share refreshes in place); a different
    /// collection gets `-2`, `-3`, … This covers two distinct collision sources:
    /// (1) names that sanitize to the same leaf ("Trip/Italy" vs "Trip-Italy"),
    /// and (2) two collections sharing an IDENTICAL display name — keying on the
    /// stable id (not the name) is what catches case 2. Without it, sharing the
    /// second would delete the first's copies and silently repoint its
    /// already-distributed iCloud link at the second's images. Pure (no I/O).
    static func uniqueFolderName(for collectionName: String, identity: String,
                                 owners: [String: String]) -> String {
        let base = sanitizedFolderName(collectionName)
        func free(_ name: String) -> Bool {
            guard let owner = owners[name] else { return true }   // unused
            return owner == identity                              // already ours
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
