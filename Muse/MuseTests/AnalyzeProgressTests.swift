import XCTest
@testable import Muse

final class AnalyzeProgressTests: XCTestCase {

    func testCountsUpMonotonically() {
        var p = AnalyzeProgress(total: 4)
        let a = p.complete(); XCTAssertEqual(a.completed, 1); XCTAssertEqual(a.fraction, 0.25, accuracy: 1e-9)
        let b = p.complete(); XCTAssertEqual(b.completed, 2); XCTAssertEqual(b.fraction, 0.50, accuracy: 1e-9)
        let c = p.complete(); XCTAssertEqual(c.completed, 3); XCTAssertEqual(c.fraction, 0.75, accuracy: 1e-9)
        let d = p.complete(); XCTAssertEqual(d.completed, 4); XCTAssertEqual(d.fraction, 1.00, accuracy: 1e-9)
        XCTAssertTrue(p.isFinished)
    }

    /// The bug this type exists to prevent: with a concurrent loop, completion
    /// order is not index order. Progress must never go backwards or overshoot.
    func testNeverExceedsTotalOrGoesBackwards() {
        var p = AnalyzeProgress(total: 3)
        var seen: [Double] = []
        for _ in 0..<10 { seen.append(p.complete().fraction) }
        XCTAssertEqual(seen, seen.sorted(), "fraction must be monotonically non-decreasing")
        XCTAssertLessThanOrEqual(seen.max() ?? 0, 1.0, "fraction must never exceed 1")
        XCTAssertEqual(p.complete().completed, 3, "completed must clamp at total")
    }

    func testZeroTotalIsFinishedAndSafe() {
        var p = AnalyzeProgress(total: 0)
        XCTAssertTrue(p.isFinished)
        let r = p.complete()
        XCTAssertEqual(r.completed, 0)
        XCTAssertEqual(r.fraction, 0, accuracy: 1e-9, "no division by zero")
    }

    func testNegativeTotalIsTreatedAsZero() {
        var p = AnalyzeProgress(total: -5)
        XCTAssertEqual(p.total, 0)
        XCTAssertTrue(p.isFinished)
        XCTAssertEqual(p.complete().fraction, 0, accuracy: 1e-9)
    }
}
