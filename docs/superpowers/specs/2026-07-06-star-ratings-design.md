# Star ratings — design spec

**Date:** 2026-07-06
**Branch context:** off `feat/next-115` (clean, `main`-equivalent)
**Source:** `docs/perf-and-feature-review-2026-07-03.md` — Part 2, item 6 "Star
ratings" (owner design finalized 2026-07-04). BINDING; this spec does not
re-litigate it, only fills the delegated open decisions.
**Scope:** one self-contained feature. Ratings ride the existing tag system;
the only genuinely new visual is a small on-tile badge.

---

## 1. Problem / goal

Muse has no way to rate a photo. The generalist persona wants the Adobe-Bridge
staple: mark keepers 1–5 stars, then instantly see and filter by rating. The
owner's finalized design realizes a rating **as a special manual tag** so that
storage, per-folder scoping, safety from the auto-tagger, and filtering all come
for free from machinery that already exists and is test-pinned — leaving exactly
one new UI primitive to build (the tile badge).

Non-goals (owner, explicit): color labels (dropped — stars cover it and are
colorblind-safe), any auto-rating, any rating over the hero image, a clickable
badge, EXIF/XMP rating write (settled no).

---

## 2. The rating-as-tag model

A rating is a **manual tag whose label is a run of BLACK STAR glyphs** (`U+2605
★`), 1 to 5, per `(file_id, parent_dir)` — identical in every respect to a
hand-typed tag, so it inherits:

- **Per-location scoping.** A tag belongs to `(file_id, parent_dir)`
  (`TagScope.parentDir`, `Database/TagScope.swift:22`; schema `UNIQUE(file_id,
  parent_dir, label)`). A duplicate of a rated photo in another folder has its
  own rating; a rating delete never leaks across folders. No library-wide rating
  delete — same as tags.
- **Safety from the auto-tagger.** `TagStore.addManualTag` stamps
  `source = "manual"` (`Database/TagStore.swift:66–100`); manual beats vision on
  the `UNIQUE` conflict (Q32). The Vision tagger only ever emits vocabulary
  terms — never a pure glyph run — so a rating tag can never collide with an
  auto-tag, and even if it somehow did, manual wins and the rating survives
  re-analysis.
- **Filtering for free.** Rating tags surface as ordinary chips in `TagChipsRow`;
  clicking the `★★★★★` chip filters the grid to 5-star photos through the exact
  same `setActiveTag(label)` path every tag chip uses
  (`Views/TagChipsRow.swift:77`, `Models/AppState+Filters.swift:476`). No new
  filter code.

### 2.1 Canonical stored label (delegated decision — resolved)

The glyph run **is** the canonical stored label: `"★"`, `"★★"`, `"★★★"`,
`"★★★★"`, `"★★★★★"`. Five distinct labels. Because a glyph needs no
translation, a rating label needs **no** `VocabularyLocalizer` / `VisionVocabulary.json`
row.

**Verified against the real display path (not assumed):** every chip and pill
renders its label through `VocabularyLocalizer.shared.display(canonical)`
(`Views/TagChipsRow.swift:54`, `Viewers/Viewer/ViewerInfoColumn.swift:448`).
`display` returns `forward[canonical.lowercased()] ?? canonical`
(`Localization/VocabularyLocalizer.swift:40`) — pure identity for any label not
in the vocabulary table. A glyph run is never in the table, so it passes through
**unchanged** and renders as literal stars in the chip, the active-filter banner,
and the hero pills. No special-casing of the display layer is required. (This
was the load-bearing assumption to check; it holds.)

### 2.2 Badge glyph form (delegated decision — resolved)

**Filled-only**, e.g. `★★★` for three stars — NOT out-of-five (`★★★☆☆`). Compact
for a corner badge, and it equals the canonical label 1:1 (the badge just draws
the label string).

### 2.3 Pure, testable helper — `StarRating`

All star↔label logic lives in one pure value type, `Models/StarRating.swift`
(pure, `nonisolated`, no I/O), unit-tested in isolation. It is the single source
of truth for "what label is N stars", "is this label a rating", the front-sort
rank, and the mutual-exclusion resolution.

