//
//  SearchQueryParserTests.swift
//  MuseTests
//
//  Every token form, incl. quoted values, numeric ops/ranges, `in:` shapes,
//  all star spellings, unknown-key fallthrough to free text, and the
//  removing(tokenAt:) round-trip the chip bar's ✕ depends on.
//

import XCTest
@testable import Muse

final class SearchQueryParserTests: XCTestCase {

    func testCameraToken() {
        let p = SearchQueryParser.parse("camera:x100v")
        XCTAssertEqual(p.tokens, [.camera("x100v")])
        XCTAssertEqual(p.freeText, "")
    }

    func testQuotedValueCarriesSpaces() {
        XCTAssertEqual(SearchQueryParser.parse("near:\"New York\"").tokens, [.near("New York")])
    }

    func testNumericOperators() {
        XCTAssertEqual(SearchQueryParser.parse("iso:>1600").tokens,
                       [.iso(.init(op: .gt, value: 1600))])
        XCTAssertEqual(SearchQueryParser.parse("iso:>=1600").tokens,
                       [.iso(.init(op: .gte, value: 1600))])
        XCTAssertEqual(SearchQueryParser.parse("f:<2").tokens,
                       [.aperture(.init(op: .lt, value: 2))])
        XCTAssertEqual(SearchQueryParser.parse("f:<=2.8").tokens,
                       [.aperture(.init(op: .lte, value: 2.8))])
        XCTAssertEqual(SearchQueryParser.parse("iso:400").tokens,
                       [.iso(.init(op: .eq, value: 400))])
    }

    func testNumericRange() {
        guard case let .iso(filter)? = SearchQueryParser.parse("iso:100-400").tokens.first,
              case .range(100, 400) = filter.op else {
            return XCTFail("expected range 100-400")
        }
    }

    func testInDateShapes() {
        XCTAssertEqual(SearchQueryParser.parse("in:2019").tokens,
                       [.inDate(.init(year: 2019, month: nil, day: nil))])
        XCTAssertEqual(SearchQueryParser.parse("in:2019-06").tokens,
                       [.inDate(.init(year: 2019, month: 6, day: nil))])
        XCTAssertEqual(SearchQueryParser.parse("in:2019-06-21").tokens,
                       [.inDate(.init(year: 2019, month: 6, day: 21))])
    }

    func testInvalidDateStaysInFreeText() {
        XCTAssertTrue(SearchQueryParser.parse("in:2019-13").tokens.isEmpty)
        XCTAssertTrue(SearchQueryParser.parse("in:19").tokens.isEmpty)
    }

    func testStarForms() {
        XCTAssertEqual(SearchQueryParser.parse("star:4").tokens, [.rating(atLeast: 4)])
        XCTAssertEqual(SearchQueryParser.parse("star:=4").tokens, [.rating(atLeast: 4)])
        XCTAssertEqual(SearchQueryParser.parse("★★★★").tokens, [.rating(atLeast: 4)])
        XCTAssertEqual(SearchQueryParser.parse("★≥4").tokens, [.rating(atLeast: 4)])
        XCTAssertEqual(SearchQueryParser.parse("★>=4").tokens, [.rating(atLeast: 4)])
    }

    func testOutOfRangeStarStaysInFreeText() {
        XCTAssertTrue(SearchQueryParser.parse("star:9").tokens.isEmpty)
        XCTAssertTrue(SearchQueryParser.parse("star:0").tokens.isEmpty)
    }

    func testUnknownKeyStaysInFreeText() {
        let p = SearchQueryParser.parse("banana:split")
        XCTAssertEqual(p.tokens, [])
        XCTAssertEqual(p.freeText, "banana:split")
    }

    func testEmptyValueStaysInFreeText() {
        // Typing "iso:" mid-thought must not silently drop text.
        let p = SearchQueryParser.parse("iso: sunset")
        XCTAssertTrue(p.tokens.isEmpty)
        XCTAssertTrue(p.freeText.contains("iso:"))
        XCTAssertTrue(p.freeText.contains("sunset"))
    }

    func testKeysCaseInsensitive() {
        XCTAssertEqual(SearchQueryParser.parse("CAMERA:x100v").tokens, [.camera("x100v")])
    }

    func testMixedTokensAndFreeText() {
        let p = SearchQueryParser.parse("camera:x100v beach sunset")
        XCTAssertEqual(p.tokens, [.camera("x100v")])
        XCTAssertEqual(p.freeText, "beach sunset")
    }

    func testKindToken() {
        XCTAssertEqual(SearchQueryParser.parse("kind:raw").tokens, [.kind(.raw)])
        XCTAssertTrue(SearchQueryParser.parse("kind:banana").tokens.isEmpty)
    }

    func testColorToken() {
        XCTAssertEqual(SearchQueryParser.parse("color:red").tokens, [.color("red")])
        XCTAssertEqual(SearchQueryParser.parse("color:#a1b2c3").tokens, [.color("#a1b2c3")])
    }

    func testTextToken() {
        XCTAssertEqual(SearchQueryParser.parse("text:\"receipt\"").tokens, [.text("receipt")])
    }

    func testRemovingTokenAtRebuildsQuery() {
        let p = SearchQueryParser.parse("camera:x100v beach")
        let rebuilt = p.removing(tokenAt: 0)
        XCTAssertEqual(SearchQueryParser.parse(rebuilt).tokens, [])
        XCTAssertTrue(rebuilt.contains("beach"))
        XCTAssertFalse(rebuilt.contains("camera:"))
    }

    func testRemovingLastTokenWithNoFreeTextLeavesEmptyString() {
        let p = SearchQueryParser.parse("camera:x100v")
        XCTAssertEqual(p.removing(tokenAt: 0).trimmingCharacters(in: .whitespaces), "")
    }

    func testRemovingOneOfSeveralTokensKeepsTheOthers() {
        let p = SearchQueryParser.parse("camera:x100v iso:400 beach")
        let rebuilt = p.removing(tokenAt: 0)
        XCTAssertEqual(SearchQueryParser.parse(rebuilt).tokens, [.iso(.init(op: .eq, value: 400))])
        XCTAssertTrue(rebuilt.contains("beach"))
    }

    func testTokenlessQueryProducesNoTokens() {
        // The pin behind "a tokenless query is byte-identical to the
        // pre-token pipeline": nothing here may parse as a token.
        for query in ["sunset beach", "#a1b2c3", "12:30", "a:b", ""] {
            XCTAssertTrue(SearchQueryParser.parse(query).tokens.isEmpty, "\(query) parsed a token")
        }
    }
}
