# Editor adjustments batch — design

*2026-08-02. Six editor features in three stages, plus one dead-code deletion.
Derived from an audit of what the editing engine already supports but never
exposes. Companion finding — search-token discoverability — is deliberately
NOT in this spec; it gets its own.*

---

## 1. Why this exists

An audit of `Editing/` against `Views/Editor/` found two adjustment groups
that are plumbed end-to-end — model, renderer, codec, preset carry, copy/paste
— and that **no view can write**:

| Group | Model | Renderer | Writers found |
|---|---|---|---|
| `GeometryParams` | `EditStack.swift:406` | `EditRenderer.swift:142` | `LightroomEditMapper.swift:72` (import), `ExportCard.swift:290` (social crop) — no editor UI |
| `VignetteParams` | `EditStack.swift:442` | `EditRenderer.swift:85` | none; `LooksBrowserView.swift:108` only **resets** it |

A mechanical sweep (every top-level type checked for references outside its
own file; every non-View function checked for external callers) found no other
orphaned type, and three dead functions covered in §7.

Four further features are wanted and sit on the "v2 / deferred" list in
`docs/new-build/muse-photo-foundation.md`, not the NEVER list: auto-tone,
HSL, split toning, grain.

### Out of scope — permanently

`foundation.md:243` is the NEVER list and this spec does not touch it:
masking/brush systems · healing beyond a dust-spot clone · layers · **AI
subject/sky selection** · camera calibration · manual lens-distortion sliders ·
dehaze · parametric curve alongside the point curve · reorderable stack · own
demosaic · anything GPL · a custom Metal pipeline replacing Core Image.

Subject/sky masking, background removal and AI spot removal were raised and
are **declined on that basis**. The stated answer is Path B: Open With ▸ Edit a
Copy with Muse Adjustments, which hands the rendered file to an external editor
and brings the result back stacked with its parent (`foundation.md:168`).

Also out of scope, deferred by owner: **colored borders / framing**. It is
export furniture, not an edit — if built it belongs in `OutputRender` / social
export, never in the adjustment stack.

Also declined: **graduated density** (masking-adjacent) and **channel mixer /
monochrome** (deprecated in darktable itself; 80% of the value already arrives
via `.cube` LUTs plus split toning).

---

## 2. Binding constraints

These are not suggestions. Each one is enforced by an existing test or an
existing comment that this work must not falsify.

**C1 — Reuse, don't invent.** Every control in Stages A and B must be an
existing component. The inventory in §3 is the complete permitted set. Exactly
one new interactive control is authorized in this spec: the crop drag overlay
(§6).

**C2 — `Adjustment` cases APPEND, never insert.** `EditStack.swift:225`
declares `canonicalIndex` 0–7. The three new cases take **8 (`hsl`), 9
(`splitTone`), 10 (`grain`)**. Inserting mid-list re-keys every edited
thumbnail's `stack_hash` in every library.

**C3 — No version bump, and no migration.** Stacks are JSON blobs in the
existing `edits` table, so nothing schema-side changes. `schemaVersion` stays 1
(the shape is unchanged; the enum gains members). `processVersion` stays 1
(existing parameters still produce identical pixels). An older build decoding a
stack containing `.hsl` throws on the unknown `type` and therefore renders the
**original** with the blob preserved — that is the designed forward-compat
mechanism (`EditStack.swift:260`), not a bug to work around.

**C4 — The scale rule.** Every radius is `fraction × sourceLongEdge`, scaled by
the actual decode ratio (`EditRenderer.swift:18`). A fixed pixel radius makes a
thumbnail and an export disagree. `EditRenderConsistencyTests` is the gate.

**C5 — Originals are never written.** Edits are parameters. Nothing in this
spec opens a user file for writing, including auto-inset on straighten (§6.4),
which writes a `crop` value and nothing else.

**C6 — Localization.** Every new user-facing string is localized. SwiftUI
text-literal positions auto-extract; anything passed as a `String` (menu item
titles, custom-view `label:` params, dynamic accessibility strings) must be
hand-wrapped in `String(localized:)`. Run `-exportLocalizations` for `fr` and
finish at 0 untranslated.

