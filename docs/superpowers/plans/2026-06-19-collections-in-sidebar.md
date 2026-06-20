# Collections in the Sidebar — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an opt-in second sidebar section that lists Collections beneath Folders, with its own independent sort + manual drag-reorder, click-to-open, right-click rename/delete/move, app-menu + a11y parity, and a two-pill bottom bar.

**Architecture:** A new Preferences toggle (`showCollectionsInSidebar`, default OFF) gates the whole feature. When ON, `SidebarView` wraps both a FOLDERS section and a new COLLECTIONS section inside one shared `ScrollView` with collapsible gray headers (reusing the hero `PlusCircleButton` look). Collection ordering adds a persisted `collections.sort_order` column (migration v8) plus a pure `SidebarCollectionSort` helper; the sidebar's sort state lives only on `AppState` and never touches the Collections page. Reorder mirrors the existing folder live-drag mechanism.

**Tech Stack:** Swift, SwiftUI, GRDB (SQLite), `xcodebuild -scheme Muse`, XCTest (`MuseTests`).

## Global Constraints

- Min macOS 14.6; sandboxed; **no new network/sync/data-collection surface** (only existing Sparkle network path).
- Collection "delete" is **`setHidden(true)`** (durable tombstone) — NEVER a row delete.
- Collection counts use the **reachability-aware alive-paths count** (`CollectionStore.fetchAll(rootPaths:)`).
- **Never** use `.onDrag` on sidebar rows (it eats single-clicks) — reorder is a live `DragGesture` off a trailing grip.
- The Collections **page** is OUT OF SCOPE — its sort/cards/behavior must remain byte-for-byte unchanged.
- Setting OFF ⇒ the sidebar is exactly today's experience.
- GRDB writes are `try await queue.write { }`; rows inserted as `var`.
- Build is authoritative over SourceKit errors; verify with `xcodebuild ... build`.
- Match existing code idiom; additive a11y annotations don't change layout.
- Commit after each task. Commit message footer:
  ```
  Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_01FzJhG3QHAyCCPxCJ7n6Dsv
  ```

---

### Task 1: `SidebarCollectionSortMode` enum + pure `SidebarCollectionSort`

**Files:**
- Create: `Muse/Muse/Models/SidebarCollectionSortMode.swift`
- Test: `Muse/MuseTests/SidebarCollectionSortTests.swift`

**Interfaces:**
- Produces:
  - `enum SidebarCollectionSortMode: String, CaseIterable, Identifiable { case manual, name, dateCreated, dateModified }` with `var id: String { rawValue }` and `var label: String`.
  - `enum SidebarCollectionSort` with `struct Item: Equatable { let id: String; let name: String; let createdAt: Int64; let updatedAt: Int64; let sortOrder: Int }` and `static func order(_ items: [Item], by mode: SidebarCollectionSortMode) -> [String]`.

- [ ] **Step 1: Write the failing test**

```swift
//  SidebarCollectionSortTests.swift
import XCTest
@testable import Muse

final class SidebarCollectionSortTests: XCTestCase {
    private func item(_ id: String, _ name: String, created: Int64, updated: Int64, order: Int)
        -> SidebarCollectionSort.Item {
        .init(id: id, name: name, createdAt: created, updatedAt: updated, sortOrder: order)
    }

    func testManualUsesSortOrderAscending() {
        let items = [
            item("a", "Zeta", created: 1, updated: 1, order: 2),
            item("b", "Alpha", created: 2, updated: 2, order: 0),
            item("c", "Mid", created: 3, updated: 3, order: 1),
        ]
        XCTAssertEqual(SidebarCollectionSort.order(items, by: .manual), ["b", "c", "a"])
    }

    func testNameIsAToZLocalized() {
        let items = [
            item("a", "banana", created: 1, updated: 1, order: 0),
            item("b", "Apple", created: 2, updated: 2, order: 1),
            item("c", "cherry", created: 3, updated: 3, order: 2),
        ]
        XCTAssertEqual(SidebarCollectionSort.order(items, by: .name), ["b", "a", "c"])
    }

    func testDateCreatedNewestFirstWithNameTie() {
        let items = [
            item("a", "Older", created: 10, updated: 1, order: 0),
            item("b", "Newer", created: 20, updated: 1, order: 1),
            item("c", "Bravo", created: 20, updated: 1, order: 2),  // tie w/ b on created
        ]
        // 20s first, name tiebreak Bravo < Newer; then Older
        XCTAssertEqual(SidebarCollectionSort.order(items, by: .dateCreated), ["c", "b", "a"])
    }

    func testDateModifiedNewestFirst() {
        let items = [
            item("a", "A", created: 1, updated: 5, order: 0),
            item("b", "B", created: 1, updated: 9, order: 1),
        ]
        XCTAssertEqual(SidebarCollectionSort.order(items, by: .dateModified), ["b", "a"])
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -scheme Muse -destination 'platform=macOS' test -only-testing:MuseTests/SidebarCollectionSortTests 2>&1 | tail -20`
Expected: FAIL — `Cannot find 'SidebarCollectionSort' in scope`.

- [ ] **Step 3: Write minimal implementation**

```swift
//
//  SidebarCollectionSortMode.swift
//  Muse
//
//  How the sidebar's COLLECTIONS section is ordered — independent of the
//  Collections PAGE sort. Manual = the user's hand arrangement (persisted
//  collections.sort_order, drag-to-reorder). The other modes are read-only
//  sorted displays. `SidebarCollectionSort.order` is a pure comparator, so
//  it's unit-testable. Mirrors FolderSort / CollectionSort.
//

import Foundation

enum SidebarCollectionSortMode: String, CaseIterable, Identifiable {
    case manual, name, dateCreated, dateModified

    var id: String { rawValue }

    var label: String {
        switch self {
        case .manual: return "Manual"
        case .name: return "Name"
        case .dateCreated: return "Date Created"
        case .dateModified: return "Date Modified"
        }
    }
}

nonisolated enum SidebarCollectionSort {
    struct Item: Equatable {
        let id: String
        let name: String
        let createdAt: Int64
        let updatedAt: Int64
        let sortOrder: Int
    }

    /// Ordered ids for `items` under `mode`. Manual → ascending `sortOrder`
    /// (name tiebreak); Name A→Z; dates newest-first with a name tiebreak.
    static func order(_ items: [Item], by mode: SidebarCollectionSortMode) -> [String] {
        switch mode {
        case .manual:
            return items.sorted(by: manualOrder).map(\.id)
        case .name:
            return items.sorted(by: nameAscending).map(\.id)
        case .dateCreated:
            return items.sorted { tie($0, $1, $0.createdAt, $1.createdAt) }.map(\.id)
        case .dateModified:
            return items.sorted { tie($0, $1, $0.updatedAt, $1.updatedAt) }.map(\.id)
        }
    }

    private static func manualOrder(_ a: Item, _ b: Item) -> Bool {
        a.sortOrder != b.sortOrder ? a.sortOrder < b.sortOrder : nameAscending(a, b)
    }

    private static func nameAscending(_ a: Item, _ b: Item) -> Bool {
        a.name.localizedStandardCompare(b.name) == .orderedAscending
    }

    private static func tie(_ a: Item, _ b: Item, _ da: Int64, _ db: Int64) -> Bool {
        da != db ? da > db : nameAscending(a, b)
    }
}
```

