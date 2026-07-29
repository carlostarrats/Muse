//
//  SimilarTagSuggestions.swift
//  Muse
//
//  "What did you tag photos that look like this one?"
//
//  Backs the Add Tag card's suggestion row. Muse already stores a Vision
//  feature print per analyzed image (the same signal the duplicate finder and
//  the clusterer use), so the nearest neighbours of the photo in hand are
//  cheap to find — and the tags THEY carry are a far better offer than the
//  library's most-used labels, which are the same handful for every photo.
//
//  Degrades quietly: an unanalyzed photo (no feature print), a library with no
//  tagged neighbours, or any DB failure returns an empty list and the caller
//  falls back to most-used.
//

import Foundation
import Vision
import GRDB

nonisolated enum SimilarTagSuggestions {

    /// How many nearest neighbours to harvest tags from. Small enough to stay
    /// specific — widen it and the row drifts back toward "the library's most
    /// common tags", which is what this exists to improve on.
    static let neighbourCount = 20

    /// Upper bound on feature prints pulled into memory for the scan. A print is
    /// ~3 KB, so 4000 is ~12 MB and a few ms of distance math — bounded work on
    /// a card that has to appear instantly. Beyond that the newest files win,
    /// which is where a user's recent tagging vocabulary lives anyway.
    static let candidateLimit = 4000

    /// Labels carried by the nearest visual neighbours of `url`, most common
    /// first.
    ///
    /// - `exclude`: labels already on this file. Star ratings are dropped too —
    ///   a rating is a manual tag with no mutual exclusion, so offering one
    ///   would let a file end up with two.
    static func candidates(for url: URL,
                           excluding exclude: Set<String>,
                           limit: Int) async -> [TagSuggest.Candidate] {
        guard let queue = Database.shared.dbQueue else { return [] }
        let path = url.standardizedFileURL.path

        let rows: [(fileID: String, print: Data)]
        let selfPrint: Data
        do {
            let fetched = try await queue.read { db -> (Data, [(String, Data)])? in
                // This file's own print, via its alive path row.
                guard let me = try PathRow
                    .filter(PathRow.Columns.absolute_path == path
                            && PathRow.Columns.is_alive == 1)
                    .fetchOne(db),
                    let myFileID = me.file_id,
                    let myPrint = try FileRow.fetchOne(db, key: myFileID)?.feature_print
                else { return nil }

                // Candidates: analyzed files that actually carry a tag — an
                // untagged neighbour contributes nothing, so it's not worth the
                // distance computation or the memory.
                let candidates = try Row.fetchAll(db, sql: """
                    SELECT f.id AS id, f.feature_print AS fp
                    FROM files f
                    WHERE f.feature_print IS NOT NULL
                      AND f.id <> ?
                      AND EXISTS (SELECT 1 FROM tags t WHERE t.file_id = f.id)
                    ORDER BY f.modified_at DESC
                    LIMIT ?
                    """, arguments: [myFileID, candidateLimit])
                    .compactMap { row -> (String, Data)? in
                        guard let id: String = row["id"], let fp: Data = row["fp"] else { return nil }
                        return (id, fp)
                    }
                return (myPrint, candidates)
            }
            guard let fetched else { return [] }
            selfPrint = fetched.0
            rows = fetched.1.map { (fileID: $0.0, print: $0.1) }
        } catch {
            return []
        }
        guard !rows.isEmpty else { return [] }

        // Distance math off the main actor — this runs while a modal is opening.
        let nearest: [String] = await Task.detached(priority: .userInitiated) {
            guard let me = unarchive(selfPrint) else { return [] }
            var scored: [(id: String, distance: Float)] = []
            scored.reserveCapacity(rows.count)
            for row in rows {
                guard let other = unarchive(row.print) else { continue }
                var d: Float = 0
                // Throws on a dimension/revision mismatch (e.g. prints written by
                // a different Vision revision) — skip those rather than fail the
                // whole lookup.
                guard (try? me.computeDistance(&d, to: other)) != nil else { continue }
                scored.append((row.fileID, d))
            }
            return scored.sorted { $0.distance < $1.distance }
                .prefix(neighbourCount)
                .map(\.id)
        }.value
        guard !nearest.isEmpty else { return [] }

        // Tally the neighbours' labels. Counted across neighbours, so a label
        // several of them share outranks one that appears on a single photo.
        let tally: [String: Int]
        do {
            tally = try await queue.read { db in
                let placeholders = databaseQuestionMarks(count: nearest.count)
                let labels = try String.fetchAll(db, sql: """
                    SELECT label FROM tags WHERE file_id IN (\(placeholders))
                    """, arguments: StatementArguments(nearest))
                return labels.reduce(into: [:]) { $0[$1, default: 0] += 1 }
            }
        } catch {
            return []
        }

        let kept = tally.filter { !exclude.contains($0.key) && !StarRating.isRating($0.key) }
        var out: [TagSuggest.Candidate] = kept.map {
            TagSuggest.Candidate(label: $0.key, count: $0.value)
        }
        // Most-shared first; alphabetical breaks ties so the row is stable
        // between openings rather than reshuffling on dictionary order.
        out.sort { a, b in
            if a.count != b.count { return a.count > b.count }
            return a.label.localizedCaseInsensitiveCompare(b.label) == .orderedAscending
        }
        return Array(out.prefix(limit))
    }

    private static func unarchive(_ data: Data) -> VNFeaturePrintObservation? {
        try? NSKeyedUnarchiver.unarchivedObject(
            ofClass: VNFeaturePrintObservation.self, from: data)
    }
}
