# Share a collection as a PDF — design

**Date:** 2026-06-16
**Status:** Design (pending implementation plan)

## Goal

When viewing a collection, let the user share it as a **multi-page PDF**
contact sheet. A new share button sits in the in-collection header, left
of the trash button, and presents the standard macOS share sheet — the
same surface used to share a single image. The shared item is a generated
PDF of the collection's images, paginated onto fixed 11×14in pages with a
title block on the first page.

This is purely additive. It does not change the in-app collection view,
the existing image `ShareButton`, or any data.

## User-facing behavior

1. Inside a collection, the header shows: back arrow · name · count ·
   Edit · (spacer) · **Share** · Trash. Share is the only new control,
   placed immediately to the left of Trash.
2. Tapping Share opens a small **menu** with two plain items — no system
   UI is customized, we only compose standard pieces:
   - **Save to…** — opens the standard macOS save dialog (`NSSavePanel`),
     defaulted to the Desktop with the filename pre-filled
     (`<Collection Name>.pdf`). Confirming writes the PDF there; the panel
     grants sandbox access to the chosen location, so this needs **no new
     entitlement** (the app already has `files.user-selected.read-write`).
     The user can redirect to any folder.
   - **Share** — opens the normal, unmodified macOS share sheet
     (`NSSharingServicePicker`: AirDrop, Mail, Messages, Notes, …)
     anchored to the window. The OS owns the transfer — no network surface.
3. The PDF is built **only after the user picks an item** (not on opening
   the menu). During the build the menu/button shows a brief "preparing"
   state (a small spinner replacing the icon) and is non-interactive, so a
   large collection never feels frozen. Then the panel or share sheet
   appears.
4. Share is disabled when the collection has zero alive members.

## What the PDF contains

- The collection's **currently displayed members**: `AppState.activeCollectionFiles`
  — the exact set and order shown in the grid (WYSIWYG; respects the
  active sort).
- **No app chrome**: no tags, no back/edit/trash, no app/mood background.
  A clean white document with black text.
- **Whole images, never cropped** — each image appears in full.

## Page layout

**Page size:** 11×14in portrait = **792×1008pt** (72pt/in). Fixed; the
document is paginated, never one tall page.

**Margins / grid:**
- 0.5in (36pt) margins on all sides → content box 720×936pt.
- **Columns = the user's current grid density** — the same
  `@AppStorage("gridColumnCount")` value driven by the in-grid column
  slider (range 2–8, default 4). The PDF mirrors how the user has the
  collection laid out when they hit Share, so a sparse grid → big tiles /
  more pages, a dense grid → small tiles / fewer pages.
- 12pt gutters; tile width = `(720 − gutters) / columns` (e.g. 4 columns →
  ≈ 171pt tiles, 2 columns → ≈ 354pt).

**Masonry packing (per page):**
- Each tile's height = `columnWidth × (imageHeight / imageWidth)`, so the
  tile is the image's own shape — the whole image fills it with no crop
  and no letterbox.
- Greedy shortest-column placement (same feel as the in-app grid), one
  image at a time in display order.
- **Page break:** if placing the next tile would cross the page's bottom
  margin, the page is finished and a new page begins with all column
  offsets reset to the top. **No image is ever split across a page** —
  this is what guarantees finite, clean pages.
- A single image taller than the content box is scaled down to fit within
  one page.

**Header (first page only):**
- Collection name at **24pt semibold**, top-left within the content box.
- The image count immediately follows the name with a small gap, in gray
  (e.g. `Saved Inspo  42`) — adjacent to the name, not right-aligned to
  the page edge. Matches how the in-app header reads today.
- Page 1's image area starts below this header block. Pages 2+ have no
  header (more images per page).

**Background:** white page, black/gray text — independent of the app's
current mood. It's a shareable document, so it stays neutral.

## Implementation shape

New files, mirroring existing patterns (`MasonryGeometry`, `ShareButton`):

- **`CollectionPDFLayout`** (pure, in `Components/` or `Intelligence/Export/`)
  - Input: ordered list of image pixel sizes + page geometry (page size,
    margins, columns, gutter, first-page header height).
  - Output: `[Page]`, where each `Page` is `[(index, rect)]` in PDF
    coordinates.
  - Pure and deterministic → unit-testable with no I/O. Reuses the
    shortest-column idea from `MasonryGeometry` but adds page breaks.

- **`CollectionPDFExporter`**
  - Loads member images via ImageIO, **downsampled for print** (max pixel
    dimension sized to the tile, ~2× tile points; keeps the PDF lean and
    crisp), **off the main thread**.
  - Reads each image's pixel dimensions (from `AspectRatioCache` / DB
    `width`·`height` with an ImageIO header fallback) to feed the layout.
  - Takes the column count as a parameter; the caller passes the current
    `gridColumnCount` (read from `@AppStorage`) so the export matches the
    grid the user is viewing.
  - Runs `CollectionPDFLayout`, then draws each page into a `CGPDFContext`
    (white fill, page-1 header text, images into their rects), writes to a
    temp file (`<Collection Name>.pdf` in `NSTemporaryDirectory()`), and
    returns the URL.

- **`ShareCollectionButton`** (header control)
  - A `Menu` styled like `TrashButton` (40pt circle, `square.and.arrow.up`,
    secondary→primary hover) with two items: **Save to…** and **Share**.
  - **Save to…**: enter `preparing` → await `CollectionPDFExporter` → run
    an `NSSavePanel` (`directoryURL` = Desktop, `nameFieldStringValue` =
    `<Collection Name>.pdf`, allowed type PDF) → on confirm, write the PDF
    to the chosen URL. Restore the icon when done/cancelled.
  - **Share**: enter `preparing` → await `CollectionPDFExporter` → present
    `NSSharingServicePicker` with the temp URL (standard, unmodified).
  - Wired into `ActiveCollectionHeader`'s `HStack`, before `TrashButton`.

## Testing

- `CollectionPDFLayoutTests`: every image placed exactly once; no tile
  exceeds the content box; no tile crosses a page boundary; an
  oversized-aspect image is scaled to fit one page; image count → page
  count behaves (e.g. N images at a known geometry produce the expected
  page count).

## Decisions made (defaults, easily tuned)

- **Columns mirror the grid** — the PDF uses the user's current
  `gridColumnCount` (2–8) so the exported density matches what they're
  viewing, no separate setting.
- **White background / black text** regardless of mood (shareable doc).
- **Source = `activeCollectionFiles`** (displayed order) so the PDF
  matches what the user sees.

## Out of scope

- No print dialog / page-setup UI (saving the PDF + Preview cover
  printing).
- No customizing of the macOS share sheet — the menu's **Share** item
  presents it unmodified.
- No per-image captions, tags, or metadata on the page.
- No change to the single-image `ShareButton` or the collection grid.
- No new entitlement (the OS share sheet owns the transfer).