Add the new file to the Xcode project target (Muse) so it compiles.

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild -scheme Muse -destination 'platform=macOS' test -only-testing:MuseTests/SidebarCollectionSortTests 2>&1 | tail -20`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add "Muse/Muse/Models/SidebarCollectionSortMode.swift" "Muse/MuseTests/SidebarCollectionSortTests.swift" Muse/Muse.xcodeproj
git commit -m "feat: pure sidebar collection sort (manual/name/created/modified)"
```

---

### Task 2: Migration v8 — `collections.sort_order` column + `CollectionRow` field

**Files:**
- Modify: `Muse/Muse/Database/Database.swift` (after the `v7_tag_parent_dir` migration block)
- Modify: `Muse/Muse/Database/Records.swift:117-126` (`CollectionRow`)
- Test: `Muse/MuseTests/CollectionSortOrderMigrationTests.swift`

**Interfaces:**
- Produces: `CollectionRow.sort_order: Int` (non-optional, default 0). A `collections.sort_order INTEGER NOT NULL DEFAULT 0` column, back-filled so existing rows get a deterministic ascending order by `created_at` then `name`.

- [ ] **Step 1: Write the failing test**

```swift
//  CollectionSortOrderMigrationTests.swift
import XCTest
import GRDB
@testable import Muse

final class CollectionSortOrderMigrationTests: XCTestCase {
    func testBackfillAssignsAscendingByCreatedThenName() throws {
        let queue = try DatabaseQueue()                 // in-memory
        try Database.makeMigrator().migrate(queue)      // runs v1…v8

        try queue.write { db in
            // Insert three rows out of order; created_at is the primary key for order.
            for (id, name, created) in [("c", "Gamma", 30), ("a", "Alpha", 10), ("b", "Beta", 20)] {
                try db.execute(sql: """
                    INSERT INTO collections (id, name, is_hidden, model_version, created_at, updated_at, sort_order)
                    VALUES (?, ?, 0, 'manual', ?, ?, 0)
                    """, arguments: [id, name, created, created])
            }
        }

        // Re-run the back-fill helper deterministically.
        try queue.write { db in try Database.backfillCollectionSortOrder(db) }

        let order = try queue.read { db in
            try String.fetchAll(db, sql: "SELECT id FROM collections ORDER BY sort_order ASC")
        }
        XCTAssertEqual(order, ["a", "b", "c"])
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -scheme Muse -destination 'platform=macOS' test -only-testing:MuseTests/CollectionSortOrderMigrationTests 2>&1 | tail -20`
Expected: FAIL — `makeMigrator` / `backfillCollectionSortOrder` not found, or no `sort_order` column. (If `Database.makeMigrator()` already exists with another name, use the existing migrator accessor the other migration tests use — check `MuseTests` for the pattern, e.g. `Database.migrator` — and match it.)

- [ ] **Step 3: Write minimal implementation**

In `Database.swift`, after the `v7_tag_parent_dir` block, register:

```swift
        migrator.registerMigration("v8_collection_sort_order") { db in
            // Sidebar-only manual ordering for collections. Independent of the
            // Collections PAGE sort. New rows append (max+1) via CollectionStore.
            try db.alter(table: "collections") { t in
                t.add(column: "sort_order", .integer).notNull().defaults(to: 0)
            }
            try Database.backfillCollectionSortOrder(db)
        }
```

Add the deterministic back-fill helper (static, on `Database`, reachable from the migration and the test):

```swift
    /// Assign collections.sort_order = 0,1,2,… ordered by created_at then name,
    /// so an existing library gets a stable manual baseline. Idempotent.
    /// `nonisolated` to match `makeMigrator()` (callable from the migration
    /// closure + tests on a possibly @MainActor `Database`).
    nonisolated static func backfillCollectionSortOrder(_ db: GRDB.Database) throws {
        let ids = try String.fetchAll(db, sql:
            "SELECT id FROM collections ORDER BY created_at ASC, name ASC")
        for (i, id) in ids.enumerated() {
            try db.execute(sql: "UPDATE collections SET sort_order = ? WHERE id = ?",
                           arguments: [i, id])
        }
    }
```

In `Records.swift`, add the field to `CollectionRow` (default keeps existing call-sites that build rows in code valid):

```swift
    var cover_file_id: String?      // user-chosen cover; nil = auto (first member)
    var sort_order: Int = 0         // sidebar-only manual order (v8)
```

> Note: If `CollectionRow` is decoded via `fetchAll(db)` (it is — `fetchAll` in `CollectionStore`), the column must exist. The `NOT NULL DEFAULT 0` guarantees a value for every row.

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild -scheme Muse -destination 'platform=macOS' test -only-testing:MuseTests/CollectionSortOrderMigrationTests 2>&1 | tail -20`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Muse/Muse/Database/Database.swift Muse/Muse/Database/Records.swift "Muse/MuseTests/CollectionSortOrderMigrationTests.swift" Muse/Muse.xcodeproj
git commit -m "feat: v8 migration — collections.sort_order with deterministic backfill"
```

---

### Task 3: `CollectionStore` — surface `sort_order`, append-on-create, reorder

**Files:**
- Modify: `Muse/Muse/Intelligence/Collections/CollectionStore.swift`
- Test: `Muse/MuseTests/CollectionReorderStoreTests.swift`

