import XCTest
@testable import Muse

final class ReclusterGateTests: XCTestCase {

    func testGateSkipsWhenNothingNewWasEmbedded() {
        XCTAssertFalse(ReclusterGate.shouldRecluster(embeddingsWritten: 0, force: false))
    }

    func testGateRunsWhenSomethingWasEmbedded() {
        XCTAssertTrue(ReclusterGate.shouldRecluster(embeddingsWritten: 1, force: false))
        XCTAssertTrue(ReclusterGate.shouldRecluster(embeddingsWritten: 250, force: false))
    }

    func testForceAlwaysRuns() {
        XCTAssertTrue(ReclusterGate.shouldRecluster(embeddingsWritten: 0, force: true))
        XCTAssertTrue(ReclusterGate.shouldRecluster(embeddingsWritten: 5, force: true))
    }

    func testNegativeCountIsTreatedAsNothing() {
        XCTAssertFalse(ReclusterGate.shouldRecluster(embeddingsWritten: -3, force: false))
    }
}
