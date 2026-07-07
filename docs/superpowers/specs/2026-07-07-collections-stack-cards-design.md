# Collections page: scattered stack cards (mymind-style)

**Date:** 2026-07-07 · **Branch:** `feat/next-126` · **Status:** approved

## Goal

Replace the Collections page's single cropped cover rectangle with a loose
pile of member images that fans apart on hover — matching the mymind
"Spaces" reference video (owner-supplied, watched frame by frame). The owner
will visually compare the result against the video.

## Reference behavior (from the video)

- **Rest:** each collection is a messy pile — the cover card on top at its
  natural aspect ratio, slightly rotated; ~5 more cards peek out underneath
  at varied offsets/rotations on all sides. Soft shadows. Label centered
  below the pile.
- **Hover:** the pile fans apart with a springy overshoot. The top card
  mostly stays put (slight lift/rotation); the under-cards slide outward in
  stable per-pile directions with rotations up to ~±25°, spilling past the
  pile's footprint and OVER neighboring piles (the hovered pile z-raises;
  neighbors never move). Mouse-out springs back to the tight pile.
- Scatter directions are stable per pile (not re-randomized every hover).

## Decisions (owner)

- Stack depth: **6** cards max.
- Fewer members than 6 → **repeat members to fill** (a 1-image collection
  shows that image stacked behind itself).
- Layout stays **4 across**; label (name + count) is now **centered**.
- The existing right-click "Set as Collection Cover" (grid context menu →
  `cover_file_id`) keeps working and now means "top card of the stack".

## Design

### Stack composition
- Top card = chosen cover if alive-member, else first alive member
  (`CollectionStore.coverPath` / `alivePaths` — existing seams).
- Under-cards = next alive members in query order, cover deduped, capped at
  6 total; repeat from the start to fill if short.
- Empty collection: plain grey rounded card (as today), no pile.

### Geometry (pure, unit-tested)
- New pure type in `Components/` (`StackScatter`): given a **stable seed**
  (FNV-1a over the collection id — NOT `Hasher`, which is randomized per
  launch), card count, and cell size, produce per-card rest + fanned poses
  (rotation, offset; fractions of the cell).
- Rest poses: top card ±3°; under-cards ±2–7° rotated, offset up to ~8% of
  the cell, directions distributed across angle sectors (jittered) so edges
  peek on all sides.
- Fan poses: top card small lift; under-cards move outward along their rest
  direction to ~18–34% of the cell, rotation up to ~±18° (owner-tuned down
  from a wider first cut — the full-video spread read as "too much").
- Deterministic: same seed → identical poses forever.

### View
- `CollectionStackCard` replaces `CollectionCover` inside `CollectionCard`
  (`Views/CollectionsRow.swift`); Collections page cell becomes square-ish
  (pile area = cardWidth × ~0.9·cardWidth), row gap opens up for the fan.
- Each card: thumbnail at its natural aspect (from the loaded `NSImage`
  size), scaled to fit ~78% of the cell. SQUARE corners (owner call — no
  rounding on the images) and a soft diffuse shadow (~12% black, radius 9;
  the darker first cut read as "unrefined").
- Hover (`.onHover` on the cell-rect `contentShape`, hit area does NOT grow
  with the fan — prevents retract flicker): spring fan-out
  (~response 0.38 / damping 0.62, visible overshoot), spring back
  (higher damping). Pile z-raises above siblings while hovered/animating.
- The dark hover veil is removed (the fan is the hover cue). Click opens
  the collection; context-menu Delete, `.help`, and the single-element
  VoiceOver treatment carry over unchanged.
- Reduce Motion: no fan — subtle static cue only.
- Active-collection accent: stroke on the top card (rarely visible; page is
  covered while a collection is active).
- Thumbnails via `ThumbnailCache` (320px probe, same as today), ≤6 per
  collection, loaded async with fade-in; `LazyVGrid` keeps off-screen rows
  unloaded.

### Out of scope
- Sidebar collection rows, in-collection header, grid tiles: unchanged.
- No new user-facing strings expected (reuse existing localized ones); any
  that do appear must be localized (EN + FR) per repo rule.

## Testing
- `StackScatterTests`: determinism (same seed/count/cell → same poses),
  pose bounds (rest offsets/rotations within spec, fan within spec),
  direction distribution (under-cards spread across sectors), count edge
  cases (1, 2, 6).
- Stack-fill logic (cover-first, dedupe, repeat-to-fill, cap 6) is a pure
  static function with its own tests.
- Visual feel: owner compares against the reference video (the acceptance
  gate for animation tuning).
