//
//  IndexerDecisionTests.swift
//  MuseTests
//
//  Exhaustive truth-table coverage for the folder-open discovery decision.
//  Pure function, no database — one assertion per branch of decideIndexAction.
//

import XCTest
@testable import Muse

final class IndexerDecisionTests: XCTestCase {

    private func stored(hash: String? = "h1", size: Int64? = 100, mtime: Int64? = 50,
                        lastSeen: Int64 = 0) -> Indexer.StoredIdentity {
        Indexer.StoredIdentity(fileID: "f1", contentHash: hash, size: size,
                               mtime: mtime, lastSeen: lastSeen)
    }

    // Row 1: dataless wins over everything, incl. force.
    func testDatalessSkipsEvenUnderForce() {
        XCTAssertEqual(Indexer.decideIndexAction(isDataless: true, force: false,
            isUbiquitous: false, stored: nil, onDiskSize: 1, onDiskMtime: 1), .skipDataless)
        XCTAssertEqual(Indexer.decideIndexAction(isDataless: true, force: true,
            isUbiquitous: true, stored: stored(), onDiskSize: 100, onDiskMtime: 50), .skipDataless)
    }

    // Row 2: force hashes regardless of stored metadata.
    func testForceNeedsHashing() {
        XCTAssertEqual(Indexer.decideIndexAction(isDataless: false, force: true,
            isUbiquitous: false, stored: stored(), onDiskSize: 100, onDiskMtime: 50), .needsHashing)
    }

    // Row 3: no stored identity → hash.
    func testUnknownPathNeedsHashing() {
        XCTAssertEqual(Indexer.decideIndexAction(isDataless: false, force: false,
            isUbiquitous: false, stored: nil, onDiskSize: 100, onDiskMtime: 50), .needsHashing)
    }

    // Row 4: NULL content_hash → hash, even for iCloud (checked before the trust branch).
    func testNullHashNeedsHashingIncludingICloud() {
        XCTAssertEqual(Indexer.decideIndexAction(isDataless: false, force: false,
            isUbiquitous: false, stored: stored(hash: nil), onDiskSize: 100, onDiskMtime: 50), .needsHashing)
        XCTAssertEqual(Indexer.decideIndexAction(isDataless: false, force: false,
            isUbiquitous: true, stored: stored(hash: nil), onDiskSize: 100, onDiskMtime: 50), .needsHashing)
    }

    // Row 5: iCloud trusts the stored hash and IGNORES size/mtime (deliberately mismatched).
    func testICloudTrustsHashIgnoresMetadata() {
        XCTAssertEqual(Indexer.decideIndexAction(isDataless: false, force: false,
            isUbiquitous: true, stored: stored(size: 100, mtime: 50),
            onDiskSize: 999, onDiskMtime: 999), .unchanged)
    }

    // Row 6: local, exact size + mtime match → unchanged.
    func testLocalMatchUnchanged() {
        XCTAssertEqual(Indexer.decideIndexAction(isDataless: false, force: false,
            isUbiquitous: false, stored: stored(size: 100, mtime: 50),
            onDiskSize: 100, onDiskMtime: 50), .unchanged)
    }

    // Rows 7–8: local, size OR mtime mismatch → hash.
    func testLocalSizeMismatchNeedsHashing() {
        XCTAssertEqual(Indexer.decideIndexAction(isDataless: false, force: false,
            isUbiquitous: false, stored: stored(size: 100, mtime: 50),
            onDiskSize: 101, onDiskMtime: 50), .needsHashing)
    }
    func testLocalMtimeMismatchNeedsHashing() {
        XCTAssertEqual(Indexer.decideIndexAction(isDataless: false, force: false,
            isUbiquitous: false, stored: stored(size: 100, mtime: 50),
            onDiskSize: 100, onDiskMtime: 51), .needsHashing)
    }

    // Nil-optional equality quirk: nil == nil → unchanged (preserves current behavior).
    func testLocalNilSizeEqualityUnchanged() {
        XCTAssertEqual(Indexer.decideIndexAction(isDataless: false, force: false,
            isUbiquitous: false, stored: stored(size: nil, mtime: 50),
            onDiskSize: nil, onDiskMtime: 50), .unchanged)
    }
}
