# Grid File Names + Native macOS File Visuals — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Show the real macOS type icon / content preview on non-image grid tiles, and add an off-by-default "Show file names" toggle that captions every tile.

**Architecture:** A pure `captionHeight` parameter on `MasonryGeometry` reserves a fixed strip per tile (mirroring the existing `CollectionPDFLayout.captionHeight`), keeping the precomputed-frames virtualization intact. `GridView` reads a new `AppSettings.showFileNames` flag and passes the caption height into both the geometry and each `TileView`. `TileView` splits into an image area + optional caption strip, and finally *displays* the QuickLook image (the macOS icon / content preview) on non-image cards instead of an SF Symbol.

**Tech Stack:** SwiftUI, AppKit, XCTest, GRDB (unaffected), QuickLookThumbnailing (supply side already done).

## Global Constraints

- Min macOS 14.6; `@MainActor` on `AppState`/UI; GRDB unaffected here.
- No network calls. No new dependencies.
- Files are never deleted; this plan touches only layout/display + a setting.
- UI views are not unit-tested (project convention); only pure logic (`MasonryGeometry`) gets XCTest coverage. Everything else is verified by `xcodebuild build` + the full `MuseTests` suite staying green + a live run.
- The "Show file names" setting defaults **OFF** (`UserDefaults … as? Bool ?? false`).
- The collection-PDF export (`Export/CollectionPDFLayout.swift`, `Export/CollectionPDFExporter.swift`) must NOT change — it always renders filenames regardless of the setting.
- Supply side already shipped: `ThumbnailCache.generate()` requests `representationTypes: .all` (committed). Do not revert it.
- Build command (run from repo root):
  `xcodebuild -scheme Muse -configuration Debug build`
- Test command:
  `xcodebuild -scheme Muse -destination 'platform=macOS' test`

---

### Task 1: MasonryGeometry — `captionHeight` parameter

**Files:**
- Modify: `Muse/Muse/Components/MasonryGeometry.swift`
- Test (create): `Muse/MuseTests/MasonryGeometryTests.swift`

**Interfaces:**
- Consumes: nothing (pure leaf).
- Produces: `MasonryGeometry.compute(aspects:columns:width:spacing:captionHeight:) -> Result` where the new trailing parameter `captionHeight: CGFloat = 0` adds a fixed strip to each tile's frame height. `Result` is unchanged (`frames: [CGRect]`, `totalHeight: CGFloat`). The `= 0` default keeps the single existing caller (`GridView.recompute`) compiling unchanged until Task 3 updates it.

- [ ] **Step 1: Write the failing tests**

Create `Muse/MuseTests/MasonryGeometryTests.swift`:

