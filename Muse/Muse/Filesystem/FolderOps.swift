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
    // `ioError` carries the OS failure reason for display; `parentNotWritable`
    // is the sandbox case — renaming a top-level (root) folder writes to its
    // PARENT directory, which a folder's own security-scoped bookmark doesn't
    // cover, so the caller must obtain a one-time grant on the parent and retry.
    enum OpError: Error, Equatable { case emptyName, invalidName, collision, ioError(String), parentNotWritable }

    /// True when a FileManager error is the OS denying the write for permission
    /// reasons (sandbox or POSIX). This is the reliable signal that a root rename
    /// needs a parent-folder grant: `isWritableFile` can report a parent as
    /// POSIX-writable (e.g. the home directory) even when the sandbox will still
    /// deny the move, so we also inspect the Cocoa code and the underlying POSIX
    /// EPERM/EACCES.
    static func isPermissionDenied(_ error: Error) -> Bool {
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain && ns.code == NSFileWriteNoPermissionError { return true }
        if ns.domain == NSPOSIXErrorDomain && (ns.code == Int(EPERM) || ns.code == Int(EACCES)) { return true }
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError,
           underlying.domain == NSPOSIXErrorDomain,
           underlying.code == Int(EPERM) || underlying.code == Int(EACCES) { return true }
        return false
    }

    /// Trim and validate a proposed folder name. Rejects empty names, path
    /// separators ("/" and ":" — the latter is the legacy HFS separator Finder
    /// also forbids), and the "." / ".." specials.
    static func sanitize(_ raw: String) -> Result<String, OpError> {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { return .failure(.emptyName) }
        if name.contains("/") || name.contains(":") { return .failure(.invalidName) }
        // A leading dot makes the folder hidden (and covers "." / ".."). The
        // sidebar loads with showHidden:false, so such a folder would be created
        // but never appear — reject it rather than silently vanish.
        if name.hasPrefix(".") { return .failure(.invalidName) }
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
            } catch {
                let writable = FileManager.default.isWritableFile(atPath: parent.path)
                NSLog("[Muse] createSubfolder failed at %@ (parent writable: %@): %@",
                      target.path, writable ? "true" : "false", String(describing: error))
                if !writable { return .failure(.parentNotWritable) }
                let ns = error as NSError
                return .failure(.ioError(ns.localizedFailureReason ?? ns.localizedDescription))
            }
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
            let targetPath = target.standardizedFileURL.path
            let folderPath = folder.standardizedFileURL.path
            if targetPath == folderPath {
                return .success(folder)   // no change
            }
            // A case-only rename ("Photos" → "photos") collides with itself on a
            // case-insensitive volume (the default). Allow it — moveItem performs
            // the case change — instead of rejecting it as a duplicate.
            let caseOnly = targetPath.lowercased() == folderPath.lowercased()
            if !caseOnly && FileManager.default.fileExists(atPath: target.path) {
                return .failure(.collision)
            }
            do {
                try FileManager.default.moveItem(at: folder, to: target)
                return .success(target)
            } catch {
                let writable = FileManager.default.isWritableFile(atPath: parent.path)
                NSLog("[Muse] rename failed %@ → %@ (parent writable: %@): %@",
                      folder.path, target.path, writable ? "true" : "false", String(describing: error))
                if !writable || isPermissionDenied(error) { return .failure(.parentNotWritable) }
                let ns = error as NSError
                return .failure(.ioError(ns.localizedFailureReason ?? ns.localizedDescription))
            }
        }
    }
}
