//
//  GeocodeBackfill.swift
//  Muse
//
//  Offline reverse geocoding: coordinates → city/admin/country via the bundled
//  GeoNames dataset + k-d tree. No network, ever. CLGeocoder is throttled
//  (~50 requests/60s — a non-starter at library scale) and is a network call,
//  which doctrine forbids regardless.
//
//  A `places` row is written for EVERY geocoded file, including one with
//  nothing within range: the row itself is the attempted-marker, so an ocean
//  photo isn't re-geocoded on every launch.
//

import Foundation
import GRDB

nonisolated enum ReverseGeocoder {
    /// Beyond this, the nearest settlement is not a useful answer — the file
    /// gets a NULL-place attempted-marker row instead.
    static let maxDistanceKM: Double = 150

    struct Place: Equatable {
        var city: String
        var admin: String?
        /// ISO 3166-1 alpha-2 — display names resolve at render time.
        var country: String
        var key: String
    }

    /// nil = no city within `maxDistanceKM` ("geocoded, no place").
    static func place(lat: Double, lon: Double, tree: GeoKDTree, cities: [GeoCity],
                      dataset: GeoNamesDataset) -> Place? {
        guard let nearest = tree.nearest(lat: lat, lon: lon),
              nearest.distanceKM <= maxDistanceKM,
              cities.indices.contains(nearest.index) else { return nil }
        let city = cities[nearest.index]
        let admin = dataset.admin1Name(for: city.admin1Code)
        return Place(city: city.name, admin: admin, country: city.countryCode,
                     key: placeKey(city: city.name, admin: admin, country: city.countryCode))
    }

    /// The grouping key Places and the `near:`/`.location` rules match on.
    /// Lowercased "city|admin|country" — one declaration site.
    static func placeKey(city: String, admin: String?, country: String) -> String {
        [city, admin ?? "", country].joined(separator: "|").lowercased()
    }
}

nonisolated enum GeocodeBackfill {
    static let writeChunk = 200

    /// Single-flight — reachable from the launch chain, from
    /// `PhotoHeaderBackfill` when it writes, and from all three importers.
    /// Two concurrent copies each parse the ~7 MB dataset and build their own
    /// k-d tree over the same rows.
    static func run() async {
        await BackfillCoordinator.shared.run("geocode") { await work() }
    }

    struct Candidate { let fileID: String; let hash: String; let lat: Double; let lon: Double }

    /// One page of stale rows, keyset-paged past `afterID`. Keyset rather than
    /// a whole-library fetch: a 800k-geotagged library materialized every
    /// candidate at once, against "never write code that assumes everything
    /// fits in RAM"; and keyset rather than OFFSET so the scan can't be
    /// quadratic. `id` ordering also guarantees forward progress even when a
    /// row is skipped by the content-identity guard below (an OFFSET-free
    /// "re-query the predicate" loop would re-fetch those forever).
    static func page(db: GRDB.Database, version: Int, afterID: String?,
                     limit: Int) throws -> [Candidate] {
        let rows = try Row.fetchAll(db, sql: """
            SELECT f.id AS id, f.content_hash AS content_hash, f.lat AS lat, f.lon AS lon
            FROM files f
            LEFT JOIN places p ON p.file_id = f.id
            WHERE f.lat IS NOT NULL AND f.content_hash IS NOT NULL
              AND (p.file_id IS NULL
                   OR p.geocoded_hash != f.content_hash
                   OR p.dataset_version != ?)
              AND (? IS NULL OR f.id > ?)
            ORDER BY f.id
            LIMIT ?
            """, arguments: [version, afterID, afterID, limit])
        return rows.compactMap { row -> Candidate? in
            guard let id: String = row["id"], let hash: String = row["content_hash"],
                  let lat: Double = row["lat"], let lon: Double = row["lon"] else { return nil }
            return Candidate(fileID: id, hash: hash, lat: lat, lon: lon)
        }
    }

    private static func work() async {
        guard let q = Database.shared.dbQueue else { return }
        let version = GeoNamesDataset.version

        // Probe before paying for the dataset: the common launch case is that
        // the chained copy already drained the queue and this finds nothing.
        let first: [Candidate] = (try? await q.read { db in
            try page(db: db, version: version, afterID: nil, limit: writeChunk)
        }) ?? []
        guard !first.isEmpty else { return }

        // The dataset (~7 MB parsed) is loaded only now that there is work,
        // and released when this function returns.
        guard let cities = GeoNamesDataset.shared.cities() else { return }
        let tree = GeoKDTree(points: cities.map { ($0.lat, $0.lon) })

        var wroteAny = false
        var chunk = first
        while !chunk.isEmpty {
            if Task.isCancelled { return }
            await WorkThrottleStore.shared.waitUntilRunnable()
            let lastID = chunk[chunk.count - 1].fileID

            let wrote: Bool = (try? await q.write { db -> Bool in
                var any = false
                for c in chunk {
                    // Same content-identity guard as every other derived write:
                    // a file re-indexed mid-pass stays pending.
                    guard let current = try FileRow.filter(FileRow.Columns.id == c.fileID).fetchOne(db),
                          current.content_hash == c.hash else { continue }
                    let resolved = ReverseGeocoder.place(lat: c.lat, lon: c.lon, tree: tree,
                                                         cities: cities,
                                                         dataset: GeoNamesDataset.shared)
                    var row = PlaceRow(file_id: c.fileID, geocoded_hash: c.hash,
                                       dataset_version: version, city: resolved?.city,
                                       admin: resolved?.admin, country: resolved?.country,
                                       place_key: resolved?.key)
                    try row.save(db)
                    any = true
                }
                return any
            }) ?? false
            if wrote { wroteAny = true }

            chunk = (try? await q.read { db in
                try page(db: db, version: version, afterID: lastID, limit: writeChunk)
            }) ?? []
        }

        if wroteAny {
            await PlacesStore.shared.reload()
            await SearchFacets.shared.refresh()
        }
    }
}
