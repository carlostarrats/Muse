//
//  AppState+Starring.swift
//  Muse
//
//  Starred-folder (pin) actions. Extracted from AppState.swift in the
//  2026-06-20 code-health refactor (methods only; `startedStarredScopes` stays
//  in the core file as a stored property).
//

import Foundation

@MainActor
extension AppState {
    func toggleStar(folder: FolderNode) {
        if stars.isStarred(folder.url) {
            stars.unstar(folder: folder.url)
        } else {
            stars.star(folder: folder.url)
        }
    }

    func openStarred(_ star: StarStore.StarredFolder) {
        guard let url = stars.resolveURL(for: star) else { return }
        let path = url.standardizedFileURL.path
        // Start the scope once per distinct path, and only RECORD it as started
        // when the start actually succeeds — so a transient first-open failure
        // doesn't permanently skip the retry on a later open this session.
        if !startedStarredScopes.contains(path),
           url.startAccessingSecurityScopedResource() {
            startedStarredScopes.insert(path)
        }
        let node = FolderNode(url: url, displayName: star.displayName)
        select(folder: node)
    }
}