```swift
import XCTest
import CoreGraphics
@testable import Muse

final class MasonryGeometryTests: XCTestCase {

    // width 414, 2 columns, 14pt spacing → columnWidth = (414 - 14) / 2 = 200.

    func testCaptionHeightDefaultsToZero() {
        // No captionHeight argument → tile height is purely columnWidth × aspect.
        let r = MasonryGeometry.compute(aspects: [1.0], columns: 2,
                                        width: 414, spacing: 14)
        XCTAssertEqual(r.frames[0].width, 200, accuracy: 0.5)
        XCTAssertEqual(r.frames[0].height, 200, accuracy: 0.5)
    }

    func testCaptionHeightReservedPerTile() {
        let r = MasonryGeometry.compute(aspects: [1.0], columns: 2,
                                        width: 414, spacing: 14, captionHeight: 18)
        // tile = image(200 × 1.0) + 18pt caption strip.
        XCTAssertEqual(r.frames[0].width, 200, accuracy: 0.5)
        XCTAssertEqual(r.frames[0].height, 200 + 18, accuracy: 0.5)
    }

    func testTotalHeightIncludesCaption() {
        // Two square tiles, two columns → one row each. The caption adds 18pt
        // to the row's height, so totalHeight grows by exactly 18.
        let noCap = MasonryGeometry.compute(aspects: [1.0, 1.0], columns: 2,
                                            width: 414, spacing: 14)
        let withCap = MasonryGeometry.compute(aspects: [1.0, 1.0], columns: 2,
                                              width: 414, spacing: 14, captionHeight: 18)
        XCTAssertEqual(withCap.totalHeight - noCap.totalHeight, 18, accuracy: 0.5)
    }

    func testCaptionedTilesDoNotOverlapWithinColumn() {
        // 6 squares, 2 columns → 3 stacked per column. Once the caption strip is
        // reserved, each tile in a column must start at/after the previous one's
        // bottom (no overlap).
        let r = MasonryGeometry.compute(aspects: Array(repeating: 1.0, count: 6),
                                        columns: 2, width: 414, spacing: 14,
                                        captionHeight: 18)
        let byColumn = Dictionary(grouping: r.frames, by: { Int($0.minX.rounded()) })
        for (_, colFrames) in byColumn {
            let sorted = colFrames.sorted { $0.minY < $1.minY }
            for i in 1..<sorted.count {
                XCTAssertGreaterThanOrEqual(sorted[i].minY, sorted[i - 1].maxY - 0.5)
            }
        }
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `xcodebuild -scheme Muse -destination 'platform=macOS' test -only-testing:MuseTests/MasonryGeometryTests`
Expected: FAIL — the `captionHeight:` argument doesn't exist yet (compile error: "extra argument 'captionHeight' in call").

- [ ] **Step 3: Add the parameter to `compute`**

In `Muse/Muse/Components/MasonryGeometry.swift`, update the signature and the per-tile height line.

Change the signature from:

```swift
    static func compute(aspects: [CGFloat],
                        columns: Int,
                        width: CGFloat,
                        spacing: CGFloat) -> Result {
```

to:

```swift
    /// - Parameter captionHeight: a fixed strip added to every tile's height
    ///   (for an under-tile filename caption). 0 = no caption (default).
    static func compute(aspects: [CGFloat],
                        columns: Int,
                        width: CGFloat,
                        spacing: CGFloat,
                        captionHeight: CGFloat = 0) -> Result {
```

Change the height line from:

```swift
            let height = max(1, columnWidth * (aspect > 0 ? aspect : 1))
```

to:

```swift
            let height = max(1, columnWidth * (aspect > 0 ? aspect : 1)) + captionHeight
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `xcodebuild -scheme Muse -destination 'platform=macOS' test -only-testing:MuseTests/MasonryGeometryTests`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add Muse/Muse/Components/MasonryGeometry.swift Muse/MuseTests/MasonryGeometryTests.swift
git commit -m "Add captionHeight to MasonryGeometry (reserve per-tile caption strip)"
```

---

### Task 2: "Show file names" setting

**Files:**
- Modify: `Muse/Muse/Settings/AppSettings.swift`
- Modify: `Muse/Muse/Settings/SettingsView.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `AppSettings.showFileNamesKey` (String) and `AppSettings.showFileNames` (Bool, default false). `GridView` (Task 3) binds `@AppStorage(AppSettings.showFileNamesKey)`.

No unit test — this mirrors the existing `autoTag` UserDefaults accessor + a SwiftUI `Toggle`, neither of which is unit-tested. Verified by build + live run.

- [ ] **Step 1: Add the key + accessor to `AppSettings`**

In `Muse/Muse/Settings/AppSettings.swift`, inside `enum AppSettings`, after the `autoCollectionsKey` line add:

```swift
    static let showFileNamesKey = "showFileNames"
```

and after the `autoCollections` accessor add:

```swift
    /// Show each file's name beneath its thumbnail in the grid. Default false.
    /// Unset → treated as off.
    static var showFileNames: Bool {
        UserDefaults.standard.object(forKey: showFileNamesKey) as? Bool ?? false
    }
```

- [ ] **Step 2: Add the toggle to `SettingsView`**

In `Muse/Muse/Settings/SettingsView.swift`, add the `@AppStorage` property after the existing two:

```swift
    @AppStorage(AppSettings.showFileNamesKey) private var showFileNames = false
```

Then add a new `Section` inside the `Form`, after the existing "Automatic organization" section's closing brace:

```swift
            Section {
                Toggle("Show file names", isOn: $showFileNames)
            } header: {
                Text("Grid")
            } footer: {
                Text("Show each file's name beneath its thumbnail in the grid.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
```

- [ ] **Step 3: Build**

Run: `xcodebuild -scheme Muse -configuration Debug build`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4: Commit**

```bash
git add Muse/Muse/Settings/AppSettings.swift Muse/Muse/Settings/SettingsView.swift
git commit -m "Add 'Show file names' setting (default off)"
```

---

### Task 3: GridView + TileView — caption strip + native macOS card visuals

**Files:**
- Modify: `Muse/Muse/Views/GridView.swift`

**Interfaces:**
- Consumes: `MasonryGeometry.compute(…, captionHeight:)` (Task 1); `AppSettings.showFileNamesKey` (Task 2).
- Produces: a `TileView` that accepts `showFileNames: Bool` and `captionHeight: CGFloat`, renders the QuickLook image on non-image cards, and lays out an image area + optional caption strip. No downstream consumers.

This is one task because every change is in `GridView.swift` and they're interdependent for compilation (the `TileView` call site and the `TileView` definition must change together). Verified by build + full suite + live run.

- [ ] **Step 1: Add the setting + caption constant to `GridView`**

In `struct GridView`, after the existing `@AppStorage("gridColumnCount") private var gridColumns = 4` line, add:

```swift
    /// Off-by-default: show each file's name under its tile.
    @AppStorage(AppSettings.showFileNamesKey) private var showFileNames = false
    /// Fixed under-tile caption strip height (one line of `.caption`), constant
    /// across column counts — matches the collection-PDF export's fixed caption.
    private let captionStripHeight: CGFloat = 18

    /// The caption height actually reserved this render (0 when names are off).
    private var effectiveCaptionHeight: CGFloat {
        showFileNames ? captionStripHeight : 0
    }
```

- [ ] **Step 2: Pass the caption height into the geometry**

In `recompute(width:)`, change the `MasonryGeometry.compute` call from:

```swift
        let result = MasonryGeometry.compute(aspects: ratios,
                                             columns: gridColumns,
                                             width: width,
                                             spacing: spacing)
```

to:

```swift
        let result = MasonryGeometry.compute(aspects: ratios,
                                             columns: gridColumns,
                                             width: width,
                                             spacing: spacing,
                                             captionHeight: effectiveCaptionHeight)
```

- [ ] **Step 3: Re-pack when the setting toggles**

In `body`, after the existing `.onChange(of: gridColumns) { … }` block, add:

```swift
            .onChange(of: showFileNames) { _, _ in
                withAnimation(.easeInOut(duration: 0.25)) {
                    recompute(width: contentWidth)
                }
            }
```

- [ ] **Step 4: Pass the new params to `TileView` at the call site**

In `masonryCanvas(viewportHeight:)`, change the `TileView(…)` construction from:

```swift
                TileView(file: file, order: i, deletion: appState.deletion,
                         reportAspect: { [weak aspects] ratio in
                             aspects?.report(aspect: ratio,
                                              forStandardizedPath: file.url.standardizedFileURL.path)
                         })
```

to:

```swift
                TileView(file: file, order: i, deletion: appState.deletion,
                         showFileNames: showFileNames,
                         captionHeight: effectiveCaptionHeight,
                         reportAspect: { [weak aspects] ratio in
                             aspects?.report(aspect: ratio,
                                              forStandardizedPath: file.url.standardizedFileURL.path)
                         })
```

- [ ] **Step 5: Add the two stored properties to `TileView`**

In `private struct TileView`, after the `reportAspect` property add:

```swift
    /// Whether to show a filename caption strip below the tile.
    var showFileNames: Bool = false
    /// Reserved caption strip height (0 when names are off).
    var captionHeight: CGFloat = 0
```

- [ ] **Step 6: Restructure `TileView.body` into image area + caption strip**

Replace the entire `var body: some View { … }` of `TileView` (the block starting `tile` and ending at the `.task { … }` closure) with:

```swift
    var body: some View {
        VStack(spacing: 0) {
            imageContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if showFileNames {
                Text(file.basename)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .frame(height: captionHeight)
                    .padding(.horizontal, 4)
            }
        }
        .scaleEffect(hovering ? 1.025 : 1)
        .animation(.easeOut(duration: 0.18), value: hovering)
        .onHover { hovering = $0 }
        // Prototype's hidden-cell: the tile vanishes while its image is
        // flying/open so no ghost copy sits behind the hero stage.
        .opacity(appState.selectedFile?.url == file.url ? 0 : 1)
        // Never animated: the restore must land in the same frame the hero
        // unmounts (see the close-flight note in the original code).
        .animation(nil, value: appState.selectedFile?.url)
        // Delete = a quiet fade-out.
        .opacity(deletion.burningPaths.contains(file.url.path) ? 0 : 1)
        .animation(.easeOut(duration: 0.3),
                   value: deletion.burningPaths.contains(file.url.path))
        // Re-runs when the URL changes OR the file's content version bumps
        // (an in-place edit / iCloud sync).
        .task(id: TileLoadID(url: file.url, version: appState.contentToken(for: file))) {
            // 320 matches the hero viewer's first cache probe, so the open
            // flight starts from this exact bitmap with zero wait. Retry on nil
            // so a tile never stays grey: the QuickLook fallback (PDF, SVG,
            // fonts…) can transiently fail under load — a short backoff recovers
            // it instead of leaving a dead box.
            for attempt in 0..<4 {
                if let img = await ThumbnailCache.shared.thumbnail(
                    for: file.url,
                    size: CGSize(width: 320, height: 320),
                    order: order
                ) {
                    // Correct the tile's aspect from the real image BEFORE
                    // showing it, so the frame is already right when the image
                    // lands. Image kinds only: non-image cards keep their fixed
                    // labeled-card aspect (a QuickLook doc/icon thumbnail's
                    // proportions must not resize the card).
                    if isImageKind, img.size.width > 0 {
                        reportAspect(img.size.height / img.size.width)
                    }
                    thumbnail = img
                    return
                }
                if Task.isCancelled { return }
                if attempt < 3 {
                    try? await Task.sleep(nanoseconds: UInt64(300_000_000) * UInt64(attempt + 1))
                }
            }
        }
    }

    /// The image area: the thumbnail/preview/card, clipped, with the selection
    /// overlay and the global-frame reporter for the hero open/close flight.
    /// The caption strip (if any) sits below this, OUTSIDE the selection border.
    private var imageContent: some View {
        tile
            // Images sit square-cornered (edge-to-edge jigsaw pieces); only the
            // non-image file cards keep the rounded card look.
            .clipShape(RoundedRectangle(cornerRadius: isImageKind ? 0 : 8,
                                        style: .continuous))
            .overlay {
                // Selected (multi-select) OR the open file get an accent wash +
                // border, wrapping the image area only (Finder-style; the label
                // below stays unbordered). Inside the scaleEffect so it grows
                // with the hover zoom.
                if appState.selectedFiles.contains(file.url.standardizedFileURL.path)
                    || appState.selectedFile?.id == file.id {
                    RoundedRectangle(cornerRadius: isImageKind ? 0 : 8, style: .continuous)
                        .fill(Color.accentColor.opacity(0.22))
                        .overlay {
                            RoundedRectangle(cornerRadius: isImageKind ? 0 : 8, style: .continuous)
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

- [ ] **Step 7: Rework the `tile` ViewBuilder to display the macOS visual**

Replace the entire existing `tile` computed property (the `@ViewBuilder private var tile: some View { … }`) with:

```swift
    /// Images: natural aspect, fitted into the precomputed jigsaw frame.
    /// Other kinds: a grey card showing the native macOS icon / content preview.
    @ViewBuilder
    private var tile: some View {
        if isImageKind {
            // Placeholder stays put; the decoded image fades IN over it when it
            // lands, so a cold grid resolves as a soft fade.
            ZStack {
                Rectangle()
                    .fill(appState.moodPalette.tileFill)
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
                }
            }
            .animation(.easeOut(duration: 0.28), value: thumbnail != nil)
        } else {
            // Non-image card: the QuickLook image is the real macOS TYPE ICON
            // (zip/dmg/folder) or a CONTENT preview (PDF/doc), centered and
            // scaled to fit. Falls back to an SF Symbol only while loading / if
            // QuickLook genuinely fails.
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(appState.moodPalette.tileFill)
                if showFileNames {
                    // Name lives below the card (the body caption); show the
                    // icon/preview using the whole card.
                    cardIcon
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .padding(12)
                } else {
                    // Name sits inside the card near the bottom; the centered
                    // icon/preview fills the area above it and never overlaps
                    // (they're stacked, not layered).
                    VStack(spacing: 6) {
                        cardIcon
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        Text(file.basename)
                            .font(.caption)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                    }
                    .padding(10)
                }
            }
        }
    }

    /// The native macOS icon / content preview when QuickLook has delivered it,
    /// otherwise the kind's SF Symbol as a transient fallback.
    @ViewBuilder
    private var cardIcon: some View {
        if let img = thumbnail {
            Image(nsImage: img)
                .resizable()
                .aspectRatio(contentMode: .fit)
        } else {
            Image(systemName: iconName(for: file.kind))
                .font(.system(size: 30))
                .foregroundStyle(.secondary)
        }
    }
