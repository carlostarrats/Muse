//
//  ImageRepository.swift
//  Muse
//
//  Created by Carlos Tarrats on 3/19/26.
//

import Foundation
import GRDB

/// Provides async CRUD operations for images, tags, and collections.
final class ImageRepository {

    // MARK: - Dependencies

    private let dbQueue: DatabaseQueue

    // MARK: - Init

    init(dbQueue: DatabaseQueue) {
        self.dbQueue = dbQueue
    }

    // MARK: - Image CRUD

    /// Inserts a new image record. The `image` parameter is mutated in place so the caller
    /// receives any DB-assigned values (e.g. defaults written back through GRDB).
    func insertImage(_ image: inout MuseImage) async throws {
        // Capture a local copy to use inside the closure (inout cannot cross concurrency boundary).
        var local = image
        try await dbQueue.write { db in
            try local.insert(db)
        }
        image = local
    }

    /// Persists all changes to an existing image record.
    func updateImage(_ image: MuseImage) async throws {
        try await dbQueue.write { db in
            try image.update(db)
        }
    }

    /// Deletes an image's database record and removes both the storage file and thumbnail from disk.
    func deleteImage(_ image: MuseImage) async throws {
        // Capture resolved URLs before entering the write closure.
        let storageURL = image.resolvedStorageURL
        let thumbnailURL = image.resolvedThumbnailURL

        try await dbQueue.write { db in
            try image.delete(db)
        }

        // Remove files after the DB transaction succeeds.
        let fm = FileManager.default
        if let url = storageURL, fm.fileExists(atPath: url.path) {
            try fm.removeItem(at: url)
        }
        if let url = thumbnailURL, fm.fileExists(atPath: url.path) {
            try fm.removeItem(at: url)
        }
    }

    /// Returns all images ordered by dateAdded descending.
    func fetchAllImages() async throws -> [MuseImage] {
        try await dbQueue.read { db in
            try MuseImage
                .order(MuseImage.Columns.dateAdded.desc)
                .fetchAll(db)
        }
    }

    /// Returns all images belonging to the specified collection.
    func fetchImages(inCollection collectionID: UUID) async throws -> [MuseImage] {
        try await dbQueue.read { db in
            try MuseImage
                .filter(MuseImage.Columns.collectionID == collectionID)
                .order(MuseImage.Columns.dateAdded.desc)
                .fetchAll(db)
        }
    }

    // MARK: - Search

    /// Searches images by fileName, notes, and associated tag labels using a LEFT JOIN.
    /// Returns deduplicated results ordered by dateAdded descending.
    func searchImages(query: String) async throws -> [MuseImage] {
        let pattern = "%\(query)%"
        return try await dbQueue.read { db in
            let sql = """
                SELECT DISTINCT muse_images.*
                FROM muse_images
                LEFT JOIN tags ON tags.imageID = muse_images.id
                WHERE muse_images.fileName LIKE ?
                   OR muse_images.notes    LIKE ?
                   OR tags.label           LIKE ?
                ORDER BY muse_images.dateAdded DESC
                """
            return try MuseImage.fetchAll(db, sql: sql, arguments: [pattern, pattern, pattern])
        }
    }

    // MARK: - Tag Operations

    /// Returns all tags associated with the given image.
    func fetchTags(for imageID: UUID) async throws -> [Tag] {
        try await dbQueue.read { db in
            try Tag
                .filter(Tag.Columns.imageID == imageID)
                .fetchAll(db)
        }
    }

    /// Inserts a new tag record.
    func addTag(_ tag: Tag) async throws {
        try await dbQueue.write { db in
            try tag.insert(db)
        }
    }

    /// Deletes the given tag record.
    func deleteTag(_ tag: Tag) async throws {
        try await dbQueue.write { db in
            try tag.delete(db)
        }
    }

    /// Returns all unique tag labels across all images.
    func fetchAllTags() async throws -> [Tag] {
        try await dbQueue.read { db in
            try Tag
                .order(Tag.Columns.label.asc)
                .fetchAll(db)
        }
    }

    /// Returns all tags in the database.
    func fetchEveryTag() async throws -> [Tag] {
        try await dbQueue.read { db in
            try Tag.fetchAll(db)
        }
    }

    // MARK: - Collection Operations

    /// Inserts a new collection record. The `collection` parameter is mutated in place so the
    /// caller receives any DB-assigned values.
    func insertCollection(_ collection: inout MuseCollection) async throws {
        var local = collection
        try await dbQueue.write { db in
            try local.insert(db)
        }
        collection = local
    }

    /// Returns all collections ordered by sortOrder ascending.
    func fetchAllCollections() async throws -> [MuseCollection] {
        try await dbQueue.read { db in
            try MuseCollection
                .order(MuseCollection.Columns.sortOrder.asc)
                .fetchAll(db)
        }
    }

    /// Deletes a collection and NULLs out `collectionID` on all associated images.
    /// Images themselves are NOT deleted.
    func deleteCollection(_ collection: MuseCollection) async throws {
        let collectionID = collection.id
        try await dbQueue.write { db in
            // NULL out collectionID on all images that belong to this collection.
            try db.execute(
                sql: "UPDATE muse_images SET collectionID = NULL WHERE collectionID = ?",
                arguments: [collectionID]
            )
            try collection.delete(db)
        }
    }
}
