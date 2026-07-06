# Grid keyboard navigation + spacebar-open — design spec

**Date:** 2026-07-06
**Branch context:** off `feat/next-115` (clean, `main`-equivalent)
**Source:** `docs/perf-and-feature-review-2026-07-03.md`, Part 2 item 2
("Grid keyboard nav + spacebar open", ✅ APPROVED) — binding owner design.
**Scope:** one self-contained interaction change in the grid. Plain arrow keys
move a highlighted photo (single selection follows) with auto-scroll; Spacebar
opens the highlighted photo in the hero viewer. Fn+arrow / Page keys keep their
existing page-scroll behavior unchanged.

No new AI/tag/collection semantics; no new dependency; no network. Two new pure,
unit-tested math components; a targeted rewrite of `PageScrollCatcher.keyDown`;
thin wiring in `GridView` + `AppState+Selection`.

---

## 1. Problem / current behavior

Today the grid has **no arrow-key cell navigation and no spacebar-open**. Keyboard
interaction with the grid is limited to page scrolling.

`PageScrollCatcher` is an invisible 0×0 `NSViewRepresentable` placed inside the
grid's scroll content (`GridView.swift:114`, `PageScrollCatcher(isActive: { appState.selectedFile == nil })`).
It claims first responder when the grid appears and reclaims it on a click inside
the scroll view, so keys route to it whenever no text field (the search box) is
focused. Its `keyDown` (`PageScrollCatcher.swift:101–139`) does exactly two things:

- **Page Up / Page Down** — dedicated keys (`pageUpKey = 116`, `pageDownKey = 121`)
  OR `Fn`+Up/Down (arrow keycode + `.function` modifier), detected at
  `PageScrollCatcher.swift:104–105`. It scrolls the enclosing `NSScrollView`'s
  clip view by one page using the pure `PageScroll.newOriginY(...)`
  (`PageScroll.swift:18–29`).
- **Everything else — including PLAIN arrow keys — is forwarded down the responder
  chain** (`PageScrollCatcher.swift:110–116`):

  ```swift
  // Not ours — forward down the responder chain instead of
  // dead-ending into a beep, so the scroll view (and others) can
  // still handle arrows and other keys.
  if let next = nextResponder {
      next.keyDown(with: event)
  } else {
      super.keyDown(with: event)
  }
  ```

  That forward is what makes a **plain ↑/↓/←/→ line-scroll the grid today**: the
  event reaches the enclosing `NSScrollView`, whose default `keyDown` line-scrolls.

The owner design **replaces** that plain-arrow line-scroll with **selection
movement**. Fn+arrow / Page keys are untouched.

### Selection model as it exists (what we build on)

- `AppState.selectedFiles: Set<String>` (`AppState.swift:170`) — the grid
  multi-selection, standardized file paths.
- `AppState.selectionAnchor: String?` (`AppState.swift:172`) — the Shift-range
  anchor, **updated on every click** by `GridSelection.apply` (`GridSelection.swift:21–39`)
  via `AppState.applyClick` (`AppState+Selection.swift:20–25`).
- `AppState.selectedFile: FileNode?` (`AppState.swift:166`) — the file **OPEN in
  the hero viewer** (distinct from `selectedFiles`). Setting it opens the viewer;
  this is exactly what double-click does (`GridView.swift:66`,
  `appState.selectedFile = file`) and what the tile's VoiceOver default action
  does (`GridView.swift:317–323`).
- `AppState.visibleFiles: [FileNode]` (`AppState+Filters.swift:35`) — the ordered
  grid contents; `selectionOrder` is its standardized-path projection
  (`AppState+Selection.swift:16–18`).
- The masonry layout array `frames: [CGRect]` (`GridView.swift:83`) is the
  **full, precomputed frame of every file** (`MasonryGeometry.compute`,
  `GridView.swift:447`), index-aligned with `visibleFiles`. Only the *views*
  (`TileView`) are windowed to the viewport (`visibleIndices`, `GridView.swift:416–426`);
  the frames themselves cover the whole set. **Navigation to an off-screen tile
  therefore has a valid frame already** — no full-set materialization needed.
