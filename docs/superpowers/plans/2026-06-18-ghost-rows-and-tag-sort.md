# Ghost-Row Reconcile + Tag-Chip Sort Control — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** (1) Stop deleted/moved files from lingering as `is_alive=1` rows that leak into search (blank tiles) and inflate collection counts; (2) add a toolbar control to sort the tag chips By Count (default) or A→Z.

**Architecture:** A new pure+DB `PathReconciler` runs inside the existing off-main folder load on a *fresh selection*: it diffs the enumerated on-disk set against the DB's alive rows scoped to that folder and flips vanished rows to `is_alive=0` (guarding evicted-but-present iCloud placeholders). The tag-sort control mirrors the existing `folderSortMode` settings pattern: a `TagSortMode` enum + `AppSettings` key + an `@Published` on `AppState` whose change re-runs `reloadTagChips()`, with `TagChipLoader.ordered(_:sortMode:)` made configurable.

**Tech Stack:** SwiftUI, GRDB (SQLite), XCTest, Xcode 16, macOS 14.6+.

## Global Constraints

- GRDB writes are async in app code (`try await queue.write`), but `PathReconciler` runs off-main in a detached task and may use the synchronous `try queue.write { }` / `try queue.read { }` overloads (it is NOT in an async context at the call site we add — it's plain synchronous code inside `Task.detached`).
- `AppState` is `@MainActor`; all `@Published` mutations happen on the main actor.
- No network. No new dependencies.
- Files are never deleted — `is_alive=0` only marks a row dead; the file (if it ever returns) is re-indexed normally.
- Forward fix only — NO one-time data migration / DB-patching pass (per memory `muse-fix-code-not-my-data`).
- Do NOT reintroduce size/mtime comparison for iCloud items (per memory `muse-icloud-content-refresh-override`); this change is filesystem-presence only, not metadata polling.
- Pure logic gets unit tests; the suite (`xcodebuild -scheme Muse test`) stays green.

---

### Task 1: `PathReconciler` pure scope + diff logic

**Files:**
- Create: `Muse/Muse/Filesystem/PathReconciler.swift`
- Test: `Muse/MuseTests/PathReconcilerTests.swift`

**Interfaces:**
- Produces: `PathReconciler.inScope(_ alivePaths: [String], folder: String, recursive: Bool) -> [String]`, `PathReconciler.vanished(inScope: [String], present: Set<String>) -> [String]`

- [ ] **Step 1: Write the failing tests** (`PathReconcilerTests.swift`)

```swift
import XCTest
@testable import Muse

final class PathReconcilerTests: XCTestCase {
    private let folder = "/Users/me/Inspo"

    // inScope — non-recursive keeps only direct children
    func testInScopeNonRecursiveDirectChildrenOnly() {
        let alive = ["/Users/me/Inspo/a.jpg",
                     "/Users/me/Inspo/sub/b.jpg",
                     "/Users/me/Other/c.jpg",
                     "/Users/me/Inspo.jpg"]           // sibling, not a child
        XCTAssertEqual(PathReconciler.inScope(alive, folder: folder, recursive: false),
                       ["/Users/me/Inspo/a.jpg"])
    }

    // inScope — recursive keeps the whole subtree
    func testInScopeRecursiveKeepsSubtree() {
        let alive = ["/Users/me/Inspo/a.jpg",
                     "/Users/me/Inspo/sub/b.jpg",
                     "/Users/me/Other/c.jpg"]
        XCTAssertEqual(Set(PathReconciler.inScope(alive, folder: folder, recursive: true)),
                       ["/Users/me/Inspo/a.jpg", "/Users/me/Inspo/sub/b.jpg"])
    }

    // vanished — in-scope paths NOT present on disk
    func testVanishedReturnsMissingOnly() {
        let scope = ["/Users/me/Inspo/a.jpg", "/Users/me/Inspo/gone.jpg"]
        let present: Set<String> = ["/Users/me/Inspo/a.jpg"]
        XCTAssertEqual(PathReconciler.vanished(inScope: scope, present: present),
                       ["/Users/me/Inspo/gone.jpg"])
    }

    func testVanishedEmptyWhenAllPresent() {
        let scope = ["/Users/me/Inspo/a.jpg"]
        XCTAssertTrue(PathReconciler.vanished(inScope: scope,
                                              present: ["/Users/me/Inspo/a.jpg"]).isEmpty)
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd "Muse" && xcodebuild -scheme Muse -destination 'platform=macOS' test -only-testing:MuseTests/PathReconcilerTests 2>&1 | tail -20`
Expected: FAIL — `cannot find 'PathReconciler' in scope`.

- [ ] **Step 3: Create `PathReconciler.swift` with the pure functions**

```swift
//
//  PathReconciler.swift
//  Muse
//
//  Reconciles the index against the filesystem: marks DB path rows DEAD when
//  the file they point at has vanished from disk (deleted or moved out of the
//  folder externally). Without this, a removed file's `is_alive = 1` row
//  lingers forever — leaking into search as a blank, unrenderable tile and
//  inflating collection counts. The normal grid hides this (it enumerates the
//  disk); search + collection counts query the DB by `is_alive`, so the ghost
//  rows surface there.
//
//  Driven per-folder on a fresh selection — the off-main folder load already
//  enumerates the folder, so the "present" set is free. Self-heals as the user
//  browses; no library-wide sweep, no data migration.
//

import Foundation
import GRDB

nonisolated enum PathReconciler {

    // MARK: - Pure scope + diff (unit-tested)

    /// Of `alivePaths`, the ones belonging to `folder` at the current depth:
    /// recursive → anywhere beneath it; non-recursive → direct children only.
    /// Standardized-path in, standardized-path out. Mirrors FolderEventFilter's
    /// scope rule so "what the grid shows" and "what we reconcile" agree.
    static func inScope(_ alivePaths: [String], folder: String,
                        recursive: Bool) -> [String] {
        let prefix = folder + "/"
        return alivePaths.filter { path in
            guard path.hasPrefix(prefix) else { return false }
            if recursive { return true }
            let relative = path.dropFirst(prefix.count)
            return !relative.contains("/")    // direct child only
        }
    }

    /// In-scope alive paths whose file is no longer in the enumerated set.
    static func vanished(inScope: [String], present: Set<String>) -> [String] {
        inScope.filter { !present.contains($0) }
    }
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `cd "Muse" && xcodebuild -scheme Muse -destination 'platform=macOS' test -only-testing:MuseTests/PathReconcilerTests 2>&1 | tail -20`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add "Muse/Muse/Filesystem/PathReconciler.swift" "Muse/MuseTests/PathReconcilerTests.swift"
git commit -m "feat: PathReconciler pure scope + diff for ghost-row cleanup"
```

---

### Task 2: `PathReconciler` filesystem guard + DB ops

**Files:**
- Modify: `Muse/Muse/Filesystem/PathReconciler.swift`
- Test: `Muse/MuseTests/PathReconcilerTests.swift` (add a DB-backed test)

**Interfaces:**
- Consumes: `Database.makeMigrator()`, GRDB `DatabaseQueue`, `databaseQuestionMarks(count:)` (module-level helper used by TagChipLoader).
- Produces: `PathReconciler.isEvictedPlaceholder(_ path: String) -> Bool`, `PathReconciler.aliveUnder(folder: String, queue: DatabaseQueue) -> [String]`, `@discardableResult PathReconciler.markDead(_ paths: [String], queue: DatabaseQueue) -> Int`, `@discardableResult PathReconciler.reconcile(folder: URL, recursive: Bool, present: Set<String>, queue: DatabaseQueue) -> Int`

- [ ] **Step 1: Write the failing DB test** (append to `PathReconcilerTests.swift`)

```swift
import GRDB

extension PathReconcilerTests {
    private func makeQueue() throws -> DatabaseQueue {
        let q = try DatabaseQueue()
        try Database.makeMigrator().migrate(q)
        return q
    }

    private func insertAlivePath(_ q: DatabaseQueue, _ path: String) throws {
        try q.write { db in
            try db.execute(sql: """
                INSERT INTO paths (id, file_id, absolute_path, bookmark_data, is_alive)
                VALUES (?, NULL, ?, NULL, 1)
                """, arguments: [UUID().uuidString, path])
        }
    }

    private func isAlive(_ q: DatabaseQueue, _ path: String) throws -> Int? {
        try q.read { db in
            try Int.fetchOne(db,
                sql: "SELECT is_alive FROM paths WHERE absolute_path = ?",
                arguments: [path])
        }
    }

    func testMarkDeadFlipsOnlyNamedRows() throws {
        let q = try makeQueue()
        try insertAlivePath(q, "/Users/me/Inspo/a.jpg")
        try insertAlivePath(q, "/Users/me/Inspo/gone.jpg")

        let n = PathReconciler.markDead(["/Users/me/Inspo/gone.jpg"], queue: q)
        XCTAssertEqual(n, 1)
        XCTAssertEqual(try isAlive(q, "/Users/me/Inspo/a.jpg"), 1)
        XCTAssertEqual(try isAlive(q, "/Users/me/Inspo/gone.jpg"), 0)

        // Idempotent: a second pass changes nothing.
        XCTAssertEqual(PathReconciler.markDead(["/Users/me/Inspo/gone.jpg"], queue: q), 0)
    }

    func testReconcileMarksMissingDeadKeepsPresent() throws {
        let q = try makeQueue()
        try insertAlivePath(q, "/Users/me/Inspo/a.jpg")
        try insertAlivePath(q, "/Users/me/Inspo/gone.jpg")
        try insertAlivePath(q, "/Users/me/Other/x.jpg")   // out of scope — untouched

        let n = PathReconciler.reconcile(
            folder: URL(fileURLWithPath: "/Users/me/Inspo"),
            recursive: false,
            present: ["/Users/me/Inspo/a.jpg"],
            queue: q)

        XCTAssertEqual(n, 1)
        XCTAssertEqual(try isAlive(q, "/Users/me/Inspo/a.jpg"), 1)
        XCTAssertEqual(try isAlive(q, "/Users/me/Inspo/gone.jpg"), 0)
        XCTAssertEqual(try isAlive(q, "/Users/me/Other/x.jpg"), 1)
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd "Muse" && xcodebuild -scheme Muse -destination 'platform=macOS' test -only-testing:MuseTests/PathReconcilerTests 2>&1 | tail -20`
Expected: FAIL — `cannot find 'markDead'`/`'reconcile'`.

- [ ] **Step 3: Add the FS guard + DB ops to `PathReconciler.swift`**

```swift
    // MARK: - Filesystem guard

    /// An OLD-STYLE evicted iCloud file shows a hidden `.<name>.icloud`
    /// placeholder instead of its real name, so the enumeration (which skips
    /// hidden files) won't list it — but it is NOT gone. Keep such rows alive.
    /// Modern dataless-in-place files keep their real name and ARE enumerated,
    /// so they never reach this guard.
    static func isEvictedPlaceholder(_ path: String) -> Bool {
        let url = URL(fileURLWithPath: path)
        let name = url.lastPathComponent
        let placeholder = url.deletingLastPathComponent()
            .appendingPathComponent(".\(name).icloud")
        return FileManager.default.fileExists(atPath: placeholder.path)
    }

    // MARK: - DB

    /// Every alive path under `folder` (prefix match bounds the read to the
    /// folder's subtree, not the whole library). LENGTH/SUBSTR computed in SQL
    /// so character semantics match (mirrors FolderRenameMigration's approach).
    static func aliveUnder(folder: String, queue: DatabaseQueue) -> [String] {
        let prefix = folder + "/"
        return (try? queue.read { db in
            try String.fetchAll(db, sql: """
                SELECT absolute_path FROM paths
                WHERE is_alive = 1 AND SUBSTR(absolute_path, 1, LENGTH(?)) = ?
                """, arguments: [prefix, prefix])
        }) ?? []
    }

    /// Flip the named alive paths to dead in one write. Returns rows changed.
    @discardableResult
    static func markDead(_ paths: [String], queue: DatabaseQueue) -> Int {
        guard !paths.isEmpty else { return 0 }
        return (try? queue.write { db -> Int in
            let marks = databaseQuestionMarks(count: paths.count)
            try db.execute(sql: """
                UPDATE paths SET is_alive = 0
                WHERE is_alive = 1 AND absolute_path IN (\(marks))
                """, arguments: StatementArguments(paths))
            return db.changesCount
        }) ?? 0
    }

    /// Full per-folder reconcile. `present` = standardized paths the folder
    /// enumeration found. Returns the number of rows marked dead.
    @discardableResult
    static func reconcile(folder: URL, recursive: Bool,
                          present: Set<String>, queue: DatabaseQueue) -> Int {
        let folderPath = folder.standardizedFileURL.path
        let alive = aliveUnder(folder: folderPath, queue: queue)
        let scoped = inScope(alive, folder: folderPath, recursive: recursive)
        let gone = vanished(inScope: scoped, present: present)
            .filter { !isEvictedPlaceholder($0) }
        return markDead(gone, queue: queue)
    }
```

- [ ] **Step 4: Run to verify it passes**

Run: `cd "Muse" && xcodebuild -scheme Muse -destination 'platform=macOS' test -only-testing:MuseTests/PathReconcilerTests 2>&1 | tail -20`
Expected: PASS (6 tests).

- [ ] **Step 5: Commit**

```bash
git add "Muse/Muse/Filesystem/PathReconciler.swift" "Muse/MuseTests/PathReconcilerTests.swift"
git commit -m "feat: PathReconciler DB ops + evicted-iCloud guard"
```

---

### Task 3: Wire reconcile into the folder load + refresh collections

**Files:**
- Modify: `Muse/Muse/Models/AppState.swift` (the `reloadCurrentFiles` detached task, ~826–918)

**Interfaces:**
- Consumes: `PathReconciler.reconcile(folder:recursive:present:queue:)`, `CollectionsEngine.shared.reload()`.

- [ ] **Step 1: Add the reconcile before chip computation** — in `reloadCurrentFiles`, inside `Task.detached`, after `let sorted = SmartSorter.apply(...)` and BEFORE the `if freshSelect, let dbQueue { ... chipRows ... }` block, insert:

```swift
            // Reconcile externally-deleted files on a fresh folder open: flip
            // DB rows for files that vanished from disk to is_alive=0, so they
            // stop leaking into search (blank tiles) + collection counts. Runs
            // BEFORE the chip counts below so those exclude the dead files too.
            var reconciledDead = 0
            if freshSelect, let dbQueue {
                let present = Set(raw.map { $0.url.standardizedFileURL.path })
                reconciledDead = PathReconciler.reconcile(
                    folder: folderURL, recursive: showSub,
                    present: present, queue: dbQueue)
            }
```

- [ ] **Step 2: Refresh collections on the main actor when rows died** — in the `await MainActor.run { ... }` block of the same task, after the `if thenIndex { ... }` line and before the closing brace, insert:

```swift
                // Marking ghosts dead shrinks alive-aware collection counts;
                // refresh the published cards so a stale count (e.g. "5" for a
                // collection with 1 real member) corrects immediately.
                if reconciledDead > 0 {
                    Task { await CollectionsEngine.shared.reload() }
                }
```

- [ ] **Step 3: Build to verify it compiles**

Run: `cd "Muse" && xcodebuild -scheme Muse -destination 'platform=macOS' build 2>&1 | tail -15`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Commit**

```bash
git add "Muse/Muse/Models/AppState.swift"
git commit -m "feat: reconcile deleted files on folder load; refresh collections"
```

---

### Task 4: `TagSortMode` enum + `AppSettings` key

**Files:**
- Create: `Muse/Muse/Models/TagSortMode.swift`
- Modify: `Muse/Muse/Settings/AppSettings.swift`

**Interfaces:**
- Produces: `enum TagSortMode: String, CaseIterable, Identifiable { case count, alphabetical; var label: String }`, `AppSettings.tagSortMode: TagSortMode { get set }`, `AppSettings.tagSortModeKey`.

- [ ] **Step 1: Create `TagSortMode.swift`**

```swift
//
//  TagSortMode.swift
//  Muse
//
//  How the tag chips above the grid are ordered. `.count` = most-used first
//  (the default / historical behavior, alphabetical tiebreak); `.alphabetical`
//  = A→Z. The actual ordering lives in TagChipLoader.ordered(_:sortMode:).
//

import Foundation

enum TagSortMode: String, CaseIterable, Identifiable {
    case count, alphabetical

    var id: String { rawValue }

    var label: String {
        switch self {
        case .count: return "Most Used"
        case .alphabetical: return "A → Z"
        }
    }
}
```

- [ ] **Step 2: Add the `AppSettings` accessor** — in `AppSettings.swift`, after the `folderSortMode` block (line 48), insert:

```swift

    static let tagSortModeKey = "tagSortMode"

    /// Tag-chip row sort order. Default `.count` (most-used first). Unset → count.
    static var tagSortMode: TagSortMode {
        get {
            (UserDefaults.standard.string(forKey: tagSortModeKey))
                .flatMap(TagSortMode.init(rawValue:)) ?? .count
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: tagSortModeKey) }
    }
```

- [ ] **Step 3: Build to verify it compiles**

Run: `cd "Muse" && xcodebuild -scheme Muse -destination 'platform=macOS' build 2>&1 | tail -15`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Commit**

```bash
git add "Muse/Muse/Models/TagSortMode.swift" "Muse/Muse/Settings/AppSettings.swift"
git commit -m "feat: TagSortMode enum + AppSettings.tagSortMode"
```

---

### Task 5: Make `TagChipLoader.ordered` configurable

**Files:**
- Modify: `Muse/Muse/Database/TagChipLoader.swift:35-43`
- Test: `Muse/MuseTests/TagChipLoaderOrderTests.swift` (create)

**Interfaces:**
- Produces: `TagChipLoader.ordered(_ counts: [String: Int], sortMode: TagSortMode = .count) -> [(label: String, count: Int)]`

- [ ] **Step 1: Write the failing test** (`TagChipLoaderOrderTests.swift`)

```swift
import XCTest
@testable import Muse

final class TagChipLoaderOrderTests: XCTestCase {
    private let counts = ["zebra": 5, "apple": 5, "mango": 9]

    func testCountModeMostUsedFirstThenAlpha() {
        let out = TagChipLoader.ordered(counts, sortMode: .count).map(\.label)
        XCTAssertEqual(out, ["mango", "apple", "zebra"])   // 9, then 5&5 A→Z
    }

    func testAlphabeticalMode() {
        let out = TagChipLoader.ordered(counts, sortMode: .alphabetical).map(\.label)
        XCTAssertEqual(out, ["apple", "mango", "zebra"])
    }

    func testDefaultIsCount() {
        XCTAssertEqual(TagChipLoader.ordered(counts).map(\.label),
                       ["mango", "apple", "zebra"])
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd "Muse" && xcodebuild -scheme Muse -destination 'platform=macOS' test -only-testing:MuseTests/TagChipLoaderOrderTests 2>&1 | tail -20`
Expected: FAIL — extra argument `sortMode` / mismatch.

- [ ] **Step 3: Replace `ordered` in `TagChipLoader.swift`** (lines 34-43) with:

```swift
    /// Ordered chips. `.count` = most-used first, alphabetical tiebreak (a
    /// stable order between reloads); `.alphabetical` = A→Z by label.
    static func ordered(_ counts: [String: Int],
                        sortMode: TagSortMode = .count) -> [(label: String, count: Int)] {
        let sorted: [(key: String, value: Int)]
        switch sortMode {
        case .count:
            sorted = counts.sorted {
                $0.value != $1.value
                    ? $0.value > $1.value
                    : $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending
            }
        case .alphabetical:
            sorted = counts.sorted {
                $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending
            }
        }
        return sorted.map { (label: $0.key, count: $0.value) }
    }
```

- [ ] **Step 4: Run to verify it passes**

Run: `cd "Muse" && xcodebuild -scheme Muse -destination 'platform=macOS' test -only-testing:MuseTests/TagChipLoaderOrderTests 2>&1 | tail -20`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add "Muse/Muse/Database/TagChipLoader.swift" "Muse/MuseTests/TagChipLoaderOrderTests.swift"
git commit -m "feat: TagChipLoader.ordered takes a TagSortMode"
```

---

### Task 6: `AppState.tagSortMode` + reload wiring

**Files:**
- Modify: `Muse/Muse/Models/AppState.swift` (add `@Published`, an init sink, and pass the mode to both `ordered(...)` call sites)

**Interfaces:**
- Consumes: `AppSettings.tagSortMode`, `TagChipLoader.ordered(_:sortMode:)`.
- Produces: `AppState.tagSortMode: TagSortMode` (`@Published`).

- [ ] **Step 1: Add the `@Published` property** — near the other tag-chip state (the `tagChipRows` declaration, ~line 92), add:

```swift
    /// Tag-chip sort order (By Count / A→Z). Persisted in AppSettings; a change
    /// re-runs reloadTagChips() via the sink in init.
    @Published var tagSortMode: TagSortMode = AppSettings.tagSortMode
```

- [ ] **Step 2: Add the init sink** — in `init`, right after the `tagsVersionCancellable = $tagsVersion ... reloadTagChips() }` block (~line 413), add:

```swift
        // Tag-sort-mode change → persist + re-order the chip row in place.
        $tagSortMode
            .dropFirst()
            .sink { [weak self] mode in
                AppSettings.tagSortMode = mode
                self?.reloadTagChips()
            }
            .store(in: &cancellables)
