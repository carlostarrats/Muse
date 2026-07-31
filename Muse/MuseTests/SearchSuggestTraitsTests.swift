//
//  SearchSuggestTraitsTests.swift
//  MuseTests
//

import XCTest
@testable import Muse

final class SearchSuggestTraitsTests: XCTestCase {
    func testFacesIsASuggestedKey() {
        let suggestions = SearchSuggest.suggestions(fieldText: "fa", facets: .empty)
        XCTAssertTrue(suggestions.contains { $0.completion.hasSuffix("faces:") })
    }

    func testIsSuggestsPortraitAndGroupValues() {
        let suggestions = SearchSuggest.suggestions(fieldText: "is:", facets: .empty)
        let completions = Set(suggestions.map(\.completion))
        XCTAssertTrue(completions.contains("is:portrait"))
        XCTAssertTrue(completions.contains("is:group"))
    }

    func testPetsSuggestsANumericHint() {
        let suggestions = SearchSuggest.suggestions(fieldText: "pets:", facets: .empty)
        XCTAssertTrue(suggestions.contains { $0.completion == "pets:>0" })
    }

    func testDisplayLabels() {
        XCTAssertEqual(SearchToken.faces(.init(op: .gt, value: 2)).displayLabel,
                       "\(String(localized: "faces")) >2")
        XCTAssertEqual(SearchToken.pets(.init(op: .gt, value: 0)).displayLabel,
                       "\(String(localized: "pets")) >0")
        XCTAssertEqual(SearchToken.traitIs(.portrait).displayLabel, String(localized: "Portrait"))
        XCTAssertEqual(SearchToken.traitIs(.group).displayLabel, String(localized: "Group photo"))
    }

    func testUnresolvableSimilarHandleLabelsAsExpired() {
        XCTAssertEqual(SearchToken.similar(handle: "s99999").displayLabel,
                       String(localized: "Similar (expired)"))
    }
}
