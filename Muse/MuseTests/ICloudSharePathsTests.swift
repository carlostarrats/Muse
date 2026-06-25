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

    func testShareFolderIsDeterministicUnderSharedCollections() {
        let docs = URL(fileURLWithPath: "/tmp/Documents", isDirectory: true)
        let folder = ICloudSharePaths.shareFolder(zoneDocuments: docs, collectionName: "Kitchen Inspo")
        XCTAssertEqual(folder.path, "/tmp/Documents/Shared Collections/Kitchen Inspo")
        // Same name → same URL (re-share refreshes, never duplicates).
        let again = ICloudSharePaths.shareFolder(zoneDocuments: docs, collectionName: "Kitchen Inspo")
        XCTAssertEqual(folder, again)
    }
}
