# Grid Faceted Filters (kind / date / size) — design

**Date:** 2026-06-20
**Status:** Approved (brainstorm complete)
**Ships as:** its own branch (second of three)

## Summary

Add a **filter** control to the grid: narrow the visible tiles by **kind**
(images / videos / PDFs / docs / audio / other), **date** (modified-date
presets), and **size** (size buckets). Today Muse can *sort* by these
dimensions but cannot *filter* by them. The filter is a popover opened from a
new funnel button placed in the toolbar's **sort grouping** (next to the
sort-mode icon and the direction arrow), and it stacks with the existing tag
and collection filters and with search.

## Motivation

The primary persona manages a Downloads/Documents pile. The recurring need is
"show me just the PDFs from this week" or "just the videos over 100 MB." That's
filtering, not sorting — and it's pure local work over data the app already has
(`AssetKind`, `FileRow.size_bytes`, `FileRow.modified_at` / `resourceValues`).

## The control

A new **funnel toolbar button** in the sort grouping (the pill that holds the
sort-mode menu + the up/down direction arrow in the toolbar). It opens a
**popover** styled like the mood picker. When **any** filter is active the
button **inverts to the accent (blue, white-on-accent)** — the same engaged
treatment as the show-subfolders toggle — so an active filter is never hidden.

Popover contents (one stacked pane, no tabs):

- **Kind** (checkboxes, multi-select):
  Images · Videos · PDFs · Documents · Audio · Other
  - Derived from `AssetKind` grouped into these buckets. All checked = no kind
    constraint (equivalent to off).
- **Date** (radio, single):
  Any · Today · This week · This month · This year
  - **Based on modified date** — matches the subtitle line and how a Downloads
    folder is mentally organized. ("Any" = off.)
- **Size** (radio, single):
  Any · < 1 MB · 1–10 MB · 10–100 MB · > 100 MB
  - ("Any" = off.)
- **Clear all** button — resets every facet to off (button returns to neutral).

Popover width follows the mood popover convention (~270).

## Behavior

### Composition

The filter is a **narrowing layer applied to the same `visibleFiles`
pipeline**, *after* the tag-chip filter. It therefore stacks with everything:
- Browsing a folder → folder files, minus tag filter, minus facet filter.
- Inside a collection → members, minus tag filter, minus facet filter.
- Search results → the facet filter narrows the result set too.

It never changes *which* set is the source (folder / collection / search) — only
removes non-matching files from it.

### Persistence

