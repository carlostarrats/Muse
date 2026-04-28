//
//  BookmarkStore.swift
//  Muse
//
//  Persists Roots (security-scoped bookmarks) so the user's folder
//  selections survive relaunch under sandbox. Stores in UserDefaults —
//  small, flat, predictable.
//

import Foundation
import AppKit

@MainActor
final class BookmarkStore: ObservableObject {
    private static let defaultsKey = "muse.roots.v1"

    @Published private(set) var roots: [Root] = []

    /// URLs we've called `startAccessingSecurityScopedResource()` on so we can
    /// balance with stop-access at app exit. Keyed by Root.id.
    private var accessedURLs: [UUID: URL] = [:]

    init() {
        load()
    }

    // MARK: - Persistence

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: Self.defaultsKey),
              let decoded = try? JSONDecoder().decode([Root].self, from: data) else {
            return
        }
        roots = decoded
        // Activate access for each persisted root.
        for root in roots {
            activate(root)
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(roots) {
            UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        }
    }

    // MARK: - Add / Remove

    /// Show an NSOpenPanel and add the chosen folder as a new root.
    /// Returns the new Root, or nil if the user cancelled.
    @discardableResult
    func pickAndAddRoot() -> Root? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Pick a folder for Muse to view."
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return addRoot(at: url)
    }

    @discardableResult
    func addRoot(at url: URL) -> Root? {
        guard let data = try? url.bookmarkData(
            options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ) else { return nil }
        let root = Root(
            id: UUID(),
            displayName: url.lastPathComponent,
            bookmarkData: data,
            addedAt: Date()
        )
        roots.append(root)
        save()
        activate(root)
        return root
    }

    func removeRoot(_ root: Root) {
        if let url = accessedURLs[root.id] {
            url.stopAccessingSecurityScopedResource()
            accessedURLs.removeValue(forKey: root.id)
        }
        roots.removeAll { $0.id == root.id }
        save()
    }

    // MARK: - Access

    /// Returns the resolved URL for a root, or nil if the bookmark is stale or
    /// the resource is unavailable. Caller should not call start/stop access —
    /// the BookmarkStore manages that lifetime for active roots.
    func url(for root: Root) -> URL? {
        accessedURLs[root.id]
    }

    private func activate(_ root: Root) {
        guard let url = root.resolveURL() else { return }
        if url.startAccessingSecurityScopedResource() {
            accessedURLs[root.id] = url
        }
    }

    deinit {
        for url in accessedURLs.values {
            url.stopAccessingSecurityScopedResource()
        }
    }
}
