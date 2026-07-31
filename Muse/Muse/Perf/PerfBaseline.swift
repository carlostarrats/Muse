//
//  PerfBaseline.swift
//  Muse
//
//  Developer command (`MUSE_PERF=1` at launch), never wired into app UI —
//  same env-var gating as PhaseTrace, so a shipped run does nothing.
//
//  Measures against the M1 Air 8GB reference machine (DECIDED #24): the
//  10k–50k design centre has to be flawless there, and "flawless" needs
//  numbers beside budgets rather than an impression. Writes
//  docs/perf-baseline-<date>.md with each measurement next to its budget.
//
//  It RECORDS; it does not fail. A perf assertion on a machine doing other
//  work is noise, so the tests cover the report formatting and this harness
//  reports over-budget rather than erroring.
//

import Foundation
import GRDB

struct PerfMeasurement: Sendable {
    let name: String
    let value: Double
    let unit: String
    let budget: Double
    /// Set when the measurement couldn't be taken on this run (no fixture, a
    /// mark never recorded) — reported as such rather than as a 0 that reads
    /// like a spectacular result.
    var unavailable: Bool = false

    var overBudget: Bool { !unavailable && value > budget }
}

struct PerfReport: Sendable {
    let machine: String
    let os: String
    let librarySize: Int
    let measurements: [PerfMeasurement]

    func markdown() -> String {
        var lines = [
            "# Muse Performance Baseline",
            "",
            "Machine: \(machine)",
            "OS: \(os)",
            "Library size: \(librarySize) files",
            "",
            "| Metric | Value | Budget | Status |",
            "|---|---|---|---|",
        ]
        for m in measurements {
            let value = m.unavailable ? "—" : "\(String(format: "%.1f", m.value)) \(m.unit)"
            let status = m.unavailable ? "not measured" : (m.overBudget ? "⚠ OVER BUDGET" : "OK")
            lines.append("| \(m.name) | \(value) | \(String(format: "%.1f", m.budget)) \(m.unit) | \(status) |")
        }
        return lines.joined(separator: "\n") + "\n"
    }
}

enum PerfBaseline {
    static let enabled = ProcessInfo.processInfo.environment["MUSE_PERF"] == "1"

    /// Long edge of the grid thumbnail whose decode is timed. Must be one of
    /// `ThumbnailCache.renderedVariants` — an unlisted size leaks past
    /// `invalidate`, so the "cache cleared" premise of the measurement would be
    /// false and the number would be a cache hit.
    private static let thumbnailProbeSize = CGSize(width: 320, height: 320)

    @MainActor
    static func run() async -> PerfReport {
        let machine = ProcessInfo.processInfo.hostName
        let os = ProcessInfo.processInfo.operatingSystemVersionString
        let librarySize: Int = (try? await Database.shared.dbQueue?.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM files") ?? 0
        }) as? Int ?? 0

        var measurements: [PerfMeasurement] = []
        measurements.append(measureColdStart())
        measurements.append(await measureSearchLatency())
        measurements.append(await measureThumbnailDecode())
        // Grid scroll frame time needs a scripted scroll against a mounted
        // view, which this headless harness can't drive. The row is emitted
        // anyway so the report's shape is stable and the budget is on record.
        measurements.append(PerfMeasurement(
            name: "grid scroll frame time (manual)", value: 0, unit: "ms p95",
            budget: 16.7, unavailable: true))

        let report = PerfReport(machine: machine, os: os,
                                librarySize: librarySize, measurements: measurements)
        writeReport(report)
        return report
    }

    // MARK: - Measurements

    private static func measureColdStart() -> PerfMeasurement {
        guard let elapsed = PhaseTrace.elapsed(from: "app.start", to: "grid.firstPaint") else {
            return PerfMeasurement(name: "cold start → first grid paint", value: 0,
                                   unit: "ms", budget: 1500, unavailable: true)
        }
        return PerfMeasurement(name: "cold start → first grid paint",
                               value: elapsed * 1000, unit: "ms", budget: 1500)
    }

    @MainActor
    private static func measureSearchLatency() async -> PerfMeasurement {
        let start = DispatchTime.now()
        _ = await SearchService.search(query: "photo", scope: .everywhere)
        return PerfMeasurement(name: "search latency", value: millis(since: start),
                               unit: "ms", budget: 150)
    }

    @MainActor
    private static func measureThumbnailDecode() async -> PerfMeasurement {
        // The fixture is supplied by env var rather than committed: a real
        // 24MP JPEG is not something to carry in the repo.
        guard let path = ProcessInfo.processInfo.environment["MUSE_PERF_FIXTURE_24MP"] else {
            return PerfMeasurement(name: "thumbnail decode (24MP)", value: 0,
                                   unit: "ms", budget: 60, unavailable: true)
        }
        let url = URL(fileURLWithPath: path)
        ThumbnailCache.shared.invalidate(url)
        let start = DispatchTime.now()
        _ = await ThumbnailCache.shared.thumbnail(for: url, size: thumbnailProbeSize, scale: 2.0)
        return PerfMeasurement(name: "thumbnail decode (24MP)", value: millis(since: start),
                               unit: "ms", budget: 60)
    }

    private static func millis(since start: DispatchTime) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000
    }

    // MARK: - Output

    /// Written to the repo's `docs/` when the process's working directory is
    /// the repo (running from Xcode), and to the sandbox tmp dir otherwise —
    /// a sandboxed app's write to an arbitrary path is silently denied, and a
    /// silently-missing report is worse than one in an odd place. The path is
    /// printed either way.
    private static func writeReport(_ report: PerfReport) {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let name = "perf-baseline-\(formatter.string(from: Date())).md"
        let markdown = report.markdown()

        let docs = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("docs", isDirectory: true)
        var target = docs.appendingPathComponent(name)
        if !FileManager.default.fileExists(atPath: docs.path) ||
            (try? markdown.write(to: target, atomically: true, encoding: .utf8)) == nil {
            target = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(name)
            try? markdown.write(to: target, atomically: true, encoding: .utf8)
        }
        print("[Muse] perf baseline → \(target.path)")
    }
}
