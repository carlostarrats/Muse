import XCTest
@testable import Muse

/// The shared ranker behind every add-a-tag / add-to-collection suggestion list.
final class TagSuggestTests: XCTestCase {

    private func c(_ label: String, _ count: Int) -> TagSuggest.Candidate {
        TagSuggest.Candidate(label: label, count: count)
    }

    private let pool = [
        TagSuggest.Candidate(label: "sunset", count: 48),
        TagSuggest.Candidate(label: "sunrise", count: 12),
        TagSuggest.Candidate(label: "sun", count: 4),
        TagSuggest.Candidate(label: "beach", count: 30),
        TagSuggest.Candidate(label: "unsorted", count: 2),
    ]

    // MARK: - Empty query

    func testEmptyQueryReturnsMostUsedFirst() {
        let out = TagSuggest.rank(pool, query: "", limit: 3)
        XCTAssertEqual(out.map(\.label), ["sunset", "beach", "sunrise"])
    }

    func testWhitespaceOnlyQueryIsTreatedAsEmpty() {
        XCTAssertEqual(TagSuggest.rank(pool, query: "   ", limit: 2).map(\.label),
                       TagSuggest.rank(pool, query: "", limit: 2).map(\.label))
    }

    func testLimitIsHonoured() {
        XCTAssertEqual(TagSuggest.rank(pool, query: "", limit: 2).count, 2)
        XCTAssertEqual(TagSuggest.rank(pool, query: "sun", limit: 1).count, 1)
    }

    // MARK: - Filtering

    func testPrefixMatchesRankAboveMidStringMatches() {
        // "unsorted" CONTAINS "sun"? No — but "sunset"/"sunrise"/"sun" all start
        // with it. Use a needle where both kinds exist: "un".
        let out = TagSuggest.rank(pool, query: "un", limit: 10)
        // "unsorted" is the only prefix match, so it leads despite the lowest count.
        XCTAssertEqual(out.first?.label, "unsorted")
        XCTAssertEqual(Set(out.map(\.label)), ["unsorted", "sunset", "sunrise", "sun"])
    }

    func testNonMatchesAreDropped() {
        XCTAssertEqual(TagSuggest.rank(pool, query: "beach", limit: 10).map(\.label), ["beach"])
        XCTAssertTrue(TagSuggest.rank(pool, query: "zzzz", limit: 10).isEmpty)
    }

    func testMatchIsCaseInsensitive() {
        XCTAssertEqual(TagSuggest.rank(pool, query: "BEACH", limit: 10).map(\.label), ["beach"])
    }

    func testMatchIsDiacriticInsensitive() {
        let accented = [c("café", 5), c("cafeteria", 1)]
        XCTAssertEqual(Set(TagSuggest.rank(accented, query: "cafe", limit: 10).map(\.label)),
                       ["café", "cafeteria"])
        // …and in the other direction.
        XCTAssertEqual(TagSuggest.rank([c("cafe", 5)], query: "café", limit: 10).map(\.label),
                       ["cafe"])
    }

    // MARK: - Ordering stability

    /// Equal counts must not shuffle between calls, or the list reorders under
    /// the user's cursor as they type.
    func testEqualCountsBreakTiesAlphabetically() {
        let tied = [c("zebra", 7), c("apple", 7), c("mango", 7)]
        XCTAssertEqual(TagSuggest.rank(tied, query: "", limit: 10).map(\.label),
                       ["apple", "mango", "zebra"])
    }

    func testOrderIsDeterministicAcrossRepeatedCalls() {
        let tied = [c("b", 3), c("a", 3), c("c", 3), c("d", 3)]
        let first = TagSuggest.rank(tied, query: "", limit: 10).map(\.label)
        for _ in 0..<20 {
            XCTAssertEqual(TagSuggest.rank(tied, query: "", limit: 10).map(\.label), first)
        }
    }

    // MARK: - Exclusions

    func testExcludeIsHonoured() {
        let out = TagSuggest.rank(pool, query: "", exclude: ["sunset", "beach"], limit: 10)
        XCTAssertFalse(out.map(\.label).contains("sunset"))
        XCTAssertFalse(out.map(\.label).contains("beach"))
        XCTAssertEqual(out.first?.label, "sunrise")
    }

    /// A rating is a manual tag whose label is a run of stars. Offering one here
    /// would let `addManualTag` (which has no mutual exclusion) attach a SECOND
    /// rating to a file and break StarRating.resolution.
    func testRatingGlyphsAreNeverSuggested() {
        var withRatings = pool
        for label in StarRating.allLabels {
            withRatings.append(c(label, 999))   // most-used, so it would lead
        }
        let unfiltered = TagSuggest.rank(withRatings, query: "", limit: 20)
        XCTAssertTrue(unfiltered.allSatisfy { !StarRating.isRating($0.label) })

        // …including when the user types the glyph itself.
        let searched = TagSuggest.rank(withRatings, query: StarRating.glyph, limit: 20)
        XCTAssertTrue(searched.allSatisfy { !StarRating.isRating($0.label) })
    }

    // MARK: - Display transform

    /// Matching runs on the DISPLAY term (what the user sees and types), but the
    /// returned label is the canonical key that gets written.
    func testMatchesTheDisplayTermButReturnsTheCanonicalLabel() {
        let french = ["dog": "chien", "cat": "chat", "bird": "oiseau"]
        let candidates = french.keys.map { c($0, 1) }

        let out = TagSuggest.rank(candidates, query: "chien",
                                  displaying: { french[$0] ?? $0 }, limit: 10)
        XCTAssertEqual(out.map(\.label), ["dog"])

        // The canonical English key must NOT match when a display transform is
        // in play — otherwise a French user typing "chat" and a stray "cat"
        // would both hit, which is the ambiguity this avoids.
        XCTAssertTrue(TagSuggest.rank(candidates, query: "dog",
                                      displaying: { french[$0] ?? $0 }, limit: 10).isEmpty)
    }

    func testDefaultDisplayIsIdentity() {
        XCTAssertEqual(TagSuggest.rank(pool, query: "beach", limit: 10).map(\.label), ["beach"])
    }

    // MARK: - Edges

    func testEmptyPoolIsEmpty() {
        XCTAssertTrue(TagSuggest.rank([], query: "", limit: 10).isEmpty)
        XCTAssertTrue(TagSuggest.rank([], query: "anything", limit: 10).isEmpty)
    }

    func testZeroLimitReturnsNothing() {
        XCTAssertTrue(TagSuggest.rank(pool, query: "", limit: 0).isEmpty)
    }
}
