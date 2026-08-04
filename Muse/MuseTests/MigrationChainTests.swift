//
//  MigrationChainTests.swift
//  MuseTests
//
//  The migration CHAIN itself, not any one migration: order and endpoint.
//
//  GRDB replays migrations in registration order and records each by NAME, so
//  reordering or renaming one silently changes what an existing library
//  becomes on its next launch — a class of bug no single-migration test can
//  see. DECISIONS' "Current state" block states the chain ends at v23 and the
//  next spec starts at v26; this is that claim, executable.
//

import XCTest
import GRDB
@testable import Muse

final class MigrationChainTests: XCTestCase {

    private static let expectedOrder = [
        "v1_schema", "v2_intelligence", "v3_membership", "v4_auto_analyze",
        "v5_intent", "v6_collection_cover", "v7_tag_parent_dir",
        "v8_collection_sort_order",
        "v9_fts_basename_backfill", "v10_collection_appearance", "v11_file_note",
        "v12_smart_collections", "v13_coordinates", "v14_photo_meta",
        "v15_places", "v16_rediscovery", "v17_stacks", "v18_clip_embeddings",
        "v19_photo_traits", "v20_edits", "v21_edit_presets", "v22_photo_stats",
        "v23_edit_luts", "v24_per_file_identity",
        "v25_per_file_identity_repair",
    ]

    func testChainOrderIsExactlyAsRecorded() {
        XCTAssertEqual(Database.makeMigrator().migrations, Self.expectedOrder)
    }

    /// The chain's endpoint. A new spec adds v26 and updates this line — which
    /// is the point: the change is deliberate and reviewed, not incidental.
    func testChainEndsAtV25() {
        XCTAssertEqual(Database.makeMigrator().migrations.last, "v25_per_file_identity_repair")
    }

    /// A fresh database must run the whole chain and land on the same schema
    /// an upgraded one does.
    func testFreshDatabaseAppliesEveryMigration() throws {
        let queue = try DatabaseQueue()
        let migrator = Database.makeMigrator()
        try migrator.migrate(queue)
        try queue.read { db in
            for name in Self.expectedOrder {
                XCTAssertTrue(try migrator.hasCompletedMigrations(db),
                              "migration \(name) left the chain incomplete")
            }
            // Spot-check the tables Specs 01–07 added, so "completed" isn't
            // taken on trust from the migrator's own bookkeeping.
            for table in ["photo_meta", "places", "stacks", "stack_members",
                          "clip_embeddings", "photo_traits", "edits",
                          "edit_versions", "edit_presets", "edit_luts"] {
                XCTAssertTrue(try db.tableExists(table), "\(table) missing after migration")
            }
        }
    }

    /// Stepping to an INTERMEDIATE version must stop there — the property an
    /// upgrade from an older library depends on.
    func testPartialMigrationStopsAtTheTarget() throws {
        let queue = try DatabaseQueue()
        try Database.makeMigrator().migrate(queue, upTo: "v12_smart_collections")
        try queue.read { db in
            XCTAssertTrue(try db.tableExists("collections"))
            XCTAssertFalse(try db.tableExists("photo_meta"),
                           "v14 ran despite a v12 target")
            XCTAssertFalse(try db.tableExists("edits"))
        }
        // …and resuming completes the rest, which is what a real upgrade does.
        try Database.makeMigrator().migrate(queue)
        try queue.read { db in
            XCTAssertTrue(try db.tableExists("edit_luts"))
        }
    }
}
