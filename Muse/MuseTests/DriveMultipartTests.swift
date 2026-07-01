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
}