**C7 — `EditorCanvasGeometry` owns canvas geometry in POINTS.** The crop
overlay maps through it. No point→pixel conversion may be reintroduced in the
renderer; the view's aspect equals the image's aspect and must not change on
resize (`feat/next-150`).

**C8 — Warning-free Release build.** Keep it that way.

---

## 3. The reuse inventory (C1's permitted set)

| Need | Component | Where it already lives |
|---|---|---|
| Collapsible card | `EditorSection(title:ink:accessory:summary:isExpanded:)` | `EditorPanel.swift:78` |
| Any scalar control | `EditSlider(label:value:range:neutral:onCommit:)` | `EditSlider.swift:16` |
| Boolean row | `EditToggleRow` | `EditSlider.swift:78` |
| Card-header button (Auto, Reset, Apply) | `EditorSmallButton` via the `resetButton(_:action:)` pattern | `EditorView.swift:757` |
| Toggling a canvas mode | `EditorToolRow` with `isActive` | `EditorView.swift:610` (Side by Side, Split Compare) |
| In-header segmented pair (HSL tabs) | `stylesModeButton` | `EditorView.swift:850` |
| On-canvas colour pick | `WBEyedropperButton` + session picker plumbing | `WBEyedropperButton.swift` |
| Card open/closed persistence | `expansion(Section.x)` | `EditorView.swift` |
| Colour + WCAG AA contrast | `panelTheme` / `PanelContrast.Ink` | `Components/PanelContrast.swift` |
| One undo step per gesture | `session.commitGesture()` | `EditSession.swift` |
| Deterministic hashing | `SeededRandom` / `fnv1a` | `Components/SeededRandom.swift` |

`EditSlider` already carries double-click-to-neutral on the whole label row,
history push on gesture **end** rather than per tick, and a VoiceOver
`accessibilityAdjustableAction` that pushes history like a real drag. Nothing
may re-implement those.

---

## 4. Stage A — finish what's built

No new `Adjustment` cases. No new render code. No migration.

### 4.1 EFFECTS card (vignette)

New `EditorSection` on the right panel, below COLOR, titled **EFFECTS**. Named
for plain language rather than foundation's "Character", consistent with
SCOPES→HISTOGRAM and "Why it looks this way"→INSIGHTS. Grain joins it in
Stage B.

Three `EditSlider`s bound through `setVignette`, plus the standard per-card
Reset in the `accessory` slot:

| Control | Range | Neutral |
|---|---|---|
| Amount (negative darkens) | −1…+1 | 0 |
| Midpoint | 0…1 | 0.5 |
| Feather | 0…1 | 0.5 |

`VignetteParams.isNeutral` is `amount == 0`, so midpoint/feather at any value
with amount 0 stores nothing. The renderer applies geometry first and vignette
last, so the vignette is **post-crop** automatically — the correct behavior,
already free.

New `Section` case for expansion persistence.

### 4.2 Auto-tone

**Two buttons, not one.** Per-card Reset is deliberately scoped — "undoes that
group and nothing else, so fixing the colour doesn't cost you the tone work"
(`EditorView.swift:755`). A button in LIGHT that silently changed COLOR would
break that convention. So each card gets an **Auto** `EditorSmallButton` beside
its Reset, matching its Reset's scope:

- **Auto in LIGHT** → writes `exposureEV`, `contrast`, `blacks`, `whites`
- **Auto in COLOR** → writes `temperature`, `tint`

Each is one `commitGesture()`, therefore one undo step, and every value it
picks lands on a slider the user can immediately drag. Nothing is hidden.

**It needs its own statistics pass.** `EditSession.stats` cannot be reused:
it is tapped from the **rendered** image (`EditSession.swift:280`) and gated on
`statsVisible`, so it measures the current draft rather than the original and
is absent entirely when the Histogram card is collapsed. Reusing it would make
a second press compound its own output, and would make the button a no-op with
a collapsed card.

