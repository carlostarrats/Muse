import XCTest
@testable import Muse

final class CloudLayoutTests: XCTestCase {
    func testMeasuredPosesAreThe25FromThePrototype() {
        XCTAssertEqual(CloudPose.measured.count, 25)
        // Spot-check first and last against cloud-pose-prototype.html POSES
        let first = CloudPose.measured[0]
        XCTAssertEqual(first.w, 194.0, accuracy: 0.01)
        XCTAssertEqual(first.h, 219.4, accuracy: 0.01)
        XCTAssertEqual(first.cx, 337.5, accuracy: 0.01)
        XCTAssertEqual(first.cy, 199.4, accuracy: 0.01)
        XCTAssertEqual(first.rx, -33.0, accuracy: 0.01)
        XCTAssertEqual(first.ry, -30.4, accuracy: 0.01)
        XCTAssertEqual(first.rz, 47.5, accuracy: 0.01)
        let last = CloudPose.measured[24]
        XCTAssertEqual(last.w, 514.8, accuracy: 0.01)
        XCTAssertEqual(last.cy, 1006.4, accuracy: 0.01)
    }

    func testSmallCountsUseMeasuredPrefix() {
        let poses = CloudLayout.poses(count: 7, seed: 99)
        XCTAssertEqual(poses.count, 7)
        XCTAssertEqual(poses[3].cx, CloudPose.measured[3].cx, accuracy: 0.001)
    }

    func testLargeCountsAreGeneratedWithinSpecStatistics() {
        let poses = CloudLayout.poses(count: 60, seed: 5)
        XCTAssertEqual(poses.count, 60)
        for p in poses {
            XCTAssertTrue(abs(p.rx) >= 10 && abs(p.rx) <= 33, "rx \(p.rx)")
            XCTAssertTrue(abs(p.ry) >= 5 && abs(p.ry) <= 30, "ry \(p.ry)")
            XCTAssertTrue(abs(p.rz) >= 5 && abs(p.rz) <= 47, "rz \(p.rz)")
            XCTAssertTrue(p.w >= CloudPose.refW * 0.04 && p.w <= CloudPose.refW * 0.10, "w \(p.w)")
            // Cards stay on the stage
            XCTAssertTrue(p.cx > 0 && p.cx < CloudPose.refW)
            XCTAssertTrue(p.cy > 0 && p.cy < CloudPose.refH)
            XCTAssertTrue(p.w.isFinite && p.h.isFinite && p.cx.isFinite && p.cy.isFinite)
        }
    }

    func testGenerationIsDeterministicPerSeed() {
        let a = CloudLayout.poses(count: 40, seed: 11)
        let b = CloudLayout.poses(count: 40, seed: 11)
        let c = CloudLayout.poses(count: 40, seed: 12)
        XCTAssertEqual(a.map(\.cx), b.map(\.cx))
        XCTAssertNotEqual(a.map(\.cx), c.map(\.cx))
    }

    func testZeroCount() {
        XCTAssertTrue(CloudLayout.poses(count: 0, seed: 1).isEmpty)
    }
}
