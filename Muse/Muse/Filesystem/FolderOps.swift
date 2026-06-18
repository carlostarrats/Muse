//
//  FolderOps.swift
//  Muse
//
//  Create / rename folders on disk. Roots already hold read-write security
//  scope for the app's lifetime (BookmarkStore), so operations inside them
//  need no per-op start/stop access. Pure validation + thin FileManager calls;
//  the DB migration that must accompany a rename lives in AppState (it needs
//  the database queue), keyed off a successful disk move here.
//

import Foundation

enum FolderOps {
    enum OpError: Error, Equatable { case emptyName, invalidName, collision, ioError }

    /// Trim and validate a proposed folder name. Rejects empty names, path
    /// separators ("/" and ":" — the latter is the legacy HFS separator Finder
    /// also forbids), and the "." / ".." specials.
    static func sanitize(_ raw: String) -> Result<String, OpError> {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { return .failure(.emptyName) }
        if name == "." || name == ".." { return .failure(.invalidName) }
        if name.contains("/") || name.contains(":") { return .failure(.invalidName) }
        return .success(name)
    }

    /// Create `name` as a subfolder of `parent`. Fails on a name collision
    /// (never overwrites) or an IO error.
    static func createSubfolder(named raw: String, in parent: URL) -> Result<URL, OpError> {
        switch sanitize(raw) {
        case .failure(let e): return .failure(e)
        case .success(let name):
            let target = parent.appendingPathComponent(name, isDirectory: true)
            if FileManager.default.fileExists(atPath: target.path) { return .failure(.collision) }
            do {
                try FileManager.default.createDirectory(
                    at: target, withIntermediateDirectories: false)
                return .success(target)
            } catch { return .failure(.ioError) }
        }
    }

    /// Rename `folder` in place (same parent, new last component). Renaming to
    /// the current name is a no-op success. Fails on a collision with a
    /// different existing item, or an IO error (e.g. a protected system folder).
    static func rename(_ folder: URL, to raw: String) -> Result<URL, OpError> {
        switch sanitize(raw) {
        case .failure(let e): return .failure(e)
        case .success(let name):
            let parent = folder.deletingLastPathComponent()
            let target = parent.appendingPathComponent(name, isDirectory: true)
            // Compare by resolved path: `target` is built with isDirectory:true
            // (trailing slash), so a raw URL equality would miss the no-op case.
            if target.standardizedFileURL.path == folder.standardizedFileURL.path {
                return .success(folder)   // no change
            }
            if FileManager.default.fileExists(atPath: target.path) { return .failure(.collision) }
            do {
                try FileManager.default.moveItem(at: folder, to: target)
                return .success(target)
            } catch { return .failure(.ioError) }
        }
    }
}