**Interfaces:**
- Consumes: `CollectionStore.Loaded` (Task none — existing), `CollectionRow.sort_order` (Task 2).
- Produces:
  - `Loaded.sortOrder: Int` (already available via `collection.sort_order`; no new field needed — callers read `loaded.collection.sort_order`).
  - `static func nextSortOrder(_ db: GRDB.Database) throws -> Int` — `max(sort_order)+1`. (Plain `static` is fine — it's only called from `CollectionStore`'s own `async` writes, not the migrator.)
  - `static func setSortOrder(queue:id:order:) async throws`.
  - `static func reorder(queue:moving id:toIndex:orderedIDs:) async throws` — assigns `0…n-1` to `orderedIDs` after moving `id` to `toIndex`. (Simplest correct contract: caller passes the FINAL desired id order; store writes `sort_order = position`.)

Simplify: expose **`static func persistOrder(queue:orderedIDs:) async throws`** that writes `sort_order = index` for each id in `orderedIDs` (one transaction). The sidebar computes the new order array (drag or Move Up/Down) and calls this. This keeps the store dumb and the rule testable.

- [ ] **Step 1: Write the failing test**

```swift
//  CollectionReorderStoreTests.swift
import XCTest
import GRDB
@testable import Muse

final class CollectionReorderStoreTests: XCTestCase {
    private func makeDB() throws -> DatabaseQueue {
        let q = try DatabaseQueue()
        try Database.makeMigrator().migrate(q)
        return q
    }

    func testNewManualCollectionAppendsAtBottom() async throws {
        let q = try makeDB()
        try await q.write { db in
            try db.execute(sql: """
                INSERT INTO collections (id, name, is_hidden, model_version, created_at, updated_at, sort_order)
                VALUES ('x', 'X', 0, 'manual', 1, 1, 0)
                """)
        }
        let newID = try await CollectionStore.createManual(queue: q)
        let order = try await q.read { db in
            try Int.fetchOne(db, sql: "SELECT sort_order FROM collections WHERE id = ?",
                             arguments: [newID])
        }
        XCTAssertEqual(order, 1)        // max(0)+1
    }

    func testPersistOrderWritesPositions() async throws {
        let q = try makeDB()
        try await q.write { db in
            for (id, order) in [("a", 0), ("b", 1), ("c", 2)] {
                try db.execute(sql: """
                    INSERT INTO collections (id, name, is_hidden, model_version, created_at, updated_at, sort_order)
                    VALUES (?, ?, 0, 'manual', 1, 1, ?)
                    """, arguments: [id, id, order])
            }
        }
        try await CollectionStore.persistOrder(queue: q, orderedIDs: ["c", "a", "b"])
        let rows = try await q.read { db in
            try Row.fetchAll(db, sql: "SELECT id, sort_order FROM collections ORDER BY sort_order")
                .map { ($0["id"] as String, $0["sort_order"] as Int) }
        }
        XCTAssertEqual(rows.map(\.0), ["c", "a", "b"])
        XCTAssertEqual(rows.map(\.1), [0, 1, 2])
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -scheme Muse -destination 'platform=macOS' test -only-testing:MuseTests/CollectionReorderStoreTests 2>&1 | tail -20`
Expected: FAIL — `persistOrder` not found; `createManual` doesn't set `sort_order` (column defaults 0, so the append test fails: order is 0 not 1).

- [ ] **Step 3: Write minimal implementation**

In `CollectionStore.swift`, add the helper + persist call, and set `sort_order` on BOTH `createManual` overloads and `upsert` (new auto collections should also append, not collide at 0):

```swift
    /// Next bottom slot for a new collection (max existing + 1; 0 if empty).
    static func nextSortOrder(_ db: GRDB.Database) throws -> Int {
        (try Int.fetchOne(db, sql: "SELECT MAX(sort_order) FROM collections") ?? -1) + 1
    }

    /// Write sort_order = index for each id, in one transaction. The sidebar
    /// computes the final order (drag / Move Up-Down) and calls this.
    static func persistOrder(queue: DatabaseQueue, orderedIDs: [String]) async throws {
        try await queue.write { db in
            for (i, id) in orderedIDs.enumerated() {
                try db.execute(sql: "UPDATE collections SET sort_order = ? WHERE id = ?",
                               arguments: [i, id])
            }
        }
    }
```

Update the empty `createManual(queue:)` (lines ~157-170) INSERT to include `sort_order`:

```swift
    @discardableResult
    static func createManual(queue: DatabaseQueue) async throws -> String {
        let id = UUID().uuidString
        let now = Int64(Date().timeIntervalSince1970)
        try await queue.write { db in
            let names = try String.fetchAll(db, sql: "SELECT name FROM collections")
            let name = ManualCollectionName.next(existing: names)
            let order = try nextSortOrder(db)
            try db.execute(sql: """
                INSERT INTO collections (id, name, is_hidden, model_version, created_at, updated_at, sort_order)
                VALUES (?, ?, 0, 'manual', ?, ?, ?)
                """, arguments: [id, name, now, now, order])
        }
        return id
    }
```

Update the single-file `createManual(queue:name:fileID:)` (lines ~119-132) INSERT the same way:

```swift
        try await queue.write { db in
            let order = try nextSortOrder(db)
            try db.execute(sql: """
                INSERT INTO collections (id, name, is_hidden, model_version, created_at, updated_at, sort_order)
                VALUES (?, ?, 0, 'manual', ?, ?, ?)
                """, arguments: [id, name, now, now, order])
            try db.execute(sql: """
                INSERT INTO collection_members (collection_id, file_id, added_by) VALUES (?, ?, 'manual')
                """, arguments: [id, fileID])
        }
```

