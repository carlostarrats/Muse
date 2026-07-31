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
        // Supersede the predecessor BEFORE starting: the token guard below
        // stops a stale result from LANDING, but only this stops it from being
        // COMPUTED — the semantic leg walks every embedding row in the library,
        // so typing a second query used to pay for the first one in full.
        inFlightSearchCancellation?.cancel()
        let cancellation = SearchCancellation()
        inFlightSearchCancellation = cancellation
        let results = await SearchService.search(query: trimmed, scope: scope,
                                                 cancellation: cancellation)
        // A newer search — or clearSearch() — invalidates this stale result.
        guard token == searchRequestToken else { return }
        // Search narrows visibleFiles to a different scope (the global/folder
        // result set), so drop the prior selection — otherwise a folder-selected
        // file that isn't in the results stays in selectedFiles and rides into
        // Move/Delete/Collection/Tag/Share via effectiveSelectionURLs (which
        // rebuilds URLs for off-view paths). Mirrors select(folder:)/
        // setActiveCollection/setActiveTags, the other scope-change inputs.
        clearSelection()
        isSearchActive = true
        // Post-search, non-blocking: offer the model once, and let the
        // natural-language layer propose a token rewrite. Neither delays the
        // results the user is already looking at.
        considerSearchModelOffer(for: trimmed)
        NLQuerySuggest.shared.consider(query: trimmed)
        // search results keep relevance rank; sort modes apply to folder browsing only
        currentFiles = results
        // Chip labels derive from the search result set (tagSourceFiles is
        // search-aware) so the offered chips stay relevant while searching.
        reloadTagChips()
    }

    func clearSearch() {
        searchRequestToken += 1   // cancel any in-flight search result
        inFlightSearchCancellation?.cancel()
        inFlightSearchCancellation = nil
        searchQuery = ""
        isSearchActive = false
        reloadCurrentFiles()
    }

    /// The one-time "Smarter Search" offer: a plain multi-word query that
    /// resolved to NO tokens is exactly the query semantic search would
    /// improve, so that's when it's worth asking.
    private func considerSearchModelOffer(for query: String) {
        guard ClipModelStore.shared.state == .absent,
              !UserDefaults.standard.bool(forKey: AppSettings.clipOfferSeenKey) else { return }
        let parsed = SearchQueryParser.parse(query)
        guard parsed.tokens.isEmpty,
              parsed.freeText.split(separator: " ").count >= NLQuerySuggest.minWords else { return }
        clipOfferShown = true
    }
}
