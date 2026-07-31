//
//  PhotoSearch.swift
//  Muse
//
//  Token → SQL, indexed-only. Every token hits an index from v13/v14/v15 or an
//  existing one; nothing here opens a file, calls Vision, or geocodes. AND
//  across tokens is set intersection, mirroring SmartRuleSet.all.
//
//  Rating tokens carry per-(file_id, parent_dir) dir restrictions — a rating is
//  a manual tag, the one per-location axis in this set. Every other token is
//  content-derived and folder-unrestricted.
//
//  `.text` and `.color` are deliberately NOT matched here: SearchService folds
//  a `text:` value into its free-text leg and routes a `color:` value into the
//  EXISTING palette leg, so there is exactly one FTS engine and one colour
//  matcher in the app.
//

import Foundation
import GRDB

nonisolated enum PhotoSearch {
    struct Result: Sendable {
        var ids: [String]
        var idSet: Set<String>
        var dirRestrictions: [String: Set<String>] = [:]
    }

    /// Tokens PhotoSearch actually resolves to id sets. `.text`/`.color` are
    /// handled by SearchService's existing legs (see the file header).
    static func isIntersectable(_ token: SearchToken) -> Bool {
        switch token {
        case .text, .color: return false
        default: return true
        }
    }

    /// Query-time values a token can't carry in its own text. Resolved on the
    /// main actor BEFORE entering `queue.read`, so the read closure captures a
    /// plain value, never an isolated store.
    struct TokenContext: Sendable {
        var similarVectors: [String: [Float]] = [:]

        init(similarVectors: [String: [Float]] = [:]) {
            self.similarVectors = similarVectors
        }
    }

    /// nil when there is nothing to intersect (no intersectable tokens).
    static func filter(tokens: [SearchToken], context: TokenContext = .init(),
                       db: GRDB.Database) throws -> Result? {
        let usable = tokens.filter(isIntersectable)
        guard !usable.isEmpty else { return nil }

        var idSet: Set<String>?
        var dirRestrictions: [String: Set<String>] = [:]
        /// When a `similar:` token is present, SIMILARITY SCORE DESC replaces
        /// capture DESC as the result order — that's the whole point of the
        /// query. Other tokens still intersect via `idSet`.
        var similarityRanking: [(id: String, score: Double)]?

        for token in usable {
            if case let .similar(handle) = token {
                guard let vector = context.similarVectors[handle] else {
                    // Unresolvable handle → matches NOTHING. Never a silent
                    // widening back to the unfiltered library.
                    return Result(ids: [], idSet: [], dirRestrictions: [:])
                }
                let hits = try ClipIndex.matches(query: vector,
                                                 minScore: ClipIndex.imageMinScore, db: db)
                similarityRanking = hits
                let matched = Set(hits.map(\.id))
                idSet = idSet.map { $0.intersection(matched) } ?? matched
                if idSet?.isEmpty == true { break }
                continue
            }
            let (matched, dirs) = try matchIDs(for: token, db: db)
            for (id, d) in dirs {
                dirRestrictions[id] = dirRestrictions[id].map { $0.union(d) } ?? d
            }
            idSet = idSet.map { $0.intersection(matched) } ?? matched
            if idSet?.isEmpty == true { break }
        }
        let finalSet = idSet ?? []
        // Dir restrictions only matter for surviving files.
        dirRestrictions = dirRestrictions.filter { finalSet.contains($0.key) }
        let ordered: [String]
        if let similarityRanking {
            ordered = similarityRanking.map(\.id).filter { finalSet.contains($0) }
        } else {
            ordered = try orderByCapture(ids: finalSet, db: db)
        }
        return Result(ids: ordered, idSet: finalSet, dirRestrictions: dirRestrictions)
    }

    // MARK: - Per-token matching

    private static func matchIDs(for token: SearchToken, db: GRDB.Database) throws
        -> (ids: Set<String>, dirRestrictions: [String: Set<String>]) {
        switch token {
        case let .camera(term):
            let like = "%\(term.lowercased())%"
            let rows = try Row.fetchAll(db, sql: """
                SELECT file_id FROM photo_meta
                WHERE LOWER(camera_make) LIKE ? OR LOWER(camera_model) LIKE ?
                   OR LOWER(camera_make || ' ' || camera_model) LIKE ?
                """, arguments: [like, like, like])
            return (fileIDs(rows), [:])

        case let .lens(term):
            let like = "%\(term.lowercased())%"
            let rows = try Row.fetchAll(
                db, sql: "SELECT file_id FROM photo_meta WHERE LOWER(lens) LIKE ?",
                arguments: [like])
            return (fileIDs(rows), [:])

        case let .iso(f):
            return (try numericIDs(column: "iso", filter: f, db: db), [:])
        case let .aperture(f):
            return (try numericIDs(column: "f_number", filter: f, db: db), [:])

        case let .inDate(d):
            return (try dateIDs(d, db: db), [:])

        case let .near(place):
            let lower = place.lowercased()
            // A user typing a localized country name ("Portugal") must match
            // the ISO code the DB stores ("PT") — the display-time
            // localization rule, resolved back in Swift before the query.
            let code = countryCode(forDisplayName: place)
            let rows = try Row.fetchAll(db, sql: """
                SELECT file_id FROM places
                WHERE place_key IS NOT NULL
                  AND (LOWER(city) = ? OR LOWER(admin) = ? OR LOWER(country) = ?
                       OR LOWER(city) LIKE ?)
                """, arguments: [lower, lower, (code ?? place).lowercased(), lower + "%"])
            return (fileIDs(rows), [:])

        case .text, .color:
            // Unreachable — filtered out by `isIntersectable`. Kept explicit
            // so a future token can't fall through to a silent empty set.
            return ([], [:])

        case let .rating(atLeast):
            let labels = StarRating.labels(atLeast: atLeast)
            guard !labels.isEmpty else { return ([], [:]) }
            let placeholders = labels.map { _ in "?" }.joined(separator: ",")
            let rows = try Row.fetchAll(db, sql: """
                SELECT file_id, parent_dir FROM tags WHERE label IN (\(placeholders))
                """, arguments: StatementArguments(labels))
            var ids: Set<String> = []
            var dirs: [String: Set<String>] = [:]
            for row in rows {
                guard let id: String = row["file_id"] else { continue }
                ids.insert(id)
                // A NULL parent_dir is an orphaned tag row — it can't name a
                // folder, so it contributes no restriction (same rule the
                // tag/note search leg uses).
                if let dir: String = row["parent_dir"] {
                    dirs[id, default: []].insert(dir)
                }
            }
            return (ids, dirs)

        case let .kind(group):
            let placeholders = group.kinds.map { _ in "?" }.joined(separator: ",")
            let rows = try Row.fetchAll(db, sql: "SELECT id FROM files WHERE kind IN (\(placeholders))",
                                        arguments: StatementArguments(group.kinds))
            return (Set(rows.compactMap { $0["id"] as String? }), [:])

        // Trait tokens read `photo_traits` only. A file with NO row is
        // UNSCANNED, so `faces:0` matches only files that were actually
        // scanned and found faceless — never "we haven't looked yet".
        case let .faces(f):
            return (try traitNumericIDs(column: "face_count", filter: f, db: db), [:])
        case let .pets(f):
            return (try traitNumericIDs(column: "pet_count", filter: f, db: db), [:])

        case let .traitIs(query):
            switch query {
            case .portrait:
                let rows = try Row.fetchAll(db, sql: """
                    SELECT file_id FROM photo_traits
                    WHERE face_count BETWEEN 1 AND ? AND largest_face_frac >= ?
                    """, arguments: [PortraitHeuristic.portraitMaxFaces,
                                      PortraitHeuristic.portraitMinFaceFrac])
                return (fileIDs(rows), [:])
            case .group:
                let rows = try Row.fetchAll(db, sql: """
                    SELECT file_id FROM photo_traits WHERE face_count >= ?
                    """, arguments: [PortraitHeuristic.groupMinFaces])
                return (fileIDs(rows), [:])
            }

        case .similar:
            // Unreachable — handled ahead of this switch in `filter`, where the
            // TokenContext is in scope. Kept explicit so a future token can't
            // fall through to a silent empty set.
            return ([], [:])
        }
    }

    private static func fileIDs(_ rows: [Row]) -> Set<String> {
        Set(rows.compactMap { $0["file_id"] as String? })
    }

    /// Resolve a localized country display name back to its ISO 3166-1
    /// alpha-2 code, which is what `places.country` stores.
    static func countryCode(forDisplayName name: String) -> String? {
        let target = name.lowercased()
        if target.count == 2, Locale.Region.isoRegions.contains(where: {
            $0.identifier.lowercased() == target
        }) { return target.uppercased() }
        for region in Locale.Region.isoRegions {
            if let display = Locale.current.localizedString(forRegionCode: region.identifier),
               display.lowercased() == target {
                return region.identifier
            }
        }
        return nil
    }

    private static func numericIDs(column: String, filter: SearchToken.NumericFilter,
                                   db: GRDB.Database) throws -> Set<String> {
        let clause: String
        let args: [DatabaseValueConvertible]
        switch filter.op {
        case .eq:  clause = "\(column) = ?";  args = [filter.value]
        case .gt:  clause = "\(column) > ?";  args = [filter.value]
        case .gte: clause = "\(column) >= ?"; args = [filter.value]
        case .lt:  clause = "\(column) < ?";  args = [filter.value]
        case .lte: clause = "\(column) <= ?"; args = [filter.value]
        case let .range(lo, hi): clause = "\(column) BETWEEN ? AND ?"; args = [lo, hi]
        }
        let rows = try Row.fetchAll(db, sql: "SELECT file_id FROM photo_meta WHERE \(clause)",
                                    arguments: StatementArguments(args))
        return fileIDs(rows)
    }

    /// The same numeric-op shape as `numericIDs`, over `photo_traits`.
    private static func traitNumericIDs(column: String, filter: SearchToken.NumericFilter,
                                        db: GRDB.Database) throws -> Set<String> {
        let clause: String
        let args: [DatabaseValueConvertible]
        switch filter.op {
        case .eq:  clause = "\(column) = ?";  args = [filter.value]
        case .gt:  clause = "\(column) > ?";  args = [filter.value]
        case .gte: clause = "\(column) >= ?"; args = [filter.value]
        case .lt:  clause = "\(column) < ?";  args = [filter.value]
        case .lte: clause = "\(column) <= ?"; args = [filter.value]
        case let .range(lo, hi): clause = "\(column) BETWEEN ? AND ?"; args = [lo, hi]
        }
        let rows = try Row.fetchAll(db, sql: "SELECT file_id FROM photo_traits WHERE \(clause)",
                                    arguments: StatementArguments(args))
        return fileIDs(rows)
    }

    /// `in:` matches `photo_meta.capture_date`, falling back to
    /// `files.created_at` for a file with no photo_meta row (a video indexed
    /// before v14, or a file whose header carried no date).
    private static func dateIDs(_ d: SearchToken.DateToken, db: GRDB.Database) throws -> Set<String> {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone.current
        var components = DateComponents(year: d.year, month: d.month ?? 1, day: d.day ?? 1)
        components.timeZone = TimeZone.current
        guard let start = cal.date(from: components) else { return [] }
        let end: Date
        if d.day != nil {
            end = cal.date(byAdding: .day, value: 1, to: start) ?? start
        } else if d.month != nil {
            end = cal.date(byAdding: .month, value: 1, to: start) ?? start
        } else {
            end = cal.date(byAdding: .year, value: 1, to: start) ?? start
        }
        let startEpoch = Int64(start.timeIntervalSince1970)
        let endEpoch = Int64(end.timeIntervalSince1970)

        let withMeta = try Row.fetchAll(db, sql: """
            SELECT file_id FROM photo_meta
            WHERE capture_date >= ? AND capture_date < ?
            """, arguments: [startEpoch, endEpoch])
        let fallback = try Row.fetchAll(db, sql: """
            SELECT f.id AS id FROM files f
            LEFT JOIN photo_meta m ON m.file_id = f.id
            WHERE (m.file_id IS NULL OR m.capture_date IS NULL)
              AND f.created_at >= ? AND f.created_at < ?
            """, arguments: [startEpoch, endEpoch])
        var ids = fileIDs(withMeta)
        ids.formUnion(fallback.compactMap { $0["id"] as String? })
        return ids
    }

    /// Token-only queries order by capture date DESC, falling back to
    /// modified_at for files with no capture date.
    private static func orderByCapture(ids: Set<String>, db: GRDB.Database) throws -> [String] {
        guard !ids.isEmpty else { return [] }
        let ordered = Array(ids)
        let placeholders = ordered.map { _ in "?" }.joined(separator: ",")
        let rows = try Row.fetchAll(db, sql: """
            SELECT f.id AS id, COALESCE(m.capture_date, f.modified_at, f.created_at, 0) AS ord
            FROM files f LEFT JOIN photo_meta m ON m.file_id = f.id
            WHERE f.id IN (\(placeholders))
            ORDER BY ord DESC, f.id ASC
            """, arguments: StatementArguments(ordered))
        return rows.compactMap { $0["id"] as String? }
    }
}
