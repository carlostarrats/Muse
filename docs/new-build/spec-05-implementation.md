# Spec 05 — Editing Readouts, Learning Layer, Looks & LUTs: full implementation spec

*Derived from `pre-spec-05-editing-readouts-learning.md` + `muse-photo-foundation.md`
(§6 "the distinctive layer"; §13 decision log is authoritative) + `DECISIONS.md` (the
binding build-level layer from Specs 01–04). Build-level expansion: exact files, exact
schema, exact seams, exact tests. Written before implementation. Verified against the
codebase at `cefa008` (`feat/editing`) — as of that commit **no Spec 01/02/03/04 code
exists in the tree** (migrations end at `v12_smart_collections`); everything referenced
from Specs 01–04 is referenced exactly as specified there, and every reference to
existing code was read from the actual source (`ViewerInfoColumn.swift`,
`FileMetadata.swift`, `AppSettings.swift`, `KeyCaptureView.swift`,
`ThumbnailCache.swift`, `Database.swift`).*

---

## 0. What this spec does, does not, and depends on

**Does:** the live statistics tap on the editor's render loop; the teaching histogram
(RGB + luminance, plain-English clipping messages, drag-to-adjust) in the left card's
Scopes tab; the curve panel's histogram-behind fill (the `CurveEditorView(histogram:)`
seam Spec 04 left); on-image clipping zebras with adjustable thresholds; the
**tone-zone control** (the flagship — darktable's tone-equalizer mechanic: edge-aware
per-zone exposure with hover readout + scroll-to-adjust) and its companion zone
overlay; **"Why it looks this way"** (deterministic, rule-based plain-language photo
feedback in the hero INFO column and the editor's Info tab, backed by new capture
statistics in `photo_traits` — migration **v22**); **`.cube` 3D LUT import**
(migration **v23 `edit_luts`**) with a strength slider; the **Looks browser** (every
user preset + imported LUT rendered live on the current photo, replacing Spec 04's
Looks-tab rows); and the **reference view** (pin a library photo beside the one being
edited). Two new `Adjustment` cases (`toneZone`, `lut`) extend the Spec 04 edit model,
ride sidecars, and join copy/paste/presets.

