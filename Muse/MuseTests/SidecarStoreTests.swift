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
        let expected = tempDir.appendingPathComponent(".muse/hash1__photo.jpg.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: expected.path))
    }

    func testReadMissingReturnsNil() {
        let asset = tempDir.appendingPathComponent("nope.jpg")
        XCTAssertNil(SidecarStore.read(forAsset: asset, contentHash: "absent"))
    }

    /// The collision per-file identity turns from a curiosity into a real case:
    /// two byte-identical files in ONE folder used to share a single
    /// `<hash>.json`, so per-file data could not round-trip through sync.
    func testTwoCopiesInOneFolderGetSeparateSidecars() {
        let a = tempDir.appendingPathComponent("one.arw")
        let b = tempDir.appendingPathComponent("one copy.arw")
        XCTAssertNotEqual(SidecarStore.sidecarURL(forAsset: a, contentHash: "H"),
                          SidecarStore.sidecarURL(forAsset: b, contentHash: "H"))
    }

    /// Each copy's sidecar must survive the other being written.
    func testEachCopyKeepsItsOwnSidecarContents() throws {
        let a = tempDir.appendingPathComponent("one.arw")
        let b = tempDir.appendingPathComponent("one copy.arw")
        try Data([0]).write(to: a)
        try Data([0]).write(to: b)
        var scA = sample(hash: "H"); scA.caption = "caption A"
        var scB = sample(hash: "H"); scB.caption = "caption B"
        try SidecarStore.write(scA, forAsset: a)
        try SidecarStore.write(scB, forAsset: b)
        XCTAssertEqual(SidecarStore.read(forAsset: a, contentHash: "H")?.caption, "caption A")
        XCTAssertEqual(SidecarStore.read(forAsset: b, contentHash: "H")?.caption, "caption B")
    }

    /// A library already synced carries the OLD `<hash>.json` names. They must
    /// still hydrate, or upgrading looks like every sidecar vanished.
    func testLegacyHashOnlyNameIsStillReadable() throws {
        let asset = tempDir.appendingPathComponent("photo.jpg")
        try Data([0]).write(to: asset)
        let museDir = tempDir.appendingPathComponent(".muse", isDirectory: true)
        try FileManager.default.createDirectory(at: museDir, withIntermediateDirectories: true)
        let legacy = museDir.appendingPathComponent("hash1.json")
        try JSONEncoder().encode(sample(hash: "hash1")).write(to: legacy)

        XCTAssertEqual(SidecarStore.read(forAsset: asset, contentHash: "hash1"),
                       sample(hash: "hash1"))
    }

    /// When both names exist the NEW one wins — it is the per-file truth, and
    /// the legacy file is a stale shared leftover.
    func testNewNameWinsOverLegacyWhenBothExist() throws {
        let asset = tempDir.appendingPathComponent("photo.jpg")
        try Data([0]).write(to: asset)
        let museDir = tempDir.appendingPathComponent(".muse", isDirectory: true)
        try FileManager.default.createDirectory(at: museDir, withIntermediateDirectories: true)
        var legacySidecar = sample(hash: "hash1"); legacySidecar.caption = "stale"
        try JSONEncoder().encode(legacySidecar)
            .write(to: museDir.appendingPathComponent("hash1.json"))
        var current = sample(hash: "hash1"); current.caption = "current"
        try SidecarStore.write(current, forAsset: asset)

        XCTAssertEqual(SidecarStore.read(forAsset: asset, contentHash: "hash1")?.caption,
                       "current")
    }
}
