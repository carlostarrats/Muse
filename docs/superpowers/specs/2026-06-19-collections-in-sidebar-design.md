# Collections in the Sidebar — design spec

**Date:** 2026-06-19
**Branch:** `feat/next-32`
**Status:** Approved, ready for implementation plan

## Summary

Add an opt-in second section to the left sidebar that lists the user's
**Collections** beneath the existing **Folders** tree. Gated by a new
Preferences toggle (**default OFF**). When OFF the sidebar is byte-for-byte
the current experience. When ON, the sidebar shows two labeled, independently
collapsible sections — **FOLDERS** and **COLLECTIONS** — and the bottom
"Add Folder" pill is replaced by two compact pills (Add Folder + Add
Collection).

Collections in the sidebar are a *browsing + management* surface: click to
open in the grid, drag to reorder, right-click to rename/delete/move, with a
sidebar-only sort that is **completely independent** of the Collections page.

## Goals

- A new setting **"Show Collections in the Sidebar"** (default OFF).
- When ON: a gray `FOLDERS` header and a gray `COLLECTIONS` header, each with
  the hero-page circular collapse/expand button (`+` collapsed → rotates 45°
  to `×` expanded).
- Collections list rows: collection (layered-stack) icon, name, image count.
- Click a collection → activates it in the grid (same as the Collections
  page); active row shows the blue selection highlight.
- A sidebar-only Collections **sort** (Manual / Name / Date Created / Date
  Modified), independent of the Collections page sort.
- **Manual** sort persists an explicit per-collection order; reorder via the
  same live drag used for folders + right-click Move Up/Down.
- Right-click Rename / Delete (durable `setHidden`) / Move Up / Move Down;
  app-menu + VoiceOver parity; full accessibility wiring.
- Bottom bar: when ON, two compact pills — **+ folder** (Add Folder) and
  **+ stack** (Add Collection, opens the Name Collection modal). New
  collection lands at the bottom of the Manual order.
- The whole sidebar (both sections) scrolls as one when content runs long;
  the bottom pill row stays pinned.

## Non-goals

- **No change to the Collections page.** Its card grid, sort options, and
  behavior are untouched. The sidebar's order/sort never affects the page,
  and vice-versa.
- No drag-reorder on the Collections page cards.
- No right-click "New Collection" in the sidebar list (creation is the bottom
  **+ stack** pill, the Collections page **+**, and the grid right-click
  "New Collection from Selection").
- No new network, sync, or data-collection surface.

## Behavior detail

### The setting

- `AppSettings.showCollectionsInSidebarKey = "showCollectionsInSidebar"`,
  accessor `AppSettings.showCollectionsInSidebar` defaulting to `false`
  (mirrors the existing `object(forKey:) as? Bool ?? false` pattern).
- `SettingsView` gets a new **Sidebar** section with a single toggle,
  bound via `@AppStorage(AppSettings.showCollectionsInSidebarKey)`.
- `SidebarView` reads the same key via `@AppStorage` and branches its layout
  on it. The detail/grid side is unaffected by the toggle.

### Section headers (only when ON)

- A gray uppercase **`FOLDERS`** label and a gray uppercase **`COLLECTIONS`**
  label, styled like the mockup (small, secondary, tracked caps).
- Each header has a trailing circular button reusing the hero viewer's
  `PlusCircleButton` look (white glyph at ~0.7 opacity on a faint circle,
  brighten on hover, **rotate 45° when expanded** so `+`→`×`). Because the
  sidebar background is light, the button uses a sidebar-appropriate tint
  (a faint `Color.primary`/secondary fill + primary glyph) rather than the
  hero's white-on-dark; the *shape, size, rotation, spring motion
  (`response 0.45, dampingFraction 0.75`), and hover behavior* match.
- Toggling a header collapses/expands that section: when collapsed, the
  section's `Sort:` row and all its rows are hidden, leaving only the header.
- **Default: both expanded.** Collapse state persists per section via
  `@AppStorage` (`sidebarFoldersCollapsed`, `sidebarCollectionsCollapsed`,
  both default `false` = expanded).
