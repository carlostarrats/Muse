//
//  CollectionsEngine.swift
//  Muse
//
//  Reclusters the library into living collections. Runs after analyze
//  batches. Hidden collections keep their identity (currentMembership
//  includes them) and stay hidden (upsert never touches is_hidden on
//  conflict); fetchAll excludes them from the UI.
//

import Foundation
import GRDB

/// Reclusters the library into living collections. Runs after analyze batches.
/// Cheap enough to run whole-library at personal scale; incremental smartness
/// arrives behind the same interface later.
@MainActor
final class CollectionsEngine: ObservableObject {
    static let shared = CollectionsEngine()
    @Published var collections: [CollectionStore.Loaded] = []
    @Published var isClustering = false

    func reload() async {
        guard let q = Database.shared.dbQueue else { return }
        collections = (try? await CollectionStore.fetchAll(queue: q)) ?? []
    }

    func recluster() async {
        guard let q = Database.shared.dbQueue, !isClustering else { return }
        isClustering = true
        defer { isClustering = false }

        let registry = IntelligenceRegistry.shared
        let items: [ClusterItem] = (try? await q.read { db in
            let rows = try EmbeddingRow.fetchAll(db)
            return rows.map {
                ClusterItem(id: $0.file_id,
                            textVector: VectorMath.fromData($0.vector),
                            featurePrint: nil)
            }
        }) ?? []
        guard !items.isEmpty else { return }

        let clusters = registry.clusterer.cluster(items)
        let old = (try? await CollectionStore.currentMembership(queue: q)) ?? [:]
        let matched = CollectionIdentity.match(old: old,
                                               new: clusters.map { Set($0.memberIDs) })

        // drop collections that no longer exist
        let liveIDs = Set(matched.map(\.id))
        for staleID in old.keys where !liveIDs.contains(staleID) {
            try? await q.write { db in
                try db.execute(sql: "DELETE FROM collections WHERE id = ?", arguments: [staleID])
            }
        }

        for m in matched {
            let name: String
            if m.isNew {
                let tags = (try? await topTags(queue: q, fileIDs: Array(m.members))) ?? []
                name = await registry.namer.name(tagsByFrequency: tags)
            } else {
                name = (try? await q.read { db in
                    try String.fetchOne(db, sql: "SELECT name FROM collections WHERE id = ?",
                                        arguments: [m.id])
                }).flatMap { $0 } ?? "Collection"
            }
            try? await CollectionStore.upsert(queue: q, id: m.id, name: name,
                                              memberIDs: Array(m.members),
                                              modelVersion: registry.clusterer.modelVersion)
        }
        await reload()
    }

    private func topTags(queue: DatabaseQueue, fileIDs: [String]) async throws -> [String] {
        try await queue.read { db in
            guard !fileIDs.isEmpty else { return [] }
            let marks = fileIDs.map { _ in "?" }.joined(separator: ",")
            let rows = try Row.fetchAll(db, sql: """
                SELECT label, COUNT(*) AS n FROM tags
                WHERE file_id IN (\(marks)) AND source != 'vision-color'
                GROUP BY label ORDER BY n DESC LIMIT 10
                """, arguments: StatementArguments(fileIDs))
            return rows.map { $0["label"] }
        }
    }
}
