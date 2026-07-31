# Spec 05 — Editing Readouts, Learning Layer, Looks & LUTs Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship the editor's "distinctive layer" on top of Spec 04's engine: a live
statistics tap feeding a teaching histogram + plain-English clipping messages, on-image
clipping zebras, the tone-zone control (edge-aware per-zone exposure — the flagship),
deterministic "Why it looks this way" photo feedback, `.cube` 3D LUT import with a
strength slider, a live-thumbnail Looks browser, and a pinned reference-photo view.

**Architecture:** Everything here is an extension of Spec 04's editor — two new
`Adjustment` cases (`toneZone`, `lut`) appended to the existing enum; one shared,
cheap statistics pass (`HistogramCompute`) piggybacked on Spec 04's `RenderCoalescer`
feeding three consumers (histogram, curve-behind, zone strip); new Metal kernels
joining `EditKernels.metal`; two new migrations (`v22` on `photo_traits`, `v23` new
table `edit_luts`); three new Pattern-B stores (`LutStore`, `EditReferenceStore`, plus
`EditSession` state). No `AppState` changes, no new render contexts, no second render
loop — every new visual reads through the existing chain/coalescer/consistency gate.

**Tech Stack:** Swift 5 (MainActor default isolation), SwiftUI + AppKit escape hatches,
GRDB 7.10, Core Image + Metal (`[[stitchable]]` kernels), CryptoKit (LUT hashing),
XCTest (pure-logic only, house convention — no UI unit tests).

## Global Constraints

- **Hard dependency on Spec 04** (`docs/superpowers/plans/2026-07-30-spec-04-editing-engine.md`):
  `EditStack`/`Adjustment`/`EditStackCodec`, `EditRenderer.apply`/`canRender`/`render`,
  `RenderCoalescer`, `EditSession`, `EditTransfer`/`AdjustmentGroup`, `Theme`, the Looks-tab +
  Scopes-tab scaffold, `CurveEditorView(histogram:)`'s `nil`-today seam, and
  `EditKernels.metal`/`EditKernels.swift` must exist and be green before any task here starts.
  Nothing in this plan builds without them.
- **Soft dependency on Spec 02 (`photo_meta` v14) and Spec 03 (`photo_traits` v19,
  `DeepAnalysisBackfill`, `SharpnessScore`) for §"Why it looks this way" ONLY** (Phase 5,
  Tasks 5.1–5.6). Every other phase has zero Spec 02/03 dependency and ships independently.
  If Specs 02/03 are not yet built when this plan executes, skip Phase 5 and resume it once
  they land — do not stub `photo_meta`/`photo_traits` reads.
- **Migration numbering is fixed by DECISIONS**: this spec adds **v22 `photo_stats`**
  (columns on the existing `photo_traits` table, `PhotoTraits.currentVersion` 1 → 2) and
  **v23 `edit_luts`** (new table) — separate migrations, registered at the end of
  `Database.makeMigrator()` after whatever the tree currently ends at (v21 if Spec 04 is the
  most recent landed spec; re-confirm with `grep -n "registerMigration"
  Muse/Muse/Database/Database.swift` before editing). Do not renumber; a future spec
  continues at v24.
- **New `Adjustment` cases append at the END of the enum, after `.vignette`, never
  mid-list.** Canonical order is declaration order (`EditStack.normalized()`); inserting
  anywhere else re-keys every pre-existing edited thumbnail's `stack_hash`. The pinned
  `EditStackCodecTests` fixture hash from Spec 04 MUST NOT change — only the *new* fixture
  covering `toneZone`/`lut` gets a fresh pin.
- **`schemaVersion` and `currentProcessVersion` both stay at their Spec 04 values.** A new
  enum case is the wrapper's designed forward-evolution path (Spec 04 §1.1): an old build
  decode-fails a stack containing `toneZone`/`lut` and renders the ORIGINAL image,
  detectably, blob preserved. Do not bump either constant for this spec.
- **Scene-referred rule extends to `toneZone`**: it runs on un-clamped linear working-space
  data, chain position 2b (after tone, before curve) — a single per-pixel gain, hue-preserving
  by construction. **`lut` is the display-referred exception**, chain position 4b (after
  color, before presence) — `.cube` packs are authored against display/video encoding, same
  pocket the curve already established.
- **Renderer chain order, updated (code, never data):** `1 geometry → 2 tone → 2b toneZone →
  3 curve → 4 color → 4b lut → 5 presence → 6 vignette → 7 display`. This order lives in
  `EditRenderer.apply`'s source, never in the stack's JSON or its `adjustments` array order.
- **Every scale-dependent parameter is a fraction of the source long edge** (Spec 04's
  standing rule) — the tone-zone guided filter's radius and the zone/stats sample sizes obey
  it. `EditRenderConsistencyTests`' all-groups fixture must include every renderable group,
  current and future: `toneZone` and `lut` join that fixture in the SAME commit that adds
  their render stage, or the stage doesn't land (durable constraint, restated per spec-05 §12.7).
- **Zebras, the live clipping stats, and the Scopes clipping messages read the SAME two
  AppSettings thresholds** (`editorZebraHighKey`/`editorZebraLowKey`, defaults 0.98/0.02) —
  never fork the constant. **Stored capture statistics** (`photo_traits.clip_high_r/g/b`,
  `clip_low`) use FIXED constants (`ClippingStats.storedHighThreshold = 254/255`,
  `storedLowThreshold = 2/255`) and must NEVER read the user's zebra prefs — DB rows must not
  change meaning when a slider moves.
- **Editor statistics compute ONLY while a consumer is visible** (`EditSession.statsVisible`
  — Light or Scopes tab, Edit mode; never Preview), at `statsSampleLongEdge = 256`,
  piggybacked on `RenderCoalescer` — never a second render loop, never full-resolution.
  Overlays (zebras, zone hatch) are single `[[stitchable]]` kernel passes at canvas
  resolution, applied in `EditCanvasView`'s draw step.
- **LUT rows are immutable** (`edit_luts`, content-addressed PK = SHA-256 of the canonical
  float bytes): import is `INSERT OR IGNORE`, rename touches `name` only, there is no update
  path. A stack whose `lut` reference is unresolvable on this device renders the ORIGINAL
  image everywhere (thumbnails/hero/exports), never a partial stack; `EditRenderer.canRender`
  gates on LUT resolvability. `LutRegistry` is render-path-only — never call it on the main
  thread (it does synchronous DB I/O).
- **Photo feedback (`PhotoFeedback`) is deterministic and rule-based, NEVER an LLM** — a
  Swift-declared threshold table, computed only from precomputed columns
  (`photo_meta`/`photo_traits`), read inside the hero's existing details-load pass so the
  surface never triggers a decode or query-time analysis. An empty result renders no card —
  silence is a feature, not a fallback state.
- **`AppState` is frozen** — Spec 05 adds zero new `@Published` properties. New state lives
  in `EditSession` (existing Spec 04 store, extended), `LutStore`/`EditReferenceStore`
  (new Pattern B singletons), following the exact shape DECISIONS documents for
  `EditPresetStore`/`EditStore`.
- **House test convention: no UI unit tests.** All new tests are pure-logic (`nonisolated
  enum`/`struct` functions or migration/query tests against an in-memory `DatabaseQueue`),
  added to the `MuseTests` target.
- **Zero AppKit imports under `Editing/` and `Editing/Render/`** — Foundation/CoreGraphics/
  CoreImage/Metal only, enforced by Spec 04's `EditingModuleImportTests` (extend its file
  list, don't create a second grep-test).
- **French localization is a hard requirement for every new user-facing string** — every
  literal is a SwiftUI text-literal position or `String(localized:)`. The build isn't done
  until an `-exportLocalizations -exportLanguage fr` pass reports 0 untranslated for new keys
  (Task 9.2).
- **`BUILD SUCCEEDED` is not proof of a working build** — `stat` the `.app`'s executable
  mtime before handing off any milestone for visual/manual verification (stale DerivedData/
  signing issue, documented in CLAUDE.md).
- Codebase note: verified present at plan-writing time (`plan-1` branch, 2026-07-30) — this
  plan assumes Spec 04's editor code exists in the tree per its own plan
  (`2026-07-30-spec-04-editing-engine.md`). File/line references below are copied from
  `spec-05-implementation.md` and cross-checked against `spec-04`'s plan and the existing
  repo files (`AppSettings.swift`, `ViewerInfoColumn.swift`, `KeyCaptureView.swift`,
  `SelectionMenu.swift`) at commit time; re-confirm each with a fresh `grep -n` before
  editing, since the tree moves between commits.

---

## Build order (10 phases, matches spec-05 §14)

0. Model additions (§1): `ToneZoneParams`/`LutParams`, enum cases appended, groups,
   codec/transfer/normalize test extensions incl. the hash-stability pin — pure, invisible.
1. Stats tap + teaching histogram + curve-behind (§2, §3): `HistogramCompute`, session
   plumbing, `ScopesPanel`/`HistogramView`, clipping messages, drag-to-adjust, the
   `CurveEditorView(histogram:)` seam filled.
2. Zebras (§4): kernel, toggle + J key, threshold popover + AppSettings keys.
3. Tone-zone (§5.1–5.5): math, guided filter, render stage, consistency/neutrality
   extensions, zone strip, target mode.
4. Zone overlay (§5.6): hatch kernel + hover wiring.
5. "Why it looks this way" (§6): v22 + version bump, `NoiseEstimate`, traits fill +
   backfill fields, `PhotoFeedback`, `PhotoStatsQueries`, hero card + editor Info rows +
   RAW process line. (Blocks on Specs 02/03 being built; the only phase that does.)
6. LUT import (§7): parser, v23, `LutRegistry`, `LutStore`, render stage, missing-LUT UX,
   import panel.
7. Looks browser (§8): browser grid replacing the Looks rows, live thumbs, strength
   slider, management menus.
8. Reference view (§9): store, context-menu entry, chrome toggle, pane.
9. Docs (`CLAUDE.md` constraints + phase-table row; `architecture-map.md`; `session-log.md`;
   DECISIONS.md refresh) + localization export pass.

Each numbered phase ships independently and leaves the app releasable (spec-05 §0's
requirement, preserved).

---

## Phase 0 — Model additions

### Task 0.1: `ToneZoneParams` + `LutParams` + new `Adjustment` cases

**Files:**
- Modify: `Muse/Muse/Editing/EditStack.swift` (add the two param structs, extend
  `Adjustment`, extend `normalized()`'s canonical-index switch, add `isNeutralCase`
  coverage, add `toneZoneParams`/`lutParams` accessors)
- Test: `Muse/MuseTests/EditStackNormalizeTests.swift` (extend)

**Interfaces:**
- Consumes: `EditStack`, `Adjustment` (Spec 04 Task 1.1).
- Produces: `ToneZoneParams { static let zoneCount = 9; var gains: [Double]; static let
  neutral: ToneZoneParams; var isNeutral: Bool; func clamped() -> Self }`, `LutParams { var
  lutHash: String; var name: String; var strength: Double; var isNeutral: Bool; func
  clamped() -> Self }`, `Adjustment.toneZone(ToneZoneParams)`, `Adjustment.lut(LutParams)`
  (declared after `.vignette`), `EditStack.toneZoneParams: ToneZoneParams?`,
  `EditStack.lutParams: LutParams?`.

- [ ] **Step 1: Write the failing test**

```swift
// Append to Muse/MuseTests/EditStackNormalizeTests.swift

extension EditStackNormalizeTests {
    func testToneZoneParamsNeutralIsAllZeroGains() {
        XCTAssertTrue(ToneZoneParams.neutral.isNeutral)
        XCTAssertEqual(ToneZoneParams.neutral.gains.count, ToneZoneParams.zoneCount)
        XCTAssertTrue(ToneZoneParams.neutral.gains.allSatisfy { $0 == 0 })
    }

    func testToneZoneParamsClampedPadsShortArray() {
        let short = ToneZoneParams(gains: [0.5, -0.5])
        let clamped = short.clamped()
        XCTAssertEqual(clamped.gains.count, ToneZoneParams.zoneCount)
        XCTAssertEqual(clamped.gains[0], 0.5)
        XCTAssertEqual(clamped.gains[1], -0.5)
        XCTAssertEqual(clamped.gains[2], 0)
    }

    func testToneZoneParamsClampedTruncatesLongArray() {
        let long = ToneZoneParams(gains: Array(repeating: 0.3, count: 20))
        XCTAssertEqual(long.clamped().gains.count, ToneZoneParams.zoneCount)
    }

    func testToneZoneParamsClampedBoundsEachGain() {
        var p = ToneZoneParams.neutral
        p.gains[0] = 99
        p.gains[1] = -99
        let clamped = p.clamped()
        XCTAssertEqual(clamped.gains[0], 1)
        XCTAssertEqual(clamped.gains[1], -1)
    }

    func testLutParamsNeutralAtZeroStrength() {
        let p = LutParams(lutHash: "abc", name: "Kodak 2383", strength: 0)
        XCTAssertTrue(p.isNeutral)
    }

    func testLutParamsNonNeutralAtNonZeroStrength() {
        let p = LutParams(lutHash: "abc", name: "Kodak 2383", strength: 0.5)
        XCTAssertFalse(p.isNeutral)
    }

    func testLutParamsClampedBoundsStrength() {
        var p = LutParams(lutHash: "abc", name: "x", strength: 5)
        p = p.clamped()
        XCTAssertLessThanOrEqual(p.strength, 1)
        p = LutParams(lutHash: "abc", name: "x", strength: -5).clamped()
        XCTAssertGreaterThanOrEqual(p.strength, 0)
    }

    func testAdjustmentToneZoneAndLutAppendAfterVignetteInNormalizedOrder() {
        var stack = EditStack.fresh()
        var tz = ToneZoneParams.neutral; tz.gains[0] = 0.4
        let lut = LutParams(lutHash: "deadbeef", name: "Look", strength: 0.8)
        stack.adjustments = [.lut(lut), .vignette(.neutral), .toneZone(tz), .tone(.neutral)]
        let order = stack.normalized().adjustments.map { adj -> Int in
            switch adj {
            case .tone: return 0; case .color: return 1; case .presence: return 2
            case .curve: return 3; case .geometry: return 4; case .vignette: return 5
            case .toneZone: return 6; case .lut: return 7
            }
        }
        XCTAssertEqual(order, order.sorted())
    }

    func testStackToneZoneParamsAccessorExtractsCase() {
        var stack = EditStack.fresh()
        var tz = ToneZoneParams.neutral; tz.gains[3] = -0.2
        stack.adjustments = [.toneZone(tz)]
        XCTAssertEqual(stack.toneZoneParams?.gains[3], -0.2)
    }

    func testStackLutParamsAccessorExtractsCase() {
        var stack = EditStack.fresh()
        let lut = LutParams(lutHash: "hash1", name: "Warm Film", strength: 0.6)
        stack.adjustments = [.lut(lut)]
        XCTAssertEqual(stack.lutParams?.lutHash, "hash1")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -scheme Muse -only-testing:MuseTests/EditStackNormalizeTests test`
Expected: FAIL — `ToneZoneParams`/`LutParams` don't exist, `Adjustment` has no
`.toneZone`/`.lut` cases, the switch in the test itself won't compile against the
old `Adjustment` (expected — this pins the target shape).

- [ ] **Step 3: Add the two param structs to `EditStack.swift`**

```swift
/// 9 zones, one photographic stop each, covering -8...0 EV relative to diffuse
/// white (darktable's tone-equalizer range). gains[0] = deepest shadows (-8 EV),
/// gains[8] = highlights (0 EV). The EV mapping is renderer-side
/// (ToneZoneMath.maxZoneEV) so this struct stores only the -1...+1 slider value.
nonisolated struct ToneZoneParams: Codable, Equatable, Sendable {
    static let zoneCount = 9

    var gains: [Double]

    static let neutral = ToneZoneParams(gains: .init(repeating: 0, count: zoneCount))

    var isNeutral: Bool { gains.allSatisfy { $0 == 0 } }

    /// Clamps each gain to -1...+1 and normalizes the array length: shorter pads
    /// with 0, longer truncates. A hand-edited or future-shaped sidecar can't
    /// crash the renderer or index out of bounds.
    func clamped() -> Self {
        var padded = gains
        if padded.count < Self.zoneCount {
            padded += Array(repeating: 0, count: Self.zoneCount - padded.count)
        } else if padded.count > Self.zoneCount {
            padded = Array(padded.prefix(Self.zoneCount))
        }
        return ToneZoneParams(gains: padded.map { min(max($0, -1), 1) })
    }
}

/// References an `edit_luts` row by content hash — never embedded data (a 64^3
/// table is ~3 MB and the stack rides sidecars and is hashed per edit).
nonisolated struct LutParams: Codable, Equatable, Sendable {
    /// SHA-256 hex of the LUT's canonical float bytes — the edit_luts PK.
    var lutHash: String
    /// Display fallback when the LUT row is absent on this device.
    var name: String
    var strength: Double = 1 // 0...1; UI shows 0-100

    var isNeutral: Bool { strength == 0 }

    func clamped() -> Self {
        LutParams(lutHash: lutHash, name: name, strength: min(max(strength, 0), 1))
    }
}
```

- [ ] **Step 4: Extend `Adjustment`, its `Codable` conformance, `normalized()`'s canonical
index, and `isNeutralCase`**

In the `Adjustment` enum declaration, append after `case vignette(VignetteParams)`:

```swift
    case toneZone(ToneZoneParams)
    case lut(LutParams)
```

In `Adjustment`'s custom `Codable` conformance (Spec 04 Task 1.2), extend `Kind` and both
switches:

```swift
    private enum Kind: String, Codable {
        case tone, color, presence, curve, geometry, vignette, toneZone, lut
    }
```

Add matching cases to `init(from:)`:

```swift
        case .toneZone: self = .toneZone(try c.decode(ToneZoneParams.self, forKey: .params))
        case .lut: self = .lut(try c.decode(LutParams.self, forKey: .params))
```

And to `encode(to:)`:

```swift
        case .toneZone(let p): try c.encode(Kind.toneZone, forKey: .type); try c.encode(p, forKey: .params)
        case .lut(let p): try c.encode(Kind.lut, forKey: .type); try c.encode(p, forKey: .params)
```

In `EditStack.swift`'s private `canonicalIndex` extension (used by `normalized()`), extend:

```swift
private extension Adjustment {
    var canonicalIndex: Int {
        switch self {
        case .tone: 0; case .color: 1; case .presence: 2
        case .curve: 3; case .geometry: 4; case .vignette: 5
        case .toneZone: 6; case .lut: 7
        }
    }
}
```

Extend `Adjustment.isNeutralCase` (or the equivalent switch `EditStack.isNeutral` uses):

```swift
    var isNeutralCase: Bool {
        switch self {
        case .tone(let p): p.isNeutral
        case .color(let p): p.isNeutral
        case .presence(let p): p.isNeutral
        case .curve(let p): p.isNeutral
        case .geometry(let p): p.isNeutral
        case .vignette(let p): p.isNeutral
        case .toneZone(let p): p.isNeutral
        case .lut(let p): p.isNeutral
        }
    }
```

Add the two convenience accessors alongside `stack.toneParams`/`.colorParams` etc.:

```swift
extension EditStack {
    var toneZoneParams: ToneZoneParams? {
        adjustments.compactMap { if case .toneZone(let p) = $0 { p } else { nil } }.first
    }
    var lutParams: LutParams? {
        adjustments.compactMap { if case .lut(let p) = $0 { p } else { nil } }.first
    }
}
```

- [ ] **Step 5: Run test to verify it passes**

Run: `xcodebuild -scheme Muse -only-testing:MuseTests/EditStackNormalizeTests test`
Expected: PASS

- [ ] **Step 6: Run the full existing `EditStackNormalizeTests` + `EditStackCodecTests`
suites to confirm no regression**

Run: `xcodebuild -scheme Muse -only-testing:MuseTests/EditStackNormalizeTests
-only-testing:MuseTests/EditStackCodecTests test`
Expected: PASS — the Spec 04 pinned-hash test (`testHashIsStablePinnedFixture`) must be
UNCHANGED (its fixture stack has no `toneZone`/`lut`, so appending cases at the end of the
enum cannot move it).

- [ ] **Step 7: Commit**

```bash
git add "Muse/Muse/Editing/EditStack.swift" "Muse/MuseTests/EditStackNormalizeTests.swift"
git commit -m "feat(editing): ToneZoneParams + LutParams — two new Adjustment cases appended after vignette"
```

### Task 0.2: `AdjustmentGroup` extension + `EditTransfer` coverage

**Files:**
- Modify: `Muse/Muse/Editing/EditTransfer.swift`
- Test: `Muse/MuseTests/EditTransferTests.swift` (extend)

**Interfaces:**
- Consumes: `AdjustmentGroup` (Spec 04 Task 1.4), `Adjustment.toneZone`/`.lut` (Task 0.1).
- Produces: `AdjustmentGroup.toneZone`, `AdjustmentGroup.lut` (rawValues `"toneZone"`,
  `"lut"`), `EditTransfer.adjustedGroups`/`.apply` handling both like every existing group.

- [ ] **Step 1: Write the failing test**

```swift
// Append to Muse/MuseTests/EditTransferTests.swift

extension EditTransferTests {
    func nonNeutralToneZone() -> EditStack {
        var s = EditStack.fresh()
        var tz = ToneZoneParams.neutral; tz.gains[4] = 0.5
        s.adjustments = [.toneZone(tz)]
        return s
    }

    func nonNeutralLut() -> EditStack {
        var s = EditStack.fresh()
        s.adjustments = [.lut(LutParams(lutHash: "abc123", name: "Kodak", strength: 0.7))]
        return s
    }

    func testAdjustedGroupsIncludesToneZone() {
        XCTAssertEqual(EditTransfer.adjustedGroups(of: nonNeutralToneZone()), [.toneZone])
    }

    func testAdjustedGroupsIncludesLut() {
        XCTAssertEqual(EditTransfer.adjustedGroups(of: nonNeutralLut()), [.lut])
    }

    func testApplyCopiesToneZoneGainsWholesale() {
        let result = EditTransfer.apply(groups: [.toneZone], from: nonNeutralToneZone(), onto: .fresh())
        XCTAssertEqual(result.toneZoneParams?.gains[4], 0.5)
    }

    func testApplyCopiesLutReferenceAndStrength() {
        let result = EditTransfer.apply(groups: [.lut], from: nonNeutralLut(), onto: .fresh())
        XCTAssertEqual(result.lutParams?.lutHash, "abc123")
        XCTAssertEqual(result.lutParams?.strength, 0.7)
    }

    func testPresetsMayCarryLutGroup() {
        // Geometry remains the only preset exclusion (Spec 04 D8, unchanged) — lut is NOT
        // excluded, since a "look" is very often a LUT plus tweaks.
        let allExceptGeometry: Set<AdjustmentGroup> = Set(AdjustmentGroup.allCases)
            .subtracting([.geometry])
        XCTAssertTrue(allExceptGeometry.contains(.lut))
        XCTAssertTrue(allExceptGeometry.contains(.toneZone))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -scheme Muse -only-testing:MuseTests/EditTransferTests test`
Expected: FAIL — `AdjustmentGroup` has no `.toneZone`/`.lut` cases.

- [ ] **Step 3: Implement**

Extend `AdjustmentGroup`:

```swift
nonisolated enum AdjustmentGroup: String, CaseIterable, Codable, Sendable {
    case tone, color, presence, curve, geometry, vignette, raw, toneZone, lut
}
```

Extend the private `Adjustment.group` accessor `EditTransfer.swift` declares:

```swift
private extension Adjustment {
    var group: AdjustmentGroup {
        switch self {
        case .tone: .tone; case .color: .color; case .presence: .presence
        case .curve: .curve; case .geometry: .geometry; case .vignette: .vignette
        case .toneZone: .toneZone; case .lut: .lut
        }
    }
}
```

Extend `EditTransfer.adjustedGroups`' switch:

```swift
    static func adjustedGroups(of stack: EditStack) -> Set<AdjustmentGroup> {
        var groups = Set<AdjustmentGroup>()
        for adj in stack.adjustments where !adj.isNeutralCase {
            switch adj {
            case .tone: groups.insert(.tone)
            case .color: groups.insert(.color)
            case .presence: groups.insert(.presence)
            case .curve: groups.insert(.curve)
            case .geometry: groups.insert(.geometry)
            case .vignette: groups.insert(.vignette)
            case .toneZone: groups.insert(.toneZone)
            case .lut: groups.insert(.lut)
            }
        }
        if let raw = stack.rawParams, !raw.isNeutral { groups.insert(.raw) }
        return groups
    }
```

`EditTransfer.apply` needs no change beyond what `Adjustment.group` already gives it — it
filters/copies by `group` generically, so `toneZone`/`lut` ride the same code path as every
existing case for free.

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild -scheme Muse -only-testing:MuseTests/EditTransferTests test`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add "Muse/Muse/Editing/EditTransfer.swift" "Muse/MuseTests/EditTransferTests.swift"
git commit -m "feat(editing): AdjustmentGroup gains toneZone/lut — copy/paste/preset parity"
```

### Task 0.3: `EditStackCodec` extended — round-trip, hash pin, wrong-length gains, unknown-type failure

**Files:**
- Modify: `Muse/Muse/Editing/EditStack.swift` (only if Task 0.1 left a gap — this task is
  test-only against the Task 0.1/0.2 implementation)
- Test: `Muse/MuseTests/EditStackCodecTests.swift` (extend)

**Interfaces:**
- Consumes: `EditStackCodec.encode`/`.decode`/`.hash` (Spec 04 Task 1.2), `ToneZoneParams`/
  `LutParams` (Task 0.1).
- Produces: nothing new — this task is the closing test coverage spec-05 §13 requires
  before Phase 0 is considered done.

- [ ] **Step 1: Write the failing tests**

```swift
// Append to Muse/MuseTests/EditStackCodecTests.swift

extension EditStackCodecTests {
    func fixtureStackWithToneZoneAndLut() -> EditStack {
        var stack = EditStack.fresh()
        var tz = ToneZoneParams.neutral; tz.gains[0] = -0.6; tz.gains[8] = 0.3
        let lut = LutParams(lutHash: "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcd",
                             name: "Kodak 2383", strength: 0.75)
        stack.adjustments = [.tone(.neutral), .toneZone(tz), .lut(lut)]
        return stack
    }

    func testToneZoneAndLutRoundTrip() throws {
        let stack = fixtureStackWithToneZoneAndLut()
        let json = try EditStackCodec.encode(stack)
        let decoded = try XCTUnwrap(EditStackCodec.decode(json))
        XCTAssertEqual(decoded.toneZoneParams?.gains[0], -0.6)
        XCTAssertEqual(decoded.toneZoneParams?.gains[8], 0.3)
        XCTAssertEqual(decoded.lutParams?.strength, 0.75)
    }

    func testPreExistingFixtureHashIsUnchangedByAppendedCases() throws {
        // The Spec 04 fixture (tone-only) must still hash to its pinned value — appending
        // toneZone/lut at the END of the enum must not perturb ANY pre-existing stack.
        let hash = EditStackCodec.hash(fixtureStack())
        XCTAssertEqual(hash, EditStackCodec.hash(fixtureStack()))
        // The literal pin from Spec 04's testHashIsStablePinnedFixture is asserted there;
        // this test only re-confirms determinism survives the enum extension.
    }

    func testWrongLengthGainsDecodeNormalized() throws {
        // A hand-edited or future-shaped sidecar with a short gains array must not crash —
        // ToneZoneParams itself doesn't auto-clamp on decode (that's the renderer's job via
        // .clamped()), but decode must succeed and produce a valid (if unclamped) struct.
        let json = """
        {"schemaVersion":\(EditStack.currentSchemaVersion),\
        "processVersion":\(EditStack.currentProcessVersion),\
        "adjustments":[{"type":"toneZone","params":{"gains":[0.2,-0.2]}}],\
        "masks":[]}
        """
        let decoded = try XCTUnwrap(EditStackCodec.decode(json))
        XCTAssertEqual(decoded.toneZoneParams?.gains.count, 2)
        // The renderer (Task 3.2) is what calls .clamped() before use — pin that contract
        // here so a future refactor can't silently move the responsibility.
        XCTAssertEqual(decoded.toneZoneParams?.clamped().gains.count, ToneZoneParams.zoneCount)
    }

    func testUnknownAdjustmentTypeStillFailsWholeStackDecode() {
        let json = """
        {"schemaVersion":\(EditStack.currentSchemaVersion),\
        "processVersion":\(EditStack.currentProcessVersion),\
        "adjustments":[{"type":"futureCase","params":{}}],\
        "masks":[]}
        """
        XCTAssertNil(EditStackCodec.decode(json))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -scheme Muse -only-testing:MuseTests/EditStackCodecTests test`
Expected: FAIL initially only if Task 0.1's `Codable` conformance is incomplete; if Task
0.1 was implemented as specified, this step should already mostly pass — treat any failure
as a signal to revisit Task 0.1's `init(from:)`/`encode(to:)` switches.

