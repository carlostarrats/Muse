//
//  DriveShareStoreTests.swift
//  MuseTests
//

import XCTest
@testable import Muse

final class DriveShareStoreTests: XCTestCase {
    private func tempStore() -> (DriveShareStore, URL) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("driveshares-\(UUID().uuidString).json")
        return (DriveShareStore(fileURL: url), url)
    }
    private func rec(_ id: String, folder: String, expiry: Date) -> DriveShareRecord {
        DriveShareRecord(id: id, collectionName: "C", folderID: folder, pageURL: "u",
                         itemCount: 1, createdAt: Date(timeIntervalSince1970: 0), expiry: expiry)
    }

    func testAddPersistsReplaceByFolderRemove() {
        let (store, url) = tempStore(); defer { try? FileManager.default.removeItem(at: url) }
        store.add(rec("1", folder: "F", expiry: Date(timeIntervalSince1970: 10)))
        store.add(rec("2", folder: "F", expiry: Date(timeIntervalSince1970: 20))) // same folder → replace
        XCTAssertEqual(DriveShareStore(fileURL: url).all().map(\.id), ["2"])
        store.remove(id: "2")
        XCTAssertTrue(store.all().isEmpty)
    }

    func testRemoveIdsDropsTheGivenSetInOneRewrite() {
        let (store, url) = tempStore(); defer { try? FileManager.default.removeItem(at: url) }
        store.add(rec("1", folder: "A", expiry: Date(timeIntervalSince1970: 10)))
        store.add(rec("2", folder: "B", expiry: Date(timeIntervalSince1970: 20)))
        store.add(rec("3", folder: "C", expiry: Date(timeIntervalSince1970: 30)))
        store.remove(ids: ["1", "3"])
        XCTAssertEqual(store.all().map(\.id), ["2"])
        // Empty set is a no-op (and unknown ids are ignored).
        store.remove(ids: [])
        store.remove(ids: ["nope"])
        XCTAssertEqual(store.all().map(\.id), ["2"])
    }

    func testAddReturnsTrueWhenPersisted() {
        let (store, url) = tempStore(); defer { try? FileManager.default.removeItem(at: url) }
        // The return value gates the publish UI's "couldn't track this share"
        // warning, so a successful write must report true.
        XCTAssertTrue(store.add(rec("1", folder: "F", expiry: Date(timeIntervalSince1970: 10))))
    }

    func testAddReturnsFalseWhenWriteFails() {
        // A path whose parent directory doesn't exist → the atomic write throws,
        // so add must report false (the share is live but untracked → warn).
        let bad = URL(fileURLWithPath: "/no/such/dir/\(UUID().uuidString)/driveShares.json")
        let store = DriveShareStore(fileURL: bad)
        XCTAssertFalse(store.add(rec("1", folder: "F", expiry: Date(timeIntervalSince1970: 10))))
    }

    func testExpiredSelectsOnlyPastRecords() {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(secondsFromGMT: 0)!
        let expiryDay = Date(timeIntervalSince1970: 86_400) // 1970-01-02
        let record = rec("p", folder: "P", expiry: expiryDay)
        XCTAssertTrue(DriveExpiry.expired(
            [record], now: expiryDay.addingTimeInterval(86_399), calendar: utc).isEmpty,
            "the share stays live through its displayed expiry day")
        XCTAssertEqual(DriveExpiry.expired(
            [record], now: expiryDay.addingTimeInterval(86_400), calendar: utc).map(\.id), ["p"],
            "the share expires at the start of the following local day")
    }

    // MARK: portfolio records (Spec 07)

    private func portfolioRec(_ id: String, folder: String, collectionID: String) -> DriveShareRecord {
        DriveShareRecord(id: id, collectionName: "Portfolio", folderID: folder,
                         pageURL: "https://muse-share.pages.dev#xyz", itemCount: 5,
                         createdAt: Date(timeIntervalSince1970: 0),
                         expiry: DriveShareRecord.neverExpires,
                         kind: "portfolio", manifestFileID: "m1",
                         layoutSettingsFileID: "u1", collectionID: collectionID,
                         layout: "essay", introTitle: "My Work", bodyText: "About this work.")
    }

    // A driveShares.json written by a build before Spec 07 carries none of the
    // new keys and must decode unchanged.
    func testPreSpec07RecordDecodesUnchanged() throws {
        let legacy = """
        [{"id":"a","collectionName":"Trip","folderID":"f1",
          "pageURL":"https://muse-share.pages.dev#abc","itemCount":3,
          "createdAt":"2026-01-01T00:00:00Z","expiry":"2026-02-01T00:00:00Z"}]
        """
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("legacy-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(legacy.utf8).write(to: url)
        let all = DriveShareStore(fileURL: url).all()
        XCTAssertEqual(all.count, 1)
        XCTAssertNil(all.first?.kind)
        XCTAssertNil(all.first?.layoutSettingsFileID)
        XCTAssertFalse(all.first!.isPortfolio)
    }

    func testPortfolioRecordRoundTrips() {
        let (store, url) = tempStore(); defer { try? FileManager.default.removeItem(at: url) }
        let record = portfolioRec("p1", folder: "F1", collectionID: "col1")
        store.add(record)
        let loaded = DriveShareStore(fileURL: url).all().first
        XCTAssertEqual(loaded, record)
        XCTAssertEqual(loaded?.layoutSettingsFileID, "u1")
        XCTAssertTrue(loaded!.isPortfolio)
    }

    func testPortfolioForCollectionIDFiltersAndSortsNewestFirst() {
        let (store, url) = tempStore(); defer { try? FileManager.default.removeItem(at: url) }
        var older = portfolioRec("p1", folder: "F1", collectionID: "col1")
        older = DriveShareRecord(id: "p1", collectionName: older.collectionName, folderID: "F1",
                                 pageURL: older.pageURL, itemCount: older.itemCount,
                                 createdAt: Date(timeIntervalSince1970: 10), expiry: older.expiry,
                                 kind: "portfolio", collectionID: "col1")
        let newer = DriveShareRecord(id: "p2", collectionName: "P", folderID: "F2",
                                     pageURL: "u", itemCount: 1,
                                     createdAt: Date(timeIntervalSince1970: 20),
                                     expiry: DriveShareRecord.neverExpires,
                                     kind: "portfolio", collectionID: "col1")
        let other = portfolioRec("p3", folder: "F3", collectionID: "col2")
        let classic = rec("c1", folder: "F4", expiry: Date(timeIntervalSince1970: 99))
        [older, newer, other, classic].forEach { store.add($0) }
        XCTAssertEqual(store.portfolio(forCollectionID: "col1").map(\.id), ["p2", "p1"])
    }

    // The sentinel preserves backward decoding; DriveExpiry also excludes the
    // portfolio explicitly so even a clock beyond 2100 cannot sweep it.
    func testTheNeverExpiresSentinelIsNeverSwept() {
        let record = portfolioRec("p1", folder: "F1", collectionID: "col1")
        XCTAssertTrue(DriveExpiry.expired([record], now: Date(timeIntervalSince1970: 4_102_444_700)).isEmpty)
        XCTAssertTrue(DriveExpiry.expired([record], now: Date(timeIntervalSince1970: 4_102_444_900)).isEmpty,
                      "portfolio exclusion is explicit, not only a far-future timestamp")
    }

    func testUpsertByFolderIDReplacesAPortfolioRecordInPlace() {
        let (store, url) = tempStore(); defer { try? FileManager.default.removeItem(at: url) }
        let original = portfolioRec("p1", folder: "F1", collectionID: "col1")
        store.add(original)
        var updated = original
        updated.itemCount = 9
        updated.bodyText = "Updated text."
        store.add(updated)
        let all = store.all()
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all.first?.itemCount, 9)
        XCTAssertEqual(all.first?.bodyText, "Updated text.")
        XCTAssertEqual(all.first?.pageURL, original.pageURL)   // the link never changes
    }
}
