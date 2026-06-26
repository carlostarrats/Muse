//
//  ICloudShareStoreTests.swift
//  MuseTests
//

import XCTest
@testable import Muse

final class ICloudShareStoreTests: XCTestCase {
    private func tempStore() -> (ICloudShareStore, URL) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("icloudshares-\(UUID().uuidString).json")
        return (ICloudShareStore(fileURL: url), url)
    }

    func testAddPersistsAndReloads() {
        let (store, url) = tempStore()
        defer { try? FileManager.default.removeItem(at: url) }
        let r = ICloudShareRecord(id: "1", collectionName: "A", folderPath: "/p/A",
                                  itemCount: 3, createdAt: Date(timeIntervalSince1970: 100))
        store.add(r)
        // A fresh store over the same file sees it (persisted to disk).
        XCTAssertEqual(ICloudShareStore(fileURL: url).all(), [r])
    }

    func testAllReturnsNewestFirst() {
        let (store, url) = tempStore()
        defer { try? FileManager.default.removeItem(at: url) }
        let older = ICloudShareRecord(id: "1", collectionName: "old", folderPath: "/p/old",
                                      itemCount: 1, createdAt: Date(timeIntervalSince1970: 10))
        let newer = ICloudShareRecord(id: "2", collectionName: "new", folderPath: "/p/new",
                                      itemCount: 1, createdAt: Date(timeIntervalSince1970: 99))
        store.add(older); store.add(newer)
        XCTAssertEqual(store.all().map(\.id), ["2", "1"])
    }

    func testReSharingSameFolderReplacesRecord() {
        let (store, url) = tempStore()
        defer { try? FileManager.default.removeItem(at: url) }
        let first = ICloudShareRecord(id: "1", collectionName: "Kitchen", folderPath: "/p/Kitchen",
                                      itemCount: 2, createdAt: Date(timeIntervalSince1970: 10))
        let reshare = ICloudShareRecord(id: "2", collectionName: "Kitchen", folderPath: "/p/Kitchen",
                                        itemCount: 5, createdAt: Date(timeIntervalSince1970: 20))
        store.add(first); store.add(reshare)
        // Same folder path → only the latest record remains (no stale duplicate).
        XCTAssertEqual(store.all(), [reshare])
    }

    func testRemoveDropsRecord() {
        let (store, url) = tempStore()
        defer { try? FileManager.default.removeItem(at: url) }
        store.add(ICloudShareRecord(id: "1", collectionName: "A", folderPath: "/p/A",
                                    itemCount: 1, createdAt: Date()))
        store.remove(id: "1")
        XCTAssertTrue(store.all().isEmpty)
    }
}
