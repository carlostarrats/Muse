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

    /// Resolves the bookmark to a URL. Returned URL must have
    /// `startAccessingSecurityScopedResource()` called on it before reading,
    /// balanced by `stopAccessingSecurityScopedResource()`. Staleness is NOT
    /// handled here (a struct can't persist the re-minted data) — callers that
    /// own storage use `resolveURLReportingStale()` and re-mint.
    func resolveURL() -> URL? {
        resolveURLReportingStale()?.url
    }

    /// Like `resolveURL()`, but also reports the system's stale flag so the
    /// owning store can re-mint + persist fresh bookmark data — a stale
    /// bookmark keeps resolving for a while, then fails for good, silently
    /// dropping the root from the sidebar.
    func resolveURLReportingStale() -> (url: URL, isStale: Bool)? {
        var isStale = false
        guard let url = try? URL(
            resolvingBookmarkData: bookmarkData,
            options: [.withSecurityScope],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) else { return nil }
        return (url, isStale)
    }
}
