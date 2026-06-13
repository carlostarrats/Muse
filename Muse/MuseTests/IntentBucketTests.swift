import XCTest
@testable import Muse

final class IntentBucketTests: XCTestCase {
    func testAllTenBucketsExist() {
        XCTAssertEqual(IntentBucket.allCases.count, 10)
    }

    func testStableCollectionID() {
        XCTAssertEqual(IntentBucket.recipe.collectionID, "intent:recipe")
        XCTAssertEqual(IntentBucket.receipt.collectionID, "intent:receipt")
    }

    func testDisplayNames() {
        XCTAssertEqual(IntentBucket.recipe.displayName, "Recipes")
        XCTAssertEqual(IntentBucket.code.displayName, "Code")
        XCTAssertEqual(IntentBucket.places.displayName, "Places")
    }

    func testFromValidKey() {
        XCTAssertEqual(IntentBucket.from("recipe"), .recipe)
    }

    func testFromIsCaseAndPunctuationTolerant() {
        XCTAssertEqual(IntentBucket.from("  Recipe."), .recipe)
        XCTAssertEqual(IntentBucket.from("CODE"), .code)
    }

    func testFromNoneReturnsNil() {
        XCTAssertNil(IntentBucket.from("none"))
        XCTAssertNil(IntentBucket.from(""))
        XCTAssertNil(IntentBucket.from("banana"))
    }
}
