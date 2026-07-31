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
}
