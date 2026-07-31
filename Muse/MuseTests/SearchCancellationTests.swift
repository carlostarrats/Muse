//
//  SearchCancellationTests.swift
//  MuseTests
//
//  A superseded search must stop COMPUTING, not merely stop landing. The token
//  guard in AppState.runSearch already discards a stale result; without this
//  signal the work behind it — an embedding walk over every row in the library —
//  still ran to completion first.
//
//  This is a waste fix, not a correctness one, so the assertions are about the
//  signal itself and about `search` bailing when it's already set.
//

import XCTest
@testable import Muse

final class SearchCancellationTests: XCTestCase {

    func testStartsUncancelled() {
        XCTAssertFalse(SearchCancellation().isCancelled)
    }

    func testCancelIsOneWay() {
        let c = SearchCancellation()
        c.cancel()
        XCTAssertTrue(c.isCancelled)
        c.cancel()
        XCTAssertTrue(c.isCancelled, "nothing resets it — a superseded pass stays superseded")
    }

    /// The flag must be readable from a non-main thread: the whole reason it
    /// exists is that the expensive leg runs on GRDB's own thread, where Swift
    /// task-local cancellation doesn't reach.
    func testReadableOffMainThread() async {
        let c = SearchCancellation()
        c.cancel()
        let seen = await Task.detached { c.isCancelled }.value
        XCTAssertTrue(seen)
    }

    func testConcurrentCancelAndReadIsSafe() async {
        let c = SearchCancellation()
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<50 {
                group.addTask { if i.isMultiple(of: 2) { c.cancel() } else { _ = c.isCancelled } }
            }
        }
        XCTAssertTrue(c.isCancelled)
    }

    /// An already-superseded pass returns immediately without touching the DB,
    /// the embedder, or the embedding table.
    @MainActor
    func testPreCancelledSearchReturnsEmptyWithoutWork() async {
        let c = SearchCancellation()
        c.cancel()
        let results = await SearchService.search(query: "anything", scope: .everywhere,
                                                 cancellation: c)
        XCTAssertTrue(results.isEmpty)
    }

    /// Default-nil keeps every existing call site (App Intents, tests) working
    /// with no cancellation at all.
    @MainActor
    func testEmptyQueryStillShortCircuitsWithoutCancellation() async {
        let results = await SearchService.search(query: "   ", scope: .everywhere)
        XCTAssertTrue(results.isEmpty)
    }
}
