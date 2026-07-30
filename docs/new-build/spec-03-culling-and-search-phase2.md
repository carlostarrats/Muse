# Spec 03 — Culling & Search Phase 2 (CLIP, Similarity, Compare, Faces-lite)

*Read with `muse-photo-foundation.md`. Depends on Spec 01; pairs with Spec 02 (token bar, stacks).*

## Purpose
The workflow photographers actually run after a shoot (pick the keepers), plus the semantic-search upgrade to the Angles-app bar: text-to-image, image-to-image, find-similar-in-region — all local, instant at 10k+.

## In scope

### 1. Semantic engine upgrade (replaces NLEmbedding path)
- **MobileCLIP** (Core ML). ⚠️ GATE: apple/ml-mobileclip code is MIT but WEIGHTS are under Apple's ML Research Model TOU — legal read required before shipping in a paid app; fallback is self-converted OpenCLIP ViT-B/32 (clean license). Pick S2-class model (~3.6ms/image on ANE).
- Model downloaded on-demand (not bundled — keep the app lightweight, DECIDED #26); indexing in the existing analyze pass; embeddings 512-d float16 BLOBs in GRDB.
- Retrieval: brute-force cosine via Accelerate at design-center scale (50k ≈ 50MB RAM, ms-level). Structure the store so it can go memory-mapped/sqlite-vec at the 200k+ tier WITHOUT rewrite (no RAM-residency assumptions — DECIDED #25).
- One embedding space serves text→image AND image→image (search-by-image = embed the image).

### 2. Region similarity ("find similar inside a photo" — the Angles feature)
- In the viewer: select/drag a region → embed the crop → search the library with it. Result surface = the standard grid. ~Small work on top of (1); high demo value. Pairs with existing color search.

### 3. Auto-growing albums
- New `SmartRule` type: embedding query — "similar to these N photos" (centroid of their embeddings) or a text prompt, with a similarity threshold slider. Collection re-evaluates as new photos are analyzed. Plain-language naming/UI — no invented vocabulary.

### 4. Natural-language search (macOS 26+ enhancement layer)
- Foundation Models `@Generable` guided generation parses free-form phrases ("beach photos last summer with lots of red") into the structured `SearchQuery` (dates, place, camera constraints, semantic text). **Result ALWAYS rendered as visible, editable tokens** — never a black box. Token grammar remains the primary path; below macOS 26, free text just goes to CLIP+FTS as before.

### 5. Compare & culling
- **Side-by-side compare** (2-up minimum; 3–4-up nice-to-have): decode at higher `kCGImageSourceThumbnailMaxPixelSize` in compare mode specifically (this answers the old "previews only" objection). Synchronized zoom/pan. Keyboard-driven: arrows swap candidates, stars apply from keyboard.
- **Focus peaking overlay**: port `PeakingOverlay.swift` from Surface Camera (155 LOC; high-pass + `CIColorThreshold`; input must be display-referred — keep its doc note). Toggle in compare and viewer.
- **Sharpness badge**: Laplacian-variance (or Vision-assisted) sharpness score per photo, surfaced as a subtle badge in compare/culling contexts (FastRawViewer/Narrative Select precedent). Computed in analyze pass.
- **Ephemeral cull state** (DECIDED #13): keep/reject pass state during a culling session; resolves to stars and/or trash on completion, then disappears. NOT a persisted taxonomy, NOT flags, NOT tags.

### 6. Faces-lite (detection, NOT identity — DECIDED #16)
- Vision face detection in analyze pass (public API, App Store-safe): face count, has-faces, portrait-vs-group, face quality. Search tokens: `faces:>2`, `portrait`, etc. Pets: Vision animal detection → `pets` filter.
- NO identity/clustering/naming (deferred project — AuraFace path documented in foundation §4; do not use InsightFace/EdgeFace — non-commercial licenses).

## Out of scope
Editing (Specs 04–05). Named people. Map. Import surfaces.

## Binding decisions
#15 search bar: accurate + instant at 10k+; precompute-everything rule · #16 faces detection-only now · #22 analysis always on (new analyzers join the same always-on pipeline + the Spec-06 time-estimate FYI covers their cost) · #24 M1 Air 8GB budgets apply (ANE-friendly models, fp16, throttle on battery) · #25/#26 as always.

## Acceptance
- Text search "dog on a beach" returns correct results in <300ms perceived at 50k photos (reference machine); image-drop search works; region similarity works from the viewer.
- Auto-growing album fills as new matching photos are imported.
- NL phrase becomes visible editable tokens on macOS 26; degrades gracefully below.
- Compare mode: two 24MP photos side by side, synchronized zoom, peaking toggle, star from keyboard; cull session ends with stars/trash applied and no residual state.
- `faces:>2` token filters correctly on a real library.
