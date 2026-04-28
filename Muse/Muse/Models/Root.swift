//
//  Root.swift
//  Muse
//
//  A user-selected folder Muse has been pointed at. Backed by a
//  security-scoped bookmark so access survives relaunch even under
//  sandbox.
//

import Foundation

struct Root: Identifiable, Hashable, Codable {
    let id: UUID
    let displayName: String
    let bookmarkData: Data
    let addedAt: Date

    /// Resolves the bookmark to a URL, refreshing if the bookmark is stale.
    /// Returned URL must have `startAccessingSecurityScopedResource()` called
    /// on it before reading, balanced by `stopAccessingSecurityScopedResource()`.
    func resolveURL() -> URL? {
        var isStale = false
        let url = try? URL(
            resolvingBookmarkData: bookmarkData,
            options: [.withSecurityScope],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )
        return url
    }
}
