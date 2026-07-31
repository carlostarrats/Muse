//
//  AppState+Rediscovery.swift
//  Muse
//
//  Rediscovery orchestration — methods only. AppState gains no new stored
//  state; RediscoveryStore.shared IS the state.
//
//  Context-switch teardown parity is mandatory here: a surface is a content
//  scope like a collection, so opening one must clear the others and clear the
//  selection (the narrows-visibleFiles rule).
//

import Foundation

@MainActor
extension AppState {
    /// Standardized active root paths — the root filter every root-scoped
    /// surface shares.
    var rootPathList: [String] {
        rootNodes.map { $0.url.standardizedFileURL.path }
    }

    func openRediscovery(_ surface: RediscoverySurface) {
        clearSelection()
        setActiveCollection(nil)
        showingCollections = false
        PlacesStore.shared.setShowing(false)
        RediscoveryStore.shared.activate(surface, roots: rootPathList)
    }

    func closeRediscovery() {
        clearSelection()
        RediscoveryStore.shared.dismiss()
    }
}
