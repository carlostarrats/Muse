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
    private var pending: Set<String> = []
    private var debounce: DispatchWorkItem?

    func stat(for url: URL) -> FolderStat? {
        stats[url.standardizedFileURL.path]
    }

    /// Point the cache at the current top-level folders: (re)start the watcher,
    /// drop stats for folders that went away, and recompute each root. Safe to
    /// call repeatedly (launch + whenever the roots change).
    func update(roots newRoots: [URL]) {
        roots = newRoots.map { $0.standardizedFileURL }
        let live = Set(roots.map(\.path))
        stats = stats.filter { live.contains($0.key) }

        watcher = FolderWatcher { [weak self] paths in
            self?.handle(paths: paths)   // delivered on main by FolderWatcher.fire
        }
        watcher?.watch(urls: roots)

        for r in roots { recompute(r) }
    }

    private func handle(paths: [String]) {
        let affected = Set(paths.compactMap {
            FolderStats.root(containing: $0, in: roots)?.standardizedFileURL.path
        })
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

    private func recompute(_ root: URL) {
        let key = root.standardizedFileURL.path
        Task.detached(priority: .utility) { [weak self] in
            let stat = FolderStats.compute(folder: root)
            await MainActor.run { self?.stats[key] = stat }
        }
    }
}