- When the setting is OFF, there is **no** `FOLDERS` header — the existing
  `Sort:` row sits at the top exactly as today.

### Collections list rows

- Source: the same visible-collections list the Collections page uses
  (`CollectionStore.fetchAll(queue:rootPaths:)` via `CollectionsEngine`),
  so hidden/deleted collections are excluded and the per-collection **count**
  is the reachability-aware alive-paths count (never lies vs. what opens).
- Each row: layered-stack icon (the collection glyph used by the Collections
  toolbar/cards, e.g. `square.stack.3d.up` family — match the existing card
  icon), the collection **name** (truncated tail), and the **count** on the
  trailing edge (secondary, monospaced digits), mirroring the folder row's
  count treatment.
- **Click** → `appState.setActiveCollection(collection.id)` (identical to
  opening from the Collections page; clears the grid selection, loads members,
  animates in). The clicked row becomes the **selected** row (blue
  `accentColor` tint + accent icon/label, matching folder selection); folders
  show no selection while a collection is active (already true via
  `activeCollectionID != nil`).
- The active collection row derives "selected" from
  `appState.activeCollectionID == collection.id` **and** not on the
  Collections page.
- Live refresh: the list and counts update when collections change
  (observe `CollectionsEngine` published snapshot, same as the page).

### Sidebar Collections sort (independent)

- New sidebar-only state on `AppState`:
  - `sidebarCollectionSortMode: SidebarCollectionSortMode` (@Published,
    persisted), default `.manual`.
  - `sidebarCollectionSortReversed: Bool` if a direction toggle is wanted —
    **deferred**; the sidebar sort header is a single menu like the folder
    `Sort:` header (no direction arrow in the sidebar today). Direction is
    out of scope unless folders gain one.
- A `Sort:` row under the COLLECTIONS header, same style/menu as the folder
  `Sort:` row, listing **Manual / Name / Date Created / Date Modified** with a
  checkmark on the active mode.
- Sorting helper: a pure `SidebarCollectionSort` (mirrors `FolderSort` /
  `CollectionSort`) that orders the loaded collections by the chosen mode.
  Name = A→Z; Date Created / Date Modified = newest first; Manual = explicit
  `sort_order`. Unit-tested.
- This state is **never** read by the Collections page and never writes the
  page's `collectionSortMode` / `collectionSortReversed`.

### Manual order + reorder

- Add a persisted manual order for collections. **Schema migration**: add a
  `sort_order INTEGER` column to the `collections` table (new migration
  version, e.g. `v8_collection_sort_order`), back-filled so existing
  collections keep their current display order (e.g. by `created_at` then
  name, or current biggest-first — choose a deterministic seed and document
  it). New collections (any creation path) get `max(sort_order)+1` so they
  append to the bottom of Manual.
- `CollectionStore` gains:
  - read of `sort_order` into the loaded model.
  - `setSortOrder(queue:id:order:)` / a `reorder(queue:moved:relativeTo:
    placeAfter:)`-style call that rewrites the affected rows in one
    transaction (mirror `BookmarkStore.reorder` semantics).
- The sidebar reorder UI reuses the **folder drag mechanism**: a trailing
  grip that appears on hover (Manual only) and swaps with the count, the
  dragged row hidden in place, an opaque floating overlay following the
  cursor, other rows parting with an insertion line, non-animated commit.
  This works **inside the shared scroll view** using a named coordinate space
  like the folder reorder does.
- Right-click **Move Up / Move Down** (Manual only) call the
  `CollectionStore` reorder, indexing the displayed sidebar order — the
  keyboard/VoiceOver parallel to the drag.

### Right-click menu, app menu, accessibility

