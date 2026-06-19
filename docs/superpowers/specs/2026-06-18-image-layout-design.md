# Image Layout — Design Spec

**Date:** 2026-06-18
**Status:** Approved, ready for implementation planning

## Summary

Add a global setting that changes how images are laid out on every grid in Muse — across all-tags, specific tags, and inside a chosen collection. Today the grid is always masonry. This feature keeps masonry as the default and adds 11 fixed aspect-ratio layouts. The setting is chosen from a new modal opened by a toolbar button placed between the Collections and Mood (color) buttons. Layout changes apply instantly and globally.

Fixed-ratio layouts never crop: each image is fit (letterboxed) inside a uniform tile of the chosen aspect, with the existing light-grey placeholder color filling any extra space. All other grid behavior (selection, hover, captions, delete, virtualization) is preserved unchanged in every layout.

## Goals

- A single global image-layout preference, persisted across launches.
- Masonry remains the default and is behaviorally unchanged.
- 11 fixed aspect-ratio layouts that fit images without cropping, grey-filling letterbox gaps.
- A modal matching the existing info modal's styling for selecting the layout.
- Instant, animated layout change visible behind the modal.

## Non-Goals

- No per-folder / per-tag / per-collection override — the setting is strictly global.
- No cropping or fill-to-frame mode.
- No new color theming in the grid; fixed-ratio tiles reuse the existing mood palette.
- No paid/metered behavior.

## Data Model & Persistence

New `enum ImageLayout: String, CaseIterable, Identifiable` (in `Models/`), 12 cases:

- `.masonry` (default)
- Ratios: `r1x1`, `r9x16`, `r16x9`, `r4x5`, `r5x4`, `r6x7`, `r7x6`, `r2x3`, `r3x2`, `r3x4`, `r4x3`

Each case exposes:

- `displayName: String` — `"Mason"`, `"1:1"`, `"9:16"`, … (used as the tile label).
- `aspect: CGFloat?` — tile height ÷ width for fixed-ratio cases; `nil` for `.masonry`.
  - Ratio strings are **width:height**. So `9:16` → tall tile (`aspect = 16/9`), `16:9` → wide tile (`aspect = 9/16`).
- `iconKind: LayoutIconKind` — which of the 4 generic preview graphics to draw.

`enum LayoutIconKind { case mason, square, portrait, landscape }`. Mapping:

- `.masonry` → `.mason`
- `r1x1` → `.square`
- Portrait (width < height): `r9x16`, `r4x5`, `r6x7`, `r2x3`, `r3x4` → `.portrait`
- Landscape (width > height): `r16x9`, `r5x4`, `r7x6`, `r3x2`, `r4x3` → `.landscape`

**Tile display order** (matches the wireframe, 4 columns):

```
Mason  1:1   9:16  16:9
4:5    5:4   6:7   7:6
2:3    3:2   3:4   4:3
```

**Persistence:** stored in `AppSettings` (UserDefaults) following the existing `folderSortMode` / `tagSortMode` pattern, and mirrored as a `@Published var imageLayout: ImageLayout` on `AppState` (with `didSet` writing back to `AppSettings`) so the grid reacts instantly — same shape as the existing `mood` property. Default resolves to `.masonry` when unset or unparseable.

## Grid Rendering

`GridView` branches on `appState.imageLayout`:

- **Masonry** → existing `MasonryGeometry.compute()`. Untouched. This is the default and its behavior must not change.
- **Fixed ratio** → a new `UniformGridGeometry` that produces the same `frames: [CGRect]` + `totalHeight` output that masonry does, so virtualization, viewport visible-index scanning, and scrolling are identical. Every tile is a fixed box: `tileHeight = columnWidth * layout.aspect + captionHeight`, using the **existing grid column-count slider** (`@AppStorage("gridColumnCount")`) for the number of columns. Tiles are laid out row-major (uniform rows, no shortest-column packing).

Inside a fixed-ratio tile:

