# Grid keyboard navigation + spacebar-open Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Plain ↑↓←→ move a highlighted photo (single selection follows) with the grid auto-scrolling to keep it visible, and Spacebar opens the highlighted photo in the hero viewer — replacing today's plain-arrow line-scroll, while Fn+arrow / Page keys keep their existing page-scroll behavior.

**Architecture:** Two new pure, unit-tested math components — `GridKeyboardNav` (index math for the masonry move rule) and `GridScrollReveal` (clip-view scroll math) — plus thin wiring: two `AppState+Selection` helpers reusing the existing `selectionAnchor` as the "current tile", and a targeted rewrite of `PageScrollCatcher.keyDown` that consumes plain arrows/space (via new `onArrow`/`onSpace` closures) and stops forwarding them, keeping the Fn/Page paging path untouched. `GridView` provides the closures, mapping SwiftUI layout coords to the AppKit scroll via the existing `canvasMinY`.

**Tech Stack:** Swift / SwiftUI / AppKit (`NSViewRepresentable`, `NSScrollView` clip-view animation), CoreGraphics, XCTest (`MuseTests`), Xcode 16.

## Global Constraints

- **Grid must stay virtualized.** No non-lazy container over the full file set; read the already-precomputed `frames` array and mutate selection/scroll only. (CLAUDE.md)
- **Do NOT change the Fn+arrow / Page Up/Down paging path** in `PageScrollCatcher` (`PageScrollCatcher.swift:104–105, 118–138`). Only stop forwarding PLAIN arrows and consume them + plain Space. (owner design / spec §8)
- **Keep the "forward everything else down the chain" fallback** for keys we don't own, so ⌘A Select All still reaches `AppDelegate.selectAll(_:)` and typing still reaches the search field. Do NOT add a custom Select All. (CLAUDE.md)
- **"Plain arrow" is tested against the meaningful modifier set only** — `event.modifierFlags.intersection([.command, .option, .control, .shift, .function])` — because arrow events often carry `.numericPad`. `.function` present ⇒ Fn/paging, not plain. (spec §8)
- **Spacebar opens via the exact double-click path** (`appState.selectedFile = file`; a folder tile calls `appState.openSubfolder(file.url)`). NO Quick Look. (owner design)
- **Arrow nav does NOT narrow `visibleFiles`** (it selects a single visible file), so no selection prune is required or added. (spec §11)
- **Reuse `selectionAnchor` as the current/highlighted tile** — do NOT add a new `@Published` field. (spec §5)
- **No new user-facing strings expected.** If any is added it MUST be localized (literal → `String(localized:)`; runtime-variable → `NSLocalizedString(_, comment:)` + manual `Localizable.xcstrings` key). (CLAUDE.md)
- Build: `xcodebuild -scheme Muse -project Muse/Muse.xcodeproj build`. Test: `xcodebuild -scheme Muse -project Muse/Muse.xcodeproj test`. Keep the full suite green (503+ tests).
- Pure components live in `Muse/Muse/Components/` with tests in `Muse/MuseTests/`, mirroring `MasonryGeometry`/`GridSelection`/`PageScroll`.

---

### Task 1: Pure `GridKeyboardNav` index math

**Files:**
- Create: `Muse/Muse/Components/GridKeyboardNav.swift`
- Test: `Muse/MuseTests/GridKeyboardNavTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `enum GridKeyboardNav { enum Direction { case up, down, left, right }; static func next(currentIndex: Int?, direction: Direction, frames: [CGRect], epsilon: CGFloat = 1, bandTolerance: CGFloat) -> Int? }` — used by `GridView`'s `onArrow` closure in Task 5.

The test fixture is a hand-built 2-column masonry (column width 100, spacing 0 for
easy arithmetic). Tiles (index: origin → size, all width 100):

- 0: (0, 0) 100×120   — col 0, row band top 0
- 1: (100, 0) 100×80  — col 1, row band top 0
- 2: (100, 80) 100×140 — col 1 (shorter col filled first)
- 3: (0, 120) 100×100 — col 0
- 4: (0, 220) 100×90  — col 0
- 5: (100, 220) 100×90 — col 1

Band tolerance passed as 100 (the column width) in these tests.

- [ ] **Step 1: Write the failing tests**

Create `Muse/MuseTests/GridKeyboardNavTests.swift`:

```swift
import XCTest
import CoreGraphics
@testable import Muse

final class GridKeyboardNavTests: XCTestCase {

    // 2-column masonry fixture, column width 100, spacing 0.
    private let frames: [CGRect] = [
        CGRect(x: 0,   y: 0,   width: 100, height: 120), // 0
        CGRect(x: 100, y: 0,   width: 100, height: 80),  // 1
        CGRect(x: 100, y: 80,  width: 100, height: 140), // 2
        CGRect(x: 0,   y: 120, width: 100, height: 100), // 3
        CGRect(x: 0,   y: 220, width: 100, height: 90),  // 4
        CGRect(x: 100, y: 220, width: 100, height: 90),  // 5
    ]
    private let band: CGFloat = 100

    func testNilCurrentSelectsFirstTile() {
        XCTAssertEqual(GridKeyboardNav.next(currentIndex: nil, direction: .down,
                                            frames: frames, bandTolerance: band), 0)
        XCTAssertEqual(GridKeyboardNav.next(currentIndex: nil, direction: .right,
                                            frames: frames, bandTolerance: band), 0)
    }

