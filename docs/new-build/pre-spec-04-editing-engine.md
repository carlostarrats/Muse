# Spec 04 — Editing Engine, Core Adjustments, Editor UI

*Read with `muse-photo-foundation.md` (§3 and §6 especially). Depends on Spec 01 (cache/geometry seams, render choke point). Estimated 3–5 weeks. The readouts/learning layer is Spec 05 — this spec is the engine + standard controls.*

## Purpose
Real, user-driven, non-destructive editing (manual sliders — NOT a preset pack; explicitly decided). Originals never touched; edits in DB + sidecars, never written into image files (EXIF/XMP-write stays rejected).

## Model (port from Surface Camera, extend)
Port `PhotoRecipe`/`ToneAdjustments`/`EditHistory`/`RecipeAdjustmentData` patterns from `Surface Camera/Packages/SurfaceCore` — versioned Codable, back-compat decoding that never bumps version, session undo/redo stack.

```swift
struct EditStack: Codable {
  var schemaVersion: Int
  var processVersion: Int      // NEVER mutate old stacks; RAW v9 (macOS 27) drops params — old stacks keep old semantics; explicit badged opt-in upgrade
  var rawParams: RawParams?
  var adjustments: [Adjustment]// fixed order, enum-tagged. NOT reorderable (NEVER)
  var masks: [Mask]            // empty in v1; slot reserved
}
```
- Storage: GRDB `edits` table, one JSON blob per (file, parent_dir — consistent with tag scoping), `stack_hash` column feeding the Spec-01 thumbnail-cache keying. Mirrored into `.muse` sidecars (mobile-later prerequisite).
- Virtual copies: multiple stacks per photo; grid shows a stacked version badge (digiKam pattern); persistent (never session-only).
- Every scale-dependent parameter normalized as a fraction of image long edge (Surface's grain-cell lesson). **Required test: thumbnail/screen/export renders of the same stack agree at multiple resolutions.**

## Pipeline (Core Image + Metal; zero third-party image deps — GPL is banned, full OSS audit in foundation §6)
- Linear, extended-range working space, explicit at every boundary; port Surface's `WorkingSpaceImage` type-safety pattern (Encoded/Linear with a single crossing).
- **Scene-referred**: adjustments on un-clamped data; single display transform at the end. Highlight recovery must actually recover (Surface's clamp-before-tone ordering is the documented mistake — do not repeat).
- **RAW hybrid split**: `CIRAWFilter` params for demosaic-stage ops (WB via neutralTemperature/Tint, highlight recovery, boost/baselineExposure, sharpness, luminance NR, `isLensCorrectionEnabled`); generic CIFilter chain on `outputImage` for the rest. Neutralize Apple's default look for the editing base (`baselineExposure=0; shadowBias=0; boostAmount=0; localToneMapAmount=0; isGamutMappingEnabled=false` — WWDC21 §10160). Never WB post-demosaic with `CITemperatureAndTint`. Gate every RAW param on `isSupported(option:)`; opt into decoder `.version9` where available.
- HDR/EDR: load `.expandToHDR`; no 1.0 clamps; `CIToneMapHeadroom` before display; export round-trips the gain map.
- Live canvas: persistent `MTKView` + long-lived `CIContext(cacheIntermediates: true)` at screen resolution via `scaleFactor`; separate export context (`cacheIntermediates: false`, memoryLimit 512–1024MB); export via `heifRepresentation`/`jpegRepresentation`; Extended Virtual Addressing entitlement; debounced/coalesced slider renders (Surface's per-tick re-render is the anti-pattern).
- Known filter gaps: point curve → CPU monotone-cubic spline → 1024-entry LUT → `CIColorCurves` (`CIToneCurve` is unusable: 5-pt cap, black-output bug). Clarity/Texture → one shared Metal blend kernel (midtone-weighted local contrast). Kernels in `[[stitchable]]` MSL, never CIKL.

## v1 adjustment set
Tone: Exposure, Contrast, Highlights, Shadows, Whites, Blacks · Color: Temperature, Tint (+eyedropper), Vibrance, Saturation · Presence: Clarity, Texture, Sharpen, Noise Reduction · Curve: point tone curve RGB + per-channel (histogram behind it — the drawing lands in Spec 05, leave the seam) · Geometry: crop, straighten, rotate, flip, aspect presets · Character: Vignette · RAW: auto lens-correction toggle · Workflow: per-slider reset, edit history.

## Before/After suite (DECIDED, required)
Hold-to-peek original · ⌘Y side-by-side · split-wipe with draggable divider · **snapshots** (freeze states, compare any two via wipe). Implementation: cached rendered textures + mask composite — cheap.

## Copy/Paste/Sync + user presets (DECIDED, required v1)
- Copy adjustments → paste to selection with **partial selection** (tone/color/crop groups). Default: auto-select only what was actually adjusted (Capture One pattern — NOT a 60-checkbox wall). Batch sync across a selection.
- **User presets = named recipes. Application is COPY-BY-VALUE**: applying copies values into the photo's stack; later slider tweaks touch only the photo, never the preset. Preset mutation is a separate explicit action ("Update preset from this photo" / "Save as new"). This rule is non-negotiable — it delivers "adjust for one image without changing the preset" automatically.

## Editor layout (validated sketch — build this)
- Double-click → hero viewer (exists). **(Preview | Edit) segmented control top-center.** Enter Edit: image shrinks slightly (mode transition), backdrop becomes controllable neutral — default 18% gray, right-click cycle white/light/mid/dark/black (Lightroom convention).
- **Anchored floating panels**: visually detached cards (shadow/margin), positionally FIXED with snap-back if dragged. NOT free-floating (Pixelmator Pro abandoned floating palettes for exactly the occlusion/drift reasons). Internal tabs allowed.
- Right, tabbed: **Light** / **Color** / **Looks** (Looks tab populated in Spec 05). Left: scopes + info + history/snapshots (scope internals in Spec 05; panel scaffolding here).
- All chrome through the Theme token layer (Decision #27).

## Edit-a-Copy (external editors — DECIDED)
On Open With when Muse edits exist: explicit fork **Edit Original / Edit a Copy with Muse Adjustments**. Copy = rendered with stack applied, written next to the original (naming pattern spec'd, collision-safe), handed to the chosen app, and **ingested back into the library stacked with its parent** (watch the folder; Peakto's one-way round-trip is the trust-killer to avoid). This permanently answers masking/healing/layers requests.

## Out of scope
Readouts/histogram/tone-zone/looks-browser/.cube (Spec 05) · import of other apps' edit values (Spec 06) · social export (Spec 07) · masking, healing, layers, AI selection, dehaze, lens-profile DB, own demosaic (NEVER list, foundation §6).

## Binding decisions
#5–#11 (editing model, two-path, before/after, copy/paste, presets) · #24 M1 floor (60MP file editable on M1 Air 8GB without beachball — screen-res preview, tiled export) · #26 own module/store, AppState frozen · #32 no GPL.

## Acceptance
- Non-destructive: original bytes untouched; revert always available; edits survive file moves (content-hash identity) and app restarts; sidecars carry stacks.
- Thumbnail/screen/export consistency test passes at 3 resolutions.
- RAW: blown-highlight recovery demonstrably works on a test DNG; v9 opt-in on macOS 27, graceful on 14.6.
- Slider-to-render < 50ms perceived at screen res on reference machine; 60MP export completes without memory pressure kill.
- Copy/paste/sync across 200 frames works with partial selection; preset apply-then-tweak never mutates the preset.
- Edit-a-Copy round-trips through Affinity/Preview and the copy appears stacked with its parent.
