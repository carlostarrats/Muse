# Tile Background — design

**Date:** 2026-06-18
**Status:** Approved (brainstorm complete)

## Summary

Add a user-selectable **tile background** — the backdrop drawn behind grid
content: the letterbox area around aspect-fit images *and* the background of
non-image file cards (zip, pdf, folders, docs). Today that backdrop is welded
to the app **mood** (`moodPalette.tileFill`). This feature decouples it into
its own global setting, while keeping a mood-wired option for users who like
the current behavior.

Motivation: a grey image on a grey backdrop disappears. The fix is *tonal*
(make the backdrop lighter or darker), not chromatic — so the control offers a
clean neutral luminance ladder, not an arbitrary color picker.

The chosen backdrop also carries into the **collection PDF export**: the PDF
grid reflects what's on screen at export time (the active Image Layout ratio +
the chosen backdrop color behind each image). The PDF *paper* page is always
white — only the per-image backdrops take the color.

## The control

Five options, presented in two labeled groups so the automatic-vs-static
distinction is structural (not a tooltip):

**Automatic** (these track the mood)
- **None** — transparent. Letterbox areas and card backgrounds reveal the page
  behind them; images/icons appear to float. (What shows through is the
  mood-driven page, hence "automatic".)
- **Auto** — the current behavior: backdrop follows `moodPalette.tileFill`.
  **This is the default**, so existing users see no change. Its swatch renders
  the *live* mood color and updates when the mood changes — that visible change
  is what signals "automatic". Never labeled "grey" (in Dark mood it's nearly
  black).

**Static** (fixed neutrals, independent of mood)
- **Light** — `#FAFAFA` (`MoodRGB(0.980, 0.980, 0.980)`)
- **Dark Grey** — `#555555` (`MoodRGB(0.333, 0.333, 0.333)`) — a true *mid*
  grey, deliberately not charcoal, so it reads clearly distinct from both the
  Auto/light end and Black.
- **Black** — `#0D0D0D` (`MoodRGB(0.051, 0.051, 0.051)`)

The static values target a clean luminance ladder with obvious gaps
(Auto↔Dark Grey, Dark Grey↔Black). Exact values are tunable live against real
images; the spacing intent above is the requirement.

## Where it lives

A new **"Tile Background"** section appended *below* the existing mood swatches
and HSB sliders inside the `paintpalette` toolbar popover (`MoodPickerView`).
**One stacked pane, no tabs** — the control is shallow (five one-tap options),
so keeping everything visible beats hiding half behind a tab, and it preserves
the popover's existing expand behavior.

Layout within the section: a divider, a section caption, then the five swatches
arranged as two captioned groups ("Automatic": None, Auto · "Static": Light,
Dark Grey, Black). Swatches reuse the existing `MoodSwatch` visual language
(circle + selection ring + label):
- **None** — a circle with a diagonal slash (the conventional "no color" glyph).
- **Auto** — filled with the live `moodPalette.tileFill`.
- **Light / Dark Grey / Black** — filled with their fixed colors.

Popover width stays 270.

## Scope (what changes / what doesn't)

**In scope** — exactly two surfaces:
1. **On-screen grid tiles** — both image tiles and non-image file cards in
   `GridView.TileView`.
2. **Collection PDF export** — per-image backdrop reflects the choice; PDF grid
   reflects the active Image Layout ratio.

**Explicitly out of scope** (flag if you disagree):
- The app/mood **page** background (unchanged; mood owns it).
- The PDF **paper** page (always white).
- Hero viewer backdrop (its own adaptive wash).
- Collection card covers, `ImageLayoutSheet` previews (still mood-based).
- Selection-ring / hover-veil contrast logic (stays mood-derived as today).
- No per-folder override — one global setting.

## Architecture & data flow

### New model: `TileBackground` (Models/TileBackground.swift)

A pure, unit-testable enum mirroring the shape of `ImageLayout`/`Mood`:

```swift
enum TileBackground: String, CaseIterable, Identifiable {
    case none, auto, light, darkGrey, black

    var id: String { rawValue }
    var displayName: String   // "None" / "Auto" / "Light" / "Dark Grey" / "Black"

    // Fixed neutral values for the static cases (nil for none/auto).
    var staticRGB: MoodRGB?   // light/darkGrey/black → their MoodRGB; else nil

    /// SwiftUI fill for the on-screen grid tile.
    /// none → .clear (transparent), auto → mood.tileFill, static → fixed color.
    func fill(for mood: MoodPalette) -> Color

    /// Backdrop color for PDF export (and any layer that needs an explicit
    /// color vs "no fill"). none → nil (skip fill → white paper shows),
    /// auto → mood.tileRGB, static → fixed MoodRGB.
    func backdropRGB(for mood: MoodPalette) -> MoodRGB?

    static func resolve(_ raw: String?) -> TileBackground  // default .auto
}
```

### Persistence + state

- `AppSettings`: add a `tileBackground` accessor (UserDefaults key
  `muse.tileBackground`), default `.auto` — mirrors how `imageLayout` is stored.
- `AppState`: add `@Published var tileBackground: TileBackground` mirrored to
  `AppSettings` (setter persists), exactly like `imageLayout`. Add a computed
  `var tileFill: Color { tileBackground.fill(for: moodPalette) }`.

