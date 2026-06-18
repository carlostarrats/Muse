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
}