Update `upsert` (lines ~44-68) so a newly-inserted auto collection gets a bottom slot (the `ON CONFLICT` path must NOT touch `sort_order`, preserving a user's manual arrangement across reclustering):

```swift
        try await queue.write { db in
            let order = try nextSortOrder(db)
            try db.execute(sql: """
                INSERT INTO collections (id, name, is_hidden, model_version, created_at, updated_at, sort_order)
                VALUES (?, ?, 0, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET name = excluded.name,
                    model_version = excluded.model_version, updated_at = excluded.updated_at
                """, arguments: [id, name, modelVersion, now, now, order])
            // …unchanged member rebuild below…
```

(Leave the member-rebuild block untouched.)

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild -scheme Muse -destination 'platform=macOS' test -only-testing:MuseTests/CollectionReorderStoreTests 2>&1 | tail -20`
Expected: PASS (2 tests).

- [ ] **Step 5: Commit**

```bash
git add Muse/Muse/Intelligence/Collections/CollectionStore.swift "Muse/MuseTests/CollectionReorderStoreTests.swift" Muse/Muse.xcodeproj
git commit -m "feat: collection sort_order — append on create, persistOrder for reorder"
```

---

### Task 4: `AppState` sidebar-collection state + ordered list + reorder action

**Files:**
- Modify: `Muse/Muse/Models/AppState.swift` (add @Published + persistence sink, near `folderSortMode`)
- Modify: `Muse/Muse/Models/AppState+Filters.swift` (add the ordered-list computed + reorder/move helpers)

**Interfaces:**
- Consumes: `SidebarCollectionSort` (Task 1), `CollectionStore.persistOrder` (Task 3), `CollectionsEngine.shared.collections` (existing `[CollectionStore.Loaded]`), `setActiveCollection(_:)` (existing).
- Produces (read by SidebarView, Task 6-9):
  - `@Published var sidebarCollectionSortMode: SidebarCollectionSortMode` (persisted).
  - `var sidebarCollections: [CollectionStore.Loaded]` — engine's collections re-ordered by the sidebar sort mode.
  - `func moveSidebarCollection(id: String, by delta: Int)` — Manual-only Move Up/Down.
  - `func reorderSidebarCollections(_ orderedIDs: [String])` — commit a drag result.

- [ ] **Step 1: Add the persisted sort-mode state** (mirror `folderSortMode`)

Find how `folderSortMode` is declared/persisted in `AppState.swift` (a `@Published` with a Combine sink writing `AppSettings.folderSortMode`). Add alongside it:

```swift
    @Published var sidebarCollectionSortMode: SidebarCollectionSortMode =
        AppSettings.sidebarCollectionSortMode {
        didSet { AppSettings.sidebarCollectionSortMode = sidebarCollectionSortMode }
    }
```

(If `folderSortMode` uses a `$folderSortMode.sink` to persist rather than `didSet`, match THAT exact pattern instead — keep the file consistent. Add the `AppSettings.sidebarCollectionSortMode` accessor in Task 5; for now this references it, which is fine since tasks may land in any order — add the accessor before building.)

- [ ] **Step 2: Add the ordered list + reorder helpers** in `AppState+Filters.swift`

```swift
extension AppState {
    /// The engine's visible collections, ordered by the sidebar's own sort mode
    /// (independent of the Collections page). Sidebar UI reads this.
    var sidebarCollections: [CollectionStore.Loaded] {
        let loaded = CollectionsEngine.shared.collections
        let items = loaded.map {
            SidebarCollectionSort.Item(id: $0.collection.id,
                                       name: $0.collection.name,
                                       createdAt: $0.collection.created_at,
                                       updatedAt: $0.collection.updated_at,
                                       sortOrder: $0.collection.sort_order)
        }
        let orderedIDs = SidebarCollectionSort.order(items, by: sidebarCollectionSortMode)
        let byID = Dictionary(uniqueKeysWithValues: loaded.map { ($0.collection.id, $0) })
        return orderedIDs.compactMap { byID[$0] }
    }

    /// Move a collection one slot in Manual mode (Move Up/Down). No-op otherwise.
    func moveSidebarCollection(id: String, by delta: Int) {
        guard sidebarCollectionSortMode == .manual else { return }
        var ids = sidebarCollections.map { $0.collection.id }
        guard let from = ids.firstIndex(of: id) else { return }
        let to = from + delta
        guard ids.indices.contains(to) else { return }
        ids.swapAt(from, to)
        reorderSidebarCollections(ids)
    }

    /// Commit a new full order (drag result or Move Up/Down) to the DB + reload.
    func reorderSidebarCollections(_ orderedIDs: [String]) {
        Task { @MainActor in
            guard let q = Database.shared.dbQueue else { return }
            try? await CollectionStore.persistOrder(queue: q, orderedIDs: orderedIDs)
            await CollectionsEngine.shared.reload()
        }
    }
}
```

> `CollectionsEngine` is `@ObservedObject` in the sidebar, so reading `.collections` inside a computed property means the sidebar must also observe the engine (Task 6 injects it). The computed re-runs on engine publishes.

- [ ] **Step 3: Build to verify it compiles**

Run: `xcodebuild -scheme Muse -destination 'platform=macOS' build 2>&1 | tail -20`
Expected: BUILD SUCCEEDED (after Task 5's `AppSettings` accessor exists — if building this task alone fails only on `AppSettings.sidebarCollectionSortMode`, do Task 5 Step 1 first, then return).

- [ ] **Step 4: Commit**

```bash
git add Muse/Muse/Models/AppState.swift Muse/Muse/Models/AppState+Filters.swift
git commit -m "feat: AppState sidebar-collection sort state + ordered list + reorder"
```

---

### Task 5: Settings — `showCollectionsInSidebar` + sidebar collection sort persistence + toggle UI

**Files:**
- Modify: `Muse/Muse/Settings/AppSettings.swift`
- Modify: `Muse/Muse/Settings/SettingsView.swift`

**Interfaces:**
- Produces:
  - `AppSettings.showCollectionsInSidebarKey` / `AppSettings.showCollectionsInSidebar: Bool` (default `false`).
  - `AppSettings.sidebarCollectionSortModeKey` / `AppSettings.sidebarCollectionSortMode: SidebarCollectionSortMode` (default `.manual`).

- [ ] **Step 1: Add accessors to `AppSettings.swift`** (after `tileBackground`)

```swift
    static let showCollectionsInSidebarKey = "showCollectionsInSidebar"

    /// Show the Collections section in the sidebar. Default false. Unset → off.
    static var showCollectionsInSidebar: Bool {
        UserDefaults.standard.object(forKey: showCollectionsInSidebarKey) as? Bool ?? false
    }

    static let sidebarCollectionSortModeKey = "sidebarCollectionSortMode"

    /// Sidebar Collections-section sort. Default `.manual`. Independent of the
    /// Collections-page sort. Unset → manual.
    static var sidebarCollectionSortMode: SidebarCollectionSortMode {
        get {
            (UserDefaults.standard.string(forKey: sidebarCollectionSortModeKey))
                .flatMap(SidebarCollectionSortMode.init(rawValue:)) ?? .manual
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: sidebarCollectionSortModeKey) }
    }