**Does not:** waveform/RGB parade scopes, ΔE spot adjustment, 3-way grade wheels, HSL
chips, film-negative inversion (all v2 candidates per the pre-spec's deferred list);
true raw-sensor (pre-demosaic) clipping (skipped, not faked — §4.4); Lightroom `.xmp`
*preset* import (rides Spec 06's crs: work); any LLM/Foundation-Models involvement in
photo feedback (the pre-spec is explicit: deterministic and rule-based); masking, CIECAM,
filmic UI, dehaze (NEVER list, foundation §6).

**Depends on:**

| Dependency | Needed by | Nature |
|---|---|---|
| Spec 04 (editor UI, `EditStack` model/codec, `EditRenderer` chain, `RenderCoalescer`, `EditSession`, Theme, the Looks tab + Scopes-tab scaffold + `CurveEditorView(histogram:)` seam, `EditKernels.metal`) | everything | **Hard.** This spec is an extension of the Spec 04 editor; nothing here builds without it. |
| Spec 02 §photo_meta (v14: `iso`, `exposure_seconds`, `f_number`, `focal_length_35mm`, `flash_fired`) | "Why it looks this way" (§6) | Hard for §6 only. |
| Spec 03 §photo_traits (v19: `sharpness`, `face_count`, `largest_face_frac`, `traits_version`) + `DeepAnalysisBackfill` + `SharpnessScore` | "Why it looks this way" (§6) | Hard for §6 only. §6 is independently shippable and simply waits if 02/03 are unbuilt; every other section has no 02/03 dependency. |
| Spec 03 compare machinery | reference view (§9) | Soft — §9 as specified reuses nothing from compare (fit-only pane); the pre-spec's "reuses compare-mode machinery" is satisfied by the shared `EditRenderer`/decode discipline, recorded as deviation D14. |

**Migration numbering:** v22 = `photo_traits` capture-statistics columns (§6) ·
v23 = `edit_luts` (§7) — separate migrations so the two features land in separate
commits without renumbering (DECISIONS house rule). v22 precedes v23 because the
pre-spec's build order puts "Why it looks this way" (item 5) before `.cube` import
(item 7). Future specs continue at **v24**.

**Independently shippable** (the pre-spec's requirement, preserved): each numbered
build-order step (§14) maps to one pre-spec item and leaves the app releasable.

---

## 1. Edit-model additions — two new `Adjustment` cases

### 1.1 The forward-evolution mechanism (how new cases land without breaking old builds)

Spec 04 §1.1 designed `Adjustment`'s explicit keyed wrapper (`{"type":…,"params":…}`)
precisely so "a future case decode-fail[s] *detectably*": on a Spec 04 build, a stack
containing `toneZone` or `lut` fails the **whole-stack** decode → renders as the
ORIGINAL image, blob preserved (the §1.6 stale/foreign-blob rule doing its designed
job). Consequences, all deliberate:

- **`schemaVersion` stays 1.** The version gates *shape* changes; a new enum case is
  the wrapper's designed evolution path, and bumping the schema would make every new
  stack (even one with no new adjustments) undecodable on Spec 04 builds for no
  reason. (Deviation D1.)
- **`currentProcessVersion` stays 1.** A process bump re-renders *existing* stacks
  differently; old stacks contain neither new case and render byte-identically —
  nothing about their semantics changed.
- **New cases are declared at the END of the enum**, after `vignette`:
  `EditStack.normalized()` sorts by declaration order, so appending keeps every
  pre-existing stack's canonical JSON — and therefore its `stack_hash` and every
  edited thumbnail's cache key — byte-identical. `EditStackCodecTests`' pinned
  fixture hash MUST NOT change; the extended test re-pins it (§13). The renderer's
  chain order is its own (§1.4) — declaration order is a hashing concern only.

### 1.2 `ToneZoneParams` (in `Editing/EditStack.swift`)

```swift
nonisolated struct ToneZoneParams: Codable, Equatable, Sendable {
    /// 9 zones, one photographic stop each, covering −8…0 EV relative to
    /// diffuse white (darktable's tone-equalizer range, per the pre-spec).
    /// gains[0] = deepest shadows (−8 EV), gains[8] = highlights (0 EV).
    static let zoneCount = 9
    var gains: [Double]              // exactly zoneCount entries, each −1…+1
    static let neutral = ToneZoneParams(gains: .init(repeating: 0, count: zoneCount))
    var isNeutral: Bool              // all gains == 0
    /// Clamps each gain to −1…+1 AND normalizes the array length: shorter pads
    /// with 0, longer truncates — a hand-edited or future-shaped sidecar can't
    /// crash the renderer or index out of bounds.
    func clamped() -> Self
}
```

Stored −1…+1 like every other scalar (DECISIONS stored-units rule); the EV mapping
lives in the renderer as a named constant (`ToneZoneMath.maxZoneEV = 2.0` — ±1 slider
↦ ±2 EV in-zone, owner-tuned per §15.1).

### 1.3 `LutParams`

```swift
nonisolated struct LutParams: Codable, Equatable, Sendable {
    /// SHA-256 hex of the LUT's canonical float bytes — the `edit_luts` PK
    /// (§7.2). A REFERENCE, not embedded data: a 64³ table is ~3 MB and the
    /// stack rides sidecars and is hashed per edit — embedding is untenable.
    /// Safe because LUTs are IMMUTABLE by construction (§7.3): re-importing
    /// the same .cube dedupes onto the same hash, and there is no edit-LUT
    /// path, so a reference can never observe a change. (Deviation D2.)
    var lutHash: String
    /// Display fallback when the LUT row is absent on this device — the
    /// missing-LUT notice (§7.6) can say WHICH file to re-import.
    var name: String
    var strength: Double = 1         // 0…1; UI shows 0–100
    var isNeutral: Bool              // strength == 0
    func clamped() -> Self
}
```

`Adjustment` gains `case toneZone(ToneZoneParams)` and `case lut(LutParams)` (in that
order, appended after `vignette`). At most one LUT per stack, like every case — the
one-per-case rule is what keeps "a look" singular; stacking LUTs is out of scope.

### 1.4 Renderer chain order (updated — code, never data)

```
1. geometry
2. tone            exposure → temp/tint (encoded only) → toneBands → contrast
2b. toneZone       edge-aware per-zone exposure, scene-referred linear (§5)
3. curve           display-referred exception (unchanged)
4. color           vibrance → saturation
4b. lut            CIColorCubeWithColorSpace + strength mix, display-referred
                   domain like the curve (§7.5)
5. presence        NR → clarity → texture → sharpen
6. vignette
7. display         (consumer-side, unchanged)
```

- **toneZone sits after tone, before the curve**: it is a scene-referred operation on
  un-clamped linear data (single per-pixel gain — hue-preserving by construction,
  same argument as toneBands), and running it post-tone means the zones the user
  hovers/adjusts are zones of the image *as currently toned* — WYSIWYG for the
  direct-manipulation loop.
- **lut sits after color, before presence**: `.cube` LUTs are authored against
  display-referred input (film-look packs assume video/sRGB encoding), so it lives in
  the display-referred pocket the curve established; sharpening/NR after the LUT is
  output-order convention (sharpen the final look), and vignette stays last.

### 1.5 `AdjustmentGroup` + transfer/preset semantics

`AdjustmentGroup` (Editing/EditTransfer.swift) gains `case toneZone`, `case lut`
(rawValues `"toneZone"`, `"lut"`). `EditTransfer.adjustedGroups`/`apply` handle them
identically to the existing groups — copy-by-value copies `ToneZoneParams` wholesale
and copies the LUT *reference + strength* (the data is immutable, so
reference-sharing cannot leak edits between photos — deviation D2's other half).

- **Presets MAY carry the lut group** — a "look" very often IS a LUT plus tweaks;
  geometry remains the ONLY preset exclusion (Spec 04 deviation D8 unchanged).
- Copy/paste group card: the two new toggles, localized `Text("Tone Zones")` /
  `Text("LUT")`.
- Batch sync (`SelectionActionsMenu` "Paste Adjustments") inherits both for free —
  no mechanics change.

### 1.6 Sidecars

Nothing structural: `toneZone`/`lut` ride `Sidecar.edit_stack` inside the stack JSON
automatically. **Recorded limitation (deviation D3):** a hydrated stack referencing a
LUT the receiving device hasn't imported renders as the ORIGINAL there (never
partial — §7.6) and heals the moment the same `.cube` is imported anywhere on that
device (hash-keyed, filename-independent). `edit_luts` data does NOT ride sidecars
(megabytes per photo); it IS in backups (the `.muselibrary` archive carries the DB).

---

## 2. The live statistics tap — `Editing/HistogramCompute.swift` + session plumbing

Everything in §3–§5 reads one shared, cheap statistics pass computed from the render
loop. One mechanism, three consumers (histogram/messages, curve-behind, zone
strip/hover) — never three parallel decodes.

### 2.1 `EditStats` (in `Editing/HistogramCompute.swift`)

```swift
nonisolated struct HistogramData: Equatable, Sendable {
    static let binCount = 64
    var r: [Float]; var g: [Float]; var b: [Float]; var luma: [Float]
    // each binCount entries, normalized so the max bin across channels == 1
}

nonisolated struct ClippingStats: Equatable, Sendable {
    /// Fixed thresholds for STORED capture stats (§6.2) — pref-independent,
    /// single declaration site. The EDITOR's live stats + zebras use the
    /// user-adjustable AppSettings thresholds instead (§4.2).
    static let storedHighThreshold: Double = 254.0 / 255.0
    static let storedLowThreshold: Double  = 2.0 / 255.0
    var highR: Double; var highG: Double; var highB: Double  // fraction ≥ high
    var low: Double                                          // fraction of luma ≤ low
    /// Row centroid of the clipped-high / clipped-low mass, 0 (top) … 1
    /// (bottom); nil when the fraction is 0. Drives the deterministic
    /// "mostly near the top of the frame" hint (§3.3) — spatial attribution
    /// from stats alone, never scene semantics.
    var highMassCenterY: Double?
    var lowMassCenterY: Double?
}

nonisolated struct EditStats: Equatable, Sendable {
    var histogram: HistogramData
    var clipping: ClippingStats
    var zoneMass: [Double]            // ToneZoneParams.zoneCount fractions, Σ ≤ 1
    var curveHistogram: CurveHistogram // Spec 04's 64-luma-bin seam type, filled here
}
```

`HistogramCompute` is a nonisolated enum of pure funcs over raw buffers
(`compute(rgba8:width:height:thresholds:) -> (HistogramData, ClippingStats)`,
`zoneMass(evMap:) -> [Double]`, `curveHistogram(from: HistogramData) -> CurveHistogram`)
— unit-tested on synthetic gradients with zero Core Image involvement. vDSP where it
helps; a 256px buffer is ~0.26 MB and a plain loop is already sub-millisecond.

### 2.2 The tap — piggybacked on `RenderCoalescer`

When (and only when) a stats consumer is visible, each **completed** coalesced
preview render additionally produces, at `statsSampleLongEdge = 256`:

1. **Display tap** — the final display-referred output rendered to an RGBA8 bitmap
   (one extra `CIContext.render(toBitmap:)` of the already-built image, downsampled;
   the context is the long-lived preview context). Feeds histogram + clipping.
2. **Zone tap** — the chain's stage-2b *input* (post-tone linear) passed through
   `ToneZoneFilter.smoothedEVMap` (§5.3) at 256px, rendered to a Float32 buffer.
   Feeds `zoneMass`, the hover readout, and the zone overlay's CPU side.

Both land on the session as one `@Published private(set) var stats: EditStats?` write
(main-actor hop after compute) plus a non-published `private(set) var zoneEVMap:
ZoneEVMap?` (`struct { width, height, values: [Float] }` — read imperatively by hover
sampling; publishing a per-render buffer would re-render panels for no reason).

**Gating (frame-rate rule, foundation #24 / pre-spec binding decisions):**
`EditSession.statsVisible: Bool`, set by panel appearance — true while Edit mode has
the Light tab (zone strip + curve) or the Scopes tab visible; false otherwise and in
Preview. False → the coalescer skips both taps entirely; zebras (§4) are a GPU
overlay in the canvas draw and need no CPU tap. Debouncing comes free: the coalescer
already renders at most one frame at a time, so stats update exactly at render
cadence ("updates debounced with the render loop", pre-spec item 1).

### 2.3 `EditSession` additions (Views/Editor/EditSession.swift)

```swift
@Published private(set) var stats: EditStats?
private(set) var zoneEVMap: ZoneEVMap?
@Published var statsVisible = false
@Published var zebrasOn = false            // §4
@Published var toneZoneTargeting = false   // §5.5
@Published var hoveredZone: Int?           // strip hover OR target hover → §5.6 overlay
```

---

## 3. Teaching histogram — the Scopes tab goes live

### 3.1 `Views/Editor/ScopesPanel.swift`

Replaces Spec 04's empty-scaffold placeholder in the left card's Scopes tab. Content,
top to bottom: `HistogramView` · the luminance-overlay toggle (a small
`Toggle(String(localized: "Luminance"))` in `theme.labelFont`) · the clipping-message
lines (§3.3). All chrome reads `@Environment(\.theme)` (Spec 04 durable constraint 8).

### 3.2 `Views/Editor/HistogramView.swift`

- Draws `stats.histogram`: three filled channel paths (R/G/B) composited
  `.blendMode(.screen)` over `theme.panelFill` — additive overlap is what makes
  single-channel clipping visible (the "classic trap" the pre-spec names RGB display
  for); the optional luminance curve draws as a neutral line on top. 64 bins, Path
  per channel, nothing fancier — this redraws at render cadence and must stay cheap.
- Fixed height `histogramHeight = 96` inside the card; no axis labels (it's a shape
  readout, not a plot — dataviz chrome would fight the panel).
- **Drag-to-adjust** (darktable's pattern; the pre-spec's optional item, included
  because it is ~30 lines on the existing gesture conventions): a horizontal
  `DragGesture` over the view; gestures beginning in the LEFT third drive
  `ToneParams.blacks`, in the RIGHT third `ToneParams.exposureEV`; the middle third
  is inert. Mapping: `ΔEV = dx × dragEVPerPoint` (0.01 EV/pt, named constant) /
  `Δblacks = dx × dragBlacksPerPoint` (0.004/pt), written to `session.draft` live,
  `session.commitGesture()` on end — one history push per drag, exactly the
  `EditSlider` contract. Cursor: `.resizeLeftRight` on hover over the active thirds.
  VoiceOver: the drag has no VO equivalent and needs none — the same parameters are
  the Light tab's accessible `EditSlider`s (the mouse-only-modifier rule's "parallel
  path" is already the primary UI).

### 3.3 Plain-English clipping messages — `Editing/ClippingMessages.swift`

Pure, deterministic, stats-only (the pre-spec: "Message set is deterministic, derived
from channel stats"). The Darkroom-style spatial flavor ("mostly the sky") is
delivered WITHOUT scene semantics via the clip-mass centroid (deviation D4):

```swift
nonisolated enum FrameRegion: Equatable { case top, middle, bottom }   // centroid ≤ ⅓ / middle / ≥ ⅔

nonisolated enum ClippingMessage: Equatable {
    case highlightsClipping(percent: Double, channel: RGBChannel?, region: FrameRegion?)
    case shadowsCrushed(percent: Double, region: FrameRegion?)
}

nonisolated enum ClippingMessages {
    static let messageFloor = 0.001          // 0.1% — below, stay silent
    static let channelDominanceRatio = 3.0   // one channel ≥ 3× the others → name it
    static func compose(_ c: ClippingStats) -> [ClippingMessage]   // 0…2 messages
}
```

- All three channels ≥ floor → one combined message; a single dominant channel →
  the per-channel form ("The red channel is clipping — 0.4% of pixels…").
- Localized display text lives in `ClippingMessage.displayText` via
  `String(localized:)` format keys (Foundation-only — legal in `Editing/`; the pure
  layer stays testable on the typed cases, per the English-host test rule).
- These messages render in the Scopes panel under the graph; they read the **live**
  editor thresholds (§4.2), so the numbers always agree with the zebras on screen.

### 3.4 Curve histogram-behind (the Spec 04 seam, closed)

`EditorView`'s Light tab passes `session.stats?.curveHistogram` into
`CurveEditorView(histogram:)` — the 64-bin backdrop draws whenever stats are live.
One line; ships with this section rather than as pre-spec item 8's separate step
(deviation D5 — same data, zero additional machinery).

---

## 4. Clipping zebras — on-image overlay

### 4.1 Kernel + canvas composite

One `[[stitchable]]` CIColorKernel `zebraStripes` added to
`Editing/Render/EditKernels.metal` (loaded by name; joins `EditKernelLoadTests`):
inputs `(image, highThreshold, lowThreshold, phase)` — a pixel with ANY channel ≥
`highThreshold` renders animated-free diagonal stripes (45°, `zebraPeriodPx = 8`,
white/red alternation from `destination.coord()`); a pixel with luminance ≤
`lowThreshold` renders blue stripes; everything else passes through. Applied in
`EditCanvasView`'s draw as the LAST compositing step over the **display-referred**
output (post tone-map) — display clipping is what the thresholds mean, and it costs
one kernel pass at canvas resolution (frame-rate rule; measured in §11).

**Raw-sensor clipping is skipped, not faked** (pre-spec's own instruction):
`CIRAWFilter` exposes no cheap pre-demosaic tap, and pretending display clipping is
sensor clipping would mis-teach the exact audience this layer serves. (Deviation D6.)

### 4.2 Toggle + thresholds

- Toggle: an editor-chrome button (glyph `circle.lefthalf.striped.horizontal`,
  `.help(String(localized: "Clipping Zebras"))`), plus the **J key** in Edit mode
  (Lightroom's clipping key) via the hero `KeyCaptureView`'s `onKey` passthrough
  (KeyCaptureView.swift:13-36 — the same extension Spec 03/04 specified; whichever
  lands first adds it). Session-scoped `session.zebrasOn`, default off, not
  persisted (an overlay left on across launches reads as a rendering bug).
- Thresholds: a small popover off the toggle (long-press/right-click) with two
  sliders — Over: 0.90…1.00, Under: 0.00…0.10 — persisted via
  `AppSettings.editorZebraHighKey` / `editorZebraLowKey` (Double accessors, defaults
  **0.98** / **0.02**, the AppSettings accessor pattern at AppSettings.swift:18-27).
- **Agreement by construction (durable):** the zebra kernel, the live
  `ClippingStats`, and the Scopes messages all read the SAME two AppSettings values —
  the pre-spec acceptance "zebras … match reported clipping %" is structural, not
  tuned. (The *stored* capture stats of §6 deliberately do NOT read these prefs —
  §2.1's fixed constants — because DB rows must not change meaning when a pref
  moves.)

---

## 5. Tone-zone control + zone overlay (the flagship)

### 5.1 Pure math — `Editing/ToneZoneMath.swift`

```swift
nonisolated enum ToneZoneMath {
    static let zoneCount = ToneZoneParams.zoneCount      // 9
    static let evFloor: Double = -8                      // zone 0 center
    static let evCeiling: Double = 0                     // zone 8 center
    static let maxZoneEV: Double = 2.0                   // gain −1…+1 ↦ ±2 EV
    /// Raised-cosine weights over EV, a partition of unity: Σ weights == 1 for
    /// every EV in range; EV below/above the range clamps to the end zones.
    static func weights(forEV ev: Double) -> [Double]
    static func zoneIndex(forEV ev: Double) -> Int
    /// Σ weights[i] × gains[i] × maxZoneEV — the per-pixel exposure offset.
    static func gainEV(forEV ev: Double, gains: [Double]) -> Double
}
```

Unit-tested exhaustively (§13); the Metal kernel mirrors these formulas, and the
render-consistency + neutrality goldens (§5.4) are what pin the two implementations
together (the `ClipTokenizer`-fixture rule class — CPU truth, GPU checked against it
through rendered output).

### 5.2 Render stage — `Editing/Render/ToneZoneFilter.swift`

Applied at chain position 2b on un-clamped linear working-space data:

1. **Guide map**: log2 luminance of the input (Rec.709 luma coefficients on linear
   RGB), computed at a working resolution of `min(inputLongEdge, 1024)` — the mask
   is low-frequency by design; full-res masks buy halos nothing.
2. **Edge-aware smoothing**: a self-guided **guided filter** over the log-lum map —
   box means via `CIBoxBlur`, the arithmetic via three small `[[stitchable]]`
   kernels (`tzSquare`, `tzLinearCoeffs`, `tzApplyCoeffs`) implementing the standard
   `a = var/(var+ε)`, `b = mean(1−a)·mean` linear-model form. Radius =
   `guidedRadiusFraction × longEdge` (named, **0.05**) — scale-normalized like every
   radius in the pipeline, which is what keeps thumbnail/screen/export agreement
   (§4.6 of Spec 04, extended here). `guidedEpsilon = 0.25` (log2-lum² units,
   named, owner-tuned). Edge-awareness is the anti-halo mechanism the pre-spec
   demands ("lifting shadows doesn't flatten local contrast"; owner validation
   §15.1).
3. **Application**: kernel `toneZoneGain(image, smoothedEV, g0…g8)` — per pixel,
   `outRGB = inRGB × exp2(ToneZoneMath.gainEV(smoothedEV, gains))`, single gain on
   all three channels (hue-preserving). Exact identity when all gains are 0 (the
   neutrality golden).
4. `smoothedEVMap(for:longEdge:) -> CIImage` is a public (module-internal) hook on
   the filter — the SAME pipeline serves the render stage, the §2.2 zone tap, and
   the §5.6 overlay; three consumers, one mask, by construction.

### 5.3 Zone strip — `Views/Editor/ToneZoneStrip.swift` (the reserved Light-tab slot)

Mounted exactly where Spec 04 §6.4 reserved it: above the Light sliders.

- A horizontal strip of 9 cells shaded black→white (the zone ramp). Behind each
  cell, a vertical bar renders that zone's mass from `stats.zoneMass` — the "compact
  strip/graph" of the pre-spec. Above each cell, a small gain handle: **vertical
  drag** on a cell adjusts `draft` toneZone `gains[i]` live
  (`dy × stripGainPerPoint`, 0.01/pt), `commitGesture()` on end.
- Hovering a cell sets `session.hoveredZone` → the §5.6 hatch overlay on the canvas
  (Silver Efex pattern) and a readout label under the strip ("Zone 6 · −3 EV ·
  12% of pixels", `theme.valueFont`).
- **Accessible fallback** (pre-spec requirement): a `DisclosureGroup(String(
  localized: "Zone Sliders"))` under the strip revealing 9 standard `EditSlider`s
  (labels "−8 EV" … "0 EV") — the VoiceOver-reachable path; the strip's drag needs
  no parallel `.accessibilityAction` because the sliders ARE the parallel path
  (the house rule satisfied by the fallback, recorded).
- Double-click a cell (or its slider label) → that zone to 0; a "Reset Zones"
  row-end button → `ToneZoneParams.neutral` (one history push).

### 5.4 Consistency + neutrality (the standing gates, extended)

- `EditRenderConsistencyTests`' all-groups fixture stack now includes a non-neutral
  `toneZone` (and `lut`, §7) — the pre-spec acceptance "thumbnail/screen/export
  consistency test still passes with zone edits" is the SAME gate Spec 04 built,
  with the new stages inside it. Tolerance unchanged (start 3/255); the guided
  radius normalization (§5.2.2) is what makes it pass.
- `EditRenderNeutralityTests` gains: zero-gain toneZone == plain decode;
  strength-0 lut == plain decode.

### 5.5 Direct manipulation — target mode (hover readout + scroll-to-adjust)

Plain scroll already zooms the canvas (Spec 04 §6.4), so scroll-to-adjust lives
behind an explicit **target mode** — the WB-eyedropper pattern, this editor's
established convention for "the next canvas interaction means something else"
(deviation D7):

- A target toggle at the strip's leading edge (glyph `dot.scope`,
  `.help(String(localized: "Adjust zones on the photo"))`) sets
  `session.toneZoneTargeting`.
- While targeting: crosshair cursor over the canvas; hover maps the cursor through
  `CanvasPointMath` (Spec 04's pure helper) into the `zoneEVMap` buffer → a floating
  readout beside the cursor ("−3.2 EV · Zone 6") and `hoveredZone` highlights both
  the strip cell and the §5.6 overlay; **scroll** adjusts that zone
  (`deltaY × scrollGainPerTick`, 0.02, natural-scroll-corrected), canvas zoom
  suspended while targeting. Gesture end = 250 ms scroll quiescence →
  `commitGesture()` (one history push per burst).
- Exits: re-click the toggle, or **Escape** — consumed FIRST in the hero's
  `viewerClosing` onChange edit-mode branch (`if session.toneZoneTargeting {
  session.toneZoneTargeting = false; return }` before `exitEditMode()`), the exact
  consume-the-trigger nesting Spec 04 §6.10 established. `EscapeResolver` unchanged.
- The readout samples the SMOOTHED EV map (not raw pixel luminance) — the number the
  user sees is the number scrolling will move, by construction.

### 5.6 Zone overlay (companion)

`hoveredZone != nil` → the canvas composites kernel `zoneHatch(image, smoothedEV,
zoneIndex)` — 45° hatch lines (`hatchPeriodPx = 10`) over pixels whose hovered-zone
weight ≥ `overlayWeightFloor = 0.5`, image dimmed 20% elsewhere so the hatch reads.
The smoothed-EV input at canvas resolution comes from `smoothedEVMap` (§5.2.4) —
shared mask, days-of-work scope as the pre-spec sizes it. Cleared on un-hover;
never rendered outside Edit mode.

---

## 6. "Why it looks this way" — deterministic photo feedback

### 6.1 What it reads (and the one schema change)

Inputs are exactly the pre-spec's list — EXIF + computed stats: `photo_meta`
(iso, exposure_seconds, f_number, focal_length_35mm, flash_fired — Spec 02 v14),
`photo_traits` (sharpness, face_count, largest_face_frac — Spec 03 v19), plus THIS
spec's capture statistics: per-channel highlight clipping, shadow crush, and a noise
estimate, computed once at analyze time (the query-time-touches-only-precomputed
rule — feedback renders in the hero INFO column, which must never trigger a decode).

### 6.2 Migration `v22_photo_stats` — columns on `photo_traits`, version bump

Spec 03 D2 designed this exact mechanism: "a future trait bumps
`PhotoTraits.currentVersion` (re-scan) rather than adding a parallel marker."
(Deviation D8 — columns ride the existing table/marker, no new table.)

```swift
migrator.registerMigration("v22_photo_stats") { db in
    try db.alter(table: "photo_traits") { t in
        t.add(column: "clip_high_r", .real)      // fraction of pixels ≥ storedHighThreshold
        t.add(column: "clip_high_g", .real)
        t.add(column: "clip_high_b", .real)
        t.add(column: "clip_low", .real)         // fraction of luma ≤ storedLowThreshold
        t.add(column: "noise_sigma", .real)      // §6.3, normalized @1024px
    }
}
```

- `PhotoTraits.currentVersion` **1 → 2**. Existing rows are version-behind →
  `DeepAnalysisBackfill`'s stale-by-any-marker selection re-scans them under the
  standing `maxPerLaunch = 5_000` cap (a 50k library refills across ~10 launches —
  the notes appear progressively; recorded, not a bug). No new backfill, no new
  marker, no index (nothing queries these columns per-keystroke).
- Compute sites (both ride the existing single decode — never a second decode):
  `AnalyzePipeline.analyzeOne`'s traits fill (the Spec 03 `TraitFields` write) and
  `DeepAnalysisBackfill`'s per-file pass. `TraitFields`/`VisionResult` gain
  `clipHighR/G/B, clipLow, noiseSigma` (all `Double?`); clipping fractions via
  `HistogramCompute` over the decoded raster's channels using
  `ClippingStats.storedHighThreshold/storedLowThreshold` (§2.1 — fixed constants,
  never the zebra prefs); nil on degenerate input.
- `PhotoTraitsRow` gains the five fields.

### 6.3 `Intelligence/Core/NoiseEstimate.swift`

```swift
nonisolated enum NoiseEstimate {
    static let normalizedLongEdge = 1024     // same normalization as SharpnessScore
    /// Robust noise sigma: median absolute deviation (×1.4826) of the 3×3
    /// Laplacian response over the flattest half of 32×32 tiles (gradient-
    /// ranked) of the luminance plane, downsampled to ≤ normalizedLongEdge.
    /// Restricting to flat tiles is what separates noise from texture.
    /// nil for degenerate (≤ 64px) input.
    static func sigma(_ cgImage: CGImage) -> Double?
}
```

vImage grayscale + convolve, the `SharpnessScore` implementation family (Spec 03
§3.1); ~5 ms at 1024px inside the existing pass.

### 6.4 `Editing/PhotoFeedback.swift` — the rule table

```swift
nonisolated enum PhotoFeedback {
    struct Inputs: Equatable, Sendable {     // every field optional; absent data never faked
        var iso: Int?; var exposureSeconds: Double?; var fNumber: Double?
        var focalLength35: Double?; var flashFired: Bool?
        var sharpness: Double?; var faceCount: Int?
        var clipHighR: Double?; var clipHighG: Double?; var clipHighB: Double?
        var clipLow: Double?; var noiseSigma: Double?
    }
    enum Note: Equatable, Sendable {
        case clippedHighlights(percent: Double, channel: RGBChannel?)
        case crushedShadows(percent: Double)
        case motionBlurRisk(shutterSeconds: Double)
        case highISONoise(iso: Int, wellControlled: Bool)
        case softFocus
        case thinFocusPlane(fNumber: Double, hasFaces: Bool)
        var displayText: String              // String(localized:) format keys
    }
    static let maxNotes = 3
    static func notes(for inputs: Inputs) -> [Note]
}
```

Rules — each a named-constant threshold, one declaration site, owner-tuned (§15.2);
fixed severity order **clipping → shadows → motion blur → noise → soft → thin
focus**, capped at `maxNotes`:

| Note | Fires when | Constants | Sample copy (localized format keys) |
|---|---|---|---|
| clippedHighlights | max channel clip ≥ `clipNoteFloor = 0.002`; channel named when ≥ `channelDominanceRatio`× the others | | "0.4% of pixels are clipped in the red channel — those areas have lost detail." |
| crushedShadows | clipLow ≥ `shadowNoteFloor = 0.02` | | "Deep shadows cover 3% of the frame — some shadow detail is gone." |
| motionBlurRisk | `exposureSeconds ≥ max(1/focal35, 1/handheldFallbackFocal)` (reciprocal rule; `handheldFallbackFocal = 50` when focal is unknown), **suppressed when `flashFired == true`** (flash freezes the subject) | | "Handheld at 1/15 s — motion blur is likely." |
| highISONoise | iso ≥ `noiseISOFloor = 3200`; `wellControlled` when noiseSigma exists and < `noiseSigmaQuiet` (owner-tuned) softens the phrasing | | "Shadows are noisy because ISO 6400." / "…ISO 6400, though noise is well controlled here." |
| softFocus | sharpness ≤ `SharpnessScore.softCeiling` AND no motionBlurRisk note (cause beats symptom — never double-diagnose one blur) | | "This photo is soft — focus may have missed." |
| thinFocusPlane | fNumber ≤ `thinApertureCeiling = 2.0`; the faces variant when faceCount ≥ 1 | | "Shot at f/1.8 — a thin focus plane; check the eyes." |

- **Silent case is a feature**: fast shutter / low ISO / no clipping → `[]` → the
  card doesn't render (the pre-spec acceptance's explicit row).
- Tone: helpful, never judgmental — the copy above is the register; French pass
  reviews phrasing (§15.2).
- **The rule table is Swift-declared, not an external data file** (deviation D9):
  the pre-spec's "rules file is data-driven (easy to extend/localize)" collides with
  the localization pipeline — `xcstrings` extraction cannot see external files, and
  a JSON of English sentences would ship unlocalizable. The table delivers the
  intent (one declaration site, add-a-row extensibility) inside the catalog's reach.
- **Deterministic, never an LLM** — restated as a durable constraint (§12.4).

### 6.5 Data plumbing — `Database/PhotoStatsQueries.swift`

Nonisolated enum (the `NoteStore` shape): `feedbackInputs(fileID: String,
db: GRDB.Database) -> PhotoFeedback.Inputs?` — one read joining `photo_meta` +
`photo_traits` by PK. Called inside the hero's existing details load
(`HeroImageViewer.loadDetails`, HeroImageViewer.swift:510 — already an off-main
async pass) and passed down as a plain value.

### 6.6 Surfaces

- **Hero INFO column (Preview mode — the pre-spec's "applies in Preview mode
  too")**: a new collapsible card in `ViewerInfoColumn` between the INFO card and
  the actions row (ViewerInfoColumn.swift:87-90), title
  `CardLabel(text: String(localized: "WHY IT LOOKS THIS WAY"))`, one row per
  `Note.displayText` in the card's body style. Omitted entirely when notes are
  empty (like the metadata card at :87). Expansion is a GLOBAL last-choice —
  `AppSettings.feedbackCardExpandedKey`, default true, plain-`@State`-seeded like
  `colorsExpanded` (:63-70; the `@AppStorage`-inside-`withAnimation` trap is
  documented there). New `ViewerInfoColumn` param `feedbackNotes:
  [PhotoFeedback.Note] = []`.
- **Editor left card, Info tab**: the same note rows appended under the existing
  EXIF summary — and, for RAW sources, the **process line** Spec 04 §4.5 promised
  this spec would surface: "Process: RAW decoder v9" or, on substitution,
  "Process: RAW decoder v9 (this Mac renders with v8)" — read from
  `rawParams.decoderVersion` vs the live `supportedDecoderVersions`, the
  recorded-not-hidden rule made visible.
- Kinds: wherever the data exists (image/raw/psd have traits; video has
  `photo_meta` only) — the empty-notes rule gates naturally; no explicit kind gate.

---

## 7. `.cube` LUT import

### 7.1 Parser — `Editing/CubeLUT.swift` (pure, zero dependencies)

Written fresh against the Adobe/Resolve `.cube` conventions; SwiftCube (MIT) is the
read-for-reference implementation per the pre-spec — read, not copied.

```swift
nonisolated struct CubeLUT: Equatable, Sendable {
    let size: Int                    // 2…CubeLUTParser.maxSize
    /// size³ × 3 floats, R fastest-varying (the .cube spec's storage order,
    /// pinned by an asymmetric fixture test). Values may exceed 0…1 (some
    /// looks lift beyond the domain; CIColorCube tolerates it).
    let data: [Float]
    var canonicalData: Data          // float32 LE bytes of `data` — the hash input
    static func hash(_ lut: CubeLUT) -> String   // SHA-256 hex, CryptoKit
}

nonisolated enum CubeLUTParser {
    static let maxFileBytes = 64 * 1024 * 1024   // a 128³ text cube ≈ 50 MB; beyond is not a LUT
    static let maxSize = 128                     // CIColorCube's documented ceiling
    enum ParseError: Error, Equatable {
        case tooLarge, notA3DLUT, badSize
        case badValue(line: Int), wrongCount(expected: Int, got: Int)
        case unsupportedDomain
    }
    /// TITLE "…" is returned as the default display name.
    static func parse(_ text: String) throws -> (lut: CubeLUT, title: String?)
}
```

Grammar handled: `#` comments · `TITLE` · `LUT_3D_SIZE n` · `DOMAIN_MIN`/`DOMAIN_MAX`
(accepted at the default 0 0 0 / 1 1 1 within 1e-4; anything else →
`unsupportedDomain` — resampling a non-default domain would silently misrepresent
the look, and commercial packs overwhelmingly ship the default; recorded limitation,
deviation D10) · `LUT_1D_SIZE` → `notA3DLUT` (clear error: "This is a 1D LUT — Muse
imports 3D .cube files"). Exactly n³ data lines of 3 floats; errors carry line
numbers.

### 7.2 Migration `v23_edit_luts`

```swift
migrator.registerMigration("v23_edit_luts") { db in
    try db.create(table: "edit_luts") { t in
        t.column("id", .text).primaryKey()       // CubeLUT.hash — content-addressed
        t.column("name", .text).notNull()        // user-renameable display name
        t.column("size", .integer).notNull()
        t.column("data", .blob).notNull()        // canonicalData: float32 LE RGB, R fastest
        t.column("created_at", .integer).notNull()
    }
}
```

Library-global like `edit_presets` (a LUT is a look, not a per-file fact); no file
cascade. Record: `EditLutRow` (the `EditPresetRow` shape; `data` excluded from the
store's listing fetch — §7.4). Content-addressed PK = re-importing the same pack
dedupes for free and renames never re-key stacks (name is display-only).

### 7.3 Immutability rule (what makes the reference model safe)

There is NO update path for LUT data: import inserts (`INSERT OR IGNORE` on the
content hash), rename touches `name` only, delete removes the row. A
`LutParams.lutHash` therefore either resolves to byte-identical data forever or to
nothing — reference semantics with value guarantees. (Deviation D2.)

### 7.4 `Models/LutStore.swift` (Pattern B) + import UX

```swift
@MainActor final class LutStore: ObservableObject {
    static let shared = LutStore()
    struct Listing: Identifiable, Equatable { let id, name: String; let size: Int; let createdAt: Int64 }
    @Published private(set) var luts: [Listing] = []      // name COLLATE NOCASE order; no data resident
    func reload() async
    func importCubes(at urls: [URL]) async -> [String: Error]   // per-file failures by filename
    func rename(id: String, to: String) async
    /// Stacks referencing this LUT keep their blobs (never rewritten — the
    /// §1.6 rule); they render as originals until the LUT returns.
    func delete(id: String) async
    /// COUNT of edits + edit_versions + edit_presets whose stack JSON contains
    /// the 64-hex id (LIKE '%<id>%' — unambiguous at that length) — shown in
    /// the delete confirm.
    func referenceCount(id: String) async -> Int
}
```

- Import entry: the Looks tab's "Import LUTs…" button → `NSOpenPanel`
  (`allowedContentTypes: [UTType(filenameExtension: "cube")!]`, multi-select —
  a user-initiated powerbox read, no new sandbox surface). Name = `TITLE` ??
  filename stem. Failures surface via the `MuseAlert` seam, one card listing the
  failed filenames + reasons.
- Delete confirm (`MuseAlert`): "Used by N edited photos — they'll show their
  originals until this LUT is imported again." Zero AppState integration beyond the
  standing alert seam.

### 7.5 Render stage + `Editing/LutRegistry.swift`

```swift
nonisolated enum LutRegistry {
    static let cacheLimit = 8            // decoded LUTs are MB-scale; never library-resident
    /// RGBA float32 cube data ready for CIColorCube (alpha appended), cached
    /// LRU. Miss → one sync queue.read of the blob. NEVER call on the main
    /// thread (render paths only — coalescer actor, thumbnail pipeline,
    /// export); the read is small but it is I/O.
    static func rgbaCube(for id: String) -> (size: Int, data: Data)?
    static func invalidate(_ id: String)         // on delete/import
}
```

Chain stage 4b (encoded and RAW sources alike — post-demosaic, display-referred
pocket):

- `CIFilter.colorCubeWithColorSpace` — `cubeDimension = size`, `cubeData` = the
  registry's RGBA buffer, **`colorSpace` explicitly sRGB** (NEVER bare
  `CIColorCube` — the P3-shift bug the foundation names; same explicit-space
  discipline as the curve), **`extrapolate = true`** (HDR headroom survives the
  table, per the pre-spec).
- Strength: kernel `lutMix(base, lutted, strength)` in `EditKernels.metal` —
  `mix(base, lutted, s)`; strength 1 bypasses the mix, strength 0 is neutral
  (normalized away).

### 7.6 The missing-LUT rule (unrenderable, never partial)

`EditRenderer.canRender(_ stack:)` extends to: `processVersion ≤ current` **AND
every `lut` reference resolves via `LutRegistry`**. An unresolvable LUT therefore
renders the ORIGINAL image everywhere — thumbnails, hero, exports (`OutputRender`'s
"renderable → render, else identity" branch already does the right thing) — never a
stack-minus-the-LUT (Spec 04 §1.6's never-partial rule; silently dropping the look
IS changing the photo). The blob is never rewritten; import of the matching `.cube`
heals every referencing photo at once (`markContentChanged` for affected paths +
`EditStore.generation` bump on import).

Editor UX on an unresolvable LUT: the session opens normally; the canvas shows the
original; a notice row pinned atop the right card — `"This edit uses a LUT that
isn't on this Mac ('Kodak 2383'). The photo shows unedited until it's imported."` +
an **Import…** button (the §7.4 panel). Removing the LUT from the draft is an
explicit user edit and re-renders the rest of the stack immediately.

---

## 8. Looks browser — the Looks tab goes live

### 8.1 `Views/Editor/LooksBrowserView.swift`

Replaces Spec 04's name-row list in the right card's Looks tab (the tab + 
`EditPresetStore` are Spec 04's scaffolding, kept):

- A two-section thumbnail grid — **Presets** (`EditPresetStore.presets`) and
  **LUTs** (`LutStore.luts`) — every entry rendered live on THE CURRENT PHOTO
  (PhotoDemon's pattern; "Apple's Filters tab at 9 looks, this at N"). Thumb size
  `looksThumbLongEdge = 200` points of cell, names beneath in `theme.labelFont`.
- **Click applies**: a preset via `EditTransfer.apply(groups: adjustedGroups(preset),
  from: preset, onto: draft)` (copy-by-value, Spec 04 durable constraint 5); a LUT
  by writing `lut(LutParams(lutHash:name:strength: current ?? 1))` into the draft.
  Either path ends in `session.commitGesture()` — one undo step.
- The applied LUT look shows a **strength `EditSlider`** (0–100 display) pinned
  under the grid — visible only while the draft carries that LUT ("strength slider
  where the look is LUT-based"; presets have no strength — they are value-copies,
  and partial application is copy/paste's job).
- Management (context menus, actions preserved from Spec 04's rows): presets —
  Apply / Update from This Photo / Rename / Delete; LUTs — Rename / Delete (the
  §7.4 confirm). "Save Preset…" and "Import LUTs…" buttons in the tab footer.
- A selected/active look shows a checkmark badge when the draft currently matches
  it (`EditTransfer` equality on the look's groups) — cheap, and it answers "which
  look is this?" at a glance.

### 8.2 Thumbnail rendering — latest-wins, base-decoded-once

The browser's render loop (an actor-confined helper in the view file, the
`RenderCoalescer` pattern — no new module):

1. Decode the base proxy ONCE: bounded decode of the original at
   `looksThumbLongEdge × 2` px (retina) through `ThumbnailCache.withinDecodeBudget`
   (ThumbnailCache.swift:469 — automatic-decode rule), then apply the DRAFT's
   geometry group only → the base `LinearImage` (thumbs show the current crop —
   what clicking would actually produce).
2. Per look, build the candidate stack (§8.1's apply semantics, in-memory) and run
   `EditRenderer.apply(candidate, to: base, sourceLongEdge: effective)` → render
   via the preview context → CGImage. ~N cheap 200-px chains; **30 looks < 1 s on
   the reference machine is the acceptance row** (§11).
3. Recompute triggers: tab appear · preset/LUT list change · draft change debounced
   `looksRefreshDebounce = 400 ms` (matching the autosave debounce — a slider drag
   re-thumbs once, not per tick). Latest-wins: a newer trigger abandons the stale
   sweep between items.
4. Thumbs are session-memory only — never `ThumbnailCache`, never disk, no
   `renderedVariants` entry (they are per-draft ephemera; caching them would need
   stack-hash × look keys for zero reuse).

---

## 9. Reference view

### 9.1 `Models/EditReferenceStore.swift` (Pattern B, memory-only)

```swift
@MainActor final class EditReferenceStore: ObservableObject {
    static let shared = EditReferenceStore()
    @Published var url: URL?             // the pinned library photo; nil = none
    @Published var paneVisible = false   // editor pane toggle, app-run scoped
}
```

Never persisted (a stale reference across launches is noise; LR's is session-scoped
too). Zero AppState integration.

### 9.2 Choosing the reference

Grid context menu: **"Use as Reference Photo"** in `SelectionActionsMenu`
(Views/SelectionMenu.swift — beside the existing single-file actions), visible for a
single image-kind selection (`fileURLs` guard pattern; hidden otherwise, never
disabled). Sets `EditReferenceStore.shared.url` and shows a toast. The workflow is
deliberate: pick the finished frame as reference FIRST, then open each photo to
match it — there is no in-editor picker in v1 (the editor owns the whole window;
a mini-grid inside it is real scope for marginal gain — deviation D14).

### 9.3 The pane

- Editor chrome toggle (glyph `photo.on.rectangle`, `.help(String(localized:
  "Reference Photo"))`): enabled when `url != nil` (disabled state's help text:
  "Right-click a photo in the grid → Use as Reference Photo"). Toggles
  `paneVisible`.
- Visible → the canvas region splits `[reference | working]` (the ⌘Y side-by-side
  geometry, reused): the reference pane renders its photo **through its own edit
  stack** via `EditRenderer.render(url:stack:maxPixel:)` (the consumer-sweep durable
  constraint — a reference with Muse edits must look like it looks everywhere else),
  bounded to the pane size, fit-only. No zoom/pan sync in v1 (matching looks is a
  global-color judgment; recorded). Filename chip in the pane corner,
  `theme.labelFont`.
- The pane never blocks editing — all panels/controls operate on the working image;
  before/after modes (`⌘Y`, wipe) temporarily replace the split (one comparison at a
  time; `compareMode != .off` hides the reference pane until it returns to `.off`).

---

## 10. What Spec 05 explicitly does NOT change

- The hero open/close choreography, Escape resolution order, and every Spec 04
  editor guard — new Escape consumers nest INSIDE the existing edit-mode branch
  (§5.5), `EscapeResolver` untouched.
- `EditStack` schema/process versions (§1.1), the codec's canonical-bytes rule, and
  every pre-existing stack's hash (pinned).
- The renderer's contexts, coalescer, proxy ladder, HDR handling, RAW neutralization
  — new stages slot into the existing chain; no context or decode-budget change.
- `AnalyzePipeline` claim gates, hash-capture, guarded writes — §6.2's fields ride
  the existing traits write and backfill untouched in structure.
- Search: no `lut:`/`edited:`/feedback tokens; no smart-rule cases. `SearchFacets`
  reads nothing new.
- Sidecar merge/resolve rules (Spec 04 §2.3) — the stack JSON simply carries more
  cases.
- The status pill (background-work-only rule): looks-browser sweeps, stats taps, and
  LUT imports report nothing to it.
- `renderedVariants` — no new thumbnail sizes anywhere in this spec.
- `AppState` — zero new `@Published`; the three new stores (`LutStore`,
  `EditReferenceStore`, plus session state) follow Pattern B with zero integration
  cost.

---

## 11. Performance

Additive `PerfBaseline` rows (record, never assert — house rule):

| Metric | Budget | How |
|---|---|---|
| Stats tap per coalesced render (256 px, both taps) | ≤ 3 ms | coalescer timestamps, Scopes visible |
| Zebra overlay cost per canvas draw (canvas res) | ≤ 4 ms | canvas draw timing, on vs off |
| toneZone stage overhead in a 24 MP proxy render | ≤ 15 ms | consistency-fixture stack ± toneZone |
| Zone overlay (hatch + smoothed map @ canvas res) | ≤ 8 ms | hover on vs off |
| Looks browser: 30 looks full refresh | < 1 s | acceptance row; sweep timestamps |
| `.cube` 64³ parse + hash + insert | < 300 ms | import path timing |
| LUT stage overhead (cache-warm) in a proxy render | ≤ 5 ms | fixture stack ± lut |
| `DeepAnalysisBackfill` v2 throughput (traits + stats + noise) | ≥ 8 files/s | unchanged Spec 03 row re-measured |

Frame-rate discipline (foundation #24 / pre-spec binding decision), restated as
build rules: every overlay (zebras, hatch) is one kernel pass on the ≤-canvas-res
image; every CPU statistic reads a ≤ 256 px buffer; stats compute only while a
consumer is visible; the guided-filter working map caps at 1024 px. Nothing in this
spec touches a full-resolution raster outside the existing render/export paths.

---

## 12. New durable constraints (added to `CLAUDE.md`)

1. **New `Adjustment` cases append at the END of the enum, never mid-list** —
   canonical order is declaration order, so insertion re-keys every edited
   thumbnail and breaks `stack_hash` stability (the pinned-fixture test is the
   tripwire). The renderer's chain order is independent and lives in code.
2. **Stacks reference LUTs by content hash; LUT rows are immutable** (import
   dedupes onto the hash, rename is display-only, no update path). A stack whose
   LUT is unresolvable is UNRENDERABLE — it renders the ORIGINAL everywhere
   (`canRender` includes LUT resolvability), never a partial stack, and the blob is
   never rewritten; importing the matching `.cube` heals it. `LutRegistry` is
   render-path-only — never call it on the main thread.
3. **Zebras, the live clipping stats, and the Scopes messages read the SAME two
   AppSettings thresholds** — their agreement is structural; don't fork a constant.
   The STORED capture stats (`photo_traits.clip_*`) use the fixed
   `ClippingStats.stored*` constants and must never read user prefs — DB rows can't
   change meaning when a slider moves.
4. **Photo feedback is deterministic and rule-based, never an LLM** — a
   Swift-declared threshold table (`PhotoFeedback`), computed from precomputed
   columns only (the surface renders in the INFO column and must never trigger a
   decode or query-time analysis). The silent case (nothing noteworthy → no card)
   is part of the design.
5. **Editor statistics run only while a consumer is visible, at
   `statsSampleLongEdge`, piggybacked on the coalescer** — never a second render
   loop, never full-res, never in Preview mode. Overlays are single kernel passes
   at canvas resolution (the frame-rate rule as a build constraint).
6. **Tone-zone direct manipulation is a target mode (the WB-eyedropper pattern)**:
   plain scroll keeps zooming the canvas; Escape consumes targeting INSIDE the
   edit-mode branch before exiting to Preview (`EscapeResolver` untouched). The
   hover readout samples the smoothed mask EV — the number shown is the number
   scrolled.
7. **`EditRenderConsistencyTests`' all-groups fixture includes every renderable
   group, current and future** — a new chain stage lands inside the standing
   thumbnail/screen/export gate in the same commit, or it doesn't land.

---

## 13. Tests

All pure-logic (house convention; no UI unit tests). New files:

| File | Covers |
|---|---|
| `ToneZoneMathTests` | weights are a partition of unity across the EV range; end-zone clamping; `zoneIndex` mapping; `gainEV` linearity + zero-gain identity; `clamped()` pads/truncates wrong-length gains |
| `CubeLUTParserTests` | sizes 2/33/64 parse; **R-fastest order pinned via an asymmetric fixture**; TITLE + comments; default DOMAIN accepted, non-default → `unsupportedDomain`; `LUT_1D_SIZE` → `notA3DLUT`; wrong count / bad value with line numbers; > maxSize; > maxFileBytes; hash stability on a fixture (pinned hex) |
| `LutRegistryTests` | RGB→RGBA conversion correctness; LRU + `invalidate`; missing id → nil (in-memory GRDB queue) |
| `LutStoreTests` | import dedupes by hash (same bytes, two names → one row, first name kept); rename display-only (id stable); delete; `referenceCount` across edits/versions/presets |
| `HistogramComputeTests` | synthetic ramps → exact expected bins; clip fractions exact on constructed buffers; centroid → `FrameRegion` mapping; `zoneMass` on a synthetic EV ramp; `curveHistogram` derivation |
| `ClippingMessagesTests` | floor silence; combined vs dominant-channel selection at `channelDominanceRatio`; region phrasing presence/absence; at most 2 messages |
| `PhotoFeedbackTests` | the curated matrix (pre-spec acceptance): fast shutter + low ISO + clean → `[]`; 1/15 s handheld → motionBlurRisk; flash suppresses it; ISO 6400 → noise note, `wellControlled` variant; soft suppressed when motion-blur fires; thin-plane faces variant; severity order; `maxNotes` cap; nil-field tolerance (absent data never fires a rule) |
| `NoiseEstimateTests` | synthetic Gaussian noise → sigma recovered within tolerance; textured-but-clean image scores below noisy-flat (the flat-tile restriction pin); resolution normalization (1× vs 4× within band); degenerate → nil |
| `PhotoStatsMigrationTests` | v22 runs clean on a v21-shaped library; version bump makes existing `photo_traits` rows version-behind (backfill selection picks them up); existing row values untouched; idempotent re-migrate |
| `EditLutMigrationTests` | v23 clean on v22; idempotent; content-addressed PK conflict = ignore |
| `PhotoStatsQueriesTests` | `feedbackInputs` join shape; missing meta/traits rows → partial Inputs, never a throw |
| `EditStackCodecTests` (extended) | `toneZone`/`lut` round-trip; **the pre-existing fixture stack's pinned hash is UNCHANGED** (the append-only tripwire); wrong-length `gains` decode → normalized; unknown type still fails whole-stack |
| `EditTransferTests` (extended) | `adjustedGroups` sees both new groups; lut copy carries hash + strength; presets may include lut, still exclude geometry |
| `EditRenderConsistencyTests` (extended) | the all-groups fixture stack gains non-neutral `toneZone` + `lut` (fixture LUT registered in-memory) — the standing 3-resolution gate |
| `EditRenderNeutralityTests` (extended) | zero-gain toneZone ≡ plain decode; strength-0 lut ≡ plain decode |
| `EditKernelLoadTests` (extended) | `zebraStripes`, `zoneHatch`, `toneZoneGain`, `tzSquare`, `tzLinearCoeffs`, `tzApplyCoeffs`, `lutMix` all load by name |

Existing suites that must stay green and are touched: `EditStackNormalizeTests`
(new cases in canonical order), `EditSidecarTests` (stack JSON with new cases
round-trips the sidecar fields), `EditRecordStoreTests` (unchanged semantics,
re-run), Spec 03's traits/backfill suites (selection now version-2-aware),
`EditingModuleImportTests` (every new `Editing/` file obeys the no-AppKit rule —
`PhotoFeedback`, `HistogramCompute`, `ClippingMessages`, `CubeLUT`, `ToneZoneMath`,
`LutRegistry` are all Foundation/CoreGraphics/CoreImage only).

---

## 14. Build order

Each step ships independently (the pre-spec's per-item shippability, preserved;
order is the pre-spec's, with the one recorded fold-in):

0. **Model additions** (§1): `ToneZoneParams`/`LutParams`, enum cases appended,
   groups, codec/transfer/normalize test extensions incl. the hash-stability pin —
   pure, invisible.
1. **Stats tap + teaching histogram + curve-behind** (§2, §3): `HistogramCompute`,
   session plumbing, `ScopesPanel`/`HistogramView`, clipping messages, drag-to-
   adjust, `CurveEditorView(histogram:)` filled. (Pre-spec items 1 + 8 — the curve
   fill is one line on this data; deviation D5.)
2. **Zebras** (§4): kernel, toggle + J key, threshold popover + AppSettings keys.
3. **Tone-zone** (§5.1–5.5): math, guided filter, render stage, consistency/
   neutrality extensions, zone strip, target mode.
4. **Zone overlay** (§5.6): hatch kernel + hover wiring.
5. **"Why it looks this way"** (§6): v22 + version bump, `NoiseEstimate`, traits
   fill + backfill fields, `PhotoFeedback`, `PhotoStatsQueries`, hero card + editor
   Info rows + RAW process line. (Blocks on Specs 02/03 being built; the only step
   that does.)
6. **LUT import** (§7): parser, v23, `LutRegistry`, `LutStore`, render stage,
   missing-LUT UX, import panel.
7. **Looks browser** (§8): browser grid replacing the Looks rows, live thumbs,
   strength slider, management menus.
8. **Reference view** (§9): store, context-menu entry, chrome toggle, pane.
9. **Docs** (`CLAUDE.md` §12 constraints + phase-table row; `architecture-map.md`;
   `session-log.md`; DECISIONS.md refresh) + localization export pass
   (`xcodebuild -exportLocalizations … fr` → 0 untranslated — new strings: the two
   group toggles, Scopes/zebra/zone-strip chrome, clipping messages, feedback
   sentences, LUT import/delete/missing copy, Looks-tab buttons, reference-view
   items, the feedback card title).

---

## 15. Owner-only steps

1. **Tone-zone feel + halo validation on a real test set** — `maxZoneEV`,
   `guidedRadiusFraction`, `guidedEpsilon`, strip/scroll sensitivities are named
   constants expected to move (the Surface "baby steps" precedent); the pre-spec
   acceptance "shadows lift without halos" is a visual judgment only the owner
   makes, on real backlit/high-contrast photos.
2. **Feedback thresholds + copy review** — `noiseSigmaQuiet` needs calibration
   against real high-ISO files (§6.4); sentence tone ("helpful, never judgmental")
   and the French phrasing are editorial sign-offs.
3. **Commercial `.cube` pack acceptance** (the pre-spec's explicit row): import a
   purchased pack, browse it in Looks, apply with strength, export, and verify the
   export matches the canvas (the consistency gate covers it mechanically; the
   owner verifies on the real pack).
4. **Frame-rate on the M1 Air 8 GB**: slider drag with Scopes open + zebras on +
   zone strip visible must hold the editor's feel; commit the §11 PerfBaseline
   report.
5. **Zebra defaults sanity** (0.98/0.02) on real skies/shadows; adjust the shipped
   defaults if they chatter.
6. Looks-browser visual sign-off (cell size, sections, checkmark affordance) and
   the zone strip's handle ergonomics.

---

## 16. Deliberate deviations from the source specs

Recorded so they read as decisions, not drift:

1. **`schemaVersion` stays 1 for the new adjustment cases** — the keyed wrapper's
   unknown-type whole-stack decode failure is Spec 04's DESIGNED forward mechanism
   (§1.1 there); a schema bump would gratuitously break every new stack on Spec 04
   builds. Old builds render new-case stacks as originals, detectably. §1.1.
2. **LUTs are referenced by content hash, not embedded, and LUT rows are
   immutable** — embedding megabytes in every stack/sidecar/hash is untenable;
   immutability (content-addressed PK, no update path) restores value semantics to
   the reference, so copy-by-value discipline survives intact. §1.3, §7.3.
3. **A hydrated stack referencing an un-imported LUT renders as the original on
   that device until the `.cube` is imported** (hash-keyed heal) — recorded
   limitation, same class as device-local versions/snapshots. §1.6.
4. **"Mostly the sky" ships as a stats-only spatial hint** (clip-mass row centroid →
   top/middle/bottom phrasing) — the pre-spec requires deterministic
   channel-stats-derived messages; scene recognition would be neither. §3.3.
5. **The curve histogram-behind (pre-spec item 8) ships inside the histogram step**
   — it is one line on the same `EditStats` data; a separate build item would be
   ceremony. §3.4.
6. **Raw-sensor clipping zebras are skipped, not approximated** — per the
   pre-spec's own "do not fake it"; `CIRAWFilter` exposes no cheap pre-demosaic
   tap. §4.1.
7. **Scroll-to-adjust zones lives behind an explicit target mode** — plain scroll
   already zooms the canvas (Spec 04); the WB eyedropper established the
   editor's convention for reassigning canvas input. §5.5.
8. **Capture statistics ride `photo_traits` + a `currentVersion` bump** — Spec 03
   D2 designed exactly this evolution ("a future trait bumps the version rather
   than adding a parallel marker"); no new table, marker, or backfill. §6.2.
9. **The feedback "rules file" is a Swift-declared table, not an external data
   file** — `xcstrings` extraction cannot see external files; the table keeps the
   data-driven intent (one site, add-a-row) inside the localization pipeline. §6.4.
10. **Non-default `DOMAIN_MIN/MAX` cubes are refused with a clear error** —
    resampling would silently misrepresent the look; commercial packs ship the
    default domain. Recorded limitation. §7.1.
11. **Presets may carry the lut group** — a look is very often LUT + tweaks;
    geometry remains the only preset exclusion. §1.5.
12. **Looks thumbnails render the draft-plus-look** (not the bare original) — the
    browser previews what clicking produces, including the current crop; thumbs
    are session-ephemera, never cached to disk. §8.2.
13. **Zebra state is session-scoped; only its thresholds persist** — an overlay
    that survives relaunch reads as a rendering bug. §4.2.
14. **The reference photo is chosen from the grid, not an in-editor picker, and
    the pane is fit-only with no zoom sync** — v1 scope; the pre-spec's "reuses
    compare-mode machinery" is satisfied by the shared render/decode discipline
    rather than a dependency on Spec 03's compare surface. §9.
15. **Histogram drag-to-adjust is included** (the pre-spec marks it optional) — it
    is ~30 lines on the established gesture contract, and the accessible parallel
    path (the Light sliders) already exists. §3.2.

---

## 17. Acceptance mapping (from `pre-spec-05-editing-readouts-learning.md`)

| Acceptance item | Where satisfied |
|---|---|
| Histogram + messages update live while dragging exposure | §2.2 tap piggybacked on every coalesced render; §3.1–3.3; measured §11 |
| Zebras toggle correctly and match reported clipping % | §4.2 shared-threshold agreement by construction (durable constraint §12.3) |
| Tone-zone: hover shows zone readout; scroll adjusts that zone | §5.5 target mode; readout samples the smoothed mask EV |
| Shadows lift without halos on a test set | §5.2 guided-filter edge-aware mask; owner step §15.1 |
| Thumbnail/screen/export consistency test still passes with zone edits | §5.4 — `EditRenderConsistencyTests` extended, the standing gate |
| "Why it looks this way" correct on the curated matrix (fast/low → silent; 1/15 handheld → blur; ISO 6400 → noise) | §6.4 rule table + `PhotoFeedbackTests` (the matrix is the test) |
| 30 looks render in the browser in < 1 s on the reference machine | §8.2 base-once + 200 px chains; §11 row; owner-verified §15.4 |
| A commercial .cube pack imports, previews, applies with strength, and survives export identically | §7 parser/registry/stage + §5.4 consistency gate incl. lut; owner step §15.3 |
