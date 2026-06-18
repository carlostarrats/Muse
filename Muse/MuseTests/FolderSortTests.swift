import XCTest
@testable import Muse

final class FolderSortTests: XCTestCase {
    private func item(_ name: String, stat: FolderStat? = nil) -> FolderSort.Item {
        FolderSort.Item(id: UUID(), name: name, stat: stat)
    }
    private func names(_ ids: [UUID], _ items: [FolderSort.Item]) -> [String] {
        let byId = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0.name) })
        return ids.map { byId[$0]! }
    }
    private func stat(size: Int64 = 0, modified: Date? = nil) -> FolderStat {
        FolderStat(immediateFileCount: 0, recursiveFileCount: 0,
                   totalSize: size, latestModified: modified)
    }

    func testManualPreservesOrder() {
        let items = [item("b"), item("a"), item("c")]
        XCTAssertEqual(names(FolderSort.order(items, by: .manual), items), ["b", "a", "c"])
    }

    func testNameLocalizedCaseInsensitiveNumeric() {
        let items = [item("Banana"), item("apple"), item("Cherry"), item("file10"), item("file2")]
        XCTAssertEqual(names(FolderSort.order(items, by: .name), items),
                       ["apple", "Banana", "Cherry", "file2", "file10"])
    }

    func testDateNewestFirstNilLast() {
        let now = Date()
        let items = [
            item("old", stat: stat(modified: now.addingTimeInterval(-100))),
            item("new", stat: stat(modified: now)),
            item("none", stat: nil)
        ]
        XCTAssertEqual(names(FolderSort.order(items, by: .dateModified), items),
                       ["new", "old", "none"])
    }

    func testSizeLargestFirstNilLast() {
        let items = [
            item("small", stat: stat(size: 10)),
            item("big", stat: stat(size: 100)),
            item("none", stat: nil),
            item("mid", stat: stat(size: 50))
        ]
        XCTAssertEqual(names(FolderSort.order(items, by: .size), items),
                       ["big", "mid", "small", "none"])
    }
}
