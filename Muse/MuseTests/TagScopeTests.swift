//
//  TagScopeTests.swift
//  MuseTests
//
//  The parent-folder key derivation that makes tags per-location.
//

import XCTest
@testable import Muse

final class TagScopeTests: XCTestCase {
    func testParentDirOfPath() {
        XCTAssertEqual(TagScope.parentDir(ofPath: "/a/b/c.png"), "/a/b")
        XCTAssertEqual(TagScope.parentDir(ofPath: "/Users/x/Pics/img.jpg"), "/Users/x/Pics")
    }

    func testParentDirOfURLMatchesPath() {
        let url = URL(fileURLWithPath: "/a/b/c.png")
        XCTAssertEqual(TagScope.parentDir(of: url), "/a/b")
    }

    func testDuplicatesInDifferentFoldersGetDifferentScopes() {
        let a = TagScope.parentDir(ofPath: "/A/shot.png")
        let b = TagScope.parentDir(ofPath: "/B/shot.png")
        XCTAssertNotEqual(a, b)
    }

    func testRenameInSameFolderKeepsScope() {
        // Same folder, different name (a rename in place) → same tag scope.
        let before = TagScope.parentDir(ofPath: "/A/old.png")
        let after = TagScope.parentDir(ofPath: "/A/new.png")
        XCTAssertEqual(before, after)
    }
}
