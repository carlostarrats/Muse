//
//  FolderStat.swift
//  Muse
//
//  Aggregate stats for a top-level sidebar folder — file counts (immediate +
//  recursive), recursive total size, recursive newest mtime. Pure + nonisolated
//  so it runs off the main thread. The IMMEDIATE count mirrors the one-level grid:
//  every non-hidden immediate entry (files, packages, AND plain subfolders), so the
//  sidebar number matches the grid (which shows folder cards) and Finder. The
//  RECURSIVE count stays files-only (packages count as files, plain folders are
//  not descended-as-folders), so it matches what the recursive grid would show.
//

import Foundation

nonisolated struct FolderStat: Equatable {
    var immediateFileCount: Int
    var recursiveFileCount: Int
    var totalSize: Int64
    var latestModified: Date?
    /// False when the folder could not be listed at all (unplugged volume,
    /// revoked scope, an iCloud container not yet materialized on a cold
    /// launch). The counts are then structurally zero and mean NOTHING —
    /// distinguishing that from a genuinely empty folder is the whole point,
    /// because "0 files" is a decision input elsewhere.
    var reachable: Bool = true

    /// The recursive count when it is actually KNOWN, else nil.
    ///
    /// Every consumer that treats zero as a fact must read this, not the raw
    /// count. `ICloudSidebarVisibility` is the load-bearing one: an unlistable
    /// iCloud container used to report 0, which reads as `.empty` and HIDES a
    /// folder that may be full — the case its `.unknown` state exists to
    /// prevent, defeated because the stat could never say "unknown".
    var knownRecursiveFileCount: Int? { reachable ? recursiveFileCount : nil }
}

nonisolated enum FolderStats {
    /// Walk `folder` and aggregate counts/size/latest-mtime. Immediate = depth-1
    /// non-folder entries; recursive = all non-folder entries beneath it.
    static func compute(folder: URL, showHidden: Bool = false) -> FolderStat {
        let fm = FileManager.default
        let opts: FileManager.DirectoryEnumerationOptions = showHidden ? [] : [.skipsHiddenFiles]

        // Every non-hidden immediate entry counts: files, packages, AND plain
        // subfolders (the grid shows folder cards in the one-level view, so the
        // count must include them to match — and Finder). The recursive tally
        // below stays files-only, matching the recursive grid (no folder tiles).
        var immediate = 0
        // A failed listing is NOT an empty folder — record which it was.
        var reachable = false
        if let entries = try? fm.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: nil,
            options: opts
        ) {
            immediate = entries.count
            reachable = true
        }

        var recursive = 0
        var size: Int64 = 0
        var latest: Date?
        if let en = fm.enumerator(
            at: folder,
            includingPropertiesForKeys: [
                .isDirectoryKey, .isPackageKey, .fileSizeKey, .contentModificationDateKey
            ],
            options: opts
        ) {
            for case let url as URL in en {
                let v = try? url.resourceValues(forKeys: [
                    .isDirectoryKey, .isPackageKey, .fileSizeKey, .contentModificationDateKey
                ])
                let isDir = v?.isDirectory == true
                let isPackage = v?.isPackage == true
                if isDir && !isPackage { continue }          // skip plain folders
                recursive += 1
                size += Int64(v?.fileSize ?? 0)
                if let m = v?.contentModificationDate, latest == nil || m > latest! {
                    latest = m
                }
            }
        }

        return FolderStat(immediateFileCount: immediate,
                          recursiveFileCount: recursive,
                          totalSize: size,
                          latestModified: latest,
                          reachable: reachable)
    }

    /// Which watched root contains `path` (longest prefix wins, since roots can
    /// nest). Pure → unit-testable for the FSEvents path→root mapping.
    static func root(containing path: String, in roots: [URL]) -> URL? {
        let std = URL(fileURLWithPath: path).standardizedFileURL.path
        var best: URL?
        var bestLen = -1
        for root in roots {
            let rp = root.standardizedFileURL.path
            if (std == rp || std.hasPrefix(rp + "/")) && rp.count > bestLen {
                best = root
                bestLen = rp.count
            }
        }
        return best
    }

}