### On-screen grid

- `GridView.TileView`: replace the two `Rectangle().fill(appState.moodPalette.tileFill)`
  calls (image tile + file card) with `Rectangle().fill(appState.tileFill)`.
  Everything else (shimmer, `cardIcon`, captions, selection ring) is untouched.
  The grid *background* (`appState.moodPalette.background`) is **not** changed.

### Mood picker UI

- `MoodPickerView`: add the new "Tile Background" section described above,
  writing `appState.tileBackground` via a setter that persists.

### PDF export

The PDF grid mirrors the on-screen grid at export time — both the ratio and the
per-image backdrop color. Paper stays white.

- `ShareCollectionButton.makePDF()` passes two new values into the exporter,
  read from `AppState` on the main actor before the detached task:
  - `layoutAspect: CGFloat?` = `appState.imageLayout.aspect` (nil = masonry).
  - `tileBackdrop: MoodRGB?` = `appState.tileBackground.backdropRGB(for: appState.moodPalette)`.
- `CollectionPDFExporter.makePDF(urls:title:count:columns:layoutAspect:tileBackdrop:)`:
  - **Paper fill unchanged** — still white (`CGColor(red:1,green:1,blue:1,alpha:1)`).
  - **Layout reflects the ratio**: build the `aspects` array as
    `layoutAspect.map { a in Array(repeating: a, count: images.count) } ?? images.map(\.aspect)`.
    A fixed ratio feeds a uniform aspect array (mirrors how `GridView` feeds
    `MasonryGeometry` a uniform aspect for fixed layouts — packs an even
    row-major grid); masonry keeps per-image aspects. `CollectionPDFLayout`
    needs no change — it already paginates from an arbitrary aspect array.
  - **Per-image backdrop**: for each placement, before drawing the image, if
    `tileBackdrop != nil` fill the `imageRect` (the tile minus the caption
    strip, flipped to PDF coords) with the backdrop color. Then aspect-fit and
    draw the image on top. `none` (nil) → no fill → white paper shows through
    (and shows through transparent images), i.e. transparent backdrop.
  - **Captions unchanged**: the filename strip sits below `imageRect` on white
    paper, so existing caption/header colors stay legible — no ink flip needed
    (paper is always white).

## Testing

- **`TileBackgroundTests`** (pure, new): `displayName`; `resolve` default +
  parse + unknown→`.auto`; `fill(for:)` mapping (`.clear` for none, mood tile
  for auto, fixed values for statics); `backdropRGB(for:)` (nil for none, mood
  tileRGB for auto, fixed for statics). Matches the project's "pure logic is
  unit-tested" convention.
- Exporter drawing + `MoodPickerView` are view/CG layers (not unit-tested per
  project convention) — verify by build (`xcodebuild -scheme Muse build`),
  running the app, and exporting a collection in each backdrop option + a
  fixed ratio to confirm the PDF matches the grid.

## Notes / rationale

- Neutral densities over a custom color picker: the problem is contrast
  (luminance), and colored backdrops fight image content. Fewer, well-chosen
  neutrals = fewer bad outcomes and a simpler control.
- "Auto" stays the default so the change is invisible to existing users until
  they opt into a static tone.
- The per-image backdrop is meaningful even in masonry export for images with
  transparency (e.g. PNG logos), where the color shows through the image.

## Revisions (round 2 — post-implementation review)

These refinements were made after driving the first build:

1. **Masonry uses Auto only.** Masonry has no letterbox, so the static tones
   wouldn't read anyway. When `imageLayout == .masonry` the effective backdrop
   is forced to Auto and the picker's options are disabled (dimmed) with a note
   ("Masonry always uses Auto. Pick a fixed ratio to choose a backdrop."). The
   stored `tileBackground` is preserved, so switching back to a ratio restores
   the prior pick. Implemented as `AppState.effectiveTileBackground` — used by
   `tileFill`, the grid card text color, the picker highlight, and the export.
2. **None swatch hit target.** The transparent "None" glyph wasn't hit-testable
   over its empty area — added `.contentShape(Rectangle())` to the swatch so the
   whole graphic + label is tappable (matching the other swatches).
3. **File-card filename auto-contrast.** The card's internal filename now adapts
   to the effective backdrop luminance (`SelectionStyle.relativeLuminance`):
   light text on a dark backdrop, dark on light. None follows the page (mood)
   background. Fixes unreadable names on Black/Dark Grey backdrops.
4. **File cards export.** Export now includes non-image members (zip/pdf/doc…),
   not just images. Folders are excluded. The exporter decodes images via
   ImageIO and falls back to QuickLook (`QLThumbnailGenerator`, `.all`
   representation) for everything else — the same macOS type icon / content
   preview the grid cards show — drawn on the chosen backdrop like any image.
   `ShareCollectionButton.imageURLs` → `exportURLs` (all non-folder members).
5. **Image Layout modal is mood-independent.** `ImageLayoutSheet`'s tiles were
   tinted by the mood (`moodPalette.tileFill`); they now use a fixed default
   grey (`Mood.paperPalette.tileFill`) with fixed dark label/icon colors, so the
   modal looks the same regardless of the app color or tile-background choice.
