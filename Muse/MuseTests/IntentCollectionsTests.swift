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

    func testDuplicateFileIDsCountedOnce() {
        // The same file under several alive paths (copied into multiple folders)
        // appears multiple times in the JOINed input. The threshold must count
        // DISTINCT files, so a single duplicated screenshot must NOT qualify.
        let members = [
            (fileID: "a", bucket: "recipe"),
            (fileID: "a", bucket: "recipe"),
            (fileID: "a", bucket: "recipe"),
        ]
        XCTAssertNil(IntentCollections.qualifyingBuckets(members: members)["recipe"],
                     "one distinct file repeated 3× must not cross the threshold")
    }

    func testMixedDuplicatesCountDistinctOnly() {
        // 2 distinct files, one duplicated, below a threshold of 3.
        let members = [
            (fileID: "a", bucket: "code"),
            (fileID: "a", bucket: "code"),
            (fileID: "b", bucket: "code"),
        ]
        XCTAssertNil(IntentCollections.qualifyingBuckets(members: members)["code"])
        // With a duplicate AND enough distinct files, it qualifies with deduped IDs.
        let members2 = members + [(fileID: "c", bucket: "code"), (fileID: "b", bucket: "code")]
        XCTAssertEqual(IntentCollections.qualifyingBuckets(members: members2)["code"]?.sorted(),
                       ["a", "b", "c"])
    }
}
