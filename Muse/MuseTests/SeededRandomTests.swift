import XCTest
@testable import Muse

final class SeededRandomTests: XCTestCase {
    func testSameSeedSameSequence() {
        var a = SeededRandom(seed: 42), b = SeededRandom(seed: 42)
        for _ in 0..<32 { XCTAssertEqual(a.next(), b.next()) }
    }

    func testDifferentSeedsDiverge() {
        var a = SeededRandom(seed: 1), b = SeededRandom(seed: 2)
        let av = (0..<8).map { _ in a.next() }
        let bv = (0..<8).map { _ in b.next() }
        XCTAssertNotEqual(av, bv)
    }

    func testFNV1aIsStableAndOrderSensitive() {
        let s1 = SeededRandom.fnv1a(["/a/b.png", "/c/d.jpg"])
        let s2 = SeededRandom.fnv1a(["/a/b.png", "/c/d.jpg"])
        let s3 = SeededRandom.fnv1a(["/c/d.jpg", "/a/b.png"])
        XCTAssertEqual(s1, s2)
        XCTAssertNotEqual(s1, s3)
        // Known vector: FNV-1a 64 of empty input is the offset basis.
        XCTAssertEqual(SeededRandom.fnv1a([]), 0xcbf29ce484222325)
    }

    func testUniformDoubleInRange() {
        var rng = SeededRandom(seed: 7)
        for _ in 0..<100 {
            let v = Double.random(in: 3...9, using: &rng)
            XCTAssertTrue(v >= 3 && v <= 9)
        }
    }
}