- [ ] **Step 3: Fix any gaps surfaced by Step 2** (there should be none if Task 0.1 was
followed verbatim; if `testWrongLengthGainsDecodeNormalized` fails because `ToneZoneParams`
itself has a custom decoder that force-pads, remove that — the struct's `Codable` stays
Swift-synthesized; only `.clamped()` normalizes, called explicitly by the renderer, per the
spec's `func clamped()` on the type rather than a decode-time guard).

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild -scheme Muse -only-testing:MuseTests/EditStackCodecTests test`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add "Muse/MuseTests/EditStackCodecTests.swift"
git commit -m "test(editing): EditStackCodec — toneZone/lut round-trip, pinned-hash survival, wrong-length gains, unknown-type failure"
```

---

## Phase 1 — Live statistics tap + teaching histogram + curve-behind

### Task 1.1: `Editing/HistogramCompute.swift` — pure statistics over raw buffers

**Files:**
- Create: `Muse/Muse/Editing/HistogramCompute.swift`
- Test: `Muse/MuseTests/HistogramComputeTests.swift`

**Interfaces:**
- Consumes: nothing (pure over raw pixel buffers).
- Produces:
  ```swift
  nonisolated struct HistogramData: Equatable, Sendable {
      static let binCount = 64
      var r: [Float]; var g: [Float]; var b: [Float]; var luma: [Float]
  }
  nonisolated enum RGBChannel: Equatable, Sendable { case red, green, blue }
  nonisolated enum FrameRegion: Equatable, Sendable { case top, middle, bottom }
  nonisolated struct ClippingStats: Equatable, Sendable {
      static let storedHighThreshold: Double = 254.0 / 255.0
      static let storedLowThreshold: Double = 2.0 / 255.0
      var highR: Double; var highG: Double; var highB: Double
      var low: Double
      var highMassCenterY: Double?; var lowMassCenterY: Double?
  }
  nonisolated struct CurveHistogram: Equatable, Sendable { let bins: [Float] }
  nonisolated enum HistogramCompute {
      static func compute(rgba8: [UInt8], width: Int, height: Int,
                           highThreshold: Double, lowThreshold: Double)
          -> (histogram: HistogramData, clipping: ClippingStats)
      static func zoneMass(evMap: [Float], width: Int, height: Int) -> [Double]
      static func curveHistogram(from histogram: HistogramData) -> CurveHistogram
      static func frameRegion(forCenterY y: Double?) -> FrameRegion?
  }
  ```

- [ ] **Step 1: Write the failing test**

```swift
//
//  HistogramComputeTests.swift
//  MuseTests
//

import XCTest
@testable import Muse

final class HistogramComputeTests: XCTestCase {

    /// A `width` x `height` RGBA8 buffer, one solid color, alpha 255 throughout.
    private func solidBuffer(width: Int, height: Int, r: UInt8, g: UInt8, b: UInt8) -> [UInt8] {
        var buf = [UInt8](repeating: 0, count: width * height * 4)
        for i in stride(from: 0, to: buf.count, by: 4) {
            buf[i] = r; buf[i + 1] = g; buf[i + 2] = b; buf[i + 3] = 255
        }
        return buf
    }

    /// A horizontal gradient 0...255 across `width` columns, replicated down `height` rows.
    private func gradientBuffer(width: Int, height: Int) -> [UInt8] {
        var buf = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let v = UInt8(Double(x) / Double(max(width - 1, 1)) * 255)
                let i = (y * width + x) * 4
                buf[i] = v; buf[i + 1] = v; buf[i + 2] = v; buf[i + 3] = 255
            }
        }
        return buf
    }

    func testSolidMidGrayFillsOneBinAcrossAllChannels() {
        let buf = solidBuffer(width: 8, height: 8, r: 128, g: 128, b: 128)
        let (hist, _) = HistogramCompute.compute(rgba8: buf, width: 8, height: 8,
                                                   highThreshold: 0.98, lowThreshold: 0.02)
        XCTAssertEqual(hist.r.count, HistogramData.binCount)
        let peakBin = hist.r.firstIndex(of: hist.r.max()!)!
        // 128/255 ~= 0.502 -> bin ~= 0.502 * 64 = 32
        XCTAssertEqual(peakBin, 32, accuracy: 1)
        XCTAssertEqual(hist.g.firstIndex(of: hist.g.max()!)!, peakBin)
        XCTAssertEqual(hist.b.firstIndex(of: hist.b.max()!)!, peakBin)
        // Normalized so the max bin across channels == 1.
        XCTAssertEqual(hist.r.max()!, 1.0, accuracy: 0.001)
    }

    func testAllWhiteBufferClipsHighOnAllThreeChannels() {
        let buf = solidBuffer(width: 4, height: 4, r: 255, g: 255, b: 255)
        let (_, clip) = HistogramCompute.compute(rgba8: buf, width: 4, height: 4,
                                                   highThreshold: 0.98, lowThreshold: 0.02)
        XCTAssertEqual(clip.highR, 1.0, accuracy: 0.001)
        XCTAssertEqual(clip.highG, 1.0, accuracy: 0.001)
        XCTAssertEqual(clip.highB, 1.0, accuracy: 0.001)
        XCTAssertEqual(clip.low, 0.0, accuracy: 0.001)
    }

    func testAllBlackBufferClipsLowOnly() {
        let buf = solidBuffer(width: 4, height: 4, r: 0, g: 0, b: 0)
        let (_, clip) = HistogramCompute.compute(rgba8: buf, width: 4, height: 4,
                                                   highThreshold: 0.98, lowThreshold: 0.02)
        XCTAssertEqual(clip.low, 1.0, accuracy: 0.001)
        XCTAssertEqual(clip.highR, 0.0, accuracy: 0.001)
    }

    func testMidGrayBufferHasZeroClipping() {
        let buf = solidBuffer(width: 4, height: 4, r: 128, g: 128, b: 128)
        let (_, clip) = HistogramCompute.compute(rgba8: buf, width: 4, height: 4,
                                                   highThreshold: 0.98, lowThreshold: 0.02)
        XCTAssertEqual(clip.highR, 0)
        XCTAssertEqual(clip.low, 0)
    }

    func testClipMassCenterYNilWhenFractionIsZero() {
        let buf = solidBuffer(width: 4, height: 4, r: 128, g: 128, b: 128)
        let (_, clip) = HistogramCompute.compute(rgba8: buf, width: 4, height: 4,
                                                   highThreshold: 0.98, lowThreshold: 0.02)
        XCTAssertNil(clip.highMassCenterY)
        XCTAssertNil(clip.lowMassCenterY)
    }

    func testClipMassCenterYIsTopWhenClippedRowsAreAtTop() {
        // Top 2 rows white (row 0,1), bottom 2 rows mid-gray, height 4 -> row centroid
        // for the clipped mass should sit near y=0 (top), normalized 0...1.
        var buf = [UInt8](repeating: 0, count: 4 * 4 * 4)
        for y in 0..<4 {
            for x in 0..<4 {
                let v: UInt8 = y < 2 ? 255 : 128
                let i = (y * 4 + x) * 4
                buf[i] = v; buf[i + 1] = v; buf[i + 2] = v; buf[i + 3] = 255
            }
        }
        let (_, clip) = HistogramCompute.compute(rgba8: buf, width: 4, height: 4,
                                                   highThreshold: 0.98, lowThreshold: 0.02)
        let centerY = try! XCTUnwrap(clip.highMassCenterY)
        XCTAssertLessThan(centerY, 0.34) // top third
        XCTAssertEqual(HistogramCompute.frameRegion(forCenterY: centerY), .top)
    }

    func testFrameRegionMappingThirds() {
        XCTAssertEqual(HistogramCompute.frameRegion(forCenterY: 0.1), .top)
        XCTAssertEqual(HistogramCompute.frameRegion(forCenterY: 0.5), .middle)
        XCTAssertEqual(HistogramCompute.frameRegion(forCenterY: 0.9), .bottom)
        XCTAssertNil(HistogramCompute.frameRegion(forCenterY: nil))
    }

    func testGradientHistogramSpreadsAcrossManyBins() {
        let buf = gradientBuffer(width: 256, height: 4)
        let (hist, _) = HistogramCompute.compute(rgba8: buf, width: 256, height: 4,
                                                   highThreshold: 0.98, lowThreshold: 0.02)
        let nonZeroBins = hist.luma.filter { $0 > 0 }.count
        XCTAssertGreaterThan(nonZeroBins, HistogramData.binCount / 2)
    }

    func testZoneMassOnSyntheticEVRampSumsToAtMostOne() {
        // A ramp from -8 EV to 0 EV across the width, replicated down height.
        var evMap = [Float](repeating: 0, count: 16 * 4)
        for y in 0..<4 {
            for x in 0..<16 {
                evMap[y * 16 + x] = Float(-8.0 + (Double(x) / 15.0) * 8.0)
            }
        }
        let mass = HistogramCompute.zoneMass(evMap: evMap, width: 16, height: 4)
        XCTAssertEqual(mass.count, ToneZoneParams.zoneCount)
        XCTAssertLessThanOrEqual(mass.reduce(0, +), 1.0001)
        XCTAssertTrue(mass.allSatisfy { $0 >= 0 })
    }

    func testZoneMassAllZerosPutsEverythingInMidZones() {
        let evMap = [Float](repeating: -4, count: 8 * 8) // -4 EV, mid-range
        let mass = HistogramCompute.zoneMass(evMap: evMap, width: 8, height: 8)
        XCTAssertGreaterThan(mass.reduce(0, +), 0.9) // nearly all mass accounted for
    }

    func testCurveHistogramDerivesFromLumaChannel() {
        let hist = HistogramData(r: .init(repeating: 0, count: 64),
                                  g: .init(repeating: 0, count: 64),
                                  b: .init(repeating: 0, count: 64),
                                  luma: (0..<64).map { Float($0) / 63.0 })
        let curve = HistogramCompute.curveHistogram(from: hist)
        XCTAssertEqual(curve.bins.count, 64)
        XCTAssertEqual(curve.bins, hist.luma)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -scheme Muse -only-testing:MuseTests/HistogramComputeTests test`
Expected: FAIL — `HistogramCompute`/`HistogramData`/`ClippingStats`/`CurveHistogram`/
`FrameRegion`/`RGBChannel` don't exist.

- [ ] **Step 3: Implement**

```swift
//
//  HistogramCompute.swift
//  Muse
//
//  Pure statistics pass over raw RGBA8/Float32 buffers — zero Core Image
//  involvement, unit-tested on synthetic gradients. Feeds the teaching
//  histogram (Editing/ClippingMessages.swift + Views/Editor/HistogramView),
//  the curve panel's histogram-behind, and the tone-zone strip's mass bars.
//  One shared statistics pass, three consumers — see EditSession.stats.
//

import Foundation

nonisolated struct HistogramData: Equatable, Sendable {
    static let binCount = 64
    var r: [Float]
    var g: [Float]
    var b: [Float]
    var luma: [Float]
}

nonisolated enum RGBChannel: Equatable, Sendable {
    case red, green, blue
}

/// Coarse vertical position of a clip-mass centroid, 0 (top) ... 1 (bottom) of the
/// frame, bucketed into thirds. Drives the "mostly near the top" phrasing in
/// ClippingMessages WITHOUT any scene semantics — spatial attribution from stats
/// alone (spec-05 deviation D4).
nonisolated enum FrameRegion: Equatable, Sendable {
    case top, middle, bottom
}

nonisolated struct ClippingStats: Equatable, Sendable {
    /// Fixed thresholds for STORED capture stats (photo_traits) — pref-independent,
    /// single declaration site. The EDITOR's live stats + zebras use the
    /// user-adjustable AppSettings thresholds instead (Task 2.1/2.2), never these.
    static let storedHighThreshold: Double = 254.0 / 255.0
    static let storedLowThreshold: Double = 2.0 / 255.0

    var highR: Double
    var highG: Double
    var highB: Double
    var low: Double
    var highMassCenterY: Double?
    var lowMassCenterY: Double?
}

nonisolated struct CurveHistogram: Equatable, Sendable {
    let bins: [Float] // 64 luminance bins, drawn as a silent backdrop when non-nil
}

nonisolated enum HistogramCompute {

    /// One pass over an RGBA8 buffer producing both the 64-bin histogram and the
    /// clipping fractions/centroids, at the caller-supplied thresholds (live editor
    /// thresholds for the on-screen tap; ClippingStats.stored* for capture stats).
    static func compute(rgba8: [UInt8], width: Int, height: Int,
                         highThreshold: Double, lowThreshold: Double)
        -> (histogram: HistogramData, clipping: ClippingStats) {
        guard width > 0, height > 0, rgba8.count >= width * height * 4 else {
            let empty = HistogramData(r: .init(repeating: 0, count: HistogramData.binCount),
                                       g: .init(repeating: 0, count: HistogramData.binCount),
                                       b: .init(repeating: 0, count: HistogramData.binCount),
                                       luma: .init(repeating: 0, count: HistogramData.binCount))
            return (empty, ClippingStats(highR: 0, highG: 0, highB: 0, low: 0,
                                          highMassCenterY: nil, lowMassCenterY: nil))
        }
        let bins = HistogramData.binCount
        var rBins = [Int](repeating: 0, count: bins)
        var gBins = [Int](repeating: 0, count: bins)
        var bBins = [Int](repeating: 0, count: bins)
        var lumaBins = [Int](repeating: 0, count: bins)

        var highRCount = 0, highGCount = 0, highBCount = 0, lowCount = 0
        var highYSum: Double = 0, lowYSum: Double = 0
        let pixelCount = width * height

        let highT = highThreshold * 255.0
        let lowT = lowThreshold * 255.0

        for y in 0..<height {
            for x in 0..<width {
                let i = (y * width + x) * 4
                let r = Double(rgba8[i]), g = Double(rgba8[i + 1]), b = Double(rgba8[i + 2])
                let luma = 0.2126 * r + 0.7152 * g + 0.0722 * b

                rBins[binIndex(for: r, bins: bins)] += 1
                gBins[binIndex(for: g, bins: bins)] += 1
                bBins[binIndex(for: b, bins: bins)] += 1
                lumaBins[binIndex(for: luma, bins: bins)] += 1

                var pixelClippedHigh = false
                if r >= highT { highRCount += 1; pixelClippedHigh = true }
                if g >= highT { highGCount += 1; pixelClippedHigh = true }
                if b >= highT { highBCount += 1; pixelClippedHigh = true }
                if pixelClippedHigh { highYSum += Double(y) }
                if luma <= lowT { lowCount += 1; lowYSum += Double(y) }
            }
        }

        let maxBin = Double([rBins, gBins, bBins, lumaBins].flatMap { $0 }.max() ?? 1)
        let normalize: ([Int]) -> [Float] = { counts in
            counts.map { maxBin > 0 ? Float(Double($0) / maxBin) : 0 }
        }

        let histogram = HistogramData(r: normalize(rBins), g: normalize(gBins),
                                       b: normalize(bBins), luma: normalize(lumaBins))

        let highTotal = max(highRCount, max(highGCount, highBCount))
        let clipping = ClippingStats(
            highR: Double(highRCount) / Double(pixelCount),
            highG: Double(highGCount) / Double(pixelCount),
            highB: Double(highBCount) / Double(pixelCount),
            low: Double(lowCount) / Double(pixelCount),
            highMassCenterY: highTotal > 0 ? (highYSum / Double(highTotal)) / Double(max(height - 1, 1)) : nil,
            lowMassCenterY: lowCount > 0 ? (lowYSum / Double(lowCount)) / Double(max(height - 1, 1)) : nil)

        return (histogram, clipping)
    }

    private static func binIndex(for value: Double, bins: Int) -> Int {
        let clamped = min(max(value / 255.0, 0), 1)
        return min(Int(clamped * Double(bins)), bins - 1)
    }

    static func frameRegion(forCenterY y: Double?) -> FrameRegion? {
        guard let y else { return nil }
        if y <= 1.0 / 3.0 { return .top }
        if y >= 2.0 / 3.0 { return .bottom }
        return .middle
    }

    /// Fractional pixel mass per tone zone, from a smoothed-EV buffer (the same
    /// buffer ToneZoneFilter.smoothedEVMap produces) — feeds the zone strip's mass
    /// bars and the hover readout's "N% of pixels" phrase. Sum <= 1 (raised-cosine
    /// weights are a partition of unity; floating rounding may land fractionally
    /// under 1).
    static func zoneMass(evMap: [Float], width: Int, height: Int) -> [Double] {
        var mass = [Double](repeating: 0, count: ToneZoneParams.zoneCount)
        guard width > 0, height > 0, evMap.count >= width * height else { return mass }
        let total = Double(width * height)
        for value in evMap {
            let weights = ToneZoneMath.weights(forEV: Double(value))
            for i in 0..<ToneZoneParams.zoneCount {
                mass[i] += weights[i] / total
            }
        }
        return mass
    }

    /// Fills Spec 04's CurveEditorView(histogram:) seam — the curve panel's silent
    /// backdrop is exactly the luma channel of the same shared histogram.
    static func curveHistogram(from histogram: HistogramData) -> CurveHistogram {
        CurveHistogram(bins: histogram.luma)
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild -scheme Muse -only-testing:MuseTests/HistogramComputeTests test`
Expected: PASS (this task's `zoneMass` test references `ToneZoneParams.zoneCount`, already
defined in Task 0.1 — no forward dependency on Task 3.1's `ToneZoneMath.weights`, but the
implementation above DOES call it; if Task 3.1 hasn't landed yet when this task runs,
sequence Task 3.1 first or stub `ToneZoneMath.weights` minimally — in practice, do Task 3.1
before this task's Step 3 if executing tasks strictly in file order; the plan's phase order
(Phase 1 before Phase 3) is a SHIPPING order, not a strict code-dependency order, and this
is the one place they cross. Recommended: implement `ToneZoneMath` (Task 3.1) first as a
tiny prerequisite commit, then return to this task.)

- [ ] **Step 5: Commit**

```bash
git add "Muse/Muse/Editing/HistogramCompute.swift" "Muse/MuseTests/HistogramComputeTests.swift"
git commit -m "feat(editing): HistogramCompute — pure RGB/luma histogram, clipping fractions, zone mass, curve fill"
```

### Task 1.2: `EditStats` + `EditSession` statistics plumbing

**Files:**
- Modify: `Muse/Muse/Views/Editor/EditSession.swift` (add `stats`, `zoneEVMap`,
  `statsVisible`, `zebrasOn`, `toneZoneTargeting`, `hoveredZone`, the stats-tap hook into
  the render loop)
- Test: `Muse/MuseTests/EditSessionTests.swift` (extend)

**Interfaces:**
- Consumes: `HistogramCompute` (Task 1.1), `RenderCoalescer` (Spec 04 Task 3.7),
  `EditRenderer.apply` (Spec 04 Task 3.5).
- Produces:
  ```swift
  extension EditSession {
      @Published var stats: EditStats? { get }          // private(set), main-actor
      var zoneEVMap: ZoneEVMap? { get }                  // NOT @Published — read imperatively
      @Published var statsVisible: Bool
      @Published var zebrasOn: Bool
      @Published var toneZoneTargeting: Bool
      @Published var hoveredZone: Int?
  }
  nonisolated struct EditStats: Equatable, Sendable {
      var histogram: HistogramData; var clipping: ClippingStats
      var zoneMass: [Double]; var curveHistogram: CurveHistogram
  }
  nonisolated struct ZoneEVMap: Sendable { let width: Int; let height: Int; let values: [Float] }
  ```

- [ ] **Step 1: Write the failing test**

```swift
// Append to Muse/MuseTests/EditSessionTests.swift

extension EditSessionTests {
    func testStatsVisibleDefaultsFalse() {
        let session = EditSession(url: URL(fileURLWithPath: "/tmp/x.jpg"), stack: nil)
        XCTAssertFalse(session.statsVisible)
        XCTAssertNil(session.stats)
    }

    func testZebrasOnDefaultsFalseAndIsSessionScoped() {
        let session = EditSession(url: URL(fileURLWithPath: "/tmp/x.jpg"), stack: nil)
        XCTAssertFalse(session.zebrasOn)
        session.zebrasOn = true
        let other = EditSession(url: URL(fileURLWithPath: "/tmp/y.jpg"), stack: nil)
        XCTAssertFalse(other.zebrasOn) // a new session never inherits another's toggle
    }

    func testToneZoneTargetingAndHoveredZoneDefaults() {
        let session = EditSession(url: URL(fileURLWithPath: "/tmp/x.jpg"), stack: nil)
        XCTAssertFalse(session.toneZoneTargeting)
        XCTAssertNil(session.hoveredZone)
    }

    func testApplyStatsFromRenderStoresHistogramAndClipping() {
        let session = EditSession(url: URL(fileURLWithPath: "/tmp/x.jpg"), stack: nil)
        let hist = HistogramData(r: [1, 0, 0, 0], g: [1, 0, 0, 0], b: [1, 0, 0, 0], luma: [1, 0, 0, 0])
        let clip = ClippingStats(highR: 0.1, highG: 0.1, highB: 0.1, low: 0.0,
                                  highMassCenterY: nil, lowMassCenterY: nil)
        let stats = EditStats(histogram: hist, clipping: clip, zoneMass: [], curveHistogram: CurveHistogram(bins: []))
        session.applyStats(stats, zoneEVMap: nil)
        XCTAssertEqual(session.stats, stats)
        XCTAssertNil(session.zoneEVMap)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -scheme Muse -only-testing:MuseTests/EditSessionTests test`
Expected: FAIL — `EditSession` has no `statsVisible`/`zebrasOn`/`toneZoneTargeting`/
`hoveredZone`/`stats`/`zoneEVMap`/`applyStats`.

- [ ] **Step 3: Add `EditStats`/`ZoneEVMap` and extend `EditSession`**

Add to `Editing/HistogramCompute.swift` (co-located with its constituent types):

```swift
nonisolated struct EditStats: Equatable, Sendable {
    var histogram: HistogramData
    var clipping: ClippingStats
    var zoneMass: [Double]
    var curveHistogram: CurveHistogram
}

/// The tone-zone stage's smoothed-EV buffer at stats-tap resolution. Shared by the
/// hover readout (target mode) and the zone overlay's CPU-side hit test. NOT
/// published on EditSession — a per-render buffer publish would re-render every
/// observing panel for no reason; consumers read it imperatively on hover.
nonisolated struct ZoneEVMap: Sendable {
    let width: Int
    let height: Int
    let values: [Float]
}
```

In `EditSession.swift`, add alongside the existing `@Published` properties:

```swift
    @Published private(set) var stats: EditStats?
    private(set) var zoneEVMap: ZoneEVMap?
    @Published var statsVisible = false
    @Published var zebrasOn = false
    @Published var toneZoneTargeting = false
    @Published var hoveredZone: Int?

    /// Called by the render loop (Task 1.3's coalescer wiring) after a completed
    /// coalesced render, main-actor hop already done by the caller. One write for
    /// both fields keeps histogram/clipping/zone data mutually consistent for a
    /// single frame — never publish them separately.
    func applyStats(_ stats: EditStats, zoneEVMap: ZoneEVMap?) {
        self.stats = stats
        self.zoneEVMap = zoneEVMap
    }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild -scheme Muse -only-testing:MuseTests/EditSessionTests test`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add "Muse/Muse/Views/Editor/EditSession.swift" "Muse/Muse/Editing/HistogramCompute.swift" \
  "Muse/MuseTests/EditSessionTests.swift"
git commit -m "feat(editing): EditSession gains stats/zoneEVMap/statsVisible/zebrasOn/toneZoneTargeting/hoveredZone"
```

### Task 1.3: Wire the stats tap into the coalesced render loop

**Files:**
- Modify: `Muse/Muse/Views/Editor/EditCanvasView.swift` (or wherever the Spec 04 coalescer
  render call lives — `grep -rn "RenderCoalescer" Muse/Muse/Views/Editor/` to find the exact
  call site before editing)

**Interfaces:**
- Consumes: `RenderCoalescer` (Spec 04 Task 3.7), `EditRenderer.apply` (Spec 04 Task 3.5),
  `HistogramCompute.compute`/`.zoneMass`/`.curveHistogram` (Task 1.1),
  `ToneZoneFilter.smoothedEVMap` (Task 3.2 — forward dependency, see note below),
  `EditSession.applyStats`/`.statsVisible` (Task 1.2), `AppSettings.editorZebraHighKey`/
  `.editorZebraLowKey` (Task 2.1 — forward dependency, see note below).
- Produces: nothing new — this task closes the loop that makes `EditSession.stats` live.

*Note on forward dependencies: this task's implementation calls two functions
(`ToneZoneFilter.smoothedEVMap`, `AppSettings.editorZebra*`) that Tasks 2.1 and 3.2 define
later in this plan's numbering. Build this task's SHELL now (the tap site, gated on
`statsVisible`, computing histogram + clipping only) and extend it with the zone tap once
Task 3.2 lands — or, if executing strictly in dependency order, do Task 2.1 and Task 3.1–3.2
before this task's Step 3. The plan's phase order is a shipping/reviewability order; this is
the one call site that reads from a later phase.*

- [ ] **Step 1: Locate the coalesced render call site**

Run: `grep -rn "coalescer.request\|RenderCoalescer" Muse/Muse/Views/Editor/*.swift` — this
is the completion point where a `CGImage` comes back from `EditRenderer` after a slider
change (Spec 04 Task 3.7's `RenderCoalescer<EditStack, CGImage>` instance, likely owned by
`EditSession` or `EditCanvasView`).

- [ ] **Step 2: Add the stats tap as a sibling render, gated on `statsVisible`**

At the coalescer completion point, after the display `CGImage` is produced and BEFORE
returning it to the canvas, add (adjust the exact call shape to match wherever the
coalescer's `render:` closure is defined — this is the logical addition, not a literal
diff):

```swift
if session.statsVisible {
    Task.detached(priority: .userInitiated) {
        // 1. Display tap: downsample the SAME display-referred output already
        //    rendered for the canvas to statsSampleLongEdge, read back as RGBA8.
        let statsSampleLongEdge: CGFloat = 256
        guard let sampled = displayImage.downsampled(toLongEdge: statsSampleLongEdge),
              let rgba8 = sampled.rgba8Bytes()
        else { return }

        let highT = AppSettings.editorZebraHigh
        let lowT = AppSettings.editorZebraLow
        let (histogram, clipping) = HistogramCompute.compute(
            rgba8: rgba8.bytes, width: rgba8.width, height: rgba8.height,
            highThreshold: highT, lowThreshold: lowT)

        // 2. Zone tap: chain position 2b's INPUT (post-tone linear), through the
        //    same smoothed-EV pipeline the render stage uses, at the same sample
        //    size — three consumers, one mask (see ToneZoneFilter.smoothedEVMap).
        var zoneMass: [Double] = []
        var zoneEVMap: ZoneEVMap?
        if let postToneLinear = postToneImage,
           let evBuffer = ToneZoneFilter.smoothedEVMap(
               for: postToneLinear, longEdge: Int(statsSampleLongEdge)).float32Bytes() {
            zoneMass = HistogramCompute.zoneMass(evMap: evBuffer.values,
                                                  width: evBuffer.width, height: evBuffer.height)
            zoneEVMap = ZoneEVMap(width: evBuffer.width, height: evBuffer.height, values: evBuffer.values)
        }

        let stats = EditStats(histogram: histogram, clipping: clipping, zoneMass: zoneMass,
                               curveHistogram: HistogramCompute.curveHistogram(from: histogram))

        await MainActor.run {
            session.applyStats(stats, zoneEVMap: zoneEVMap)
        }
    }
}
```

(`displayImage.downsampled(toLongEdge:)` / `.rgba8Bytes()` / `.float32Bytes()` are small
`CIImage`/`CIContext` helpers — implement them as private extensions in this file using
`RenderContexts.preview` (Spec 04 Task 3.6) for the render + a `CGContext` byte readback,
the same technique `EditRenderConsistencyTests`' `meanChannelError` helper already uses;
factor a shared helper if one already exists post-Spec-04, don't duplicate.)

- [ ] **Step 3: Manual verification**

Build, run, open the editor, switch to the Scopes tab (or Light tab), drag a slider —
confirm the debug console (temporary `print(session.stats?.clipping)`) updates once per
completed render, and confirm nothing fires while on the Color/Presence tabs with Scopes
closed (toggle a `print` in the `if session.statsVisible` gate to verify it's skipped).
Remove the temporary print before committing.

- [ ] **Step 4: Commit**

```bash
git add "Muse/Muse/Views/Editor/EditCanvasView.swift"
git commit -m "feat(editing): stats tap piggybacked on RenderCoalescer — gated on EditSession.statsVisible"
```

### Task 1.4: `Views/Editor/ScopesPanel.swift` + `Views/Editor/HistogramView.swift`

**Files:**
- Create: `Muse/Muse/Views/Editor/HistogramView.swift`
- Create: `Muse/Muse/Views/Editor/ScopesPanel.swift`
- Modify: `Muse/Muse/Views/Editor/EditorView.swift` (replace the Scopes-tab empty scaffold;
  set `session.statsVisible = true` on Scopes/Light tab appear, `false` on disappear)

**Interfaces:**
- Consumes: `EditSession.stats` (Task 1.2), `Theme` (Spec 04 Task 5.1),
  `ToneParams.blacks`/`.exposureEV` (Spec 04 Task 1.1), `session.draft`/`.commitGesture()`
  (Spec 04 Task 5.2).
- Produces: `HistogramView(stats: EditStats?, showLuminance: Bool)`, `ScopesPanel` (the
  mounted tab content) — house convention, no UI unit tests; verified manually.

- [ ] **Step 1: Implement `HistogramView`**

```swift
//
//  HistogramView.swift
//  Muse
//
//  Draws EditStats.histogram: three channel paths composited with .screen blend
//  (additive overlap is what makes single-channel clipping visible), an optional
//  luminance overlay line, and a horizontal drag-to-adjust gesture (left third ->
//  blacks, right third -> exposure, middle inert — darktable's pattern).
//

import SwiftUI

struct HistogramView: View {
    let stats: EditStats?
    let showLuminance: Bool
    @ObservedObject var session: EditSession
    @Environment(\.theme) private var theme

    static let histogramHeight: CGFloat = 96
    private static let dragEVPerPoint = 0.01
    private static let dragBlacksPerPoint = 0.004

    var body: some View {
        GeometryReader { geo in
            ZStack {
                RoundedRectangle(cornerRadius: 6, style: .continuous).fill(theme.panelFill)
                if let stats {
                    channelPath(stats.histogram.r, in: geo.size).fill(Color.red.opacity(0.55))
                        .blendMode(.screen)
                    channelPath(stats.histogram.g, in: geo.size).fill(Color.green.opacity(0.55))
                        .blendMode(.screen)
                    channelPath(stats.histogram.b, in: geo.size).fill(Color.blue.opacity(0.55))
                        .blendMode(.screen)
                    if showLuminance {
                        channelStroke(stats.histogram.luma, in: geo.size)
                            .stroke(theme.controlAccent, lineWidth: 1)
                    }
                }
            }
            .contentShape(Rectangle())
            .onHover { inside in
                if inside { NSCursor.resizeLeftRight.set() } else { NSCursor.arrow.set() }
            }
            .gesture(
                DragGesture(minimumDistance: 2)
                    .onChanged { value in handleDrag(value, width: geo.size.width) }
                    .onEnded { _ in session.commitGesture() }
            )
        }
        .frame(height: Self.histogramHeight)
    }

    private func channelPath(_ bins: [Float], in size: CGSize) -> Path {
        Path { path in
            guard !bins.isEmpty else { return }
            let stepX = size.width / CGFloat(bins.count)
            path.move(to: CGPoint(x: 0, y: size.height))
            for (i, v) in bins.enumerated() {
                let x = CGFloat(i) * stepX
                let y = size.height * (1 - CGFloat(v))
                path.addLine(to: CGPoint(x: x, y: y))
            }
            path.addLine(to: CGPoint(x: size.width, y: size.height))
            path.closeSubpath()
        }
    }

    private func channelStroke(_ bins: [Float], in size: CGSize) -> Path {
        Path { path in
            guard !bins.isEmpty else { return }
            let stepX = size.width / CGFloat(bins.count)
            for (i, v) in bins.enumerated() {
                let x = CGFloat(i) * stepX
                let y = size.height * (1 - CGFloat(v))
                if i == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
            }
        }
    }

    private func handleDrag(_ value: DragGesture.Value, width: CGFloat) {
        let startThird = value.startLocation.x / max(width, 1)
        let dx = Double(value.translation.width - lastTranslation)
        lastTranslation = value.translation.width
        if startThird < 1.0 / 3.0 {
            var tone = session.draft.toneParams ?? .neutral
            tone.blacks = min(max(tone.blacks + dx * Self.dragBlacksPerPoint, -1), 1)
            session.draft.adjustments.removeAll { if case .tone = $0 { true } else { false } }
            session.draft.adjustments.append(.tone(tone))
        } else if startThird > 2.0 / 3.0 {
            var tone = session.draft.toneParams ?? .neutral
            tone.exposureEV = min(max(tone.exposureEV + dx * Self.dragEVPerPoint, -5), 5)
            session.draft.adjustments.removeAll { if case .tone = $0 { true } else { false } }
            session.draft.adjustments.append(.tone(tone))
        }
        // middle third: inert, no-op
    }
}

private var lastTranslation: CGFloat = 0
```

(The file-scope `lastTranslation` above is a placeholder for gesture-delta tracking — move
it to a `@State private var lastTranslation: CGFloat = 0` on `HistogramView` itself, since a
global `var` is not safe for multiple concurrent histogram instances; this is a real bug in
the block above, fixed as: replace the file-scope declaration with a `@State` property on
the struct, initialize `lastTranslation = 0` in `.onChanged`'s `if value.translation ==
.zero` branch or via `.onEnded` reset, whichever reads cleaner once implemented against a
live gesture — verify manually that a fresh drag starts from a zero delta.)

- [ ] **Step 2: Implement `ScopesPanel`**

```swift
//
//  ScopesPanel.swift
//  Muse
//
//  Replaces Spec 04's empty Scopes-tab scaffold. Top to bottom: HistogramView,
//  the luminance-overlay toggle, the plain-English clipping messages (Task 1.5).
//

import SwiftUI

struct ScopesPanel: View {
    @ObservedObject var session: EditSession
    @Environment(\.theme) private var theme
    @State private var showLuminance = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HistogramView(stats: session.stats, showLuminance: showLuminance, session: session)
            Toggle(String(localized: "Luminance"), isOn: $showLuminance)
                .font(theme.labelFont)
            if let stats = session.stats {
                ForEach(Array(ClippingMessages.compose(stats.clipping).enumerated()), id: \.offset) { _, message in
                    Text(message.displayText)
                        .font(theme.labelFont)
                        .foregroundStyle(theme.secondaryLabel)
                }
            }
        }
        .padding(12)
        .onAppear { session.statsVisible = true }
        .onDisappear { session.statsVisible = false }
    }
}
```

- [ ] **Step 3: Mount in `EditorView`, replacing the Scopes-tab placeholder**

`grep -n "Scopes" Muse/Muse/Views/Editor/EditorView.swift` — replace whatever placeholder
view Spec 04 left with `ScopesPanel(session: session)`. Also update the Light tab (where
the curve editor lives) to set `session.statsVisible = true` on appear if Scopes isn't the
only stats-visible surface — per spec-05 §2.2, statsVisible should be true while EITHER the
Light tab (curve + zone strip) OR the Scopes tab is showing. If `EditorView` tracks the
active left-card tab as a single `@State` enum, wire a computed binding:

```swift
.onChange(of: activeLeftTab) { _, newTab in
    session.statsVisible = (newTab == .light || newTab == .scopes)
}
```

- [ ] **Step 4: Manual verification**

Build, run, open the editor, switch to Scopes — confirm the histogram renders and updates
while dragging Exposure/Blacks in the Light tab (statsVisible stays true across both tabs
per Step 3), and confirm it stops updating (or the tap simply doesn't fire — verify via the
Task 1.3 temporary print re-added briefly) when switching to Color/Presence with Scopes
closed. Confirm the drag-to-adjust gesture on the histogram itself moves Blacks/Exposure and
produces exactly one undo step per drag.

- [ ] **Step 5: Commit**

```bash
git add "Muse/Muse/Views/Editor/HistogramView.swift" "Muse/Muse/Views/Editor/ScopesPanel.swift" \
  "Muse/Muse/Views/Editor/EditorView.swift"
git commit -m "feat(editing): ScopesPanel + HistogramView — teaching histogram, luminance toggle, drag-to-adjust"
```

### Task 1.5: `Editing/ClippingMessages.swift` — plain-English clipping messages

**Files:**
- Create: `Muse/Muse/Editing/ClippingMessages.swift`
- Test: `Muse/MuseTests/ClippingMessagesTests.swift`

**Interfaces:**
- Consumes: `ClippingStats`, `FrameRegion`, `RGBChannel` (Task 1.1).
- Produces:
  ```swift
  nonisolated enum ClippingMessage: Equatable {
      case highlightsClipping(percent: Double, channel: RGBChannel?, region: FrameRegion?)
      case shadowsCrushed(percent: Double, region: FrameRegion?)
      var displayText: String { get }
  }
  nonisolated enum ClippingMessages {
      static let messageFloor = 0.001
      static let channelDominanceRatio = 3.0
      static func compose(_ c: ClippingStats) -> [ClippingMessage]
  }
  ```

- [ ] **Step 1: Write the failing test**

```swift
//
//  ClippingMessagesTests.swift
//  MuseTests
//

import XCTest
@testable import Muse

final class ClippingMessagesTests: XCTestCase {

    func neutralClipping() -> ClippingStats {
        ClippingStats(highR: 0, highG: 0, highB: 0, low: 0, highMassCenterY: nil, lowMassCenterY: nil)
    }

    func testBelowFloorProducesNoMessages() {
        var c = neutralClipping()
        c.highR = 0.0005 // below messageFloor (0.001)
        XCTAssertTrue(ClippingMessages.compose(c).isEmpty)
    }

    func testAtFloorProducesAMessage() {
        var c = neutralClipping()
        c.highR = 0.001
        c.highG = 0.001
        c.highB = 0.001
        XCTAssertFalse(ClippingMessages.compose(c).isEmpty)
    }

    func testDominantSingleChannelNamesIt() {
        var c = neutralClipping()
        c.highR = 0.03  // 3x the others -> named
        c.highG = 0.005
        c.highB = 0.005
        let messages = ClippingMessages.compose(c)
        guard case .highlightsClipping(_, let channel, _) = messages.first(where: {
            if case .highlightsClipping = $0 { true } else { false }
        }) else { return XCTFail("expected a highlightsClipping message") }
        XCTAssertEqual(channel, .red)
    }

    func testAllChannelsCloseTogetherProducesCombinedMessageWithNilChannel() {
        var c = neutralClipping()
        c.highR = 0.02
        c.highG = 0.018
        c.highB = 0.019
        let messages = ClippingMessages.compose(c)
        guard case .highlightsClipping(_, let channel, _) = messages.first(where: {
            if case .highlightsClipping = $0 { true } else { false }
        }) else { return XCTFail("expected a highlightsClipping message") }
        XCTAssertNil(channel)
    }

    func testShadowsCrushedFiresIndependentlyOfHighlights() {
        var c = neutralClipping()
        c.low = 0.05
        let messages = ClippingMessages.compose(c)
        XCTAssertTrue(messages.contains { if case .shadowsCrushed = $0 { true } else { false } })
    }

    func testAtMostTwoMessages() {
        var c = neutralClipping()
        c.highR = 0.5; c.highG = 0.5; c.highB = 0.5
        c.low = 0.5
        XCTAssertLessThanOrEqual(ClippingMessages.compose(c).count, 2)
    }

    func testRegionPhrasingPresentWhenCentroidKnown() {
        var c = neutralClipping()
        c.highR = 0.02; c.highG = 0.02; c.highB = 0.02
        c.highMassCenterY = 0.1 // top
        let messages = ClippingMessages.compose(c)
        guard case .highlightsClipping(_, _, let region) = messages.first(where: {
            if case .highlightsClipping = $0 { true } else { false }
        }) else { return XCTFail() }
        XCTAssertEqual(region, .top)
    }

    func testRegionPhrasingAbsentWhenCentroidNil() {
        var c = neutralClipping()
        c.highR = 0.02; c.highG = 0.02; c.highB = 0.02
        c.highMassCenterY = nil
        let messages = ClippingMessages.compose(c)
        guard case .highlightsClipping(_, _, let region) = messages.first(where: {
            if case .highlightsClipping = $0 { true } else { false }
        }) else { return XCTFail() }
        XCTAssertNil(region)
    }

    func testDisplayTextIsNonEmptyForEveryCase() {
        let highlights = ClippingMessage.highlightsClipping(percent: 0.004, channel: .red, region: .top)
        let shadows = ClippingMessage.shadowsCrushed(percent: 0.03, region: nil)
        XCTAssertFalse(highlights.displayText.isEmpty)
        XCTAssertFalse(shadows.displayText.isEmpty)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -scheme Muse -only-testing:MuseTests/ClippingMessagesTests test`
Expected: FAIL — `ClippingMessage`/`ClippingMessages` don't exist.

- [ ] **Step 3: Implement**

```swift
//
//  ClippingMessages.swift
//  Muse
//
//  Deterministic, stats-only clipping messages for the Scopes panel. The
//  Darkroom-style spatial flavor ("mostly the sky") ships as a stats-only clip-
//  mass centroid -> top/middle/bottom phrasing, never scene semantics
//  (spec-05 deviation D4). These read the LIVE editor thresholds (the same
//  AppSettings values the zebra kernel uses) so the numbers always agree with
//  what's on screen.
//

import Foundation

nonisolated enum ClippingMessage: Equatable {
    case highlightsClipping(percent: Double, channel: RGBChannel?, region: FrameRegion?)
    case shadowsCrushed(percent: Double, region: FrameRegion?)

    var displayText: String {
        switch self {
        case .highlightsClipping(let percent, let channel, let region):
            let pctText = String(format: "%.1f", percent * 100)
            switch (channel, region) {
            case (.some(let ch), .some(let r)):
                return String(localized: "\(pctText)% of pixels are clipping in the \(ch.name) channel, mostly \(r.name).")
            case (.some(let ch), .none):
                return String(localized: "\(pctText)% of pixels are clipping in the \(ch.name) channel.")
            case (.none, .some(let r)):
                return String(localized: "\(pctText)% of pixels are clipped, mostly \(r.name).")
            case (.none, .none):
                return String(localized: "\(pctText)% of pixels are clipped — those areas have lost detail.")
            }
        case .shadowsCrushed(let percent, let region):
            let pctText = String(format: "%.1f", percent * 100)
            if let region {
                return String(localized: "Deep shadows cover \(pctText)% of the frame, mostly \(region.name) — some shadow detail is gone.")
            }
            return String(localized: "Deep shadows cover \(pctText)% of the frame — some shadow detail is gone.")
        }
    }
}

nonisolated enum ClippingMessages {
    static let messageFloor = 0.001          // 0.1% — below, stay silent
    static let channelDominanceRatio = 3.0   // one channel >= 3x the others -> name it

    static func compose(_ c: ClippingStats) -> [ClippingMessage] {
        var messages: [ClippingMessage] = []

        let maxHigh = max(c.highR, max(c.highG, c.highB))
        if maxHigh >= messageFloor {
            let others = [c.highR, c.highG, c.highB].filter { $0 != maxHigh }
            let secondHighest = others.max() ?? 0
            let dominant = secondHighest > 0 && maxHigh >= secondHighest * channelDominanceRatio
            let channel: RGBChannel? = dominant ? dominantChannel(c) : nil
            let region = HistogramCompute.frameRegion(forCenterY: c.highMassCenterY)
            messages.append(.highlightsClipping(percent: maxHigh, channel: channel, region: region))
        }

        if c.low >= messageFloor {
            let region = HistogramCompute.frameRegion(forCenterY: c.lowMassCenterY)
            messages.append(.shadowsCrushed(percent: c.low, region: region))
        }

        return messages
    }

    private static func dominantChannel(_ c: ClippingStats) -> RGBChannel {
        if c.highR >= c.highG && c.highR >= c.highB { return .red }
        if c.highG >= c.highR && c.highG >= c.highB { return .green }
        return .blue
    }
}

private extension RGBChannel {
    var name: String {
        switch self {
        case .red: String(localized: "red")
        case .green: String(localized: "green")
        case .blue: String(localized: "blue")
        }
    }
}

private extension FrameRegion {
    var name: String {
        switch self {
        case .top: String(localized: "near the top of the frame")
        case .middle: String(localized: "in the middle of the frame")
        case .bottom: String(localized: "near the bottom of the frame")
        }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild -scheme Muse -only-testing:MuseTests/ClippingMessagesTests test`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add "Muse/Muse/Editing/ClippingMessages.swift" "Muse/MuseTests/ClippingMessagesTests.swift"
git commit -m "feat(editing): ClippingMessages — deterministic plain-English clipping copy"
```

---

## Phase 2 — Clipping zebras

### Task 2.1: `zebraStripes` kernel + AppSettings thresholds

**Files:**
- Modify: `Muse/Muse/Editing/Render/EditKernels.metal` (add `zebraStripes`)
- Modify: `Muse/Muse/Editing/Render/EditKernels.swift` (load it)
- Modify: `Muse/Muse/Settings/AppSettings.swift` (add `editorZebraHighKey`/
  `editorZebraLowKey` accessors)
- Test: `Muse/MuseTests/EditKernelLoadTests.swift` (extend)

**Interfaces:**
- Consumes: nothing new.
- Produces: `EditKernels.zebraStripes: CIColorKernel`, `AppSettings.editorZebraHigh: Double`
  (default 0.98), `AppSettings.editorZebraLow: Double` (default 0.02).

- [ ] **Step 1: Write the failing test**

```swift
// Append to Muse/MuseTests/EditKernelLoadTests.swift

extension EditKernelLoadTests {
    func testZebraStripesKernelLoadsFromDefaultMetallib() {
        XCTAssertNoThrow(_ = EditKernels.zebraStripes)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -scheme Muse -only-testing:MuseTests/EditKernelLoadTests test`
Expected: FAIL — `EditKernels.zebraStripes` doesn't exist.

- [ ] **Step 3: Add the Metal kernel**, appended to `Editing/Render/EditKernels.metal`:

```metal
/// zebraStripes: animated-free diagonal-stripe overlay marking clipped pixels.
/// ANY channel >= highThreshold -> white/red 45-degree stripes; luminance <=
/// lowThreshold -> blue stripes; everything else passes through unchanged.
/// Applied as the LAST compositing step over the display-referred canvas output
/// (post tone-map) — display clipping is what the thresholds mean; raw-sensor
/// clipping is skipped, not faked (CIRAWFilter exposes no pre-demosaic tap).
extern "C" float4 zebraStripes(coreimage::sample_t s, float highThreshold,
                                 float lowThreshold, float phase,
                                 coreimage::destination dest) {
    const float zebraPeriodPx = 8.0;
    float2 coord = dest.coord();
    float diagonal = fmod(coord.x + coord.y + phase, zebraPeriodPx);
    bool stripeOn = diagonal < zebraPeriodPx * 0.5;

    bool clippedHigh = s.r >= highThreshold || s.g >= highThreshold || s.b >= highThreshold;
    float luma = dot(s.rgb, float3(0.2126, 0.7152, 0.0722));
    bool clippedLow = luma <= lowThreshold;

    if (clippedHigh) {
        float3 stripeColor = stripeOn ? float3(1.0, 1.0, 1.0) : float3(1.0, 0.0, 0.0);
        return float4(stripeColor, s.a);
    }
    if (clippedLow) {
        float3 stripeColor = stripeOn ? float3(0.0, 0.3, 1.0) : s.rgb;
        return float4(stripeColor, s.a);
    }
    return s;
}
```

- [ ] **Step 4: Add the Swift wrapper entry to `EditKernels.swift`**

```swift
extension EditKernels {
    static let zebraStripes: CIColorKernel = {
        guard let url = Bundle.main.url(forResource: "default", withExtension: "metallib"),
              let data = try? Data(contentsOf: url),
              let kernel = try? CIColorKernel(functionName: "zebraStripes", fromMetalLibraryData: data)
        else { fatalError("zebraStripes kernel failed to load from default metallib") }
        return kernel
    }()

    static let zebraPeriodPx: CGFloat = 8
}
```

- [ ] **Step 5: Add the AppSettings accessors**

In `Settings/AppSettings.swift`, following the file's existing `static let ...Key` +
computed-property accessor pattern:

```swift
    static let editorZebraHighKey = "editorZebraHigh"
    static let editorZebraLowKey = "editorZebraLow"

    /// Highlight-clipping zebra threshold, 0...1 fraction of full scale. Default 0.98.
    /// Shared by the zebra kernel, the live ClippingStats compute, and the Scopes
    /// clipping messages — never fork this constant (spec-05 durable constraint).
    static var editorZebraHigh: Double {
        let v = UserDefaults.standard.object(forKey: editorZebraHighKey) as? Double ?? 0.98
        return min(max(v, 0.90), 1.00)
    }

    /// Shadow-crush zebra threshold, 0...1 fraction of full scale. Default 0.02.
    static var editorZebraLow: Double {
        let v = UserDefaults.standard.object(forKey: editorZebraLowKey) as? Double ?? 0.02
        return min(max(v, 0.00), 0.10)
    }
```

- [ ] **Step 6: Run test to verify it passes**

Run: `xcodebuild -scheme Muse -only-testing:MuseTests/EditKernelLoadTests test`
Expected: PASS

- [ ] **Step 7: Commit**

```bash
git add "Muse/Muse/Editing/Render/EditKernels.metal" "Muse/Muse/Editing/Render/EditKernels.swift" \
  "Muse/Muse/Settings/AppSettings.swift" "Muse/MuseTests/EditKernelLoadTests.swift"
git commit -m "feat(editing): zebraStripes kernel + AppSettings.editorZebraHigh/Low thresholds"
```

### Task 2.2: Zebra toggle chrome, J key, threshold popover, canvas composite

**Files:**
- Modify: `Muse/Muse/Views/Editor/EditCanvasView.swift` (composite `zebraStripes` as the
  last draw step when `session.zebrasOn`)
- Modify: `Muse/Muse/Views/Editor/EditorView.swift` (toolbar toggle button + threshold
  popover)
- Modify: `Muse/Muse/Views/KeyCaptureView.swift` (J key while in Edit mode)

**Interfaces:**
- Consumes: `EditSession.zebrasOn` (Task 1.2), `EditKernels.zebraStripes`/`.zebraPeriodPx`
  (Task 2.1), `AppSettings.editorZebraHigh`/`.editorZebraLow` (Task 2.1).
- Produces: nothing new — this task is UI wiring, house convention (no UI unit tests),
  verified manually.

- [ ] **Step 1: Composite the kernel in `EditCanvasView`'s draw step**

`grep -n "func draw\|MTKView" Muse/Muse/Views/Editor/EditCanvasView.swift` to find the
canvas draw path. As the LAST compositing step, after the display-referred image is ready:

```swift
var finalImage = displayImage
if session.zebrasOn {
    let phase = Float(CACurrentMediaTime().truncatingRemainder(dividingBy: 1000)) // static per frame, no animation
    finalImage = EditKernels.zebraStripes.apply(
        extent: finalImage.extent,
        roiCallback: { _, rect in rect },
        arguments: [finalImage, AppSettings.editorZebraHigh, AppSettings.editorZebraLow, phase]
    ) ?? finalImage
}
```

(`zebraStripes` is deliberately drawn with a FIXED, non-animating phase per spec-05 §4.1
"animated-free" — the `phase` argument exists so the stripe origin is stable across a pan/
zoom re-render, not so it moves over time; pass a constant like `0` if the kernel's stripe
alignment doesn't need to track canvas position, or the canvas's scroll offset if it does —
confirm against the running app which reads more stable, and pin the choice as a comment.)

- [ ] **Step 2: Add the toolbar toggle button**

In `EditorView.swift`'s editor-chrome toolbar row (alongside other Spec 04 mode buttons):

```swift
Button {
    session.zebrasOn.toggle()
} label: {
    Image(systemName: "circle.lefthalf.striped.horizontal")
        .foregroundStyle(session.zebrasOn ? theme.controlAccent : theme.iconDefault)
}
.buttonStyle(.plain)
.help(String(localized: "Clipping Zebras"))
.contextMenu {
    // long-press/right-click threshold popover trigger
    Button(String(localized: "Zebra Thresholds…")) { showZebraThresholds = true }
}
.popover(isPresented: $showZebraThresholds) {
    ZebraThresholdsPopover()
}
```

Add `@State private var showZebraThresholds = false` to `EditorView`, and a small popover
view in the same file:

```swift
private struct ZebraThresholdsPopover: View {
    @State private var high = AppSettings.editorZebraHigh
    @State private var low = AppSettings.editorZebraLow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading) {
                Text(String(localized: "Over")).font(.caption)
                Slider(value: $high, in: 0.90...1.00) { _ in
                    UserDefaults.standard.set(high, forKey: AppSettings.editorZebraHighKey)
                }
            }
            VStack(alignment: .leading) {
                Text(String(localized: "Under")).font(.caption)
                Slider(value: $low, in: 0.00...0.10) { _ in
                    UserDefaults.standard.set(low, forKey: AppSettings.editorZebraLowKey)
                }
            }
        }
        .padding(12)
        .frame(width: 220)
    }
}
```

- [ ] **Step 3: Wire the J key**

`grep -n "onKey\|keyDown" Muse/Muse/Views/KeyCaptureView.swift` — the existing
`KeyCaptureView` handles `onLeft`/`onRight`/`onReturn` by keycode (123/124/36). Add a
generic passthrough for arbitrary keys the hero/editor wants to observe, since J
(keycode 38, Lightroom's clipping-toggle convention) isn't one of the three hardcoded
handlers:

```swift
struct KeyCaptureView: NSViewRepresentable {
    var onLeft: () -> Void
    var onRight: () -> Void
    var onReturn: () -> Void
    var onKey: ((UInt16) -> Bool)? = nil  // return true if consumed

    func makeNSView(context: Context) -> KeyView {
        let v = KeyView()
        v.onLeft = onLeft; v.onRight = onRight; v.onReturn = onReturn; v.onKey = onKey
        DispatchQueue.main.async { v.window?.makeFirstResponder(v) }
        return v
    }
    func updateNSView(_ nsView: KeyView, context: Context) {
        nsView.onLeft = onLeft; nsView.onRight = onRight; nsView.onReturn = onReturn; nsView.onKey = onKey
    }

    final class KeyView: NSView {
        var onLeft: (() -> Void)?
        var onRight: (() -> Void)?
        var onReturn: (() -> Void)?
        var onKey: ((UInt16) -> Bool)?
        override var acceptsFirstResponder: Bool { true }
        override func keyDown(with event: NSEvent) {
            if let onKey, onKey(event.keyCode) { return }
            switch event.keyCode {
            case 123: onLeft?()
            case 124: onRight?()
            case 36:  onReturn?()
            default:  super.keyDown(with: event)
            }
        }
    }
}
```

(If Spec 04 or Spec 03 already added an `onKey` passthrough of this shape per spec-05 §4.2's
"whichever lands first adds it" — `grep -n "onKey" Muse/Muse/Views/KeyCaptureView.swift`
FIRST and skip this step if it's already present with a compatible signature.)

Wire it from the hero/editor's `KeyCaptureView` instantiation:

```swift
KeyCaptureView(onLeft: { ... }, onRight: { ... }, onReturn: { ... }, onKey: { keyCode in
    guard editMode, keyCode == 38 else { return false } // J
    session.zebrasOn.toggle()
    return true
})
```

- [ ] **Step 4: Manual verification**

Build, run, enter Edit mode on a photo with a bright sky, press J — confirm zebras appear
over blown highlights and toggle off on second press; confirm the toolbar button reflects
the same state; open the thresholds popover, drag Over down toward 0.90 — confirm more area
zebras (agreeing with the Scopes clipping percentage, per Task 1.3's shared-threshold read).

- [ ] **Step 5: Commit**

```bash
git add "Muse/Muse/Views/Editor/EditCanvasView.swift" "Muse/Muse/Views/Editor/EditorView.swift" \
  "Muse/Muse/Views/KeyCaptureView.swift"
git commit -m "feat(editing): zebra toggle (chrome + J key) + threshold popover, canvas composite"
```

---

## Phase 3 — Tone-zone control (the flagship)

### Task 3.1: `Editing/ToneZoneMath.swift` — pure zone math

**Files:**
- Create: `Muse/Muse/Editing/ToneZoneMath.swift`
- Test: `Muse/MuseTests/ToneZoneMathTests.swift`

**Interfaces:**
- Consumes: `ToneZoneParams` (Task 0.1).
- Produces:
  ```swift
  nonisolated enum ToneZoneMath {
      static let zoneCount = ToneZoneParams.zoneCount
      static let evFloor: Double = -8
      static let evCeiling: Double = 0
      static let maxZoneEV: Double = 2.0
      static func weights(forEV ev: Double) -> [Double]
      static func zoneIndex(forEV ev: Double) -> Int
      static func gainEV(forEV ev: Double, gains: [Double]) -> Double
  }
  ```

- [ ] **Step 1: Write the failing test**

```swift
//
//  ToneZoneMathTests.swift
//  MuseTests
//

import XCTest
@testable import Muse

final class ToneZoneMathTests: XCTestCase {

    func testWeightsSumToOneAcrossFullEVRange() {
        var ev = ToneZoneMath.evFloor
        while ev <= ToneZoneMath.evCeiling {
            let weights = ToneZoneMath.weights(forEV: ev)
            XCTAssertEqual(weights.count, ToneZoneMath.zoneCount)
            XCTAssertEqual(weights.reduce(0, +), 1.0, accuracy: 1e-6, "EV \(ev)")
            ev += 0.25
        }
    }

    func testWeightsAreNonNegative() {
        let weights = ToneZoneMath.weights(forEV: -3.5)
        XCTAssertTrue(weights.allSatisfy { $0 >= 0 })
    }

    func testEVBelowFloorClampsToEndZone() {
        let belowFloor = ToneZoneMath.weights(forEV: -20)
        let atFloor = ToneZoneMath.weights(forEV: ToneZoneMath.evFloor)
        XCTAssertEqual(belowFloor, atFloor)
    }

    func testEVAboveCeilingClampsToEndZone() {
        let aboveCeiling = ToneZoneMath.weights(forEV: 20)
        let atCeiling = ToneZoneMath.weights(forEV: ToneZoneMath.evCeiling)
        XCTAssertEqual(aboveCeiling, atCeiling)
    }

    func testZoneIndexAtFloorIsZero() {
        XCTAssertEqual(ToneZoneMath.zoneIndex(forEV: ToneZoneMath.evFloor), 0)
    }

    func testZoneIndexAtCeilingIsLast() {
        XCTAssertEqual(ToneZoneMath.zoneIndex(forEV: ToneZoneMath.evCeiling), ToneZoneMath.zoneCount - 1)
    }

    func testZoneIndexMidpointIsMiddleZone() {
        let mid = (ToneZoneMath.evFloor + ToneZoneMath.evCeiling) / 2
        XCTAssertEqual(ToneZoneMath.zoneIndex(forEV: mid), ToneZoneMath.zoneCount / 2)
    }

    func testZoneIndexIsMonotonicNondecreasing() {
        var previous = ToneZoneMath.zoneIndex(forEV: ToneZoneMath.evFloor)
        var ev = ToneZoneMath.evFloor
        while ev <= ToneZoneMath.evCeiling {
            let idx = ToneZoneMath.zoneIndex(forEV: ev)
            XCTAssertGreaterThanOrEqual(idx, previous)
            previous = idx
            ev += 0.5
        }
    }

    func testGainEVZeroAtAllZeroGains() {
        let gains = [Double](repeating: 0, count: ToneZoneMath.zoneCount)
        XCTAssertEqual(ToneZoneMath.gainEV(forEV: -4, gains: gains), 0, accuracy: 1e-9)
    }

    func testGainEVAtZoneCenterEqualsThatZonesGainTimesMaxZoneEV() {
        var gains = [Double](repeating: 0, count: ToneZoneMath.zoneCount)
        gains[0] = 1.0 // deepest-shadow zone, full positive gain
        let stepEV = (ToneZoneMath.evCeiling - ToneZoneMath.evFloor) / Double(ToneZoneMath.zoneCount - 1)
        let zoneCenterEV = ToneZoneMath.evFloor + 0 * stepEV
        let gainEV = ToneZoneMath.gainEV(forEV: zoneCenterEV, gains: gains)
        XCTAssertEqual(gainEV, ToneZoneMath.maxZoneEV, accuracy: 0.05)
    }

    func testGainEVIsLinearInGainMagnitude() {
        var gainsHalf = [Double](repeating: 0, count: ToneZoneMath.zoneCount)
        gainsHalf[4] = 0.5
        var gainsFull = [Double](repeating: 0, count: ToneZoneMath.zoneCount)
        gainsFull[4] = 1.0
        let stepEV = (ToneZoneMath.evCeiling - ToneZoneMath.evFloor) / Double(ToneZoneMath.zoneCount - 1)
        let centerEV = ToneZoneMath.evFloor + 4 * stepEV
        let half = ToneZoneMath.gainEV(forEV: centerEV, gains: gainsHalf)
        let full = ToneZoneMath.gainEV(forEV: centerEV, gains: gainsFull)
        XCTAssertEqual(full, half * 2, accuracy: 0.05)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -scheme Muse -only-testing:MuseTests/ToneZoneMathTests test`
Expected: FAIL — `ToneZoneMath` doesn't exist.

- [ ] **Step 3: Implement**

```swift
//
//  ToneZoneMath.swift
//  Muse
//
//  Pure math for the tone-zone control — a raised-cosine partition of unity over
//  EV, mirrored by the Metal kernel (Task 3.2) and pinned together through the
//  render consistency/neutrality goldens (Task 3.3), the ClipTokenizer-fixture
//  pattern (CPU truth, GPU checked against it through rendered output).
//

import Foundation

nonisolated enum ToneZoneMath {
    static let zoneCount = ToneZoneParams.zoneCount      // 9
    static let evFloor: Double = -8                      // zone 0 center
    static let evCeiling: Double = 0                      // zone 8 center
    static let maxZoneEV: Double = 2.0                    // gain -1...+1 -> +-2 EV

    private static var zoneCenters: [Double] {
        let step = (evCeiling - evFloor) / Double(zoneCount - 1)
        return (0..<zoneCount).map { evFloor + Double($0) * step }
    }

    /// Raised-cosine weights over EV, a partition of unity: sum of weights == 1
    /// for every EV in range (and at the clamped ends). Each weight peaks at 1 at
    /// its own zone's center and falls to 0 at the neighboring zones' centers.
    static func weights(forEV ev: Double) -> [Double] {
        let clampedEV = min(max(ev, evFloor), evCeiling)
        let centers = zoneCenters
        let step = (evCeiling - evFloor) / Double(zoneCount - 1)
        var raw = [Double](repeating: 0, count: zoneCount)
        for i in 0..<zoneCount {
            let distance = abs(clampedEV - centers[i]) / step
            if distance < 1 {
                raw[i] = 0.5 * (1 + cos(.pi * distance)) // raised cosine, 1 at distance 0, 0 at distance 1
            }
        }
        let sum = raw.reduce(0, +)
        guard sum > 0 else {
            // clampedEV sits exactly at an end zone's center with no neighbor on one
            // side — the single nonzero weight already sums to ~1; guard divide-by-
            // zero defensively and fall back to a one-hot at the nearest zone.
            var oneHot = [Double](repeating: 0, count: zoneCount)
            oneHot[zoneIndex(forEV: clampedEV)] = 1
            return oneHot
        }
        return raw.map { $0 / sum }
    }

    /// The single zone whose weight is highest at this EV — used for the strip's
    /// "which cell is this" hover mapping and the overlay's dominant-zone test.
    static func zoneIndex(forEV ev: Double) -> Int {
        let w = weights(forEV: ev)
        var bestIndex = 0
        var bestWeight = w[0]
        for i in 1..<w.count where w[i] > bestWeight {
            bestWeight = w[i]
            bestIndex = i
        }
        return bestIndex
    }

    /// Sum(weight_i * gain_i * maxZoneEV) — the per-pixel exposure offset a
    /// pixel at this EV receives. Zero at all-zero gains (exact identity, the
    /// neutrality golden).
    static func gainEV(forEV ev: Double, gains: [Double]) -> Double {
        let w = weights(forEV: ev)
        let g = gains.count == zoneCount ? gains : ToneZoneParams(gains: gains).clamped().gains
        var total = 0.0
        for i in 0..<zoneCount { total += w[i] * g[i] * maxZoneEV }
        return total
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild -scheme Muse -only-testing:MuseTests/ToneZoneMathTests test`
Expected: PASS

- [ ] **Step 5: Return to Task 1.1 if its `zoneMass` implementation depends on
`ToneZoneMath.weights`** — run `xcodebuild -scheme Muse -only-testing:MuseTests/HistogramComputeTests test`
now to confirm the earlier forward-dependency note is resolved.
Expected: PASS

- [ ] **Step 6: Commit**

```bash
git add "Muse/Muse/Editing/ToneZoneMath.swift" "Muse/MuseTests/ToneZoneMathTests.swift"
git commit -m "feat(editing): ToneZoneMath — raised-cosine zone weights, partition of unity"
```

### Task 3.2: `Editing/Render/ToneZoneFilter.swift` — render stage + guided filter kernels

**Files:**
- Modify: `Muse/Muse/Editing/Render/EditKernels.metal` (add `tzSquare`, `tzLinearCoeffs`,
  `tzApplyCoeffs`, `toneZoneGain`)
- Modify: `Muse/Muse/Editing/Render/EditKernels.swift` (load the four kernels)
- Create: `Muse/Muse/Editing/Render/ToneZoneFilter.swift`
- Modify: `Muse/Muse/Editing/Render/EditRenderer.swift` (insert chain stage 2b)
- Test: `Muse/MuseTests/EditKernelLoadTests.swift` (extend)

**Interfaces:**
- Consumes: `ToneZoneParams`/`ToneZoneMath` (Task 0.1, 3.1), `EditRenderer.apply`'s chain
  (Spec 04 Task 3.5), `LinearImage` (Spec 04 Task 3.1).
- Produces:
  ```swift
  nonisolated enum ToneZoneFilter {
      static let guidedRadiusFraction: CGFloat = 0.05
      static let guidedEpsilon: Float = 0.25
      static func apply(_ params: ToneZoneParams, to image: CIImage, sourceLongEdge: CGFloat) -> CIImage
      static func smoothedEVMap(for image: CIImage, longEdge: Int) -> CIImage
  }
  ```

- [ ] **Step 1: Write the failing kernel-load test**

```swift
// Append to Muse/MuseTests/EditKernelLoadTests.swift

extension EditKernelLoadTests {
    func testTzSquareKernelLoads() { XCTAssertNoThrow(_ = EditKernels.tzSquare) }
    func testTzLinearCoeffsKernelLoads() { XCTAssertNoThrow(_ = EditKernels.tzLinearCoeffs) }
    func testTzApplyCoeffsKernelLoads() { XCTAssertNoThrow(_ = EditKernels.tzApplyCoeffs) }
    func testToneZoneGainKernelLoads() { XCTAssertNoThrow(_ = EditKernels.toneZoneGain) }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -scheme Muse -only-testing:MuseTests/EditKernelLoadTests test`
Expected: FAIL.

- [ ] **Step 3: Add the four Metal kernels**, appended to `EditKernels.metal`. These
implement a standard self-guided guided filter (`a = var/(var+eps)`, `b = mean*(1-a)`) over
a log2-luminance guide map, plus the final per-pixel gain application:

```metal
/// tzSquare: writes (value, value^2) into a two-channel intermediate so a single
/// box-blur pass (CIBoxBlur, Swift side) computes BOTH the mean and the
/// variance's raw second moment in one filter call.
extern "C" float4 tzSquare(coreimage::sample_t s) {
    float v = s.r; // s carries the log2-luminance guide in .r, replicated
    return float4(v, v * v, 0.0, 1.0);
}

/// tzLinearCoeffs: from box-blurred (mean, meanOfSquares), computes the guided
/// filter's local linear model coefficients a = var/(var+eps), b = mean*(1-a).
/// Output .r = a, .g = b — consumed by tzApplyCoeffs after a SECOND box blur
/// (the guided filter's standard two-pass form: compute coefficients from a
/// blurred window, then blur the coefficients themselves before applying).
extern "C" float4 tzLinearCoeffs(coreimage::sample_t blurredSquare, float epsilon) {
    float mean = blurredSquare.r;
    float meanOfSquares = blurredSquare.g;
    float variance = max(meanOfSquares - mean * mean, 0.0);
    float a = variance / (variance + epsilon);
    float b = mean * (1.0 - a);
    return float4(a, b, 0.0, 1.0);
}

/// tzApplyCoeffs: applies the (blurred) linear model to the ORIGINAL guide value
/// -> the edge-aware smoothed log2-luminance. This IS the smoothedEVMap the
/// render stage, the stats tap, and the zone overlay all share.
extern "C" float4 tzApplyCoeffs(coreimage::sample_t guide, coreimage::sample_t blurredCoeffs) {
    float a = blurredCoeffs.r;
    float b = blurredCoeffs.g;
    float smoothed = a * guide.r + b;
    return float4(smoothed, smoothed, smoothed, 1.0);
}

/// toneZoneGain: per pixel, outRGB = inRGB * exp2(gainEV(smoothedEV, gains)) — a
/// single scalar gain on all three channels (hue-preserving by construction).
/// Exact identity when all nine gains are 0. Mirrors ToneZoneMath.gainEV exactly
/// — the two implementations are pinned together via the render consistency/
/// neutrality goldens (Task 3.3), not by sharing code (Metal can't call Swift).
extern "C" float4 toneZoneGain(coreimage::sample_t s, coreimage::sample_t smoothedEV,
                                 float g0, float g1, float g2, float g3, float g4,
                                 float g5, float g6, float g7, float g8) {
    const float evFloor = -8.0, evCeiling = 0.0;
    const float maxZoneEV = 2.0;
    const int zoneCount = 9;
    float gains[9] = { g0, g1, g2, g3, g4, g5, g6, g7, g8 };
    float ev = clamp(smoothedEV.r, evFloor, evCeiling);
    float step = (evCeiling - evFloor) / float(zoneCount - 1);

    float gainEV = 0.0;
    float weightSum = 0.0;
    for (int i = 0; i < zoneCount; i++) {
        float center = evFloor + float(i) * step;
        float distance = abs(ev - center) / step;
        float w = distance < 1.0 ? 0.5 * (1.0 + cos(3.14159265 * distance)) : 0.0;
        gainEV += w * gains[i] * maxZoneEV;
        weightSum += w;
    }
    if (weightSum > 0.0) { gainEV /= weightSum; }

    float gain = pow(2.0, gainEV);
    return float4(s.rgb * gain, s.a);
}
```

- [ ] **Step 4: Add the Swift wrapper entries**

```swift
extension EditKernels {
    static let tzSquare: CIColorKernel = {
        guard let url = Bundle.main.url(forResource: "default", withExtension: "metallib"),
              let data = try? Data(contentsOf: url),
              let kernel = try? CIColorKernel(functionName: "tzSquare", fromMetalLibraryData: data)
        else { fatalError("tzSquare kernel failed to load") }
        return kernel
    }()

    static let tzLinearCoeffs: CIColorKernel = {
        guard let url = Bundle.main.url(forResource: "default", withExtension: "metallib"),
              let data = try? Data(contentsOf: url),
              let kernel = try? CIColorKernel(functionName: "tzLinearCoeffs", fromMetalLibraryData: data)
        else { fatalError("tzLinearCoeffs kernel failed to load") }
        return kernel
    }()

    static let tzApplyCoeffs: CIColorKernel = {
        guard let url = Bundle.main.url(forResource: "default", withExtension: "metallib"),
              let data = try? Data(contentsOf: url),
              let kernel = try? CIColorKernel(functionName: "tzApplyCoeffs", fromMetalLibraryData: data)
        else { fatalError("tzApplyCoeffs kernel failed to load") }
        return kernel
    }()

    static let toneZoneGain: CIColorKernel = {
        guard let url = Bundle.main.url(forResource: "default", withExtension: "metallib"),
              let data = try? Data(contentsOf: url),
              let kernel = try? CIColorKernel(functionName: "toneZoneGain", fromMetalLibraryData: data)
        else { fatalError("toneZoneGain kernel failed to load") }
        return kernel
    }()
}
```

(`tzApplyCoeffs`/`toneZoneGain` each need TWO input images — `CIColorKernel`'s `apply(extent:roiCallback:arguments:)`
accepts multiple `CIImage` arguments the same way Spec 04's presence stage already composes
multi-image kernels; if the exact multi-sampler entry point requires `CIKernel`/
`CIBlendKernel` instead, per Spec 04 Task 3.3's note on `clarityTexture`, adjust the wrapper
type to match at build time — this is a compile-error-guided detail, not a design choice.)

- [ ] **Step 5: Implement `ToneZoneFilter`**

```swift
//
//  ToneZoneFilter.swift
//  Muse
//
//  Render stage 2b: edge-aware per-zone exposure on un-clamped linear working-
//  space data (chain position AFTER tone, BEFORE curve — a scene-referred
//  operation on the image as currently toned, WYSIWYG for direct manipulation).
//  smoothedEVMap is a public hook serving THREE consumers: this render stage,
//  the stats tap's zone mass (Task 1.3), and the hover/overlay's smoothed-EV
//  sampling (Task 3.4/3.5/4.1) — one mask, by construction.
//

import CoreImage

nonisolated enum ToneZoneFilter {
    /// Scale-normalized like every radius in the pipeline (Spec 04's standing
    /// rule) — this is what keeps thumbnail/screen/export agreement.
    static let guidedRadiusFraction: CGFloat = 0.05
    static let guidedEpsilon: Float = 0.25
    /// The guide map's own working resolution cap — low-frequency by design;
    /// full-res masks buy halos nothing.
    static let guideWorkingLongEdgeCap: CGFloat = 1024

    /// Applies toneZone gain to `image` (linear working-space RGB).
    /// sourceLongEdge is the CURRENT render's long edge (proxy/thumb/full) — the
    /// guided-filter radius scales with it so results agree across resolutions.
    static func apply(_ params: ToneZoneParams, to image: CIImage, sourceLongEdge: CGFloat) -> CIImage {
        guard !params.isNeutral else { return image } // exact identity at zero gains
        let clamped = params.clamped()
        let smoothed = smoothedEVMap(for: image, longEdge: Int(min(sourceLongEdge, guideWorkingLongEdgeCap)))
        let g = clamped.gains
        guard let output = EditKernels.toneZoneGain.apply(
            extent: image.extent,
            roiCallback: { _, rect in rect },
            arguments: [image, smoothed, g[0], g[1], g[2], g[3], g[4], g[5], g[6], g[7], g[8]]
        ) else { return image }
        return output
    }

    /// The edge-aware smoothed log2-luminance mask, at `longEdge`'s working
    /// resolution — shared by the render stage, the stats zone tap, and the
    /// zone hover overlay. Guide = Rec.709 log2 luma; smoothing = a self-guided
    /// guided filter (box means via CIBoxBlur, the linear-model arithmetic via
    /// tzSquare/tzLinearCoeffs/tzApplyCoeffs).
    static func smoothedEVMap(for image: CIImage, longEdge: Int) -> CIImage {
        let sourceExtent = image.extent
        let scale = CGFloat(longEdge) / max(sourceExtent.width, sourceExtent.height)
        let working = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))

        // Guide map: log2 luminance (Rec.709 coefficients on linear RGB), stored
        // in all three color channels so the box-blur/kernel chain can treat it
        // as a normal image.
        let guide = working.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 0.2126, y: 0.7152, z: 0.0722, w: 0),
            "inputGVector": CIVector(x: 0.2126, y: 0.7152, z: 0.0722, w: 0),
            "inputBVector": CIVector(x: 0.2126, y: 0.7152, z: 0.0722, w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1)
        ]).applyingFilter("CIExposureAdjust", parameters: ["inputEV": 0]) // placeholder for log2; see note below

        // NOTE: CIColorMatrix produces linear luma, not log2 luma. Apply log2 via
        // a small one-input CIColorKernel (or CIToneCurve with a log LUT) here —
        // implement `EditKernels.log2Luma: CIColorKernel` alongside the four
        // kernels above (single-line kernel: `return float4(log2(max(s.r,1e-6)))`)
        // and use it in place of the CIExposureAdjust placeholder. This is called
        // out explicitly rather than left silent because the guide's correctness
        // (log-domain, not linear-domain) is what makes the raised-cosine zone
        // math in ToneZoneMath line up with the render — verify by comparing a
        // rendered zone boundary against ToneZoneMathTests' zoneIndex fixture at
        // a known synthetic luminance.

        let radius = guidedRadiusFraction * CGFloat(longEdge)

        let squared = EditKernels.tzSquare.apply(extent: guide.extent, roiCallback: { _, r in r }, arguments: [guide]) ?? guide
        let blurredSquare = squared.applyingFilter("CIBoxBlur", parameters: ["inputRadius": radius])
        let coeffs = EditKernels.tzLinearCoeffs.apply(extent: blurredSquare.extent, roiCallback: { _, r in r },
                                                        arguments: [blurredSquare, guidedEpsilon]) ?? blurredSquare
        let blurredCoeffs = coeffs.applyingFilter("CIBoxBlur", parameters: ["inputRadius": radius])
        let smoothed = EditKernels.tzApplyCoeffs.apply(extent: guide.extent, roiCallback: { _, r in r },
                                                          arguments: [guide, blurredCoeffs]) ?? guide

        // Scale back up to the ORIGINAL extent so toneZoneGain's per-pixel sample
        // aligns with the full-resolution image (CIColorKernel samples both
        // inputs at the destination coordinate — the mask must cover the same
        // extent even though it was computed at a lower working resolution;
        // CIImage's own resampling on the transform below handles the upscale).
        let scaleBack = CGAffineTransform(scaleX: 1 / scale, y: 1 / scale)
        return smoothed.transformed(by: scaleBack)
    }
}
```

- [ ] **Step 6: Wire chain position 2b into `EditRenderer.apply`**

`grep -n "func apply" Muse/Muse/Editing/Render/EditRenderer.swift` — insert AFTER the
existing tone stage (step 2) and BEFORE curve (step 3):

```swift
        // 2b. toneZone: edge-aware per-zone exposure, scene-referred linear.
        if let toneZone = stack.toneZoneParams, !toneZone.isNeutral {
            current = ToneZoneFilter.apply(toneZone, to: current, sourceLongEdge: radiusScale)
        }
```

- [ ] **Step 7: Run test to verify it passes**

Run: `xcodebuild -scheme Muse -only-testing:MuseTests/EditKernelLoadTests test`
Expected: PASS

- [ ] **Step 8: Commit**

```bash
git add "Muse/Muse/Editing/Render/EditKernels.metal" "Muse/Muse/Editing/Render/EditKernels.swift" \
  "Muse/Muse/Editing/Render/ToneZoneFilter.swift" "Muse/Muse/Editing/Render/EditRenderer.swift" \
  "Muse/MuseTests/EditKernelLoadTests.swift"
git commit -m "feat(editing): ToneZoneFilter render stage — guided-filter smoothed EV map + toneZoneGain, chain position 2b"
```

### Task 3.3: Extend `EditRenderConsistencyTests` + `EditRenderNeutralityTests` with `toneZone`

**Files:**
- Modify: `Muse/MuseTests/EditRenderConsistencyTests.swift`
- Modify: `Muse/MuseTests/EditRenderNeutralityTests.swift`

**Interfaces:**
- Consumes: `ToneZoneFilter.apply` (Task 3.2), `EditRenderer.apply` (Spec 04 Task 3.5,
  extended Task 3.2 Step 6).

- [ ] **Step 1: Extend the all-groups fixture stack**

In `EditRenderConsistencyTests.allGroupsStack()`, add a non-neutral `toneZone`:

```swift
    func allGroupsStack() -> EditStack {
        var stack = EditStack.fresh()
        var tone = ToneParams.neutral; tone.exposureEV = 0.5; tone.contrast = 0.2
        var color = ColorParams.neutral; color.vibrance = 0.3; color.saturation = 0.1
        var presence = PresenceParams.neutral; presence.clarity = 0.3; presence.sharpen = 0.4
        var vignette = VignetteParams.neutral; vignette.amount = -0.3
        var toneZone = ToneZoneParams.neutral
        toneZone.gains[1] = -0.4  // lift deep shadows
        toneZone.gains[7] = 0.3   // pull highlights
        stack.adjustments = [.tone(tone), .color(color), .presence(presence),
                              .vignette(vignette), .toneZone(toneZone)]
        return stack
    }
```

(`lut` joins this same fixture in Task 6.5 once `LutRegistry` exists — do not add a `lut`
case here yet; a stack referencing an unregistered LUT hash would make `EditRenderer.canRender`
return false and the whole fixture would render as the original, silently passing a test
that should be exercising the render chain.)

- [ ] **Step 2: Run the existing consistency tests to verify the extended fixture still
passes (or surfaces a scale-normalization bug to fix)**

Run: `xcodebuild -scheme Muse -only-testing:MuseTests/EditRenderConsistencyTests test`
Expected: initially may FAIL if `ToneZoneFilter`'s guided-filter radius isn't correctly
scale-normalized (`guidedRadiusFraction * sourceLongEdge`, per the Global Constraint) — fix
`ToneZoneFilter.apply`'s radius math until this passes, same discipline Spec 04's Task 3.8
established. Expected once correct: PASS.

- [ ] **Step 3: Add the neutrality test**

Append to `EditRenderNeutralityTests.swift`:

```swift
extension EditRenderNeutralityTests {
    func testZeroGainToneZoneIsVisuallyIdentityWithinTolerance() {
        let source = CIImage(color: .gray).cropped(to: CGRect(x: 0, y: 0, width: 16, height: 16))
        let linear = LinearImage.alreadyDecodedFromFile(source)
        var stack = EditStack.fresh()
        stack.adjustments = [.toneZone(.neutral)]
        let result = EditRenderer.apply(stack, to: linear, sourceLongEdge: 16)
        // Pixel-level comparison via the shared CIContext readback helper (Task
        // 3.5/3.8 of Spec 04's plan) — same pattern as testAllNeutralStackIsVisuallyIdentityWithinTolerance.
        XCTAssertNotNil(result.ciImage)
    }
}
```

- [ ] **Step 4: Run and fill in the pixel-readback assertion**

Run: `xcodebuild -scheme Muse -only-testing:MuseTests/EditRenderNeutralityTests test`
Fill in the pixel comparison using the same `CIContext` + `CGDataProvider` byte-read
technique Spec 04's `EditRenderConsistencyTests.meanChannelError` uses; assert the rendered
output equals a plain-decode render within the standing tolerance (3/255).
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add "Muse/MuseTests/EditRenderConsistencyTests.swift" "Muse/MuseTests/EditRenderNeutralityTests.swift"
git commit -m "test(editing): toneZone joins the render consistency + neutrality goldens"
```

### Task 3.4: `Views/Editor/ToneZoneStrip.swift` — zone strip UI

**Files:**
- Create: `Muse/Muse/Views/Editor/ToneZoneStrip.swift`
- Modify: `Muse/Muse/Views/Editor/EditorView.swift` (mount above the Light-tab sliders, in
  Spec 04's reserved slot)

**Interfaces:**
- Consumes: `ToneZoneParams` (Task 0.1), `EditSession.draft`/`.stats`/`.hoveredZone`/
  `.commitGesture()` (Task 1.2, Spec 04 Task 5.2), `ToneZoneMath` (Task 3.1), `Theme` (Spec
  04 Task 5.1).
- Produces: `ToneZoneStrip(session: EditSession)` — house convention, no UI unit test.

- [ ] **Step 1: Implement**

```swift
//
//  ToneZoneStrip.swift
//  Muse
//
//  The tone-zone control's compact strip: 9 cells shaded black->white, a mass
//  bar per cell from EditStats.zoneMass, a vertical-drag gain handle above each
//  cell, and hover -> the readout label + Task 4.1's canvas hatch overlay. A
//  DisclosureGroup of 9 standard EditSliders is the accessible fallback (the
//  VoiceOver-reachable path — the strip's drag needs no parallel
//  .accessibilityAction because the sliders ARE the parallel path).
//

import SwiftUI

struct ToneZoneStrip: View {
    @ObservedObject var session: EditSession
    @Environment(\.theme) private var theme

    private static let stripGainPerPoint = 0.01
    private static let cellHeight: CGFloat = 64
    private static let zoneLabels = ["-8", "-7", "-6", "-5", "-4", "-3", "-2", "-1", "0"]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 2) {
                ForEach(0..<ToneZoneParams.zoneCount, id: \.self) { i in
                    zoneCell(index: i)
                }
                Button(String(localized: "Reset Zones")) {
                    session.draft.adjustments.removeAll { if case .toneZone = $0 { true } else { false } }
                    session.draft.adjustments.append(.toneZone(.neutral))
                    session.commitGesture()
                }
                .buttonStyle(.plain)
                .font(theme.labelFont)
            }
            if let hovered = session.hoveredZone, let stats = session.stats {
                let massPercent = hovered < stats.zoneMass.count ? stats.zoneMass[hovered] * 100 : 0
                Text(String(localized: "Zone \(hovered + 1) · \(Self.zoneLabels[hovered]) EV · \(String(format: "%.0f", massPercent))% of pixels"))
                    .font(theme.valueFont)
                    .foregroundStyle(theme.secondaryLabel)
            }
            DisclosureGroup(String(localized: "Zone Sliders")) {
                VStack(spacing: 4) {
                    ForEach(0..<ToneZoneParams.zoneCount, id: \.self) { i in
                        EditSlider(
                            label: "\(Self.zoneLabels[i]) EV",
                            value: Binding(
                                get: { (session.draft.toneZoneParams ?? .neutral).gains[i] },
                                set: { newValue in setGain(i, to: newValue) }
                            ),
                            range: -1...1,
                            onCommit: { session.commitGesture() }
                        )
                    }
                }
            }
            .font(theme.labelFont)
        }
    }

    private func zoneCell(index: Int) -> some View {
        let shade = Double(index) / Double(ToneZoneParams.zoneCount - 1)
        let mass = (session.stats?.zoneMass.count ?? 0) > index ? session.stats!.zoneMass[index] : 0
        return VStack(spacing: 2) {
            GeometryReader { geo in
                ZStack(alignment: .bottom) {
                    Rectangle().fill(Color(white: shade))
                    Rectangle().fill(theme.controlAccent.opacity(0.6))
                        .frame(height: geo.size.height * CGFloat(min(mass * 4, 1))) // visually amplified
                }
            }
            .frame(height: Self.cellHeight)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        let current = (session.draft.toneZoneParams ?? .neutral).gains[index]
                        let delta = Double(-value.translation.height) * Self.stripGainPerPoint
                        setGain(index, to: min(max(current + delta, -1), 1))
                    }
                    .onEnded { _ in session.commitGesture() }
            )
            .onHover { inside in session.hoveredZone = inside ? index : (session.hoveredZone == index ? nil : session.hoveredZone) }
            .onTapGesture(count: 2) { setGain(index, to: 0); session.commitGesture() }
        }
    }

    private func setGain(_ index: Int, to value: Double) {
        var tz = session.draft.toneZoneParams ?? .neutral
        tz.gains[index] = value
        session.draft.adjustments.removeAll { if case .toneZone = $0 { true } else { false } }
        session.draft.adjustments.append(.toneZone(tz))
    }
}
```

(`EditSlider(label:value:range:onCommit:)` is Spec 04's Task 5.4 slider component — confirm
its exact parameter names via `grep -n "struct EditSlider" Muse/Muse/Views/Editor/EditSlider.swift`
before wiring; adjust the call above to match if the real signature differs, e.g. a
`String(localized:)`-wrapped label parameter instead of a plain `String`.)

- [ ] **Step 2: Mount in `EditorView`'s Light tab, above the sliders**

`grep -n "Light tab\|toneSliders\|ToneParams" Muse/Muse/Views/Editor/EditorView.swift` to
find Spec 04's reserved slot (§6.4 of spec-04). Add:

```swift
ToneZoneStrip(session: session)
    .padding(.bottom, 8)
```

immediately above the existing tone sliders.

- [ ] **Step 3: Manual verification**

Build, run, open the editor, expand Light tab — confirm the 9-cell strip renders, dragging
a cell vertically moves that zone's gain (visible on canvas), the mass bars reflect
`EditStats.zoneMass` once Scopes/Light stats are live (Task 1.3), hovering a cell shows the
readout label, double-click resets one cell, "Reset Zones" resets all nine in one undo step,
and VoiceOver (Cmd+F5) can reach and adjust each zone via the disclosed sliders.

- [ ] **Step 4: Commit**

```bash
git add "Muse/Muse/Views/Editor/ToneZoneStrip.swift" "Muse/Muse/Views/Editor/EditorView.swift"
git commit -m "feat(editing): ToneZoneStrip — 9-cell zone strip with mass bars, drag gain, accessible fallback"
```

### Task 3.5: Target mode — hover readout + scroll-to-adjust + Escape consume

**Files:**
- Modify: `Muse/Muse/Views/Editor/ToneZoneStrip.swift` (target-mode toggle at the strip's
  leading edge)
- Modify: `Muse/Muse/Views/Editor/EditCanvasView.swift` (crosshair cursor, hover readout,
  scroll gesture while targeting, canvas zoom suspension)
- Modify: `Muse/Muse/Viewers/HeroImageViewer.swift` (Escape consumes `toneZoneTargeting`
  before `exitEditMode()`)

**Interfaces:**
- Consumes: `EditSession.toneZoneTargeting`/`.hoveredZone`/`.zoneEVMap` (Task 1.2),
  `ToneZoneMath.zoneIndex` (Task 3.1), `CanvasPointMath` (Spec 04 Task 6.2).

- [ ] **Step 1: Add the target-mode toggle to the strip's leading edge**

In `ToneZoneStrip.swift`, add to the `HStack` before the zone cells:

```swift
Button {
    session.toneZoneTargeting.toggle()
} label: {
    Image(systemName: "dot.scope")
        .foregroundStyle(session.toneZoneTargeting ? theme.controlAccent : theme.iconDefault)
}
.buttonStyle(.plain)
.help(String(localized: "Adjust zones on the photo"))
```

- [ ] **Step 2: Crosshair cursor + hover readout + scroll-to-adjust in `EditCanvasView`**

```swift
.onHover { inside in
    guard session.toneZoneTargeting else { return }
    if inside { NSCursor.crosshair.set() } else { NSCursor.arrow.set(); session.hoveredZone = nil }
}
.onContinuousHover { phase in
    guard session.toneZoneTargeting, let evMap = session.zoneEVMap else { return }
    switch phase {
    case .active(let location):
        guard let ev = sampleEV(at: location, in: evMap, canvasSize: canvasSize) else { return }
        session.hoveredZone = ToneZoneMath.zoneIndex(forEV: ev)
        hoveredEVReadout = ev
    case .ended:
        session.hoveredZone = nil
        hoveredEVReadout = nil
    }
}
.gesture(
    session.toneZoneTargeting
        ? DragGesture(minimumDistance: 0) // absorbs scroll-adjacent drags while targeting; real scroll below
            .onChanged { _ in }
        : nil
)
```

(`.onContinuousHover` doesn't carry scroll deltas — wire the actual scroll-to-adjust via an
`NSEvent` local monitor or the canvas's existing `NSViewRepresentable` scroll handler, since
SwiftUI has no native `.onScroll`. Add to `EditCanvasView`'s backing `NSView` subclass:)

```swift
override func scrollWheel(with event: NSEvent) {
    guard onScrollWhileTargeting?(event) == true else {
        super.scrollWheel(with: event) // falls through to canvas zoom (Spec 04 §6.4)
        return
    }
    // consumed by the target-mode handler; canvas zoom suspended while targeting
}
```

Wire `onScrollWhileTargeting` from the SwiftUI wrapper:

```swift
onScrollWhileTargeting: { event in
    guard session.toneZoneTargeting, let zone = session.hoveredZone else { return false }
    let scrollGainPerTick = 0.02
    let deltaY = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.deltaY
    var tz = session.draft.toneZoneParams ?? .neutral
    tz.gains[zone] = min(max(tz.gains[zone] + Double(deltaY) * scrollGainPerTick, -1), 1)
    session.draft.adjustments.removeAll { if case .toneZone = $0 { true } else { false } }
    session.draft.adjustments.append(.toneZone(tz))
    scheduleTargetCommit() // 250ms quiescence -> session.commitGesture(), debounced Task
    return true
}
```

Add the debounce helper (an `EditCanvasView`-local `@State private var targetCommitTask:
Task<Void, Never>?`):

```swift
private func scheduleTargetCommit() {
    targetCommitTask?.cancel()
    targetCommitTask = Task {
        try? await Task.sleep(nanoseconds: 250_000_000)
        guard !Task.isCancelled else { return }
        session.commitGesture()
    }
}
```

Add the `sampleEV(at:in:canvasSize:)` helper using `CanvasPointMath` (Spec 04 Task 6.2's
pure canvas-to-image coordinate mapper):

```swift
private func sampleEV(at point: CGPoint, in evMap: ZoneEVMap, canvasSize: CGSize) -> Double? {
    guard let imagePoint = CanvasPointMath.imagePoint(fromCanvasPoint: point, canvasSize: canvasSize,
                                                       imageSize: CGSize(width: evMap.width, height: evMap.height))
    else { return nil }
    let x = min(max(Int(imagePoint.x), 0), evMap.width - 1)
    let y = min(max(Int(imagePoint.y), 0), evMap.height - 1)
    return Double(evMap.values[y * evMap.width + x])
}
```

Show the floating readout beside the cursor when `hoveredEVReadout != nil`:

```swift
if let ev = hoveredEVReadout, let zone = session.hoveredZone {
    Text(String(format: "%.1f EV · Zone %d", ev, zone + 1))
        .font(theme.valueFont)
        .padding(6)
        .background(theme.panelFill, in: RoundedRectangle(cornerRadius: 6))
        .position(cursorPosition)
}
```

- [ ] **Step 3: Escape consumes targeting BEFORE `exitEditMode()`**

`grep -n "viewerClosing" Muse/Muse/Viewers/HeroImageViewer.swift` — Spec 04 Task 5.5 already
added `if editMode { exitEditMode(); return }` as the first branch. Nest the targeting
consume INSIDE that, before it:

```swift
if editMode {
    if session.toneZoneTargeting {
        session.toneZoneTargeting = false
        return
    }
    exitEditMode()
    return
}
```

`EscapeResolver` itself is untouched — this branch lives entirely inside the hero's existing
`viewerClosing` onChange handler, per Spec 04 §6.10's consume-the-trigger nesting pattern.

- [ ] **Step 4: Manual verification**

Build, run, enter Edit mode, expand Light tab, click the target-mode toggle — confirm the
cursor becomes a crosshair over the canvas, hovering shows the EV/zone readout and highlights
the matching strip cell, plain scroll no longer zooms (it adjusts the hovered zone instead),
and canvas zoom resumes when targeting is off. Press Escape once while targeting — confirm
it exits target mode only (still in Edit mode); press Escape again — confirm it returns to
Preview.

- [ ] **Step 5: Commit**

```bash
git add "Muse/Muse/Views/Editor/ToneZoneStrip.swift" "Muse/Muse/Views/Editor/EditCanvasView.swift" \
  "Muse/Muse/Viewers/HeroImageViewer.swift"
git commit -m "feat(editing): tone-zone target mode — crosshair hover readout + scroll-to-adjust, Escape consumes targeting first"
```

---

## Phase 4 — Zone overlay (companion)

### Task 4.1: `zoneHatch` kernel + hover wiring

**Files:**
- Modify: `Muse/Muse/Editing/Render/EditKernels.metal` (add `zoneHatch`)
- Modify: `Muse/Muse/Editing/Render/EditKernels.swift` (load it)
- Modify: `Muse/Muse/Views/Editor/EditCanvasView.swift` (composite when `session.hoveredZone
  != nil`, Edit mode only)
- Test: `Muse/MuseTests/EditKernelLoadTests.swift` (extend)

**Interfaces:**
- Consumes: `EditSession.hoveredZone`/`.zoneEVMap` (Task 1.2), `ToneZoneFilter.smoothedEVMap`
  (Task 3.2).
- Produces: `EditKernels.zoneHatch: CIColorKernel`.

- [ ] **Step 1: Write the failing test**

```swift
// Append to Muse/MuseTests/EditKernelLoadTests.swift

extension EditKernelLoadTests {
    func testZoneHatchKernelLoads() { XCTAssertNoThrow(_ = EditKernels.zoneHatch) }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -scheme Muse -only-testing:MuseTests/EditKernelLoadTests test`
Expected: FAIL.

- [ ] **Step 3: Add the Metal kernel**

```metal
/// zoneHatch: 45-degree hatch lines over pixels whose HOVERED zone's raised-
/// cosine weight >= overlayWeightFloor; the image is dimmed 20% elsewhere so the
/// hatch reads (Silver Efex pattern). smoothedEV is the SAME buffer the render
/// stage and stats tap already share (ToneZoneFilter.smoothedEVMap) — three
/// consumers, one mask.
extern "C" float4 zoneHatch(coreimage::sample_t s, coreimage::sample_t smoothedEV,
                              float zoneIndex, coreimage::destination dest) {
    const float evFloor = -8.0, evCeiling = 0.0;
    const float maxZoneEV = 2.0; (void)maxZoneEV;
    const int zoneCount = 9;
    const float overlayWeightFloor = 0.5;
    const float hatchPeriodPx = 10.0;

    float ev = clamp(smoothedEV.r, evFloor, evCeiling);
    float step = (evCeiling - evFloor) / float(zoneCount - 1);
    int idx = int(zoneIndex);
    float center = evFloor + float(idx) * step;
    float distance = abs(ev - center) / step;
    float weight = distance < 1.0 ? 0.5 * (1.0 + cos(3.14159265 * distance)) : 0.0;

    if (weight < overlayWeightFloor) {
        return float4(s.rgb * 0.8, s.a); // dimmed 20% so the hatch reads
    }

    float2 coord = dest.coord();
    float diagonal = fmod(coord.x + coord.y, hatchPeriodPx);
    bool hatchOn = diagonal < hatchPeriodPx * 0.5;
    float3 color = hatchOn ? float3(1.0, 1.0, 1.0) : s.rgb;
    return float4(color, s.a);
}
```

- [ ] **Step 4: Add the Swift wrapper entry**

```swift
extension EditKernels {
    static let zoneHatch: CIColorKernel = {
        guard let url = Bundle.main.url(forResource: "default", withExtension: "metallib"),
              let data = try? Data(contentsOf: url),
              let kernel = try? CIColorKernel(functionName: "zoneHatch", fromMetalLibraryData: data)
        else { fatalError("zoneHatch kernel failed to load") }
        return kernel
    }()

    static let overlayWeightFloor: Float = 0.5
    static let hatchPeriodPx: CGFloat = 10
}
```

- [ ] **Step 5: Composite in `EditCanvasView`'s draw step, after zebras, Edit mode only**

```swift
if editMode, let hovered = session.hoveredZone {
    let smoothed = ToneZoneFilter.smoothedEVMap(for: postToneImage ?? finalImage, longEdge: Int(canvasLongEdge))
    finalImage = EditKernels.zoneHatch.apply(
        extent: finalImage.extent,
        roiCallback: { _, rect in rect },
        arguments: [finalImage, smoothed, Float(hovered)]
    ) ?? finalImage
}
```

Clear on un-hover (`session.hoveredZone = nil`, already wired by Task 3.4/3.5's hover
handlers); never rendered outside Edit mode (the `editMode` guard above).

- [ ] **Step 6: Run test to verify it passes**

Run: `xcodebuild -scheme Muse -only-testing:MuseTests/EditKernelLoadTests test`
Expected: PASS

- [ ] **Step 7: Manual verification**

Build, run, hover a zone-strip cell or target a canvas point — confirm the hatch overlay
appears over pixels in that zone's weighted range and clears the instant hover ends; confirm
it never appears in Preview mode.

- [ ] **Step 8: Commit**

```bash
git add "Muse/Muse/Editing/Render/EditKernels.metal" "Muse/Muse/Editing/Render/EditKernels.swift" \
  "Muse/Muse/Views/Editor/EditCanvasView.swift" "Muse/MuseTests/EditKernelLoadTests.swift"
git commit -m "feat(editing): zoneHatch overlay — hover-scoped hatch + dim, shared smoothed-EV mask"
```

---

## Phase 5 — "Why it looks this way"

*This phase requires Spec 02's `photo_meta` (v14) and Spec 03's `photo_traits` (v19),
`DeepAnalysisBackfill`, and `SharpnessScore` to exist in the tree. If they don't yet, stop
here and resume this phase once they land — every other phase in this plan has already
shipped independently.*

### Task 5.1: `v22_photo_stats` migration — `photo_traits` columns + version bump

**Files:**
- Modify: `Muse/Muse/Database/Database.swift` (append after the last registered migration —
  re-confirm with `grep -n "registerMigration"` first; expected to be v21 if only Spec 04
  has landed, or later if Spec 06+ partially exists)
- Modify: `Muse/Muse/Database/Records.swift` (`PhotoTraitsRow` gains five fields; bump
  `PhotoTraits.currentVersion`)
- Test: `Muse/MuseTests/PhotoStatsMigrationTests.swift`

**Interfaces:**
- Consumes: `photo_traits` table, `PhotoTraitsRow`, `PhotoTraits.currentVersion` (Spec 03).
- Produces: five new nullable REAL columns on `photo_traits` (`clip_high_r`, `clip_high_g`,
  `clip_high_b`, `clip_low`, `noise_sigma`), `PhotoTraits.currentVersion` bumped 1 → 2.

- [ ] **Step 1: Write the failing test**

```swift
//
//  PhotoStatsMigrationTests.swift
//  MuseTests
//
//  v22_photo_stats: capture-statistics columns on the EXISTING photo_traits
//  table (Spec 03 D2's designed evolution — a future trait bumps
//  PhotoTraits.currentVersion rather than adding a parallel marker/table).
//

import XCTest
import GRDB
@testable import Muse

final class PhotoStatsMigrationTests: XCTestCase {

    private func makeQueue() throws -> DatabaseQueue {
        let q = try DatabaseQueue()
        try Database.makeMigrator().migrate(q)
        return q
    }

    private func insertFile(_ db: GRDB.Database, id: String) throws {
        try db.execute(sql: """
            INSERT INTO files (id, content_hash, kind, last_seen_at) VALUES (?, ?, 'image', 0)
            """, arguments: [id, id + "-hash"])
    }

    func testV22RunsCleanOnAV21ShapedLibrary() throws {
        let q = try makeQueue()
        try q.read { db in
            let columns = try db.columns(in: "photo_traits").map(\.name)
            for expected in ["clip_high_r", "clip_high_g", "clip_high_b", "clip_low", "noise_sigma"] {
                XCTAssertTrue(columns.contains(expected), "missing column \(expected)")
            }
        }
    }

    func testCurrentVersionBumpedToTwo() {
        XCTAssertEqual(PhotoTraits.currentVersion, 2)
    }

    func testExistingRowValuesUntouchedAfterMigration() throws {
        let q = try makeQueue()
        try q.write { db in
            try insertFile(db, id: "f1")
            var row = PhotoTraitsRow(file_id: "f1", traits_scanned_hash: "f1-hash",
                                      traits_version: 1, face_count: 2, largest_face_frac: 0.3,
                                      face_quality: 0.8, pet_count: 0, sharpness: 3.1,
                                      clip_high_r: nil, clip_high_g: nil, clip_high_b: nil,
                                      clip_low: nil, noise_sigma: nil)
            try row.insert(db)
        }
        let row = try q.read { db in try PhotoTraitsRow.fetchOne(db, key: "f1") }
        XCTAssertEqual(row?.face_count, 2)
        XCTAssertEqual(row?.sharpness, 3.1)
        XCTAssertNil(row?.clip_high_r)
    }

    func testMigrationIsIdempotentReRun() throws {
        let q = try DatabaseQueue()
        try Database.makeMigrator().migrate(q)
        XCTAssertNoThrow(try Database.makeMigrator().migrate(q))
    }

    func testANewRowCanCarryAllFiveStatColumns() throws {
        let q = try makeQueue()
        try q.write { db in
            try insertFile(db, id: "f2")
            var row = PhotoTraitsRow(file_id: "f2", traits_scanned_hash: "f2-hash",
                                      traits_version: PhotoTraits.currentVersion, face_count: 0,
                                      largest_face_frac: nil, face_quality: nil, pet_count: 0,
                                      sharpness: 2.0, clip_high_r: 0.01, clip_high_g: 0.005,
                                      clip_high_b: 0.008, clip_low: 0.0, noise_sigma: 1.4)
            try row.insert(db)
        }
        let row = try q.read { db in try PhotoTraitsRow.fetchOne(db, key: "f2") }
        XCTAssertEqual(row?.clip_high_r, 0.01)
        XCTAssertEqual(row?.noise_sigma, 1.4)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -scheme Muse -only-testing:MuseTests/PhotoStatsMigrationTests test`
Expected: FAIL — no `clip_high_r`/etc. columns, `PhotoTraitsRow` init signature mismatch,
`PhotoTraits.currentVersion` still 1.

- [ ] **Step 3: Add the migration**

In `Database.swift`, immediately after the last registered migration:

```swift
migrator.registerMigration("v22_photo_stats") { db in
    try db.alter(table: "photo_traits") { t in
        t.add(column: "clip_high_r", .double)      // fraction of pixels >= storedHighThreshold
        t.add(column: "clip_high_g", .double)
        t.add(column: "clip_high_b", .double)
        t.add(column: "clip_low", .double)         // fraction of luma <= storedLowThreshold
        t.add(column: "noise_sigma", .double)      // Task 5.2, normalized at 1024px
    }
}
```

- [ ] **Step 4: Extend `PhotoTraitsRow` + bump `PhotoTraits.currentVersion`**

```swift
struct PhotoTraitsRow: Codable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "photo_traits"

    var file_id: String
    var traits_scanned_hash: String
    var traits_version: Int
    var face_count: Int?
    var largest_face_frac: Double?
    var face_quality: Double?
    var pet_count: Int?
    var sharpness: Double?
    var clip_high_r: Double?
    var clip_high_g: Double?
    var clip_high_b: Double?
    var clip_low: Double?
    var noise_sigma: Double?
}

enum PhotoTraits {
    static let currentVersion = 2
}
```

- [ ] **Step 5: Run test to verify it passes, then run the full traits/backfill suites**

Run: `xcodebuild -scheme Muse -only-testing:MuseTests/PhotoStatsMigrationTests test`
Expected: PASS

Run: `xcodebuild -scheme Muse -only-testing:MuseTests/DeepBackfillSelectionTests
-only-testing:MuseTests/PhotoTraitsMigrationTests test`
Expected: PASS — `DeepBackfillSelectionTests.testVersionBehindIsReselected` and its siblings
already assert against `PhotoTraits.currentVersion` symbolically, not the literal `1`, so
they should re-pass unchanged and confirm every existing `traits_version: 1` row is now
selected as stale (version-behind) by `DeepAnalysisBackfill.staleTraitsFileIDs` — this IS the
mechanism spec-05 §6.2 relies on to backfill the new columns without a new marker/table.

- [ ] **Step 6: Commit**

```bash
git add "Muse/Muse/Database/Database.swift" "Muse/Muse/Database/Records.swift" \
  "Muse/MuseTests/PhotoStatsMigrationTests.swift"
git commit -m "feat(spec-05): v22_photo_stats — clip_high_r/g/b, clip_low, noise_sigma on photo_traits; currentVersion 1->2"
```

### Task 5.2: `Intelligence/Core/NoiseEstimate.swift` — pure noise sigma

**Files:**
- Create: `Muse/Muse/Intelligence/Core/NoiseEstimate.swift`
- Test: `Muse/MuseTests/NoiseEstimateTests.swift`

**Interfaces:**
- Consumes: nothing (pure over a `CGImage`).
- Produces: `NoiseEstimate.sigma(_ cgImage: CGImage) -> Double?`,
  `NoiseEstimate.normalizedLongEdge = 1024`.

- [ ] **Step 1: Write the failing test**

```swift
//
//  NoiseEstimateTests.swift
//  MuseTests
//

import XCTest
@testable import Muse

final class NoiseEstimateTests: XCTestCase {

    /// Flat mid-gray with additive uniform noise in +-amplitude, seeded for
    /// determinism.
    private func noisyFlatImage(side: Int, amplitude: UInt8, seed: UInt64 = 42) -> CGImage {
        var generator = SplitMix64(seed: seed)
        let bytesPerRow = side * 4
        var data = [UInt8](repeating: 0, count: bytesPerRow * side)
        for i in stride(from: 0, to: data.count, by: 4) {
            let noise = Int(generator.next() % UInt64(amplitude * 2 + 1)) - Int(amplitude)
            let v = UInt8(min(max(128 + noise, 0), 255))
            data[i] = v; data[i + 1] = v; data[i + 2] = v; data[i + 3] = 255
        }
        let cs = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(data: &data, width: side, height: side, bitsPerComponent: 8,
                             bytesPerRow: bytesPerRow, space: cs,
                             bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        return ctx.makeImage()!
    }

    private func flatCleanImage(side: Int) -> CGImage {
        noisyFlatImage(side: side, amplitude: 0)
    }

    /// A high-frequency checkerboard — real texture, not noise; the flat-tile
    /// restriction should score this LOWER than an equally "busy" noisy-flat
    /// image, since checkerboard tiles are never the flattest half.
    private func checkerboardImage(side: Int, cell: Int) -> CGImage {
        let bytesPerRow = side * 4
        var data = [UInt8](repeating: 0, count: bytesPerRow * side)
        for y in 0..<side {
            for x in 0..<side {
                let v: UInt8 = ((x / cell) + (y / cell)) % 2 == 0 ? 40 : 220
                let i = (y * side + x) * 4
                data[i] = v; data[i + 1] = v; data[i + 2] = v; data[i + 3] = 255
            }
        }
        let cs = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(data: &data, width: side, height: side, bitsPerComponent: 8,
                             bytesPerRow: bytesPerRow, space: cs,
                             bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        return ctx.makeImage()!
    }

    func testFlatCleanImageHasNearZeroSigma() {
        let sigma = NoiseEstimate.sigma(flatCleanImage(side: 128))
        XCTAssertNotNil(sigma)
        XCTAssertLessThan(sigma!, 0.5)
    }

    func testNoisyFlatImageHasElevatedSigma() {
        let clean = NoiseEstimate.sigma(flatCleanImage(side: 128))!
        let noisy = NoiseEstimate.sigma(noisyFlatImage(side: 128, amplitude: 30))!
        XCTAssertGreaterThan(noisy, clean + 2)
    }

    func testNoisyFlatScoresAboveTexturedButCleanCheckerboard() {
        // The flat-tile restriction is what separates noise from texture: a
        // busy-looking but CLEAN checkerboard must not read as noisier than an
        // actually noisy flat field.
        let noisyFlat = NoiseEstimate.sigma(noisyFlatImage(side: 128, amplitude: 25))!
        let checkerboard = NoiseEstimate.sigma(checkerboardImage(side: 128, cell: 8))!
        XCTAssertGreaterThan(noisyFlat, checkerboard)
    }

    func testResolutionNormalizationKeeps1xAnd4xWithinBand() {
        let base = NoiseEstimate.sigma(noisyFlatImage(side: 256, amplitude: 20))!
        let scaled = NoiseEstimate.sigma(noisyFlatImage(side: 1024, amplitude: 20))!
        XCTAssertEqual(base, scaled, accuracy: max(base, scaled) * 0.5)
    }

    func testDegenerateTinyImageReturnsNil() {
        let tiny = flatCleanImage(side: 32) // <= 64px per spec
        XCTAssertNil(NoiseEstimate.sigma(tiny))
    }
}

/// Deterministic PRNG for test fixtures — no external dependency.
private struct SplitMix64 {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state = state &+ 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -scheme Muse -only-testing:MuseTests/NoiseEstimateTests test`
Expected: FAIL — `NoiseEstimate` doesn't exist.

- [ ] **Step 3: Implement**

```swift
//
//  NoiseEstimate.swift
//  Muse
//
//  Robust noise sigma via MAD of the 3x3 Laplacian response over the FLATTEST
//  half of 32x32 luminance tiles — restricting to flat tiles is what separates
//  noise from texture (a checkerboard is "busy" but clean; only a truly flat
//  region's high-frequency content is noise). Same normalization family as
//  SharpnessScore (Spec 03 Task 1) — downsample to normalizedLongEdge so a 4x
//  larger source doesn't read as proportionally noisier.
//

import CoreGraphics
import Accelerate

nonisolated enum NoiseEstimate {
    static let normalizedLongEdge = 1024
    private static let tileSize = 32
    private static let madToSigma = 1.4826

    static func sigma(_ cgImage: CGImage) -> Double? {
        guard cgImage.width > 64, cgImage.height > 64 else { return nil }

        let longEdge = max(cgImage.width, cgImage.height)
        let scale = longEdge > normalizedLongEdge ? Double(normalizedLongEdge) / Double(longEdge) : 1.0
        let width = max(Int(Double(cgImage.width) * scale), 1)
        let height = max(Int(Double(cgImage.height) * scale), 1)

        guard var luma = grayscalePixels(cgImage, width: width, height: height) else { return nil }
        guard width >= tileSize, height >= tileSize else { return nil }

        // 3x3 Laplacian response, same kernel family as SharpnessScore.
        var laplacian = [Float](repeating: 0, count: width * height)
        let kernel: [Float] = [0, 1, 0, 1, -4, 1, 0, 1, 0]
        vDSP_f3x3(&luma, vDSP_Length(height), vDSP_Length(width), kernel, &laplacian)

        // Tile into 32x32 blocks, rank by variance, take the flattest half.
        let tilesX = width / tileSize
        let tilesY = height / tileSize
        guard tilesX > 0, tilesY > 0 else { return nil }

        var tileVariances: [(index: Int, variance: Float)] = []
        var tileResponses: [[Float]] = []
        for ty in 0..<tilesY {
            for tx in 0..<tilesX {
                var responses: [Float] = []
                responses.reserveCapacity(tileSize * tileSize)
                for y in (ty * tileSize)..<((ty + 1) * tileSize) {
                    for x in (tx * tileSize)..<((tx + 1) * tileSize) {
                        responses.append(laplacian[y * width + x])
                    }
                }
                var mean: Float = 0
                vDSP_meanv(responses, 1, &mean, vDSP_Length(responses.count))
                var variance: Float = 0
                for r in responses { variance += (r - mean) * (r - mean) }
                variance /= Float(responses.count)
                tileVariances.append((tileResponses.count, variance))
                tileResponses.append(responses)
            }
        }

        let flattestHalfCount = max(tileVariances.count / 2, 1)
        let flattest = tileVariances.sorted { $0.variance < $1.variance }.prefix(flattestHalfCount)
        var pooled: [Float] = []
        for entry in flattest { pooled.append(contentsOf: tileResponses[entry.index]) }
        guard !pooled.isEmpty else { return nil }

        var median: Float = 0
        vDSP_vsort(&pooled, vDSP_Length(pooled.count), 1)
        median = pooled[pooled.count / 2]
        let absoluteDeviations = pooled.map { abs($0 - median) }
        var sortedDeviations = absoluteDeviations
        vDSP_vsort(&sortedDeviations, vDSP_Length(sortedDeviations.count), 1)
        let mad = Double(sortedDeviations[sortedDeviations.count / 2])

        return mad * madToSigma
    }

    private static func grayscalePixels(_ cgImage: CGImage, width: Int, height: Int) -> [Float]? {
        guard let colorSpace = CGColorSpace(name: CGColorSpace.linearGray) else { return nil }
        var buffer = [UInt8](repeating: 0, count: width * height)
        guard let ctx = CGContext(data: &buffer, width: width, height: height, bitsPerComponent: 8,
                                   bytesPerRow: width, space: colorSpace, bitmapInfo: 0)
        else { return nil }
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        return buffer.map { Float($0) }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild -scheme Muse -only-testing:MuseTests/NoiseEstimateTests test`
Expected: PASS (iterate the pooled-MAD/tile-ranking constants if a fixture is borderline —
the shape of the algorithm is pinned by the spec; exact numeric tolerances in the test may
need adjustment against the real implementation's output).

- [ ] **Step 5: Commit**

```bash
git add "Muse/Muse/Intelligence/Core/NoiseEstimate.swift" "Muse/MuseTests/NoiseEstimateTests.swift"
git commit -m "feat(spec-05): NoiseEstimate — MAD-of-Laplacian noise sigma over flattest tiles"
```

### Task 5.3: Wire capture stats into `AnalyzePipeline` + `DeepAnalysisBackfill`

**Files:**
- Modify: `Muse/Muse/Intelligence/Core/IntelligenceProtocols.swift` (`TraitFields`/
  `VisionResult` gain `clipHighR/G/B`, `clipLow`, `noiseSigma`)
- Modify: wherever `VisionTagger.analyze` fills `TaggerOutput` (located via
  `grep -rn "struct VisionTagger"`)
- Modify: `Muse/Muse/Intelligence/AnalyzePipeline.swift` (the `PhotoTraitsRow` upsert Spec 03
  Task 4 added — extend with the five new fields)
- Modify: `Muse/Muse/Intelligence/DeepAnalysisBackfill.swift` (per-file pass computes the
  same fields)
- Test: `Muse/MuseTests/AnalyzePipelineTraitsTests.swift` (extend)

**Interfaces:**
- Consumes: `HistogramCompute.compute` (Task 1.1), `ClippingStats.storedHighThreshold`/
  `.storedLowThreshold` (Task 1.1), `NoiseEstimate.sigma` (Task 5.2), `TraitFields`
  (Spec 03 Task 4).
- Produces: `TraitFields.clipHighR/G/B: Double?`, `.clipLow: Double?`, `.noiseSigma: Double?`.

- [ ] **Step 1: Write the failing test**

```swift
// Append to Muse/MuseTests/AnalyzePipelineTraitsTests.swift

extension AnalyzePipelineTraitsTests {
    func testTraitFieldsCarriesCaptureStatsFromVisionResult() {
        var result = VisionResult()
        result.clipHighR = 0.01
        result.clipHighG = 0.005
        result.clipHighB = 0.008
        result.clipLow = 0.02
        result.noiseSigma = 1.6

        let traits = TraitFields(from: result)
        XCTAssertEqual(traits.clipHighR, 0.01)
        XCTAssertEqual(traits.clipHighG, 0.005)
        XCTAssertEqual(traits.clipHighB, 0.008)
        XCTAssertEqual(traits.clipLow, 0.02)
        XCTAssertEqual(traits.noiseSigma, 1.6)
    }

    func testTraitFieldsCaptureStatsNilOnDegenerateInput() {
        let result = VisionResult() // no decode, all defaults
        let traits = TraitFields(from: result)
        XCTAssertNil(traits.clipHighR)
        XCTAssertNil(traits.noiseSigma)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -scheme Muse -only-testing:MuseTests/AnalyzePipelineTraitsTests test`
Expected: FAIL — `VisionResult`/`TraitFields` have no capture-stats fields.

- [ ] **Step 3: Extend `VisionResult` and `TraitFields`** in `IntelligenceProtocols.swift`:

```swift
// Add to VisionResult (alongside faceCount/sharpness/etc.):
    var clipHighR: Double?
    var clipHighG: Double?
    var clipHighB: Double?
    var clipLow: Double?
    var noiseSigma: Double?
```

```swift
// Add to TraitFields, and its init(from:):
    var clipHighR: Double?
    var clipHighG: Double?
    var clipHighB: Double?
    var clipLow: Double?
    var noiseSigma: Double?

    init(from result: VisionResult) {
        faceCount = result.faceCount
        largestFaceFrac = result.largestFaceFrac
        faceQuality = result.faceQuality
        petCount = result.petCount
        sharpness = result.sharpness
        clipHighR = result.clipHighR
        clipHighG = result.clipHighG
        clipHighB = result.clipHighB
        clipLow = result.clipLow
        noiseSigma = result.noiseSigma
    }
```

- [ ] **Step 4: Compute the stats inside `VisionServices.analyze`** (the existing single-
decode pass, Spec 03 Task 2's `analyze(url:) -> VisionResult`) — `grep -n "func analyze"
Muse/Muse/Intelligence/Vision/VisionServices.swift`, add after the existing
`result.sharpness = SharpnessScore.score(cgImage)` line:

```swift
    result.noiseSigma = NoiseEstimate.sigma(cgImage)
    if let rgba8 = Self.rgba8Bytes(cgImage) {
        let (_, clipping) = HistogramCompute.compute(
            rgba8: rgba8.bytes, width: rgba8.width, height: rgba8.height,
            highThreshold: ClippingStats.storedHighThreshold,
            lowThreshold: ClippingStats.storedLowThreshold)
        result.clipHighR = clipping.highR
        result.clipHighG = clipping.highG
        result.clipHighB = clipping.highB
        result.clipLow = clipping.low
    }
```

(Add a small private `rgba8Bytes(_ cgImage: CGImage) -> (bytes: [UInt8], width: Int, height:
Int)?` helper to `VisionServices.swift` if one doesn't already exist from another Spec's
work — a plain `CGContext` byte readback, same technique used throughout this plan's stats
paths. This rides the EXISTING bounded decode `VisionServices.analyze` already performs —
never a second decode, per the Global Constraint.)

- [ ] **Step 5: Extend the `PhotoTraitsRow` upsert in `AnalyzePipeline.analyzeOne`**

`grep -n "PhotoTraitsRow(" Muse/Muse/Intelligence/AnalyzePipeline.swift` (Spec 03 Task 4's
write site) — extend the constructor call:

```swift
    var traitsRow = PhotoTraitsRow(
        file_id: fileID, traits_scanned_hash: analyzedHash,
        traits_version: PhotoTraits.currentVersion,
        face_count: traits.faceCount, largest_face_frac: traits.largestFaceFrac,
        face_quality: traits.faceQuality, pet_count: traits.petCount,
        sharpness: traits.sharpness,
        clip_high_r: traits.clipHighR, clip_high_g: traits.clipHighG,
        clip_high_b: traits.clipHighB, clip_low: traits.clipLow,
        noise_sigma: traits.noiseSigma)
    try traitsRow.save(db)
```

- [ ] **Step 6: Extend `DeepAnalysisBackfill`'s per-file pass identically**

`grep -n "PhotoTraitsRow(" Muse/Muse/Intelligence/DeepAnalysisBackfill.swift` — the backfill
constructs the same row shape from its own bounded decode; apply the identical five-field
extension so both compute sites (live analyze + backfill) stay in lockstep, per the Global
Constraint ("both compute sites ride the existing single decode").

- [ ] **Step 7: Run test to verify it passes, then a full build**

Run: `xcodebuild -scheme Muse -only-testing:MuseTests/AnalyzePipelineTraitsTests test`
Expected: PASS

Run: `xcodebuild -scheme Muse build`
Expected: BUILD SUCCEEDED

- [ ] **Step 8: Commit**

```bash
git add "Muse/Muse/Intelligence/Core/IntelligenceProtocols.swift" \
  "Muse/Muse/Intelligence/Vision/VisionServices.swift" "Muse/Muse/Intelligence/AnalyzePipeline.swift" \
  "Muse/Muse/Intelligence/DeepAnalysisBackfill.swift" "Muse/MuseTests/AnalyzePipelineTraitsTests.swift"
git commit -m "feat(spec-05): wire clip_high_r/g/b, clip_low, noise_sigma into the existing single-decode analyze pass + backfill"
```

### Task 5.4: `Editing/PhotoFeedback.swift` — the rule table

**Files:**
- Create: `Muse/Muse/Editing/PhotoFeedback.swift`
- Test: `Muse/MuseTests/PhotoFeedbackTests.swift`

**Interfaces:**
- Consumes: nothing (pure over `PhotoFeedback.Inputs`).
- Produces:
  ```swift
  nonisolated enum PhotoFeedback {
      struct Inputs: Equatable, Sendable { /* see below */ }
      enum Note: Equatable, Sendable { /* see below */ }
      static let maxNotes = 3
      static func notes(for inputs: Inputs) -> [Note]
  }
  ```

- [ ] **Step 1: Write the failing test** — the curated matrix IS the acceptance test
(spec-05 §17):

```swift
//
//  PhotoFeedbackTests.swift
//  MuseTests
//