```swift
nonisolated enum StarRating {
    static let maxStars = 5
    static let glyph = "\u{2605}"                 // ★ BLACK STAR

    /// Canonical label for a star count. nil if out of 1...maxStars.
    static func label(for stars: Int) -> String?

    /// Star count for a label, or nil if the label is NOT a rating.
    /// A rating label is EXACTLY `glyph` repeated 1...maxStars times — a
    /// user tag like "★ favorite" or "" or "★★★★★★" (6) is NOT a rating.
    static func rating(from label: String) -> Int?

    static func isRating(_ label: String) -> Bool   // rating(from:) != nil

    /// All five canonical rating labels, ascending (["★", … , "★★★★★"]).
    static let allLabels: [String]

    /// Mutual-exclusion resolution: given the labels a file already carries and
    /// the desired new rating (nil = remove rating), return which rating labels
    /// to DELETE and which to ADD so the file ends with EXACTLY the desired
    /// rating and no other. Non-rating labels in `existingLabels` are ignored.
    static func resolution(existingLabels: [String], newRating: Int?)
        -> (remove: [String], add: [String])
}
```

Resolution rule (exactly one rating per photo):
- `desired = newRating.flatMap(label(for:))` (nil if `newRating` is nil/out of range).
- `remove` = every rating label currently present that is not `desired`.
- `add` = `[desired]` when `desired` is non-nil and not already present, else `[]`.
- `newRating == nil` → remove all present rating labels, add nothing.
- Setting the rating a photo already has → remove nothing, add nothing (idempotent).

---

## 3. Mutual exclusion (one rating per photo)

Setting a rating is **replace, not append**: any existing star tag is removed
first, then the new one added. This is enforced at the store seam so every entry
point (context menu, menu-bar, hero panel) is mutually exclusive by construction.

New store method, `Database/TagStore.swift`:

```swift
/// Set (or clear, with nil) the star rating for `urls`, scoped per file's
/// folder. Mutually exclusive: removes any existing rating tag, then adds the
/// new one as a MANUAL tag. Leaves other tags untouched. No-op for an empty set.
func setRating(_ stars: Int?, forURLs urls: [URL]) async
```

Implementation shape (mirrors the existing `TagStore` write closures + `tagScopes`
helper, `Database/TagStore.swift:18`):
- Resolve each URL to its `(file_id, parent_dir)` scope via `tagScopes`.
- Per scope, read the scope's current rating labels
  (`SELECT label FROM tags WHERE file_id=? AND parent_dir=?`, filtered through
  `StarRating.isRating`), call `StarRating.resolution(existingLabels:newRating:)`,
  then apply: `DELETE` each `remove` label for that scope, and for each `add`
  label upsert a `source = "manual"` row (promote-to-manual if a vision row of
  that label somehow exists — the same insert/promote branch `addManualTag`
  uses, `TagStore.swift:80–100`).
- After the write, call `AnalyzePipeline.shared.exportSidecarsAfterTagEdit(for:
  urls)` — every other `TagStore` mutation does this so iCloud sidecars stay
  current (`TagStore.swift:108`); a rating is a manual tag edit and must too.