    func testEmptyFramesIsNoOp() {
        XCTAssertNil(GridKeyboardNav.next(currentIndex: nil, direction: .down,
                                          frames: [], bandTolerance: band))
        XCTAssertNil(GridKeyboardNav.next(currentIndex: 0, direction: .left,
                                          frames: [], bandTolerance: band))
    }

    func testRightIsNextInReadingOrder() {
        XCTAssertEqual(GridKeyboardNav.next(currentIndex: 0, direction: .right,
                                            frames: frames, bandTolerance: band), 1)
    }

    func testRightWrapsAcrossRowBoundary() {
        // index 1 → index 2 crosses from row-band top 0 into the next tile.
        XCTAssertEqual(GridKeyboardNav.next(currentIndex: 1, direction: .right,
                                            frames: frames, bandTolerance: band), 2)
    }

    func testLeftIsPreviousInReadingOrder() {
        XCTAssertEqual(GridKeyboardNav.next(currentIndex: 3, direction: .left,
                                            frames: frames, bandTolerance: band), 2)
    }

    func testRightAtLastTileIsNoOp() {
        XCTAssertNil(GridKeyboardNav.next(currentIndex: 5, direction: .right,
                                          frames: frames, bandTolerance: band))
    }

    func testLeftAtFirstTileIsNoOp() {
        XCTAssertNil(GridKeyboardNav.next(currentIndex: 0, direction: .left,
                                          frames: frames, bandTolerance: band))
    }

    func testDownPicksNearestBandThenClosestCentre() {
        // From tile 0 (top 0, midX 50): tiles strictly below are 2 (top 80),
        // 3 (top 120), 4/5 (top 220). Nearest band anchor = 80; within
        // tolerance 100 that band is {2 (top 80), 3 (top 120)}. Centres:
        // tile 2 midX 150 (|150-50|=100), tile 3 midX 50 (|50-50|=0) → tile 3.
        XCTAssertEqual(GridKeyboardNav.next(currentIndex: 0, direction: .down,
                                            frames: frames, bandTolerance: band), 3)
    }

    func testDownAtBottomRowIsNoOp() {
        // Tile 4 (top 220) — nothing has a greater minY.
        XCTAssertNil(GridKeyboardNav.next(currentIndex: 4, direction: .down,
                                          frames: frames, bandTolerance: band))
    }

    func testUpPicksNearestBandThenClosestCentre() {
        // From tile 4 (top 220, midX 50): tiles strictly above with the
        // largest minY toward it = tile 3 (top 120) and tile 2 (top 80).
        // Band anchor = 120; tolerance 100 → band {3 (120), 2 (80)}.
        // Centres: tile 3 midX 50 (0), tile 2 midX 150 (100) → tile 3.
        XCTAssertEqual(GridKeyboardNav.next(currentIndex: 4, direction: .up,
                                            frames: frames, bandTolerance: band), 3)
    }

    func testUpAtTopRowIsNoOp() {
        XCTAssertNil(GridKeyboardNav.next(currentIndex: 1, direction: .up,
                                          frames: frames, bandTolerance: band))
    }

