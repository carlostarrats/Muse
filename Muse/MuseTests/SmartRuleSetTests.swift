//
//  SmartRuleSetTests.swift
//  MuseTests
//
//  Pure model: JSON round-trip for every rule type, validity boundaries,
//  and the KindGroup → files.kind mapping.
//

import XCTest
@testable import Muse

final class SmartRuleSetTests: XCTestCase {

    func testEveryRuleTypeRoundTrips() {
        let set = SmartRuleSet(match: .all, rules: [
            .rating(op: .atLeast, stars: 4),
            .color(.hex("#3a7bd5")),
            .color(.name("red")),
            .tag(op: .has, label: "beach"),
            .tag(op: .hasNot, label: "draft"),
            .kind(.image),
            .date(field: .modified, op: .withinDays(30)),
            .date(field: .created, op: .before(1_700_000_000)),
            .filename(contains: "invoice"),
            .size(op: .atMost, bytes: 5_000_000),
        ])
        guard let json = set.encodedJSON(), let back = SmartRuleSet.decode(json) else {
            return XCTFail("round-trip failed")
        }
        XCTAssertEqual(set, back)
    }

    func testLegacyEmptyRuleSetDecodes() {
        let back = SmartRuleSet.decode("{\"match\":\"any\",\"rules\":[]}")
        XCTAssertEqual(back, SmartRuleSet(match: .any, rules: []))
    }

    func testInvalidJSONReturnsNil() {
        XCTAssertNil(SmartRuleSet.decode("not json"))
    }

    func testRatingStarsBounds() {
        XCTAssertFalse(SmartRule.rating(op: .atLeast, stars: 0).isValid)
        XCTAssertTrue(SmartRule.rating(op: .atLeast, stars: 1).isValid)
        XCTAssertTrue(SmartRule.rating(op: .equal, stars: 5).isValid)
        XCTAssertFalse(SmartRule.rating(op: .atMost, stars: 6).isValid)
    }

    func testTagLabelNonEmpty() {
        XCTAssertFalse(SmartRule.tag(op: .has, label: "  ").isValid)
        XCTAssertTrue(SmartRule.tag(op: .has, label: "beach").isValid)
    }

    func testFilenameNonEmpty() {
        XCTAssertFalse(SmartRule.filename(contains: "").isValid)
        XCTAssertTrue(SmartRule.filename(contains: "a").isValid)
    }

    func testSizePositive() {
        XCTAssertFalse(SmartRule.size(op: .atMost, bytes: 0).isValid)
        XCTAssertTrue(SmartRule.size(op: .atMost, bytes: 1).isValid)
    }

    func testColorHexMustParse() {
        XCTAssertTrue(SmartRule.color(.hex("#3a7bd5")).isValid)
        XCTAssertTrue(SmartRule.color(.hex("3a7bd5")).isValid)
        XCTAssertFalse(SmartRule.color(.hex("nope")).isValid)
        XCTAssertTrue(SmartRule.color(.name("red")).isValid)   // any non-empty name; resolution deferred
        XCTAssertFalse(SmartRule.color(.name("")).isValid)
    }

    func testSetIsValidRequiresAtLeastOneValidRuleAndAllValid() {
        XCTAssertFalse(SmartRuleSet(match: .all, rules: []).isValid, "no rules = nothing to match")
        XCTAssertFalse(SmartRuleSet(match: .all, rules: [.tag(op: .has, label: "")]).isValid)
        XCTAssertTrue(SmartRuleSet(match: .all, rules: [.tag(op: .has, label: "x")]).isValid)
    }

    func testKindGroupMapping() {
        XCTAssertEqual(SmartRule.KindGroup.image.kinds, ["image", "psd", "svg"])
        XCTAssertEqual(SmartRule.KindGroup.raw.kinds, ["raw"])
        XCTAssertEqual(SmartRule.KindGroup.document.kinds, ["text", "markdown", "code", "office"])
    }
}
