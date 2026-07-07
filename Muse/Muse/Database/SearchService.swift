//
//  SearchService.swift
//  Muse
//
//  FTS5 + path search. Returns FileNodes matching the query against
//  filename, caption, OCR text, and tag labels.
//

import Foundation
import GRDB

@MainActor
enum SearchScope {
    case currentFolder(URL)
    case everywhere
}

@MainActor
enum SearchService {

    static func search(query: String, scope: SearchScope) async -> [FileNode] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        guard let queue = Database.shared.dbQueue else { return [] }

        // Pull any hex color tokens out of the query. Non-hex tokens (incl.
        // color *names* like "red", which are already tags) stay as text and
        // flow through the pipeline unchanged. A query with no hex is inert
        // on the color path — identical to today's behavior.
        let cq = ColorQuery.parse(trimmed)
        let colorQuery: [LabColor] = cq.hexes.map { LabColor(rgb: $0) }
        let textQuery = colorQuery.isEmpty ? trimmed : cq.textRemainder
        let hasText = !textQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        let escaped = ftsEscape(textQuery)
        // Embed the query here on the main actor (the registry is @MainActor);
        // the off-main DB scan below only does cosine scoring on this vector.
        let queryVector = hasText ? IntelligenceRegistry.shared.embedder?.embed(textQuery) : nil

        let absPaths: [String] = (try? await queue.read { db -> [String] in
            // Color filter: IDs whose palette matches EVERY query color (AND),
            // plus a closeness score for color-only ranking. Only when the
            // query actually carries a hex token.
            var colorIDs: Set<String>? = nil
            var colorScore: [String: Double] = [:]
            if !colorQuery.isEmpty {
                var ids = Set<String>()
                let rows = try Row.fetchAll(
                    db, sql: "SELECT id, palette FROM files WHERE palette IS NOT NULL")
                for row in rows {
                    guard let id = row["id"] as String?,
                          let json = row["palette"] as String?,
                          let data = json.data(using: .utf8),
                          let hexes = try? JSONDecoder().decode([String].self, from: data)
                    else { continue }
                    let palette: [LabColor] = hexes.compactMap { hex in
                        NamedColor.parse(hex).map { LabColor(rgb: RGB(r: $0.0, g: $0.1, b: $0.2)) }
                    }
                    guard !palette.isEmpty else { continue }
                    if PaletteMatch.matches(query: colorQuery, palette: palette,
                                            threshold: ColorDistance.nearThreshold) {
                        ids.insert(id)
                        colorScore[id] = PaletteMatch.score(query: colorQuery, palette: palette)
                    }
                }
                colorIDs = ids
            }

            // Color-only query (no text remainder) → rank by palette closeness
            // (closest first), resolve, return.
            if !colorQuery.isEmpty && !hasText {
                let ranked = (colorIDs ?? []).sorted {
                    let s0 = colorScore[$0] ?? .infinity, s1 = colorScore[$1] ?? .infinity
                    // Tiebreak on id so equal-distance files keep a stable,
                    // repeatable order across identical searches.
                    return s0 != s1 ? s0 < s1 : $0 < $1
                }
                return try aliveePaths(for: ranked, db: db)
            }

            // --- Existing text pipeline, now driven by textQuery ---
            // 1) FTS5 hits
            let ftsRows = try Row.fetchAll(
                db,
                sql: "SELECT file_id FROM files_fts WHERE files_fts MATCH ?",
                arguments: [escaped]
            )
            let ftsIDs = ftsRows.compactMap { $0["file_id"] as String? }

            // 2) Tag label matches (for indexed content). Bridge a localized
            //    query to its canonical vision term so e.g. "plage" finds files
            //    tagged canonical "beach"; the raw query is always included so
            //    French filenames/OCR/manual tags still match.
            let tagTerms = SearchBridge.tagSearchTerms(for: textQuery) {
                VocabularyLocalizer.shared.canonicalize($0)
            }
            let tagFilter = tagTerms
                .map { TagRow.Columns.label.like("%" + $0 + "%") }
                .joined(operator: .or)
            let tagIDs = try TagRow
                .filter(tagFilter)
                .fetchAll(db)
                .map { $0.file_id }

            // 2b) Note substring matches (per (file_id, parent_dir), LIKE — notes
            //     are not in FTS). Uses the raw text query, same as basename/OCR.
            let noteIDs = try NoteStore.searchIDs(term: textQuery, db: db)

            // Exact hits, ordered: FTS5 result order first, then tag matches
            // not already included, in their query order.
            var exactSeen = Set<String>()
            var exactIDs: [String] = []
            for id in ftsIDs + tagIDs + noteIDs where !exactSeen.contains(id) {
                exactIDs.append(id); exactSeen.insert(id)
            }

            // 3) Semantic hits (embedding cosine similarity), merged after
            // exact hits — exact first, semantic by descending similarity.
            let semantic = (queryVector.flatMap {
                try? SemanticSearch.semanticIDs(queryVector: $0, db: db)
            }) ?? []
            var orderedIDs = SemanticSearch.merge(
                exactIDs: exactIDs, semantic: semantic, threshold: 0.45)

            // Color, when present alongside text, is an additional AND filter
            // over the text results (text ranking preserved).
            if let colorIDs {
                orderedIDs = orderedIDs.filter { colorIDs.contains($0) }
            }
            guard !orderedIDs.isEmpty else { return [] }

            return try aliveePaths(for: orderedIDs, db: db)
        }) ?? []

