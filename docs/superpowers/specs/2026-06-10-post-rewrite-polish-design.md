# Muse post-rewrite polish — design spec

Date: 2026-06-10
Status: validated with Carlos through interactive prototypes (visual companion
session, `.superpowers/brainstorm/*/content/`). This spec records every decision
as settled there. ALL FOUR PHASES SHIPPED (P4 delights landed 2026-06-11,
`feat/delights`). The binding rewrite plan
(`docs/superpowers/plans/file-viewer-rewrite.md`) remains the base; this spec
layers the polish pass on top.

## Goals

Make Muse feel fun, fast, and loud — mymind-inspired, built for Carlos as the
primary user. Free app, zero network, no strictness about conventional
usability. Four feature areas, in priority order:

1. **The AI brain** — living collections, richer auto-tagging, semantic search
2. **The open-image moment** — hero viewer with adaptive color wash
3. **The spatial views** — cloud scatter + knowledge-graph rework of the globe
4. **The delights** — burn-up delete, background moods, polish

### Architectural constraint: AI upgrade path

Apple announced major Apple Intelligence upgrades for macOS 27 (WWDC25),
shipping a few months out. ALL intelligence features route through protocols —
never call Vision/NL/FoundationModels directly from feature code:

```swift
protocol Tagger          // image -> [Tag]  (label, kind, confidence)
protocol Embedder        // text/image -> vector
protocol Clusterer       // [item] -> [cluster] with stable identities
protocol CollectionNamer // cluster -> display name
```

Implementations register through a capability gate (same pattern as
`ChatService`). Every tag/embedding/collection row records `source` +
`model_version` so a macOS 27 adapter can be slotted in and the library
re-analyzed incrementally — no rearchitecting.

## 1. The AI brain

### Tagging (extends the existing Vision pipeline)

- Keep: classification, OCR, faces, feature prints, dominant colors.
- Add: **named colors** ("teal", "warm beige") derived from dominant-color
  extraction; **style/kind tag** (screenshot, photo, poster, illustration,
  diagram) from classifier heuristics.
- Cap stored palette at ~6 dominant colors per image.
- No limit on tag count per image. Manual tags still beat vision tags (Q32).

### Semantic search

- Each image gets an on-device embedding of its semantic document
  (tags + caption + OCR) via `NLContextualEmbedding` (v1 `Embedder`).
- Query embedding + cosine similarity, merged with FTS5: exact hits rank
  first, semantic fills out. "soccer" finds images tagged
  football/stadium/ball. Zero network.
- Embeddings stored in SQLite alongside `model_version`.

### Living collections

- A background clustering job groups images over embeddings + visual feature
  prints (hybrid). Collections form, grow, and merge automatically; zero
  maintenance. Stable identities across re-clustering.
- Names from Foundation Models when available (capability-gated), else the
  strongest shared tag. Right-click to hide a collection.
