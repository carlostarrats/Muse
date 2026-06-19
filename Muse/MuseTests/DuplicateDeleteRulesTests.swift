//
//  DuplicateDeleteRulesTests.swift
//  MuseTests
//
//  The "never delete every copy of any group" guarantee + two-copy swap for the
//  Duplicates review modal — including when a file belongs to more than one
//  group. These guard a destructive action, so they're tested directly.
//

import XCTest
@testable import Muse

final class DuplicateDeleteRulesTests: XCTestCase {

    private func url(_ p: String) -> URL { URL(fileURLWithPath: p) }

    // MARK: - seed

    func testSeedMarksNonKeepersWhenAKeeperExists() {
        let a = url("/a.jpg"), b = url("/b.jpg"), c = url("/c.jpg")
        let seed = DuplicateDeleteRules.seed(members: [(a, true), (b, false), (c, false)])
        XCTAssertEqual(Set(seed), [b, c])
        XCTAssertFalse(seed.contains(a)) // keeper is never pre-marked
    }

    func testSeedIsEmptyWhenNoKeeper() {
        let a = url("/a.jpg"), b = url("/b.jpg")
        XCTAssertEqual(DuplicateDeleteRules.seed(members: [(a, false), (b, false)]), [])
    }

    // MARK: - isLocked

    func testTwoCopyGroupIsNeverLocked() {
        let a = url("/a.jpg"), b = url("/b.jpg")
        let groups = [[a, b]]
        XCTAssertFalse(DuplicateDeleteRules.isLocked(a, groupsContaining: groups, selected: [b]))
        XCTAssertFalse(DuplicateDeleteRules.isLocked(b, groupsContaining: groups, selected: [b]))
    }

    func testLastSurvivorOfThreeIsLocked() {
        let a = url("/a.jpg"), b = url("/b.jpg"), c = url("/c.jpg")
        let groups = [[a, b, c]]
        XCTAssertTrue(DuplicateDeleteRules.isLocked(a, groupsContaining: groups, selected: [b, c]))
        XCTAssertFalse(DuplicateDeleteRules.isLocked(b, groupsContaining: groups, selected: [b, c]))
    }

    func testNotLockedWhileTwoCopiesRemainKept() {
        let a = url("/a.jpg"), b = url("/b.jpg"), c = url("/c.jpg")
        let groups = [[a, b, c]]
        XCTAssertFalse(DuplicateDeleteRules.isLocked(a, groupsContaining: groups, selected: [c]))
        XCTAssertFalse(DuplicateDeleteRules.isLocked(b, groupsContaining: groups, selected: [c]))
    }

    // MARK: - selecting (single group)

    func testSelectingWhileAnotherCopyStaysKept() {
        let a = url("/a.jpg"), b = url("/b.jpg"), c = url("/c.jpg")
        let result = DuplicateDeleteRules.selecting(a, groupsContaining: [[a, b, c]], selected: [])
        XCTAssertEqual(result, [a]) // b and c still kept → plain select
    }

    func testThreeCopyLastSurvivorCannotBeSelected() {
        let a = url("/a.jpg"), b = url("/b.jpg"), c = url("/c.jpg")
        let result = DuplicateDeleteRules.selecting(a, groupsContaining: [[a, b, c]], selected: [b, c])
        XCTAssertEqual(result, [b, c]) // unchanged — a stays kept
    }

    func testTwoCopySelectingLastSurvivorSwaps() {
        let a = url("/a.jpg"), b = url("/b.jpg")
        let result = DuplicateDeleteRules.selecting(a, groupsContaining: [[a, b]], selected: [b])
        XCTAssertEqual(result, [a]) // swap: b freed, a marked
    }

    func testTwoCopyGroupNeverHasBothSelected() {
        let a = url("/a.jpg"), b = url("/b.jpg")
        let groups = [[a, b]]
        var selected: Set<URL> = []
        selected = DuplicateDeleteRules.selecting(a, groupsContaining: groups, selected: selected)
        XCTAssertEqual(selected, [a])
        selected = DuplicateDeleteRules.selecting(b, groupsContaining: groups, selected: selected)
        XCTAssertEqual(selected, [b]) // swapped, not both
    }

    func testInvariantAtLeastOneKeptAcrossManySelects() {
        let urls = (0..<5).map { url("/img\($0).jpg") }
        var selected: Set<URL> = []
        for u in urls {
            selected = DuplicateDeleteRules.selecting(u, groupsContaining: [urls], selected: selected)
            XCTAssertGreaterThanOrEqual(urls.filter { !selected.contains($0) }.count, 1,
                                        "a group must never be fully marked for delete")
        }
    }

    // MARK: - cross-group (a file in more than one group)

    func testSelectingCannotEmptyAnOverlappingGroup() {
        // `a` is in a 2-copy byte-exact group [a,b] and a 3-copy visual group
        // [a,c,d]. With b,c,d already marked, `a` is the only survivor of BOTH
        // pending deletes — selecting it must be refused (no ambiguous swap).
        let a = url("/a.jpg"), b = url("/b.jpg"), c = url("/c.jpg"), d = url("/d.jpg")
        let groups = [[a, b], [a, c, d]]
        XCTAssertTrue(DuplicateDeleteRules.isLocked(a, groupsContaining: groups, selected: [b, c, d]))
        let result = DuplicateDeleteRules.selecting(a, groupsContaining: groups, selected: [b, c, d])
        XCTAssertEqual(result, [b, c, d]) // unchanged — neither group emptied
        XCTAssertFalse([a, c, d].allSatisfy { result.contains($0) }) // visual group keeps a
    }

    func testNoSwapWhenFileIsInMultipleGroups() {
        // Even though [a,b] is a 2-copy group, `a` also lives in [a,c], so the
        // swap target is ambiguous → no swap, and selecting `a` is allowed only
        // because [a,c] still keeps c.
        let a = url("/a.jpg"), b = url("/b.jpg"), c = url("/c.jpg")
        let groups = [[a, b], [a, c]]
        // b marked; selecting a would empty [a,b]; [a,c] still keeps c → but
        // emptying [a,b] is not allowed and there's no single-group swap.
        XCTAssertTrue(DuplicateDeleteRules.isLocked(a, groupsContaining: groups, selected: [b]))
        XCTAssertEqual(DuplicateDeleteRules.selecting(a, groupsContaining: groups, selected: [b]), [b])
    }

    // MARK: - rescued (cross-group seeding reconciliation)

    func testRescuedFreesAFullyMarkedGroup() {
        // Byte-exact [a,b] keeps a, marks b. Visual [b,c] keeps b, marks c.
        // Union {b,c} leaves [b,c] fully marked — rescue must free one of them.
        let a = url("/a.jpg"), b = url("/b.jpg"), c = url("/c.jpg")
        let rescued = DuplicateDeleteRules.rescued([b, c], groups: [[a, b], [b, c]])
        XCTAssertFalse([b, c].allSatisfy { rescued.contains($0) }, "[b,c] must keep a survivor")
        XCTAssertFalse([a, b].allSatisfy { rescued.contains($0) }, "[a,b] must keep a survivor")
    }

    func testRescuedIsNoOpWhenEveryGroupHasASurvivor() {
        let a = url("/a.jpg"), b = url("/b.jpg"), c = url("/c.jpg")
        XCTAssertEqual(DuplicateDeleteRules.rescued([b], groups: [[a, b], [b, c]]), [b])
    }
}
