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

    /// Standardized paths of the active roots, pushed by AppState whenever the
    /// root list changes. The badge/card count is narrowed to members under one
    /// of these so it matches what the grid can actually show (Lever 1 of the
    /// 2026-06-19 count-vs-contents fix). Empty until AppState pushes them.
    private var rootPaths: [String] = []

    private init() {}

    /// AppState calls this from rebuildRootNodes so the reachability-aware count
    /// always reflects the current roots. Re-counts (reloads) on a real change.
    func setRoots(_ urls: [URL]) {
        let paths = urls.map { $0.standardizedFileURL.path }
        guard paths != rootPaths else { return }
        rootPaths = paths
        Task { await reload() }
    }

    func reload() async {
        guard let q = Database.shared.dbQueue else { return }
        collections = (try? await CollectionStore.fetchAll(queue: q, rootPaths: rootPaths)) ?? []
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
            // DISTINCT: a file with several alive paths (same content in multiple
            // folders) JOINs to one row per path; without it the threshold gate
            // counts paths, not files. qualifyingBuckets also dedupes defensively.
            try Row.fetchAll(db, sql: """
                SELECT DISTINCT f.id AS id, f.intent AS intent FROM files f
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
        // These reads feed the destructive stale-deletion below: if the embeddings
        // read transiently fails but the membership read succeeds, present clusters
        // look absent and unprotected auto-collections (including renamed ones) get
        // hard-deleted. So read inside one do/catch and bail the emergent pass on
        // ANY failure rather than treating "couldn't read" as "nothing there". The
        // intent track above already committed; the next pass retries.
        let typedIDs: Set<String>
        let items: [ClusterItem]
        let old: [String: Set<String>]
        do {
            typedIDs = try await q.read { db in
                try Set(String.fetchAll(db, sql: "SELECT id FROM files WHERE intent IS NOT NULL"))
            }
            items = try await q.read { db in
                let rows = try EmbeddingRow.fetchAll(db)
                return rows.compactMap { row -> ClusterItem? in
                    guard !typedIDs.contains(row.file_id) else { return nil }
                    return ClusterItem(id: row.file_id,
                                       textVector: VectorMath.fromData(row.vector),
                                       featurePrint: nil)
                }
            }
            old = try await CollectionStore.currentMembership(queue: q)
        } catch {
            await reload()
            return
        }
        var matched: [CollectionIdentity.Matched] = []
        if !items.isEmpty {
            let clusterer = registry.clusterer
            let clusters = await Task.detached(priority: .userInitiated) { clusterer.cluster(items) }.value
            matched = CollectionIdentity.match(old: old,
                                               new: clusters.map { Set($0.memberIDs) })
        }

        // Drop collections that no longer exist — but never manual collections,
        // collections holding manual members, live intent collections, or HIDDEN
        // collections. A "deleted" collection is a durable is_hidden tombstone the
        // recluster must never clear: if its membership drifts so it no longer
        // matches a cluster, hard-deleting it would let an equivalent cluster
        // re-form un-hidden, silently undoing the user's delete.
        let liveIDs = Set(matched.map(\.id)).union(intentLiveIDs)
        // Protected (manual) + hidden (tombstone) collections must survive the
        // stale sweep. Read both fail-CLOSED: if either read throws transiently,
        // SKIP the destructive deletion entirely this pass rather than delete a
        // protected/tombstoned collection because a flaky read returned an empty
        // guard set (a `try?`/`?? []` here would re-open the exact bug the hidden
        // exclusion fixes). The upserts below still run; next pass retries the sweep.
        let pruneGuards: (protected: Set<String>, hidden: Set<String>)?
        do {
            let protected = try await CollectionStore.protectedCollectionIDs(queue: q)
            let hidden = try await q.read { db in
                try Set(String.fetchAll(db, sql: "SELECT id FROM collections WHERE is_hidden = 1"))
            }
            pruneGuards = (protected, hidden)
        } catch {
            pruneGuards = nil
        }
        if let guards = pruneGuards {
            for staleID in old.keys
            where !liveIDs.contains(staleID) && !guards.protected.contains(staleID) && !guards.hidden.contains(staleID) {
                try? await q.write { db in
                    try db.execute(sql: "DELETE FROM collections WHERE id = ?", arguments: [staleID])
                }
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
