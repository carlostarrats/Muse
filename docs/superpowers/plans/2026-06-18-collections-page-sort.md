# Collections Page Sort Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let the user sort the collections card grid using the existing toolbar sort menu + direction arrow, showing only the options that apply to a collection.

**Architecture:** Reuse the existing `SortMode` enum filtered to `[.name, .dateCreated, .dateModified]`. Add a separate, persisted `collectionSortMode` / `collectionSortReversed` to `AppState` (mirroring `tagSortMode` / `folderSortMode`). A pure, unit-tested `CollectionSort` helper (mirroring `FolderSort`) orders collections. The toolbar's `sortMenu` / `sortDirectionButton` become context-aware on the collections page; `CollectionsPage` re-sorts reactively off the `@Published` state.

**Tech Stack:** Swift, SwiftUI, Combine, GRDB, XCTest. macOS app built with `xcodebuild -scheme Muse`.

## Global Constraints

- App is `@MainActor`-centric; pure logic helpers are `nonisolated`. (verbatim from codebase conventions)
- Sort helpers in this codebase are pure value-type functions, unit-tested (e.g. `FolderSort.order`). Follow that pattern.
- No schema changes — `collections.created_at` / `updated_at` (Int64 unix seconds) already exist on `CollectionRow`.
- Persisted UI prefs go through `AppSettings` (UserDefaults), restored on init and saved via a Combine sink in `AppState.init`.
- SourceKit cross-file errors during editing are noise — verify only with `xcodebuild ... build`.
- Working directory for all `xcodebuild` commands: `Muse App/Muse/` (contains `Muse.xcodeproj`).
- The git repo root is `Muse App/` (the project root `Muse/` is NOT a repo). Run all git commands from there. Feature work lands on a `feat/next-N` branch (this landed on `feat/next-20`). Treat each task's "Checkpoint" as build/tests green; the whole feature is committed at the end.

---

### Task 1: Pure `CollectionSort` helper + tests

**Files:**
- Create: `Muse App/Muse/Muse/Intelligence/Collections/CollectionSort.swift`
- Create: `Muse App/Muse/MuseTests/CollectionSortTests.swift`
- Modify: `Muse App/Muse/Muse/Intelligence/Sort/SmartSorter.swift` (add `SortMode.collectionCases`)

**Interfaces:**
- Consumes: existing `SortMode` enum (cases `.name`, `.dateCreated`, `.dateModified`) from `SmartSorter.swift`.
- Produces:
  - `SortMode.collectionCases: [SortMode]` == `[.name, .dateCreated, .dateModified]`
  - `CollectionSort.Item(id: String, name: String, createdAt: Int64, updatedAt: Int64)`
  - `CollectionSort.order(_ items: [Item], by mode: SortMode, reversed: Bool) -> [String]` (returns ordered ids)

- [ ] **Step 1: Write the failing test**

Create `Muse App/Muse/MuseTests/CollectionSortTests.swift`:

```swift
import XCTest
@testable import Muse

final class CollectionSortTests: XCTestCase {
    private func item(_ name: String, created: Int64 = 0, updated: Int64 = 0) -> CollectionSort.Item {
        CollectionSort.Item(id: name, name: name, createdAt: created, updatedAt: updated)
    }

    func testCollectionCasesAreOnlyTheApplicableModes() {
        XCTAssertEqual(SortMode.collectionCases, [.name, .dateCreated, .dateModified])
    }

    func testNameAscendingLocalizedNumeric() {
        let items = [item("Banana"), item("apple"), item("Cherry"), item("file10"), item("file2")]
        XCTAssertEqual(CollectionSort.order(items, by: .name, reversed: false),
                       ["apple", "Banana", "Cherry", "file2", "file10"])
    }

    func testNameReversed() {
        let items = [item("a"), item("b"), item("c")]
        XCTAssertEqual(CollectionSort.order(items, by: .name, reversed: true),
                       ["c", "b", "a"])
    }

    func testDateCreatedNewestFirst() {
        let items = [item("old", created: 100), item("new", created: 300), item("mid", created: 200)]
        XCTAssertEqual(CollectionSort.order(items, by: .dateCreated, reversed: false),
                       ["new", "mid", "old"])
    }

    func testDateModifiedNewestFirstReversedIsOldestFirst() {
        let items = [item("old", updated: 100), item("new", updated: 300), item("mid", updated: 200)]
        XCTAssertEqual(CollectionSort.order(items, by: .dateModified, reversed: true),
                       ["old", "mid", "new"])
    }

    func testEqualDatesTiebreakByName() {
        let items = [item("b", created: 100), item("a", created: 100)]
        XCTAssertEqual(CollectionSort.order(items, by: .dateCreated, reversed: false),
                       ["a", "b"])
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd "Muse App/Muse" && xcodebuild -scheme Muse -destination 'platform=macOS' test -only-testing:MuseTests/CollectionSortTests 2>&1 | tail -30`
Expected: FAIL — build error "cannot find 'CollectionSort' in scope" / "type 'SortMode' has no member 'collectionCases'".

