//
//  DriveSharePublishGuardTests.swift
//  MuseTests
//
//  The app must never mint a link its own share page rejects.
//

import XCTest
@testable import Muse

final class DriveSharePublishGuardTests: XCTestCase {
    private func makeForm(intro: String = "x", bodyText: String = "") -> DriveShareForm {
        DriveShareForm(intro: intro, label: "l", name: "n", date: Date(), expiry: Date(),
                       bodyText: bodyText)
    }

    func testAcceptsUnderTheImageCap() {
        let urls = (0..<10).map { URL(fileURLWithPath: "/tmp/\($0).jpg") }
        XCTAssertNil(DriveSharePublishGuard.validate(urls: urls, form: makeForm()))
        // Exactly at the cap is still fine — the page rejects only ABOVE 1000.
        let atCap = (0..<DriveShareManifest.maxImages).map { URL(fileURLWithPath: "/tmp/\($0).jpg") }
        XCTAssertNil(DriveSharePublishGuard.validate(urls: atCap, form: makeForm()))
    }

    func testRejectsOverTheImageCap() {
        let urls = (0...DriveShareManifest.maxImages).map { URL(fileURLWithPath: "/tmp/\($0).jpg") }
        guard case .unshareableTooManyImages(let count)? =
                DriveSharePublishGuard.validate(urls: urls, form: makeForm()) else {
            return XCTFail("expected .unshareableTooManyImages")
        }
        XCTAssertEqual(count, 1001)
    }

    func testRejectsOversizedFields() {
        let urls = [URL(fileURLWithPath: "/tmp/a.jpg")]
        let over = String(repeating: "x", count: DriveShareManifest.maxFieldLength + 1)
        XCTAssertNotNil(DriveSharePublishGuard.validate(urls: urls, form: makeForm(intro: over)))
        XCTAssertNotNil(DriveSharePublishGuard.validate(urls: urls, form: makeForm(bodyText: over)))
        let atCap = String(repeating: "x", count: DriveShareManifest.maxFieldLength)
        XCTAssertNil(DriveSharePublishGuard.validate(urls: urls, form: makeForm(intro: atCap)))
    }
}

/// Pins the portfolio update ORDER as a value, not just as prose: whatever
/// future refactor touches the update, it still has to emit
/// upload → swap manifest → sweep, in that order. Reordering would show
/// recipients a manifest whose images are already gone.
final class DriveShareUpdateOrderTests: XCTestCase {
    func testStepOrderIsUploadThenSwapThenSweep() {
        XCTAssertEqual(DriveShareUpdateSteps.order,
                       [.uploadImages, .swapManifest, .sweepOldChildren])
    }
}

final class SharingTierTests: XCTestCase {
    func testUnenforcedAlwaysAvailableRegardlessOfEntitlement() {
        XCTAssertEqual(SharingTier.enforced, false)
        XCTAssertTrue(SharingTier.portfolioAvailable(entitledToSharing: false))
        XCTAssertTrue(SharingTier.portfolioAvailable(entitledToSharing: true))
    }
}
