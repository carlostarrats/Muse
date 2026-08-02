//
//  EditStore.swift
//  Muse
//
//  The @MainActor seam for edit stacks — a Pattern B singleton, observed
//  directly by views. `AppState` is frozen, and this store's integration cost
//  is deliberately ZERO: not even a forwarded `objectWillChange`. The grid
//  picks up changes through `EditStore.generation` inside its existing
//  `gridSignature` string, which is all it needs.
//
//  The SAVE SEQUENCE lives here, in one place, in order. Every step exists for
//  a reason and the order matters:
//
//    1. resolve the (file_id, parent_dir) scope from the alive path
//    2. EditRecordStore.write — or DELETE, when the stack is neutral
//    3. refresh the provider index (so every consumer sees the new stack)
//    4. AppState.markContentChanged — the tile-refresh seam, which already
//       drops BOTH thumbnail-key variants and bumps the tile task token
//    5. generation += 1 — relayout, because a crop changes the tile's aspect
//    6. exportSidecarsAfterEditChange — the only editAuthoritative writer
//
//  Step 3 before step 4 is load-bearing: `markContentChanged` computes the
//  edited cache-key variant from the index, so invalidating first would clear
//  the OLD pair and leave the new stack's PNGs live.
//

import Foundation

@MainActor
final class EditStore: ObservableObject {
    static let shared = EditStore()
    private init() {}

    /// Bumped on every mutation. The grid folds it into `gridSignature`;
    /// nothing subscribes to this store directly.
    @Published private(set) var generation = 0

    /// The app's `AppState`, installed once at launch.
    ///
    /// This is a one-way reference OUT of the store, not an integration: the
    /// store publishes nothing to AppState, forwards no `objectWillChange`,
    /// and adds no `@Published` property there. It exists because
    /// `markContentChanged` is the app's single tile-refresh seam (it drops
    /// both thumbnail-key variants AND bumps the tile task token), and an edit
    /// save needs exactly that. Reimplementing half of it here is how the two
    /// paths drift. Weak, because AppState owns the app's lifetime and this
    /// singleton must not extend it.
    private weak var host: AppState?

    func installHost(_ appState: AppState) {
        host = appState
    }

    /// alive path → number of saved versions/snapshots, for the grid badge's
    /// count suffix. Refreshed alongside the index rather than queried per
    /// tile — a per-tile DB read on the grid's critical path is the thing this
    /// map exists to avoid.
    @Published private(set) var versionCounts: [String: Int] = [:]

    // MARK: - Read

    func stack(for url: URL) async -> EditStack? {
        // The index is the fast path and is already correct for any file the
        // user can see; fall back to the DB only for a file the index hasn't
        // been warmed for yet (e.g. one opened straight from a search result).
        if let cached = EditStackIndex.resolvedStack(for: url) { return cached }
        guard let queue = Database.shared.dbQueue,
              let scope = await scope(for: url) else { return nil }
        let row = try? await queue.read { db in
            try EditRecordStore.read(fileID: scope.fileID, parentDir: scope.parentDir, db: db)
        }
        return row.flatMap { EditStackCodec.decode($0.stack) }
    }

    func versions(for url: URL) async -> [EditVersionRow] {
        guard let queue = Database.shared.dbQueue,
              let scope = await scope(for: url) else { return [] }
        return (try? await queue.read { db in
            try EditRecordStore.versions(fileID: scope.fileID, parentDir: scope.parentDir, db: db)
        }) ?? []
    }

    // MARK: - Write

