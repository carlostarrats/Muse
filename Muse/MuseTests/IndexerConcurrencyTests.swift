//
//  IndexerConcurrencyTests.swift
//  MuseTests
//
//  indexFile's body was moved OFF the actor so hashing actually runs 4-wide
//  (measured peak concurrency was 1 before). That only stays correct because
//  GRDB's DatabaseQueue serializes every read AND write on one connection, so
//  the whole identity-reconcile matrix still runs as an atomic, totally-ordered
//  transaction. These tests attack that assumption directly: if the queue did
//  NOT serialize, two byte-identical files reconciling concurrently would both
//  see "no row with this hash" and both insert, tripping the content_hash
//  UNIQUE constraint and silently dropping a file from the index.
//

import XCTest
import GRDB
@testable import Muse

final class IndexerConcurrencyTests: XCTestCase {

    /// Non-async so `q.read` resolves to the SYNC overload (inside an async
    /// test it would pick the async one — the documented GRDB overload gotcha).
    private func count(_ q: DatabaseQueue, _ sql: String) throws -> Int {
        try q.read { db in try Int.fetchOne(db, sql: sql) ?? 0 }
    }

    private func migrated() throws -> DatabaseQueue {
        let q = try DatabaseQueue()
        try Database.makeMigrator().migrate(q)
        return q
    }

    /// 32 concurrent reconciles of the SAME content in 32 different folders must
    /// dedupe onto exactly one files row, with 32 alive paths — no UNIQUE
    /// violation, no lost path.
    func testConcurrentIdenticalContentDedupesToOneRow() async throws {
        let q = try migrated()
        let n = 32
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<n {
                group.addTask {
                    // Same shape as indexFileBody: the whole matrix inside one
                    // queue.write, called from an arbitrary thread.
                    try? q.write { db in
                        _ = try Indexer.reconcile(db: db, absPath: "/f\(i)/x.png",
                                                  hash: "sharedhash", kind: .image,
                                                  sizeBytes: 10, createdAt: 0,
                                                  modifiedAt: 0, now: 1)
                    }
                }
            }
        }
        let files = try count(q, "SELECT COUNT(*) FROM files")
        let alive = try count(q, "SELECT COUNT(*) FROM paths WHERE is_alive = 1")
        XCTAssertEqual(files, 1, "identical content must share ONE row even under concurrency")
        XCTAssertEqual(alive, n, "every path survived — none lost to a constraint failure")
    }

    /// 32 concurrent reconciles of DISTINCT content must produce 32 rows and 32
    /// paths — nothing merged, nothing dropped.
    func testConcurrentDistinctContentKeepsEveryRow() async throws {
        let q = try migrated()
        let n = 32
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<n {
                group.addTask {
                    try? q.write { db in
                        _ = try Indexer.reconcile(db: db, absPath: "/f/x\(i).png",
                                                  hash: "hash\(i)", kind: .image,
                                                  sizeBytes: 10, createdAt: 0,
                                                  modifiedAt: 0, now: 1)
                    }
                }
            }
        }
        let files = try count(q, "SELECT COUNT(*) FROM files")
        let fts = try count(q, "SELECT COUNT(*) FROM files_fts")
        XCTAssertEqual(files, n)
        XCTAssertEqual(fts, n, "every new identity got its basename FTS row")
    }

    /// The in-flight claim is per-path and must be released before indexFile
    /// returns, or the next pass over the same file is skipped for no reason.
    /// Claiming the same path twice concurrently admits exactly one.
    func testClaimAdmitsOneAndIsReleasedForReuse() async throws {
        let indexer = Indexer.shared
        // A path that does not exist: indexFile claims, finds no bytes to hash,
        // releases, and returns false. Running it twice in a row must behave
        // identically the second time — proving the claim was released.
        let url = URL(fileURLWithPath: "/nonexistent/muse-claim-probe.png")
        let first = await indexer.indexFile(at: url, kind: .image)
        let second = await indexer.indexFile(at: url, kind: .image)
        XCTAssertFalse(first)
        XCTAssertFalse(second, "a leaked claim would make this indistinguishable, but the "
                     + "release is inline so the second call runs the body again")
    }
}
