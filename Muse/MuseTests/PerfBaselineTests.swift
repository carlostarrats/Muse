//
//  PerfBaselineTests.swift
//  MuseTests
//
//  This suite asserts the pure report-formatting logic, NOT the timing numbers
//  themselves — a perf assertion on a machine doing other work is noise, and a
//  flaky red suite teaches people to ignore it. The harness records; a human
//  reads the report.
//

import XCTest
@testable import Muse

final class PerfBaselineTests: XCTestCase {

    private func report(_ measurements: [PerfMeasurement]) -> PerfReport {
        PerfReport(machine: "Test Machine", os: "macOS 14.6",
                   librarySize: 100, measurements: measurements)
    }

    func testMarkdownIncludesAllMeasurements() {
        let md = report([
            PerfMeasurement(name: "cold start", value: 1200, unit: "ms", budget: 1500),
            PerfMeasurement(name: "search latency", value: 90, unit: "ms", budget: 150),
        ]).markdown()
        XCTAssertTrue(md.contains("cold start"))
        XCTAssertTrue(md.contains("search latency"))
        XCTAssertTrue(md.contains("Test Machine"))
        XCTAssertTrue(md.contains("100 files"))
    }

    func testMarkdownFlagsOverBudgetMeasurements() {
        let md = report([
            PerfMeasurement(name: "slow thing", value: 200, unit: "ms", budget: 60),
        ]).markdown()
        XCTAssertTrue(md.contains("OVER BUDGET"))
    }

    func testWithinBudgetReadsOK() {
        let md = report([
            PerfMeasurement(name: "fast thing", value: 10, unit: "ms", budget: 60),
        ]).markdown()
        XCTAssertTrue(md.contains("OK"))
        XCTAssertFalse(md.contains("OVER BUDGET"))
    }

    /// An unavailable measurement must never render as a 0 that reads like a
    /// spectacular result.
    func testUnavailableMeasurementIsNotReportedAsZero() {
        let m = PerfMeasurement(name: "no fixture", value: 0, unit: "ms",
                                budget: 60, unavailable: true)
        XCTAssertFalse(m.overBudget)
        let md = report([m]).markdown()
        XCTAssertTrue(md.contains("not measured"))
        XCTAssertFalse(md.contains("| 0.0 ms |"))
    }

    func testExactBudgetIsNotOverBudget() {
        XCTAssertFalse(PerfMeasurement(name: "x", value: 60, unit: "ms", budget: 60).overBudget)
    }

    // MARK: - PhaseTrace timeline, which cold start is measured from

    func testElapsedIsNilForUnrecordedMarks() {
        XCTAssertNil(PhaseTrace.elapsed(from: "perf.no.such.mark.a",
                                        to: "perf.no.such.mark.b"))
    }

    /// The timeline keeps the FIRST occurrence of each mark, so a phase that
    /// repeats (a later folder switch re-publishing the grid) can't move a
    /// baseline's start or end.
    func testTimelineKeepsFirstOccurrence() throws {
        try XCTSkipUnless(PhaseTrace.timelineEnabled,
                          "timeline only records under MUSE_TRACE/MUSE_PERF")
        PhaseTrace.mark("perf.test.a")
        PhaseTrace.mark("perf.test.b")
        let first = PhaseTrace.elapsed(from: "perf.test.a", to: "perf.test.b")
        PhaseTrace.mark("perf.test.b")
        XCTAssertEqual(first, PhaseTrace.elapsed(from: "perf.test.a", to: "perf.test.b"))
    }
}
