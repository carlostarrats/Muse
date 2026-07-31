//
//  ReverseGeocoderTests.swift
//  MuseTests
//
//  Offline reverse geocoding: nearest bundled settlement within 150 km, else
//  nil (which the backfill stores as a NULL-place attempted-marker row).
//

import XCTest
@testable import Muse

final class ReverseGeocoderTests: XCTestCase {

    private func fixtureCities() -> [GeoCity] {
        [GeoCity(name: "Lisboa", lat: 38.7223, lon: -9.1393, admin1Code: "PT.14", countryCode: "PT"),
         GeoCity(name: "Porto", lat: 41.1579, lon: -8.6291, admin1Code: "PT.13", countryCode: "PT")]
    }

    private func resolve(lat: Double, lon: Double) -> ReverseGeocoder.Place? {
        let cities = fixtureCities()
        let tree = GeoKDTree(points: cities.map { ($0.lat, $0.lon) })
        return ReverseGeocoder.place(lat: lat, lon: lon, tree: tree, cities: cities,
                                     dataset: GeoNamesDataset.shared)
    }

    func testKnownCoordinateResolvesExpectedCity() {
        let place = resolve(lat: 38.72, lon: -9.14)
        XCTAssertEqual(place?.city, "Lisboa")
        XCTAssertEqual(place?.country, "PT")
    }

    func testFarAwayCoordinateReturnsNil() {
        // Middle of the Atlantic, well over 150 km from either fixture city.
        XCTAssertNil(resolve(lat: 30.0, lon: -40.0))
    }

    func testPlaceKeyIsLowercasedComposite() {
        let place = resolve(lat: 38.72, lon: -9.14)
        XCTAssertEqual(place?.key, place?.key.lowercased())
        XCTAssertTrue(place?.key.contains("lisboa") ?? false)
        XCTAssertTrue(place?.key.hasSuffix("|pt") ?? false)
    }

    func testPlaceKeyLeavesAnEmptySegmentForMissingAdmin() {
        XCTAssertEqual(ReverseGeocoder.placeKey(city: "Nowhere", admin: nil, country: "XX"),
                       "nowhere||xx")
    }

    func testJustWithinRangeResolvesAndJustBeyondDoesNot() {
        // Walk due south from Lisboa: 1° of latitude ≈ 111.2 km.
        let inside = resolve(lat: 38.7223 - (149.0 / 111.2), lon: -9.1393)
        XCTAssertEqual(inside?.city, "Lisboa")
        let outside = resolve(lat: 38.7223 - (200.0 / 111.2), lon: -9.1393)
        // 200 km south of Lisboa is also >150 km from Porto (which is north).
        XCTAssertNil(outside)
    }

    func testEmptyCityListReturnsNil() {
        XCTAssertNil(ReverseGeocoder.place(lat: 0, lon: 0, tree: GeoKDTree(points: []),
                                           cities: [], dataset: GeoNamesDataset.shared))
    }
}
