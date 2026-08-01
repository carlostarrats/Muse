//
//  PhotoHeaderBackfill.swift
//  Muse
//
//  Launch-time pass filling files.lat/lon/coords_scanned_hash and the
//  photo_meta row for files the analysis pipeline hasn't stamped yet —
//  libraries indexed before v13/v14, and files whose bytes changed since
//  their last header read. Supersedes Spec 01's CoordinateBackfill; one
//  header read now serves both. Mirrors IntentBackfill: fire-and-forget,
//  self-limiting, safe to call on every launch.
//
//  Header-only reads (no decode), bounded concurrency, and capped per launch
//  so a 100k cold library spreads over a few launches instead of hammering
//  the disk once at startup.
//

import Foundation
import GRDB

enum PhotoHeaderBackfill {
    /// Cap per launch — see file header.
    static let maxPerLaunch = 5_000
    /// Rows per write transaction. Batching keeps the serial DB queue free
    /// between chunks so an interactive read isn't stuck behind the whole pass.
    static let chunkSize = 200
    /// Concurrent header reads. Matches the indexer's hash concurrency; these
    /// are small sequential reads, not decodes.
    static let concurrency = 4

    struct Candidate: Sendable {
        let id: String
        let url: URL
        let kind: AssetKind
    }

    /// Pure: which enumerated rows are worth opening. A kind
    /// `PhotoHeaderReader` doesn't handle would be re-selected on every launch
    /// (it never gets a scanned hash), so filtering here is what keeps the
    /// pass bounded.
    static func candidate(id: String, path: String) -> Candidate? {
        let url = URL(fileURLWithPath: path)
        let kind = AssetKind.detect(at: url)
        switch kind {
        case .image, .raw, .psd, .video:
            return Candidate(id: id, url: url, kind: kind)
        default:
            return nil
        }
    }

    static func run() async {
        guard let q = Database.shared.dbQueue else { return }

        // Stale by EITHER marker — a library upgraded from v13 already has
        // coordinates but no photo_meta at all.
        let candidates: [Candidate] = (try? await q.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT f.id AS id, MIN(p.absolute_path) AS absolute_path
                FROM files f
                JOIN paths p ON p.file_id = f.id AND p.is_alive = 1
                LEFT JOIN photo_meta m ON m.file_id = f.id
                WHERE f.content_hash IS NOT NULL
                  AND (f.coords_scanned_hash IS NULL
                       OR f.coords_scanned_hash != f.content_hash
                       OR m.exif_scanned_hash IS NULL
                       OR m.exif_scanned_hash != f.content_hash)
                GROUP BY f.id
                LIMIT \(maxPerLaunch)
                """)
            return rows.compactMap { row -> Candidate? in
                guard let id: String = row["id"],
                      let path: String = row["absolute_path"] else { return nil }
                return candidate(id: id, path: path)
            }
        }) ?? []
        guard !candidates.isEmpty else { return }

        var wroteAny = false
        var index = 0
        while index < candidates.count {
            if Task.isCancelled { return }
            // Additive scheduling only — `.utility` priority is unchanged.
            await WorkThrottleStore.shared.waitUntilRunnable()
            let end = min(index + chunkSize, candidates.count)
            let chunk = Array(candidates[index..<end])
            index = end

            var results: [(id: String, hash: String, header: PhotoHeader)] = []
            await withTaskGroup(of: (String, String, PhotoHeader)?.self) { group in
                var iterator = chunk.makeIterator()
                var spawned = 0

                @Sendable func work(_ c: Candidate) async -> (String, String, PhotoHeader)? {
                    // Re-read the hash rather than carrying it from the
                    // selection query: the file may have been re-indexed since,
                    // and the write below guards on this value.
                    let hash: String? = (try? await q.read { db in
                        try FileRow.filter(FileRow.Columns.id == c.id).fetchOne(db)?.content_hash
                    }) ?? nil
                    guard let hash else { return nil }
                    let header = await PhotoHeaderReader.read(url: c.url, kind: c.kind)
                    return (c.id, hash, header)
                }

                while spawned < concurrency, let c = iterator.next() {
                    spawned += 1
                    group.addTask { await work(c) }
                }
                for await result in group {
                    if let result { results.append(result) }
                    if let c = iterator.next() {
                        group.addTask { await work(c) }
                    }
                }
            }

            let batch = results
            let wrote: Bool = (try? await q.write { db -> Bool in
                var any = false
                for (id, hash, header) in batch {
                    try AnalyzePipeline.writePhotoHeader(db: db, fileID: id,
                                                        hash: hash, header: header)
                    any = true
                }
                return any
            }) ?? false
            if wrote { wroteAny = true }
        }

        if wroteAny {
            // Fresh coordinates mean fresh places; fresh EXIF means the
            // autocomplete facets are stale.
            await GeocodeBackfill.run()
            await SearchFacets.shared.refresh()
        }
    }
}
