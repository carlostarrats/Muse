# Grid layout modes — design

**Date:** 2026-07-28
**Status:** approved, not yet implemented
**Supersedes:** the `muse-grid-mode-proposal` memory (2026-07-27)

## Problem

Two complaints, one root cause.

1. **The ratio picker is overcomplicated.** Muse asks the user to choose one of
   10 fixed aspect ratios (`1:1`, `9:16`, `4:5`, `6:7`, …) just to view their
   images. No comparable app does this — Cosmos, Atlas, Savee, Eagle,
   Gatheros and Mattoboard all present images without a ratio picker. The middle
   eight ratios are also visually indistinguishable: at 4 columns / ~290pt tiles,
   `6:7` / `4:5` / `3:4` render 338 / 362 / 387pt tall, ~7% steps no user has a
   preference between.

2. **The tile backdrop reads as a forced frame.** Every tile draws
   `Rectangle().fill(appState.tileFill)` at the full cell frame with the image
   `.fit` inside (`Views/GridView.swift:952-967`). The image already fits its
   natural shape and already scales as large as it can — the visible opaque slab
   around it is what makes a fixed ratio look imposed. The hover veil is drawn at
   the *tile* rect too, so hovering darkens the slab along with the photo.

The ratio picks a *card* shape, not an image shape. Delete the card and the
ratios lose most of their reason to exist.

## What we're building

Three layout modes, no card behind photos, a spacing slider, and one consistency
fix that this work makes visible.

### 1. Three layout modes

`ImageLayout` becomes three cases. The 10 ratio cases are deleted.

| Case | Name | Behaviour |
|---|---|---|
| `.columns` | Columns | Vertical columns; each image at its natural shape; ragged bottom. This is today's `.masonry`, renamed. |
| `.rows` | Rows | Every row the same height; widths natural; each row stretched to exactly fill the content width. Atlas / Flickr / Google Photos. |
| `.grid` | Grid | One square slot per image; the image drawn as large as its own shape allows inside it. Rows **and** columns align. |

Names are the user-facing labels; raw values are the persisted strings.

**Migration.** `ImageLayout.resolve` currently defaults any unknown raw to
masonry, which would silently snap a user persisted on `r6x7` to Columns. Map
instead:

- `"masonry"` → `.columns`
- any `r*` raw → `.grid`
- unknown / missing → `.columns` (unchanged default)

### 2. No card behind photos, in any mode

Image tiles (`.image` / `.raw` / `.psd` / `.svg`) stop drawing a fill. The photo
draws at its own shape; leftover slot space shows the page background.

- **Loading placeholder.** The shimmer currently fills the whole slot. It must
  draw at the photo's *fitted* rect instead (the aspect is already known from
  `AspectRatioCache` before the thumbnail lands), so nothing resizes when the
  image arrives.
- **Transparent images.** A PNG with an alpha channel is drawn fully
  transparent — the page background shows through. No auto-backdrop, no setting.
  A dark logo on a dark mood will be hard to see; that is also true in Finder and
  Preview, and the mood is the user's choice.
- **Non-photo tiles keep their card.** PDF / zip / video / folder tiles are
  icons, not images, and need something to sit on. Their card is always the
  mood's tile colour — what `TileBackground.auto` does today, and what masonry
  already forced via `effectiveTileBackground`.

### 3. Tile Background is deleted

`TileBackground` (None / Auto / Light / Dark Grey / Black) exists to colour the
letterbox around photos. With no letterbox it has nothing to do.

Removed:

- `Models/TileBackground.swift` and `MuseTests/TileBackgroundTests.swift`
- `AppState.tileBackground`, `AppState.effectiveTileBackground`
- `AppSettings.tileBackground` / `tileBackgroundKey`
- The `TILE BACKGROUND` section of `Views/MoodPickerView.swift` (lines ~74-95),
  its `tileGroup` helper, the `TileSwatch` view, and the "Masonry always uses
  Auto" footnote

Rewired:

- `AppState.tileFill` becomes `moodPalette.tileFill` and is read **only** by the
  non-photo card branch (`GridView.swift:986`)
- `GridView.cardNameColor` reads the mood tile colour directly
- `Views/CollectionPDFSave.swift:39` passes the mood tile colour instead of
  `effectiveTileBackground`

The persisted `tileBackground` UserDefaults key is left on disk (harmless) rather
than migrated away.

### 4. Ring, hover and star badge hug the photo

