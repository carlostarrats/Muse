//
//  ReconnectApplier.swift
//  Muse
//
//  Writes backup metadata onto the rows the indexer already created (joined by
//  content hash / disk path), then materializes collections + stars. The live
//  library only ever gains REAL, reconnected files — never ghosts.
//

import Foundation
import GRDB

// `nonisolated`: every member drives a GRDB queue closure — restore work must
// not run on the main actor.
nonisolated enum ReconnectApplier {
    /// content_hash -> files.id for every hashed file currently in the DB.
    static func currentFileIDForHash(queue: DatabaseQueue) async throws -> [String: String] {
        try await queue.read { db in
            var map: [String: String] = [:]
            for f in try FileRow.fetchAll(db) where f.content_hash != nil {
                map[f.content_hash!] = f.id
            }
            return map
        }
    }

    static func applyMeta(matches: [OccurrenceMatch], file: BackupFile,
                          queue: DatabaseQueue) async throws {
        for m in matches {
            let url = URL(fileURLWithPath: m.diskPath)
            let parentDir = url.deletingLastPathComponent().path
            let basename = url.lastPathComponent
            try await queue.write { db in
                guard let path = try PathRow
                        .filter(PathRow.Columns.absolute_path == m.diskPath)
                        .filter(PathRow.Columns.is_alive == 1).fetchOne(db),
                      let fid = path.file_id,
                      var fileRow = try FileRow.filter(FileRow.Columns.id == fid).fetchOne(db)
                else { return }
                file.meta.apply(onto: &fileRow)
                try fileRow.update(db)
                // A rating is a manual tag but is MUTUALLY EXCLUSIVE, and the
                // insert below only skips a tag whose EXACT label already
                // exists — so restoring "★★★★" onto a file the user has since
                // rated "★★" would leave it carrying two, breaking
                // `StarRating.resolution`. A restore is an explicit user action
                // to reinstate the backed-up state, so the backup's rating
                // REPLACES the local one (unlike passive sidecar hydration,
                // which yields to a rating already set on this device).
                let incomingRatings = Sidecar.collapsingRatings(m.occurrence.tags)
                    .filter { StarRating.isRating($0.label) }
                if incomingRatings.isEmpty == false {
                    for existing in try TagRow
                        .filter(TagRow.Columns.file_id == fid)
                        .filter(TagRow.Columns.parent_dir == parentDir)
                        .fetchAll(db) where StarRating.isRating(existing.label) {
                        _ = try existing.delete(db)
                    }
                }
                // Tags: occurrence's tags at the NEW parent_dir (manual beats vision).
                // Ratings collapsed to one first, in case the archive itself
                // carries a pre-fix double rating.
                for t in tagRows(from: Sidecar.collapsingRatings(m.occurrence.tags),
                                 fileID: fid, parentDir: parentDir) {
                    if let existing = try TagRow
                        .filter(TagRow.Columns.file_id == fid)
                        .filter(TagRow.Columns.parent_dir == parentDir)
                        .filter(TagRow.Columns.label == t.label).fetchOne(db) {
                        if existing.source != "manual" && t.source == "manual" {
                            var u = existing; u.source = "manual"; u.confidence = nil
                            u.model_version = nil; try u.update(db)
                        }
                    } else {
                        var row = t; try row.insert(db)
                    }
                }
                // Note: apply the occurrence's note at the NEW parent_dir.
                if let body = m.occurrence.note {
                    try NoteStore.write(body, fileID: fid, parentDir: parentDir,
                                        updatedAt: Int64(Date().timeIntervalSince1970), db: db)
                }
                // Edit stack: same grain, same NEW parent_dir, same
                // restore-wins rule as the note and the rating above. Absent
                // means the file was unedited when the backup was taken — and
                // absence is deliberately NOT a reset: it leaves any local edit
                // alone rather than deleting work the archive simply predates.
                if let stack = m.occurrence.edit_stack {
                    try EditRecordStore.applyRestored(
                        json: stack,
                        updatedAt: m.occurrence.edit_updated_at
                            ?? Int64(Date().timeIntervalSince1970),
                        fileID: fid, parentDir: parentDir, db: db)
                }
                // Versions/snapshots insert with FRESH UUIDs — the archive's own
                // ids may already belong to a different local row, so they are
                // not identity here. But a fresh id per insert would make a
                // SECOND restore of the same archive duplicate every version,
                // so identity is the CONTENT: (kind, name, stack, created_at) at
                // this scope. Re-running Restore is then idempotent, which is
                // the rule the rest of this file follows.
                //
                // The existing-versions read is INSIDE the emptiness guard on
                // purpose: almost no file in a library carries versions, and
                // hoisting it out would put one extra query on every single
                // matched occurrence of a whole-library restore.
                let incomingVersions = m.occurrence.edit_versions ?? []
                if !incomingVersions.isEmpty {
                    let existingVersions = try EditRecordStore.versions(
                        fileID: fid, parentDir: parentDir, db: db)
                    for v in incomingVersions {
                        let name = v.name ?? ""
                        let alreadyHere = existingVersions.contains {
                            $0.kind == v.kind && $0.name == name
                                && $0.stack == v.stack && $0.created_at == v.created_at
                        }
                        guard !alreadyHere else { continue }
                        var row = EditVersionRow(
                            id: UUID().uuidString, file_id: fid, parent_dir: parentDir,
                            kind: v.kind, name: name, stack: v.stack,
                            created_at: v.created_at)
                        try row.insert(db)
                    }
                }
                // FTS mirror (basename + caption; OCR intentionally empty — same as hydrate).
                try db.execute(sql: "DELETE FROM files_fts WHERE file_id = ?", arguments: [fid])
                try db.execute(sql: """
                    INSERT INTO files_fts(file_id, basename, ocr_text, caption)
                    VALUES (?, ?, ?, ?)
                    """, arguments: [fid, basename, "", file.meta.caption ?? ""])
            }
        }
    }

    private static func tagRows(from tags: [SidecarTag], fileID: String,
                                parentDir: String) -> [TagRow] {
        tags.map {
            TagRow(id: UUID().uuidString, file_id: fileID, parent_dir: parentDir,
                   label: $0.label, source: $0.source, confidence: $0.confidence,
                   model_version: $0.model_version)
        }
    }

    /// `diskPathForOriginal` maps each archived occurrence path to where that
    /// file actually landed — a restore may reconnect a library at a new
    /// location. Resolving those to row ids is what lets membership be restored
    /// per FILE; without it two byte-identical copies both join every
    /// collection either was in.
    static func applyCollections(_ archive: BackupArchive, fileIDForHash: [String: String],
                                 diskPathForOriginal: [String: String] = [:],
                                 queue: DatabaseQueue) async throws {
        let fileIDForPath = try await queue.read { db -> [String: String] in
            var map: [String: String] = [:]
            for (original, disk) in diskPathForOriginal {
                guard let fid = try String.fetchOne(db, sql: """
                    SELECT file_id FROM paths WHERE absolute_path = ? AND is_alive = 1
                    """, arguments: [disk]) else { continue }
                map[original] = fid
            }
            return map
        }
        let materialized = CollectionMaterializer.materialize(archive.collections,
                                                              fileIDForHash: fileIDForHash,
                                                              fileIDForPath: fileIDForPath)
        let now = Int64(Date().timeIntervalSince1970)
        try await queue.write { db in
            for c in materialized {
                try db.execute(sql: """
                    INSERT INTO collections (id, name, is_hidden, model_version, created_at, updated_at, cover_file_id, sort_order, icon, color, smart_rules)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET name = excluded.name,
                        is_hidden = excluded.is_hidden, model_version = excluded.model_version,
                        cover_file_id = excluded.cover_file_id, sort_order = excluded.sort_order,
                        icon = excluded.icon, color = excluded.color,
                        smart_rules = excluded.smart_rules,
                        updated_at = excluded.updated_at
                    """, arguments: [c.id, c.name, c.isHidden, c.modelVersion, now, now,
                                     c.coverFileID, c.sortOrder, c.icon, c.color, c.smartRules])
                try db.execute(sql: "DELETE FROM collection_members WHERE collection_id = ?",
                               arguments: [c.id])
                for m in c.memberFileIDs {
                    try db.execute(sql: """
                        INSERT OR IGNORE INTO collection_members (collection_id, file_id, added_by)
                        VALUES (?, ?, ?)
                        """, arguments: [c.id, m.fileID, m.addedBy])
                }
                try db.execute(sql: "DELETE FROM collection_exclusions WHERE collection_id = ?",
                               arguments: [c.id])
                for ex in c.excludedFileIDs {
                    try db.execute(sql: """
                        INSERT OR IGNORE INTO collection_exclusions (collection_id, file_id)
                        VALUES (?, ?)
                        """, arguments: [c.id, ex])
                }
            }
        }
    }

    /// Library-global edit assets: saved presets and imported LUTs.
    ///
    /// Both are `INSERT OR IGNORE`, for different reasons that land in the same
    /// place. A LUT's primary key IS the SHA-256 of its bytes, so ignoring a
    /// conflict is the IMMUTABILITY rule doing its job — a re-restore can never
    /// rewrite LUT data, and a name collision on identical bytes keeps the
    /// name already in the library. A preset conflicts only on its own UUID,
    /// i.e. only when this exact preset is already here, so ignoring leaves the
    /// user's current version of their own look alone.
    ///
    /// Returns the LUT ids actually present after the write, so the caller can
    /// invalidate the render-path cache for them.
    @discardableResult
    static func applyEditAssets(_ archive: BackupArchive,
                                queue: DatabaseQueue) async throws -> [String] {
        let presets = archive.edit_presets ?? []
        // A `.muselibrary` is a file the user picked off disk, and these rows go
        // in by a plain INSERT — so the archive is the one place a `(size, blob)`
        // pair that does NOT describe a real cube can enter the table. The render
        // path hands the pair to `CIColorCubeWithColorSpace`, which reads
        // size³ × 4 floats out of the buffer without checking. `LutRegistry`
        // refuses such a row too, so this is belt-and-braces; the reason to do it
        // HERE as well is that a row nobody can render is dead weight the user
        // sees in the Looks browser and cannot explain.
        let luts = (archive.edit_luts ?? []).filter {
            CubeLUT.isRenderableStoredCube(size: $0.size, byteCount: $0.data.count)
                && CubeLUT.storedCubeIsFinite($0.data)
        }
        guard !presets.isEmpty || !luts.isEmpty else { return [] }
        let now = Int64(Date().timeIntervalSince1970)
        try await queue.write { db in
            for p in presets {
                try db.execute(sql: """
                    INSERT OR IGNORE INTO edit_presets (id, name, stack, created_at, updated_at)
                    VALUES (?, ?, ?, ?, ?)
                    """, arguments: [p.id, p.name, p.stack, p.created_at, p.updated_at])
            }
            for l in luts {
                try db.execute(sql: """
                    INSERT OR IGNORE INTO edit_luts (id, name, size, data, created_at)
                    VALUES (?, ?, ?, ?, ?)
                    """, arguments: [l.id, l.name, l.size, l.data, now])
            }
        }
        return luts.map(\.id)
    }

    static func applyStars(_ archive: BackupArchive, queue: DatabaseQueue) async throws {
        // Existence is checked HERE, not inside the write: `FileManager` is
        // non-Sendable, so capturing it in the @Sendable closure is a data race.
        let fm = FileManager.default
        let present = archive.stars.filter { fm.fileExists(atPath: $0.path) }
        try await queue.write { db in
            for s in present {
                try db.execute(sql: """
                    INSERT OR IGNORE INTO starred_folders (id, absolute_path, display_name, added_at)
                    VALUES (?, ?, ?, ?)
                    """, arguments: [UUID().uuidString, s.path, s.display_name,
                                     Int64(Date().timeIntervalSince1970)])
            }
        }
    }
}
