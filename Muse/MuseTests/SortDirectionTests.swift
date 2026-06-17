import XCTest
@testable import Muse

/// Sort-direction toggle: reversing flips the order, and the arrow/label
/// metadata is consistent. Name sort derives from the URL (no disk needed).
final class SortDirectionTests: XCTestCase {
    private func nodes(_ names: [String]) -> [FileNode] {
        names.map { FileNode(url: URL(fileURLWithPath: "/tmp/MuseSortTest/\($0)")) }
    }

    func testNameAscendingIsAtoZ() {
        let sorted = SmartSorter.apply(.name, to: nodes(["c.png", "a.png", "b.png"]))
        XCTAssertEqual(sorted.map { $0.basename }, ["a.png", "b.png", "c.png"])
    }

    func testReversedFlipsTheOrder() {
        let sorted = SmartSorter.apply(.name, to: nodes(["c.png", "a.png", "b.png"]),
                                       reversed: true)
        XCTAssertEqual(sorted.map { $0.basename }, ["c.png", "b.png", "a.png"])
    }

    func testReversedIsExactInverseOfDefault() {
        let input = nodes(["one.jpg", "two.jpg", "three.jpg", "four.jpg"])
        let forward = SmartSorter.apply(.name, to: input)
        let backward = SmartSorter.apply(.name, to: input, reversed: true)
        XCTAssertEqual(forward.map { $0.basename }, backward.reversed().map { $0.basename })
    }

    func testDefaultDirections() {
        // Date / size / shape default to descending (newest / largest first);
        // name / kind / color default to ascending.
        XCTAssertFalse(SortMode.dateModified.defaultAscending)
        XCTAssertFalse(SortMode.size.defaultAscending)
        XCTAssertTrue(SortMode.name.defaultAscending)
        XCTAssertTrue(SortMode.kind.defaultAscending)
    }

    func testDirectionLabelsAreModeAware() {
        XCTAssertEqual(SortMode.dateModified.directionLabel(ascending: false), "Newest first")
        XCTAssertEqual(SortMode.dateModified.directionLabel(ascending: true), "Oldest first")
        XCTAssertEqual(SortMode.name.directionLabel(ascending: true), "A → Z")
        XCTAssertEqual(SortMode.size.directionLabel(ascending: false), "Largest first")
    }
}
