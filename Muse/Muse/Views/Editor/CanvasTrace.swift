//
//  CanvasTrace.swift
//  Muse
//
//  TEMPORARY diagnostic instrumentation for the editor canvas's resize
//  behaviour (2026-08-02). Not a feature — DELETE THIS FILE and its call sites
//  once the resize question is settled.
//
//  Off unless `MUSE_CANVAS_TRACE=1` is in the environment, so a normal launch
//  (Finder, Xcode, a shipped build) does nothing at all: no file, no formatting,
//  no queue work. Writes to `<container>/canvas-trace.log`, which in the sandbox
//  is ~/Library/Containers/com.tarrats.Muse/Data/canvas-trace.log
//

import Foundation

enum CanvasTrace {
    static let enabled =
        ProcessInfo.processInfo.environment["MUSE_CANVAS_TRACE"] == "1"

    /// Serial, so lines from the draw callback and from the session's render
    /// task can't interleave mid-line. All mutable state below is touched ONLY
    /// inside it.
    private static let queue = DispatchQueue(label: "com.tarrats.Muse.canvas-trace")
    nonisolated(unsafe) private static var handle: FileHandle?
    nonisolated(unsafe) private static var started: Date?

    private static let url = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent("canvas-trace.log")

    /// Truncate, so each run is one readable session rather than an append pile.
    static func begin(_ note: String) {
        guard enabled else { return }
        queue.async {
            try? Data().write(to: url)
            handle = try? FileHandle(forWritingTo: url)
            started = Date()
            write("=== \(note) ===")
        }
    }

    static func log(_ line: @autoclosure () -> String) {
        guard enabled else { return }
        // Evaluate the string on the CALLING thread: the values it formats are
        // live view state, and reading them later off the queue would sample a
        // different moment than the one being traced.
        let text = line()
        queue.async { write(text) }
    }

    /// Queue-only.
    private static func write(_ text: String) {
        let t = started.map { Date().timeIntervalSince($0) } ?? 0
        let stamp = String(format: "%8.3f  ", t)
        handle?.write(Data((stamp + text + "\n").utf8))
    }

    static func flush() {
        guard enabled else { return }
        queue.sync { try? handle?.synchronize() }
    }
}

/// Compact CGRect/CGSize formatting, so a line of six of them still reads.
func tr(_ r: CGRect) -> String {
    String(format: "(%.1f,%.1f %.1f×%.1f)", r.origin.x, r.origin.y, r.width, r.height)
}

func tr(_ s: CGSize) -> String {
    String(format: "%.1f×%.1f", s.width, s.height)
}
