//
//  TrialGateTests.swift
//  MuseTests
//
//  Pure trial-state resolution. `enforced: false` (this spec's shipped default
//  — pricing is OPEN, Spec 09) must never expire, so the UI can read state
//  without anything being blocked.
//

import XCTest
@testable import Muse

final class TrialGateTests: XCTestCase {

    private let day: TimeInterval = 86_400
    private func policy(_ enforced: Bool) -> TrialPolicy {
        TrialPolicy(duration: 14 * 86_400, enforced: enforced)
    }

    func testEntitledShortCircuitsToUnlockedRegardlessOfClock() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertEqual(
            TrialGate.state(now: now, firstLaunch: now, entitled: true, policy: policy(true)),
            .unlocked)
    }

    func testUnenforcedNeverExpiresEvenPastDuration() {
        let firstLaunch = Date(timeIntervalSince1970: 0)
        let now = firstLaunch.addingTimeInterval(365 * day)
        let state = TrialGate.state(now: now, firstLaunch: firstLaunch,
                                    entitled: false, policy: policy(false))
        XCTAssertNotEqual(state, .expired, "unenforced policy must never expire")
        XCTAssertEqual(state, .trial(daysLeft: 0))
    }

    func testDefaultPolicyIsUnenforced() {
        XCTAssertFalse(TrialPolicy().enforced,
                       "the shipped default must block nothing until pricing is decided")
    }

    func testEnforcedExpiresPastDuration() {
        let firstLaunch = Date(timeIntervalSince1970: 0)
        let now = firstLaunch.addingTimeInterval(15 * day)
        XCTAssertEqual(
            TrialGate.state(now: now, firstLaunch: firstLaunch, entitled: false, policy: policy(true)),
            .expired)
    }

    func testEnforcedWithinDurationReportsDaysLeft() {
        let firstLaunch = Date(timeIntervalSince1970: 0)
        let now = firstLaunch.addingTimeInterval(3 * day)
        XCTAssertEqual(
            TrialGate.state(now: now, firstLaunch: firstLaunch, entitled: false, policy: policy(true)),
            .trial(daysLeft: 11))
    }

    func testMissingAnchorTreatedAsFirstLaunchNow() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertEqual(
            TrialGate.state(now: now, firstLaunch: nil, entitled: false, policy: policy(true)),
            .trial(daysLeft: 14))
    }

    func testClockRollbackDoesNotGrantExtraDays() {
        let firstLaunch = Date(timeIntervalSince1970: 100_000)
        let now = Date(timeIntervalSince1970: 0)
        XCTAssertEqual(
            TrialGate.state(now: now, firstLaunch: firstLaunch, entitled: false, policy: policy(true)),
            .trial(daysLeft: 14))
    }

    func testDayBoundaryRoundsDownRemainingDays() {
        let firstLaunch = Date(timeIntervalSince1970: 0)
        let now = firstLaunch.addingTimeInterval(13.5 * day)
        XCTAssertEqual(
            TrialGate.state(now: now, firstLaunch: firstLaunch, entitled: false, policy: policy(true)),
            .trial(daysLeft: 0))
    }

    /// Exactly at expiry is expired, not a zero-day trial — the boundary must
    /// not depend on sub-second timing.
    func testExactExpiryInstantIsExpired() {
        let firstLaunch = Date(timeIntervalSince1970: 0)
        let now = firstLaunch.addingTimeInterval(14 * day)
        XCTAssertEqual(
            TrialGate.state(now: now, firstLaunch: firstLaunch, entitled: false, policy: policy(true)),
            .expired)
    }
}
