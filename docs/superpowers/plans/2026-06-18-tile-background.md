# Tile Background Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let the user pick the backdrop behind grid content (None / Auto / Light / Dark Grey / Black) independent of the app mood, surfaced in the mood popover, and reflect that choice (plus the active ratio) in the collection PDF export.

**Architecture:** A pure `TileBackground` enum is the single source of truth for backdrop resolution. `AppState` holds the selected value (persisted via `AppSettings`, mirroring `ImageLayout`) and exposes a computed `tileFill` color the grid tiles draw. The PDF exporter gains two parameters — the active ratio and the resolved backdrop `CGColor?` — so the exported grid mirrors the on-screen grid; the PDF paper page stays white.

**Tech Stack:** Swift, SwiftUI, CoreGraphics/CoreText (PDF), XCTest, xcodebuild.

## Global Constraints

- The PDF **paper** page is always white — only per-image backdrops take the chosen color. (Spec: "the paper page of the pdf will always be white".)
- **Auto is the default** so existing users see no change until they opt in.
- Static values (verbatim): Light `MoodRGB(0.980, 0.980, 0.980)` (#FAFAFA), Dark Grey `MoodRGB(0.333, 0.333, 0.333)` (#555555), Black `MoodRGB(0.051, 0.051, 0.051)` (#0D0D0D).
- "Auto" is never labeled "grey" in the UI.
- Only two surfaces change: on-screen grid tiles + PDF export. The app/mood page background, hero viewer, collection cards, and `ImageLayoutSheet` previews are untouched.
- Pure logic is unit-tested; views and CG-drawing code are verified by build + manual run (project convention — no `AppSettings`/exporter unit tests exist).
- Build verify command (run from `Muse App/`):
  `xcodebuild -project Muse/Muse.xcodeproj -scheme Muse -destination 'platform=macOS' build`
- Test command (run from `Muse App/`):
  `xcodebuild -project Muse/Muse.xcodeproj -scheme Muse -destination 'platform=macOS' test`

---

### Task 1: `TileBackground` model

**Files:**
- Create: `Muse/Muse/Models/TileBackground.swift`
- Test: `Muse/MuseTests/TileBackgroundTests.swift`

**Interfaces:**
- Consumes: `MoodRGB` and `MoodPalette` from `Muse/Muse/Models/Mood.swift` (`MoodRGB` is `Equatable` with `r/g/b: Double` and `var color: Color`; `MoodPalette` has `tileRGB: MoodRGB` and `tileFill: Color`).
- Produces:
  - `enum TileBackground: String, CaseIterable, Identifiable { case none, auto, light, darkGrey, black }`
  - `var displayName: String`
  - `func backdropRGB(for mood: MoodPalette) -> MoodRGB?` — the single resolver (nil = transparent/no fill).
  - `func fill(for mood: MoodPalette) -> Color` — derived: `backdropRGB(for:)?.color ?? .clear`.
  - `static func resolve(_ raw: String?) -> TileBackground` — default `.auto`.

- [ ] **Step 1: Write the failing test**

Create `Muse/MuseTests/TileBackgroundTests.swift`:

```swift
import XCTest
@testable import Muse

final class TileBackgroundTests: XCTestCase {

    func testDisplayNames() {
        XCTAssertEqual(TileBackground.allCases.map(\.displayName),
                       ["None", "Auto", "Light", "Dark Grey", "Black"])
    }

    func testResolveDefaultsToAuto() {
        XCTAssertEqual(TileBackground.resolve(nil), .auto)
        XCTAssertEqual(TileBackground.resolve("bogus"), .auto)
        XCTAssertEqual(TileBackground.resolve("black"), .black)
    }

    func testNoneIsTransparent() {
        XCTAssertNil(TileBackground.none.backdropRGB(for: Mood.paperPalette))
    }

    func testAutoFollowsMoodTile() {
        XCTAssertEqual(TileBackground.auto.backdropRGB(for: Mood.paperPalette),
                       Mood.paperPalette.tileRGB)
        XCTAssertEqual(TileBackground.auto.backdropRGB(for: Mood.fallbackPalette),
                       Mood.fallbackPalette.tileRGB)
    }

    func testStaticValuesAreFixedAndIgnoreMood() {
        XCTAssertEqual(TileBackground.light.backdropRGB(for: Mood.fallbackPalette),
                       MoodRGB(r: 0.980, g: 0.980, b: 0.980))
        XCTAssertEqual(TileBackground.darkGrey.backdropRGB(for: Mood.paperPalette),
                       MoodRGB(r: 0.333, g: 0.333, b: 0.333))
        XCTAssertEqual(TileBackground.black.backdropRGB(for: Mood.paperPalette),
                       MoodRGB(r: 0.051, g: 0.051, b: 0.051))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run (from `Muse App/`): `xcodebuild -project Muse/Muse.xcodeproj -scheme Muse -destination 'platform=macOS' test`
Expected: FAIL — compile error, `Cannot find 'TileBackground' in scope`.

- [ ] **Step 3: Write minimal implementation**

Create `Muse/Muse/Models/TileBackground.swift`:

```swift
//
//  TileBackground.swift
//  Muse
//
//  The backdrop drawn behind grid content — the letterbox around aspect-fit
//  images and the background of non-image file cards. Decoupled from the app
//  mood: None (transparent), Auto (follows the mood tile color — the default),
//  and three fixed neutral densities (Light / Dark Grey / Black) for separating
//  images that would otherwise blend into the backdrop. Global; also carried
//  into the collection PDF export. `backdropRGB` is the single resolver.
//

import SwiftUI

enum TileBackground: String, CaseIterable, Identifiable {
    case none, auto, light, darkGrey, black

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .none:     return "None"
        case .auto:     return "Auto"
        case .light:    return "Light"
        case .darkGrey: return "Dark Grey"
        case .black:    return "Black"
        }
    }

    /// Resolved backdrop color, or `nil` for None (transparent — no fill drawn).
    /// Auto follows the mood's tile color; the static cases are fixed neutrals
    /// that ignore the mood.
    func backdropRGB(for mood: MoodPalette) -> MoodRGB? {
        switch self {
        case .none:     return nil
        case .auto:     return mood.tileRGB
        case .light:    return MoodRGB(r: 0.980, g: 0.980, b: 0.980)
        case .darkGrey: return MoodRGB(r: 0.333, g: 0.333, b: 0.333)
        case .black:    return MoodRGB(r: 0.051, g: 0.051, b: 0.051)
        }
    }

    /// SwiftUI fill for an on-screen grid tile. None → `.clear` (transparent).
    func fill(for mood: MoodPalette) -> Color {
        backdropRGB(for: mood)?.color ?? .clear
    }

    /// Parse a persisted raw value, defaulting to Auto when missing/unknown.
    static func resolve(_ raw: String?) -> TileBackground {
        raw.flatMap(TileBackground.init(rawValue:)) ?? .auto
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run (from `Muse App/`): `xcodebuild -project Muse/Muse.xcodeproj -scheme Muse -destination 'platform=macOS' test`
Expected: PASS — `TileBackgroundTests` all green.

- [ ] **Step 5: Commit**

```bash
git add Muse/Muse/Models/TileBackground.swift Muse/MuseTests/TileBackgroundTests.swift
git commit -m "feat: TileBackground model (None/Auto/Light/Dark Grey/Black)"
```

---

### Task 2: Persist + expose the selection in `AppState`

**Files:**
- Modify: `Muse/Muse/Settings/AppSettings.swift:82-88` (add a `tileBackground` accessor after `imageLayout`)
- Modify: `Muse/Muse/Models/AppState.swift:396-402` (add state after the Image layout block)

**Interfaces:**
- Consumes: `TileBackground` (Task 1); `AppState.moodPalette` (existing computed `MoodPalette`).
- Produces:
  - `AppSettings.tileBackground: TileBackground` (UserDefaults key `tileBackground`, default `.auto`).
  - `AppState.tileBackground: TileBackground` (`@Published`, persisted on set).
  - `AppState.tileFill: Color` (computed) — what grid tiles draw.

- [ ] **Step 1: Add the AppSettings accessor**

In `Muse/Muse/Settings/AppSettings.swift`, immediately before the final closing `}` (after the `imageLayout` accessor, currently lines 82-88), add:

```swift
    static let tileBackgroundKey = "tileBackground"

    /// Global grid tile backdrop. Default `.auto` (follows the mood). Unset → auto.
    static var tileBackground: TileBackground {
        get { TileBackground.resolve(UserDefaults.standard.string(forKey: tileBackgroundKey)) }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: tileBackgroundKey) }
    }
```

- [ ] **Step 2: Add the AppState state + computed fill**

In `Muse/Muse/Models/AppState.swift`, immediately after the `imageLayout` block (currently ends at line 402 with `}`), add:

```swift

    // MARK: - Tile background

    /// Global backdrop behind grid content (None / Auto / Light / Dark Grey /
    /// Black). Persisted; GridView reads `tileFill`.
    @Published var tileBackground: TileBackground = AppSettings.tileBackground {
        didSet { AppSettings.tileBackground = tileBackground }
    }

    /// The resolved tile backdrop for the current mood + selection.
    var tileFill: Color { tileBackground.fill(for: moodPalette) }
```

- [ ] **Step 3: Build to verify it compiles**

Run (from `Muse App/`): `xcodebuild -project Muse/Muse.xcodeproj -scheme Muse -destination 'platform=macOS' build`
Expected: `BUILD SUCCEEDED`.

- [ ] **Step 4: Commit**

```bash
git add Muse/Muse/Settings/AppSettings.swift Muse/Muse/Models/AppState.swift
git commit -m "feat: persist + expose AppState.tileBackground and tileFill"
```

---

### Task 3: Grid tiles draw the chosen backdrop

**Files:**
- Modify: `Muse/Muse/Views/GridView.swift:627` and `Muse/Muse/Views/GridView.swift:652`

**Interfaces:**
- Consumes: `AppState.tileFill` (Task 2).
- Produces: image tiles and non-image file cards fill with `appState.tileFill` instead of `appState.moodPalette.tileFill`.

Note: leave `appState.moodPalette.background` (line 575) and the selection-ring logic (line 493) unchanged — only the two tile-rectangle fills change.

- [ ] **Step 1: Change the image-tile fill**

In `Muse/Muse/Views/GridView.swift`, line 627, change:

```swift
                Rectangle()
                    .fill(appState.moodPalette.tileFill)
```

to:

```swift
                Rectangle()
                    .fill(appState.tileFill)
```

- [ ] **Step 2: Change the file-card fill**

In `Muse/Muse/Views/GridView.swift`, line 652 (the non-image card branch), change:

```swift
                Rectangle()
                    .fill(appState.moodPalette.tileFill)
```

to:

```swift
                Rectangle()
                    .fill(appState.tileFill)
```

- [ ] **Step 3: Build to verify it compiles**

Run (from `Muse App/`): `xcodebuild -project Muse/Muse.xcodeproj -scheme Muse -destination 'platform=macOS' build`
Expected: `BUILD SUCCEEDED`.

- [ ] **Step 4: Commit**

```bash
git add Muse/Muse/Views/GridView.swift
git commit -m "feat: grid tiles draw AppState.tileFill backdrop"
```

---

### Task 4: Tile Background section in the mood popover

**Files:**
- Modify: `Muse/Muse/Views/MoodPickerView.swift` (append a section to `body`; add a `TileSwatch` subview)

**Interfaces:**
- Consumes: `AppState.tileBackground` (Task 2), `AppState.moodPalette`, the existing `MoodSwatch` visual pattern.
- Produces: a "Tile Background" section with five swatches in two captioned groups (Automatic: None, Auto · Static: Light, Dark Grey, Black) that set `appState.tileBackground`.

- [ ] **Step 1: Append the section to the popover body**

In `Muse/Muse/Views/MoodPickerView.swift`, inside the outer `VStack(alignment: .leading, spacing: 16)` in `body`, add this block immediately after the sliders' `VStack { ... }.opacity(...).saturation(...).animation(...)` closure (i.e. just before the outer `VStack`'s closing `}` that is followed by `.padding(16)`):