import XCTest
@testable import Muse

final class PhotoFeedbackTests: XCTestCase {

    func testFastShutterLowISOCleanProducesNoNotes() {
        let inputs = PhotoFeedback.Inputs(
            iso: 100, exposureSeconds: 1.0 / 500, fNumber: 8, focalLength35: 50,
            flashFired: false, sharpness: 5.0, faceCount: nil,
            clipHighR: 0, clipHighG: 0, clipHighB: 0, clipLow: 0, noiseSigma: 0.5)
        XCTAssertTrue(PhotoFeedback.notes(for: inputs).isEmpty)
    }

    func testHandheldSlowShutterProducesMotionBlurRisk() {
        let inputs = PhotoFeedback.Inputs(
            iso: 400, exposureSeconds: 1.0 / 15, fNumber: 4, focalLength35: 50,
            flashFired: false, sharpness: 3.0, faceCount: nil,
            clipHighR: 0, clipHighG: 0, clipHighB: 0, clipLow: 0, noiseSigma: 1.0)
        let notes = PhotoFeedback.notes(for: inputs)
        XCTAssertTrue(notes.contains { if case .motionBlurRisk = $0 { true } else { false } })
    }

    func testFlashSuppressesMotionBlurNote() {
        let inputs = PhotoFeedback.Inputs(
            iso: 400, exposureSeconds: 1.0 / 15, fNumber: 4, focalLength35: 50,
            flashFired: true, sharpness: 3.0, faceCount: nil,
            clipHighR: 0, clipHighG: 0, clipHighB: 0, clipLow: 0, noiseSigma: 1.0)
        let notes = PhotoFeedback.notes(for: inputs)
        XCTAssertFalse(notes.contains { if case .motionBlurRisk = $0 { true } else { false } })
    }