    func save(_ stack: EditStack, for url: URL) async {
        guard let queue = Database.shared.dbQueue,
              let scope = await scope(for: url) else { return }
        let normalized = stack.normalized()
        let now = Int64(Date().timeIntervalSince1970)

        // NOTHING CHANGED → do nothing. The save sequence ends in
        // `generation += 1`, which is in the grid's signature, so an
        // unconditional save relaid the whole grid and reloaded every visible
        // tile's aspect — every photo appeared to load in again. Leaving the
        // editor calls save() whether or not a slider ever moved, so this was
        // the common case, not the rare one.
        let current = await self.stack(for: url)
        if (current ?? .fresh()).normalized() == normalized { return }

        if normalized.isNeutral {
            // "No edit" is the ABSENCE of a row, never a stored no-op — which
            // is also what reverts the thumbnail key to its unedited variant.
            try? await queue.write { db in
                try EditRecordStore.delete(fileID: scope.fileID,
                                           parentDir: scope.parentDir, db: db)
            }
        } else {
            guard let json = try? EditStackCodec.encode(normalized) else { return }
            let hash = EditStackCodec.hash(normalized)
            try? await queue.write { db in
                try EditRecordStore.write(stackJSON: json, hash: hash,
                                          processVersion: normalized.processVersion,
                                          fileID: scope.fileID, parentDir: scope.parentDir,
                                          updatedAt: now, db: db)
            }
        }
        await applySaveConsequences(for: [url])
    }

    func reset(for url: URL) async {
        await save(.fresh(), for: url)
    }

    func saveVersion(name: String, kind: String, stack: EditStack, for url: URL) async {
        guard let queue = Database.shared.dbQueue,
              let scope = await scope(for: url),
              let json = try? EditStackCodec.encode(stack.normalized()) else { return }
        let row = EditVersionRow(id: UUID().uuidString, file_id: scope.fileID,
                                 parent_dir: scope.parentDir, kind: kind, name: name,
                                 stack: json, created_at: Int64(Date().timeIntervalSince1970))
        try? await queue.write { db in try EditRecordStore.addVersion(row, db: db) }
        await refreshVersionCounts(paths: [url.standardizedFileURL.path])
        generation += 1
    }

    func deleteVersion(id: String, for url: URL) async {
        guard let queue = Database.shared.dbQueue else { return }
        try? await queue.write { db in try EditRecordStore.deleteVersion(id: id, db: db) }
        await refreshVersionCounts(paths: [url.standardizedFileURL.path])
        generation += 1
    }

    /// Switching auto-preserves the CURRENT stack as a version first, so
    /// picking the wrong version is never destructive — there is exactly one
    /// current stack (path-keyed identity can't show one file twice), so
    /// without this the stack you switched away from would be gone.
    func switchToVersion(_ id: String, for url: URL) async {
        let versionsList = await versions(for: url)
        guard let target = versionsList.first(where: { $0.id == id }),
              let targetStack = EditStackCodec.decode(target.stack) else { return }
        let current = await stack(for: url) ?? .fresh()
        if !current.isNeutral, !versionsList.contains(where: {
            EditStackCodec.decode($0.stack) == current
        }) {
            // CANONICAL ENGLISH, not String(localized:). This name is generated
            // by Muse, not typed by the user, and it is persisted — so the
            // app-wide rule applies: storage stays canonical, localization
            // happens at display time (`EditVersionName.display`). Persisting
            // the translation would leave a French library holding "Précédent"
            // rows that an English relaunch shows untranslated, and would mix
            // languages for anyone who ever switches.
            await saveVersion(name: EditVersionName.autoPreserved, kind: "version",
                              stack: current, for: url)
        }
        await save(targetStack, for: url)
    }

    /// Apply one stack to many files (batch "Paste Adjustments"). Each file
    /// runs the FULL save sequence, so tiles refresh as the sweep progresses —
    /// no progress UI, per the status-pill-is-background-work-only rule.
    func applyToAll(_ transform: @Sendable (EditStack) -> EditStack, urls: [URL]) async {
        for url in urls {
            let current = await stack(for: url) ?? .fresh()
            await save(transform(current), for: url)
        }
    }

    // MARK: - Index