- [ ] **Step 3: Add `SortMode.collectionCases`**

In `Muse App/Muse/Muse/Intelligence/Sort/SmartSorter.swift`, inside the `SortMode` enum (after `directionLabel(ascending:)`), add:

```swift
    /// The sort modes that apply to a *collection* (a group, not a file).
    /// Size/Kind/Color/Shape are per-image properties a collection lacks, so the
    /// Collections-page sort menu shows only these three.
    static let collectionCases: [SortMode] = [.name, .dateCreated, .dateModified]
```

- [ ] **Step 4: Create the `CollectionSort` helper**

Create `Muse App/Muse/Muse/Intelligence/Collections/CollectionSort.swift`:

```swift
//
//  CollectionSort.swift
//  Muse
//
//  Pure ordering for the Collections page, mirroring FolderSort. Only the
//  collection-applicable SortMode cases (Name / Date Created / Date Modified)
//  are handled; the base direction matches each mode's `defaultAscending`
//  (Name A→Z, dates newest-first) so the toolbar arrow + tooltip stay truthful,
//  and `reversed` flips the whole result uniformly (same strategy as
//  SmartSorter.apply).
//

import Foundation

nonisolated enum CollectionSort {
    struct Item: Equatable {
        let id: String
        let name: String
        let createdAt: Int64
        let updatedAt: Int64
    }

    /// Ordered ids for `items` under `mode`, reversed if `reversed`.
    static func order(_ items: [Item], by mode: SortMode, reversed: Bool) -> [String] {
        let base: [Item]
        switch mode {
        case .name:
            base = items.sorted(by: nameAscending)                          // A→Z
        case .dateCreated:
            base = items.sorted { tie($0, $1, $0.createdAt, $1.createdAt) }  // newest first
        case .dateModified:
            base = items.sorted { tie($0, $1, $0.updatedAt, $1.updatedAt) }  // newest first
        default:
            base = items   // unreachable; only collectionCases are selectable
        }
        let ids = base.map(\.id)
        return reversed ? ids.reversed() : ids
    }

    private static func nameAscending(_ a: Item, _ b: Item) -> Bool {
        a.name.localizedStandardCompare(b.name) == .orderedAscending
    }

    /// Newest-first with a name tiebreak (matches SmartSorter's date modes).
    private static func tie(_ a: Item, _ b: Item, _ da: Int64, _ db: Int64) -> Bool {
        da != db ? da > db : nameAscending(a, b)
    }
}
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `cd "Muse App/Muse" && xcodebuild -scheme Muse -destination 'platform=macOS' test -only-testing:MuseTests/CollectionSortTests 2>&1 | tail -30`
Expected: PASS — `Test Suite 'CollectionSortTests' passed`, 6 tests.

- [ ] **Step 6: Checkpoint**

Tests green. (No git in this repo — no commit.)

---

### Task 2: AppState state + persistence

**Files:**
- Modify: `Muse App/Muse/Muse/Settings/AppSettings.swift` (after the `tagSortMode` accessor, ~line 59)
- Modify: `Muse App/Muse/Muse/Models/AppState.swift` (add @Published props near line 153; cancellable near line 100; sink in init near line 449)

**Interfaces:**
- Consumes: `SortMode` (+ its `defaultAscending`), `AppSettings`.
- Produces (used by Tasks 3 & 4):
  - `AppState.collectionSortMode: SortMode` (`@Published`, default `.name`)
  - `AppState.collectionSortReversed: Bool` (`@Published`, default `false`)
  - `AppState.collectionSortAscending: Bool` (computed)
  - `AppState.toggleCollectionSortDirection()`
  - `AppSettings.collectionSortMode: SortMode` (get/set), `AppSettings.collectionSortReversed: Bool` (get/set)

- [ ] **Step 1: Add `AppSettings` persistence**

In `Muse App/Muse/Muse/Settings/AppSettings.swift`, immediately before the closing brace of the type (after the `tagSortMode` computed property, currently ending at line 59), add:

```swift

    static let collectionSortModeKey = "collectionSortMode"

    /// Collections-page sort mode. Default `.name` (A→Z), matching the page's
    /// original hardcoded order. Unset → name.
    static var collectionSortMode: SortMode {
        get {
            (UserDefaults.standard.string(forKey: collectionSortModeKey))
                .flatMap(SortMode.init(rawValue:)) ?? .name
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: collectionSortModeKey) }
    }

    static let collectionSortReversedKey = "collectionSortReversed"

    /// Whether the Collections-page sort is flipped from its mode's natural
    /// direction. Default false. Unset → false.
    static var collectionSortReversed: Bool {
        get { UserDefaults.standard.bool(forKey: collectionSortReversedKey) }
        set { UserDefaults.standard.set(newValue, forKey: collectionSortReversedKey) }
    }
