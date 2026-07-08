//
//  NoteStore.swift
//  Muse
//
//  Pure DB read/write/search for the notes table. A note belongs to a file IN
//  A FOLDER: identity is (file_id, parent_dir), exactly like tags. These are
//  free/`nonisolated` static functions taking a GRDB `Database` so they can run
//  inside any read/write closure and be unit-tested with an in-memory queue.
//  The @MainActor write seam the UI calls is `TagStore.setNote`.
//

import Foundation
import GRDB

nonisolated enum NoteStore {
    /// The note body for a (file_id, parent_dir), or nil if there is none.
    static func read(fileID: String, parentDir: String, db: GRDB.Database) throws -> String? {
        try String.fetchOne(db, sql:
            "SELECT body FROM notes WHERE file_id = ? AND parent_dir = ?",
            arguments: [fileID, parentDir])
    }

    /// Upsert the note for a (file_id, parent_dir). A blank/whitespace body
    /// DELETES the row ("no note" is the absence of a row, never an empty string).
    static func write(_ body: String, fileID: String, parentDir: String,
                      updatedAt: Int64, db: GRDB.Database) throws {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            try db.execute(sql: "DELETE FROM notes WHERE file_id = ? AND parent_dir = ?",
                           arguments: [fileID, parentDir])
            return
        }
        try db.execute(sql: """
            INSERT INTO notes (file_id, parent_dir, body, updated_at)
            VALUES (?, ?, ?, ?)
            ON CONFLICT(file_id, parent_dir) DO UPDATE SET
                body = excluded.body, updated_at = excluded.updated_at
            """, arguments: [fileID, parentDir, trimmed, updatedAt])
    }

    /// Apply a note arriving from a synced sidecar / archive, last-writer-wins at
    /// the row level: if a STRICTLY-newer local note exists (its `updated_at` >
    /// `incomingUpdatedAt`), keep it — an older sidecar's absence-of-note (or
    /// stale value) must never clobber a note the user just wrote on this device.
    /// Otherwise the incoming value wins (nil/empty deletes, mirroring `write`).
    static func applyHydrated(_ body: String?, fileID: String, parentDir: String,
                              incomingUpdatedAt: Int64, db: GRDB.Database) throws {
        let localUpdated = try Int64.fetchOne(db, sql:
            "SELECT updated_at FROM notes WHERE file_id = ? AND parent_dir = ?",
            arguments: [fileID, parentDir])
        if let localUpdated, localUpdated > incomingUpdatedAt { return }
        try write(body ?? "", fileID: fileID, parentDir: parentDir,
                  updatedAt: incomingUpdatedAt, db: db)
    }

    /// Distinct file_ids whose note body contains `term` (case-insensitive
    /// substring). Empty term → no matches. Mirrors the tag LIKE search path;
    /// notes are NOT in FTS (files_fts is keyed by the immutable files.id, which
    /// can't represent a per-(file_id, parent_dir) value).
    static func searchIDs(term: String, db: GRDB.Database) throws -> [String] {
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let pattern = "%" + likeEscape(trimmed) + "%"
        return try String.fetchAll(db, sql: """
            SELECT DISTINCT file_id FROM notes WHERE body LIKE ? ESCAPE '\\'
            """, arguments: [pattern])
    }

    /// Carry a note from one (file_id, parent_dir) identity/scope to another,
    /// mirroring how tags follow a relocation. Used by the three paths that
    /// rewrite a file's identity or folder key: the Indexer shared-row
    /// split/collision (fromFileID → toFileID, same dir) and an in-app move
    /// (same file_id, fromDir → toDir). COPY when `deleteOriginal` is false (a
    /// byte-identical sibling still surfaces the source note), MOVE when true.
    /// Never clobbers a note already at the destination — INSERT OR IGNORE, so a
    /// copy already living at the target keeps its own note.
    static func carry(fromFileID: String, fromDir: String,
                      toFileID: String, toDir: String,
                      deleteOriginal: Bool, db: GRDB.Database) throws {
        try db.execute(sql: """
            INSERT OR IGNORE INTO notes (file_id, parent_dir, body, updated_at)
            SELECT ?, ?, body, updated_at FROM notes
            WHERE file_id = ? AND parent_dir = ?
            """, arguments: [toFileID, toDir, fromFileID, fromDir])
        if deleteOriginal {
            try db.execute(sql: "DELETE FROM notes WHERE file_id = ? AND parent_dir = ?",
                           arguments: [fromFileID, fromDir])
        }
    }

    /// MOVE every note of one identity onto another (all parent_dirs), for the
    /// sole-alive-path collision where the old identity is done. Mirrors the
    /// unscoped `Indexer.unionTags` carry (which deletes its source rows), so the
    /// source notes don't linger orphaned after the union. Never clobbers a
    /// destination note (INSERT OR IGNORE), then drops the source rows.
    static func carryAll(fromFileID: String, toFileID: String, db: GRDB.Database) throws {
        try db.execute(sql: """
            INSERT OR IGNORE INTO notes (file_id, parent_dir, body, updated_at)
            SELECT ?, parent_dir, body, updated_at FROM notes WHERE file_id = ?
            """, arguments: [toFileID, fromFileID])
        try db.execute(sql: "DELETE FROM notes WHERE file_id = ?", arguments: [fromFileID])
    }

    /// Escape LIKE metacharacters so a user query is matched literally.
    private static func likeEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
         .replacingOccurrences(of: "%", with: "\\%")
         .replacingOccurrences(of: "_", with: "\\_")
    }
}
