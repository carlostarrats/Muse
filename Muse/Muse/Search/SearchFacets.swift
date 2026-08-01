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
    /// `nonisolated`: interpolated into SQL inside the off-main refresh.
    nonisolated static let facetLimit = 50

    /// Distinct capture years, newest first, as a loose index scan rather than
    /// `SELECT DISTINCT strftime('%Y', capture_date, 'unixepoch')`: strftime in
    /// the projection forces a full scan of photo_meta, and v14's own schema
    /// comment forbids exactly that pattern (it is why `capture_md` is
    /// materialized). Every step here is one indexed `MIN(capture_date)` seek
    /// on `photo_meta_capture_idx` — O(distinct years · log n), not O(rows) —
    /// and the answer is still exact, so no empty year is ever offered.
    ///
    /// `nonisolated` + internal so the query itself is testable without the
    /// @MainActor store.
    ///
    /// **Both the label and the year step are LOCAL** (`'localtime'`), because the
    /// token these years feed — `in:<year>` — resolves its bounds through a
    /// `Calendar` in the current zone (`PhotoSearch.dateIDs`). Reading the column
    /// as UTC broke this function's own "no empty year is ever offered" promise
    /// in both directions for a capture within the zone offset of a year boundary:
    /// 2019-12-31 20:00 PST is 2020 in UTC, so the facet offered **2020** while
    /// `in:2020` matched nothing — and, because the *step* was a UTC year too, a
    /// following June 2020 photo was jumped clean over and **2019 was never
    /// offered at all**. `'utc'` closes the step back to an epoch after
    /// `'localtime'` opens it, so the arithmetic happens on local wall-clock
    /// years and the comparison still happens on the stored epoch — the loose
    /// index scan is unchanged.
    nonisolated static func distinctYears(db: GRDB.Database) throws -> [String] {
        try String.fetchAll(db, sql: """
            WITH RECURSIVE y(t) AS (
                SELECT MIN(capture_date) FROM photo_meta WHERE capture_date IS NOT NULL
                UNION ALL
                SELECT (SELECT MIN(capture_date) FROM photo_meta
                        WHERE capture_date >= CAST(strftime('%s',
                            datetime(y.t, 'unixepoch', 'localtime',
                                     'start of year', '+1 year', 'utc')) AS INTEGER))
                FROM y WHERE y.t IS NOT NULL
            )
            SELECT strftime('%Y', t, 'unixepoch', 'localtime') AS v FROM y
            WHERE t IS NOT NULL ORDER BY v DESC
            """)
    }

    var snapshot: FacetsSnapshot {
        FacetsSnapshot(cameras: cameras, lenses: lenses, places: places, years: years)
    }

    /// Single-flight with one trailing re-run. Three launch backfills, every
    /// analyze pass and every import all call this, and several of them can
    /// land at once — running four identical GROUP BY sweeps concurrently on
    /// the serial queue bought nothing. A caller that arrives mid-refresh is
    /// still guaranteed a pass that STARTS after its writes.
    private var refreshing = false
    private var refreshAgain = false

    func refresh() async {
        if refreshing {
            refreshAgain = true
            return
        }
        refreshing = true
        defer { refreshing = false }
        repeat {
            refreshAgain = false
            await performRefresh()
        } while refreshAgain
    }

    private func performRefresh() async {
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
            func values(_ rows: [Row]) -> [String] { rows.compactMap { $0["v"] as String? } }
            return FacetsSnapshot(cameras: values(cameraRows), lenses: values(lensRows),
                                  places: values(placeRows),
                                  years: try Self.distinctYears(db: db))
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
        // Not DB-enumerable like camera/lens — a fixed vocabulary and a single
        // numeric-op hint, so the key still completes into something usable.
        case "is":     return SearchToken.TraitQuery.allCases.map(\.rawValue)
        case "faces":  return [">2", "0"]
        case "pets":   return [">0"]
        default:       return []
        }
    }
}