```

(If `cancellables` is not the set name used here, store it the same way the neighboring sinks do — e.g. assign to a dedicated `AnyCancellable` property mirroring `tagsVersionCancellable`. Verify by reading the surrounding init.)

- [ ] **Step 3: Pass the mode at the folder-load call site** — in `reloadCurrentFiles`'s detached task, the chip block currently reads:

```swift
                    chipRows = TagChipLoader.ordered(
                        TagChipLoader.counts(paths: tagPaths, simpleFolderDir: simpleDir, queue: dbQueue))
```

Capture the mode with the other `let`s at the top of `reloadCurrentFiles` (beside `let mode = sortMode`):

```swift
        let tagSort = tagSortMode
```

and change the call to:

```swift
                    chipRows = TagChipLoader.ordered(
                        TagChipLoader.counts(paths: tagPaths, simpleFolderDir: simpleDir, queue: dbQueue),
                        sortMode: tagSort)
```

- [ ] **Step 4: Pass the mode in `reloadTagChips`** — capture before the detached task (beside `let scope = tagSourceFiles`):

```swift
        let tagSort = tagSortMode
```

and change the `ordered(...)` call (~line 940) to:

```swift
            let rows = TagChipLoader.ordered(
                TagChipLoader.counts(paths: paths, simpleFolderDir: simpleDir, queue: queue),
                sortMode: tagSort)
