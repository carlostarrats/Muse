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
}
