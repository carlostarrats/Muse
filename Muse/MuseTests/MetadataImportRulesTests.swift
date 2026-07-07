//
//  MetadataImportRulesTests.swift
//  MuseTests
//
//  Pure conflict/normalize rules for the keywords & ratings import: keyword
//  trim/dedupe, XMP/IPTC rating clamp, and the "never clobber a Muse rating"
//  decision.
//

import XCTest
@testable import Muse

final class MetadataImportRulesTests: XCTestCase {

    // MARK: normalizeKeywords

    func testKeywordsTrimDropEmptyAndDedupeCaseInsensitively() {
        let out = MetadataImportRules.normalizeKeywords(
            ["  Travel ", "japan", "", "   ", "TRAVEL", "Japan", "tokyo"])
        // First spelling wins; order preserved.
        XCTAssertEqual(out, ["Travel", "japan", "tokyo"])
    }

    func testKeywordsEmptyInputIsEmptyOutput() {
        XCTAssertEqual(MetadataImportRules.normalizeKeywords([]), [])
    }

    // MARK: normalizeRating

    func testRatingPassesOneThroughFive() {
        XCTAssertEqual(MetadataImportRules.normalizeRating(1), 1)
        XCTAssertEqual(MetadataImportRules.normalizeRating(5), 5)
        XCTAssertEqual(MetadataImportRules.normalizeRating(3.0), 3)
    }

    func testRatingClampsAboveFive() {
        XCTAssertEqual(MetadataImportRules.normalizeRating(7), 5)
    }

    func testRatingZeroNegativeAndAbsentAreNil() {
        XCTAssertNil(MetadataImportRules.normalizeRating(0))    // unrated
        XCTAssertNil(MetadataImportRules.normalizeRating(-1))   // LR "rejected"
        XCTAssertNil(MetadataImportRules.normalizeRating(nil))
    }

    // MARK: ratingToApply

    func testImportedRatingFillsGapOnly() {
        XCTAssertEqual(MetadataImportRules.ratingToApply(imported: 4, existingHasRating: false), 4)
        XCTAssertNil(MetadataImportRules.ratingToApply(imported: 4, existingHasRating: true))
        XCTAssertNil(MetadataImportRules.ratingToApply(imported: nil, existingHasRating: false))
    }
}
