//
//  SmartRuleLocationTests.swift
//  MuseTests
//
//  Round-trip Codable, isValid branches, resolver `.place` (incl. a localized
//  country name resolving back to its ISO code) and `.near` (bbox + haversine,
//  antimeridian split).
//

import XCTest
import GRDB
@testable import Muse

final class SmartRuleLocationTests: XCTestCase {

    func testLocationPlaceRoundTripsCodable() {
        let set = SmartRuleSet(match: .all, rules: [.location(.place("Lisboa"))])
        guard let json = set.encodedJSON() else { return XCTFail("no JSON") }
        XCTAssertEqual(SmartRuleSet.decode(json), set)
    }

    func testLocationNearRoundTripsCodable() {
        let set = SmartRuleSet(match: .all,
                               rules: [.location(.near(lat: 38.72, lon: -9.14, radiusKM: 50))])
        guard let json = set.encodedJSON() else { return XCTFail("no JSON") }
        XCTAssertEqual(SmartRuleSet.decode(json), set)
    }

    func testPlaceIsValidRequiresNonBlank() {
        XCTAssertFalse(SmartRule.location(.place("  ")).isValid)
        XCTAssertTrue(SmartRule.location(.place("Lisboa")).isValid)
    }

    func testNearIsValidRequiresSaneCoordinatesAndPositiveRadius() {
        XCTAssertFalse(SmartRule.location(.near(lat: 91, lon: 0, radiusKM: 10)).isValid)
        XCTAssertFalse(SmartRule.location(.near(lat: 0, lon: 0, radiusKM: 0)).isValid)
        XCTAssertTrue(SmartRule.location(.near(lat: 38.72, lon: -9.14, radiusKM: 10)).isValid)
    }

    private func placedQueue() throws -> DatabaseQueue {
        let queue = try DatabaseQueue()
        try Database.makeMigrator().migrate(queue)
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO files (id, content_hash, kind, last_seen_at) VALUES ('f1','h1','image',0)
                """)
            try db.execute(sql: """
                INSERT INTO places (file_id, geocoded_hash, dataset_version, city, admin, country, place_key)
                VALUES ('f1','h1',1,'Lisboa','Lisbon','PT','lisboa|lisbon|pt')
                """)
        }
        return queue
    }

    private func members(_ rule: SmartRule, _ queue: DatabaseQueue) throws -> Set<String> {
        try queue.read { db in
            try SmartCollectionResolver.memberIDs(SmartRuleSet(match: .all, rules: [rule]), db: db)
        }
    }

    func testResolverPlaceMatchesCityCaseInsensitive() throws {
        XCTAssertEqual(try members(.location(.place("lisboa")), try placedQueue()), ["f1"])
    }

    func testResolverPlaceMatchesAdmin() throws {
        XCTAssertEqual(try members(.location(.place("Lisbon")), try placedQueue()), ["f1"])
    }

    func testResolverPlaceMatchesLocalizedCountryName() throws {
        // The DB stores "PT"; the user types the display name.
        XCTAssertEqual(try members(.location(.place("Portugal")), try placedQueue()), ["f1"])
    }

    func testResolverPlaceNoMatch() throws {
        XCTAssertTrue(try members(.location(.place("Reykjavik")), try placedQueue()).isEmpty)
    }

    func testResolverNearMatchesWithinRadius() throws {
        let queue = try DatabaseQueue()
        try Database.makeMigrator().migrate(queue)
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO files (id, content_hash, kind, last_seen_at, lat, lon)
                VALUES ('f1','h1','image',0,38.7223,-9.1393), ('f2','h2','image',0,30.0,-40.0)
                """)
        }
        XCTAssertEqual(try members(.location(.near(lat: 38.72, lon: -9.14, radiusKM: 20)), queue),
                       ["f1"])
    }

    func testResolverNearSplitsAcrossAntimeridian() throws {
        let queue = try DatabaseQueue()
        try Database.makeMigrator().migrate(queue)
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO files (id, content_hash, kind, last_seen_at, lat, lon)
                VALUES ('f1','h1','image',0,0.0,179.95)
                """)
        }
        // ~11 km apart across ±180°.
        XCTAssertEqual(try members(.location(.near(lat: 0, lon: -179.95, radiusKM: 50)), queue),
                       ["f1"])
    }
}
