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
