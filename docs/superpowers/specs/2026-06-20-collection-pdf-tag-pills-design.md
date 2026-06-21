# Collection PDF export — carry the active tag filter

**Date:** 2026-06-20
**Status:** Approved design, pending implementation plan

## Problem

A collection can now be filtered by one or more tag chips (the multi-tag
AND/intersection view, `feat/next-45`). On the Collections page this shows as a
highlighted chip (single tag) or a "Viewing [a] and [b]" pill banner (2+ tags),
and the grid narrows to the matching images.

Exporting that collection to a PDF (`ShareCollectionButton` → Save to… / Share)
**ignores the filter entirely**: `exportURLs` reads `activeCollectionFiles` (all
members), so the PDF contains every image and gives no indication a filter was
applied. The user wants the export to reflect the on-screen refinement — both the
narrowed image set and a visual marker of which tags drove it.

## Goal

When a collection is exported while a tag filter is active:

1. Export **only the images currently shown in the grid** (the refined set).
2. Draw the active tag labels as **pills above the collection name** in the PDF
   header — bare pills (e.g. `[Black] [Purple]`), no "Viewing"/"and" connective
   words.

When no tag filter is active, the export is byte-for-byte unchanged.

## Decisions (locked)

- **Export set = exactly what's on screen.** Use `AppState.visibleFiles` (minus
  folders), which already honors the active tags AND any engaged kind/date/size
  facet filter. Mental model: "the PDF = what I see." (Chosen over a tags-only
  subset.)
- **Pills appear for 1+ active tags.** A single active tag shows no on-screen
  banner (just a highlighted chip), but the PDF has no chip row, so the single
  pill is the only cue the export was refined. So pills render for one or more
  tags — a deliberate, documented divergence from the on-screen banner's 2+
  threshold.

## Design

Two files change. `CollectionPDFLayout` (pure pagination) is untouched — it
already accepts a variable first-page header height.

### 1. Export the filtered set — `ShareCollectionButton.swift`

`exportURLs` changes from `activeCollectionFiles` to `visibleFiles`:

```swift
private var exportURLs: [URL] {
    appState.visibleFiles.compactMap { node in
        node.kind == .folder ? nil : node.url
    }
}
```

- The header count already comes from `urls.count` in `makePDF`, so the count
  auto-follows the filtered set (e.g. "Inspo  7" when 7 of 20 match).
- The disabled guard `exportURLs.isEmpty` keeps the button dead if a filter
  empties the grid (an empty intersection is a legitimate empty view).
- `makePDF` passes the active tag labels through to the exporter:
  `tagLabels: appState.activeTagLabels`.

### 2. Draw tag pills above the title — `CollectionPDFExporter.swift`

`makePDF(...)` gains a `tagLabels: [String]` parameter, threaded into a
pill-aware header.

**Header band (page 1 only), top → down:**

1. Pill row(s) at the top margin.
2. A gap.
3. The collection name + count (today's title block), unchanged otherwise.

**Pill rendering** (CoreText capsules, matching the on-screen `BannerPill`):

- Label: 12pt system medium, `black @ 100%`.
- Padding: 8pt horizontal, 2pt vertical → capsule height ~16pt.
- Fill: `black @ 8%` rounded capsule on the white page (mirrors
  `BannerPill`'s `.primary.opacity(0.08)` on light paper).
- Bare labels only — NO "Viewing"/"and"/comma connective words.
- Laid out left → right; **wrap to a second row** when the next pill would
  exceed the content width (robust for many/long tags; typical 1–3 short color
  tags stay on one row).

**Variable header height:** the page-1 `firstPageHeaderHeight` passed into
`CollectionPDFLayout.Geometry` is computed to fit the pill row(s) + gap + title.
With no tags it equals today's 46pt (no pills) for a zero-regression unfiltered
export. `CollectionPDFLayout.paginate` already reserves a variable first-page
header, so image packing flows below it with no layout change.

## Out of scope

- Filename of the exported PDF (stays collection-title based).
- Any change to the on-screen banner / chip behavior.
- Pills on pages 2+ (header block is page-1 only, as today).
- Reflecting the facet filter in the header text (the narrowed image set already
  conveys it; only tags get pills, per the request).

## Testing

- No new pure logic: pill capsule placement is CoreText text measurement,
  consistent with the existing **untested** `drawHeader`/`drawCaption` (the
  unit-tested surface is `CollectionPDFLayout` pagination, which is unchanged).
- Verify by building and exporting a tag-filtered collection: confirm (a) only
  the visible images export, (b) pills render above the title for both a single
  tag and 2+ tags, (c) an unfiltered export is identical to today.

## Files touched

- `Muse/Muse/Views/ShareCollectionButton.swift` — export set + pass labels.
- `Muse/Muse/Export/CollectionPDFExporter.swift` — `tagLabels` param, header
  height, pill drawing.
