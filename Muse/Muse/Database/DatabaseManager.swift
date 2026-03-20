//
//  DatabaseManager.swift
//  Muse
//
//  Created by Carlos Tarrats on 3/19/26.
//

import Foundation
import GRDB

/// Manages the SQLite database for Muse, including directory setup, migrations, and error state.
final class DatabaseManager: ObservableObject {

    // MARK: - Published State

    /// Non-nil when the database failed to initialize or migrate. Observe this for UI alerts.
    @Published var initializationError: Error?

    // MARK: - Database Queue

    /// The GRDB database queue. Nil if setup failed — callers must guard against nil before use.
    var dbQueue: DatabaseQueue?

    // MARK: - Paths

    /// `~/Library/Application Support/Muse/`
    static var appSupportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Muse", isDirectory: true)
    }

    /// `~/Library/Application Support/Muse/Images/`
    static var imagesDirectory: URL {
        appSupportDirectory.appendingPathComponent("Images", isDirectory: true)
    }

    /// `~/Library/Application Support/Muse/muse.db`
    static var databaseURL: URL {
        appSupportDirectory.appendingPathComponent("muse.db")
    }

    // MARK: - Init

    init() {
        do {
            try Self.createDirectoriesIfNeeded()
            let queue = try DatabaseQueue(path: Self.databaseURL.path)
            try Self.migrate(queue)
            dbQueue = queue
        } catch {
            initializationError = error
            dbQueue = nil
        }
    }

    // MARK: - Directory Setup

    private static func createDirectoriesIfNeeded() throws {
        let fm = FileManager.default
        for directory in [appSupportDirectory, imagesDirectory] {
            if !fm.fileExists(atPath: directory.path) {
                try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            }
        }
    }

    // MARK: - Migrations

    private static func migrate(_ queue: DatabaseQueue) throws {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1") { db in
            // collections — referenced by muse_images, so must be created first
            try db.create(table: "collections", ifNotExists: true) { t in
                t.column("id", .text).primaryKey()
                t.column("name", .text).notNull()
                t.column("colorHex", .text).defaults(to: "#5E8BFF")
                t.column("sortOrder", .integer).defaults(to: 0)
                t.column("dateCreated", .text).notNull()
            }

            // muse_images
            try db.create(table: "muse_images", ifNotExists: true) { t in
                t.column("id", .text).primaryKey()
                t.column("fileName", .text).notNull()
                t.column("storagePath", .text).notNull()
                t.column("thumbnailPath", .text)
                t.column("collectionID", .text).references("collections")
                t.column("sourceURL", .text)
                t.column("notes", .text).defaults(to: "")
                t.column("width", .integer)
                t.column("height", .integer)
                t.column("fileSize", .integer)
                t.column("dateAdded", .text).notNull()
                t.column("dateModified", .text).notNull()
            }

            // tags
            try db.create(table: "tags", ifNotExists: true) { t in
                t.column("id", .text).primaryKey()
                t.column("imageID", .text).notNull()
                    .references("muse_images", onDelete: .cascade)
                t.column("label", .text).notNull()
                t.column("source", .text).notNull().defaults(to: "manual")
                t.uniqueKey(["imageID", "label"])
            }
        }

        try migrator.migrate(queue)
    }
}
