import XCTest
import simd
@testable import Muse

final class SimilarityLayoutTests: XCTestCase {
    func testDegenerateCounts() {
        XCTAssertTrue(SimilarityLayout.positions(distances: [], seed: 1).isEmpty)
        XCTAssertEqual(SimilarityLayout.positions(distances: [[0]], seed: 1),
                       [SIMD3(0, 0, 0)])
        let two = SimilarityLayout.positions(distances: [[0, 1], [1, 0]], seed: 1)
        XCTAssertEqual(two.count, 2)
        for v in two { XCTAssertTrue(v.x.isFinite && v.y.isFinite && v.z.isFinite) }
    }

    func testDeterministicPerSeed() {
        let d: [[Float]] = [[0, 0.5, 1], [0.5, 0, 0.7], [1, 0.7, 0]]
        XCTAssertEqual(SimilarityLayout.positions(distances: d, seed: 3),
                       SimilarityLayout.positions(distances: d, seed: 3))
        XCTAssertNotEqual(SimilarityLayout.positions(distances: d, seed: 3),
                          SimilarityLayout.positions(distances: d, seed: 4))
    }

    func testSimilarPairEndsCloserThanDissimilar() {
        // 0 and 1 are near-identical; 2 is far from both.
        let d: [[Float]] = [[0, 0.05, 1.0],
                            [0.05, 0, 1.0],
                            [1.0, 1.0, 0]]
        let p = SimilarityLayout.positions(distances: d, seed: 7)
        let d01 = simd_length(p[0] - p[1])
        let d02 = simd_length(p[0] - p[2])
        XCTAssertLessThan(d01, d02 * 0.5)
    }

    func testAllZeroDistancesStayFinite() {
        let d = [[Float]](repeating: [Float](repeating: 0, count: 5), count: 5)
        let p = SimilarityLayout.positions(distances: d, seed: 2)
        for v in p { XCTAssertTrue(v.x.isFinite && v.y.isFinite && v.z.isFinite) }
    }

    func testNormalizedToUnitRadius() {
        let d: [[Float]] = [[0, 2, 3], [2, 0, 4], [3, 4, 0]]
        let p = SimilarityLayout.positions(distances: d, seed: 9)
        XCTAssertEqual(p.map(simd_length).max() ?? 0, 1.0, accuracy: 1e-6)
    }
}
