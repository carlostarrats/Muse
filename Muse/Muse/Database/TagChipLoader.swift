//
//  TagChipLoader.swift
//  Muse
//
//  Single source of truth for the tag-chip labels shown above the grid: given
//  the files currently in view, returns each label with the number of those
//  files carrying it, scoped per-folder (tags belong to (file_id, parent_dir),
//  so a duplicate's tag in another folder never surfaces here).
//
//  The query LOGIC lives here, in one place. It's owned by AppState — computed
//  off the main thread as part of the folder load (so files + chips reveal in
//  one publish, no SwiftUI round-trip) and on collection / tag-edit changes.
//  The view (TagChipsRow) only renders the result.
//

import Foundation
import GRDB

nonisolated enum TagChipLoader {

    /// Per-label counts for the in-view files. `simpleFolderDir` non-nil selects
    /// the fast single-folder GROUP BY (one constant parent_dir); nil uses the
    /// general per-file-scope path (collections / recursive listings, where each
    /// file's parent_dir can differ). Synchronous — call it off the main thread.
    static func counts(paths: [String], simpleFolderDir: String?,
                       queue: DatabaseQueue) -> [String: Int] {
        guard !paths.isEmpty else { return [:] }
        if let dir = simpleFolderDir {
            return fast(paths: paths, parentDir: dir, queue: queue)
        }
        return general(paths: paths, queue: queue)
    }

    /// Ordered chips. `.count` = most-used first, alphabetical tiebreak (a
    /// stable order between reloads); `.alphabetical` = A→Z by label.
    static func ordered(_ counts: [String: Int],
                        sortMode: TagSortMode = .count) -> [(label: String, count: Int)] {
        let sorted: [(key: String, value: Int)]
        switch sortMode {
        case .count:
            sorted = counts.sorted {
                $0.value != $1.value
                    ? $0.value > $1.value
                    : $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending
            }
        case .alphabetical:
            sorted = counts.sorted {
                $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending
            }
        }
        return sorted.map { (label: $0.key, count: $0.value) }
    }

    // MARK: - Query paths

    /// Fast path: a single non-recursive folder has one constant parent_dir, so
    /// the counts come straight from a SQL GROUP BY instead of fetching every tag
    /// row and counting in Swift. `paths` restricts the count to the files
    /// actually in view, so a chip can never filter the grid down to empty.
    private static func fast(paths: [String], parentDir: String,
                             queue: DatabaseQueue) -> [String: Int] {
        (try? queue.read { db -> [String: Int] in
            var out: [String: Int] = [:]
            for start in stride(from: 0, to: paths.count, by: 800) {
                let chunk = Array(paths[start..<min(start + 800, paths.count)])
                let marks = databaseQuestionMarks(count: chunk.count)
                let rows = try Row.fetchAll(db, sql: """
                    SELECT t.label AS label, COUNT(DISTINCT p.file_id) AS c
                    FROM paths p JOIN tags t ON t.file_id = p.file_id
                    WHERE p.is_alive = 1 AND t.parent_dir = ? AND p.absolute_path IN (\(marks))
                    GROUP BY t.label
                    """, arguments: StatementArguments([parentDir] + chunk))
                for r in rows {
                    guard let label: String = r["label"], let c: Int = r["c"] else { continue }
                    out[label, default: 0] += c
                }
            }
            return out
        }) ?? [:]
    }

    /// General path: collection members or a recursive listing, where parent_dir
    /// varies per file — so each file's (file_id, parent_dir) scope is checked
    /// individually, and a duplicate's tag in another folder never surfaces here.
    private static func general(paths: [String], queue: DatabaseQueue) -> [String: Int] {
        var counts: [String: Int] = [:]
        for start in stride(from: 0, to: paths.count, by: 500) {
            let chunk = Array(paths[start..<min(start + 500, paths.count)])
            let rows: [(String, Int)] = (try? queue.read { db -> [(String, Int)] in
                let marks = databaseQuestionMarks(count: chunk.count)
                let pathRows = try Row.fetchAll(db, sql: """
                    SELECT file_id, absolute_path FROM paths
                    WHERE is_alive = 1 AND file_id IS NOT NULL AND absolute_path IN (\(marks))
                """, arguments: StatementArguments(chunk))
                var scopeKeys = Set<String>()
                var fileIDs = Set<String>()
                for r in pathRows {
                    guard let fid: String = r["file_id"],
                          let p: String = r["absolute_path"] else { continue }
                    fileIDs.insert(fid)
                    scopeKeys.insert(fid + "\u{0}" + TagScope.parentDir(ofPath: p))
                }
                guard !fileIDs.isEmpty else { return [] }
                let fmarks = databaseQuestionMarks(count: fileIDs.count)
                let tagRows = try Row.fetchAll(db, sql: """
                    SELECT label, file_id, parent_dir FROM tags WHERE file_id IN (\(fmarks))
                """, arguments: StatementArguments(Array(fileIDs)))
                var perLabel: [String: Set<String>] = [:]
                for tr in tagRows {
                    guard let label: String = tr["label"], let fid: String = tr["file_id"],
                          let dir: String = tr["parent_dir"] else { continue }
                    let key = fid + "\u{0}" + dir
                    if scopeKeys.contains(key) { perLabel[label, default: []].insert(key) }
                }
                return perLabel.map { ($0.key, $0.value.count) }
            }) ?? []
            for (label, count) in rows { counts[label, default: 0] += count }
        }
        return counts
    }
}
