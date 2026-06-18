# Grid file names + native macOS file visuals — design

**Date:** 2026-06-17
**Status:** approved, ready for implementation plan
**Branch (work):** `feat/next-11`

## Problem

Two related gaps in how the grid presents files:

1. **Non-image files render as flat SF Symbols, not the real macOS visual.**
   The grid has two render paths (`GridView.tile`): image kinds show their
   thumbnail; everything else (zip, pdf, dmg, doc, font, archive…) shows a
   generic `Image(systemName:)` symbol + filename card and *ignores the fetched
   thumbnail entirely*. The user wants the actual Finder-style visuals — the
   native macOS **type icon** (zip/dmg/folder icon) when there's no content, and
   a real **content preview** (PDF first page, text/office doc render) when there
   is — exactly what macOS shows in the OS.

2. **No way to show file names under images.** Today only the non-image cards
   carry a name; photos never do. The user wants an optional, off-by-default
   "Show file names" mode that puts a truncated filename under every tile.

## Goals

- Non-image tiles display the genuine macOS icon / content preview.
- A Preferences toggle **"Show file names"**, default **OFF**.
- Filenames truncate to the tile width with a trailing ellipsis (`…`), matching
  the collection-PDF export style.
- Masonry alignment is preserved — captions never desync image tiles from
  non-image tiles.
- The collection-PDF export is **untouched** (always renders filenames).

## Non-goals

- Folders in the grid. Folders remain sidebar-only navigation; they never become
  grid tiles. (Confirmed with the user.)
- Editing/renaming files from the grid.
- Per-folder name settings. The toggle is global.
- Changing the collection-PDF export behavior in any way.

## Behavior matrix

| Tile type | "Show file names" **OFF** (default) | "Show file names" **ON** |
|---|---|---|
| **Photo** (jpg/png/heic/raw/psd/svg) | image only, no text *(unchanged)* | image in the top area + filename caption **below**; masonry reserves the strip |
| **Non-image card** (zip/pdf/dmg/doc/font/archive/code/text/md/office/video/audio/3d/unknown) | grey rounded card · QuickLook icon/preview centered above a reserved bottom strip · filename in that strip, single line, tail-ellipsis, width = tile width | grey card with centered icon (no internal text) + filename caption **below** *(name moved out of the card to match photos)* |
| **Collection PDF export** | filenames always *(untouched)* | filenames always *(untouched)* |

## Supply side — already implemented

`ThumbnailCache.generate()` now requests `representationTypes: .all` (was
`.thumbnail`) from `QLThumbnailGenerator` for the non-image path. QuickLook's
`generateBestRepresentation` returns its best available: a real content
thumbnail when one exists, otherwise the native macOS **type icon** — instead of
returning nil and leaving a grey tile. Files that already rendered a content
thumbnail are unchanged (content is still preferred over the icon). This change
is on the supply side only; the grid must be updated to *display* the result for
non-image kinds. Build verified green.

## Components

### 1. Setting

- **`Settings/AppSettings.swift`** — add:
  - `static let showFileNamesKey = "showFileNames"`
  - `static var showFileNames: Bool` accessor, default **false**
    (`UserDefaults … as? Bool ?? false`).
- **`Settings/SettingsView.swift`** — add a section (title e.g. *"Grid"*) with
  `Toggle("Show file names", isOn: $showFileNames)` bound via
  `@AppStorage(AppSettings.showFileNamesKey)` (default `false`) + a one-line
  footer ("Show each file's name beneath its thumbnail in the grid.").

### 2. Layout — `Components/MasonryGeometry.swift`

Add one parameter to `compute`:

```swift
static func compute(aspects: [CGFloat],
                    columns: Int,
                    width: CGFloat,
                    spacing: CGFloat,
                    captionHeight: CGFloat = 0) -> Result
```

When `captionHeight > 0`, each tile's frame height is
`columnWidth * aspect + captionHeight` (the caption strip is reserved per tile
and packed into the masonry). `totalHeight` accounts for it naturally because it
derives from the column heights. The default `0` preserves today's behavior
byte-for-byte.

