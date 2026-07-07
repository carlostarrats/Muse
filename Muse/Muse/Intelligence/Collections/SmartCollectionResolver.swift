//
//  SmartCollectionResolver.swift
//  Muse
//
//  Live membership for a smart collection: evaluate each SmartRule to a
//  Set<file_id> over the files table, then combine by Match.all (∩) / .any (∪).
//  Pure (takes a GRDB.Database) so it's fixture-testable. Reachability (under
//  an active root) is applied by the caller on the returned alive paths, using
//  the same CollectionStore.isUnderAnyRoot rule as manual collections.
//

import Foundation
import GRDB

enum SmartCollectionResolver {

    /// Combined matching file_ids (content rows). NOT reachability-filtered.
    static func memberIDs(_ set: SmartRuleSet, db: GRDB.Database) throws -> Set<String> {
        guard !set.rules.isEmpty else { return [] }
        let perRule = try set.rules.map { try evaluate($0, db: db) }
        switch set.match {
        case .all:
            return perRule.dropFirst().reduce(perRule[0]) { $0.intersection($1) }
        case .any:
            return perRule.reduce(into: Set<String>()) { $0.formUnion($1) }
        }
    }

    /// Distinct alive absolute paths for the matching members (what the grid
    /// renders, one tile per alive path). Empty when nothing matches.
    static func alivePaths(_ set: SmartRuleSet, db: GRDB.Database) throws -> [String] {
        let ids = try memberIDs(set, db: db)
        guard !ids.isEmpty else { return [] }
        let placeholders = ids.map { _ in "?" }.joined(separator: ",")
        return try String.fetchAll(db, sql: """
            SELECT DISTINCT absolute_path FROM paths
            WHERE is_alive = 1 AND file_id IN (\(placeholders))
            """, arguments: StatementArguments(Array(ids)))
    }

    // MARK: - Per-rule evaluation

    private static func evaluate(_ rule: SmartRule, db: GRDB.Database) throws -> Set<String> {
        switch rule {
        case let .kind(group):
            return try idSet(db, sql: "SELECT id FROM files WHERE kind IN (\(qmarks(group.kinds.count)))",
                             args: group.kinds)

        case let .size(op, bytes):
            let cmp = sqlComparison(op)
            return try idSet(db, sql: "SELECT id FROM files WHERE size_bytes IS NOT NULL AND size_bytes \(cmp) ?",
                             args: [bytes])

        case let .date(field, op):
            let col = field == .created ? "created_at" : "modified_at"
            switch op {
            case let .before(t):
                return try idSet(db, sql: "SELECT id FROM files WHERE \(col) IS NOT NULL AND \(col) < ?", args: [t])
            case let .after(t):
                return try idSet(db, sql: "SELECT id FROM files WHERE \(col) IS NOT NULL AND \(col) > ?", args: [t])
            case .withinDays:
                // A persisted `.withinDays` is converted to an absolute `.after`
                // bound at rule-BUILD time (SmartCollectionRulesView.save). If one
                // ever reaches here, degrade to "has a value" rather than silently
                // emptying the collection.
                return try idSet(db, sql: "SELECT id FROM files WHERE \(col) IS NOT NULL", args: [])
            }

        case let .filename(contains):
            // Pre-narrow with LIKE on the whole path, then keep only rows whose
            // BASENAME contains the term (case-insensitive) — LIKE alone would
            // also match a directory component.
            let needle = contains.lowercased()
            let rows = try Row.fetchAll(db, sql: """
                SELECT DISTINCT file_id, absolute_path FROM paths
                WHERE is_alive = 1 AND LOWER(absolute_path) LIKE '%' || ? || '%'
                """, arguments: [needle])
            var out = Set<String>()
            for r in rows {
                guard let fid = r["file_id"] as String?, let p = r["absolute_path"] as String? else { continue }
                if (p as NSString).lastPathComponent.lowercased().contains(needle) { out.insert(fid) }
            }
            return out

        case let .tag(op, label):
            let has = try idSet(db, sql: "SELECT DISTINCT file_id FROM tags WHERE label = ?", args: [label])
            if op == .has { return has }
            // hasNot = every file MINUS those that have the tag (any location).
            let all = try idSet(db, sql: "SELECT id FROM files", args: [])
            return all.subtracting(has)

        case let .rating(op, stars):
            let labels = qualifyingRatingLabels(op: op, stars: stars)
            guard !labels.isEmpty else { return [] }
            return try idSet(db, sql: "SELECT DISTINCT file_id FROM tags WHERE label IN (\(qmarks(labels.count)))",
                             args: labels)

        case let .color(term):
            guard let target = colorLab(term) else { return [] }
            let rows = try Row.fetchAll(db, sql: "SELECT id, palette FROM files WHERE palette IS NOT NULL")
            var out = Set<String>()
            for row in rows {
                guard let id = row["id"] as String?,
                      let json = row["palette"] as String?,
                      let data = json.data(using: .utf8),
                      let hexes = try? JSONDecoder().decode([String].self, from: data) else { continue }
                let palette: [LabColor] = hexes.compactMap { hex in
                    NamedColor.parse(hex).map { LabColor(rgb: RGB(r: $0.0, g: $0.1, b: $0.2)) }
                }
                if PaletteMatch.matches(query: [target], palette: palette,
                                        threshold: ColorDistance.nearThreshold) {
                    out.insert(id)
                }
            }
            return out
        }
    }

    // MARK: - Helpers

    private static func idSet(_ db: GRDB.Database, sql: String,
                              args: [DatabaseValueConvertible]) throws -> Set<String> {
        Set(try String.fetchAll(db, sql: sql, arguments: StatementArguments(args)))
    }

    private static func qmarks(_ n: Int) -> String {
        Array(repeating: "?", count: n).joined(separator: ",")
    }

    private static func sqlComparison(_ op: Comparison) -> String {
        switch op { case .atLeast: return ">="; case .equal: return "="; case .atMost: return "<=" }
    }

    /// The star-glyph labels a rating rule matches, e.g. atLeast 4 → ["★★★★","★★★★★"].
    private static func qualifyingRatingLabels(op: Comparison, stars: Int) -> [String] {
        let range: [Int]
        switch op {
        case .atLeast: range = Array(stars...StarRating.maxStars)
        case .equal:   range = [stars]
        case .atMost:  range = Array(1...stars)
        }
        return range.compactMap { StarRating.label(for: $0) }
    }

    /// A color term → its LAB target, or nil if it can't be decoded.
    private static func colorLab(_ term: ColorTerm) -> LabColor? {
        switch term {
        case let .hex(h):
            return SmartRule.parsedHex(h).map { LabColor(rgb: $0) }
        case let .name(n):
            // Reuse NamedColor's table (v1 decodes hex only; a bare name yields
            // nil → matches nothing — the builder emits .hex, not .name).
            return NamedColor.parse(n).map { LabColor(rgb: RGB(r: $0.0, g: $0.1, b: $0.2)) }
        }
    }
}
