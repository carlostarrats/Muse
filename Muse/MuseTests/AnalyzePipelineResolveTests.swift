//
//  AnalyzePipelineResolveTests.swift
//  MuseTests
//
//  P6: the batched path→fileID resolution must preserve dedup-by-file-id and
//  first-seen URL order (duplicate content analyzed once).
//

import XCTest
import GRDB
@testable import Muse

final class AnalyzePipelineResolveTests: XCTestCase {

    private func freshQueue() throws -> DatabaseQueue {
        let q = try DatabaseQueue()
        try Database.makeMigrator().migrate(q)
        return q
    }

    func testAliveFileIDsResolvesAndSkipsDeadOrOrphan() async throws {
        let q = try freshQueue()
        try await q.write { db in
            try db.execute(sql: "INSERT INTO files (id, content_hash, kind, last_seen_at) VALUES ('f1','h1','image',0)")
            try db.execute(sql: "INSERT INTO paths (id, file_id, absolute_path, is_alive) VALUES ('p1','f1','/a/x.png',1)")
            try db.execute(sql: "INSERT INTO paths (id, file_id, absolute_path, is_alive) VALUES ('p2','f1','/a/dead.png',0)")
        }
        let map = await AnalyzePipeline.aliveFileIDs(
            queue: q, absPaths: ["/a/x.png", "/a/dead.png", "/a/gone.png"])
        XCTAssertEqual(map, ["/a/x.png": "f1"])
    }

    func testDedupPreservesFirstSeenOrder() throws {
        // Two paths resolve to the SAME file_id; the pair must keep the FIRST url,
        // and order of distinct ids must follow first appearance.
        let idByPath = ["/a/dup1.png": "fA", "/a/dup2.png": "fA", "/a/other.png": "fB"]
        let urls = ["/a/dup1.png", "/a/dup2.png", "/a/other.png"].map { URL(fileURLWithPath: $0) }
        let pairs = AnalyzePipeline.dedupByFileID(urls: urls, idByPath: idByPath)
        XCTAssertEqual(pairs.map { $0.id }, ["fA", "fB"])
        XCTAssertEqual(pairs.map { $0.url.path }, ["/a/dup1.png", "/a/other.png"])
    }
}
