//
//  FileMover.swift
//  Muse
//
//  Moves user files into a destination folder. Roots are already held under
//  read-write security scope by BookmarkStore for the app's lifetime, so no
//  per-move start/stop access is needed — a move just needs the source and
//  destination to live under active roots. Returns the URLs that failed (name
//  collision or permission/IO error) so the caller can report them.
//

import Foundation

enum FileMover {
    /// Move `urls` into `destination`. Returns the URLs that could not be moved.
    @discardableResult
    static func move(_ urls: [URL], into destination: URL) -> [URL] {
        var failed: [URL] = []
        for url in urls {
            let target = destination.appendingPathComponent(url.lastPathComponent)
            // Already in this folder — nothing to do.
            if target.standardizedFileURL == url.standardizedFileURL { continue }
            do {
                if FileManager.default.fileExists(atPath: target.path) {
                    failed.append(url)   // name collision — don't overwrite
                    continue
                }
                try FileManager.default.moveItem(at: url, to: target)
            } catch {
                failed.append(url)
            }
        }
        return failed
    }

    /// Rename `url` in place (same parent, new last component). Returns the new
    /// URL on success (or the unchanged URL for a same-name no-op), and `nil` on
    /// failure. A case-only change (Photo.jpg -> photo.jpg) is allowed, not
    /// treated as a self-collision. Refuses a collision with a DIFFERENT existing
    /// item (never overwrites) and reports any IO/permission failure as nil. This
    /// is the ONLY sanctioned FileManager.moveItem for a rename — orchestration
    /// goes through AppState.renameFile so the DB migration always runs.
    static func rename(_ url: URL, to newName: String) -> URL? {
        let target = url.deletingLastPathComponent().appendingPathComponent(newName)
        if target.standardizedFileURL == url.standardizedFileURL { return url }
        let caseOnly = target.standardizedFileURL.path.lowercased()
            == url.standardizedFileURL.path.lowercased()
        if !caseOnly && FileManager.default.fileExists(atPath: target.path) {
            return nil   // collision — don't overwrite
        }
        do {
            try FileManager.default.moveItem(at: url, to: target)
            return target
        } catch {
            NSLog("[Muse] file rename failed %@ -> %@: %@",
                  url.path, target.path, String(describing: error))
            return nil
        }
    }
}
