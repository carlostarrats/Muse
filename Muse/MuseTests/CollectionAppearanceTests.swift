//
//  CollectionAppearanceTests.swift
//  MuseTests
//
//  Pure rules for the sidebar collection icon/color customization
//  (feat/next-128): token table, symbol catalog validity, fallback
//  resolution, the v10 columns + setAppearance store seam, and the
//  backup carry (archive fields + materializer).
//

import XCTest
import GRDB
@testable import Muse

final class CollectionAppearanceTests: XCTestCase {

    // MARK: - Color tokens

    func testTwentySevenUniqueColorTokens() {
        let tokens = CollectionAppearance.colorTokens.map(\.token)
        // 27 + the Default cell = a full 7-row × 4 picker grid.
        XCTAssertEqual(tokens.count, 27)
        XCTAssertEqual(Set(tokens).count, 27, "duplicate token would break selection identity")
    }

    func testColorForKnownTokenResolves() {
        for entry in CollectionAppearance.colorTokens {
            XCTAssertNotNil(CollectionAppearance.color(for: entry.token))
        }
    }

    func testColorForNilOrUnknownTokenIsNil() {
        XCTAssertNil(CollectionAppearance.color(for: nil))
        XCTAssertNil(CollectionAppearance.color(for: "chartreuse"))
        XCTAssertNil(CollectionAppearance.color(for: ""))
    }

    func testEveryTokenHasADisplayName() {
        for entry in CollectionAppearance.colorTokens {
            let name = CollectionAppearance.displayName(forToken: entry.token)
            XCTAssertFalse(name.isEmpty)
            XCTAssertNotEqual(name, entry.token,
                              "token \(entry.token) fell through to the raw-token fallback")
        }
    }

    // MARK: - Symbol catalog

    func testSymbolCatalogShape() {
        let symbols = CollectionAppearance.symbols
        XCTAssertEqual(symbols.count, 36, "the picker grid is designed as 6×6")
        XCTAssertEqual(symbols.first, CollectionAppearance.defaultIcon)
        XCTAssertEqual(Set(symbols).count, symbols.count, "duplicate symbol cell")
    }

    func testEveryCatalogSymbolExistsOnThisOS() {
        for name in CollectionAppearance.symbols {
            XCTAssertTrue(CollectionAppearance.isValidSymbol(name),
                          "\(name) is not in this OS's SF Symbols set — blank picker cell")
        }
    }

    func testEverySymbolHasADisplayName() {
        for name in CollectionAppearance.symbols {
            let display = CollectionAppearance.displayName(forSymbol: name)
            XCTAssertFalse(display.isEmpty)
            XCTAssertNotEqual(display, name,
                              "\(name) fell through to the raw-name fallback")
        }
    }

    // MARK: - Icon resolution (fallback rules)

    func testResolvedIconFallsBackForNilAndBogusNames() {
        XCTAssertEqual(CollectionAppearance.resolvedIcon(nil), CollectionAppearance.defaultIcon)
        XCTAssertEqual(CollectionAppearance.resolvedIcon("not.a.real.symbol.xyz"),
                       CollectionAppearance.defaultIcon)
        XCTAssertEqual(CollectionAppearance.resolvedIcon(""), CollectionAppearance.defaultIcon)
    }

    func testResolvedIconKeepsAValidName() {
        XCTAssertEqual(CollectionAppearance.resolvedIcon("star"), "star")
    }

    // MARK: - v10 migration + store seam

    private func makeQueue() throws -> DatabaseQueue {
        let queue = try DatabaseQueue()                 // in-memory
        try Database.makeMigrator().migrate(queue)
        return queue
    }

    private func insertCollection(_ db: GRDB.Database, id: String) throws {
        try db.execute(sql: """
            INSERT INTO collections (id, name, is_hidden, model_version, created_at, updated_at, sort_order)
            VALUES (?, 'Test', 0, 'manual', 1, 1, 0)
            """, arguments: [id])
    }

    func testMigrationAddsNullableAppearanceColumns() throws {
        let queue = try makeQueue()
        try queue.write { db in try self.insertCollection(db, id: "c1") }
        let row = try queue.read { db in
            try CollectionRow.fetchOne(db, sql: "SELECT * FROM collections WHERE id = 'c1'")
        }
        XCTAssertNil(row?.icon)
        XCTAssertNil(row?.color)
    }

    func testSetAppearanceWritesAndClears() async throws {
        let queue = try makeQueue()
        try await queue.write { db in try self.insertCollection(db, id: "c1") }

        try await CollectionStore.setAppearance(queue: queue, id: "c1",
                                                icon: "star.fill", color: "red")
        var row = try await queue.read { db in
            try CollectionRow.fetchOne(db, sql: "SELECT * FROM collections WHERE id = 'c1'")
        }
        XCTAssertEqual(row?.icon, "star.fill")
        XCTAssertEqual(row?.color, "red")

        // Reset to Default = nil/nil, back to the classic look.
        try await CollectionStore.setAppearance(queue: queue, id: "c1", icon: nil, color: nil)
        row = try await queue.read { db in
            try CollectionRow.fetchOne(db, sql: "SELECT * FROM collections WHERE id = 'c1'")
        }
        XCTAssertNil(row?.icon)
        XCTAssertNil(row?.color)
    }

    // MARK: - Backup carry

    func testPreAppearanceArchiveJSONStillDecodes() throws {
        // A BackupCollection serialized before v10 has no icon/color keys.
        let json = """
        {"id":"c1","name":"Old","sort_order":0,"model_version":"manual",
         "is_hidden":0,"members":[],"excluded_hashes":[]}
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(BackupCollection.self, from: json)
        XCTAssertNil(decoded.icon)
        XCTAssertNil(decoded.color)
    }

    func testMaterializerCarriesAppearance() {
        let c = BackupCollection(id: "c1", name: "N", sort_order: 0,
                                 model_version: "manual", is_hidden: 0,
                                 cover_hash: nil, members: [], excluded_hashes: [],
                                 icon: "heart.fill", color: "pink")
        let out = CollectionMaterializer.materialize([c], fileIDForHash: [:])
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out.first?.icon, "heart.fill")
        XCTAssertEqual(out.first?.color, "pink")
    }
}