`StarRating.resolution` is the tested contract; the SQL application is verified
at runtime (per the repo's "verify runtime, not just tests" rule).

---

## 4. Storage / scope / sort

- **Storage:** ordinary `tags` rows, `source = "manual"`, canonical glyph label,
  keyed `(file_id, parent_dir)`. Nothing new in the schema — no migration.
- **Scope:** per file-location, exactly like tags. A rating never leaks to a
  byte-identical copy in another folder.
- **Front-sort (owner requirement):** rating chips sort to the FRONT of the tag
  list / chip row. Implemented in the single ordering seam
  `TagChipLoader.ordered(_:sortMode:)` (`Database/TagChipLoader.swift:36`):
  partition the sorted labels into rating labels and the rest; emit rating labels
  first (ordered `★★★★★` → `★` i.e. highest star count first), then the
  non-rating labels in the caller's chosen mode order. This is the ONE place chip
  order is decided (both the fresh-select inline path and `reloadTagChips` call
  it), so the front-sort applies everywhere with one change. The `"All"` chip is
  prepended by the view (`TagChipsRow.swift:45`), so ratings land immediately
  after "All".

Verified: `TagChipLoader.ordered` is pure/static and already unit-tested
(`MuseTests/TagChipLoaderOrderTests.swift`); the front-sort is a pure addition,
testable in the same file with no DB.

---

## 5. Set / change / remove — right-click context menu

Added to the file branch of `SelectionActionsMenu` (`Views/SelectionMenu.swift`),
which every tile's `contextMenu` already hosts (`Views/GridView.swift:353`) and
which already operates on the **effective selection** (`fileURLs`, derived from
`effectiveSelectionURLs(fallback:)`, `AppState+Selection.swift:64`). So the same
menu batch-rates a multi-selection with no extra path.

A `Menu("Rating")` containing:
- Five `Button`s, one per star count, titled with the glyph label
  (`StarRating.label(for: n)`), each carrying a `.accessibilityLabel` of the
  localized `"N-star rating"` string (a bare glyph title reads poorly to
  VoiceOver).
- A **checkmark** (`Image(systemName: "checkmark")`, or a leading checkmark via
  the button label) on the star option that equals the **current** rating of the
  effective selection when it is uniform. Picking a **different** star changes
  the rating; picking the **currently-checked** star **removes** it (sets rating
  to nil). **No "Remove" verb** — re-selecting the checked rating is the removal
  gesture, per owner.
- "Current rating of the selection" is computed from the effective selection's
  ratings: uniform rating → that value is checked; mixed/none → nothing checked.

Multi-select semantics: choosing N stars sets every file in the effective
selection to N (each replaces its own existing rating, per §3). This rides the
existing selection-actions path — no bespoke batch code.

Parallel `.accessibilityAction`: the `contextMenu` is itself VoiceOver-reachable
(per the CLAUDE.md rule), and the menu-bar command (§7) is the keyboard path, so
the rating action has full non-mouse coverage.

---

## 6. On-tile badge

The one new visual. Rendered as an overlay on the grid tile.

- **Position:** TOP-RIGHT corner (`.overlay(alignment: .topTrailing)` inside the
  tile), small inset (~6 pt).
- **Content:** the filled glyph run for the rating (`★★★` for 3), drawn in
  BLACK, on a translucent WHITE rounded backing (a capsule/rounded rect, white
  ~0.85 opacity, small padding). NO yellow — high-contrast, colorblind-safe, and
  mood-independent (the white backing keeps black stars legible over any tile /
  any background mood).
- **Shown only when rated.** Unrated tiles stay clean (no clutter). Zero footprint
  for the common case.
- **Display-only, NOT clickable** (`.allowsHitTesting(false)`). Owner removed
  tap-to-remove: a badge click would conflict with tile select/open
  (`handleTileTap`, `GridView.swift:288`). Rating changes go through the context
  menu / menu-bar / hero panel only.
- **Scales/positions with the tile** — placed inside `TileView`'s image area so
  it tracks the hover-zoom / selection-inset like the rest of the tile chrome.

**Data source for the badge.** The tile currently loads no tag data. Add an
AppState-published per-file rating map, computed with a batched query modeled
exactly on `TagChipLoader` (per `(file_id, parent_dir)` scope, chunked `IN`
lists):

- New loader `Database/RatingLoader.swift` (`nonisolated enum`, like
  `TagChipLoader`): `static func ratings(paths:[String], simpleFolderDir:String?,
  queue:) -> [String: Int]` returning standardized-path → star count, counting
  only `StarRating.isRating` labels (max wins if a scope somehow has two, though
  §3 prevents it).
- `AppState`: `@Published var starRatings: [String: Int] = [:]` (standardized
  path → stars), plus a `starRatingsToken` guard. Recomputed off-main over
  `tagSourceFiles` (the same scope the chips use) by a new `reloadStarRatings()`,
  invoked from the SAME seams that refresh chips:
  (1) `reloadTagChips()` (`AppState+TagChips.swift:26`) — covers every tag edit
  (`tagsVersion` sink), collection change, and live reload; and
  (2) the fresh-select branch of `reloadCurrentFiles` (`AppState.swift:1117–1142`)
  — computed inline alongside `chipRows` and committed in the same MainActor
  transaction so badges appear with the folder.
- `TileView` reads its rating via a value passed down from `GridView`'s `ForEach`
  (`rating: appState.starRatings[path]`), like `showFileNames`/`captionHeight`,
  so the tile re-renders when its rating changes without each tile independently
  subscribing to the whole map.

Because a rating change bumps `tagsVersion` (§8) → `reloadTagChips` →
`reloadStarRatings`, badges update live after any set/change/remove.

- **Accessibility:** the tile is a single a11y element
  (`.accessibilityElement(children: .ignore)`, `GridView.swift:300`), so the
  badge is not a separate node. Surface the rating via the tile's
  `.accessibilityValue` — when rated, add the localized `"N-star rating"` string
  (using `NSLocalizedString` with the count interpolated) so VoiceOver announces
  it alongside the filename label. (A standalone badge label would be unreachable
  under `children: .ignore`.)

---

## 7. Menu-bar command (keyboard / VoiceOver)

So rating isn't mouse/right-click-only (accessibility), add a menu-bar command
over the current selection, mirroring the "New Collection from Selection…"
pattern (`MuseApp.swift:306`, in the `Collections` `CommandMenu`).

A new `CommandMenu("Rating")` in `MuseApp.swift` `.commands`:
- `Button("No Rating")` → `appState.setRating(nil, forSelectionFallback: "")`,
  shortcut `⌘0`.
- Five star buttons, `Button(StarRating.label(for: n)!)` → `setRating(n, …)`,
  shortcuts `⌘1`…`⌘5` (Apple Photos convention).
- Each `.disabled(appState.selectedFiles.isEmpty)` (a rating needs a selection),
  and each star button carries the localized `"N-star rating"` accessibility
  label.

The command targets the current multi-selection (`effectiveSelectionURLs(fallback:
"")`), identical to the menu-bar "Remove Tag from Selection" / "New Collection
from Selection…" precedent.

`AppState` gains the wrapper (new `Models/AppState+Rating.swift` extension):

```swift
/// Set/clear the star rating on the effective selection (menu-bar + context
/// menu). Files only (folders can't be tagged). Bumps tagsVersion so chips +
/// badges refresh; refreshes the rating map.
func setRating(_ stars: Int?, forSelectionFallback fallback: String) {
    let urls = effectiveSelectionURLs(fallback: fallback)
        .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory != true }
    guard !urls.isEmpty else { return }
    Task { @MainActor in
        await TagStore.shared.setRating(stars, forURLs: urls)
        tagsVersion &+= 1
    }
}

/// Current rating shared by ALL the given paths, or nil if mixed/none.
/// Backs the context-menu checkmark and the hero panel's current state.
func uniformRating(forPaths paths: [String]) -> Int?
```

---

## 8. Hero viewer — right panel, under Tags

Per owner: NO star over the hero image. The rating shows in the RIGHT info
column, UNDER the Tags card (`Viewers/Viewer/ViewerInfoColumn.swift`, between
`tagsCard` and `colorsCard`, `ViewerInfoColumn.swift:64–65`).

- A compact `ratingCard` (same `InfoCard` shell as the other cards) titled
  `"RATING"`, displaying the current rating derived from `details?.tags` via
  `StarRating` (the first tag whose label `isRating`).
- Interactive: a row of five star controls; filled up to the current rating,
  empty beyond. Tapping star N sets the rating to N; tapping the current rating
  removes it (mirrors the context-menu "pick the checked one to remove"). This
  is the natural editable parallel to the already-editable Tags/Collection cards.
  (Owner text says the rating "shows" here; making it interactive is the obvious
  affordance and low-risk — flagged as a spec decision.)
- On change: `await TagStore.shared.setRating(n, forURLs: [url])`, then
  `await refresh()` and `appState.tagsVersion &+= 1` — the hero MUST bump
  `tagsVersion` like every other hero tag mutation
  (`ViewerInfoColumn.swift:208`), else the grid's chips/badge lag until an
  unrelated edit. A toast (`show(String(localized: …))`) confirms, matching the
  tag/collection cards.
- Each star control carries a localized `"N-star rating"` accessibility label
  and is keyboard-activatable (a `Button`, so VoiceOver reaches it).

---

## 9. Filter-for-free behavior

No new filter code. Because rating tags are ordinary tags:
- They appear as chips in `TagChipsRow` whenever a visible file carries one
  (surfaced by `TagChipLoader.counts`), front-sorted (§4).
- Clicking a rating chip runs `setActiveTag("★★★")` — the existing synchronous
  `setActiveTags` path (`AppState+Filters.swift:448`), which resolves
  `activeTagPaths` as the intersection in one render turn. **This must NOT be
  disturbed** (see §11); ratings ride it unchanged.
- Cmd-clicking a rating chip ANDs it with other tags (e.g. `★★★★★` AND `beach`)
  through `toggleActiveTag` — also free.
- The active-filter banner shows the glyph pill with a ✕ to clear, like any tag.

---

## 10. Localization & accessibility

- **Glyph labels are language-neutral** — stored + displayed verbatim, no
  vocabulary row, no translation (verified §2.1).
- **The only localized string is the screen-reader label** `"N-star rating"`:
  `String(format: NSLocalizedString("%lld-star rating", comment: "VoiceOver: star
  rating of a photo"), count)`. Add the key to `Localizable.xcstrings` and fill
  the French value (e.g. `"note de %lld étoiles"`); the number is interpolated.
- Card title `"RATING"`, menu titles `"Rating"` / `"No Rating"`, and hero toasts
  (`"Rated %lld stars"` / `"Rating removed"`) are SwiftUI text-literals /
  `String(localized:)` — auto-extracted; run `-exportLocalizations` and fill
  French per the CLAUDE.md workflow.
- **Every mouse path has a non-mouse parallel:** context menu (VO-reachable) +
  menu-bar command (keyboard, ⌘0–⌘5) + interactive hero star buttons
  (keyboard/VO). The display-only badge folds into the tile's `accessibilityValue`.

---

## 11. Invariants preserved (MUST NOT break)

- **`setActiveTags` stays SYNCHRONOUS** (`AppState+Filters.swift:448`). Rating
  filtering reuses it verbatim; do not touch its resolution.
- **`tagsVersion` bump on every mutation.** Context-menu, menu-bar, and hero
  rating changes all bump `tagsVersion` (→ `reloadTagChips` → `reloadStarRatings`),
  exactly like existing tag edits (`ViewerInfoColumn.swift:208`,
  `AppState+Filters.swift:281`).
- **Per-location `(file_id, parent_dir)` scoping.** `setRating` goes through the
  same `tagScopes` seam as `deleteAllTags`/`removeLabel`; no library-wide rating
  op. A rating never touches a copy in another folder.
- **Manual-beats-vision.** Rating rows are `source = "manual"`; the promote-to-
  manual branch is reused. The tagger never emits glyph runs, so no conflict.
- **`exportSidecarsAfterTagEdit`** is called after `setRating` (iCloud sidecar
  currency), like every other `TagStore` mutation.
- **Grid stays virtualized.** The badge is an overlay inside the existing
  `TileView`; no new container over the full file set. The `starRatings` map is a
  plain dictionary lookup passed as a per-tile value.
- **Selection-narrowing prune rule** is unaffected (rating adds no filter that
  hides tiles beyond the existing tag filter, which already prunes).

---

## 12. Out of scope

- Color labels — DROPPED (owner; stars cover it, colorblind-safe).
- Out-of-five badge (`★★★☆☆`) — rejected in favor of filled-only (§2.2).
- Auto-rating, rating over the hero image, clickable badge, EXIF/XMP rating write
  — all excluded per owner.

---

## 13. File touch list

**New:**
- `Muse/Muse/Models/StarRating.swift` — pure helper (§2.3).
- `Muse/Muse/Database/RatingLoader.swift` — batched per-file rating map (§6).
- `Muse/Muse/Models/AppState+Rating.swift` — `setRating(_:forSelectionFallback:)`,
  `uniformRating(forPaths:)`, `reloadStarRatings()` (§6, §7).
- `Muse/MuseTests/StarRatingTests.swift` — helper round-trips + resolution.

**Modified:**
- `Muse/Muse/Database/TagStore.swift` — `setRating(_:forURLs:)` (§3).
- `Muse/Muse/Database/TagChipLoader.swift` — front-sort in `ordered` (§4).
- `Muse/MuseTests/TagChipLoaderOrderTests.swift` — front-sort assertion (§4).
- `Muse/Muse/Models/AppState.swift` — `@Published starRatings`, `starRatingsToken`,
  fresh-select inline rating commit (§6).
- `Muse/Muse/Models/AppState+TagChips.swift` — call `reloadStarRatings()` from
  `reloadTagChips` (§6).
- `Muse/Muse/Views/SelectionMenu.swift` — Rating submenu with checkmarks (§5).
- `Muse/Muse/Views/GridView.swift` — pass `rating:` to `TileView`, badge overlay,
  tile `accessibilityValue` (§6).
- `Muse/Muse/MuseApp.swift` — `CommandMenu("Rating")` (§7).
- `Muse/Muse/Viewers/Viewer/ViewerInfoColumn.swift` — `ratingCard` under Tags (§8).
- `Muse/Muse/Localizable.xcstrings` — `"%lld-star rating"` + card/menu/toast
  strings, French filled (§10).