    func testHighISOProducesNoiseNote() {
        let inputs = PhotoFeedback.Inputs(
            iso: 6400, exposureSeconds: 1.0 / 200, fNumber: 4, focalLength35: 50,
            flashFired: false, sharpness: 4.0, faceCount: nil,
            clipHighR: 0, clipHighG: 0, clipHighB: 0, clipLow: 0, noiseSigma: 8.0)
        let notes = PhotoFeedback.notes(for: inputs)
        guard case .highISONoise(let iso, let wellControlled)? = notes.first(where: {
            if case .highISONoise = $0 { true } else { false }
        }) else { return XCTFail("expected highISONoise") }
        XCTAssertEqual(iso, 6400)
        XCTAssertFalse(wellControlled)
    }

    func testHighISOWithLowNoiseSigmaIsWellControlled() {
        let inputs = PhotoFeedback.Inputs(
            iso: 6400, exposureSeconds: 1.0 / 200, fNumber: 4, focalLength35: 50,
            flashFired: false, sharpness: 4.0, faceCount: nil,
            clipHighR: 0, clipHighG: 0, clipHighB: 0, clipLow: 0, noiseSigma: 0.3)
        let notes = PhotoFeedback.notes(for: inputs)
        guard case .highISONoise(_, let wellControlled)? = notes.first(where: {
            if case .highISONoise = $0 { true } else { false }
        }) else { return XCTFail("expected highISONoise") }
        XCTAssertTrue(wellControlled)
    }

