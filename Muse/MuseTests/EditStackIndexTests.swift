//
//  EditStackIndexTests.swift
//  MuseTests
//
//  Identity-function seam today (no provider installed = nil everywhere).
//  Spec 04 installs a real provider; every consumer of this type is already
//  wired correctly when that happens.
//

import XCTest
@testable import Muse

/// Shared stub so the seam's consumers (ThumbnailCache, EffectiveDimensions,
/// OutputRender) all drive it the same way.
struct StubEditStackProvider: EditStackProviding {
    var hash: String?
    var cropped: CGSize?
    func stackHash(for url: URL) -> String? { hash }
    func croppedSize(for url: URL) -> CGSize? { cropped }
}

final class EditStackIndexTests: XCTestCase {

    override func tearDown() {
        EditStackIndex.installProvider(nil)
        super.tearDown()
    }

    func testNilProviderReturnsNilHashAndSize() {
        let url = URL(fileURLWithPath: "/tmp/photo.jpg")
        XCTAssertNil(EditStackIndex.stackHash(for: url))
        XCTAssertNil(EditStackIndex.croppedSize(for: url))
    }

    func testInstalledProviderIsConsulted() {
        EditStackIndex.installProvider(
            StubEditStackProvider(hash: "abc123", cropped: CGSize(width: 100, height: 200)))
        let url = URL(fileURLWithPath: "/tmp/photo.jpg")
        XCTAssertEqual(EditStackIndex.stackHash(for: url), "abc123")
        XCTAssertEqual(EditStackIndex.croppedSize(for: url), CGSize(width: 100, height: 200))
    }

    func testProviderRemovalRestoresIdentity() {
        EditStackIndex.installProvider(StubEditStackProvider(hash: "abc123", cropped: nil))
        EditStackIndex.installProvider(nil)
        let url = URL(fileURLWithPath: "/tmp/photo.jpg")
        XCTAssertNil(EditStackIndex.stackHash(for: url))
    }

    /// An installed provider that reports no stack for a file is the unedited
    /// case and must be indistinguishable from no provider at all — this is
    /// what keeps a library from re-keying its whole thumbnail cache.
    func testProviderReportingNoStackMatchesIdentity() {
        EditStackIndex.installProvider(StubEditStackProvider(hash: nil, cropped: nil))
        let url = URL(fileURLWithPath: "/tmp/photo.jpg")
        XCTAssertNil(EditStackIndex.stackHash(for: url))
        XCTAssertNil(EditStackIndex.croppedSize(for: url))
    }

    // MARK: - The live index

    private func toneStack(_ ev: Double) -> EditStack {
        var s = EditStack.fresh()
        s.setTone { $0.exposureEV = ev }
        return s
    }

    private func entry(_ path: String, _ stack: EditStack) throws
    -> (path: String, stackJSON: String, hash: String) {
        (path, try EditStackCodec.encode(stack), EditStackCodec.hash(stack))
    }

    func testRebuildThenResolvedStackReturnsTheDecodedStack() throws {
        let path = "/tmp/edited.jpg"
        let stack = toneStack(1)
        EditStackIndex.rebuild(entries: [try entry(path, stack)])
        XCTAssertEqual(EditStackIndex.resolvedStack(for: URL(fileURLWithPath: path)),
                       stack.normalized())
    }

    func testRebuildReplacesTheWholeIndex() throws {
        EditStackIndex.rebuild(entries: [try entry("/tmp/a.jpg", toneStack(1))])
        EditStackIndex.rebuild(entries: [try entry("/tmp/b.jpg", toneStack(2))])
        XCTAssertNil(EditStackIndex.resolvedStack(for: URL(fileURLWithPath: "/tmp/a.jpg")))
        XCTAssertNotNil(EditStackIndex.resolvedStack(for: URL(fileURLWithPath: "/tmp/b.jpg")))
    }

    /// The reset case: merging with a scope that reports nothing must REMOVE
    /// the entry. Without the clear, a reset photo keeps rendering its old
    /// stack until the next full rebuild.
    func testMergeClearsScopedPathsThatNoLongerCarryAnEdit() throws {
        EditStackIndex.rebuild(entries: [try entry("/tmp/a.jpg", toneStack(1)),
                                         try entry("/tmp/b.jpg", toneStack(2))])
        EditStackIndex.merge(entries: [], clearingScope: ["/tmp/a.jpg"])
        XCTAssertNil(EditStackIndex.resolvedStack(for: URL(fileURLWithPath: "/tmp/a.jpg")))
        XCTAssertNotNil(EditStackIndex.resolvedStack(for: URL(fileURLWithPath: "/tmp/b.jpg")),
                        "merge must not disturb paths outside its scope")
    }

    func testMergeUpdatesAnExistingEntry() throws {
        EditStackIndex.rebuild(entries: [try entry("/tmp/a.jpg", toneStack(1))])
        EditStackIndex.merge(entries: [try entry("/tmp/a.jpg", toneStack(3))],
                             clearingScope: ["/tmp/a.jpg"])
        XCTAssertEqual(
            EditStackIndex.resolvedStack(for: URL(fileURLWithPath: "/tmp/a.jpg"))?
                .toneParams?.exposureEV, 3)
    }

    /// An undecodable blob resolves to NO stack (the original renders) but
    /// must still report a HASH — otherwise a build that later learns to read
    /// it would serve the original's cached PNG forever.
    func testUndecodableBlobKeepsItsHashButResolvesToNoStack() {
        let future = "{\"schemaVersion\":99,\"processVersion\":1,\"adjustments\":[],\"masks\":[]}"
        EditStackIndex.rebuild(entries: [("/tmp/future.jpg", future, "futurehash")])
        EditStackIndex.installProvider(LiveEditStackProvider())
        let url = URL(fileURLWithPath: "/tmp/future.jpg")
        XCTAssertNil(EditStackIndex.resolvedStack(for: url))
        XCTAssertEqual(EditStackIndex.stackHash(for: url), "futurehash")
    }

    func testLiveProviderReportsNilForAnUnindexedPath() {
        EditStackIndex.rebuild(entries: [])
        EditStackIndex.installProvider(LiveEditStackProvider())
        XCTAssertNil(EditStackIndex.stackHash(for: URL(fileURLWithPath: "/tmp/unedited.jpg")))
    }

    /// `croppedSize` needs BOTH a crop and a warm header size — it must never
    /// perform I/O to get the latter.
    func testLiveProviderCroppedSizeAppliesGeometryToTheHeaderSize() throws {
        let path = "/tmp/cropped-fixture.jpg"
        let url = URL(fileURLWithPath: path)
        ImageHeaderSizeCache.record(url, width: 200, height: 100)
        var stack = EditStack.fresh()
        stack.setGeometry { $0.crop = CropRect(x: 0, y: 0, w: 0.5, h: 1) }
        EditStackIndex.rebuild(entries: [try entry(path, stack)])
        EditStackIndex.installProvider(LiveEditStackProvider())
        XCTAssertEqual(EditStackIndex.croppedSize(for: url), CGSize(width: 100, height: 100))
    }

    func testLiveProviderReportsNoCroppedSizeForANonGeometryStack() throws {
        let path = "/tmp/tone-only.jpg"
        let url = URL(fileURLWithPath: path)
        ImageHeaderSizeCache.record(url, width: 200, height: 100)
        EditStackIndex.rebuild(entries: [try entry(path, toneStack(1))])
        EditStackIndex.installProvider(LiveEditStackProvider())
        XCTAssertNil(EditStackIndex.croppedSize(for: url))
    }
}
