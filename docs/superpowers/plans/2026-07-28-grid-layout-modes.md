# Grid Layout Modes Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace `ImageLayout`'s masonry + 10 fixed ratios with three meaningful modes (Columns / Rows / Grid), delete the coloured card behind photos and the Tile Background setting with it, add a spacing slider, and make EXIF orientation consistent across the three places Muse resolves an image's shape.

**Architecture:** Layout stays pure and unit-tested: Columns and Grid reuse `MasonryGeometry` (Grid feeds it a constant aspect of 1 — `UniformGridLayoutTests` already locks that this produces an aligned row-major grid), and Rows gets a new pure `JustifiedRowsGeometry` in `Components/`. On the render side, an image tile's overlays (ring, hover veil, star badge) move from the slot rect onto the drawn-photo rect by wrapping the tile's content stack in an `.aspectRatio(_, contentMode: .fit)` container — mathematically the same fit as `ViewerGeometry.fitWithin`, which is what the hero flight uses, so the two agree by construction.

**Tech Stack:** Swift 5 / SwiftUI / AppKit, Xcode 16+, XCTest. macOS 14.6 minimum. No new dependencies.

## Global Constraints

- **Spec:** `docs/superpowers/specs/2026-07-28-grid-layout-modes-design.md`. Read it before starting.
- **Grid must stay virtualized.** No custom SwiftUI `Layout`, no non-lazy container over the full file set. Geometry is precomputed into `frames` and only viewport tiles are materialized. (`CLAUDE.md` durable constraint.)
- **Hero flight geometry is diagnosed by instrumenting the running app, never by reading code.** If anything about hero open/close looks wrong, read `docs/hero-viewer-open-close-handoff.md` first.
- **Every new user-facing string must be localized.** SwiftUI text-literal positions auto-extract; anything passed as a `String` needs `String(localized:)`. See the localization rules in `CLAUDE.md`.
- **Files are never deleted, only moved to Trash.** Not touched by this work, but don't regress it.
- **No network calls.** Not touched by this work.
- **GRDB writes are async** (`try await queue.write { }`); rows insert as `var`.
- Build: `xcodebuild -project Muse/Muse.xcodeproj -scheme Muse build`
- Test: `xcodebuild -project Muse/Muse.xcodeproj -scheme Muse test`
- Single test class: append `-only-testing:MuseTests/<ClassName>`
- Run the suite in an **English** host. A French `AppleLanguages` override makes `displayName` assertions read French and fail — that is expected, not a regression.
- SourceKit "cannot find type in scope" errors during editing are noise. Verify with `xcodebuild`.
- **Task ordering keeps the build green at every commit.** Do not reorder tasks 3–5.

---

### Task 1: `JustifiedRowsGeometry` — the Rows packing

Pure, stateless, no SwiftUI. Mirrors `MasonryGeometry`'s shape so the grid can precompute frames and virtualize.

**Files:**
- Create: `Muse/Muse/Components/JustifiedRowsGeometry.swift`
- Test: `Muse/MuseTests/JustifiedRowsGeometryTests.swift`

**Interfaces:**
- Consumes: nothing (first task).
- Produces:
  - `JustifiedRowsGeometry.Item` — `{ let index: Int; let width: CGFloat }`
  - `JustifiedRowsGeometry.Row` — `{ var items: [Item]; var height: CGFloat }`
  - `JustifiedRowsGeometry.Result` — `{ var frames: [CGRect]; var totalHeight: CGFloat }`
  - `static func rows(aspects: [CGFloat], targetHeight: CGFloat, width: CGFloat, spacing: CGFloat) -> [Row]`
  - `static func compute(aspects: [CGFloat], targetHeight: CGFloat, width: CGFloat, spacing: CGFloat, captionHeight: CGFloat = 0) -> Result`
  - `static let minAspect: CGFloat` = 0.1, `static let maxAspect: CGFloat` = 10