```

- [ ] **Step 5: Build to verify it compiles**

Run: `cd "Muse" && xcodebuild -scheme Muse -destination 'platform=macOS' build 2>&1 | tail -15`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 6: Commit**

```bash
git add "Muse/Muse/Models/AppState.swift"
git commit -m "feat: AppState.tagSortMode drives live tag-chip re-order"
```

---

### Task 7: Toolbar control between sort and show-subfolders

**Files:**
- Modify: `Muse/Muse/ContentView.swift` (toolbar ~99–102; add a `tagSortMenu` computed view near `sortMenu` ~281)

**Interfaces:**
- Consumes: `appState.tagSortMode`, `TagSortMode.allCases`.

- [ ] **Step 1: Add the toolbar item** — between the sort cluster `ToolbarItem` (ends line 99) and the show-subfolders `ToolbarItem` (begins line 102), insert:

```swift
                // Tag-chip sort order (By Count / A→Z) — its own item, sitting
                // between the grid sort cluster and the show-subfolders toggle.
                ToolbarItem(placement: .navigation) {
                    tagSortMenu
                        // The tag chips don't show on the Collections card page.
                        .disabled(isCollectionsPage)
                }
```

- [ ] **Step 2: Add the `tagSortMenu` computed view** — near `sortMenu` (after it, ~line 304), add:

```swift
    /// Orders the tag chips above the grid: Most Used (count) or A→Z.
    private var tagSortMenu: some View {
        Menu {
            Picker("Tag order", selection: Binding(
                get: { appState.tagSortMode },
                set: { appState.tagSortMode = $0 }
            )) {
                ForEach(TagSortMode.allCases) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            Image(systemName: "tag")
        }
        .help("Tag order: \(appState.tagSortMode.label)")
    }
```

- [ ] **Step 3: Build to verify it compiles**

Run: `cd "Muse" && xcodebuild -scheme Muse -destination 'platform=macOS' build 2>&1 | tail -15`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Commit**

```bash
git add "Muse/Muse/ContentView.swift"
git commit -m "feat: tag-sort menu in toolbar between sort and show-subfolders"
```

---

### Task 8: Full verification + session log

**Files:**
- Modify: `CLAUDE.md` (append a `### ` session log entry dated 2026-06-18 + update the architecture map for `PathReconciler.swift`, `TagSortMode.swift`, `AppSettings`, `TagChipLoader`, `ContentView`)

- [ ] **Step 1: Run the FULL suite + Debug build**

Run: `cd "Muse" && xcodebuild -scheme Muse -destination 'platform=macOS' test 2>&1 | tail -25`
Expected: `** TEST SUCCEEDED **`, all tests pass.

- [ ] **Step 2: Append the session log to `CLAUDE.md`** — a `###` entry summarizing: the ghost-row root cause (deleted/moved files left `is_alive=1`, leaked into search as blank tiles + inflated collection counts), the per-folder-on-load reconcile (evicted-iCloud guard, no migration), and the tag-sort control. Update the architecture map entries for the new/changed files.

- [ ] **Step 3: Commit**

```bash
git add CLAUDE.md
git commit -m "docs: session log — ghost-row reconcile + tag-chip sort"
```

---

## Self-Review notes

- **Spec coverage:** Spec 1&2 (reconcile) → Tasks 1–3; Spec 3 (tag sort) → Tasks 4–7; verification/docs → Task 8. ✓
- **Type consistency:** `PathReconciler.reconcile/markDead/aliveUnder/inScope/vanished/isEvictedPlaceholder`, `TagSortMode` cases `.count`/`.alphabetical`, `TagChipLoader.ordered(_:sortMode:)`, `AppSettings.tagSortMode`, `AppState.tagSortMode` — names consistent across tasks. ✓
- **Risk note for executor:** the exact line numbers in `AppState.swift` drift as edits land; anchor edits on the quoted surrounding code, not the line numbers. Confirm the `cancellables` set name in Task 6 by reading the neighboring sinks before adding the new one.
