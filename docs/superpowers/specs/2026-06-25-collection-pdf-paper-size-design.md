# Collection PDF — paper-size picker in "Save to…"

**Date:** 2026-06-25
**Status:** approved, ready for implementation
**Branch:** `feat/next-56`

## Problem

Saving a collection as a PDF always produces an 11 × 14 in page (a photo-print
size hardcoded in `CollectionPDFExporter`). Users want to choose a standard
paper size at save time — Letter, Legal, Tabloid, A3, A4 — the same way a
save dialog lets you pick a file format.

## Decisions (locked)

- **Where:** a "Paper Size:" dropdown in the `NSSavePanel` accessory band, only
  on the **Save to…** path.
- **Sizes (portrait only):** 11 × 14 (default), Letter, Legal, Tabloid, A4, A3.
- **Default:** always 11 × 14 — no persistence; the dropdown opens on 11 × 14
  every export (preserves today's behavior for anyone who ignores it).
- **Share path:** unchanged — the system Share sheet keeps producing an
  11 × 14 PDF (no save dialog to host the dropdown, and size matters most when
  saving a file to print).
- **Orientation:** portrait only. Landscape can be added later if wanted.

## Sizes (points @ 72 dpi, portrait)

| Name    | Points     | Physical     |
|---------|------------|--------------|
| 11 × 14 | 792 × 1008 | 11 × 14 in   |
| Letter  | 612 × 792  | 8.5 × 11 in  |
| Legal   | 612 × 1008 | 8.5 × 14 in  |
| Tabloid | 792 × 1224 | 11 × 17 in   |
| A4      | 595 × 842  | 210 × 297 mm |
| A3      | 842 × 1191 | 297 × 420 mm |

## Architecture

The exporter is already size-parametric: margin (36 pt), gutter (12 pt),
captions, the masonry/ratio pagination, tag pills, per-image backdrop, and the
white paper all derive from `pageSize`. The only reason output is fixed at
11 × 14 is the single hardcoded constant. So the change is small and contained.

### 1. `Export/PaperSize.swift` (new)

A pure value type — unit-testable, no AppKit.

```swift
enum PaperSize: String, CaseIterable {
    case elevenByFourteen, letter, legal, tabloid, a4, a3

    /// Portrait page size in points (72 dpi).
    var size: CGSize { … }      // table above

    /// Localized label for the popup.
    var displayName: String { … }   // String(localized:) per case
}
```

- `size` returns the portrait `CGSize` from the table.
- `displayName` is `String(localized:)`-wrapped (AppKit popup titles are not
  auto-extracted). "11 × 14 in" carries its unit to distinguish it from a ratio;
  the rest are bare names (Letter, Legal, Tabloid, A4, A3).
- The default is `PaperSize.elevenByFourteen` (also the popup's initial
  selection and `share()`'s fixed size).

### 2. `Export/CollectionPDFExporter.swift` (edit)

- Add a `pageSize: CGSize` parameter to `makePDF(urls:title:count:columns:…)`.
- Replace line 51 `let pageSize = CGSize(width: 792, height: 1008)` with the
  passed-in value. No other change — everything downstream already reads
  `pageSize`.

### 3. `Views/ShareCollectionButton.swift` (edit)

- `makePDF()` helper gains a `pageSize: CGSize` argument and forwards it.
- `share()` passes `PaperSize.elevenByFourteen.size` (unchanged output).
- `save()` is **reordered** so the size choice can take effect:
  1. Build the accessory view: an `NSView` containing a "Paper Size:" label
     (`NSTextField`) + `NSPopUpButton` populated from `PaperSize.allCases`
     `displayName`s, selecting 11 × 14.
  2. Assign `panel.accessoryView`; run the panel. **No PDF is rendered yet.**
  3. On `.OK`: map the popup's selected index → `PaperSize` → `.size`; set
     `preparing = true`; render the PDF at that size; write atomically to dest.

  (Today `makePDF()` runs *before* the panel; flipping the order is what makes
  the choice apply, and it removes the spinner that currently shows before the
  panel even appears.)

### 4. Localization

`String(localized:)`-wrap the six `displayName`s and the "Paper Size:" label,
then run the `-exportLocalizations` write-back and fill the French values.

### 5. Tests

- New `MuseTests/PaperSizeTests.swift`: assert each case's `.size` matches the
  table (point dimensions, portrait orientation).
- Pagination at non-11×14 sizes is already covered structurally by
  `CollectionPDFLayoutTests` (the geometry is fully parametric on `pageSize`).

## Out of scope

- Landscape orientation.
- Remembering the last-used size.
- A paper-size choice on the Share path.
- Custom margins / DPI.

## Risks

- **AppKit accessory view on main thread** — `save()` is already `@MainActor`
  (SwiftUI view method); view construction is fine.
- **Popup index ↔ enum mapping** — drive both the popup population and the
  read-back from the same `PaperSize.allCases` order so they can't drift.
