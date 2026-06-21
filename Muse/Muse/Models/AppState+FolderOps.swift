//
//  AppState+FolderOps.swift
//  Muse
//
//  Folder management — create/rename subfolders + the DB path migration and
//  the new-subfolder/rename dialog requests. Extracted from AppState.swift in
//  the 2026-06-20 code-health refactor (methods only; stored state stays core).
//

import Foundation

@MainActor
extension AppState {
    // MARK: - Folder dialog requests

    /// Present the New Subfolder dialog for `node` (empty draft).
    func requestNewSubfolder(_ node: FolderNode) {
        folderNameDraft = ""
        newSubfolderRequest = node
    }

    /// Present the Rename dialog for `node` (draft pre-filled with its name).
    func requestRenameFolder(_ node: FolderNode) {
        folderNameDraft = node.displayName
        folderRenameRequest = node
    }

    // MARK: - Folder management

    /// Create a subfolder inside `node` on disk, then refresh the tree and
    /// drill into the new folder. Surfaces failures via `folderOpError`.
    func createSubfolder(named name: String, in node: FolderNode) {
        switch FolderOps.createSubfolder(named: name, in: node.url) {
        case .failure(let e):
            folderOpError = Self.message(for: e, verb: "create")
        case .success:
            // Reveal the new folder in the sidebar but DON'T navigate into it —
            // the user stays on whatever they're currently viewing.
            node.reloadChildren()
            node.isExpanded = true
        }
    }

    /// Rename `node`'s folder on disk and migrate the index + tags + pins so
    /// nothing is orphaned. Roots repoint their bookmark; subfolders reload from
    /// their parent. The iCloud home is never renamed (callers gate it).
    func renameFolder(_ node: FolderNode, to name: String) {
        let oldURL = node.url
        switch FolderOps.rename(oldURL, to: name) {
        case .failure(let e):
            folderOpError = Self.message(for: e, verb: "rename")
        case .success(let newURL):
            // No-op rename (same name) — FolderOps returns the original URL.
            guard newURL.standardizedFileURL != oldURL.standardizedFileURL else { return }
            let oldPath = oldURL.standardizedFileURL.path
            let newPath = newURL.standardizedFileURL.path

            // Sidebar refresh (disk already moved; these are synchronous).
            if node.isRoot, let root = bookmarks.roots.first(where: {
                bookmarks.url(for: $0) == oldURL
            }) {
                // rootRenamed mutates bookmarks.roots → the $roots sink rebuilds
                // rootNodes with the new URL/name.
                if !bookmarks.rootRenamed(root, to: newURL) {
                    folderOpError = "Couldn’t finish renaming the folder."
                }
            } else {
                node.parent?.reloadChildren()
            }

            // Does the active selection sit AT or UNDER the renamed folder?
            // (renaming an ancestor of the open folder must follow it, not
            // strand the grid on a now-nonexistent path).
            let selPath = selectedFolder?.url.standardizedFileURL.path
            let selectedWasRoot = selectedFolder?.isRoot ?? false
            let newSelPath: String? = selPath.flatMap {
                FolderRenameMigration.rewrite(path: $0, old: oldPath, new: newPath)
            }

            // Migrate the DB FIRST, then reselect — the reselect triggers a
            // re-index of the new location, which must not run before the
            // path/tag rows are rewritten (a half-migrated state loses tags and
            // could collide on the alive-path unique index).
            Task { [weak self] in
                let ok = await Self.migratePaths(old: oldPath, new: newPath,
                                                 newName: newURL.lastPathComponent)
                guard let self else { return }
                if !ok {
                    self.folderOpError = "The folder was renamed, but updating its tags failed."
                }
                self.tagsVersion &+= 1
                self.stars.load()   // refresh pin paths/labels after migration
                if let newSelPath {
                    let url = URL(fileURLWithPath: newSelPath)
                    let node = self.findNode(withURL: url)
                        ?? FolderNode(url: url, isRoot: selectedWasRoot && newSelPath == newPath)
                    self.select(folder: node)
                }
            }
        }
    }

    /// Find a loaded node by URL across all root trees (best-effort; only walks
    /// already-loaded children). Used to reselect after a rename.
    private func findNode(withURL url: URL) -> FolderNode? {
        let target = url.standardizedFileURL
        func walk(_ n: FolderNode) -> FolderNode? {
            if n.url.standardizedFileURL == target { return n }
            for c in n.children { if let hit = walk(c) { return hit } }
            return nil
        }
        for r in rootNodes { if let hit = walk(r) { return hit } }
        return nil
    }

    /// Rewrite stored path prefixes after a folder rename (paths.absolute_path,
    /// tags.parent_dir, starred_folders) in one transaction. Off the main actor;
    /// returns false on failure so the caller can surface it. The actual SQL
    /// lives in `FolderRenameMigration.apply` so it is unit-testable.
    private static func migratePaths(old: String, new: String, newName: String) async -> Bool {
        guard let queue = Database.shared.dbQueue else { return false }
        do {
            try await queue.write { db in
                try FolderRenameMigration.apply(db, old: old, new: new, newName: newName)
            }
            return true
        } catch {
            return false
        }
    }

    /// User-facing folder-op error copy.
    private static func message(for error: FolderOps.OpError, verb: String) -> String {
        switch error {
        case .emptyName:   return "Please enter a folder name."
        case .invalidName: return "A folder name can’t contain “/” or “:”."
        case .collision:   return "A folder with that name already exists here."
        case .ioError:     return "Couldn’t \(verb) the folder. You may not have permission."
        }
    }
}