    func testHorizontalCentreTieBreaksToLowerIndex() {
        // Both bottom tiles 4 (midX 50) and 5 (midX 150) are below tile 3
        // (midX 50, top 120) at band anchor 220. tile 4 centre distance 0 wins;
        // this asserts the closest-centre rule (not a raw tie), guarding the
        // comparator's ordering.
        XCTAssertEqual(GridKeyboardNav.next(currentIndex: 3, direction: .down,
                                            frames: frames, bandTolerance: band), 4)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild -scheme Muse -project Muse/Muse.xcodeproj test -only-testing:MuseTests/GridKeyboardNavTests 2>&1 | tail -20`
Expected: FAIL — compile error "cannot find 'GridKeyboardNav' in scope".

- [ ] **Step 3: Write the implementation**

Create `Muse/Muse/Components/GridKeyboardNav.swift`:

```swift
//
//  GridKeyboardNav.swift
//  Muse
//
//  Pure keyboard-navigation math for the grid. Given the ordered masonry frame
//  array, the current highlighted index, and an arrow direction, returns the new
//  highlighted index (or nil for a no-op). Left/Right = ±1 in reading order,
//  wrapping across row boundaries, clamped at the ends. Up/Down = the masonry
//  rule: nearest row-band in that vertical direction, then the tile closest in
//  horizontal centre. No UI — unit tested, mirroring MasonryGeometry/GridSelection.
//

import CoreGraphics

enum GridKeyboardNav {
    enum Direction { case up, down, left, right }

    /// New highlighted index after an arrow press, or nil for a no-op (empty
    /// grid; a vertical move with no tile in that direction; a horizontal move
    /// already at the first/last tile). A nil `currentIndex` selects tile 0.
    static func next(currentIndex: Int?,
                     direction: Direction,
                     frames: [CGRect],
                     epsilon: CGFloat = 1,
                     bandTolerance: CGFloat) -> Int? {
        guard !frames.isEmpty else { return nil }
        guard let cur = currentIndex, cur >= 0, cur < frames.count else {
            return 0
        }
        switch direction {
        case .left:
            return cur > 0 ? cur - 1 : nil
        case .right:
            return cur < frames.count - 1 ? cur + 1 : nil
        case .down:
            return verticalTarget(from: cur, frames: frames,
                                  epsilon: epsilon, bandTolerance: bandTolerance,
                                  below: true)
        case .up:
            return verticalTarget(from: cur, frames: frames,
                                  epsilon: epsilon, bandTolerance: bandTolerance,
                                  below: false)
        }
    }

    private static func verticalTarget(from cur: Int,
                                       frames: [CGRect],
                                       epsilon: CGFloat,
                                       bandTolerance: CGFloat,
                                       below: Bool) -> Int? {
        let curTop = frames[cur].minY
        let curMidX = frames[cur].midX

        let candidates = frames.indices.filter { i in
            i != cur && (below ? frames[i].minY > curTop + epsilon
                               : frames[i].minY < curTop - epsilon)
        }
        guard !candidates.isEmpty else { return nil }

        let bandAnchor: CGFloat = below
            ? candidates.map { frames[$0].minY }.min()!
            : candidates.map { frames[$0].minY }.max()!

        let bandMembers = candidates.filter {
            abs(frames[$0].minY - bandAnchor) <= bandTolerance
        }

        return bandMembers.min { a, b in
            let da = abs(frames[a].midX - curMidX)
            let db = abs(frames[b].midX - curMidX)
            return da == db ? a < b : da < db
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcodebuild -scheme Muse -project Muse/Muse.xcodeproj test -only-testing:MuseTests/GridKeyboardNavTests 2>&1 | tail -20`
Expected: PASS (all 12 cases).

- [ ] **Step 5: Commit**

```bash
git add Muse/Muse/Components/GridKeyboardNav.swift Muse/MuseTests/GridKeyboardNavTests.swift
git commit -m "feat: pure GridKeyboardNav masonry arrow-move math"
```

---

### Task 2: Pure `GridScrollReveal` scroll math

**Files:**
- Create: `Muse/Muse/Components/GridScrollReveal.swift`
- Test: `Muse/MuseTests/GridScrollRevealTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `enum GridScrollReveal { static func newOriginY(clipOriginY: CGFloat, viewportHeight: CGFloat, documentHeight: CGFloat, tileTopInViewport: CGFloat, tileHeight: CGFloat, margin: CGFloat) -> CGFloat }` — used by `PageScrollCatcher.scrollToReveal` in Task 4.

- [ ] **Step 1: Write the failing tests**

Create `Muse/MuseTests/GridScrollRevealTests.swift`:

```swift
import XCTest
import CoreGraphics
@testable import Muse

final class GridScrollRevealTests: XCTestCase {

    // Viewport 500 tall, document 2000 tall → maxY = 1500. margin 20.

    func testAlreadyVisibleTileDoesNotScroll() {
        // Tile top 100, height 80 → sits within [20, 480]. No change.
        let y = GridScrollReveal.newOriginY(
            clipOriginY: 300, viewportHeight: 500, documentHeight: 2000,
            tileTopInViewport: 100, tileHeight: 80, margin: 20)
        XCTAssertEqual(y, 300, accuracy: 0.001)
    }

    func testTileBelowScrollsDownSoBottomLandsAtViewportMinusMargin() {
        // Tile top 460, height 80 → bottom 540 > 480. Δ = 540 - 480 = 60.
        let y = GridScrollReveal.newOriginY(
            clipOriginY: 300, viewportHeight: 500, documentHeight: 2000,
            tileTopInViewport: 460, tileHeight: 80, margin: 20)
        XCTAssertEqual(y, 360, accuracy: 0.001)
    }

    func testTileAboveScrollsUpSoTopLandsAtMargin() {
        // Tile top -50 (above viewport). Δ = -50 - 20 = -70.
        let y = GridScrollReveal.newOriginY(
            clipOriginY: 300, viewportHeight: 500, documentHeight: 2000,
            tileTopInViewport: -50, tileHeight: 80, margin: 20)
        XCTAssertEqual(y, 230, accuracy: 0.001)
    }

    func testClampsToZeroAtTop() {
        // Small upward need but already near the very top → clamp at 0.
        let y = GridScrollReveal.newOriginY(
            clipOriginY: 10, viewportHeight: 500, documentHeight: 2000,
            tileTopInViewport: -50, tileHeight: 80, margin: 20)
        // raw = 10 + (-50 - 20) = -60 → clamped to 0.
        XCTAssertEqual(y, 0, accuracy: 0.001)
    }

    func testClampsToMaxYAtBottom() {
        // Near the bottom; requested scroll exceeds maxY 1500 → clamp.
        let y = GridScrollReveal.newOriginY(
            clipOriginY: 1490, viewportHeight: 500, documentHeight: 2000,
            tileTopInViewport: 470, tileHeight: 80, margin: 20)
        // bottom 550 > 480 → raw = 1490 + (550 - 480) = 1560 → clamp to 1500.
        XCTAssertEqual(y, 1500, accuracy: 0.001)
    }

    func testOversizedTilePinsTopNotBottom() {
        // Tile taller than the viewport: top branch wins, top → margin.
        let y = GridScrollReveal.newOriginY(
            clipOriginY: 300, viewportHeight: 500, documentHeight: 3000,
            tileTopInViewport: -30, tileHeight: 700, margin: 20)
        // top -30 < 20 → raw = 300 + (-30 - 20) = 250.
        XCTAssertEqual(y, 250, accuracy: 0.001)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild -scheme Muse -project Muse/Muse.xcodeproj test -only-testing:MuseTests/GridScrollRevealTests 2>&1 | tail -20`
Expected: FAIL — compile error "cannot find 'GridScrollReveal' in scope".

- [ ] **Step 3: Write the implementation**

Create `Muse/Muse/Components/GridScrollReveal.swift`:

```swift
//
//  GridScrollReveal.swift
//  Muse
//
//  Pure math for keyboard-driven "scroll the highlighted tile into view": given
//  the current clip-view origin, the viewport + document heights, and the tile's
//  top in viewport coordinates, compute the new clip origin so the tile is fully
//  visible with a small margin. Flipped coordinates (0 at top, growing downward),
//  matching PageScroll and the hosted scroll content. No I/O — unit tested; the
//  AppKit catcher (PageScrollCatcher) feeds it live values.
//

import CoreGraphics

enum GridScrollReveal {
    /// New clip-view origin.y so the highlighted tile is on screen with `margin`
    /// clearance. Returns `clipOriginY` unchanged when the tile is already in
    /// view. `tileTopInViewport` = the tile top relative to the viewport
    /// (canvasMinY + frames[i].minY); 0 = viewport top, negative = above it.
    static func newOriginY(clipOriginY: CGFloat,
                           viewportHeight: CGFloat,
                           documentHeight: CGFloat,
                           tileTopInViewport: CGFloat,
                           tileHeight: CGFloat,
                           margin: CGFloat) -> CGFloat {
        let maxY = max(0, documentHeight - viewportHeight)
        let top = tileTopInViewport
        let bottom = tileTopInViewport + tileHeight

        var newY = clipOriginY
        if top < margin {
            newY = clipOriginY + (top - margin)
        } else if bottom > viewportHeight - margin {
            newY = clipOriginY + (bottom - (viewportHeight - margin))
        }
        return min(maxY, max(0, newY))
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcodebuild -scheme Muse -project Muse/Muse.xcodeproj test -only-testing:MuseTests/GridScrollRevealTests 2>&1 | tail -20`
Expected: PASS (all 6 cases).

- [ ] **Step 5: Commit**

```bash
git add Muse/Muse/Components/GridScrollReveal.swift Muse/MuseTests/GridScrollRevealTests.swift
git commit -m "feat: pure GridScrollReveal clip-view reveal math"
```

---

### Task 3: `AppState+Selection` highlighted-tile helpers

**Files:**
- Modify: `Muse/Muse/Models/AppState+Selection.swift` (add two methods to the existing `extension AppState`)

**Interfaces:**
- Consumes: `visibleFiles` order, `selectionAnchor`, `selectedFiles` (all existing on `AppState`).
- Produces: `func currentKeyboardIndex(order files: [FileNode]) -> Int?` and `func keyboardSelect(path: String)` — used by `GridView`'s catcher closures in Task 5.

- [ ] **Step 1: Add the two helpers**

In `Muse/Muse/Models/AppState+Selection.swift`, inside `extension AppState`, after `effectiveSelectionURLs(fallback:)` (~L64–77), add:

```swift
    /// The index of the current highlighted tile within `files` (the grid
    /// order), derived from the selection anchor — the "current tile" for
    /// keyboard nav, deliberately distinct from the multi-select Set and already
    /// maintained on every click by GridSelection.apply. nil when nothing is
    /// highlighted yet (the first arrow then selects tile 0).
    func currentKeyboardIndex(order files: [FileNode]) -> Int? {
        guard let anchor = selectionAnchor else { return nil }
        return files.firstIndex { $0.url.standardizedFileURL.path == anchor }
    }

    /// Collapse the selection to exactly the highlighted tile and record it as
    /// the current tile. A plain arrow always yields a single-file selection;
    /// the anchor becomes the new highlight so the next arrow moves relative to
    /// it. This narrows the selection to a visible file (never widens it), so no
    /// pruning is needed.
    func keyboardSelect(path: String) {
        selectedFiles = [path]
        selectionAnchor = path
    }
```

- [ ] **Step 2: Build**

Run: `xcodebuild -scheme Muse -project Muse/Muse.xcodeproj build 2>&1 | tail -15`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Commit**

```bash
git add Muse/Muse/Models/AppState+Selection.swift
git commit -m "feat: AppState highlighted-tile helpers for grid keyboard nav"
```

---

### Task 4: `PageScrollCatcher` — consume plain arrows + space, keep Fn/Page

**Files:**
- Modify: `Muse/Muse/Views/PageScrollCatcher.swift`

**Interfaces:**
- Consumes: `GridKeyboardNav.Direction` (Task 1), `GridScrollReveal.newOriginY` (Task 2).
- Produces: on `PageScrollCatcher` — `var onArrow: (GridKeyboardNav.Direction) -> KeyboardScrollTarget?` and `var onSpace: () -> Void` initializer params; and the shared type `struct KeyboardScrollTarget { let tileTopInViewport: CGFloat; let tileHeight: CGFloat }`. Both consumed by `GridView` in Task 5.

This task rewrites `PageScrollCatcher` to: (a) add the two closures + the shared
`KeyboardScrollTarget` type; (b) add `leftArrowKey`/`rightArrowKey`/`spaceKey`
keycodes; (c) refactor `keyDown` so plain arrows navigate (and auto-scroll via
`GridScrollReveal`), plain Space opens, Fn+arrow / Page keys page exactly as
before, and every other key still forwards down the chain.

- [ ] **Step 1: Add the closures, the shared type, and wire `updateNSView`**

In `Muse/Muse/Views/PageScrollCatcher.swift`, replace the struct header + `makeNSView` + `updateNSView` (currently `PageScrollCatcher.swift:21–40`) with:

```swift
/// What `GridView` returns from `onArrow` so the catcher can auto-scroll the new
/// highlighted tile into view. `tileTopInViewport` = canvasMinY + frames[i].minY
/// (the tile top relative to the visible viewport); height is the tile's frame
/// height. nil is returned for a no-op move (edge / empty), and no scroll happens.
struct KeyboardScrollTarget {
    let tileTopInViewport: CGFloat
    let tileHeight: CGFloat
}

struct PageScrollCatcher: NSViewRepresentable {
    var isActive: () -> Bool
    /// Plain-arrow navigation: move the highlighted tile in `direction`, returning
    /// the new tile's scroll target (or nil for a no-op). GridView owns the frames.
    var onArrow: (GridKeyboardNav.Direction) -> KeyboardScrollTarget? = { _ in nil }
    /// Plain-Space open: open the highlighted tile (hero viewer / navigate-in for
    /// a folder) — the same path as double-click.
    var onSpace: () -> Void = {}

    func makeNSView(context: Context) -> CatcherView {
        let v = CatcherView()
        v.isActive = isActive
        v.onArrow = onArrow
        v.onSpace = onSpace
        v.grabFocusSoon()
        return v
    }

    func updateNSView(_ nsView: CatcherView, context: Context) {
        nsView.isActive = isActive
        // Reassign every update: these closures capture GridView's value-type
        // @State (frames, canvasMinY), so they must be refreshed after a relayout
        // or scroll — same reason `isActive` is reassigned here.
        nsView.onArrow = onArrow
        nsView.onSpace = onSpace
        // Re-claim focus when paging becomes active again (e.g. a hero viewer
        // just closed) so Page keys resume without needing a grid click.
        let active = isActive()
        if active && !nsView.lastActive {
            nsView.grabFocusSoon()
        }
        nsView.lastActive = active
    }
```

- [ ] **Step 2: Add closures + keycodes to `CatcherView`**

In the same file, update the `CatcherView` stored properties + keycode constants (currently `PageScrollCatcher.swift:42–54`). Replace:

```swift
    final class CatcherView: NSView {
        var isActive: () -> Bool = { false }
        var lastActive = false
        private var clickMonitor: Any?

        // Dedicated Page Up/Down keys (full keyboards) …
        private static let pageUpKey: UInt16 = 116
        private static let pageDownKey: UInt16 = 121
        // … and the arrow keys, which become Page Up/Down on Mac keyboards
        // without dedicated keys when pressed with Fn (reported as the arrow
        // keycode + the .function modifier).
        private static let upArrowKey: UInt16 = 126
        private static let downArrowKey: UInt16 = 125
```

with:

```swift
    final class CatcherView: NSView {
        var isActive: () -> Bool = { false }
        var onArrow: (GridKeyboardNav.Direction) -> KeyboardScrollTarget? = { _ in nil }
        var onSpace: () -> Void = {}
        var lastActive = false
        private var clickMonitor: Any?

        // Dedicated Page Up/Down keys (full keyboards) …
        private static let pageUpKey: UInt16 = 116
        private static let pageDownKey: UInt16 = 121
        // … and the arrow keys, which become Page Up/Down on Mac keyboards
        // without dedicated keys when pressed with Fn (reported as the arrow
        // keycode + the .function modifier).
        private static let upArrowKey: UInt16 = 126
        private static let downArrowKey: UInt16 = 125
        private static let leftArrowKey: UInt16 = 123
        private static let rightArrowKey: UInt16 = 124
        private static let spaceKey: UInt16 = 49
```

- [ ] **Step 3: Rewrite `keyDown` + extract `pageScroll` / `scrollToReveal`**

Replace the whole `keyDown` method (currently `PageScrollCatcher.swift:101–139`) with:

```swift
        override func keyDown(with event: NSEvent) {
            let key = event.keyCode
            // Ignore .numericPad/.capsLock: arrow events often carry .numericPad,
            // so "plain" must be measured against the meaningful modifier set only.
            let mods = event.modifierFlags.intersection(
                [.command, .option, .control, .shift, .function])
            let fn = mods.contains(.function)

            // Page Up / Page Down — dedicated keys or Fn+Up/Down. UNCHANGED.
            let isPageUp = key == Self.pageUpKey || (fn && key == Self.upArrowKey)
            let isPageDown = key == Self.pageDownKey || (fn && key == Self.downArrowKey)
            if (isPageUp || isPageDown), isActive(), let scrollView = enclosingScrollView {
                pageScroll(scrollView, pageUp: isPageUp)
                return
            }

            // Plain arrows (NO ⌘/⌥/⌃/⇧/Fn) MOVE the highlighted tile + auto-scroll.
            // This replaces the old plain-arrow line-scroll (which happened via the
            // forward-down-the-chain fallback below).
            let isArrow = key == Self.upArrowKey || key == Self.downArrowKey
                || key == Self.leftArrowKey || key == Self.rightArrowKey
            if isArrow, mods.isEmpty, isActive() {
                let direction: GridKeyboardNav.Direction
                switch key {
                case Self.upArrowKey:    direction = .up
                case Self.downArrowKey:  direction = .down
                case Self.leftArrowKey:  direction = .left
                default:                 direction = .right
                }
                if let target = onArrow(direction) {
                    scrollToReveal(target)
                }
                return  // consume — never line-scroll on a plain arrow now
            }

            // Plain Space opens the highlighted tile (hero viewer) — same as a
            // double-click. Inactive while a hero viewer covers the grid.
            if key == Self.spaceKey, mods.isEmpty, isActive() {
                onSpace()
                return
            }

            // Not ours — forward down the responder chain (letters, ⌘A Select
            // All, ⇧/⌘/⌥+arrow, and other keys) instead of dead-ending in a beep.
            if let next = nextResponder {
                next.keyDown(with: event)
            } else {
                super.keyDown(with: event)
            }
        }

        /// One-page clip-view scroll (Page Up/Down / Fn+Up/Down). Unchanged from
        /// the original keyDown body — extracted so keyDown stays readable.
        private func pageScroll(_ scrollView: NSScrollView, pageUp: Bool) {
            let clip = scrollView.contentView
            let documentHeight = scrollView.documentView?.frame.height ?? 0
            let newY = PageScroll.newOriginY(
                currentY: clip.bounds.origin.y,
                viewportHeight: clip.bounds.height,
                documentHeight: documentHeight,
                pageUp: pageUp)
            guard abs(newY - clip.bounds.origin.y) > 0.5 else {
                scrollView.flashScrollers()   // already at the edge — still show position
                return
            }
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.25
                ctx.allowsImplicitAnimation = true
                clip.animator().setBoundsOrigin(NSPoint(x: clip.bounds.origin.x, y: newY))
            }
            scrollView.reflectScrolledClipView(clip)
            scrollView.flashScrollers()
        }

        /// Auto-scroll so the newly highlighted tile is on screen, using the pure
        /// GridScrollReveal math over live clip/document values.
        private func scrollToReveal(_ target: KeyboardScrollTarget) {
            guard let scrollView = enclosingScrollView else { return }
            let clip = scrollView.contentView
            let documentHeight = scrollView.documentView?.frame.height ?? 0
            let newY = GridScrollReveal.newOriginY(
                clipOriginY: clip.bounds.origin.y,
                viewportHeight: clip.bounds.height,
                documentHeight: documentHeight,
                tileTopInViewport: target.tileTopInViewport,
                tileHeight: target.tileHeight,
                margin: 24)
            guard abs(newY - clip.bounds.origin.y) > 0.5 else { return }
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.18
                ctx.allowsImplicitAnimation = true
                clip.animator().setBoundsOrigin(NSPoint(x: clip.bounds.origin.x, y: newY))
            }
            scrollView.reflectScrolledClipView(clip)
        }
```

- [ ] **Step 4: Build**

Run: `xcodebuild -scheme Muse -project Muse/Muse.xcodeproj build 2>&1 | tail -20`
Expected: `** BUILD SUCCEEDED **`. (`onArrow`/`onSpace` default to no-ops, so the existing `GridView` call site still compiles until Task 5 wires them.)

- [ ] **Step 5: Commit**

```bash
git add Muse/Muse/Views/PageScrollCatcher.swift
git commit -m "feat: PageScrollCatcher consumes plain arrows (nav) + space (open), keeps Fn/Page"
```

---

### Task 5: Wire `GridView` — provide `onArrow` / `onSpace`

**Files:**
- Modify: `Muse/Muse/Views/GridView.swift` (the `PageScrollCatcher(...)` call, `GridView.swift:114`)

**Interfaces:**
- Consumes: `GridKeyboardNav.next(...)` (Task 1); `KeyboardScrollTarget` (Task 4); `AppState.currentKeyboardIndex(order:)` + `AppState.keyboardSelect(path:)` (Task 3); the existing `frames`/`canvasMinY` `@State` and `appState.visibleFiles`/`openSubfolder`/`selectedFile`.
- Produces: nothing for later tasks (integration).

- [ ] **Step 1: Replace the `PageScrollCatcher` call with the wired version**

In `Muse/Muse/Views/GridView.swift`, replace the existing catcher usage (`GridView.swift:113–116`):

```swift
                    // Page Up / Page Down scrolls the grid a screenful at a
                    // time. Inactive while a hero viewer covers the grid.
                    PageScrollCatcher(isActive: { appState.selectedFile == nil })
                        .frame(width: 0, height: 0)
                        .accessibilityHidden(true)
```

with:

```swift
                    // Keyboard navigation for the grid:
                    // • plain arrows MOVE the highlighted tile (+ auto-scroll),
                    // • plain Space OPENS it (hero viewer / navigate-in), same as
                    //   double-click,
                    // • Fn+arrow / Page keys page-scroll (unchanged).
                    // Inactive while a hero viewer covers the grid. The frames
                    // array is the FULL precomputed masonry (index-aligned with
                    // visibleFiles), so navigating to an off-screen tile has a
                    // valid frame with no full-set materialization — virtualization
                    // is untouched.
                    PageScrollCatcher(
                        isActive: { appState.selectedFile == nil },
                        onArrow: { direction in
                            let files = appState.visibleFiles
                            guard !files.isEmpty, !frames.isEmpty else { return nil }
                            let current = appState.currentKeyboardIndex(order: files)
                            // Band tolerance = the column width (uniform across the
                            // masonry) so a tile within one column-width of the
                            // nearest row-band top counts as that row.
                            let band = frames.first?.width ?? 1
                            guard let newIndex = GridKeyboardNav.next(
                                    currentIndex: current, direction: direction,
                                    frames: frames, bandTolerance: band),
                                  newIndex < files.count else { return nil }
                            appState.keyboardSelect(
                                path: files[newIndex].url.standardizedFileURL.path)
                            let f = frames[newIndex]
                            return KeyboardScrollTarget(
                                tileTopInViewport: canvasMinY + f.minY,
                                tileHeight: f.height)
                        },
                        onSpace: {
                            let files = appState.visibleFiles
                            guard let idx = appState.currentKeyboardIndex(order: files),
                                  idx < files.count else { return }
                            let file = files[idx]
                            // Exact double-click path: a folder navigates in, a
                            // file opens the hero viewer. NO Quick Look.
                            if file.kind == .folder {
                                appState.openSubfolder(file.url)
                            } else {
                                appState.selectedFile = file
                            }
                        })
                        .frame(width: 0, height: 0)
                        .accessibilityHidden(true)
```

- [ ] **Step 2: Build**

Run: `xcodebuild -scheme Muse -project Muse/Muse.xcodeproj build 2>&1 | tail -20`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Run the full unit suite (nothing regressed)**

Run: `xcodebuild -scheme Muse -project Muse/Muse.xcodeproj test 2>&1 | tail -15`
Expected: all tests pass (503+ plus the new `GridKeyboardNavTests` + `GridScrollRevealTests`).

- [ ] **Step 4: Manual verification in the running app** (repo rule — green tests are necessary but not sufficient)

Build & run (Cmd+R). Point Muse at a folder with enough images to overflow several screens, then verify:
1. Click a tile, press → / ← — the highlight (single selection) moves to the next / previous tile in reading order, wrapping across rows; at the very first/last tile it stays put.
2. Press ↓ / ↑ — the highlight moves to the nearest tile below / above, biased to the same horizontal position; at the bottom/top row it stays put.
3. Navigating past the visible area auto-scrolls so the highlighted tile stays on screen (top and bottom); a highlighted tile already fully visible does not scroll.
4. With nothing selected, the first arrow highlights the first tile.
5. Press Space on a highlighted image — the hero viewer opens (same as double-click); on a highlighted video the hero video player opens (no Quick Look); on a highlighted folder tile it navigates into the folder.
6. Fn+↑ / Fn+↓ (and Page Up/Down on a full keyboard) still page-scroll a screenful — unchanged.
7. Focus the search field, type a space and arrows — they edit the search text; the grid does NOT move the highlight (the catcher isn't first responder while a text field is focused).
8. ⌘A still selects all visible; ⇧+arrow does nothing new (forwarded), confirming no accidental Shift-extend.
9. Open the hero viewer, then press arrows/Space — the grid underneath does not react (the viewer owns keys); close it and grid nav resumes without needing a click.

- [ ] **Step 5: Commit**

```bash
git add Muse/Muse/Views/GridView.swift
git commit -m "feat: grid arrow-key navigation + spacebar open (hero viewer)"
```

---

### Task 6 (OPTIONAL — clearly marked): Home / End (Fn+← / Fn+→) jump to top / bottom

Owner-optional. Scroll-only (does not move the selection); jumps the grid to the
very top / bottom, mirroring the paging path. Skip entirely if not wanted — nothing
else depends on it.

**Files:**
- Modify: `Muse/Muse/Views/PageScrollCatcher.swift`

**Interfaces:**
- Consumes: nothing new (uses `PageScroll`-style clamp inline).
- Produces: nothing for later tasks.

- [ ] **Step 1: Add Home/End keycodes**

In `CatcherView` (added in Task 4 Step 2), after `spaceKey`, add:

```swift
        private static let homeKey: UInt16 = 115
        private static let endKey: UInt16 = 119
```

- [ ] **Step 2: Handle Home/End in `keyDown`**

In `keyDown` (Task 4 Step 3), immediately after the Page Up/Down `if` block and
before the plain-arrows block, insert:

```swift
            // Home / End — dedicated keys or Fn+Left/Fn+Right — jump to the very
            // top / bottom (scroll only; the highlight is unchanged).
            let isHome = key == Self.homeKey || (fn && key == Self.leftArrowKey)
            let isEnd = key == Self.endKey || (fn && key == Self.rightArrowKey)
            if (isHome || isEnd), isActive(), let scrollView = enclosingScrollView {
                let clip = scrollView.contentView
                let documentHeight = scrollView.documentView?.frame.height ?? 0
                let maxY = max(0, documentHeight - clip.bounds.height)
                let newY: CGFloat = isHome ? 0 : maxY
                guard abs(newY - clip.bounds.origin.y) > 0.5 else {
                    scrollView.flashScrollers()
                    return
                }
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.25
                    ctx.allowsImplicitAnimation = true
                    clip.animator().setBoundsOrigin(NSPoint(x: clip.bounds.origin.x, y: newY))
                }
                scrollView.reflectScrolledClipView(clip)
                scrollView.flashScrollers()
                return
            }
```

Note: `fn && key == leftArrowKey` for Home means the plain-arrow branch (which
requires `mods.isEmpty`) never captures a Fn+Left, so the two paths don't collide.

- [ ] **Step 3: Build + manual verify**

Run: `xcodebuild -scheme Muse -project Muse/Muse.xcodeproj build 2>&1 | tail -15`
Expected: `** BUILD SUCCEEDED **`. Then Cmd+R: Fn+← jumps to the top, Fn+→ jumps to the bottom; plain ← / → still move the highlight.

- [ ] **Step 4: Commit**

```bash
git add Muse/Muse/Views/PageScrollCatcher.swift
git commit -m "feat: optional Home/End (Fn+arrow) jump to top/bottom of the grid"
```

---

### Task 7: Confirm no new user-facing strings (localization gate)

**Files:**
- Inspect only: `Muse/Muse/Views/PageScrollCatcher.swift`, `Muse/Muse/Views/GridView.swift`, `Muse/Muse/Models/AppState+Selection.swift`, `Muse/Muse/Components/GridKeyboardNav.swift`, `Muse/Muse/Components/GridScrollReveal.swift`.

**Interfaces:**
- Consumes / Produces: nothing.

This feature is designed to add **no new user-facing copy** (spec §9): space-open
reuses the tile's existing default `.accessibilityAction` + localized hint, and
arrow-move's VoiceOver parallel is native tile-element navigation.

- [ ] **Step 1: Verify no new visible strings were introduced**

Run:
```bash
cd "/Users/carlostarrats/Documents/Projects/Muse/Muse App"
grep -nE 'Text\("|Button\("|\.help\(|\.accessibilityLabel\(|String\(localized' \
  Muse/Muse/Components/GridKeyboardNav.swift \
  Muse/Muse/Components/GridScrollReveal.swift \
  Muse/Muse/Views/PageScrollCatcher.swift \
  Muse/Muse/Models/AppState+Selection.swift
```
Expected: no new string literals from this feature (the components are pure math;
the catcher/AppState changes add only closures + math). If the grep surfaces a NEW
user-facing literal you added, wrap it per CLAUDE.md (`String(localized:)` for a
literal; `NSLocalizedString(_, comment:)` + a manual `Localizable.xcstrings` key for
a runtime-variable string) and add the `fr` translation before proceeding.

- [ ] **Step 2: Final full-suite run**

Run: `xcodebuild -scheme Muse -project Muse/Muse.xcodeproj test 2>&1 | tail -15`
Expected: green.

- [ ] **Step 3: Commit (only if Step 1 required a wrap; otherwise skip)**

```bash
git add Muse/Muse/Localizable.xcstrings
git commit -m "i18n: French strings for grid keyboard nav (if any were added)"
```

---

## Self-Review

**1. Spec coverage:**
- Pure masonry nav-math component + exact rules (left/right ±1 wrap+clamp; up/down nearest-band then closest centre; nil no-op) → Task 1 (`GridKeyboardNav`) with a fixture covering every direction, wrap, edge no-ops, band tie-break. ✅ (spec §3)
- Highlighted-tile state distinct from multi-select, reusing `selectionAnchor` → Task 3 (`currentKeyboardIndex` / `keyboardSelect`). ✅ (spec §5)
- Scroll-to-visible via clip-view + `canvasMinY` bridge, pure reveal math → Task 2 (`GridScrollReveal`) + Task 4 (`scrollToReveal`) + Task 5 (`tileTopInViewport = canvasMinY + f.minY`). ✅ (spec §4, §6)
- Spacebar-open via exact double-click path, no Quick Look, folder navigates in → Task 4 (`onSpace` plumbing) + Task 5 (`selectedFile` / `openSubfolder`). ✅ (spec §7)
- PageScrollCatcher change: stop forwarding plain arrows, consume plain space, KEEP Fn/Page → Task 4 (keyDown rewrite; `pageScroll` extracted unchanged; plain-vs-Fn via meaningful-modifier intersection). ✅ (spec §8)
- Accessibility + localization (parallel action already exists; no new strings) → §9 + Task 7. ✅
- Virtualization safety (full frames array, no non-lazy container) → Task 5 comment + spec §10. ✅
- Invariants (no narrow→no prune; ⌘A intact; text-field focus) → Task 5 Step 4 verification 7–8; Global Constraints. ✅ (spec §11)
- Out-of-scope: no Shift-extend (⇧+arrow forwarded) → Global Constraints + Task 5 verify 8. ✅
- Optional Home/End → Task 6, clearly marked optional. ✅

**2. Placeholder scan:** none — every code step shows full code; every command has expected output. ✅

**3. Type consistency:**
- `GridKeyboardNav.next(currentIndex:direction:frames:epsilon:bandTolerance:) -> Int?` defined Task 1, called Task 5 with `bandTolerance: frames.first?.width ?? 1`. ✅
- `GridScrollReveal.newOriginY(clipOriginY:viewportHeight:documentHeight:tileTopInViewport:tileHeight:margin:) -> CGFloat` defined Task 2, called Task 4 `scrollToReveal`. ✅
- `KeyboardScrollTarget { tileTopInViewport; tileHeight }` defined Task 4, constructed Task 5, consumed Task 4 `scrollToReveal`. ✅
- `currentKeyboardIndex(order:) -> Int?` / `keyboardSelect(path:)` defined Task 3, called Task 5 (`onArrow`, `onSpace`). ✅
- `onArrow: (GridKeyboardNav.Direction) -> KeyboardScrollTarget?` / `onSpace: () -> Void` params defined Task 4, supplied Task 5. ✅
```
