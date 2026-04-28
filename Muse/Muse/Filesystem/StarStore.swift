//
//  StarStore.swift
//  Muse
//
//  Persists starred folders in SQLite. Each starred entry gets a
//  bookmark so we can resolve the path under sandbox even after the
//  user closes the parent root.
//

import Foundation
import GRDB
import AppKit

@MainActor
final class StarStore: ObservableObject {

    @Published private(set) var starred: [StarredFolder] = []

    init() {
        load()
    }

    struct StarredFolder: Identifiable, Hashable {
        let id: String
        let path: String
        let displayName: String
        let bookmarkData: Data?
    }

    func load() {
        guard let queue = Database.shared.dbQueue else { return }
        do {
            let rows = try queue.read { db in
                try StarredFolderRow.fetchAll(db)
            }
            self.starred = rows
                .map {
                    StarredFolder(
                        id: $0.id,
                        path: $0.absolute_path,
                        displayName: $0.display_name,
                        bookmarkData: $0.bookmark_data
                    )
                }
                .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
        } catch {
            print("[StarStore] load failed: \(error)")
        }
    }

    func star(folder: URL) {
        guard let queue = Database.shared.dbQueue else { return }
        let bookmark = try? folder.bookmarkData(
            options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        var row = StarredFolderRow(
            id: UUID().uuidString,
            absolute_path: folder.standardizedFileURL.path,
            bookmark_data: bookmark,
            display_name: folder.lastPathComponent,
            added_at: Int64(Date().timeIntervalSince1970)
        )
        do {
            try queue.write { db in
                try row.insert(db, onConflict: .ignore)
            }
            load()
        } catch {
            print("[StarStore] star failed: \(error)")
        }
    }

    func unstar(folder: URL) {
        guard let queue = Database.shared.dbQueue else { return }
        let path = folder.standardizedFileURL.path
        do {
            try queue.write { db in
                _ = try StarredFolderRow
                    .filter(Column("absolute_path") == path)
                    .deleteAll(db)
            }
            load()
        } catch {
            print("[StarStore] unstar failed: \(error)")
        }
    }

    func isStarred(_ folder: URL) -> Bool {
        let path = folder.standardizedFileURL.path
        return starred.contains { $0.path == path }
    }

    /// Resolve a starred folder back to a URL with security scope.
    func resolveURL(for star: StarredFolder) -> URL? {
        guard let data = star.bookmarkData else {
            return URL(fileURLWithPath: star.path)
        }
        var isStale = false
        return try? URL(
            resolvingBookmarkData: data,
            options: [.withSecurityScope],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )
    }
}