```

- [ ] **Step 2: Add the toggle to `SettingsView.swift`**

Add the `@AppStorage` property near the others (line ~17):

```swift
    @AppStorage(AppSettings.showCollectionsInSidebarKey) private var showCollectionsInSidebar = false
```

Add a new section after the "Grid" section (after line 42):

```swift
            Section {
                Toggle("Show Collections in the Sidebar", isOn: $showCollectionsInSidebar)
            } header: {
                Text("Sidebar")
            } footer: {
                Text("Show your collections as a collapsible section beneath the "
                     + "folders, with their own sort order.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
```

- [ ] **Step 3: Build**

Run: `xcodebuild -scheme Muse -destination 'platform=macOS' build 2>&1 | tail -20`
Expected: BUILD SUCCEEDED.

- [ ] **Step 4: Manual check**

Run the app, open Settings (⌘,). Confirm a "Sidebar" section with the toggle, default OFF.

- [ ] **Step 5: Commit**

```bash
git add Muse/Muse/Settings/AppSettings.swift Muse/Muse/Settings/SettingsView.swift
git commit -m "feat: Settings toggle 'Show Collections in the Sidebar' + sidebar sort persistence"
```

---

### Task 6: Sidebar layout — gated two-section scaffold with collapsible gray headers

**Files:**
- Modify: `Muse/Muse/Views/SidebarView.swift` (body restructure + new header component + collapse state)

**Interfaces:**
- Consumes: `AppSettings.showCollectionsInSidebarKey`, `@ObservedObject CollectionsEngine.shared`.
- Produces: a `SectionHeader` view (gray caps label + circular collapse button) and `@AppStorage` collapse flags reused by Tasks 7-9. The existing folder content is wrapped, unchanged in behavior.

**Design:** When the toggle is OFF, the body is byte-for-byte today's (early-return that path). When ON, build ONE `ScrollView` containing: `FOLDERS` header → (if expanded) folder `sortHeader` + folder `LazyVStack` → spacer → `COLLECTIONS` header → (if expanded) collection `sortHeader` + collection rows. The bottom pill row (Task 9) stays outside the scroll.

- [ ] **Step 1: Add observation + collapse state to `SidebarView`**

Near the top of `SidebarView` (with the other `@State`/`@EnvironmentObject`):

```swift
    @AppStorage(AppSettings.showCollectionsInSidebarKey) private var showCollectionsInSidebar = false
    @ObservedObject private var collectionsEngine = CollectionsEngine.shared
    @AppStorage("sidebarFoldersCollapsed") private var foldersCollapsed = false
    @AppStorage("sidebarCollectionsCollapsed") private var collectionsCollapsed = false
```

- [ ] **Step 2: Extract the existing folder list into a helper** so it can be reused inside either layout. Wrap the current `LazyVStack(alignment: .leading, spacing: 1) { … }` (lines 63-89, the iCloud node + stars + reorderable rows + endDropZone) into:

```swift
    @ViewBuilder private var folderList: some View {
        LazyVStack(alignment: .leading, spacing: 1) {
            // …exact current contents (iCloud node, stars, rootRows, endDropZone)…
        }
        .padding(.horizontal, 8)
        .padding(.top, 6)
        .padding(.bottom, 12)
    }
```

- [ ] **Step 3: Add the `SectionHeader` component** (file-private, at the bottom of the file near `AddFolderPillButton`):

```swift
/// A gray uppercase section label with a trailing circular collapse/expand
/// button — the +/× toggle from the hero viewer, tuned for the light sidebar.
/// `+` when collapsed, rotates 45°→`×` when expanded. Same spring motion.
private struct SectionHeader: View {
    let title: String
    @Binding var collapsed: Bool
    @State private var hovering = false

    var body: some View {
        HStack {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(.secondary)
            Spacer()
            Button {
                withAnimation(.spring(response: 0.45, dampingFraction: 0.75)) {
                    collapsed.toggle()
                }
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary.opacity(hovering ? 1.0 : 0.8))
                    .frame(width: 18, height: 18)
                    .background(Circle().fill(Color.primary.opacity(hovering ? 0.16 : 0.08)))
                    .rotationEffect(.degrees(collapsed ? 0 : 45))   // + collapsed, × expanded
            }
            .buttonStyle(.plain)
            .accessibilityLabel(collapsed ? "Expand \(title.capitalized)"
                                          : "Collapse \(title.capitalized)")
            .onHover { hovering = $0 }
        }
        .padding(.horizontal, 14)
        .padding(.top, 8)
        .padding(.bottom, 2)
    }
}
```

- [ ] **Step 4: Branch the body.** Replace the `else` branch (lines 60-116) so it picks a layout based on `showCollectionsInSidebar`:

```swift
            } else if showCollectionsInSidebar {
                twoSectionScroll
            } else {
                sortHeader
                ScrollView {
                    folderList
                }
                .scrollContentBackground(.hidden)
                .coordinateSpace(name: Self.reorderSpace)
                .onPreferenceChange(RootFramePreference.self) { rootFrames = $0 }
                .environment(\.sidebarReordering, draggingRoot != nil)
                .onChange(of: reorderableNodes.map(\.id)) { _, _ in
                    if draggingRoot != nil, draggedIndex == nil { resetDrag() }
                }
                .overlay(alignment: .top) { /* insertion line — unchanged */ }
                .overlay(alignment: .top) { /* dragged overlay — unchanged */ }
            }
```

(Keep the two `.overlay` closures exactly as they are today.)

- [ ] **Step 5: Add `twoSectionScroll`** — both sections in one scroll:

```swift
    private var twoSectionScroll: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                SectionHeader(title: "FOLDERS", collapsed: $foldersCollapsed)
                if !foldersCollapsed {
                    sortHeader
                    folderList
                }
                Color.clear.frame(height: 14)
                SectionHeader(title: "COLLECTIONS", collapsed: $collectionsCollapsed)
                if !collectionsCollapsed {
                    collectionsSortHeader        // Task 8
                    collectionsList              // Task 7
                }
            }
        }
        .scrollContentBackground(.hidden)
        .coordinateSpace(name: Self.reorderSpace)
        .onPreferenceChange(RootFramePreference.self) { rootFrames = $0 }
        .environment(\.sidebarReordering, draggingRoot != nil)
        .onChange(of: reorderableNodes.map(\.id)) { _, _ in
            if draggingRoot != nil, draggedIndex == nil { resetDrag() }
        }
        .overlay(alignment: .top) {
            if draggingRoot != nil, let y = insertionLineY() {
                insertionLine.offset(y: y - 1).allowsHitTesting(false)
            }
        }
        .overlay(alignment: .top) {
            if let dragging = draggingRoot, let f = dragStartFrames[dragging.id] {
                draggedRowOverlay(dragging).offset(y: f.minY + dragOffset).allowsHitTesting(false)
            }
        }
    }
