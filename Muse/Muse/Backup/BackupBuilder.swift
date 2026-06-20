//
//  BackupBuilder.swift
//  Muse
//
//  Reads the live DB and assembles a portable BackupArchive. Re-keys all
//  collection membership/cover from the per-machine FileRow.id to content_hash.
//

import Foundation
import GRDB

enum BackupBuilder {
    static func build(queue: DatabaseQueue, roots: [BackupRoot],
                      createdAt: Int64, appVersion: String?) async throws -> BackupArchive {
        try await queue.read { db in
            // file_id -> content_hash (only files that HAVE a hash)
            let fileRows = try FileRow.fetchAll(db)
            var hashByFileID: [String: String] = [:]
            var fileByID: [String: FileRow] = [:]
            for f in fileRows {
                fileByID[f.id] = f
                if let h = f.content_hash { hashByFileID[f.id] = h }
            }

            // Alive paths grouped by file_id.
            let alive = try PathRow.filter(PathRow.Columns.is_alive == 1).fetchAll(db)
            var pathsByFileID: [String: [PathRow]] = [:]
            for p in alive where p.file_id != nil {
                pathsByFileID[p.file_id!, default: []].append(p)
            }

            // Tags grouped by (file_id, parent_dir).
            let tagRows = try TagRow.fetchAll(db)
            var tagsByFileDir: [String: [SidecarTag]] = [:]   // key "file_id\u{1}parent_dir"
            for t in tagRows {
                let key = "\(t.file_id)\u{1}\(t.parent_dir ?? "")"
                tagsByFileDir[key, default: []].append(
                    SidecarTag(label: t.label, source: t.source,
                               confidence: t.confidence, model_version: t.model_version))
            }

            // Build BackupFile per content-hashed file that has >=1 alive path.
            var files: [BackupFile] = []
            for (fid, file) in fileByID {
                guard let hash = file.content_hash,
                      let paths = pathsByFileID[fid], !paths.isEmpty else { continue }
                guard let meta = Sidecar.build(from: file, tags: [], updatedAt: file.last_seen_at)
                    else { continue }
                let occurrences = paths.map { p -> BackupOccurrence in
                    let url = URL(fileURLWithPath: p.absolute_path)
                    let parent = url.deletingLastPathComponent().path
                    let rootPath = roots.first { p.absolute_path == $0.path
                        || p.absolute_path.hasPrefix($0.path + "/") }?.path
                    return BackupOccurrence(
                        original_path: p.absolute_path,
                        basename: url.lastPathComponent,
                        root_path: rootPath,
                        parent_dir: parent,
                        tags: tagsByFileDir["\(fid)\u{1}\(parent)"] ?? [])
                }
                files.append(BackupFile(content_hash: hash, meta: meta, occurrences: occurrences))
            }
            files.sort { $0.content_hash < $1.content_hash }

            // Only content that's actually reconnectable (has an alive path, so it
            // made it into `files`) is referenceable by a collection. A member whose
            // file has no alive path can't reconnect anyway, so dropping it keeps the
            // archive internally consistent (every member hash has a BackupFile).
            let backedUp = Set(files.map { $0.content_hash })
            func backupHash(forFileID fid: String) -> String? {
                guard let h = hashByFileID[fid], backedUp.contains(h) else { return nil }
                return h
            }

            // Collections, members/cover/exclusions re-keyed to content_hash.
            let collRows = try CollectionRow.fetchAll(db)
            var collections: [BackupCollection] = []
            for c in collRows {
                let memberRows = try CollectionMemberRow
                    .filter(Column("collection_id") == c.id).fetchAll(db)
                let members = memberRows.compactMap { m -> BackupMember? in
                    guard let h = backupHash(forFileID: m.file_id) else { return nil }
                    return BackupMember(content_hash: h, added_by: m.added_by)
                }
                let excluded = try String.fetchAll(db, sql:
                    "SELECT file_id FROM collection_exclusions WHERE collection_id = ?",
                    arguments: [c.id]).compactMap { backupHash(forFileID: $0) }
                let coverHash = c.cover_file_id.flatMap { backupHash(forFileID: $0) }
                collections.append(BackupCollection(
                    id: c.id, name: c.name, sort_order: c.sort_order,
                    model_version: c.model_version, is_hidden: c.is_hidden,
                    cover_hash: coverHash, members: members, excluded_hashes: excluded))
            }

            let starRows = try StarredFolderRow.fetchAll(db)
            let stars = starRows.map { BackupStar(path: $0.absolute_path, display_name: $0.display_name) }

            return BackupArchive(
                schema: BackupArchive.currentSchema, created_at: createdAt,
                app_version: appVersion, roots: roots, files: files,
                collections: collections, stars: stars)
        }
    }
}
