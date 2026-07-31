//
//  SearchTokenFacesTests.swift
//  MuseTests
//

import XCTest
@testable import Muse

final class SearchTokenFacesTests: XCTestCase {
    func testFacesGreaterThanParses() {
        let parsed = SearchQueryParser.parse("faces:>2")
        XCTAssertEqual(parsed.tokens, [.faces(.init(op: .gt, value: 2))])
        XCTAssertTrue(parsed.freeText.isEmpty)
    }

    func testFacesExactZeroParses() {
        let parsed = SearchQueryParser.parse("faces:0")
        XCTAssertEqual(parsed.tokens, [.faces(.init(op: .eq, value: 0))])
    }

    func testPetsGreaterThanZeroParses() {
        let parsed = SearchQueryParser.parse("pets:>0")
        XCTAssertEqual(parsed.tokens, [.pets(.init(op: .gt, value: 0))])
    }

    func testIsPortraitParses() {
        XCTAssertEqual(SearchQueryParser.parse("is:portrait").tokens, [.traitIs(.portrait)])
    }

    func testIsGroupParses() {
        XCTAssertEqual(SearchQueryParser.parse("is:group").tokens, [.traitIs(.group)])
    }

    func testIsWithUnknownValueStaysFreeText() {
        let parsed = SearchQueryParser.parse("is: that photo of us")
        XCTAssertTrue(parsed.tokens.isEmpty, "an unrecognized is: value must not silently eat the text")
        XCTAssertTrue(parsed.freeText.contains("that photo of us"))
    }

    func testRemovingFacesTokenRoundTrips() {
        let parsed = SearchQueryParser.parse("faces:>2 beach")
        let rebuilt = parsed.removing(tokenAt: 0)
        XCTAssertEqual(SearchQueryParser.parse(rebuilt).tokens, [])
        XCTAssertTrue(rebuilt.contains("beach"))
    }

    func testSimilarHandleShapeParses() {
        XCTAssertEqual(SearchQueryParser.parse("similar:s1").tokens, [.similar(handle: "s1")])
    }

    func testOffShapeSimilarStaysFreeText() {
        let parsed = SearchQueryParser.parse("similar:notanumber")
        XCTAssertTrue(parsed.tokens.isEmpty)
        XCTAssertTrue(parsed.freeText.contains("similar:notanumber"))
    }

    func testBareSimilarKeyIsNotAToken() {
        // "similar:s" alone is a one-character value with no digits — off-shape.
        XCTAssertTrue(SearchQueryParser.parse("similar:s").tokens.isEmpty)
    }
}
