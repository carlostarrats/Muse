//
//  CoordinateReaderTests.swift
//  MuseTests
//
//  Header-only GPS extraction, shared with FileMetadata's display-time reader —
//  must never diverge (a viewer showing one location while the DB stores
//  another is worse than no column).
//

import XCTest
@testable import Muse

final class CoordinateReaderTests: XCTestCase {

    func testSanitizeAcceptsValidRange() {
        let c = Coordinate(lat: 38.7223, long: -9.1393)
        XCTAssertEqual(CoordinateReader.sanitize(c)?.lat, 38.7223)
        XCTAssertEqual(CoordinateReader.sanitize(c)?.long, -9.1393)
    }

    func testSanitizeRejectsOutOfRangeLatitude() {
        XCTAssertNil(CoordinateReader.sanitize(Coordinate(lat: 91, long: 0)))
        XCTAssertNil(CoordinateReader.sanitize(Coordinate(lat: -91, long: 0)))
    }

    func testSanitizeRejectsOutOfRangeLongitude() {
        XCTAssertNil(CoordinateReader.sanitize(Coordinate(lat: 0, long: 181)))
        XCTAssertNil(CoordinateReader.sanitize(Coordinate(lat: 0, long: -181)))
    }

    func testSanitizeRejectsNonFiniteValues() {
        XCTAssertNil(CoordinateReader.sanitize(Coordinate(lat: .nan, long: 0)))
        XCTAssertNil(CoordinateReader.sanitize(Coordinate(lat: 0, long: .infinity)))
    }

    func testSanitizeAcceptsBoundaryValues() {
        XCTAssertNotNil(CoordinateReader.sanitize(Coordinate(lat: 90, long: 180)))
        XCTAssertNotNil(CoordinateReader.sanitize(Coordinate(lat: -90, long: -180)))
    }

    func testReadReturnsNilForUnsupportedKind() async {
        let url = URL(fileURLWithPath: "/tmp/muse-coord-nonexistent.txt")
        let result = await CoordinateReader.read(url: url, kind: .text)
        XCTAssertNil(result)
    }

    func testReadReturnsNilForMissingImageFile() async {
        let url = URL(fileURLWithPath: "/tmp/muse-coord-nonexistent.jpg")
        let result = await CoordinateReader.read(url: url, kind: .image)
        XCTAssertNil(result)
    }

    /// The whole point of the shared-pure-function design: a GPS dictionary
    /// with S/W refs signs the same way in both readers.
    func testMirrorsFileMetadataSigningConvention() {
        let southWest = FileMetadata.coordinate(latitude: 33.8688, latRef: "S",
                                                longitude: 151.2093, longRef: "W")
        XCTAssertEqual(CoordinateReader.sanitize(southWest!)?.lat, -33.8688)
        XCTAssertEqual(CoordinateReader.sanitize(southWest!)?.long, -151.2093)
    }
}
