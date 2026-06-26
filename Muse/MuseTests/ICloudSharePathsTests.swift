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

    func testSanitizeRejectsPathTraversalNames() {
        // `.` / `..` are path-special: they would make the share folder escape
        // its root and the clean-and-recopy `removeItem` would delete the parent
        // (the iCloud Documents zone). All must fall back to "Collection".
        XCTAssertEqual(ICloudSharePaths.sanitizedFolderName(".."), "Collection")
        XCTAssertEqual(ICloudSharePaths.sanitizedFolderName("."), "Collection")
        XCTAssertEqual(ICloudSharePaths.sanitizedFolderName("/../"), "Collection")
        XCTAssertEqual(ICloudSharePaths.sanitizedFolderName("  ..  "), "Collection")
        XCTAssertEqual(ICloudSharePaths.sanitizedFolderName("..."), "Collection")
        // And the resulting folder never escapes the share root.
        let docs = URL(fileURLWithPath: "/tmp/Documents", isDirectory: true)
        let folder = ICloudSharePaths.shareFolder(zoneDocuments: docs, collectionName: "..")
        XCTAssertEqual(folder.standardizedFileURL.path, "/tmp/Documents/Shared Collections/Collection")
        XCTAssertTrue(folder.standardizedFileURL.path.hasPrefix("/tmp/Documents/Shared Collections/"))
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

    func testUniqueFolderNameReusesForSameCollection() {
        // Re-sharing the SAME collection (same stable identity) reuses its folder
        // (refresh in place), regardless of any display-name edits.
        let owners = ["Kitchen Inspo": "id-A"]
        XCTAssertEqual(ICloudSharePaths.uniqueFolderName(for: "Kitchen Inspo",
                                                         identity: "id-A", owners: owners),
                       "Kitchen Inspo")
    }

    func testUniqueFolderNameDisambiguatesIdenticalDisplayNames() {
        // Two DIFFERENT collections with the SAME display name must NOT share one
        // folder — keying on the stable id (not the name) is what catches this.
        // The second gets "-2"; without it, sharing the second would delete the
        // first's images and silently repoint its live link.
        let owners = ["Kitchen Inspo": "id-A"]
        XCTAssertEqual(ICloudSharePaths.uniqueFolderName(for: "Kitchen Inspo",
                                                         identity: "id-B", owners: owners),
                       "Kitchen Inspo-2")
    }

    func testUniqueFolderNameDisambiguatesCollidingCollections() {
        // "Trip/Italy" and "Trip-Italy" both sanitize to "Trip-Italy". The second
        // collection (a different identity) must NOT reuse the first's folder
        // (which would delete the first's images and repoint its live link). "-2".
        let owners = ["Trip-Italy": "id-A"]
        XCTAssertEqual(ICloudSharePaths.uniqueFolderName(for: "Trip-Italy",
                                                         identity: "id-B", owners: owners),
                       "Trip-Italy-2")
        // And re-sharing the SECOND collection keeps its own "-2" folder.
        let owners2 = ["Trip-Italy": "id-A", "Trip-Italy-2": "id-B"]
        XCTAssertEqual(ICloudSharePaths.uniqueFolderName(for: "Trip-Italy",
                                                         identity: "id-B", owners: owners2),
                       "Trip-Italy-2")
        // A third colliding collection climbs to "-3".
        let owners3 = ["Trip-Italy": "id-A", "Trip-Italy-2": "id-B"]
        XCTAssertEqual(ICloudSharePaths.uniqueFolderName(for: "Trip:Italy",
                                                         identity: "id-C", owners: owners3),
                       "Trip-Italy-3")
        // The first collection (id-A) still reuses the base folder.
        XCTAssertEqual(ICloudSharePaths.uniqueFolderName(for: "Trip/Italy",
                                                         identity: "id-A", owners: owners3),
                       "Trip-Italy")
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
