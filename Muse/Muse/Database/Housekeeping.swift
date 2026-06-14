//
//  Housekeeping.swift
//  Muse
//
//  Launch-time retention pass: index data for files that are no longer
//  reachable from any sidebar folder is kept for 180 days (so re-adding
//  a removed folder restores everything instantly), then fully purged —
//  row, paths, tags, search text, fingerprints, vectors, memberships.
//  Folders still in the sidebar are never pruned, opened or not.
//

import Foundation
import GRDB

enum Housekeeping {
    nonisolated static let retentionDays = 180

    /// Purge index data for files unreachable from `rootPaths` whose
    /// last_seen_at is older than the retention window. Runs in one write
    /// transaction; FK cascades cover embeddings, collection_members, and
    /// duplicate_members.
    static func pruneUnreachable(queue: DatabaseQueue,
                                 rootPaths: [String],
                                 retentionDays: Int = Housekeeping.retentionDays) async {
        let cutoff = Int64(Date().timeIntervalSince1970) - Int64(retentionDays) * 86_400
        do {
            let pruned = try await queue.write { db -> Int in
                let candidates = try String.fetchAll(db, sql: """
                    SELECT id FROM files WHERE last_seen_at < ?
                    """, arguments: [cutoff])
                guard !candidates.isEmpty else { return 0 }

                var doomed: [String] = []
                for id in candidates {
                    let paths = try String.fetchAll(db, sql: """
                        SELECT absolute_path FROM paths
                        WHERE file_id = ? AND is_alive = 1
                        """, arguments: [id])
                    let reachable = paths.contains { p in
                        rootPaths.contains { root in
                            p == root || p.hasPrefix(root + "/")
                        }
                    }
                    if !reachable { doomed.append(id) }
                }
                guard !doomed.isEmpty else { return 0 }

                for id in doomed {
                    try db.execute(sql: "DELETE FROM files_fts WHERE file_id = ?",
                                   arguments: [id])
                    try db.execute(sql: "DELETE FROM tags WHERE file_id = ?",
                                   arguments: [id])
                    try db.execute(sql: "DELETE FROM paths WHERE file_id = ?",
                                   arguments: [id])
                    try db.execute(sql: "DELETE FROM files WHERE id = ?",
                                   arguments: [id])
                }
                return doomed.count
            }
            if pruned > 0 {
                print("[Housekeeping] pruned \(pruned) unreachable files (>\(retentionDays)d)")
            }
        } catch {
            print("[Housekeeping] prune failed: \(error)")
        }
    }
}
