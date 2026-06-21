//
//  AppState+TagChips.swift
//  Muse
//
//  Tag-chip label loading for the current scope. Extracted from AppState.swift
//  in the 2026-06-20 code-health refactor (methods only; `tagChipToken` stays
//  in the core file as a stored property).
//

import Foundation
import SwiftUI

@MainActor
extension AppState {
    /// Recompute the tag-chip labels for the CURRENT scope (the active
    /// collection's members, else the selected folder) off the main thread, then
    /// publish them. The shared entry point for collection changes, tag edits,
    /// and live folder reloads. A fresh folder SELECT instead computes the chips
    /// inline in `reloadCurrentFiles`, so files + chips reveal together (and that
    /// path, not this one, manages the `tagRowReady` gate).
    /// `sortModeOverride` is supplied by the `$tagSortMode` sink: `@Published`
    /// fires in `willSet`, so when the sink runs `self.tagSortMode` still holds
    /// the OLD value — reading it here would order the chips one selection
    /// behind (the "backwards" bug). The sink passes the delivered new value;
    /// every other caller reads the (already-committed) property.
    func reloadTagChips(sortModeOverride: TagSortMode? = nil) {
        tagChipToken &+= 1
        let token = tagChipToken
        let scope = tagSourceFiles
        let recursive = showSubfolders
        let inCollection = activeCollectionID != nil
        guard let queue = Database.shared.dbQueue, !scope.isEmpty else {
            tagChipRows = []
            return
        }
        let paths = scope.map { $0.url.standardizedFileURL.path }
        // Search results can span folders, so the single-folder GROUP BY fast
        // path doesn't apply — fall to the general per-file-scope query.
        let simpleDir = (!inCollection && !recursive && !isSearchActive)
            ? TagScope.parentDir(ofPath: paths[0]) : nil
        let tagSort = sortModeOverride ?? tagSortMode
        Task.detached(priority: .userInitiated) {
            let rows = TagChipLoader.ordered(
                TagChipLoader.counts(paths: paths, simpleFolderDir: simpleDir, queue: queue),
                sortMode: tagSort)
            await MainActor.run {
                guard token == self.tagChipToken else { return }
                withAnimation(.easeInOut(duration: AppState.navTransition)) {
                    self.tagChipRows = rows
                }
            }
        }
    }

    /// Not `private`: the inline chip computation in `reloadCurrentFiles` (core)
    /// also bumps the token.
    func bumpTagChipToken() { tagChipToken &+= 1 }
}
