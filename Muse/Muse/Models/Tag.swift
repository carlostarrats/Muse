//
//  Tag.swift
//  Muse
//
//  Created by Carlos Tarrats on 3/19/26.
//

import Foundation
import GRDB

struct Tag: Identifiable, Codable, Sendable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "tags"

    var id: UUID
    var imageID: UUID
    var label: String
    var source: String

    enum CodingKeys: String, CodingKey {
        case id, imageID, label, source
    }

    init(
        id: UUID = UUID(),
        imageID: UUID,
        label: String,
        source: String = "manual"
    ) {
        self.id = id
        self.imageID = imageID
        self.label = label
        self.source = source
    }
}

// MARK: - GRDB Columns

extension Tag {
    enum Columns {
        static let id = Column("id")
        static let imageID = Column("imageID")
        static let label = Column("label")
        static let source = Column("source")
    }
}
