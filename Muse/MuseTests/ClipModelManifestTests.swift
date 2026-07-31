//
//  ClipModelManifestTests.swift
//  MuseTests
//

import XCTest
@testable import Muse

final class ClipModelManifestTests: XCTestCase {
    func testValidManifestParses() {
        let json = """
        { "version": 1, "name": "mobileclip-s2", "generation": 1,
          "totalBytes": 204812345, "sha256": "abc123",
          "chunks": ["model.zip.000", "model.zip.001"] }
        """.data(using: .utf8)!
        let manifest = ClipModelManifest.parse(json)
        XCTAssertNotNil(manifest)
        XCTAssertEqual(manifest?.chunks.count, 2)
        XCTAssertEqual(manifest?.totalBytes, 204812345)
    }

    func testUnknownVersionIsRefused() {
        let json = """
        { "version": 99, "name": "x", "generation": 1, "totalBytes": 1, "sha256": "a", "chunks": [] }
        """.data(using: .utf8)!
        XCTAssertNil(ClipModelManifest.parse(json))
    }

    func testOversizedResponseIsRefused() {
        let oversized = Data(repeating: 0x41, count: 17 * 1024) // > the 16 KB cap
        XCTAssertNil(ClipModelManifest.parse(oversized))
    }

    func testMalformedJSONReturnsNil() {
        XCTAssertNil(ClipModelManifest.parse(Data("not json".utf8)))
    }

    func testEmptyChunkListIsShapeValid() {
        // Shape-valid even if degenerate; SHA verification is the real gate.
        let json = """
        { "version": 1, "name": "x", "generation": 1, "totalBytes": 0, "sha256": "a", "chunks": [] }
        """.data(using: .utf8)!
        XCTAssertNotNil(ClipModelManifest.parse(json))
    }

    func testShaVerificationRejectsMismatch() {
        XCTAssertFalse(ClipModelManifest.verify(assembled: Data("hello".utf8),
                                                 expectedSHA256: "wrong-hash"))
    }

    func testShaVerificationAcceptsMatch() {
        let data = Data("hello".utf8)
        XCTAssertTrue(ClipModelManifest.verify(assembled: data,
                                                expectedSHA256: ClipModelManifest.sha256Hex(data)))
    }
}