One rule for all three modes: the selection ring, the hover veil and the
star-rating badge attach to the **drawn photo rect**, never to the slot.

- In Columns and Rows the slot aspect equals the image aspect by construction, so
  the drawn rect *is* the slot and nothing changes.
- In Grid the two differ whenever the photo isn't square. This is the only mode
  where the rule has visible effect.
- The **hit target stays the full slot** — clicking anywhere in a slot selects or
  opens, so targets don't shrink.

**Load-bearing detail.** The hero open/close flight already computes the drawn
rect via `ViewerGeometry.fitWithin` (see the durable constraint in `CLAUDE.md`
dated 2026-07-07). The grid's ring rect **must be computed by the same function
from the same aspect source**, or in Grid mode the photo will visibly jump at the
moment the flight starts or lands. This is the single highest-risk part of the
change and must be verified in the running app, not by reading code (see
`docs/hero-viewer-open-close-handoff.md`).

### 5. Rows geometry — a new pure unit

Columns and Grid both fall out of the existing engine:

- Columns → `MasonryGeometry.compute` with per-file aspects (today's behaviour)
- Grid → `MasonryGeometry.compute` with every aspect `1`. Equal aspects already
  pack into an exact aligned row-major grid — `MuseTests/UniformGridLayoutTests`
  locks that invariant and was written for exactly this reuse

Rows needs a new pure unit, `JustifiedRowsGeometry`, in `Components/` alongside
`MasonryGeometry` (same shape: stateless, `[CGRect]` + `totalHeight`, unit-tested
with no SwiftUI).

Algorithm:

1. Fill a row greedily. At a common height `H`, an item's width is `H / aspect`
   (aspect = height ÷ width).
2. Close the row when its natural height at full width drops to or below the
   target height. Row height that exactly fills the width is
   `(width - spacing × (n - 1)) / Σ(1 / aspectᵢ)`.
3. Scale the row to that height so it fills the content width exactly.
4. **The last row is not stretched.** Leave it at the target height, left
   aligned — otherwise a single trailing image becomes a full-width panorama.
5. **Clamp each aspect to `[0.1, 10]` for layout purposes only.** A pathological
   panorama would otherwise force a 1pt-tall row. The clamp affects packing only,
   never how the image is drawn.

The target row height is derived from the existing images-per-row slider:
`(width - spacing × (cols - 1)) / cols` — the column width that slider already
produces. So the slider keeps meaning "bigger or smaller images" in all three
modes and no second control is needed.

Reflow note: `AspectRatioCache.aspect` returns `1.0` as a placeholder until the
real ratio resolves, so a cold folder reflows once as ratios land. That is
already true for Columns; Rows inherits it.

### 6. Spacing slider

`private let spacing: CGFloat = 14` (`GridView.swift:22`) is hardcoded and
already flows into the geometry. Promote it to a persisted setting driven by a
slider next to the existing images-per-row slider (`GridView.swift:626-630`).

- Range 0–28pt, step 1, default 14 (today's value)
- Persisted via `AppSettings`, same shape as `gridColumns`
- Feeds `MasonryGeometry.compute` and `JustifiedRowsGeometry` alike

Tight spacing is what makes Grid and Rows read as a dense contact sheet.

### 7. Consistent image orientation

Muse resolves an image's shape from three places, and they disagree about
EXIF-rotated photos:

| Source | Honors EXIF orientation? |
|---|---|
| `AspectRatioCache.imageIOAspect` (`AspectRatioCache.swift:186-196`) | **Yes** — swaps w/h for orientations 5–8 |
| `ImageHeaderSizeCache.resolve` (`ImageHeaderSizeCache.swift:64-73`) | **No** — raw `kCGImagePropertyPixelWidth/Height` |
| `files.width/height` via `VisionServices.analyze:47` | **No** — reads `ImageHeaderSizeCache` |

Consequences today: an *analyzed* rotated photo packs at the wrong shape (DB
dimensions path) while an *unanalyzed* one packs correctly (ImageIO fallback) —
two files side by side in one folder, laid out differently. The hero flight reads
the non-honoring path, so a rotated photo already takes off from a slightly wrong
rect. Both self-correct once the thumbnail decodes and `report(aspect:)` fires,
so the window is short and it currently shows only as transient extra grey.

Deleting the card removes the grey that hides it, and in Rows a wrong aspect
breaks row alignment outright — so fix it here:

- `ImageHeaderSizeCache` stores the **display** size (rotation applied).
  `resolve` applies the orientation swap; `record` callers pass display
  dimensions (`ThumbnailCache.swift:324`).
- `files.width/height` therefore become display dimensions. The Info card will
  report a rotated photo as e.g. 3000×4000 rather than 4000×3000 — matching what
  Preview reports. Existing analyzed rows keep their old values until
  re-analyzed; this is accepted, not migrated.
- One shared helper does the orientation swap so the three call sites cannot
  drift apart again.

### 8. PDF export follows

`Views/CollectionPDFSave.swift` and the exporter reflect the grid, so they must
follow the same rules: no slab behind photos, the three modes' geometry, the
chosen spacing, and the mood-coloured card for non-photo tiles.

## Out of scope

- Corner radius on tiles (Atlas has a slider; Muse draws square corners and stays
  that way)
- A "Canvas" / freeform mode (Atlas has one; unrelated to this complaint)
- Any change to the hero viewer beyond keeping its flight geometry correct

## Testing

Pure units, unit-tested (no SwiftUI):

- `JustifiedRowsGeometryTests` — rows fill the width exactly; every item in a row
  shares one height; the last row is not stretched; extreme aspects are clamped;
  zero spacing; single item; empty input
- `ImageLayoutTests` — extended for the three cases and the `r*` → `.grid`
  migration, including that `"masonry"` maps to `.columns`
- `UniformGridLayoutTests` — already covers Grid's packing via equal aspects
- Orientation: a shared-helper test asserting orientations 5–8 swap and 1–4 don't

Runtime verification required (per `verify-runtime-not-just-tests`):

- Grid mode: hero open **and** close on a wide photo, a tall photo, and an
  EXIF-rotated photo — the image must not jump at flight start or landing
- Rows mode: a folder mixing analyzed and unanalyzed rotated photos must lay out
  in straight rows
- Spacing at 0 and at 28 in all three modes
- A transparent PNG on a light mood and on a dark mood
- A folder of PDFs/zips/videos — cards still legible, filename still readable

## Localization

- Delete: the 10 ratio `displayName` strings and the six "Common Sizes"
  description strings in `ImageLayoutSheet`
- Delete: the five `TileBackground` display names, "TILE BACKGROUND",
  "Automatic", "Static", and the "Masonry always uses Auto…" footnote
- Add: "Columns", "Rows", "Grid", the spacing slider's accessibility label, and
  any revised `ImageLayoutSheet` subtitle
- Run `xcodebuild -exportLocalizations` and fill the French values; a plain build
  does not write keys back into `Localizable.xcstrings`

## Files touched

| File | Change |
|---|---|
| `Models/ImageLayout.swift` | Three cases, migration in `resolve`, icon kinds |
| `Models/TileBackground.swift` | Deleted |
| `Models/AppState.swift` | Drop `tileBackground` / `effectiveTileBackground`; `tileFill` → mood |
| `Settings/AppSettings.swift` | Drop tile-background keys; add grid spacing |
| `Components/JustifiedRowsGeometry.swift` | **New** — Rows packing |
| `Components/ImageHeaderSizeCache.swift` | Store display size |
| `Views/GridView.swift` | Mode branch, no photo fill, fitted shimmer, ring/hover/badge on the drawn rect, spacing slider |
| `Views/ImageLayoutSheet.swift` | Three tiles; delete the Common Sizes table |
| `Views/MoodPickerView.swift` | Delete the tile-background section |
| `Views/CollectionPDFSave.swift` | Mood card; follow the three modes |
| `Intelligence/Vision/VisionServices.swift` | Display dimensions |
| `Filesystem/ThumbnailCache.swift` | Record display dimensions |
| `Localizable.xcstrings` | Per the localization section |

## Decisions on record

Asked and answered during design, so a later session doesn't relitigate them:

- **Card behind photos:** gone everywhere, in every mode — not just in a new Grid
  mode, and not a hover-only fix
- **Tile Background setting:** deleted outright, not retitled to "File Card
  Colour"
- **Ratios:** replaced, not kept alongside
- **Modes:** three (Columns / Rows / Grid), after Atlas screenshots showed the
  Rows layout is a distinct thing worth having, not just a spacing demo
- **Ring and hover:** hug the photo, not the slot
- **Transparent images:** fully transparent; no auto-backdrop, no toggle
- **Rotation:** fixed as part of this work, not deferred