- `canvasMinY: CGFloat` (`GridView.swift:89`) — the masonry canvas top measured in
  the `"gridScroll"` coordinate space named on the `ScrollView` (`GridView.swift:154–158, 183`).
  It is the tile grid's top **relative to the visible viewport** (0 at the top,
  negative as scrolled). So a tile's current viewport-Y top is exactly
  `canvasMinY + frames[i].minY`.

There is **no `ScrollViewReader` / `scrollTo` anywhere in the app** (verified: zero
matches for `ScrollViewReader`/`scrollTo`/`.scrollPosition`). Scroll-to-visible
must therefore reuse the same AppKit clip-view mechanism `PageScrollCatcher`
already uses for paging, driven by a new pure reveal-math function and the
`canvasMinY` coordinate bridge.

---

## 2. Owner decisions (binding)

- Plain **↑ ↓ ← →** move the highlighted photo; the single selection follows the
  highlight; the grid **auto-scrolls to keep the highlighted tile visible** (Apple
  Photos / Finder icon-view convention). This **replaces** today's plain-arrow
  line-scroll.
- **Fn+↑ / Fn+↓ (Page Up/Down)** = fast page scroll — the existing
  `PageScrollCatcher` paging path, **unchanged**.
- **Spacebar** opens the highlighted photo in the hero viewer — the **exact
  double-click path** (`appState.selectedFile = file`). **No Quick Look.** Video
  is already safe: the hero viewer routes video/audio through the restricted
  `AVURLAsset.noNetwork` player and no file reaches `QLPreviewView`.
- A **"current/highlighted tile"** concept, distinct from the multi-select `Set`.
- Parallel `.accessibilityAction` for space-open + arrow moves; localize any new
  strings.
- **Out of scope (YAGNI):** no Shift-extend keyboard selection.

### Resolved masonry navigation rule (owner delegated to spec — implement exactly)

Defined as a **pure function** over the ordered file frames (unit-testable):

- **Left / Right** = previous / next tile in reading order (index ±1 over the
  ordered `visibleFiles`), wrapping across row boundaries. At the very first tile,
  Left is a no-op; at the very last tile, Right is a no-op (no global wrap).