Instead: a new pure `AutoToneStats` computed over the **original** decode at
`statsSampleLongEdge` (256), cached once per photo on the session. This makes
Auto **idempotent** — always measured from the original, so pressing it twice
gives the same answer, and pressing it after manual tweaks recomputes from the
original and overwrites (the Lightroom behavior).

It needs finer bins than the shipped histogram: a 0.1% black-point percentile
cannot be read off 64 bins of ~4% width. `AutoToneStats` declares its own bin
count; `HistogramData.binCount` is **not** changed, as three consumers depend
on it.

Algorithm — deterministic arithmetic, no model:
- black/white points from percentile-clipped luma → `blacks`, `whites`
- mean luminance vs. target mid-grey → `exposureEV`
- inter-percentile spread → `contrast`
- grey-world channel-mean neutralization → `temperature`, `tint`

Lives beside `HistogramCompute` and is unit-tested the same way, on synthetic
gradients.

---

## 5. Stage B — three appended cases

Each is a new `Adjustment` case (C2), a new `[[stitchable]]` kernel in
`EditKernels.metal` beside the existing six, a new `AdjustmentGroup` case in
`EditTransfer` so copy/paste and batch sync carry it, and UI assembled from §3.

A nil kernel (broken metallib) must **skip its stage** rather than crash, as
`applyTone` already does (`EditRenderer.swift:184`).

### 5.1 HSL / colour zones — `.hsl`, index 8

Lightroom's model, because it is the one people have seen. Eight hue bands —
red, orange, yellow, green, aqua, blue, purple, magenta — each with hue-shift,
saturation and luminance. Presented inside COLOR as three tabs of eight
`EditSlider`s, the tab switcher being the `stylesModeButton` in-header pattern
(its own comment records why it sits in the heading: inside the card it pushed
every row down). Plus an on-canvas eyedropper reusing `WBEyedropperButton`'s
plumbing to select the band under the cursor.

One Metal `CIColorKernel`, scene-referred, rendered **after** saturation and
**before** the LUT.

### 5.2 Split toning — `.splitTone`, index 9

Shadow hue + saturation, highlight hue + saturation, balance. Five
`EditSlider`s under HSL in COLOR — no hue wheel and no gradient track, because
darktable's own split toning is exactly this: hue and saturation sliders with
numeric readouts. `EditSlider`'s `%.2f` readout already matches.

Display-referred, so it renders **after the curve and the LUT**, in the same
pocket and for the same reason (`.cube` packs and hand-drawn curves are both
authored against display encoding).

### 5.3 Grain — `.grain`, index 10

Amount, size, roughness. Three `EditSlider`s in the EFFECTS card beside
vignette. Rendered **last**, after vignette.

Two hard requirements, both from prior art rather than taste:

1. **Cell size is normalized**: `(1.5 + 4.5 · size) · longEdge / 4032`, the
   formula already recorded at `foundation.md:92`. This is C4 applied.
2. **The noise field is deterministically seeded from the file's content
   hash** via `SeededRandom`/`fnv1a`, so the grid thumbnail, the screen preview
   and the export produce the *same* grain rather than three different random
   fields.

**Grain renders in grid thumbnails.** Surface dropped grain from previews;
`foundation.md:97` states Muse cannot: "the grid IS the product — an edit must
render identically at thumbnail, screen, and export." Grained photos therefore
cost slightly more to thumbnail. Accepted, not worked around.

Grain gets its own `EditRenderConsistencyTests` case asserting preview/full
agreement at multiple resolutions.

---

## 6. Stage C — the crop card

Self-contained: it appends nothing to the enum and adds no kernel, so it can
slip or be cut without touching A or B. Sequenced **last** for exactly that
reason.

### 6.1 Shape

A CROP `EditorSection` on the left panel beside TOOLS. Contents:

- **Enter Crop** — an `EditorToolRow` with `isActive`, a third canvas mode
  alongside the existing Side by Side and Split Compare (`EditorView.swift:610`).
  Not a new interaction pattern.
