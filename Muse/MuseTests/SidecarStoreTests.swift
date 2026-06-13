import XCTest
@testable import Muse

final class SidecarStoreTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("muse-sidecar-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func sample(hash: String) -> Sidecar {
        Sidecar(schema: 1, updated_at: 1, content_hash: hash, kind: "image",
                width: 1, height: 1, duration_seconds: nil, created_at: nil,
                modified_at: nil, caption: "c", dominant_color: nil, palette: nil,
                feature_print: nil, analyzed_hash: hash, intent: nil,
                intent_model_version: nil, tags: [])
    }

    func testWriteThenReadRoundTrip() throws {
        let asset = tempDir.appendingPathComponent("photo.jpg")
        try Data([0]).write(to: asset)
        let sc = sample(hash: "hash1")
        try SidecarStore.write(sc, forAsset: asset)
        let back = SidecarStore.read(forAsset: asset, contentHash: "hash1")
        XCTAssertEqual(back, sc)
    }

    func testSidecarLandsInHiddenMuseDir() throws {
        let asset = tempDir.appendingPathComponent("photo.jpg")
        try Data([0]).write(to: asset)
        try SidecarStore.write(sample(hash: "hash1"), forAsset: asset)
        let expected = tempDir.appendingPathComponent(".muse/hash1.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: expected.path))
    }

    func testReadMissingReturnsNil() {
        let asset = tempDir.appendingPathComponent("nope.jpg")
        XCTAssertNil(SidecarStore.read(forAsset: asset, contentHash: "absent"))
    }
}
