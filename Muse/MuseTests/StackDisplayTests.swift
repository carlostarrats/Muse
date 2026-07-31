//
//  StackDisplayTests.swift
//  MuseTests
//
//  Collapse keeps the pick (else the first in order) and hides the rest unless
//  expanded; badge counts are members actually IN VIEW; a stack with fewer than
//  two members present is never collapsed; input order is preserved.
//

import XCTest
@testable import Muse

final class StackDisplayTests: XCTestCase {

    private func node(_ path: String) -> FileNode {
        FileNode(url: URL(fileURLWithPath: path))
    }

    func testCollapseKeepsPickWhenPresent() {
        let files = [node("/a"), node("/b"), node("/c")]
        let entries = ["/a": StackDisplay.Entry(stackID: "s1", isPick: false),
                       "/b": StackDisplay.Entry(stackID: "s1", isPick: true)]
        let result = StackDisplay.collapse(files, entries: entries, expanded: [])
        XCTAssertEqual(result.visible.map { $0.url.path }, ["/b", "/c"])
        XCTAssertEqual(result.hiddenPaths, ["/a"])
        XCTAssertEqual(result.badges["/b"], 2)
    }

    func testCollapseFallsBackToFirstInOrderWithNoPick() {
        let files = [node("/a"), node("/b"), node("/c")]
        let entries = ["/a": StackDisplay.Entry(stackID: "s1", isPick: false),
                       "/b": StackDisplay.Entry(stackID: "s1", isPick: false)]
        let result = StackDisplay.collapse(files, entries: entries, expanded: [])
        XCTAssertEqual(result.visible.map { $0.url.path }, ["/a", "/c"])
        XCTAssertEqual(result.badges["/a"], 2)
    }

    func testExpandedStackShowsAllMembers() {
        let files = [node("/a"), node("/b"), node("/c")]
        let entries = ["/a": StackDisplay.Entry(stackID: "s1", isPick: false),
                       "/b": StackDisplay.Entry(stackID: "s1", isPick: false)]
        let result = StackDisplay.collapse(files, entries: entries, expanded: ["s1"])
        XCTAssertEqual(result.visible.map { $0.url.path }, ["/a", "/b", "/c"])
        XCTAssertTrue(result.hiddenPaths.isEmpty)
        XCTAssertTrue(result.badges.isEmpty)
    }

    func testStackWithFewerThanTwoMembersPresentIsNotCollapsed() {
        // The stack's other member lives in a different folder.
        let files = [node("/a"), node("/c")]
        let entries = ["/a": StackDisplay.Entry(stackID: "s1", isPick: false)]
        let result = StackDisplay.collapse(files, entries: entries, expanded: [])
        XCTAssertEqual(result.visible.map { $0.url.path }, ["/a", "/c"])
        XCTAssertTrue(result.hiddenPaths.isEmpty)
        XCTAssertTrue(result.badges.isEmpty)
    }

    func testInputOrderPreservedForNonHiddenItems() {
        let files = [node("/z"), node("/a"), node("/m")]
        let result = StackDisplay.collapse(files, entries: [:], expanded: [])
        XCTAssertEqual(result.visible.map { $0.url.path }, ["/z", "/a", "/m"])
    }

    func testTwoStacksCollapseIndependently() {
        let files = [node("/a"), node("/b"), node("/c"), node("/d")]
        let entries = ["/a": StackDisplay.Entry(stackID: "s1", isPick: false),
                       "/b": StackDisplay.Entry(stackID: "s1", isPick: false),
                       "/c": StackDisplay.Entry(stackID: "s2", isPick: false),
                       "/d": StackDisplay.Entry(stackID: "s2", isPick: false)]
        let result = StackDisplay.collapse(files, entries: entries, expanded: ["s2"])
        XCTAssertEqual(result.visible.map { $0.url.path }, ["/a", "/c", "/d"])
        XCTAssertEqual(result.badges, ["/a": 2])
    }

    func testNoEntriesIsIdentity() {
        let files = [node("/a"), node("/b")]
        let result = StackDisplay.collapse(files, entries: [:], expanded: [])
        XCTAssertEqual(result.visible.count, 2)
        XCTAssertTrue(result.badges.isEmpty)
    }
}
