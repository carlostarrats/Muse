//
//  FolderTree.swift
//  Muse
//
//  Lazy hierarchical view of disk folders. Each node is a folder; its
//  children are loaded on demand. Honors Q33 indexer policies:
//  symlinks followed once, opaque bundles not descended, hidden files
//  skipped (toggle TBD in Phase 6).
//

import Foundation

@MainActor
final class FolderNode: ObservableObject, Identifiable {
    let id: UUID
    let url: URL
    let displayName: String
    let isRoot: Bool

    @Published var children: [FolderNode] = []
    @Published var isLoaded: Bool = false
    @Published var isExpanded: Bool = false

    init(url: URL, displayName: String? = nil, isRoot: Bool = false) {
        self.id = UUID()
        self.url = url
        self.displayName = displayName ?? url.lastPathComponent
        self.isRoot = isRoot
    }

    /// Loads immediate folder children once. Idempotent.
    func loadChildrenIfNeeded(showHidden: Bool = false) {
        guard !isLoaded else { return }
        isLoaded = true
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey, .isHiddenKey],
            options: showHidden ? [] : [.skipsHiddenFiles]
        ) else { return }

        let folders = entries.compactMap { childURL -> FolderNode? in
            let values = try? childURL.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
            guard values?.isDirectory == true, values?.isPackage != true else { return nil }
            return FolderNode(url: childURL)
        }
        .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }

        children = folders
    }
}

/// Reads files (non-folder entries) inside a single folder. Used by the grid.
enum FolderReader {
    static func files(in url: URL, showHidden: Bool = false) -> [FileNode] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [
                .isDirectoryKey, .isPackageKey, .fileSizeKey,
                .contentModificationDateKey, .creationDateKey
            ],
            options: showHidden ? [] : [.skipsHiddenFiles]
        ) else { return [] }

        // Q33: include opaque bundles as files (don't descend into them).
        let nodes = entries.compactMap { url -> FileNode? in
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
            let isDir = values?.isDirectory == true
            let isPackage = values?.isPackage == true
            // Skip plain directories; treat packages (like .app) as files.
            if isDir && !isPackage { return nil }
            return FileNode(url: url)
        }
        return nodes.sorted { lhs, rhs in
            // Default sort: date modified desc (generalist persona, Q24).
            let l = lhs.modifiedAt ?? .distantPast
            let r = rhs.modifiedAt ?? .distantPast
            return l > r
        }
    }
}
