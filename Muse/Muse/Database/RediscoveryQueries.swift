//
//  RediscoveryQueries.swift
//  Muse
//
//  Pure db-taking query functions (the NoteStore/PlaceQueries shape). All
//  three surfaces are capped — they are browse surfaces, not archives. Kinds
//  are limited to image/raw/psd/video. Root filtering happens in Swift at the
//  RediscoveryStore layer, after fetch; these return unfiltered file ids.
//
//  Rediscovery adds NO new analysis: every column read here is written by the
//  indexer, the analyze pass, or the header backfill.
//

import Foundation
import GRDB

nonisolated enum RediscoveryQueries {
    /// Surfaces are browse surfaces, not archives.
    static let defaultLimit = 500

    private static let photoKinds = "'image','raw','psd','video'"

    /// Never-viewed first, then longest-ago-viewed. `created_at` breaks ties so
    /// the order is stable between activations.
    static func rarelySeen(db: GRDB.Database, limit: Int = defaultLimit) throws -> [String] {
        let rows = try Row.fetchAll(db, sql: """
            SELECT f.id AS id FROM files f
            JOIN paths p ON p.file_id = f.id AND p.is_alive = 1
            WHERE f.kind IN (\(photoKinds))
            GROUP BY f.id
            ORDER BY f.last_viewed_at IS NOT NULL, f.last_viewed_at ASC,
                     f.created_at ASC, f.id ASC
            LIMIT ?
            """, arguments: [limit])
        return rows.compactMap { $0["id"] as String? }
    }

    /// `todayMD` is "MM-DD"; `currentYear` excludes this year's own captures.
    /// Files with no `photo_meta` row fall back to the same month-day test on
    /// `files.created_at` — a set that shrinks toward zero as the header
    /// backfill completes.
    ///
    /// Feb 29 shows on Feb 29 only (no Mar 1 remap): that falls out of the
    /// exact string match, it isn't a branch.
    static func onThisDay(db: GRDB.Database, todayMD: String, currentYear: Int,
                          limit: Int = defaultLimit) throws -> [String] {
        let withMeta = try Row.fetchAll(db, sql: """
            SELECT f.id AS id, m.capture_date AS ord FROM files f
            JOIN paths p ON p.file_id = f.id AND p.is_alive = 1
            JOIN photo_meta m ON m.file_id = f.id
            WHERE f.kind IN (\(photoKinds)) AND m.capture_md = ?
              AND CAST(strftime('%Y', m.capture_date, 'unixepoch') AS INTEGER) < ?
            GROUP BY f.id
            """, arguments: [todayMD, currentYear])
        let fallback = try Row.fetchAll(db, sql: """
            SELECT f.id AS id, f.created_at AS ord FROM files f
            JOIN paths p ON p.file_id = f.id AND p.is_alive = 1
            LEFT JOIN photo_meta m ON m.file_id = f.id
            WHERE f.kind IN (\(photoKinds))
              AND (m.file_id IS NULL OR m.capture_md IS NULL)
              AND strftime('%m-%d', f.created_at, 'unixepoch') = ?
              AND CAST(strftime('%Y', f.created_at, 'unixepoch') AS INTEGER) < ?
            GROUP BY f.id
            """, arguments: [todayMD, currentYear])

        var seen = Set<String>()
        var ordered: [(id: String, ord: Int64)] = []
        for row in (withMeta + fallback) {
            guard let id: String = row["id"], !seen.contains(id) else { continue }
            seen.insert(id)
            ordered.append((id, row["ord"] ?? 0))
        }
        // Newest year first.
        return ordered.sorted {
            $0.ord != $1.ord ? $0.ord > $1.ord : $0.id < $1.id
        }.prefix(limit).map(\.id)
    }

    /// Deterministic under a fixed seed; `RediscoveryStore` passes a fresh seed
    /// on each activation so "Shuffle Again" re-samples.
    static func shuffle(db: GRDB.Database, limit: Int = defaultLimit, seed: UInt64) throws -> [String] {
        let rows = try Row.fetchAll(db, sql: """
            SELECT f.id AS id FROM files f
            JOIN paths p ON p.file_id = f.id AND p.is_alive = 1
            WHERE f.kind IN (\(photoKinds))
            GROUP BY f.id
            ORDER BY f.id ASC
            """)
        var ids = rows.compactMap { $0["id"] as String? }
        var rng = SeededRandom(seed: seed)
        ids.shuffle(using: &rng)
        return Array(ids.prefix(limit))
    }
}
