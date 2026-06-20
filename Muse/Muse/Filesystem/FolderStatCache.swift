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

/// Pure debounce policy for the folder-stat recompute. A plain trailing debounce
/// (reschedule on every event) starves forever under a *sustained* event stream:
/// FSEvents arriving faster than `quiet` reset it indefinitely, so the recompute
/// never runs and the sidebar count freezes — e.g. while iCloud syncs newly
/// imported files during a long analysis. The cap (`maxWait`) forces a flush once
/// the current burst has run that long, guaranteeing the count refreshes even
/// under continuous churn. Mirrors lodash's debounce `{ maxWait }`.
nonisolated enum StatRecomputeScheduler {
    enum Decision: Equatable {
        case flushNow
        case debounce(TimeInterval)
    }
    static func decide(burstStart: TimeInterval, now: TimeInterval,
                       quiet: TimeInterval = 0.4, maxWait: TimeInterval = 2.0) -> Decision {
        (now - burstStart >= maxWait) ? .flushNow : .debounce(quiet)
    }
}

@MainActor
final class FolderStatCache: ObservableObject {
    /// Stats keyed by standardized root path.
    @Published private(set) var stats: [String: FolderStat] = [:]

    private var roots: [URL] = []
    private var watcher: FolderWatcher?
    private var watchedPaths: Set<String> = []
    private var pending: Set<String> = []
    private var debounce: DispatchWorkItem?
    /// systemUptime of the first event in the current un-flushed burst; drives
    /// the maxWait cap so a continuous event stream can't starve the recompute.
    private var burstStart: TimeInterval?

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

        let now = ProcessInfo.processInfo.systemUptime
        let start = burstStart ?? now
        burstStart = start
        debounce?.cancel()
        debounce = nil

        switch StatRecomputeScheduler.decide(burstStart: start, now: now) {
        case .flushNow:
            // Burst has run past the cap — recompute now instead of resetting the
            // timer again, so a continuous FSEvents stream (iCloud sync churn
            // during a long analysis) can't freeze the count indefinitely.
            flush()
        case .debounce(let quiet):
            let work = DispatchWorkItem { [weak self] in self?.flush() }
            debounce = work
            DispatchQueue.main.asyncAfter(deadline: .now() + quiet, execute: work)
        }
    }

    /// Recompute every pending root, then reset the burst + debounce state so the
    /// next event starts a fresh window.
    private func flush() {
        debounce = nil
        burstStart = nil
        let todo = pending
        pending.removeAll()
        for p in todo { recompute(URL(fileURLWithPath: p)) }
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
