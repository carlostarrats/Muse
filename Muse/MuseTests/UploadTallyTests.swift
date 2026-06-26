//
//  UploadTallyTests.swift
//  MuseTests
//

import XCTest
@testable import Muse

final class UploadTallyTests: XCTestCase {
    func testEmptyIsNotComplete() {
        let t = UploadTally.tally(uploadedFlags: [])
        XCTAssertEqual(t, UploadTally(uploaded: 0, total: 0))
        XCTAssertFalse(t.isComplete)
        XCTAssertEqual(t.fraction, 0, accuracy: 0.0001)
    }

    func testPartial() {
        let t = UploadTally.tally(uploadedFlags: [true, false, true, false])
        XCTAssertEqual(t, UploadTally(uploaded: 2, total: 4))
        XCTAssertFalse(t.isComplete)
        XCTAssertEqual(t.fraction, 0.5, accuracy: 0.0001)
    }

    func testAllUploadedIsComplete() {
        let t = UploadTally.tally(uploadedFlags: [true, true])
        XCTAssertTrue(t.isComplete)
        XCTAssertEqual(t.fraction, 1.0, accuracy: 0.0001)
    }
}
