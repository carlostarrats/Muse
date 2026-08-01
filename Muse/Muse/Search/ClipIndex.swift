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
    /// Accumulator high-water mark before it is sorted back down to `topK`.
    /// Two topK's worth: enough that trimming is rare, small enough that the
    /// accumulator is a fixed cost rather than one that grows with the library.
    static let trimAt = topK * 2

    static func matches(query: [Float], minScore: Float,
                        db: GRDB.Database) throws -> [(id: String, score: Double)] {
        let dimension = query.count
        guard dimension > 0 else { return [] }

        var best: [(id: String, score: Double)] = []
        best.reserveCapacity(trimAt)
        // Once `topK` candidates are held, only a score at least as good as the
        // weakest of them can matter. Starting at `minScore` keeps the first
        // pass identical to the unbounded version.
        var threshold = Double(minScore)

        /// Keep the accumulator bounded at `topK`. Without this, EVERY row
        /// scoring above the (low) minimum was appended before the final
        /// truncate — ~40 B a tuple, so an 800k library could hold tens of MB
        /// of matches to answer a 400-row query.
        func trim() {
            best.sort { $0.score > $1.score }
            if best.count > topK {
                best.removeLast(best.count - topK)
                // `>=`, so equal scores still enter and ties aren't decided by
                // which chunk a row happened to land in.
                threshold = best[topK - 1].score
            }
        }

        // KEYSET paging, not LIMIT/OFFSET: SQLite has to walk and discard
        // `offset` rows for every page, so an 800k-row scan at 4,096 a page
        // cost ~78M discarded row-visits — quadratic in library size, in the
        // one place the file's own header promises graceful degradation.
        var lastID: String?
        while true {
            var request = ClipEmbeddingRow
                .filter(ClipEmbeddingRow.Columns.model_generation == ClipModel.current.generation)
                .filter(ClipEmbeddingRow.Columns.vector != nil)
                .order(ClipEmbeddingRow.Columns.file_id)
                .limit(chunkRows)
            if let lastID {
                request = request.filter(ClipEmbeddingRow.Columns.file_id > lastID)
            }
            let rows = try request.fetchAll(db)
            if rows.isEmpty { break }

            for row in rows {
                // A length mismatch means a vector from another model — never
                // pair them, the same rule as FeaturePrints.distance.
                guard let vector = row.vector.flatMap(ClipVectors.fromData),
                      vector.count == dimension else { continue }
                var dot: Float = 0
                vDSP_dotpr(vector, 1, query, 1, &dot, vDSP_Length(dimension))
                if Double(dot) >= threshold {
                    best.append((row.file_id, Double(dot)))
                    if best.count >= trimAt { trim() }
                }
            }
            lastID = rows.last?.file_id
            if rows.count < chunkRows { break }
        }

        best.sort { $0.score > $1.score }
        return Array(best.prefix(topK))
    }
}
