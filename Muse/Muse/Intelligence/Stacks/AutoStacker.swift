//
//  AutoStacker.swift
//  Muse
//
//  Clusters VIRGIN files (no stack_members row — dissolved included) among the
//  given file ids and writes kind:"auto" stacks. There is no global launch
//  pass: it runs at the end of an analyze pass over that pass's ids, and
//  lazily per-folder from StacksStore.reload(for:), so existing libraries
//  stack up folder by folder as they're browsed.
//

import Foundation
import GRDB

nonisolated enum AutoStacker {
    /// `dbQueue` exists so tests can run against an in-memory queue; the
    /// production call sites omit it.
    @discardableResult
    static func run(fileIDs: [String], dbQueue: DatabaseQueue? = nil) async -> Int {
        guard let q = dbQueue ?? Database.shared.dbQueue, !fileIDs.isEmpty else { return 0 }

        let clusters: [[String]] = (try? await q.read { db -> [[String]] in
            let claimed = try StackStore.claimedFileIDs(db: db)
            let virginIDs = fileIDs.filter { !claimed.contains($0) }
            guard !virginIDs.isEmpty else { return [] }
            var items: [BurstClusterer.Item] = []
            var index = 0
            while index < virginIDs.count {
                let end = min(index + StackStore.idChunk, virginIDs.count)
                let chunk = Array(virginIDs[index..<end])
                index = end
                let placeholders = chunk.map { _ in "?" }.joined(separator: ",")
                let rows = try Row.fetchAll(db, sql: """
                    SELECT f.id AS id,
                           COALESCE(m.capture_date, f.created_at, 0) AS captureAt,
                           f.feature_print AS print
                    FROM files f LEFT JOIN photo_meta m ON m.file_id = f.id
                    WHERE f.id IN (\(placeholders))
                      AND f.kind IN ('image','raw','psd')
                    """, arguments: StatementArguments(chunk))
                for row in rows {
                    guard let id: String = row["id"] else { continue }
                    let printData: Data? = row["print"]
                    items.append(BurstClusterer.Item(
                        fileID: id,
                        captureAt: row["captureAt"] ?? 0,
                        print: printData.flatMap(FeaturePrints.floats)))
                }
            }
            return BurstClusterer.clusters(items)
        }) ?? []
        guard !clusters.isEmpty else { return 0 }

        // Counted INSIDE the write and returned, rather than mutated across
        // the @Sendable closure boundary.
        let created: Int = (try? await q.write { db -> Int in
            // Re-check virginity INSIDE the write: a manual stack could have
            // claimed a member between the read above and here.
            let stillClaimed = try StackStore.claimedFileIDs(db: db)
            var claimedNow = stillClaimed
            var made = 0
            for cluster in clusters {
                let members = cluster.filter { !claimedNow.contains($0) }
                guard members.count >= 2 else { continue }
                try StackStore.createStack(kind: "auto", memberIDs: members, pick: nil, db: db)
                claimedNow.formUnion(members)
                made += 1
            }
            return made
        }) ?? 0
        return created
    }
}
