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
        let now = Date(timeIntervalSince1970: 100)
        let past = rec("p", folder: "P", expiry: Date(timeIntervalSince1970: 50))
        let future = rec("f", folder: "F", expiry: Date(timeIntervalSince1970: 150))
        XCTAssertEqual(DriveExpiry.expired([past, future], now: now).map(\.id), ["p"])
    }
}
