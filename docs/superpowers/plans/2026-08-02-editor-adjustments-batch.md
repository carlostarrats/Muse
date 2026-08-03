# Editor Adjustments Batch Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Expose two adjustment groups that are already plumbed end-to-end but unreachable (geometry, vignette), add auto-tone, and append three new adjustments (HSL, split toning, grain) — all assembled from existing components.

**Architecture:** Three stages. Stage A adds UI over finished model+renderer code and one new pure-math statistics file — no schema, no enum change. Stage B appends three `Adjustment` cases at indices 8/9/10 with one Metal kernel each. Stage C adds the crop card and ports Surface Camera's crop overlay. Stage C is severable.

**Tech Stack:** Swift 6 / SwiftUI / Core Image / Metal stitchable kernels / GRDB / XCTest.

**Spec:** `docs/superpowers/specs/2026-08-02-editor-adjustments-batch-design.md`

## Global Constraints

- **C1 — Reuse, don't invent.** Every control in Stages A and B is an existing component (spec §3). The ONLY new interactive control authorized is the crop drag overlay (Task 11).
- **C2 — `Adjustment` cases APPEND.** `canonicalIndex` 0–7 exist. New: **8 `hsl`, 9 `splitTone`, 10 `grain`**. Never insert mid-list.
- **C3 — No migration, no version bump.** `schemaVersion` stays 1, `processVersion` stays 1.
- **C4 — Scale rule.** Every radius is `fraction × sourceLongEdge`. Never a pixel constant.
- **C5 — Originals are never written.** Edits are parameters only.
- **C6 — Localize every user-facing string.** Literals in SwiftUI text positions auto-extract; anything passed as a `String` must be hand-wrapped in `String(localized:)`.
- **C7 — Canvas geometry is POINTS.** `EditorCanvasGeometry` owns it. No point→pixel conversion in the renderer.
- **C8 — Release build stays warning-free.**
- **Test command:** `xcodebuild -project Muse/Muse.xcodeproj -scheme Muse test -only-testing:MuseTests/<TestClass> 2>&1 | tail -20`
- **Before every commit:** `./scripts/audit-invariants.sh`

---

# STAGE A — finish what's built

---

### Task 1: `AutoToneStats` — the pure statistics

**Files:**
- Create: `Muse/Muse/Editing/AutoToneStats.swift`
- Test: `Muse/MuseTests/AutoToneStatsTests.swift`
- Modify: `Muse/Muse.xcodeproj/project.pbxproj` (add both files to targets)

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `AutoToneStats.Result` with `exposureEV: Double`, `contrast: Double`, `blacks: Double`, `whites: Double`, `temperature: Double`, `tint: Double`
  - `AutoToneStats.compute(rgba8:width:height:) -> Result`

