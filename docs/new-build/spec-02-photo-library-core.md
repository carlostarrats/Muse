# Spec 02 — Photo Library Core: Places, Rediscovery, Stacks, Search Phase 1

*Read with `muse-photo-foundation.md`. Depends on Spec 01 (coordinates persisted, budget harness).*

## Purpose
The features that turn Muse from "a nice grid" into a photo library: location, rediscovery, near-duplicate stacks, and the first phase of token search. This is where the app stops being comparable to inspo tools and starts being uncatchable by them.

## In scope

### 1. Places (no map — DECIDED)
- Offline reverse geocoding: bundle GeoNames cities dataset (cities1000 or cities15000, CC-BY 4.0 — attribution in About). K-d tree lookup lat/lon → city/admin/country. Runs in the analyze pass; results into a `places` table.
- **Place-grouped grid**: a Places surface listing thumbnails grouped by place name (Apple Photos "Places → Grid" pattern). Zero network. Groups ordered by photo count or recency; click-through to the filtered grid.
- `.location` case added to `SmartRule` (the enum and `SmartCollectionRulesView` are already generic — follow existing rule patterns): within-place-name and near-coordinates-radius variants.
- Viewer link-out: keep existing `OpenInMapsButton` (`maps://`); **add "Open in Google Maps" option** (URL scheme/web). No in-app map (deferred), no globe (never).

### 2. Rediscovery
- Track `lastViewedAt` per file (migration + write path on viewer open; cheap, private, local).
- Surfaces: **Rarely Seen** (coldest assets), **Shuffle/Random** browse mode, **On This Day / N years ago**. Sidebar entries following existing sidebar patterns. Queries only — no new analysis.

### 3. Near-duplicate stacks
- Cluster burst/near-identical frames: time-proximity bucket first (e.g. same 10s window), then perceptual similarity within bucket (existing feature prints / dHash — reuse duplicate-finder machinery). Time-bucketing first is the O(n²) fix.
- Grid presentation: one representative tile with a stack badge/count; click expands inline or into a strip; user can change the representative ("stack pick"), unstack, or manually stack a selection (Google Photos added manual stacking — support both auto and manual).
- Stacks are presentation-layer grouping — they must NOT alter file identity, tags, or collections membership.

### 4. Search Phase 1 — tokens over indexed metadata
- EXIF columns indexed and queryable: camera make/model, lens, ISO, aperture, shutter, focal length, flash, date, dimensions (extracted via `CGImageSourceCopyPropertiesAtIndex` in the analyze pass — no decode).
- **Custom SwiftUI token bar** (AppKit has no native token search field): typed terms become editable filter chips — `camera:`, `lens:`, `iso:>1600`, `f:<2`, `in:2019`, `near:Lisbon` (from places), `text:"…"` (FTS), `color:` (existing color search), `★≥4`, `kind:`. Free text falls through to existing semantic + FTS search. Autocomplete suggestions from actual index values (e.g. the cameras that exist in this library).
- Debounce/async everywhere; query time touches ONLY precomputed data.
- **NOT tags** (DECIDED #14): all of this is derived metadata; must work fully with tags off.

## Out of scope
CLIP/MobileCLIP upgrade, region similarity, auto-growing albums, natural-language parsing (Spec 03). Compare/culling (Spec 03). Any editing. Faces.

## Binding decisions
#13 minimal taxonomies (stacks are grouping, not taxonomy) · #14 photo info never becomes tags · #17 offline geocoding only · #18 no map now, link-out + Google Maps option · #22 analysis always on · #25 no RAM-residency assumptions (stacks clustering must be time-bucketed) · #26 new stores, AppState frozen · #27 tokenized UI (all new surfaces use the Theme layer).

## Acceptance
- 20k-photo library: Places populated fully offline; place grid opens instantly; smart collection by location works.
- Rarely Seen/Shuffle/On This Day live in sidebar; lastViewedAt updates on view.
- Bursts collapse into stacks; manual stack/unstack/pick works; no identity side effects.
- Token search returns in <100ms on the reference machine for indexed queries at 50k photos; autocomplete reflects real library values; works with tags disabled.
