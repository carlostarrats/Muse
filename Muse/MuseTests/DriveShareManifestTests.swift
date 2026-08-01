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

    func testFilenamesRoundTrip() {
        var m = sample
        m.filenames = ["Sunset_final.jpg", "IMG_4821.png"]
        XCTAssertEqual(DriveShareManifest.decode(m.encoded()), m)
    }

    // A large manifest crosses the threshold where DEFLATE beats raw JSON, so this
    // exercises the compressed (0x01-marker) path round-tripping.
    func testCompressedLargeManifestRoundTrips() {
        var m = sample
        m.imageIDs = (0..<300).map { String(format: "img%017d", $0) }
        m.filenames = (0..<300).map { "Photo_\($0)_final_export.jpg" }
        let encoded = m.encoded()
        XCTAssertNil(encoded.rangeOfCharacter(from: CharacterSet(charactersIn: "+/=")))
        XCTAssertEqual(DriveShareManifest.decode(encoded), m)
    }

    // Links produced before compression (raw base64url JSON, no 0x01 marker) must
    // still decode. Build the legacy form directly: plain JSON → base64url, no
    // deflate, mirroring the pre-compression encoder.
    func testDecodesLegacyUncompressedLink() {
        let json = try! JSONEncoder().encode(sample)
        let legacy = json.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        XCTAssertEqual(legacy.first, "e", "legacy link is uncompressed (base64 of JSON starts with 'e' for '{')")
        XCTAssertEqual(DriveShareManifest.decode(legacy), sample)
    }

    // MARK: v2 (Spec 07) — layout / bodyText / manifestID

    func testV2FieldsRoundTrip() {
        var m = sample
        m.layout = DriveShareLayout.essay.rawValue
        m.bodyText = "An intro paragraph."
        m.manifestID = "dddddddddddddddddddd"
        XCTAssertEqual(DriveShareManifest.decode(m.encoded()), m)
    }

    // A manifest not using a v2 feature must encode with NONE of the new keys —
    // the wire shape stays byte-identical to the pre-Spec-07 format.
    func testNilV2FieldsEncodeNoNewKeys() throws {
        let json = try JSONEncoder().encode(sample)
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: json) as? [String: Any])
        XCTAssertNil(obj["y"])
        XCTAssertNil(obj["s"])
        XCTAssertNil(obj["m"])
    }

    func testPortfolioManifestWithEmptyExpiryRoundTrips() {
        var m = sample
        m.expiry = ""
        m.manifestID = "eeeeeeeeeeeeeeeeeeee"
        let decoded = DriveShareManifest.decode(m.encoded())
        XCTAssertEqual(decoded?.expiry, "")
        XCTAssertEqual(decoded?.manifestID, "eeeeeeeeeeeeeeeeeeee")
    }

    func testJSONDataParsesAsSameObject() throws {
        var m = sample
        m.layout = DriveShareLayout.sheet.rawValue
        let data = m.jsonData()
        XCTAssertEqual(try JSONDecoder().decode(DriveShareManifest.self, from: data), m)
        // jsonData() is plain (uncompressed, un-base64'd) JSON — first byte '{'.
        XCTAssertEqual(data.first, UInt8(ascii: "{"))
    }

    func testMaxImagesAndMaxFieldLengthConstants() {
        XCTAssertEqual(DriveShareManifest.maxImages, 1000)
        XCTAssertEqual(DriveShareManifest.maxFieldLength, 4096)
    }

    // Wire values — share.js's layoutOf must match these exactly.
    func testDriveShareLayoutRawValues() {
        XCTAssertEqual(DriveShareLayout.grid.rawValue, "grid")
        XCTAssertEqual(DriveShareLayout.sheet.rawValue, "sheet")
        XCTAssertEqual(DriveShareLayout.essay.rawValue, "essay")
        XCTAssertEqual(DriveShareLayout.allCases.count, 3)
    }
}
