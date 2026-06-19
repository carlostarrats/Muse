# Sort the collections page — design

**Date:** 2026-06-18
**Status:** Approved (design); ready for implementation plan

## Goal

Let the user sort the collections card grid. Today it is hardcoded to
alphabetical A→Z. Reuse the existing toolbar **sort menu** and **direction
arrow**, made context-aware for the collections page, hiding the sort options
that don't apply to a collection.

## Background (current behavior)

- **Collections page** (`Views/CollectionsPage.swift`): renders all collections
  as a 4-column card grid. `sorted` is hardcoded A→Z (case-insensitive) over
  `engine.collections`.
- **Grid sort** uses `SortMode` (`Intelligence/Sort/SmartSorter.swift`):
  `dateModified, dateCreated, name, size, kind, dominantColor, shape`. It has
  `defaultAscending` and `directionLabel(ascending:)`.
- **Toolbar** (`ContentView.swift`): `sortMenu` (Picker over `SortMode.allCases`)
  and `sortDirectionButton` (toggles `appState.sortReversed`). Both are
  `.disabled(isCollectionsPage || appState.isSearchActive)`.
- **Per-context sort precedent already exists:** `tagSortMode` (TagSortMode) and
  `folderSortMode` (FolderSortMode) are separate `@Published` properties on
  `AppState`, persisted in `AppSettings`. This feature follows the same pattern.
- **Collection model** (`CollectionRow` in `Database/Records.swift`) has `name`,
  `created_at: Int64`, `updated_at: Int64`, `aliveCount` (via
  `CollectionStore.Loaded`). No manual-order/index field.

## Design

### Sort options on the collections page

Reuse the same `SortMode` menu, filtered to the three cases that apply to a
collection: **Name**, **Date Created**, **Date Modified**. **Size, Kind, Color,
Shape are hidden** whenever the user is on the collections card grid — they are
per-image properties a collection (a group) does not have.

The direction arrow is unchanged and flips each one using the existing
`SortMode.directionLabel`/`defaultAscending` (Name: A→Z / Z→A; dates: Oldest /
Newest first).

Add a small helper exposing the collection-applicable cases, e.g.:

```swift
extension SortMode {
    /// Cases that map onto a collection (a group, not a file).
    static let collectionCases: [SortMode] = [.name, .dateCreated, .dateModified]
}
```

### State (AppState)

Add two properties, mirroring `tagSortMode` / `folderSortMode`:

```swift
@Published var collectionSortMode: SortMode = .name        // A→Z by default
@Published var collectionSortReversed = false
```

- Persist both in `AppSettings` (new keys), restored on init, saved via Combine
  sinks like the existing sort modes.
- Default `.name` + not-reversed reproduces today's A→Z behavior exactly.
- Kept **separate** from the grid's `sortMode` / `sortReversed` so sorting
  collections never disturbs the image-grid sort and vice versa (same isolation
  as tag and folder sorts).

Add an effective-direction helper paralleling `sortAscending`:

```swift
var collectionSortAscending: Bool {
    collectionSortReversed ? !collectionSortMode.defaultAscending
                           : collectionSortMode.defaultAscending
}
```

…and a `toggleCollectionSortDirection()` paralleling `toggleSortDirection()`.

### Toolbar wiring (ContentView.swift)

- Make `sortMenu` context-aware: when `isCollectionsPage`, bind the Picker to
  `collectionSortMode` and iterate `SortMode.collectionCases`; otherwise bind to
  `sortMode` over `SortMode.allCases` (current behavior). Changing the collection
  mode needs no `resort()` — see below.
- Make `sortDirectionButton` context-aware: when `isCollectionsPage`, render the
  arrow from `collectionSortAscending`, tooltip from
  `collectionSortMode.directionLabel(ascending:)`, and call
  `toggleCollectionSortDirection()`; otherwise current behavior.
- Change the `.disabled(...)` on the sort cluster from
  `isCollectionsPage || appState.isSearchActive` to just
  `appState.isSearchActive`, so the cluster is live on the collections page.