```

> To compile this task before Tasks 7-8 land, add temporary stubs `private var collectionsSortHeader: some View { EmptyView() }` and `private var collectionsList: some View { EmptyView() }`; Tasks 7-8 replace them. (If using subagent-driven execution, land 6→7→8 in sequence and skip the stubs by implementing them in their own tasks — the reviewer gates each.)

- [ ] **Step 6: Build + manual check**

Run: `xcodebuild -scheme Muse -destination 'platform=macOS' build 2>&1 | tail -20`
Expected: BUILD SUCCEEDED. Toggle the setting ON: FOLDERS + COLLECTIONS headers appear, each collapses/expands with the +/× spring; folders behave exactly as before; both scroll together. Toggle OFF: identical to today.

- [ ] **Step 7: Commit**

```bash
git add Muse/Muse/Views/SidebarView.swift
git commit -m "feat: sidebar two-section scaffold with collapsible FOLDERS/COLLECTIONS headers"
```

---

### Task 7: Collection rows — icon, name, count, click-to-activate, selection highlight

**Files:**
- Modify: `Muse/Muse/Views/SidebarView.swift` (replace the `collectionsList` stub + add a `CollectionSidebarRow`)

**Interfaces:**
- Consumes: `appState.sidebarCollections` (Task 4), `appState.setActiveCollection(_:)`, `appState.activeCollectionID`, `appState.showingCollections`.
- Produces: `collectionsList` view; `CollectionSidebarRow` (reused by Task 8 for context menu + reorder).

- [ ] **Step 1: Implement `collectionsList`** (replaces the stub):

```swift
    @ViewBuilder private var collectionsList: some View {
        LazyVStack(alignment: .leading, spacing: 1) {
            ForEach(appState.sidebarCollections, id: \.collection.id) { loaded in
                CollectionSidebarRow(loaded: loaded)
            }
        }
        .padding(.horizontal, 8)
        .padding(.top, 6)
        .padding(.bottom, 12)
    }
```

- [ ] **Step 2: Implement `CollectionSidebarRow`** (file-private). Mirrors the folder row's count + selection styling:

```swift
private struct CollectionSidebarRow: View {
    @EnvironmentObject var appState: AppState
    let loaded: CollectionStore.Loaded
    @State private var isHovered = false

