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

    /// Escape LIKE metacharacters so a user query is matched literally.
    private static func likeEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
         .replacingOccurrences(of: "%", with: "\\%")
         .replacingOccurrences(of: "_", with: "\\_")
    }
}
