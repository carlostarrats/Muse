import Foundation
import GRDB

/// Everything the viewer's info column needs about one file, loaded in one read.
struct ViewerFileDetails {
    var fileID: String
    var pixelSize: CGSize?
    var sizeBytes: Int64?
    var dominantColor: String?
    var palette: [String]
    var tags: [TagRow]
    var collections: [CollectionRow]
    /// User-authored note for this file IN THIS FOLDER ("" if none).
    var note: String

    static func load(queue: DatabaseQueue, path: String) async throws -> ViewerFileDetails? {
        try await queue.read { db -> ViewerFileDetails? in
            guard let p = try PathRow
                    .filter(Column("absolute_path") == path && Column("is_alive") == 1)
                    .fetchOne(db),
                  let fid = p.file_id,
                  let f = try FileRow.fetchOne(db, key: fid) else { return nil }
            let palette: [String] = f.palette
                .flatMap { $0.data(using: .utf8) }
                .flatMap { try? JSONDecoder().decode([String].self, from: $0) } ?? []
            // Tags are per-folder: scope to THIS file's folder so the viewer
            // never shows (or, via the remove-pill, deletes) a duplicate's tags
            // from another folder. `path` is the stored absolute_path matched
            // above, so its parent matches the tags' parent_dir key.
            let dir = TagScope.parentDir(ofPath: path)
            let tags = try TagRow
                .filter(Column("file_id") == fid && Column("parent_dir") == dir)
                .order(Column("label")).fetchAll(db)
            let cols = try CollectionRow.fetchAll(db, sql: """
                SELECT c.* FROM collections c
                JOIN collection_members m ON m.collection_id = c.id
                WHERE m.file_id = ? AND c.is_hidden = 0
                """, arguments: [fid])
            let note = try NoteStore.read(fileID: fid, parentDir: dir, db: db) ?? ""
            var size: CGSize? = nil
            if let w = f.width, let h = f.height { size = CGSize(width: w, height: h) }
            return ViewerFileDetails(fileID: fid, pixelSize: size, sizeBytes: f.size_bytes,
                                     dominantColor: f.dominant_color, palette: palette,
                                     tags: tags, collections: cols, note: note)
        }
    }
}
