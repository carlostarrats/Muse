import XCTest
@testable import Muse

final class ClustererTests: XCTestCase {
    private func item(_ id: String, _ v: [Float]) -> ClusterItem {
        ClusterItem(id: id, textVector: v, featurePrint: nil)
    }
    func testTwoCleanClusters() {
        var items: [ClusterItem] = []
        for i in 0..<5 { items.append(item("a\(i)", [1, 0.01 * Float(i), 0])) }
        for i in 0..<5 { items.append(item("b\(i)", [0, 0.01 * Float(i), 1])) }
        let clusters = HybridClusterer().cluster(items)
        XCTAssertEqual(clusters.count, 2)
        let sets = clusters.map { Set($0.memberIDs) }
        XCTAssertTrue(sets.contains(Set(["a0","a1","a2","a3","a4"])))
        XCTAssertTrue(sets.contains(Set(["b0","b1","b2","b3","b4"])))
    }
    func testSmallGroupsDropped() {
        let items = [item("x1", [1, 0, 0]), item("x2", [1, 0.01, 0]),
                     item("y", [0, 1, 0])]
        XCTAssertTrue(HybridClusterer().cluster(items).isEmpty)
    }
    func testItemsWithoutVectorsIgnored() {
        let items = [ClusterItem(id: "n", textVector: nil, featurePrint: nil)]
        XCTAssertTrue(HybridClusterer().cluster(items).isEmpty)
    }
}