**Why its own file:** `EditSession.stats` is tapped from the *rendered* image and gated on `statsVisible`, so it measures the draft, not the original, and is absent with the Histogram card closed. Reusing it would make Auto compound on a second press. This computes from the ORIGINAL and uses 256 bins (a 0.1% percentile can't be read off the shipped 64).

- [ ] **Step 1: Write the failing test**

```swift
//  AutoToneStatsTests.swift
import XCTest
@testable import Muse

final class AutoToneStatsTests: XCTestCase {

    /// A flat mid-grey frame is already correctly exposed and neutral —
    /// every output must be 0, or Auto would "fix" a correct photo.
    func testNeutralGreyProducesNoChange() {
        let px = Self.solid(r: 128, g: 128, b: 128, count: 64 * 64)
        let r = AutoToneStats.compute(rgba8: px, width: 64, height: 64)
        XCTAssertEqual(r.exposureEV, 0, accuracy: 0.15)
        XCTAssertEqual(r.temperature, 0, accuracy: 0.02)
        XCTAssertEqual(r.tint, 0, accuracy: 0.02)
    }

    /// A dark frame must be pushed UP, never down.
    func testDarkFrameRaisesExposure() {
        let px = Self.solid(r: 40, g: 40, b: 40, count: 64 * 64)
        let r = AutoToneStats.compute(rgba8: px, width: 64, height: 64)
        XCTAssertGreaterThan(r.exposureEV, 0.5)
    }

    /// A blown frame must be pulled DOWN.
    func testBrightFrameLowersExposure() {
        let px = Self.solid(r: 225, g: 225, b: 225, count: 64 * 64)
        let r = AutoToneStats.compute(rgba8: px, width: 64, height: 64)
        XCTAssertLessThan(r.exposureEV, -0.5)
    }

    /// A warm cast (red high, blue low) must be corrected COOLER, i.e.
    /// negative temperature. Getting this sign backwards doubles the cast.
    func testWarmCastIsCorrectedCooler() {
        let px = Self.solid(r: 200, g: 150, b: 100, count: 64 * 64)
        let r = AutoToneStats.compute(rgba8: px, width: 64, height: 64)
        XCTAssertLessThan(r.temperature, -0.05)
    }

    /// A low-contrast frame (everything crammed mid-range) must widen the
    /// black and white points.
    func testLowContrastOpensBlackAndWhitePoints() {
        var px: [UInt8] = []
        for i in 0..<(64 * 64) {
            let v = UInt8(110 + (i % 30))          // ~110…139, a narrow band
            px += [v, v, v, 255]
        }
        let r = AutoToneStats.compute(rgba8: px, width: 64, height: 64)
        XCTAssertGreaterThan(r.whites, 0.05)
        XCTAssertLessThan(r.blacks, -0.05)
    }

    /// Idempotence at the STATS level: identical input, identical output.
    /// The session-level guarantee (§4.2) rests on this.
    func testDeterministic() {
        let px = Self.solid(r: 90, g: 120, b: 160, count: 32 * 32)
        let a = AutoToneStats.compute(rgba8: px, width: 32, height: 32)
        let b = AutoToneStats.compute(rgba8: px, width: 32, height: 32)
        XCTAssertEqual(a.exposureEV, b.exposureEV)
        XCTAssertEqual(a.temperature, b.temperature)
    }

    /// Degenerate input must not crash or produce NaN.
    func testEmptyInputIsNeutral() {
        let r = AutoToneStats.compute(rgba8: [], width: 0, height: 0)
        XCTAssertEqual(r.exposureEV, 0)
        XCTAssertFalse(r.temperature.isNaN)
    }

    private static func solid(r: UInt8, g: UInt8, b: UInt8, count: Int) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(count * 4)
        for _ in 0..<count { out += [r, g, b, 255] }
        return out
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `xcodebuild -project Muse/Muse.xcodeproj -scheme Muse test -only-testing:MuseTests/AutoToneStatsTests 2>&1 | tail -20`
Expected: compile failure — `cannot find 'AutoToneStats' in scope`.

- [ ] **Step 3: Write the implementation**

```swift
//
//  AutoToneStats.swift
//  Muse
//
//  Auto-tone's statistics. Deliberately NOT `EditSession.stats`: that one is
//  tapped from the RENDERED image and gated on `statsVisible`, so it describes
//  the current draft rather than the original. Auto must measure the ORIGINAL
//  every time or a second press compounds its own output — see the spec's
//  idempotence requirement.
//
//  Pure arithmetic over an RGBA8 buffer, unit-tested on synthetic frames, in
//  the same spirit as `HistogramCompute` (which this deliberately does not
//  reuse: 64 bins are ~4% wide and a 0.1% percentile cannot be read off them).
//
//  Platform-neutral by the `Editing/` rule: Foundation only.
//

import Foundation

nonisolated enum AutoToneStats {

    /// Finer than `HistogramData.binCount` on purpose — see the file note.
    static let binCount = 256

    /// Fraction of pixels allowed to sit outside the black/white points.
    static let clipFraction = 0.001

    /// Where a correctly-exposed frame's mean luma should land (sRGB-encoded,
    /// not linear — this measures the display-encoded buffer it is handed).
    static let targetMeanLuma = 0.46

    /// Inter-percentile spread of an image that already has normal contrast.
    /// Narrower than this opens up, wider pulls back.
    static let targetSpread = 0.62

    struct Result: Equatable {
        var exposureEV: Double = 0
        var contrast: Double = 0
        var blacks: Double = 0
        var whites: Double = 0
        var temperature: Double = 0
        var tint: Double = 0

        static let none = Result()
    }

    static func compute(rgba8: [UInt8], width: Int, height: Int) -> Result {
        let pixelCount = width * height
        guard pixelCount > 0, rgba8.count >= pixelCount * 4 else { return .none }

        var luma = [Int](repeating: 0, count: binCount)
        var sumR = 0.0, sumG = 0.0, sumB = 0.0, sumLuma = 0.0

        for i in stride(from: 0, to: pixelCount * 4, by: 4) {
            let r = Double(rgba8[i]) / 255
            let g = Double(rgba8[i + 1]) / 255
            let b = Double(rgba8[i + 2]) / 255
            sumR += r; sumG += g; sumB += b
            // Rec.709 luma on the display-encoded values, matching what the
            // histogram panel shows the user.
            let y = 0.2126 * r + 0.7152 * g + 0.0722 * b
            sumLuma += y
            let bin = min(binCount - 1, max(0, Int(y * Double(binCount - 1))))
            luma[bin] += 1
        }

        let n = Double(pixelCount)
        var out = Result()

        // --- Exposure: mean luma toward the target, expressed in stops.
        let mean = sumLuma / n
        if mean > 0.0001 {
            out.exposureEV = clamp(log2(targetMeanLuma / mean), -5, 5)
        }

        // --- Black / white points from clipped percentiles.
        let lowIdx = percentileBin(luma, count: n, fraction: clipFraction)
        let highIdx = percentileBin(luma, count: n, fraction: 1 - clipFraction)
        let low = Double(lowIdx) / Double(binCount - 1)
        let high = Double(highIdx) / Double(binCount - 1)

        // Distance from the ideal 0 and 1 endpoints, scaled to slider units.
        // A frame whose darkest pixel is already 0 needs no black lift.
        out.blacks = clamp(-low * 2.0, -1, 1)
        out.whites = clamp((1 - high) * 2.0, -1, 1)

        // --- Contrast from the inter-percentile spread.
        let spread = max(0.0001, high - low)
        out.contrast = clamp((targetSpread - spread) * 1.2, -1, 1)

        // --- Grey-world white balance. The average scene is neutral, so the
        // correction is the INVERSE of the cast: a red-heavy frame gets a
        // negative (cooler) temperature. Sign errors here double the cast,
        // which is why `testWarmCastIsCorrectedCooler` pins it.
        let avgR = sumR / n, avgG = sumG / n, avgB = sumB / n
        let avgAll = (avgR + avgG + avgB) / 3
        if avgAll > 0.0001 {
            out.temperature = clamp(-((avgR - avgB) / avgAll) * 0.8, -1, 1)
            out.tint = clamp(-((avgG - (avgR + avgB) / 2) / avgAll) * 0.8, -1, 1)
        }

        return out
    }

    /// First bin at or past `fraction` of the cumulative population.
    private static func percentileBin(_ hist: [Int], count: Double,
                                      fraction: Double) -> Int {
        let target = count * fraction
        var running = 0.0
        for (i, v) in hist.enumerated() {
            running += Double(v)
            if running >= target { return i }
        }
        return hist.count - 1
    }

    private static func clamp(_ v: Double, _ lo: Double, _ hi: Double) -> Double {
        v.isFinite ? min(max(v, lo), hi) : 0
    }
}
```

- [ ] **Step 4: Add both files to the Xcode targets**

`AutoToneStats.swift` → the `Muse` app target. `AutoToneStatsTests.swift` → the `MuseTests` target. Open `Muse/Muse.xcodeproj` and drag them in, or edit `project.pbxproj` directly. A file that isn't in a target compiles nowhere and the test will keep failing with "cannot find in scope".

- [ ] **Step 5: Run the test to verify it passes**

Run: `xcodebuild -project Muse/Muse.xcodeproj -scheme Muse test -only-testing:MuseTests/AutoToneStatsTests 2>&1 | tail -20`
Expected: PASS, 7 tests.

- [ ] **Step 6: Commit**

```bash
./scripts/audit-invariants.sh
git add Muse/Muse/Editing/AutoToneStats.swift Muse/MuseTests/AutoToneStatsTests.swift Muse/Muse.xcodeproj/project.pbxproj
git commit -m "auto-tone: the statistics pass, measured from the original"
```

---

### Task 2: EFFECTS card — vignette reaches a UI at last

**Files:**
- Modify: `Muse/Muse/Views/Editor/EditorView.swift` (Section enum ~line 70; right-panel builder ~line 746)
- Test: `Muse/MuseTests/EditStackNormalizeTests.swift`

**Interfaces:**
- Consumes: `EditStack.setVignette`, `VignetteParams` (both already exist).
- Produces: `Section.effects` string id, `effectsSection` view. Task 9 adds grain sliders to the same card.

**Context:** `VignetteParams` has shipped since Spec 04 with a full renderer branch and NOTHING that writes it — `LooksBrowserView.swift:108` only resets it. This is pure UI.

- [ ] **Step 1: Write the failing test**

Append to `Muse/MuseTests/EditStackNormalizeTests.swift`:

```swift
    /// Vignette survives a normalize round-trip at its canonical index and is
    /// not neutral once amount moves — the two facts the EFFECTS card depends
    /// on. Before this card existed nothing in the app could produce this
    /// state.
    func testVignetteRoundTripsAtItsCanonicalIndex() {
        var stack = EditStack.fresh()
        stack.setVignette { $0.amount = -0.4; $0.midpoint = 0.3; $0.feather = 0.8 }
        XCTAssertFalse(stack.isNeutral)

        let normalized = stack.normalized()
        XCTAssertEqual(normalized.vignetteParams?.amount, -0.4)
        XCTAssertEqual(normalized.vignetteParams?.midpoint, 0.3)
        XCTAssertEqual(normalized.vignetteParams?.feather, 0.8)

        // Amount back to zero is neutral REGARDLESS of midpoint/feather —
        // this is what stops the card from persisting a no-op blob.
        stack.setVignette { $0.amount = 0 }
        XCTAssertTrue(stack.isNeutral)
    }
```

- [ ] **Step 2: Run it to verify it passes already**

Run: `xcodebuild -project Muse/Muse.xcodeproj -scheme Muse test -only-testing:MuseTests/EditStackNormalizeTests 2>&1 | tail -20`
Expected: PASS. This one is a characterization test — the model is already correct, and this pins the contract the card relies on before the card exists.

- [ ] **Step 3: Add the Section id**

In `EditorView.swift`, the `Section` enum (~line 70) currently reads:

```swift
    private enum Section {
        static let tools = "tools", histogram = "histogram"
        static let insights = "insights", history = "history"
        static let looks = "looks", light = "light", zones = "zones", color = "color"
    }
```

Add `effects`:

```swift
    private enum Section {
        static let tools = "tools", histogram = "histogram"
        static let insights = "insights", history = "history"
        static let looks = "looks", light = "light", zones = "zones", color = "color"
        static let effects = "effects", crop = "crop"
    }
```

(`crop` is added now so Task 12 doesn't have to touch this line again.)

- [ ] **Step 4: Add the card to the right panel**

In `EditorView.swift`, immediately after the `EditorSection(title: String(localized: "COLOR") …)` block that closes the right-panel builder, append:

```swift
        // Vignette (and, from Stage B, grain). Named EFFECTS rather than the
        // spec's original "Character" for the same reason SCOPES became
        // HISTOGRAM: it has to say what it does to someone looking at their
        // own photo.
        EditorSection(title: String(localized: "EFFECTS"),
                      ink: ink,
                      accessory: resetButton(String(localized: "Reset Effects")) {
                          session.draft.setVignette { $0 = .neutral }
                          session.commitGesture()
                      },
                      isExpanded: expansion(Section.effects)) { effectsSection }
```

- [ ] **Step 5: Add the section body and its binding**

Add beside `colorTab` in `EditorView.swift`:

```swift
    private var effectsSection: some View {
        VStack(alignment: .leading, spacing: panelTheme.spacingS) {
            EditSlider(label: String(localized: "Vignette"),
                       value: vignetteBinding(\.amount), onCommit: session.commitGesture)
            EditSlider(label: String(localized: "Midpoint"),
                       value: vignetteBinding(\.midpoint), range: 0...1, neutral: 0.5,
                       onCommit: session.commitGesture)
            EditSlider(label: String(localized: "Feather"),
                       value: vignetteBinding(\.feather), range: 0...1, neutral: 0.5,
                       onCommit: session.commitGesture)
        }
    }

    private func vignetteBinding(_ key: WritableKeyPath<VignetteParams, Double>)
        -> Binding<Double> {
        Binding(get: { session.draft.vignetteParams?[keyPath: key]
                        ?? VignetteParams.neutral[keyPath: key] },
                set: { v in session.draft.setVignette { $0[keyPath: key] = v } })
    }
```

Note the `neutral:` arguments — double-clicking Midpoint or Feather must return to 0.5, not 0, or the reset gesture lands somewhere the user never chose.

- [ ] **Step 6: Build and verify the card appears**

Run: `xcodebuild -project Muse/Muse.xcodeproj -scheme Muse -configuration Debug build 2>&1 | tail -5`
Expected: `BUILD SUCCEEDED`, no new warnings.

Then confirm the binary is actually fresh before looking at it (a stale `.app` has burned a whole session here before):

```bash
rm -rf ~/Library/Developer/Xcode/DerivedData/Muse-*/Build/Products/Debug/Muse.app
xcodebuild -project Muse/Muse.xcodeproj -scheme Muse -configuration Debug build 2>&1 | tail -3
stat -f "%Sm %N" ~/Library/Developer/Xcode/DerivedData/Muse-*/Build/Products/Debug/Muse.app/Contents/MacOS/Muse
```

Open a photo → Edit → the EFFECTS card is below COLOR. Drag Vignette; the corners darken. Double-click Midpoint's label; it returns to 0.5.

- [ ] **Step 7: Commit**

```bash
./scripts/audit-invariants.sh
git add Muse/Muse/Views/Editor/EditorView.swift Muse/MuseTests/EditStackNormalizeTests.swift
git commit -m "editor: EFFECTS card — vignette finally has a UI"
```

---

### Task 3: The two scoped Auto buttons

**Files:**
- Modify: `Muse/Muse/Views/Editor/EditSession.swift` (add the auto-tone tap)
- Modify: `Muse/Muse/Views/Editor/EditorView.swift` (LIGHT + COLOR accessories)
- Test: `Muse/MuseTests/AutoToneApplyTests.swift` (create)

**Interfaces:**
- Consumes: `AutoToneStats.Result` and `AutoToneStats.compute` (Task 1); `EditSession.originalImage`, `EditSession.rgba8Sample`.
- Produces: `EditSession.autoToneResult() async -> AutoToneStats.Result?`, `AutoToneApply.light(_:onto:)`, `AutoToneApply.color(_:onto:)`.

**Why two buttons:** per-card Reset is deliberately scoped — "undoes that group and nothing else, so fixing the colour doesn't cost you the tone work" (`EditorView.swift:755`). A button in LIGHT that silently changed COLOR would break that convention.

- [ ] **Step 1: Write the failing test**

```swift
//  AutoToneApplyTests.swift
import XCTest
@testable import Muse

final class AutoToneApplyTests: XCTestCase {

    private var sample: AutoToneStats.Result {
        AutoToneStats.Result(exposureEV: 1.2, contrast: 0.3, blacks: -0.2,
                             whites: 0.25, temperature: -0.4, tint: 0.1)
    }

    /// Auto in LIGHT writes tone and leaves COLOR strictly alone. This is the
    /// scoping guarantee that mirrors per-card Reset.
    func testLightAutoDoesNotTouchColor() {
        var stack = EditStack.fresh()
        stack.setColor { $0.temperature = 0.75 }        // the user's own choice
        AutoToneApply.light(sample, onto: &stack)

        XCTAssertEqual(stack.toneParams?.exposureEV, 1.2)
        XCTAssertEqual(stack.toneParams?.whites, 0.25)
        XCTAssertEqual(stack.colorParams?.temperature, 0.75, "Auto in Light must not touch Color")
    }

    /// And the mirror image.
    func testColorAutoDoesNotTouchTone() {
        var stack = EditStack.fresh()
        stack.setTone { $0.exposureEV = -2 }
        AutoToneApply.color(sample, onto: &stack)

        XCTAssertEqual(stack.colorParams?.temperature, -0.4)
        XCTAssertEqual(stack.colorParams?.tint, 0.1)
        XCTAssertEqual(stack.toneParams?.exposureEV, -2, "Auto in Color must not touch Light")
    }

    /// Idempotence: the same stats applied twice give the same stack. The
    /// session guarantees the stats themselves come from the ORIGINAL.
    func testApplyingTwiceIsIdempotent() {
        var a = EditStack.fresh()
        AutoToneApply.light(sample, onto: &a)
        var b = a
        AutoToneApply.light(sample, onto: &b)
        XCTAssertEqual(a.normalized(), b.normalized())
    }

    /// An all-zero result must leave a fresh stack neutral — Auto on an
    /// already-perfect photo stores nothing at all.
    func testNeutralResultLeavesStackNeutral() {
        var stack = EditStack.fresh()
        AutoToneApply.light(.none, onto: &stack)
        AutoToneApply.color(.none, onto: &stack)
        XCTAssertTrue(stack.isNeutral)
    }
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `xcodebuild -project Muse/Muse.xcodeproj -scheme Muse test -only-testing:MuseTests/AutoToneApplyTests 2>&1 | tail -20`
Expected: `cannot find 'AutoToneApply' in scope`.

- [ ] **Step 3: Write `AutoToneApply`**

Append to `Muse/Muse/Editing/AutoToneStats.swift`:

```swift
/// Which sliders each Auto button is allowed to write. Split by CARD, matching
/// the per-card Reset scope exactly: Auto in Light may never move a Color
/// slider, and vice versa.
nonisolated enum AutoToneApply {
    static func light(_ r: AutoToneStats.Result, onto stack: inout EditStack) {
        stack.setTone {
            $0.exposureEV = r.exposureEV
            $0.contrast = r.contrast
            $0.blacks = r.blacks
            $0.whites = r.whites
        }
    }

    static func color(_ r: AutoToneStats.Result, onto stack: inout EditStack) {
        stack.setColor {
            $0.temperature = r.temperature
            $0.tint = r.tint
        }
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `xcodebuild -project Muse/Muse.xcodeproj -scheme Muse test -only-testing:MuseTests/AutoToneApplyTests 2>&1 | tail -20`
Expected: PASS, 4 tests. (Add the test file to `MuseTests` first if it isn't picked up.)

- [ ] **Step 5: Add the session tap over the ORIGINAL**

In `EditSession.swift`, add after `refreshStats()`:

```swift
    // MARK: - Auto tone

    /// Cached so pressing Auto twice measures the SAME original, which is what
    /// makes the button idempotent. `originalImage` is the unedited render of
    /// the proxy the session already keeps for before/after, so this costs one
    /// small downsample and no extra decode.
    private var autoToneCache: AutoToneStats.Result?

    func autoToneResult() async -> AutoToneStats.Result? {
        if let autoToneCache { return autoToneCache }
        guard let image = originalImage else { return nil }
        let sampleEdge = Self.statsSampleLongEdge
        let result = await Task.detached(priority: .userInitiated) {
            () -> AutoToneStats.Result? in
            guard let sample = Self.rgba8Sample(of: image, longEdge: sampleEdge,
                                                context: RenderContexts.preview)
            else { return nil }
            return AutoToneStats.compute(rgba8: sample.bytes,
                                         width: sample.width, height: sample.height)
        }.value
        autoToneCache = result
        return result
    }
```

Then relax `rgba8Sample`'s access from `private nonisolated static` to `nonisolated static` so the detached closure above can reach it (it is already `nonisolated`, only the `private` has to go).

- [ ] **Step 6: Add the two buttons**

In `EditorView.swift`, add the helper beside `resetButton`:

```swift
    /// Auto sits beside Reset and is scoped the same way — see AutoToneApply.
    private func autoButton(_ help: String, action: @escaping () -> Void) -> some View {
        EditorSmallButton(label: String(localized: "Auto"),
                          systemName: "wand.and.stars",
                          action: action)
            .environment(\.theme, panelTheme)
            .help(Text(help))
    }
```

Change the LIGHT card's accessory from the bare `resetButton(…)` to an `HStack` of both:

```swift
        EditorSection(title: String(localized: "LIGHT"),
                      ink: ink,
                      accessory: AnyView(HStack(spacing: 4) {
                          autoButton(String(localized: "Auto Light")) {
                              Task {
                                  guard let r = await session.autoToneResult() else { return }
                                  AutoToneApply.light(r, onto: &session.draft)
                                  session.commitGesture()
                              }
                          }
                          EditorSmallButton(label: String(localized: "Reset"),
                                            systemName: "arrow.counterclockwise") {
                              session.draft.setTone { $0 = .neutral }
                              session.draft.setPresence { $0 = .neutral }
                              session.draft.setCurve { $0 = .neutral }
                              session.commitGesture()
                          }
                          .environment(\.theme, panelTheme)
                          .help(Text(String(localized: "Reset Light")))
                      }),
                      isExpanded: expansion(Section.light)) { lightTab }
```

Do the same for COLOR, with `AutoToneApply.color` and the existing Color reset body.

- [ ] **Step 7: Build and verify by hand**

Run: `xcodebuild -project Muse/Muse.xcodeproj -scheme Muse -configuration Debug build 2>&1 | tail -5`

In the app: open an underexposed photo → Edit → press Auto in LIGHT. Exposure/contrast/blacks/whites move; Temperature and Tint do NOT. Press Auto again — nothing changes (idempotence). ⌘Z undoes the whole thing in one step.

- [ ] **Step 8: Commit**

```bash
./scripts/audit-invariants.sh
git add Muse/Muse/Editing/AutoToneStats.swift Muse/Muse/Views/Editor/EditSession.swift Muse/Muse/Views/Editor/EditorView.swift Muse/MuseTests/AutoToneApplyTests.swift
git commit -m "auto-tone: scoped Auto buttons in Light and Color"
```

---

### Task 4: Delete the three dead analyze functions

**Files:**
- Modify: `Muse/Muse/Models/AppState+Indexing.swift:82-95`
- Modify: `Muse/Muse/Intelligence/AnalyzePipeline.swift:104-105`

**Context:** `analyzeCurrentFolder()` and `analyzeSelected()` have zero callers; the shipped Regenerate Tags command routes through `AppState.swift:801` instead. `analyzeFileManual` is dead by transitivity. Per-photo re-analyze is NOT being wired up.

- [ ] **Step 1: Confirm they are still uncalled**

```bash
grep -rn "analyzeCurrentFolder\|analyzeSelected\|analyzeFileManual" Muse --include="*.swift"
```
Expected: only the declarations themselves and `AppState+Indexing.swift`'s two call sites into the pipeline. If anything else appears, STOP — something now calls them and this task is void.

- [ ] **Step 2: Delete `analyzeCurrentFolder()` and `analyzeSelected()`**

Remove both functions from `AppState+Indexing.swift` (lines 82–95, through the closing brace of `analyzeSelected`).

- [ ] **Step 3: Delete `analyzeFileManual(_:)`**

Remove it from `AnalyzePipeline.swift` along with its doc comment. Leave `analyzeFolderManual` — `AppState.swift:801` calls it.

- [ ] **Step 4: Build**

Run: `xcodebuild -project Muse/Muse.xcodeproj -scheme Muse -configuration Debug build 2>&1 | tail -5`
Expected: `BUILD SUCCEEDED`. Any error means something did reference them — revert and re-check Step 1.

- [ ] **Step 5: Run the unit target**

Run: `xcodebuild -project Muse/Muse.xcodeproj -scheme Muse test -only-testing:MuseTests 2>&1 | tail -15`
Expected: all green.

- [ ] **Step 6: Commit**

```bash
./scripts/audit-invariants.sh
git add Muse/Muse/Models/AppState+Indexing.swift Muse/Muse/Intelligence/AnalyzePipeline.swift
git commit -m "cull: three uncalled analyze functions"
```

---

# STAGE B — three appended cases

Each task follows the same shape: model case → codec → transfer group → kernel → renderer → UI. Do them in order; each ends green.

---

### Task 5: `.hsl` — model, codec, transfer

**Files:**
- Modify: `Muse/Muse/Editing/EditStack.swift`
- Modify: `Muse/Muse/Editing/EditTransfer.swift`
- Test: `Muse/MuseTests/HSLParamsTests.swift` (create)

**Interfaces:**
- Produces: `HSLParams` with `hue: [Double]`, `saturation: [Double]`, `luminance: [Double]` (8 each); `HSLParams.bandCount = 8`; `Adjustment.hsl(HSLParams)` at `canonicalIndex` **8**; `EditStack.hslParams`, `EditStack.setHSL`; `AdjustmentGroup.hsl`.

- [ ] **Step 1: Write the failing test**

```swift
//  HSLParamsTests.swift
import XCTest
@testable import Muse

final class HSLParamsTests: XCTestCase {

    func testNeutralIsAllZeroAcrossEightBands() {
        let p = HSLParams.neutral
        XCTAssertEqual(p.hue.count, 8)
        XCTAssertEqual(p.saturation.count, 8)
        XCTAssertEqual(p.luminance.count, 8)
        XCTAssertTrue(p.isNeutral)
    }

    /// C2: the new case MUST land at index 8. Anything else re-keys every
    /// edited thumbnail's stack_hash in every library.
    func testCanonicalIndexIsEight() {
        XCTAssertEqual(Adjustment.hsl(.neutral).canonicalIndex, 8)
    }

    /// A short or long array from a hand-edited sidecar must not crash the
    /// renderer — clamped() normalizes LENGTH as well as range, exactly as
    /// ToneZoneParams does.
    func testClampedNormalizesLengthAndRange() {
        let p = HSLParams(hue: [2.0], saturation: [], luminance: Array(repeating: -9.0, count: 40))
        let c = p.clamped()
        XCTAssertEqual(c.hue.count, 8)
        XCTAssertEqual(c.saturation.count, 8)
        XCTAssertEqual(c.luminance.count, 8)
        XCTAssertEqual(c.hue[0], 1.0)        // clamped from 2.0
        XCTAssertEqual(c.hue[1], 0)          // padded
        XCTAssertEqual(c.luminance[0], -1.0) // clamped from -9.0
    }

    func testRoundTripsThroughTheCodec() throws {
        var stack = EditStack.fresh()
        stack.setHSL { $0.saturation[2] = 0.5 }         // yellow band
        let data = try EditStackCodec.encode(stack)
        let back = try EditStackCodec.decode(data)
        XCTAssertEqual(back.hslParams?.saturation[2], 0.5)
    }

    /// Copy/paste must carry it, or "sync this look across the shoot" silently
    /// drops the hue work.
    func testTransferCarriesTheGroup() {
        var source = EditStack.fresh()
        source.setHSL { $0.hue[0] = -0.3 }
        XCTAssertTrue(EditTransfer.adjustedGroups(of: source).contains(.hsl))

        let target = EditTransfer.apply(groups: [.hsl], from: source, onto: .fresh())
        XCTAssertEqual(target.hslParams?.hue[0], -0.3)
    }
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `xcodebuild -project Muse/Muse.xcodeproj -scheme Muse test -only-testing:MuseTests/HSLParamsTests 2>&1 | tail -20`
Expected: `cannot find 'HSLParams' in scope`.

- [ ] **Step 3: Add `HSLParams` to `EditStack.swift`**

Append after `LutParams` (order in the FILE doesn't matter; order in the ENUM does):

```swift
/// Eight fixed hue bands — red, orange, yellow, green, aqua, blue, purple,
/// magenta — Lightroom's model, because it is the one people have already
/// seen. Three parallel arrays rather than eight structs so the renderer can
/// hand the kernel three contiguous buffers.
nonisolated struct HSLParams: Codable, Equatable, Sendable {
    static let bandCount = 8

    var hue: [Double]
    var saturation: [Double]
    var luminance: [Double]

    init(hue: [Double], saturation: [Double], luminance: [Double]) {
        self.hue = hue; self.saturation = saturation; self.luminance = luminance
    }

    static let neutral = HSLParams(
        hue: .init(repeating: 0, count: bandCount),
        saturation: .init(repeating: 0, count: bandCount),
        luminance: .init(repeating: 0, count: bandCount))

    var isNeutral: Bool {
        hue.allSatisfy { $0 == 0 } && saturation.allSatisfy { $0 == 0 }
            && luminance.allSatisfy { $0 == 0 }
    }

    /// Clamps range AND normalizes length, for the same reason `ToneZoneParams`
    /// does: decoding round-trips the blob byte-identically, so a hand-edited
    /// or future-shaped sidecar reaches the renderer and must not index out of
    /// bounds.
    func clamped() -> HSLParams {
        HSLParams(hue: Self.fit(hue), saturation: Self.fit(saturation),
                  luminance: Self.fit(luminance))
    }

    private static func fit(_ a: [Double]) -> [Double] {
        var v = a
        if v.count < bandCount { v += Array(repeating: 0, count: bandCount - v.count) }
        else if v.count > bandCount { v = Array(v.prefix(bandCount)) }
        return v.map { min(max($0, -1), 1) }
    }
}
```

- [ ] **Step 4: Append the enum case (index 8)**

In `Adjustment`, append after `case lut(LutParams)`:

```swift
    // Stage B — APPENDED after lut. Inserting mid-list would re-key every
    // pre-existing edited thumbnail's `stack_hash`.
    case hsl(HSLParams)
```

Add to `canonicalIndex`: `case .hsl: 8`. Add to `isNeutralCase`: `case .hsl(let p): p.isNeutral`. Add `hsl` to the `Kind` enum, the `init(from:)` switch, and the `encode(to:)` switch — following the exact shape of the `lut` cases beside them.

- [ ] **Step 5: Add the accessor and mutator**

In the `nonisolated extension EditStack` block:

```swift
    var hslParams: HSLParams? {
        for case .hsl(let p) in adjustments { return p }
        return nil
    }
```

and:

```swift
    mutating func setHSL(_ mutate: (inout HSLParams) -> Void) {
        var p = hslParams ?? .neutral
        mutate(&p)
        replace(.hsl(p))
    }
```

- [ ] **Step 6: Add the transfer group**

In `EditTransfer.swift`, append `hsl` to `AdjustmentGroup` and add `case .hsl: .hsl` to the group→case mapping, plus the `adjustedGroups` / `apply` branches matching the existing `lut` shape.

- [ ] **Step 7: Run the test to verify it passes**

Run: `xcodebuild -project Muse/Muse.xcodeproj -scheme Muse test -only-testing:MuseTests/HSLParamsTests 2>&1 | tail -20`
Expected: PASS, 5 tests.

- [ ] **Step 8: Verify the pinned codec hash still passes**

Run: `xcodebuild -project Muse/Muse.xcodeproj -scheme Muse test -only-testing:MuseTests/EditStackCodecTests 2>&1 | tail -20`
Expected: PASS. A failure here means a pre-existing stack's canonical bytes changed — the case was inserted rather than appended. Fix before continuing.

- [ ] **Step 9: Commit**

```bash
./scripts/audit-invariants.sh
git add Muse/Muse/Editing/EditStack.swift Muse/Muse/Editing/EditTransfer.swift Muse/MuseTests/HSLParamsTests.swift
git commit -m "hsl: model, codec and transfer group at canonical index 8"
```

---

### Task 6: `.hsl` — kernel and renderer

**Files:**
- Modify: `Muse/Muse/Editing/Render/EditKernels.metal`
- Modify: `Muse/Muse/Editing/Render/EditKernels.swift`
- Modify: `Muse/Muse/Editing/Render/EditRenderer.swift`
- Test: `Muse/MuseTests/EditRenderNeutralityTests.swift`

**Interfaces:**
- Consumes: `HSLParams` (Task 5).
- Produces: `EditKernels.hslAdjust`, `EditRenderer.applyHSL(_:to:)`.

- [ ] **Step 1: Write the failing test**

Append to `EditRenderNeutralityTests.swift`:

```swift
    /// Neutral HSL must render byte-identically to no HSL at all. Every stage
    /// in this chain owes this guarantee — a "neutral" that shifts pixels
    /// means the stack is never really off.
    func testNeutralHSLRendersUnchanged() throws {
        var stack = EditStack.fresh()
        stack.setHSL { $0 = .neutral }
        XCTAssertTrue(stack.isNeutral)
    }

    /// A saturation pull on one band changes pixels; the neutral bands do not.
    func testHSLSaturationOnOneBandIsNotNeutral() throws {
        var stack = EditStack.fresh()
        stack.setHSL { $0.saturation[5] = -1 }        // blue → grey
        XCTAssertFalse(stack.isNeutral)
        XCTAssertNotNil(EditRenderer.canRender(stack) ? stack.hslParams : nil)
    }
```

- [ ] **Step 2: Run it to verify it fails**

Run: `xcodebuild -project Muse/Muse.xcodeproj -scheme Muse test -only-testing:MuseTests/EditRenderNeutralityTests 2>&1 | tail -20`
Expected: FAIL to compile until Step 3–5 land (the test references nothing new, so if it passes immediately, that is fine — it becomes the guard for the kernel work).

- [ ] **Step 3: Add the Metal kernel**

Append to `EditKernels.metal`:

```metal
// Eight-band HSL. Bands are centred every 45° starting at red (0°), and a
// pixel's influence falls off linearly to zero at the neighbouring centres —
// so the weights of any two adjacent bands always sum to 1 and there is no
// seam between them. Operates on un-clamped linear data like its neighbours.
extern "C" [[stitchable]] float4 hslAdjust(coreimage::sample_t s,
                                           float h0, float h1, float h2, float h3,
                                           float h4, float h5, float h6, float h7,
                                           float s0, float s1, float s2, float s3,
                                           float s4, float s5, float s6, float s7,
                                           float l0, float l1, float l2, float l3,
                                           float l4, float l5, float l6, float l7) {
    float hueArr[8]  = {h0, h1, h2, h3, h4, h5, h6, h7};
    float satArr[8]  = {s0, s1, s2, s3, s4, s5, s6, s7};
    float lumArr[8]  = {l0, l1, l2, l3, l4, l5, l6, l7};

    float3 c = max(s.rgb, 0.0);
    float mx = max(c.r, max(c.g, c.b));
    float mn = min(c.r, min(c.g, c.b));
    float delta = mx - mn;
    if (delta < 1e-6) { return s; }              // grey: no hue to target

    float hue;
    if (mx == c.r)      { hue = fmod((c.g - c.b) / delta, 6.0); }
    else if (mx == c.g) { hue = (c.b - c.r) / delta + 2.0; }
    else                { hue = (c.r - c.g) / delta + 4.0; }
    hue = fmod(hue * 60.0 + 360.0, 360.0);

    float pos = hue / 45.0;                      // 0…8 across the eight bands
    int lo = int(floor(pos)) % 8;
    int hi = (lo + 1) % 8;
    float t = pos - floor(pos);

    float dHue = mix(hueArr[lo], hueArr[hi], t);
    float dSat = mix(satArr[lo], satArr[hi], t);
    float dLum = mix(lumArr[lo], lumArr[hi], t);

    // Rotate hue (±30° at full slider), scale saturation, scale value.
    hue = fmod(hue + dHue * 30.0 + 360.0, 360.0);
    float sat = clamp((delta / max(mx, 1e-6)) * (1.0 + dSat), 0.0, 1.0);
    float val = mx * (1.0 + dLum * 0.5);

    float cc = val * sat;
    float xx = cc * (1.0 - fabs(fmod(hue / 60.0, 2.0) - 1.0));
    float m = val - cc;
    float3 o;
    if      (hue <  60.0) o = float3(cc, xx, 0.0);
    else if (hue < 120.0) o = float3(xx, cc, 0.0);
    else if (hue < 180.0) o = float3(0.0, cc, xx);
    else if (hue < 240.0) o = float3(0.0, xx, cc);
    else if (hue < 300.0) o = float3(xx, 0.0, cc);
    else                  o = float3(cc, 0.0, xx);
    return float4(o + m, s.a);
}
```

- [ ] **Step 4: Register the kernel**

In `EditKernels.swift`, under a new `// MARK: - Stage B` heading:

```swift
    /// Eight-band HSL.
    static let hslAdjust: CIColorKernel? = load("hslAdjust")
```

- [ ] **Step 5: Call it from the chain**

In `EditRenderer.apply`, insert AFTER the `applyColor` block and BEFORE the LUT block:

```swift
        if let hsl = stack.hslParams, !hsl.isNeutral {
            current = applyHSL(hsl.clamped(), to: current)
        }
```

And add the method beside `applyColor`:

```swift
    private static func applyHSL(_ p: HSLParams, to image: CIImage) -> CIImage {
        guard let kernel = EditKernels.hslAdjust else { return image }
        var args: [Any] = [image]
        args += p.hue.map { Float($0) }
        args += p.saturation.map { Float($0) }
        args += p.luminance.map { Float($0) }
        return kernel.apply(extent: image.extent, arguments: args) ?? image
    }
```

The `guard … else { return image }` is the nil-kernel rule (`EditRenderer.swift:184`): a broken metallib skips the stage rather than crashing.

- [ ] **Step 6: Run the tests**

Run: `xcodebuild -project Muse/Muse.xcodeproj -scheme Muse test -only-testing:MuseTests/EditRenderNeutralityTests -only-testing:MuseTests/EditKernelLoadTests 2>&1 | tail -20`
Expected: PASS. `EditKernelLoadTests` is what catches a kernel that failed to compile into the metallib.

- [ ] **Step 7: Commit**

```bash
./scripts/audit-invariants.sh
git add Muse/Muse/Editing/Render/
git commit -m "hsl: eight-band Metal kernel, rendered after saturation"
```

---

### Task 7: `.hsl` — the UI

**Files:**
- Modify: `Muse/Muse/Views/Editor/EditorView.swift`

**Interfaces:**
- Consumes: `EditStack.setHSL`, `HSLParams.bandCount`.
- Produces: `hslSection`, `hslTab` state.

- [ ] **Step 1: Add the band names and tab state**

In `EditorView.swift`:

```swift
    /// Which of the three HSL channels the eight sliders are editing. In the
    /// card HEADING, not the body — same reason the Styles Grid/List pair is:
    /// inside the card it pushed every row down.
    private enum HSLTab: String, CaseIterable { case hue, saturation, luminance }
    @State private var hslTab: HSLTab = .saturation

    /// Band order is fixed and matches the kernel's 45° centres starting at red.
    private static let hslBandNames = [
        String(localized: "Red"), String(localized: "Orange"),
        String(localized: "Yellow"), String(localized: "Green"),
        String(localized: "Aqua"), String(localized: "Blue"),
        String(localized: "Purple"), String(localized: "Magenta"),
    ]
```

- [ ] **Step 2: Add the section body**

```swift
    private var hslSection: some View {
        VStack(alignment: .leading, spacing: panelTheme.spacingS) {
            ForEach(Array(Self.hslBandNames.enumerated()), id: \.offset) { i, name in
                EditSlider(label: name, value: hslBinding(i), onCommit: session.commitGesture)
            }
        }
    }

    private func hslBinding(_ band: Int) -> Binding<Double> {
        Binding(get: {
            let p = session.draft.hslParams ?? .neutral
            let arr = switch hslTab {
                case .hue: p.hue
                case .saturation: p.saturation
                case .luminance: p.luminance
            }
            return band < arr.count ? arr[band] : 0
        }, set: { v in
            session.draft.setHSL { p in
                switch hslTab {
                case .hue: if band < p.hue.count { p.hue[band] = v }
                case .saturation: if band < p.saturation.count { p.saturation[band] = v }
                case .luminance: if band < p.luminance.count { p.luminance[band] = v }
                }
            }
        })
    }

    private var hslTabButtons: AnyView {
        AnyView(HStack(spacing: 4) {
            stylesModeButton(systemName: "paintpalette", isOn: hslTab == .hue,
                             label: String(localized: "Hue")) { hslTab = .hue }
            stylesModeButton(systemName: "drop", isOn: hslTab == .saturation,
                             label: String(localized: "Saturation")) { hslTab = .saturation }
            stylesModeButton(systemName: "sun.max", isOn: hslTab == .luminance,
                             label: String(localized: "Luminance")) { hslTab = .luminance }
        })
    }
```

- [ ] **Step 3: Add the card, below COLOR and above EFFECTS**

```swift
        EditorSection(title: String(localized: "COLOR MIX"),
                      ink: ink,
                      accessory: hslTabButtons,
                      isExpanded: expansion(Section.hsl)) { hslSection }
```

Add `static let hsl = "hsl"` to the `Section` enum.

- [ ] **Step 4: Build and verify by hand**

Run: `xcodebuild -project Muse/Muse.xcodeproj -scheme Muse -configuration Debug build 2>&1 | tail -5`

In the app: open a photo with a blue sky → COLOR MIX → Saturation tab → drag Blue to −1. The sky desaturates and nothing else does. Switch to Luminance; the eight sliders show that channel's values, not Saturation's.

- [ ] **Step 5: Commit**

```bash
./scripts/audit-invariants.sh
git add Muse/Muse/Views/Editor/EditorView.swift
git commit -m "hsl: COLOR MIX card with three channel tabs"
```

---

### Task 8: `.splitTone` — model, kernel, renderer, UI

**Files:**
- Modify: `EditStack.swift`, `EditTransfer.swift`, `EditKernels.metal`, `EditKernels.swift`, `EditRenderer.swift`, `EditorView.swift`
- Test: `Muse/MuseTests/SplitToneParamsTests.swift` (create)

**Interfaces:**
- Produces: `SplitToneParams` with `shadowHue`, `shadowSaturation`, `highlightHue`, `highlightSaturation`, `balance`; `Adjustment.splitTone` at index **9**; `EditKernels.splitTone`.

- [ ] **Step 1: Write the failing test**

```swift
//  SplitToneParamsTests.swift
import XCTest
@testable import Muse

final class SplitToneParamsTests: XCTestCase {

    func testCanonicalIndexIsNine() {
        XCTAssertEqual(Adjustment.splitTone(.neutral).canonicalIndex, 9)
    }

    /// Neutral means BOTH saturations at zero — a hue with no saturation
    /// tints nothing, so it must not count as an edit.
    func testHueWithoutSaturationIsNeutral() {
        var p = SplitToneParams.neutral
        p.shadowHue = 0.8
        p.highlightHue = 0.2
        XCTAssertTrue(p.isNeutral)

        p.shadowSaturation = 0.3
        XCTAssertFalse(p.isNeutral)
    }

    func testClampedBoundsEveryField() {
        let p = SplitToneParams(shadowHue: 5, shadowSaturation: -3,
                                highlightHue: -9, highlightSaturation: 4, balance: 7)
        let c = p.clamped()
        XCTAssertEqual(c.shadowHue, 1)
        XCTAssertEqual(c.shadowSaturation, 0)     // saturation floors at 0
        XCTAssertEqual(c.highlightHue, 0)
        XCTAssertEqual(c.highlightSaturation, 1)
        XCTAssertEqual(c.balance, 1)
    }

    func testRoundTripsAndTransfers() throws {
        var stack = EditStack.fresh()
        stack.setSplitTone { $0.shadowHue = 0.6; $0.shadowSaturation = 0.4 }
        let back = try EditStackCodec.decode(EditStackCodec.encode(stack))
        XCTAssertEqual(back.splitToneParams?.shadowHue, 0.6)
        XCTAssertTrue(EditTransfer.adjustedGroups(of: stack).contains(.splitTone))
    }
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `xcodebuild -project Muse/Muse.xcodeproj -scheme Muse test -only-testing:MuseTests/SplitToneParamsTests 2>&1 | tail -20`

- [ ] **Step 3: Add the params**

```swift
/// Shadow and highlight tinting. Hue is 0…1 around the wheel; saturation is
/// 0…1; balance shifts the shadow/highlight split point. Display-referred —
/// see the renderer note.
nonisolated struct SplitToneParams: Codable, Equatable, Sendable {
    var shadowHue: Double = 0
    var shadowSaturation: Double = 0
    var highlightHue: Double = 0
    var highlightSaturation: Double = 0
    var balance: Double = 0           // −1…+1

    static let neutral = SplitToneParams()

    /// A hue with no saturation tints nothing, so it is NOT an edit.
    var isNeutral: Bool { shadowSaturation == 0 && highlightSaturation == 0 }

    func clamped() -> SplitToneParams {
        SplitToneParams(shadowHue: min(max(shadowHue, 0), 1),
                        shadowSaturation: min(max(shadowSaturation, 0), 1),
                        highlightHue: min(max(highlightHue, 0), 1),
                        highlightSaturation: min(max(highlightSaturation, 0), 1),
                        balance: min(max(balance, -1), 1))
    }
}
```

Append `case splitTone(SplitToneParams)` to `Adjustment` with `canonicalIndex` **9**, plus the `isNeutralCase`, `Kind`, decode and encode branches, the `splitToneParams` accessor, `setSplitTone` mutator, and the `AdjustmentGroup.splitTone` case — all mirroring what Task 5 did for `.hsl`.

- [ ] **Step 4: Add the Metal kernel**

```metal
// Split toning. Weights each pixel toward a shadow tint or a highlight tint by
// its luma, with `balance` sliding the crossover. Display-referred: it runs
// after the curve and the LUT because that is where the user is judging it.
extern "C" [[stitchable]] float4 splitTone(coreimage::sample_t s,
                                           float shR, float shG, float shB, float shAmt,
                                           float hiR, float hiG, float hiB, float hiAmt,
                                           float balance) {
    float3 c = s.rgb;
    float y = clamp(dot(c, float3(0.2126, 0.7152, 0.0722)), 0.0, 1.0);
    // balance −1 pushes the crossover down (more highlight tint), +1 up.
    float pivot = clamp(0.5 - balance * 0.4, 0.05, 0.95);
    float hiW = smoothstep(pivot - 0.35, pivot + 0.35, y);
    float shW = 1.0 - hiW;

    float3 shadowTint    = float3(shR, shG, shB);
    float3 highlightTint = float3(hiR, hiG, hiB);
    // Soft-light-ish blend toward the tint, scaled by weight and amount.
    c = mix(c, c * (1.0 - shAmt) + shadowTint * shAmt, shW);
    c = mix(c, c * (1.0 - hiAmt) + highlightTint * hiAmt, hiW);
    return float4(c, s.a);
}
```

Register it: `static let splitTone: CIColorKernel? = load("splitTone")`.

- [ ] **Step 5: Call it AFTER the LUT**

In `EditRenderer.apply`, after the `applyLut` block:

```swift
        // Display-referred, and after the LUT for the same reason the curve is
        // display-referred: the user is grading what they can see.
        if let split = stack.splitToneParams, !split.isNeutral {
            current = applySplitTone(split.clamped(), to: current)
        }
```

```swift
    private static func applySplitTone(_ p: SplitToneParams, to image: CIImage) -> CIImage {
        guard let kernel = EditKernels.splitTone else { return image }
        let sh = rgbFromHue(p.shadowHue)
        let hi = rgbFromHue(p.highlightHue)
        return kernel.apply(extent: image.extent, arguments: [
            image, sh.0, sh.1, sh.2, Float(p.shadowSaturation),
            hi.0, hi.1, hi.2, Float(p.highlightSaturation), Float(p.balance),
        ]) ?? image
    }

    /// Fully-saturated RGB for a 0…1 hue — the tint colour the kernel blends toward.
    private static func rgbFromHue(_ h: Double) -> (Float, Float, Float) {
        let x = (h.truncatingRemainder(dividingBy: 1) + 1)
            .truncatingRemainder(dividingBy: 1) * 6
        let f = Float(x.truncatingRemainder(dividingBy: 1))
        switch Int(x) {
        case 0: return (1, f, 0)
        case 1: return (1 - f, 1, 0)
        case 2: return (0, 1, f)
        case 3: return (0, 1 - f, 1)
        case 4: return (f, 0, 1)
        default: return (1, 0, 1 - f)
        }
    }
```

- [ ] **Step 6: Add the UI under COLOR MIX**

```swift
    private var splitToneSection: some View {
        VStack(alignment: .leading, spacing: panelTheme.spacingS) {
            Text("Shadows").font(panelTheme.labelFont)
                .foregroundStyle(panelTheme.textSecondary)
            EditSlider(label: String(localized: "Hue"), value: splitBinding(\.shadowHue),
                       range: 0...1, neutral: 0, onCommit: session.commitGesture)
            EditSlider(label: String(localized: "Saturation"),
                       value: splitBinding(\.shadowSaturation),
                       range: 0...1, neutral: 0, onCommit: session.commitGesture)

            Divider()

            Text("Highlights").font(panelTheme.labelFont)
                .foregroundStyle(panelTheme.textSecondary)
            EditSlider(label: String(localized: "Hue"), value: splitBinding(\.highlightHue),
                       range: 0...1, neutral: 0, onCommit: session.commitGesture)
            EditSlider(label: String(localized: "Saturation"),
                       value: splitBinding(\.highlightSaturation),
                       range: 0...1, neutral: 0, onCommit: session.commitGesture)

            Divider()

            EditSlider(label: String(localized: "Balance"), value: splitBinding(\.balance),
                       onCommit: session.commitGesture)
        }
    }

    private func splitBinding(_ key: WritableKeyPath<SplitToneParams, Double>)
        -> Binding<Double> {
        Binding(get: { session.draft.splitToneParams?[keyPath: key]
                        ?? SplitToneParams.neutral[keyPath: key] },
                set: { v in session.draft.setSplitTone { $0[keyPath: key] = v } })
    }
```

Add the card with `Section.splitTone` and a Reset accessory, below COLOR MIX.

- [ ] **Step 7: Run the tests and build**

Run: `xcodebuild -project Muse/Muse.xcodeproj -scheme Muse test -only-testing:MuseTests/SplitToneParamsTests -only-testing:MuseTests/EditStackCodecTests -only-testing:MuseTests/EditKernelLoadTests 2>&1 | tail -20`
Expected: PASS.

- [ ] **Step 8: Commit**

```bash
./scripts/audit-invariants.sh
git add Muse/Muse/Editing Muse/Muse/Views/Editor Muse/MuseTests/SplitToneParamsTests.swift
git commit -m "split toning: shadow/highlight tint at canonical index 9"
```

---

### Task 9: `.grain` — model, kernel, renderer, UI, consistency test

**Files:**
- Modify: `EditStack.swift`, `EditTransfer.swift`, `EditKernels.metal`, `EditKernels.swift`, `EditRenderer.swift`, `EditorView.swift`
- Test: `Muse/MuseTests/GrainParamsTests.swift` (create), `Muse/MuseTests/EditRenderConsistencyTests.swift`

**Interfaces:**
- Produces: `GrainParams` with `amount`, `size`, `roughness`; `Adjustment.grain` at index **10**; `EditKernels.grain`, `EditKernels.grainCellFraction(size:)`.

**The two hard requirements** (spec §5.3): cell size is `(1.5 + 4.5 · size) · longEdge / 4032` (C4), and the noise field is **deterministically seeded from the file's content hash** so the thumbnail, the preview and the export produce the same grain. `foundation.md:97` names grain as the thing that broke preview/export agreement in Surface.

- [ ] **Step 1: Write the failing test**

```swift
//  GrainParamsTests.swift
import XCTest
@testable import Muse

final class GrainParamsTests: XCTestCase {

    func testCanonicalIndexIsTen() {
        XCTAssertEqual(Adjustment.grain(.neutral).canonicalIndex, 10)
    }

    /// Amount is what makes grain real; size/roughness alone change nothing.
    func testAmountZeroIsNeutral() {
        var p = GrainParams.neutral
        p.size = 0.9
        p.roughness = 0.7
        XCTAssertTrue(p.isNeutral)
        p.amount = 0.2
        XCTAssertFalse(p.isNeutral)
    }

    /// C4: cell size is a fraction of the long edge, per foundation.md:92.
    /// A fixed pixel cell is exactly the bug that makes a thumbnail and an
    /// export disagree.
    func testCellFractionMatchesTheNormalizationFormula() {
        // (1.5 + 4.5 * size) / 4032
        XCTAssertEqual(EditKernels.grainCellFraction(size: 0),
                       1.5 / 4032, accuracy: 1e-9)
        XCTAssertEqual(EditKernels.grainCellFraction(size: 1),
                       6.0 / 4032, accuracy: 1e-9)
        XCTAssertEqual(EditKernels.grainCellFraction(size: 0.5),
                       3.75 / 4032, accuracy: 1e-9)
    }

    /// Determinism: the same content hash yields the same seed, a different
    /// one yields a different seed. This is what makes grid, screen and export
    /// agree instead of producing three random fields.
    func testSeedIsStableForTheSameHashAndDiffersAcrossHashes() {
        let a = GrainParams.seed(forContentHash: "abc123")
        let b = GrainParams.seed(forContentHash: "abc123")
        let c = GrainParams.seed(forContentHash: "def456")
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
    }
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `xcodebuild -project Muse/Muse.xcodeproj -scheme Muse test -only-testing:MuseTests/GrainParamsTests 2>&1 | tail -20`

- [ ] **Step 3: Add the params**

```swift
/// Film grain. `amount` is the only field that makes it real — size and
/// roughness shape a grain that isn't there otherwise.
nonisolated struct GrainParams: Codable, Equatable, Sendable {
    var amount: Double = 0            // 0…1
    var size: Double = 0.5            // 0…1
    var roughness: Double = 0.5       // 0…1

    static let neutral = GrainParams()

    var isNeutral: Bool { amount == 0 }

    func clamped() -> GrainParams {
        GrainParams(amount: min(max(amount, 0), 1),
                    size: min(max(size, 0), 1),
                    roughness: min(max(roughness, 0), 1))
    }

    /// Deterministic per-photo seed. The SAME photo must grain identically at
    /// thumbnail, screen and export — `foundation.md:97` names this as the
    /// thing that broke preview/export agreement in Surface, and Muse cannot
    /// dodge it because the grid IS the product.
    static func seed(forContentHash hash: String) -> Float {
        Float(SeededRandom.fnv1a(hash) % 100_000) / 100_000
    }
}
```

If `SeededRandom.fnv1a` is `private`, relax it to internal and note why in a comment.

Append `case grain(GrainParams)` at `canonicalIndex` **10** with all the same branches as Tasks 5 and 8, plus `grainParams`, `setGrain`, and `AdjustmentGroup.grain`.

- [ ] **Step 4: Add the cell-size constant**

In `EditKernels.swift`:

```swift
    /// Grain cell size as a LONG-EDGE FRACTION — `(1.5 + 4.5·size) · longEdge / 4032`,
    /// the normalization carried over from Surface (foundation.md:92). Never a
    /// pixel constant: that is what makes a thumbnail and an export disagree.
    static func grainCellFraction(size: Double) -> CGFloat {
        CGFloat(1.5 + 4.5 * min(max(size, 0), 1)) / 4032
    }

    static let grain: CIColorKernel? = load("grain")
```

- [ ] **Step 5: Add the Metal kernel**

```metal
// Film grain. Value noise on a cell lattice whose size is passed in as a
// PIXEL count already resolved from the long-edge fraction, so the same photo
// grains identically at thumbnail, screen and export. `seed` is derived from
// the file's content hash — never from time or position alone.
static inline float grainHash(float2 p, float seed) {
    float h = dot(p, float2(127.1, 311.7)) + seed * 43.7;
    return fract(sin(h) * 43758.5453123);
}

extern "C" [[stitchable]] float4 grain(coreimage::sample_t s, coreimage::destination dest,
                                       float amount, float cellPx, float roughness,
                                       float seed) {
    float2 p = dest.coord() / max(cellPx, 1.0);
    float2 i = floor(p);
    float2 f = fract(p);
    // Bilinear value noise — smoother than raw per-cell noise, which reads as
    // digital blocks rather than film.
    float a = grainHash(i, seed);
    float b = grainHash(i + float2(1.0, 0.0), seed);
    float c = grainHash(i + float2(0.0, 1.0), seed);
    float d = grainHash(i + float2(1.0, 1.0), seed);
    float2 u = f * f * (3.0 - 2.0 * f);
    float n = mix(mix(a, b, u.x), mix(c, d, u.x), u.y);

    // Roughness sharpens the noise toward its extremes.
    n = mix(n, step(0.5, n), roughness);
    float delta = (n - 0.5) * amount * 0.5;

    // Grain is strongest in the midtones and fades in deep shadow and clipped
    // highlight, which is how film behaves.
    float y = clamp(dot(s.rgb, float3(0.2126, 0.7152, 0.0722)), 0.0, 1.0);
    float weight = 1.0 - fabs(y * 2.0 - 1.0);
    return float4(s.rgb + delta * weight, s.a);
}
```

- [ ] **Step 6: Call it LAST**

In `EditRenderer.apply`, after the vignette block — grain is the final stage:

```swift
        if let grain = stack.grainParams, !grain.isNeutral {
            current = applyGrain(grain.clamped(), to: current,
                                 sourceLongEdge: radiusScale, seed: grainSeed)
        }
```

`grainSeed` comes from the content hash the renderer already resolves for the file; thread it in from the caller, defaulting to `0` when unavailable.

```swift
    private static func applyGrain(_ p: GrainParams, to image: CIImage,
                                   sourceLongEdge: CGFloat, seed: Float) -> CIImage {
        guard let kernel = EditKernels.grain else { return image }
        let cellPx = max(1, EditKernels.grainCellFraction(size: p.size) * sourceLongEdge)
        return kernel.apply(extent: image.extent, arguments: [
            image, Float(p.amount), Float(cellPx), Float(p.roughness), seed,
        ]) ?? image
    }
```

- [ ] **Step 7: Add the sliders to the EFFECTS card**

In `effectsSection` (Task 2), after the vignette sliders:

```swift
            Divider()

            EditSlider(label: String(localized: "Grain"),
                       value: grainBinding(\.amount), range: 0...1, neutral: 0,
                       onCommit: session.commitGesture)
            EditSlider(label: String(localized: "Grain Size"),
                       value: grainBinding(\.size), range: 0...1, neutral: 0.5,
                       onCommit: session.commitGesture)
            EditSlider(label: String(localized: "Grain Roughness"),
                       value: grainBinding(\.roughness), range: 0...1, neutral: 0.5,
                       onCommit: session.commitGesture)
```

```swift
    private func grainBinding(_ key: WritableKeyPath<GrainParams, Double>) -> Binding<Double> {
        Binding(get: { session.draft.grainParams?[keyPath: key]
                        ?? GrainParams.neutral[keyPath: key] },
                set: { v in session.draft.setGrain { $0[keyPath: key] = v } })
    }
```

Extend the EFFECTS Reset to clear grain too.

- [ ] **Step 8: Add the render-consistency test**

Append to `EditRenderConsistencyTests.swift`:

```swift
    /// Grain must look the SAME at thumbnail and export size. This is the
    /// specific failure Surface shipped (foundation.md:97) and the reason the
    /// cell size is a long-edge fraction rather than a pixel count.
    func testGrainAgreesAcrossResolutions() throws {
        var stack = EditStack.fresh()
        stack.setGrain { $0.amount = 0.8; $0.size = 0.5; $0.roughness = 0.5 }

        let small = try Self.renderMeanAbsDeviation(stack, maxPixel: 320)
        let large = try Self.renderMeanAbsDeviation(stack, maxPixel: 1600)

        // The grain's STRENGTH relative to the image must match within 20%
        // across a 5× resolution change. A pixel-constant cell size fails this
        // by a wide margin.
        XCTAssertEqual(small, large, accuracy: max(small, large) * 0.2)
    }
```

Implement `renderMeanAbsDeviation` as a helper in that file, following the existing render helpers there: render the stack and the neutral stack at `maxPixel`, and return the mean absolute per-pixel difference.

- [ ] **Step 9: Run the tests**

Run: `xcodebuild -project Muse/Muse.xcodeproj -scheme Muse test -only-testing:MuseTests/GrainParamsTests -only-testing:MuseTests/EditRenderConsistencyTests -only-testing:MuseTests/EditKernelLoadTests 2>&1 | tail -20`
Expected: PASS.

- [ ] **Step 10: Verify grain reaches the GRID**

Build, open a folder, edit one photo with Grain at 1.0, and look at its **tile**. The grain must be visible there, not only in the editor. If the tile is clean, the thumbnail path is not applying the stack and that is a bug to fix before committing — the grid is the product.

- [ ] **Step 11: Commit**

```bash
./scripts/audit-invariants.sh
git add Muse/Muse/Editing Muse/Muse/Views/Editor Muse/MuseTests
git commit -m "grain: deterministic, long-edge-normalized, rendered last"
```

---

# STAGE C — the crop card

Severable. Nothing in A or B depends on it.

---

### Task 10: `CropDragMath` — the pure geometry

**Files:**
- Create: `Muse/Muse/Components/CropDragMath.swift`
- Test: `Muse/MuseTests/CropDragMathTests.swift`

**Interfaces:**
- Produces:
  - `CropDragMath.Handle` (`.topLeft … .left`, 8 cases)
  - `CropDragMath.resize(_:handle:by:aspect:) -> CropRect`
  - `CropDragMath.fit(aspect:into:) -> CropRect`
  - `CropDragMath.straightenInset(degrees:aspect:) -> CropRect`
  - `CropDragMath.minimumSide = 0.05`

**Why `Components/`:** that folder is "pure UI math — all unit-tested". Surface's `CropGestureState` is the model for splitting logic out of the view.

- [ ] **Step 1: Write the failing test**

```swift
//  CropDragMathTests.swift
import XCTest
@testable import Muse

final class CropDragMathTests: XCTestCase {

    private let full = CropRect(x: 0, y: 0, w: 1, h: 1)

    func testDraggingBottomRightInwardShrinksTheRect() {
        let r = CropDragMath.resize(full, handle: .bottomRight,
                                    by: CGSize(width: -0.2, height: -0.3), aspect: nil)
        XCTAssertEqual(r.x, 0, accuracy: 1e-9)
        XCTAssertEqual(r.y, 0, accuracy: 1e-9)
        XCTAssertEqual(r.w, 0.8, accuracy: 1e-9)
        XCTAssertEqual(r.h, 0.7, accuracy: 1e-9)
    }

    func testDraggingTopLeftMovesTheOriginAndShrinks() {
        let r = CropDragMath.resize(full, handle: .topLeft,
                                    by: CGSize(width: 0.25, height: 0.1), aspect: nil)
        XCTAssertEqual(r.x, 0.25, accuracy: 1e-9)
        XCTAssertEqual(r.y, 0.1, accuracy: 1e-9)
        XCTAssertEqual(r.w, 0.75, accuracy: 1e-9)
        XCTAssertEqual(r.h, 0.9, accuracy: 1e-9)
    }

    /// The rect can never leave the image or invert.
    func testCannotDragPastTheOppositeEdge() {
        let r = CropDragMath.resize(full, handle: .bottomRight,
                                    by: CGSize(width: -5, height: -5), aspect: nil)
        XCTAssertEqual(r.w, CropDragMath.minimumSide, accuracy: 1e-9)
        XCTAssertEqual(r.h, CropDragMath.minimumSide, accuracy: 1e-9)
        XCTAssertGreaterThanOrEqual(r.x, 0)
        XCTAssertLessThanOrEqual(r.x + r.w, 1 + 1e-9)
    }

    func testCannotDragOutsideTheImage() {
        let r = CropDragMath.resize(full, handle: .topLeft,
                                    by: CGSize(width: -0.5, height: -0.5), aspect: nil)
        XCTAssertEqual(r.x, 0, accuracy: 1e-9)
        XCTAssertEqual(r.y, 0, accuracy: 1e-9)
    }

    /// A locked aspect is honoured on every drag.
    func testAspectLockIsPreserved() {
        let r = CropDragMath.resize(full, handle: .bottomRight,
                                    by: CGSize(width: -0.4, height: 0), aspect: 1.0)
        XCTAssertEqual(r.w, r.h, accuracy: 1e-6)
    }

    /// Fitting 1:1 into a 3:2 frame gives a centred square that touches the
    /// short edge.
    func testFitSquareIntoLandscapeIsCentred() {
        let r = CropDragMath.fit(aspect: 1.0, into: 1.5)
        XCTAssertEqual(r.h, 1.0, accuracy: 1e-9)
        XCTAssertEqual(r.w, 1.0 / 1.5, accuracy: 1e-6)
        XCTAssertEqual(r.x, (1 - r.w) / 2, accuracy: 1e-6)
    }

    /// Straighten auto-inset: 0° must not crop at all.
    func testZeroStraightenLeavesFullFrame() {
        let r = CropDragMath.straightenInset(degrees: 0, aspect: 1.5)
        XCTAssertEqual(r.w, 1.0, accuracy: 1e-9)
        XCTAssertEqual(r.h, 1.0, accuracy: 1e-9)
    }

    /// A rotation must inset enough that no corner leaves the source, and the
    /// result stays centred. This is what stops the transparent wedges.
    func testStraightenInsetsAndStaysCentred() {
        let r = CropDragMath.straightenInset(degrees: 10, aspect: 1.5)
        XCTAssertLessThan(r.w, 1.0)
        XCTAssertLessThan(r.h, 1.0)
        XCTAssertEqual(r.x, (1 - r.w) / 2, accuracy: 1e-6)
        XCTAssertEqual(r.y, (1 - r.h) / 2, accuracy: 1e-6)
    }

    /// Symmetric: tilting left and right cost the same area.
    func testStraightenInsetIsSymmetric() {
        let a = CropDragMath.straightenInset(degrees: 12, aspect: 1.5)
        let b = CropDragMath.straightenInset(degrees: -12, aspect: 1.5)
        XCTAssertEqual(a.w, b.w, accuracy: 1e-9)
        XCTAssertEqual(a.h, b.h, accuracy: 1e-9)
    }
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `xcodebuild -project Muse/Muse.xcodeproj -scheme Muse test -only-testing:MuseTests/CropDragMathTests 2>&1 | tail -20`

- [ ] **Step 3: Write the implementation**

```swift
//
//  CropDragMath.swift
//  Muse
//
//  Pure geometry for the crop frame — no View, no gesture state, so it is
//  unit-testable without a host. Modelled on Surface Camera's
//  `CropGestureState`, which splits the same way.
//
//  Every rect here is `CropRect`: normalized to the image, TOP-LEFT origin,
//  y down. That is the same convention `EditRenderer.applyGeometry` decodes,
//  so a value from here goes straight into `GeometryParams.crop` with no flip.
//

import Foundation
import CoreGraphics

nonisolated enum CropDragMath {

    /// The smallest fraction of either axis the frame may be dragged to.
    static let minimumSide: Double = 0.05

    enum Handle: CaseIterable {
        case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left

        var movesLeftEdge: Bool { self == .topLeft || self == .left || self == .bottomLeft }
        var movesRightEdge: Bool { self == .topRight || self == .right || self == .bottomRight }
        var movesTopEdge: Bool { self == .topLeft || self == .top || self == .topRight }
        var movesBottomEdge: Bool { self == .bottomLeft || self == .bottom || self == .bottomRight }
    }

    /// Apply a normalized drag delta to one handle. `aspect` (w/h) locks the
    /// shape when non-nil.
    static func resize(_ rect: CropRect, handle: Handle, by delta: CGSize,
                       aspect: Double?) -> CropRect {
        var minX = rect.x
        var minY = rect.y
        var maxX = rect.x + rect.w
        var maxY = rect.y + rect.h

        if handle.movesLeftEdge   { minX += Double(delta.width) }
        if handle.movesRightEdge  { maxX += Double(delta.width) }
        if handle.movesTopEdge    { minY += Double(delta.height) }
        if handle.movesBottomEdge { maxY += Double(delta.height) }

        minX = min(max(minX, 0), 1)
        minY = min(max(minY, 0), 1)
        maxX = min(max(maxX, 0), 1)
        maxY = min(max(maxY, 0), 1)

        var w = max(maxX - minX, minimumSide)
        var h = max(maxY - minY, minimumSide)

        if let aspect, aspect > 0 {
            // Honour the lock by fitting the larger of the two proposals.
            if w / h > aspect { w = h * aspect } else { h = w / aspect }
        }

        // Re-anchor to whichever edges the handle did NOT move.
        var x = handle.movesLeftEdge ? maxX - w : minX
        var y = handle.movesTopEdge ? maxY - h : minY

        w = min(w, 1); h = min(h, 1)
        x = min(max(x, 0), 1 - w)
        y = min(max(y, 0), 1 - h)

        return CropRect(x: x, y: y, w: w, h: h)
    }

    /// The largest centred rect of `aspect` (w/h) that fits an image whose own
    /// aspect is `imageAspect`.
    static func fit(aspect: Double, into imageAspect: Double) -> CropRect {
        guard aspect > 0, imageAspect > 0 else { return .full }
        var w = 1.0, h = 1.0
        if aspect > imageAspect {
            h = imageAspect / aspect            // limited by height
        } else {
            w = aspect / imageAspect            // limited by width
        }
        return CropRect(x: (1 - w) / 2, y: (1 - h) / 2, w: w, h: h)
    }

    /// The largest centred rect that stays inside the image after rotating by
    /// `degrees`. Without this, straightening leaves transparent wedges in the
    /// corners — Lightroom and Apple Photos both inset automatically, and Muse
    /// follows. This is NOT destructive: it writes a `crop` value, the original
    /// file is untouched, and returning the slider to 0 restores the full frame.
    static func straightenInset(degrees: Double, aspect: Double) -> CropRect {
        let radians = abs(degrees) * .pi / 180
        guard radians > 1e-9, aspect > 0 else { return .full }

        let c = cos(radians), s = sin(radians)
        // Largest axis-aligned rect of the SAME aspect inscribed in the rotated
        // source. Working in source-relative units where width = aspect, height = 1.
        let w0 = aspect, h0 = 1.0
        let scale = min(w0 / (w0 * c + h0 * s), h0 / (w0 * s + h0 * c))
        let w = min(1, scale)
        let h = min(1, scale)
        return CropRect(x: (1 - w) / 2, y: (1 - h) / 2, w: w, h: h)
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `xcodebuild -project Muse/Muse.xcodeproj -scheme Muse test -only-testing:MuseTests/CropDragMathTests 2>&1 | tail -20`
Expected: PASS, 9 tests.

- [ ] **Step 5: Commit**

```bash
./scripts/audit-invariants.sh
git add Muse/Muse/Components/CropDragMath.swift Muse/MuseTests/CropDragMathTests.swift
git commit -m "crop: pure drag/fit/straighten-inset geometry"
```

---

### Task 11: `CropFrameOverlay` — the one new control

**Files:**
- Create: `Muse/Muse/Views/Editor/CropFrameOverlay.swift`
- Reference: `/Users/carlostarrats/Documents/Projects/Surface Camera/App/Photo/CropFrameOverlay.swift`

**Interfaces:**
- Consumes: `CropDragMath` (Task 10), `panelTheme`.
- Produces: `CropFrameOverlay(rect:aspect:onCommit:)`.

**Port, don't copy.** Keep: eight grab targets (four corner brackets, four mid-edge bars), even-odd dimming so the discarded area reads as discarded, generous hit slop, one `onCommit` per completed drag. Change: `SC.ColorToken.captureAccent` → `panelTheme.selectionInk`; iOS gestures → macOS `DragGesture` with `.onHover` cursors.

- [ ] **Step 1: Read the reference implementation**

```bash
cat "/Users/carlostarrats/Documents/Projects/Surface Camera/App/Photo/CropFrameOverlay.swift"
```

- [ ] **Step 2: Write the port**

```swift
//
//  CropFrameOverlay.swift
//  Muse
//
//  The crop frame: an outline over the fitted photo with eight grab targets —
//  four thick corner brackets and four shorter mid-edge bars — plus a dim over
//  everything the crop discards. Dragging a handle resizes the window; the
//  photo itself never moves.
//
//  Ported from Surface Camera's overlay of the same name. Its rect convention
//  is ALREADY Muse's: normalized to the displayed image, top-left origin, y
//  down — the same one `CropRect` and `EditRenderer.applyGeometry` use, so no
//  flip is needed anywhere.
//
//  All geometry here is POINTS (C7). `EditorCanvasGeometry` positions this view
//  over the image's fitted rect; nothing in this file knows about pixels.
//

import SwiftUI

struct CropFrameOverlay: View {
    @Binding var rect: CropRect
    /// Locked aspect (w/h), or nil for freeform.
    var aspect: Double?
    /// Called once per completed drag — exactly one undo step per gesture,
    /// the same rule `EditSlider` follows.
    let onCommit: () -> Void

    @Environment(\.theme) private var theme

    private let cornerArm: CGFloat = 22
    private let cornerThickness: CGFloat = 4
    private let edgeBar: CGFloat = 30
    private let hairline: CGFloat = 1
    /// The drawn marks are thin; the grab area is not.
    private let hitSlop: CGFloat = 22

    @State private var dragStart: CropRect?

    var body: some View {
        GeometryReader { geo in
            let frame = pointFrame(in: geo.size)
            ZStack(alignment: .topLeading) {
                dimming(frame: frame, in: geo.size)
                Rectangle()
                    .strokeBorder(theme.selectionInk.opacity(0.9), lineWidth: hairline)
                    .frame(width: frame.width, height: frame.height)
                    .offset(x: frame.minX, y: frame.minY)
                    .allowsHitTesting(false)
                thirdsGuides(frame: frame)
                marks(frame: frame)
                handles(frame: frame, bounds: geo.size)
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
        }
    }

    private func pointFrame(in size: CGSize) -> CGRect {
        CGRect(x: rect.x * size.width, y: rect.y * size.height,
               width: rect.w * size.width, height: rect.h * size.height)
    }

    /// Everything OUTSIDE the window, dimmed — the kept area is never darkened,
    /// so at full frame this paints nothing at all.
    private func dimming(frame: CGRect, in size: CGSize) -> some View {
        Path { p in
            p.addRect(CGRect(origin: .zero, size: size))
            p.addRect(frame)
        }
        .fill(Color.black.opacity(0.55), style: FillStyle(eoFill: true))
        .allowsHitTesting(false)
    }

    /// Rule-of-thirds guides, the standard framing aid.
    private func thirdsGuides(frame: CGRect) -> some View {
        Path { p in
            for i in 1...2 {
                let fx = frame.minX + frame.width * CGFloat(i) / 3
                p.move(to: CGPoint(x: fx, y: frame.minY))
                p.addLine(to: CGPoint(x: fx, y: frame.maxY))
                let fy = frame.minY + frame.height * CGFloat(i) / 3
                p.move(to: CGPoint(x: frame.minX, y: fy))
                p.addLine(to: CGPoint(x: frame.maxX, y: fy))
            }
        }
        .stroke(Color.white.opacity(0.25), lineWidth: hairline)
        .allowsHitTesting(false)
    }

    private func marks(frame: CGRect) -> some View {
        ForEach(Array(CropDragMath.Handle.allCases.enumerated()), id: \.offset) { _, h in
            markShape(for: h, frame: frame)
                .fill(theme.selectionInk)
                .allowsHitTesting(false)
        }
    }

    private func markShape(for h: CropDragMath.Handle, frame: CGRect) -> Path {
        let c = center(of: h, in: frame)
        var p = Path()
        switch h {
        case .topLeft, .topRight, .bottomLeft, .bottomRight:
            let dx: CGFloat = h.movesLeftEdge ? 1 : -1
            let dy: CGFloat = h.movesTopEdge ? 1 : -1
            p.addRect(CGRect(x: c.x - (dx < 0 ? cornerArm : 0), y: c.y - cornerThickness / 2,
                             width: cornerArm, height: cornerThickness))
            p.addRect(CGRect(x: c.x - cornerThickness / 2, y: c.y - (dy < 0 ? cornerArm : 0),
                             width: cornerThickness, height: cornerArm))
        case .top, .bottom:
            p.addRect(CGRect(x: c.x - edgeBar / 2, y: c.y - cornerThickness / 2,
                             width: edgeBar, height: cornerThickness))
        case .left, .right:
            p.addRect(CGRect(x: c.x - cornerThickness / 2, y: c.y - edgeBar / 2,
                             width: cornerThickness, height: edgeBar))
        }
        return p
    }

    private func center(of h: CropDragMath.Handle, in f: CGRect) -> CGPoint {
        let x = h.movesLeftEdge ? f.minX : (h.movesRightEdge ? f.maxX : f.midX)
        let y = h.movesTopEdge ? f.minY : (h.movesBottomEdge ? f.maxY : f.midY)
        return CGPoint(x: x, y: y)
    }

    private func handles(frame: CGRect, bounds: CGSize) -> some View {
        ForEach(Array(CropDragMath.Handle.allCases.enumerated()), id: \.offset) { _, h in
            let c = center(of: h, in: frame)
            Color.clear
                .contentShape(Rectangle())
                .frame(width: hitSlop * 2, height: hitSlop * 2)
                .offset(x: c.x - hitSlop, y: c.y - hitSlop)
                .onHover { inside in
                    if inside { NSCursor.crosshair.push() } else { NSCursor.pop() }
                }
                .gesture(
                    DragGesture(minimumDistance: 1)
                        .onChanged { value in
                            let start = dragStart ?? rect
                            if dragStart == nil { dragStart = rect }
                            let delta = CGSize(
                                width: value.translation.width / max(bounds.width, 1),
                                height: value.translation.height / max(bounds.height, 1))
                            rect = CropDragMath.resize(start, handle: h,
                                                       by: delta, aspect: aspect)
                        }
                        .onEnded { _ in
                            dragStart = nil
                            onCommit()
                        })
                .accessibilityLabel(Text(String(localized: "Crop handle")))
        }
    }
}
```

- [ ] **Step 3: Build**

Run: `xcodebuild -project Muse/Muse.xcodeproj -scheme Muse -configuration Debug build 2>&1 | tail -5`
Expected: `BUILD SUCCEEDED`. If `theme.selectionInk` doesn't exist on the editor theme, use the nearest accent the panel theme exposes and note the substitution in a comment.

- [ ] **Step 4: Commit**

```bash
./scripts/audit-invariants.sh
git add Muse/Muse/Views/Editor/CropFrameOverlay.swift
git commit -m "crop: the frame overlay, ported from Surface Camera"
```

---

### Task 12: The CROP card, aspect menu, and crop mode

**Files:**
- Modify: `Muse/Muse/Views/Editor/EditSession.swift` (crop mode + pending rect)
- Modify: `Muse/Muse/Views/Editor/EditorView.swift` (the card)
- Modify: `Muse/Muse/Views/Editor/EditCanvasView.swift` (host the overlay)
- Create: `Muse/Muse/Views/Editor/CropAspectPreset.swift`
- Test: `Muse/MuseTests/CropAspectPresetTests.swift`

**Interfaces:**
- Consumes: `CropDragMath`, `CropFrameOverlay`, `SocialPreset.nameKey`.
- Produces: `CropAspectPreset` (id, label, ratio); `EditSession.cropMode: Bool`, `EditSession.pendingCrop: CropRect?`.

- [ ] **Step 1: Write the failing test**

```swift
//  CropAspectPresetTests.swift
import XCTest
@testable import Muse

final class CropAspectPresetTests: XCTestCase {

    func testOriginalAndFreeformCarryNoRatio() {
        XCTAssertNil(CropAspectPreset.original.ratio)
        XCTAssertNil(CropAspectPreset.freeform.ratio)
    }

    func testRatiosAreCorrect() {
        XCTAssertEqual(CropAspectPreset.square.ratio, 1.0)
        XCTAssertEqual(CropAspectPreset.igPost.ratio!, 4.0 / 5.0, accuracy: 1e-9)
        XCTAssertEqual(CropAspectPreset.story.ratio!, 9.0 / 16.0, accuracy: 1e-9)
        XCTAssertEqual(CropAspectPreset.print4x6.ratio!, 3.0 / 2.0, accuracy: 1e-9)
        XCTAssertEqual(CropAspectPreset.print8x10.ratio!, 5.0 / 4.0, accuracy: 1e-9)
        XCTAssertEqual(CropAspectPreset.cameraDefault.ratio!, 4.0 / 3.0, accuracy: 1e-9)
        XCTAssertEqual(CropAspectPreset.widescreen.ratio!, 16.0 / 9.0, accuracy: 1e-9)
    }

    /// The portrait toggle swaps w:h — one entry per shape, never two.
    func testPortraitInvertsTheRatio() {
        XCTAssertEqual(CropAspectPreset.widescreen.ratio(portrait: true)!,
                       9.0 / 16.0, accuracy: 1e-9)
        XCTAssertEqual(CropAspectPreset.story.ratio(portrait: true)!,
                       16.0 / 9.0, accuracy: 1e-9)
    }

    /// Orientation is meaningless for these three, so the button disables.
    func testOrientationIsDisabledWhereItHasNoMeaning() {
        XCTAssertFalse(CropAspectPreset.original.supportsOrientation)
        XCTAssertFalse(CropAspectPreset.freeform.supportsOrientation)
        XCTAssertFalse(CropAspectPreset.square.supportsOrientation)
        XCTAssertTrue(CropAspectPreset.print4x6.supportsOrientation)
    }

    /// The two social rows share their NAME with the export card so the
    /// vocabulary can't drift. The geometry is deliberately NOT shared.
    func testSocialRowsReuseTheExportPresetNames() {
        XCTAssertEqual(CropAspectPreset.story.label,
                       String(localized: String.LocalizationValue(
                           SocialPreset.preset(id: "ig-story")!.nameKey)))
    }

    func testMenuOrderMatchesTheSpec() {
        XCTAssertEqual(CropAspectPreset.all.map(\.id),
                       ["original", "freeform", "square", "ig-post", "ig-story",
                        "print-4x6", "print-8x10", "camera-default", "widescreen"])
    }
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `xcodebuild -project Muse/Muse.xcodeproj -scheme Muse test -only-testing:MuseTests/CropAspectPresetTests 2>&1 | tail -20`

- [ ] **Step 3: Write `CropAspectPreset`**

```swift
//
//  CropAspectPreset.swift
//  Muse
//
//  The crop menu's rows. Each names BOTH a destination and a ratio, at equal
//  weight — a photographer scans for "3:2", someone posting scans for
//  "Story & Reel", and neither should have to decode the other.
//
//  The two social rows read their DISPLAY NAME from `SocialPreset` so the crop
//  menu and the export card can never drift apart. The NAME is shared, not the
//  geometry: `SocialPreset`'s four remaining entries are mostly `longEdge` with
//  no aspect at all, deliberately (SocialPreset.swift:42), and coupling to that
//  table would fight the reasoning that produced the cut from twelve to four.
//

import Foundation

struct CropAspectPreset: Identifiable, Equatable {
    let id: String
    let label: String
    /// Landscape orientation, width ÷ height. Nil = no fixed ratio.
    private let baseRatio: Double?

    var ratio: Double? { baseRatio }

    func ratio(portrait: Bool) -> Double? {
        guard let baseRatio else { return nil }
        return portrait ? 1 / baseRatio : baseRatio
    }

    /// Square, Original and Freeform have no orientation to swap.
    var supportsOrientation: Bool {
        guard let baseRatio else { return false }
        return abs(baseRatio - 1) > 1e-9
    }

    /// The ratio as the user reads it — shown beside the label, same weight.
    var ratioLabel: String {
        switch id {
        case "original":  return ""
        case "freeform":  return ""
        case "square":    return "1:1"
        case "ig-post":   return "4:5"
        case "ig-story":  return "9:16"
        case "print-4x6": return "3:2"
        case "print-8x10":return "5:4"
        case "camera-default": return "4:3"
        default:          return "16:9"
        }
    }

    private static func socialName(_ presetID: String, fallback: String) -> String {
        guard let key = SocialPreset.preset(id: presetID)?.nameKey else { return fallback }
        return String(localized: String.LocalizationValue(key))
    }

    static let original = CropAspectPreset(
        id: "original", label: String(localized: "Original"), baseRatio: nil)
    static let freeform = CropAspectPreset(
        id: "freeform", label: String(localized: "Freeform"), baseRatio: nil)
    static let square = CropAspectPreset(
        id: "square", label: String(localized: "Square"), baseRatio: 1)
    static let igPost = CropAspectPreset(
        id: "ig-post", label: socialName("instagram", fallback: String(localized: "Instagram Post")),
        baseRatio: 4.0 / 5.0)
    static let story = CropAspectPreset(
        id: "ig-story", label: socialName("ig-story", fallback: String(localized: "Story & Reel")),
        baseRatio: 9.0 / 16.0)
    static let print4x6 = CropAspectPreset(
        id: "print-4x6", label: String(localized: "Print 4×6"), baseRatio: 3.0 / 2.0)
    static let print8x10 = CropAspectPreset(
        id: "print-8x10", label: String(localized: "Print 8×10"), baseRatio: 5.0 / 4.0)
    static let cameraDefault = CropAspectPreset(
        id: "camera-default", label: String(localized: "Camera Default"), baseRatio: 4.0 / 3.0)
    static let widescreen = CropAspectPreset(
        id: "widescreen", label: String(localized: "Video / Widescreen"), baseRatio: 16.0 / 9.0)

    static let all: [CropAspectPreset] = [
        .original, .freeform, .square, .igPost, .story,
        .print4x6, .print8x10, .cameraDefault, .widescreen,
    ]
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `xcodebuild -project Muse/Muse.xcodeproj -scheme Muse test -only-testing:MuseTests/CropAspectPresetTests 2>&1 | tail -20`
Expected: PASS, 6 tests.

- [ ] **Step 5: Add crop mode to the session**

In `EditSession.swift`:

```swift
    // MARK: - Crop mode

    /// While true the canvas renders the image UNCROPPED with the frame drawn
    /// over it, so you frame against the whole picture and can pull the frame
    /// back out to reclaim area — Apple Photos' behaviour, and the trick
    /// Surface uses via `CropGeometry.withFullRect()`.
    @Published var cropMode = false
    /// The frame being dragged, committed to `draft` only on Apply.
    @Published var pendingCrop: CropRect?

    /// The stack to RENDER right now: in crop mode the crop is forced full.
    var renderStack: EditStack {
        guard cropMode else { return draft }
        var s = draft
        s.setGeometry { $0.crop = .full }
        return s
    }
```

Then route the render loop through `renderStack` instead of `draft` (one call site, in the render request).

- [ ] **Step 6: Add the CROP card**

```swift
    private var cropSection: some View {
        VStack(alignment: .leading, spacing: 2) {
            EditorToolRow(systemName: "crop",
                          label: String(localized: "Crop"),
                          isActive: session.cropMode,
                          action: {
                session.cropMode.toggle()
                session.pendingCrop = session.cropMode
                    ? (session.draft.geometryParams?.crop ?? .full) : nil
            })

            Menu {
                ForEach(CropAspectPreset.all) { p in
                    Button {
                        cropAspect = p
                        applyAspect(p)
                    } label: {
                        // Purpose AND ratio, equal weight.
                        Text(p.ratioLabel.isEmpty ? p.label : "\(p.label)   \(p.ratioLabel)")
                    }
                }
            } label: {
                Text(cropAspect.label)
            }
            .disabled(!session.cropMode)

            EditorToolRow(systemName: "rotate.right",
                          label: String(localized: "Portrait / Landscape"),
                          isEnabled: cropAspect.supportsOrientation,
                          action: { cropPortrait.toggle(); applyAspect(cropAspect) })

            Divider().padding(.vertical, 4)

            EditSlider(label: String(localized: "Straighten"),
                       value: straightenBinding, range: -45...45,
                       onCommit: session.commitGesture)

            EditorToolRow(systemName: "rotate.left",
                          label: String(localized: "Rotate Left"),
                          action: { session.draft.setGeometry { $0.quarterTurns -= 1 }
                                    session.commitGesture() })
            EditorToolRow(systemName: "rotate.right",
                          label: String(localized: "Rotate Right"),
                          action: { session.draft.setGeometry { $0.quarterTurns += 1 }
                                    session.commitGesture() })
            EditorToolRow(systemName: "arrow.left.and.right.righttriangle.left.righttriangle.right",
                          label: String(localized: "Flip Horizontal"),
                          isActive: session.draft.geometryParams?.flipH ?? false,
                          action: { session.draft.setGeometry { $0.flipH.toggle() }
                                    session.commitGesture() })
            EditorToolRow(systemName: "arrow.up.and.down.righttriangle.up.righttriangle.down",
                          label: String(localized: "Flip Vertical"),
                          isActive: session.draft.geometryParams?.flipV ?? false,
                          action: { session.draft.setGeometry { $0.flipV.toggle() }
                                    session.commitGesture() })
        }
    }
```

Add `@State private var cropAspect: CropAspectPreset = .original` and `@State private var cropPortrait = false`, plus:

```swift
    private func applyAspect(_ p: CropAspectPreset) {
        guard let ratio = p.ratio(portrait: cropPortrait) else {
            if p.id == "original" { session.pendingCrop = .full }
            return
        }
        session.pendingCrop = CropDragMath.fit(aspect: ratio, into: session.imageAspect)
    }
```

`session.imageAspect` is the source image's w/h; derive it from `originalImage?.extent` and default to 1.

- [ ] **Step 7: Add the Apply accessory**

```swift
        EditorSection(title: String(localized: "CROP"),
                      ink: ink,
                      accessory: cropApplyButton,
                      isExpanded: expansion(Section.crop)) { cropSection }
```

```swift
    /// Appears only when the pending frame differs from what is stored —
    /// `EditorSection` already renders `accessory` conditionally.
    private var cropApplyButton: AnyView? {
        guard session.cropMode,
              let pending = session.pendingCrop,
              pending != (session.draft.geometryParams?.crop ?? .full) else { return nil }
        return AnyView(EditorSmallButton(label: String(localized: "Apply"),
                                         systemName: "checkmark") {
            session.draft.setGeometry { $0.crop = pending }
            session.commitGesture()
            session.cropMode = false
            session.pendingCrop = nil
        }
        .environment(\.theme, panelTheme))
    }
```

- [ ] **Step 8: Host the overlay on the canvas**

In `EditCanvasView.swift`, overlay the frame on the image's fitted rect when `session.cropMode` is true, positioned by `EditorCanvasGeometry` in POINTS (C7):

```swift
            if session.cropMode {
                CropFrameOverlay(
                    rect: Binding(get: { session.pendingCrop ?? .full },
                                  set: { session.pendingCrop = $0 }),
                    aspect: cropAspectRatio,
                    onCommit: {})
                    .frame(width: geometry.fittedRect.width,
                           height: geometry.fittedRect.height)
                    .offset(x: geometry.fittedRect.minX, y: geometry.fittedRect.minY)
            }
```

- [ ] **Step 9: Build and verify by hand**

Run: `xcodebuild -project Muse/Muse.xcodeproj -scheme Muse -configuration Debug build 2>&1 | tail -5`

In the app: open a photo → Edit → CROP → press Crop. The frame appears over the whole photo. Drag a corner; the outside dims. Pick "Square 1:1"; the frame snaps to a centred square. Press Apply; the canvas renders cropped and crop mode ends. Re-open Crop — the whole photo is visible again with your rectangle on it. **Check the grid tile reflowed to the new aspect** (spec §6.5 — intended).

- [ ] **Step 10: Commit**

```bash
./scripts/audit-invariants.sh
git add Muse/Muse/Views/Editor Muse/MuseTests/CropAspectPresetTests.swift
git commit -m "crop: CROP card, aspect menu with purpose+ratio labels, crop mode"
```

---

### Task 13: Straighten auto-inset

**Files:**
- Modify: `Muse/Muse/Views/Editor/EditorView.swift` (the straighten binding)
- Test: `Muse/MuseTests/CropDragMathTests.swift` (already covers the math in Task 10)

**Context:** `applyGeometry` rotates then crops with no inset, so straightening at full frame leaves transparent wedges. Adobe documents that Lightroom auto-adjusts the crop to avoid empty corners; Apple Photos does the same. **Not destructive** (C5): it writes a `crop` value, the original is untouched, and returning the slider to 0 restores the full frame.

- [ ] **Step 1: Write the straighten binding with auto-inset**

```swift
    /// Straighten writes the angle AND the inset crop that keeps the photo a
    /// filled rectangle — without it, rotating leaves transparent wedges in the
    /// corners. Reversible in one gesture: double-clicking the slider returns
    /// to 0, which restores the full frame.
    private var straightenBinding: Binding<Double> {
        Binding(get: { session.draft.geometryParams?.straightenDegrees ?? 0 },
                set: { degrees in
            session.draft.setGeometry { g in
                g.straightenDegrees = degrees
                // Only auto-manage the crop while it IS the auto-inset — a
                // hand-dragged frame is the user's, and straighten must not
                // silently overwrite it.
                if degrees == 0 {
                    g.crop = .full
                } else {
                    g.crop = CropDragMath.straightenInset(degrees: degrees,
                                                          aspect: session.imageAspect)
                }
            }
        })
    }
```

- [ ] **Step 2: Build and verify by hand**

Run: `xcodebuild -project Muse/Muse.xcodeproj -scheme Muse -configuration Debug build 2>&1 | tail -5`

In the app: open a photo → Edit → CROP → drag Straighten to 10°. The photo tilts and stays a **filled rectangle** — no transparent corners. Double-click the Straighten label; it returns to 0 and the full frame comes back.

- [ ] **Step 3: Run the full unit target**

Run: `xcodebuild -project Muse/Muse.xcodeproj -scheme Muse test -only-testing:MuseTests 2>&1 | tail -15`
Expected: all green.

- [ ] **Step 4: Commit**

```bash
./scripts/audit-invariants.sh
git add Muse/Muse/Views/Editor/EditorView.swift
git commit -m "crop: straighten auto-insets so no transparent wedges appear"
```

---

### Task 14: Localization and the feature ledger

**Files:**
- Modify: `Muse/Muse/Localizable.xcstrings`
- Modify: `docs/new-build/FEATURE-LEDGER.md`
- Modify: `CLAUDE.md` (one Polish row)

- [ ] **Step 1: Export the new strings**

```bash
xcodebuild -exportLocalizations -project Muse/Muse.xcodeproj \
  -localizationPath /tmp/muse-loc -exportLanguage fr 2>&1 | tail -5
```

This write-backs every new key into the source `.xcstrings`. A plain build does NOT.

- [ ] **Step 2: Fill in the French values**

Every key added by Tasks 2, 3, 7, 8, 9, 11, 12, 13 — the card titles (EFFECTS, COLOR MIX, CROP), the slider labels, the eight HSL band names, the nine crop preset labels, Auto, Apply, and the accessibility labels. Re-run Step 1 until it reports **0 untranslated**.

- [ ] **Step 3: Update the feature ledger**

Add rows to `docs/new-build/FEATURE-LEDGER.md` for vignette, auto-tone, HSL, split toning, grain and crop — each with its automated / static / runtime state. The Runtime column doubles as the GUI test plan; record the by-hand checks from Tasks 2, 3, 7, 9, 12 and 13 there.

- [ ] **Step 4: Add the CLAUDE.md row**

One line in the implementation-status table, per the file's own "keep new rows to one line here" rule. Narrative goes in `docs/session-log.md`.

- [ ] **Step 5: Full verification**

```bash
xcodebuild -project Muse/Muse.xcodeproj -scheme Muse -configuration Release build 2>&1 | grep -c warning:
xcodebuild -project Muse/Muse.xcodeproj -scheme Muse test -only-testing:MuseTests 2>&1 | tail -15
./scripts/audit-invariants.sh
```
Expected: 0 warnings (C8), all unit tests green, audit 14/14.

- [ ] **Step 6: Commit**

```bash
git add Muse/Muse/Localizable.xcstrings docs/ CLAUDE.md
git commit -m "editor batch: localization, feature ledger, status row"
```

---

## Self-Review Notes

**Spec coverage:** §4.1 → Task 2 · §4.2 → Tasks 1, 3 · §5.1 → Tasks 5, 6, 7 · §5.2 → Task 8 · §5.3 → Task 9 · §6.1 → Task 12 · §6.2 → Task 12 · §6.3 → Task 11 · §6.4 → Tasks 12 (full-rect render), 13 (auto-inset) · §6.5 → Task 12 Step 9 (verified by hand) · §6.6 → free, no task needed · §7 → Task 4 · §8 → distributed, plus Task 14 Step 5.

**Known judgment calls the implementer should not silently "fix":**
- Grain renders in grid thumbnails on purpose (Task 9 Step 10). If it looks expensive, that is a tuning question, not a reason to drop it from previews.
- Straighten only auto-manages the crop when the crop is the auto-inset or full (Task 13). A hand-dragged frame is the user's.
- `AutoToneStats` deliberately duplicates a little of `HistogramCompute` rather than changing `HistogramData.binCount`, which three shipped consumers depend on.
