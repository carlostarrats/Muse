import XCTest
import simd
@testable import Muse

final class GraphLayoutTests: XCTestCase {
    func testEmptyAndSingle() {
        XCTAssertTrue(GraphLayout.positions(nodeCount: 0, edges: []).isEmpty)
        XCTAssertEqual(GraphLayout.positions(nodeCount: 1, edges: []), [SIMD2(0, 0)])
    }

    func testDeterministic() {
        let e = [GraphEdge(a: 0, b: 1, sharedTags: 2)]
        let p1 = GraphLayout.positions(nodeCount: 4, edges: e)
        let p2 = GraphLayout.positions(nodeCount: 4, edges: e)
        XCTAssertEqual(p1, p2)
    }

    func testConnectedNodesEndUpCloserThanUnconnected() {
        // 0-1 share tags; 2 floats free.
        let p = GraphLayout.positions(nodeCount: 3,
                                      edges: [GraphEdge(a: 0, b: 1, sharedTags: 3)])
        let d01 = simd_length(p[0] - p[1])
        let d02 = simd_length(p[0] - p[2])
        let d12 = simd_length(p[1] - p[2])
        XCTAssertLessThan(d01, d02)
        XCTAssertLessThan(d01, d12)
    }

    func testOutputIsFiniteAndNormalized() {
        let edges = [GraphEdge(a: 0, b: 1, sharedTags: 1),
                     GraphEdge(a: 1, b: 2, sharedTags: 4),
                     GraphEdge(a: 0, b: 5, sharedTags: 2)]
        let p = GraphLayout.positions(nodeCount: 8, edges: edges)
        XCTAssertEqual(p.count, 8)
        for v in p {
            XCTAssertTrue(v.x.isFinite && v.y.isFinite)
            XCTAssertTrue(abs(v.x) <= 1.0001 && abs(v.y) <= 1.0001)
        }
    }

    func testCoincidentStartDoesNotNaN() {
        // exercise the degenerate guard with many nodes + strong springs.
        let edges = (1..<6).map { GraphEdge(a: 0, b: $0, sharedTags: 4) }
        let p = GraphLayout.positions(nodeCount: 6, edges: edges)
        for v in p { XCTAssertTrue(v.x.isFinite && v.y.isFinite) }
    }
}
