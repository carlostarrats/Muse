//
//  LaunchBackfillQueryTests.swift
//  MuseTests
//
//  The two launch-pass queries the 2026-08-01 review rewrote for cost:
//  SearchFacets' distinct-years loose index scan (was an unindexable strftime
//  scan of all photo_meta) and GeocodeBackfill's keyset page (was a whole-
//  library fetch into RAM). Both must return exactly what the old shape did.
//

import XCTest
import GRDB
@testable import Muse

final class LaunchBackfillQueryTests: XCTestCase {

    private func makeQueue() throws -> DatabaseQueue {
        let q = try DatabaseQueue()
        try Database.makeMigrator().migrate(q)
        return q
    }

    private func insertFile(_ db: GRDB.Database, id: String, hash: String,
                            lat: Double? = nil, lon: Double? = nil) throws {
        try db.execute(sql: """
            INSERT INTO files (id, content_hash, kind, last_seen_at, lat, lon)
            VALUES (?, ?, 'image', 0, ?, ?)
            """, arguments: [id, hash, lat, lon])
        try db.execute(sql: """
            INSERT INTO paths (id, file_id, absolute_path, is_alive)
            VALUES (?, ?, ?, 1)
            """, arguments: [id + "-p", id, "/tmp/\(id).jpg"])
    }

    /// Epoch seconds for Jan 2 of a year, UTC — inside the year either way the
    /// query interprets it.
    private func earlyIn(_ year: Int) -> Int64 {
        var c = DateComponents()
        c.year = year; c.month = 1; c.day = 2; c.hour = 12
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        return Int64(cal.date(from: c)!.timeIntervalSince1970)
    }

    private func insertMeta(_ db: GRDB.Database, fileID: String, capture: Int64?) throws {
        try db.execute(sql: """
            INSERT INTO photo_meta (file_id, exif_scanned_hash, capture_date)
            VALUES (?, 'h', ?)
            """, arguments: [fileID, capture])
    }

    // MARK: - distinct years

    func testDistinctYearsIsExactAndNewestFirst() throws {
        let q = try makeQueue()
        try q.write { db in
            for (i, year) in [2019, 2019, 2021, 2024, 2024, 2024].enumerated() {
                try insertFile(db, id: "f\(i)", hash: "h\(i)")
                try insertMeta(db, fileID: "f\(i)", capture: earlyIn(year))
            }
        }
        let years = try q.read { db in try SearchFacets.distinctYears(db: db) }
        XCTAssertEqual(years, ["2024", "2021", "2019"])
    }

    /// A gap year with no photos must NOT be offered — the whole point of
    /// keeping the answer exact rather than enumerating min…max.
    func testDistinctYearsSkipsEmptyYears() throws {
        let q = try makeQueue()
        try q.write { db in
            try insertFile(db, id: "a", hash: "ha")
            try insertMeta(db, fileID: "a", capture: earlyIn(2010))
            try insertFile(db, id: "b", hash: "hb")
            try insertMeta(db, fileID: "b", capture: earlyIn(2020))
        }
        let years = try q.read { db in try SearchFacets.distinctYears(db: db) }
        XCTAssertEqual(years, ["2020", "2010"])
    }

    /// The years offered here feed `in:<year>`, which resolves its bounds with a
    /// local `Calendar`. So the label must be the LOCAL year: 2019-12-31 20:00 PST
    /// is 2020 in UTC, and labelling it "2020" offers a facet that `in:2020`
    /// then matches nothing for — the exact "no empty year is ever offered"
    /// promise this query documents.
    func testDistinctYearsLabelsTheLocalYearNotTheUTCYear() throws {
        let q = try makeQueue()
        try q.write { db in
            try insertFile(db, id: "a", hash: "ha")
            try insertMeta(db, fileID: "a", capture: 1_577_851_200)  // 2019-12-31 20:00 PST
        }
        try withTimeZone("America/Los_Angeles") {
            let years = try q.read { db in try SearchFacets.distinctYears(db: db) }
            XCTAssertEqual(years, ["2019"])
        }
    }

