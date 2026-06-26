//
//  DriveShareManifestTests.swift
//  MuseTests
//

import XCTest
@testable import Muse

final class DriveShareManifestTests: XCTestCase {
    private let sample = DriveShareManifest(
        intro: "Leslie-Ann Thomson ALDO MUAH 2025", label: "Sent by",
        name: "The Project", date: "2026-04-01", expiry: "2026-04-04",
        imageIDs: ["aaaaaaaaaaaaaaaaaaaa", "bbbbbbbbbbbbbbbbbbbb"], pdfID: "cccccccccccccccccccc")

    func testRoundTripThroughBase64URL() {
        let encoded = sample.encoded()
        XCTAssertNil(encoded.rangeOfCharacter(from: CharacterSet(charactersIn: "+/=")))
        XCTAssertEqual(DriveShareManifest.decode(encoded), sample)
    }

    func testPageURLUsesFragment() {
        let url = sample.pageURL(base: "https://share.example.com/s")
        XCTAssertTrue(url.hasPrefix("https://share.example.com/s#"))
        XCTAssertEqual(DriveShareManifest.decode(String(url.split(separator: "#")[1])), sample)
    }

    func testDecodeRejectsGarbage() {
        XCTAssertNil(DriveShareManifest.decode("not-valid-base64url!!"))
    }
}
