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
        // Read-WRITE scope: Muse moves files to Trash (delete + undo), which
        // needs write access. `.securityScopeAllowOnlyReadAccess` made every
        // delete fail with afpAccessDenied even though reads worked. The app's
        // entitlement is user-selected.read-write, so this is permitted.
        guard let data = try? url.bookmarkData(
            options: [.withSecurityScope],
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

    // MARK: - Reorder

    /// Reorder by Root identity (manual sidebar ordering): move `moving` to sit
    /// just before/after `target`, or to the end when `target` is nil. Keyed by
    /// identity — not integer indices — so it stays correct even when the
    /// sidebar hides a root whose bookmark didn't resolve. Persists immediately.
    func reorder(_ moving: Root, relativeTo target: Root?, placeAfter: Bool) {
        guard moving != target,
              let from = roots.firstIndex(of: moving) else { return }
        var updated = roots
        updated.remove(at: from)
        if let target, let t = updated.firstIndex(of: target) {
            updated.insert(moving, at: placeAfter ? t + 1 : t)
        } else {
            updated.append(moving)
        }
        guard updated != roots else { return }   // dropped in place — no churn
        roots = updated
        save()
    }

    // MARK: - Rename

    /// After a ROOT folder is renamed on disk, repoint its bookmark + display
    /// name to the new location. Security-scoped bookmarks are inode-based and
    /// survive a same-volume rename, so the existing active scope still covers
    /// the moved folder; we mint a fresh bookmark from `newURL` (accessible via
    /// that live scope), swap access, and update the stored Root. Returns false
    /// if a new bookmark could not be created (access then stays on the old
    /// URL, which the caller surfaces as an error).
    @discardableResult
    func rootRenamed(_ root: Root, to newURL: URL) -> Bool {
        guard let data = try? newURL.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ) else { return false }

        // Drop the old scope, then build + activate the renamed root.
        if let old = accessedURLs[root.id] {
            old.stopAccessingSecurityScopedResource()
            accessedURLs.removeValue(forKey: root.id)
        }
        let renamed = Root(id: root.id,
                           displayName: newURL.lastPathComponent,
                           bookmarkData: data,
                           addedAt: root.addedAt)
        activate(renamed)   // resolves newURL + starts access + sets accessedURLs
        if let i = roots.firstIndex(of: root) {
            roots[i] = renamed   // @Published willSet → AppState rebuilds the tree
        }
        save()
        return true
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
