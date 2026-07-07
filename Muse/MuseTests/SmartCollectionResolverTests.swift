//
//  SmartCollectionResolverTests.swift
//  MuseTests
//
//  Live rule resolution over a fixture DB: each rule type, AND/OR composition,
//  the "any location satisfies" grain for tag/rating, alive filtering, the
//  color rule reusing PaletteMatch — plus the CollectionStore smart CRUD and
//  smart-aware fetchAll that ride on top of the resolver.
//

import XCTest
import GRDB
@testable import Muse

final class SmartCollectionResolverTests: XCTestCase {

    private func makeQueue() throws -> DatabaseQueue {
        let q = try DatabaseQueue()
        try Database.makeMigrator().migrate(q)
        return q
    }

    /// Insert a file (+ one alive path) with optional metadata.
    private func insert(_ db: GRDB.Database, id: String, kind: String = "image",
                        path: String, size: Int64? = nil, created: Int64? = nil,
                        modified: Int64? = nil, palette: [String]? = nil) throws {
        let pj: String? = palette.flatMap { try? JSONEncoder().encode($0) }
            .flatMap { String(data: $0, encoding: .utf8) }
        try db.execute(sql: """
            INSERT INTO files (id, kind, size_bytes, created_at, modified_at, last_seen_at, palette)
            VALUES (?, ?, ?, ?, ?, 0, ?)
            """, arguments: [id, kind, size, created, modified, pj])
        try db.execute(sql: "INSERT INTO paths (id, file_id, absolute_path, is_alive) VALUES (?, ?, ?, 1)",
                       arguments: ["p_\(id)", id, path])
    }

    private func tag(_ db: GRDB.Database, fileID: String, dir: String, label: String) throws {
        try db.execute(sql: """
            INSERT INTO tags (id, file_id, parent_dir, label, source, model_version)
            VALUES (?, ?, ?, ?, 'manual', 'test')
            """, arguments: [UUID().uuidString, fileID, dir, label])
    }

    private func resolve(_ q: DatabaseQueue, _ set: SmartRuleSet) throws -> Set<String> {
        try q.read { db in try SmartCollectionResolver.memberIDs(set, db: db) }
    }

    // MARK: - Per-rule

    func testKindRule() throws {
        let q = try makeQueue()
        try q.write { db in
            try insert(db, id: "a", kind: "image", path: "/x/a.jpg")
            try insert(db, id: "b", kind: "pdf", path: "/x/b.pdf")
        }
        let ids = try resolve(q, SmartRuleSet(match: .all, rules: [.kind(.pdf)]))
        XCTAssertEqual(ids, ["b"])
    }

    func testSizeRule() throws {
        let q = try makeQueue()
        try q.write { db in
            try insert(db, id: "a", path: "/x/a.jpg", size: 1_000_000)
            try insert(db, id: "b", path: "/x/b.jpg", size: 9_000_000)
        }
        XCTAssertEqual(try resolve(q, SmartRuleSet(match: .all, rules: [.size(op: .atMost, bytes: 5_000_000)])), ["a"])
        XCTAssertEqual(try resolve(q, SmartRuleSet(match: .all, rules: [.size(op: .atLeast, bytes: 5_000_000)])), ["b"])
    }

    func testDateWithinAndBounds() throws {
        let q = try makeQueue()
        try q.write { db in
            try insert(db, id: "old", path: "/x/o.jpg", created: 1_000)
            try insert(db, id: "new", path: "/x/n.jpg", created: 2_000)
        }
        XCTAssertEqual(try resolve(q, SmartRuleSet(match: .all, rules: [.date(field: .created, op: .after(1_500))])), ["new"])
        XCTAssertEqual(try resolve(q, SmartRuleSet(match: .all, rules: [.date(field: .created, op: .before(1_500))])), ["old"])
    }

    func testFilenameMatchesBasenameNotFullPath() throws {
        let q = try makeQueue()
        try q.write { db in
            // "invoice" appears in a's DIRECTORY but b's BASENAME. Only b matches.
            try insert(db, id: "a", path: "/invoice/photo.jpg")
            try insert(db, id: "b", kind: "pdf", path: "/x/invoice-2024.pdf")
        }
        XCTAssertEqual(try resolve(q, SmartRuleSet(match: .all, rules: [.filename(contains: "invoice")])), ["b"])
    }

    func testTagHasAndHasNotAnyLocation() throws {
        let q = try makeQueue()
        try q.write { db in
            try insert(db, id: "a", path: "/x/a.jpg")
            try insert(db, id: "b", path: "/x/b.jpg")
            try tag(db, fileID: "a", dir: "/x", label: "beach")
        }
        XCTAssertEqual(try resolve(q, SmartRuleSet(match: .all, rules: [.tag(op: .has, label: "beach")])), ["a"])
        XCTAssertEqual(try resolve(q, SmartRuleSet(match: .all, rules: [.tag(op: .hasNot, label: "beach")])), ["b"])
    }

    func testRatingComparisons() throws {
        let q = try makeQueue()
        try q.write { db in
            try insert(db, id: "a", path: "/x/a.jpg")
            try insert(db, id: "b", path: "/x/b.jpg")
            try tag(db, fileID: "a", dir: "/x", label: StarRating.label(for: 3)!)
            try tag(db, fileID: "b", dir: "/x", label: StarRating.label(for: 5)!)
        }
        XCTAssertEqual(try resolve(q, SmartRuleSet(match: .all, rules: [.rating(op: .atLeast, stars: 4)])), ["b"])
        XCTAssertEqual(try resolve(q, SmartRuleSet(match: .all, rules: [.rating(op: .equal, stars: 3)])), ["a"])
        XCTAssertEqual(try resolve(q, SmartRuleSet(match: .all, rules: [.rating(op: .atMost, stars: 3)])), ["a"])
    }