- The **tag-sort menu stays** `.disabled(isCollectionsPage || isSearchActive)` —
  no tag chips on the collections page.

### Applying the sort — a pure helper (CollectionSort)

Follow the codebase's established pattern for sortable lists (`FolderSort.order`
in `FolderSortMode.swift`, unit-tested in `FolderSortTests`): a pure, `@testable`
function over a minimal value type, not an inline closure in the view. This keeps
`CollectionsPage` thin and gives the sort its own unit test like every other sort
in the app.

Add (e.g. in `Intelligence/Collections/CollectionSort.swift`):

```swift
nonisolated enum CollectionSort {
    struct Item: Equatable {
        let id: String
        let name: String
        let createdAt: Int64
        let updatedAt: Int64
    }

    /// Ordered ids for `items` under `mode`, then reversed if `reversed`.
    /// Base direction matches each mode's `SortMode.defaultAscending`
    /// (Name A→Z, dates newest-first) so the toolbar arrow + tooltip stay
    /// truthful. Name is the tiebreak for the date modes.
    static func order(_ items: [Item], by mode: SortMode,
                      reversed: Bool) -> [String] {
        let base: [Item]
        switch mode {
        case .name:
            base = items.sorted(by: nameAscending)               // A→Z
        case .dateCreated:
            base = items.sorted { tie($0, $1, $0.createdAt, $1.createdAt) } // newest first
        case .dateModified:
            base = items.sorted { tie($0, $1, $0.updatedAt, $1.updatedAt) } // newest first
        default:
            base = items   // unreachable; only collectionCases are selectable
        }
        let ids = base.map(\.id)
        return reversed ? ids.reversed() : ids
    }

    private static func nameAscending(_ a: Item, _ b: Item) -> Bool {
        a.name.localizedStandardCompare(b.name) == .orderedAscending
    }
    // Newest-first with a name tiebreak (matches SmartSorter's date modes).
    private static func tie(_ a: Item, _ b: Item, _ da: Int64, _ db: Int64) -> Bool {
        da != db ? da > db : nameAscending(a, b)
    }
}
```

`CollectionsPage.sorted` then maps `engine.collections` → `CollectionSort.Item`,
calls `order(_:by:reversed:)` with `appState.collectionSortMode` /
`collectionSortReversed`, and reorders the loaded collections by the returned ids.

Because `collectionSortMode` / `collectionSortReversed` are `@Published` and the
view observes `AppState`, the card grid re-sorts reactively — no manual resort
path is needed (unlike the grid, which stores `currentFiles` as an array).
Confirm `CollectionsPage` observes `AppState` (env object) so the computed
property re-evaluates on change.

## Out of scope (YAGNI)

- No new "Members" / member-count sort.
- No manual drag-reordering of collections (no order field; would need a schema
  change).
- No schema migration (the `created_at` / `updated_at` columns already exist).
- In-collection (drilled-in) image sorting is unchanged — it already reuses the
  grid `sortMode`.

## Files touched

- `Intelligence/Sort/SmartSorter.swift` — add `SortMode.collectionCases`.
- `Intelligence/Collections/CollectionSort.swift` (new) — pure `CollectionSort`
  helper.
- `MuseTests/CollectionSortTests.swift` (new) — unit tests for the helper.
- `Models/AppState.swift` — `collectionSortMode`, `collectionSortReversed`,
  `collectionSortAscending`, `toggleCollectionSortDirection()`, persistence
  sink.
- `Settings/AppSettings.swift` — two new persisted keys.
- `ContentView.swift` — context-aware `sortMenu` / `sortDirectionButton`;
  relax `.disabled`.
- `Views/CollectionsPage.swift` — state-driven `sorted` via `CollectionSort`.

## Verification

- Collections page defaults to Name A→Z (unchanged from today).
- Switching to Date Created / Date Modified and toggling the arrow reorders cards
  immediately; tooltip text matches direction.
- Size/Kind/Color/Shape do not appear in the menu on the collections page.
- Leaving and returning to the collections page preserves the chosen sort
  (persistence).
- The image-grid sort and the in-collection sort are unaffected by collection
  sort changes.