    /// Full rebuild — launch, and after anything that rewrites paths wholesale
    /// (a move or a folder rename).
    func rebuildIndex() async {
        guard let queue = Database.shared.dbQueue else { return }
        let entries = (try? await queue.read { db in
            try EditRecordStore.allWithAlivePaths(db: db)
        }) ?? []
        // Building the index decodes every stack's JSON and, for a LUT-bearing
        // stack, does a synchronous multi-MB `queue.read` inside
        // `EditRenderer.canRender` → `LutRegistry.rgbaCube` — both of whose
        // headers say in as many words that they must never run on the main
        // thread. This store is @MainActor, so the work has to be handed off
        // explicitly. The index itself is lock-guarded, so it is safe to write
        // from anywhere.
        await Task.detached(priority: .userInitiated) {
            EditStackIndex.rebuild(entries: entries)
        }.value
        await refreshVersionCounts()
    }

    /// Incremental refresh scoped to `paths` — a folder load, and every save.
    /// `clearingScope: paths` is what makes a reset take effect: the entry has
    /// to be REMOVED, not merely not-re-added.
    func warmIndex(paths: [String]) async {
        guard !paths.isEmpty, let queue = Database.shared.dbQueue else { return }
        let wanted = paths.map { URL(fileURLWithPath: $0).standardizedFileURL.path }
        // Scoped query, not "load every edit in the library and filter in
        // Swift": this runs on every save, i.e. every 400 ms of slider
        // movement once autosave fires.
        let entries = (try? await queue.read { db in
            try EditRecordStore.withAlivePaths(wanted, db: db)
        }) ?? []
        // Off-main for the same reason as `rebuildIndex` — see there.
        await Task.detached(priority: .userInitiated) {
            EditStackIndex.merge(entries: entries, clearingScope: wanted)
        }.value
    }

    /// Full refresh — launch and wholesale path rewrites only.
    private func refreshVersionCounts() async {
        guard let queue = Database.shared.dbQueue else { return }
        versionCounts = (try? await queue.read { db in
            try EditRecordStore.versionCounts(db: db)
        }) ?? [:]
    }

    /// Scoped refresh — the per-save case. A missing count REMOVES the key,
    /// which is what makes deleting the last version drop the badge.
    private func refreshVersionCounts(paths: [String]) async {
        guard !paths.isEmpty, let queue = Database.shared.dbQueue else { return }
        let counts = (try? await queue.read { db in
            try EditRecordStore.versionCounts(forPaths: paths, db: db)
        }) ?? [:]
        for path in paths { versionCounts[path] = counts[path] }
    }

    // MARK: - Save consequences

    private func applySaveConsequences(for urls: [URL]) async {
        let paths = urls.map { $0.standardizedFileURL.path }
        // Index BEFORE invalidation: `markContentChanged` derives the edited
        // cache-key variant from the index, so the other order clears the old
        // pair and leaves the new stack's PNGs live.
        await warmIndex(paths: paths)
        await refreshVersionCounts(paths: paths)
        host?.markContentChanged(paths)
        generation += 1
        await AnalyzePipeline.shared.exportSidecarsAfterEditChange(for: urls)
    }

    /// Called by the sidecar hydrator after applying an incoming edit — the
    /// same consequences as a local save, minus the sidecar re-export (which
    /// would bounce the edit straight back at the device that sent it).
    func applyHydratedConsequences(for urls: [URL]) async {
        let paths = urls.map { $0.standardizedFileURL.path }
        await warmIndex(paths: paths)
        await refreshVersionCounts(paths: paths)
        host?.markContentChanged(paths)
        generation += 1
    }

    // MARK: - Scope resolution

    struct Scope: Sendable { let fileID: String; let parentDir: String }

    /// Resolve (file_id, parent_dir) from an alive path — the same join
    /// `TagStore` uses, because an edit shares tags' grain exactly.
    func scope(for url: URL) async -> Scope? {
        guard let queue = Database.shared.dbQueue else { return nil }
        let absPath = url.standardizedFileURL.path
        let dir = TagScope.parentDir(ofPath: absPath)
        let fileID = try? await queue.read { db -> String? in
            try String.fetchOne(db, sql: """
                SELECT file_id FROM paths
                WHERE absolute_path = ? AND is_alive = 1 AND file_id IS NOT NULL
                LIMIT 1
                """, arguments: [absPath])
        }
        guard let fileID = fileID ?? nil else { return nil }
        return Scope(fileID: fileID, parentDir: dir)
    }
}