```swift
            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("TILE BACKGROUND")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)

                HStack(alignment: .top, spacing: 14) {
                    tileGroup("Automatic", options: [.none, .auto])
                    Divider().frame(height: 52)
                    tileGroup("Static", options: [.light, .darkGrey, .black])
                }
            }
```

- [ ] **Step 2: Add the group + swatch helpers**

In `MoodPickerView`, add these methods/properties after the existing `binding(_:)` method (before the struct's closing `}`):

```swift
    @ViewBuilder
    private func tileGroup(_ caption: String, options: [TileBackground]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(caption)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.tertiary)
            HStack(spacing: 10) {
                ForEach(options) { option in
                    TileSwatch(option: option,
                               isSelected: appState.tileBackground == option,
                               moodFill: appState.moodPalette.tileFill,
                               action: { appState.tileBackground = option })
                }
            }
        }
    }
```

Then add the `TileSwatch` view at file scope (after the `MoodSwatch` struct):

```swift
// MARK: - Tile background swatch

private struct TileSwatch: View {
    let option: TileBackground
    let isSelected: Bool
    let moodFill: Color           // live mood tile color, shown for .auto
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                swatchFill
                    .frame(width: 28, height: 28)
                    .overlay(Circle().strokeBorder(
                        isSelected ? Color.accentColor : .primary.opacity(hovering ? 0.35 : 0.15),
                        lineWidth: isSelected ? 2 : 1))
                Text(option.displayName)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(isSelected ? .primary : .secondary)
            }
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }

    @ViewBuilder
    private var swatchFill: some View {
        switch option {
        case .none:
            // "No color" glyph: empty circle with a diagonal slash.
            ZStack {
                Circle().fill(.clear)
                Circle().strokeBorder(.primary.opacity(0.25), lineWidth: 1)
                Path { p in
                    p.move(to: CGPoint(x: 5, y: 23))
                    p.addLine(to: CGPoint(x: 23, y: 5))
                }
                .stroke(.primary.opacity(0.4), lineWidth: 1.5)
                .frame(width: 28, height: 28)
            }
        case .auto:
            // Live mood tile color — visibly changes when the mood changes.
            Circle().fill(moodFill)
        default:
            Circle().fill(option.backdropRGB(for: Mood.paperPalette)?.color ?? .clear)
        }
    }
}
```

Note: the `default` branch covers `.light/.darkGrey/.black`, whose `backdropRGB` ignores the mood argument — `Mood.paperPalette` is just a non-nil placeholder.

- [ ] **Step 3: Build to verify it compiles**

Run (from `Muse App/`): `xcodebuild -project Muse/Muse.xcodeproj -scheme Muse -destination 'platform=macOS' build`
Expected: `BUILD SUCCEEDED`.

- [ ] **Step 4: Manual visual check**

Run the app. Open the `paintpalette` popover. Confirm: the new "Tile Background" section appears below the sliders; tapping None makes image letterboxes/file cards transparent (page shows through); Light/Dark Grey/Black apply fixed tones globally; Auto matches the old grey and its swatch changes when you switch Light/Dark mood.

- [ ] **Step 5: Commit**

```bash
git add Muse/Muse/Views/MoodPickerView.swift
git commit -m "feat: Tile Background section in the mood popover"
```

---

### Task 5: Reflect ratio + backdrop in the PDF export

**Files:**
- Modify: `Muse/Muse/Export/CollectionPDFExporter.swift:20` (signature), `:59` (aspects), and `:79-94` (per-image backdrop fill)
- Modify: `Muse/Muse/Views/ShareCollectionButton.swift:61-65` (`makePDF()` passes the new args)

**Interfaces:**
- Consumes: `AppState.imageLayout.aspect` (`CGFloat?`), `AppState.tileBackground.backdropRGB(for:)` (Task 1), `AppState.moodPalette`.
- Produces: `CollectionPDFExporter.makePDF(urls:title:count:columns:layoutAspect:tileBackdrop:)` — the exported grid mirrors the on-screen ratio (uniform aspect for a fixed layout, per-image for masonry) and fills each image's backdrop with `tileBackdrop` (nil = no fill → white paper / transparent). Paper page stays white.

- [ ] **Step 1: Add the exporter parameters**

In `Muse/Muse/Export/CollectionPDFExporter.swift`, change the function signature (line 20) from:

```swift
    static func makePDF(urls: [URL], title: String, count: Int, columns: Int) async -> URL? {
```

to:

```swift
    static func makePDF(urls: [URL], title: String, count: Int, columns: Int,
                        layoutAspect: CGFloat?, tileBackdrop: CGColor?) async -> URL? {
```

- [ ] **Step 2: Make the layout reflect the active ratio**

In the same file, replace the pagination line (currently line 59):

```swift
            let pages = CollectionPDFLayout.paginate(aspects: images.map(\.aspect), geometry: geo)
```

with:

```swift
            // Mirror the on-screen grid: a fixed ratio gives every tile a
            // uniform aspect (even row-major grid); masonry uses each image's
            // own aspect.
            let aspects: [CGFloat] = layoutAspect.map { Array(repeating: $0, count: images.count) }
                ?? images.map(\.aspect)
            let pages = CollectionPDFLayout.paginate(aspects: aspects, geometry: geo)
```

- [ ] **Step 3: Fill each image's backdrop before drawing**

In the same file, inside the `for pl in page.placements` loop, after the `let fit = aspectFit(...)` line and immediately before `ctx.draw(img, in: fit)` (currently line 94), insert:

```swift
                    // Per-image backdrop (mirrors the grid tile fill). nil = no
                    // fill, so the white paper shows through (transparent). The
                    // image is drawn on top; for a fixed ratio it letterboxes
                    // over this fill, for masonry the image covers it (the fill
                    // shows only through transparent images).
                    if let tileBackdrop {
                        ctx.setFillColor(tileBackdrop)
                        ctx.fill(flipped)
                    }
```

(The page-level white fill at lines 71-72 stays — the paper is always white.)

- [ ] **Step 4: Pass the new args from the caller**

In `Muse/Muse/Views/ShareCollectionButton.swift`, replace `makePDF()` (lines 61-65):

```swift
    private func makePDF() async -> URL? {
        let urls = imageURLs
        return await CollectionPDFExporter.makePDF(
            urls: urls, title: title, count: urls.count, columns: gridColumns)
    }
```

with:

```swift
    private func makePDF() async -> URL? {
        let urls = imageURLs
        let layoutAspect = appState.imageLayout.aspect
        let backdrop = appState.tileBackground
            .backdropRGB(for: appState.moodPalette)
            .map { CGColor(red: $0.r, green: $0.g, blue: $0.b, alpha: 1) }
        return await CollectionPDFExporter.makePDF(
            urls: urls, title: title, count: urls.count, columns: gridColumns,
            layoutAspect: layoutAspect, tileBackdrop: backdrop)
    }
```

- [ ] **Step 5: Build to verify it compiles**

Run (from `Muse App/`): `xcodebuild -project Muse/Muse.xcodeproj -scheme Muse -destination 'platform=macOS' build`
Expected: `BUILD SUCCEEDED`. (If the compiler reports `CGColor` unavailable in `ShareCollectionButton.swift`, it is provided via the existing `import SwiftUI`/`AppKit`; no new import is needed.)

- [ ] **Step 6: Manual export check**

Run the app. With a collection open: export (Save to…) once per backdrop option and confirm the PDF — paper stays white in all; None → images sit on white (color shows through transparent PNGs only); Black/Dark Grey/Light → that tone fills behind each image; switch the Image Layout to a fixed ratio (e.g. 1:1) and re-export → tiles are that ratio with the chosen color letterboxing the images.

- [ ] **Step 7: Run the full test suite**

Run (from `Muse App/`): `xcodebuild -project Muse/Muse.xcodeproj -scheme Muse -destination 'platform=macOS' test`
Expected: PASS — including `TileBackgroundTests`; `CollectionPDFLayoutTests` still green (pagination is unchanged).

- [ ] **Step 8: Commit**

```bash
git add Muse/Muse/Export/CollectionPDFExporter.swift Muse/Muse/Views/ShareCollectionButton.swift
git commit -m "feat: PDF export reflects grid ratio + tile backdrop (white paper)"
```

---

## Self-Review

**Spec coverage:**
- Five-option control (None/Auto/Light/Dark Grey/Black) → Task 1 (model) + Task 4 (UI). ✅
- Auto = default, mood-wired; statics fixed; values verbatim → Task 1. ✅
- Lives in mood popover, one stacked pane, two captioned groups, "Auto" not "grey", None slash glyph, live Auto swatch → Task 4. ✅
- Persisted like ImageLayout → Task 2. ✅
- Grid tiles (image + file card) use the choice; grid background unchanged → Task 3. ✅
- PDF export reflects ratio + backdrop; paper always white; None transparent → Task 5. ✅
- Out-of-scope surfaces untouched (hero, cards, layout sheet, selection ring) → no tasks touch them; Task 3 note guards the grid background + ring. ✅

**Placeholder scan:** No TBD/TODO; every code step shows full code. ✅

**Type consistency:** `TileBackground.backdropRGB(for:) -> MoodRGB?` and `fill(for:) -> Color` are defined in Task 1 and used identically in Tasks 2–5. `MoodRGB` fields `r/g/b` used consistently in the exporter `CGColor` conversion (Task 5) and tests (Task 1). `layoutAspect`/`tileBackdrop` parameter names match between exporter signature (Task 5 Step 1) and caller (Task 5 Step 4). ✅
