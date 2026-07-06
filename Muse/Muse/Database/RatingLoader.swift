//
//  RatingLoader.swift
//  Muse
//
//  Per-file star rating for the tiles in view: standardized path -> star count
//  (1...5), scoped per (file_id, parent_dir) exactly like tags, so a duplicate's
//  rating in another folder never surfaces here. Modeled on TagChipLoader
//  (chunked IN lists, off-main). The result drives the top-right tile badge.
//

import Foundation
import GRDB

nonisolated enum RatingLoader {

    /// Standardized-path -> star count for the given files. `simpleFolderDir`
    /// non-nil selects the single-folder fast path (one constant parent_dir);
    /// nil uses the general per-file-scope path. Synchronous — call off-main.
    static func ratings(paths: [String], simpleFolderDir: String?,
                        queue: DatabaseQueue) -> [String: Int] {
        guard !paths.isEmpty else { return [:] }
        if let dir = simpleFolderDir {
            return fast(paths: paths, parentDir: dir, queue: queue)
        }
        return general(paths: paths, queue: queue)
    }

    /// One constant parent_dir: join paths->tags in a single GROUP-free scan,
    /// keep the max rating label per path (mutual exclusion means there is only
    /// one, but max is defensive).
    private static func fast(paths: [String], parentDir: String,
                             queue: DatabaseQueue) -> [String: Int] {
        (try? queue.read { db -> [String: Int] in
            var out: [String: Int] = [:]
            for start in stride(from: 0, to: paths.count, by: 800) {
                let chunk = Array(paths[start..<min(start + 800, paths.count)])
                let marks = databaseQuestionMarks(count: chunk.count)
                let rows = try Row.fetchAll(db, sql: """
                    SELECT p.absolute_path AS path, t.label AS label
                    FROM paths p JOIN tags t ON t.file_id = p.file_id
                    WHERE p.is_alive = 1 AND t.parent_dir = ? AND p.absolute_path IN (\(marks))
                    """, arguments: StatementArguments([parentDir] + chunk))
                for r in rows {
                    guard let path: String = r["path"], let label: String = r["label"],
                          let n = StarRating.rating(from: label) else { continue }
                    out[path] = max(out[path] ?? 0, n)
                }
            }
            return out
        }) ?? [:]
    }

    /// Collections / recursive listings: parent_dir varies per file, so scope
    /// each (file_id, parent_dir) individually.
    private static func general(paths: [String], queue: DatabaseQueue) -> [String: Int] {
        var out: [String: Int] = [:]
        for start in stride(from: 0, to: paths.count, by: 500) {
            let chunk = Array(paths[start..<min(start + 500, paths.count)])
            let partial: [String: Int] = (try? queue.read { db -> [String: Int] in
                let marks = databaseQuestionMarks(count: chunk.count)
                let pathRows = try Row.fetchAll(db, sql: """
                    SELECT file_id, absolute_path FROM paths
                    WHERE is_alive = 1 AND file_id IS NOT NULL AND absolute_path IN (\(marks))
                    """, arguments: StatementArguments(chunk))
                // file_id -> [(path, dir)] so we can attribute a scoped rating.
                var byFile: [String: [(path: String, dir: String)]] = [:]
                var fileIDs = Set<String>()
                for r in pathRows {
                    guard let fid: String = r["file_id"],
                          let p: String = r["absolute_path"] else { continue }
                    fileIDs.insert(fid)
                    byFile[fid, default: []].append((p, TagScope.parentDir(ofPath: p)))
                }
                guard !fileIDs.isEmpty else { return [:] }
                let fmarks = databaseQuestionMarks(count: fileIDs.count)
                let tagRows = try Row.fetchAll(db, sql: """
                    SELECT label, file_id, parent_dir FROM tags WHERE file_id IN (\(fmarks))
                    """, arguments: StatementArguments(Array(fileIDs)))
                var result: [String: Int] = [:]
                for tr in tagRows {
                    guard let label: String = tr["label"],
                          let fid: String = tr["file_id"],
                          let dir: String = tr["parent_dir"],
                          let n = StarRating.rating(from: label) else { continue }
                    for entry in byFile[fid] ?? [] where entry.dir == dir {
                        result[entry.path] = max(result[entry.path] ?? 0, n)
                    }
                }
                return result
            }) ?? [:]
            for (k, v) in partial { out[k] = max(out[k] ?? 0, v) }
        }
        return out
    }
}
