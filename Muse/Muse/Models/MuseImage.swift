//
//  MuseImage.swift
//  Muse
//
//  Created by Carlos Tarrats on 3/19/26.
//

import Foundation
import GRDB

struct MuseImage: Identifiable, Codable, Sendable, Equatable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "muse_images"

    var id: UUID
    var fileName: String
    var storagePath: String
    var thumbnailPath: String?
    var collectionID: UUID?
    var sourceURL: String?
    var notes: String
    var width: Int?
    var height: Int?
    var fileSize: Int?
    var dateAdded: Date
    var dateModified: Date

    enum CodingKeys: String, CodingKey {
        case id, fileName, storagePath, thumbnailPath, collectionID
        case sourceURL, notes, width, height, fileSize, dateAdded, dateModified
    }

    init(
        id: UUID = UUID(),
        fileName: String,
        storagePath: String,
        thumbnailPath: String? = nil,
        collectionID: UUID? = nil,
        sourceURL: String? = nil,
        notes: String = "",
        width: Int? = nil,
        height: Int? = nil,
        fileSize: Int? = nil,
        dateAdded: Date = Date(),
        dateModified: Date = Date()
    ) {
        self.id = id
        self.fileName = fileName
        self.storagePath = storagePath
        self.thumbnailPath = thumbnailPath
        self.collectionID = collectionID
        self.sourceURL = sourceURL
        self.notes = notes
        self.width = width
        self.height = height
        self.fileSize = fileSize
        self.dateAdded = dateAdded
        self.dateModified = dateModified
    }

    // MARK: - Computed Properties

    /// The app's storage directory: ~/Library/Application Support/Muse/
    private static var appStorageDirectory: URL? {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("Muse", isDirectory: true)
    }

    /// Resolves the relative storagePath against the app storage directory.
    var resolvedStorageURL: URL? {
        Self.appStorageDirectory?.appendingPathComponent(storagePath)
    }

    /// Resolves the relative thumbnailPath against the app storage directory.
    var resolvedThumbnailURL: URL? {
        guard let path = thumbnailPath else { return nil }
        return Self.appStorageDirectory?.appendingPathComponent(path)
    }
}

// MARK: - GRDB Columns

extension MuseImage {
    enum Columns {
        static let id = Column("id")
        static let fileName = Column("fileName")
        static let storagePath = Column("storagePath")
        static let thumbnailPath = Column("thumbnailPath")
        static let collectionID = Column("collectionID")
        static let sourceURL = Column("sourceURL")
        static let notes = Column("notes")
        static let width = Column("width")
        static let height = Column("height")
        static let fileSize = Column("fileSize")
        static let dateAdded = Column("dateAdded")
        static let dateModified = Column("dateModified")
    }
}