```

Leave `iconName(for:)` exactly as it is (still used by `cardIcon`'s fallback).

- [ ] **Step 8: Build**

Run: `xcodebuild -scheme Muse -configuration Debug build`
Expected: `** BUILD SUCCEEDED **`
(Ignore any SourceKit "Cannot find type … in scope" diagnostics — per CLAUDE.md they're cross-file noise that resolves at build time.)

- [ ] **Step 9: Run the full test suite**

Run: `xcodebuild -scheme Muse -destination 'platform=macOS' test`
Expected: all tests pass (the new `MasonryGeometryTests` + the existing suite green). No geometry regressions because non-caption callers pass `captionHeight` 0.

- [ ] **Step 10: Live verification (manual)**

Run the app. Confirm:
1. With "Show file names" **off** (default): photos show no text; a folder containing a `.zip`/`.pdf`/`.dmg`/other non-image file shows a grey card with the real macOS icon/preview centered and the filename inside near the bottom (tail-ellipsis on long names). Photo layout unchanged.
2. Toggle "Show file names" **on** in Settings (⌘,): every tile gets a filename caption *below* it, the grid re-packs to make room, and the non-image cards drop their internal name (icon only, name below). Long names truncate with `…`.
3. Selection border wraps the image area only; the caption sits below it.
4. A collection PDF export still shows filenames (unchanged) in both modes.

- [ ] **Step 11: Commit**

```bash
git add Muse/Muse/Views/GridView.swift
git commit -m "Grid: show native macOS file icons/previews + 'Show file names' captions"
```

---

## Self-Review

**Spec coverage:**
- Native macOS icon/preview on non-image tiles → Task 3 Step 7 (`cardIcon` renders `thumbnail`) + the already-shipped `.all` supply change. ✅
- "Show file names" toggle, default off → Task 2. ✅
- OFF: photos no text; cards show name inside near bottom → Task 3 Step 7 (`else` branch, `VStack` with bottom `Text`). ✅
- ON: name below every tile, masonry reserves space, cards drop internal name → Task 1 (`captionHeight`) + Task 3 Steps 2/6/7. ✅
- Truncate to tile width with trailing ellipsis → `.lineLimit(1)` + `.truncationMode(.tail)` in both the body caption (Step 6) and the card-internal name (Step 7). ✅
- Masonry alignment preserved → Task 1 reserves the strip per tile in the shared geometry; Task 3 splits the frame accordingly. ✅
- Collection PDF untouched → no task modifies `Export/`. ✅
- Selection border on image area only → Task 3 Step 6 (`imageContent` carries the overlay; caption is outside it). ✅
- Live toggle re-pack → Task 3 Step 3 (`onChange(of: showFileNames)`). ✅

**Placeholder scan:** No TBD/TODO; all steps carry complete code or exact commands. ✅

**Type consistency:** `captionHeight: CGFloat` is consistent across `MasonryGeometry.compute` (Task 1), `GridView.effectiveCaptionHeight` / `captionStripHeight` (Task 3 Step 1), and `TileView.captionHeight` (Task 3 Step 5). `showFileNames: Bool` consistent across `AppSettings` (Task 2), `GridView.@AppStorage` (Task 3 Step 1), and `TileView.showFileNames` (Task 3 Step 5). `AppSettings.showFileNamesKey` used identically in Tasks 2 and 3. `cardIcon` defined and used within Task 3. ✅