    private var isSelected: Bool {
        appState.activeCollectionID == loaded.collection.id && !appState.showingCollections
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "square.stack.3d.up")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(isSelected ? AnyShapeStyle(Color.accentColor)
                                            : AnyShapeStyle(.primary))
                .frame(width: 20)
            Text(loaded.collection.name)
                .font(.system(size: 13))
                .foregroundStyle(isSelected ? AnyShapeStyle(Color.accentColor)
                                            : AnyShapeStyle(.primary))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 6)
            Text("\(loaded.aliveCount)")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .padding(.horizontal, 8)
        .frame(height: 28)
        .contentShape(Rectangle())
        .background {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(rowFill)
        }
        .onHover { isHovered = $0 }
        .onTapGesture { appState.setActiveCollection(loaded.collection.id) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(loaded.collection.name), \(loaded.aliveCount) "
                            + (loaded.aliveCount == 1 ? "item" : "items"))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { appState.setActiveCollection(loaded.collection.id) }
    }

    private var rowFill: Color {
        if isSelected { return Color.accentColor.opacity(0.14) }
        return Color.primary.opacity(isHovered ? 0.08 : 0)
    }
}
```

(Use the same hover-fill opacity constant the folder row uses — `SidebarView.rowHoverFillOpacity` is `0.08`; matching the literal is fine, or reference the constant if accessible.)

- [ ] **Step 3: Build + manual check**

Run: `xcodebuild -scheme Muse -destination 'platform=macOS' build 2>&1 | tail -20`
Expected: BUILD SUCCEEDED. With the toggle ON and ≥1 collection: rows show the stack icon, name, and count; clicking opens the collection in the grid and highlights the row blue; the previously-selected folder loses its highlight; back to a folder clears the collection highlight.

- [ ] **Step 4: Commit**

```bash
git add Muse/Muse/Views/SidebarView.swift
git commit -m "feat: sidebar collection rows — icon/name/count, click-to-open, selection"
```

---

### Task 8: Collection sort header + Manual drag-reorder + context menu + a11y actions

**Files:**
- Modify: `Muse/Muse/Views/SidebarView.swift`

**Interfaces:**
- Consumes: `appState.sidebarCollectionSortMode`, `appState.moveSidebarCollection(id:by:)`, `appState.reorderSidebarCollections(_:)`, `appState.collectionRenameRequest`, `setActiveCollection`, `CollectionStore.setHidden`/`rename` patterns (reuse `AppState` request flags where they exist).
- Produces: `collectionsSortHeader` (replaces the stub); reorder + context menu on `CollectionSidebarRow`.

- [ ] **Step 1: Implement `collectionsSortHeader`** (mirror `sortHeader`, lines 151-180):

```swift
    private var collectionsSortHeader: some View {
        HStack {
            Menu {
                ForEach(SidebarCollectionSortMode.allCases) { mode in
                    Button {
                        appState.sidebarCollectionSortMode = mode
                    } label: {
                        if appState.sidebarCollectionSortMode == mode {
                            Label(mode.label, systemImage: "checkmark")
                        } else {
                            Text(mode.label)
                        }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Text("Sort: \(appState.sidebarCollectionSortMode.label)")
                    Image(systemName: "chevron.down")
                }
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .accessibilityLabel("Sort collections")
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.top, 4)
        .padding(.bottom, 2)
    }
```

- [ ] **Step 2: Add the right-click context menu + Move/Rename/Delete to `CollectionSidebarRow`.** Add a `.contextMenu` and confirm-delete `.alert`. Compute neighbor indices from `appState.sidebarCollections`:

```swift
    // add to CollectionSidebarRow:
    @State private var confirmDelete = false

    private var manual: Bool { appState.sidebarCollectionSortMode == .manual }
    private var index: Int? {
        appState.sidebarCollections.firstIndex { $0.collection.id == loaded.collection.id }
    }
    private var count: Int { appState.sidebarCollections.count }
```

Append to the row modifiers (after `.accessibilityAction`):

```swift
        .contextMenu {
            Button("Rename…") {
                appState.setActiveCollection(loaded.collection.id)
                appState.collectionRenameRequest = true
            }
            Button("Delete…") { confirmDelete = true }
            if manual {
                Divider()
                Button("Move Up") { appState.moveSidebarCollection(id: loaded.collection.id, by: -1) }
                    .disabled((index ?? 0) <= 0)
                Button("Move Down") { appState.moveSidebarCollection(id: loaded.collection.id, by: 1) }
                    .disabled(index == nil || index! >= count - 1)
            }
        }
        .accessibilityAction(named: "Rename Collection") {
            appState.setActiveCollection(loaded.collection.id)
            appState.collectionRenameRequest = true
        }
        .accessibilityAction(named: "Delete Collection") { confirmDelete = true }
        .alert("Delete Collection", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) {
                let id = loaded.collection.id
                Task { @MainActor in
                    guard let q = Database.shared.dbQueue else { return }
                    if appState.activeCollectionID == id { appState.setActiveCollection(nil) }
                    try? await CollectionStore.setHidden(queue: q, id: id, hidden: true)
                    await CollectionsEngine.shared.reload()
                }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("The collection is removed everywhere. Your images stay on disk.")
        }
```

> Verify `appState.collectionRenameRequest` drives the existing rename `.alert` (it's the same flag the Collections menu uses, MuseApp.swift:246). If rename for a not-yet-active collection needs the active id, activating first (as above) is the simplest correct path.

- [ ] **Step 3: Add Manual drag-reorder** mirroring the folder grip mechanism. This is the same live-`DragGesture` approach used for roots (SidebarView.swift: the grip at lines 554-577, the `ReorderContext` at 781-784, hidden-row + overlay). For collections, the simplest faithful port:
  - Add sidebar `@State` for collection drag: `draggingCollectionID: String?`, `collectionDragOffset: CGFloat`, `collectionDropTarget: Int?`, and a frames dictionary keyed by collection id (reuse the same `reorderSpace` coordinate space).
  - In `CollectionSidebarRow`, when `manual && isHovered`, swap the trailing count for a `line.3.horizontal` grip (opacity crossfade, `accessibilityHidden(true)`) carrying a `DragGesture(minimumDistance: 3, coordinateSpace: .named(SidebarView.reorderSpace))`.
  - On `.onChanged`, update offset + compute the drop index from row frames; on `.onEnded`, build the new id order and call `appState.reorderSidebarCollections(newOrder)`, then reset drag state.
  - Draw the dragged row as a `ScrollView` overlay following the cursor and hide the source row in place (`opacity`/`offset`), exactly like roots, plus the insertion line.

  Because this duplicates a lot of root-reorder machinery, factor the shared pieces if practical; otherwise replicate the structure for collections. Keep behavior identical to folder reorder (non-animated commit, grip only in Manual on hover).

  **Minimum acceptable for this step if the full live overlay proves heavy:** ship Move Up/Down (Step 2) as the functional reorder and the grip-drag as the visual port; both must persist via `reorderSidebarCollections`. Do NOT use `.onDrag`.

- [ ] **Step 4: Build + manual check**

Run: `xcodebuild -scheme Muse -destination 'platform=macOS' build 2>&1 | tail -20`
Expected: BUILD SUCCEEDED. In Manual: a grip appears on hover and dragging reorders + persists (survives relaunch); Move Up/Down works and is disabled at the ends; switching to Name/Date reorders read-only and hides the grip. Right-click Rename opens the name dialog; Delete shows the confirm and removes (durable). Reorder works while the list scrolls.

- [ ] **Step 5: Commit**

```bash
git add Muse/Muse/Views/SidebarView.swift
git commit -m "feat: sidebar collection sort header, drag-reorder, context menu, a11y actions"
```

---

### Task 9: Two-pill bottom bar (Add Folder + Add Collection)

**Files:**
- Modify: `Muse/Muse/Views/SidebarView.swift` (the bottom `AddFolderPillButton` area, lines 118-120 + the `AddFolderPillButton` struct ~739)

**Interfaces:**
- Consumes: `appState.pickAndAddRoot()`, `appState.requestNewCollection()` (existing — opens the Name Collection alert).
- Produces: a `SidebarBottomBar` that shows one pill when OFF and two compact pills when ON.

- [ ] **Step 1: Generalize the pill** into an icon-only compact form and add the bottom bar. Add a file-private compact pill:

```swift
/// Compact icon-only "+ <glyph>" capsule for the two-up bottom bar.
private struct AddPillButton: View {
    let systemImage: String
    let label: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "plus")
                Image(systemName: systemImage)
            }
            .font(.system(size: 12, weight: .medium))
            .frame(maxWidth: .infinity)
            .frame(height: 28)
        }
        .buttonStyle(.plain)
        .background { Capsule(style: .continuous).fill(Color.primary.opacity(0.08)) }
        .accessibilityLabel(label)
    }
}
```

(Match the existing `AddFolderPillButton` fill color for visual consistency — read its `fillColor` and reuse the same value.)

- [ ] **Step 2: Replace the bottom `AddFolderPillButton { … }`** (lines 118-120) with:

```swift
            if showCollectionsInSidebar {
                HStack(spacing: 10) {
                    AddPillButton(systemImage: "folder", label: "Add Folder") {
                        appState.pickAndAddRoot()
                    }
                    AddPillButton(systemImage: "square.stack.3d.up", label: "Add Collection") {
                        appState.requestNewCollection()
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            } else {
                AddFolderPillButton { appState.pickAndAddRoot() }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
            }
```

- [ ] **Step 3: Build + manual check**

Run: `xcodebuild -scheme Muse -destination 'platform=macOS' build 2>&1 | tail -20`
Expected: BUILD SUCCEEDED. OFF: single "Add Folder" pill (unchanged). ON: two equal pills (`+ folder`, `+ stack`); the stack pill opens the Name Collection dialog; confirming creates an empty named collection that appears at the BOTTOM of Manual order. Both pills stay pinned while the list scrolls.

- [ ] **Step 4: Commit**

```bash
git add Muse/Muse/Views/SidebarView.swift
git commit -m "feat: two-pill sidebar bottom bar — Add Folder + Add Collection"
```

---

### Task 10: App-menu Move Collection Up/Down (keyboard + VoiceOver parity)

**Files:**
- Modify: `Muse/Muse/MuseApp.swift` (the `CommandMenu("Collections")` block, lines 235-270)

**Interfaces:**
- Consumes: `appState.activeCollectionID`, `appState.sidebarCollectionSortMode`, `appState.sidebarCollections`, `appState.moveSidebarCollection(id:by:)`, `appState.showCollectionsInSidebar` (read `AppSettings.showCollectionsInSidebar` directly).

- [ ] **Step 1: Add Move items** after the "Delete Collection…" button (before the `Divider()` at line 264). Gate to: sidebar shown ON + Manual mode + an active collection that isn't at the end:

```swift
                Button("Move Collection Up") {
                    if let id = appState.activeCollectionID {
                        appState.moveSidebarCollection(id: id, by: -1)
                    }
                }
                .disabled(!sidebarManualMoveEnabled || sidebarActiveIndex == nil
                          || (sidebarActiveIndex ?? 0) <= 0)

                Button("Move Collection Down") {
                    if let id = appState.activeCollectionID {
                        appState.moveSidebarCollection(id: id, by: 1)
                    }
                }
                .disabled(!sidebarManualMoveEnabled || sidebarActiveIndex == nil
                          || (sidebarActiveIndex ?? Int.max) >= appState.sidebarCollections.count - 1)
```

- [ ] **Step 2: Add the gate helpers** to the same `App` struct (near `moveSelectedRoot` / `selectedRootIndex`):

```swift
    private var sidebarManualMoveEnabled: Bool {
        AppSettings.showCollectionsInSidebar
            && appState.sidebarCollectionSortMode == .manual
            && appState.activeCollectionID != nil
    }
    private var sidebarActiveIndex: Int? {
        guard let id = appState.activeCollectionID else { return nil }
        return appState.sidebarCollections.firstIndex { $0.collection.id == id }
    }
```

- [ ] **Step 3: Build + manual check**

Run: `xcodebuild -scheme Muse -destination 'platform=macOS' build 2>&1 | tail -20`
Expected: BUILD SUCCEEDED. With sidebar ON + Manual + a collection open: Collections menu shows enabled Move Collection Up/Down that reorder the sidebar; disabled when OFF, in a sorted mode, at the ends, or with no active collection.

- [ ] **Step 4: Commit**

```bash
git add Muse/Muse/MuseApp.swift
git commit -m "feat: app-menu Move Collection Up/Down (sidebar manual reorder a11y parity)"
```

---

### Task 11: Full verification + docs

**Files:**
- Modify: `CLAUDE.md` (phase log: add the `feat/next-32` row + session entry), `docs/session-log.md` (full narrative).

- [ ] **Step 1: Full build**

Run: `xcodebuild -scheme Muse -destination 'platform=macOS' build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED.

- [ ] **Step 2: Full test suite**

Run: `xcodebuild -scheme Muse -destination 'platform=macOS' test 2>&1 | tail -15`
Expected: TEST SUCCEEDED, all green (including the three new test files).

- [ ] **Step 3: Manual QA pass** (toggle OFF = identical to today; toggle ON: headers collapse/expand with +/× spring; both sections scroll as one with the bottom pills pinned; click a collection opens it + highlights it + deselects folders; Manual drag + Move Up/Down persist across relaunch; Name/Date sorts reorder read-only; right-click Rename/Delete; Add Collection pill creates at the bottom of Manual; VoiceOver reads rows + named Rename/Delete/Move actions; the Collections PAGE is unchanged).

- [ ] **Step 4: Update docs** — add a `feat/next-32` row to the CLAUDE.md phase log and a session-log entry summarizing: opt-in sidebar Collections section, independent sort + v8 `sort_order` migration, drag-reorder mirror, two-pill bottom bar, app-menu + a11y parity, page untouched.

- [ ] **Step 5: Commit**

```bash
git add CLAUDE.md docs/session-log.md
git commit -m "docs: log Collections-in-Sidebar (feat/next-32)"
```

---

## Self-Review

**Spec coverage:**
- Setting (default OFF) → Task 5. OFF = current → Task 6 (branch keeps today's path). ✓
- Gray FOLDERS/COLLECTIONS headers + hero +/× collapse → Task 6 (`SectionHeader`). ✓
- Collection rows icon/name/count → Task 7. ✓
- Click-to-activate + selection highlight → Task 7. ✓
- Independent sidebar sort (Manual/Name/Created/Modified) → Tasks 1, 4, 5, 8. ✓
- Manual persisted order + drag + Move Up/Down → Tasks 2, 3, 4, 8. ✓
- Right-click Rename/Delete (setHidden) → Task 8. ✓
- App-menu + VoiceOver parity → Tasks 8 (named actions) + 10 (menu). ✓
- Two-pill bottom bar (Add Folder + Add Collection → Name modal, bottom of Manual) → Tasks 3 (append), 9. ✓
- Scroll-as-one → Task 6 (`twoSectionScroll`). ✓
- Collections page untouched → guaranteed by using sidebar-only state; no page files modified. ✓

**Placeholder scan:** Task 6 intentionally uses temporary `collectionsSortHeader`/`collectionsList` stubs only so the scaffold compiles before Tasks 7-8; both are replaced with real implementations in those tasks (not shipped placeholders). Task 8 Step 3 gives a concrete fallback (Move Up/Down as functional reorder) if the full live-overlay drag is deferred — both persist via the same API.

**Type consistency:** `SidebarCollectionSortMode` / `SidebarCollectionSort.Item(id,name,createdAt,updatedAt,sortOrder)` / `SidebarCollectionSort.order(_:by:)` consistent across Tasks 1, 4. `CollectionStore.persistOrder(queue:orderedIDs:)` / `nextSortOrder(_:)` consistent across Tasks 3, 4. `CollectionRow.sort_order: Int` consistent across Tasks 2, 3, 4. `AppState.sidebarCollections` / `moveSidebarCollection(id:by:)` / `reorderSidebarCollections(_:)` consistent across Tasks 4, 7, 8, 10. `Database.makeMigrator()` is referenced in tests — confirm the actual migrator accessor name in the existing `MuseTests` migration tests and match it in Tasks 2-3 (the only external dependency to verify before running).
