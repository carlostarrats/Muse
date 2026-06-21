# Code-health refactor: shrink `AppState.swift` + `SidebarView.swift`

**Date:** 2026-06-20
**Branch:** `feat/next-50`
**Type:** Pure code-organization refactor (no behavior change, no new features)

## Motivation

The 2026-06-19 codebase-health rating (memory `muse-health-watch-list`) flagged
two files as the spots where future complexity will hurt first, with a standing
request to split them *before* they sprawl rather than after:

- `Muse/Muse/Models/AppState.swift` — **1,404 LOC** (was ~1,258 at the rating).
  Already partially split into `AppState+Selection` / `AppState+Filters`; the
  guidance is to keep splitting along that extension seam as state lands.
- `Muse/Muse/Views/SidebarView.swift` — **1,373 LOC** (was ~1,359). The named
  prime candidate is its **live-drag reorder logic**, which should be extracted
  into its own model/component before the file hits ~1,500.

Both have grown since the rating. This refactor addresses them now, as a
deliberate, conscious code-health pass.

## Hard constraints (non-negotiable)

This is a **reorganization, not a rewrite**. The bar is:

1. **No runtime behavior change.** Every drag, animation, sort, load, and
   transition must behave byte-identically to today.
2. **No performance regression.** The grid-virtualization, synchronous-commit,
   and animation-scoping invariants documented in `CLAUDE.md` must all survive
   untouched.
3. **The existing test suite stays green** at every checkpoint; new tests only
   add coverage, never replace the manual safety net for view wiring.

The two delicate, documented gotchas that this refactor must NOT disturb:

- The sidebar reorder commit must apply the new order **synchronously**
  (`bookmarks.$roots` delivers synchronously; the collection path mutates
  `CollectionsEngine.collections` in place synchronously) inside a
  `disablesAnimations` transaction. **This commit code stays inline on the
  view** — it is not moved.
- The reorderable lists must stay **non-lazy** `VStack`s. Untouched here.

## Approach (chosen)

**"Pure-math helper + file moves."** Considered and rejected: a full generic
`ReorderController` that relocates the drag `@State` off the view into an
external Observable. Rejected because moving that state changes *when* SwiftUI
observes mutations relative to its update cycle — precisely the seam where the
sidebar's historical timing bugs lived (frame-late snap/flash). Maximum dedup is
not worth disturbing timing-sensitive code that works. The chosen approach
removes duplication only at the **pure-math layer** (safe) and leaves the
**view/`@State`/gesture/commit layer** exactly as-is.

---

## Part A — `AppState.swift` extension splits

Mechanical reorganization. Swift extensions on the same `@MainActor class
AppState` compile to identical code — same type, same dispatch, same actor
isolation. Zero behavior change by construction.

### What stays in the core `AppState.swift`

- **All stored state** — every `@Published` property and every `private` stored
  property (the `FolderWatcher?`, the auto-mood `Timer?`, the Combine
  cancellables, tokens, caches). Swift extensions **cannot add stored
  properties**, so all declarations remain grouped in the core file. Only
  *methods* move.
- The load-bearing core logic: `init`, roots wiring (`rebuildRootNodes`,
  `pickAndAddRoot`, `removeRoot`, `select(rootForFirstFolder:)`,
  `discoverICloudZone`), and the folder-load pipeline (`select(folder:)`,
  `reloadCurrentFiles` + its Task, `openSubfolder`, `resolveFolderNode`,
  `reloadAfterMove`, `reloadCurrentFilesPublic`), the sort-direction toggles,
  and the small request-flag setters that are one-liners.

### New extension files (methods only)

