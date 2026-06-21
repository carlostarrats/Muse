# Granular image-format filtering — design (feat/next-48)

**Date:** 2026-06-20
**Branch:** `feat/next-48`
**Status:** approved, pre-implementation

## Context

The grid faceted filter (`feat/next-42`) narrows the visible tiles by a coarse
*kind* facet: Images / Videos / PDFs / Documents / Audio / Folders / Other.
Earlier on this branch (`feat/next-48`) the **Date** and **Size** facets were
removed — sort-by-date and sort-by-size cover those needs — leaving a kind-only
filter (`GridFilter.kinds: Set<KindFacet>`, empty = all).

The single "Images" bucket is too coarse for a photo-heavy library. The user
wants to narrow images by *format* — JPEG, PNG, HEIC, TIFF, etc. — while every
other kind stays generic.

## Goal

Replace the coarse "Images" facet with a set of image-**format** leaf facets,
presented under a collapsible "Images" parent row in the filter popover. Every
image file maps to exactly one leaf, so nothing can become unreachable.

Non-goals (unchanged, out of scope): the other kind facets stay generic; no
date/size filtering (removed); no per-format detail for video/audio/documents;
no Collections-card-page filtering; the funnel's engaged-blue active indicator
and Clear All are untouched.

## Format list

Ten image leaves (RAW collapsed to a single bucket per the user's choice):

| Leaf | Matches |
|---|---|
| JPEG | `.jpg`, `.jpeg` |
| PNG | `.png` |
| HEIC | `.heic`, `.heif` |
| TIFF | `.tif`, `.tiff` |
| GIF | `.gif` |
| WebP | `.webp` |
| RAW | every camera-raw format: `dng`, `cr2`, `cr3`, `nef`, `arw`, `orf`, `rw2`, `raf`, `srw`, `pef`, … (`AssetKind.raw`) |
| PSD | `.psd` (`AssetKind.psd`) |
| SVG | `.svg` (`AssetKind.svg`) |
| Other | any image whose format is **not** named above — BMP, ICO, AVIF, extensionless-but-image, … (the catch-all) |

The "Other" image leaf is the load-bearing piece: without it, an image of an
unlisted format would have no checkbox controlling it, so narrowing the list
would make it vanish with no way to bring it back. With it, **every image file
maps to exactly one leaf**, and "all leaves checked" (the default) is byte-for-
byte today's single "Images" behavior.

This image-group "Other" is distinct from the **top-level "Other" kind** (non-
image files: 3D models, fonts, archives, unknown). The image one only ever
covers files that classify as images.

## Data model — one flat leaf set; hierarchy is UI only

`GridFilter.kinds` keeps being a single `Set<KindFacet>` with the existing
"empty = all" sentinel. The `.image` case is **replaced** by the ten image
leaves; the non-image cases are unchanged:

```
enum KindFacet {
    // image leaves (was a single `.image`)
    case jpeg, png, heic, tiff, gif, webp, raw, psd, svg, imageOther
    // non-image kinds (unchanged)
    case video, pdf, document, audio, folder, other
}
```

"Images" is **not** a stored facet — it is purely a UI parent that toggles its
ten children together. Because the set stays flat with the same sentinel, an
unfiltered grid (`kinds == []`) is identical to today.

A helper exposes the image-leaf grouping for the UI and the "all/some/none"
parent state, e.g.:

```
extension KindFacet {
    static let imageLeaves: [KindFacet] = [.jpeg,.png,.heic,.tiff,.gif,.webp,.raw,.psd,.svg,.imageOther]
    var isImageLeaf: Bool { Self.imageLeaves.contains(self) }
}
```

## Matching — `(kind, ext)` → leaf

`matches` gains the file's extension so it can resolve an image to its leaf. It
stays pure and IO-free; the extension comes from the `FileNode.url` the caller
already holds (`AppState+Filters.visibleFiles`).

```
func matches(kind: AssetKind, ext: String) -> Bool {
    guard !kinds.isEmpty else { return true }      // empty = all
    return kinds.contains(Self.leaf(kind: kind, ext: ext))
}

static func leaf(kind: AssetKind, ext: String) -> KindFacet {
    switch kind {
    case .raw:  return .raw
    case .psd:  return .psd
    case .svg:  return .svg
    case .image:
        switch ext.lowercased() {
        case "jpg", "jpeg":  return .jpeg
        case "png":          return .png
        case "heic", "heif": return .heic
        case "tif", "tiff":  return .tiff
        case "gif":          return .gif
        case "webp":         return .webp
        default:             return .imageOther   // bmp, ico, avif, extensionless-image, …
        }
    case .video:    return .video
    case .pdf:      return .pdf
    case .text, .markdown, .code, .office: return .document
    case .audio:    return .audio
    case .folder:   return .folder
    case .model3d, .font, .archive, .unknown: return .other
    }
}
```

Folders: a folder maps to the `.folder` leaf and is matched by it alone (no
date/size concepts remain, so the earlier "folder matched only by kind" carve-
out is moot — `.folder` is just another leaf).

`KindFacet(from:)` (the old coarse mapper) is removed/replaced by `leaf(kind:ext:)`.

## UI — `GridFilterPopover`

The KIND section becomes:

```
KIND
▸ ☑ Images          (parent: tri-state, with disclosure triangle)
  ☑ Videos
  ☑ PDFs
  ☑ Documents
  ☑ Audio
  ☑ Folders
  ☑ Other
```

Expanding the Images row reveals the ten format checkboxes indented under it:
JPEG · PNG · HEIC · TIFF · GIF · WebP · RAW · PSD · SVG · Other.

- **Disclosure** collapsed by default (keeps the popover short). State is local
  view `@State` (transient; not persisted).
- **Images parent checkbox is tri-state**:
  - all ten image leaves present (or `kinds == []`) → **checked**
  - some present → **mixed** (dash)
  - none present → **unchecked**
  - clicking it: if currently all-on → remove all ten image leaves; otherwise →
    add all ten.
- **Child checkbox** toggles its one leaf, reusing the existing "empty == all"
  expand/collapse sentinel logic (`toggleKind`), generalized to the flat leaf
  set: expand the empty sentinel to the full `KindFacet.allCases`, flip the
  leaf, then collapse back to `[]` if the result is the full set or empty.

SwiftUI has no native tri-state `Toggle`; implement the parent as an
`NSButton`-backed control with `allowsMixedState` (a small `NSViewRepresentable`)
**or** a `Button` showing one of three SF Symbols
(`checkmark.square.fill` / `minus.square.fill` / `square`) wired to the toggle-
all action. Pick whichever reads cleanest at build time; behavior is the spec.

## Accessibility

- The indented image **Other** uses a disambiguating VoiceOver label
  ("Other image formats") so it isn't confused with the top-level "Other".
- The **Images parent** exposes its checked/mixed/unchecked state
  (`.accessibilityValue` or the AppKit mixed state) and a clear label.
- The disclosure control is labeled ("Show image formats" / "Hide image
  formats") and is keyboard-reachable; the existing section header keeps
  `.isHeader`.

## Persistence / upgrade

`GridFilter` persists as JSON via `AppSettings.gridFilter`, decoded by
`GridFilter.resolve(_:)`. A filter saved before this change may contain the old
`"image"` value, which no longer decodes; `Set<KindFacet>` decoding throws on an
unknown case, so `resolve` falls back to `.none` (no filter, all shown). This is
acceptable — the filter is transient view state, and it mirrors how removing
Date/Size earlier on this branch behaved. No migration code.

## Testing — extend `GridFilterTests`

- `leaf(kind:ext:)` mapping: each named extension → its leaf; **unknown image
  ext → `imageOther`** (bmp, ico, avif, empty string); case-insensitivity
  (`.JPG`); aliases (`jpeg`, `heif`, `tif`).
- `.raw`/`.psd`/`.svg` kinds → `raw`/`psd`/`svg` regardless of ext.
- non-image kinds → unchanged leaves (document collapses text/markdown/code/
  office; other collapses model3d/font/archive/unknown).
- `matches`: empty set matches everything; a narrowed set passes only its
  leaves; a JPEG is hidden when only PNG is selected; a BMP is hidden when
  specific named formats are selected but shown when `imageOther` is selected.
- `isActive`: false only for the empty set.
- Codable round-trip via `resolve`; legacy `{"kinds":["image"]}` → `.none`.

The popover's tri-state/disclosure interaction is UI and not unit-tested (UI
views aren't, per the project convention), but the toggle-all and
collapse-to-sentinel *logic* should be a pure helper that is unit-tested.

## Files touched

- `Models/GridFilter.swift` — leaf enum, `leaf(kind:ext:)`, `matches(kind:ext:)`,
  `imageLeaves` helper, pure toggle/collapse helper.
- `Views/GridFilterPopover.swift` — disclosure + tri-state parent + indented
  children + a11y.
- `Models/AppState+Filters.swift` — pass the file extension into `matches`.
- `MuseTests/GridFilterTests.swift` — the cases above.
</content>
