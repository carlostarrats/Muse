//
//  AutoTintTests.swift
//  MuseTests
//
//  Auto mood (polish spec §4): blends the view's dominant colors into a
//  dark tinted background — hue preserved, saturation capped, brightness
//  pinned low so thumbnails/text hold up.
//

import XCTest
import GRDB
@testable import Muse

final class AutoTintTests: XCTestCase {
    func testBlendKeepsHueAndPinsDark() {
        let t = AutoTint.blend(hexes: ["#FF0000", "#EE1100"])!
        // red hue survives
        XCTAssertGreaterThan(t.background.r, t.background.g)
        XCTAssertGreaterThan(t.background.r, t.background.b)
        // pinned dark
        XCTAssertLessThan(max(t.background.r, t.background.g, t.background.b), 0.18)
        // tile reads brighter than the background
        XCTAssertGreaterThan(t.tile.r, t.background.r)
        // resolved palette is dark-scheme
        XCTAssertEqual(t.palette.scheme, .dark)
    }

    func testBlendEmptyOrUnparseableReturnsNil() {
        XCTAssertNil(AutoTint.blend(hexes: []))
        XCTAssertNil(AutoTint.blend(hexes: ["not-a-color"]))
    }

    func testHSBRoundTrip() {
        let cases: [(Double, Double, Double)] =
            [(0.2, 0.4, 0.8), (0.9, 0.1, 0.3), (0.5, 0.5, 0.5), (1.0, 0.0, 0.0)]
        for (r, g, b) in cases {
            let (h, s, v) = AutoTint.rgbToHSB(r, g, b)
            let (r2, g2, b2) = AutoTint.hsbToRGB(h, s, v)
            XCTAssertEqual(r, r2, accuracy: 1e-9)
            XCTAssertEqual(g, g2, accuracy: 1e-9)
            XCTAssertEqual(b, b2, accuracy: 1e-9)
        }
    }

    func testDominantColorsQueryFiltersAliveAndNonNull() async throws {
        let q = try DatabaseQueue()
        try Database.makeMigrator().migrate(q)
        try await q.write { db in
            try db.execute(sql: """
                INSERT INTO files (id, kind, last_seen_at, dominant_color)
                VALUES ('f1', 'image', 0, '#AA3322')
                """)
            try db.execute(sql: """
                INSERT INTO files (id, kind, last_seen_at) VALUES ('f2', 'image', 0)
                """)
            try db.execute(sql: """
                INSERT INTO paths (id, file_id, absolute_path, is_alive)
                VALUES ('p1', 'f1', '/a/x.png', 1),
                       ('p2', 'f2', '/a/y.png', 1),
                       ('p3', 'f1', '/a/dead.png', 0)
                """)
        }
        let colors = try await AutoTint.dominantColors(
            queue: q, paths: ["/a/x.png", "/a/y.png", "/a/dead.png"])
        XCTAssertEqual(colors, ["#AA3322"])
    }
}
