//
//  AnnouncementFeedTests.swift
//  MuseTests
//
//  Pure parse/selection logic, separated from the fetch so it's fully
//  unit-testable — matching every other pure component in this codebase.
//  The payload is remote text, so most of these are hostile-input cases.
//

import XCTest
@testable import Muse

final class AnnouncementFeedTests: XCTestCase {

    private func feed(_ json: String) -> AnnouncementFeed? {
        AnnouncementFeed.parse(Data(json.utf8))
    }

    // MARK: - Parsing

    func testParsesValidFeed() {
        let f = feed("""
        { "version": 1, "messages": [
          { "id": "a", "title": "Hello", "body": "World",
            "url": "https://example.com", "minAppVersion": "1.6" }
        ] }
        """)
        XCTAssertEqual(f?.messages.first?.id, "a")
        XCTAssertEqual(f?.messages.first?.title, "Hello")
        XCTAssertEqual(f?.messages.first?.url, "https://example.com")
    }

    func testRejectsInvalidJSON() {
        XCTAssertNil(AnnouncementFeed.parse(Data("not json".utf8)))
    }

    func testRejectsOversizedPayloadBeforeDecoding() {
        let huge = Data(repeating: 0x41, count: AnnouncementFeed.maxPayloadBytes + 1)
        XCTAssertNil(AnnouncementFeed.parse(huge))
    }

    func testIgnoresUnknownVersion() {
        XCTAssertNil(feed(#"{ "version": 99, "messages": [] }"#))
    }

    func testDropsMessagesWithEmptyOrOversizedID() {
        let long = String(repeating: "x", count: AnnouncementFeed.maxIDLength + 1)
        let f = feed("""
        { "version": 1, "messages": [
          { "id": "", "title": "A", "body": "B", "url": null, "minAppVersion": null },
          { "id": "\(long)", "title": "A", "body": "B", "url": null, "minAppVersion": null }
        ] }
        """)
        XCTAssertEqual(f?.messages.count, 0)
    }

    // MARK: - Hostile text

    func testSanitizesHostileTitleAndBody() {
        let f = feed("""
        { "version": 1, "messages": [
          { "id": "a", "title": "\\u202Eevil", "body": "hi\\u200Bthere",
            "url": null, "minAppVersion": null }
        ] }
        """)
        XCTAssertEqual(f?.messages.first?.title, "evil")
        XCTAssertEqual(f?.messages.first?.body, "hithere")
    }

    func testCapsFieldLengths() {
        let longTitle = String(repeating: "t", count: 1000)
        let f = feed("""
        { "version": 1, "messages": [
          { "id": "a", "title": "\(longTitle)", "body": "B", "url": null, "minAppVersion": null }
        ] }
        """)
        XCTAssertEqual(f?.messages.first?.title.count, AnnouncementFeed.maxTitleLength)
    }

    func testRejectsNonHTTPSURL() {
        for scheme in ["http://example.com", "file:///etc/passwd", "javascript:alert(1)"] {
            let f = feed("""
            { "version": 1, "messages": [
              { "id": "a", "title": "A", "body": "B", "url": "\(scheme)", "minAppVersion": null }
            ] }
            """)
            XCTAssertNil(f?.messages.first?.url, "\(scheme) must be dropped, not opened")
            XCTAssertEqual(f?.messages.first?.id, "a", "the message itself survives; only the url drops")
        }
    }

    // MARK: - Selection

    func testUnseenFiltersAlreadySeenIDs() {
        let f = AnnouncementFeed(version: 1, messages: [
            Announcement(id: "a", title: "A", body: "", url: nil, minAppVersion: nil),
            Announcement(id: "b", title: "B", body: "", url: nil, minAppVersion: nil),
        ])
        XCTAssertEqual(AnnouncementFeed.unseen(f, seen: ["a"], appVersion: "1.6").map(\.id), ["b"])
    }

    func testMinAppVersionGating() {
        let f = AnnouncementFeed(version: 1, messages: [
            Announcement(id: "a", title: "A", body: "", url: nil, minAppVersion: "2.0"),
        ])
        XCTAssertTrue(AnnouncementFeed.unseen(f, seen: [], appVersion: "1.6").isEmpty,
                      "a message requiring a newer app version must be withheld")
    }

    func testMinAppVersionSatisfiedByEqualOrNewer() {
        let f = AnnouncementFeed(version: 1, messages: [
            Announcement(id: "a", title: "A", body: "", url: nil, minAppVersion: "1.6"),
        ])
        XCTAssertEqual(AnnouncementFeed.unseen(f, seen: [], appVersion: "1.6").count, 1)
        XCTAssertEqual(AnnouncementFeed.unseen(f, seen: [], appVersion: "1.7").count, 1)
    }

    /// Multi-digit segments: "1.10" is NEWER than "1.6", which a plain string
    /// compare gets backwards.
    func testVersionComparisonIsNumericNotLexicographic() {
        let f = AnnouncementFeed(version: 1, messages: [
            Announcement(id: "a", title: "A", body: "", url: nil, minAppVersion: "1.10"),
        ])
        XCTAssertTrue(AnnouncementFeed.unseen(f, seen: [], appVersion: "1.6").isEmpty,
                      "1.6 is older than 1.10 — the message must be withheld")
        XCTAssertEqual(AnnouncementFeed.unseen(f, seen: [], appVersion: "1.10").count, 1)
    }

    func testNoMinVersionAlwaysApplies() {
        let f = AnnouncementFeed(version: 1, messages: [
            Announcement(id: "a", title: "A", body: "", url: nil, minAppVersion: nil),
        ])
        XCTAssertEqual(AnnouncementFeed.unseen(f, seen: [], appVersion: "0").count, 1)
    }
}