- **Down** = among tiles strictly below the current tile (`frame.minY` greater than
  the current tile's, beyond a small epsilon), pick the **nearest row-band**
  (smallest such `minY`), collect the tiles whose `minY` is within a **band
  tolerance** of that smallest, then within that band pick the tile minimizing
  `|tile.midX − current.midX|`. **Up** = symmetric over tiles strictly above
  (largest `minY` below the current top). If no tile exists in the target
  direction, the highlight **stays put (no vertical wrap)**.
- The highlighted index maps to a **single-file selection**: a plain arrow sets the
  selection `Set` to exactly that one file AND records it as the current tile.

Masonry nuance (accepted, per the literal rule): because rows are uneven, the
"nearest row-band below" is chosen purely by smallest `minY > current.minY`. A tile
in an adjacent, shorter column that begins only slightly below the current tile's
top can be that nearest band. This is deterministic and testable; it is the
accepted behavior, not a bug.

---

## 3. The pure nav-math component — `GridKeyboardNav`

New file `Muse/Muse/Components/GridKeyboardNav.swift`. Pure, no UI, no `AppState`,
unit-tested exactly like `MasonryGeometry` / `GridSelection`.

```swift
import CoreGraphics

enum GridKeyboardNav {
    enum Direction { case up, down, left, right }

    /// New highlighted index after an arrow press, or nil for a no-op
    /// (empty grid, or a vertical move with no tile in that direction, or a
    /// horizontal move already at the first/last tile).
    ///
    /// - currentIndex: the current highlighted index, or nil when nothing is
    ///   highlighted yet (the first arrow press then selects tile 0).
    /// - frames: the full masonry frame array (index-aligned with visibleFiles).
    ///   Every frame shares the same width (the column width).
    /// - epsilon: minimum vertical separation to count a tile as strictly
    ///   above/below the current one.
    /// - bandTolerance: how close (in points) a below/above tile's minY must be
    ///   to the nearest such minY to count as the same row band. Callers pass the
    ///   column width (a tile's own width — uniform across the masonry).
    static func next(currentIndex: Int?,
                     direction: Direction,
                     frames: [CGRect],
                     epsilon: CGFloat = 1,
                     bandTolerance: CGFloat) -> Int? {
        guard !frames.isEmpty else { return nil }
        guard let cur = currentIndex, cur >= 0, cur < frames.count else {
            // Nothing highlighted yet → the first arrow selects tile 0.
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

        // Candidate tiles strictly in the target vertical direction.
        let candidates = frames.indices.filter { i in
            i != cur && (below ? frames[i].minY > curTop + epsilon
                               : frames[i].minY < curTop - epsilon)
        }
        guard !candidates.isEmpty else { return nil }

        // Nearest row-band = the extreme minY toward the current tile.
        let bandAnchor: CGFloat = below
            ? candidates.map { frames[$0].minY }.min()!
            : candidates.map { frames[$0].minY }.max()!

        // Everything within bandTolerance of that anchor is the same band.
        let band = candidates.filter {
            abs(frames[$0].minY - bandAnchor) <= bandTolerance
        }

        // Within the band, minimize horizontal centre distance; ties → lower index.
        return band.min { a, b in
            let da = abs(frames[a].midX - curMidX)
            let db = abs(frames[b].midX - curMidX)
            return da == db ? a < b : da < db
        }
    }
}
```

Unit tests use a hand-built masonry frame fixture with known answers for every
direction, including wrap across rows, no-op at each edge, and the band-tolerance
tie-break. See the plan, Task 1.

---

## 4. The pure scroll-reveal component — `GridScrollReveal`

New file `Muse/Muse/Components/GridScrollReveal.swift`. Pure, unit-tested exactly
like `PageScroll`.

```swift
import CoreGraphics

enum GridScrollReveal {
    /// New clip-view origin.y so the highlighted tile is fully visible with a
    /// small margin. Flipped coordinates (0 at top, growing downward), matching
    /// PageScroll / the hosted scroll content. Returns the current origin
    /// unchanged when the tile is already comfortably in view.
    ///
    /// - tileTopInViewport: the tile top measured in the visible viewport
    ///   (canvasMinY + frames[i].minY); 0 = viewport top, negative = above it.
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
            // Tile top is above (or too near) the viewport top — scroll up.
            newY = clipOriginY + (top - margin)
        } else if bottom > viewportHeight - margin {
            // Tile bottom is below the viewport bottom — scroll down. (The
            // top-branch wins first, so a tile taller than the viewport pins
            // its top rather than its bottom.)
            newY = clipOriginY + (bottom - (viewportHeight - margin))
        }
        return min(maxY, max(0, newY))
    }
}
```

Reasoning: moving the clip origin by +Δ moves content up by Δ, so a tile's
viewport-Y decreases by Δ. To bring a too-high tile's top to `margin`, scroll by
`Δ = top - margin` (negative → up); to bring a too-low tile's bottom to
`viewportHeight - margin`, scroll by `Δ = bottom - (viewportHeight - margin)`.
Clamp to `[0, documentHeight - viewportHeight]`.

Unit tests in the plan, Task 2: already-visible → unchanged; below → bottom lands
at `viewportHeight - margin`; above → top lands at `margin`; clamp at 0 and maxY;
oversized tile pins the top.

---

## 5. Highlighted-tile state model (distinct from multi-select)

**We reuse the existing `selectionAnchor` as the "current/highlighted tile"
reference** rather than adding a new `@Published` field. `selectionAnchor` is
already (a) distinct from the multi-select `Set` and (b) maintained on every click
by `GridSelection.apply`. This satisfies the owner's "current tile distinct from
the multi-select Set" with no new state to keep in sync, and it means keyboard nav
continues naturally from the last mouse click.

Two thin helpers on `AppState+Selection.swift`:

```swift
/// The index of the current highlighted tile within the given grid order,
/// derived from the selection anchor. nil when nothing is highlighted yet.
func currentKeyboardIndex(order files: [FileNode]) -> Int? {
    guard let anchor = selectionAnchor else { return nil }
    return files.firstIndex { $0.url.standardizedFileURL.path == anchor }
}

/// Collapse the selection to exactly the highlighted tile and record it as the
/// current tile. A plain arrow always yields a single-file selection.
func keyboardSelect(path: String) {
    selectedFiles = [path]
    selectionAnchor = path
}
```

Because a plain arrow collapses the selection to the one highlighted file, the
**existing selection ring** (`TileView`, `GridView.swift:601–603, 688–714`) is the
on-screen highlight — no separate focus decoration is added. After a Cmd-click
multi-select, the anchor is the last-touched tile, so the first arrow moves
relative to it and collapses to a single selection (standard Finder behavior).

---

## 6. Scroll-to-visible

No `ScrollViewReader` exists, so we scroll the enclosing `NSScrollView`'s clip view
directly — the same mechanism `PageScrollCatcher` already uses for paging
(`PageScrollCatcher.swift:118–138`). The bridge from SwiftUI layout coordinates to
the AppKit scroll is `canvasMinY`:

1. `GridView`'s `onArrow` closure computes the new index (`GridKeyboardNav.next`),
   collapses the selection (`AppState.keyboardSelect`), and returns the new tile's
   position as `KeyboardScrollTarget(tileTopInViewport: canvasMinY + frames[i].minY, tileHeight: frames[i].height)`.
2. `PageScrollCatcher` reads live AppKit values (`clip.bounds.origin.y`,
   `clip.bounds.height`, `documentView.frame.height`), calls
   `GridScrollReveal.newOriginY(...)`, and animates `clip.animator().setBoundsOrigin`
   only when the delta exceeds 0.5pt (tile already visible → no scroll, selection
   still moved).

A `margin` of 24pt keeps the highlighted tile off the very edge.

---

## 7. Spacebar open routing

`PageScrollCatcher` gains an `onSpace: () -> Void` closure. `GridView` wires it to
resolve the current highlighted tile and open it via the **exact double-click
path**:

```swift
onSpace: {
    let files = appState.visibleFiles
    guard let idx = appState.currentKeyboardIndex(order: files),
          idx < files.count else { return }
    let file = files[idx]
    if file.kind == .folder { appState.openSubfolder(file.url) } // matches double-click
    else { appState.selectedFile = file }                        // matches double-click
}
```

The folder branch mirrors `handleTileTap` (`GridView.swift:64–68`) and the tile's
VoiceOver default action (`GridView.swift:317–323`): a folder tile navigates in, a
file tile opens the hero viewer. No Quick Look. Space is gated by `isActive()`
(false while a hero viewer covers the grid, `GridView.swift:114`), so it can't open
a second viewer over an open one.

---

## 8. The `PageScrollCatcher` change

**Keep unchanged:** the Page Up / Page Down and Fn+Up/Down paging path
(`PageScrollCatcher.swift:104–105, 118–138`); the first-responder claim + click
monitor; the `isActive` gate; the "forward everything else down the chain"
fallback for keys we don't own (so ⌘A Select All still reaches the responder chain
/ `AppDelegate.selectAll`, and typing still reaches the search field).

