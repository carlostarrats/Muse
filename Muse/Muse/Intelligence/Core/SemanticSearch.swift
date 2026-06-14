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

nonisolated enum SemanticSearch {
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

    /// Cosine-score a precomputed query vector against all stored embeddings.
    /// The caller embeds the query (touching the @MainActor registry) and
    /// passes the vector in, so this scoring pass stays off-main/nonisolated.
    static func semanticIDs(queryVector qv: [Float], db: GRDB.Database) throws -> [(String, Double)] {
        let rows = try EmbeddingRow.fetchAll(db)
        return rows.map { ($0.file_id, VectorMath.cosine(qv, VectorMath.fromData($0.vector))) }
    }
}
