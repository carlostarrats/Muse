import XCTest
@testable import Muse

final class DecodePermitTests: XCTestCase {

    func testOrdinaryPhotoCostsOnePermit() {
        XCTAssertEqual(DecodePermit.cost(forDeclaredPixels: 12_000_000, limit: 8), 1)   // 12 MP phone
        XCTAssertEqual(DecodePermit.cost(forDeclaredPixels: 24_000_000, limit: 8), 1)   // 24 MP RAW
        XCTAssertEqual(DecodePermit.cost(forDeclaredPixels: 100_000_000, limit: 8), 1)  // at the line
    }

    /// Regression guard for a measured mistake: weighting a 65 MP scan above 1
    /// permit serialised folder-open and made it 2.6x SLOWER over big scans.
    /// Realistic images — including medium-format scans — must stay at full
    /// 8-wide parallelism.
    func testRealisticScansStayFullyParallel() {
        XCTAssertEqual(DecodePermit.cost(forDeclaredPixels: 65_000_000, limit: 8), 1,
                       "a 65 MP medium-format scan must not be throttled")
        XCTAssertEqual(DecodePermit.cost(forDeclaredPixels: 99_000_000, limit: 8), 1)
    }

    func testOnlyExtremeImagesCostMore() {
        XCTAssertEqual(DecodePermit.cost(forDeclaredPixels: 115_000_000, limit: 8), 2)
        XCTAssertEqual(DecodePermit.cost(forDeclaredPixels: 250_000_000, limit: 8), 2,
                       "cost is capped so a giant image can never serialise the gate")
    }

    func testCostNeverExceedsLimit() {
        XCTAssertLessThanOrEqual(DecodePermit.cost(forDeclaredPixels: 299_000_000, limit: 8), DecodePermit.maxCost)
        XCTAssertLessThanOrEqual(DecodePermit.cost(forDeclaredPixels: Int.max, limit: 8), DecodePermit.maxCost)
        XCTAssertEqual(DecodePermit.cost(forDeclaredPixels: 115_000_000, limit: 1), 1)
    }

    func testUnknownOrDegenerateSizeCostsOne() {
        XCTAssertEqual(DecodePermit.cost(forDeclaredPixels: nil, limit: 8), 1,
                       "unknown header must not deadlock the gate")
        XCTAssertEqual(DecodePermit.cost(forDeclaredPixels: 0, limit: 8), 1)
        XCTAssertEqual(DecodePermit.cost(forDeclaredPixels: -5, limit: 8), 1)
    }

    func testCostIsAlwaysAtLeastOne() {
        for px in [1, 1000, 1_000_000, 50_000_000, 200_000_000] {
            XCTAssertGreaterThanOrEqual(DecodePermit.cost(forDeclaredPixels: px, limit: 8), 1)
        }
        XCTAssertGreaterThanOrEqual(DecodePermit.cost(forDeclaredPixels: 100_000_000, limit: 0), 1,
                                    "a degenerate limit must still grant a usable permit")
    }
}
