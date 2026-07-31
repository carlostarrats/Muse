//
//  GeoNamesDatasetTests.swift
//  MuseTests
//
//  Bounded-inflate contract (a bundled file is not attacker-controlled, but
//  the guard is three lines and makes the loader reusable and testable) + TSV
//  parsing + the admin1 join.
//

import XCTest
@testable import Muse

final class GeoNamesDatasetTests: XCTestCase {

    func testLoadsBundledCities() {
        let cities = GeoNamesDataset.shared.cities()
        XCTAssertNotNil(cities)
        XCTAssertGreaterThan(cities?.count ?? 0, 0)
        XCTAssertTrue(cities?.contains { $0.name == "Lisboa" } ?? false)
    }

    func testAdmin1NameResolvesKnownCode() {
        XCTAssertNotNil(GeoNamesDataset.shared.admin1Name(for: "PT.14"))
    }

    func testUnknownAdmin1CodeReturnsNil() {
        XCTAssertNil(GeoNamesDataset.shared.admin1Name(for: "ZZ.99"))
    }

    func testCorruptDeclaredSizeFailsClosed() {
        // A declared size that doesn't match the payload must return nil —
        // never crash, never over-allocate.
        var bad = Data()
        bad.append(contentsOf: withUnsafeBytes(of: UInt32(999_999).littleEndian) { Array($0) })
        bad.append(contentsOf: [0x03, 0x00, 0x00, 0x00, 0x00, 0x01])
        XCTAssertNil(GeoNamesDataset.loadCities(from: bad))
    }

    func testAbsurdDeclaredSizeRejectedBeforeAllocation() {
        var bad = Data()
        bad.append(contentsOf: withUnsafeBytes(of: UInt32.max.littleEndian) { Array($0) })
        bad.append(contentsOf: [0x03, 0x00])
        XCTAssertNil(GeoNamesDataset.loadCities(from: bad))
    }

    func testTooShortBufferReturnsNil() {
        XCTAssertNil(GeoNamesDataset.loadCities(from: Data([0, 1, 2])))
    }
}
