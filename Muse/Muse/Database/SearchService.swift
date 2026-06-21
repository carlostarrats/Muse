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

        let escaped = ftsEscape(trimmed)
        // Embed the query here on the main actor (the registry is @MainActor);
        // the off-main DB scan below only does cosine scoring on this vector.
        let queryVector = IntelligenceRegistry.shared.embedder?.embed(trimmed)

        let absPaths: [String] = (try? await queue.read { db -> [String] in
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
            let tagTerms = SearchBridge.tagSearchTerms(for: trimmed) {
                VocabularyLocalizer.shared.canonicalize($0)
            }
            let tagFilter = tagTerms
                .map { TagRow.Columns.label.like("%" + $0 + "%") }
                .joined(operator: .or)
            let tagIDs = try TagRow
                .filter(tagFilter)
                .fetchAll(db)
                .map { $0.file_id }

            // Exact hits, ordered: FTS5 result order first, then tag matches
            // not already included, in their query order.
            var exactSeen = Set<String>()
            var exactIDs: [String] = []
            for id in ftsIDs + tagIDs where !exactSeen.contains(id) {
                exactIDs.append(id); exactSeen.insert(id)
            }

            // 3) Semantic hits (embedding cosine similarity), merged after
            // exact hits — exact first, semantic by descending similarity.
            let semantic = (queryVector.flatMap {
                try? SemanticSearch.semanticIDs(queryVector: $0, db: db)
            }) ?? []
            let orderedIDs = SemanticSearch.merge(
                exactIDs: exactIDs, semantic: semantic, threshold: 0.45)
            guard !orderedIDs.isEmpty else { return [] }

            // Resolve to alive paths, preserving rank order.
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

        // Ranked results (exact-then-semantic) keep their rank order.
        let ranked: [FileNode] = scopedPaths.map { FileNode(url: URL(fileURLWithPath: $0)) }

        // Also do a basename substring match on enumerated files (so search
        // works even when files aren't indexed yet, scoped to current folder).
        // These unranked extras sort by modifiedAt and trail the ranked hits.
        var extras: [FileNode] = []
        if case .currentFolder(let url) = scope {
            let candidates = FolderReader.files(in: url, showHidden: false)
            let lower = trimmed.lowercased()
            for f in candidates {
                if f.basename.lowercased().contains(lower),
                   !ranked.contains(where: { $0.url.standardizedFileURL == f.url.standardizedFileURL }),
                   !extras.contains(where: { $0.url.standardizedFileURL == f.url.standardizedFileURL }) {
                    extras.append(f)
                }
            }
        }

        return ranked + extras.sorted { ($0.modifiedAt ?? .distantPast) > ($1.modifiedAt ?? .distantPast) }
    }

    /// Escape a user query for FTS5: split into tokens, prefix-match each,
    /// AND them together. Defensive against punctuation that breaks the parser.
    private static func ftsEscape(_ raw: String) -> String {
        let cleaned = raw.replacingOccurrences(
            of: "[\"\\(\\)*]",
            with: " ",
            options: .regularExpression
        )
        let tokens = cleaned
            .split(whereSeparator: { $0.isWhitespace })
            .filter { !$0.isEmpty }
        if tokens.isEmpty { return "\"\"" }
        return tokens.map { "\"\($0)\"*" }.joined(separator: " AND ")
    }
}
