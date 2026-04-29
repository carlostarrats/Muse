//
//  SmartSorter.swift
//  Muse
//
//  Sort modes for the grid. Standard sorts are pure (work at the
//  enumerated stage). Smart sorts depend on indexed Vision data and
//  fall back to date-modified when data is missing.
//

import Foundation
import GRDB

enum SortMode: String, CaseIterable, Identifiable {
    case dateModified, dateCreated, name, size, kind
    case dominantColor, faceCount, hasText

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .dateModified: return "Date Modified"
        case .dateCreated: return "Date Created"
        case .name: return "Name"
        case .size: return "Size"
        case .kind: return "Kind"
        case .dominantColor: return "Dominant Color"
        case .faceCount: return "Faces"
        case .hasText: return "Has Text"
        }
    }

    var requiresIndexedData: Bool {
        switch self {
        case .dominantColor, .faceCount, .hasText: return true
        default: return false
        }
    }
}

@MainActor
enum SmartSorter {

    /// Sort (and optionally group) files. For smart sorts, looks up the
    /// indexed FileRow and uses its data; falls back to a stable date-modified
    /// order for any files not yet indexed.
    static func apply(_ mode: SortMode, to files: [FileNode]) -> [FileNode] {
        switch mode {
        case .dateModified:
            return files.sorted { ($0.modifiedAt ?? .distantPast) > ($1.modifiedAt ?? .distantPast) }
        case .dateCreated:
            return files.sorted { ($0.createdAt ?? .distantPast) > ($1.createdAt ?? .distantPast) }
        case .name:
            return files.sorted { $0.basename.localizedStandardCompare($1.basename) == .orderedAscending }
        case .size:
            return files.sorted { ($0.sizeBytes ?? 0) > ($1.sizeBytes ?? 0) }
        case .kind:
            return files.sorted { $0.kind.rawValue < $1.kind.rawValue }
        case .dominantColor:
            return sortByIndexed(files: files, valueFor: { row in row.dominant_color })
        case .faceCount:
            return sortByIndexed(files: files, descending: true,
                                 valueFor: { _ in nil as String? },
                                 numericFor: { row in
                // tags table has face count? we encode it implicitly via vision tags;
                // for v1, just use the FileRow.feature_print presence as a proxy
                row.feature_print != nil ? 1 : 0
            })
        case .hasText:
            return sortByIndexed(files: files, descending: true,
                                 valueFor: { _ in nil as String? },
                                 numericFor: { row in
                // We index OCR text via files_fts; check via caption containing "text:"
                (row.caption?.contains("text:") == true) ? 1 : 0
            })
        }
    }

    // MARK: - Index-aware sorts

    private static func sortByIndexed(
        files: [FileNode],
        descending: Bool = false,
        valueFor: (FileRow) -> String?,
        numericFor: ((FileRow) -> Int)? = nil
    ) -> [FileNode] {
        let rows = indexedRows(for: files)
        let pairs: [(FileNode, String, Int)] = files.map { node in
            let row = rows[node.url.standardizedFileURL.path]
            let s = row.flatMap(valueFor) ?? ""
            let n = (row.flatMap { numericFor?($0) }) ?? 0
            return (node, s, n)
        }
        let sorted: [(FileNode, String, Int)]
        if numericFor != nil {
            sorted = pairs.sorted { lhs, rhs in
                if lhs.2 != rhs.2 { return descending ? lhs.2 > rhs.2 : lhs.2 < rhs.2 }
                // tiebreak by date modified
                return (lhs.0.modifiedAt ?? .distantPast) > (rhs.0.modifiedAt ?? .distantPast)
            }
        } else {
            sorted = pairs.sorted { lhs, rhs in
                if lhs.1 != rhs.1 {
                    return descending ? lhs.1 > rhs.1 : lhs.1 < rhs.1
                }
                return (lhs.0.modifiedAt ?? .distantPast) > (rhs.0.modifiedAt ?? .distantPast)
            }
        }
        return sorted.map { $0.0 }
    }

    /// Lookup FileRows for a list of FileNodes by absolute path.
    private static func indexedRows(for files: [FileNode]) -> [String: FileRow] {
        guard let queue = Database.shared.dbQueue else { return [:] }
        let paths = files.map { $0.url.standardizedFileURL.path }
        return (try? queue.read { db -> [String: FileRow] in
            guard !paths.isEmpty else { return [:] }
            let placeholders = paths.map { _ in "?" }.joined(separator: ",")
            let pathRows = try PathRow.fetchAll(
                db,
                sql: "SELECT * FROM paths WHERE absolute_path IN (\(placeholders)) AND is_alive = 1",
                arguments: StatementArguments(paths)
            )
            let fileIDs = pathRows.compactMap { $0.file_id }
            let fileRows = try FileRow.filter(fileIDs.contains(FileRow.Columns.id)).fetchAll(db)
            let byID = Dictionary(uniqueKeysWithValues: fileRows.map { ($0.id, $0) })
            var out: [String: FileRow] = [:]
            for path in pathRows {
                if let id = path.file_id, let row = byID[id] {
                    out[path.absolute_path] = row
                }
            }
            return out
        }) ?? [:]
    }
}
