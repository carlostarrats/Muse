# Hero INFO Card (EXIF / file metadata) — design

**Date:** 2026-06-20
**Status:** Approved (brainstorm complete)
**Ships as:** its own branch (first of three; recommended starting point)

## Summary

Add a new **INFO** card to the hero viewer's right-hand info column
(`ViewerInfoColumn`), directly **below the COLORS card**. It surfaces the
file's *extra* metadata — the stuff that isn't already in the subtitle line
(which today shows size · pixel dimensions · modified date). For a photo that's
EXIF (date taken, camera, lens, exposure, location); for a PDF it's page count
and document properties; for A/V it's duration.

The card is **generic, not photo-specific** — labeled **INFO**, never "PHOTO",
because the same slot serves PDFs, screenshots, video, etc. Each row renders
only when its value exists. **If the file yields no extra metadata at all, the
card does not render** (a plain screenshot usually has nothing beyond the
subtitle, so it simply won't show a card).

## Motivation

The info column already answers "what is this / how big" but stops short of the
question people actually open a photo to ask: *when/where was this shot, what
took it.* All of that lives in the file's own headers and is readable locally
with zero network — it just isn't surfaced yet.

## The control / appearance

A new card using the **existing `InfoCard` shell** (radius 14, white 0.09 fill,
same padding as COLLECTION / TAGS / COLORS), with the same `CardLabel`
treatment ("INFO", uppercase, kerned, white 0.42).

Inside: a vertical stack of **label → value rows** (a compact definition list).
- Label: white ~0.42, 10–11pt (matches `CardLabel` tone, smaller).
- Value: white ~0.9, 11pt (matches the column's body text).
- Rows wrap/truncate tail like the rest of the column. Column width is unchanged
  (`258 + 24`).

Rows shown per file type (only when the value is present):

**Images** (ImageIO EXIF/TIFF/GPS):
- **Taken** — `DateTimeOriginal` (formatted medium date + short time)
- **Camera** — TIFF `Make` + `Model` (e.g. "Apple iPhone 15 Pro")
- **Lens** — EXIF `LensModel` / focal length (e.g. "Main · 24 mm")
- **Exposure** — ƒ-number · shutter · ISO (e.g. "ƒ1.8 · 1/120 · ISO 64")
- **Location** — `lat, long` as text, plus an **"Open in Maps" button**

**PDFs** (PDFKit `PDFDocument.documentAttributes`):
- **Pages** — page count
- **Title** / **Author** / **Creator** — when present in the doc attributes

**Video / Audio** (AVFoundation, already partly in `FileRow.duration_seconds`):
- **Duration** — formatted (e.g. "3:42")
- **Codec** — only if cheap to read; otherwise omit (see Scope)

### Location is text-only — no inline map

Location renders as plain coordinates plus an **"Open in Maps"** action
(`NSWorkspace.shared.open(URL(string: "maps://?ll=<lat>,<long>"))`). An inline
`MKMapSnapshotter` map is **deliberately excluded** — it fetches map tiles from
Apple's servers, which is a remote content fetch and violates Muse's
update-only network policy. Coordinates + a hand-off to Maps.app keeps Muse
itself network-free.

## Architecture & data flow

### Extraction — on viewer open, no DB storage

Metadata is read **lazily when the hero opens a file**, async, mirroring how the
viewer already computes a palette fallback (`fallbackPalette` / `paletteLoading`
in `ViewerInfoColumn`). **No new DB column, no migration** — this data is only
ever shown in the hero for the current file, so persisting it earns nothing.

New pure-ish helper, e.g. `Viewers/FileMetadata.swift`:

```swift
struct InfoRow: Identifiable { let id = UUID(); let label: String; let value: String }

struct FileMetadata {
    var rows: [InfoRow]          // ordered, only present values
    var coordinate: (lat: Double, long: Double)?   // drives the Open in Maps button

    /// Reads headers off-main for the given file + kind. Returns empty rows
    /// (and nil coordinate) when nothing extra is available.
    static func load(url: URL, kind: AssetKind) async -> FileMetadata
}
```

- **Images:** `CGImageSourceCreateWithURL` →
  `CGImageSourceCopyPropertiesAtIndex` → read `kCGImagePropertyExifDictionary`,
  `kCGImagePropertyTIFFDictionary`, `kCGImagePropertyGPSDictionary`. Build rows
  from whatever keys are present.
- **PDFs:** `PDFDocument(url:)` → `pageCount` + `documentAttributes`
  (`.titleAttribute`, `.authorAttribute`, `.creatorAttribute`).
- **A/V:** reuse `FileRow.duration_seconds` if already loaded via
  `ViewerFileDetails`; else read `AVURLAsset` duration. Codec only if trivial.

**iCloud guard:** like the rest of the app, skip reading bytes of a dataless
iCloud placeholder (check `.ubiquitousItemDownloadingStatusKey`); show no card
until the file is local. Reading headers must never force a download.

### Wiring into the column

- `ViewerInfoColumn` gains an optional `metadata: FileMetadata?` (loaded by the
  hero viewer the same way `details` is, refreshed when the file changes).
- New private `infoCard` view, inserted **after** `colorsCard` / placeholder and
  **before** `actionsRow`, gated on `!(metadata?.rows.isEmpty ?? true)`.
- The "Open in Maps" button uses the column's existing small-button styling
  (e.g. `HoverTextButton` or a compact `ActionButton`), shown only when
  `metadata?.coordinate != nil`.

No layout jump risk: because the card is omitted entirely when empty, there's no
placeholder flicker; while metadata is still loading the card simply hasn't
appeared yet (acceptable — it's secondary info, unlike the palette which has a
placeholder to hold the actions row position). If a load-flicker proves
distracting in practice, a one-line "INFO" placeholder can be added, but default
is **no placeholder**.

## Scope (what changes / what doesn't)

**In scope:**
1. A new INFO card in `ViewerInfoColumn` (hero viewer only).
2. A `FileMetadata` extraction helper (ImageIO / PDFKit / AVFoundation).
3. The "Open in Maps" hand-off.

**Out of scope (flag if you disagree):**
- The grid tiles / file cards (no metadata shown there).
- Persisting metadata in SQLite or making it searchable (FTS unchanged).
- Editing metadata (Muse never mutates files except move-to-Trash).
- Inline maps (network).
- Non-hero viewers' chrome (the `ViewerChrome` fallback) — INFO is hero-only.
- Codec/advanced media internals beyond a cheap duration (can extend later).

## Testing

- **`FileMetadataTests`** (pure, new): feed known EXIF/PDF property dictionaries
  (or small fixture files in the test bundle) and assert the produced `rows`
  (labels, formatting of exposure/date) and `coordinate`. Assert an
  image/file with no extra metadata yields empty `rows` (→ card hidden).
- The card view + Maps hand-off are SwiftUI/AppKit (not unit-tested per project
  convention) — verify by build + opening photos, a PDF, a screenshot, and a
  video in the hero and confirming each shows the right rows (or no card).

## Notes / rationale

- Generic "INFO" label keeps one slot reusable across file types instead of a
  type-specific card per kind.
- On-open extraction (vs DB) keeps the feature self-contained: no schema churn,
  no backfill, nothing to keep in sync with the analyze pipeline.
- Text coordinates + Open in Maps is the only location treatment that honors the
  no-network identity.
