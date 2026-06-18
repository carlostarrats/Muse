# Grid hover + selection redesign — design

Date: 2026-06-17
Branch: `feat/next-12`

## Problem

The current grid tile interaction isn't loved:

- **Hover** scales the tile up to `1.025×` (`GridView.swift` `TileView.body`,
  the `scaleEffect(hovering ? 1.025 : 1)`). The grow feels busy.
- **Selection** draws a *flush*, edge-to-edge accent treatment on the image:
  an `accentColor`-at-0.22 wash plus a 3pt `accentColor` stroke
  (`TileView.imageContent`, the `if selected { Rectangle().fill(...).overlay(stroke) }`).
  The flush ring can blend into same-hue backgrounds and feels hard.

## Goals

Replace both with a calmer, more intentional treatment:

1. **Hover** = a subtle dark veil over the image, no size change.
2. **Selection** = the image shrinks slightly inside its tile, revealing a gap
   of the app's background color, with a **padded ring** drawn around the
   outside of that gap, plus a subtle color tint over the image.
3. **The ring/tint color adapts to the app background mood** so it always
   stands out — blue on neutral backgrounds, black/white on colorful ones.

Scope is confined to `TileView` in `GridView.swift` plus one small pure helper
for the ring-color decision. No masonry/layout/virtualization changes: the tile
*frame* is unchanged; only the image's displayed size changes within it.

## Hover (unselected tile)

- Remove the `scaleEffect`/`1.025` grow and its `onHover`-driven animation
  entirely.
- On hover, overlay a **dark veil**: `Color.black` at ~`0.12` opacity over the
  image area, animated with a short ease (~0.18s).
- No veil on a tile that is currently selected (selection look wins — see
  "Selected + hover" below).

## Selection

When a tile is selected (multi-select `selectedFiles` contains its path, OR it
is the open `selectedFile`):

- **The image shrinks** by a small uniform inset on all four sides (a few
  points). It keeps its **natural aspect ratio** — it is NOT forced square; only
  the corners stay square (no corner rounding on the image). The shrink is the
  mechanism that reveals the inset gap.
- **The inset gap** between the shrunken image and the ring shows the app
  background color (`appState.moodPalette.background`), so the image reads as
  "lifted into" the ring.
- **The ring** is stroked around the outside of the gap, just inside the tile's
  outer frame. Corners are **slightly rounded** (small radius). The radius is a
  single constant so it can be set to `0` (square ring) trivially if the rounded
  look isn't liked when seen live.
- **A subtle tint** in the ring's color sits over the (shrunken) image, the
  spiritual successor to today's 0.22 accent wash.

The selection treatment is drawn inside the image area only; the optional
filename caption strip below the tile (when "Show file names" is on) stays
outside the ring, unchanged.

### Selected + hover

A hovered, already-selected tile keeps **only** the selection look — no dark
hover veil stacked on top.

## Ring + tint color (whole-grid rule from the background mood)

One rule for the entire grid, derived from the current background color
(`appState.moodPalette.background` / mood). NOT per-image.

- **Neutral background** → **blue** ring + blue tint (today's `accentColor`
  look). Neutral = Light / Dark / Auto moods always, plus any Custom mood whose
  color is low-saturation (near-grey).
- **Colorful background** (a Custom mood with meaningful saturation) → the ring
  becomes **black or white**, whichever has the higher contrast against the
  background color, and the tint follows (a subtle black or white veil instead
  of blue). This guarantees the ring never vanishes into a same-hue background
  (a blue ring on a blue/purple background).

### Decision helper (pure)

A small pure function decides the ring color from the background color:

1. **Is the background colorful?** Convert the background RGB to HSB; it's
   "colorful" when `saturation` exceeds a threshold (≈`0.20`). Light/Dark/Auto
   are neutral by construction; only a saturated Custom mood trips this.
2. **If neutral** → return the system accent (blue).
3. **If colorful** → compute WCAG relative-luminance contrast of pure white vs
   the background and pure black vs the background; return whichever yields the
   higher contrast ratio. (Picking the max of the two always clears AA's 4.5:1
   for any saturated color, so the ring is always legible.)

The tint color is the same hue as the ring at a low opacity.

This helper is pure (RGB in → color decision out), unit-testable, and lives
next to the mood/palette code or in a small new file.

## Tunable constants (dev-only, locked for production)

These are internal constants I tune to nail the look, then hardcode to final
values. They are NOT user-facing and ship no settings UI:

- Hover veil opacity (~0.12) and animation duration.
- Selection image inset / shrink amount (a few points).
- Ring corner radius (small; `0` = square fallback).
- Ring thickness.
- Selection tint opacity.
- "Colorful" saturation threshold (~0.20).

## Non-goals / unchanged

- Masonry packing, tile frames, and grid virtualization are untouched (the tile
  frame is the same; only the image's displayed size changes within it).
- The hero open/close flight still reads the tile's image-area global frame; the
  selected tile remains hidden (`opacity 0`) while the hero is open, so the
  slight selection inset does not affect the flight handoff in practice.
- VoiceOver `.isSelected` trait, drag-to-move, double-click-to-open, and the
  deselect surfaces are unchanged.
- The Collection-PDF export and any non-grid surface are untouched.

## Testing

- Unit-test the pure ring-color helper: neutral backgrounds (Light/Dark/Auto +
  low-saturation Custom) → accent/blue; saturated Custom colors → black or white
  with the higher contrast, and assert the chosen color clears AA (≥4.5:1)
  against the background.
- The visual hover/selection rendering is verified live in the app (the
  rounded-vs-square ring is explicitly a see-it-live decision).
