# Galaxy View — Design

**Date:** 2026-06-12
**Status:** Approved, ready for implementation

## Summary

Replace the current collection-cluster "graph" view (`AppState.ViewMode.graph`)
with a spatial **galaxy**: a pseudo-3D cloud of image thumbnails positioned by
their learned relationships (visual look + semantic meaning + color), so similar
images cluster together. Grid and Cloud view modes are unchanged.

## Scope (which images)

- The images in the **currently selected folder**; when the **Show subfolders**
  toggle (`appState.showSubfolders`) is on, include everything nested under it.
- Same image set the grid shows for that folder, so the galaxy stays in sync as
  the user navigates the sidebar.
- Only **analyzed** images participate (they need a Vision feature print and/or
  text embedding). If fewer than ~2 analyzed images are in scope, show a short
  message ("Analyze this folder to see the galaxy") instead of an empty scene.

## Positioning engine

For the in-scope images, build a **blended pairwise distance** from data already
persisted per image:

- **Visual** — Vision feature print (`files.feature_print`): how images *look*.
- **Semantic** — text embedding (`embeddings.vector`): what they're *about*
  (tags + caption + OCR).
- **Color** — palette distance (`files.palette`).

```
distance(i,j) = 0.5 * visual + 0.4 * semantic + 0.1 * color
```

Weights are starting constants, exposed for tuning by feel. Each component is
normalised to a comparable 0–1 range before weighting. If an image is missing a
component (e.g. no embedding), that term is dropped and the remaining weights are
renormalised for that pair.

The distance matrix is projected to **3D** via stress-relaxation (the existing
`SimilarityLayout` approach, extended to the whole in-scope set), **seeded** so
the layout is stable every time the same set is opened. Computed **off the main
thread**; the finished cloud appears with a quick fade-in — no physics-settle
animation ("instant, no settle").

**Performance.** The matrix is O(n²); comfortable to ~1,000–1,500 tiles. Above a
cap, fall back to the most-recently-modified N images and **surface** that the
view was limited (a small banner/log — never a silent truncation).

## Look (pseudo-3D)

- SceneKit, perspective camera. Near tiles render larger and brighter, far tiles
  smaller and dimmer (subtle depth fade / fog).
- Backdrop = the current **mood palette background** (`appState.moodPalette`),
  so the galaxy matches the app theme (can be light or dark).

## Overlays

- **Cluster labels.** Images are grouped (clustering over the blended distance,
  reusing `HybridClusterer` where practical). Each cluster gets a **billboarded**
  text label at its centroid showing its **dominant tag** (most common
  high-confidence tag among members).
- **Constellation lines.** Each tile links to its 1–2 nearest neighbours, drawn
  only when similarity clears a threshold; faint, with a global cap on line count
  to avoid clutter.
- Label and line colors **auto-adapt** to the mood background's luminance (light
  on dark themes, dark on light).

## Interaction

- **Drag** → orbit/tumble the cloud.
- **Scroll / pinch** → zoom (dolly through depth).
- **Click a tile** → open it in the existing hero viewer, using `SceneProjection`
  to pass the on-screen tile rect so the zoom-from-tile animation works.
- **Click empty space** → deselect.
- **Hover** → tile brightens slightly.

## Components

- **`GalaxyModel`** — gathers per-image vectors/palette/tags for the in-scope
  file set, builds the blended distance matrix, clusters, and produces cluster
  labels + nearest-neighbour edges. Pure data; testable in isolation.
- **`GalaxyLayout`** — blended distance → seeded 3D positions (stress
  relaxation). Pure function; deterministic.
- **`GalaxyView`** — SceneKit host: builds the scene from model + layout, applies
  thumbnails, renders depth/overlays, handles gestures and tile open.

Reuses: `SimilarityLayout`, `SeededRandom`, `SceneProjection`, `ThumbnailCache`,
`VectorMath`, `HybridClusterer`, and the per-image DB rows in `Records.swift`.

`ContentView` routes `.graph` → `GalaxyView`. The old `GraphView`, `GraphModel`,
and `GraphLayout` are retired.

## Edge cases

- No folder selected → "Select a folder" (consistent with the grid).
- Folder with < 2 analyzed images → "Analyze this folder to see the galaxy".
- Images in scope but none analyzed yet → same analyze prompt.
- Scope larger than cap → render most-recent N + surface the limit.