**Change:** stop forwarding **plain** arrows; instead consume them for navigation,
and consume plain Space for open. New closures `onArrow`/`onSpace` and a shared
`KeyboardScrollTarget` type. New keycodes `leftArrowKey = 123`, `rightArrowKey = 124`,
`spaceKey = 49`.

**Plain vs Fn vs modified — the load-bearing distinction.** macOS arrow-key events
often carry `.numericPad` (and the existing code already treats `.function` as the
Fn indicator). So "plain arrow" must be tested against the **meaningful modifier
set only**, ignoring `.numericPad`/`.capsLock`:

```swift
let mods = event.modifierFlags.intersection([.command, .option, .control, .shift, .function])
```

- `mods.contains(.function)` + Up/Down → paging (existing).
- Arrow keycode + `mods.isEmpty` → navigation (`onArrow`), consume (no line-scroll
  forward).
- Space keycode + `mods.isEmpty` → open (`onSpace`), consume.
- Anything else (letters, ⌘/⇧/⌥/⌃+arrow, ⌘A, …) → forwarded down the chain exactly
  as today. (⇧+arrow is deliberately forwarded, not consumed — leaves room for a
  future Shift-extend without breaking anything now.)

`updateNSView` must reassign `onArrow`/`onSpace` on every update (as it already
does for `isActive`), because those closures capture the value-type `@State`
(`frames`, `canvasMinY`) and must see the latest layout after a scroll. See §11.

