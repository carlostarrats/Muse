import XCTest
@testable import Muse

final class IndexerConcurrencyTests: XCTestCase {
    func testHashConcurrencyIsFourWide() {
        XCTAssertEqual(Indexer.hashConcurrency, 4)
    }

    /// A window this small must never be zero (no work would ever start) and
    /// must stay modest — an unbounded fan-out of userInitiated hashing tasks
    /// was the original large-library UI-stutter bug.
    func testHashConcurrencyIsBoundedAndPositive() {
        XCTAssertGreaterThan(Indexer.hashConcurrency, 0)
        XCTAssertLessThanOrEqual(Indexer.hashConcurrency, 8)
    }
}