- **Aspect menu** — §6.2
- **Portrait / Landscape** — an `EditorToolRow` that swaps w:h on the selected
  ratio, so 16:9 and 9:16 are one entry. Disabled for Original, Freeform and
  Square, which have no orientation to swap.
- **Straighten** — `EditSlider`, ±45, matching `GeometryParams.clamped()`
- **Rotate left / Rotate right** — `EditorToolRow`s → `quarterTurns`
- **Flip horizontal / Flip vertical** — `EditorToolRow`s → `flipH` / `flipV`
- **Apply** — an `EditorSmallButton` in the section's `accessory` slot,
  appearing only when the pending rect differs from the stored one.
  `EditorSection` already renders `accessory` conditionally. Committing writes
  `setGeometry`, calls `commitGesture()` once, and leaves crop mode.

### 6.2 Aspect menu

Labelled by **both** destination and ratio at equal weight — a photographer
scans for "3:2", someone posting scans for "Story & Reel", and neither should
have to decode the other:

```
  Original
  Freeform
  ────────────────────────────
  Square                   1:1
  Instagram Post           4:5
  Story & Reel            9:16
  Print 4×6                3:2
  Print 8×10               5:4
  Camera Default           4:3
  Video / Widescreen      16:9
```

The two social rows read their display names from `SocialPreset.nameKey`, so
the crop menu and the export card cannot drift apart. **The name is shared,
not the geometry** — `SocialPreset` is not otherwise imported. Its four
remaining presets are deliberately mostly `longEdge` with no aspect at all
(`SocialPreset.swift:42`), and coupling to that table would fight the reasoning
that produced the cut from twelve to four.

Worth one line of card copy: `ig-story` is a fixed 1080×1920 and Polish 30
replaced its interactive crop-drag with an automatic centred crop — so cropping
to 9:16 here makes that automatic crop a no-op and keeps framing under the
user's control.

### 6.3 The overlay — the one new control

A port of Surface Camera's `CropFrameOverlay` (`App/Photo/CropFrameOverlay.swift`,
255 lines), whose rect convention is **already identical to Muse's**:
normalized, top-left origin, y down. `EditRenderer.swift:152` anticipates this
feature by name — "Getting this wrong crops the wrong band and looks like an
off-by-one in the editor's crop handles."

Ported as-is: eight grab targets (four thick corner brackets, four shorter
mid-edge bars), even-odd-filled dimming so the discarded area reads as
discarded while the kept area stays at full brightness, generous hit slop
around thin marks, one `onCommit` per completed drag.

Adapted: `SC.ColorToken.captureAccent` → `panelTheme.selectionInk`; iOS drag →
macOS drag with hover cursors; positioned by `EditorCanvasGeometry` in point
space (C7).

Its pure drag math lands in `Components/` as a unit-tested helper, which is
what that folder is for. Surface's `CropGestureState` is the model for the
split.

### 6.4 Framing behaviour

**While crop mode is active the canvas renders the image with `crop` forced to
`.full`**, so you frame against the whole picture and can pull the frame back
out to reclaim area — the Apple Photos behaviour, and the trick Surface already
uses (`CropGeometry.withFullRect()`). One line in the session's render path.

**Straighten auto-insets the crop.** `applyGeometry` rotates then crops with no
inset (`EditRenderer.swift:144-163`), so straightening at full frame leaves
transparent wedges in the corners. Adobe documents that Lightroom auto-adjusts
the crop to avoid empty corners as you rotate; Apple Photos does the same. Muse
follows.

Implementation: **the crop card computes the inset rect and writes it into
`crop`.** The renderer is untouched, and `appliedDisplaySize` keeps reporting
the true post-crop size to the grid.

This is not destructive (C5). It changes a parameter, not a file. Every step is
reversible: re-entering crop mode shows the whole photo again, dragging the
frame out returns the area, double-clicking the straighten slider restores full
frame in one gesture, per-card Reset restores the group, and export always
renders from the original.

