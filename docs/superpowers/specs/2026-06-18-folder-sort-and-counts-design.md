# Sidebar folder sort modes + live file counts — design

**Date:** 2026-06-18
**Branch:** `feat/next-15`
**Status:** approved (brainstorm) — ready for implementation plan

## Summary

Add, at the top of the left sidebar, a **sort control** for the top-level
folders, plus a **live file count** on each top-level row. Default sort is
**Manual** (today's drag-to-reorder). Alternatives: **Name**, **Date Modified**,
**Size**. The count sits at the far right of each row; on hover in Manual mode it
swaps in place for the drag grip. All numbers (count/size/modified) update live as
folder contents change.

## Scope

- **Top-level folders only** — the reorderable roots, matching where drag-reorder
  already lives. The iCloud "Muse" home gets a count but stays pinned/undraggable.
- Subfolders revealed by expanding a folder are **not** sorted or counted
  (unchanged).

## Behavior

### Sort modes

A slim header at the very top of the sidebar is a **labeled menu button**:
`Sort: Manual ▾` (label reflects the active mode). Tapping opens a menu with a
checkmark on the active item:

- **Manual** (default) — the user's hand-ordered arrangement (today's behavior).
  Draggable.
- **Name** — A → Z (case-insensitive, localized), by folder display name.
- **Date Modified** — newest first.
- **Size** — largest first.

Directions are **fixed** (no per-mode direction toggle — YAGNI). The chosen mode
**persists across launches**.

### Manual vs sorted (the key interaction)

- **Manual** mode: rows are draggable — grip shows on hover, reorder works exactly
  as today, manual order persists in the existing `BookmarkStore.roots` array.
- **Name / Date Modified / Size**: rows are a **read-only sorted display — NOT
  draggable**. No grip appears; the count stays put on hover. To rearrange, switch
  to Manual.
- The Manual order is a **separate, preserved state** — selecting a sort never
  alters it, and switching back to Manual restores it exactly. (This is why
  sorted modes are read-only: it keeps the manual arrangement from being silently
  overwritten.)

### File count + hover swap

- Far right of each top-level row: a **small, secondary-colored count**.
- The count **follows the show-subfolders toggle** (`AppState.showSubfolders`) so
  it always matches what the grid would show:
  - toggle **off** → `immediateFileCount` (viewable files directly in the folder),
  - toggle **on** → `recursiveFileCount` (all viewable files under the folder).
  - Toggling is **instant** — both counts live in the cached stat; no recompute.
- **Hover swap (Manual mode only):** on hover the count fades out and the drag
  grip (≡) fades in **in the same slot**; the grip stays through the drag and
  until release / cursor leaves. In sorted modes there is no grip, so the count
  simply remains on hover.
- The iCloud "Muse" row shows a count but never a grip.

### Size and Date Modified are always whole-folder (recursive)

Unlike the count, **Size and Date Modified are inherently aggregate** and do NOT
follow the show-subfolders toggle: adding/removing an image deep in a subfolder
changes the top folder's total size and counts as a modification to it. So:

- **Size** = recursive total bytes of all files under the folder.
- **Date Modified** = the **newest modification time anywhere under the folder**
  (recursive max mtime — NOT the folder's own inode mtime, which doesn't bubble up
  from deep changes).

### Live updates

Counts/size/modified must stay current as files are added, removed, or edited —
including changes in subfolders and in folders that aren't currently selected.

- A dedicated **FSEvents watch over all top-level root paths (recursive)** drives
  recomputation. Any change under a root invalidates that root's stat and triggers
  a background re-walk, **debounced/coalesced** (~0.3–0.5s) so bursts collapse into
  one recompute. The published result updates the row's number in place.
- Also recompute when roots are added/removed and once at launch.
- In-app mutations (move-to-folder, move-to-Trash, drop-in) hit the filesystem and
  flow through the same watch; the existing post-mutation reloads may also nudge a
  refresh for immediacy.

## Components

### `FolderStat` (value type, `Filesystem/`)

```
struct FolderStat {
    var immediateFileCount: Int   // viewable files directly in the folder
    var recursiveFileCount: Int   // viewable files anywhere under it
    var totalSize: Int64          // recursive sum of all file sizes
    var latestModified: Date?     // recursive newest mtime (nil if empty)
}
```

"Viewable" is decided by the existing `AssetKind` classification (same notion the
grid uses), so the count matches the grid.

### `FolderStatCache` (new, `Filesystem/`, `@MainActor` `ObservableObject`)

- Computes `FolderStat` per top-level folder URL **off-main** (a recursive walk
  reusing `FolderReader`/`AssetKind`); the **immediate** count is cheap and can
  show instantly, the recursive fields fill in when ready (like thumbnails).
- Caches by standardized URL; publishes changes so the sidebar refreshes.
- Owns the **roots FSEvents watcher** (recursive, all root paths) + debounce; on a
  change under a root, re-walks just that root.
- Reacts to roots add/remove (rebuild the watch + drop stale entries) and computes
  at launch.
- A folder whose stat isn't computed yet returns `nil`/placeholder (row shows no
  number until ready).

### `FolderSortMode` (enum) + persistence

```
enum FolderSortMode: String, CaseIterable { case manual, name, dateModified, size }
```

Persisted in `UserDefaults` (e.g., via `AppSettings`), default `.manual`. A pure
**comparator** maps `(mode, FolderStat, displayName)` → ordering, with a stable
**name tiebreak** for Date/Size ties (and folders missing a stat sort last among
their mode). This comparator is pure and unit-tested.

### `SidebarView` changes

- New top header: the `Sort: <mode> ▾` menu button.
- Display order of the reorderable roots = Manual → `BookmarkStore.roots` order;
  otherwise the comparator applied over the roots + their `FolderStat`.
- The drag grip + the count→grip hover swap are gated on `mode == .manual`.
- Each top-level row shows the count (toggle-scoped) from `FolderStatCache`.
- The live reorder gesture (from the prior session) is unchanged and only active
  in Manual mode.

### `BookmarkStore`

- Unchanged for reordering — the identity-based `reorder(_:relativeTo:placeAfter:)`
  still drives Manual drags, and `roots` remains the manual order. No "bake
  sorted→manual" path is needed (sorted modes are read-only).

## Performance

- Immediate count: one directory read, instant.
- Recursive fields: background + cached; appear when ready.
- Toggling show-subfolders: instant (selects a different cached field, no recompute).
- Live updates: debounced full re-walk per affected root (simple + robust; no
  fragile incremental delta math).
- Counts for unselected roots are kept live by the roots watcher; worst case they
  lag by the debounce interval.

## Testing

- **Pure comparator** — Name (case/locale, tiebreak), Date newest-first, Size
  largest-first, missing-stat ordering, Manual passthrough.
- **`FolderStat` aggregation** — against a temp directory tree: immediate vs
  recursive viewable count, total size sum, latest mtime including a deep change,
  empty folder.
- **Persistence** — sort mode round-trips through `UserDefaults`.
- UI wiring (menu, hover swap, gating) is not unit-tested (consistent with the
  project's "UI views aren't unit-tested" stance) — verified by running the app.

## Out of scope / non-goals

- Sorting subfolders inside the tree.
- A direction toggle per mode.
- Converting a sorted arrangement into the manual order (sorted modes are
  read-only by design).
- Counting/sizing non-viewable files for the *count* (count = viewable, matching
  the grid); `totalSize` does include all files (true folder size).
