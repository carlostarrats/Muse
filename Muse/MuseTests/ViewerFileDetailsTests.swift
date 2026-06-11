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
                INSERT INTO tags (id, file_id, label, source, confidence)
                VALUES ('t1', 'f1', 'dog', 'vision', 0.9)
                """)
        }
        let d = try await ViewerFileDetails.load(queue: q, path: "/tmp/dog.jpg")
        XCTAssertEqual(d?.fileID, "f1")
        XCTAssertEqual(d?.pixelSize, CGSize(width: 2400, height: 1600))
        XCTAssertEqual(d?.palette, ["#4a3320", "#8a6a42"])
        XCTAssertEqual(d?.dominantColor, "#4a3320")
        XCTAssertEqual(d?.tags.map(\.label), ["dog"])
    }

    func testUnindexedReturnsNil() async throws {
        let q = try DatabaseQueue()
        try Database.makeMigrator().migrate(q)
        let d = try await ViewerFileDetails.load(queue: q, path: "/nope.jpg")
        XCTAssertNil(d)
    }
}
