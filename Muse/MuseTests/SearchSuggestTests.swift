//
//  SearchSuggestTests.swift
//  MuseTests
//
//  Pure: current field text + facets → at most 8 suggestions. A trailing
//  partial word that prefixes a token key suggests the key; a trailing "key:"
//  or "key:partial" suggests real facet values; plain free text suggests
//  nothing.
//

import XCTest
@testable import Muse

final class SearchSuggestTests: XCTestCase {
    private let facets = FacetsSnapshot(
        cameras: ["FUJIFILM X100V", "Canon EOS R5"],
        lenses: ["23mm f/2", "50mm f/1.8"],
        places: ["Lisboa", "Porto"],
        years: ["2019", "2023"])

    func testKeyPrefixSuggestsKey() {
        let suggestions = SearchSuggest.suggestions(fieldText: "cam", facets: facets)
        XCTAssertTrue(suggestions.contains { $0.completion.hasSuffix("camera:") })
    }

    func testKeyColonSuggestsRealValues() {
        let suggestions = SearchSuggest.suggestions(fieldText: "camera:", facets: facets)
        XCTAssertTrue(suggestions.contains { $0.completion.contains("FUJIFILM X100V") })
    }

    func testValueWithSpacesIsQuotedSoItStaysOneToken() {
        let suggestions = SearchSuggest.suggestions(fieldText: "camera:", facets: facets)
        guard let completion = suggestions.first(where: { $0.display.contains("FUJIFILM") })?.completion
        else { return XCTFail("no FUJIFILM suggestion") }
        XCTAssertEqual(SearchQueryParser.parse(completion).tokens, [.camera("FUJIFILM X100V")])
    }

    func testPartialValueFiltersFacetList() {
        let suggestions = SearchSuggest.suggestions(fieldText: "camera:fuji", facets: facets)
        XCTAssertTrue(suggestions.contains { $0.completion.contains("FUJIFILM X100V") })
        XCTAssertFalse(suggestions.contains { $0.completion.contains("Canon") })
    }

    func testPlainFreeTextSuggestsNothing() {
        XCTAssertTrue(SearchSuggest.suggestions(fieldText: "sunset beach", facets: facets).isEmpty)
    }

    func testEmptyFieldSuggestsNothing() {
        XCTAssertTrue(SearchSuggest.suggestions(fieldText: "", facets: facets).isEmpty)
    }

    func testCompletionPreservesPrecedingText() {
        let suggestions = SearchSuggest.suggestions(fieldText: "star:4 cam", facets: facets)
        XCTAssertFalse(suggestions.isEmpty)
        XCTAssertTrue(suggestions.allSatisfy { $0.completion.hasPrefix("star:4 ") })
    }

    func testCapsAtEight() {
        let many = FacetsSnapshot(cameras: (0..<20).map { "Camera \($0)" },
                                  lenses: [], places: [], years: [])
        XCTAssertLessThanOrEqual(
            SearchSuggest.suggestions(fieldText: "camera:", facets: many).count, 8)
    }

    func testUnknownKeyOffersNoValues() {
        XCTAssertTrue(SearchSuggest.suggestions(fieldText: "banana:", facets: facets).isEmpty)
    }
}
