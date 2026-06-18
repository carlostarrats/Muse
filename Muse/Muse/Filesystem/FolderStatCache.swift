//
//  FolderStatCache.swift
//  Muse
//
//  Caches a FolderStat per top-level folder for the sidebar's counts + sort.
//  Computes off-main; keeps stats live via an FSEvents watch over ALL root paths
//  (recursive — FSEvents reports descendants), so adds/removes/edits anywhere
//  under a root refresh that root's number. Recomputes are coalesced.
//

import Foundation

@MainActor
final class FolderStatCache: ObservableObject {
    /// Stats keyed by standardized root path.
    @Published private(set) var stats: [String: FolderStat] = [:]

    private var roots: [URL] = []
    private var watcher: FolderWatcher?
    private var watchedPaths: Set<String> = []
    private var pending: Set<String> = []
    private var debounce: DispatchWorkItem?

    func stat(for url: URL) -> FolderStat? {
        stats[url.standardizedFileURL.path]
    }

    /// Point the cache at the current top-level folders: drop stats for folders
    /// that went away, restart the watcher only when the root-path SET actually
    /// changed (a drag-reorder with the same folders must NOT rebuild the watcher
    /// or re-walk any root), and recompute only newly added roots.
    func update(roots newRoots: [URL]) {
        roots = newRoots.map { $0.standardizedFileURL }
        let newKeys = Set(roots.map(\.path))
        stats = stats.filter { newKeys.contains($0.key) }

        if newKeys != watchedPaths {
            watcher = FolderWatcher { [weak self] paths in
                self?.handle(paths: paths)   // delivered on main by FolderWatcher.fire
            }
            watcher?.watch(urls: roots)
            watchedPaths = newKeys
        }

        // Only recompute roots not already cached; existing roots stay live via
        // the watcher and must not be re-walked on every publish (e.g. reorder).
        for r in roots where stats[r.standardizedFileURL.path] == nil { recompute(r) }
    }

    private func handle(paths: [String]) {
        let affected = Set(paths.compactMap { rootForMediaChange($0) })
        guard !affected.isEmpty else { return }
        pending.formUnion(affected)
        debounce?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let todo = self.pending
            self.pending.removeAll()
            for p in todo { self.recompute(URL(fileURLWithPath: p)) }
        }
        debounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    /// The watched root containing `path`, but only for a change Muse's count
    /// cares about: ignore hidden / dotfile-segment paths (e.g. `.muse` sidecars
    /// written on every analyze pass, `.DS_Store`). The recursive walk uses
    /// `skipsHiddenFiles`, so such changes never alter the count — mapping them to
    /// a root would just schedule a redundant full re-walk (and a spurious
    /// re-render) on every analyze. Returns the standardized root path, or nil.
    private func rootForMediaChange(_ path: String) -> String? {
        guard let root = FolderStats.root(containing: path, in: roots) else { return nil }
        let rootPath = root.standardizedFileURL.path
        let std = URL(fileURLWithPath: path).standardizedFileURL.path
        if std.hasPrefix(rootPath + "/") {
            let relative = std.dropFirst(rootPath.count + 1)
            if relative.split(separator: "/").contains(where: { $0.hasPrefix(".") }) {
                return nil
            }
        }
        return rootPath
    }

    private func recompute(_ root: URL) {
        let key = root.standardizedFileURL.path
        Task.detached(priority: .utility) { [weak self] in
            // Passes showHidden: false (the default). If a "show hidden files"
            // option ever becomes user-facing, this must read AppState.showHidden
            // so the sidebar count stays in sync with the grid.
            let stat = FolderStats.compute(folder: root)
            await MainActor.run {
                guard let self, self.roots.contains(where: { $0.path == key }) else { return }
                self.stats[key] = stat
            }
        }
    }
}
