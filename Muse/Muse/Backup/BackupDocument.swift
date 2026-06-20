//
//  BackupDocument.swift
//  Muse
//
//  Serializes a BackupArchive to/from the single .muselibrary file.
//

import Foundation

enum BackupDocument {
    static let fileExtension = "muselibrary"

    enum DocError: Error { case unreadable, unsupportedSchema(Int) }

    static func encode(_ archive: BackupArchive) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(archive)
    }

    static func decode(_ data: Data) throws -> BackupArchive {
        let archive: BackupArchive
        do { archive = try JSONDecoder().decode(BackupArchive.self, from: data) }
        catch { throw DocError.unreadable }
        guard archive.schema == BackupArchive.currentSchema else {
            throw DocError.unsupportedSchema(archive.schema)
        }
        return archive
    }
}
