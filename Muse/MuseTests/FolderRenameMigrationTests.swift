//
//  FolderRenameMigrationTests.swift
//  MuseTests
//
//  The pure path-prefix rewrite used by a folder rename.
//

import XCTest
@testable import Muse

final class FolderRenameMigrationTests: XCTestCase {
    func testExactFolderMatchRewrites() {
        // tags.parent_dir of a file directly in the renamed folder.
        XCTAssertEqual(
            FolderRenameMigration.rewrite(path: "/a/Old", old: "/a/Old", new: "/a/New"),
            "/a/New")
    }
    func testNestedChildRewrites() {
        XCTAssertEqual(
            FolderRenameMigration.rewrite(path: "/a/Old/sub/p.png", old: "/a/Old", new: "/a/New"),
            "/a/New/sub/p.png")
    }
    func testSiblingPrefixIsNotMatched() {
        // "/a/Old" must not catch "/a/OldStuff".
        XCTAssertNil(
            FolderRenameMigration.rewrite(path: "/a/OldStuff/p.png", old: "/a/Old", new: "/a/New"))
    }
    func testUnrelatedPathIsNil() {
        XCTAssertNil(
            FolderRenameMigration.rewrite(path: "/b/x.png", old: "/a/Old", new: "/a/New"))
    }
    func testPathWithSqlWildcardsRewrites() {
        XCTAssertEqual(
            FolderRenameMigration.rewrite(path: "/a/Old/100%_off/p_1.png", old: "/a/Old", new: "/a/New"),
            "/a/New/100%_off/p_1.png")
    }
}