**Default: the filter persists across folder switches** (like sort mode does),
held on `AppState` and mirrored to `AppSettings`. The blue button is the
always-visible reminder, so a folder that looks sparse because of an active
filter is explained at a glance. *(Alternative considered: reset on folder
switch. Rejected as the default because it makes a cross-folder sweep — "PDFs
this week, everywhere I look" — impossible. Revisit if it confuses in practice.)*

### Empty result

If a filter removes everything, the grid shows its normal empty state. The blue
funnel + the open-popover state make the cause obvious; "Clear all" is one tap.

## Architecture & data flow

### New pure model: `GridFilter` (Models/GridFilter.swift)

A pure, unit-testable value type + matcher, mirroring the shape of
`ImageLayout` / `TileBackground`:

```swift
enum KindFacet: String, CaseIterable { case image, video, pdf, document, audio, other }
enum DateFacet: String, CaseIterable { case any, today, week, month, year }
enum SizeFacet: String, CaseIterable { case any, under1MB, mb1to10, mb10to100, over100MB }

struct GridFilter: Equatable, Codable {
    var kinds: Set<KindFacet>      // empty = no kind constraint
    var date: DateFacet            // .any = off
    var size: SizeFacet            // .any = off

    static let none = GridFilter(kinds: [], date: .any, size: .any)
    var isActive: Bool             // any facet constrains

    /// Pure predicate. `now` injected so date windows are testable.
    func matches(kind: AssetKind, sizeBytes: Int64?, modified: Date?, now: Date) -> Bool

    // Codable round-trip for AppSettings persistence.
    static func resolve(_ raw: String?) -> GridFilter   // default .none
}
```

- `KindFacet` maps from `AssetKind` (one helper `KindFacet(from: AssetKind)`),
  with anything unhandled → `.other`.
- Date windows computed against `now` via `Calendar.current` (start-of-day,
  start-of-week, etc.). Injecting `now` keeps `matches` deterministic in tests.
- Size buckets are simple byte-range checks; a nil size never matches a size
  constraint other than `.any`.

### Persistence + state

- `AppSettings`: add a `gridFilter` accessor (UserDefaults key
  `muse.gridFilter`, JSON-encoded `GridFilter`), default `.none`. Mirrors how
  `imageLayout` / `tileBackground` are stored.
- `AppState`: add `@Published var gridFilter: GridFilter`, mirrored to
  `AppSettings` (setter persists). Its `didSet` **invalidates the
  `visibleFiles` memo** (`_visibleFilesValid = false`), exactly like the
  existing filter inputs do.

### `visibleFiles` integration

In `AppState+Filters.visibleFiles`, apply the facet filter as the final
narrowing step, on **all** branches (search + browse):

```swift
var files = /* search results OR collection/tag-filtered files */
if gridFilter.isActive {
    let now = Date()
    files = files.filter {
        gridFilter.matches(kind: $0.kind,
                           sizeBytes: /* FileRow.size_bytes or resourceValues */,
                           modified: /* FileRow.modified_at or resourceValues */,
                           now: now)
    }
}
```

- `FileNode` already carries `kind`. Size + modified date come from the file's
  `resourceValues` (cheap, already used elsewhere) or the indexed `FileRow`
  values where available. The matcher takes raw inputs so the source is an
  implementation detail.
- The memo guarantees the per-file `resourceValues` reads happen only when an
  input actually changed, not on every grid render (same reason the tag filter
  is memoized today).

### Toolbar UI

- Add the funnel button to the sort grouping in `ContentView`'s toolbar, using
  the `moodToolbarIcon(_:selected:)` treatment so it recolors with the mood and
  shows the engaged blue when `gridFilter.isActive`.
- New `Views/GridFilterPopover.swift` renders the three sections + Clear all,
  writing `appState.gridFilter`.

## Scope (what changes / what doesn't)

**In scope:**
1. `GridFilter` pure model + matcher (+ tests).
2. `AppSettings.gridFilter` + `AppState.gridFilter` (persisted, memo-invalidating).
3. `visibleFiles` facet-narrowing on browse / collection / search branches.
4. Funnel toolbar button (engaged-blue) + `GridFilterPopover`.

**Out of scope (flag if you disagree):**
- Custom date ranges / custom size thresholds (presets only for v1).
- A tag facet inside this popover (tags are the chip row; kept separate).
- Filtering the Collections **card** page (it lists collections, not files).
- Per-folder saved filters / saved searches.
- Changing sort behavior or the direction arrow (the arrow still applies to the
  active sort mode, as today).

## Testing

- **`GridFilterTests`** (pure, new): `matches` across kind buckets, each date
  window (with an injected fixed `now` near boundaries — start of day/week/
  month/year), each size bucket (including nil size), combined facets (kind +
  date + size all set), and `isActive`/`resolve` default + round-trip.
- The popover + toolbar button are SwiftUI (not unit-tested per convention) —
  verify by build + applying each facet in a real folder, a collection, and a
  search, and confirming the blue engaged state + Clear all.

## Notes / rationale

- Reuses the established "pure model + AppSettings mirror + AppState @Published +
  memo invalidation" pattern (`imageLayout`, `tileBackground`), so it slots into
  the codebase with no new architecture.
- Modified-date basis (not created) chosen to match the subtitle line and the
  Downloads mental model; revisitable if "date taken" is wanted later (that data
  would come from the INFO-card EXIF work, a separate branch).
