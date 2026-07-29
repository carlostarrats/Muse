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

    // MARK: - Grid badge sizing

    /// Width of the full ★-run at `n` stars, capsule padding included — the
    /// same expression `badgeLabel` compares against.
    private func fullRunWidth(_ n: Int) -> CGFloat {
        CGFloat(n) * StarRating.badgeStarGlyphWidth + StarRating.badgeHorizontalPadding * 2
    }

    func testCompactLabelShape() {
        XCTAssertEqual(StarRating.compactLabel(for: 1), "1\u{2605}")
        XCTAssertEqual(StarRating.compactLabel(for: 5), "5\u{2605}")
    }

    func testCompactLabelOutOfRangeIsNil() {
        XCTAssertNil(StarRating.compactLabel(for: 0))
        XCTAssertNil(StarRating.compactLabel(for: 6))
        XCTAssertNil(StarRating.compactLabel(for: -1))
    }

    func testBadgeLabelOutOfRangeIsNil() {
        XCTAssertNil(StarRating.badgeLabel(for: 0, availableWidth: 999))
        XCTAssertNil(StarRating.badgeLabel(for: 6, availableWidth: 999))
    }

    /// With room to spare, every rating draws its full run.
    func testBadgeLabelUsesFullRunWhenItFits() {
        for n in 1...5 {
            XCTAssertEqual(StarRating.badgeLabel(for: n, availableWidth: 500),
                           StarRating.label(for: n),
                           "\(n) stars should draw the full run at a generous width")
        }
    }

    /// The boundary is exact: at precisely the run's own width it still fits;
    /// a hair under and it doesn't.
    func testBadgeLabelBoundaryIsExact() {
        for n in 2...5 {
            let w = fullRunWidth(n)
            XCTAssertEqual(StarRating.badgeLabel(for: n, availableWidth: w),
                           StarRating.label(for: n),
                           "\(n) stars should still fit at exactly its own width")
            XCTAssertEqual(StarRating.badgeLabel(for: n, availableWidth: w - 0.01),
                           StarRating.compactLabel(for: n),
                           "\(n) stars should collapse just below its own width")
        }
    }

    /// One star never collapses: the compact form ("1★") is WIDER than the run
    /// itself ("★"), so collapsing would make the overflow worse.
    func testOneStarNeverCollapses() {
        XCTAssertEqual(StarRating.badgeLabel(for: 1, availableWidth: 0),
                       StarRating.label(for: 1))
        XCTAssertEqual(StarRating.badgeLabel(for: 1, availableWidth: 1),
                       StarRating.label(for: 1))
    }

    /// Whenever the compact form IS chosen, it is genuinely narrower than the
    /// run it replaced — the property that makes the swap worth doing.
    func testCompactIsNarrowerWheneverChosen() {
        let compactWidth = StarRating.badgeCompactWidth + StarRating.badgeHorizontalPadding * 2
        for n in 1...5 {
            let chosen = StarRating.badgeLabel(for: n, availableWidth: 0)
            if chosen == StarRating.compactLabel(for: n) {
                XCTAssertLessThan(compactWidth, fullRunWidth(n),
                                  "\(n) stars collapsed to a form that isn't narrower")
            }
        }
    }

    /// A zero/negative budget (a tile whose slot hasn't been measured yet) must
    /// still return SOMETHING drawable rather than nil — the badge should never
    /// silently vanish because geometry arrived late.
    func testDegenerateWidthStillDrawsABadge() {
        for n in 1...5 {
            XCTAssertNotNil(StarRating.badgeLabel(for: n, availableWidth: 0))
            XCTAssertNotNil(StarRating.badgeLabel(for: n, availableWidth: -50))
        }
    }

    // MARK: - Write policy
    //
    // A rating is stored as a manual tag, so every generic tag-write path can
    // reach it — and none of them enforce one-rating-per-photo.

    func testManualTagPolicyRejectsRatingRunsOnly() {
        // Every canonical rating is refused: addManualTag has no mutual
        // exclusion, so one would leave a file carrying two ratings.
        for label in StarRating.allLabels {
            XCTAssertFalse(StarRating.allowsManualTag(label), "\(label) must not be addable as a tag")
        }
        // Ordinary labels are unaffected, including ones that merely CONTAIN a
        // star or exceed the rating range — those are real user tags.
        for label in ["beach", "★ favourite", "5 stars", "★★★★★★", "", "☆☆"] {
            XCTAssertTrue(StarRating.allowsManualTag(label), "\(label) is a normal tag")
        }
    }

    func testRenamePolicyRefusesBothDirections() {
        // FROM a rating: library-wide data loss (every ★★★ in the library).
        XCTAssertFalse(StarRating.allowsRename(from: "★★★", to: "three stars"))
        // TO a rating: mints a second rating on files that already have one.
        XCTAssertFalse(StarRating.allowsRename(from: "beach", to: "★★★"))
        // Rating to rating is both at once.
        XCTAssertFalse(StarRating.allowsRename(from: "★", to: "★★"))
        // Ordinary renames still work, including near-misses on either side.
        XCTAssertTrue(StarRating.allowsRename(from: "beach", to: "shore"))
        XCTAssertTrue(StarRating.allowsRename(from: "★★★★★★", to: "six stars"))
        XCTAssertTrue(StarRating.allowsRename(from: "sunset", to: "★ sunset"))
    }
}
