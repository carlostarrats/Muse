//
//  Collection.swift
//  Muse
//
//  Created by Carlos Tarrats on 3/19/26.
//

import Foundation
import GRDB

struct MuseCollection: Identifiable, Codable, Sendable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "collections"

    var id: UUID
    var name: String
    var colorHex: String
    var sortOrder: Int
    var dateCreated: Date

    enum CodingKeys: String, CodingKey {
        case id, name, colorHex, sortOrder, dateCreated
    }

    init(
        id: UUID = UUID(),
        name: String,
        colorHex: String = "#5E8BFF",
        sortOrder: Int = 0,
        dateCreated: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.colorHex = colorHex
        self.sortOrder = sortOrder
        self.dateCreated = dateCreated
    }
}

// MARK: - GRDB

extension MuseCollection {
    enum Columns {
        static let id = Column("id")
        static let name = Column("name")
        static let colorHex = Column("colorHex")
        static let sortOrder = Column("sortOrder")
        static let dateCreated = Column("dateCreated")
    }
}