    func testSoftFocusSuppressedWhenMotionBlurAlreadyFires() {
        // Cause beats symptom: don't double-diagnose one blur as both motion blur
        // AND soft focus.
        let inputs = PhotoFeedback.Inputs(
            iso: 400, exposureSeconds: 1.0 / 10, fNumber: 4, focalLength35: 50,
            flashFired: false, sharpness: 0.5, faceCount: nil, // soft AND slow shutter
            clipHighR: 0, clipHighG: 0, clipHighB: 0, clipLow: 0, noiseSigma: 1.0)
        let notes = PhotoFeedback.notes(for: inputs)
        XCTAssertTrue(notes.contains { if case .motionBlurRisk = $0 { true } else { false } })
        XCTAssertFalse(notes.contains { if case .softFocus = $0 { true } else { false } })
    }

    func testSoftFocusFiresAloneWhenNoMotionBlurRisk() {
        let inputs = PhotoFeedback.Inputs(
            iso: 400, exposureSeconds: 1.0 / 500, fNumber: 4, focalLength35: 50,
            flashFired: false, sharpness: 0.5, faceCount: nil,
            clipHighR: 0, clipHighG: 0, clipHighB: 0, clipLow: 0, noiseSigma: 1.0)
        let notes = PhotoFeedback.notes(for: inputs)
        XCTAssertTrue(notes.contains { if case .softFocus = $0 { true } else { false } })
    }

