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

    /// Cosine-similarity floor for a semantic hit. Read by BOTH the merge and
    /// the folder-scope relaxation below — they must agree on what counts as a
    /// semantic match, or a file could be merged in as semantic while still
    /// being narrowed to its tag's folder.
    static let semanticThreshold = 0.45

    /// `cancellation` lets a superseded pass bail before doing the expensive
    /// work. The token guard at the call site already stops a stale result from
    /// LANDING; this stops it from being COMPUTED — without it, typing a second
    /// query runs the first one's full embedding walk to completion for nothing.
    /// It's an explicit object rather than `Task.isCancelled` because task-local
    /// cancellation doesn't reach inside GRDB's read closure (see
    /// SearchCancellation).
    static func search(query: String, scope: SearchScope,
                       cancellation: SearchCancellation? = nil) async -> [FileNode] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        guard cancellation?.isCancelled != true else { return [] }

        guard let queue = Database.shared.dbQueue else { return [] }

        // Search tokens (camera:/lens:/iso:/f:/in:/near:/text:/color:/star:/
        // kind:) are parsed out of the committed field text BEFORE every other
        // leg. With no token this is a pure no-op and the pipeline below runs
        // byte-identically to the pre-token behaviour, legacy bare-hex colour
        // included — that equivalence is pinned by test.
        let parsed = SearchQueryParser.parse(trimmed)
        let hasTokens = !parsed.tokens.isEmpty
        // `text:` folds into the free-text leg; `color:` folds into the
        // existing palette leg. Neither is matched by PhotoSearch.
        let tokenText = parsed.tokens.compactMap { token -> String? in
            if case let .text(v) = token { return v }
            return nil
        }.joined(separator: " ")
        let tokenColors = parsed.tokens.compactMap { token -> String? in
            if case let .color(v) = token { return v }
            return nil
        }
        let effectiveQuery: String = {
            guard hasTokens else { return trimmed }
            return [parsed.freeText, tokenText]
                .filter { !$0.isEmpty }.joined(separator: " ")
        }()

        // Pull any hex color tokens out of the query. Non-hex tokens (incl.
        // color *names* like "red", which are already tags) stay as text and
        // flow through the pipeline unchanged. A query with no hex is inert
        // on the color path — identical to today's behavior.
        let cq = ColorQuery.parse(effectiveQuery)
        // A `color:` token routes into this SAME leg rather than a parallel
        // matcher: a hex value joins the hex list, a named swatch resolves
        // through SmartColor exactly as the smart-rule path does.
        var colorQuery: [LabColor] = cq.hexes.map { LabColor(rgb: $0) }
        for value in tokenColors {
            if let rgb = SmartRule.parsedHex(value) {
                colorQuery.append(LabColor(rgb: rgb))
            } else if let rgb = SmartColor.rgb(for: value.lowercased()) {
                colorQuery.append(LabColor(rgb: rgb))
            }
        }
        let textQuery = cq.hexes.isEmpty ? effectiveQuery : cq.textRemainder
        let hasText = !textQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        let escaped = ftsEscape(textQuery)
        // Embed the query here on the main actor (the registry is @MainActor);
        // the off-main DB scan below only does cosine scoring on this vector.
        guard cancellation?.isCancelled != true else { return [] }
        let queryVector = hasText ? IntelligenceRegistry.shared.embedder?.embed(textQuery) : nil
        // Last check before the read: everything past here is on GRDB's thread.
        guard cancellation?.isCancelled != true else { return [] }

        let absPaths: [String] = (try? await queue.read { db -> [String] in
            // Token leg: an AND intersection over indexed columns only. Runs
            // first so an empty intersection short-circuits the expensive legs.
            let tokenResult = hasTokens ? try PhotoSearch.filter(tokens: parsed.tokens, db: db) : nil
            if let tokenResult, tokenResult.idSet.isEmpty { return [] }

            // Token-only query (no free text, no `text:`, no colour): the
            // capture-DESC order PhotoSearch already produced IS the result.
            if let tokenResult, !hasText, colorQuery.isEmpty {
                return try aliveePaths(for: tokenResult.ids,
                                       restrictedToDirs: tokenResult.dirRestrictions, db: db)
            }

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
                var eligible = colorIDs ?? []
                if let tokenResult { eligible.formIntersection(tokenResult.idSet) }
                let ranked = eligible.sorted {
                    let s0 = colorScore[$0] ?? .infinity, s1 = colorScore[$1] ?? .infinity
                    // Tiebreak on id so equal-distance files keep a stable,
                    // repeatable order across identical searches.
                    return s0 != s1 ? s0 < s1 : $0 < $1
                }
                return try aliveePaths(for: ranked,
                                       restrictedToDirs: tokenResult?.dirRestrictions ?? [:],
                                       db: db)
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
            let tagRows = try TagRow.filter(tagFilter).fetchAll(db)
            let tagIDs = tagRows.map { $0.file_id }

            // 2b) Note substring matches (per (file_id, parent_dir), LIKE — notes
            //     are not in FTS). Uses the raw text query, same as basename/OCR.
            let noteScopes = try NoteStore.searchScopes(term: textQuery, db: db)
            let noteIDs = noteScopes.map(\.fileID)

            // Tags and notes are per (file_id, parent_dir): the same content in
            // another folder is a different image with its own. Resolving those
            // matches to EVERY alive path of the file leaked the other folder's
            // duplicate into the results for a tag/note it does not carry — the
            // exact cross-folder bleed the (file_id, parent_dir) grain exists to
            // prevent. Record which folders actually matched so the resolve can
            // narrow to them. FTS and semantic hits are content-derived and so
            // are legitimately folder-agnostic; a file matched by either is left
            // unrestricted.
            // A NULL parent_dir is an orphaned tag row (no alive path) — it can't
            // name a folder, so it contributes no restriction and the file falls
            // back to unrestricted rather than being narrowed to nothing.
            var matchedDirs: [String: Set<String>] = [:]
            var unscopedTagIDs = Set<String>()
            for r in tagRows {
                if let dir = r.parent_dir {
                    matchedDirs[r.file_id, default: []].insert(dir)
                } else {
                    unscopedTagIDs.insert(r.file_id)
                }
            }
            for s in noteScopes { matchedDirs[s.fileID, default: []].insert(s.parentDir) }

            // Exact hits, ordered: FTS5 result order first, then tag matches
            // not already included, in their query order.
            var exactSeen = Set<String>()
            var exactIDs: [String] = []
            for id in ftsIDs + tagIDs + noteIDs where !exactSeen.contains(id) {
                exactIDs.append(id); exactSeen.insert(id)
            }

            // 3) Semantic hits (embedding cosine similarity), merged after
            // exact hits — exact first, semantic by descending similarity.
            // The expensive leg: every embedding row, cosine-scored. A
            // superseded pass skips it entirely rather than finishing work
            // whose result the caller's token guard will discard.
            let semantic: [(String, Double)] = cancellation?.isCancelled == true ? [] :
                (queryVector.flatMap {
                    try? SemanticSearch.semanticIDs(queryVector: $0, db: db)
                }) ?? []
            var orderedIDs = SemanticSearch.merge(
                exactIDs: exactIDs, semantic: semantic, threshold: Self.semanticThreshold)

            // A file also matched by a content-derived tier — or by a tag row
            // that names no folder — is unrestricted.
            for id in ftsIDs { matchedDirs[id] = nil }
            for id in unscopedTagIDs { matchedDirs[id] = nil }
            for (id, score) in semantic where score >= Self.semanticThreshold {
                matchedDirs[id] = nil
            }

            // Color, when present alongside text, is an additional AND filter
            // over the text results (text ranking preserved).
            if let colorIDs {
                orderedIDs = orderedIDs.filter { colorIDs.contains($0) }
            }

            // Tokens AND the text result — the same precedent as the colour
            // intersection just above. Dir restrictions are applied AFTER the
            // relaxation loop that cleared `matchedDirs` for FTS/semantic hits,
            // so an FTS match can never un-restrict a rating token (ratings are
            // per (file_id, parent_dir); a text hit on a byte-identical copy in
            // another folder must not surface that unrated copy).
            if let tokenResult {
                orderedIDs = orderedIDs.filter { tokenResult.idSet.contains($0) }
                for (id, dirs) in tokenResult.dirRestrictions {
                    matchedDirs[id] = matchedDirs[id].map { $0.intersection(dirs) } ?? dirs
                }
            }
            guard !orderedIDs.isEmpty else { return [] }

            return try aliveePaths(for: orderedIDs, restrictedToDirs: matchedDirs, db: db)
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
        // Also skipped when tokens are present: an unindexed file has no
        // photo_meta/places row either, so it can never satisfy a token.
        var extras: [FileNode] = []
        if case .currentFolder(let url) = scope, colorQuery.isEmpty, !hasTokens {
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
    /// `restrictedToDirs` narrows a file's resolved paths to the folders that
    /// actually matched — set only for files whose sole evidence is a per-folder
    /// tag or note. An absent entry means unrestricted (every alive path).
    nonisolated private static func aliveePaths(for orderedIDs: [String],
                                                restrictedToDirs: [String: Set<String>],
                                                db: GRDB.Database) throws -> [String] {
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
            if let allowed = restrictedToDirs[fid],
               !allowed.contains(TagScope.parentDir(ofPath: row.absolute_path)) { continue }
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
