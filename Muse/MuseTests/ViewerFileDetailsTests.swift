import XCTest
import GRDB
@testable import Muse

final class ViewerFileDetailsTests: XCTestCase {
    func testLoadByPath() async throws {
        let q = try DatabaseQueue()
        try Database.makeMigrator().migrate(q)
        try await q.write { db in
            try db.execute(sql: """
                INSERT INTO files (id, kind, last_seen_at, width, height, size_bytes,
                                   dominant_color, palette)
                VALUES ('f1', 'image', 0, 2400, 1600, 1048576, '#4a3320',
                        '["#4a3320","#8a6a42"]')
                """)
            try db.execute(sql: """
                INSERT INTO paths (id, file_id, absolute_path, is_alive)
                VALUES ('p1', 'f1', '/tmp/dog.jpg', 1)
                """)
            try db.execute(sql: """
                INSERT INTO tags (id, file_id, parent_dir, label, source, confidence)
                VALUES ('t1', 'f1', '/tmp', 'dog', 'vision', 0.9)
                """)
        }
        let d = try await ViewerFileDetails.load(queue: q, path: "/tmp/dog.jpg")
        XCTAssertEqual(d?.fileID, "f1")
        XCTAssertEqual(d?.pixelSize, CGSize(width: 2400, height: 1600))
        XCTAssertEqual(d?.palette, ["#4a3320", "#8a6a42"])
        XCTAssertEqual(d?.dominantColor, "#4a3320")
        XCTAssertEqual(d?.tags.map(\.label), ["dog"])
    }

    /// A byte-identical duplicate in another folder shares the file_id but has
    /// its own (folder-scoped) tags. The viewer must show ONLY this folder's
    /// tags — never the duplicate's — or the remove-pill would delete across
    /// folders.
    func testTagsScopedToFolderNotDuplicate() async throws {
        let q = try DatabaseQueue()
        try Database.makeMigrator().migrate(q)
        try await q.write { db in
            try db.execute(sql: "INSERT INTO files (id, kind, last_seen_at) VALUES ('f1','image',0)")
            // Same content (f1) at two paths in two folders.
            try db.execute(sql: "INSERT INTO paths (id, file_id, absolute_path, is_alive) VALUES ('pA','f1','/A/x.jpg',1)")
            try db.execute(sql: "INSERT INTO paths (id, file_id, absolute_path, is_alive) VALUES ('pB','f1','/B/x.jpg',1)")
            // 'blue' only in /A, 'red' only in /B.
            try db.execute(sql: "INSERT INTO tags (id, file_id, parent_dir, label, source) VALUES ('tA','f1','/A','blue','manual')")
            try db.execute(sql: "INSERT INTO tags (id, file_id, parent_dir, label, source) VALUES ('tB','f1','/B','red','manual')")
        }
        let a = try await ViewerFileDetails.load(queue: q, path: "/A/x.jpg")
        let b = try await ViewerFileDetails.load(queue: q, path: "/B/x.jpg")
        XCTAssertEqual(a?.tags.map(\.label), ["blue"])   // not ["blue","red"]
        XCTAssertEqual(b?.tags.map(\.label), ["red"])
    }

    func testUnindexedReturnsNil() async throws {
        let q = try DatabaseQueue()
        try Database.makeMigrator().migrate(q)
        let d = try await ViewerFileDetails.load(queue: q, path: "/nope.jpg")
        XCTAssertNil(d)
    }
}