```

- [ ] **Step 2: Add the `@Published` state to `AppState`**

In `Muse App/Muse/Muse/Models/AppState.swift`, after the `toggleSortDirection()` method (currently ends line 165), add:

```swift

    /// Collections-page sort mode — independent of the grid `sortMode` so
    /// sorting collections never disturbs the image grid (same isolation as
    /// `tagSortMode` / `folderSortMode`). Only `SortMode.collectionCases` are
    /// ever selectable in the UI. Persisted via a sink in `init`.
    @Published var collectionSortMode: SortMode = AppSettings.collectionSortMode

    /// Flip the collections sort's natural order (the toolbar arrow, on the
    /// Collections page). Persisted via a sink in `init`.
    @Published var collectionSortReversed: Bool = AppSettings.collectionSortReversed

    /// Effective ascending/descending for the Collections page (default XOR
    /// reversed) — drives the toolbar arrow + tooltip there.
    var collectionSortAscending: Bool {
        collectionSortReversed ? !collectionSortMode.defaultAscending
                               : collectionSortMode.defaultAscending
    }

    /// Flip the collections sort direction. The card grid re-sorts reactively
    /// off the `@Published` change — no manual resort needed.
    func toggleCollectionSortDirection() {
        collectionSortReversed.toggle()
    }
```

- [ ] **Step 3: Add the persistence cancellables**

In `Muse App/Muse/Muse/Models/AppState.swift`, after the `folderSortModeCancellable` declaration (line 106), add:

```swift
    private var collectionSortModeCancellable: AnyCancellable?
    private var collectionSortReversedCancellable: AnyCancellable?
```

- [ ] **Step 4: Add the persistence sinks in `init`**

In `Muse App/Muse/Muse/Models/AppState.swift`, after the `folderSortModeCancellable` sink (ends line 449), add:

```swift

        // Collections-page sort → persist. CollectionsPage re-renders off the
        // @Published change; nothing else to recompute here.
        collectionSortModeCancellable = $collectionSortMode
            .dropFirst()
            .sink { mode in AppSettings.collectionSortMode = mode }
        collectionSortReversedCancellable = $collectionSortReversed
            .dropFirst()
            .sink { reversed in AppSettings.collectionSortReversed = reversed }
```

- [ ] **Step 5: Build to verify it compiles**

Run: `cd "Muse App/Muse" && xcodebuild -scheme Muse -destination 'platform=macOS' build 2>&1 | tail -20`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 6: Checkpoint**

Build green.

---

### Task 3: Apply the sort in `CollectionsPage`

**Files:**
- Modify: `Muse App/Muse/Muse/Views/CollectionsPage.swift` (the `sorted` computed property, lines 24-30; doc comment lines 5-10)

**Interfaces:**
- Consumes: `appState.collectionSortMode`, `appState.collectionSortReversed` (Task 2); `CollectionSort.Item` / `CollectionSort.order` (Task 1); existing `engine.collections: [CollectionStore.Loaded]` where each has `.collection.id`, `.collection.name`, `.collection.created_at`, `.collection.updated_at`.
- Produces: a reactively re-sorted card grid.

- [ ] **Step 1: Replace the hardcoded `sorted` computed property**

In `Muse App/Muse/Muse/Views/CollectionsPage.swift`, replace lines 24-30:

```swift
    /// Collections, A→Z (case-insensitive).
    private var sorted: [CollectionStore.Loaded] {
        engine.collections.sorted {
            $0.collection.name.localizedCaseInsensitiveCompare($1.collection.name)
                == .orderedAscending
        }
    }