- **UI (Cosmos-style, per Carlos's reference):**
  - Featured row above the grid: top ~4 collections as cover cards
    (3-thumbnail mosaic, name, image count).
  - "All" card + **⌘K** opens a Spotlight/⌘-Tab-style overlay: the app blurs
    and darkens behind; all collections in a scrollable, arrow-key-navigable
    sheet floating above. Esc closes; click enters a collection.
  - Clicking a collection filters the current view (works in Grid, Cloud,
    and Graph).

## 2. The open-image moment (viewer)

Replaces the overlay presentation path for images; PDFs/video/etc. keep the
existing chrome. Working prototype: `docs/superpowers/assets/viewer-motion-prototype.html`
(committed copy, final state) — implementation must match its behavior and
timings. SHIPPED in polish phase 2.

### Motion

- Open: grid thumbnail flies from its exact cell to center — one continuous
  element, 0.4s, gentle ease-out (no spring overshoot). Full-res swaps in
  mid-flight.
- Close: 0.34s with a barely-perceptible settle into the cell
  (cubic-bezier ≈ (.2,1.08,.35,1)); the grid cell reappears instantly under
  the flying image (no flicker, no fade-in gap).
- Info column and chrome fade out FAST on close (~0.12s, no delay) — no
  ghosting. Fade in is slower (0.4s, 0.15s delay) for the staggered feel.
- Arrow keys flip between images; background color cross-fades.

### Background (option C, approved)

- Two layers: a true blur layer (backdrop blur ~30px, brightness ~0.5) under a
  translucent color tint = the image's dominant color darkened ~45%, alpha
  ~0.78. The grid stays faintly readable through the wash. Every image gets
  its own mood.

### Layout

- Image centered in the true viewable space between the left edge and the
  info column — equal gaps both sides at Fit. Never overlaps the info column
  at Fit (overlap while zoomed is fine). Re-fits live on window resize.
- Info column (right, ~258pt + 40pt margin): title + file info on the wash
  surface; then rounded translucent **cards**: Collection, Tags, Colors;
  then Open in Finder + Delete buttons (with folder/trash icons).
- Close ✕ top-RIGHT, right-aligned with the info cards, 18pt from top.
- Zoom pill (− / Fit / ＋ with % readout) top-LEFT of the info column,
  left-aligned with the cards, same height/top as ✕ (38pt). When zoomed:
  ✕ hides, a "Fit" button appears beside the zoom pill; at Fit it reverses.
- Scroll wheel zooms (except over the info column, which scrolls);
  drag pans when zoomed (clamped); zoom buttons never text-select.

### Tags & collections in the viewer

- Pills are clickable (filter to that tag/collection) and removable (✕ in a
  grey circle, hover state, appears on pill hover).
- **No-reflow hover rule (hard requirement):** rows wrap normally at rest;
  on hover the pill grows rightward to reveal ✕ and ONLY same-row pills
  after it condense (ellipsis) by exactly the needed amount, floor 26pt,
  truncating the hovered pill's own text as last resort. The hovered pill
  and everything before it never move; pills never change rows; row math
  uses naturals (measured at render) with max-width pinned to current width
  before animating — bounded at every frame. (This was stress-tested:
  slow sweeps, rapid sweeps, 80 random mid-animation jumps.)
- ＋ button (SVG glyph filling the button — text glyphs render off-center)
  expands the card downward with a spring: existing tags/collections as
  dashed pills (click to add) + a "create new" field with a ＋ submit button.
  ＋ rotates to ✕ while open. Card springs back when done.
- Colors card: full extracted palette, wraps if needed; each swatch copies
  its hex (toast); "copy all" copies the comma-separated set.

### Delete

- Always `NSWorkspace.shared.recycle` (Trash, recoverable) — never unlink.
- Toast: "Moved to Trash" with **Undo** (puts the file back).
- This is where the burn-up effect plays (section 4).

## 3. The spatial views

Grid / Cloud / Graph three-way toggle in the toolbar. Cloud and Graph show
whatever is currently in scope (folder, collection, search results).
SHIPPED in polish phase 3 (`docs/superpowers/plans/2026-06-11-spatial-views.md`).

### Cloud view

Final prototype: `docs/superpowers/assets/cloud-pose-prototype.html` (committed
copy; measured pose data in `docs/superpowers/assets/cloud-poses.json`). The
look is the Sternberg Press reference (`~/Desktop/MUSE APP/1.png`) — reached
only after converging on:

- A **real 3D scene**: cards are true tilted rectangles under perspective
  (per-card rx/ry/rz), giving genuine internal foreshortening. Flat
  rotated/sheared cards read as wrong immediately — do not ship that.
- The default arrangement uses the **measured poses fitted from the
  reference** (traced corners → rigid-pose fit, worst error 0.6% of canvas).
  For arbitrary item counts, generate poses with the same statistics
  (rx ±10–33°, ry ±5–30°, rz ±5–47°, sizes 4–10% of canvas width,
  flowing band composition).
- Composition locked to a fixed-aspect stage (letterboxed) so it never
  distorts with window shape.
- Soft warm shadows; barely-there drift (a few px); hover floats a card up
  flat; click opens the viewer.
- SwiftUI implementation via SceneKit (one camera) — maps 1:1 to the scene
  model.

### Graph view (replaces GlobeView)

- Zoomed out: flat 2D — collections as labeled thumbnail clusters, lines
  between collections sharing tags (knowledge-graph reading).
- Zooming into a cluster transitions to 3D: images spread spatially,
  positioned by visual similarity (feature-print distance); camera flies in.
  Hybrid logic as decided: membership = collections, internal arrangement =
  similarity.
- Zoom out flattens back. Click opens the viewer. SceneKit; the
  FibonacciSphere code retires with GlobeView.

## 4. The delights

SHIPPED in polish phase 4 (`docs/superpowers/plans/2026-06-11-delights.md`).

- **Burn-up delete:** Metal `layerEffect` (composes with the water shader):
  the thumbnail chars from the edges inward over ~0.8s with drifting ember
  particles, then the cell collapses and the file is recycled. Plays in grid
  and viewer deletes.
- **Background moods:** toolbar picker — Ink (current dark), Paper (warm
  beige, as prototyped), Navy, Blush, and **Auto** (tints from the dominant
  colors of the current view's content). Each named mood is hand-tuned so
  text/thumbnails/shaders hold up.
- **Water shader** stays as-is (kept and loved).

## Performance requirements

- Grid/cloud/graph thumbnails come from the existing 2-tier ThumbnailCache —
  views open instantly from cache.
- Analysis, embedding, clustering: background queues (Indexer actor /
  Task.detached); collections update incrementally; UI never blocks on AI.
- Viewer opens with the cached thumbnail and swaps full-res mid-flight.

## Phasing

| Phase | Contents |
|---|---|
| P1 — AI brain | Intelligence protocols + provenance schema, enriched tagging, semantic index + merged search, living collections + featured cards + ⌘K overlay |
| P2 — Viewer | Hero open/close motion, adaptive wash, info cards, tag/collection interactions, zoom/pan/Fit chrome, Delete+Undo |
| P3 — Spatial views | Cloud view (SceneKit), Graph view replacing Globe |
| P4 — Delights | Burn-up delete, background moods + Auto, final polish pass |

Each phase lands as its own branch/commits in the established convention.

## Out of scope (unchanged from rewrite plan)

Editing UI (Open With… only), network anything, onboarding, Settings pane,
saved smart searches UI, archive browsing, iCloud badges.

## Open questions

None — all decisions above were settled interactively on 2026-06-10.
