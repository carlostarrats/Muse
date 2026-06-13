import XCTest
@testable import Muse

final class SidecarTests: XCTestCase {
    private func sampleSidecar() -> Sidecar {
        Sidecar(
            schema: 1,
            updated_at: 1000,
            content_hash: "abc123",
            kind: "image",
            width: 1920,
            height: 1080,
            duration_seconds: nil,
            created_at: 10,
            modified_at: 20,
            caption: "a dog on a beach",
            dominant_color: "#11AA33",
            palette: "[\"#11AA33\"]",
            feature_print: Data([1, 2, 3, 4]),
            analyzed_hash: "abc123",
            intent: nil,
            intent_model_version: nil,
            tags: [
                SidecarTag(label: "dog", source: "vision", confidence: 0.9, model_version: "v1"),
                SidecarTag(label: "favorite", source: "manual", confidence: nil, model_version: nil),
            ]
        )
    }

    func testJSONRoundTrip() throws {
        let original = sampleSidecar()
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Sidecar.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    func testFeaturePrintSurvivesAsBase64() throws {
        let original = sampleSidecar()
        let data = try JSONEncoder().encode(original)
        // Foundation encodes Data as a base64 string by default — assert it's
        // textual JSON (no raw bytes), so the sidecar is portable to iOS.
        let json = String(data: data, encoding: .utf8)
        XCTAssertNotNil(json)
        let decoded = try JSONDecoder().decode(Sidecar.self, from: data)
        XCTAssertEqual(decoded.feature_print, Data([1, 2, 3, 4]))
    }
}

extension SidecarTests {
    func testBuildFromFileRowAndTags() {
        let file = FileRow(
            id: "f1", content_hash: "abc123", kind: "image",
            size_bytes: 100, width: 1920, height: 1080,
            duration_seconds: nil, created_at: 10, modified_at: 20,
            last_seen_at: 999, caption: "a dog", dominant_color: "#112233",
            feature_print: Data([9, 9]), palette: "[]",
            analyzed_hash: "abc123", intent: "recipe", intent_model_version: "iv1"
        )
        let tags = [
            TagRow(id: "t1", file_id: "f1", label: "dog", source: "vision",
                   confidence: 0.8, model_version: "v1"),
            TagRow(id: "t2", file_id: "f1", label: "fav", source: "manual",
                   confidence: nil, model_version: nil),
        ]
        let sc = Sidecar.build(from: file, tags: tags, updatedAt: 555)
        XCTAssertEqual(sc?.content_hash, "abc123")
        XCTAssertEqual(sc?.caption, "a dog")
        XCTAssertEqual(sc?.intent, "recipe")
        XCTAssertEqual(sc?.updated_at, 555)
        XCTAssertEqual(sc?.tags.count, 2)
        XCTAssertEqual(sc?.tags.first(where: { $0.source == "manual" })?.label, "fav")
    }

    func testBuildReturnsNilWithoutContentHash() {
        let file = FileRow(
            id: "f1", content_hash: nil, kind: "image",
            size_bytes: nil, width: nil, height: nil, duration_seconds: nil,
            created_at: nil, modified_at: nil, last_seen_at: 0, caption: nil,
            dominant_color: nil, feature_print: nil, palette: nil,
            analyzed_hash: nil, intent: nil, intent_model_version: nil
        )
        XCTAssertNil(Sidecar.build(from: file, tags: [], updatedAt: 1))
    }

    func testApplyOntoFileRowPreservesIdentityColumns() {
        let sc = sampleSidecar()                       // content_hash "abc123"
        var existing = FileRow(
            id: "keep-me", content_hash: "abc123", kind: "image",
            size_bytes: 42, width: nil, height: nil, duration_seconds: nil,
            created_at: nil, modified_at: nil, last_seen_at: 7, caption: nil,
            dominant_color: nil, feature_print: nil, palette: nil,
            analyzed_hash: nil, intent: nil, intent_model_version: nil
        )
        sc.apply(onto: &existing)
        XCTAssertEqual(existing.id, "keep-me")         // id never overwritten
        XCTAssertEqual(existing.size_bytes, 42)        // local-only column kept
        XCTAssertEqual(existing.last_seen_at, 7)       // device-local, kept
        XCTAssertEqual(existing.caption, "a dog on a beach")  // hydrated
        XCTAssertEqual(existing.analyzed_hash, "abc123")
    }

    func testTagRowsFactory() {
        let sc = sampleSidecar()
        var counter = 0
        let rows = sc.tagRows(fileID: "f1") { counter += 1; return "id\(counter)" }
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0].file_id, "f1")
        XCTAssertEqual(Set(rows.map(\.id)), ["id1", "id2"])
    }
}
