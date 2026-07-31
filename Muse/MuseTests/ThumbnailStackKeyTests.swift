//
//  ThumbnailStackKeyTests.swift
//  MuseTests
//
//  The cache key must incorporate the edit-stack hash when one exists, and be
//  byte-identical to the pre-change key when it doesn't — that equality is the
//  proof that upgrading doesn't re-key every cached PNG in every library and
//  force a full-library thumbnail regeneration on first launch.
//

import XCTest
@testable import Muse

final class ThumbnailStackKeyTests: XCTestCase {

    private let url = URL(fileURLWithPath: "/tmp/muse-thumb-key.jpg")
    private let size = CGSize(width: 320, height: 320)

    override func tearDown() {
        EditStackIndex.installProvider(nil)
        super.tearDown()
    }

    private func key() -> String {
        ThumbnailCache.cacheKeyForTesting(url: url, size: size, scale: 2.0)
    }

    func testKeyUnchangedWhenNoStackHash() {
        let before = key()
        EditStackIndex.installProvider(StubEditStackProvider(hash: nil, cropped: nil))
        XCTAssertEqual(before, key(), "nil stack hash must not change the raw key string")
    }

    func testKeyDiffersWhenStackHashDiffers() {
        EditStackIndex.installProvider(StubEditStackProvider(hash: "aaa", cropped: nil))
        let keyA = key()
        EditStackIndex.installProvider(StubEditStackProvider(hash: "bbb", cropped: nil))
        let keyB = key()
        XCTAssertNotEqual(keyA, keyB)
    }

    func testEditedKeyDiffersFromUneditedKey() {
        let unedited = key()
        EditStackIndex.installProvider(StubEditStackProvider(hash: "aaa", cropped: nil))
        XCTAssertNotEqual(unedited, key())
    }

    func testRevertingRestoresTheOriginalKey() {
        let unedited = key()
        EditStackIndex.installProvider(StubEditStackProvider(hash: "aaa", cropped: nil))
        _ = key()
        EditStackIndex.installProvider(nil)
        XCTAssertEqual(unedited, key(),
                       "reverting an edit must address the original's cached PNGs again")
    }

    func testSizeAndScaleStillSeparateKeys() {
        EditStackIndex.installProvider(StubEditStackProvider(hash: "aaa", cropped: nil))
        let a = ThumbnailCache.cacheKeyForTesting(url: url, size: size, scale: 2.0)
        let b = ThumbnailCache.cacheKeyForTesting(url: url, size: size, scale: 1.0)
        let c = ThumbnailCache.cacheKeyForTesting(
            url: url, size: CGSize(width: 160, height: 160), scale: 2.0)
        XCTAssertNotEqual(a, b)
        XCTAssertNotEqual(a, c)
    }
}
