//
//  SingleInstanceGuard.swift
//  MuseUITests
//
//  Refuse to drive the GUI while a second Muse is already running.
//
//  GRDB's `busyMode` is `.immediateError` and `Database.swift` states the
//  design assumption outright — "Single writer, single process." That holds for
//  a shipping user, but not on a dev machine, where an Xcode-launched or
//  `open -n` instance sits alongside the one the test starts. The loser of a
//  write collision gets `SQLITE_BUSY` with no retry, and a great many writes
//  are wrapped in `try?` — so the failures show up as phantom "my edit didn't
//  save" behaviour attributed to the app.
//
//  This was a note in the lens registry ("worth a mechanical guard rather than
//  a note") after a 2026-08-02 round lost a session to a 21-failure suite with
//  exactly this cause. A test that fails saying WHY costs nothing; a suite that
//  fails pointing at the wrong subsystem costs a round.
//

import XCTest
import AppKit

enum SingleInstanceGuard {
    static let bundleID = "com.tarrats.Muse"

    /// Call BEFORE `app.launch()`. Anything running at that point is not ours.
    static func assertNoOtherInstance(file: StaticString = #filePath,
                                      line: UInt = #line) {
        let running = NSRunningApplication
            .runningApplications(withBundleIdentifier: bundleID)
            .filter { !$0.isTerminated }
        guard running.isEmpty else {
            let pids = running.map { String($0.processIdentifier) }.joined(separator: ", ")
            XCTFail("""
                A Muse instance is already running (pid \(pids)) and this suite is \
                about to launch a second one. Two processes against one SQLite \
                file with busyMode = .immediateError manufacture failures that \
                look like app bugs — quit the other instance and re-run. This is \
                a test-environment problem, NOT a defect in whatever fails next.
                """, file: file, line: line)
            return
        }
    }
}
