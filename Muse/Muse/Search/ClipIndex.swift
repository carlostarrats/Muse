//
//  ClipIndex.swift
//  Muse
//
//  Brute-force retrieval, structured for the 200k+ tier: streams `chunkRows`
//  at a time so the memory ceiling is `chunkRows × 2KB` regardless of library
//  size — no code may assume the whole vector matrix fits in RAM, and that
//  rule is satisfied HERE rather than deferred to a rewrite. Swapping in
//  sqlite-vec/mmap at the 800k tier would replace this enum's body only.
//

import Accelerate
import GRDB

nonisolated enum ClipIndex {
    /// CLIP text↔image cosines live in a much lower band than same-modality
    /// cosines — 0.20 is a real match there. Never validated live yet.
    static let textMinScore: Float = 0.20
    /// The image↔image band is higher.
    static let imageMinScore: Float = 0.55
    static let topK = 400
    static let chunkRows = 4_096

    static func matches(query: [Float], minScore: Float,
                        db: GRDB.Database) throws -> [(id: String, score: Double)] {
        let dimension = query.count
        guard dimension > 0 else { return [] }

        var best: [(id: String, score: Double)] = []
        var offset = 0
        while true {
            let rows = try ClipEmbeddingRow
                .filter(ClipEmbeddingRow.Columns.model_generation == ClipModel.current.generation)
                .filter(ClipEmbeddingRow.Columns.vector != nil)
                .order(ClipEmbeddingRow.Columns.file_id)
                .limit(chunkRows, offset: offset)
                .fetchAll(db)
            if rows.isEmpty { break }

            for row in rows {
                // A length mismatch means a vector from another model — never
                // pair them, the same rule as FeaturePrints.distance.
                guard let vector = row.vector.flatMap(ClipVectors.fromData),
                      vector.count == dimension else { continue }
                var dot: Float = 0
                vDSP_dotpr(vector, 1, query, 1, &dot, vDSP_Length(dimension))
                if dot >= minScore {
                    best.append((row.file_id, Double(dot)))
                }
            }
            if rows.count < chunkRows { break }
            offset += chunkRows
        }

        best.sort { $0.score > $1.score }
        return Array(best.prefix(topK))
    }
}
