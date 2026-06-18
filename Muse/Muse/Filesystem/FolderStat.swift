//
//  FolderStat.swift
//  Muse
//
//  Aggregate stats for a top-level sidebar folder — file counts (immediate +
//  recursive), recursive total size, recursive newest mtime. Pure + nonisolated
//  so it runs off the main thread. Counts mirror the grid's file notion (every
//  non-folder entry; packages count as files, not descended-as-folders), so the
//  sidebar number always matches what the grid would show.
//

import Foundation

nonisolated struct FolderStat: Equatable {
    var immediateFileCount: Int
    var recursiveFileCount: Int
    var totalSize: Int64
    var latestModified: Date?
}

nonisolated enum FolderStats {
    /// Walk `folder` and aggregate counts/size/latest-mtime. Immediate = depth-1
    /// non-folder entries; recursive = all non-folder entries beneath it.
    static func compute(folder: URL, showHidden: Bool = false) -> FolderStat {
        let fm = FileManager.default
        let opts: FileManager.DirectoryEnumerationOptions = showHidden ? [] : [.skipsHiddenFiles]

        var immediate = 0
        if let entries = try? fm.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey],
            options: opts
        ) {
            for url in entries where !isPlainDirectory(url) { immediate += 1 }
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
                          latestModified: latest)
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

    private static func isPlainDirectory(_ url: URL) -> Bool {
        let v = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
        return v?.isDirectory == true && v?.isPackage != true
    }
}
