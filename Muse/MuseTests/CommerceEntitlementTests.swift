//
//  CommerceEntitlementTests.swift
//  MuseTests
//
//  CommerceCache is permissive-only: it can grant an entitlement StoreKit
//  hasn't confirmed yet (offline tolerance — a purchased user on a plane must
//  never be locked out while StoreKit warms up), and must never revoke one on
//  its own. Revocation happens only on a COMPLETED verified StoreKit read that
//  lacks the entitlement.
//
//  StoreKit's own Transaction/Product types can't be constructed in a plain
//  unit test (they need StoreKitTest/SKTestSession, which this suite has no
//  harness for), so this file covers the pure reconciliation logic that
//  CommerceStore wraps.
//

import XCTest
@testable import Muse

final class CommerceEntitlementTests: XCTestCase {

    func testCacheGrantsAreLocalOnly() {
        var cache = CommerceCache(unlocked: false, sharing: false)
        cache.grant(unlocked: true)
        XCTAssertTrue(cache.unlocked)
        XCTAssertFalse(cache.sharing)
    }

    func testGrantFalseIsNotARevoke() {
        var cache = CommerceCache(unlocked: true, sharing: false)
        cache.grant(unlocked: false)
        XCTAssertTrue(cache.unlocked, "grant is one-way; clearing goes through revoke")
    }

    func testCacheNeverSelfRevokes() {
        var cache = CommerceCache(unlocked: true, sharing: false)
        cache.merge(remoteGrants: Entitlements(unlocked: false, sharing: false))
        XCTAssertTrue(cache.unlocked,
                      "merge must be permissive-only (grant-or-keep, never auto-revoke)")
    }

    func testMergeAddsNewEntitlements() {
        var cache = CommerceCache(unlocked: false, sharing: false)
        cache.merge(remoteGrants: Entitlements(unlocked: true, sharing: true))
        XCTAssertEqual(cache.entitlements, Entitlements(unlocked: true, sharing: true))
    }

    func testExplicitRevokeClearsEntitlement() {
        var cache = CommerceCache(unlocked: true, sharing: true)
        cache.revoke(unlocked: true)
        XCTAssertFalse(cache.unlocked)
        XCTAssertTrue(cache.sharing, "revoke is per-axis")
    }

    func testRevokeFalseIsANoOp() {
        var cache = CommerceCache(unlocked: true, sharing: true)
        cache.revoke()
        XCTAssertEqual(cache.entitlements, Entitlements(unlocked: true, sharing: true))
    }

    /// The full reconciliation CommerceStore.refresh performs after a completed
    /// walk: merge grants, then revoke what the walk verifiably lacked.
    func testCompletedWalkReconcilesBothDirections() {
        var cache = CommerceCache(unlocked: true, sharing: false)
        let remote = Entitlements(unlocked: false, sharing: true)
        cache.merge(remoteGrants: remote)
        cache.revoke(unlocked: cache.unlocked && !remote.unlocked,
                     sharing: cache.sharing && !remote.sharing)
        XCTAssertEqual(cache.entitlements, Entitlements(unlocked: false, sharing: true),
                       "a refund clears the unlock; the new subscription is granted")
    }
}