### 6.5 Known consequence — the grid reflows

`EffectiveDimensions` already feeds tile aspect, hero flight and the Info card
from `geometryParams.appliedDisplaySize`. That seam was built for this, so the
moment crop is reachable, **cropping a photo changes its tile shape in the
masonry grid and its hero fit**. Intended, and the most visible effect of this
stage.

### 6.6 Free consequence — batch crop

`AdjustmentGroup` already includes `.geometry` and `.vignette`
(`EditTransfer.swift:23`) and `SelectionMenu.swift:50` already does batch
paste. So the moment Stages A and C land, copying a crop across a shoot and
batch-syncing a vignette work with no additional code.

---

## 7. Dead-code deletion

Three functions have zero callers and are removed:

- `AppState.analyzeCurrentFolder()` — `AppState+Indexing.swift:82`. A duplicate
  of the path the shipped Regenerate Tags command uses (`AppState.swift:801`).
- `AppState.analyzeSelected()` — `AppState+Indexing.swift:91`.
- `AnalyzePipeline.analyzeFileManual(_:)` — dead by transitivity; `analyzeSelected`
  was its only caller.

Folder-wide Regenerate Tags already covers the need. Per-photo re-analyze is
**not** being wired up.

---

## 8. Test obligations

| Area | Test |
|---|---|
| Vignette | Extend `EditStackNormalizeTests` / preset round-trip; card writes reach `setVignette` |
| Auto-tone | `AutoToneStatsTests` on synthetic gradients (flat, bimodal, colour-cast, already-neutral); **idempotence** — apply twice, identical stack |
| Auto-tone scoping | Auto in LIGHT leaves `ColorParams` untouched, and vice versa |
| HSL / split tone / grain | `EditRenderNeutralityTests` — neutral params render byte-identical to the original |
| Grain | New `EditRenderConsistencyTests` case: same seed → same field; preview and full-res agree at multiple resolutions |
| Enum append | `EditStackCodecTests`' pinned hash still passes — pre-existing stacks' canonical bytes unchanged |
| Forward compat | A stack containing `.hsl` decoded by a build without it throws and renders the original, blob preserved |
| Crop math | `CropDragMath` tests in `Components/` — handle drags, minimum side, aspect constraint, straighten auto-inset rect |
| Crop geometry | Extend `GeometryParamsTests` for the auto-inset rect at representative angles |
| Copy/paste | `EditTransferTests` covers the three new groups |
| Localization | `-exportLocalizations` for `fr` reports 0 untranslated |
| Invariants | `./scripts/audit-invariants.sh` green before every commit |

Runtime verification per `verify-runtime-not-just-tests`: green tests are not
the claim. Each stage is driven in the running app, and
`docs/new-build/FEATURE-LEDGER.md` is updated with automated / static / runtime
states per feature.

---

## 9. Sequencing

1. **Stage A** — EFFECTS card + vignette; auto-tone (two buttons + `AutoToneStats`)
2. **Stage B** — `.hsl`, then `.splitTone`, then `.grain`
3. **Stage C** — crop card + overlay port
4. Dead-code deletion (§7) folds into whichever commit is convenient

Stage A touches no schema and appends no enum case, so it lands first and
proves the card layout before Stage B touches `Adjustment`. Stage C is last and
severable by owner decision.

---

## 10. Deliberately not in this spec

- **Search-token discoverability.** Fourteen token types (`camera:`, `lens:`,
  `iso:`, `aperture:`, `in:`, `near:`, `text:`, `color:`, `rating:`, `kind:`,
  `faces:`, `pets:`, `is:`, `similar:`) parse and work, and nothing in the UI
  says they exist. Only `similar:` has a discoverable door. `NLQuerySuggest` is
  gated to macOS 26 + Apple Intelligence and bails when a token is present.
  This is the largest buried capability in the app and gets its **own spec
  next** — it is a search problem, not an editing one.
- **Colored borders / framing** — owner-deferred; export furniture.
- Anything on the `foundation.md:243` NEVER list.