    func testColorRuleUsesPaletteMatch() throws {
        let q = try makeQueue()
        try q.write { db in
            try insert(db, id: "blue", path: "/x/blue.jpg", palette: ["#3a7bd5", "#204080"])
            try insert(db, id: "red", path: "/x/red.jpg", palette: ["#d53a3a", "#802020"])
            try insert(db, id: "none", path: "/x/none.jpg")   // no palette
        }
        let ids = try resolve(q, SmartRuleSet(match: .all, rules: [.color(.hex("#3a7bd5"))]))
        XCTAssertEqual(ids, ["blue"])
    }

    // MARK: - Composition

    func testMatchAllIntersects() throws {
        let q = try makeQueue()
        try q.write { db in
            try insert(db, id: "a", kind: "image", path: "/x/a.jpg", size: 1_000)
            try insert(db, id: "b", kind: "image", path: "/x/b.jpg", size: 9_000)
        }
        let ids = try resolve(q, SmartRuleSet(match: .all, rules: [.kind(.image), .size(op: .atMost, bytes: 5_000)]))
        XCTAssertEqual(ids, ["a"])
    }

    func testMatchAnyUnions() throws {
        let q = try makeQueue()
        try q.write { db in
            try insert(db, id: "a", kind: "pdf", path: "/x/a.pdf", size: 9_000)
            try insert(db, id: "b", kind: "image", path: "/x/b.jpg", size: 1_000)
        }
        let ids = try resolve(q, SmartRuleSet(match: .any, rules: [.kind(.pdf), .size(op: .atMost, bytes: 5_000)]))
        XCTAssertEqual(ids, ["a", "b"])
    }

    func testEmptyRuleSetResolvesEmpty() throws {
        let q = try makeQueue()
        try q.write { db in try insert(db, id: "a", path: "/x/a.jpg") }
        XCTAssertEqual(try resolve(q, SmartRuleSet(match: .all, rules: [])), [])
    }

    func testAlivePathsExcludesDeadRows() throws {
        let q = try makeQueue()
        try q.write { db in
            try insert(db, id: "a", path: "/x/a.jpg")
            try db.execute(sql: "UPDATE paths SET is_alive = 0 WHERE file_id = 'a'")
        }
        let paths = try q.read { db in
            try SmartCollectionResolver.alivePaths(SmartRuleSet(match: .all, rules: [.kind(.image)]), db: db)
        }
        XCTAssertTrue(paths.isEmpty, "a file with no alive path contributes no tile")
    }

    // MARK: - CollectionStore smart CRUD (Task 4)

    func testCreateSmartAndResolveAlivePaths() async throws {
        let q = try makeQueue()
        try await q.write { db in
            try self.insert(db, id: "a", kind: "pdf", path: "/x/a.pdf")
            try self.insert(db, id: "b", kind: "image", path: "/x/b.jpg")
        }
        let set = SmartRuleSet(match: .all, rules: [.kind(.pdf)])
        let id = try await CollectionStore.createSmart(queue: q, name: "PDFs", ruleSet: set)

        let back = try await CollectionStore.smartRuleSet(queue: q, id: id)
        XCTAssertEqual(back, set)

        let paths = try await CollectionStore.alivePathsResolving(queue: q, collectionID: id)
        XCTAssertEqual(paths, ["/x/a.pdf"])
    }

    func testFetchAllCountsSmartCollectionLive() async throws {
        let q = try makeQueue()
        try await q.write { db in
            try self.insert(db, id: "a", kind: "pdf", path: "/root/a.pdf")
            try self.insert(db, id: "b", kind: "pdf", path: "/root/b.pdf")
            try self.insert(db, id: "c", kind: "image", path: "/root/c.jpg")
        }
        _ = try await CollectionStore.createSmart(queue: q, name: "PDFs",
                                                  ruleSet: SmartRuleSet(match: .all, rules: [.kind(.pdf)]))
        let all = try await CollectionStore.fetchAll(queue: q, rootPaths: ["/root"])
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all[0].aliveCount, 2, "two PDFs match, resolved live")
    }

    func testMakeSmartDropsMembers() async throws {
        let q = try makeQueue()
        try await q.write { db in
            try self.insert(db, id: "a", kind: "pdf", path: "/root/a.pdf")
        }
        let cid = try await CollectionStore.createManual(queue: q)  // empty manual
        try await CollectionStore.addFile(queue: q, fileID: "a", collectionID: cid)
        try await CollectionStore.makeSmart(queue: q, id: cid,
                                            ruleSet: SmartRuleSet(match: .all, rules: [.kind(.image)]))
        let members = try await q.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM collection_members WHERE collection_id = ?",
                             arguments: [cid]) ?? -1
        }
        XCTAssertEqual(members, 0, "hand-picked members are removed on conversion")
        let stillSmart = try await CollectionStore.smartRuleSet(queue: q, id: cid)
        XCTAssertNotNil(stillSmart)
    }

    // MARK: - Recluster protection (Task 6)

    func testSmartCollectionIsProtectedFromStaleSweep() async throws {
        let q = try makeQueue()
        try await q.write { db in try self.insert(db, id: "a", kind: "pdf", path: "/root/a.pdf") }
        let id = try await CollectionStore.createSmart(queue: q, name: "PDFs",
                                                       ruleSet: SmartRuleSet(match: .all, rules: [.kind(.pdf)]))
        let protectedIDs = try await CollectionStore.protectedCollectionIDs(queue: q)
        XCTAssertTrue(protectedIDs.contains(id), "smart collections (model_version=manual) survive reclustering")
    }
}
