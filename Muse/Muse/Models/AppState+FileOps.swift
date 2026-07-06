//
//  AppState+FileOps.swift
//  Muse
//
//  In-app FILE rename. A rename is a KNOWN relocation (a move whose destination
//  dir equals the source dir with a new basename), so it routes through the same
//  migration seam as moveFiles: disk rename OFF-MAIN via FileMover.rename, then
//  FileMoveMigration.apply (reused verbatim — the same-dir case repoints the path
//  row and leaves the (file_id, parent_dir) tags in place), then reloadAfterMove.
//  The extension is LOCKED (only the base name is editable); collision REFUSES.
//

import Foundation

@MainActor
extension AppState {

    /// Present the rename modal for `node` (files only — a folder card routes to
    /// requestRenameFolder). The alert seeds its local draft with the file's stem
    /// (basename minus locked extension) on open; see FileRenameAlert.
    func requestRenameFile(_ node: FileNode) {
        guard node.kind != .folder else { return }
        fileRenameRequest = node
    }

    /// Rename `node` on disk to `newStem` + its LOCKED extension, then migrate the
    /// path row + carry tags/memberships (FileMoveMigration) and reload. Refuses a
    /// name collision (names the file) and an invalid name; never overwrites.
    func renameFile(_ node: FileNode, to newStem: String) {
        let (_, ext) = FileNameSplit.split(node.basename)
        let full: String
        switch FileNameSplit.validate(stem: newStem, ext: ext, originalName: node.basename) {
        case .failure(let e):
            fileRenameError = Self.renameMessage(for: e)
            return
        case .success(let name):
            full = name
        }
        // No-op: same name, nothing to do.
        guard full != node.basename else { return }

        let target = node.url.deletingLastPathComponent().appendingPathComponent(full)
        // Collision refusal (owner: name the file, never overwrite / auto-suffix).
        // Allow a case-only change (Photo.jpg -> photo.jpg) on a case-insensitive
        // volume, which "collides with itself".
        let caseOnly = target.standardizedFileURL.path.lowercased()
            == node.url.standardizedFileURL.path.lowercased()
        if !caseOnly && FileManager.default.fileExists(atPath: target.path) {
            fileRenameError = String(localized: "A file named “\(full)” already exists in this folder.")
            return
        }

        Task { @MainActor in
            // Disk rename off-main (symmetric with moveFiles).
            let newURL = await Task.detached(priority: .userInitiated) {
                FileMover.rename(node.url, to: full)
            }.value
            guard let newURL else {
                fileRenameError = String(localized: "Couldn’t rename the file.")
                return
            }
            let from = node.url.standardizedFileURL.path
            let to = newURL.standardizedFileURL.path
            if from != to, let queue = Database.shared.dbQueue {
                do {
                    try await queue.write { db in
                        try FileMoveMigration.apply(db, moves: [(from, to)])
                    }
                } catch {
                    // The disk rename already happened; a failed migration only
                    // degrades to external-move semantics (vision-only tag inherit
                    // after reconcile) — log it, don't fail the rename.
                    print("[AppState] rename DB migration failed: \(error)")
                }
                // Keep the iCloud sidecar current if the file lives in the zone
                // (no-op otherwise; same rule as moveFiles / every TagStore edit).
                AnalyzePipeline.shared.exportSidecarsAfterTagEdit(for: [newURL])
            }
            // Reuse the move tail: clears selection, dismisses a hero showing the
            // old path, re-resolves the active collection, reloads the folder.
            reloadAfterMove(failed: [])
        }
    }

    /// User-facing copy for a rename shape-validation failure.
    private static func renameMessage(for error: RenameNameError) -> String {
        switch error {
        case .empty:            return String(localized: "Please enter a name.")
        case .invalidCharacter: return String(localized: "A file name can’t contain “/” or “:”.")
        case .wouldHide:        return String(localized: "That name would hide the file. A name starting with a dot makes the file hidden.")
        }
    }
}