- **Row context menu:** `Rename…` (opens a Name dialog like folder rename →
  `CollectionStore.rename`), `Delete` (durable `setHidden(true)` + reload,
  same confirm copy as the card today: "The collection is removed everywhere.
  Your images stay on disk."), `Move Up` / `Move Down` (Manual only).
- **App menu:** add a Collections menu group (or extend the existing one)
  with keyboard/VoiceOver-reachable **Move Collection Up / Move Collection
  Down** (gated to Manual + a selected/active collection), paralleling the
  Edit-menu Move Folder Up/Down.
- **Accessibility:** each row is one activatable element — label
  "`<name>`, `<n>` items", `.isButton` (+ `.isSelected` when active), a
  primary action that activates the collection, and named actions
  `Rename Collection`, `Delete Collection`, `Move Up`, `Move Down`. The drag
  grip is `accessibilityHidden` (mouse-only), like the folder grip. The two
  section headers and their collapse buttons, the `Sort:` menu, and both
  bottom pills get explicit labels.

### Bottom bar

- **OFF:** unchanged — the single full-width "Add Folder" pill
  (`AddFolderPillButton` → `pickAndAddRoot`).
- **ON:** two compact, equal, capsule pills on one row at the same height as
  the current pill, each icon-only with a leading `+`:
  - **`+` + folder glyph** → `appState.pickAndAddRoot()` (Add Folder).
  - **`+` + stack glyph** → `appState.requestNewCollection()` → the existing
    **Name Collection** `.alert` → `confirmNewCollection()` →
    `createManual` + rename. Empty selection ⇒ a new empty named collection,
    assigned the next (bottom) Manual `sort_order`.
- Both pills stay pinned below the scroll view; the scroll view holds both
  sections.

### Scrolling

- FOLDERS and COLLECTIONS live in **one** scroll view so the combined content
  scrolls together; the bottom pill row remains pinned (matches today's
  layout where `AddFolderPillButton` sits outside the scroll view).

## Components touched / added

- `Settings/AppSettings.swift` — new key + accessor.
- `Settings/SettingsView.swift` — new Sidebar section + toggle.
- `Models/AppState.swift` (+ `AppState+Filters.swift` if appropriate) —
  `sidebarCollectionSortMode` (@Published, persisted); helpers to load/observe
  the sidebar collections list; `setActiveCollection` reused as-is.
- `Models/SidebarCollectionSortMode.swift` (new) — enum + pure
  `SidebarCollectionSort.order(...)`. Unit-tested.
- `Database/Database.swift` — new migration adding `collections.sort_order`.
- `Database/Records.swift` — `CollectionRow.sort_order`.
- `Intelligence/Collections/CollectionStore.swift` — read `sort_order`;
  `reorder` / `setSortOrder`; assign bottom order on create.
- `Intelligence/Collections/CollectionsEngine.swift` — surface `sort_order`
  in its loaded snapshot if needed for the sidebar.
- `Views/SidebarView.swift` — the headers, collapse buttons, COLLECTIONS
  section (rows, sort header, drag-reorder, context menus), the two-pill
  bottom bar, single shared scroll view.
- `ContentView.swift` — app-menu Move Collection Up/Down; (Name Collection
  alert already exists).
- `MuseTests/` — `SidebarCollectionSortTests`, a migration test for
  `sort_order`, and reorder-rule coverage.

## Testing

- Unit: `SidebarCollectionSort.order` across all four modes (Name A→Z, the two
  date modes newest-first, Manual by `sort_order`); tie-breaks.
- Unit: the `sort_order` migration back-fills deterministically; new rows get
  `max+1`; reorder rewrites are correct and transactional.
- Manual/QA: toggle ON/OFF parity (OFF = exactly current sidebar); collapse
  persistence; click-to-activate + selection highlight; drag reorder inside
  the scroll; Move Up/Down; rename/delete; both bottom pills; long-list
  scrolling; VoiceOver labels/actions.
- Full suite stays green; build clean via `xcodebuild -scheme Muse`.

## Durable constraints respected

- Collection "delete" stays `setHidden(true)` (durable tombstone), never a row
  delete.
- Counts use the reachability-aware alive-paths count (feat/next-28), so the
  sidebar badge can't claim a number the grid can't back up.
- No `.onDrag` on sidebar rows (it eats single-clicks) — reorder is a live
  `DragGesture` off a trailing grip, mirroring the folder implementation.
- Sidebar reserve / scroll-clip rules: the new section lives within the
  existing scroll structure; the bottom pills stay outside it.
- Fix-the-code, not the dev DB: the migration back-fill is forward code;
  validate by a clean run.
