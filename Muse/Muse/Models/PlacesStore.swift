//
//  PlacesStore.swift
//  Muse
//
//  Places page state — Pattern B (its own @MainActor singleton, observed
//  directly by the views). AppState gains no @Published property for this;
//  its only integration is one forwarded objectWillChange cancellable plus the
//  methods-only AppState+Places extension.
//

import Foundation
import GRDB

nonisolated struct PlaceGroup: Identifiable, Equatable, Sendable {
    var key: String
    var city: String
    var admin: String?
    /// ISO 3166-1 alpha-2 — resolved to a display name at RENDER time, per the
    /// display-time-localization rule.
    var countryCode: String
    var count: Int
    var latestAt: Int64
    var coverPath: String?
    var id: String { key }

    var displayName: String {
        guard !countryCode.isEmpty else { return city }
        let countryName = Locale.current.localizedString(forRegionCode: countryCode) ?? countryCode
        return "\(city), \(countryName)"
    }
}

@MainActor final class PlacesStore: ObservableObject {
    static let shared = PlacesStore()
    private init() {}

    @Published private(set) var showingPlaces = false
    @Published private(set) var groups: [PlaceGroup] = []
    @Published var sortByCount = true

    /// Standardized active root paths, pushed by AppState (the same shape
    /// CollectionsEngine uses) so this store never reaches back into AppState.
    private var rootPaths: [String] = []

    func setRootPaths(_ paths: [String]) {
        rootPaths = paths
    }

    func reload() async {
        guard let q = Database.shared.dbQueue else { return }
        let fetched = (try? await q.read { db in try PlaceQueries.groups(db: db) }) ?? []
        // Only groups whose cover resolves under a tracked root are shown —
        // the same rule collection counts use, so Places can never advertise a
        // group the grid couldn't open.
        groups = rootPaths.isEmpty ? fetched : fetched.filter { group in
            guard let cover = group.coverPath else { return false }
            return CollectionStore.isUnderAnyRoot(cover, roots: rootPaths)
        }
    }

    func setShowing(_ v: Bool) {
        showingPlaces = v
    }
}