| New file | Methods moved out of core |
|---|---|
| `Models/AppState+Backup.swift` | `exportBackup`, `beginRestorePicker` |
| `Models/AppState+FolderOps.swift` | `createSubfolder`, `renameFolder`, `migratePaths` (static), `findNode`, `requestNewSubfolder`, `requestRenameFolder` |
| `Models/AppState+Indexing.swift` | `scheduleIndexing`, `analyzeCurrentFolder`, `analyzeSelected`, `findDuplicatesInCurrentFolder` |
| `Models/AppState+Search.swift` | `runSearch`, `clearSearch` |
| `Models/AppState+Mood.swift` | `moodPalette` (computed), `setMood`, `updateAutoMoodTimer` |
| `Models/AppState+Watcher.swift` | `startWatching`, `handleFolderEvent` |
| `Models/AppState+TagChips.swift` | `reloadTagChips`, `bumpTagChipToken` |
| `Models/AppState+Starring.swift` | `toggleStar`, `openStarred` |

> **As-built note (deviation from the original spec table).** `enumerateRecursive`
> was originally listed under `+Indexing` but **stayed in core** `AppState.swift`:
> the core folder-load (`reloadCurrentFiles`) calls it, so leaving it in core avoids
> widening its visibility and keeps it next to its primary caller. `markContentChanged`
> likewise stays in core (shared by `+Indexing` and `+Watcher`). The final
> architecture map in `CLAUDE.md` reflects the as-built state.

Each extension file is `@MainActor extension AppState { … }` (the class is
already `@MainActor`; the explicit annotation keeps each file self-documenting
and matches the isolation). Private helpers move with the only method that uses
them; if a private method is shared across two extensions it stays in core.
`access` levels are preserved exactly (a `private func` that is only called from
within its new extension file stays `private`; one called cross-file becomes the
minimum visibility that compiles — `fileprivate` won't work across files, so
such a method becomes internal, which is a no-op for an internal-by-default
type).

### Expected result

Core `AppState.swift` drops from ~1,404 to roughly ~950–1,050 LOC; ~8 focused
extension files of 25–130 LOC each, named by responsibility. No test changes
required — behavior is identical, so the existing suite is the net.

---

## Part B — `SidebarView.swift` file moves + pure reorder-math helper

### B1 — Move the row/support types into their own files

These are **already independent `private struct`s** that merely share the file.
Moving each to its own file is a copy-with-no-semantic-change. They lose
`private` (file-scope) and become internal (the default), which is invisible for
types used only within the module. New folder `Views/Sidebar/`:

| New file | Types moved |
|---|---|
| `Views/Sidebar/FolderTreeNode.swift` | `FolderTreeNode` (~240 LOC) |
| `Views/Sidebar/CollectionSidebarRow.swift` | `CollectionSidebarRow` (~150 LOC) |
| `Views/Sidebar/SidebarRows.swift` | `StarRow`, `AddFolderPillButton`, `AddPillButton`, `SectionHeader` |
| `Views/Sidebar/SidebarReorderSupport.swift` | `RootFramePreference`, `CollectionFramePreference`, `SidebarReorderingKey` (+ its `EnvironmentValues` accessor), `ReorderContext` |

Constants currently `fileprivate static` on `SidebarView` that the moved types
reference (e.g. `SidebarView.reorderSpace`, `SidebarView.rowHeight`) must become
reachable cross-file. `reorderSpace` and `rowHeight` change from `fileprivate
static` to `static` (internal) on `SidebarView` so the moved row types can read
them, OR are promoted to a small shared `SidebarMetrics` enum if that reads
cleaner — decided during implementation, whichever yields the smaller diff.
Anything else the moved types touched that was `fileprivate` gets the same
minimal visibility bump.

### B2 — Extract the pure reorder math

The folder reorder math and the collection reorder math are **verified exact
mirrors** (confirmed line-by-line):

| Folder (on `SidebarView`) | Collection (on `SidebarView`) | Shared pure form |
|---|---|---|
| `rowShift(forIndex:)` | `collectionRowShift(forIndex:)` | `rowShift(forIndex:draggedIndex:dropTarget:pitch:)` |
| `reorderSlot(forY:)` | `collectionReorderSlot(forY:)` | `slot(forY:orderedStartFrames:)` |
| `insertionLineY()` | `collectionInsertionLineY()` | `insertionLineY(dropTarget:orderedLiveFrames:)` |

Create `Components/ReorderMath.swift` — a pure, `nonisolated enum` joining the
codebase's established pure-helper family (`GridSelection`, `PageScroll`,
`MasonryGeometry`, `CollectionSort`):

