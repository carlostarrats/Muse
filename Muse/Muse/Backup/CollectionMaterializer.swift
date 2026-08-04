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
    var icon: String? = nil
    var color: String? = nil
    var smartRules: String? = nil
}

nonisolated enum CollectionMaterializer {
    /// `fileIDForPath` maps an archived occurrence path to the row it
    /// reconnected to. When the archive carries per-occurrence membership it
    /// WINS: hash-keyed membership cannot distinguish two byte-identical
    /// copies, so restoring by hash put every copy in the collection. An
    /// archive taken before per-file identity has no path fields and falls back
    /// to the hash view, which is the correct reading of what it recorded.
    static func materialize(_ collections: [BackupCollection],
                            fileIDForHash: [String: String],
                            fileIDForPath: [String: String] = [:]) -> [MaterializedCollection] {
        var out: [MaterializedCollection] = []
        for c in collections {
            let members: [MaterializedMember]
            if let paths = c.member_paths {
                members = paths.compactMap { m in
                    guard let fid = fileIDForPath[m.original_path] else { return nil }
                    return MaterializedMember(fileID: fid, addedBy: m.added_by)
                }
            } else {
                members = c.members.compactMap { m -> MaterializedMember? in
                    guard let fid = fileIDForHash[m.content_hash] else { return nil }
                    return MaterializedMember(fileID: fid, addedBy: m.added_by)
                }
            }
            // Drop a dead AUTO collection (zero reconnected members) — UNLESS it's
            // a hand-made one (preserved even empty) or a hidden one (a durable
            // "deleted" tombstone; recreating it keeps a user-deleted auto
            // collection from being resurrected when re-analysis reclusters the
            // same files into the same deterministic id on the new Mac).
            let isManual = c.model_version == "manual"
            if members.isEmpty && !isManual && c.is_hidden == 0 { continue }
            out.append(MaterializedCollection(
                id: c.id, name: c.name, sortOrder: c.sort_order,
                modelVersion: c.model_version, isHidden: c.is_hidden,
                coverFileID: c.cover_path.flatMap { fileIDForPath[$0] }
                    ?? c.cover_hash.flatMap { fileIDForHash[$0] },
                memberFileIDs: members,
                excludedFileIDs: c.excluded_paths.map { $0.compactMap { fileIDForPath[$0] } }
                    ?? c.excluded_hashes.compactMap { fileIDForHash[$0] },
                icon: c.icon, color: c.color, smartRules: c.smart_rules))
        }
        return out
    }
}
