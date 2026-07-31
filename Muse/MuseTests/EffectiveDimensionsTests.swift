//
//  EffectiveDimensionsTests.swift
//  MuseTests
//
//  Falls back to ImageHeaderSizeCache; a crop (via EditStackIndex) overrides
//  it. Orientation stays ImageHeaderSizeCache's job — this layer sits above it
//  and never re-derives display dimensions itself.
//

import XCTest
@testable import Muse

final class EffectiveDimensionsTests: XCTestCase {

    private let url = URL(fileURLWithPath: "/tmp/muse-edt-photo.jpg")

    override func tearDown() {
        EditStackIndex.installProvider(nil)
        ImageHeaderSizeCache.invalidate(url)
        super.tearDown()
    }

    func testFallsBackToHeaderCacheWhenNoCrop() {
        ImageHeaderSizeCache.record(url, width: 4000, height: 3000)
        XCTAssertEqual(EffectiveDimensions.cached(url), CGSize(width: 4000, height: 3000))
    }

    func testCropOverridesHeaderCache() {
        ImageHeaderSizeCache.record(url, width: 4000, height: 3000)
        EditStackIndex.installProvider(
            StubEditStackProvider(hash: "h1", cropped: CGSize(width: 2000, height: 3000)))
        XCTAssertEqual(EffectiveDimensions.cached(url), CGSize(width: 2000, height: 3000))
    }

    /// An edit stack with no crop must not shadow the header cache — only a
    /// crop changes the drawn geometry.
    func testStackWithoutCropLeavesHeaderCacheIntact() {
        ImageHeaderSizeCache.record(url, width: 4000, height: 3000)
        EditStackIndex.installProvider(StubEditStackProvider(hash: "h1", cropped: nil))
        XCTAssertEqual(EffectiveDimensions.cached(url), CGSize(width: 4000, height: 3000))
    }

    func testAspectDerivesFromEffectiveSize() {
        ImageHeaderSizeCache.record(url, width: 4000, height: 2000)
        XCTAssertEqual(EffectiveDimensions.aspect(url), 2.0)
    }

    func testAspectFollowsTheCrop() {
        ImageHeaderSizeCache.record(url, width: 4000, height: 2000)
        EditStackIndex.installProvider(
            StubEditStackProvider(hash: "h1", cropped: CGSize(width: 1000, height: 1000)))
        XCTAssertEqual(EffectiveDimensions.aspect(url), 1.0)
    }

    func testAspectNilWhenNoDataAvailable() {
        let missing = URL(fileURLWithPath: "/tmp/muse-edt-nonexistent-\(UUID().uuidString).jpg")
        XCTAssertNil(EffectiveDimensions.aspect(missing))
    }

    func testAspectNilForZeroHeight() {
        ImageHeaderSizeCache.record(url, width: 4000, height: 0)
        XCTAssertNil(EffectiveDimensions.aspect(url))
    }
}
