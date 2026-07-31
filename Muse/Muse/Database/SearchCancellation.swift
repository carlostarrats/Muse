//
//  SearchCancellation.swift
//  Muse
//
//  A cancellation signal for a search pass that SURVIVES the hop onto GRDB's
//  own thread.
//
//  Swift task-local cancellation does not propagate into a `queue.read {}`
//  closure — GRDB runs it on its serial DB thread behind a continuation, so
//  `Task.isCancelled` there is always false. That is exactly where the
//  expensive work lives: the semantic leg fetches EVERY embedding row and
//  cosine-scores all of them, which is the whole reason a superseded search
//  is worth stopping. So the flag is an explicit object, passed in.
//
//  It only ever goes false → true. Nothing resets it; a superseded pass stays
//  superseded.
//

import Foundation

final class SearchCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock(); defer { lock.unlock() }
        cancelled = true
    }
}
