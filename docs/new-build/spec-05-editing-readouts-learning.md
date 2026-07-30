# Spec 05 — Editing Readouts, Learning Layer, Looks & LUTs

*Read with `muse-photo-foundation.md` §6. Depends on Spec 04 (engine, panels scaffolding). These are the differentiators — the pieces that serve "curious about the technical side but not fluent" and that no consumer app ships. Each item is independently shippable; build in the order below.*

## In scope

### 1. Teaching histogram (left scope panel)
- RGB histogram (not luminance-only — single-channel clipping is the classic trap it must catch), luminance overlay optional.
- **Plain-English clipping messages** under the graph (Darkroom's documented design): "Highlights are clipping — mostly the sky" beats blinkies. Message set is deterministic, derived from channel stats.
- Drag interactions (darktable pattern): drag right region = exposure, left region = black point. Optional, behind the same gesture conventions as sliders.
- Live against the current edit state; updates debounced with the render loop.

### 2. Clipping zebras (on-image)
- Over/under exposure overlays, per-channel display clipping, adjustable thresholds; toggle in the Edit toolbar. (True raw-sensor clipping only if the pipeline exposes pre-demosaic data cheaply — otherwise skip; do not fake it.)

### 3. Tone-zone control (the flagship — darktable tone-equalizer mechanic)
- Image segmented into brightness zones (approx -8…0 EV) via an edge-aware mask (guided-filter style; Metal). Zone distribution displayed as a compact strip/graph in the Light tab.
- **Direct manipulation: hover over the image → readout shows that pixel's zone; scroll to lift/drop that zone.** Sliders per zone as the accessible fallback.
- Edge-aware so lifting shadows doesn't flatten local contrast. ~2 weeks; the single most differentiating edit control in the plan.

### 4. Zone overlay (companion)
- Hover a zone in the strip → hatch matching image areas (Silver Efex pattern). Shares the tone-zone mask; days of work.

### 5. "Why it looks this way" (plain-language photo feedback)
- **Deterministic, rule-based** — NOT an LLM feature. Inputs: EXIF + computed stats (sharpness score from Spec 03, clipping %, noise estimate, histogram shape). Output: short plain sentences in the info column, e.g. "Handheld at 1/15s — motion blur likely" · "Shadows are noisy because ISO 6400" · "0.4% of pixels clipped in the red channel" · "Shot at f/1.8 — thin focus plane; check the eyes."
- Rules file is data-driven (easy to extend/localize). Tone: helpful, never judgmental. Nearly zero competition (only Adobe's experimental AI critique, may never ship). Applies in Preview mode too, not just Edit.

### 6. Looks browser (Looks tab)
- Every preset — user presets (Spec 04) + imported LUTs (below) — rendered live as a thumbnail OF THE CURRENT PHOTO in a browsable grid (PhotoDemon pattern; Apple's Filters tab at 9 looks, this at N). Render base once at ~200px, apply each recipe; cheap.
- Click applies (copy-by-value per Spec 04 rule); strength slider where the look is LUT-based.

### 7. `.cube` LUT import
- ~100-line parser (`LUT_3D_SIZE n`, n³ RGB floats, R fastest-varying; sizes 33³/64³ typical). Reference: SwiftCube (MIT) — read it, write our own.
- Feed `CIColorCubeWithColorSpace` with an explicit working color space (NEVER bare `CIColorCube` — P3 shifts); `inputExtrapolate = true` for HDR input; 0–100 strength slider (mix).
- Imported LUTs become Looks (named, in the browser); this is how film-company/camera-company look packs arrive. (Lightroom .xmp PRESET import rides the Spec-06 crs: work, not here.)

### 8. Curve panel finish
- Histogram drawn BEHIND the point curve (seam left in Spec 04) so users see where pixels live while dragging.

### 9. Reference view
- Pin any library photo beside the one being edited (Lightroom Shift+R) to match looks across a set. Days; reuses compare-mode machinery from Spec 03.

## Deferred within this area (v2 candidates, do not build now)
ΔE spot adjustment (single local tool — RT Locallab/U-Point mechanic, ~2 weeks) · waveform/RGB parade scopes · simplified 3-way grade wheels · HSL chips with image eyedropper · film-negative inversion. NEVER: full masking, CIECAM, filmic UI, dehaze.

## Binding decisions
#5 editing is user-driven; readouts serve the learning persona · #27 all new UI through the Theme layer · #24 all overlays/scopes must hold frame rate on the reference machine (they're compute shaders on the preview-res image, not full-res).

## Acceptance
- Histogram + messages update live while dragging exposure; zebras toggle correctly and match reported clipping %.
- Tone-zone: hover shows zone readout; scroll adjusts that zone; shadows lift without halos on a test set; thumbnail/screen/export consistency test still passes with zone edits.
- "Why it looks this way" produces correct sentences on a curated test set (fast shutter/low ISO → silent; 1/15s handheld → blur warning; ISO 6400 → noise note).
- 30 looks render in the browser in <1s on the reference machine.
- A commercial .cube pack imports, previews, applies with strength, and survives export identically.
