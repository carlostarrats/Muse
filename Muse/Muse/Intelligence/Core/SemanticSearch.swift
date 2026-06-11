//
//  SemanticSearch.swift
//  Muse
//
//  Embedding-based search merged with exact (FTS5 + tag) hits.
//  Exact hits always rank first; semantic hits above the similarity
//  threshold follow, sorted by score.
//

import Foundation
import GRDB

enum SemanticSearch {
    /// Exact hits keep their order and rank first; semantic hits above the
    /// threshold follow, sorted by similarity, deduplicated.
    static func merge(exactIDs: [String], semantic: [(String, Double)],
                      threshold: Double) -> [String] {
        var seen = Set(exactIDs)
        var out = exactIDs
        for (id, score) in semantic.sorted(by: { $0.1 > $1.1 })
        where score >= threshold && !seen.contains(id) {
            out.append(id); seen.insert(id)
        }
        return out
    }

    /// Cosine-score the query against all stored embeddings.
    static func semanticIDs(query: String, db: GRDB.Database) throws -> [(String, Double)] {
        guard let embedder = IntelligenceRegistry.shared.embedder,
              let qv = embedder.embed(query) else { return [] }
        let rows = try EmbeddingRow.fetchAll(db)
        return rows.map { ($0.file_id, VectorMath.cosine(qv, VectorMath.fromData($0.vector))) }
    }
}