    /// The year *step* has to be local for the same reason. Stepping by a UTC
    /// year from a capture whose UTC year already ran ahead jumps clean over the
    /// following local year — so 2020 below used to vanish from the list
    /// entirely, which is a miss rather than a mislabel.
    func testDistinctYearsStepsByLocalYearSoNoYearIsSkipped() throws {
        let q = try makeQueue()
        try q.write { db in
            try insertFile(db, id: "a", hash: "ha")
            try insertMeta(db, fileID: "a", capture: 1_577_851_200)  // 2019-12-31 20:00 PST
            try insertFile(db, id: "b", hash: "hb")
            try insertMeta(db, fileID: "b", capture: 1_591_038_000)  // 2020-06-01 12:00 PDT
        }
        try withTimeZone("America/Los_Angeles") {
            let years = try q.read { db in try SearchFacets.distinctYears(db: db) }
            XCTAssertEqual(years, ["2020", "2019"])
        }
    }

    func testDistinctYearsIgnoresNullCaptureDates() throws {
        let q = try makeQueue()
        try q.write { db in
            try insertFile(db, id: "a", hash: "ha")
            try insertMeta(db, fileID: "a", capture: nil)
        }
        let years = try q.read { db in try SearchFacets.distinctYears(db: db) }
        XCTAssertTrue(years.isEmpty)
    }

    // MARK: - geocode keyset paging

    func testGeocodePageIsBoundedAndAdvances() throws {
        let q = try makeQueue()
        try q.write { db in
            for i in 0..<5 {
                try insertFile(db, id: "g\(i)", hash: "h\(i)", lat: 40.0, lon: -74.0)
            }
        }
        let version = GeoNamesDataset.version
        let first = try q.read { db in
            try GeocodeBackfill.page(db: db, version: version, afterID: nil, limit: 2)
        }
        XCTAssertEqual(first.map(\.fileID), ["g0", "g1"])
        let second = try q.read { db in
            try GeocodeBackfill.page(db: db, version: version, afterID: "g1", limit: 2)
        }
        XCTAssertEqual(second.map(\.fileID), ["g2", "g3"])
    }

    /// A row skipped by the write's content-identity guard must not be able to
    /// stall the loop: paging is by id, so the cursor advances regardless.
    func testGeocodePageSkipsAlreadyGeocodedRows() throws {
        let q = try makeQueue()
        let version = GeoNamesDataset.version
        try q.write { db in
            try insertFile(db, id: "g0", hash: "h0", lat: 1, lon: 1)
            try insertFile(db, id: "g1", hash: "h1", lat: 2, lon: 2)
            var row = PlaceRow(file_id: "g0", geocoded_hash: "h0", dataset_version: version,
                               city: "X", admin: nil, country: "US", place_key: "x||us")
            try row.insert(db)
        }
        let page = try q.read { db in
            try GeocodeBackfill.page(db: db, version: version, afterID: nil, limit: 10)
        }
        XCTAssertEqual(page.map(\.fileID), ["g1"])
    }

    func testGeocodePageReselectsOnDatasetVersionBump() throws {
        let q = try makeQueue()
        let version = GeoNamesDataset.version
        try q.write { db in
            try insertFile(db, id: "g0", hash: "h0", lat: 1, lon: 1)
            var row = PlaceRow(file_id: "g0", geocoded_hash: "h0", dataset_version: version - 1,
                               city: "X", admin: nil, country: "US", place_key: "x||us")
            try row.insert(db)
        }
        let page = try q.read { db in
            try GeocodeBackfill.page(db: db, version: version, afterID: nil, limit: 10)
        }
        XCTAssertEqual(page.map(\.fileID), ["g0"])
    }
}
