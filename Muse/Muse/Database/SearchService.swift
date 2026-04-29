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

        let absPaths: [String] = (try? await queue.read { db -> [String] in
            // 1) FTS5 hits
            let ftsRows = try Row.fetchAll(
                db,
                sql: "SELECT file_id FROM files_fts WHERE files_fts MATCH ?",
                arguments: [escaped]
            )
            let ftsIDs = ftsRows.compactMap { $0["file_id"] as String? }

            // 2) Tag label matches (for indexed content)
            let tagIDs = try TagRow
                .filter(TagRow.Columns.label.like("%" + trimmed + "%"))
                .fetchAll(db)
                .map { $0.file_id }

            let allIDs = Array(Set(ftsIDs + tagIDs))
            guard !allIDs.isEmpty else { return [] }

            // Resolve to alive paths
            let placeholders = allIDs.map { _ in "?" }.joined(separator: ",")
            let pathRows = try PathRow.fetchAll(
                db,
                sql: "SELECT * FROM paths WHERE file_id IN (\(placeholders)) AND is_alive = 1",
                arguments: StatementArguments(allIDs)
            )
            return pathRows.map { $0.absolute_path }
        }) ?? []

        // Filter by scope
        let scopedPaths: [String]
        switch scope {
        case .currentFolder(let url):
            let prefix = url.standardizedFileURL.path
            scopedPaths = absPaths.filter { $0.hasPrefix(prefix) }
        case .everywhere:
            scopedPaths = absPaths
        }

        // Also do a basename substring match on enumerated files (so search
        // works even when files aren't indexed yet, scoped to current folder).
        var results: [FileNode] = scopedPaths.map { FileNode(url: URL(fileURLWithPath: $0)) }

        if case .currentFolder(let url) = scope {
            let candidates = FolderReader.files(in: url, showHidden: false)
            let lower = trimmed.lowercased()
            for f in candidates {
                if f.basename.lowercased().contains(lower),
                   !results.contains(where: { $0.url.standardizedFileURL == f.url.standardizedFileURL }) {
                    results.append(f)
                }
            }
        }

        return results.sorted { ($0.modifiedAt ?? .distantPast) > ($1.modifiedAt ?? .distantPast) }
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