        // Filter by scope
        let scopedPaths: [String]
        switch scope {
        case .currentFolder(let url):
            // Match the folder itself or its descendants — guard with a trailing
            // separator so a sibling like "/a/Inspo Extra" doesn't match
            // "/a/Inspo" (the rest of the codebase uses this same `+ "/"` rule).
            let prefix = url.standardizedFileURL.path
            scopedPaths = absPaths.filter { $0 == prefix || $0.hasPrefix(prefix + "/") }
        case .everywhere:
            scopedPaths = absPaths
        }

        // Ranked results (exact-then-semantic, or color-closeness) keep order.
        let ranked: [FileNode] = scopedPaths.map { FileNode(url: URL(fileURLWithPath: $0)) }

        // Also do a basename substring match on enumerated files (so search
        // works even when files aren't indexed yet, scoped to current folder).
        // These unranked extras sort by modifiedAt and trail the ranked hits.
        // The enumeration is a full stat sweep of the folder — run it OFF the
        // main actor (this method is @MainActor; on a multi-thousand-file
        // folder it janked every debounced keystroke).
        // Skipped for color queries: an unindexed file has no palette, so it
        // can never satisfy a color filter — color search only surfaces
        // analyzed images.
        var extras: [FileNode] = []
        if case .currentFolder(let url) = scope, colorQuery.isEmpty {
            let lower = trimmed.lowercased()
            let rankedPaths = Set(ranked.map { $0.url.standardizedFileURL })
            extras = await Task.detached(priority: .userInitiated) { () -> [FileNode] in
                var out: [FileNode] = []
                var seen = Set<URL>()
                for f in FolderReader.files(in: url, showHidden: false) {
                    let std = f.url.standardizedFileURL
                    if f.basename.lowercased().contains(lower),
                       !rankedPaths.contains(std), !seen.contains(std) {
                        out.append(f)
                        seen.insert(std)
                    }
                }
                return out
            }.value
        }

        return ranked + extras.sorted { ($0.modifiedAt ?? .distantPast) > ($1.modifiedAt ?? .distantPast) }
    }

    /// Resolve ranked file IDs to their alive absolute paths, preserving the
    /// input order. Shared by the color-only and text search branches.
    nonisolated private static func aliveePaths(for orderedIDs: [String], db: GRDB.Database) throws -> [String] {
        guard !orderedIDs.isEmpty else { return [] }
        let placeholders = orderedIDs.map { _ in "?" }.joined(separator: ",")
        let pathRows = try PathRow.fetchAll(
            db,
            sql: "SELECT * FROM paths WHERE file_id IN (\(placeholders)) AND is_alive = 1",
            arguments: StatementArguments(orderedIDs)
        )
        var pathsByID: [String: [String]] = [:]
        for row in pathRows {
            guard let fid = row.file_id else { continue }
            pathsByID[fid, default: []].append(row.absolute_path)
        }
        return orderedIDs.flatMap { pathsByID[$0] ?? [] }
    }

    /// Escape a user query for FTS5: split into tokens, prefix-match each,
    /// AND them together. Defensive against punctuation that breaks the parser.
    ///
    /// Common English stopwords are dropped before the AND so a natural phrase
    /// ("white wedding dresses for summer") isn't sabotaged by forcing a
    /// rare-token AND on a filler word ("for") that an image's filename/OCR/
    /// caption rarely contains. The semantic layer still sees the full phrase;
    /// this only affects the exact-match (FTS5) tier. If a query is ALL
    /// stopwords, every token is kept so a literal search still matches.
    static func ftsEscape(_ raw: String) -> String {
        let cleaned = raw.replacingOccurrences(
            of: "[\"\\(\\)*]",
            with: " ",
            options: .regularExpression
        )
        let tokens = cleaned
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
            .filter { !$0.isEmpty }
        if tokens.isEmpty { return "\"\"" }
        let content = tokens.filter { !ftsStopwords.contains($0.lowercased()) }
        // All-stopword query → keep every token (don't strip to nothing).
        let used = content.isEmpty ? tokens : content
        return used.map { "\"\($0)\"*" }.joined(separator: " AND ")
    }

    /// Filler words that carry no signal for an image search and would only
    /// over-constrain the FTS5 AND. Deliberately small + conservative, and
    /// avoids English words that are meaningful CONTENT nouns in a shipped
    /// language — notably French "or" (gold) and "as" (ace), which must stay
    /// searchable. Don't add those back; a wrong strip silently drops a real
    /// term. (English-only by design; non-English filler isn't stripped, which
    /// is no worse than before — only ever a recall win, never a wrong miss.)
    private static let ftsStopwords: Set<String> = [
        "a", "an", "and", "the", "of", "to", "in", "on", "at", "by", "for",
        "from", "with", "that", "this", "these", "those", "is", "are", "was",
        "were", "be", "it", "its", "have", "has", "had",
    ]
}
