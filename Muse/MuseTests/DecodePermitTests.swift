import XCTest
@testable import Muse

final class DecodePermitTests: XCTestCase {

    func testOrdinaryPhotoCostsOnePermit() {
        XCTAssertEqual(DecodePermit.cost(forDeclaredPixels: 12_000_000, limit: 8), 1)  // 12 MP phone
        XCTAssertEqual(DecodePermit.cost(forDeclaredPixels: 24_000_000, limit: 8), 1)  // 24 MP RAW
        XCTAssertEqual(DecodePermit.cost(forDeclaredPixels: 30_000_000, limit: 8), 1)  // at the line
    }

    func testLargeScanCostsMore() {
        let mid = DecodePermit.cost(forDeclaredPixels: 65_000_000, limit: 8)
        let big = DecodePermit.cost(forDeclaredPixels: 115_000_000, limit: 8)
        XCTAssertGreaterThan(mid, 1, "a 65 MP scan must not be treated like a snapshot")
        XCTAssertGreaterThan(big, mid, "cost must grow with pixel count")
    }

    func testCostNeverExceedsLimit() {
        XCTAssertLessThanOrEqual(DecodePermit.cost(forDeclaredPixels: 299_000_000, limit: 8), 8)
        XCTAssertLessThanOrEqual(DecodePermit.cost(forDeclaredPixels: Int.max, limit: 8), 8)
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
