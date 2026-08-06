//
//  DriveMultipartTests.swift
//  MuseTests
//

import XCTest
@testable import Muse

final class DriveMultipartTests: XCTestCase {
    @MainActor
    func testMultipartBodyHasBothPartsAndBoundary() {
        let body = DriveClient.multipartBody(
            metadata: ["name": "a.jpg"], fileData: Data([0xFF, 0xD8]),
            mime: "image/jpeg", boundary: "BNDRY")
        let text = String(decoding: body, as: UTF8.self)
        XCTAssertTrue(text.contains("--BNDRY"))
        XCTAssertTrue(text.contains("application/json"))
        XCTAssertTrue(text.contains("\"name\":\"a.jpg\"") || text.contains("\"name\": \"a.jpg\""))
        XCTAssertTrue(text.contains("Content-Type: image/jpeg"))
        XCTAssertTrue(text.hasSuffix("--BNDRY--\r\n"))
    }

    // MARK: - mime header-injection guard (defense-in-depth)

    @MainActor
    func testValidMIMEAcceptsRealTypes() {
        for m in ["image/jpeg", "image/png", "image/svg+xml", "image/heic",
                  "application/octet-stream", "image/vnd.adobe.photoshop", "image/x-canon-cr2"] {
            XCTAssertTrue(DriveClient.isValidMIME(m), "\(m) should be accepted")
        }
    }

    @MainActor
    func testValidMIMERejectsInjectionAndMalformed() {
        let bad = [
            "image/png\r\nContent-Type: text/html",         // CRLF header injection
            "image/png\r\n\r\n--BNDRY\r\n",                  // forge a whole extra part
            "image/png\n",                                   // bare LF
            "image/ png",                                    // space (header separator)
            "image/png; charset=x",                          // ';' + space are separators
            "imagepng", "image//png", "/png", "image/", "",  // malformed grammar
        ]
        for m in bad {
            XCTAssertFalse(DriveClient.isValidMIME(m), "\(m.debugDescription) should be rejected")
        }
    }

    @MainActor
    func testMultipartBodyNeutralizesInjectedMIME() {
        // A CRLF-bearing mime must NOT reach the header — it collapses to the
        // neutral default, so no forged header/part appears in the body.
        let body = DriveClient.multipartBody(
            metadata: ["name": "a.jpg"], fileData: Data([0xFF, 0xD8]),
            mime: "image/png\r\nContent-Type: text/html\r\n\r\n<script>", boundary: "BNDRY")
        let text = String(decoding: body, as: UTF8.self)
        XCTAssertFalse(text.contains("text/html"), "injected header must not appear")
        XCTAssertFalse(text.contains("<script>"), "injected body must not appear")
        XCTAssertTrue(text.contains("Content-Type: application/octet-stream"),
                      "off-grammar mime falls back to the neutral default")
        // Exactly the two legitimate parts remain (json + file) → 3 boundary hits.
        XCTAssertEqual(text.components(separatedBy: "--BNDRY").count - 1, 3)
    }

    // MARK: portfolio (Spec 07)

    // JSON sidecars are the ONLY non-image upload path. Their mime is pinned
    // inside the implementation rather than taken from the caller, so neither
    // manifest.json nor layout.json can become a bypass around uploadFile's
    // metadata strip — this pins the body shape that pinning produces.
    @MainActor
    func testManifestUploadBodyUsesJSONMimeAndCorrectMetadata() {
        let json = Data(#"{"i":"x"}"#.utf8)
        let body = DriveClient.multipartBody(
            metadata: ["name": "manifest.json", "parents": ["parent123"]],
            fileData: json, mime: "application/json", boundary: "BNDRY")
        let text = String(decoding: body, as: UTF8.self)
        XCTAssertTrue(text.contains("Content-Type: application/json\r\n"))
        XCTAssertTrue(text.contains("\"name\":\"manifest.json\""))
        XCTAssertTrue(text.contains("\"parents\":[\"parent123\"]"))
        XCTAssertTrue(text.contains(#"{"i":"x"}"#))
        XCTAssertTrue(DriveClient.isValidMIME("application/json"))
    }

    // Test the production URL builder, including the pagination fields required
    // now that 1,000 images + two JSON sidecars exceed one Drive result page.
    @MainActor
    func testListChildrenQueryIsWellFormedEscapedAndPaginated() throws {
        let url = try DriveClient.listChildrenURL(
            of: "abcDEF_12345678901234567890", pageToken: "next page/token")
        let comps = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let items = Dictionary(uniqueKeysWithValues:
            (comps.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(items["q"], "'abcDEF_12345678901234567890' in parents and trashed=false")
        XCTAssertEqual(items["fields"], "nextPageToken,files(id,name)")
        XCTAssertEqual(items["pageSize"], "1000")
        XCTAssertEqual(items["pageToken"], "next page/token")
        XCTAssertFalse(url.absoluteString.contains(" "), "spaces must be percent-encoded")
    }

    @MainActor
    func testDriveFileIDValidationRejectsPathAndQueryInjection() {
        XCTAssertTrue(DriveClient.isValidFileID("abcDEF_12345678901234567890"))
        for id in ["short", "abcDEF_123456789012345/../../x",
                   "abcDEF_123456789012345' or '1'='1", "abc DEF_12345678901234567890"] {
            XCTAssertFalse(DriveClient.isValidFileID(id), id)
            XCTAssertThrowsError(try DriveClient.listChildrenURL(of: id))
        }
    }
}
