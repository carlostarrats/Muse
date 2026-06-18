# Grid hover + selection redesign — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the grid tile's hover-grow and flush accent selection with a dark hover veil and a padded, mood-adaptive selection ring (blue on neutral backgrounds, black/white on colorful ones).

**Architecture:** One pure helper (`SelectionStyle`) decides the ring/tint color family from the app background color (`moodPalette.backgroundRGB`) using HSB saturation + WCAG contrast. `TileView` in `GridView.swift` consumes it: hover lays a dark veil (no scale); selection shrinks the image, reveals an app-background gap, strokes a slightly-rounded ring, and tints the image.

**Tech Stack:** SwiftUI, XCTest. Existing `MoodRGB`/`MoodPalette` (Mood.swift), `AppState.moodPalette`.

## Global Constraints

- Min macOS 14.6; SwiftUI + AppKit as already used.
- `Muse/Muse/` is a `fileSystemSynchronizedGroup` — new `.swift` files are auto-included; NO `project.pbxproj` edits needed.
- All visual magic numbers are **dev-only tunable constants**, hardcoded to final values for production. No user-facing settings, no shipped UI to expose them.
- The ring/tint rule is a **whole-grid** decision from the background mood, NOT per-image.
- Neutral backgrounds use `Color.accentColor` (today's look), exactly as the current selection does.
- Do not touch masonry packing, tile frames, virtualization, the hero open/close flight frame reporter, VoiceOver traits, drag-to-move, or double-click-to-open.
- Run the full suite with `xcodebuild -scheme Muse test`; keep it green. Build with `xcodebuild -scheme Muse build`.

---

### Task 1: `SelectionStyle` pure ring-color helper

**Files:**
- Create: `Muse/Muse/Models/SelectionStyle.swift`
- Test: `Muse/MuseTests/SelectionStyleTests.swift`

**Interfaces:**
- Consumes: `MoodRGB` (from `Muse/Muse/Models/Mood.swift` — `struct MoodRGB { var r, g, b: Double }`).
- Produces:
  - `enum SelectionAccent: Equatable { case systemBlue, black, white }`
  - `enum SelectionStyle` with:
    - `static let colorfulSaturationThreshold = 0.20`
    - `static func accent(forBackground rgb: MoodRGB) -> SelectionAccent`
    - `static func saturation(_ rgb: MoodRGB) -> Double`
    - `static func relativeLuminance(_ rgb: MoodRGB) -> Double`
    - `static func contrast(_ a: Double, _ b: Double) -> Double`

- [ ] **Step 1: Write the failing tests**

Create `Muse/MuseTests/SelectionStyleTests.swift`:

```swift
import XCTest
@testable import Muse

final class SelectionStyleTests: XCTestCase {
    private func rgb(_ r: Double, _ g: Double, _ b: Double) -> MoodRGB {
        MoodRGB(r: r, g: g, b: b)
    }

    // Neutral backgrounds (Light/Dark/Auto + near-grey Custom) → blue.
    func testNeutralBackgroundsUseSystemBlue() {
        XCTAssertEqual(SelectionStyle.accent(forBackground: rgb(0, 0, 0)), .systemBlue)
        XCTAssertEqual(SelectionStyle.accent(forBackground: rgb(1, 1, 1)), .systemBlue)
        XCTAssertEqual(SelectionStyle.accent(forBackground: rgb(0.5, 0.5, 0.5)), .systemBlue)
        // The shipped Light/Dark mood backgrounds.
        XCTAssertEqual(SelectionStyle.accent(forBackground: rgb(0.965, 0.962, 0.955)), .systemBlue)
        XCTAssertEqual(SelectionStyle.accent(forBackground: rgb(0.066, 0.066, 0.078)), .systemBlue)
        // A barely-tinted Custom near grey stays neutral.
        XCTAssertEqual(SelectionStyle.accent(forBackground: rgb(0.50, 0.48, 0.46)), .systemBlue)
    }

    // A light, colorful background → black ring (black contrasts better).
    func testLightColorfulBackgroundUsesBlack() {
        let bg = rgb(0.6, 0.9, 0.6) // light green
        XCTAssertEqual(SelectionStyle.accent(forBackground: bg), .black)
    }

    // A dark, colorful background → white ring (white contrasts better).
    func testDarkColorfulBackgroundUsesWhite() {
        let bg = rgb(0.3, 0.0, 0.4) // dark purple
        XCTAssertEqual(SelectionStyle.accent(forBackground: bg), .white)
    }

    // The chosen ring always clears WCAG AA (>= 4.5:1) on colorful backgrounds.
    func testChosenAccentClearsAAOnColorfulBackgrounds() {
        let colorful = [rgb(0.6, 0.9, 0.6), rgb(0.3, 0.0, 0.4),
                        rgb(0.0, 0.5, 0.5), rgb(0.9, 0.2, 0.2),
                        rgb(0.2, 0.2, 0.9), rgb(0.95, 0.85, 0.1)]
        for bg in colorful {
            let bgL = SelectionStyle.relativeLuminance(bg)
            let chosenL: Double
            switch SelectionStyle.accent(forBackground: bg) {
            case .white: chosenL = 1.0
            case .black: chosenL = 0.0
            case .systemBlue: XCTFail("expected black/white for \(bg)"); continue
            }
            XCTAssertGreaterThanOrEqual(
                SelectionStyle.contrast(chosenL, bgL), 4.5,
                "ring must clear AA against \(bg)")
        }
    }

    func testSaturationBasics() {
        XCTAssertEqual(SelectionStyle.saturation(rgb(0, 0, 0)), 0, accuracy: 1e-9)
        XCTAssertEqual(SelectionStyle.saturation(rgb(0.5, 0.5, 0.5)), 0, accuracy: 1e-9)
        XCTAssertEqual(SelectionStyle.saturation(rgb(1, 0, 0)), 1, accuracy: 1e-9)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `xcodebuild -scheme Muse test -only-testing:MuseTests/SelectionStyleTests 2>&1 | tail -20`
Expected: FAIL — `cannot find 'SelectionStyle' in scope` / `cannot find 'SelectionAccent' in scope`.

- [ ] **Step 3: Write the implementation**

Create `Muse/Muse/Models/SelectionStyle.swift`:

```swift
//
//  SelectionStyle.swift
//  Muse
//
//  Pure decision for the grid selection ring/tint color. Chosen from the
//  app background mood so the ring always stands out: blue on neutral
//  backgrounds, black or white on colorful ones (whichever clears WCAG AA).
//  See docs/superpowers/specs/2026-06-17-grid-selection-redesign-design.md.
//

import Foundation

enum SelectionAccent: Equatable {
    case systemBlue   // neutral background → system accent (blue) ring + tint
    case black        // colorful background, black gives more contrast
    case white        // colorful background, white gives more contrast
}

enum SelectionStyle {
    /// A Custom mood with saturation at/above this counts as "colorful";
    /// below it — and every Light/Dark/Auto mood — is neutral → blue.
    static let colorfulSaturationThreshold = 0.20

    /// The ring/tint color family for a given app background color.
    static func accent(forBackground rgb: MoodRGB) -> SelectionAccent {
        if saturation(rgb) < colorfulSaturationThreshold { return .systemBlue }
        let bg = relativeLuminance(rgb)
        // Pick whichever of white/black has the higher contrast against the
        // background. The max of the two always clears AA (4.5:1) for any
        // saturated color, so the ring is never lost into the background.
        return contrast(1.0, bg) >= contrast(bg, 0.0) ? .white : .black
    }

    /// HSB saturation: (max - min) / max, 0 when the color is black.
    static func saturation(_ rgb: MoodRGB) -> Double {
        let hi = max(rgb.r, max(rgb.g, rgb.b))
        let lo = min(rgb.r, min(rgb.g, rgb.b))
        return hi <= 0 ? 0 : (hi - lo) / hi
    }

    /// WCAG relative luminance (sRGB channels linearized).
    static func relativeLuminance(_ rgb: MoodRGB) -> Double {
        func lin(_ c: Double) -> Double {
            c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * lin(rgb.r) + 0.7152 * lin(rgb.g) + 0.0722 * lin(rgb.b)
    }

    /// WCAG contrast ratio between two relative luminances.
    static func contrast(_ a: Double, _ b: Double) -> Double {
        let hi = max(a, b), lo = min(a, b)
        return (hi + 0.05) / (lo + 0.05)
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `xcodebuild -scheme Muse test -only-testing:MuseTests/SelectionStyleTests 2>&1 | tail -20`
Expected: PASS (all 5 tests).

- [ ] **Step 5: Commit**

```bash
git add Muse/Muse/Models/SelectionStyle.swift Muse/MuseTests/SelectionStyleTests.swift
git commit -m "Add SelectionStyle: mood-adaptive selection ring color (blue / black / white)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 2: Wire the new hover + selection look into `TileView`

**Files:**
- Modify: `Muse/Muse/Views/GridView.swift` (the `TileView` struct — `body` hover block ~lines 469–471, and `imageContent` ~lines 518–550)

**Interfaces:**
- Consumes: `SelectionStyle.accent(forBackground:)` and `SelectionAccent` (Task 1); `appState.moodPalette` (`.background`, `.backgroundRGB`); existing `appState.selectedFiles` / `appState.selectedFile`.
- Produces: no new public surface — internal view changes only.

This task is view code (not unit-tested in this codebase — see CLAUDE.md "UI views aren't unit-tested"). Its deliverable is verified by a green build + the full suite staying green; the rounded-vs-square ring is tuned live afterward.

- [ ] **Step 1: Add the dev-tunable constants and `isSelected`/`ringColor` helpers to `TileView`**

In `Muse/Muse/Views/GridView.swift`, find the `TileView` state declarations:

```swift
    @State private var thumbnail: NSImage?
    @State private var hovering = false
```

Immediately AFTER those two lines, add:

```swift

    // MARK: - Selection / hover styling (dev-tunable; locked for production)
    /// Hover veil over an unselected tile (no size change).
    private static let hoverVeilOpacity = 0.12
    /// How far the image shrinks on each side when selected (reveals the gap).
    private static let selectionInset: CGFloat = 6
    /// How far the ring sits inside the tile's outer edge.
    private static let ringInset: CGFloat = 2
    /// Ring stroke thickness.
    private static let ringWidth: CGFloat = 2.5
    /// Ring corner radius. Set to 0 for a square ring.
    private static let ringCornerRadius: CGFloat = 6
    /// Tint laid over the selected (shrunken) image, in the ring's color.
    private static let selectionTintOpacity = 0.18

    /// True when this tile is multi-selected OR is the open file.
    private var isSelected: Bool {
        appState.selectedFiles.contains(file.url.standardizedFileURL.path)
            || appState.selectedFile?.id == file.id
    }

    /// Ring + tint color, decided once from the app background mood.
    private var ringColor: Color {
        switch SelectionStyle.accent(forBackground: appState.moodPalette.backgroundRGB) {
        case .systemBlue: return Color.accentColor
        case .black:      return Color.black
        case .white:      return Color.white
        }
    }
```

- [ ] **Step 2: Remove the hover scale from `body`**

Find these three lines in `TileView.body`:

```swift
        .scaleEffect(hovering ? 1.025 : 1)
        .animation(.easeOut(duration: 0.18), value: hovering)
        .onHover { hovering = $0 }
```

Replace them with (drop the scale + its animation; keep hover tracking):

```swift
        .onHover { hovering = $0 }
```

- [ ] **Step 3: Rewrite `imageContent` for the veil + padded ring + gap + tint**

Replace the entire `imageContent` computed property:

```swift
    private var imageContent: some View {
        tile
            // Every tile is square-cornered (edge-to-edge jigsaw pieces) — the
            // non-image cards' grey backing matches the photos, no rounding.
            .clipShape(Rectangle())
            .overlay {
                // Selected (multi-select) OR the open file get an accent wash +
                // border, wrapping the image area only (Finder-style; the label
                // below stays unbordered). Inside the scaleEffect so it grows
                // with the hover zoom.
                if appState.selectedFiles.contains(file.url.standardizedFileURL.path)
                    || appState.selectedFile?.id == file.id {
                    Rectangle()
                        .fill(Color.accentColor.opacity(0.22))
                        .overlay {
                            Rectangle()
                                .stroke(Color.accentColor, lineWidth: 3)
                        }
                }
            }
            .background(
                GeometryReader { proxy in
                    Color.clear
                        // Global tile frame feeds the hero open/close flight.
                        .onAppear {
                            appState.tileFrames[file.url.path] = proxy.frame(in: .global)
                        }
                        .onChange(of: proxy.frame(in: .global)) { _, f in
                            appState.tileFrames[file.url.path] = f
                        }
                }
            )
    }
```

with:

```swift
    private var imageContent: some View {
        ZStack {
            // When selected, the gap between the shrunken image and the ring
            // shows the app background (same color as the grid gutter), so the
            // image reads as lifted into the ring.
            if isSelected {
                Rectangle().fill(appState.moodPalette.background)
            }

            // The image. Square-cornered, natural aspect; shrinks inward when
            // selected to reveal the gap. The selection tint rides on top of it.
            tile
                .clipShape(Rectangle())
                .overlay {
                    if isSelected {
                        Rectangle().fill(ringColor.opacity(Self.selectionTintOpacity))
                    }
                }
                .padding(isSelected ? Self.selectionInset : 0)

            // Hover veil — unselected tiles only; a calm dark wash, no resize.
            Rectangle()
                .fill(Color.black)
                .opacity((hovering && !isSelected) ? Self.hoverVeilOpacity : 0)
                .allowsHitTesting(false)

            // The padded ring, just inside the tile's outer edge.
            if isSelected {
                RoundedRectangle(cornerRadius: Self.ringCornerRadius, style: .continuous)
                    .strokeBorder(ringColor, lineWidth: Self.ringWidth)
                    .padding(Self.ringInset)
            }
        }
        .animation(.easeOut(duration: 0.18), value: hovering)
        .animation(.easeOut(duration: 0.15), value: isSelected)
        .background(
            GeometryReader { proxy in
                Color.clear
                    // Global tile frame feeds the hero open/close flight.
                    .onAppear {
                        appState.tileFrames[file.url.path] = proxy.frame(in: .global)
                    }
                    .onChange(of: proxy.frame(in: .global)) { _, f in
                        appState.tileFrames[file.url.path] = f
                    }
            }
        )
    }
```

- [ ] **Step 4: Build to verify it compiles**

Run: `xcodebuild -scheme Muse build 2>&1 | tail -15`
Expected: `** BUILD SUCCEEDED **` (SourceKit cross-file "cannot find" noise during edits is not authoritative — only the build is).

- [ ] **Step 5: Run the full test suite to verify nothing regressed**

Run: `xcodebuild -scheme Muse test 2>&1 | tail -20`
Expected: all tests pass (the new `SelectionStyleTests` + the existing suite).

- [ ] **Step 6: Commit**

```bash
git add Muse/Muse/Views/GridView.swift
git commit -m "Grid: dark hover veil + padded mood-adaptive selection ring

Hover lays a subtle dark veil (no grow); selection shrinks the image,
reveals an app-background gap, and strokes a slightly-rounded ring tinted
blue on neutral moods or black/white on colorful ones.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 3: Live tuning pass + doc the feature

**Files:**
- Modify (as needed during tuning): `Muse/Muse/Views/GridView.swift` (the Task 2 constants only)
- Modify: `CLAUDE.md` (add a short session-log entry)

**Interfaces:** none.

- [ ] **Step 1: Run the app and review the look live**

Run the app (Cmd+R in Xcode, or `xcodebuild -scheme Muse build` then launch). Verify against the spec:
- Hover (unselected) → dark veil, NO grow.
- Click to select → image shrinks slightly (natural aspect, square corners), a background-colored gap appears, a slightly-rounded ring is drawn; a subtle tint sits over the image.
- Switch the mood to a saturated Custom color (e.g. teal/purple) → ring becomes black or white and stays clearly visible (not lost into the background). Switch to Light/Dark → ring is blue.
- Hovering an already-selected tile → keeps the selection look only (no extra veil).

- [ ] **Step 2: Tune the constants to nail it, then lock them**

Adjust only the `Self.` constants from Task 2 Step 1 (`hoverVeilOpacity`, `selectionInset`, `ringInset`, `ringWidth`, `ringCornerRadius`, `selectionTintOpacity`). If the rounded ring isn't liked, set `ringCornerRadius = 0` for a square ring. Re-run and confirm. These are the final production values — no settings UI is added.

- [ ] **Step 3: Build + full suite once more after tuning**

Run: `xcodebuild -scheme Muse build 2>&1 | tail -5` then `xcodebuild -scheme Muse test 2>&1 | tail -20`
Expected: `** BUILD SUCCEEDED **` and all tests pass.

- [ ] **Step 4: Add a CLAUDE.md session-log entry**

Add a dated entry (under the existing 2026-06-17 session logs) summarizing: hover grow → dark veil; flush accent selection → padded mood-adaptive ring (blue on neutral, black/white-by-AA on colorful Custom moods) via the pure `SelectionStyle` helper; image shrinks with natural aspect + square corners; all magic numbers are locked production constants (no settings UI). Note the new files: `Models/SelectionStyle.swift`, `MuseTests/SelectionStyleTests.swift`.

- [ ] **Step 5: Commit**

```bash
git add Muse/Muse/Views/GridView.swift CLAUDE.md
git commit -m "Grid selection: final tuning + doc the hover/selection redesign

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Self-Review

**Spec coverage:**
- Hover dark veil, no scale → Task 2 Steps 2–3. ✅
- Selection shrink (natural aspect, square corners) + bg gap + padded ring + tint → Task 2 Step 3. ✅
- Whole-grid ring color from background mood; neutral→blue, colorful→black/white by AA → Task 1 (helper + tests) + Task 2 (`ringColor`). ✅
- Selected+hover keeps selection look only → veil gated on `!isSelected` (Task 2 Step 3). ✅
- Tunable knobs are dev-only, locked for production, no settings UI → Task 2 constants + Task 3 tuning + Global Constraints. ✅
- Slightly-rounded ring with one-line square fallback → `ringCornerRadius` constant. ✅
- No layout/virtualization/hero-flight/VoiceOver/drag changes → frame reporter preserved verbatim; only image display size changes. ✅
- Unit-test the pure helper incl. AA assertion → Task 1 Step 1. ✅

**Placeholder scan:** No TBD/TODO; all code blocks complete. ✅

**Type consistency:** `SelectionAccent` cases (`systemBlue`/`black`/`white`), `SelectionStyle.accent(forBackground:)`, `relativeLuminance`, `contrast`, `saturation`, `MoodRGB(r:g:b:)`, and `moodPalette.backgroundRGB`/`.background` are used identically across Tasks 1–2. ✅