Note for later tasks: `aspects` are **height ÷ width** (`MasonryGeometry`'s convention). `rows(...)` is consumed directly by the PDF paginator in Task 7; `compute(...)` is consumed by `GridView` in Task 3.

- [ ] **Step 1: Write the failing tests**

Create `Muse/MuseTests/JustifiedRowsGeometryTests.swift`:

```swift
import XCTest
import CoreGraphics
@testable import Muse

/// Rows mode: every row shares one height, widths follow each image's own
/// shape, and a full row spans the content width exactly. The trailing
/// partial row is deliberately NOT stretched.
final class JustifiedRowsGeometryTests: XCTestCase {

    func testEmptyInputProducesNothing() {
        let r = JustifiedRowsGeometry.compute(aspects: [], targetHeight: 200,
                                              width: 1000, spacing: 10)
        XCTAssertTrue(r.frames.isEmpty)
        XCTAssertEqual(r.totalHeight, 0)
    }

    func testZeroWidthProducesNothing() {
        let r = JustifiedRowsGeometry.compute(aspects: [1, 1], targetHeight: 200,
                                              width: 0, spacing: 10)
        XCTAssertTrue(r.frames.isEmpty)
    }

    func testFullRowSpansTheWidthExactly() {
        // Six squares at target 200 in a 1000pt width: squares are 200 wide, so
        // a row closes well before six fit — whichever row closes first must
        // span the full width.
        let aspects = [CGFloat](repeating: 1, count: 12)
        let rows = JustifiedRowsGeometry.rows(aspects: aspects, targetHeight: 200,
                                              width: 1000, spacing: 10)
        XCTAssertGreaterThan(rows.count, 1, "12 squares should need several rows")
        // Every row except the last is justified to the full width.
        for row in rows.dropLast() {
            let widths = row.items.reduce(CGFloat(0)) { $0 + $1.width }
            let gaps = CGFloat(row.items.count - 1) * 10
            XCTAssertEqual(widths + gaps, 1000, accuracy: 0.5)
        }
    }

    func testEveryItemInARowSharesOneHeight() {
        // Mixed shapes: tall, square, wide.
        let aspects: [CGFloat] = [1.5, 1.0, 0.6, 1.2, 0.8, 1.0, 1.4, 0.7]
        let r = JustifiedRowsGeometry.compute(aspects: aspects, targetHeight: 180,
                                              width: 900, spacing: 12)
        XCTAssertEqual(r.frames.count, aspects.count)
        // Group frames by their y origin — that's a row.
        let byRow = Dictionary(grouping: r.frames.indices) { i in
            (r.frames[i].minY * 10).rounded()
        }
        for (_, indices) in byRow {
            let h = r.frames[indices[0]].height
            for i in indices {
                XCTAssertEqual(r.frames[i].height, h, accuracy: 0.5)
            }
        }
    }

    func testItemWidthFollowsItsOwnAspect() {
        // A wide image (aspect 0.5 → twice as wide as tall) must be twice the
        // width of a square at the same row height.
        let r = JustifiedRowsGeometry.compute(aspects: [0.5, 1.0],
                                              targetHeight: 100,
                                              width: 1000, spacing: 0)
        XCTAssertEqual(r.frames[0].width, r.frames[1].width * 2, accuracy: 0.5)
    }

    func testTrailingPartialRowIsNotStretched() {
        // One lone wide image can't fill a row on its own without becoming a
        // full-width panorama. It must stay at the target height.
        let rows = JustifiedRowsGeometry.rows(aspects: [3.0], targetHeight: 150,
                                              width: 1000, spacing: 10)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].height, 150, accuracy: 0.5)
        // Aspect 3 (tall) at height 150 → 50 wide, nowhere near 1000.
        XCTAssertEqual(rows[0].items[0].width, 50, accuracy: 0.5)
    }

    func testExtremeAspectsAreClampedForLayout() {
        // A pathological panorama (aspect 0.001 → 1000× wider than tall) would
        // otherwise force a sub-pixel row height.
        let rows = JustifiedRowsGeometry.rows(aspects: [0.001], targetHeight: 200,
                                              width: 1000, spacing: 0)
        XCTAssertEqual(rows.count, 1)
        // Clamped to minAspect 0.1 → width = height / 0.1 = 10 × height, and the
        // row closes justified at width 1000 → height 100.
        XCTAssertEqual(rows[0].height, 100, accuracy: 0.5)
    }

    func testZeroSpacingPacksFlush() {
        let aspects = [CGFloat](repeating: 1, count: 8)
        let r = JustifiedRowsGeometry.compute(aspects: aspects, targetHeight: 200,
                                              width: 800, spacing: 0)
        // Four squares of 200 fill 800 exactly with no gaps.
        XCTAssertEqual(r.frames[0].minX, 0, accuracy: 0.5)
        XCTAssertEqual(r.frames[1].minX, 200, accuracy: 0.5)
        XCTAssertEqual(r.frames[3].maxX, 800, accuracy: 0.5)
    }

    func testCaptionHeightAddsToEveryTile() {
        let aspects = [CGFloat](repeating: 1, count: 4)
        let plain = JustifiedRowsGeometry.compute(aspects: aspects, targetHeight: 200,
                                                  width: 800, spacing: 0)
        let capped = JustifiedRowsGeometry.compute(aspects: aspects, targetHeight: 200,
                                                   width: 800, spacing: 0,
                                                   captionHeight: 18)
        XCTAssertEqual(capped.frames[0].height - plain.frames[0].height, 18,
                       accuracy: 0.5)
        XCTAssertEqual(capped.totalHeight - plain.totalHeight, 18, accuracy: 0.5)
    }

    func testNonPositiveAspectIsTreatedAsSquare() {
        let r = JustifiedRowsGeometry.compute(aspects: [0, -1], targetHeight: 100,
                                              width: 1000, spacing: 0)
        XCTAssertEqual(r.frames[0].width, r.frames[1].width, accuracy: 0.5)
    }

    func testTotalHeightHasNoTrailingSpacing() {
        let aspects = [CGFloat](repeating: 1, count: 8)
        let r = JustifiedRowsGeometry.compute(aspects: aspects, targetHeight: 200,
                                              width: 800, spacing: 10)
        let lastBottom = r.frames.map(\.maxY).max() ?? 0
        XCTAssertEqual(r.totalHeight, lastBottom, accuracy: 0.5)
    }
}
```

- [ ] **Step 2: Run the tests and verify they fail**

Run: `xcodebuild -project Muse/Muse.xcodeproj -scheme Muse test -only-testing:MuseTests/JustifiedRowsGeometryTests`

Expected: compile failure — `cannot find 'JustifiedRowsGeometry' in scope`.

- [ ] **Step 3: Write the implementation**

Create `Muse/Muse/Components/JustifiedRowsGeometry.swift`:

```swift
//
//  JustifiedRowsGeometry.swift
//  Muse
//
//  Pure justified-rows packing — the "Rows" image layout. Every row shares one
//  height, each item keeps its own shape, and a closed row spans the content
//  width exactly. Sibling of MasonryGeometry (which packs vertical columns for
//  the "Columns" layout): stateless, O(n), no SwiftUI, unit-tested.
//
//  The trailing partial row is deliberately NOT justified. Stretching it would
//  blow a single leftover image up to a full-width panorama.
//

import CoreGraphics

enum JustifiedRowsGeometry {

    /// One item's placement within its row (x is derived when laying out).
    struct Item: Equatable {
        let index: Int
        let width: CGFloat
    }

    /// A run of items sharing one height.
    struct Row: Equatable {
        var items: [Item]
        var height: CGFloat
    }

    struct Result {
        /// Frame of each item in content coordinates (origin top-left),
        /// positionally matching the input `aspects`.
        var frames: [CGRect]
        /// Total scrollable content height.
        var totalHeight: CGFloat
    }

    /// Layout-only clamp on a single item's aspect. A pathological panorama
    /// (a few thousand pixels wide, a dozen tall) would otherwise force a
    /// sub-pixel row height and swallow the whole row. This bounds PACKING
    /// only — the image is still drawn at its true shape inside its frame.
    static let minAspect: CGFloat = 0.1
    static let maxAspect: CGFloat = 10

    private static func clamped(_ aspect: CGFloat) -> CGFloat {
        let a = aspect > 0 ? aspect : 1
        return min(maxAspect, max(minAspect, a))
    }

    /// Group `aspects` (height ÷ width) into rows.
    ///
    /// A row accumulates items until justifying it to the full width would make
    /// it no taller than `targetHeight`; at that point it closes at exactly the
    /// height that fills the width. Any leftover items form a final row at
    /// `targetHeight`, left-aligned and unstretched.
    static func rows(aspects: [CGFloat],
                     targetHeight: CGFloat,
                     width: CGFloat,
                     spacing: CGFloat) -> [Row] {
        guard !aspects.isEmpty, width > 0, targetHeight > 0 else { return [] }

        var out: [Row] = []
        var current: [Int] = []
        // Σ (1 / aspect) — the row's total width at a height of 1.
        var inverseSum: CGFloat = 0

        for (i, raw) in aspects.enumerated() {
            current.append(i)
            inverseSum += 1 / clamped(raw)

            let gaps = spacing * CGFloat(current.count - 1)
            let fitted = max(1, (width - gaps) / inverseSum)
            guard fitted <= targetHeight else { continue }

            out.append(Row(items: current.map {
                Item(index: $0, width: fitted / clamped(aspects[$0]))
            }, height: fitted))
            current = []
            inverseSum = 0
        }

        if !current.isEmpty {
            out.append(Row(items: current.map {
                Item(index: $0, width: targetHeight / clamped(aspects[$0]))
            }, height: targetHeight))
        }
        return out
    }

    /// Lay the rows out into content-coordinate frames.
    ///
    /// - Parameters:
    ///   - targetHeight: the row height to aim for. `GridView` derives this
    ///     from the images-per-row slider so one control drives every mode.
    ///   - captionHeight: a fixed strip added to every tile's height (for an
    ///     under-tile filename caption). 0 = no caption.
    static func compute(aspects: [CGFloat],
                        targetHeight: CGFloat,
                        width: CGFloat,
                        spacing: CGFloat,
                        captionHeight: CGFloat = 0) -> Result {
        let packed = rows(aspects: aspects, targetHeight: targetHeight,
                          width: width, spacing: spacing)
        guard !packed.isEmpty else { return Result(frames: [], totalHeight: 0) }

        var frames = [CGRect](repeating: .zero, count: aspects.count)
        var y: CGFloat = 0
        for row in packed {
            var x: CGFloat = 0
            let tileHeight = row.height + captionHeight
            for item in row.items {
                frames[item.index] = CGRect(x: x, y: y,
                                            width: item.width, height: tileHeight)
                x += item.width + spacing
            }
            y += tileHeight + spacing
        }
        // Strip the trailing spacing added after the last row.
        return Result(frames: frames, totalHeight: max(0, y - spacing))
    }
}
```

- [ ] **Step 4: Run the tests and verify they pass**

Run: `xcodebuild -project Muse/Muse.xcodeproj -scheme Muse test -only-testing:MuseTests/JustifiedRowsGeometryTests`

Expected: PASS, 11 tests.

If `testExtremeAspectsAreClampedForLayout` fails, check the clamp is applied in **both** the accumulation (`inverseSum`) and the width calculation — using the raw aspect in one and the clamped one in the other makes the row not sum to the width.

- [ ] **Step 5: Add the new file to the Xcode target**

The project uses a file-system-synchronized group, so a new file under `Muse/Muse/Components/` is picked up automatically. Confirm by running a plain build:

Run: `xcodebuild -project Muse/Muse.xcodeproj -scheme Muse build`
Expected: BUILD SUCCEEDED.

If it is NOT picked up (unresolved symbol at link time), add it in Xcode: File → Add Files to "Muse", select the file, target Muse.

- [ ] **Step 6: Commit**

```bash
git add Muse/Muse/Components/JustifiedRowsGeometry.swift Muse/MuseTests/JustifiedRowsGeometryTests.swift
git commit -m "feat: JustifiedRowsGeometry — pure justified-rows packing for the Rows layout"
```

---

### Task 2: One orientation truth

Three places resolve an image's shape and disagree about EXIF-rotated photos. `AspectRatioCache.imageIOAspect` swaps width/height for orientations 5–8; `ImageHeaderSizeCache` does not; `files.width`/`height` inherit `ImageHeaderSizeCache`'s raw values. Today an *analyzed* rotated photo therefore packs at the wrong shape while an *unanalyzed* one packs correctly, and the hero flight takes off from a slightly wrong rect. Deleting the tile card (Task 5) removes the grey that hides this, and in Rows a wrong aspect breaks row alignment outright.

Fix: `ImageHeaderSizeCache` becomes the single authority and stores **display** dimensions.

**Files:**
- Modify: `Muse/Muse/Components/ImageHeaderSizeCache.swift` (add the orientation helper; apply it in `resolve`)
- Modify: `Muse/Muse/Filesystem/ThumbnailCache.swift:315-327` (`declaredPixelCount` records display dimensions)
- Test: `Muse/MuseTests/ImageOrientationTests.swift` (create)

**Interfaces:**
- Consumes: nothing from Task 1.
- Produces: `ImageHeaderSizeCache.displaySize(width: Int, height: Int, orientation: Int) -> CGSize` — pure, swaps for EXIF orientations 5–8. Task 5 relies on `ImageHeaderSizeCache.cached(url)` returning display dimensions.

- [ ] **Step 1: Write the failing test**

Create `Muse/MuseTests/ImageOrientationTests.swift`:

```swift
import XCTest
import CoreGraphics
@testable import Muse

/// EXIF orientations 5–8 are the 90°/270° rotations: the stored pixel buffer is
/// landscape but the image DISPLAYS as portrait. Every shape lookup in Muse
/// must report the display shape, or an analyzed rotated photo lays out
/// differently from an unanalyzed one sitting beside it.
final class ImageOrientationTests: XCTestCase {

    func testUprightOrientationsKeepDimensions() {
        for orientation in 1...4 {
            let s = ImageHeaderSizeCache.displaySize(width: 4000, height: 3000,
                                                     orientation: orientation)
            XCTAssertEqual(s.width, 4000, "orientation \(orientation)")
            XCTAssertEqual(s.height, 3000, "orientation \(orientation)")
        }
    }

    func testRotatedOrientationsSwapDimensions() {
        for orientation in 5...8 {
            let s = ImageHeaderSizeCache.displaySize(width: 4000, height: 3000,
                                                     orientation: orientation)
            XCTAssertEqual(s.width, 3000, "orientation \(orientation)")
            XCTAssertEqual(s.height, 4000, "orientation \(orientation)")
        }
    }

    func testOutOfRangeOrientationIsTreatedAsUpright() {
        // A corrupt or absent orientation tag must not rotate anything.
        for orientation in [0, 9, -1, 99] {
            let s = ImageHeaderSizeCache.displaySize(width: 4000, height: 3000,
                                                     orientation: orientation)
            XCTAssertEqual(s.width, 4000, "orientation \(orientation)")
            XCTAssertEqual(s.height, 3000, "orientation \(orientation)")
        }
    }

    func testDisplaySizeAgreesWithTheGridAspectConvention() {
        // AspectRatioCache works in height ÷ width. A rotated 4000×3000 file
        // displays 3000×4000, i.e. aspect 4/3 — TALL.
        let s = ImageHeaderSizeCache.displaySize(width: 4000, height: 3000,
                                                 orientation: 6)
        XCTAssertGreaterThan(s.height / s.width, 1)
    }
}
```

- [ ] **Step 2: Run the test and verify it fails**

Run: `xcodebuild -project Muse/Muse.xcodeproj -scheme Muse test -only-testing:MuseTests/ImageOrientationTests`

Expected: compile failure — no `displaySize` member.

- [ ] **Step 3: Add the helper and apply it in `resolve`**

In `Muse/Muse/Components/ImageHeaderSizeCache.swift`, add below `key(_:)`:

```swift
    /// Display dimensions for a stored pixel buffer under an EXIF orientation.
    /// Orientations 5–8 are the 90°/270° rotations, where the buffer is stored
    /// with width and height swapped relative to how the image is shown.
    ///
    /// This is the single place the swap happens: the grid's layout aspect, the
    /// hero flight's take-off rect, and `files.width`/`height` all derive from
    /// this cache, and they must not disagree (a mismatch between the grid's
    /// drawn rect and the flight's rect makes the photo visibly jump on open).
    static func displaySize(width: Int, height: Int, orientation: Int) -> CGSize {
        let rotated = (5...8).contains(orientation)
        return rotated
            ? CGSize(width: CGFloat(height), height: CGFloat(width))
            : CGSize(width: CGFloat(width), height: CGFloat(height))
    }
```

Then change `resolve` to read the orientation tag and store the display size. Replace the body of `resolve`:

```swift
    /// Cached value, else a header read. May do file I/O — call off-main.
    /// Returns DISPLAY dimensions (EXIF orientation applied).
    static func resolve(_ url: URL) -> CGSize? {
        if let hit = cached(url) { return hit }
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let h = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              w > 0, h > 0 else { return nil }
        let orientation = (props[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        let size = displaySize(width: w, height: h, orientation: orientation)
        record(url, width: Int(size.width), height: Int(size.height))
        return size
    }
```

Also update the file's header comment: after the "So: a plain table that never evicts" paragraph, add:

```swift
//  The stored size is the DISPLAY size — EXIF orientation applied. A rotated
//  photo (orientations 5–8) is stored landscape but shown portrait, and the
//  grid, the hero flight and `files.width`/`height` all read this table, so the
//  swap has to happen once, here, or they disagree.
```

- [ ] **Step 4: Record display dimensions from the thumbnail prewarm**

In `Muse/Muse/Filesystem/ThumbnailCache.swift`, `declaredPixelCount` reads the header for the decode budget and opportunistically warms the cache with raw values. Make it warm with display values.

Replace:

```swift
        // Free prewarm: the hero flight needs this exact value from its first
        // frame, and resolving it here (off-main, before any click) keeps the
        // main thread out of the filesystem entirely. See ImageHeaderSizeCache.
        ImageHeaderSizeCache.record(url, width: w, height: h)
```

with:

```swift
        // Free prewarm: the hero flight needs this exact value from its first
        // frame, and resolving it here (off-main, before any click) keeps the
        // main thread out of the filesystem entirely. See ImageHeaderSizeCache.
        // DISPLAY dimensions, not the raw buffer's — a rotated photo is stored
        // landscape and shown portrait, and every consumer of this table wants
        // the shape the user sees. (The pixel COUNT below is orientation-
        // invariant, so the decode budget is unaffected either way.)
        let orientation = (props[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        let display = ImageHeaderSizeCache.displaySize(width: w, height: h,
                                                       orientation: orientation)
        ImageHeaderSizeCache.record(url, width: Int(display.width),
                                    height: Int(display.height))
```

- [ ] **Step 5: Run the tests and verify they pass**

Run: `xcodebuild -project Muse/Muse.xcodeproj -scheme Muse test -only-testing:MuseTests/ImageOrientationTests`
Expected: PASS, 4 tests.

Then the whole suite, to catch any test that pinned the old raw-dimension behaviour:

Run: `xcodebuild -project Muse/Muse.xcodeproj -scheme Muse test`
Expected: PASS. If a Vision/metadata test asserts specific `width`/`height` for a rotated fixture, update the expectation to display dimensions and note why in the test comment.

- [ ] **Step 6: Commit**

```bash
git add Muse/Muse/Components/ImageHeaderSizeCache.swift Muse/Muse/Filesystem/ThumbnailCache.swift Muse/MuseTests/ImageOrientationTests.swift
git commit -m "fix: one orientation truth — ImageHeaderSizeCache stores display dimensions

A rotated photo (EXIF 5-8) is stored landscape and shown portrait.
AspectRatioCache honoured that; ImageHeaderSizeCache and files.width/height
did not, so an analyzed rotated photo packed at a different shape from an
unanalyzed one beside it and the hero flight took off from a wrong rect.
The swap now happens once, in the cache every consumer reads."
```

---

### Task 3: Three layout modes

`ImageLayout` becomes Columns / Rows / Grid. Every consumer is updated in this same task so the build never breaks.

**Files:**
- Modify: `Muse/Muse/Models/ImageLayout.swift` (rewrite)
- Modify: `Muse/Muse/Views/GridView.swift:561-586` (`recompute`)
- Modify: `Muse/Muse/Views/ImageLayoutSheet.swift` (three tiles; delete the Common Sizes table)
- Modify: `Muse/Muse/Settings/AppSettings.swift:113-119` (comment only)
- Modify: `Muse/MuseTests/ImageLayoutTests.swift` (rewrite)

**Interfaces:**
- Consumes: `JustifiedRowsGeometry.compute(aspects:targetHeight:width:spacing:captionHeight:)` from Task 1.
- Produces:
  - `ImageLayout` cases `.columns`, `.rows`, `.grid` with raw values `"columns"`, `"rows"`, `"grid"`
  - `ImageLayout.aspect: CGFloat?` — `nil` for `.columns`/`.rows`, `1` for `.grid`. **Kept deliberately**: `GridView`'s parting-ripple damping (`GridView.swift:349`) and the PDF exporter both branch on "is this a uniform lattice?", and `aspect == nil` already expresses it.
  - `LayoutIconKind` cases `.columns`, `.rows`, `.grid`

- [ ] **Step 1: Write the failing tests**

Replace `Muse/MuseTests/ImageLayoutTests.swift` entirely:

```swift
import XCTest
@testable import Muse

final class ImageLayoutTests: XCTestCase {

    func testThreeModesInOrder() {
        XCTAssertEqual(ImageLayout.allCases.map(\.displayName),
                       ["Columns", "Rows", "Grid"])
    }

    func testColumnsAndRowsHaveNoFixedAspect() {
        XCTAssertNil(ImageLayout.columns.aspect)
        XCTAssertNil(ImageLayout.rows.aspect)
    }

    func testGridIsSquare() {
        XCTAssertEqual(ImageLayout.grid.aspect, 1)
    }

    func testIconKinds() {
        XCTAssertEqual(ImageLayout.columns.iconKind, .columns)
        XCTAssertEqual(ImageLayout.rows.iconKind, .rows)
        XCTAssertEqual(ImageLayout.grid.iconKind, .grid)
    }

    func testResolveDefaultsToColumns() {
        XCTAssertEqual(ImageLayout.resolve(nil), .columns)
        XCTAssertEqual(ImageLayout.resolve("bogus"), .columns)
    }

    func testResolveRoundTripsTheNewRawValues() {
        for layout in ImageLayout.allCases {
            XCTAssertEqual(ImageLayout.resolve(layout.rawValue), layout)
        }
    }

    /// A user persisted on the old masonry default must land on Columns —
    /// the same layout under a new name, not a silent change.
    func testLegacyMasonryMigratesToColumns() {
        XCTAssertEqual(ImageLayout.resolve("masonry"), .columns)
    }

    /// A user persisted on any of the ten deleted fixed ratios must land on
    /// Grid — the mode that kept the aligned-lattice feel. Falling through to
    /// the unknown-value default would silently drop them into Columns.
    func testLegacyRatiosMigrateToGrid() {
        for raw in ["r1x1", "r9x16", "r16x9", "r4x5", "r5x4",
                    "r6x7", "r7x6", "r2x3", "r3x2", "r3x4", "r4x3"] {
            XCTAssertEqual(ImageLayout.resolve(raw), .grid, "raw: \(raw)")
        }
    }
}
```

- [ ] **Step 2: Run the tests and verify they fail**

Run: `xcodebuild -project Muse/Muse.xcodeproj -scheme Muse test -only-testing:MuseTests/ImageLayoutTests`
Expected: compile failure — no `.columns` member.

- [ ] **Step 3: Rewrite `ImageLayout`**

Replace `Muse/Muse/Models/ImageLayout.swift` entirely:

```swift
//
//  ImageLayout.swift
//  Muse
//
//  How images are laid out on every grid. Three modes, all of which draw each
//  image at its own natural shape — none crops, none letterboxes:
//
//    Columns — vertical columns, ragged bottom (the classic masonry pack)
//    Rows    — every row one height, widths natural, rows justified to the width
//    Grid    — one square slot per image, the image fitted inside it
//
//  Global — applies on all-tags, a single tag, and inside a collection.
//
//  This replaced a masonry default plus ten fixed aspect ratios (1:1, 9:16,
//  4:5, …). The ratios picked a CARD shape, not an image shape: the visible
//  slab around a fitted image is what made them look imposed, and with the slab
//  gone they had nothing left to express. The middle eight were also
//  indistinguishable in practice (~7% steps in rendered height).
//

import CoreGraphics

enum ImageLayout: String, CaseIterable, Identifiable {
    case columns
    case rows
    case grid

    var id: String { rawValue }

    /// Label on the modal tile.
    var displayName: String {
        switch self {
        case .columns: return String(localized: "Columns")
        case .rows:    return String(localized: "Rows")
        case .grid:    return String(localized: "Grid")
        }
    }

    /// A single uniform tile aspect (height ÷ width) when the layout imposes
    /// one, else `nil`. Only Grid does — square slots, which `MasonryGeometry`
    /// packs into an exact aligned row-major grid when every aspect is equal.
    ///
    /// Also read as "is this a uniform lattice?" by the hero parting ripple
    /// (which damps its amplitude on one) and by the PDF exporter.
    var aspect: CGFloat? {
        switch self {
        case .columns, .rows: return nil
        case .grid:           return 1
        }
    }

    /// Which preview graphic the modal draws for this layout.
    var iconKind: LayoutIconKind {
        switch self {
        case .columns: return .columns
        case .rows:    return .rows
        case .grid:    return .grid
        }
    }

    /// Parse a persisted raw value.
    ///
    /// Migration matters here: `"masonry"` and the ten `r*` ratio raws are live
    /// on users' disks. Falling through to the default would silently drop a
    /// ratio user into Columns — a visibly different layout — so map them:
    /// masonry is Columns under a new name, and a fixed ratio is closest to
    /// Grid (an aligned lattice of same-size slots).
    static func resolve(_ raw: String?) -> ImageLayout {
        guard let raw else { return .columns }
        if let known = ImageLayout(rawValue: raw) { return known }
        if raw == "masonry" { return .columns }
        if raw.first == "r", raw.dropFirst().contains("x") { return .grid }
        return .columns
    }
}

/// The three preview graphics in the layout modal.
enum LayoutIconKind {
    case columns, rows, grid
}
```

- [ ] **Step 4: Wire Rows into the grid's geometry**

In `Muse/Muse/Views/GridView.swift`, replace `recompute(width:)` (lines ~559-586):

```swift
    /// Recompute the full packing. Called only on set/column/width/aspect/
    /// spacing changes — not on scroll.
    private func recompute(width: CGFloat) {
        let files = appState.visibleFiles
        guard width > 0, !files.isEmpty else {
            frames = []
            totalHeight = 0
            layoutWidth = width
            return
        }
        let natural = files.map { aspects.aspect(for: $0) }
        let result: (frames: [CGRect], totalHeight: CGFloat)

        switch appState.imageLayout {
        case .rows:
            // One control drives every mode: the images-per-row slider's column
            // width IS the target row height, so dragging it grows and shrinks
            // images in Rows exactly as it does in Columns and Grid.
            let target = max(1, (width - spacing * CGFloat(max(0, gridColumns - 1)))
                                / CGFloat(max(1, gridColumns)))
            let r = JustifiedRowsGeometry.compute(aspects: natural,
                                                  targetHeight: target,
                                                  width: width,
                                                  spacing: spacing,
                                                  captionHeight: effectiveCaptionHeight)
            result = (r.frames, r.totalHeight)
        case .columns, .grid:
            // Grid gives every tile one aspect — uniform aspects make
            // MasonryGeometry pack an exact row-major lattice. Columns uses
            // each image's natural ratio from the cache.
            let ratios = appState.imageLayout.aspect
                .map { Array(repeating: $0, count: files.count) } ?? natural
            let r = MasonryGeometry.compute(aspects: ratios,
                                            columns: gridColumns,
                                            width: width,
                                            spacing: spacing,
                                            captionHeight: effectiveCaptionHeight)
            result = (r.frames, r.totalHeight)
        }

        frames = result.frames
        totalHeight = result.totalHeight
        layoutWidth = width
    }
```

- [ ] **Step 5: Rewrite the layout sheet**

In `Muse/Muse/Views/ImageLayoutSheet.swift`:

1. Change the grid to three columns — replace the `columns` property:

```swift
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 14),
                                count: 3)
```

2. Delete the `commonSizes` reference table: remove the `sizes` array (the six `("1:1", …)` tuples) and the entire `commonSizes` computed property, and remove `commonSizes` from the `ScrollView`'s `VStack`. The `VStack(alignment: .leading, spacing: 28)` wrapper now holds only the `LazyVGrid`.

3. Update the subtitle under the title from "Choose how images are arranged. Applies to every grid." to:

```swift
                Text("Choose how images are arranged. Every mode draws each image at its own shape — nothing is cropped. Applies to every grid.")
```

4. Replace `LayoutIconView`'s `body` switch:

```swift
    var body: some View {
        switch kind {
        case .columns: columnsIcon
        case .rows:    rowsIcon
        case .grid:    grid(cols: 3, rows: 3)
        }
    }
```

5. Keep the existing `grid(cols:rows:)` and `mason` helpers, renaming `mason` to `columnsIcon`, and add a `rowsIcon` beneath it that draws three bands of unequal-width cells (the justified-rows tell). Add after `columnsIcon`:

```swift
    /// Three rows of equal height with unequal widths — the Rows tell.
    private var rowsIcon: some View {
        VStack(spacing: gap) {
            row(weights: [2, 1, 1.4])
            row(weights: [1, 1.8, 1.2])
            row(weights: [1.5, 1, 1.6])
        }
    }

    private func row(weights: [CGFloat]) -> some View {
        GeometryReader { geo in
            let total = weights.reduce(0, +)
            let usable = max(0, geo.size.width - gap * CGFloat(weights.count - 1))
            HStack(spacing: gap) {
                ForEach(Array(weights.enumerated()), id: \.offset) { _, w in
                    Rectangle()
                        .fill(color)
                        .frame(width: usable * (w / total))
                }
            }
            .frame(height: geo.size.height)
        }
    }
```

If `mason` was written as a `some View` computed property with a different internal shape, keep its body as-is and only rename it — the Columns icon is unchanged from today's masonry icon.

- [ ] **Step 6: Update the settings comment**

In `Muse/Muse/Settings/AppSettings.swift`, the doc comment on `imageLayout`:

```swift
    /// Global image layout for every grid. Default `.columns`. Unset → columns;
    /// legacy `masonry` → columns, legacy `r*` ratios → grid (see
    /// `ImageLayout.resolve`).
```

- [ ] **Step 7: Build and run the full suite**

Run: `xcodebuild -project Muse/Muse.xcodeproj -scheme Muse build`
Expected: BUILD SUCCEEDED. Any remaining `.masonry` / `.r1x1` references will surface here — fix each by mapping masonry → `.columns` and a ratio → `.grid`.

Run: `xcodebuild -project Muse/Muse.xcodeproj -scheme Muse test`
Expected: PASS.

- [ ] **Step 8: Commit**

```bash
git add Muse/Muse/Models/ImageLayout.swift Muse/Muse/Views/GridView.swift Muse/Muse/Views/ImageLayoutSheet.swift Muse/Muse/Settings/AppSettings.swift Muse/MuseTests/ImageLayoutTests.swift
git commit -m "feat: three layout modes — Columns / Rows / Grid

Replaces masonry + ten fixed aspect ratios. Rows is new (justified rows via
JustifiedRowsGeometry); Columns is masonry renamed; Grid is the square-slot
lattice MasonryGeometry already produces from a uniform aspect. Persisted
masonry migrates to Columns and any r* ratio to Grid, so nobody silently
lands somewhere else."
```

---

### Task 4: Delete the Tile Background setting

`TileBackground` (None / Auto / Light / Dark Grey / Black) exists to colour the letterbox around a fitted photo. Task 5 removes the letterbox, so it has nothing left to do. Non-photo tiles (PDF / zip / video / folder) are icons and still need a card — theirs becomes the mood's tile colour unconditionally, which is what `.auto` did and what masonry already forced via `effectiveTileBackground`.

Do this **before** Task 5 so the two commits stay reviewable: this one is deletion, the next is the visual change.

**Files:**
- Delete: `Muse/Muse/Models/TileBackground.swift`
- Delete: `Muse/MuseTests/TileBackgroundTests.swift`
- Modify: `Muse/Muse/Models/AppState.swift:488-528`
- Modify: `Muse/Muse/Settings/AppSettings.swift:121-127`
- Modify: `Muse/Muse/Views/MoodPickerView.swift:74-116` and the `TileSwatch` struct (~line 172-225)
- Modify: `Muse/Muse/Views/GridView.swift:1013-1022` (`cardNameColor`)
- Modify: `Muse/Muse/Views/CollectionPDFSave.swift:38-45`
- Modify: `Muse/Muse/Export/CollectionPDFExporter.swift:52-53, 158-166`

**Interfaces:**
- Consumes: `ImageLayout` from Task 3 (the mood picker's disabled-in-masonry gate goes away with the section).
- Produces: `AppState.tileFill: Color` survives as `moodPalette.tileFill`, read only by the non-photo card branch. `CollectionPDFExporter.makePDF` loses its `tileBackdrop:` parameter.

- [ ] **Step 1: Delete the model, its tests, and the stored setting**

```bash
git rm Muse/Muse/Models/TileBackground.swift Muse/MuseTests/TileBackgroundTests.swift
```

In `Muse/Muse/Settings/AppSettings.swift`, delete `tileBackgroundKey` and the `tileBackground` static var (lines ~121-127). Leave the `"tileBackground"` UserDefaults key on disk — it's inert, and migrating it away buys nothing.

In `Muse/Muse/Models/AppState.swift`, delete the `tileBackground` `@Published` property (~488-492) and `effectiveTileBackground` (~521-526), and replace `tileFill`:

```swift
    /// Backdrop for a NON-PHOTO tile — the card behind a PDF / zip / video /
    /// folder icon, which needs something to sit on. Photos never draw a card:
    /// the slab around a fitted image is what made a layout read as imposed.
    /// Always the mood's tile colour (the old TileBackground setting's `.auto`,
    /// which masonry already forced).
    var tileFill: Color { moodPalette.tileFill }
```

- [ ] **Step 2: Remove the mood popover's Tile Background section**

In `Muse/Muse/Views/MoodPickerView.swift`, delete from the `Divider()` at line ~74 through the closing brace of the `VStack` at ~95 — the "TILE BACKGROUND" label, both `tileGroup` calls, the `.opacity`/`.disabled` masonry gate, and the "Masonry always uses Auto…" footnote. Then delete the `tileGroup(_:options:)` helper (~101-116) and the whole `private struct TileSwatch` (~172-225) with its `// MARK: - Tile background swatch` comment.

- [ ] **Step 3: Fix the card filename colour**

In `Muse/Muse/Views/GridView.swift`, replace `cardNameColor`:

```swift
    /// Readable colour for the card's internal filename against the card's
    /// mood-derived backdrop (light text on a dark card, dark on light).
    private var cardNameColor: Color {
        let rgb = appState.moodPalette.tileRGB
        return SelectionStyle.relativeLuminance(rgb) < 0.5
            ? Color.white.opacity(0.9)
            : Color.black.opacity(0.55)
    }
```

- [ ] **Step 4: Drop the PDF's per-image backdrop**

The PDF export renders raster images only, so with photos card-free there is nothing left to fill — the white page shows through, which is what a printed contact sheet should do.

In `Muse/Muse/Export/CollectionPDFExporter.swift`:
- Remove `tileBackdrop: CGColor?` from `makePDF`'s signature (line ~53) and from its doc comment.
- Delete the fill block in the placement loop (~158-166):

```swift
                    if let tileBackdrop {
                        ctx.setFillColor(tileBackdrop)
                        ctx.fill(flipped)
                    }
```

In `Muse/Muse/Views/CollectionPDFSave.swift`, delete the `backdrop` local (~39-40) and drop `tileBackdrop: backdrop,` from the `makePDF` call.

- [ ] **Step 5: Build and run the full suite**

Run: `xcodebuild -project Muse/Muse.xcodeproj -scheme Muse build`
Expected: BUILD SUCCEEDED. Any straggling `TileBackground` reference surfaces here.

Run: `xcodebuild -project Muse/Muse.xcodeproj -scheme Muse test`
Expected: PASS. `TileBackgroundTests` is gone; nothing else should reference it.

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "refactor: delete the Tile Background setting

It coloured the letterbox around a fitted photo; photos are about to stop
having one. Non-photo cards (PDF/zip/video/folder) keep a card in the mood's
tile colour — what .auto did, and what masonry already forced. The PDF export
loses its per-image backdrop with it: white paper shows through."
```

---

### Task 5: No card behind photos; ring, hover and badge hug the photo

The visual change. An image tile stops drawing `Rectangle().fill(appState.tileFill)`, and its whole content stack — placeholder shimmer, image, star badge, hover veil, selection ring — is fitted to the drawn-photo rect instead of the slot.

The fit is done with `.aspectRatio(_, contentMode: .fit)`, which is the same min-scale fit as `ViewerGeometry.fitWithin`. The aspect comes from `ImageHeaderSizeCache` (Task 2), which is also what the hero flight reads — so the ring rect and the flight rect agree by construction rather than by two code paths happening to match.

**Files:**
- Modify: `Muse/Muse/Views/GridView.swift` — `TileView.imageContent` (~847-943), `TileView.tile` (~947-978), the `TileView(...)` call site (~355-364), and the tap/drag hit area (~365-375)

**Interfaces:**
- Consumes: `ImageHeaderSizeCache.cached(_:)` (Task 2, now display dimensions); `ImageLayout` (Task 3); `AppState.tileFill` (Task 4, non-photo cards only).
- Produces: `TileView.imageAspect: CGFloat` — a new parameter, height ÷ width, supplied by `GridView` from `AspectRatioCache` as the fallback when the header cache is cold.

- [ ] **Step 1: Give the tile the image's own aspect**

In `Muse/Muse/Views/GridView.swift`, add a stored property to `TileView` beside `reportAspect` (~709-711):

```swift
    /// The IMAGE's own shape (height ÷ width) — which is not the slot's shape
    /// in Grid mode, where every slot is square. Drives where the photo
    /// actually draws, and therefore where the ring, hover veil and star badge
    /// sit. Fallback only: `ImageHeaderSizeCache` wins when it's warm, because
    /// the hero flight reads that same table and the two rects must not
    /// disagree (they'd make the photo jump at flight start).
    var imageAspect: CGFloat = 1
```

And pass it at the call site (~355-364), inside the `TileView(...)` argument list after `rating:`:

```swift
                         imageAspect: aspects.aspect(for: file),
```

- [ ] **Step 2: Resolve the drawn aspect, preferring the header cache**

Add to `TileView`, next to `isImageKind` (~762-764):

```swift
    /// Where the photo draws inside its slot, as a width ÷ height ratio for
    /// `.aspectRatio(_:contentMode:)`.
    ///
    /// Prefers `ImageHeaderSizeCache` — the same never-evicting table the hero
    /// flight resolves its take-off rect from, warmed off-main by the thumbnail
    /// pass long before any click. Using it here means the ring and the flight
    /// are computing the same rect from the same number. `imageAspect` (from
    /// AspectRatioCache, which may still hold a placeholder or a stale DB
    /// value) is the cold-start fallback.
    private var drawnAspectRatio: CGFloat {
        if let size = ImageHeaderSizeCache.cached(file.url),
           size.width > 0, size.height > 0 {
            return size.width / size.height
        }
        return imageAspect > 0 ? 1 / imageAspect : 1
    }
```

- [ ] **Step 3: Fit the content stack to the photo, for image kinds only**

In `TileView.imageContent` (~847), the current shape is:

```swift
    private var imageContent: some View {
        ZStack {
            ...
        }
        .animation(.easeOut(duration: 0.18), value: hovering)
        .animation(.easeOut(duration: 0.15), value: isSelected)
        .background( GeometryReader { ... tileFrames ... } )
    }
```

Change the declaration to `@ViewBuilder`, extract the existing body into `contentStack`, and fit it:

```swift
    /// The image area: the thumbnail/preview/card, clipped, with the selection
    /// overlay and the global-frame reporter for the hero open/close flight.
    /// The caption strip (if any) sits below this, OUTSIDE the selection border.
    ///
    /// For an image kind the whole stack is fitted to the photo's own shape, so
    /// the ring, the hover veil and the star badge hug the visible image and
    /// never box in empty slot space. In Columns and Rows the slot already has
    /// the image's shape, so the fit is a no-op; only Grid (square slots) shows
    /// a difference. Non-photo cards keep the full slot — their card IS the
    /// tile.
    @ViewBuilder
    private var imageContent: some View {
        if isImageKind {
            contentStack
                .aspectRatio(drawnAspectRatio, contentMode: .fit)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            contentStack
        }
    }

    private var contentStack: some View {
        ZStack {
            // ... the existing ZStack body, unchanged ...
        }
        .animation(.easeOut(duration: 0.18), value: hovering)
        .animation(.easeOut(duration: 0.15), value: isSelected)
        .background(
            GeometryReader { proxy in
                Color.clear
                    .onAppear {
                        appState.tileFrames[file.url.path] = proxy.frame(in: .global)
                    }
                    .onChange(of: proxy.frame(in: .global)) { _, f in
                        guard appState.selectedFile == nil
                            || appState.selectedFile?.url == file.url else { return }
                        appState.tileFrames[file.url.path] = f
                    }
            }
        )
    }
```

Leave the `ZStack` body and the geometry reader's comments exactly as they are — only the wrapping changed.

**Why the frame reporter moves with the fitted stack, deliberately:** `tileFrames` now carries the DRAWN rect rather than the slot rect. `HeroStage` computes `fitWithin(headerSize, sourceFrame)` on it, and fitting an already-fitted rect is the identity — so the flight endpoint is unchanged in Columns and Rows, and in Grid it becomes exact instead of depending on two caches agreeing. Do not "restore" this to report the slot.

- [ ] **Step 4: Drop the fill behind photos and fit the placeholder**

In `TileView.tile` (~947), replace the `isImageKind` branch:

```swift
        if isImageKind {
            // No backdrop: a photo draws on the page itself. The opaque slab a
            // fitted image used to sit on is exactly what made a layout read as
            // imposed, and a transparent PNG is meant to show the page through.
            // The placeholder stays put and the decoded image fades IN over it,
            // so a cold grid resolves as a soft fade. Both are already inside
            // the photo-fitted container, so the shimmer occupies the rect the
            // image will land in — nothing resizes when it arrives.
            ZStack {
                if thumbnail == nil {
                    let tuning = shimmerTuning(
                        isCustom: appState.mood == .custom,
                        isDark: appState.moodPalette.scheme == .dark)
                    ShimmerBand(peak: tuning.peak,
                                shoulder: tuning.shoulder,
                                blurRadius: 12)
                        .opacity(tuning.stackOpacity)
                }
                if let img = thumbnail {
                    Image(nsImage: img)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .transition(.opacity)
                        // While this tile is the open hero, the IMAGE stays
                        // hidden even when the card is revealed for the grid
                        // close flight (heroHidden) — it must appear only in
                        // the unmount frame, as the seamless handoff from the
                        // flying image that lands exactly on its rect.
                        .opacity(appState.selectedFile?.url == file.url ? 0 : 1)
                        .animation(nil, value: appState.selectedFile?.url == file.url)
                }
            }
            .animation(.easeOut(duration: 0.28), value: thumbnail != nil)
        } else {
```

The `else` branch (the non-photo card) is unchanged and keeps its `Rectangle().fill(appState.tileFill)`.

- [ ] **Step 5: Keep the whole slot clickable**

With no fill, the empty part of a Grid slot draws nothing and therefore isn't hit-testable — clicking beside a photo would fall through to the background tap that clears the selection. Restore the slot as the hit target at the `TileView` call site in `masonryCanvas` (~364), immediately after `.frame(width: rect.width, height: rect.height)`:

```swift
                    .frame(width: rect.width, height: rect.height)
                    // The photo no longer paints the whole slot, so without an
                    // explicit shape the empty part of a Grid slot isn't
                    // hit-testable and a click beside the image would fall
                    // through to the background (clearing the selection).
                    // Ring and hover hug the photo; the TARGET stays the slot.
                    .contentShape(Rectangle())
```

- [ ] **Step 6: Build, test, and verify in the running app**

Run: `xcodebuild -project Muse/Muse.xcodeproj -scheme Muse build`
Expected: BUILD SUCCEEDED.

Run: `xcodebuild -project Muse/Muse.xcodeproj -scheme Muse test`
Expected: PASS.

Then launch and check by hand — this is the part unit tests cannot cover, and hero-flight geometry is the one area of this codebase where reasoning from code has a documented track record of being wrong:

- Grid mode, a **wide** photo: hover shows the veil on the photo only; select shows the ring around the photo only; the star badge sits on the photo's top-right corner.
- Grid mode, click the empty air beside a photo — it must select that tile, not clear the selection.
- Grid mode, open the hero on a wide photo, a tall photo, and an EXIF-rotated photo, then close each. The image must not jump or re-fit at flight start or landing.
- Columns and Rows: unchanged from before — the fit is a no-op there.
- A transparent PNG shows the page background through it, on a light mood and a dark mood.
- A folder of PDFs / zips / videos: cards still drawn, filename still legible.

If the hero flight misbehaves, do NOT reason about it from the source — instrument the running app per `docs/hero-viewer-open-close-handoff.md` (`sample <pid>` for main-thread stalls; an `NSTemporaryDirectory()` timeline trace for state ordering — the app is sandboxed, so a `/tmp` path is silently denied and NSLog does not reach `log stream`).

- [ ] **Step 7: Commit**

```bash
git add Muse/Muse/Views/GridView.swift
git commit -m "feat: photos draw on the page, not on a card

An image tile no longer fills its slot with tileFill, and its whole content
stack — shimmer, image, star badge, hover veil, selection ring — is fitted to
the photo's own rect instead of the slot. Only Grid (square slots) differs
visibly; Columns and Rows already had the image's shape.

The fitted rect is what tileFrames now reports, and the aspect comes from
ImageHeaderSizeCache — the same table the hero flight reads — so the ring and
the flight compute one rect from one number instead of two paths agreeing by
luck. The slot stays the click target via an explicit contentShape."
```

---

### Task 6: Spacing slider

`spacing` is a hardcoded `14` that already flows into the geometry. Promote it to a persisted setting with a slider beside the existing images-per-row slider. Tight spacing is what makes Grid and Rows read as a dense contact sheet.

**Files:**
- Modify: `Muse/Muse/Settings/AppSettings.swift` (add the key + accessor)
- Modify: `Muse/Muse/Views/GridView.swift:22` (constant → `@AppStorage`), `:619-646` (the slider row), and wherever `columnSlider` is placed
- Test: `Muse/MuseTests/GridSpacingTests.swift` (create)

**Interfaces:**
- Consumes: nothing new.
- Produces: `AppSettings.gridSpacingKey: String` = `"gridSpacing"`, `AppSettings.gridSpacingRange: ClosedRange<Double>` = `0...28`, `AppSettings.defaultGridSpacing: Double` = `14`, `AppSettings.clampGridSpacing(_ raw: Double) -> Double`.

- [ ] **Step 1: Write the failing test**

Create `Muse/MuseTests/GridSpacingTests.swift`:

```swift
import XCTest
@testable import Muse

/// The grid gutter is user-set and persisted. An unset default must read as
/// today's hardcoded 14 (so nobody's grid changes on upgrade), and a
/// out-of-range stored value must clamp rather than produce a broken layout.
final class GridSpacingTests: XCTestCase {

    func testDefaultIsTodaysHardcodedValue() {
        XCTAssertEqual(AppSettings.defaultGridSpacing, 14)
    }

    func testUnsetReadsAsDefault() {
        // A zero from UserDefaults' "never set" is indistinguishable from a
        // deliberate 0, so the accessor must seed the key rather than infer.
        XCTAssertEqual(AppSettings.clampGridSpacing(AppSettings.defaultGridSpacing), 14)
    }

    func testClampsBelowRange() {
        XCTAssertEqual(AppSettings.clampGridSpacing(-5), 0)
    }

    func testClampsAboveRange() {
        XCTAssertEqual(AppSettings.clampGridSpacing(999), 28)
    }

    func testZeroIsAllowed() {
        // Flush packing is the point of the control — 0 is a valid choice.
        XCTAssertEqual(AppSettings.clampGridSpacing(0), 0)
    }

    func testRangeBounds() {
        XCTAssertEqual(AppSettings.gridSpacingRange.lowerBound, 0)
        XCTAssertEqual(AppSettings.gridSpacingRange.upperBound, 28)
    }
}
```

- [ ] **Step 2: Run the test and verify it fails**

Run: `xcodebuild -project Muse/Muse.xcodeproj -scheme Muse test -only-testing:MuseTests/GridSpacingTests`
Expected: compile failure — no `defaultGridSpacing` member.

- [ ] **Step 3: Add the setting**

In `Muse/Muse/Settings/AppSettings.swift`, after the `imageLayout` accessor:

```swift
    static let gridSpacingKey = "gridSpacing"

    /// Gap between grid tiles, in points. Default 14 (the value that was
    /// hardcoded before this became a control), 0 = flush packing.
    static let defaultGridSpacing: Double = 14
    static let gridSpacingRange: ClosedRange<Double> = 0...28

    /// Bound a stored or slider-supplied gutter to the usable range. A value
    /// outside it doesn't just look wrong — a negative gutter overlaps tiles.
    static func clampGridSpacing(_ raw: Double) -> Double {
        min(gridSpacingRange.upperBound, max(gridSpacingRange.lowerBound, raw))
    }
```

- [ ] **Step 4: Drive the grid from it**

In `Muse/Muse/Views/GridView.swift`, replace the constant (line 22):

```swift
    /// User-set gutter between tiles, persisted; the bottom-right slider drives
    /// it. 0 packs flush — a dense contact sheet, which is most of the point of
    /// Rows and Grid.
    @AppStorage(AppSettings.gridSpacingKey) private var gridSpacingSetting =
        AppSettings.defaultGridSpacing
    private var spacing: CGFloat {
        CGFloat(AppSettings.clampGridSpacing(gridSpacingSetting))
    }
```

Add a spacing slider beside the column slider. Replace the `columnSlider` property with a pair, keeping the capsule chrome identical so the bottom controls stay one visual family:

```swift
    /// Floating zoom control: fewer columns (bigger images) on the left,
    /// more (smaller) on the right.
    private var columnSlider: some View {
        sliderCapsule(
            minIcon: "square.grid.2x2",
            maxIcon: "square.grid.4x3.fill",
            label: String(localized: "Images per row"),
            binding: Binding(
                get: { Double(gridColumns) },
                set: { gridColumns = Int($0.rounded()) }),
            range: 2...8,
            step: 1)
    }

    /// Floating gutter control: flush on the left, airy on the right.
    private var spacingSlider: some View {
        sliderCapsule(
            minIcon: "rectangle.compress.vertical",
            maxIcon: "rectangle.expand.vertical",
            label: String(localized: "Spacing between images"),
            binding: Binding(
                get: { AppSettings.clampGridSpacing(gridSpacingSetting) },
                set: { gridSpacingSetting = AppSettings.clampGridSpacing($0.rounded()) }),
            range: AppSettings.gridSpacingRange,
            step: 1)
    }

    /// Shared chrome for the bottom-right sliders: same 20pt content height and
    /// 9pt vertical padding as the status pills, so every bottom capsule
    /// matches.
    private func sliderCapsule(minIcon: String, maxIcon: String, label: String,
                               binding: Binding<Double>,
                               range: ClosedRange<Double>,
                               step: Double) -> some View {
        HStack(spacing: 10) {
            Image(systemName: minIcon)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                // Decorative min/max hint — the slider itself carries the label.
                .accessibilityHidden(true)
            Slider(value: binding, in: range, step: step)
                .frame(width: 130)
                .controlSize(.small)
                .accessibilityLabel(label)
            Image(systemName: maxIcon)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
        }
        .frame(height: 20)
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(Capsule(style: .continuous).fill(.ultraThinMaterial))
        .overlay(Capsule(style: .continuous).strokeBorder(.primary.opacity(0.08)))
        .help(label)
    }
```

Then place `spacingSlider` beside `columnSlider` wherever `columnSlider` is used in the body — find it with `grep -n "columnSlider" Muse/Muse/Views/GridView.swift` and add `spacingSlider` immediately before it in the same `HStack` (spacing slider left, zoom right, so the zoom control keeps its established far-right position).

- [ ] **Step 5: Make the layout recompute when spacing changes**

`recompute` runs on set/column/width/aspect changes. Find the `.onChange` handlers that drive it (`grep -n "recompute(width:" Muse/Muse/Views/GridView.swift`) and add a matching one for spacing next to the `gridColumns` handler:

```swift
        .onChange(of: gridSpacingSetting) { _, _ in recompute(width: layoutWidth) }
```

Match the surrounding handlers' exact form — if the neighbouring one passes a different width source, use the same one.

- [ ] **Step 6: Build, test, verify**

Run: `xcodebuild -project Muse/Muse.xcodeproj -scheme Muse test -only-testing:MuseTests/GridSpacingTests`
Expected: PASS, 6 tests.

Run: `xcodebuild -project Muse/Muse.xcodeproj -scheme Muse test`
Expected: PASS.

By hand: drag the spacing slider to 0 and to 28 in all three modes. At 0 the tiles must pack flush with no overlap and no gap; scrolling must stay smooth on a large folder (the geometry recomputes on release of each step, not per frame — if it stutters, that's a real finding, note it).

- [ ] **Step 7: Commit**

```bash
git add Muse/Muse/Settings/AppSettings.swift Muse/Muse/Views/GridView.swift Muse/MuseTests/GridSpacingTests.swift
git commit -m "feat: spacing slider beside the images-per-row slider

The 14pt gutter was hardcoded and already flowed into the geometry; it is now
persisted and user-set, 0-28pt. Zero packs flush, which is what makes Rows and
Grid read as a dense contact sheet."
```

---

### Task 7: Rows in the PDF export

The collection PDF mirrors the grid, so Rows needs a paginating justified-rows pack. `CollectionPDFLayout.paginate` is a shortest-column masonry pack; add a sibling that lays rows out and breaks pages at row boundaries. Columns and Grid already work through the existing `paginate` (Grid via a uniform aspect), and the per-image backdrop is already gone (Task 4).

**Files:**
- Modify: `Muse/Muse/Export/CollectionPDFLayout.swift` (add `paginateRows`)
- Modify: `Muse/Muse/Export/CollectionPDFExporter.swift:120-124` (choose the paginator)
- Modify: `Muse/Muse/Views/CollectionPDFSave.swift:38` (pass the layout, not just its aspect)
- Test: `Muse/MuseTests/CollectionPDFLayoutTests.swift` (extend)

**Interfaces:**
- Consumes: `JustifiedRowsGeometry.rows(aspects:targetHeight:width:spacing:)` (Task 1); `ImageLayout` (Task 3).
- Produces: `CollectionPDFLayout.paginateRows(aspects:geometry:) -> [Page]`; `CollectionPDFExporter.makePDF` takes `layout: ImageLayout` in place of `layoutAspect: CGFloat?`.

- [ ] **Step 1: Write the failing tests**

Append to `Muse/MuseTests/CollectionPDFLayoutTests.swift`:

```swift
    // MARK: - Rows pagination

    /// Rows mode on paper: one height per row, natural widths, rows justified
    /// to the content width, and no row ever split across a page break.
    func testRowsPaginationJustifiesFullRowsToContentWidth() {
        let g = CollectionPDFLayout.Geometry(
            pageSize: CGSize(width: 792, height: 1008), margin: 36, columns: 4,
            gutter: 12, firstPageHeaderHeight: 120, captionHeight: 0)
        let aspects = [CGFloat](repeating: 1, count: 16)
        let pages = CollectionPDFLayout.paginateRows(aspects: aspects, geometry: g)
        XCTAssertFalse(pages.isEmpty)

        let contentWidth = 792 - 36 * 2
        // Group placements by y within a page; every row but the document's
        // last must span the content width.
        let all = pages.flatMap(\.placements)
        let rows = Dictionary(grouping: all) { ($0.rect.minY * 10).rounded() }
        let lastRowKey = rows.keys.max()
        for (key, placements) in rows where key != lastRowKey {
            let widths = placements.reduce(CGFloat(0)) { $0 + $1.rect.width }
            let gaps = CGFloat(placements.count - 1) * 12
            XCTAssertEqual(widths + gaps, contentWidth, accuracy: 1.0)
        }
    }

    func testRowsPaginationKeepsRowsWhole() {
        let g = CollectionPDFLayout.Geometry(
            pageSize: CGSize(width: 792, height: 1008), margin: 36, columns: 3,
            gutter: 12, firstPageHeaderHeight: 120, captionHeight: 16)
        let aspects = (0..<40).map { CGFloat(0.6 + Double($0 % 5) * 0.2) }
        let pages = CollectionPDFLayout.paginateRows(aspects: aspects, geometry: g)
        XCTAssertGreaterThan(pages.count, 1, "40 images should need several pages")
        // No index appears twice, and every index appears once.
        let indices = pages.flatMap { $0.placements.map(\.index) }.sorted()
        XCTAssertEqual(indices, Array(0..<40))
        // Every placement fits inside its page's content box.
        for page in pages {
            for p in page.placements {
                XCTAssertGreaterThanOrEqual(p.rect.minY, 36)
                XCTAssertLessThanOrEqual(p.rect.maxY, 1008 - 36 + 0.5)
                XCTAssertGreaterThanOrEqual(p.rect.minX, 36 - 0.5)
                XCTAssertLessThanOrEqual(p.rect.maxX, 792 - 36 + 0.5)
            }
        }
    }

    func testRowsPaginationEmptyInput() {
        let g = CollectionPDFLayout.Geometry(
            pageSize: CGSize(width: 792, height: 1008), margin: 36, columns: 4,
            gutter: 12, firstPageHeaderHeight: 120)
        XCTAssertTrue(CollectionPDFLayout.paginateRows(aspects: [], geometry: g).isEmpty)
    }

    func testRowsPaginationReservesTheFirstPageHeader() {
        let g = CollectionPDFLayout.Geometry(
            pageSize: CGSize(width: 792, height: 1008), margin: 36, columns: 4,
            gutter: 12, firstPageHeaderHeight: 120)
        let pages = CollectionPDFLayout.paginateRows(
            aspects: [CGFloat](repeating: 1, count: 30), geometry: g)
        let firstTop = pages[0].placements.map(\.rect.minY).min() ?? 0
        XCTAssertGreaterThanOrEqual(firstTop, 36 + 120 - 0.5)
        if pages.count > 1 {
            let secondTop = pages[1].placements.map(\.rect.minY).min() ?? 0
            XCTAssertEqual(secondTop, 36, accuracy: 0.5)
        }
    }
```

- [ ] **Step 2: Run the tests and verify they fail**

Run: `xcodebuild -project Muse/Muse.xcodeproj -scheme Muse test -only-testing:MuseTests/CollectionPDFLayoutTests`
Expected: compile failure — no `paginateRows` member.

- [ ] **Step 3: Implement `paginateRows`**

Append to `CollectionPDFLayout` in `Muse/Muse/Export/CollectionPDFLayout.swift`:

```swift
    /// Pack `aspects` into pages as justified ROWS — the paper counterpart of
    /// the Rows image layout. Rows are produced by the same pure unit the grid
    /// uses (`JustifiedRowsGeometry`) so screen and print agree; this function
    /// only decides where the page breaks go.
    ///
    /// A row is never split across a break. A row taller than a page's content
    /// area is capped to fit one page (the same rule `paginate` applies to an
    /// over-tall tile).
    static func paginateRows(aspects: [CGFloat], geometry g: Geometry) -> [Page] {
        guard !aspects.isEmpty else { return [] }
        let cols = max(1, g.columns)
        let contentWidth = max(1, g.pageSize.width - g.margin * 2)
        let contentBottom = g.pageSize.height - g.margin
        // The column width the density control would produce IS the target row
        // height — the same derivation GridView uses, so the printed page has
        // the on-screen rhythm.
        let target = max(1, (contentWidth - g.gutter * CGFloat(cols - 1)) / CGFloat(cols))

        let rows = JustifiedRowsGeometry.rows(aspects: aspects,
                                              targetHeight: target,
                                              width: contentWidth,
                                              spacing: g.gutter)

        func contentTop(firstPage: Bool) -> CGFloat {
            g.margin + (firstPage ? g.firstPageHeaderHeight : 0)
        }
        func available(firstPage: Bool) -> CGFloat {
            max(1, contentBottom - contentTop(firstPage: firstPage))
        }

        var pages: [Page] = []
        var current = Page(placements: [])
        var used: CGFloat = 0
        var firstPage = true

        for row in rows {
            var avail = available(firstPage: firstPage)
            var rowHeight = min(row.height + g.captionHeight, avail)

            if !current.placements.isEmpty, used + rowHeight > avail {
                pages.append(current)
                current = Page(placements: [])
                used = 0
                firstPage = false
                avail = available(firstPage: firstPage)
                rowHeight = min(row.height + g.captionHeight, avail)
            }

            var x = g.margin
            let y = contentTop(firstPage: firstPage) + used
            for item in row.items {
                current.placements.append(
                    Placement(index: item.index,
                              rect: CGRect(x: x, y: y,
                                           width: item.width, height: rowHeight)))
                x += item.width + g.gutter
            }
            used += rowHeight + g.gutter
        }

        if !current.placements.isEmpty { pages.append(current) }
        return pages
    }
```

Also extend the file's header comment — it currently says "using a masonry (shortest-column) pack":

```swift
//  Pure pagination of a collection's images into fixed-size PDF pages. Two
//  packs, mirroring the on-screen layouts: `paginate` is the masonry
//  (shortest-column) pack used by Columns and — fed a uniform aspect — Grid;
//  `paginateRows` is the justified-rows pack used by Rows. No I/O —
//  deterministic and unit-tested. Coordinates use a TOP-LEFT origin (y grows
//  downward); the exporter flips to PDF's bottom-left origin when drawing.
```

- [ ] **Step 4: Let the exporter choose the pack**

In `Muse/Muse/Export/CollectionPDFExporter.swift`, change the signature — replace `layoutAspect: CGFloat?` with `layout: ImageLayout` (and update the doc comment's mention of `layoutAspect`):

```swift
    static func makePDF(urls: [URL], title: String, count: Int, columns: Int,
                        layout: ImageLayout,
                        tagLabels: [String] = [],
                        pageSize: CGSize = PaperSize.default.size) async -> URL? {
```

Then replace the aspects/paginate block (~120-124):

```swift
            // Mirror the on-screen grid: Grid gives every tile a uniform aspect
            // (an even row-major lattice), Rows justifies each row to the
            // content width, Columns packs each image's own aspect.
            let pages: [CollectionPDFLayout.Page]
            if layout == .rows {
                pages = CollectionPDFLayout.paginateRows(
                    aspects: images.map(\.aspect), geometry: geo)
            } else {
                let aspects: [CGFloat] = layout.aspect
                    .map { Array(repeating: $0, count: images.count) }
                    ?? images.map(\.aspect)
                pages = CollectionPDFLayout.paginate(aspects: aspects, geometry: geo)
            }
```

In `Muse/Muse/Views/CollectionPDFSave.swift`, replace the `layoutAspect` local and the call argument:

```swift
        let layout = appState.imageLayout
```

```swift
            urls: urls, title: title, count: urls.count, columns: gridColumns,
            layout: layout,
            tagLabels: tagLabels, pageSize: paper.size
```

- [ ] **Step 5: Build, test, verify**

Run: `xcodebuild -project Muse/Muse.xcodeproj -scheme Muse test -only-testing:MuseTests/CollectionPDFLayoutTests`
Expected: PASS.

Run: `xcodebuild -project Muse/Muse.xcodeproj -scheme Muse test`
Expected: PASS.

By hand: open a collection with 30+ mixed-shape images, export a PDF in each of the three modes. Rows must show justified rows with no split rows across pages; no mode may draw a grey box behind a photo; the first page must clear the header.

- [ ] **Step 6: Commit**

```bash
git add Muse/Muse/Export/CollectionPDFLayout.swift Muse/Muse/Export/CollectionPDFExporter.swift Muse/Muse/Views/CollectionPDFSave.swift Muse/MuseTests/CollectionPDFLayoutTests.swift
git commit -m "feat: Rows layout in the collection PDF export

paginateRows lays out the same JustifiedRowsGeometry rows the grid uses and
only decides page breaks, so print matches screen. Columns and Grid keep the
existing masonry pack (Grid via a uniform aspect)."
```

---

### Task 8: Localization and documentation

New strings must ship translated — French exists, so any untranslated string is a regression. Then record the durable rules so a future session doesn't undo them.

**Files:**
- Modify: `Muse/Muse/Localizable.xcstrings`
- Modify: `CLAUDE.md` (implementation-status row; durable constraints)
- Modify: `docs/architecture-map.md`
- Modify: `docs/session-log.md`

**Interfaces:** none — documentation and catalog only.

- [ ] **Step 1: Export and fill the French catalog**

Run:

```bash
xcodebuild -exportLocalizations -project Muse/Muse.xcodeproj \
  -localizationPath /tmp/muse-loc -exportLanguage fr
```

This write-backs every key into the source `.xcstrings` (a plain build does not). Then fill the French values for the new keys:

| English | French |
|---|---|
| Columns | Colonnes |
| Rows | Rangées |
| Grid | Grille |
| Choose how images are arranged. Every mode draws each image at its own shape — nothing is cropped. Applies to every grid. | Choisissez la disposition des images. Chaque mode affiche l'image à sa forme naturelle — rien n'est rogné. S'applique à toutes les grilles. |
| Spacing between images | Espacement entre les images |
| Columns layout | Disposition Colonnes |
| Rows layout | Disposition Rangées |
| Grid layout | Disposition Grille |

The `<name> layout` accessibility labels come from `LayoutTile`'s
`.accessibilityLabel("\(layout.displayName) layout")`, which interpolates —
verify how that key appears in the catalog after export and translate the form
that's actually there.

Delete the keys that no longer exist: the ten ratio names (`1:1`, `9:16`, …),
the six Common Sizes descriptions (`Square medium format`, `Sony, Canon, Nikon,
35mm film`, `iPhone, Google Pixel, Samsung Galaxy, OnePlus`, `Instagram, large
format film`, `Medium format`, `Vertical video on most phones`), `Masonry`,
`TILE BACKGROUND`, `Automatic`, `Static`, `None`, `Auto`, `Light`, `Dark Grey`,
`Black`, `Tile background: %@`, and `Masonry always uses Auto. Pick a fixed
ratio to choose a backdrop.`

**Careful:** `Light`, `Auto` and `None` are also used by the MOOD swatches and
elsewhere. Only delete a key if `grep -rn "\"<key>\"" Muse --include="*.swift"`
finds no remaining reference. Do not prune keys reached via
`NSLocalizedString(variable)` — the extractor marks them stale even though they
are live (the standing case is the 14 Info-card metadata labels).

- [ ] **Step 2: Verify the catalog is complete**

Run the export again:

```bash
xcodebuild -exportLocalizations -project Muse/Muse.xcodeproj \
  -localizationPath /tmp/muse-loc2 -exportLanguage fr
```

Expected: reports 0 untranslated strings.

Then preview it (a one-shot arg, so it doesn't pollute later test runs — never `defaults write`):

```bash
open -n <path-to-built-Muse.app> --args -AppleLanguages "(fr)"
```

Check the layout sheet's three tiles and both slider tooltips. Longer French text overflows fixed-width controls — budget ~1.3× the English width; if a tile label truncates, add `.lineLimit(1)` + `.truncationMode(.tail)` + `.minimumScaleFactor(0.8)`.

- [ ] **Step 3: Update `CLAUDE.md`**

Add an implementation-status row after Polish 25:

```markdown
| Polish 26 — **Grid layout modes** (Columns/Rows/Grid; tile card + Tile Background deleted; spacing slider; one orientation truth) | ✅ shipped | `feat/grid-layout-modes` |
```

Add these durable constraints to the "Durable constraints & gotchas" list:

```markdown
- **Photos never draw a card; the ring/hover/badge hug the DRAWN photo rect, not the slot (2026-07-28).** An image tile's content stack is fitted via `.aspectRatio(_, contentMode: .fit)` — the same min-scale fit as `ViewerGeometry.fitWithin` — so in Grid mode (square slots) the selection ring, hover veil and star badge wrap the visible image instead of boxing empty air. `tileFrames` reports that FITTED rect: `HeroStage` runs `fitWithin` on it and fitting an already-fitted rect is the identity, so the flight endpoint is exact instead of depending on two caches agreeing. The drawn aspect comes from `ImageHeaderSizeCache` (the hero's own table) with `AspectRatioCache` only as a cold-start fallback — don't swap the priority, and don't "restore" `tileFrames` to the slot rect. With no fill the empty slot area isn't hit-testable, so the tile carries an explicit `.contentShape(Rectangle())` at the slot size: ring and hover hug the photo, the click TARGET stays the slot. Removing it makes a click beside a photo fall through to the background and clear the selection.
- **`ImageHeaderSizeCache` stores DISPLAY dimensions (EXIF orientation applied) — it is the single orientation truth (2026-07-28).** Orientations 5–8 store a landscape buffer that shows portrait. `AspectRatioCache.imageIOAspect` always honoured that; the header cache and `files.width/height` (which reads it) did not — so an ANALYZED rotated photo packed at a different shape from an UNANALYZED one beside it, and the hero flight took off from a wrong rect. The swap lives in `ImageHeaderSizeCache.displaySize(width:height:orientation:)` and is applied in `resolve` and by `ThumbnailCache.declaredPixelCount`'s prewarm. Don't re-add a raw `kCGImagePropertyPixelWidth/Height` read anywhere that feeds layout, and note `files.width/height` are now display dims (matching Preview); the pixel COUNT for the decode budget is orientation-invariant, so `withinDecodeBudget` is unaffected.
- **`ImageLayout.resolve` MUST map the legacy raws — `"masonry"` → `.columns`, any `r*` → `.grid` (2026-07-28).** The ten fixed ratios and the masonry default are live on users' disks; the unknown-value fallback would silently drop a ratio user into Columns, a visibly different layout. `ImageLayout.aspect` is deliberately KEPT (`nil` for Columns/Rows, `1` for Grid) — the parting-ripple damping and the PDF exporter both read it as "is this a uniform lattice?".
- **Rows layout = `JustifiedRowsGeometry`, and its trailing partial row is NOT justified.** Stretching it blows a single leftover image up to a full-width panorama. Per-item aspects are clamped to `[0.1, 10]` for PACKING only (a pathological panorama would otherwise force a sub-pixel row height) — the image still draws at its true shape. The PDF's `CollectionPDFLayout.paginateRows` consumes the SAME `rows(...)` output and only decides page breaks, which is what keeps print matching screen; don't fork the packing.
```

- [ ] **Step 4: Update `docs/architecture-map.md`**

Add `JustifiedRowsGeometry.swift` to the `Components/` section (pure justified-rows packing for the Rows layout, sibling of `MasonryGeometry`), and remove `TileBackground.swift` from the `Models/` section.

- [ ] **Step 5: Add a session-log entry**

Append a dated entry to `docs/session-log.md` under `feat/grid-layout-modes` covering: the two complaints that started it (ratio picker overcomplicated; the tile slab reading as a forced frame), the Atlas reference that turned two modes into three, each decision on record from the spec, the orientation inconsistency found mid-design and why it had to be fixed here, and the runtime checks performed.

- [ ] **Step 6: Full verification**

Run: `xcodebuild -project Muse/Muse.xcodeproj -scheme Muse test`
Expected: PASS, whole suite.

Run: `xcodebuild -project Muse/Muse.xcodeproj -scheme Muse build`
Expected: BUILD SUCCEEDED with no new warnings.

- [ ] **Step 7: Commit**

```bash
git add Muse/Muse/Localizable.xcstrings CLAUDE.md docs/architecture-map.md docs/session-log.md
git commit -m "docs: French strings + durable constraints for the grid layout modes"
```

---

## Self-review

**Spec coverage:**

| Spec section | Task |
|---|---|
| 1. Three layout modes + migration | Task 3 (modes, migration), Task 1 (Rows packing) |
| 2. No card behind photos; fitted shimmer; transparent PNGs; non-photo cards keep theirs | Task 5 |
| 3. Tile Background deleted (model, tests, AppState, AppSettings, MoodPickerView, tileFill, cardNameColor, PDF) | Task 4 |
| 4. Ring / hover / badge hug the photo; hit target stays the slot; same fit as the hero flight | Task 5 |
| 5. Rows geometry as a new pure unit; last row unstretched; aspect clamp; target from the column slider | Task 1 (unit), Task 3 (wiring) |
| 6. Spacing slider, 0–28, default 14, persisted | Task 6 |
| 7. One orientation truth | Task 2 |
| 8. PDF export follows | Task 4 (no backdrop), Task 7 (Rows pagination) |
| Localization | Task 8 |
| Testing (unit + runtime checks) | Tests in every task; runtime checks in Tasks 5, 6, 7, 8 |

**Type consistency:** `JustifiedRowsGeometry.rows(aspects:targetHeight:width:spacing:)` is defined in Task 1 and consumed with that exact signature in Task 3 (via `compute`) and Task 7 (directly). `ImageHeaderSizeCache.displaySize(width:height:orientation:)` is defined in Task 2 and used in Task 2's `resolve` and `ThumbnailCache`. `TileView.imageAspect` is added and passed in Task 5. `CollectionPDFExporter.makePDF` loses `tileBackdrop:` in Task 4 and swaps `layoutAspect:` for `layout:` in Task 7 — both call sites updated in the same tasks. `AppSettings.clampGridSpacing` / `gridSpacingRange` / `defaultGridSpacing` are defined and consumed in Task 6.

**Build-green ordering:** Tasks 1 and 2 are additive. Task 3 changes the enum and every consumer in one commit. Task 4 deletes `TileBackground` and every consumer in one commit. Tasks 5–7 are localized changes on top. No intermediate commit leaves the project unbuildable.