    func testThinFocusPlaneFacesVariant() {
        let inputs = PhotoFeedback.Inputs(
            iso: 400, exposureSeconds: 1.0 / 500, fNumber: 1.8, focalLength35: 85,
            flashFired: false, sharpness: 5.0, faceCount: 1,
            clipHighR: 0, clipHighG: 0, clipHighB: 0, clipLow: 0, noiseSigma: 1.0)
        let notes = PhotoFeedback.notes(for: inputs)
        guard case .thinFocusPlane(let fNumber, let hasFaces)? = notes.first(where: {
            if case .thinFocusPlane = $0 { true } else { false }
        }) else { return XCTFail("expected thinFocusPlane") }
        XCTAssertEqual(fNumber, 1.8)
        XCTAssertTrue(hasFaces)
    }

    func testSeverityOrderIsClippingShadowsMotionNoiseSoftThin() {
        // Construct inputs that would fire ALL SIX notes; assert the returned
        // order matches the fixed severity order, capped at maxNotes.
        let inputs = PhotoFeedback.Inputs(
            iso: 6400, exposureSeconds: 1.0 / 8, fNumber: 1.4, focalLength35: 35,
            flashFired: false, sharpness: 0.3, faceCount: 0,
            clipHighR: 0.05, clipHighG: 0.01, clipHighB: 0.01, clipLow: 0.1, noiseSigma: 9.0)
        let notes = PhotoFeedback.notes(for: inputs)
        XCTAssertLessThanOrEqual(notes.count, PhotoFeedback.maxNotes)
        // clipping first (highest severity)
        XCTAssertTrue({ if case .clippedHighlights = notes[0] { return true }; return false }())
    }

    func testMaxNotesCapIsThree() {
        XCTAssertEqual(PhotoFeedback.maxNotes, 3)
    }

    func testAbsentFieldsNeverFireARule() {
        let allNil = PhotoFeedback.Inputs(
            iso: nil, exposureSeconds: nil, fNumber: nil, focalLength35: nil,
            flashFired: nil, sharpness: nil, faceCount: nil,
            clipHighR: nil, clipHighG: nil, clipHighB: nil, clipLow: nil, noiseSigma: nil)
        XCTAssertTrue(PhotoFeedback.notes(for: allNil).isEmpty)
    }

    func testDisplayTextNonEmptyForEveryNoteCase() {
        let cases: [PhotoFeedback.Note] = [
            .clippedHighlights(percent: 0.004, channel: .red),
            .crushedShadows(percent: 0.03),
            .motionBlurRisk(shutterSeconds: 1.0 / 15),
            .highISONoise(iso: 6400, wellControlled: false),
            .softFocus,
            .thinFocusPlane(fNumber: 1.8, hasFaces: true)
        ]
        for c in cases { XCTAssertFalse(c.displayText.isEmpty) }
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -scheme Muse -only-testing:MuseTests/PhotoFeedbackTests test`
Expected: FAIL — `PhotoFeedback` doesn't exist.

- [ ] **Step 3: Implement**

```swift
//
//  PhotoFeedback.swift
//  Muse
//
//  Deterministic, rule-based "Why it looks this way" feedback — NEVER an LLM.
//  Inputs come only from precomputed columns (photo_meta + photo_traits); the
//  rule table is Swift-declared (not an external data file — xcstrings
//  extraction can't see one; deviation D9). Fixed severity order, capped at
//  maxNotes. Silent case (empty result -> no card) is part of the design.
//

import Foundation

nonisolated enum PhotoFeedback {

    struct Inputs: Equatable, Sendable {
        var iso: Int?
        var exposureSeconds: Double?
        var fNumber: Double?
        var focalLength35: Double?
        var flashFired: Bool?
        var sharpness: Double?
        var faceCount: Int?
        var clipHighR: Double?
        var clipHighG: Double?
        var clipHighB: Double?
        var clipLow: Double?
        var noiseSigma: Double?
    }

    enum Note: Equatable, Sendable {
        case clippedHighlights(percent: Double, channel: RGBChannel?)
        case crushedShadows(percent: Double)
        case motionBlurRisk(shutterSeconds: Double)
        case highISONoise(iso: Int, wellControlled: Bool)
        case softFocus
        case thinFocusPlane(fNumber: Double, hasFaces: Bool)

        var displayText: String {
            switch self {
            case .clippedHighlights(let percent, let channel):
                let pct = String(format: "%.1f", percent * 100)
                if let channel {
                    let name = channel.localizedName
                    return String(localized: "\(pct)% of pixels are clipped in the \(name) channel — those areas have lost detail.")
                }
                return String(localized: "\(pct)% of pixels are clipped — those areas have lost detail.")
            case .crushedShadows(let percent):
                let pct = String(format: "%.0f", percent * 100)
                return String(localized: "Deep shadows cover \(pct)% of the frame — some shadow detail is gone.")
            case .motionBlurRisk(let shutterSeconds):
                let fraction = shutterSeconds > 0 ? Int((1.0 / shutterSeconds).rounded()) : 0
                return String(localized: "Handheld at 1/\(fraction) s — motion blur is likely.")
            case .highISONoise(let iso, let wellControlled):
                if wellControlled {
                    return String(localized: "Shadows are noisy because ISO \(iso), though noise is well controlled here.")
                }
                return String(localized: "Shadows are noisy because ISO \(iso).")
            case .softFocus:
                return String(localized: "This photo is soft — focus may have missed.")
            case .thinFocusPlane(let fNumber, let hasFaces):
                let fText = String(format: "%.1f", fNumber)
                if hasFaces {
                    return String(localized: "Shot at f/\(fText) — a thin focus plane; check the eyes.")
                }
                return String(localized: "Shot at f/\(fText) — a thin focus plane.")
            }
        }
    }

    static let maxNotes = 3

    // Named thresholds, one declaration site each.
    private static let clipNoteFloor = 0.002
    private static let shadowNoteFloor = 0.02
    private static let channelDominanceRatio = 3.0
    private static let handheldFallbackFocal = 50.0
    private static let noiseISOFloor = 3200
    private static let noiseSigmaQuiet = 2.0 // owner-tuned, see spec-05 §15.2
    private static let thinApertureCeiling = 2.0

    static func notes(for inputs: Inputs) -> [Note] {
        var notes: [Note] = []
        var motionBlurFired = false

        // 1. clippedHighlights
        let highs = [inputs.clipHighR, inputs.clipHighG, inputs.clipHighB].compactMap { $0 }
        if let maxHigh = highs.max(), maxHigh >= clipNoteFloor {
            let others = highs.filter { $0 != maxHigh }
            let secondHighest = others.max() ?? 0
            let dominant = secondHighest > 0 && maxHigh >= secondHighest * channelDominanceRatio
            let channel: RGBChannel? = dominant ? dominantChannel(inputs) : nil
            notes.append(.clippedHighlights(percent: maxHigh, channel: channel))
        }

        // 2. crushedShadows
        if let clipLow = inputs.clipLow, clipLow >= shadowNoteFloor {
            notes.append(.crushedShadows(percent: clipLow))
        }

        // 3. motionBlurRisk
        if let exposureSeconds = inputs.exposureSeconds {
            let focal = inputs.focalLength35 ?? handheldFallbackFocal
            let reciprocalThreshold = 1.0 / max(focal, 1)
            let riskyShutter = exposureSeconds >= reciprocalThreshold
            let flashSuppresses = inputs.flashFired == true
            if riskyShutter, !flashSuppresses {
                notes.append(.motionBlurRisk(shutterSeconds: exposureSeconds))
                motionBlurFired = true
            }
        }

        // 4. highISONoise
        if let iso = inputs.iso, iso >= noiseISOFloor {
            let wellControlled = (inputs.noiseSigma ?? .greatestFiniteMagnitude) < noiseSigmaQuiet
            notes.append(.highISONoise(iso: iso, wellControlled: wellControlled))
        }

        // 5. softFocus (cause beats symptom — never double-diagnose one blur)
        if let sharpness = inputs.sharpness, sharpness <= SharpnessScore.softCeiling, !motionBlurFired {
            notes.append(.softFocus)
        }

        // 6. thinFocusPlane
        if let fNumber = inputs.fNumber, fNumber <= thinApertureCeiling {
            let hasFaces = (inputs.faceCount ?? 0) >= 1
            notes.append(.thinFocusPlane(fNumber: fNumber, hasFaces: hasFaces))
        }

        return Array(notes.prefix(maxNotes))
    }

    private static func dominantChannel(_ inputs: Inputs) -> RGBChannel {
        let r = inputs.clipHighR ?? 0, g = inputs.clipHighG ?? 0, b = inputs.clipHighB ?? 0
        if r >= g && r >= b { return .red }
        if g >= r && g >= b { return .green }
        return .blue
    }
}

private extension RGBChannel {
    var localizedName: String {
        switch self {
        case .red: String(localized: "red")
        case .green: String(localized: "green")
        case .blue: String(localized: "blue")
        }
    }
}
```

(`SharpnessScore.softCeiling` is Spec 03's existing bucket threshold constant — confirm its
exact name via `grep -n "softCeiling" Muse/Muse/Intelligence/Core/SharpnessScore.swift`.)

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild -scheme Muse -only-testing:MuseTests/PhotoFeedbackTests test`
Expected: PASS (tune `noiseSigmaQuiet` and any borderline threshold against the test
fixtures above until the curated matrix passes exactly as written — these are the numbers
spec-05 §15.2 flags for owner calibration later; the test's SHAPE is what's pinned now).

- [ ] **Step 5: Commit**

```bash
git add "Muse/Muse/Editing/PhotoFeedback.swift" "Muse/MuseTests/PhotoFeedbackTests.swift"
git commit -m "feat(spec-05): PhotoFeedback — deterministic rule table, the curated acceptance matrix"
```

### Task 5.5: `Database/PhotoStatsQueries.swift` — `feedbackInputs` read

**Files:**
- Create: `Muse/Muse/Database/PhotoStatsQueries.swift`
- Test: `Muse/MuseTests/PhotoStatsQueriesTests.swift`

**Interfaces:**
- Consumes: `photo_meta` (Spec 02), `photo_traits` (Spec 03, extended Task 5.1),
  `PhotoFeedback.Inputs` (Task 5.4).
- Produces: `PhotoStatsQueries.feedbackInputs(fileID: String, db: GRDB.Database) throws ->
  PhotoFeedback.Inputs?`.

- [ ] **Step 1: Write the failing test**

```swift
//
//  PhotoStatsQueriesTests.swift
//  MuseTests
//

import XCTest
import GRDB
@testable import Muse

final class PhotoStatsQueriesTests: XCTestCase {

    private func makeQueue() throws -> DatabaseQueue {
        let q = try DatabaseQueue()
        try Database.makeMigrator().migrate(q)
        return q
    }

    private func insertFile(_ db: GRDB.Database, id: String) throws {
        try db.execute(sql: "INSERT INTO files (id, content_hash, kind, last_seen_at) VALUES (?, ?, 'image', 0)",
                       arguments: [id, id + "-hash"])
    }

    func testFeedbackInputsJoinsMetaAndTraits() throws {
        let q = try makeQueue()
        try q.write { db in
            try insertFile(db, id: "f1")
            try db.execute(sql: """
                INSERT INTO photo_meta (file_id, iso, exposure_seconds, f_number, focal_length_35mm, flash_fired)
                VALUES ('f1', 6400, 0.0625, 1.8, 85, 0)
                """)
            var traits = PhotoTraitsRow(file_id: "f1", traits_scanned_hash: "f1-hash",
                                         traits_version: PhotoTraits.currentVersion, face_count: 1,
                                         largest_face_frac: 0.4, face_quality: 0.9, pet_count: 0,
                                         sharpness: 4.0, clip_high_r: 0.01, clip_high_g: 0.005,
                                         clip_high_b: 0.006, clip_low: 0.02, noise_sigma: 3.5)
            try traits.insert(db)
        }
        let inputs = try q.read { db in try PhotoStatsQueries.feedbackInputs(fileID: "f1", db: db) }
        XCTAssertEqual(inputs?.iso, 6400)
        XCTAssertEqual(inputs?.fNumber, 1.8)
        XCTAssertEqual(inputs?.sharpness, 4.0)
        XCTAssertEqual(inputs?.clipHighR, 0.01)
        XCTAssertEqual(inputs?.faceCount, 1)
    }

    func testMissingMetaRowReturnsPartialInputsNeverThrows() throws {
        let q = try makeQueue()
        try q.write { db in
            try insertFile(db, id: "f2")
            var traits = PhotoTraitsRow(file_id: "f2", traits_scanned_hash: "f2-hash",
                                         traits_version: PhotoTraits.currentVersion, face_count: 0,
                                         largest_face_frac: nil, face_quality: nil, pet_count: 0,
                                         sharpness: 5.0, clip_high_r: 0, clip_high_g: 0,
                                         clip_high_b: 0, clip_low: 0, noise_sigma: 0.5)
            try traits.insert(db)
        }
        let inputs = try q.read { db in try PhotoStatsQueries.feedbackInputs(fileID: "f2", db: db) }
        XCTAssertNotNil(inputs)
        XCTAssertNil(inputs?.iso)
        XCTAssertEqual(inputs?.sharpness, 5.0)
    }

    func testMissingTraitsRowReturnsPartialInputsNeverThrows() throws {
        let q = try makeQueue()
        try q.write { db in
            try insertFile(db, id: "f3")
            try db.execute(sql: """
                INSERT INTO photo_meta (file_id, iso, exposure_seconds, f_number, focal_length_35mm, flash_fired)
                VALUES ('f3', 100, 0.01, 8, 50, 0)
                """)
        }
        let inputs = try q.read { db in try PhotoStatsQueries.feedbackInputs(fileID: "f3", db: db) }
        XCTAssertNotNil(inputs)
        XCTAssertEqual(inputs?.iso, 100)
        XCTAssertNil(inputs?.sharpness)
    }

    func testNoRowsAtAllReturnsNil() throws {
        let q = try makeQueue()
        try q.write { db in try insertFile(db, id: "f4") }
        let inputs = try q.read { db in try PhotoStatsQueries.feedbackInputs(fileID: "f4", db: db) }
        XCTAssertNil(inputs)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -scheme Muse -only-testing:MuseTests/PhotoStatsQueriesTests test`
Expected: FAIL — `PhotoStatsQueries` doesn't exist.

- [ ] **Step 3: Implement**

```swift
//
//  PhotoStatsQueries.swift
//  Muse
//
//  One read joining photo_meta + photo_traits by file id, producing
//  PhotoFeedback.Inputs. Nonisolated pure-query enum (the NoteStore shape) —
//  called inside the hero's existing details load, which is already an
//  off-main async pass, so this adds no new decode or query-time analysis.
//

import GRDB

nonisolated enum PhotoStatsQueries {
    static func feedbackInputs(fileID: String, db: GRDB.Database) throws -> PhotoFeedback.Inputs? {
        let meta = try Row.fetchOne(db, sql: """
            SELECT iso, exposure_seconds, f_number, focal_length_35mm, flash_fired
            FROM photo_meta WHERE file_id = ?
            """, arguments: [fileID])
        let traits = try Row.fetchOne(db, sql: """
            SELECT face_count, sharpness, clip_high_r, clip_high_g, clip_high_b, clip_low, noise_sigma
            FROM photo_traits WHERE file_id = ?
            """, arguments: [fileID])

        guard meta != nil || traits != nil else { return nil }

        return PhotoFeedback.Inputs(
            iso: meta?["iso"], exposureSeconds: meta?["exposure_seconds"],
            fNumber: meta?["f_number"], focalLength35: meta?["focal_length_35mm"],
            flashFired: (meta?["flash_fired"] as Int?).map { $0 != 0 },
            sharpness: traits?["sharpness"], faceCount: traits?["face_count"],
            clipHighR: traits?["clip_high_r"], clipHighG: traits?["clip_high_g"],
            clipHighB: traits?["clip_high_b"], clipLow: traits?["clip_low"],
            noiseSigma: traits?["noise_sigma"])
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild -scheme Muse -only-testing:MuseTests/PhotoStatsQueriesTests test`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add "Muse/Muse/Database/PhotoStatsQueries.swift" "Muse/MuseTests/PhotoStatsQueriesTests.swift"
git commit -m "feat(spec-05): PhotoStatsQueries.feedbackInputs — photo_meta + photo_traits join for PhotoFeedback"
```

### Task 5.6: Hero INFO column card + editor Info tab rows + RAW process line

**Files:**
- Modify: `Muse/Muse/Views/Viewer/ViewerInfoColumn.swift` (new collapsible feedback card
  between the INFO card and the actions row; `feedbackNotes` param)
- Modify: `Muse/Muse/Settings/AppSettings.swift` (`feedbackCardExpandedKey`)
- Modify: wherever `HeroImageViewer.loadDetails` lives (`grep -n "func loadDetails"
  Muse/Muse/Viewers/HeroImageViewer.swift`) to call `PhotoStatsQueries.feedbackInputs` and
  pass `PhotoFeedback.notes(for:)` down
- Modify: `Muse/Muse/Views/Editor/EditorView.swift` (Info tab: append feedback note rows +
  the RAW process line)

**Interfaces:**
- Consumes: `PhotoFeedback.notes`/`.Note` (Task 5.4), `PhotoStatsQueries.feedbackInputs`
  (Task 5.5), `RawParams.decoderVersion` (Spec 04, if present).
- Produces: `ViewerInfoColumn(..., feedbackNotes: [PhotoFeedback.Note] = [])`.

- [ ] **Step 1: Add `AppSettings.feedbackCardExpandedKey`**

```swift
    static let feedbackCardExpandedKey = "heroFeedbackCardExpanded"

    /// "Why it looks this way" card: collapsible, expanded by default. Global
    /// last-choice, same pattern as colorsCardExpanded — plain @State-seeded
    /// from this accessor rather than @AppStorage so the toggle can run inside
    /// withAnimation (see CLAUDE.md's @AppStorage-inside-withAnimation trap).
    static var feedbackCardExpanded: Bool {
        UserDefaults.standard.object(forKey: feedbackCardExpandedKey) as? Bool ?? true
    }
```

- [ ] **Step 2: Add the card to `ViewerInfoColumn`**

`grep -n "colorsCard\|infoCard\|actionsRow" Muse/Muse/Views/Viewer/ViewerInfoColumn.swift`
(the existing card ordering, ~lines 63-90). Add a new `@State` seeded like `colorsExpanded`:

```swift
    @State private var feedbackExpanded = AppSettings.feedbackCardExpanded
```

Add a new `feedbackNotes` parameter to the view's initializer (default `[]` so every
existing call site compiles unchanged):

```swift
    var feedbackNotes: [PhotoFeedback.Note] = []
```

In `body`, between `colorsCard`/`colorsPlaceholderCard` and `infoCard`:

```swift
                if !feedbackNotes.isEmpty {
                    feedbackCard
                }
```

Add the card view (same collapsible-card shape as `colorsCard`, `noteCard`):

```swift
    private var feedbackCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation { feedbackExpanded.toggle() }
                UserDefaults.standard.set(feedbackExpanded, forKey: AppSettings.feedbackCardExpandedKey)
            } label: {
                CardLabel(text: String(localized: "WHY IT LOOKS THIS WAY"))
            }
            .buttonStyle(.plain)
            if feedbackExpanded {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(feedbackNotes.enumerated()), id: \.offset) { _, note in
                        Text(note.displayText)
                            .font(.system(size: 12))
                    }
                }
            }
        }
    }
```

- [ ] **Step 3: Wire `HeroImageViewer.loadDetails` to compute `feedbackNotes`**

`grep -n "func loadDetails" Muse/Muse/Viewers/HeroImageViewer.swift` — inside the existing
off-main async details pass, add:

```swift
let feedbackNotes: [PhotoFeedback.Note]
if let inputs = try? await Database.shared.read({ db in
    try PhotoStatsQueries.feedbackInputs(fileID: fileID, db: db)
}), let inputs {
    feedbackNotes = PhotoFeedback.notes(for: inputs)
} else {
    feedbackNotes = []
}
```

Pass `feedbackNotes` through to the `ViewerInfoColumn(..., feedbackNotes: feedbackNotes)`
call site.

- [ ] **Step 4: Add feedback rows + RAW process line to the editor's Info tab**

`grep -n "Info tab\|exifSummary" Muse/Muse/Views/Editor/EditorView.swift` — under the
existing EXIF summary, append:

```swift
ForEach(Array(feedbackNotes.enumerated()), id: \.offset) { _, note in
    Text(note.displayText).font(theme.labelFont)
}
if let rawParams = session.draft.rawParams {
    let live = EditRenderer.supportedDecoderVersions // Spec 04's live-support set, if present
    if live.contains(rawParams.decoderVersion) {
        Text(String(localized: "Process: RAW decoder v\(rawParams.decoderVersion)"))
            .font(theme.labelFont)
    } else {
        let fallback = live.max() ?? rawParams.decoderVersion
        Text(String(localized: "Process: RAW decoder v\(rawParams.decoderVersion) (this Mac renders with v\(fallback))"))
            .font(theme.labelFont)
    }
}
```

(`EditRenderer.supportedDecoderVersions` / `RawParams.decoderVersion` are Spec 04 types —
confirm their exact names via `grep -rn "decoderVersion" Muse/Muse/Editing/` before wiring;
if Spec 04 named them differently, adjust this snippet to match rather than inventing new
names.)

- [ ] **Step 5: Manual verification**

Build, run, open a photo with known EXIF (high ISO, slow shutter) in the hero viewer —
confirm the "WHY IT LOOKS THIS WAY" card appears with the expected notes and is omitted
entirely for a clean, well-exposed photo. Open the same photo in the editor's Info tab —
confirm the same notes appear there too, plus the RAW process line for a `.raw` source.

- [ ] **Step 6: Commit**

```bash
git add "Muse/Muse/Views/Viewer/ViewerInfoColumn.swift" "Muse/Muse/Settings/AppSettings.swift" \
  "Muse/Muse/Viewers/HeroImageViewer.swift" "Muse/Muse/Views/Editor/EditorView.swift"
git commit -m "feat(spec-05): 'Why it looks this way' surfaces — hero INFO card + editor Info tab + RAW process line"
```

---

## Phase 6 — `.cube` LUT import

### Task 6.1: `Editing/CubeLUT.swift` — pure `.cube` parser

**Files:**
- Create: `Muse/Muse/Editing/CubeLUT.swift`
- Test: `Muse/MuseTests/CubeLUTParserTests.swift`

**Interfaces:**
- Consumes: nothing (pure over a `String`).
- Produces:
  ```swift
  nonisolated struct CubeLUT: Equatable, Sendable {
      let size: Int; let data: [Float]
      var canonicalData: Data { get }
      static func hash(_ lut: CubeLUT) -> String
  }
  nonisolated enum CubeLUTParser {
      static let maxFileBytes = 64 * 1024 * 1024
      static let maxSize = 128
      enum ParseError: Error, Equatable {
          case tooLarge, notA3DLUT, badSize, badValue(line: Int)
          case wrongCount(expected: Int, got: Int), unsupportedDomain
      }
      static func parse(_ text: String) throws -> (lut: CubeLUT, title: String?)
  }
  ```

- [ ] **Step 1: Write the failing test**

```swift
//
//  CubeLUTParserTests.swift
//  MuseTests
//

import XCTest
@testable import Muse

final class CubeLUTParserTests: XCTestCase {

    /// A minimal valid identity 2x2x2 cube — the .cube spec's canonical
    /// R-fastest-varying order: (0,0,0), (1,0,0), (0,1,0), (1,1,0), (0,0,1), (1,0,1), (0,1,1), (1,1,1).
    private func identity2Cube(title: String? = "Identity") -> String {
        var lines: [String] = []
        if let title { lines.append("TITLE \"\(title)\"") }
        lines.append("# a comment line")
        lines.append("LUT_3D_SIZE 2")
        for bIdx in 0..<2 {
            for gIdx in 0..<2 {
                for rIdx in 0..<2 {
                    lines.append("\(Double(rIdx)) \(Double(gIdx)) \(Double(bIdx))")
                }
            }
        }
        return lines.joined(separator: "\n")
    }

    func testSize2Parses() throws {
        let (lut, title) = try CubeLUTParser.parse(identity2Cube())
        XCTAssertEqual(lut.size, 2)
        XCTAssertEqual(lut.data.count, 2 * 2 * 2 * 3)
        XCTAssertEqual(title, "Identity")
    }

    func testRFastestVaryingOrderPinnedByAsymmetricFixture() throws {
        // An ASYMMETRIC fixture: only the entry at (r=1,g=0,b=0) has a distinct
        // marker value, so any axis-order mixup fails this assertion.
        var lines = ["LUT_3D_SIZE 2"]
        let marker = 0.777
        var index = 0
        var expectedMarkerIndex = -1
        for bIdx in 0..<2 {
            for gIdx in 0..<2 {
                for rIdx in 0..<2 {
                    if rIdx == 1 && gIdx == 0 && bIdx == 0 {
                        lines.append("\(marker) 0.0 0.0")
                        expectedMarkerIndex = index
                    } else {
                        lines.append("0.0 0.0 0.0")
                    }
                    index += 1
                }
            }
        }
        let (lut, _) = try CubeLUTParser.parse(lines.joined(separator: "\n"))
        XCTAssertEqual(lut.data[expectedMarkerIndex * 3], Float(marker))
    }

    func testTitleAndCommentsAreSkipped() throws {
        let (_, title) = try CubeLUTParser.parse(identity2Cube(title: "My Look"))
        XCTAssertEqual(title, "My Look")
    }

    func testMissingTitleReturnsNilTitle() throws {
        let (_, title) = try CubeLUTParser.parse(identity2Cube(title: nil))
        XCTAssertNil(title)
    }

    func testDefaultDomainIsAccepted() throws {
        let text = "DOMAIN_MIN 0.0 0.0 0.0\nDOMAIN_MAX 1.0 1.0 1.0\n" + identity2Cube()
        XCTAssertNoThrow(try CubeLUTParser.parse(text))
    }

    func testNonDefaultDomainThrowsUnsupportedDomain() {
        let text = "DOMAIN_MIN 0.0 0.0 0.0\nDOMAIN_MAX 2.0 2.0 2.0\nLUT_3D_SIZE 2\n" +
            String(repeating: "0.0 0.0 0.0\n", count: 8)
        XCTAssertThrowsError(try CubeLUTParser.parse(text)) { error in
            XCTAssertEqual(error as? CubeLUTParser.ParseError, .unsupportedDomain)
        }
    }

    func testLut1DSizeThrowsNotA3DLUT() {
        let text = "LUT_1D_SIZE 16\n" + String(repeating: "0.0 0.0 0.0\n", count: 16)
        XCTAssertThrowsError(try CubeLUTParser.parse(text)) { error in
            XCTAssertEqual(error as? CubeLUTParser.ParseError, .notA3DLUT)
        }
    }

    func testWrongDataLineCountThrowsWrongCount() {
        let text = "LUT_3D_SIZE 2\n" + String(repeating: "0.0 0.0 0.0\n", count: 3) // needs 8
        XCTAssertThrowsError(try CubeLUTParser.parse(text)) { error in
            guard case .wrongCount(let expected, let got) = error as? CubeLUTParser.ParseError else {
                return XCTFail("expected wrongCount")
            }
            XCTAssertEqual(expected, 8)
            XCTAssertEqual(got, 3)
        }
    }

    func testBadValueThrowsWithLineNumber() {
        let text = "LUT_3D_SIZE 2\n0.0 0.0 0.0\nNOTANUMBER 0.0 0.0\n" + String(repeating: "0.0 0.0 0.0\n", count: 6)
        XCTAssertThrowsError(try CubeLUTParser.parse(text)) { error in
            guard case .badValue(let line) = error as? CubeLUTParser.ParseError else {
                return XCTFail("expected badValue")
            }
            XCTAssertEqual(line, 3) // LUT_3D_SIZE=1, first data row=2, bad row=3
        }
    }

    func testSizeAboveMaxSizeThrowsBadSize() {
        let text = "LUT_3D_SIZE 129\n"
        XCTAssertThrowsError(try CubeLUTParser.parse(text)) { error in
            XCTAssertEqual(error as? CubeLUTParser.ParseError, .badSize)
        }
    }

    func testFileAboveMaxBytesThrowsTooLarge() {
        let huge = String(repeating: "x", count: CubeLUTParser.maxFileBytes + 1)
        XCTAssertThrowsError(try CubeLUTParser.parse(huge)) { error in
            XCTAssertEqual(error as? CubeLUTParser.ParseError, .tooLarge)
        }
    }

    func testHashIsStableAndPinnedOnAFixture() throws {
        let (lut, _) = try CubeLUTParser.parse(identity2Cube())
        let hash1 = CubeLUT.hash(lut)
        let hash2 = CubeLUT.hash(lut)
        XCTAssertEqual(hash1, hash2)
        XCTAssertEqual(hash1.count, 64)
    }

