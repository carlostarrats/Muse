import XCTest
@testable import Muse

final class IntentCollectionsTests: XCTestCase {
    func testBucketAtThresholdQualifies() {
        let members = [
            (fileID: "a", bucket: "recipe"),
            (fileID: "b", bucket: "recipe"),
            (fileID: "c", bucket: "recipe"),
        ]
        let q = IntentCollections.qualifyingBuckets(members: members)
        XCTAssertEqual(q["recipe"]?.sorted(), ["a", "b", "c"])
    }

    func testBucketBelowThresholdDropped() {
        let members = [
            (fileID: "a", bucket: "shopping"),
            (fileID: "b", bucket: "shopping"),
        ]
        XCTAssertNil(IntentCollections.qualifyingBuckets(members: members)["shopping"])
    }

    func testMultipleBucketsSeparated() {
        let members = [
            (fileID: "a", bucket: "recipe"), (fileID: "b", bucket: "recipe"),
            (fileID: "c", bucket: "recipe"), (fileID: "d", bucket: "code"),
            (fileID: "e", bucket: "code"),   (fileID: "f", bucket: "code"),
        ]
        let q = IntentCollections.qualifyingBuckets(members: members)
        XCTAssertEqual(q.count, 2)
        XCTAssertEqual(q["recipe"]?.count, 3)
        XCTAssertEqual(q["code"]?.count, 3)
    }

    func testCustomThreshold() {
        let members = [(fileID: "a", bucket: "places"), (fileID: "b", bucket: "places")]
        XCTAssertEqual(IntentCollections.qualifyingBuckets(members: members, threshold: 2)["places"]?.count, 2)
    }
}
