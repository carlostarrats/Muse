//
//  AppState+Similarity.swift
//  Muse
//
//  The similarity entry points. A similarity query is expressed as ordinary
//  token TEXT (`similar:<handle>`), so it lands in the chip bar as a visible,
//  removable filter like every other token — never a hidden mode.
//

import Foundation
import GRDB

extension AppState {
    /// Stash a vector, put its handle in the search field, run the search.
    func runSimilarSearch(vector: [Float], label: String) {
        let handle = SimilarityRegistry.shared.stash(vector: vector, label: label)
        searchAllFolders = true
        let query = "similar:\(handle)"
        searchQuery = query
        Task { await runSearch(query) }
    }

    /// Find photos that look like `url`. Reuses the stored CLIP vector when
    /// there is one; only falls back to embedding on the spot when the file
    /// hasn't been through the backfill yet.
    func findSimilar(to url: URL) {
        Task { @MainActor in
            if let stored = await Self.storedClipVector(for: url) {
                runSimilarSearch(vector: stored, label: url.lastPathComponent)
                return
            }
            guard let raster = VisionServices.boundedDecode(
                    url: url, maxPixel: DeepAnalysisBackfill.decodeMaxPixel),
                  let vector = await ClipEngine.shared.embedImage(raster) else { return }
            runSimilarSearch(vector: vector, label: url.lastPathComponent)
        }
    }

    /// Open the smart-collection rules card pre-seeded with a "Looks Like"
    /// rule anchored on these photos. Anchors are FILE IDS — the vectors stay
    /// in `clip_embeddings` and are averaged at evaluation time.
    func newSmartCollectionFromSelection(urls: [URL]) {
        Task { @MainActor in
            let ids = await Self.fileIDs(for: Array(urls.prefix(SimilarTerm.maxAnchors)))
            guard !ids.isEmpty else { return }
            let set = SmartRuleSet(match: .all, rules: [
                .similar(SimilarTerm(anchorIDs: ids, prompt: nil, promptVector: nil,
                                     promptGeneration: nil,
                                     threshold: SimilarTerm.defaultThreshold))
            ])
            collectionModal = .rules(CollectionModal.RulesRequest(
                collectionID: nil,
                initialName: String(localized: "Looks Like These"),
                initialSet: set))
        }
    }

    private static func storedClipVector(for url: URL) async -> [Float]? {
        guard let queue = Database.shared.dbQueue else { return nil }
        let path = url.standardizedFileURL.path
        let generation = ClipModel.current.generation
        return try? await queue.read { db -> [Float]? in
            guard let data = try Data.fetchOne(db, sql: """
                SELECT c.vector FROM paths p
                JOIN clip_embeddings c ON c.file_id = p.file_id
                WHERE p.absolute_path = ? AND p.is_alive = 1
                  AND c.model_generation = ? AND c.vector IS NOT NULL
                LIMIT 1
                """, arguments: [path, generation]) else { return nil }
            return ClipVectors.fromData(data)
        } ?? nil
    }

    private static func fileIDs(for urls: [URL]) async -> [String] {
        guard let queue = Database.shared.dbQueue else { return [] }
        let paths = urls.map(\.standardizedFileURL.path)
        return (try? await queue.read { db -> [String] in
            var out: [String] = []
            for path in paths {
                if let id = try String.fetchOne(db, sql: """
                    SELECT file_id FROM paths WHERE absolute_path = ? AND is_alive = 1 LIMIT 1
                    """, arguments: [path]) {
                    out.append(id)
                }
            }
            return out
        }) ?? []
    }
}
