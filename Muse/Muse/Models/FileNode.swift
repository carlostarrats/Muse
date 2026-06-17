//
//  FileNode.swift
//  Muse
//
//  Value type representing a file enumerated from disk. Phase 0.5 uses
//  this as the in-memory grid model — no DB row required at the
//  `enumerated` lifecycle stage.
//

import Foundation

nonisolated struct FileNode: Identifiable, Hashable {
    let id: UUID
    let url: URL
    let basename: String
    let kind: AssetKind
    let isDirectory: Bool
    let sizeBytes: Int64?
    let modifiedAt: Date?
    let createdAt: Date?

    init(url: URL) {
        self.init(url: url, kind: AssetKind.detect(at: url))
    }

    /// Fast init for enumeration: the caller (FolderReader / enumerateRecursive)
    /// already knows the entry is a file, not a plain directory, so it can pass a
    /// `kind` computed by `AssetKind.classify` — which skips the per-file
    /// `fileExists` stat syscall that `AssetKind.detect` does just to re-check
    /// "is this a directory". On a large folder that's one saved syscall per file.
    /// The resourceValues below hit the values already prefetched by
    /// `contentsOfDirectory`, so they don't touch the disk again.
    init(url: URL, kind: AssetKind) {
        self.id = UUID()
        self.url = url
        self.basename = url.lastPathComponent
        self.kind = kind
        let values = try? url.resourceValues(forKeys: [
            .isDirectoryKey,
            .fileSizeKey,
            .contentModificationDateKey,
            .creationDateKey
        ])
        self.isDirectory = values?.isDirectory ?? false
        self.sizeBytes = (values?.fileSize).map(Int64.init)
        self.modifiedAt = values?.contentModificationDate
        self.createdAt = values?.creationDate
    }
}
