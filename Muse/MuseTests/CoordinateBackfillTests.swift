//
//  CoordinateBackfillTests.swift
//  MuseTests
//
//  IntentBackfill (this pass's model) has no test of its own; the pure,
//  cheaply-testable part here is candidate selection — which is also the part
//  that decides whether the pass terminates. A kind CoordinateReader can't
//  handle never gets a coords_scanned_hash, so admitting one would re-select it
//  on every launch forever.
//

import XCTest
import GRDB
@testable import Muse

final class CoordinateBackfillTests: XCTestCase {

    func testAdmitsImageRawAndVideoKinds() {
        XCTAssertNotNil(CoordinateBackfill.candidate(id: "a", path: "/tmp/a.jpg"))
        XCTAssertNotNil(CoordinateBackfill.candidate(id: "b", path: "/tmp/b.dng"))
        XCTAssertNotNil(CoordinateBackfill.candidate(id: "c", path: "/tmp/c.mov"))
    }

    func testRejectsKindsWithNoCoordinateSource() {
        XCTAssertNil(CoordinateBackfill.candidate(id: "d", path: "/tmp/d.txt"))
        XCTAssertNil(CoordinateBackfill.candidate(id: "e", path: "/tmp/e.pdf"))
        XCTAssertNil(CoordinateBackfill.candidate(id: "f", path: "/tmp/f.ttf"))
    }

    func testCandidateCarriesTheDetectedKind() {
        XCTAssertEqual(CoordinateBackfill.candidate(id: "a", path: "/tmp/a.jpg")?.kind, .image)
        XCTAssertEqual(CoordinateBackfill.candidate(id: "c", path: "/tmp/c.mov")?.kind, .video)
    }

    /// The selection predicate the pass runs on the DB: unscanned rows and rows
    /// whose bytes changed since the scan, never rows already stamped at their
    /// current hash.
    func testSelectionSQLPicksUnscannedAndStaleRowsOnly() throws {
        let q = try DatabaseQueue()
        try Database.makeMigrator().migrate(q)
        try q.write { db in
            try db.execute(sql: """
                INSERT INTO files (id, content_hash, kind, last_seen_at, coords_scanned_hash) VALUES
                  ('unscanned', 'h1', 'image', 0, NULL),
                  ('stale',     'h2', 'image', 0, 'old'),
                  ('current',   'h3', 'image', 0, 'h3')
                """)
        }
        let selected = try q.read { db in
            try String.fetchAll(db, sql: """
                SELECT f.id FROM files f
                WHERE (f.coords_scanned_hash IS NULL
                       OR f.coords_scanned_hash != f.content_hash)
                  AND f.content_hash IS NOT NULL
                ORDER BY f.id
                """)
        }
        XCTAssertEqual(selected, ["stale", "unscanned"])
    }
}
