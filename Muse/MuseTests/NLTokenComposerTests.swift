//
//  NLTokenComposerTests.swift
//  MuseTests
//

import XCTest
@testable import Muse

final class NLTokenComposerTests: XCTestCase {
    func testFullFieldCombinationComposesParseableTokens() {
        let composed = NLTokenComposer.compose(year: 2025, month: 6, place: "Lisboa",
                                               camera: "x100v", minStars: 4, subject: "beach")
        let parsed = SearchQueryParser.parse(composed)
        XCTAssertEqual(parsed.tokens.count, 4, "year+place+camera+stars all become tokens")
        XCTAssertEqual(parsed.freeText, "beach")
    }

    func testYearOnlyComposesInDateToken() {
        let parsed = SearchQueryParser.parse(
            NLTokenComposer.compose(year: 2019, month: nil, place: nil,
                                    camera: nil, minStars: nil, subject: nil))
        XCTAssertTrue(parsed.tokens.contains {
            if case let .inDate(d) = $0 { return d.year == 2019 && d.month == nil }
            return false
        })
    }

    func testYearAndMonthComposeOneDateToken() {
        let parsed = SearchQueryParser.parse(
            NLTokenComposer.compose(year: 2021, month: 3, place: nil,
                                    camera: nil, minStars: nil, subject: nil))
        XCTAssertTrue(parsed.tokens.contains {
            if case let .inDate(d) = $0 { return d.year == 2021 && d.month == 3 }
            return false
        })
    }

    func testEmptyIntentProducesEmptyString() {
        let composed = NLTokenComposer.compose(year: nil, month: nil, place: nil,
                                               camera: nil, minStars: nil, subject: nil)
        XCTAssertTrue(composed.trimmingCharacters(in: .whitespaces).isEmpty)
    }

    func testSubjectOnlyStaysFreeText() {
        let parsed = SearchQueryParser.parse(
            NLTokenComposer.compose(year: nil, month: nil, place: nil,
                                    camera: nil, minStars: nil, subject: "dog on a beach"))
        XCTAssertTrue(parsed.tokens.isEmpty)
        XCTAssertEqual(parsed.freeText, "dog on a beach")
    }

    func testMinStarsComposesRatingToken() {
        let parsed = SearchQueryParser.parse(
            NLTokenComposer.compose(year: nil, month: nil, place: nil,
                                    camera: nil, minStars: 3, subject: nil))
        XCTAssertTrue(parsed.tokens.contains {
            if case let .rating(atLeast: n) = $0 { return n == 3 }
            return false
        })
    }

    func testMultiWordPlaceIsQuotedIntoOneToken() {
        let parsed = SearchQueryParser.parse(
            NLTokenComposer.compose(year: nil, month: nil, place: "New York",
                                    camera: nil, minStars: nil, subject: nil))
        XCTAssertEqual(parsed.tokens, [.near("New York")])
        XCTAssertTrue(parsed.freeText.isEmpty)
    }

    func testOutOfRangeValuesAreDropped() {
        let composed = NLTokenComposer.compose(year: nil, month: 99, place: "  ",
                                               camera: "", minStars: 9, subject: nil)
        XCTAssertTrue(composed.trimmingCharacters(in: .whitespaces).isEmpty)
    }

    func testComposedTextAlwaysRoundTripsThroughRealParser() {
        let combos: [(Int?, Int?, String?, String?, Int?, String?)] = [
            (2020, nil, nil, nil, nil, nil),
            (nil, nil, "Paris", nil, nil, nil),
            (nil, nil, nil, "iPhone", nil, nil),
            (nil, nil, nil, nil, 5, nil),
            (2021, 3, "Tokyo", "X100V", 4, "cherry blossoms"),
        ]
        for combo in combos {
            let composed = NLTokenComposer.compose(year: combo.0, month: combo.1, place: combo.2,
                                                    camera: combo.3, minStars: combo.4, subject: combo.5)
            _ = SearchQueryParser.parse(composed) // must not crash
        }
    }
}
