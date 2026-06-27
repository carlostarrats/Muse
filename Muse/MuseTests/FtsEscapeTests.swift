//
//  FtsEscapeTests.swift
//  MuseTests
//
//  FTS5 query escaping: tokens are prefix-matched and AND'd, but common
//  English stopwords ("for", "a", "the", …) are dropped first so a natural
//  phrase ("white wedding dresses for summer") isn't sabotaged by forcing a
//  rare-token AND on a filler word. If the query is ALL stopwords, every
//  token is kept (so a literal search for "the" still matches).
//

import XCTest
@testable import Muse

@MainActor
final class FtsEscapeTests: XCTestCase {

    func testStripsStopwordsFromAnd() {
        XCTAssertEqual(
            SearchService.ftsEscape("white wedding dresses for summer"),
            "\"white\"* AND \"wedding\"* AND \"dresses\"* AND \"summer\"*")
    }

    func testStopwordsAreCaseInsensitive() {
        XCTAssertEqual(
            SearchService.ftsEscape("Posters THAT have A happy vibe"),
            "\"Posters\"* AND \"happy\"* AND \"vibe\"*")
    }

    func testKeepsAllTokensWhenQueryIsAllStopwords() {
        // Don't strip to nothing — a literal "the for a" search must still match.
        XCTAssertEqual(
            SearchService.ftsEscape("the for a"),
            "\"the\"* AND \"for\"* AND \"a\"*")
    }

    func testOrdinaryMultiWordStillAnded() {
        XCTAssertEqual(
            SearchService.ftsEscape("red car"),
            "\"red\"* AND \"car\"*")
    }

    func testSingleContentWord() {
        XCTAssertEqual(SearchService.ftsEscape("summer"), "\"summer\"*")
    }

    func testExistingParenCleaningStillApplies() {
        // The pre-existing cleaner strips ()"* — verify stopword stripping
        // composes with it (this change must not regress that).
        XCTAssertEqual(
            SearchService.ftsEscape("happy (vibe)"),
            "\"happy\"* AND \"vibe\"*")
    }

    func testEmptyQuery() {
        XCTAssertEqual(SearchService.ftsEscape("   "), "\"\"")
    }

    // The stopword list must avoid English words that are meaningful CONTENT
    // nouns in a shipped language. French "or" = gold, "as" = ace — stripping
    // them would silently drop a real search term for a French user. Pins the
    // deliberate exclusion so a future edit doesn't "helpfully" re-add them.
    func testKeepsCrossLanguageContentWords() {
        XCTAssertEqual(
            SearchService.ftsEscape("bague or"),
            "\"bague\"* AND \"or\"*")
        XCTAssertEqual(
            SearchService.ftsEscape("carte as"),
            "\"carte\"* AND \"as\"*")
    }
}
