//
//  EditRecordStore.swift
//  Muse
//
//  Pure DB read/write for the edits + edit_versions tables — the `NoteStore`
//  shape: free `nonisolated` statics taking a GRDB `Database`, so they run
//  inside any read/write closure and unit-test against an in-memory queue.
//  The @MainActor seam the UI calls is `EditStore`.
//
//  An edit stack belongs to a file IN A FOLDER, exactly like a tag or a note,
//  so every one of these takes (fileID, parentDir) and every identity/folder
//  rewrite has to carry it — see `carry`/`carryAll` and their five call sites.
//

import Foundation
import GRDB

nonisolated enum EditRecordStore {

    // MARK: - Current stack

    static func read(fileID: String, parentDir: String,
                     db: GRDB.Database) throws -> EditRow? {
        try EditRow.fetchOne(db, sql:
            "SELECT * FROM edits WHERE file_id = ? AND parent_dir = ?",
            arguments: [fileID, parentDir])
    }

    /// Every alive-path row that carries an edit, joined to its path — the
    /// bulk load `EditStore.rebuildIndex` turns into the provider index.
    /// One query, no per-file I/O: the provider must never touch the disk.
    static func allWithAlivePaths(db: GRDB.Database)
    throws -> [(path: String, stackJSON: String, hash: String)] {
        try Row.fetchAll(db, sql: """
            SELECT p.absolute_path AS path, e.parent_dir AS dir,
                   e.stack AS stack, e.stack_hash AS hash
            FROM edits e
            JOIN paths p ON p.file_id = e.file_id AND p.is_alive = 1
            """).compactMap { row in
            guard let path: String = row["path"], let dir: String = row["dir"],
                  let stack: String = row["stack"], let hash: String = row["hash"]
            else { return nil }
            // A file can be alive at several paths; the edit belongs to the
            // one in ITS folder. Without this filter a stack applied to the
            // copy in /A would render the untouched copy in /B too.
            guard TagScope.parentDir(ofPath: path) == dir else { return nil }
            return (path, stack, hash)
        }
    }

    /// Upsert the CURRENT stack. Callers must delete instead of writing a
    /// neutral stack (`EditStore.save` owns that branch) — this function
    /// deliberately doesn't second-guess the blob it's handed, because a
    /// blob whose schema this build can't decode must still round-trip.
    static func write(stackJSON: String, hash: String, processVersion: Int,
                      fileID: String, parentDir: String, updatedAt: Int64,
                      db: GRDB.Database) throws {
        try db.execute(sql: """
            INSERT INTO edits (file_id, parent_dir, stack, stack_hash, process_version, updated_at)
            VALUES (?, ?, ?, ?, ?, ?)
            ON CONFLICT(file_id, parent_dir) DO UPDATE SET
                stack = excluded.stack, stack_hash = excluded.stack_hash,
                process_version = excluded.process_version,
                updated_at = excluded.updated_at
            """, arguments: [fileID, parentDir, stackJSON, hash, processVersion, updatedAt])
    }

    static func delete(fileID: String, parentDir: String, db: GRDB.Database) throws {
        try db.execute(sql: "DELETE FROM edits WHERE file_id = ? AND parent_dir = ?",
                       arguments: [fileID, parentDir])
    }

    /// Apply an edit arriving from a synced sidecar / archive, last-writer-wins
    /// at the row level: a STRICTLY-newer local stack is kept, so a stale
    /// sidecar can't undo an edit the user just made on this device. Mirrors
    /// `NoteStore.applyHydrated`.
    ///
    /// A nil `json` is a synced RESET (the neutral stack, stored as absence).
    static func applyHydrated(json: String?, incomingUpdatedAt: Int64,
                              fileID: String, parentDir: String,
                              db: GRDB.Database) throws {
        let localUpdated = try Int64.fetchOne(db, sql:
            "SELECT updated_at FROM edits WHERE file_id = ? AND parent_dir = ?",
            arguments: [fileID, parentDir])
        if let localUpdated, localUpdated > incomingUpdatedAt { return }
        guard let json else {
            try delete(fileID: fileID, parentDir: parentDir, db: db)
            return
        }
        // The hash/process version are DERIVED from the blob, never trusted
        // from the wire. An undecodable blob still stores (it must round-trip
        // untouched), with a hash over its raw bytes so its thumbnail key is
        // at least stable and distinct from the unedited one.
        let decoded = EditStackCodec.decode(json)
        let hash = decoded.map(EditStackCodec.hash) ?? Self.rawHash(json)
        let processVersion = decoded?.processVersion ?? EditStack.currentProcessVersion
        try write(stackJSON: json, hash: hash, processVersion: processVersion,
                  fileID: fileID, parentDir: parentDir, updatedAt: incomingUpdatedAt, db: db)
    }

    // MARK: - Versions & snapshots

    static func versions(fileID: String, parentDir: String,
                         db: GRDB.Database) throws -> [EditVersionRow] {
        try EditVersionRow.fetchAll(db, sql: """
            SELECT * FROM edit_versions
            WHERE file_id = ? AND parent_dir = ? ORDER BY created_at
            """, arguments: [fileID, parentDir])
    }

    /// alive path → how many versions/snapshots that scope holds. Drives the
    /// grid badge's count suffix; same per-folder filter as
    /// `allWithAlivePaths` for the same reason.
    static func versionCounts(db: GRDB.Database) throws -> [String: Int] {
        var out: [String: Int] = [:]
        for row in try Row.fetchAll(db, sql: """
            SELECT p.absolute_path AS path, v.parent_dir AS dir, COUNT(*) AS n
            FROM edit_versions v
            JOIN paths p ON p.file_id = v.file_id AND p.is_alive = 1
            GROUP BY p.absolute_path, v.parent_dir
            """) {
            guard let path: String = row["path"], let dir: String = row["dir"],
                  let n: Int = row["n"], TagScope.parentDir(ofPath: path) == dir
            else { continue }
            out[path, default: 0] += n
        }
        return out
    }

    static func addVersion(_ row: EditVersionRow, db: GRDB.Database) throws {
        var row = row
        try row.insert(db)
    }

    static func deleteVersion(id: String, db: GRDB.Database) throws {
        try db.execute(sql: "DELETE FROM edit_versions WHERE id = ?", arguments: [id])
    }

    // MARK: - Carry (the five identity/folder rewrite seams)

    /// Carry an edit + its versions from one (file_id, parent_dir) scope to
    /// another, mirroring how tags and notes follow a relocation. COPY when
    /// `deleteOriginal` is false (a byte-identical sibling keeps the source's
    /// edit), MOVE when true. Never clobbers a destination edit — INSERT OR
    /// IGNORE, so a copy already living at the target keeps its own stack.
    ///
    /// Carried `edit_versions` rows get FRESH UUIDs: the id is the table's PK,
    /// so reusing it would silently drop every version after the first when
    /// two scopes merge.
    static func carry(fromFileID: String, fromDir: String,
                      toFileID: String, toDir: String,
                      deleteOriginal: Bool, db: GRDB.Database) throws {
        try db.execute(sql: """
            INSERT OR IGNORE INTO edits
                (file_id, parent_dir, stack, stack_hash, process_version, updated_at)
            SELECT ?, ?, stack, stack_hash, process_version, updated_at FROM edits
            WHERE file_id = ? AND parent_dir = ?
            """, arguments: [toFileID, toDir, fromFileID, fromDir])
        for v in try versions(fileID: fromFileID, parentDir: fromDir, db: db) {
            try db.execute(sql: """
                INSERT OR IGNORE INTO edit_versions
                    (id, file_id, parent_dir, kind, name, stack, created_at)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """, arguments: [UUID().uuidString, toFileID, toDir,
                                 v.kind, v.name, v.stack, v.created_at])
        }
        if deleteOriginal {
            try delete(fileID: fromFileID, parentDir: fromDir, db: db)
            try db.execute(sql: "DELETE FROM edit_versions WHERE file_id = ? AND parent_dir = ?",
                           arguments: [fromFileID, fromDir])
        }
    }

    /// MOVE every scope of one identity onto another (all parent_dirs), for
    /// the sole-alive-path collision where the old identity is done. Mirrors
    /// `NoteStore.carryAll`.
    static func carryAll(fromFileID: String, toFileID: String,
                         db: GRDB.Database) throws {
        let dirs = try String.fetchAll(db, sql:
            "SELECT parent_dir FROM edits WHERE file_id = ?", arguments: [fromFileID])
        for dir in dirs {
            try carry(fromFileID: fromFileID, fromDir: dir,
                      toFileID: toFileID, toDir: dir, deleteOriginal: true, db: db)
        }
        // Versions can exist in scopes the current stack no longer does (a
        // reset clears the stack but keeps its versions), so sweep them too.
        try db.execute(sql: """
            INSERT OR IGNORE INTO edit_versions
                (id, file_id, parent_dir, kind, name, stack, created_at)
            SELECT lower(hex(randomblob(16))), ?, parent_dir, kind, name, stack, created_at
            FROM edit_versions WHERE file_id = ?
            """, arguments: [toFileID, fromFileID])
        try db.execute(sql: "DELETE FROM edit_versions WHERE file_id = ?",
                       arguments: [fromFileID])
    }

    /// Rewrite `parent_dir` for a renamed folder, for both tables — the same
    /// stale-target pre-clear + SUBSTR-prefix UPDATE tags and notes get. The
    /// pre-clear matters because `edits`' PK is composite: a row already
    /// sitting at the new prefix would make the UPDATE a constraint violation
    /// and abort the whole rename transaction.
    ///
    /// The prefix match is `SUBSTR(col, 1, LENGTH(:old) + 1) = :old || '/'`
    /// (plus an exact branch), NOT `LIKE` — the same shape tags and notes use,
    /// so `%`/`_` in a real path can't break it and a sibling "…/OldStuff" is
    /// never caught by old "…/Old".
    static func rewriteParentDirPrefix(oldPrefix old: String, newPrefix new: String,
                                       db: GRDB.Database) throws {
        for table in ["edits", "edit_versions"] {
            try db.execute(sql: """
                DELETE FROM \(table)
                WHERE parent_dir = ?
                   OR SUBSTR(parent_dir, 1, LENGTH(?) + 1) = ? || '/'
                """, arguments: [new, new, new])
            try db.execute(sql: """
                UPDATE \(table)
                SET parent_dir = ? || SUBSTR(parent_dir, LENGTH(?) + 1)
                WHERE parent_dir = ?
                   OR SUBSTR(parent_dir, 1, LENGTH(?) + 1) = ? || '/'
                """, arguments: [new, old, old, old, old])
        }
    }

    private static func rawHash(_ json: String) -> String {
        EditStackCodec.hashOfRawBytes(json)
    }
}