- The image is rendered `.aspectRatio(contentMode: .fit)`, centered — never cropped.
- Letterbox gaps are filled with `appState.moodPalette.tileFill` (the same grey used for zip / non-image placeholders).
- All existing `TileView` behavior is preserved: hover veil, 10pt selection inset, 2.5pt ring at 8pt continuous corners, selection tint, optional filename caption, tap-to-select, delete, shimmer-while-loading. The selection inset/ring apply to the fixed tile box (consistent with masonry), with the grey fill and centered image inside.

Switching layout (or changing the aspect via the modal) triggers a geometry recompute through the **same animated `onChange` path already used for column-count changes**, so the grid visibly re-lays-out instantly behind the open modal.

## The Modal — `ImageLayoutSheet`

Presented as a `.sheet` (matching the existing info modal presentation), styled to match `InfoSheet.swift`:

- **Title:** "Image Layout" — `.font(.system(size: 24, weight: .semibold))`.
- **Subtitle:** "Select an image layout. Applies globally" — secondary text.
- **Close button:** the identical circular, hover-sensitive X used in `InfoSheet` (`.secondary` → `.primary` on hover, `Circle().fill(.primary.opacity(hovering ? 0.16 : 0.08))`).

**Layout tiles:** a 4-column grid of the 12 `ImageLayout` cases in the order above. Each tile shows its `displayName` label and one of the 4 generic `LayoutIconKind` graphics (all drawn at the same overall dimensions — quick visual context, not exact previews).

Tile selection mirrors a grid tile but is **blue-only** (the modal's only color change):

- **Selected:** blue tint background, blue ring (8pt continuous corners), blue label text, icon shrinks with the same inset.
- **Unselected:** `moodPalette.tileFill` grey box, default label color; hover veil on hover.

Tapping a tile sets `appState.imageLayout` immediately. The modal stays open; the grid updates live behind it.

**Common Sizes section** (below the tiles): a `"Common Sizes:"` heading (`.font(.system(size: 15, weight: .semibold))`) followed by rows in InfoSheet's body style (`.font(.system(size: 13))`, secondary, hairline dividers between rows):

| Ratio | Note |
|-------|------|
| 1:1 | Square medium format, iPhone |
| 2:3 | Sony, Canon, Nikon, 35mm film |
| 3:4 | iPhone, Google Pixel, Samsung Galaxy, OnePlus |
| 4:5 | Instagram, Large format film |
| 6:7 | Medium format |
| 9:16 | Video on most phones with camera support also |

## Toolbar Button

A new `ToolbarItem(placement: .primaryAction)` inserted in `ContentView.swift` **between** the Collections button (`square.stack.3d.up`) and the Mood button (`paintpalette`):

- Icon: a grid SF Symbol — `square.grid.2x2`.
- `.help("Image Layout")`.
- Opens the sheet via a new `@State private var imageLayoutSheetShown = false`.
- `.disabled(appState.isSearchActive)` — matching the Collections button.

## Testing / Verification

- Default on first launch is masonry; masonry visuals/behavior unchanged.
- Selecting each fixed ratio re-lays the grid with uniform tiles of that aspect; portrait ratios are tall, landscape ratios wide, 1:1 square.
- No image is ever cropped; letterbox gaps use `tileFill` grey.
- Selection ring, hover, captions, delete, and virtualization all work in a fixed-ratio layout (verify scroll stays smooth on a large folder).
- The chosen layout persists across relaunch and applies in all-tags, a specific tag, and inside a collection.
- Modal matches info-modal fonts/sizes and X button; selected tile shows blue tint/ring/text; grid updates live behind the open modal.
- Column-count slider still changes columns in fixed-ratio layouts.

## Files Touched (anticipated)

- New: `Models/ImageLayout.swift` (enum + icon kind).
- New: `Components/UniformGridGeometry.swift` (fixed-ratio frame computation).
- New: `Views/ImageLayoutSheet.swift` (the modal + preview tiles).
- `Settings/AppSettings.swift` — persisted accessor.
- `Models/AppState.swift` — `@Published var imageLayout`.
- `Views/GridView.swift` — geometry branch + fixed-ratio tile fit/fill; recompute on layout change.
- `ContentView.swift` — toolbar button + sheet presentation.
