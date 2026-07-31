//
//  PlaceQueries.swift
//  Muse
//
//  Grouped place query: places JOIN alive paths LEFT JOIN photo_meta, grouped
//  by place_key. A NULL place_key is excluded — a photo the geocoder couldn't
//  place is not an "Unknown" group, it simply isn't a place.
//
//  Root filtering happens in Swift (CollectionStore.isUnderAnyRoot) after the
//  fetch, matching every other root-scoped query in the codebase.
//

import Foundation
import GRDB

nonisolated enum PlaceQueries {

    /// One row per place, carrying its count, its most-recent member's path
    /// (the cover) and that member's timestamp.
    ///
    /// Grouping and cover selection are done in Swift rather than with a
    /// window function or a correlated subquery: SQLite's window support
    /// varies with the OS-bundled version, and a place library is small
    /// (thousands of rows, not millions) well past the 50k design centre.
    static func groups(db: GRDB.Database) throws -> [PlaceGroup] {
        let rows = try Row.fetchAll(db, sql: """
            SELECT pl.place_key AS key, pl.city AS city, pl.admin AS admin,
                   pl.country AS country, p.absolute_path AS path,
                   COALESCE(m.capture_date, f.modified_at, f.created_at, 0) AS at
            FROM places pl
            JOIN files f ON f.id = pl.file_id
            JOIN paths p ON p.file_id = pl.file_id AND p.is_alive = 1
            LEFT JOIN photo_meta m ON m.file_id = pl.file_id
            WHERE pl.place_key IS NOT NULL
            """)

        var byKey: [String: PlaceGroup] = [:]
        for row in rows {
            guard let key: String = row["key"], let city: String = row["city"],
                  let path: String = row["path"] else { continue }
            let at: Int64 = row["at"] ?? 0
            if var existing = byKey[key] {
                existing.count += 1
                if at > existing.latestAt {
                    existing.latestAt = at
                    existing.coverPath = path
                }
                byKey[key] = existing
            } else {
                byKey[key] = PlaceGroup(key: key, city: city, admin: row["admin"],
                                        countryCode: row["country"] ?? "", count: 1,
                                        latestAt: at, coverPath: path)
            }
        }
        return Array(byKey.values)
    }
}
