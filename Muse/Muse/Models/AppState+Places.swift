//
//  AppState+Places.swift
//  Muse
//
//  Places page orchestration — methods only (the house rule for
//  AppState+*.swift). AppState gains no stored state: PlacesStore.shared IS
//  the state.
//

import Foundation

@MainActor
extension AppState {
    func openPlacesPage() {
        clearSelection()
        setActiveCollection(nil)
        showingCollections = false
        RediscoveryStore.shared.dismiss()
        PlacesStore.shared.setShowing(true)
        Task { await PlacesStore.shared.reload() }
    }

    func closePlacesPage() {
        PlacesStore.shared.setShowing(false)
    }

    /// Click-through from a place group: a programmatic `near:` token search,
    /// NOT a fourth `visibleFiles` substitution. One navigation system, and it
    /// dog-foods the token engine. The lost sort control inside a place is the
    /// same accepted tradeoff search already makes.
    func openPlaceSearch(_ group: PlaceGroup) {
        closePlacesPage()
        searchAllFolders = true
        // Quoted: a city name with spaces has to stay one token.
        let query = "near:\"\(group.city)\""
        searchQuery = query
        Task { await runSearch(query) }
    }
}
