import XCTest
@testable import Muse

final class StarRatingTests: XCTestCase {

    func testLabelRoundTrip() {
        for n in 1...5 {
            let label = StarRating.label(for: n)
            XCTAssertNotNil(label)
            XCTAssertEqual(StarRating.rating(from: label!), n)
        }
    }

    func testLabelIsFilledGlyphRun() {
        XCTAssertEqual(StarRating.label(for: 3), "\u{2605}\u{2605}\u{2605}")
        XCTAssertEqual(StarRating.label(for: 1), "\u{2605}")
        XCTAssertEqual(StarRating.label(for: 5), "\u{2605}\u{2605}\u{2605}\u{2605}\u{2605}")
    }

    func testLabelOutOfRangeIsNil() {
        XCTAssertNil(StarRating.label(for: 0))
        XCTAssertNil(StarRating.label(for: 6))
        XCTAssertNil(StarRating.label(for: -1))
    }

    func testRatingRejectsNonRatingLabels() {
        XCTAssertNil(StarRating.rating(from: ""))
        XCTAssertNil(StarRating.rating(from: "beach"))
        XCTAssertNil(StarRating.rating(from: "\u{2605} favorite"))   // stars + text
        XCTAssertNil(StarRating.rating(from: "\u{2605}\u{2605}\u{2605}\u{2605}\u{2605}\u{2605}")) // 6
        XCTAssertNil(StarRating.rating(from: "\u{2606}"))            // ☆ hollow star
    }

    func testIsRating() {
        XCTAssertTrue(StarRating.isRating("\u{2605}\u{2605}"))
        XCTAssertFalse(StarRating.isRating("sunset"))
    }

    func testAllLabelsAscending() {
        XCTAssertEqual(StarRating.allLabels,
                       (1...5).map { String(repeating: "\u{2605}", count: $0) })
    }

    func testResolutionAddWhenNoneExisting() {
        let r = StarRating.resolution(existingLabels: ["beach"], newRating: 3)
        XCTAssertEqual(r.remove, [])
        XCTAssertEqual(r.add, ["\u{2605}\u{2605}\u{2605}"])
    }

    func testResolutionChangeRemovesOldAddsNew() {
        let r = StarRating.resolution(
            existingLabels: ["\u{2605}\u{2605}", "beach"], newRating: 5)
        XCTAssertEqual(r.remove, ["\u{2605}\u{2605}"])
        XCTAssertEqual(r.add, ["\u{2605}\u{2605}\u{2605}\u{2605}\u{2605}"])
    }

    func testResolutionSameRatingIsIdempotent() {
        let r = StarRating.resolution(
            existingLabels: ["\u{2605}\u{2605}\u{2605}"], newRating: 3)
        XCTAssertEqual(r.remove, [])
        XCTAssertEqual(r.add, [])
    }

    func testResolutionRemoveClearsAllRatings() {
        let r = StarRating.resolution(
            existingLabels: ["\u{2605}\u{2605}\u{2605}", "beach"], newRating: nil)
        XCTAssertEqual(r.remove, ["\u{2605}\u{2605}\u{2605}"])
        XCTAssertEqual(r.add, [])
    }
}
