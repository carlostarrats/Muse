# Image Layout Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a global "Image Layout" setting (masonry default + 11 fixed aspect ratios) chosen from a modal opened by a new toolbar button, applying instantly to every grid without cropping any image.

**Architecture:** A persisted `ImageLayout` enum lives on `AppState`. `GridView`'s existing `recompute()` feeds `MasonryGeometry` either each image's natural aspect (masonry) or a single uniform aspect (fixed-ratio) — uniform aspects make the existing shortest-column packer lay out an exact row-major grid, so no new geometry engine is needed. The tile already renders a `tileFill` grey rectangle behind a `.fit` image, so letterbox fill is free; we only suppress the aspect-feedback that reshapes masonry tiles. A new `ImageLayoutSheet` (styled like `InfoSheet`) selects the layout.

**Tech Stack:** Swift / SwiftUI / AppKit, Xcode 16, GRDB, XCTest (`MuseTests`).

## Global Constraints

- Min macOS: **14.6**. No new dependencies; no network calls (sandbox forbids it).
- **Grid must stay virtualized** — never add a custom SwiftUI `Layout` or a non-lazy container over the full file set. Keep using `MasonryGeometry` precomputed frames + the viewport window in `GridView`.
- Fixed-ratio layouts **never crop**: image is `.fit`, centered, letterbox filled with `appState.moodPalette.tileFill` (the existing zip/non-image placeholder grey).
- The setting is **global** (all-tags / a single tag / inside a collection) — no per-folder override.
- Ratio names are **width:height**; `aspect` is **height ÷ width** (MasonryGeometry's convention). So `9:16` → tall tile (`16/9`), `16:9` → wide tile (`9/16`).
- Modal copy is exact: title "Image Layout", subtitle "Select an image layout. Applies globally", and the six Common Sizes rows below.
- Git repo root is `/Users/carlostarrats/Documents/Projects/Muse/Muse App`. Build/test from `/Users/carlostarrats/Documents/Projects/Muse/Muse App/Muse`.
- Build: `xcodebuild -scheme Muse -project Muse.xcodeproj build`
- Test: `xcodebuild -scheme Muse -project Muse.xcodeproj test -only-testing:MuseTests/<Class>`
- **SourceKit cross-file "Cannot find type" errors are noise** — only `xcodebuild` truth matters.

---

### Task 1: `ImageLayout` model + persistence

**Files:**
- Create: `Muse App/Muse/Muse/Models/ImageLayout.swift`
- Create: `Muse App/Muse/MuseTests/ImageLayoutTests.swift`
- Modify: `Muse App/Muse/Muse/Settings/AppSettings.swift`
- Modify: `Muse App/Muse/Muse/Models/AppState.swift` (after the mood block, ~line 394)

**Interfaces:**
- Produces:
  - `enum ImageLayout: String, CaseIterable, Identifiable` with cases `masonry, r1x1, r9x16, r16x9, r4x5, r5x4, r6x7, r7x6, r2x3, r3x2, r3x4, r4x3` (declaration order == modal display order).
  - `var displayName: String`, `var aspect: CGFloat?` (nil for masonry), `var iconKind: LayoutIconKind`.
  - `static func resolve(_ raw: String?) -> ImageLayout` (defaults `.masonry`).
  - `enum LayoutIconKind { case mason, square, portrait, landscape }`.
  - `AppSettings.imageLayout: ImageLayout` (get/set, UserDefaults key `"imageLayout"`).
  - `AppState.imageLayout: ImageLayout` (`@Published`, persists via `didSet`).

- [ ] **Step 1: Write the failing test**

Create `Muse App/Muse/MuseTests/ImageLayoutTests.swift`:

```swift
import XCTest
@testable import Muse

final class ImageLayoutTests: XCTestCase {

    func testAllCasesOrderMatchesWireframe() {
        XCTAssertEqual(ImageLayout.allCases.map(\.displayName),
                       ["Mason", "1:1", "9:16", "16:9",
                        "4:5", "5:4", "6:7", "7:6",
                        "2:3", "3:2", "3:4", "4:3"])
    }

    func testMasonryHasNoAspect() {
        XCTAssertNil(ImageLayout.masonry.aspect)
    }

    func testSquareAspectIsOne() {
        XCTAssertEqual(ImageLayout.r1x1.aspect, 1)
    }

    func testPortraitRatiosAreTallerThanWide() {
        // width:height with width < height → aspect (h/w) > 1.
        for layout in [ImageLayout.r9x16, .r4x5, .r6x7, .r2x3, .r3x4] {
            XCTAssertGreaterThan(layout.aspect ?? 0, 1, "\(layout) should be tall")
            XCTAssertEqual(layout.iconKind, .portrait)
        }
    }

    func testLandscapeRatiosAreWiderThanTall() {
        for layout in [ImageLayout.r16x9, .r5x4, .r7x6, .r3x2, .r4x3] {
            XCTAssertLessThan(layout.aspect ?? 99, 1, "\(layout) should be wide")
            XCTAssertEqual(layout.iconKind, .landscape)
        }
    }

    func testSpecificAspectValues() {
        XCTAssertEqual(ImageLayout.r9x16.aspect, 16.0 / 9, accuracy: 0.0001)
        XCTAssertEqual(ImageLayout.r16x9.aspect, 9.0 / 16, accuracy: 0.0001)
    }

    func testIconKindForMasonAndSquare() {
        XCTAssertEqual(ImageLayout.masonry.iconKind, .mason)
        XCTAssertEqual(ImageLayout.r1x1.iconKind, .square)
    }

    func testResolveDefaultsToMasonry() {
        XCTAssertEqual(ImageLayout.resolve(nil), .masonry)
        XCTAssertEqual(ImageLayout.resolve("bogus"), .masonry)
        XCTAssertEqual(ImageLayout.resolve("r3x4"), .r3x4)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd "/Users/carlostarrats/Documents/Projects/Muse/Muse App/Muse" && xcodebuild -scheme Muse -project Muse.xcodeproj test -only-testing:MuseTests/ImageLayoutTests`
Expected: FAIL to compile — "Cannot find 'ImageLayout' in scope".

- [ ] **Step 3: Write minimal implementation**

Create `Muse App/Muse/Muse/Models/ImageLayout.swift`:

```swift
//
//  ImageLayout.swift
//  Muse
//
//  How images are laid out on every grid. Masonry (default) packs each
//  image's natural aspect ratio; the fixed cases give every tile one ratio
//  and letterbox the image inside it (never cropping). Global — applies on
//  all-tags, a single tag, and inside a collection.
//

import CoreGraphics

enum ImageLayout: String, CaseIterable, Identifiable {
    case masonry
    case r1x1, r9x16, r16x9
    case r4x5, r5x4, r6x7, r7x6
    case r2x3, r3x2, r3x4, r4x3

    var id: String { rawValue }

    /// Label on the modal tile; for ratios it's also the size key.
    var displayName: String {
        switch self {
        case .masonry: return "Mason"
        case .r1x1:  return "1:1"
        case .r9x16: return "9:16"
        case .r16x9: return "16:9"
        case .r4x5:  return "4:5"
        case .r5x4:  return "5:4"
        case .r6x7:  return "6:7"
        case .r7x6:  return "7:6"
        case .r2x3:  return "2:3"
        case .r3x2:  return "3:2"
        case .r3x4:  return "3:4"
        case .r4x3:  return "4:3"
        }
    }

    /// Tile aspect as height ÷ width (MasonryGeometry's convention). `nil` for
    /// masonry, which uses each image's natural ratio. Names are width:height,
    /// so 9:16 → tall (16/9), 16:9 → wide (9/16).
    var aspect: CGFloat? {
        switch self {
        case .masonry: return nil
        case .r1x1:  return 1
        case .r9x16: return 16.0 / 9
        case .r16x9: return 9.0 / 16
        case .r4x5:  return 5.0 / 4
        case .r5x4:  return 4.0 / 5
        case .r6x7:  return 7.0 / 6
        case .r7x6:  return 6.0 / 7
        case .r2x3:  return 3.0 / 2
        case .r3x2:  return 2.0 / 3
        case .r3x4:  return 4.0 / 3
        case .r4x3:  return 3.0 / 4
        }
    }

    /// Which generic preview graphic the modal draws for this layout.
    var iconKind: LayoutIconKind {
        switch self {
        case .masonry: return .mason
        case .r1x1: return .square
        case .r9x16, .r4x5, .r6x7, .r2x3, .r3x4: return .portrait
        case .r16x9, .r5x4, .r7x6, .r3x2, .r4x3: return .landscape
        }
    }

    /// Parse a persisted raw value, defaulting to masonry when missing/unknown.
    static func resolve(_ raw: String?) -> ImageLayout {
        raw.flatMap(ImageLayout.init(rawValue:)) ?? .masonry
    }
}

/// The four generic preview graphics in the layout modal — quick context for
/// the ratio category, not an exact preview.
enum LayoutIconKind {
    case mason, square, portrait, landscape
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd "/Users/carlostarrats/Documents/Projects/Muse/Muse App/Muse" && xcodebuild -scheme Muse -project Muse.xcodeproj test -only-testing:MuseTests/ImageLayoutTests`
Expected: PASS (all 8 tests).

- [ ] **Step 5: Add the persistence accessor**

In `Muse App/Muse/Muse/Settings/AppSettings.swift`, add before the closing `}` (after the `collectionSortReversed` block, ~line 80):

```swift
    static let imageLayoutKey = "imageLayout"

    /// Global image layout for every grid. Default `.masonry`. Unset → masonry.
    static var imageLayout: ImageLayout {
        get { ImageLayout.resolve(UserDefaults.standard.string(forKey: imageLayoutKey)) }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: imageLayoutKey) }
    }
```

- [ ] **Step 6: Add the `@Published` property on AppState**

In `Muse App/Muse/Muse/Models/AppState.swift`, immediately after the `updateAutoMoodTimer()` method closes (~line 394), add:

```swift
    // MARK: - Image layout

    /// Global image layout for every grid (masonry default + fixed ratios).
    /// Persisted; GridView watches it and re-lays-out instantly.
    @Published var imageLayout: ImageLayout = AppSettings.imageLayout {
        didSet { AppSettings.imageLayout = imageLayout }
    }
```

- [ ] **Step 7: Build to verify it compiles**

Run: `cd "/Users/carlostarrats/Documents/Projects/Muse/Muse App/Muse" && xcodebuild -scheme Muse -project Muse.xcodeproj build`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 8: Commit**

```bash
cd "/Users/carlostarrats/Documents/Projects/Muse/Muse App"
git add Muse/Muse/Models/ImageLayout.swift Muse/MuseTests/ImageLayoutTests.swift Muse/Muse/Settings/AppSettings.swift Muse/Muse/Models/AppState.swift
git commit -m "feat: add ImageLayout model + global persisted setting"
```

---

### Task 2: Grid renders fixed-ratio layouts

**Files:**
- Modify: `Muse App/Muse/Muse/Views/GridView.swift` (`recompute` ~318-335; `onChange(of: aspects.version)` ~209; add a new `onChange` after ~211)
- Create: `Muse App/Muse/MuseTests/UniformGridLayoutTests.swift`

**Interfaces:**
- Consumes: `AppState.imageLayout` (Task 1), `MasonryGeometry.compute(aspects:columns:width:spacing:captionHeight:)` (existing), `appState.moodPalette.tileFill` (existing).
- Produces: no new symbols; `recompute()` behavior now branches on `appState.imageLayout.aspect`.

This task relies on the invariant that **uniform aspects fed to `MasonryGeometry` produce a row-major grid** (the shortest-column packer fills left-to-right when every tile is the same height). The test locks that invariant; the GridView edit uses it.

- [ ] **Step 1: Write the failing test**

Create `Muse App/Muse/MuseTests/UniformGridLayoutTests.swift`:

```swift
import XCTest
import CoreGraphics
@testable import Muse

/// The fixed-ratio Image Layout reuses MasonryGeometry by feeding every tile
/// the same aspect. These tests lock the invariant that equal aspects pack
/// into an exact, aligned, row-major grid (what the feature depends on).
final class UniformGridLayoutTests: XCTestCase {

    func testUniformAspectsFormAlignedRows() {
        // 7 items, 3 columns, square tiles.
        let aspects = [CGFloat](repeating: 1, count: 7)
        let r = MasonryGeometry.compute(aspects: aspects, columns: 3,
                                        width: 320, spacing: 10)
        XCTAssertEqual(r.frames.count, 7)

        // All tiles share one width and one height.
        let w = r.frames[0].width
        let h = r.frames[0].height
        for f in r.frames {
            XCTAssertEqual(f.width, w, accuracy: 0.5)
            XCTAssertEqual(f.height, h, accuracy: 0.5)
        }

        // First row sits at y == 0; row-major fill (item i in column i % 3).
        XCTAssertEqual(r.frames[0].minY, 0, accuracy: 0.5)
        XCTAssertEqual(r.frames[1].minY, 0, accuracy: 0.5)
        XCTAssertEqual(r.frames[2].minY, 0, accuracy: 0.5)
        // Item 3 starts the second row, back in column 0 (same x as item 0).
        XCTAssertEqual(r.frames[3].minX, r.frames[0].minX, accuracy: 0.5)
        XCTAssertGreaterThan(r.frames[3].minY, 0)
    }

    func testTallAspectMakesTallerTiles() {
        let square = MasonryGeometry.compute(aspects: [1, 1], columns: 2,
                                             width: 200, spacing: 0)
        let tall = MasonryGeometry.compute(aspects: [16.0/9, 16.0/9], columns: 2,
                                           width: 200, spacing: 0)
        XCTAssertGreaterThan(tall.frames[0].height, square.frames[0].height)
    }
}
```

- [ ] **Step 2: Run test to verify it passes (it documents existing behavior)**

Run: `cd "/Users/carlostarrats/Documents/Projects/Muse/Muse App/Muse" && xcodebuild -scheme Muse -project Muse.xcodeproj test -only-testing:MuseTests/UniformGridLayoutTests`
Expected: PASS. (This is a characterization test — `MasonryGeometry` already behaves this way. If it FAILS, stop: the uniform-grid assumption is wrong and Step 3 must be reconsidered.)

- [ ] **Step 3: Branch `recompute()` on the layout**

In `Muse App/Muse/Muse/Views/GridView.swift`, replace the body of `recompute(width:)` (currently lines ~318-335) with:

```swift
    private func recompute(width: CGFloat) {
        let files = appState.visibleFiles
        guard width > 0, !files.isEmpty else {
            frames = []
            totalHeight = 0
            layoutWidth = width
            return
        }
        // Fixed-ratio layouts give every tile one aspect (uniform aspects make
        // MasonryGeometry pack a row-major grid); masonry uses each image's
        // natural ratio from the cache.
        let ratios: [CGFloat]
        if let fixed = appState.imageLayout.aspect {
            ratios = Array(repeating: fixed, count: files.count)
        } else {
            ratios = files.map { aspects.aspect(for: $0) }
        }
        let result = MasonryGeometry.compute(aspects: ratios,
                                             columns: gridColumns,
                                             width: width,
                                             spacing: spacing,
                                             captionHeight: effectiveCaptionHeight)
        frames = result.frames
        totalHeight = result.totalHeight
        layoutWidth = width
    }
```

- [ ] **Step 4: Guard the aspect-feedback recompute + add the layout watcher**

In `Muse App/Muse/Muse/Views/GridView.swift`, replace the existing `onChange(of: aspects.version)` block (lines ~209-211):

```swift
            .onChange(of: aspects.version) { _, _ in
                recompute(width: contentWidth)
            }
```

with this (guard + new layout watcher):

```swift
            .onChange(of: aspects.version) { _, _ in
                // Fixed-ratio layouts ignore per-image aspects, so a decoded
                // thumbnail reporting its real ratio must NOT trigger a relayout
                // (it would churn the whole grid for no visual change).
                guard appState.imageLayout.aspect == nil else { return }
                recompute(width: contentWidth)
            }
            .onChange(of: appState.imageLayout) { _, _ in
                withAnimation(.easeInOut(duration: 0.25)) {
                    recompute(width: contentWidth)
                }
            }
```

> No tile-rendering change is needed: `TileView.tile` already draws `Rectangle().fill(appState.moodPalette.tileFill)` behind a `.aspectRatio(contentMode: .fit)` image, so a fixed-aspect frame letterboxes the image with the grey fill automatically, and the selection inset/ring already wrap the frame.

- [ ] **Step 5: Build to verify it compiles**

Run: `cd "/Users/carlostarrats/Documents/Projects/Muse/Muse App/Muse" && xcodebuild -scheme Muse -project Muse.xcodeproj build`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 6: Manually verify behavior (temporary default flip)**

The modal doesn't exist yet, so verify the grid by temporarily forcing a fixed layout. In `Muse App/Muse/Muse/Models/AppState.swift`, temporarily change the property initializer to `= .r9x16`, run the app (`xcodebuild ... build` then launch the built app, or Cmd+R in Xcode), open a folder of mixed-aspect images, and confirm:
- Every tile is the same tall (9:16) box, aligned in rows.
- No image is cropped; portrait/landscape images are centered with grey (`tileFill`) filling the gaps.
- Selection ring, hover veil, and captions still work.
- The column slider still changes the column count.

Then **revert** the initializer back to `= AppSettings.imageLayout`. (Take a screenshot for the review per the "get visual evidence early" practice.)

- [ ] **Step 7: Commit**

```bash
cd "/Users/carlostarrats/Documents/Projects/Muse/Muse App"
git add Muse/Muse/Views/GridView.swift Muse/MuseTests/UniformGridLayoutTests.swift
git commit -m "feat: render fixed-ratio image layouts in the grid"
```

---

### Task 3: The `ImageLayoutSheet` modal

**Files:**
- Create: `Muse App/Muse/Muse/Views/ImageLayoutSheet.swift`

**Interfaces:**
- Consumes: `ImageLayout` / `LayoutIconKind` (Task 1), `appState.imageLayout` (Task 1), `appState.moodPalette.tileFill` (existing).
- Produces: `struct ImageLayoutSheet: View { @Binding var isPresented: Bool }` — presented as a `.sheet` in Task 4.

- [ ] **Step 1: Create the modal view**

Create `Muse App/Muse/Muse/Views/ImageLayoutSheet.swift`:

```swift
//
//  ImageLayoutSheet.swift
//  Muse
//
//  Picks the global image layout (masonry default + fixed ratios). Styled to
//  match InfoSheet (24pt title, circular hover-X). Selecting a tile sets the
//  layout immediately — the grid re-lays-out live behind the open sheet.
//

import SwiftUI

struct ImageLayoutSheet: View {
    @Binding var isPresented: Bool
    @EnvironmentObject var appState: AppState

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 14),
                                count: 4)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Image Layout")
                    .font(.system(size: 24, weight: .semibold))
                Spacer()
                CloseButton { isPresented = false }
            }
            Text("Select an image layout. Applies globally")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .padding(.top, 4)
                .padding(.bottom, 20)

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 24) {
                    LazyVGrid(columns: columns, spacing: 14) {
                        ForEach(ImageLayout.allCases) { layout in
                            LayoutTile(
                                layout: layout,
                                isSelected: appState.imageLayout == layout,
                                tileFill: appState.moodPalette.tileFill
                            ) { appState.imageLayout = layout }
                        }
                    }
                    commonSizes
                }
                .padding(.bottom, 4)
            }
        }
        .padding(28)
        .frame(width: 640, height: 860)
    }

    // MARK: - Common Sizes

    private let sizes: [(String, String)] = [
        ("1:1", "Square medium format, iPhone"),
        ("2:3", "Sony, Canon, Nikon, 35mm film"),
        ("3:4", "iPhone, Google Pixel, Samsung Galaxy, OnePlus"),
        ("4:5", "Instagram, Large format film"),
        ("6:7", "Medium format"),
        ("9:16", "Video on most phones with camera support also"),
    ]

    private var commonSizes: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Common Sizes:")
                .font(.system(size: 15, weight: .semibold))
                .padding(.bottom, 6)
            ForEach(Array(sizes.enumerated()), id: \.offset) { idx, row in
                if idx > 0 { Divider().padding(.vertical, 12) }
                HStack(alignment: .firstTextBaseline, spacing: 16) {
                    Text(row.0)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .frame(width: 44, alignment: .leading)
                    Text(row.1)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    /// Circular ✕, hover-brightening — identical to InfoSheet's. Esc also closes.
    private struct CloseButton: View {
        var action: () -> Void
        @State private var hovering = false

        var body: some View {
            Button(action: action) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(hovering ? .primary : .secondary)
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(.primary.opacity(hovering ? 0.16 : 0.08)))
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .keyboardShortcut(.cancelAction)
            .help("Close")
        }
    }
}

/// One selectable layout tile. Mirrors the grid tile's selection feel but is
/// blue-only (the modal's single color change): selected → blue tint fill, blue
/// ring (8pt continuous corners), blue label, inset content; unselected → grey
/// tileFill box with a hover veil.
private struct LayoutTile: View {
    let layout: ImageLayout
    let isSelected: Bool
    let tileFill: Color
    let onTap: () -> Void

    @State private var hovering = false

    // Match TileView's locked selection constants.
    private static let hoverVeilOpacity = 0.2
    private static let selectionInset: CGFloat = 8
    private static let ringWidth: CGFloat = 2.5
    private static let ringCornerRadius: CGFloat = 8
    private static let selectionTintOpacity = 0.18

    private var blue: Color { Color.accentColor }

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 10) {
                Text(layout.displayName)
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(isSelected ? blue : .primary)
                LayoutIconView(kind: layout.iconKind,
                               color: isSelected ? blue : .secondary)
                    .frame(width: 56, height: 48)
            }
            .padding(isSelected ? Self.selectionInset : 0)
            .frame(maxWidth: .infinity)
            .frame(height: 132)
            .background(
                RoundedRectangle(cornerRadius: Self.ringCornerRadius, style: .continuous)
                    .fill(isSelected ? blue.opacity(Self.selectionTintOpacity) : tileFill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Self.ringCornerRadius, style: .continuous)
                    .fill(Color.black)
                    .opacity((hovering && !isSelected) ? Self.hoverVeilOpacity : 0)
                    .allowsHitTesting(false)
            )
            .overlay(
                Group {
                    if isSelected {
                        RoundedRectangle(cornerRadius: Self.ringCornerRadius, style: .continuous)
                            .strokeBorder(blue, lineWidth: Self.ringWidth)
                    }
                }
            )
            .clipShape(RoundedRectangle(cornerRadius: Self.ringCornerRadius, style: .continuous))
            .animation(.easeOut(duration: 0.18), value: hovering)
            .animation(.easeOut(duration: 0.15), value: isSelected)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel("\(layout.displayName) layout")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

/// One of the four generic preview graphics, drawn from simple cells so all
/// four share the same overall footprint. Quick context for the ratio, not a
/// literal preview.
private struct LayoutIconView: View {
    let kind: LayoutIconKind
    let color: Color

    var body: some View {
        GeometryReader { geo in
            let s = min(geo.size.width, geo.size.height)
            switch kind {
            case .square:    cellGrid(cols: 3, rows: 3, cellAspect: 1, side: s)
            case .portrait:  cellGrid(cols: 4, rows: 3, cellAspect: 1.7, side: s)
            case .landscape: cellGrid(cols: 3, rows: 4, cellAspect: 0.55, side: s)
            case .mason:     masonGrid(side: s)
            }
        }
    }

    /// A `cols × rows` grid of identical cells (cellAspect = height ÷ width).
    private func cellGrid(cols: Int, rows: Int, cellAspect: CGFloat, side: CGFloat) -> some View {
        let gap: CGFloat = 3
        return VStack(spacing: gap) {
            ForEach(0..<rows, id: \.self) { _ in
                HStack(spacing: gap) {
                    ForEach(0..<cols, id: \.self) { _ in
                        RoundedRectangle(cornerRadius: 1.5)
                            .fill(color)
                            .aspectRatio(1 / cellAspect, contentMode: .fit)
                    }
                }
            }
        }
        .frame(width: side, height: side)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// The masonry pattern: 4 columns of staggered bar heights.
    private func masonGrid(side: CGFloat) -> some View {
        let gap: CGFloat = 3
        // Per-column relative bar heights (sum drives the stagger).
        let cols: [[CGFloat]] = [[0.55, 0.41], [0.30, 0.66], [0.66, 0.30], [0.41, 0.55]]
        return HStack(spacing: gap) {
            ForEach(0..<cols.count, id: \.self) { c in
                VStack(spacing: gap) {
                    ForEach(0..<cols[c].count, id: \.self) { r in
                        RoundedRectangle(cornerRadius: 1.5)
                            .fill(color)
                            .frame(height: side * cols[c][r])
                    }
                }
            }
        }
        .frame(width: side, height: side)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
```

- [ ] **Step 2: Build to verify it compiles**

Run: `cd "/Users/carlostarrats/Documents/Projects/Muse/Muse App/Muse" && xcodebuild -scheme Muse -project Muse.xcodeproj build`
Expected: `** BUILD SUCCEEDED **` (the view is built but not yet presented anywhere — that's Task 4).

- [ ] **Step 3: Commit**

```bash
cd "/Users/carlostarrats/Documents/Projects/Muse/Muse App"
git add Muse/Muse/Views/ImageLayoutSheet.swift
git commit -m "feat: add ImageLayoutSheet modal"
```

---

### Task 4: Toolbar button + sheet presentation

**Files:**
- Modify: `Muse App/Muse/Muse/ContentView.swift` (state decl ~line 20; toolbar between ~146 and ~151; `.sheet` near ~226)

**Interfaces:**
- Consumes: `ImageLayoutSheet` (Task 3).
- Produces: a `.primaryAction` toolbar button between the Collections and Mood buttons that opens the sheet.

- [ ] **Step 1: Add the presentation state**

In `Muse App/Muse/Muse/ContentView.swift`, after `@State private var infoShown = false` (line 20), add:

```swift
    @State private var imageLayoutShown = false
```

- [ ] **Step 2: Add the toolbar button between Collections and Mood**

In `ContentView.swift`, between the Collections `ToolbarItem` (ends ~line 146) and the `// Mood and info grouped together` comment (~line 148), insert:

```swift
                // Image Layout — sits between Collections and the mood (color)
                // button. Opens the layout modal; the choice applies to every
                // grid instantly.
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        imageLayoutShown = true
                    } label: {
                        Image(systemName: "square.grid.2x2")
                    }
                    .help("Image Layout")
                    // Same as Collections: layout has no meaning over ranked
                    // search results.
                    .disabled(appState.isSearchActive)
                }
```

- [ ] **Step 3: Present the sheet**

In `ContentView.swift`, immediately after the existing info sheet (lines ~226-228):

```swift
        .sheet(isPresented: $infoShown) {
            InfoSheet(isPresented: $infoShown)
        }
```

add:

```swift
        .sheet(isPresented: $imageLayoutShown) {
            ImageLayoutSheet(isPresented: $imageLayoutShown)
                .environmentObject(appState)
        }
```

- [ ] **Step 4: Build to verify it compiles**

Run: `cd "/Users/carlostarrats/Documents/Projects/Muse/Muse App/Muse" && xcodebuild -scheme Muse -project Muse.xcodeproj build`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 5: Manually verify the whole feature**

Run the app, open a folder of mixed-aspect images, then:
- Confirm a grid button appears in the toolbar between Collections (`square.stack.3d.up`) and the color/palette button.
- Click it — the modal opens, styled like the info modal, with "Mason" selected (blue), 12 tiles in 4 columns, and the Common Sizes list below.
- Click `9:16` — the tile turns blue (fill, ring, label) and the grid behind re-lays-out instantly into tall, uniform, uncropped tiles with grey letterbox fill.
- Click a landscape ratio (e.g. `16:9`) — tiles become wide; still uncropped.
- Click `Mason` — returns to masonry. Close with the X (and with Esc).
- Quit and relaunch — the last-chosen layout persists.
- Switch into a tag filter and into a collection — the layout still applies.
- Confirm hover veil on unselected modal tiles and that the column slider still works in a fixed layout.

(Capture a screenshot of the modal + a fixed-ratio grid for the review.)

- [ ] **Step 6: Run the full test suite**

Run: `cd "/Users/carlostarrats/Documents/Projects/Muse/Muse App/Muse" && xcodebuild -scheme Muse -project Muse.xcodeproj test`
Expected: all tests pass (suite stays green).

- [ ] **Step 7: Commit**

```bash
cd "/Users/carlostarrats/Documents/Projects/Muse/Muse App"
git add Muse/Muse/ContentView.swift
git commit -m "feat: add Image Layout toolbar button + modal presentation"
```

---

## Self-Review Notes

- **Spec coverage:** data model + persistence (Task 1) ✓; global scope via `AppState` (Task 1) ✓; grid fixed-ratio rendering with no-crop letterbox grey (Task 2) ✓; instant animated change behind modal (Task 2 `onChange` + Task 4 sheet) ✓; modal styling/tiles/blue selection/Common Sizes (Task 3) ✓; toolbar button between Collections and Mood (Task 4) ✓; all existing tile behavior preserved (Task 2 note — no tile change) ✓.
- **Decision recorded:** the spec proposed a separate `UniformGridGeometry`; the plan instead reuses `MasonryGeometry` with uniform aspects (DRYer, same output), locked by `UniformGridLayoutTests`. Equivalent behavior, less code.
- **Type consistency:** `ImageLayout`, `LayoutIconKind`, `ImageLayout.resolve`, `AppSettings.imageLayout`, `AppState.imageLayout`, `ImageLayoutSheet(isPresented:)` are used identically across tasks.
- **No placeholders.** Every code step is complete.