This mirrors the proven `Export/CollectionPDFLayout.swift` `captionHeight`
pattern. Frames remain the single source of truth, so GridView's virtualization
(viewport windowing over the precomputed frames) is unaffected.

**Rejected alternatives:**
- *Bake the caption into each aspect ratio* — wrong: the caption is a fixed
  pixel height, not proportional; inflating the aspect would distort packing and
  make the caption strip grow/shrink with column width.
- *Separate overlay pass for captions* — breaks the single frames-array that
  drives windowing; two sources of truth for tile position.

### 3. Grid — `Views/GridView.swift`

- Read `@AppStorage(AppSettings.showFileNamesKey) private var showFileNames = false`.
- Define a constant caption strip height, **fixed ~18pt** (one line of
  `.caption`), independent of column count — matching the PDF export's fixed
  caption height. Tunable later.
- `recompute(width:)` passes `captionHeight: showFileNames ? captionStrip : 0`
  to `MasonryGeometry.compute`.
- Add `.onChange(of: showFileNames)` → `recompute` inside a short `withAnimation`
  so toggling re-packs the grid live.
- Pass `showFileNames` and the resolved `captionHeight` into each `TileView`.

### 4. Tile — `Views/GridView.swift` (`TileView`)

The tile splits into an **image area** (top, `frame.height − captionHeight`) and
an optional **caption strip** (bottom, `captionHeight`).

- **Image kinds:** image fills the image area exactly as today (square corners,
  fade-in over the shimmer placeholder). OFF → no caption. ON → caption below.
- **Non-image kinds:** a grey rounded card (`moodPalette.tileFill`, corner
  radius 8). The fetched QuickLook image (the macOS icon or content preview) is
  shown `scaledToFit` and centered. The non-image path currently discards
  `thumbnail`; it must now render `Image(nsImage: thumbnail)` (falling back to
  the existing SF Symbol only while the thumbnail is still loading / if it
  genuinely fails). `scaledToFit` keeps a small type-icon small and centered and
  scales a tall doc preview down — neither overlaps the text.
  - OFF → filename sits in a reserved bottom strip *inside* the card, single
    line, `.truncationMode(.tail)`, framed to the card width.
  - ON → no internal filename; the centered icon uses the full card and the
    filename is the caption strip below.
- **Caption strip** (ON, both kinds): `Text(file.basename)`, `.caption`,
  `.foregroundStyle(.secondary)`, `.lineLimit(1)`, `.truncationMode(.tail)`,
  `.frame(width: tileWidth)` — same trailing-ellipsis treatment as the PDF
  export caption.
- **Selection / hover:** the accent wash + border wraps the **image area only**
  (Finder-style; the label below is unbordered). The hover `scaleEffect(1.025)`
  still scales the whole tile (image + caption together).

`AspectRatioCache` needs **no change**: non-image cards keep their fixed
`1/1.4` aspect for the image-card portion, and the caption is added uniformly by
`MasonryGeometry.captionHeight`, not via the aspect.

### 5. Untouched

`Export/CollectionPDFLayout.swift` and `Export/CollectionPDFExporter.swift` —
the PDF always renders filenames, regardless of the setting.

## Testing

- **`MasonryGeometryTests`** (new or extended), mirroring the existing
  `CollectionPDFLayout` caption tests:
  - `captionHeight` is reserved per tile (each frame height =
    `columnWidth*aspect + captionHeight`).
  - `totalHeight` includes the caption reservation.
  - Frames don't overlap when `captionHeight > 0`.
  - `captionHeight: 0` produces frames identical to the pre-change geometry
    (regression guard).
- UI rendering (TileView, SettingsView) is not unit-tested, per the project's
  existing convention; verified by build + live run.

## Risks / notes

- The QuickLook image for cards is fetched at 320×320; `.all` may return an icon
  representation that's smaller — `scaledToFit` handles upscaling gracefully but
  type icons are vector-backed multi-res, so they stay crisp.
- On-disk thumbnail cache: a non-image file that previously cached a nil/blank
  may need its cache entry regenerated to show the new icon. Newly-seen files
  show it immediately; this is a one-time staleness, not a logic issue.
- Fixed caption height on very small tiles (8 columns) is proportionally large
  but acceptable and matches the PDF export's fixed-height approach.
