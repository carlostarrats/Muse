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
}
