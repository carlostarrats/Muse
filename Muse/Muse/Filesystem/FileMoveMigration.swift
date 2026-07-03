//
//  FileMoveMigration.swift
//  Muse
//
//  DB follow-through for an in-app file move (context-menu "Move to Folder",
//  sidebar drag-drop). Unlike an EXTERNAL move — where the indexer can only
//  see "old path died, same content appeared elsewhere" and deliberately
//  inherits vision tags only — an in-app move is KNOWN to be a relocation of
//  the same file, so its manual tags follow it (same intent as
//  FolderRenameMigration carrying tags through a folder rename). Repoints the
//  alive path row and migrates the (file_id, parent_dir) tag rows in one
//  transaction, so the later reconcile pass sees an already-consistent DB.
//

import Foundation
import GRDB

enum FileMoveMigration {

    /// Apply the DB follow-through for files ALREADY moved on disk.
    /// `moves` are (source, destination) standardized absolute paths of the
    /// files that actually moved. Must be called inside a
    /// `queue.write { db in … }` block. Files with no alive DB row (never
    /// indexed) are skipped — the normal index pass will pick them up fresh.
    static func apply(_ db: GRDB.Database, moves: [(from: String, to: String)]) throws {
        for move in moves where move.from != move.to {
            // The disk move succeeded, so nothing exists at the destination —
            // any ALIVE row there is a stale leftover of a previously-deleted
            // file. Kill it first or the repoint below trips
            // paths_alive_unique and rolls back the whole transaction.
            try db.execute(sql: """
                UPDATE paths SET is_alive = 0 WHERE is_alive = 1 AND absolute_path = ?
                """, arguments: [move.to])

            guard let row = try PathRow
                .filter(PathRow.Columns.absolute_path == move.from)
                .filter(PathRow.Columns.is_alive == 1)
                .fetchOne(db),
                  let fid = row.file_id else { continue }

            var repointed = row
            repointed.absolute_path = move.to
            try repointed.update(db)

            let oldDir = TagScope.parentDir(ofPath: move.from)
            let newDir = TagScope.parentDir(ofPath: move.to)
            guard oldDir != newDir else { continue }

            // Tags are keyed (file_id, parent_dir). If another alive path of
            // this identity remains in the SOURCE folder (a byte-identical
            // sibling), the (fid, oldDir) rows are shared with it — COPY them
            // to the destination scope. Otherwise MOVE (no sibling surfaces
            // them anymore). Same sibling rule as Indexer's split/collision
            // branches.
            let keepsSiblingInOldDir = try PathRow
                .filter(PathRow.Columns.file_id == fid)
                .filter(PathRow.Columns.is_alive == 1)
                .filter(PathRow.Columns.absolute_path != move.to)
                .fetchAll(db)
                .contains { TagScope.parentDir(ofPath: $0.absolute_path) == oldDir }
            try migrateTags(db, fileID: fid, from: oldDir, to: newDir,
                            deleteOriginals: !keepsSiblingInOldDir)
        }
    }

    /// Re-scope one identity's tag rows from `oldDir` to `newDir`, honoring
    /// UNIQUE(file_id, parent_dir, label) and manual-beats-vision on conflict
    /// (the destination folder may already hold tag rows for this identity —
    /// a byte-identical copy living there).
    private static func migrateTags(_ db: GRDB.Database, fileID: String,
                                    from oldDir: String, to newDir: String,
                                    deleteOriginals: Bool) throws {
        let fromTags = try TagRow
            .filter(TagRow.Columns.file_id == fileID)
            .filter(TagRow.Columns.parent_dir == oldDir)
            .fetchAll(db)
        for var t in fromTags {
            if let existing = try TagRow
                .filter(TagRow.Columns.file_id == fileID)
                .filter(TagRow.Columns.parent_dir == newDir)
                .filter(TagRow.Columns.label == t.label)
                .fetchOne(db) {
                if t.source == "manual" && existing.source != "manual" {
                    var updated = existing
                    updated.source = "manual"
                    updated.confidence = nil
                    updated.model_version = nil
                    try updated.update(db)
                }
                // Else keep the destination's row.
            } else {
                t.id = UUID().uuidString
                t.parent_dir = newDir
                try t.insert(db)
            }
        }
        if deleteOriginals {
            try TagRow
                .filter(TagRow.Columns.file_id == fileID)
                .filter(TagRow.Columns.parent_dir == oldDir)
                .deleteAll(db)
        }
    }
}