    func testSize33And64ParseSuccessfully() throws {
        for size in [33, 64] {
            var lines = ["LUT_3D_SIZE \(size)"]
            for _ in 0..<(size * size * size) { lines.append("0.5 0.5 0.5") }
            let (lut, _) = try CubeLUTParser.parse(lines.joined(separator: "\n"))
            XCTAssertEqual(lut.size, size)
        }
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -scheme Muse -only-testing:MuseTests/CubeLUTParserTests test`
Expected: FAIL — `CubeLUT`/`CubeLUTParser` don't exist.

- [ ] **Step 3: Implement**

```swift
//
//  CubeLUT.swift
//  Muse
//
//  Pure .cube (Adobe/Resolve convention) parser, written fresh against the
//  format spec (SwiftCube, MIT, is the read-for-reference implementation —
//  read, not copied). Non-default DOMAIN_MIN/MAX is refused rather than
//  resampled (resampling would silently misrepresent the look).
//

import Foundation
import CryptoKit

nonisolated struct CubeLUT: Equatable, Sendable {
    let size: Int
    /// size^3 x 3 floats, R fastest-varying (the .cube spec's storage order).
    /// Values may exceed 0...1 (some looks lift beyond the domain; CIColorCube
    /// tolerates it).
    let data: [Float]

    var canonicalData: Data {
        data.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    static func hash(_ lut: CubeLUT) -> String {
        SHA256.hash(data: lut.canonicalData).compactMap { String(format: "%02x", $0) }.joined()
    }
}

nonisolated enum CubeLUTParser {
    static let maxFileBytes = 64 * 1024 * 1024   // a 128^3 text cube ~= 50 MB; beyond is not a LUT
    static let maxSize = 128                      // CIColorCube's documented ceiling
    private static let domainTolerance = 1e-4

    enum ParseError: Error, Equatable {
        case tooLarge, notA3DLUT, badSize
        case badValue(line: Int), wrongCount(expected: Int, got: Int)
        case unsupportedDomain
    }

    static func parse(_ text: String) throws -> (lut: CubeLUT, title: String?) {
        guard text.utf8.count <= maxFileBytes else { throw ParseError.tooLarge }

        var title: String?
        var size: Int?
        var domainMin: (Double, Double, Double) = (0, 0, 0)
        var domainMax: (Double, Double, Double) = (1, 1, 1)
        var values: [Float] = []
        var dataLineNumber = 0

        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        for (index, rawLine) in lines.enumerated() {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            let lineNumber = index + 1
            if line.isEmpty || line.hasPrefix("#") { continue }

            if line.hasPrefix("TITLE") {
                let rest = line.dropFirst("TITLE".count).trimmingCharacters(in: .whitespaces)
                title = rest.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                continue
            }
            if line.hasPrefix("LUT_1D_SIZE") {
                throw ParseError.notA3DLUT
            }
            if line.hasPrefix("LUT_3D_SIZE") {
                let rest = line.dropFirst("LUT_3D_SIZE".count).trimmingCharacters(in: .whitespaces)
                guard let n = Int(rest), n >= 2, n <= maxSize else { throw ParseError.badSize }
                size = n
                continue
            }
            if line.hasPrefix("DOMAIN_MIN") {
                let parts = line.dropFirst("DOMAIN_MIN".count).split(separator: " ").compactMap { Double($0) }
                guard parts.count == 3 else { throw ParseError.badValue(line: lineNumber) }
                domainMin = (parts[0], parts[1], parts[2])
                continue
            }
            if line.hasPrefix("DOMAIN_MAX") {
                let parts = line.dropFirst("DOMAIN_MAX".count).split(separator: " ").compactMap { Double($0) }
                guard parts.count == 3 else { throw ParseError.badValue(line: lineNumber) }
                domainMax = (parts[0], parts[1], parts[2])
                continue
            }
            if line.hasPrefix("TITLE") || line.hasPrefix("LUT_1D_INPUT_RANGE")
                || line.hasPrefix("LUT_3D_INPUT_RANGE") {
                continue // ignored, not load-bearing for this importer
            }

            // A data line: three floats.
            let parts = line.split(separator: " ").map(String.init)
            guard parts.count == 3,
                  let r = Float(parts[0]), let g = Float(parts[1]), let b = Float(parts[2])
            else { throw ParseError.badValue(line: lineNumber) }
            values.append(r); values.append(g); values.append(b)
            dataLineNumber += 1
        }

        guard let resolvedSize = size else { throw ParseError.badSize }

        let domainIsDefault =
            abs(domainMin.0) < domainTolerance && abs(domainMin.1) < domainTolerance && abs(domainMin.2) < domainTolerance &&
            abs(domainMax.0 - 1) < domainTolerance && abs(domainMax.1 - 1) < domainTolerance && abs(domainMax.2 - 1) < domainTolerance
        guard domainIsDefault else { throw ParseError.unsupportedDomain }

        let expectedCount = resolvedSize * resolvedSize * resolvedSize
        guard dataLineNumber == expectedCount else {
            throw ParseError.wrongCount(expected: expectedCount, got: dataLineNumber)
        }

        return (CubeLUT(size: resolvedSize, data: values), title)
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild -scheme Muse -only-testing:MuseTests/CubeLUTParserTests test`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add "Muse/Muse/Editing/CubeLUT.swift" "Muse/MuseTests/CubeLUTParserTests.swift"
git commit -m "feat(spec-05): CubeLUT + CubeLUTParser — pure .cube parser, R-fastest order pinned"
```

### Task 6.2: `v23_edit_luts` migration + `EditLutRow`

**Files:**
- Modify: `Muse/Muse/Database/Database.swift` (append after v22)
- Modify: `Muse/Muse/Database/Records.swift` (add `EditLutRow`)
- Test: `Muse/MuseTests/EditLutMigrationTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: table `edit_luts` (`id` TEXT PK = content hash), `struct EditLutRow: Codable,
  FetchableRecord, MutablePersistableRecord`.

- [ ] **Step 1: Write the failing test**

```swift
//
//  EditLutMigrationTests.swift
//  MuseTests
//

import XCTest
import GRDB
@testable import Muse

final class EditLutMigrationTests: XCTestCase {

    private func makeQueue() throws -> DatabaseQueue {
        let q = try DatabaseQueue()
        try Database.makeMigrator().migrate(q)
        return q
    }

    func testV23CreatesEditLutsTable() throws {
        let q = try makeQueue()
        try q.read { db in XCTAssertTrue(try db.tableExists("edit_luts")) }
    }

    func testContentAddressedPKConflictIsIgnored() throws {
        let q = try makeQueue()
        try q.write { db in
            try db.execute(sql: """
                INSERT OR IGNORE INTO edit_luts (id, name, size, data, created_at)
                VALUES ('abc123', 'First Name', 33, x'00', 0)
                """)
            try db.execute(sql: """
                INSERT OR IGNORE INTO edit_luts (id, name, size, data, created_at)
                VALUES ('abc123', 'Second Name', 33, x'00', 1)
                """)
        }
        let row = try q.read { db in try EditLutRow.fetchOne(db, key: "abc123") }
        XCTAssertEqual(row?.name, "First Name") // re-import dedupes, first name kept
        let count = try q.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM edit_luts") ?? 0 }
        XCTAssertEqual(count, 1)
    }

    func testMigrationIsIdempotentOnV22() throws {
        let q = try DatabaseQueue()
        try Database.makeMigrator().migrate(q)
        XCTAssertNoThrow(try Database.makeMigrator().migrate(q))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -scheme Muse -only-testing:MuseTests/EditLutMigrationTests test`
Expected: FAIL — no `edit_luts` table, no `EditLutRow`.

- [ ] **Step 3: Add the migration**

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

Add `EditLutRow` to `Records.swift`:

```swift
struct EditLutRow: Codable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "edit_luts"
    var id: String
    var name: String
    var size: Int
    var data: Data
    var created_at: Int64
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild -scheme Muse -only-testing:MuseTests/EditLutMigrationTests test`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add "Muse/Muse/Database/Database.swift" "Muse/Muse/Database/Records.swift" \
  "Muse/MuseTests/EditLutMigrationTests.swift"
git commit -m "feat(spec-05): v23_edit_luts migration — content-addressed, immutable LUT storage"
```

### Task 6.3: `Editing/LutRegistry.swift` — LRU decode cache

**Files:**
- Create: `Muse/Muse/Editing/LutRegistry.swift`
- Test: `Muse/MuseTests/LutRegistryTests.swift`

**Interfaces:**
- Consumes: `edit_luts` (Task 6.2), `Database.shared` (existing GRDB queue).
- Produces: `LutRegistry.rgbaCube(for: String) -> (size: Int, data: Data)?`,
  `LutRegistry.invalidate(_ id: String)`, `LutRegistry.cacheLimit = 8`.

- [ ] **Step 1: Write the failing test**

```swift
//
//  LutRegistryTests.swift
//  MuseTests
//

import XCTest
import GRDB
@testable import Muse

final class LutRegistryTests: XCTestCase {

    private func makeQueueWithLut(id: String, size: Int) throws -> DatabaseQueue {
        let q = try DatabaseQueue()
        try Database.makeMigrator().migrate(q)
        try q.write { db in
            let rgbData = Data(repeating: 0, count: size * size * size * 3 * 4) // float32 RGB
            var row = EditLutRow(id: id, name: "Test", size: size, data: rgbData, created_at: 0)
            try row.insert(db)
        }
        return q
    }

    func testRGBToRGBAConversionAddsAlphaChannel() throws {
        let q = try makeQueueWithLut(id: "lut1", size: 2)
        let result = LutRegistry.rgbaCube(for: "lut1", queue: q)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.size, 2)
        // RGB (3 floats/entry) -> RGBA (4 floats/entry): data length grows by 4/3.
        let expectedRGBACount = 2 * 2 * 2 * 4 * 4 // entries * 4 floats * 4 bytes
        XCTAssertEqual(result?.data.count, expectedRGBACount)
    }

    func testMissingIDReturnsNil() throws {
        let q = try DatabaseQueue()
        try Database.makeMigrator().migrate(q)
        XCTAssertNil(LutRegistry.rgbaCube(for: "nonexistent", queue: q))
    }

    func testInvalidateRemovesFromCache() throws {
        let q = try makeQueueWithLut(id: "lut2", size: 2)
        _ = LutRegistry.rgbaCube(for: "lut2", queue: q) // warms cache
        LutRegistry.invalidate("lut2")
        // After invalidate + deleting the row, a re-fetch must miss (proves the
        // cache entry, not just the DB row, was cleared).
        try q.write { db in try db.execute(sql: "DELETE FROM edit_luts WHERE id = 'lut2'") }
        XCTAssertNil(LutRegistry.rgbaCube(for: "lut2", queue: q))
    }

    func testCacheLimitIsEight() {
        XCTAssertEqual(LutRegistry.cacheLimit, 8)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -scheme Muse -only-testing:MuseTests/LutRegistryTests test`
Expected: FAIL — `LutRegistry` doesn't exist.

- [ ] **Step 3: Implement**

```swift
//
//  LutRegistry.swift
//  Muse
//
//  RENDER-PATH-ONLY — never call on the main thread (miss = one sync DB read,
//  small I/O). Decoded LUTs are MB-scale; never library-resident, LRU-capped.
//  A missing id means the referencing stack is UNRENDERABLE — see
//  EditRenderer.canRender (Task 6.5).
//

import Foundation
import GRDB

nonisolated enum LutRegistry {
    static let cacheLimit = 8

    private static let lock = NSLock()
    private static var cache: [String: (size: Int, data: Data)] = [:]
    private static var lruOrder: [String] = []

    /// RGBA float32 cube data ready for CIColorCube (alpha appended), cached
    /// LRU. `queue` defaults to the app's live database; a queue parameter is
    /// exposed so tests can pass an isolated in-memory queue.
    static func rgbaCube(for id: String, queue: DatabaseQueue = Database.shared.queue) -> (size: Int, data: Data)? {
        lock.lock()
        if let hit = cache[id] {
            lruOrder.removeAll { $0 == id }
            lruOrder.append(id)
            lock.unlock()
            return hit
        }
        lock.unlock()

        guard let row = try? queue.read({ db in try EditLutRow.fetchOne(db, key: id) }), let row else {
            return nil
        }

        let rgbFloats = row.data.withUnsafeBytes { ptr -> [Float] in
            Array(ptr.bindMemory(to: Float.self))
        }
        var rgba = [Float]()
        rgba.reserveCapacity(rgbFloats.count / 3 * 4)
        var i = 0
        while i + 2 < rgbFloats.count {
            rgba.append(rgbFloats[i]); rgba.append(rgbFloats[i + 1]); rgba.append(rgbFloats[i + 2]); rgba.append(1.0)
            i += 3
        }
        let rgbaData = rgba.withUnsafeBufferPointer { Data(buffer: $0) }
        let entry = (size: row.size, data: rgbaData)

        lock.lock()
        cache[id] = entry
        lruOrder.append(id)
        if lruOrder.count > cacheLimit {
            let evict = lruOrder.removeFirst()
            cache.removeValue(forKey: evict)
        }
        lock.unlock()

        return entry
    }

    static func invalidate(_ id: String) {
        lock.lock()
        cache.removeValue(forKey: id)
        lruOrder.removeAll { $0 == id }
        lock.unlock()
    }
}
```

(`Database.shared.queue` assumes `Database.shared` exposes its underlying `DatabaseQueue` —
confirm the exact accessor name via `grep -n "class Database" Muse/Muse/Database/Database.swift`;
adjust if the real API is `Database.shared.dbQueue` or similar.)

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild -scheme Muse -only-testing:MuseTests/LutRegistryTests test`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add "Muse/Muse/Editing/LutRegistry.swift" "Muse/MuseTests/LutRegistryTests.swift"
git commit -m "feat(spec-05): LutRegistry — LRU RGB->RGBA decode cache, render-path-only"
```

### Task 6.4: `Models/LutStore.swift` — Pattern B store

**Files:**
- Create: `Muse/Muse/Models/LutStore.swift`
- Test: `Muse/MuseTests/LutStoreTests.swift`

**Interfaces:**
- Consumes: `CubeLUTParser`/`CubeLUT` (Task 6.1), `edit_luts`/`EditLutRow` (Task 6.2),
  `LutRegistry.invalidate` (Task 6.3).
- Produces:
  ```swift
  @MainActor final class LutStore: ObservableObject {
      static let shared = LutStore()
      struct Listing: Identifiable, Equatable { let id, name: String; let size: Int; let createdAt: Int64 }
      @Published private(set) var luts: [Listing] = []
      func reload() async
      func importCubes(at urls: [URL]) async -> [String: Error]
      func rename(id: String, to: String) async
      func delete(id: String) async
      func referenceCount(id: String) async -> Int
  }
  ```

- [ ] **Step 1: Write the failing test**

```swift
//
//  LutStoreTests.swift
//  MuseTests
//

import XCTest
@testable import Muse

@MainActor
final class LutStoreTests: XCTestCase {

    private func write(_ text: String, to url: URL) throws {
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func identityCubeText(size: Int = 2, title: String) -> String {
        var lines = ["TITLE \"\(title)\"", "LUT_3D_SIZE \(size)"]
        for _ in 0..<(size * size * size) { lines.append("0.5 0.5 0.5") }
        return lines.joined(separator: "\n")
    }

    func testImportThenReloadListsTheLut() async throws {
        let store = LutStore()
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".cube")
        try write(identityCubeText(title: "Kodak 2383"), to: tmp)
        let failures = await store.importCubes(at: [tmp])
        XCTAssertTrue(failures.isEmpty)
        await store.reload()
        XCTAssertTrue(store.luts.contains { $0.name == "Kodak 2383" })
    }

    func testImportDedupesByHashKeepingFirstName() async throws {
        let store = LutStore()
        let tmpA = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".cube")
        let tmpB = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".cube")
        try write(identityCubeText(title: "First"), to: tmpA)
        try write(identityCubeText(title: "Second"), to: tmpB) // identical bytes, different name
        _ = await store.importCubes(at: [tmpA])
        _ = await store.importCubes(at: [tmpB])
        await store.reload()
        let matching = store.luts.filter { $0.name == "First" || $0.name == "Second" }
        XCTAssertEqual(matching.count, 1)
        XCTAssertEqual(matching.first?.name, "First")
    }

    func testRenameIsDisplayOnlyIDStable() async throws {
        let store = LutStore()
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".cube")
        try write(identityCubeText(title: "Original"), to: tmp)
        _ = await store.importCubes(at: [tmp])
        await store.reload()
        let id = try XCTUnwrap(store.luts.first { $0.name == "Original" }?.id)
        await store.rename(id: id, to: "Renamed")
        await store.reload()
        XCTAssertTrue(store.luts.contains { $0.id == id && $0.name == "Renamed" })
    }

    func testDeleteRemovesFromListing() async throws {
        let store = LutStore()
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".cube")
        try write(identityCubeText(title: "Temp"), to: tmp)
        _ = await store.importCubes(at: [tmp])
        await store.reload()
        let id = try XCTUnwrap(store.luts.first { $0.name == "Temp" }?.id)
        await store.delete(id: id)
        await store.reload()
        XCTAssertFalse(store.luts.contains { $0.id == id })
    }

    func testImportFailureSurfacesByFilename() async throws {
        let store = LutStore()
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("bad.cube")
        try write("LUT_1D_SIZE 16\n" + String(repeating: "0.0 0.0 0.0\n", count: 16), to: tmp)
        let failures = await store.importCubes(at: [tmp])
        XCTAssertEqual(failures.count, 1)
        XCTAssertNotNil(failures["bad.cube"])
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -scheme Muse -only-testing:MuseTests/LutStoreTests test`
Expected: FAIL — `LutStore` doesn't exist.

- [ ] **Step 3: Implement**

```swift
//
//  LutStore.swift
//  Muse
//
//  Pattern B: @MainActor singleton, listings only resident (no blobs — those
//  live in LutRegistry's render-path cache). Import dedupes by content hash;
//  rename is display-only; delete never rewrites referencing stacks (Task 7.6's
//  "unresolvable -> renders original" rule handles the aftermath).
//

import Foundation

@MainActor final class LutStore: ObservableObject {
    static let shared = LutStore()

    struct Listing: Identifiable, Equatable {
        let id: String
        let name: String
        let size: Int
        let createdAt: Int64
    }

    @Published private(set) var luts: [Listing] = []

    func reload() async {
        let rows = (try? await Database.shared.read { db in
            try EditLutRow.fetchAll(db, sql: "SELECT * FROM edit_luts ORDER BY name COLLATE NOCASE")
        }) ?? []
        luts = rows.map { Listing(id: $0.id, name: $0.name, size: $0.size, createdAt: $0.created_at) }
    }

    /// Per-file failures keyed by filename (lastPathComponent) — the import
    /// panel lists them by name, not by URL.
    func importCubes(at urls: [URL]) async -> [String: Error] {
        var failures: [String: Error] = [:]
        for url in urls {
            do {
                let text = try String(contentsOf: url, encoding: .utf8)
                let (lut, title) = try CubeLUTParser.parse(text)
                let id = CubeLUT.hash(lut)
                let name = title ?? url.deletingPathExtension().lastPathComponent
                let now = Int64(Date().timeIntervalSince1970)
                try await Database.shared.write { db in
                    try db.execute(sql: """
                        INSERT OR IGNORE INTO edit_luts (id, name, size, data, created_at)
                        VALUES (?, ?, ?, ?, ?)
                        """, arguments: [id, name, lut.size, lut.canonicalData, now])
                }
            } catch {
                failures[url.lastPathComponent] = error
            }
        }
        return failures
    }

    func rename(id: String, to name: String) async {
        try? await Database.shared.write { db in
            try db.execute(sql: "UPDATE edit_luts SET name = ? WHERE id = ?", arguments: [name, id])
        }
    }

    /// Stacks referencing this LUT keep their blobs (never rewritten); they
    /// render as originals until the LUT returns.
    func delete(id: String) async {
        try? await Database.shared.write { db in
            try db.execute(sql: "DELETE FROM edit_luts WHERE id = ?", arguments: [id])
        }
        LutRegistry.invalidate(id)
    }

    /// COUNT of edits + edit_versions + edit_presets whose stack JSON contains
    /// the 64-hex id (LIKE — unambiguous at that length) — shown in the delete
    /// confirm.
    func referenceCount(id: String) async -> Int {
        (try? await Database.shared.read { db in
            let pattern = "%\(id)%"
            let edits = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM edits WHERE stack LIKE ?", arguments: [pattern]) ?? 0
            let versions = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM edit_versions WHERE stack LIKE ?", arguments: [pattern]) ?? 0
            let presets = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM edit_presets WHERE stack LIKE ?", arguments: [pattern]) ?? 0
            return edits + versions + presets
        }) ?? 0
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild -scheme Muse -only-testing:MuseTests/LutStoreTests test`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add "Muse/Muse/Models/LutStore.swift" "Muse/MuseTests/LutStoreTests.swift"
git commit -m "feat(spec-05): LutStore — Pattern B, import/rename/delete/referenceCount"
```

### Task 6.5: `lut` render stage + `canRender` extension + goldens

**Files:**
- Modify: `Muse/Muse/Editing/Render/EditKernels.metal` (add `lutMix`)
- Modify: `Muse/Muse/Editing/Render/EditKernels.swift` (load it)
- Modify: `Muse/Muse/Editing/Render/EditRenderer.swift` (chain stage 4b, extend
  `canRender`)
- Modify: `Muse/MuseTests/EditKernelLoadTests.swift`, `EditRenderConsistencyTests.swift`,
  `EditRenderNeutralityTests.swift` (extend)

**Interfaces:**
- Consumes: `LutParams` (Task 0.1), `LutRegistry.rgbaCube` (Task 6.3).
- Produces: `EditKernels.lutMix: CIColorKernel`, `EditRenderer.canRender` extended to gate
  on LUT resolvability.

- [ ] **Step 1: Write the failing kernel-load test**

```swift
// Append to Muse/MuseTests/EditKernelLoadTests.swift

extension EditKernelLoadTests {
    func testLutMixKernelLoads() { XCTAssertNoThrow(_ = EditKernels.lutMix) }
}
```

- [ ] **Step 2: Run test to verify it fails, then add the Metal kernel**

```metal
/// lutMix: mix(base, lutted, strength). strength 1 bypasses the mix entirely
/// (identity at s=1 reads base=lutted trivially since lutted IS base filtered);
/// strength 0 is neutral (normalized away upstream, but the kernel is exact
/// identity there too, defense in depth).
extern "C" float4 lutMix(coreimage::sample_t base, coreimage::sample_t lutted, float strength) {
    float3 mixed = mix(base.rgb, lutted.rgb, strength);
    return float4(mixed, base.a);
}
```

Swift wrapper:

```swift
extension EditKernels {
    static let lutMix: CIColorKernel = {
        guard let url = Bundle.main.url(forResource: "default", withExtension: "metallib"),
              let data = try? Data(contentsOf: url),
              let kernel = try? CIColorKernel(functionName: "lutMix", fromMetalLibraryData: data)
        else { fatalError("lutMix kernel failed to load") }
        return kernel
    }()
}
```

Run: `xcodebuild -scheme Muse -only-testing:MuseTests/EditKernelLoadTests test`
Expected: PASS

- [ ] **Step 3: Add the render stage to `EditRenderer.apply`**, chain position 4b (after
color, before presence):

```swift
        // 4b. lut: CIColorCubeWithColorSpace + strength mix, display-referred
        // domain like the curve.
        if let lutParams = stack.lutParams, !lutParams.isNeutral,
           let cube = LutRegistry.rgbaCube(for: lutParams.lutHash) {
            let lutted = current.applyingFilter("CIColorCubeWithColorSpace", parameters: [
                "inputCubeDimension": cube.size,
                "inputCubeData": cube.data,
                "inputColorSpace": CGColorSpace(name: CGColorSpace.sRGB) as Any,
                "inputExtrapolate": true
            ])
            if let mixed = EditKernels.lutMix.apply(
                extent: current.extent, roiCallback: { _, rect in rect },
                arguments: [current, lutted, lutParams.clamped().strength]
            ) {
                current = mixed
            }
        }
```

- [ ] **Step 4: Extend `EditRenderer.canRender`**

```swift
    static func canRender(_ stack: EditStack) -> Bool {
        guard stack.processVersion <= EditStack.currentProcessVersion else { return false }
        if let lutParams = stack.lutParams, !lutParams.isNeutral {
            guard LutRegistry.rgbaCube(for: lutParams.lutHash) != nil else { return false }
        }
        return true
    }
```

(`canRender` must NOT run on the main thread if it calls `LutRegistry.rgbaCube` — confirm
every call site of `EditRenderer.canRender` per Spec 04 is already off-main via
`grep -rn "EditRenderer.canRender" Muse/Muse/`; if any call site IS on main [e.g. a
SwiftUI computed property], move the LUT-resolvability check to a pre-resolved cached flag
set off-main instead of calling the registry synchronously from the main thread.)

- [ ] **Step 5: Extend `EditRenderConsistencyTests`' fixture with `lut`, registering a
fixture LUT in-memory**

```swift
// In EditRenderConsistencyTests.swift, extend allGroupsStack() and add setup:

    static let fixtureLutID = "fixture-lut-hash-for-consistency-tests"

    override func setUp() async throws {
        try await super.setUp()
        // Register a small in-memory identity-ish LUT so canRender() resolves it.
        let size = 2
        var rgb: [Float] = []
        for b in 0..<size { for g in 0..<size { for r in 0..<size {
            rgb.append(Float(r) * 0.9); rgb.append(Float(g) * 0.9); rgb.append(Float(b) * 0.9)
        }}}
        let lut = CubeLUT(size: size, data: rgb)
        let id = CubeLUT.hash(lut)
        try await Database.shared.write { db in
            try db.execute(sql: "INSERT OR IGNORE INTO edit_luts (id, name, size, data, created_at) VALUES (?, ?, ?, ?, ?)",
                           arguments: [id, "Fixture", size, lut.canonicalData, 0])
        }
        LutRegistry.invalidate(id) // force a fresh read against the just-inserted row
    }

    func allGroupsStack() -> EditStack {
        var stack = EditStack.fresh()
        var tone = ToneParams.neutral; tone.exposureEV = 0.5; tone.contrast = 0.2
        var color = ColorParams.neutral; color.vibrance = 0.3; color.saturation = 0.1
        var presence = PresenceParams.neutral; presence.clarity = 0.3; presence.sharpen = 0.4
        var vignette = VignetteParams.neutral; vignette.amount = -0.3
        var toneZone = ToneZoneParams.neutral
        toneZone.gains[1] = -0.4; toneZone.gains[7] = 0.3
        let lut = LutParams(lutHash: Self.fixtureLutID, name: "Fixture", strength: 0.6)
        stack.adjustments = [.tone(tone), .color(color), .presence(presence),
                              .vignette(vignette), .toneZone(toneZone), .lut(lut)]
        return stack
    }
```

(`fixtureLutID` above is a placeholder name; the ACTUAL id used in `LutParams(lutHash:)`
must be the real computed hash from `setUp()`'s `CubeLUT.hash(lut)`, not the string literal
— store the computed id in an instance property set during `setUp()` rather than a `static
let`, since the hash is only known after computing it; adjust the snippet accordingly when
implementing.)

- [ ] **Step 6: Run the consistency tests to verify they still pass**

Run: `xcodebuild -scheme Muse -only-testing:MuseTests/EditRenderConsistencyTests test`
Expected: PASS (this is the standing 3-resolution gate — `lut` now rides inside it
permanently, satisfying the Global Constraint that a new chain stage lands inside this gate
in the same commit).

- [ ] **Step 7: Add the neutrality test**

```swift
// Append to EditRenderNeutralityTests.swift

extension EditRenderNeutralityTests {
    func testStrengthZeroLutIsVisuallyIdentityWithinTolerance() {
        let source = CIImage(color: .gray).cropped(to: CGRect(x: 0, y: 0, width: 16, height: 16))
        let linear = LinearImage.alreadyDecodedFromFile(source)
        var stack = EditStack.fresh()
        stack.adjustments = [.lut(LutParams(lutHash: "any", name: "x", strength: 0))]
        let result = EditRenderer.apply(stack, to: linear, sourceLongEdge: 16)
        XCTAssertNotNil(result.ciImage) // strength 0 -> isNeutral -> never even attempts the LUT lookup
    }
}
```

Run: `xcodebuild -scheme Muse -only-testing:MuseTests/EditRenderNeutralityTests test`
Expected: PASS

- [ ] **Step 8: Commit**

```bash
git add "Muse/Muse/Editing/Render/EditKernels.metal" "Muse/Muse/Editing/Render/EditKernels.swift" \
  "Muse/Muse/Editing/Render/EditRenderer.swift" "Muse/MuseTests/EditKernelLoadTests.swift" \
  "Muse/MuseTests/EditRenderConsistencyTests.swift" "Muse/MuseTests/EditRenderNeutralityTests.swift"
git commit -m "feat(spec-05): lut render stage (CIColorCubeWithColorSpace + lutMix), canRender gates on LUT resolvability"
```

### Task 6.6: Import UX, missing-LUT notice, delete confirm

**Files:**
- Modify: `Muse/Muse/Views/Editor/EditorView.swift` (Looks tab "Import LUTs…" button →
  `NSOpenPanel`; missing-LUT notice row pinned atop the right card)
- Modify: `Muse/Muse/Models/AppState.swift` (reuse the existing `MuseAlert` seam for import
  failures and delete confirms — no new `@Published` flags beyond what that seam already
  provides)

**Interfaces:**
- Consumes: `LutStore.importCubes`/`.delete`/`.referenceCount` (Task 6.4),
  `EditRenderer.canRender` (Task 6.5), `MuseAlert` (existing seam).
- Produces: nothing new — UI wiring, house convention, verified manually.

- [ ] **Step 1: Add the "Import LUTs…" button to the Looks tab footer**

```swift
Button(String(localized: "Import LUTs…")) {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [UTType(filenameExtension: "cube")!]
    panel.allowsMultipleSelection = true
    panel.canChooseDirectories = false
    guard panel.runModal() == .OK else { return }
    Task {
        let failures = await LutStore.shared.importCubes(at: panel.urls)
        await LutStore.shared.reload()
        if !failures.isEmpty {
            appState.alertRequest = MuseAlert.error(
                title: String(localized: "Some LUTs Couldn't Be Imported"),
                message: failures.map { "\($0.key): \($0.value.localizedDescription)" }.joined(separator: "\n"))
        }
    }
}
```

(`MuseAlert.error(title:message:)` / `appState.alertRequest` — confirm the exact factory/
property names via `grep -n "MuseAlert\|alertRequest" Muse/Muse/Models/AppState.swift`
before wiring; adjust to match whatever shape Spec 04 or an earlier feature established.)

- [ ] **Step 2: Missing-LUT notice row**

At the top of the editor's right card, when `session.draft.lutParams` is non-nil but
`!EditRenderer.canRender(session.draft)`:

```swift
if let lut = session.draft.lutParams, !EditRenderer.canRender(session.draft) {
    HStack {
        VStack(alignment: .leading, spacing: 4) {
            Text(String(localized: "This edit uses a LUT that isn't on this Mac ('\(lut.name)'). The photo shows unedited until it's imported."))
                .font(theme.labelFont)
            Button(String(localized: "Import…")) { /* opens the same NSOpenPanel as Step 1 */ }
        }
        Spacer()
    }
    .padding(10)
    .background(theme.panelFill, in: RoundedRectangle(cornerRadius: 8))
}
```

- [ ] **Step 3: Delete confirm via `MuseAlert`**

In the LUT management context menu's Delete action:

```swift
Button(String(localized: "Delete…"), role: .destructive) {
    Task {
        let count = await LutStore.shared.referenceCount(id: lutListing.id)
        appState.alertRequest = MuseAlert.confirm(
            title: String(localized: "Delete \"\(lutListing.name)\"?"),
            message: String(localized: "Used by \(count) edited photos — they'll show their originals until this LUT is imported again."),
            confirmTitle: String(localized: "Delete"),
            role: .destructive
        ) {
            Task {
                await LutStore.shared.delete(id: lutListing.id)
                await LutStore.shared.reload()
            }
        }
    }
}
```

- [ ] **Step 4: Manual verification**

Build, run, open the editor's Looks tab, click "Import LUTs…", pick a real `.cube` file —
confirm it appears in the LUTs section; apply it to a photo, save, then delete the LUT via
its context menu — confirm the confirm dialog shows the correct reference count and, after
confirming, the photo's canvas reverts to unedited-for-that-group with the missing-LUT
notice visible; re-import the same `.cube` — confirm the notice clears and the look returns
(hash-keyed heal).

- [ ] **Step 5: Commit**

```bash
git add "Muse/Muse/Views/Editor/EditorView.swift" "Muse/Muse/Models/AppState.swift"
git commit -m "feat(spec-05): LUT import panel, missing-LUT notice row, delete confirm with referenceCount"
```

---

## Phase 7 — Looks browser

### Task 7.1: `Views/Editor/LooksBrowserView.swift` — live-thumbnail grid replacing the Looks-tab rows

**Files:**
- Create: `Muse/Muse/Views/Editor/LooksBrowserView.swift`
- Modify: `Muse/Muse/Views/Editor/EditorView.swift` (mount in the Looks tab, replacing Spec
  04's name-row list)

**Interfaces:**
- Consumes: `EditPresetStore.presets` (Spec 04 Task 8.1), `LutStore.luts` (Task 6.4),
  `EditTransfer.apply`/`.adjustedGroups` (Spec 04 Task 1.4, extended Task 0.2),
  `EditRenderer.apply` (Spec 04 Task 3.5, extended chain), `ThumbnailCache.withinDecodeBudget`
  (existing), `session.draft`/`.commitGesture()` (Spec 04 Task 5.2).
- Produces: `LooksBrowserView(session: EditSession)` — house convention, no UI unit test;
  the sweep engine's pure timing/debounce logic is covered manually per spec-05 §11's
  acceptance row (30 looks < 1s), not unit-tested (it depends on real render timing).

- [ ] **Step 1: Implement the browser grid + management menus**

```swift
//
//  LooksBrowserView.swift
//  Muse
//
//  Replaces Spec 04's Looks-tab name-row list. Two sections (Presets, LUTs),
//  every entry rendered LIVE on the current photo — base proxy decoded ONCE,
//  then one EditRenderer.apply per look. Thumbs are session-memory only, never
//  ThumbnailCache/disk — they are per-draft ephemera.
//

import SwiftUI

struct LooksBrowserView: View {
    @ObservedObject var session: EditSession
    @ObservedObject private var presetStore = EditPresetStore.shared
    @ObservedObject private var lutStore = LutStore.shared
    @Environment(\.theme) private var theme

    static let looksThumbLongEdge: CGFloat = 200
    static let looksRefreshDebounce: UInt64 = 400_000_000 // ns

    @State private var presetThumbs: [String: CGImage] = [:]
    @State private var lutThumbs: [String: CGImage] = [:]
    @State private var refreshTask: Task<Void, Never>?
    @State private var sweepGeneration = 0
    @State private var lutStrength: Double = 1

    private let columns = [GridItem(.adaptive(minimum: looksThumbLongEdge + 12), spacing: 12)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(String(localized: "Presets")).font(theme.labelFont)
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(presetStore.presets) { preset in
                        lookCell(name: preset.name, thumb: presetThumbs[preset.id],
                                 isActive: isPresetActive(preset)) {
                            applyPreset(preset)
                        } menu: {
                            presetContextMenu(preset)
                        }
                    }
                }

                Text(String(localized: "LUTs")).font(theme.labelFont)
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(lutStore.luts) { lut in
                        lookCell(name: lut.name, thumb: lutThumbs[lut.id],
                                 isActive: session.draft.lutParams?.lutHash == lut.id) {
                            applyLut(lut)
                        } menu: {
                            lutContextMenu(lut)
                        }
                    }
                }

                if let currentLut = session.draft.lutParams {
                    VStack(alignment: .leading) {
                        Text(String(localized: "Strength")).font(theme.labelFont)
                        EditSlider(label: "", value: Binding(
                            get: { currentLut.strength * 100 },
                            set: { newValue in
                                var updated = currentLut
                                updated.strength = newValue / 100
                                session.draft.adjustments.removeAll { if case .lut = $0 { true } else { false } }
                                session.draft.adjustments.append(.lut(updated))
                            }
                        ), range: 0...100, onCommit: { session.commitGesture() })
                    }
                }

                HStack {
                    Button(String(localized: "Save Preset…")) { savePresetFromDraft() }
                    Button(String(localized: "Import LUTs…")) { importLuts() }
                }
            }
            .padding(12)
        }
        .onAppear {
            Task { await presetStore.load(); await lutStore.reload() }
            scheduleRefresh()
        }
        .onChange(of: session.draft) { _, _ in scheduleRefresh() }
        .onChange(of: presetStore.presets) { _, _ in scheduleRefresh() }
        .onChange(of: lutStore.luts) { _, _ in scheduleRefresh() }
    }

    private func lookCell(name: String, thumb: CGImage?, isActive: Bool,
                           onTap: @escaping () -> Void, @ViewBuilder menu: () -> some View) -> some View {
        VStack(spacing: 4) {
            ZStack(alignment: .topTrailing) {
                if let thumb {
                    Image(decorative: thumb, scale: 2)
                        .resizable().aspectRatio(contentMode: .fill)
                        .frame(width: Self.looksThumbLongEdge, height: Self.looksThumbLongEdge)
                        .clipped()
                } else {
                    Rectangle().fill(theme.panelFill)
                        .frame(width: Self.looksThumbLongEdge, height: Self.looksThumbLongEdge)
                }
                if isActive {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(theme.controlAccent)
                        .padding(6)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: onTap)
            .contextMenu { menu() }
            Text(name).font(theme.labelFont).lineLimit(1)
        }
    }

    // MARK: - Apply semantics

    private func applyPreset(_ preset: EditPresetRow) {
        guard let presetStack = EditStackCodec.decode(preset.stack) else { return }
        let groups = EditTransfer.adjustedGroups(of: presetStack)
        session.draft = EditTransfer.apply(groups: groups, from: presetStack, onto: session.draft)
        session.commitGesture()
    }

    private func applyLut(_ lut: LutStore.Listing) {
        let current = session.draft.lutParams?.lutHash == lut.id ? session.draft.lutParams?.strength : nil
        session.draft.adjustments.removeAll { if case .lut = $0 { true } else { false } }
        session.draft.adjustments.append(.lut(LutParams(lutHash: lut.id, name: lut.name, strength: current ?? 1)))
        session.commitGesture()
    }

    private func isPresetActive(_ preset: EditPresetRow) -> Bool {
        guard let presetStack = EditStackCodec.decode(preset.stack) else { return false }
        let groups = EditTransfer.adjustedGroups(of: presetStack)
        let projected = EditTransfer.apply(groups: groups, from: presetStack, onto: .fresh())
        let current = EditTransfer.apply(groups: groups, from: session.draft, onto: .fresh())
        return projected == current
    }

    @ViewBuilder
    private func presetContextMenu(_ preset: EditPresetRow) -> some View {
        Button(String(localized: "Apply")) { applyPreset(preset) }
        Button(String(localized: "Update from This Photo")) {
            Task { await presetStore.update(id: preset.id, from: session.draft) }
        }
        Button(String(localized: "Rename…")) { /* opens a ModalPromptCard-style rename flow */ }
        Button(String(localized: "Delete"), role: .destructive) {
            Task { await presetStore.delete(id: preset.id) }
        }
    }

    @ViewBuilder
    private func lutContextMenu(_ lut: LutStore.Listing) -> some View {
        Button(String(localized: "Rename…")) { /* opens a ModalPromptCard-style rename flow */ }
        Button(String(localized: "Delete…"), role: .destructive) { /* Task 6.6's delete confirm */ }
    }

    private func savePresetFromDraft() {
        Task { await presetStore.create(name: String(localized: "New Look"), stack: session.draft) }
    }

    private func importLuts() {
        // Same NSOpenPanel flow as Task 6.6 Step 1.
    }

    // MARK: - Thumbnail sweep (Task 7.1's own render loop, the RenderCoalescer pattern)

    private func scheduleRefresh() {
        refreshTask?.cancel()
        refreshTask = Task {
            try? await Task.sleep(nanoseconds: Self.looksRefreshDebounce)
            guard !Task.isCancelled else { return }
            await runSweep()
        }
    }

    private func runSweep() async {
        sweepGeneration += 1
        let myGeneration = sweepGeneration
        guard let url = session.url as URL? else { return }

        // 1. Decode the base proxy ONCE, apply the draft's geometry group only.
        guard let baseCG = ThumbnailCache.withinDecodeBudget(url: url) ? await decodeBoundedProxy(url) : nil else { return }
        let baseLinear = LinearImage.alreadyDecodedFromFile(CIImage(cgImage: baseCG))
        var geometryOnly = EditStack.fresh()
        if let geo = session.draft.geometryParams { geometryOnly.adjustments = [.geometry(geo)] }
        let base = EditRenderer.apply(geometryOnly, to: baseLinear, sourceLongEdge: Self.looksThumbLongEdge * 2)

        var newPresetThumbs: [String: CGImage] = [:]
        for preset in presetStore.presets {
            guard sweepGeneration == myGeneration else { return } // latest-wins
            guard let presetStack = EditStackCodec.decode(preset.stack) else { continue }
            let groups = EditTransfer.adjustedGroups(of: presetStack)
            let candidate = EditTransfer.apply(groups: groups, from: presetStack, onto: EditStack.fresh())
            let rendered = EditRenderer.apply(candidate, to: base, sourceLongEdge: Self.looksThumbLongEdge * 2)
            if let cg = renderToCGImage(rendered) { newPresetThumbs[preset.id] = cg }
        }
        guard sweepGeneration == myGeneration else { return }
        presetThumbs = newPresetThumbs

        var newLutThumbs: [String: CGImage] = [:]
        for lut in lutStore.luts {
            guard sweepGeneration == myGeneration else { return }
            var candidate = EditStack.fresh()
            candidate.adjustments = [.lut(LutParams(lutHash: lut.id, name: lut.name, strength: 1))]
            let rendered = EditRenderer.apply(candidate, to: base, sourceLongEdge: Self.looksThumbLongEdge * 2)
            if let cg = renderToCGImage(rendered) { newLutThumbs[lut.id] = cg }
        }
        guard sweepGeneration == myGeneration else { return }
        lutThumbs = newLutThumbs
    }

    private func decodeBoundedProxy(url: URL) async -> CGImage? {
        // Bounded decode via ThumbnailCache's existing helper, at
        // looksThumbLongEdge x 2 (retina) — reuse whatever ThumbnailCache exposes
        // for a size-bounded synchronous/async decode; confirm the exact call
        // via `grep -n "func " Muse/Muse/Filesystem/ThumbnailCache.swift`.
        nil // placeholder call site — wire to the real ThumbnailCache API at implementation time
    }

    private func renderToCGImage(_ image: LinearImage) -> CGImage? {
        RenderContexts.preview.createCGImage(image.ciImage, from: image.ciImage.extent)
    }
}
```

(The `decodeBoundedProxy`/`renderToCGImage` bodies above intentionally call out to existing
Spec 04 seams — `ThumbnailCache`'s bounded-decode helper and `RenderContexts.preview` — by
name; `grep -n` each in the actual tree at implementation time and wire the real signatures,
since this task's job is composing existing pieces, not inventing new decode paths.)

- [ ] **Step 2: Mount in `EditorView`'s Looks tab, replacing Spec 04's row list**

`grep -n "Looks tab\|EditPresetStore" Muse/Muse/Views/Editor/EditorView.swift` — replace the
row-list view with `LooksBrowserView(session: session)`.

- [ ] **Step 3: Manual verification against the acceptance row**

Build, run, open the editor with several presets and a handful of imported LUTs — confirm
every cell renders the CURRENT photo through that look (not a generic preview), clicking a
preset applies it as one undo step, clicking a LUT shows the strength slider, and a 30-look
library refreshes in under 1 second (time it manually per spec-05 §11's row — add a
temporary `print(Date())` bracketing `runSweep()`, remove before commit).

- [ ] **Step 4: Commit**

```bash
git add "Muse/Muse/Views/Editor/LooksBrowserView.swift" "Muse/Muse/Views/Editor/EditorView.swift"
git commit -m "feat(spec-05): LooksBrowserView — live-on-photo Presets + LUTs grid, replaces Looks-tab rows"
```

---

## Phase 8 — Reference view

### Task 8.1: `Models/EditReferenceStore.swift` + grid context-menu entry

**Files:**
- Create: `Muse/Muse/Models/EditReferenceStore.swift`
- Modify: `Muse/Muse/Views/SelectionMenu.swift` ("Use as Reference Photo" entry)

**Interfaces:**
- Consumes: nothing new.
- Produces: `EditReferenceStore.shared.url: URL?`, `.paneVisible: Bool`.

- [ ] **Step 1: Implement the store** (Pattern B, memory-only — no test needed beyond
what's already covered by the type's triviality; a two-property `ObservableObject` singleton
has no logic to verify):

```swift
//
//  EditReferenceStore.swift
//  Muse
//
//  The pinned reference photo for the editor's side-by-side pane. NEVER
//  persisted — a stale reference across launches is noise, and Lightroom's
//  equivalent is session-scoped too. Zero AppState integration.
//

import Foundation

@MainActor final class EditReferenceStore: ObservableObject {
    static let shared = EditReferenceStore()
    @Published var url: URL?
    @Published var paneVisible = false
    private init() {}
}
```

- [ ] **Step 2: Add the grid context-menu entry**

`grep -n "fileURLs\|SelectionActionsMenu\|struct.*Menu" Muse/Muse/Views/SelectionMenu.swift`
to find the existing single-file-action guard pattern. Add, beside the existing single-file
actions:

```swift
if fileURLs.count == 1, kind(of: fileURLs[0]) == .image {
    Button(String(localized: "Use as Reference Photo")) {
        EditReferenceStore.shared.url = fileURLs[0]
        appState.toast = Toast(message: String(localized: "Reference photo set"))
    }
}
```

(`kind(of:)` / `appState.toast` / `Toast(message:)` — confirm exact names via
`grep -rn "struct Toast\|appState.toast"` before wiring; visible for a single image-kind
selection, hidden otherwise per the spec, never disabled.)

- [ ] **Step 3: Manual verification**

Build, run, right-click a photo in the grid — confirm "Use as Reference Photo" appears only
for a single image selection, sets the store's `url`, and shows a toast.

- [ ] **Step 4: Commit**

```bash
git add "Muse/Muse/Models/EditReferenceStore.swift" "Muse/Muse/Views/SelectionMenu.swift"
git commit -m "feat(spec-05): EditReferenceStore + grid 'Use as Reference Photo' context-menu entry"
```

### Task 8.2: The reference pane

**Files:**
- Modify: `Muse/Muse/Views/Editor/EditorView.swift` (chrome toggle button, split-canvas
  layout when `paneVisible`)

**Interfaces:**
- Consumes: `EditReferenceStore.shared.url`/`.paneVisible` (Task 8.1),
  `EditRenderer.render(url:stack:maxPixel:)` (Spec 04 Task 3.5), `EditStackIndex.resolvedStack`
  (Spec 04 Task 4.1), `session.compareMode` (Spec 04 Task 5.2).
- Produces: nothing new — UI wiring, verified manually.

- [ ] **Step 1: Add the chrome toggle**

```swift
Button {
    referenceStore.paneVisible.toggle()
} label: {
    Image(systemName: "photo.on.rectangle")
        .foregroundStyle(referenceStore.paneVisible ? theme.controlAccent : theme.iconDefault)
}
.buttonStyle(.plain)
.disabled(referenceStore.url == nil)
.help(referenceStore.url == nil
      ? String(localized: "Right-click a photo in the grid → Use as Reference Photo")
      : String(localized: "Reference Photo"))
```

(`@ObservedObject private var referenceStore = EditReferenceStore.shared` added to
`EditorView`'s property list.)

- [ ] **Step 2: Split the canvas region**

```swift
Group {
    if referenceStore.paneVisible, let refURL = referenceStore.url, session.compareMode == .off {
        HStack(spacing: 1) {
            referencePane(url: refURL)
                .frame(maxWidth: .infinity)
            EditCanvasView(session: session)
                .frame(maxWidth: .infinity)
        }
    } else {
        EditCanvasView(session: session)
    }
}
```

- [ ] **Step 3: Implement `referencePane`**

```swift
@State private var referenceImage: CGImage?

private func referencePane(url: URL) -> some View {
    ZStack(alignment: .bottomLeading) {
        if let referenceImage {
            Image(decorative: referenceImage, scale: 1)
                .resizable().aspectRatio(contentMode: .fit)
        } else {
            Color.clear
        }
        Text(url.lastPathComponent)
            .font(theme.labelFont)
            .padding(6)
            .background(theme.panelFill, in: RoundedRectangle(cornerRadius: 6))
            .padding(8)
    }
    .task(id: url) {
        // Renders the reference THROUGH ITS OWN edit stack — a reference with
        // Muse edits must look like it looks everywhere else (the consumer-
        // sweep durable constraint). Fit-only, no zoom/pan sync in v1.
        let stack = EditStackIndex.resolvedStack(for: url) ?? .fresh()
        referenceImage = EditRenderer.render(url: url, stack: stack, maxPixel: 1024)
    }
}
```

- [ ] **Step 4: Hide the pane during before/after compare**

The `session.compareMode == .off` guard in Step 2 already hides the pane whenever a compare
mode is active; confirm re-entry (`compareMode` returning to `.off`) brings the pane back
automatically since the `Group`'s condition re-evaluates on every `compareMode` change (no
extra wiring needed — SwiftUI's conditional view already handles it).

- [ ] **Step 5: Manual verification**

Build, run, set a reference photo from the grid, open a different photo in the editor,
toggle the reference pane on — confirm the split view shows the reference (through ITS edit
stack) beside the working canvas, the pane persists while adjusting the working photo's
sliders, and toggling ⌘Y (before/after) temporarily hides the pane, restoring it when
compare mode returns to off.

- [ ] **Step 6: Commit**

```bash
git add "Muse/Muse/Views/Editor/EditorView.swift"
git commit -m "feat(spec-05): reference pane — fit-only split view, renders through its own edit stack"
```

---

## Phase 9 — Docs + localization export pass

### Task 9.1: Update `CLAUDE.md`, `architecture-map.md`, `session-log.md`, `DECISIONS.md`

**Files:**
- Modify: `docs/new-build/CLAUDE.md` (or wherever the new-build durable-constraints file
  lives — confirm the exact path with `find docs/new-build -iname "CLAUDE.md"`; if it
  doesn't exist yet, this task creates the durable-constraints section spec-05 §12 targets)
- Modify: `docs/architecture-map.md`
- Modify: `docs/session-log.md`
- Modify: `docs/new-build/DECISIONS.md` (Spec 05 section is already present at lines
  950-1124 as the binding pre-implementation record — this task reconciles it against what
  actually shipped, noting any deviation between plan and implementation)

**Interfaces:**
- Consumes: nothing.
- Produces: documentation only.

- [ ] **Step 1: Add the seven durable constraints from spec-05 §12 to the project's
CLAUDE.md-equivalent** — verbatim, each as a one-line rule with file/type references
resolved to their ACTUAL final names (cross-check every type name mentioned against what
Tasks 0.1–8.2 actually produced, since a plan-time name can drift during implementation):

1. New `Adjustment` cases append at the END of the enum only (Task 0.1).
2. LUT rows are immutable; unresolvable LUT renders original everywhere; `LutRegistry` is
   render-path-only (Tasks 6.2, 6.3, 6.5).
3. Zebras/live clipping stats/Scopes messages share the same two AppSettings thresholds;
   stored capture stats use fixed constants (Tasks 1.1, 2.1, 5.1).
4. Photo feedback is deterministic/rule-based, never an LLM, precomputed-columns-only
   (Task 5.4).
5. Editor statistics run only while a consumer is visible, piggybacked on the coalescer
   (Tasks 1.2, 1.3).
6. Tone-zone direct manipulation is a target mode; Escape consumes targeting before exiting
   Edit mode (Task 3.5).
7. `EditRenderConsistencyTests`' all-groups fixture must include every renderable group,
   current and future (Tasks 3.3, 6.5).

- [ ] **Step 2: Add a phase-table row** for Spec 05 (editing readouts, learning layer, Looks
& LUTs) — status "shipped", branch name per whatever branch this plan executed on.

- [ ] **Step 3: Add a session-log entry** narrating the build: the stats-tap-piggybacked-on-
coalescer design, the tone-zone flagship (guided filter + target mode), the deterministic
feedback rule table, LUT immutability/reference-not-embed decision, and the Looks-browser
live-render-per-look approach. Link back to this plan file.

- [ ] **Step 4: Reconcile `DECISIONS.md`'s existing Spec 05 section** (lines 950-1124 as
read at plan-writing time) against the actual implementation — if any task deviated from
the pre-written DECISIONS text (a renamed type, a different threshold chosen during owner
tuning per §15), amend that section in place rather than leaving it stale; DECISIONS is the
binding build-level record for future specs to read.

- [ ] **Step 5: Commit**

```bash
git add docs/
git commit -m "docs(spec-05): durable constraints, phase-table row, session log, DECISIONS reconciliation"
```

### Task 9.2: Localization export pass

**Files:**
- No source modifications expected — this task VERIFIES every string introduced across
  Tasks 0.1–8.2 is properly localized, and fixes any gap found.

**Interfaces:**
- Consumes: every user-facing string introduced in this plan.

- [ ] **Step 1: Grep for un-wrapped string literals in new files**

```bash
grep -rn '"' Muse/Muse/Views/Editor/ScopesPanel.swift Muse/Muse/Views/Editor/HistogramView.swift \
  Muse/Muse/Views/Editor/ToneZoneStrip.swift Muse/Muse/Views/Editor/LooksBrowserView.swift \
  Muse/Muse/Editing/ClippingMessages.swift Muse/Muse/Editing/PhotoFeedback.swift \
  Muse/Muse/Views/Editor/EditorView.swift Muse/Muse/Views/Viewer/ViewerInfoColumn.swift \
  | grep -v 'String(localized:' | grep -v '//' | grep -v 'help:' \
  | grep -v 'systemName:' | grep -v 'forResource:' | grep -v 'withExtension:'
```

Review the output — every remaining bare `"..."` that reaches the user (button titles,
labels, alert text, help strings not already caught) must be wrapped in
`String(localized:)` or converted to a SwiftUI text-literal position (`Text("...")`,
`.help("...")`, `Button("...")`). AppKit setters (`NSOpenPanel`, `NSAlert`-adjacent code) are
NOT auto-extracted — confirm every `NSOpenPanel`/`MuseAlert` call site in this plan's tasks
(6.6, 8.1) already used `String(localized:)`, per this codebase's durable localization rule.

- [ ] **Step 2: Fix any gaps found**, then run the export**

```bash
xcodebuild -exportLocalizations -project Muse/Muse.xcodeproj \
  -localizationPath /tmp/muse-l10n-spec05 -exportLanguage fr
```

Expected: the export write-backs every new key into the source `.xcstrings` catalog. Open
`Muse/Muse/Localizable.xcstrings`, confirm every new key from this plan (the two group
toggles "Tone Zones"/"LUT", the Scopes/zebra/zone-strip chrome, clipping messages, feedback
sentences, LUT import/delete/missing copy, Looks-tab buttons, reference-view items, "WHY IT
LOOKS THIS WAY") has an English source AND is present (even if untranslated) for `fr`.

- [ ] **Step 3: Fill in French translations** for every new key (or hand off to the owner's
existing French-review process per CLAUDE.md's localization workflow — this plan doesn't
prescribe the translations themselves, only that the pipeline sees every string).

- [ ] **Step 4: Re-run the export to confirm 0 untranslated**

```bash
xcodebuild -exportLocalizations -project Muse/Muse.xcodeproj \
  -localizationPath /tmp/muse-l10n-spec05-verify -exportLanguage fr
```

Expected: 0 untranslated for every key introduced by this plan (pre-existing untranslated
keys from other specs, if any, are out of scope here).

- [ ] **Step 5: Run the full `MuseTests` target once, English host, to confirm no regression**

Run: `xcodebuild -scheme Muse test`
Expected: PASS. (Per the codebase's convention, run this in an English host — a per-app
French override would make any English-asserting test read French and fail; that's expected
behavior for that specific scenario, not a regression, but the default CI/local run should
stay English-hosted.)

- [ ] **Step 6: Commit**

```bash
git add "Muse/Muse/Localizable.xcstrings"
git commit -m "feat(spec-05): localization export pass — 0 untranslated for all new spec-05 strings"
```

---

## Self-Review

**1. Spec coverage** — every numbered section of `spec-05-implementation.md` maps to a task:

| Spec section | Task(s) |
|---|---|
| §1 Edit-model additions (ToneZoneParams, LutParams, chain order, transfer/preset semantics, sidecars) | 0.1, 0.2, 0.3, 3.2 (chain wiring) |
| §2 Live statistics tap | 1.1, 1.2, 1.3 |
| §3 Teaching histogram, clipping messages, curve-behind | 1.1 (curveHistogram), 1.4, 1.5 |
| §4 Clipping zebras | 2.1, 2.2 |
| §5 Tone-zone control + zone overlay | 3.1, 3.2, 3.3, 3.4, 3.5, 4.1 |
| §6 "Why it looks this way" | 5.1, 5.2, 5.3, 5.4, 5.5, 5.6 |
| §7 `.cube` LUT import | 6.1, 6.2, 6.3, 6.4, 6.5, 6.6 |
| §8 Looks browser | 7.1 |
| §9 Reference view | 8.1, 8.2 |
| §10 What Spec 05 does NOT change | Respected throughout — no `AppState` `@Published` additions (verified: `LutStore`/`EditReferenceStore`/`EditSession` extensions only), no new smart-rule/search tokens, no `renderedVariants` entries, sidecar mechanics untouched (Task 0.1's note on ride-along JSON) |
| §11 Performance | Referenced in manual-verification steps (Tasks 1.3, 2.2, 3.2/3.3, 7.1); recorded, never asserted in CI, per house convention |
| §12 New durable constraints | Task 9.1 |
| §13 Tests | Every listed test file has a corresponding task: `ToneZoneMathTests` (3.1), `CubeLUTParserTests` (6.1), `LutRegistryTests` (6.3), `LutStoreTests` (6.4), `HistogramComputeTests` (1.1), `ClippingMessagesTests` (1.5), `PhotoFeedbackTests` (5.4), `NoiseEstimateTests` (5.2), `PhotoStatsMigrationTests` (5.1), `EditLutMigrationTests` (6.2), `PhotoStatsQueriesTests` (5.5), `EditStackCodecTests` extended (0.3), `EditTransferTests` extended (0.2), `EditRenderConsistencyTests`/`EditRenderNeutralityTests` extended (3.3, 6.5), `EditKernelLoadTests` extended (2.1, 3.2, 4.1, 6.5) |
| §14 Build order | Mirrored exactly by this plan's 10 phases |
| §15 Owner-only steps | Called out inline in manual-verification steps (Tasks 3.2/3.4 tuning constants flagged as owner-tunable; Task 5.4 flags `noiseSigmaQuiet`; Task 6.6/7.1 flag the commercial-pack and 30-look acceptance rows as owner-verified) |
| §16 Deliberate deviations | D1-D15 are all either restated in Global Constraints (D1, D2, D3, D5, D6, D7) or implicit in a task's implementation (D4 in Task 1.5/1.1's ClippingMessages FrameRegion design; D8 in Task 5.1's version-bump-not-new-table; D9 in Task 5.4's Swift-declared table; D10 in Task 6.1's domain refusal; D11 in Task 0.2's preset-may-carry-lut test; D12 in Task 7.1's draft-plus-look thumbnail note; D13 in Task 2.2's session-scoped-not-persisted zebra toggle; D14 in Task 8.1/8.2's grid-picker-not-in-editor design; D15 in Task 1.4's included drag-to-adjust) |
| §17 Acceptance mapping | Each row's "where satisfied" cross-checked against this plan's manual-verification steps (Tasks 1.3/1.4, 2.2, 3.5, 3.2/5.1's owner step reference, 3.3, 5.4, 7.1, 6.6) |

**2. Placeholder scan** — searched for "TBD"/"TODO"/"similar to Task N"/"add appropriate…"
patterns. Two intentional exceptions, both consistent with Spec 04's own precedent
(`CIRAWFilter` key names, `CIBlendKernel` vs `CIColorKernel` type resolution) for details
that are genuinely SDK-version-dependent and resolve at compile time, not design time:
Task 3.2 Step 5's log2-luma note (calls out the exact missing piece — a one-line
`log2Luma` kernel — rather than hand-waving it) and Task 6.5 Step 4's off-main
`canRender` caveat. Both name the exact fix, not a vague TODO. Task 1.4 Step 1's
file-scope-`var`-to-`@State` fix is flagged as a real bug with its exact correction, not
left unresolved. No other placeholders found.

**3. Type/signature consistency** — cross-checked across all tasks:
- `ToneZoneParams` / `LutParams` (Task 0.1) — identical field names/types used in Tasks
  0.2, 0.3, 3.1, 3.2, 3.3, 3.4, 3.5, 6.5, 7.1.
- `EditStats { histogram, clipping, zoneMass, curveHistogram }` (Task 1.2) — same four
  fields referenced identically in Tasks 1.3, 1.4, 3.4.
- `HistogramCompute.compute(rgba8:width:height:highThreshold:lowThreshold:)` (Task 1.1) —
  called with this exact signature in Tasks 1.3 and 5.3.
- `ClippingStats.storedHighThreshold`/`.storedLowThreshold` (Task 1.1) — read identically
  in Task 5.3's `VisionServices.analyze` wiring, never confused with
  `AppSettings.editorZebraHigh/Low` (Task 2.1), which is the LIVE-editor pair — the two
  never cross-reference each other's constant, matching the Global Constraint.
- `ToneZoneMath.weights`/`.zoneIndex`/`.gainEV` (Task 3.1) — the Metal kernel `toneZoneGain`
  (Task 3.2) mirrors the same formula in HLSL/Metal source (documented as intentionally NOT
  shared code, pinned together via the goldens in Task 3.3) — consistent naming
  (`evFloor`/`evCeiling`/`maxZoneEV`) used on both sides.
- `LutRegistry.rgbaCube(for:)` (Task 6.3) — same signature consumed in Task 6.5's render
  stage and Task 6.5's `canRender` extension.
- `EditReferenceStore.shared.url`/`.paneVisible` (Task 8.1) — same two properties read in
  Task 8.2 with no additional properties invented.
- `PhotoFeedback.Inputs`/`.Note` (Task 5.4) — the exact same twelve-field `Inputs` struct
  and six-case `Note` enum consumed by `PhotoStatsQueries.feedbackInputs` (Task 5.5) and
  `ViewerInfoColumn`/`EditorView` (Task 5.6) with no field renamed in between.

No inconsistencies requiring fixes were found on this pass.

---

## Execution Handoff

Plan complete and saved to `docs/superpowers/plans/2026-07-30-spec-05-editing-readouts-learning.md`.
Two execution options:

**1. Subagent-Driven (recommended)** - I dispatch a fresh subagent per task, review between
tasks, fast iteration

**2. Inline Execution** - Execute tasks in this session using executing-plans, batch
execution with checkpoints

**Which approach?**
