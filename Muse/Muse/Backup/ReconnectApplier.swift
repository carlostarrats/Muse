//
//  ReconnectApplier.swift
//  Muse
//
//  Writes backup metadata onto the rows the indexer already created (joined by
//  content hash / disk path), then materializes collections + stars. The live
//  library only ever gains REAL, reconnected files — never ghosts.
//

import Foundation
import GRDB

enum ReconnectApplier {
    /// content_hash -> files.id for every hashed file currently in the DB.
    static func currentFileIDForHash(queue: DatabaseQueue) async throws -> [String: String] {
        try await queue.read { db in
            var map: [String: String] = [:]
            for f in try FileRow.fetchAll(db) where f.content_hash != nil {
                map[f.content_hash!] = f.id
            }
            return map
        }
    }

    static func applyMeta(matches: [OccurrenceMatch], file: BackupFile,
                          queue: DatabaseQueue) async throws {
        for m in matches {
            let url = URL(fileURLWithPath: m.diskPath)
            let parentDir = url.deletingLastPathComponent().path
            let basename = url.lastPathComponent
            try await queue.write { db in
                guard let path = try PathRow
                        .filter(PathRow.Columns.absolute_path == m.diskPath)
                        .filter(PathRow.Columns.is_alive == 1).fetchOne(db),
                      let fid = path.file_id,
                      var fileRow = try FileRow.filter(FileRow.Columns.id == fid).fetchOne(db)
                else { return }
                file.meta.apply(onto: &fileRow)
                try fileRow.update(db)
                // Tags: occurrence's tags at the NEW parent_dir (manual beats vision).
                for t in tagRows(from: m.occurrence.tags, fileID: fid, parentDir: parentDir) {
                    if let existing = try TagRow
                        .filter(TagRow.Columns.file_id == fid)
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
                // FTS mirror (basename + caption; OCR intentionally empty — same as hydrate).
                try db.execute(sql: "DELETE FROM files_fts WHERE file_id = ?", arguments: [fid])
                try db.execute(sql: """
                    INSERT INTO files_fts(file_id, basename, ocr_text, caption)
                    VALUES (?, ?, ?, ?)
                    """, arguments: [fid, basename, "", file.meta.caption ?? ""])
            }
        }
    }

    private static func tagRows(from tags: [SidecarTag], fileID: String,
                                parentDir: String) -> [TagRow] {
        tags.map {
            TagRow(id: UUID().uuidString, file_id: fileID, parent_dir: parentDir,
                   label: $0.label, source: $0.source, confidence: $0.confidence,
                   model_version: $0.model_version)
        }
    }

    static func applyCollections(_ archive: BackupArchive, fileIDForHash: [String: String],
                                 queue: DatabaseQueue) async throws {
        let materialized = CollectionMaterializer.materialize(archive.collections,
                                                              fileIDForHash: fileIDForHash)
        let now = Int64(Date().timeIntervalSince1970)
        try await queue.write { db in
            for c in materialized {
                try db.execute(sql: """
                    INSERT INTO collections (id, name, is_hidden, model_version, created_at, updated_at, cover_file_id, sort_order, icon, color)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET name = excluded.name,
                        is_hidden = excluded.is_hidden, model_version = excluded.model_version,
                        cover_file_id = excluded.cover_file_id, sort_order = excluded.sort_order,
                        icon = excluded.icon, color = excluded.color,
                        updated_at = excluded.updated_at
                    """, arguments: [c.id, c.name, c.isHidden, c.modelVersion, now, now,
                                     c.coverFileID, c.sortOrder, c.icon, c.color])
                try db.execute(sql: "DELETE FROM collection_members WHERE collection_id = ?",
                               arguments: [c.id])
                for m in c.memberFileIDs {
                    try db.execute(sql: """
                        INSERT OR IGNORE INTO collection_members (collection_id, file_id, added_by)
                        VALUES (?, ?, ?)
                        """, arguments: [c.id, m.fileID, m.addedBy])
                }
                try db.execute(sql: "DELETE FROM collection_exclusions WHERE collection_id = ?",
                               arguments: [c.id])
                for ex in c.excludedFileIDs {
                    try db.execute(sql: """
                        INSERT OR IGNORE INTO collection_exclusions (collection_id, file_id)
                        VALUES (?, ?)
                        """, arguments: [c.id, ex])
                }
            }
        }
    }

    static func applyStars(_ archive: BackupArchive, queue: DatabaseQueue) async throws {
        let fm = FileManager.default
        try await queue.write { db in
            for s in archive.stars where fm.fileExists(atPath: s.path) {
                try db.execute(sql: """
                    INSERT OR IGNORE INTO starred_folders (id, absolute_path, display_name, added_at)
                    VALUES (?, ?, ?, ?)
                    """, arguments: [UUID().uuidString, s.path, s.display_name,
                                     Int64(Date().timeIntervalSince1970)])
            }
        }
    }
}