```swift
enum ReorderMath {
    /// How far a non-dragged row at full index `i` slides to part and open a
    /// gap for the dragged row at `dropTarget`. `pitch` = row height + spacing.
    static func rowShift(forIndex i: Int, draggedIndex: Int?,
                         dropTarget: Int?, pitch: CGFloat) -> CGFloat

    /// Insertion slot (0...frames.count) for a drag at vertical position `y`,
    /// measured against the ORDERED start-frame snapshots of the "other" rows
    /// (the dragged row excluded). nil entries (unmeasured rows) are skipped.
    static func slot(forY y: CGFloat, orderedStartFrames: [CGRect?]) -> Int

    /// Y of the gap at `dropTarget`, measured against the ORDERED LIVE frames of
    /// the "other" rows (which already reflect the parting offsets). nil if no
    /// target or no rows.
    static func insertionLineY(dropTarget: Int?, orderedLiveFrames: [CGRect?]) -> CGFloat?
}
```

The call sites become thin adapters that gather the per-path inputs and
delegate:

- Folder: `pitch` from `dragStartFrames[draggingRoot.id]?.height ?? rowHeight)
  + 1`; `orderedStartFrames` = `otherReorderRoots.map { dragStartFrames[$0.id] }`;
  `orderedLiveFrames` = `otherReorderRoots.map { rootFrames[$0.id] }`.
- Collection: the same shape over `collectionDragStartFrames` /
  `collectionFrames` / `otherCollectionIDs`.

**Everything else stays put on `SidebarView`:** the `@State`, the
`DragGesture` `onChanged`/`onEnded` closures, `commitReorder` /
`commitCollectionReorder` (synchronous, `disablesAnimations`), `resetDrag`, the
overlays (`draggedRowOverlay` / `draggedCollectionOverlay`), and the
`withAnimation(.easeInOut(duration: 0.16))` slot-change animation. The timing,
animation scoping, and synchronous-commit invariants are therefore unchanged —
only the arithmetic is centralized and now testable.

### New tests

`MuseTests/ReorderMathTests.swift` — covers `rowShift` (above/below/at the
dragged index; no-target → 0), `slot` (y above first / between / past last /
with nil gaps skipped), and `insertionLineY` (no target → nil; target past end →
last row maxY; mid → target row minY; empty → nil). This is the first automated
coverage of reorder logic, which is currently hand-verify-only (health-watch
item #3).

### Expected result

`SidebarView.swift` drops well under 1,000 LOC (the ~390 LOC of row structs move
out; the duplicated math collapses into shared calls). `ReorderMath.swift` ~60
LOC + its tests. The two reorder *paths* still read independently on the view
(their differing `@State` makes them genuinely distinct call sites) but no longer
duplicate the arithmetic.

---

## Verification plan (checkpoint-gated)

| Checkpoint | Gate |
|---|---|
| After **Part A** | `xcodebuild -scheme Muse build` clean + full `MuseTests` green. Behavior identical, so the existing suite is the net. |
| After **B1** | Build clean (pure type moves; SwiftUI rendering unchanged). |
| After **B2** | Build clean + full `MuseTests` green + new `ReorderMathTests` green. |
| Final | **Manual GUI confirmation** of both live drag-reorders (folder list + sidebar collection list, Manual sort): drag up, drag down, drag to top, drag to bottom, overshoot. This is the one surface with no automated net (per health-watch item #3) and MUST be eyeballed before the work is called done. |

A diff review pass (self or subagent) confirms no method body was altered during
a move — moves must be verbatim except for the access-level bumps and the
reorder-math delegation noted above.

## Out of scope (YAGNI)

- No generic `ReorderController`, no relocation of drag `@State`.
- No change to the O(n) scaling items (semantic search, tag `LIKE` scan,
  `CollectionStore` N+2) — separate concerns, not touched here.
- No new sidebar/AppState features. No renaming of public API.
- No touching the folder-load Task or roots-wiring core logic beyond moving
  whole self-contained methods.
