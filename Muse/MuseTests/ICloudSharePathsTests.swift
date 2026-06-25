//
//  ICloudSharePathsTests.swift
//  MuseTests
//

import XCTest
@testable import Muse

final class ICloudSharePathsTests: XCTestCase {
    func testSanitizeStripsPathSeparatorsAndTrims() {
        XCTAssertEqual(ICloudSharePaths.sanitizedFolderName("  Spring/Summer 2025  "),
                       "Spring-Summer 2025")
        XCTAssertEqual(ICloudSharePaths.sanitizedFolderName("a:b/c\\d"), "a-b-c-d")
    }

    func testSanitizeEmptyFallsBackToCollection() {
        XCTAssertEqual(ICloudSharePaths.sanitizedFolderName("   "), "Collection")
        XCTAssertEqual(ICloudSharePaths.sanitizedFolderName("///"), "Collection")
    }

    func testUniqueNameReturnsOriginalWhenFree() {
        XCTAssertEqual(ICloudSharePaths.uniqueName("a.jpg", taken: []), "a.jpg")
        XCTAssertEqual(ICloudSharePaths.uniqueName("a.jpg", taken: ["b.jpg"]), "a.jpg")
    }

    func testUniqueNameAppendsSuffixBeforeExtensionOnCollision() {
        XCTAssertEqual(ICloudSharePaths.uniqueName("a.jpg", taken: ["a.jpg"]), "a-2.jpg")
        XCTAssertEqual(ICloudSharePaths.uniqueName("a.jpg", taken: ["a.jpg", "a-2.jpg"]), "a-3.jpg")
        // Extensionless name collides too.
        XCTAssertEqual(ICloudSharePaths.uniqueName("README", taken: ["README"]), "README-2")
    }

    func testShareFolderIsDeterministicUnderSharedCollections() {
        let docs = URL(fileURLWithPath: "/tmp/Documents", isDirectory: true)
        let folder = ICloudSharePaths.shareFolder(zoneDocuments: docs, collectionName: "Kitchen Inspo")
        XCTAssertEqual(folder.path, "/tmp/Documents/Shared Collections/Kitchen Inspo")
        // Same name → same URL (re-share refreshes, never duplicates).
        let again = ICloudSharePaths.shareFolder(zoneDocuments: docs, collectionName: "Kitchen Inspo")
        XCTAssertEqual(folder, again)
    }
}
