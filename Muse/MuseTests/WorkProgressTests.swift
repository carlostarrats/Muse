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

    /// Going idle now FILLS the bar and holds it (see the finish-hold tests);
    /// the clear happens on `reset()`. A fresh run must then start from its own
    /// value, never inheriting the previous run's high-water mark.
    func testResetsOnlyWhenEverythingGoesIdle() {
        var p = WorkProgress()
        p.update(.init(analyzeFraction: 0.9, analyzeActive: true))
        XCTAssertGreaterThan(p.fraction, 0)
        p.update(.init())                       // all idle -> fills and holds
        XCTAssertEqual(p.fraction, 1.0, accuracy: 1e-9)
        p.reset()                               // hold elapses
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

// MARK: - Finish hold

extension WorkProgressTests {

    /// A run must visibly reach 100% rather than vanishing partway.
    func testGoingIdleFillsTheBarAndHolds() {
        var p = WorkProgress()
        p.update(.init(analyzeFraction: 1, analyzeActive: true))
        XCTAssertLessThan(p.fraction, 1.0, "mid-run it hasn't earned 100% yet")
        p.update(.init())                       // everything idle
        XCTAssertTrue(p.isActive, "pill stays up during the finish hold")
        XCTAssertTrue(p.isFinishing)
        XCTAssertEqual(p.fraction, 1.0, accuracy: 1e-9, "bar completes")
    }

    func testResetClearsAfterTheHold() {
        var p = WorkProgress()
        p.update(.init(indexFraction: 0.5, indexActive: true))
        p.update(.init())
        p.reset()
        XCTAssertFalse(p.isActive)
        XCTAssertFalse(p.isFinishing)
        XCTAssertEqual(p.fraction, 0, accuracy: 1e-9)
    }

    /// Repeated idle publishes must not re-arm the hold over and over.
    func testRepeatedIdleUpdatesDoNotRetriggerTheFinish() {
        var p = WorkProgress()
        p.update(.init(indexFraction: 0.5, indexActive: true))
        p.update(.init())
        p.reset()
        p.update(.init())                       // still idle, already reset
        XCTAssertFalse(p.isActive, "an idle publish must not resurrect the pill")
        XCTAssertFalse(p.isFinishing)
    }

    /// Work resuming during the hold must cancel the finish, not leave the bar
    /// pinned at 100% for the new batch.
    func testWorkResumingDuringHoldCancelsTheFinish() {
        var p = WorkProgress()
        p.update(.init(analyzeFraction: 0.9, analyzeActive: true))
        p.update(.init())                       // finishing
        XCTAssertTrue(p.isFinishing)
        p.update(.init(indexFraction: 0.1, indexActive: true))   // new batch
        XCTAssertFalse(p.isFinishing, "a new run cancels the pending finish")
        XCTAssertTrue(p.isActive)
        // The bug this pins: without ending the held run first, the monotonic
        // max kept the bar at the 1.0 the finish hold set, so a brand-new batch
        // rendered as permanently complete.
        XCTAssertEqual(p.fraction, WorkProgress.indexShare * 0.1, accuracy: 1e-9,
                       "a batch starting during the hold must restart the bar")
        p.reset()                               // stale hold callback fires late
        XCTAssertTrue(p.isActive, "a late reset must not kill an active run")
    }

    func testResetIsANoOpWhenNotFinishing() {
        var p = WorkProgress()
        p.update(.init(indexFraction: 0.4, indexActive: true))
        let before = p.fraction
        p.reset()
        XCTAssertTrue(p.isActive)
        XCTAssertEqual(p.fraction, before, accuracy: 1e-9)
    }
}
