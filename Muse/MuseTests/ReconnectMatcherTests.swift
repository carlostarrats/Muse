//
//  ReconnectMatcherTests.swift
//  MuseTests
//

import XCTest
@testable import Muse

final class ReconnectMatcherTests: XCTestCase {
    private func occ(_ path: String, _ name: String) -> BackupOccurrence {
        BackupOccurrence(original_path: path, basename: name, root_path: nil,
                         parent_dir: nil, tags: [])
    }

    func testExactHashWinsEvenIfRenamed() {
        let o = occ("/old/cat.jpg", "cat.jpg")
        let disk = [DiskFile(path: "/new/renamed.jpg", basename: "renamed.jpg", contentHash: "h1")]
        let r = ReconnectMatcher.match(occurrences: [o], disk: disk,
                                       expectedHash: ["/old/cat.jpg": "h1"])
        XCTAssertEqual(r.matches, [OccurrenceMatch(occurrence: o, diskPath: "/new/renamed.jpg", kind: .exact)])
        XCTAssertTrue(r.unmatched.isEmpty)
    }

    func testNameOnlyFallbackWhenBytesChanged() {
        let o = occ("/old/cat.jpg", "cat.jpg")
        let disk = [DiskFile(path: "/new/cat.jpg", basename: "cat.jpg", contentHash: "DIFFERENT")]
        let r = ReconnectMatcher.match(occurrences: [o], disk: disk,
                                       expectedHash: ["/old/cat.jpg": "h1"])
        XCTAssertEqual(r.matches.first?.kind, .nameOnly)
        XCTAssertEqual(r.matches.first?.diskPath, "/new/cat.jpg")
    }

    func testUnmatchedWhenNeitherHashNorName() {
        let o = occ("/old/cat.jpg", "cat.jpg")
        let disk = [DiskFile(path: "/new/dog.png", basename: "dog.png", contentHash: "zzz")]
        let r = ReconnectMatcher.match(occurrences: [o], disk: disk,
                                       expectedHash: ["/old/cat.jpg": "h1"])
        XCTAssertTrue(r.matches.isEmpty)
        XCTAssertEqual(r.unmatched, [o])
    }

    func testExactResolvedBeforeNameFallbackSoNoFileTheft() {
        let o1 = occ("/old/cat.jpg", "cat.jpg")          // expects h1
        let o2 = occ("/old/copy/cat.jpg", "cat.jpg")     // expects h2 (not on disk)
        let disk = [
            DiskFile(path: "/new/other.jpg", basename: "other.jpg", contentHash: "h1"),
            DiskFile(path: "/new/cat.jpg", basename: "cat.jpg", contentHash: "h1"),
        ]
        let r = ReconnectMatcher.match(
            occurrences: [o1, o2], disk: disk,
            expectedHash: ["/old/cat.jpg": "h1", "/old/copy/cat.jpg": "h2"])
        XCTAssertEqual(r.matches.count, 2)
        XCTAssertEqual(r.matches.first { $0.occurrence == o1 }?.kind, .exact)
        XCTAssertEqual(r.matches.first { $0.occurrence == o2 }?.kind, .nameOnly)
    }
}