---

## 9. Accessibility + localization

- **Space-open already has its VoiceOver parallel.** Each tile is a single a11y
  element (`GridView.swift:300`) with `.isButton` and a **default
  `.accessibilityAction` that opens** it (`GridView.swift:317–323`), plus a
  localized hint ("Opens in the viewer." / "Opens the folder.",
  `GridView.swift:324–325`). VoiceOver activation of a tile therefore reproduces
  Spacebar's effect. No new action or string is required for open.
- **Arrow-move has a built-in VoiceOver parallel.** The grid tiles are individual
  a11y elements, so VoiceOver users move focus between them with VO-navigation
  natively — the accessible equivalent of arrow-move. The mouse-only interaction
  this feature adds (plain-arrow move) is thus already reachable non-visually.
  This satisfies CLAUDE.md's "a mouse-only/modifier interaction needs a parallel
  named `.accessibilityAction`" rule; the parallel exists via tile-element
  navigation + the existing open action.
- **New user-facing strings: none.** The feature reuses existing a11y labels/hints
  and adds no new visible copy. If implementation adds any user-facing string
  (e.g. a help tooltip), it MUST be localized per CLAUDE.md (literal →
  `String(localized:)`; runtime-variable → `NSLocalizedString(_, comment:)` with a
  manual `Localizable.xcstrings` key). The plan includes an explicit "confirm no
  new strings" verification step.

---

## 10. Virtualization safety

No change to virtualization. We add **no** non-lazy container over the full file
set. Navigation reads the already-existing full `frames` array (`MasonryGeometry`
computes every frame regardless of the viewport window) and mutates the selection +
scroll offset only. Tiles remain windowed by `visibleIndices`
(`GridView.swift:416–426`); an off-screen navigated tile materializes normally once
the auto-scroll brings it into the overscan band. The masonry recompute path
(`recompute`, `GridView.swift:430–455`) is untouched. Complies with CLAUDE.md
"grid must stay virtualized."

---

## 11. Invariants preserved / risks

- **"Any input that NARROWS `visibleFiles` must prune selection."** Arrow nav does
  NOT narrow `visibleFiles`; it sets the selection to a single, currently-visible
  file. No prune is needed, and none is added. (`pruneSelectionToVisible`,
  `AppState+Selection.swift:48–59`, and the `gridFilter.didSet` path are unaffected.)
- **Edit-menu Select All / `AppDelegate` responder chain.** ⌘A is not a plain arrow
  or plain space, so it is forwarded down the chain unchanged — it still reaches
  `AppDelegate.selectAll(_:)`. We do NOT add a custom Select All.
- **Paging unchanged.** Fn+Up/Down and the dedicated Page keys keep the exact
  existing `PageScroll` behavior.
- **First responder / text fields.** The catcher only holds first responder when no
  `NSText` field is focused (`grabFocusSoon`, `PageScrollCatcher.swift:59–66`), so
  Space and arrows in the search field are never stolen.
- **Closure staleness (known, minor).** `onArrow`/`onSpace` capture the value-type
  `@State` `frames`/`canvasMinY`. `canvasMinY` updates via its
  `onChange`→`@State`→body re-eval→`updateNSView` reassignment, so after any scroll
  the closures refresh before the next discrete keypress. During a very fast
  key-repeat burst the scroll target can lag one frame and self-corrects on the
  next press. Acceptable; documented so a future reader doesn't "fix" it into a
  regression.
- **Hero-open gate.** `isActive: { appState.selectedFile == nil }` keeps arrows and
  Space inert while the hero viewer is up (its own key handling owns those keys).

---

## 12. Out of scope

- **Shift-extend keyboard selection** — explicitly YAGNI per the owner. ⇧+arrow is
  forwarded, not consumed, so the door is open later.
- **Quick Look** — never used; Space uses the hero viewer path only.
- The **optional Home/End** (Fn+←/Fn+→ jump to top/bottom) is a clearly-marked
  optional task in the plan (scroll-only), not required for the feature.
```
