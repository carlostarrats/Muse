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
    case dominantColor, shape

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .dateModified: return String(localized: "Date Modified")
        case .dateCreated: return String(localized: "Date Created")
        case .name: return String(localized: "Name")
        case .size: return String(localized: "Size")
        case .kind: return String(localized: "Kind")
        case .dominantColor: return String(localized: "Color")
        case .shape: return String(localized: "Shape")
        }
    }

    /// Color and Shape read Vision data written by Analyze (the ✨ button);
    /// un-analyzed files fall back to date order.
    var requiresIndexedData: Bool {
        switch self {
        case .dominantColor, .shape: return true
        default: return false
        }
    }

    /// The direction this mode sorts in by DEFAULT (when `sortReversed` is
    /// false) — matches the comparators in `SmartSorter.apply`. Drives the
    /// toolbar direction arrow (up = ascending).
    var defaultAscending: Bool {
        switch self {
        case .name, .kind, .dominantColor: return true   // A→Z / first bucket first
        case .dateModified, .dateCreated, .size, .shape: return false // newest/largest/widest first
        }
    }

    /// Human-readable description of the CURRENT direction, for the arrow's
    /// tooltip. `ascending` is the effective direction (default XOR reversed).
    func directionLabel(ascending: Bool) -> String {
        switch self {
        case .dateModified, .dateCreated: return ascending ? "Oldest first" : "Newest first"
        case .name, .kind:                return ascending ? "A → Z" : "Z → A"
        case .size:                       return ascending ? "Smallest first" : "Largest first"
        case .shape:                      return ascending ? "Tall → wide" : "Wide → tall"
        case .dominantColor:              return ascending ? "Ascending" : "Descending"
        }
    }

    /// The sort modes that apply to a *collection* (a group, not a file).
    /// Size/Kind/Color/Shape are per-image properties a collection lacks, so the
    /// Collections-page sort menu shows only these three.
    static let collectionCases: [SortMode] = [.name, .dateCreated, .dateModified]
}

// Nonisolated: pure value-type sorting plus thread-safe DB reads
// (Database.shared.dbQueue is an immutable Sendable let, GRDB reads are
// thread-safe). This lets folder loads run the sort off the main thread.
nonisolated enum SmartSorter {

    /// Sort files by `mode`. `reversed` flips the result so any mode can run
    /// in either direction (the toolbar direction arrow). Reversing the fully
    /// ordered array works uniformly across every mode — including the
    /// index-aware Color/Shape sorts and their date tiebreaks.
    static func apply(_ mode: SortMode, to files: [FileNode],
                      reversed: Bool = false) -> [FileNode] {
        let result = ordered(mode, files)
        return reversed ? result.reversed() : result
    }

    /// The mode's natural order (its `defaultAscending` direction).
    private static func ordered(_ mode: SortMode, _ files: [FileNode]) -> [FileNode] {
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
        case .shape:
            // Aspect-ratio continuum: widest landscape → square → tallest
            // portrait. Files without analyzed dimensions (ratio 0) sink to
            // the end, tiebroken by date.
            return sortByIndexed(files: files, descending: true,
                                 valueFor: { _ in nil as String? },
                                 numericFor: { row in
                guard let w = row.width, let h = row.height, h > 0 else { return 0 }
                return (w * 1000) / h
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
