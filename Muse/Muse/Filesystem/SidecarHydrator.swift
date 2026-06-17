//
//  SidecarHydrator.swift
//  Muse
//
//  On folder load, imports current `.muse/<hash>.json` sidecars into the
//  local SQLite (FileRow + tags + FTS + analyzed_hash) so the automatic
//  analysis pass skips already-described files. This is what lets an
//  iCloud-only / fresh device reconstruct the experience without re-running
//  Vision. Pure mapping lives in Sidecar; this is the thin DB writer.
//

import Foundation
import GRDB

enum SidecarHydrator {
    /// For each url in the iCloud zone, if a matching sidecar exists and is
    /// current (sidecar.analyzed_hash == the file's content_hash), apply it.
    static func hydrate(urls: [URL], folder: URL?) async {
        guard folder != nil, let queue = Database.shared.dbQueue else { return }
        for url in urls {
            guard ICloudZone.contains(url, folder: folder) else { continue }
            let absPath = url.standardizedFileURL.path
            // Resolve the file id + current content hash.
            let info: (id: String, hash: String)? = try? await queue.read { db -> (id: String, hash: String)? in
                guard let path = try PathRow
                        .filter(PathRow.Columns.absolute_path == absPath)
                        .filter(PathRow.Columns.is_alive == 1).fetchOne(db),
                      let fid = path.file_id,
                      let file = try FileRow.filter(FileRow.Columns.id == fid).fetchOne(db),
                      let hash = file.content_hash else { return nil }
                // Already analyzed at this content — nothing to import.
                if file.analyzed_hash == hash { return nil }
                return (fid, hash)
            } ?? nil
            guard let info else { continue }
            guard let sidecar = SidecarStore.read(forAsset: url, contentHash: info.hash),
                  sidecar.analyzed_hash == info.hash else { continue }
            await apply(sidecar, fileID: info.id, parentDir: TagScope.parentDir(of: url),
                        basename: url.lastPathComponent, queue: queue)
        }
    }

    private static func apply(_ sidecar: Sidecar, fileID: String, parentDir: String,
                              basename: String, queue: DatabaseQueue) async {
        try? await queue.write { db in
            if var file = try FileRow.filter(FileRow.Columns.id == fileID).fetchOne(db) {
                sidecar.apply(onto: &file)
                try file.update(db)
            }
            // Tags: insert sidecar tags scoped to this folder, honoring
            // manual-beats-vision (Q32) per (file_id, parent_dir).
            for t in sidecar.tagRows(fileID: fileID, parentDir: parentDir, makeID: { UUID().uuidString }) {
                if let existing = try TagRow
                    .filter(TagRow.Columns.file_id == fileID)
                    .filter(TagRow.Columns.parent_dir == parentDir)
                    .filter(TagRow.Columns.label == t.label).fetchOne(db) {
                    if existing.source != "manual" && t.source == "manual" {
                        var u = existing; u.source = "manual"; u.confidence = nil
                        u.model_version = nil; try u.update(db)
                    }
                } else {
                    var row = t; try row.insert(db)
                }
            }
            // FTS5 — mirror AnalyzePipeline's keying.
            try db.execute(sql: "DELETE FROM files_fts WHERE file_id = ?", arguments: [fileID])
            try db.execute(sql: """
                INSERT INTO files_fts(file_id, basename, ocr_text, caption)
                VALUES (?, ?, ?, ?)
            """, arguments: [fileID, basename, "", sidecar.caption ?? ""])
        }
    }
}
