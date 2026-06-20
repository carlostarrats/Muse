import XCTest
@testable import Muse

final class FolderStatSchedulerTests: XCTestCase {

    // A fresh burst (now == burstStart) debounces by the quiet interval.
    func testFreshBurstDebounces() {
        XCTAssertEqual(
            StatRecomputeScheduler.decide(burstStart: 100, now: 100, quiet: 0.4, maxWait: 2.0),
            .debounce(0.4))
    }

    // Still within the cap → keep debouncing (trailing edge after quiet).
    func testUnderCapDebounces() {
        XCTAssertEqual(
            StatRecomputeScheduler.decide(burstStart: 100, now: 101.9, quiet: 0.4, maxWait: 2.0),
            .debounce(0.4))
    }

    // At/over the cap → flush now so a sustained event stream can't starve the
    // recompute forever (the bug: 0.4s debounce reset on every event → never fires).
    func testAtCapFlushesNow() {
        XCTAssertEqual(
            StatRecomputeScheduler.decide(burstStart: 100, now: 102.0, quiet: 0.4, maxWait: 2.0),
            .flushNow)
    }

    func testWellOverCapFlushesNow() {
        XCTAssertEqual(
            StatRecomputeScheduler.decide(burstStart: 100, now: 110, quiet: 0.4, maxWait: 2.0),
            .flushNow)
    }

    // The cap and quiet are parameters, not hardcoded in the policy.
    func testHonorsCustomIntervals() {
        XCTAssertEqual(
            StatRecomputeScheduler.decide(burstStart: 0, now: 0.5, quiet: 0.25, maxWait: 1.0),
            .debounce(0.25))
        XCTAssertEqual(
            StatRecomputeScheduler.decide(burstStart: 0, now: 1.0, quiet: 0.25, maxWait: 1.0),
            .flushNow)
    }
}
