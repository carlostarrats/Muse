//
//  BackupBuilder.swift
//  Muse
//
//  Reads the live DB and assembles a portable BackupArchive. Re-keys all
//  collection membership/cover from the per-machine FileRow.id to content_hash.
//
//  Backup is deliberately NOT an `OutputRender` consumer — the one exclusion
//  from "everything that leaves the app renders through OutputRender". This
//  archive restores ORIGINALS, matched by content hash; rendering an edit stack
//  into it would change the bytes the restore identifies files by and corrupt
//  the restore. Edits travel as their own stack data, never as baked pixels.
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

            // Notes grouped by (file_id, parent_dir), same key shape as tags.
            let noteRows = try NoteRow.fetchAll(db)
            var noteByFileDir: [String: String] = [:]
            for n in noteRows {
                noteByFileDir["\(n.file_id)\u{1}\(n.parent_dir)"] = n.body
            }

            // Edit stacks grouped by (file_id, parent_dir) — the same grain and
            // the same key shape as tags and notes, because an edit shares
            // their identity exactly. A file with no row here is unedited and
            // simply contributes no edit fields to its occurrence.
            let editRows = try EditRow.fetchAll(db)
            var editByFileDir: [String: EditRow] = [:]
            for e in editRows {
                editByFileDir["\(e.file_id)\u{1}\(e.parent_dir)"] = e
            }
            let versionRows = try EditVersionRow.fetchAll(db)
            var versionsByFileDir: [String: [BackupEditVersion]] = [:]
            for v in versionRows {
                versionsByFileDir["\(v.file_id)\u{1}\(v.parent_dir)", default: []].append(
                    BackupEditVersion(kind: v.kind, name: v.name,
                                      stack: v.stack, created_at: v.created_at))
            }
            // Deterministic order so two backups of the same library produce
            // byte-identical archives.
            for key in versionsByFileDir.keys {
                versionsByFileDir[key]?.sort {
                    ($0.created_at, $0.stack) < ($1.created_at, $1.stack)
                }
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
                    // LONGEST matching prefix, not first match — with nested
                    // roots (/a and /a/b) a file under /a/b must attribute to
                    // /a/b, or restoring that root alone finds zero occurrences.
                    let rootPath = roots
                        .filter { p.absolute_path == $0.path
                            || p.absolute_path.hasPrefix($0.path + "/") }
                        .max(by: { $0.path.count < $1.path.count })?.path
                    let scopeKey = "\(fid)\u{1}\(parent)"
                    let edit = editByFileDir[scopeKey]
                    let versions = versionsByFileDir[scopeKey]
                    return BackupOccurrence(
                        original_path: p.absolute_path,
                        basename: url.lastPathComponent,
                        root_path: rootPath,
                        parent_dir: parent,
                        tags: tagsByFileDir[scopeKey] ?? [],
                        note: noteByFileDir[scopeKey],
                        edit_stack: edit?.stack,
                        edit_updated_at: edit?.updated_at,
                        // Empty stays nil rather than `[]` so an unedited
                        // occurrence encodes exactly as it did pre-A2.
                        edit_versions: (versions?.isEmpty ?? true) ? nil : versions)
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
            // The occurrence a file_id names. Under per-file identity that is
            // exactly one alive path, which is what makes path-keyed membership
            // unambiguous; `min` keeps it deterministic if the invariant is ever
            // violated. A hash can't do this job — two copies share it.
            func backupPath(forFileID fid: String) -> String? {
                guard backupHash(forFileID: fid) != nil else { return nil }
                return pathsByFileID[fid]?.map(\.absolute_path).min()
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
                // The same three facts keyed on the occurrence instead of the
                // content — the view that can tell two byte-identical copies
                // apart. Sorted so an archive is byte-stable.
                let memberPaths = memberRows.compactMap { m -> BackupPathMember? in
                    guard let p = backupPath(forFileID: m.file_id) else { return nil }
                    return BackupPathMember(original_path: p, added_by: m.added_by)
                }.sorted { $0.original_path < $1.original_path }
                let excludedPaths = try String.fetchAll(db, sql:
                    "SELECT file_id FROM collection_exclusions WHERE collection_id = ?",
                    arguments: [c.id]).compactMap { backupPath(forFileID: $0) }.sorted()
                collections.append(BackupCollection(
                    id: c.id, name: c.name, sort_order: c.sort_order,
                    model_version: c.model_version, is_hidden: c.is_hidden,
                    cover_hash: coverHash, members: members, excluded_hashes: excluded,
                    icon: c.icon, color: c.color, smart_rules: c.smart_rules,
                    member_paths: memberPaths, excluded_paths: excludedPaths,
                    cover_path: c.cover_file_id.flatMap { backupPath(forFileID: $0) }))
            }

            let starRows = try StarredFolderRow.fetchAll(db)
            let stars = starRows.map { BackupStar(path: $0.absolute_path, display_name: $0.display_name) }

            // Library-global edit assets. Sorted for byte-stable archives.
            // Presets and LUTs are carried WHOLESALE rather than only the ones
            // a restored stack happens to reference: a preset is the user's own
            // saved look and a LUT they imported, and a backup that restored
            // photos but emptied the Looks browser would read as data loss.
            let presets = try EditPresetRow.fetchAll(db)
                .map { BackupEditPreset(id: $0.id, name: $0.name, stack: $0.stack,
                                        created_at: $0.created_at, updated_at: $0.updated_at) }
                .sorted { $0.id < $1.id }
            let luts = try EditLutRow.fetchAll(db)
                .map { BackupLut(id: $0.id, name: $0.name, size: $0.size, data: $0.data) }
                .sorted { $0.id < $1.id }

            return BackupArchive(
                schema: BackupArchive.currentSchema, created_at: createdAt,
                app_version: appVersion, roots: roots, files: files,
                collections: collections, stars: stars,
                edit_presets: presets.isEmpty ? nil : presets,
                edit_luts: luts.isEmpty ? nil : luts)
        }
    }
}