```

with:

```swift
    /// Collections ordered by the Collections-page sort (Name / Date Created /
    /// Date Modified + direction). Reactive: changing the toolbar sort or arrow
    /// updates `appState.collectionSort*`, which re-runs this computed property.
    private var sorted: [CollectionStore.Loaded] {
        let loaded = engine.collections
        let items = loaded.map {
            CollectionSort.Item(id: $0.collection.id,
                                name: $0.collection.name,
                                createdAt: $0.collection.created_at,
                                updatedAt: $0.collection.updated_at)
        }
        let orderedIDs = CollectionSort.order(items,
                                              by: appState.collectionSortMode,
                                              reversed: appState.collectionSortReversed)
        let byID = Dictionary(uniqueKeysWithValues: loaded.map { ($0.collection.id, $0) })
        return orderedIDs.compactMap { byID[$0] }
    }
```

- [ ] **Step 2: Update the file's header doc comment**

In `Muse App/Muse/Muse/Views/CollectionsPage.swift`, change the phrase on line 8 from `ordered alphabetically.` to `ordered by the toolbar sort (name / date created / date modified).`

- [ ] **Step 3: Build to verify it compiles**

Run: `cd "Muse App/Muse" && xcodebuild -scheme Muse -destination 'platform=macOS' build 2>&1 | tail -20`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Checkpoint**

Build green. (Cards still render A→Z by default since `collectionSortMode` defaults to `.name` not reversed — behavior unchanged until Task 4 wires the controls.)

---

### Task 4: Make the toolbar sort controls context-aware

**Files:**
- Modify: `Muse App/Muse/Muse/ContentView.swift` (the `.disabled` on the sort cluster, line 99; `sortMenu`, lines 322-343; `sortDirectionButton`, lines 364-376)

**Interfaces:**
- Consumes: `isCollectionsPage` (existing computed), `appState.collectionSortMode` / `collectionSortReversed` / `collectionSortAscending` / `toggleCollectionSortDirection()` (Task 2), `SortMode.collectionCases` (Task 1).
- Produces: live sort menu + direction arrow on the Collections page.

- [ ] **Step 1: Enable the sort cluster on the Collections page**

In `Muse App/Muse/Muse/ContentView.swift`, replace the `.disabled` on the sort cluster (lines 97-99):

```swift
                    // Sorting is meaningless on the Collections card grid, and
                    // it doesn't apply to search results (ranked by relevance).
                    .disabled(isCollectionsPage || appState.isSearchActive)
```

with:

```swift
                    // The sort cluster is live on the Collections page (it sorts
                    // the cards) and on the grid; only search disables it
                    // (results are ranked by relevance).
                    .disabled(appState.isSearchActive)
