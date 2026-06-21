//
//  AppState+Search.swift
//  Muse
//
//  FTS5 + tag-label search wiring. Extracted from AppState.swift in the
//  2026-06-20 code-health refactor (methods only; `searchRequestToken` stays
//  in the core AppState file because the folder-selection path also bumps it).
//

import Foundation

@MainActor
extension AppState {
    func runSearch(_ query: String) async {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            clearSearch()
            return
        }
        searchRequestToken += 1
        let token = searchRequestToken
        // Scope follows the magnifier menu: "All" searches the whole indexed
        // library; "This folder" (default) scopes to the selected folder, and
        // falls back to everywhere when nothing is selected.
        let scope: SearchScope
        if !searchAllFolders, let folder = selectedFolder {
            scope = .currentFolder(folder.url)
        } else {
            scope = .everywhere
        }
        let results = await SearchService.search(query: trimmed, scope: scope)
        // A newer search — or clearSearch() — invalidates this stale result.
        guard token == searchRequestToken else { return }
        isSearchActive = true
        // search results keep relevance rank; sort modes apply to folder browsing only
        currentFiles = results
        // Chip labels derive from the search result set (tagSourceFiles is
        // search-aware) so the offered chips stay relevant while searching.
        reloadTagChips()
    }

    func clearSearch() {
        searchRequestToken += 1   // cancel any in-flight search result
        searchQuery = ""
        isSearchActive = false
        reloadCurrentFiles()
    }
}
