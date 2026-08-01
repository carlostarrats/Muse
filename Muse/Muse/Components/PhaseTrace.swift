//
//  PhaseTrace.swift
//  Muse
//
//  Opt-in timeline of background phases, for diagnosing "the progress pill came
//  back a minute after it finished".
//
//  Reasoning about which phase restarted has already been wrong twice here (the
//  60s mood timer turned out to be palette-only; a suspected read→FSEvents loop
//  was disproved by probe — reading a file fires no events at all). So the
//  question gets answered by RECORDING what actually happened, which is this
//  codebase's standing rule for timing bugs.
//
//  Off unless `MUSE_TRACE=1` is set, so it costs a single Bool check otherwise
//  and can never affect a shipped run. Writes to NSTemporaryDirectory() — inside
//  the sandbox container, since a sandboxed app's writes to /tmp are silently
//  denied and NSLog does not reach `log stream` here.
//

import Foundation

// `nonisolated`: this is a tracing hook called from the indexer, the analyze
// pipeline and the backfills, all off-main, and it is already internally
// thread-safe (its own DispatchQueue + a lock around the timeline).
nonisolated enum PhaseTrace {
    static let enabled = ProcessInfo.processInfo.environment["MUSE_TRACE"] == "1"

    /// `<container>/tmp/muse-phase-trace.log`, printed once at startup.
    static let url: URL = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("muse-phase-trace.log")

    /// Keep an in-memory timeline as well as the log file. Enabled by MUSE_PERF
    /// too, because PerfBaseline measures cold start as the delta between two
    /// marks and parsing the log back would be absurd. Both are env-gated, so a
    /// shipped run still pays one Bool check and stores nothing.
    static let timelineEnabled = enabled
        || ProcessInfo.processInfo.environment["MUSE_PERF"] == "1"

    private static let queue = DispatchQueue(label: "com.tarrats.Muse.phaseTrace")
    private static let start = Date()

    private static let timelineLock = NSLock()
    nonisolated(unsafe) private static var timeline: [String: TimeInterval] = [:]

    /// Seconds between two recorded marks, or nil if either is missing. First
    /// occurrence of each event wins — a repeated phase must not move a
    /// baseline's start or end.
    static func elapsed(from: String, to: String) -> TimeInterval? {
        timelineLock.lock(); defer { timelineLock.unlock() }
        guard let a = timeline[from], let b = timeline[to], b >= a else { return nil }
        return b - a
    }

    /// Record one phase transition. `detail` carries the count that matters
    /// (how many files this batch is about) — the thing that says whether a
    /// second burst is real work or a repeat of the first.
    /// `detail` is an @autoclosure: Swift evaluates call arguments BEFORE the
    /// callee, so a plain `String` parameter meant every call site still built
    /// its interpolated string ("n=\(count) force=\(force)…") on every index
    /// batch and every FSEvents delivery even with tracing off. Deferring it
    /// makes a disabled trace genuinely free — one Bool check.
    static func mark(_ event: @autoclosure () -> String,
                     _ detail: @autoclosure () -> String = "") {
        guard timelineEnabled else { return }
        let t = Date().timeIntervalSince(start)
        let name = event()
        timelineLock.lock()
        if timeline[name] == nil { timeline[name] = t }
        timelineLock.unlock()
        guard enabled else { return }
        let line = String(format: "%8.2fs  %@ %@\n", t, name, detail())
        queue.async {
            if let h = try? FileHandle(forWritingTo: url) {
                h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close()
            } else {
                try? Data(line.utf8).write(to: url)
            }
        }
    }

    static func begin() {
        // The timeline's zero point. Recorded whenever either env var is set,
        // so PerfBaseline has a start even with tracing off.
        mark("app.start")
        guard enabled else { return }
        try? FileManager.default.removeItem(at: url)
        mark("TRACE-START", url.path)
        print("[Muse] phase trace → \(url.path)")
    }
}
