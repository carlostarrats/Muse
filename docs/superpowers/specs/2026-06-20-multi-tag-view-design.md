# Multi-Tag View (AND / intersection) — design

**Date:** 2026-06-20
**Status:** Approved (brainstorm complete)
**Ships as:** its own branch (third of three; most invasive)

## Summary

Let the tag chip row filter the grid by **more than one tag at once**. Today
exactly one tag can be active (`AppState.activeTagLabel: String?`). This feature
makes it a set: **Cmd-click** chips to build a selection, and the grid shows
files carrying **all** selected tags (set **intersection / AND**). When two or
more tags are selected, a **banner at the top of the grid area** names the
active set so it's legible even when the selected chips are scrolled apart.

Scope expands beyond browsing: multi-tag view works **in a folder, inside a
single collection, and over search results**.

This is a **view/filter-only** feature. There is **no** multi-select delete —
tag deletion stays single, via right-click → "Delete Tag…" (unchanged).

## Motivation

A single-tag filter is just "click each tag in turn." The value users actually
lack is *narrowing*: "show me the images that are **blue and** a **screenshot**"
— the intersection, which today requires manually building a collection. AND
across tags adds a capability the app doesn't currently offer; OR (union) would
not (it's equivalent to clicking tags one at a time).

## Behavior

### Selection model

- **Plain click** a chip → view *just* that tag (replaces the selection with a
  single tag — today's behavior, preserved).
- **Cmd-click** a chip → toggle it in/out of the selection (add if absent,
  remove if present).
- **"All"** chip, or re-plain-clicking the sole selected chip → clears the
  selection.
- Selected chips render with the existing filled/`isSelected` style. With 2+
  selected, multiple chips are filled simultaneously.

### Filtering — AND / intersection

The grid shows files whose tag set contains **every** selected label. With one
tag this is identical to today. Adding tags monotonically narrows the result;
an unrelated combination can legitimately produce **zero** results, which shows
the normal empty grid (honest — the banner explains what's being viewed).

### Banner

When **2+ tags** are selected, a banner sits at the **top of the grid view
area** (below the chip row, above the tiles):

- 2 tags: *"Viewing blue and screenshot"*
- 3+ tags: *"Viewing blue, screenshot, and invoice"* (Oxford-style, "and" before
  the last)

With 0 or 1 tag selected there is **no banner** (a single filled chip is already
clear). The banner is informational text styled to match the app's quiet
secondary text; it reserves space the same way the chip row does so the grid
top doesn't jump (see the existing `TagChipsRow.noTagsTopClearance` discipline).

### Scope — folder, single collection, AND search

- **Folder / single collection:** as today, the chip row is mounted and tag
  filtering applies to the current source set.
- **Search (new):** today the search path **bypasses** tag filtering
  (`visibleFiles` returns raw `currentFiles` when `isSearchActive`) and the chip
  row is **unmounted during search**. This feature **mounts the chip row over
  search results** and has the tag filter **narrow within the search result
  set** (works for both This-Folder and All-folders scope). The banner shows
  during search too.
- **Out of scope for the chip row** (unchanged): the Collections **card** page
  (no per-file source there).

### Escape / clearing

`EscapeResolver` currently peels a single active tag. It now clears the **whole
tag set** in one press (still ordered after closing the viewer / search per the
existing priority chain). One Escape empties the selection; it does not remove
tags one at a time.

## Architecture & data flow

### State change: scalar → ordered set

`AppState`:
- Replace `activeTagLabel: String?` with `activeTagLabels: [String]` (ordered —
  insertion order drives the banner wording) **or** a `Set<String>` plus a
  parallel order array. Ordered array is simplest; treat membership via
  `contains`.
- `activeTagPaths: Set<String>?` stays, now computed as the **intersection** of
  each selected tag's path set.

`setActiveTag` evolves into selection mutations:
- `setActiveTag(_ label: String?)` → "replace selection" (plain click / clear).
- `toggleActiveTag(_ label: String)` → "Cmd-click toggle".
- Both recompute `activeTagPaths` by querying each selected label's paths (the
  existing per-label SQL in `setActiveTag`) and **intersecting** the results.
  With the labels' path sets `P1, P2, …`, `activeTagPaths = P1 ∩ P2 ∩ …`. One
  query per selected label (selection sizes are tiny); reuse the existing
  per-location-correct SQL (the `parent_dir` scoping must be preserved).

### `visibleFiles`

- Browse / collection branch: unchanged shape, but the tag filter now uses the
  intersection `activeTagPaths`.
- **Search branch changes:** instead of returning raw `currentFiles` when
  `isSearchActive`, apply the tag filter to the search results too:
  ```swift
  if isSearchActive {
      var files = currentFiles
      if let tagPaths = activeTagPaths { files = files.filter { tagPaths.contains($0.url.standardizedFileURL.path) } }
      result = files
  }
  ```
- Memo invalidation: the selection mutations already bump the inputs that
  invalidate `_visibleFilesValid`; extend that to the new set state.

### Touchpoints to update (the invasive part)

`activeTagLabel` is referenced across the codebase; each must move to the set:
- `TagChipsRow` — chip `isSelected` becomes "label ∈ selection"; click vs
  Cmd-click routing (plain → replace, Cmd → toggle); render the banner.
- `AppState+Filters` — `setActiveTag` / new `toggleActiveTag`, the `removeTag`
  path (which checks `activeTagLabel == label` to decide whether to drop tiles /
  fall back to All), and `reloadTagChips` callers.
- `EscapeAction` / `EscapeResolver` — clear the whole set; update the
  `searchPresent`/tag-active glue and its unit tests.
- Search mounting — the view layer that unmounts `TagChipsRow` during search
  must keep it mounted; ensure chip labels are sourced correctly for the search
  result set (`tagSourceFiles` may need a search-aware source).
- Anywhere else reading `activeTagLabel` (grep before implementing).

### Chip labels during search

`tagSourceFiles` today is `activeCollectionFiles ?? currentFiles`. For search,
the chip labels should derive from the **search result set** so the offered
chips are relevant. Add a search-aware source (e.g. when `isSearchActive`, the
source is the current search results) feeding `reloadTagChips`.

## Scope (what changes / what doesn't)

**In scope:**
1. Multi-select tag chips (plain-click replace, Cmd-click toggle) with AND
   filtering.
2. The "Viewing … and …" banner for 2+ tags.
3. Tag filtering over search results + mounting the chip row during search.
4. `EscapeResolver` clearing the full set.

**Out of scope (flag if you disagree):**
- **Bulk tag delete** — explicitly dropped; deletion stays single via
  right-click context menu.
- OR/union mode or an AND/OR toggle — AND only.
- Tag filtering on the Collections card page.
- Cross-collection / cross-folder tag views beyond what search already offers.
- Saving a multi-tag selection as a collection (could be a future convenience,
  not now).

## Testing

- **Selection/intersection logic** (pure, new — e.g. extend the tag-filter
  helpers or a small `TagSelection` type): replace vs toggle transitions;
  intersection of multiple labels' path sets; clearing; banner-text formatting
  for 2 and 3+ labels (Oxford "and").
- **`EscapeActionTests`** — update for "clear whole tag set in one press" and
  confirm the viewer/search priority ordering is unchanged.
- `TagChipsRow` rendering, Cmd-click routing, and the search-mount behavior are
  SwiftUI (not unit-tested per convention) — verify by build + driving:
  multi-tag in a folder, in a collection, and over a search; confirm AND
  semantics, the banner, empty-result honesty, and Escape clearing.

## Notes / rationale

- AND is the capability that doesn't already exist; OR is just sequential
  single-tag clicks or a collection (per the brainstorm).
- The scalar→set change is the real cost; the SQL and UI are small. Grep all
  `activeTagLabel` readers first and migrate them together to avoid a
  half-migrated state.
- Preserving plain-click = single tag keeps today's muscle memory; Cmd-click is
  the additive gesture, consistent with macOS multi-select conventions and the
  grid's own Cmd-click selection model (`GridSelection`).
