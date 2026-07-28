//
//  AnalyzeProgress.swift
//  Muse
//
//  Completion accounting for the analyze pass.
//
//  The pass used to be a serial `for (idx, pair) in pairs.enumerated()` loop
//  that derived progress from the loop INDEX. Under a concurrent loop, index
//  order is not completion order, so an index-derived fraction jumps backwards
//  whenever a later-started file finishes before an earlier-started one. This
//  type counts COMPLETIONS instead, and clamps, so the "N of M" pill can only
//  ever move forward.
//

import Foundation

struct AnalyzeProgress {
    let total: Int
    private(set) var completed: Int = 0

    init(total: Int) {
        self.total = max(0, total)
    }

    var isFinished: Bool { completed >= total }

    /// Record one finished file. Returns the new count and the 0...1 fraction.
    /// Safe to over-call: both outputs clamp at `total`.
    @discardableResult
    mutating func complete() -> (completed: Int, fraction: Double) {
        completed = min(total, completed + 1)
        let fraction = total > 0 ? Double(completed) / Double(total) : 0
        return (completed, fraction)
    }
}
