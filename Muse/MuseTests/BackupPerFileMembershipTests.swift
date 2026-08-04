import XCTest
import GRDB
@testable import Muse

/// Collection membership in a backup archive.
///
/// It used to be keyed on `content_hash`, which cannot express "this copy is in
/// the collection and its byte-identical twin is not" — a real case since
/// per-file identity. Membership is now ALSO carried per occurrence path, with
/// the hash-keyed fields left in place so older archives still restore.
final class BackupPerFileMembershipTests: XCTestCase {

    private func migrated() throws -> DatabaseQueue {
        let q = try DatabaseQueue()
        try Database.makeMigrator().migrate(q)
        return q
    }

    /// Two byte-identical files, only ONE of them in the collection.
    private func seedSplitMembership(_ q: DatabaseQueue) throws {
        try q.write { db in
            try db.execute(sql: """
                INSERT INTO files (id, content_hash, kind, last_seen_at, analyzed_hash)
                VALUES ('f1', 'h1', 'image', 0, 'h1'), ('f2', 'h1', 'image', 0, 'h1')
                """)
            try db.execute(sql: """
                INSERT INTO paths (id, file_id, absolute_path, is_alive)
                VALUES ('p1', 'f1', '/lib/one.jpg', 1), ('p2', 'f2', '/lib/two.jpg', 1)
                """)
            try db.execute(sql: """
                INSERT INTO collections (id, name, is_hidden, model_version,
                                         created_at, updated_at, sort_order)
                VALUES ('C', 'Faves', 0, 'manual', 0, 0, 0)
                """)
            try db.execute(sql: """
                INSERT INTO collection_members (collection_id, file_id, added_by)
                VALUES ('C', 'f1', 'manual')
                """)
            try db.execute(sql: """
                INSERT INTO collection_exclusions (collection_id, file_id)
                VALUES ('C', 'f2')
                """)
        }
    }

    func testBuilderRecordsMembershipPerOccurrencePath() async throws {
        let q = try migrated()
        try seedSplitMembership(q)
        let archive = try await BackupBuilder.build(queue: q, roots: [BackupRoot(path: "/lib", display_name: "lib")],
                                                   createdAt: 0, appVersion: "test")
        let c = try XCTUnwrap(archive.collections.first { $0.id == "C" })

        let memberPaths = try XCTUnwrap(c.member_paths)
        XCTAssertEqual(memberPaths.map(\.original_path), ["/lib/one.jpg"])
        XCTAssertEqual(memberPaths.map(\.added_by), ["manual"])
        XCTAssertEqual(c.excluded_paths, ["/lib/two.jpg"])

        // The hash-keyed fields are still written, for older builds reading a
        // newer archive.
        XCTAssertEqual(c.members.map(\.content_hash), ["h1"])
    }

    /// The materializer prefers the per-path fields when the archive has them.
    func testMaterializerPrefersPerPathMembership() {
        let c = BackupCollection(
            id: "C", name: "Faves", sort_order: 0, model_version: "manual",
            is_hidden: 0, cover_hash: nil,
            // The hash-keyed view says BOTH copies are members — that is the
            // lossy encoding this change exists to replace.
            members: [BackupMember(content_hash: "h1", added_by: "manual")],
            excluded_hashes: [],
            member_paths: [BackupPathMember(original_path: "/lib/one.jpg", added_by: "manual")],
            excluded_paths: ["/lib/two.jpg"])

        let out = CollectionMaterializer.materialize(
            [c],
            fileIDForHash: ["h1": "f1"],
            fileIDForPath: ["/lib/one.jpg": "f1", "/lib/two.jpg": "f2"])

        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0].memberFileIDs.map(\.fileID), ["f1"],
                       "only the copy that was actually a member")
        XCTAssertEqual(out[0].excludedFileIDs, ["f2"])
    }

    /// An archive written before this change has no per-path fields, and must
    /// still restore under the old hash semantics.
    func testLegacyArchiveStillRestoresByHash() {
        let c = BackupCollection(
            id: "C", name: "Faves", sort_order: 0, model_version: "manual",
            is_hidden: 0, cover_hash: nil,
            members: [BackupMember(content_hash: "h1", added_by: "manual")],
            excluded_hashes: [])

        let out = CollectionMaterializer.materialize(
            [c], fileIDForHash: ["h1": "f1"], fileIDForPath: [:])

        XCTAssertEqual(out[0].memberFileIDs.map(\.fileID), ["f1"])
    }

    /// A member whose file did not come back must be dropped, exactly as the
    /// hash path drops unreconnected members.
    func testUnreconnectedPathMembersAreDropped() {
        let c = BackupCollection(
            id: "C", name: "Faves", sort_order: 0, model_version: "manual",
            is_hidden: 0, cover_hash: nil,
            members: [], excluded_hashes: [],
            member_paths: [BackupPathMember(original_path: "/gone.jpg", added_by: "manual")],
            excluded_paths: [])

        let out = CollectionMaterializer.materialize(
            [c], fileIDForHash: [:], fileIDForPath: [:])

        // Manual collections survive empty; the point is the ghost is not a member.
        XCTAssertEqual(out.count, 1)
        XCTAssertTrue(out[0].memberFileIDs.isEmpty)
    }

    /// End to end: build an archive from a split-membership library and
    /// materialize it back, with the files at NEW paths (a real restore moves
    /// them). The per-path map is keyed on where they landed.
    func testRoundTripKeepsTheTwoCopiesApart() async throws {
        let q = try migrated()
        try seedSplitMembership(q)
        let archive = try await BackupBuilder.build(queue: q, roots: [BackupRoot(path: "/lib", display_name: "lib")],
                                                   createdAt: 0, appVersion: "test")

        let out = CollectionMaterializer.materialize(
            archive.collections,
            fileIDForHash: ["h1": "new1"],
            fileIDForPath: ["/lib/one.jpg": "new1", "/lib/two.jpg": "new2"])

        let c = try XCTUnwrap(out.first { $0.id == "C" })
        XCTAssertEqual(c.memberFileIDs.map(\.fileID), ["new1"])
        XCTAssertEqual(c.excludedFileIDs, ["new2"])
    }
}
