//
//  AppState+Rating.swift
//  Muse
//
//  Star-rating wiring: recompute the per-file rating map for the current scope
//  (drives the tile badge), and set/clear the rating on the effective selection
//  (menu-bar command + context menu). A rating is a manual tag, so mutations go
//  through TagStore.setRating and bump tagsVersion like every tag edit.
//

import Foundation
import SwiftUI

@MainActor
extension AppState {

    /// Recompute `starRatings` for the current scope (active collection members,
    /// else the selected folder) off-main, then publish. Called from
    /// reloadTagChips() (every tag edit / collection change / live reload) and
    /// inline in the fresh-select branch of reloadCurrentFiles.
    func reloadStarRatings() {
        starRatingsToken &+= 1
        let token = starRatingsToken
        let scope = tagSourceFiles
        let recursive = showSubfolders
        let inCollection = activeCollectionID != nil
        guard let queue = Database.shared.dbQueue, !scope.isEmpty else {
            starRatings = [:]
            return
        }
        let paths = scope.map { $0.url.standardizedFileURL.path }
        let simpleDir = (!inCollection && !recursive && !isSearchActive)
            ? TagScope.parentDir(ofPath: paths[0]) : nil
        Task.detached(priority: .userInitiated) {
            let map = RatingLoader.ratings(paths: paths, simpleFolderDir: simpleDir, queue: queue)
            await MainActor.run {
                guard token == self.starRatingsToken else { return }
                self.starRatings = map
            }
        }
    }

    /// The rating shared by ALL of `paths`, or nil if mixed / none. Backs the
    /// context-menu checkmark and the hero panel's current state. Unrated counts
    /// as rating 0; a set that mixes 0 and a rating (or two ratings) → nil.
    func uniformRating(forPaths paths: [String]) -> Int? {
        guard !paths.isEmpty else { return nil }
        let values = Set(paths.map { starRatings[$0] ?? 0 })
        guard values.count == 1, let only = values.first, only > 0 else { return nil }
        return only
    }

    /// Set/clear the star rating on the effective selection (menu-bar + context
    /// menu). Files only (folders can't be tagged). Bumps tagsVersion so chips +
    /// the rating map refresh.
    func setRating(_ stars: Int?, forSelectionFallback fallback: String) {
        let urls = effectiveSelectionURLs(fallback: fallback).filter {
            (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory != true
        }
        guard !urls.isEmpty else { return }
        Task { @MainActor in
            await TagStore.shared.setRating(stars, forURLs: urls)
            tagsVersion &+= 1
        }
    }
}