```

(Leave the tag-sort menu's `.disabled(isCollectionsPage || appState.isSearchActive)` on line 108 unchanged — there are no tag chips on the Collections page.)

- [ ] **Step 2: Make `sortMenu` context-aware**

In `Muse App/Muse/Muse/ContentView.swift`, replace the whole `sortMenu` computed property (lines 322-343):

```swift
    @ViewBuilder
    private var sortMenu: some View {
        Menu {
            // Picker gives native menu checkmarks (the empty-systemImage
            // Label hack logged "no symbol named ''" console noise).
            // One flat list — Color and Shape simply use Analyze data when
            // it exists, no Standard/Smart ceremony.
            Picker("Sort", selection: Binding(
                get: { appState.sortMode },
                set: { appState.sortMode = $0; appState.resort() }
            )) {
                ForEach(SortMode.allCases) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            Image(systemName: "arrow.up.and.down.text.horizontal")
        }
        .help("Sort: \(appState.sortMode.displayName)")
    }
```

with:

```swift
    @ViewBuilder
    private var sortMenu: some View {
        Menu {
            if isCollectionsPage {
                // Collections card grid: only the modes that apply to a group.
                Picker("Sort", selection: Binding(
                    get: { appState.collectionSortMode },
                    set: { appState.collectionSortMode = $0 }
                )) {
                    ForEach(SortMode.collectionCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } else {
                // Picker gives native menu checkmarks (the empty-systemImage
                // Label hack logged "no symbol named ''" console noise).
                // One flat list — Color and Shape simply use Analyze data when
                // it exists, no Standard/Smart ceremony.
                Picker("Sort", selection: Binding(
                    get: { appState.sortMode },
                    set: { appState.sortMode = $0; appState.resort() }
                )) {
                    ForEach(SortMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            }
        } label: {
            Image(systemName: "arrow.up.and.down.text.horizontal")
        }
        .help("Sort: \(isCollectionsPage ? appState.collectionSortMode.displayName : appState.sortMode.displayName)")
    }
```

- [ ] **Step 3: Make `sortDirectionButton` context-aware**

In `Muse App/Muse/Muse/ContentView.swift`, replace the whole `sortDirectionButton` computed property (lines 364-376):

```swift
    /// Flips the current sort mode's direction. The arrow points up for an
    /// ascending order, down for descending; the tooltip spells out what that
    /// means for the active mode (e.g. "Newest first" vs "Oldest first").
    private var sortDirectionButton: some View {
        Button {
            appState.toggleSortDirection()
        } label: {
            Image(systemName: appState.sortAscending ? "arrow.up" : "arrow.down")
        }
        .help(appState.sortMode.directionLabel(ascending: appState.sortAscending))
        .accessibilityLabel("Sort direction: "
                            + appState.sortMode.directionLabel(ascending: appState.sortAscending))
    }
```

with:

```swift
    /// Flips the active sort mode's direction. On the Collections page it flips
    /// the collections sort; elsewhere it flips the grid sort. The arrow points
    /// up for ascending, down for descending; the tooltip spells out what that
    /// means for the active mode (e.g. "Newest first" vs "Oldest first").
    private var sortDirectionButton: some View {
        let ascending = isCollectionsPage ? appState.collectionSortAscending : appState.sortAscending
        let mode = isCollectionsPage ? appState.collectionSortMode : appState.sortMode
        return Button {
            if isCollectionsPage { appState.toggleCollectionSortDirection() }
            else { appState.toggleSortDirection() }
        } label: {
            Image(systemName: ascending ? "arrow.up" : "arrow.down")
        }
        .help(mode.directionLabel(ascending: ascending))
        .accessibilityLabel("Sort direction: " + mode.directionLabel(ascending: ascending))
    }
```

- [ ] **Step 4: Build to verify it compiles**

Run: `cd "Muse App/Muse" && xcodebuild -scheme Muse -destination 'platform=macOS' build 2>&1 | tail -20`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 5: Run the full test suite**

Run: `cd "Muse App/Muse" && xcodebuild -scheme Muse -destination 'platform=macOS' test 2>&1 | tail -25`
Expected: `** TEST SUCCEEDED **` (existing suite + the new `CollectionSortTests` all green).

- [ ] **Step 6: Checkpoint**

Build + tests green.

---

## Manual verification (after Task 4)

Run the app (Cmd+R in Xcode, or `xcodebuild ... build` then launch). Then:

1. Open the Collections page (toolbar `square.stack.3d.up`). The sort menu and the direction arrow are now **enabled**.
2. Open the sort menu on the Collections page → it lists exactly **Name, Date Created, Date Modified** (no Size/Kind/Color/Shape).
3. Default order is **Name A→Z** (unchanged from before).
4. Pick **Date Created**, toggle the arrow → cards reorder newest↔oldest; the arrow's tooltip reads "Newest first" / "Oldest first".
5. Pick **Name**, toggle the arrow → A→Z ↔ Z→A; tooltip matches.
6. Leave the Collections page (back arrow) → the **grid** sort menu shows the full 7 options again and reflects the grid's own `sortMode` (not the collection one). Sorting the grid does not change the collections order, and vice versa.
7. Quit and relaunch → the Collections page reopens with the sort you last chose (persistence).
8. While a search is active, the sort cluster is disabled (unchanged).

## Self-Review notes

- **Spec coverage:** sort options filtered (Task 1 `collectionCases` + Task 4 menu) ✓; separate persisted state (Task 2) ✓; context-aware toolbar + relaxed `.disabled` (Task 4) ✓; pure helper applying the sort (Task 1 + Task 3) ✓; reactive re-sort (Task 3) ✓; defaults preserve A→Z (Task 2 default `.name`) ✓.
- **No new "Members" sort, no manual reorder, no schema change** — none introduced ✓.
- **Type consistency:** `CollectionSort.order(_:by:reversed:)` signature is identical in Task 1 (definition + tests) and Task 3 (call site); `collectionSortMode` / `collectionSortReversed` / `collectionSortAscending` / `toggleCollectionSortDirection()` names identical across Tasks 2/3/4.
