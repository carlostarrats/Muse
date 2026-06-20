//
//  CollectionMaterializer.swift
//  Muse
//
//  Pure rules turning archived collections into the rows we actually create on
//  restore. Enforces "no dead collections": an auto collection with zero
//  reconnected members is dropped; a hand-made (manual) one is kept even empty.
//

import Foundation

nonisolated struct MaterializedMember: Equatable, Sendable {
    var fileID: String
    var addedBy: String
}

nonisolated struct MaterializedCollection: Equatable, Sendable {
    var id: String
    var name: String
    var sortOrder: Int
    var modelVersion: String
    var isHidden: Int
    var coverFileID: String?
    var memberFileIDs: [MaterializedMember]
    var excludedFileIDs: [String]
}

nonisolated enum CollectionMaterializer {
    static func materialize(_ collections: [BackupCollection],
                            fileIDForHash: [String: String]) -> [MaterializedCollection] {
        var out: [MaterializedCollection] = []
        for c in collections {
            let members = c.members.compactMap { m -> MaterializedMember? in
                guard let fid = fileIDForHash[m.content_hash] else { return nil }
                return MaterializedMember(fileID: fid, addedBy: m.added_by)
            }
            let isManual = c.model_version == "manual"
            if members.isEmpty && !isManual { continue }    // drop dead auto collection
            out.append(MaterializedCollection(
                id: c.id, name: c.name, sortOrder: c.sort_order,
                modelVersion: c.model_version, isHidden: c.is_hidden,
                coverFileID: c.cover_hash.flatMap { fileIDForHash[$0] },
                memberFileIDs: members,
                excludedFileIDs: c.excluded_hashes.compactMap { fileIDForHash[$0] }))
        }
        return out
    }
}
