//
//  GeoKDTreeTests.swift
//  MuseTests
//
//  3-D k-d tree over unit-sphere coordinates: Euclidean distance on the unit
//  sphere is monotone in great-circle distance, so nearest-neighbour is exact,
//  and the antimeridian/pole edge cases a lat/lon 2-D tree gets wrong simply
//  don't arise.
//

import XCTest
@testable import Muse

final class GeoKDTreeTests: XCTestCase {

    func testNearestMatchesBruteForceOnRandomPoints() {
        var generator = SeededRandom(seed: 42)
        let points: [(lat: Double, lon: Double)] = (0..<2000).map { _ in
            (lat: Double.random(in: -90...90, using: &generator),
             lon: Double.random(in: -180...180, using: &generator))
        }
        let tree = GeoKDTree(points: points)
        let queries: [(lat: Double, lon: Double)] = (0..<100).map { _ in
            (lat: Double.random(in: -90...90, using: &generator),
             lon: Double.random(in: -180...180, using: &generator))
        }
        for q in queries {
            guard let treeResult = tree.nearest(lat: q.lat, lon: q.lon) else {
                XCTFail("tree returned nil"); continue
            }
            var bestDist = Double.greatestFiniteMagnitude
            for p in points {
                let d = GreatCircle.distanceKM(lat1: q.lat, lon1: q.lon, lat2: p.lat, lon2: p.lon)
                if d < bestDist { bestDist = d }
            }
            XCTAssertEqual(treeResult.distanceKM, bestDist, accuracy: 0.01)
        }
    }

    func testAntimeridianPair() {
        // 179.9°E and 179.9°W are ~22 km apart in reality, not ~40,000 km.
        let points = [(lat: 0.0, lon: 179.9), (lat: 0.0, lon: -179.9)]
        let tree = GeoKDTree(points: points)
        let result = tree.nearest(lat: 0.0, lon: 179.95)
        XCTAssertEqual(result?.index, 0)
        XCTAssertLessThan(result?.distanceKM ?? 999, 50)
    }

    func testPolarPoints() {
        let points = [(lat: 89.9, lon: 0.0), (lat: 89.9, lon: 90.0), (lat: 89.9, lon: 180.0)]
        let tree = GeoKDTree(points: points)
        let result = tree.nearest(lat: 90.0, lon: 45.0)
        XCTAssertNotNil(result)
        XCTAssertLessThan(result?.distanceKM ?? 999, 20)
    }

    func testEmptyInputReturnsNil() {
        XCTAssertNil(GeoKDTree(points: []).nearest(lat: 0, lon: 0))
    }

    func testSinglePointTree() {
        let tree = GeoKDTree(points: [(lat: 38.7223, lon: -9.1393)])
        XCTAssertEqual(tree.nearest(lat: 38.7223, lon: -9.1393)?.index, 0)
        XCTAssertEqual(tree.nearest(lat: 38.7223, lon: -9.1393)?.distanceKM ?? -1, 0, accuracy: 0.001)
    }

    func testGreatCircleKnownDistance() {
        // Lisbon to Porto, roughly 275 km.
        let d = GreatCircle.distanceKM(lat1: 38.7223, lon1: -9.1393, lat2: 41.1579, lon2: -8.6291)
        XCTAssertEqual(d, 275, accuracy: 15)
    }

    func testGreatCircleZeroForIdenticalPoints() {
        XCTAssertEqual(GreatCircle.distanceKM(lat1: 10, lon1: 20, lat2: 10, lon2: 20),
                       0, accuracy: 0.0001)
    }

    func testGeoBoundsSplitsAtAntimeridian() {
        XCTAssertEqual(GeoBounds.boxes(lat: 0, lon: 179.9, radiusKM: 50).count, 2)
        XCTAssertEqual(GeoBounds.boxes(lat: 0, lon: -179.9, radiusKM: 50).count, 2)
    }

    func testGeoBoundsSingleBoxAwayFromAntimeridian() {
        XCTAssertEqual(GeoBounds.boxes(lat: 38.7, lon: -9.1, radiusKM: 50).count, 1)
    }

    func testGeoBoundsClampsLatitudeAtPoles() {
        let boxes = GeoBounds.boxes(lat: 89.9, lon: 0, radiusKM: 100)
        XCTAssertLessThanOrEqual(boxes[0].latRange.upperBound, 90)
        XCTAssertGreaterThanOrEqual(boxes[0].latRange.lowerBound, -90)
    }

    func testGeoBoundsWholeGlobeSpanIsOneBox() {
        let boxes = GeoBounds.boxes(lat: 0, lon: 0, radiusKM: 30_000)
        XCTAssertEqual(boxes.count, 1)
        XCTAssertEqual(boxes[0].lonRange, -180...180)
    }

    func testGeoBoundsCoversTheQueryPoint() {
        let boxes = GeoBounds.boxes(lat: 38.7, lon: -9.1, radiusKM: 50)
        XCTAssertTrue(boxes.contains { $0.latRange.contains(38.7) && $0.lonRange.contains(-9.1) })
    }
}
