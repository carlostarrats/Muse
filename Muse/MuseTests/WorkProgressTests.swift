import XCTest
@testable import Muse

final class WorkProgressTests: XCTestCase {

    func testSharesSumToOne() {
        let sum = WorkProgress.indexShare + WorkProgress.analyzeShare
                + WorkProgress.organizeShare + WorkProgress.thumbShare
        XCTAssertEqual(sum, 1.0, accuracy: 1e-9)
    }

    func testIdleIsInactiveAndZero() {
        var p = WorkProgress()
        p.update(.init())
        XCTAssertFalse(p.isActive)
        XCTAssertEqual(p.fraction, 0, accuracy: 1e-9)
    }

    /// The reported bug: indexing hands off to analysis and the bar restarts.
    /// A finished phase must keep contributing its whole share.
    func testHandoffFromIndexingToAnalyzingDoesNotGoBackwards() {
        var p = WorkProgress()
        p.update(.init(indexFraction: 1.0, indexActive: true))
        let atEndOfIndexing = p.fraction
        XCTAssertEqual(atEndOfIndexing, WorkProgress.indexShare, accuracy: 1e-9)

        // Indexing ends, analysis begins at zero files done.
        p.update(.init(indexActive: false, analyzeFraction: 0, analyzeActive: true))
        XCTAssertGreaterThanOrEqual(p.fraction, atEndOfIndexing,
                                    "bar must not fall back when the phase changes")
        XCTAssertEqual(p.fraction, WorkProgress.indexShare, accuracy: 1e-9)
    }

    func testProgressIsMonotonicAcrossAFullRun() {
        var p = WorkProgress()
        var seen: [Double] = []
        for f in stride(from: 0.0, through: 1.0, by: 0.25) {
            p.update(.init(indexFraction: f, indexActive: true)); seen.append(p.fraction)
        }
        for f in stride(from: 0.0, through: 1.0, by: 0.25) {
            p.update(.init(analyzeFraction: f, analyzeActive: true)); seen.append(p.fraction)
        }
        p.update(.init(organizing: true)); seen.append(p.fraction)
        XCTAssertEqual(seen, seen.sorted(), "fraction must never decrease: \(seen)")
        XCTAssertLessThanOrEqual(seen.max() ?? 0, 1.0)
    }

    /// A jittering phase flag (analysis flicking on/off between batches) must not
    /// make the bar stutter backwards.
    func testFlappingPhaseFlagsDoNotRewind() {
        var p = WorkProgress()
        p.update(.init(analyzeFraction: 0.8, analyzeActive: true))
        let high = p.fraction
        p.update(.init(indexFraction: 0.1, indexActive: true))   // a new batch starts indexing
        XCTAssertGreaterThanOrEqual(p.fraction, high, "must not rewind mid-run")
    }

    func testResetsOnlyWhenEverythingGoesIdle() {
        var p = WorkProgress()
        p.update(.init(analyzeFraction: 0.9, analyzeActive: true))
        XCTAssertGreaterThan(p.fraction, 0)
        p.update(.init())                       // all idle
        XCTAssertEqual(p.fraction, 0, accuracy: 1e-9)
        XCTAssertFalse(p.isActive)
        p.update(.init(indexFraction: 0.1, indexActive: true))   // fresh run
        XCTAssertEqual(p.fraction, WorkProgress.indexShare * 0.1, accuracy: 1e-9,
                       "a new run starts from its own value, not the old high-water mark")
    }

    func testFractionNeverExceedsOneWithEveryPhaseActive() {
        XCTAssertLessThanOrEqual(WorkProgress.rawFraction(
            .init(indexFraction: 1, indexActive: true,
                  analyzeFraction: 1, analyzeActive: true,
                  organizing: true, thumbFraction: 1, thumbActive: true)), 1.0)
    }

    func testOutOfRangeFractionsAreClamped() {
        let over = WorkProgress.rawFraction(.init(indexFraction: 5, indexActive: true))
        XCTAssertEqual(over, WorkProgress.indexShare, accuracy: 1e-9)
        let under = WorkProgress.rawFraction(.init(indexFraction: -3, indexActive: true))
        XCTAssertEqual(under, 0, accuracy: 1e-9)
    }

    /// Thumbnails alone (scrolling a warm folder, no index/analyze) still shows
    /// movement rather than sitting at zero.
    func testThumbnailsOnlyStillReportsProgress() {
        var p = WorkProgress()
        p.update(.init(thumbFraction: 0.5, thumbActive: true))
        XCTAssertTrue(p.isActive)
        XCTAssertGreaterThan(p.fraction, 0)
    }
}
