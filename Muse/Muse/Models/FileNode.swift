//
//  FileNode.swift
//  Muse
//
//  Value type representing a file enumerated from disk. Phase 0.5 uses
//  this as the in-memory grid model — no DB row required at the
//  `enumerated` lifecycle stage.
//

import Foundation

struct FileNode: Identifiable, Hashable {
    let id: UUID
    let url: URL
    let basename: String
    let kind: AssetKind
    let isDirectory: Bool
    let sizeBytes: Int64?
    let modifiedAt: Date?
    let createdAt: Date?

    init(url: URL) {
        self.id = UUID()
        self.url = url
        self.basename = url.lastPathComponent
        self.kind = AssetKind.detect(at: url)
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
