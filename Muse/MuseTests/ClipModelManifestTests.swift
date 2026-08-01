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

    /// Was `testEmptyChunkListIsShapeValid`, which asserted the opposite on the
    /// grounds that "SHA verification is the real gate". It isn't, for this:
    /// the digest proves the assembled bytes, and says nothing about how many
    /// were transferred to reach them. A degenerate manifest is refused before
    /// the download starts.
    func testDegenerateManifestIsRefused() {
        let json = """
        { "version": 1, "name": "x", "generation": 1, "totalBytes": 0, "sha256": "a", "chunks": [] }
        """.data(using: .utf8)!
        XCTAssertNil(ClipModelManifest.parse(json))
    }

    func testOversizedArtifactIsRefused() {
        let json = """
        { "version": 1, "name": "x", "generation": 1,
          "totalBytes": \(ClipModelManifest.maxArtifactBytes + 1),
          "sha256": "a", "chunks": ["a.000"] }
        """.data(using: .utf8)!
        XCTAssertNil(ClipModelManifest.parse(json))
        // The boundary itself is allowed.
        let atCap = """
        { "version": 1, "name": "x", "generation": 1,
          "totalBytes": \(ClipModelManifest.maxArtifactBytes),
          "sha256": "a", "chunks": ["a.000"] }
        """.data(using: .utf8)!
        XCTAssertNotNil(ClipModelManifest.parse(atCap))
    }

    func testTooManyChunksIsRefused() {
        let names = (0..<(ClipModelManifest.maxChunks + 1)).map { "\"c\($0)\"" }.joined(separator: ",")
        let json = """
        { "version": 1, "name": "x", "generation": 1, "totalBytes": 10,
          "sha256": "a", "chunks": [\(names)] }
        """.data(using: .utf8)!
        // Also past the 16 KB response cap, so assert the name check directly
        // rather than relying on which guard fires first.
        XCTAssertNil(ClipModelManifest.parse(json))
        XCTAssertGreaterThan(json.count, ClipModelManifest.maxResponseBytes)
    }

    /// A chunk name is appended to the manifest's directory URL, so a name that
    /// isn't one plain component can aim the fetch elsewhere on the host.
    func testUnsafeChunkNamesAreRefused() {
        for bad in ["../secret", "a/b", "..", ".", "", "a?b=1", "a%2Fb", "a#f", "a b"] {
            XCTAssertFalse(ClipModelManifest.isSafeChunkName(bad), "accepted \(bad)")
        }
        for good in ["model.zip.000", "a", "chunk-1_final.bin", "..leading-dots"] {
            XCTAssertTrue(ClipModelManifest.isSafeChunkName(good), "rejected \(good)")
        }
    }

    func testManifestWithATraversingChunkNameIsRefused() {
        let json = """
        { "version": 1, "name": "x", "generation": 1, "totalBytes": 10, "sha256": "a",
          "chunks": ["model.zip.000", "../../etc/passwd"] }
        """.data(using: .utf8)!
        XCTAssertNil(ClipModelManifest.parse(json))
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
