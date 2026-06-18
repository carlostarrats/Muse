//
//  FolderRenameMigration.swift
//  Muse
//
//  Pure path-prefix rewrite for a folder rename. When a folder is renamed,
//  every stored absolute path under it (paths.absolute_path) and every tag
//  parent-dir key equal to it or under it (tags.parent_dir) must follow.
//  Factored out so the prefix rule is unit-tested independent of SQLite; the
//  GRDB UPDATEs in AppState apply the identical rule in SQL.
//

import Foundation
import GRDB

enum FolderRenameMigration {
    /// New path for `path` when its folder `old` is renamed to `new`.
    /// Returns the rewritten path if `path == old` or lives under `old/`,
    /// otherwise nil (no match — leave the row untouched). A sibling like
    /// "/a/OldStuff" is never matched by old "/a/Old".
    static func rewrite(path: String, old: String, new: String) -> String? {
        if path == old { return new }
        let prefix = old.hasSuffix("/") ? old : old + "/"
        guard path.hasPrefix(prefix) else { return nil }
        return new + String(path.dropFirst(old.count))
    }

    /// Apply the rename prefix-rewrite to EVERY path-keyed table in one
    /// transaction: `paths.absolute_path`, `tags.parent_dir`, and
    /// `starred_folders` (its path + the renamed folder's own display name).
    /// file_id-keyed data (files, collections, FTS, embeddings) is unaffected —
    /// it resolves through `paths`, so rewriting `paths` is enough. Must be
    /// called inside a `queue.write { db in ... }` block. `newName` is the new
    /// last path component (used only for the renamed folder's own pin label).
    ///
    /// The prefix match uses `SUBSTR(col,1,LENGTH(:old)+1) = :old || '/'` (plus
    /// an exact `= :old` branch), NOT `LIKE`, so "%"/"_" in paths can't break it
    /// and a sibling like "…/OldStuff" is never caught by old "…/Old".
    static func apply(_ db: GRDB.Database, old: String, new: String, newName: String) throws {
        // The destination did NOT exist on disk before this rename (FolderOps
        // refuses a name collision), so any DB rows already under the NEW prefix
        // are stale leftovers from a previously-deleted folder. Clear them first
        // so the rewrites below can't hit a UNIQUE collision and roll back the
        // whole (paths + tags) transaction: starred_folders.absolute_path is
        // UNIQUE and pins are never auto-pruned, and paths has an alive-path
        // unique index. Binary collation means a case-only rename's source rows
        // (different case) are not matched here.
        try db.execute(sql: """
            DELETE FROM starred_folders
            WHERE absolute_path = ?
               OR SUBSTR(absolute_path, 1, LENGTH(?) + 1) = ? || '/'
            """, arguments: [new, new, new])
        try db.execute(sql: """
            UPDATE paths SET is_alive = 0
            WHERE is_alive = 1
              AND (absolute_path = ? OR SUBSTR(absolute_path, 1, LENGTH(?) + 1) = ? || '/')
            """, arguments: [new, new, new])

        try db.execute(sql: """
            UPDATE paths
            SET absolute_path = ? || SUBSTR(absolute_path, LENGTH(?) + 1)
            WHERE absolute_path = ?
               OR SUBSTR(absolute_path, 1, LENGTH(?) + 1) = ? || '/'
            """, arguments: [new, old, old, old, old])
        try db.execute(sql: """
            UPDATE tags
            SET parent_dir = ? || SUBSTR(parent_dir, LENGTH(?) + 1)
            WHERE parent_dir = ?
               OR SUBSTR(parent_dir, 1, LENGTH(?) + 1) = ? || '/'
            """, arguments: [new, old, old, old, old])
        // SET expressions read the OLD row value, so the CASE matches the
        // renamed folder's own pin and relabels it; nested pins keep their name.
        try db.execute(sql: """
            UPDATE starred_folders
            SET absolute_path = ? || SUBSTR(absolute_path, LENGTH(?) + 1),
                display_name = CASE WHEN absolute_path = ? THEN ? ELSE display_name END
            WHERE absolute_path = ?
               OR SUBSTR(absolute_path, 1, LENGTH(?) + 1) = ? || '/'
            """, arguments: [new, old, old, newName, old, old, old])
    }
}
