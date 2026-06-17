//
//  TagScope.swift
//  Muse
//
//  Tags belong to a file IN A FOLDER, not to the file's content alone.
//  A tag's identity is (file_id, parent_dir): the same content in a
//  different folder is a different image with its own tags. The single
//  source of truth for deriving that parent-folder key — used by the
//  schema migration, TagStore, and the analyze pipeline so they always
//  agree byte-for-byte.
//
//  parent_dir is derived from the standardized absolute path, exactly as
//  paths.absolute_path is stored, so a URL and a stored path resolve to
//  the same folder key.
//

import Foundation

enum TagScope {
    /// Parent-directory key for an already-standardized absolute path
    /// (e.g. a stored `paths.absolute_path`).
    static func parentDir(ofPath path: String) -> String {
        (path as NSString).deletingLastPathComponent
    }

    /// Parent-directory key for a file URL.
    static func parentDir(of url: URL) -> String {
        parentDir(ofPath: url.standardizedFileURL.path)
    }
}
