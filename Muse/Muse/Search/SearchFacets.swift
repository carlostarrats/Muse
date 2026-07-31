//
//  SearchFacets.swift
//  Muse
//
//  Autocomplete facets: DISTINCT values from the live index, refreshed after
//  backfills and analyze passes — never per keystroke. Pattern B store (its
//  own @MainActor singleton, observed directly, no AppState @Published).
//
//  SearchSuggest below is pure and unit-tested; the store only supplies its
//  snapshot.
//

import Foundation
import GRDB

nonisolated struct FacetsSnapshot: Equatable, Sendable {
    var cameras: [String]
    var lenses: [String]
    var places: [String]
    var years: [String]

    static let empty = FacetsSnapshot(cameras: [], lenses: [], places: [], years: [])
}

@MainActor final class SearchFacets: ObservableObject {
    static let shared = SearchFacets()
    private init() {}

    @Published private(set) var cameras: [String] = []
    @Published private(set) var lenses: [String] = []
    @Published private(set) var places: [String] = []
    @Published private(set) var years: [String] = []

    /// Per-facet cap. Autocomplete offers at most 8 rows, so the tail of a
    /// long-tail facet is never reachable — no reason to hold it.
    static let facetLimit = 50

    var snapshot: FacetsSnapshot {
        FacetsSnapshot(cameras: cameras, lenses: lenses, places: places, years: years)
    }

    func refresh() async {
        guard let q = Database.shared.dbQueue else { return }
        let result: FacetsSnapshot? = try? await q.read { db in
            let cameraRows = try Row.fetchAll(db, sql: """
                SELECT camera_model AS v, COUNT(*) AS c FROM photo_meta
                WHERE camera_model IS NOT NULL
                GROUP BY camera_model ORDER BY c DESC LIMIT \(Self.facetLimit)
                """)
            let lensRows = try Row.fetchAll(db, sql: """
                SELECT lens AS v, COUNT(*) AS c FROM photo_meta
                WHERE lens IS NOT NULL
                GROUP BY lens ORDER BY c DESC LIMIT \(Self.facetLimit)
                """)
            let placeRows = try Row.fetchAll(db, sql: """
                SELECT city AS v, COUNT(*) AS c FROM places
                WHERE place_key IS NOT NULL AND city IS NOT NULL
                GROUP BY city ORDER BY c DESC LIMIT \(Self.facetLimit)
                """)
            let yearRows = try Row.fetchAll(db, sql: """
                SELECT DISTINCT strftime('%Y', capture_date, 'unixepoch') AS v
                FROM photo_meta WHERE capture_date IS NOT NULL ORDER BY v DESC
                """)
            func values(_ rows: [Row]) -> [String] { rows.compactMap { $0["v"] as String? } }
            return FacetsSnapshot(cameras: values(cameraRows), lenses: values(lensRows),
                                  places: values(placeRows), years: values(yearRows))
        }
        guard let result else { return }
        cameras = result.cameras
        lenses = result.lenses
        places = result.places
        years = result.years
    }
}

nonisolated enum SearchSuggest {
    struct Suggestion: Equatable, Identifiable {
        var display: String
        /// The FULL replacement field text — the preceding words plus the
        /// completed trailing token. `.searchCompletion` replaces the whole
        /// field, so anything already typed has to be carried along.
        var completion: String
        var id: String { completion }
    }

    static let maxSuggestions = 8

    /// Plain free text gets no suggestions: the trailing word must either
    /// prefix a token key or already carry a colon.
    static func suggestions(fieldText: String, facets: FacetsSnapshot) -> [Suggestion] {
        guard let lastWordRange = fieldText.range(of: #"\S+$"#, options: .regularExpression) else {
            return []
        }
        let lastWord = String(fieldText[lastWordRange])
        let preceding = String(fieldText[fieldText.startIndex..<lastWordRange.lowerBound])

        if let colonIndex = lastWord.firstIndex(of: ":") {
            let key = String(lastWord[lastWord.startIndex..<colonIndex]).lowercased()
            let partial = String(lastWord[lastWord.index(after: colonIndex)...]).lowercased()
            let values = facetValues(for: key, facets: facets)
            let filtered = partial.isEmpty ? values : values.filter { $0.lowercased().contains(partial) }
            return filtered.prefix(maxSuggestions).map { value in
                // A value with spaces needs quoting or it re-parses as two
                // segments and stops being one token.
                let encoded = value.contains(" ") ? "\"\(value)\"" : value
                return Suggestion(display: "\(key): \(value)",
                                  completion: preceding + "\(key):\(encoded)")
            }
        }

        guard !lastWord.isEmpty else { return [] }
        let matchingKeys = SearchQueryParser.keys.filter { $0.hasPrefix(lastWord.lowercased()) }
        return matchingKeys.prefix(maxSuggestions).map { key in
            Suggestion(display: "\(key):", completion: preceding + "\(key):")
        }
    }

    private static func facetValues(for key: String, facets: FacetsSnapshot) -> [String] {
        switch key {
        case "camera": return facets.cameras
        case "lens":   return facets.lenses
        case "near":   return facets.places
        case "in":     return facets.years
        default:       return []
        }
    }
}
