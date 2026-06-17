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

    private init() {}

    func reload() async {
        guard let q = Database.shared.dbQueue else { return }
        collections = (try? await CollectionStore.fetchAll(queue: q)) ?? []
    }

    func recluster() async {
        // Auto-collections is opt-out (Preferences). Off → no new clustering;
        // existing collections remain, and the user can still build their own.
        guard AppSettings.autoCollections else { return }
        guard let q = Database.shared.dbQueue, !isClustering else { return }
        isClustering = true
        defer { isClustering = false }

        let registry = IntelligenceRegistry.shared

        // --- Intent track (typed screenshots) — runs regardless of embeddings.
        let intentMembers: [(fileID: String, bucket: String)] = (try? await q.read { db in
            try Row.fetchAll(db, sql: """
                SELECT f.id AS id, f.intent AS intent FROM files f
                JOIN paths p ON p.file_id = f.id
                WHERE f.intent IS NOT NULL AND p.is_alive = 1
                """).map { (fileID: $0["id"] as String, bucket: $0["intent"] as String) }
        }) ?? []
        let qualifying = IntentCollections.qualifyingBuckets(members: intentMembers)
        var intentLiveIDs = Set<String>()
        for (bucketKey, fileIDs) in qualifying {
            guard let bucket = IntentBucket(rawValue: bucketKey) else { continue }
            let id = bucket.collectionID
            intentLiveIDs.insert(id)
            // Preserve a user rename: reuse the stored name if the collection exists.
            let existing: String? = (try? await q.read { db in
                try String.fetchOne(db, sql: "SELECT name FROM collections WHERE id = ?",
                                    arguments: [id])
            }) ?? nil
            let name = existing ?? bucket.displayName
            try? await CollectionStore.upsert(queue: q, id: id, name: name,
                                              memberIDs: fileIDs, modelVersion: "intent-v1")
        }

        // --- Emergent track — everything EXCEPT typed screenshots.
        let typedIDs: Set<String> = (try? await q.read { db in
            try Set(String.fetchAll(db, sql: "SELECT id FROM files WHERE intent IS NOT NULL"))
        }) ?? []
        let items: [ClusterItem] = (try? await q.read { db in
            let rows = try EmbeddingRow.fetchAll(db)
            return rows.compactMap { row -> ClusterItem? in
                guard !typedIDs.contains(row.file_id) else { return nil }
                return ClusterItem(id: row.file_id,
                                   textVector: VectorMath.fromData(row.vector),
                                   featurePrint: nil)
            }
        }) ?? []

        let old = (try? await CollectionStore.currentMembership(queue: q)) ?? [:]
        var matched: [CollectionIdentity.Matched] = []
        if !items.isEmpty {
            let clusterer = registry.clusterer
            let clusters = await Task.detached(priority: .userInitiated) { clusterer.cluster(items) }.value
            matched = CollectionIdentity.match(old: old,
                                               new: clusters.map { Set($0.memberIDs) })
        }

        // Drop collections that no longer exist — but never manual collections,
        // collections holding manual members, or live intent collections.
        let liveIDs = Set(matched.map(\.id)).union(intentLiveIDs)
        let protected = (try? await CollectionStore.protectedCollectionIDs(queue: q)) ?? []
        for staleID in old.keys where !liveIDs.contains(staleID) && !protected.contains(staleID) {
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
