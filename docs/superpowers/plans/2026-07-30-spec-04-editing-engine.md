# Spec 04 — Editing Engine, Core Adjustments, Editor UI Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship Muse's non-destructive photo editor: edit model + Core Image/Metal render
pipeline, DB storage, the (Preview | Edit) editor UI inside the hero viewer, before/after +
versions, copy/paste/presets, and Edit-a-Copy round-trip to external apps — with every pixel
surface (grid thumbnails, hero viewer, PDF/Drive/share exports) rendering through the stack.

**Architecture:** A platform-neutral `Editing/` core (model, codec, render math — zero AppKit)
ported from Surface Camera's `PhotoRecipe`/`EditHistory`/`WorkingSpaceImage` patterns, extended
with a Core Image + Metal scene-referred render pipeline. Storage is per `(file_id,
parent_dir)` in new `edits`/`edit_versions`/`edit_presets` tables, mirrored into iCloud
sidecars. A `Models/EditStackIndex.swift` static index (installed at launch) lets every
pixel-consuming surface look up a file's stack hash/geometry with zero I/O; `EditRenderer`
renders through it. The editor itself lives inside the existing hero viewer as a
(Preview | Edit) mode swap — no new viewer, no change to hero open/close choreography.

**Tech Stack:** Swift 5 (MainActor default isolation), SwiftUI + AppKit escape hatches, GRDB
7.10, Core Image + Metal (`[[stitchable]]` kernels, no CIKL), `CIRAWFilter` hybrid RAW
pipeline, XCTest (pure-logic only, house convention — no UI unit tests).

## Global Constraints

- **Zero AppKit imports under `Editing/`** (and `Editing/Render/`) — Foundation/CoreGraphics/
  CoreImage/Metal only. Enforced by `EditingModuleImportTests` (a grep-based test). This is
  the platform-neutral-core rule (DECISIONS "Architecture & module structure").
- **`AppState` is frozen** — no new `@Published` properties, ever. New state lives in
  `Models/EditStore.swift` (Pattern B singleton, `ObservableObject`), observed directly by
  views. The grid reads `EditStore.generation` only through the existing `gridSignature`
  computed string (GridView.swift:677) — **zero cancellables**, not even a forwarded
  `objectWillChange`.
- **Migration numbering is fixed by DECISIONS**: this spec adds **v20 `edits` +
  `edit_versions`** and **v21 `edit_presets`** — separate migrations, registered at the end of
  `Database.makeMigrator()` (currently ending at `v12_smart_collections`,
  `Database/Database.swift:357`). Do not renumber; a future spec continues at v22+.
- **No `files.stack_hash` column, ever.** The edit stack is per `(file_id, parent_dir)` — the
  tags/notes grain — never content-keyed (`files.content_hash` is UNIQUE; a column on `files`
  would force two folders' copies of the same bytes to share one edit stack).
- **A neutral stack is a DELETED row**, never a stored no-op — "no edit" is the absence of an
  `edits` row (the `NoteStore.write` blank-deletes precedent).
- **Decoding never bumps `schemaVersion`/`processVersion`.** Only newly constructed stacks
  stamp `current`. A stack the renderer can't honor (newer schema, corrupt JSON, or
  `processVersion` beyond what this renderer knows) renders as the **original image**, never a
  partial stack, and the stored blob is left byte-identical — only an explicit user edit or
  Reset overwrites it.
- **Scene-referred rule**: adjustments run on un-clamped linear working-space data
  (`LinearImage`); the `EncodedImage → LinearImage` crossing happens exactly once per render.
  RAW white balance happens ONLY at demosaic (`CIRAWFilter.neutralTemperature/Tint`) — never
  `CITemperatureAndTint` on a RAW source's output.
- **Every scale-dependent parameter is a fraction of the source long edge**, scaled by the
  actual decode ratio — this is what makes thumbnail/screen/export renders agree, and
  `EditRenderConsistencyTests` is the permanent gate on any renderer change.
- **Preset application is copy-by-value.** No stack stores a preset reference; preset mutation
  happens only via explicit "Update Preset from This Photo" / "Save as New" actions.
- **Every surface that displays or ships a photo's pixels renders through the edit seam**
  (`EditStackIndex` → `EditRenderer`). Backup (`Backup/`) is the one deliberate exclusion — it
  restores originals by content hash.
- **Edits carry through every identity/folder rewrite** alongside tags/notes: the Indexer
  hash-collision (both branches) and shared-row-split sites, `FileMoveMigration.apply`,
  `FolderRenameMigration.apply` (including its stale-target pre-clear). A new rewrite path
  must carry `edits`/`edit_versions` too.
- **The sidecar's edit field is owner-gated**: only the edit-save/reset export path passes
  `editAuthoritative: true`; every other export preserves the on-disk edit value.
  `Sidecar.merge` resolves edits by the `edit_updated_at` field clock (greater non-nil wins;
  nil never clobbers).
- **Handing a file with Muse edits to an external app always forks** (Edit Original / Edit a
  Copy with Muse Adjustments) through the single `OpenWithItems.open(with:)` seam.
- **Editable kinds (Path A) are `.image` and `.raw` ONLY** — `.psd` is excluded (its flat
  composite is a preview; editing it belongs to "Edit a Copy").
- **Every new editor-adjacent surface reads `@Environment(\.theme)`** (`Views/Theme/
  Theme.swift`) — no raw hex, no ad-hoc constants. Pre-existing surfaces are NOT migrated.
- **House test convention: no UI unit tests.** All new tests are pure-logic
  (`nonisolated enum`/`struct` functions), added to the `MuseTests` target.
- **French localization is a hard requirement for every new user-facing string** — every
  literal is a SwiftUI text-literal position or `String(localized:)`. The build isn't done
  until an `-exportLocalizations -exportLanguage fr` pass reports 0 untranslated for new keys
  (Task 10.2).
- **`BUILD SUCCEEDED` is not proof of a working build** — `stat` the `.app`'s executable mtime
  before handing off any milestone for visual/manual verification (stale DerivedData/signing
  issue, documented in CLAUDE.md).
- Codebase note: verified present at plan-writing time (`plan-1` branch, 2026-07-30) — no
  Spec 01/02/03 code exists yet (migrations end at `v12_smart_collections`; no
  `EditStackIndex`/`EffectiveDimensions`/`OutputRender` files). File line numbers below are
  copied from spec-04-implementation.md (verified there against commit `cefa008`); re-confirm
  each with a fresh `grep -n` before editing, since the tree may have moved between commits.

---

## Build order (10 phases, matches spec-04 §13)

0. Spec 01 §3 seams (prerequisite plumbing — identity functions today, real by phase 4).
1. Edit model + codec + history + transfer (pure, no app dependency).
2. v20 schema + `EditRecordStore` + the five carry seams + sidecar fields/hydration.
3. Renderer core (WorkingImage → CurveLUT → kernels → chain → RawSource → goldens).
4. `EditStore` + provider + consumer sweep (thumbnails, hero, exports, grid badge).
5. Theme layer + editor shell (mode toggle, backdrop, panels, canvas, sliders, autosave).
6. Curve editor + WB eyedropper.
7. Before/after suite + snapshots + versions.
8. v21 schema + presets + copy/paste/sync.
9. Edit-a-Copy.
10. Docs + localization export pass.

Phases 1–3 are shippable invisibly (no UI change). Phase 4 is the first user-visible commit,
and the render-consistency gate (Task 3.8) must already be green before it lands.

---

## Phase 0 — Spec 01 §3 prerequisite seams

*Spec 04 depends on these existing (§0 of spec-04). They don't exist in the tree yet, so this
plan builds them first, to spec-01-implementation.md §3's text verbatim, as its own commit.
They are identity functions until Phase 4 installs the real provider — no user-visible change.*

### Task 0.1: `EditStackIndex` stub + provider protocol

**Files:**
- Create: `Muse/Muse/Models/EditStackIndex.swift`
- Test: `Muse/MuseTests/EditStackIndexTests.swift`

**Interfaces:**
- Produces: `EditStackIndex.stackHash(for: URL) -> String?`,
  `EditStackIndex.croppedSize(for: URL) -> CGSize?`,
  `EditStackIndex.installProvider(_ p: (any EditStackProviding)?)`,
  `protocol EditStackProviding: Sendable { func stackHash(for: URL) -> String?; func
  croppedSize(for: URL) -> CGSize? }`.

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import Muse

final class EditStackIndexTests: XCTestCase {
    override func tearDown() {
        EditStackIndex.installProvider(nil)
        super.tearDown()
    }

    func testNilProviderReturnsNilForEverything() {
        let url = URL(fileURLWithPath: "/tmp/a.jpg")
        XCTAssertNil(EditStackIndex.stackHash(for: url))
        XCTAssertNil(EditStackIndex.croppedSize(for: url))
    }

    func testInstalledProviderIsConsulted() {
        struct Stub: EditStackProviding {
            func stackHash(for url: URL) -> String? { "abc123" }
            func croppedSize(for url: URL) -> CGSize? { CGSize(width: 10, height: 20) }
        }
        EditStackIndex.installProvider(Stub())
        let url = URL(fileURLWithPath: "/tmp/a.jpg")
        XCTAssertEqual(EditStackIndex.stackHash(for: url), "abc123")
        XCTAssertEqual(EditStackIndex.croppedSize(for: url), CGSize(width: 10, height: 20))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -scheme Muse -only-testing:MuseTests/EditStackIndexTests test`
Expected: FAIL — "Cannot find 'EditStackIndex' in scope" (type doesn't exist yet).

- [ ] **Step 3: Write minimal implementation**

```swift
import Foundation

/// The identity of a file's non-destructive edit stack. `nil` = unedited (original bytes).
/// Keyed by standardized path, not `files.id` — deliberately NO `files.stack_hash` column
/// exists (see CLAUDE.md durable constraint). Lock-guarded nonisolated(unsafe) static,
/// the ImageHeaderSizeCache pattern, because it's read from the thumbnail pipeline off-main.
enum EditStackIndex {
    private static let lock = NSLock()
    private static nonisolated(unsafe) var provider: (any EditStackProviding)?

    static func stackHash(for url: URL) -> String? {
        lock.lock(); defer { lock.unlock() }
        return provider?.stackHash(for: url)
    }

    static func croppedSize(for url: URL) -> CGSize? {
        lock.lock(); defer { lock.unlock() }
        return provider?.croppedSize(for: url)
    }

    static func installProvider(_ p: (any EditStackProviding)?) {
        lock.lock(); defer { lock.unlock() }
        provider = p
    }
}

protocol EditStackProviding: Sendable {
    func stackHash(for url: URL) -> String?
    func croppedSize(for url: URL) -> CGSize?
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild -scheme Muse -only-testing:MuseTests/EditStackIndexTests test`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add "Muse/Muse/Models/EditStackIndex.swift" "Muse/MuseTests/EditStackIndexTests.swift"
git commit -m "feat(edit-seams): add EditStackIndex stack-hash seam (identity today)"
```

### Task 0.2: `ThumbnailCache` cache key incorporates stack hash

**Files:**
- Modify: `Muse/Muse/Filesystem/ThumbnailCache.swift` (`cacheKey`, `invalidate`)
- Test: `Muse/MuseTests/ThumbnailStackKeyTests.swift`

**Interfaces:**
- Consumes: `EditStackIndex.stackHash(for:)` (Task 0.1).
- Produces: `ThumbnailCache.cacheKey(url:size:scale:)` unchanged signature, new internal
  behavior; `invalidate(_:)` now loops `renderedVariants × {stackHash, nil}`.

- [ ] **Step 1: Read the current implementation**

Run: `grep -n "func cacheKey\|func invalidate" "Muse/Muse/Filesystem/ThumbnailCache.swift"`
to get exact current line numbers (spec cites ~line 347 and the `invalidate` loop over
`renderedVariants`; confirm before editing).

- [ ] **Step 2: Write the failing test**

```swift
import XCTest
@testable import Muse

final class ThumbnailStackKeyTests: XCTestCase {
    override func tearDown() {
        EditStackIndex.installProvider(nil)
        super.tearDown()
    }

    func testNilStackHashLeavesKeyByteIdenticalToPreChangeKey() {
        // Pin against a known-good pre-edit-awareness key for a fixed input.
        let url = URL(fileURLWithPath: "/tmp/fixture.jpg")
        let size = CGSize(width: 320, height: 320)
        let key = ThumbnailCache.cacheKey(url: url, size: size, scale: 2)
        // Recomputed by hand from "<standardized path>|320x320@2.0" SHA-256 — replace the
        // literal below with the actual SHA-256 hex once Step 3 lands (a pinned fixture,
        // not a live recompute, is what catches an accidental key-format change).
        XCTAssertEqual(key.count, 64) // SHA-256 hex length, sanity check pending the pin
    }

    func testStackHashChangesKeyFromNilVariant() {
        struct Stub: EditStackProviding {
            func stackHash(for url: URL) -> String? { "deadbeef" }
            func croppedSize(for url: URL) -> CGSize? { nil }
        }
        let url = URL(fileURLWithPath: "/tmp/fixture.jpg")
        let size = CGSize(width: 320, height: 320)
        let nilKey = ThumbnailCache.cacheKey(url: url, size: size, scale: 2)
        EditStackIndex.installProvider(Stub())
        let editedKey = ThumbnailCache.cacheKey(url: url, size: size, scale: 2)
        XCTAssertNotEqual(nilKey, editedKey)
    }
}
```

- [ ] **Step 3: Run test to verify it fails**

Run: `xcodebuild -scheme Muse -only-testing:MuseTests/ThumbnailStackKeyTests test`
Expected: FAIL (both keys currently identical — no stack awareness yet).

- [ ] **Step 4: Implement the cache-key change**

At the `cacheKey` site, build the raw string as:

```swift
var raw = "\(standardizedPath)|\(Int(size.width))x\(Int(size.height))@\(scale)"
if let hash = EditStackIndex.stackHash(for: url) {
    raw += "|\(hash)"
}
let key = SHA256.hash(data: Data(raw.utf8)).compactMap { String(format: "%02x", $0) }.joined()
```

Do NOT write `raw += "|\(hash ?? "")"` — that appends a trailing `|` in the nil case and
re-keys every cached PNG on upgrade (the whole point of this task is that the nil path stays
byte-identical to today's key).

- [ ] **Step 5: Implement the dual-variant `invalidate`**

At `invalidate(_:)`, find the existing loop over `renderedVariants` and wrap it to also try
the edited-stack variant when one exists:

```swift
func invalidate(_ url: URL) {
    let hashes: [String?] = [nil, EditStackIndex.stackHash(for: url)].uniqued()
    for size in Self.renderedVariants {
        for hash in hashes {
            let key = cacheKey(url: url, size: size, scale: 2, stackHashOverride: hash)
            // existing removal logic (memory + disk) using `key`
        }
    }
}
```

(Add a small `stackHashOverride` parameter to `cacheKey` so `invalidate` can force both
variants regardless of the CURRENT index state — the edited variant must be droppable even
after a revert flips the index back to nil.)

- [ ] **Step 6: Fill in the pinned-key literal from Step 2**

Run the test in isolation, print the actual computed nil-case key, paste it into the
`XCTAssertEqual` in Step 2's test body, replacing the sanity-only length check.

- [ ] **Step 7: Run tests to verify they pass**

Run: `xcodebuild -scheme Muse -only-testing:MuseTests/ThumbnailStackKeyTests -only-testing:MuseTests/ThumbnailVariantTests test`
Expected: PASS (both the new test and the existing `ThumbnailVariantTests`, which must stay
green).

- [ ] **Step 8: Commit**

```bash
git add "Muse/Muse/Filesystem/ThumbnailCache.swift" "Muse/MuseTests/ThumbnailStackKeyTests.swift"
git commit -m "feat(edit-seams): ThumbnailCache key + invalidate become stack-hash aware"
```

### Task 0.3: `EffectiveDimensions` geometry seam + consumer conversions

**Files:**
- Create: `Muse/Muse/Components/EffectiveDimensions.swift`
- Modify: `Muse/Muse/Views/GridView.swift` (`TileView.drawnAspectRatio`)
- Modify: `Muse/Muse/Views/Viewer/HeroStage.swift` (`resolveHeaderSize()`, the >40MP mid-res gate)
- Modify: `Muse/Muse/Viewers/FileMetadata.swift` (Dimensions/MP row)
- Modify: `Muse/Muse/Views/AspectRatioCache.swift` (`imageIOAspect` cold path)
- Test: `Muse/MuseTests/EffectiveDimensionsTests.swift`

**Interfaces:**
- Consumes: `EditStackIndex.croppedSize(for:)` (Task 0.1), `ImageHeaderSizeCache`
  (existing).
- Produces: `EffectiveDimensions.cached(_:) -> CGSize?`, `.resolve(_:) -> CGSize?`,
  `.aspect(_:) -> CGFloat?`.

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import Muse

final class EffectiveDimensionsTests: XCTestCase {
    override func tearDown() {
        EditStackIndex.installProvider(nil)
        super.tearDown()
    }

    func testFallsBackToHeaderCacheWhenNoCrop() {
        // With no provider installed, EffectiveDimensions must equal ImageHeaderSizeCache's
        // own answer for the same URL (identity behavior, Phase 0's whole point).
        let url = URL(fileURLWithPath: "/tmp/nonexistent.jpg")
        XCTAssertEqual(EffectiveDimensions.cached(url), ImageHeaderSizeCache.cached(url))
    }

    func testCroppedSizeOverridesHeaderWhenProviderReportsOne() {
        struct Stub: EditStackProviding {
            func stackHash(for url: URL) -> String? { "h" }
            func croppedSize(for url: URL) -> CGSize? { CGSize(width: 100, height: 50) }
        }
        EditStackIndex.installProvider(Stub())
        let url = URL(fileURLWithPath: "/tmp/nonexistent.jpg")
        XCTAssertEqual(EffectiveDimensions.cached(url), CGSize(width: 100, height: 50))
    }

    func testAspectDividesWidthByHeight() {
        struct Stub: EditStackProviding {
            func stackHash(for url: URL) -> String? { "h" }
            func croppedSize(for url: URL) -> CGSize? { CGSize(width: 100, height: 50) }
        }
        EditStackIndex.installProvider(Stub())
        let url = URL(fileURLWithPath: "/tmp/nonexistent.jpg")
        XCTAssertEqual(EffectiveDimensions.aspect(url), 2.0, accuracy: 0.0001)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -scheme Muse -only-testing:MuseTests/EffectiveDimensionsTests test`
Expected: FAIL — type doesn't exist.

- [ ] **Step 3: Write the implementation**

```swift
import Foundation

/// The crop-aware layout size for a file: EditStackIndex's cropped size when a stack
/// crops, else the header's (orientation-applied) display size. Layout consumers call
/// THIS, never ImageHeaderSizeCache directly — analysis and decode budgets are the only
/// callers that stay on ImageHeaderSizeCache (they must read ORIGINAL bytes).
enum EffectiveDimensions {
    static func cached(_ url: URL) -> CGSize? {
        EditStackIndex.croppedSize(for: url) ?? ImageHeaderSizeCache.cached(url)
    }

    static func resolve(_ url: URL) -> CGSize? {
        EditStackIndex.croppedSize(for: url) ?? ImageHeaderSizeCache.resolve(url)
    }

    static func aspect(_ url: URL) -> CGFloat? {
        guard let size = cached(url), size.height > 0 else { return nil }
        return size.width / size.height
    }
}
```

(Match `ImageHeaderSizeCache`'s exact `cached`/`resolve` method names and signatures at the
call site — `grep -n "func cached\|func resolve" Muse/Muse/Components/ImageHeaderSizeCache.swift`
first and adjust the two pass-through lines above if the real signatures differ.)

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild -scheme Muse -only-testing:MuseTests/EffectiveDimensionsTests test`
Expected: PASS

- [ ] **Step 5: Convert the four consumer call sites**

For each of `GridView.swift` (`TileView.drawnAspectRatio`), `HeroStage.swift`
(`resolveHeaderSize()` and the >40MP mid-res gate), `FileMetadata.swift` (Dimensions/MP row),
`AspectRatioCache.swift` (`imageIOAspect` cold path): `grep -n` the current
`ImageHeaderSizeCache` call, replace with the equivalent `EffectiveDimensions` call
(`cached`/`resolve` matching whichever the site already used), keeping every other line
untouched. Do NOT touch `ThumbnailCache.declaredPixelCount` or `VisionServices.analyze` —
those stay on `ImageHeaderSizeCache` by design (original-bytes rule).

- [ ] **Step 6: Build and run the full existing viewer/grid test suites**

Run: `xcodebuild -scheme Muse -only-testing:MuseTests/EffectiveDimensionsTests test`
(plus a full `xcodebuild -scheme Muse build` to confirm the four call-site edits compile)
Expected: BUILD SUCCEEDED, tests PASS.

- [ ] **Step 7: Commit**

```bash
git add "Muse/Muse/Components/EffectiveDimensions.swift" "Muse/Muse/Views/GridView.swift" \
  "Muse/Muse/Views/Viewer/HeroStage.swift" "Muse/Muse/Viewers/FileMetadata.swift" \
  "Muse/Muse/Views/AspectRatioCache.swift" "Muse/MuseTests/EffectiveDimensionsTests.swift"
git commit -m "feat(edit-seams): EffectiveDimensions geometry seam + 4 consumer conversions"
```

### Task 0.4: `OutputRender` export choke point

**Files:**
- Create: `Muse/Muse/Export/OutputRender.swift`
- Modify: `Muse/Muse/Export/CollectionPDFExporter.swift` (`imageIOThumbnail`)
- Modify: `Muse/Muse/Sharing/Drive/DriveClient.swift` (`uploadFile`)
- Modify: `Muse/Muse/Sharing/Drive/ImageMetadataStripper.swift` (`strip`, if a separate file —
  confirm with `grep -rn "func strip" Muse/Muse/Sharing/Drive/`)
- Modify: `Muse/Muse/Views/SelectionMenu.swift` (share picker)
- Modify: `Muse/Muse/Views/Viewer/ShareButton.swift` (share picker)
- Test: `Muse/MuseTests/OutputRenderTests.swift`

**Interfaces:**
- Produces: `struct RenderedOutput { let url: URL; let stackHash: String? }` (fileprivate
  init), `enum OutputRender { static func forOutput(_ url: URL) throws -> RenderedOutput;
  static func forOutput(_ urls: [URL]) throws -> [RenderedOutput]; static func image(_ out:
  RenderedOutput, maxPixel: Int) -> CGImage? }`.
- Consumes: `EditStackIndex.stackHash(for:)` (Task 0.1) — today `forOutput` is identity (Phase
  4 makes it render).

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import Muse

final class OutputRenderTests: XCTestCase {
    func testForOutputIsIdentityWhenNoStackExists() throws {
        let url = URL(fileURLWithPath: "/tmp/original.jpg")
        let out = try OutputRender.forOutput(url)
        XCTAssertEqual(out.url, url)
        XCTAssertNil(out.stackHash)
    }

    func testForOutputBatchPreservesOrder() throws {
        let urls = [URL(fileURLWithPath: "/tmp/a.jpg"), URL(fileURLWithPath: "/tmp/b.jpg")]
        let outs = try OutputRender.forOutput(urls)
        XCTAssertEqual(outs.map(\.url), urls)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -scheme Muse -only-testing:MuseTests/OutputRenderTests test`
Expected: FAIL — type doesn't exist.

- [ ] **Step 3: Write the implementation**

```swift
import Foundation
import CoreGraphics

/// Bytes approved for leaving the app. The ONLY way to obtain one is OutputRender —
/// RenderedOutput's init is fileprivate, so no other file can fabricate one. Backup is
/// the one deliberate exclusion (restores originals by content hash; never routes here).
struct RenderedOutput: Sendable {
    let url: URL
    let stackHash: String?
    fileprivate init(url: URL, stackHash: String?) {
        self.url = url
        self.stackHash = stackHash
    }
}

enum OutputRender {
    static func forOutput(_ url: URL) throws -> RenderedOutput {
        // Phase 0: identity — no renderer exists yet. Phase 4 replaces this body to
        // render through EditRenderer when EditStackIndex.stackHash(for: url) != nil.
        RenderedOutput(url: url, stackHash: EditStackIndex.stackHash(for: url))
    }

    static func forOutput(_ urls: [URL]) throws -> [RenderedOutput] {
        try urls.map { try forOutput($0) }
    }

    static func image(_ out: RenderedOutput, maxPixel: Int) -> CGImage? {
        // Phase 0: identity via the existing bounded ImageIO thumbnail path. Phase 4
        // routes edited outputs through EditRenderer.render instead.
        ThumbnailCache.imageIOThumbnail(url: out.url, maxPixel: maxPixel)
    }
}
```

(Confirm the exact existing bounded-decode helper name in `ThumbnailCache` via
`grep -n "func imageIOThumbnail" Muse/Muse/Filesystem/ThumbnailCache.swift` and match it.)

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild -scheme Muse -only-testing:MuseTests/OutputRenderTests test`
Expected: PASS

- [ ] **Step 5: Convert the four call sites**

- `CollectionPDFExporter.imageIOThumbnail`: change signature to take `RenderedOutput`; map
  the exporter's `urls` through `OutputRender.forOutput` once, up front, in the caller. Leave
  the QuickLook/video/audio fallback paths on raw `URL` (they carry no edit stack).
- `DriveClient.uploadFile`: change signature to `uploadFile(_ out: RenderedOutput, name:
  mime:parent:)`; `ImageMetadataStripper.strip` takes `RenderedOutput`. Order stays: render
  first (today: identity), strip second — do not reorder.
- `SelectionMenu.swift` share picker: wrap the call as
  `NSSharingServicePicker(items: try OutputRender.forOutput(fileURLs).map(\.url))`.
- `ShareButton.swift`: same pattern.
- Leave `Views/DriveShareForm.swift` untouched — it shares a text link, not pixels.

- [ ] **Step 6: Build and run the affected test suites**

Run: `xcodebuild -scheme Muse build` then
`xcodebuild -scheme Muse -only-testing:MuseTests/OutputRenderTests test`
Expected: BUILD SUCCEEDED, tests PASS.

- [ ] **Step 7: Commit**

```bash
git add "Muse/Muse/Export/OutputRender.swift" "Muse/Muse/Export/CollectionPDFExporter.swift" \
  "Muse/Muse/Sharing/Drive/DriveClient.swift" "Muse/Muse/Views/SelectionMenu.swift" \
  "Muse/Muse/Views/Viewer/ShareButton.swift" "Muse/MuseTests/OutputRenderTests.swift"
git commit -m "feat(edit-seams): OutputRender export choke point (identity today)"
```

*(If any of Task 0.4's Drive/PDF/share signatures also touch `ImageMetadataStripper`, include
that file in the same commit — it's part of the same seam, not a separate task.)*


## Phase 1 — Edit model, codec, history, transfer (pure, no app dependency)

### Task 1.1: `Editing/EditStack.swift` — the model

**Files:**
- Create: `Muse/Muse/Editing/EditStack.swift`
- Test: `Muse/MuseTests/EditStackNormalizeTests.swift`

**Interfaces:**
- Produces: `EditStack`, `Adjustment` (enum, cases `.tone/.color/.presence/.curve/.geometry/
  .vignette`, in that declaration order — canonical order — new cases must always APPEND),
  `ToneParams`, `ColorParams`, `PresenceParams`, `CurveParams` (+ `Point`), `GeometryParams`
  (+ `CropRect`), `VignetteParams`, `RawParams`, `Mask`.

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import Muse

final class EditStackNormalizeTests: XCTestCase {
    func testFreshStackIsNeutral() {
        let stack = EditStack.fresh()
        XCTAssertTrue(stack.isNeutral)
        XCTAssertEqual(stack.schemaVersion, EditStack.currentSchemaVersion)
        XCTAssertEqual(stack.processVersion, EditStack.currentProcessVersion)
        XCTAssertEqual(stack.masks, [])
    }

    func testDuplicateAdjustmentCaseKeepsLastOnNormalize() {
        var stack = EditStack.fresh()
        var a = ToneParams.neutral; a.exposureEV = 1
        var b = ToneParams.neutral; b.exposureEV = 2
        stack.adjustments = [.tone(a), .tone(b)]
        let normalized = stack.normalized()
        let toneCases = normalized.adjustments.filter {
            if case .tone = $0 { return true }; return false
        }
        XCTAssertEqual(toneCases.count, 1)
        if case .tone(let p) = toneCases[0] { XCTAssertEqual(p.exposureEV, 2) }
        else { XCTFail("expected .tone") }
    }

    func testNormalizeEnforcesCanonicalDeclarationOrder() {
        var stack = EditStack.fresh()
        stack.adjustments = [.vignette(.neutral), .tone(.neutral), .curve(.neutral)]
        let order = stack.normalized().adjustments.map { adj -> Int in
            switch adj {
            case .tone: return 0; case .color: return 1; case .presence: return 2
            case .curve: return 3; case .geometry: return 4; case .vignette: return 5
            }
        }
        XCTAssertEqual(order, order.sorted())
    }

    func testStackIsNeutralOnlyWhenEveryGroupAndRawParamsAreNeutral() {
        var stack = EditStack.fresh()
        stack.rawParams = RawParams(lensCorrection: false)
        XCTAssertFalse(stack.isNeutral)
    }

    func testToneParamsClampedBoundsExposure() {
        var p = ToneParams.neutral
        p.exposureEV = 99
        XCTAssertLessThanOrEqual(p.clamped().exposureEV, 5)
        p.exposureEV = -99
        XCTAssertGreaterThanOrEqual(p.clamped().exposureEV, -5)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -scheme Muse -only-testing:MuseTests/EditStackNormalizeTests test`
Expected: FAIL — no such module members.

- [ ] **Step 3: Write the model** (verbatim from spec-04-implementation.md §1.1 — this is a
direct copy, no invention needed: `EditStack`, `Mask`, `Adjustment`, `ToneParams`,
`ColorParams`, `PresenceParams`, `CurveParams`, `GeometryParams`, `VignetteParams`,
`RawParams`, each with the exact fields/ranges/comments shown there). Add `normalized()`:

```swift
extension EditStack {
    /// Canonical order = Adjustment's declaration order; drops duplicate cases keeping
    /// the LAST occurrence. Applied on decode and before encode/hash — see
    /// EditStackCodec (Task 1.2). The renderer never derives order from this array;
    /// it iterates its own fixed chain (Task 3.5).
    func normalized() -> EditStack {
        var seen: [Int: Adjustment] = [:]
        for (i, adj) in adjustments.enumerated() {
            seen[adj.canonicalIndex] = adj
            _ = i
        }
        var copy = self
        copy.adjustments = seen.keys.sorted().compactMap { seen[$0] }
        return copy
    }
}

private extension Adjustment {
    var canonicalIndex: Int {
        switch self {
        case .tone: 0; case .color: 1; case .presence: 2
        case .curve: 3; case .geometry: 4; case .vignette: 5
        }
    }
}
```

Add `isNeutral` on `EditStack`: `adjustments.allSatisfy { $0.isNeutralCase } &&
(rawParams?.isNeutral ?? true)` where `isNeutralCase` switches on each case's `.isNeutral`.
Add `static func fresh() -> EditStack` stamping `currentSchemaVersion`/`currentProcessVersion`
with empty `adjustments`/`masks`, `rawParams: nil`.

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild -scheme Muse -only-testing:MuseTests/EditStackNormalizeTests test`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add "Muse/Muse/Editing/EditStack.swift" "Muse/MuseTests/EditStackNormalizeTests.swift"
git commit -m "feat(editing): EditStack model — adjustments, params structs, normalize"
```

### Task 1.2: `Editing/EditStackCodec.swift` — canonical JSON + hash

**Files:**
- Create: `Muse/Muse/Editing/EditStackCodec.swift`
- Test: `Muse/MuseTests/EditStackCodecTests.swift`

**Interfaces:**
- Consumes: `EditStack` (Task 1.1).
- Produces: `EditStackCodec.encode(_:) throws -> String`, `.decode(_:) -> EditStack?`,
  `.hash(_:) -> String`.

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import Muse

final class EditStackCodecTests: XCTestCase {
    func fixtureStack() -> EditStack {
        var stack = EditStack.fresh()
        var tone = ToneParams.neutral; tone.exposureEV = 0.5; tone.contrast = 0.2
        stack.adjustments = [.tone(tone)]
        return stack
    }

    func testEncodeDecodeRoundTrips() throws {
        let stack = fixtureStack()
        let json = try EditStackCodec.encode(stack)
        let decoded = EditStackCodec.decode(json)
        XCTAssertEqual(decoded, stack.normalized())
    }

    func testHashIsStablePinnedFixture() throws {
        let json = try EditStackCodec.encode(fixtureStack())
        let hash = EditStackCodec.hash(fixtureStack())
        // Pin: hash must be deterministic across runs for the same canonical bytes.
        XCTAssertEqual(hash, EditStackCodec.hash(fixtureStack()))
        XCTAssertEqual(hash.count, 64)
        _ = json
    }

    func testDecodeReturnsNilForNewerSchemaVersion() throws {
        var stack = fixtureStack()
        stack.schemaVersion = EditStack.currentSchemaVersion + 1
        let json = try EditStackCodec.encode(stack)
        XCTAssertNil(EditStackCodec.decode(json))
    }

    func testDecodeReturnsNilForCorruptJSON() {
        XCTAssertNil(EditStackCodec.decode("{not valid json"))
    }

    func testDecodeNeverBumpsVersionOnUnchangedStack() throws {
        let stack = fixtureStack()
        let json = try EditStackCodec.encode(stack)
        let decoded = try XCTUnwrap(EditStackCodec.decode(json))
        let reencoded = try EditStackCodec.encode(decoded)
        XCTAssertEqual(json, reencoded)
    }

    func testMaskSlotRoundTripsEmpty() throws {
        let stack = fixtureStack()
        XCTAssertEqual(stack.masks, [])
        let json = try EditStackCodec.encode(stack)
        XCTAssertTrue(json.contains("\"masks\""))
        let decoded = try XCTUnwrap(EditStackCodec.decode(json))
        XCTAssertEqual(decoded.masks, [])
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -scheme Muse -only-testing:MuseTests/EditStackCodecTests test`
Expected: FAIL — type doesn't exist.

- [ ] **Step 3: Write the implementation**

```swift
import Foundation
import CryptoKit

nonisolated enum EditStackCodec {
    private static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return e
    }

    static func encode(_ stack: EditStack) throws -> String {
        let data = try encoder.encode(stack.normalized())
        return String(decoding: data, as: UTF8.self)
    }

    static func decode(_ json: String) -> EditStack? {
        guard let data = json.data(using: .utf8),
              let stack = try? JSONDecoder().decode(EditStack.self, from: data),
              stack.schemaVersion <= EditStack.currentSchemaVersion
        else { return nil }
        return stack.normalized()
    }

    static func hash(_ stack: EditStack) -> String {
        guard let json = try? encode(stack), let data = json.data(using: .utf8) else {
            return SHA256.hash(data: Data()).compactMap { String(format: "%02x", $0) }.joined()
        }
        return SHA256.hash(data: data).compactMap { String(format: "%02x", $0) }.joined()
    }
}
```

`Adjustment` needs a custom `Codable` conformance (keyed wrapper `{"type": "...", "params":
{...}}`) added in Task 1.1's file — an unknown `type` on decode must throw (fail the whole
stack decode), not silently drop a case. Add this now if Task 1.1 didn't already:

```swift
extension Adjustment: Codable {
    private enum CodingKeys: String, CodingKey { case type, params }
    private enum Kind: String, Codable {
        case tone, color, presence, curve, geometry, vignette
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(Kind.self, forKey: .type) {
        case .tone: self = .tone(try c.decode(ToneParams.self, forKey: .params))
        case .color: self = .color(try c.decode(ColorParams.self, forKey: .params))
        case .presence: self = .presence(try c.decode(PresenceParams.self, forKey: .params))
        case .curve: self = .curve(try c.decode(CurveParams.self, forKey: .params))
        case .geometry: self = .geometry(try c.decode(GeometryParams.self, forKey: .params))
        case .vignette: self = .vignette(try c.decode(VignetteParams.self, forKey: .params))
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .tone(let p): try c.encode(Kind.tone, forKey: .type); try c.encode(p, forKey: .params)
        case .color(let p): try c.encode(Kind.color, forKey: .type); try c.encode(p, forKey: .params)
        case .presence(let p): try c.encode(Kind.presence, forKey: .type); try c.encode(p, forKey: .params)
        case .curve(let p): try c.encode(Kind.curve, forKey: .type); try c.encode(p, forKey: .params)
        case .geometry(let p): try c.encode(Kind.geometry, forKey: .type); try c.encode(p, forKey: .params)
        case .vignette(let p): try c.encode(Kind.vignette, forKey: .type); try c.encode(p, forKey: .params)
        }
    }
}
```

(An unknown `Kind` raw value throws a `DecodingError` from `c.decode(Kind.self, ...)`
automatically — `JSONDecoder().decode(EditStack.self, ...)` then throws, and
`EditStackCodec.decode` catches it as `nil`. This is the "unknown type fails the whole
decode" behavior the test suite pins.)

- [ ] **Step 4: Run test to verify it passes, fill in the pinned hash**

Run: `xcodebuild -scheme Muse -only-testing:MuseTests/EditStackCodecTests test`
Print the actual hash from `testHashIsStablePinnedFixture`, and add a second assertion
literal-pinning it (`XCTAssertEqual(hash, "<actual 64-char hex>")`) so a future encoder
change is caught, not just self-consistency.
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add "Muse/Muse/Editing/EditStack.swift" "Muse/Muse/Editing/EditStackCodec.swift" \
  "Muse/MuseTests/EditStackCodecTests.swift"
git commit -m "feat(editing): EditStackCodec — canonical JSON, hash, keyed Adjustment coding"
```

### Task 1.3: `Editing/EditHistory.swift` — session-only undo (Surface port)

**Files:**
- Create: `Muse/Muse/Editing/EditHistory.swift`
- Test: `Muse/MuseTests/EditHistoryTests.swift`

**Interfaces:**
- Consumes: `EditStack` (Task 1.1).
- Produces: `struct EditHistory { init(initial: EditStack); var current: EditStack { get };
  mutating func push(_ state: EditStack); mutating func undo() -> EditStack?; mutating func
  redo() -> EditStack?; var canUndo: Bool; var canRedo: Bool }`.

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import Muse

final class EditHistoryTests: XCTestCase {
    func stack(_ ev: Double) -> EditStack {
        var s = EditStack.fresh()
        var t = ToneParams.neutral; t.exposureEV = ev
        s.adjustments = [.tone(t)]
        return s
    }

    func testPushDedupesIdenticalState() {
        var h = EditHistory(initial: stack(0))
        h.push(stack(1))
        h.push(stack(1)) // identical to current — must not push a second entry
        XCTAssertTrue(h.canUndo)
        _ = h.undo()
        XCTAssertFalse(h.canUndo) // only one real push happened
    }

    func testTruncatesForwardOnPushAfterUndo() {
        var h = EditHistory(initial: stack(0))
        h.push(stack(1))
        h.push(stack(2))
        _ = h.undo() // back to stack(1), redo available to stack(2)
        XCTAssertTrue(h.canRedo)
        h.push(stack(3)) // new branch — stack(2) redo must be discarded
        XCTAssertFalse(h.canRedo)
    }

    func testUndoRedoEdges() {
        var h = EditHistory(initial: stack(0))
        XCTAssertFalse(h.canUndo)
        XCTAssertFalse(h.canRedo)
        XCTAssertNil(h.undo())
        h.push(stack(1))
        XCTAssertEqual(h.undo(), stack(0))
        XCTAssertEqual(h.redo(), stack(1))
        XCTAssertNil(h.redo())
    }

    func testCapacityDropsOldest() {
        var h = EditHistory(initial: stack(0))
        for i in 1...105 { h.push(stack(Double(i))) }
        var undoCount = 0
        while h.canUndo { _ = h.undo(); undoCount += 1 }
        XCTAssertLessThanOrEqual(undoCount, 100)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -scheme Muse -only-testing:MuseTests/EditHistoryTests test`
Expected: FAIL — type doesn't exist.

- [ ] **Step 3: Write the implementation** (Surface's `EditHistory.swift`, 46 LOC, ported with
its shape intact — state array + cursor, dedupe on push, truncate-forward, `capacity = 100`
drop-oldest):

```swift
/// Session-only undo/redo over EditStack. Push fires on gesture END (EditSession owns the
/// call site), not per slider tick. Cross-session persistence is the stack itself +
/// snapshots/versions (edit_versions) — NOT this history (deviation D3, spec-04 §1.3).
struct EditHistory {
    private static let capacity = 100
    private var states: [EditStack]
    private var cursor: Int

    init(initial: EditStack) {
        states = [initial]
        cursor = 0
    }

    var current: EditStack { states[cursor] }
    var canUndo: Bool { cursor > 0 }
    var canRedo: Bool { cursor < states.count - 1 }

    mutating func push(_ state: EditStack) {
        guard state != current else { return }
        states.removeSubrange((cursor + 1)...) // fatal if cursor is last index; guard:
        if cursor + 1 < states.count { states.removeSubrange((cursor + 1)...) }
        states.append(state)
        cursor = states.count - 1
        if states.count > Self.capacity {
            let overflow = states.count - Self.capacity
            states.removeFirst(overflow)
            cursor -= overflow
        }
    }

    mutating func undo() -> EditStack? {
        guard canUndo else { return nil }
        cursor -= 1
        return current
    }

    mutating func redo() -> EditStack? {
        guard canRedo else { return nil }
        cursor += 1
        return current
    }
}
```

(Fix the double `removeSubrange` — keep only the guarded one: `if cursor + 1 < states.count {
states.removeSubrange((cursor + 1)...) }` before the `append`.)

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild -scheme Muse -only-testing:MuseTests/EditHistoryTests test`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add "Muse/Muse/Editing/EditHistory.swift" "Muse/MuseTests/EditHistoryTests.swift"
git commit -m "feat(editing): EditHistory — session-only undo/redo (Surface Camera port)"
```

### Task 1.4: `Editing/EditTransfer.swift` — copy/paste/preset semantics

**Files:**
- Create: `Muse/Muse/Editing/EditTransfer.swift`
- Test: `Muse/MuseTests/EditTransferTests.swift`

**Interfaces:**
- Consumes: `EditStack`, `Adjustment` (Task 1.1).
- Produces: `enum AdjustmentGroup: String, CaseIterable, Codable, Sendable { case tone, color,
  presence, curve, geometry, vignette, raw }`, `enum EditTransfer { static func
  adjustedGroups(of: EditStack) -> Set<AdjustmentGroup>; static func apply(groups:
  Set<AdjustmentGroup>, from: EditStack, onto: EditStack) -> EditStack }`.

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import Muse

final class EditTransferTests: XCTestCase {
    func nonNeutralTone() -> EditStack {
        var s = EditStack.fresh()
        var t = ToneParams.neutral; t.exposureEV = 1
        s.adjustments = [.tone(t)]
        return s
    }

    func testAdjustedGroupsReturnsOnlyNonNeutralGroups() {
        let groups = EditTransfer.adjustedGroups(of: nonNeutralTone())
        XCTAssertEqual(groups, [.tone])
    }

    func testApplyIsCopyByValueAndNeverMutatesSource() {
        let source = nonNeutralTone()
        let target = EditStack.fresh()
        let result = EditTransfer.apply(groups: [.tone], from: source, onto: target)
        if case .tone(let p) = result.adjustments.first(where: { if case .tone = $0 { true } else { false } })! {
            XCTAssertEqual(p.exposureEV, 1)
        } else { XCTFail() }
        // source untouched
        XCTAssertEqual(EditTransfer.adjustedGroups(of: source), [.tone])
    }

    func testGroupAbsentInSourceClearsItInTarget() {
        var targetWithVignette = EditStack.fresh()
        var v = VignetteParams.neutral; v.amount = 0.5
        targetWithVignette.adjustments = [.vignette(v)]
        let neutralSource = EditStack.fresh()
        let result = EditTransfer.apply(groups: [.vignette], from: neutralSource, onto: targetWithVignette)
        XCTAssertTrue(EditTransfer.adjustedGroups(of: result).isEmpty)
    }

    func testUntouchedGroupsKeepTargetValues() {
        var target = EditStack.fresh()
        var c = ColorParams.neutral; c.saturation = 0.3
        target.adjustments = [.color(c)]
        let result = EditTransfer.apply(groups: [.tone], from: nonNeutralTone(), onto: target)
        XCTAssertTrue(EditTransfer.adjustedGroups(of: result).contains(.color))
    }

    func testPresetApplyThenTweakNeverMutatesPresetStack() {
        let preset = nonNeutralTone()
        var photo = EditTransfer.apply(groups: [.tone], from: preset, onto: EditStack.fresh())
        // simulate a user tweak on the photo's OWN copy
        if case .tone(var p) = photo.adjustments[0] {
            p.exposureEV = 3
            photo.adjustments[0] = .tone(p)
        }
        XCTAssertEqual(EditTransfer.adjustedGroups(of: preset), [.tone])
        if case .tone(let originalP) = preset.adjustments[0] {
            XCTAssertEqual(originalP.exposureEV, 1) // preset's own stack is a value type — untouched
        } else { XCTFail() }
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -scheme Muse -only-testing:MuseTests/EditTransferTests test`
Expected: FAIL — type doesn't exist.

- [ ] **Step 3: Write the implementation**

```swift
nonisolated enum AdjustmentGroup: String, CaseIterable, Codable, Sendable {
    case tone, color, presence, curve, geometry, vignette, raw
}

nonisolated enum EditTransfer {
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
            }
        }
        if let raw = stack.rawParams, !raw.isNeutral { groups.insert(.raw) }
        return groups
    }

    static func apply(groups: Set<AdjustmentGroup>, from source: EditStack,
                       onto target: EditStack) -> EditStack {
        var result = target
        var adjustments = result.adjustments.filter { !groups.contains($0.group) }
        for group in groups where group != .raw {
            if let sourceAdj = source.adjustments.first(where: { $0.group == group }) {
                adjustments.append(sourceAdj)
            }
            // absent in source → the filter above already dropped target's copy: clears it
        }
        result.adjustments = adjustments
        if groups.contains(.raw) {
            result.rawParams = source.rawParams
        }
        result.schemaVersion = target.schemaVersion
        result.processVersion = target.processVersion
        return result.normalized()
    }
}

private extension Adjustment {
    var group: AdjustmentGroup {
        switch self {
        case .tone: .tone; case .color: .color; case .presence: .presence
        case .curve: .curve; case .geometry: .geometry; case .vignette: .vignette
        }
    }
}
```

(`isNeutralCase` and per-params `isNeutral` must exist from Task 1.1 — add them there if not
already present, one switch per `Adjustment` case delegating to each param struct's own
`isNeutral`.)

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild -scheme Muse -only-testing:MuseTests/EditTransferTests test`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add "Muse/Muse/Editing/EditTransfer.swift" "Muse/MuseTests/EditTransferTests.swift"
git commit -m "feat(editing): EditTransfer — adjustedGroups + copy-by-value apply"
```

### Task 1.5: `EditingModuleImportTests` — platform-neutral-core enforcement

**Files:**
- Create: `Muse/MuseTests/EditingModuleImportTests.swift`

**Interfaces:**
- Consumes: nothing (a filesystem grep test over the `Editing/` source tree).

- [ ] **Step 1: Write the test**

```swift
import XCTest

final class EditingModuleImportTests: XCTestCase {
    func testEditingFolderNeverImportsAppKit() throws {
        let fm = FileManager.default
        // Locate Muse/Muse/Editing relative to this test file's known repo layout.
        let thisFile = URL(fileURLWithPath: #filePath)
        let repoRoot = thisFile
            .deletingLastPathComponent() // MuseTests
            .deletingLastPathComponent() // Muse App (repo root containing Muse/)
        let editingDir = repoRoot.appendingPathComponent("Muse/Muse/Editing")
        guard let enumerator = fm.enumerator(at: editingDir, includingPropertiesForKeys: nil)
        else { XCTFail("Editing/ directory not found at \(editingDir.path)"); return }
        var violations: [String] = []
        for case let fileURL as URL in enumerator where fileURL.pathExtension == "swift" {
            let contents = try String(contentsOf: fileURL, encoding: .utf8)
            if contents.range(of: #"^\s*import\s+AppKit"#, options: .regularExpression) != nil {
                violations.append(fileURL.lastPathComponent)
            }
        }
        XCTAssertTrue(violations.isEmpty, "AppKit imported in Editing/: \(violations)")
    }
}
```

- [ ] **Step 2: Run test to verify it passes against Tasks 1.1–1.4's files**

Run: `xcodebuild -scheme Muse -only-testing:MuseTests/EditingModuleImportTests test`
Expected: PASS (nothing in `Editing/` imports AppKit yet — this test now guards every future
file added there, including the render pipeline in Phase 3).

- [ ] **Step 3: Commit**

```bash
git add "Muse/MuseTests/EditingModuleImportTests.swift"
git commit -m "test(editing): guard Editing/ against AppKit imports (platform-neutral rule)"
```


## Phase 2 — v20 schema, `EditRecordStore`, carry seams, sidecar mirroring

### Task 2.1: `v20_edits` migration + records

**Files:**
- Modify: `Muse/Muse/Database/Database.swift` (append after `v12_smart_collections`,
  currently ending at line 357 — re-confirm with `grep -n "registerMigration" ...` first)
- Modify: `Muse/Muse/Database/Records.swift` (add `EditRow`, `EditVersionRow`)
- Test: `Muse/MuseTests/EditMigrationTests.swift`

**Interfaces:**
- Produces: tables `edits` (composite PK `file_id, parent_dir`) and `edit_versions` (PK
  `id`), plus `struct EditRow: Codable, FetchableRecord, MutablePersistableRecord` and
  `struct EditVersionRow: Codable, FetchableRecord, MutablePersistableRecord`.

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
import GRDB
@testable import Muse

final class EditMigrationTests: XCTestCase {
    func makeMigratedQueue() throws -> DatabaseQueue {
        let queue = try DatabaseQueue()
        try Database.makeMigrator().migrate(queue)
        return queue
    }

    func testV20CreatesEditsAndEditVersionsTables() throws {
        let queue = try makeMigratedQueue()
        try queue.read { db in
            XCTAssertTrue(try db.tableExists("edits"))
            XCTAssertTrue(try db.tableExists("edit_versions"))
        }
    }

    func testEditsTableHasCompositePrimaryKeyOnFileIdParentDir() throws {
        let queue = try makeMigratedQueue()
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO files (id, content_hash, kind) VALUES ('f1', 'h1', 'image')
                """)
            try db.execute(sql: """
                INSERT INTO edits (file_id, parent_dir, stack, stack_hash, process_version, updated_at)
                VALUES ('f1', '/a', '{}', 'h', 1, 0)
                """)
        }
        try queue.read { db in
            let count = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM edits") ?? 0
            XCTAssertEqual(count, 1)
        }
    }

    func testEditsCascadeDeletesOnFileDelete() throws {
        let queue = try makeMigratedQueue()
        try queue.write { db in
            try db.execute(sql: "INSERT INTO files (id, content_hash, kind) VALUES ('f2', 'h2', 'image')")
            try db.execute(sql: """
                INSERT INTO edits (file_id, parent_dir, stack, stack_hash, process_version, updated_at)
                VALUES ('f2', '/a', '{}', 'h', 1, 0)
                """)
            try db.execute(sql: "DELETE FROM files WHERE id = 'f2'")
        }
        try queue.read { db in
            let count = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM edits") ?? 0
            XCTAssertEqual(count, 0)
        }
    }

    func testMigrationIsIdempotentOnReRun() throws {
        let queue = try makeMigratedQueue()
        XCTAssertNoThrow(try Database.makeMigrator().migrate(queue))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -scheme Muse -only-testing:MuseTests/EditMigrationTests test`
Expected: FAIL — tables don't exist.

- [ ] **Step 3: Add the migration** — append to `Database.makeMigrator()` in
`Database/Database.swift`, immediately after the `v12_smart_collections` registration:

```swift
migrator.registerMigration("v20_edits") { db in
    try db.create(table: "edits") { t in
        t.column("file_id", .text).notNull()
            .references("files", onDelete: .cascade)
        t.column("parent_dir", .text).notNull()
        t.column("stack", .text).notNull()
        t.column("stack_hash", .text).notNull()
        t.column("process_version", .integer).notNull()
        t.column("updated_at", .integer).notNull()
        t.primaryKey(["file_id", "parent_dir"])
    }
    try db.create(table: "edit_versions") { t in
        t.column("id", .text).primaryKey()
        t.column("file_id", .text).notNull()
            .references("files", onDelete: .cascade)
        t.column("parent_dir", .text).notNull()
        t.column("kind", .text).notNull()
        t.column("name", .text).notNull()
        t.column("stack", .text).notNull()
        t.column("created_at", .integer).notNull()
    }
    try db.create(index: "edit_versions_scope_idx", on: "edit_versions",
                  columns: ["file_id", "parent_dir"])
}
```

- [ ] **Step 4: Add the records** to `Database/Records.swift` (snake_case fields matching
column names exactly, inserted as `var` per house rule):

```swift
struct EditRow: Codable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "edits"
    var file_id: String
    var parent_dir: String
    var stack: String
    var stack_hash: String
    var process_version: Int
    var updated_at: Int64
}

struct EditVersionRow: Codable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "edit_versions"
    var id: String
    var file_id: String
    var parent_dir: String
    var kind: String
    var name: String
    var stack: String
    var created_at: Int64
}
```

- [ ] **Step 5: Run test to verify it passes**

Run: `xcodebuild -scheme Muse -only-testing:MuseTests/EditMigrationTests test`
Expected: PASS. Also run the full existing migration test suite (`grep -rl
"makeMigrator\|DatabaseMigrationTests" Muse/MuseTests/`) to confirm v1–v12 still apply clean.

- [ ] **Step 6: Commit**

```bash
git add "Muse/Muse/Database/Database.swift" "Muse/Muse/Database/Records.swift" \
  "Muse/MuseTests/EditMigrationTests.swift"
git commit -m "feat(editing): v20_edits migration — edits + edit_versions tables"
```

### Task 2.2: `Database/EditRecordStore.swift` — pure DB funcs

**Files:**
- Create: `Muse/Muse/Database/EditRecordStore.swift`
- Test: `Muse/MuseTests/EditRecordStoreTests.swift`

**Interfaces:**
- Consumes: `EditRow`, `EditVersionRow` (Task 2.1); mirrors `Database/NoteStore.swift`'s shape
  exactly (`grep -n "static func" Muse/Muse/Database/NoteStore.swift` to confirm signatures
  match this store's naming).
- Produces:
  ```swift
  nonisolated enum EditRecordStore {
      static func read(fileID: String, parentDir: String, db: GRDB.Database) throws -> EditRow?
      static func write(stackJSON: String, hash: String, processVersion: Int, fileID: String,
                        parentDir: String, updatedAt: Int64, db: GRDB.Database) throws
      static func delete(fileID: String, parentDir: String, db: GRDB.Database) throws
      static func applyHydrated(json: String, incomingUpdatedAt: Int64, fileID: String,
                                parentDir: String, db: GRDB.Database) throws
      static func versions(fileID: String, parentDir: String, db: GRDB.Database) throws -> [EditVersionRow]
      static func addVersion(_ row: EditVersionRow, db: GRDB.Database) throws
      static func deleteVersion(id: String, db: GRDB.Database) throws
      static func carry(fromFileID: String, fromDir: String, toFileID: String, toDir: String,
                        deleteOriginal: Bool, db: GRDB.Database) throws
      static func carryAll(fromFileID: String, toFileID: String, db: GRDB.Database) throws
  }
  ```

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
import GRDB
@testable import Muse

final class EditRecordStoreTests: XCTestCase {
    func makeQueue() throws -> DatabaseQueue {
        let queue = try DatabaseQueue()
        try Database.makeMigrator().migrate(queue)
        try queue.write { db in
            try db.execute(sql: "INSERT INTO files (id, content_hash, kind) VALUES ('f1', 'h1', 'image')")
            try db.execute(sql: "INSERT INTO files (id, content_hash, kind) VALUES ('f2', 'h2', 'image')")
        }
        return queue
    }

    func testWriteThenReadRoundTrips() throws {
        let queue = try makeQueue()
        try queue.write { db in
            try EditRecordStore.write(stackJSON: "{}", hash: "abc", processVersion: 1,
                                      fileID: "f1", parentDir: "/a", updatedAt: 100, db: db)
        }
        let row = try queue.read { db in
            try EditRecordStore.read(fileID: "f1", parentDir: "/a", db: db)
        }
        XCTAssertEqual(row?.stack_hash, "abc")
    }

    func testWriteUpsertsOnSameScope() throws {
        let queue = try makeQueue()
        try queue.write { db in
            try EditRecordStore.write(stackJSON: "{}", hash: "abc", processVersion: 1,
                                      fileID: "f1", parentDir: "/a", updatedAt: 100, db: db)
            try EditRecordStore.write(stackJSON: "{}", hash: "def", processVersion: 1,
                                      fileID: "f1", parentDir: "/a", updatedAt: 200, db: db)
        }
        let row = try queue.read { db in
            try EditRecordStore.read(fileID: "f1", parentDir: "/a", db: db)
        }
        XCTAssertEqual(row?.stack_hash, "def")
    }

    func testDeleteRemovesRow() throws {
        let queue = try makeQueue()
        try queue.write { db in
            try EditRecordStore.write(stackJSON: "{}", hash: "abc", processVersion: 1,
                                      fileID: "f1", parentDir: "/a", updatedAt: 100, db: db)
            try EditRecordStore.delete(fileID: "f1", parentDir: "/a", db: db)
        }
        let row = try queue.read { db in
            try EditRecordStore.read(fileID: "f1", parentDir: "/a", db: db)
        }
        XCTAssertNil(row)
    }

    func testApplyHydratedStrictlyNewerLocalWins() throws {
        let queue = try makeQueue()
        try queue.write { db in
            try EditRecordStore.write(stackJSON: "{\"local\":1}", hash: "local", processVersion: 1,
                                      fileID: "f1", parentDir: "/a", updatedAt: 500, db: db)
            try EditRecordStore.applyHydrated(json: "{\"incoming\":1}", incomingUpdatedAt: 100,
                                              fileID: "f1", parentDir: "/a", db: db)
        }
        let row = try queue.read { db in
            try EditRecordStore.read(fileID: "f1", parentDir: "/a", db: db)
        }
        XCTAssertEqual(row?.stack, "{\"local\":1}") // local is strictly newer — kept
    }

    func testApplyHydratedIncomingWinsWhenNewer() throws {
        let queue = try makeQueue()
        try queue.write { db in
            try EditRecordStore.write(stackJSON: "{\"local\":1}", hash: "local", processVersion: 1,
                                      fileID: "f1", parentDir: "/a", updatedAt: 100, db: db)
            try EditRecordStore.applyHydrated(json: "{\"incoming\":1}", incomingUpdatedAt: 500,
                                              fileID: "f1", parentDir: "/a", db: db)
        }
        let row = try queue.read { db in
            try EditRecordStore.read(fileID: "f1", parentDir: "/a", db: db)
        }
        XCTAssertEqual(row?.stack, "{\"incoming\":1}")
    }

    func testCarryInsertOrIgnoreNeverClobbersDestination() throws {
        let queue = try makeQueue()
        try queue.write { db in
            try EditRecordStore.write(stackJSON: "{\"source\":1}", hash: "s", processVersion: 1,
                                      fileID: "f1", parentDir: "/a", updatedAt: 100, db: db)
            try EditRecordStore.write(stackJSON: "{\"dest\":1}", hash: "d", processVersion: 1,
                                      fileID: "f2", parentDir: "/b", updatedAt: 100, db: db)
            try EditRecordStore.carry(fromFileID: "f1", fromDir: "/a", toFileID: "f2",
                                      toDir: "/b", deleteOriginal: false, db: db)
        }
        let row = try queue.read { db in
            try EditRecordStore.read(fileID: "f2", parentDir: "/b", db: db)
        }
        XCTAssertEqual(row?.stack, "{\"dest\":1}") // destination's own edit survives
    }

    func testCarryWithDeleteOriginalRemovesSource() throws {
        let queue = try makeQueue()
        try queue.write { db in
            try EditRecordStore.write(stackJSON: "{\"source\":1}", hash: "s", processVersion: 1,
                                      fileID: "f1", parentDir: "/a", updatedAt: 100, db: db)
            try EditRecordStore.carry(fromFileID: "f1", fromDir: "/a", toFileID: "f2",
                                      toDir: "/b", deleteOriginal: true, db: db)
        }
        try queue.read { db in
            XCTAssertNil(try EditRecordStore.read(fileID: "f1", parentDir: "/a", db: db))
            XCTAssertNotNil(try EditRecordStore.read(fileID: "f2", parentDir: "/b", db: db))
        }
    }

    func testVersionsCRUD() throws {
        let queue = try makeQueue()
        let versionRow = EditVersionRow(id: "v1", file_id: "f1", parent_dir: "/a",
                                        kind: "snapshot", name: "Snap 1", stack: "{}",
                                        created_at: 100)
        try queue.write { db in try EditRecordStore.addVersion(versionRow, db: db) }
        var versions = try queue.read { db in
            try EditRecordStore.versions(fileID: "f1", parentDir: "/a", db: db)
        }
        XCTAssertEqual(versions.count, 1)
        try queue.write { db in try EditRecordStore.deleteVersion(id: "v1", db: db) }
        versions = try queue.read { db in
            try EditRecordStore.versions(fileID: "f1", parentDir: "/a", db: db)
        }
        XCTAssertEqual(versions.count, 0)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -scheme Muse -only-testing:MuseTests/EditRecordStoreTests test`
Expected: FAIL — type doesn't exist.

- [ ] **Step 3: Write the implementation**, modeled exactly on `NoteStore.swift`'s
read/write/delete/carry/carryAll shapes (read that file first for the precise GRDB idioms —
raw SQL vs record-based upsert — this store's `write` must UPSERT on the composite PK, and
`carry`/`carryAll` must be `INSERT OR IGNORE`):

```swift
import Foundation
import GRDB

nonisolated enum EditRecordStore {
    static func read(fileID: String, parentDir: String, db: GRDB.Database) throws -> EditRow? {
        try EditRow.fetchOne(db, sql: """
            SELECT * FROM edits WHERE file_id = ? AND parent_dir = ?
            """, arguments: [fileID, parentDir])
    }

    static func write(stackJSON: String, hash: String, processVersion: Int, fileID: String,
                      parentDir: String, updatedAt: Int64, db: GRDB.Database) throws {
        try db.execute(sql: """
            INSERT INTO edits (file_id, parent_dir, stack, stack_hash, process_version, updated_at)
            VALUES (?, ?, ?, ?, ?, ?)
            ON CONFLICT(file_id, parent_dir) DO UPDATE SET
                stack = excluded.stack, stack_hash = excluded.stack_hash,
                process_version = excluded.process_version, updated_at = excluded.updated_at
            """, arguments: [fileID, parentDir, stackJSON, hash, processVersion, updatedAt])
    }

    static func delete(fileID: String, parentDir: String, db: GRDB.Database) throws {
        try db.execute(sql: "DELETE FROM edits WHERE file_id = ? AND parent_dir = ?",
                       arguments: [fileID, parentDir])
    }

    static func applyHydrated(json: String, incomingUpdatedAt: Int64, fileID: String,
                              parentDir: String, db: GRDB.Database) throws {
        let existing = try read(fileID: fileID, parentDir: parentDir, db: db)
        if let existing, existing.updated_at > incomingUpdatedAt { return } // local strictly newer wins
        let hash = EditStackCodec.decode(json).map(EditStackCodec.hash) ?? ""
        let processVersion = EditStackCodec.decode(json)?.processVersion ?? EditStack.currentProcessVersion
        try write(stackJSON: json, hash: hash, processVersion: processVersion, fileID: fileID,
                 parentDir: parentDir, updatedAt: incomingUpdatedAt, db: db)
    }

    static func versions(fileID: String, parentDir: String, db: GRDB.Database) throws -> [EditVersionRow] {
        try EditVersionRow.fetchAll(db, sql: """
            SELECT * FROM edit_versions WHERE file_id = ? AND parent_dir = ? ORDER BY created_at
            """, arguments: [fileID, parentDir])
    }

    static func addVersion(_ row: EditVersionRow, db: GRDB.Database) throws {
        var row = row
        try row.insert(db)
    }

    static func deleteVersion(id: String, db: GRDB.Database) throws {
        try db.execute(sql: "DELETE FROM edit_versions WHERE id = ?", arguments: [id])
    }

    /// Mirrors NoteStore.carry: INSERT OR IGNORE (never clobbers a destination edit),
    /// then delete-source when deleteOriginal. Carried edit_versions rows get fresh UUIDs.
    static func carry(fromFileID: String, fromDir: String, toFileID: String, toDir: String,
                      deleteOriginal: Bool, db: GRDB.Database) throws {
        if let source = try read(fileID: fromFileID, parentDir: fromDir, db: db) {
            try db.execute(sql: """
                INSERT OR IGNORE INTO edits (file_id, parent_dir, stack, stack_hash, process_version, updated_at)
                VALUES (?, ?, ?, ?, ?, ?)
                """, arguments: [toFileID, toDir, source.stack, source.stack_hash,
                                 source.process_version, source.updated_at])
        }
        let sourceVersions = try versions(fileID: fromFileID, parentDir: fromDir, db: db)
        for v in sourceVersions {
            try db.execute(sql: """
                INSERT OR IGNORE INTO edit_versions (id, file_id, parent_dir, kind, name, stack, created_at)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """, arguments: [UUID().uuidString, toFileID, toDir, v.kind, v.name, v.stack, v.created_at])
        }
        if deleteOriginal {
            try delete(fileID: fromFileID, parentDir: fromDir, db: db)
            try db.execute(sql: "DELETE FROM edit_versions WHERE file_id = ? AND parent_dir = ?",
                           arguments: [fromFileID, fromDir])
        }
    }

    /// Mirrors NoteStore.carryAll: move EVERY scope of one identity onto another
    /// (the sole-alive-path collision case).
    static func carryAll(fromFileID: String, toFileID: String, db: GRDB.Database) throws {
        let rows = try EditRow.fetchAll(db, sql: "SELECT * FROM edits WHERE file_id = ?",
                                        arguments: [fromFileID])
        for row in rows {
            try carry(fromFileID: fromFileID, fromDir: row.parent_dir, toFileID: toFileID,
                      toDir: row.parent_dir, deleteOriginal: true, db: db)
        }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild -scheme Muse -only-testing:MuseTests/EditRecordStoreTests test`
Expected: PASS. Re-read `NoteStore.swift` alongside this file once more and reconcile any
signature/behavior drift the tests didn't catch (e.g. exact upsert SQL dialect already used
there — reuse it verbatim if `NoteStore` already solved the same UPSERT problem).

- [ ] **Step 5: Commit**

```bash
git add "Muse/Muse/Database/EditRecordStore.swift" "Muse/MuseTests/EditRecordStoreTests.swift"
git commit -m "feat(editing): EditRecordStore — read/write/delete/applyHydrated/carry (NoteStore shape)"
```

### Task 2.3: Sidecar fields + merge + resolveForWrite

**Files:**
- Modify: `Muse/Muse/Filesystem/Sidecar.swift` (fields, `merge`, `resolveForWrite`, `build`)
- Test: `Muse/MuseTests/EditSidecarTests.swift`

**Interfaces:**
- Produces: `Sidecar.edit_stack: String? = nil`, `Sidecar.edit_updated_at: Int64? = nil`;
  `Sidecar.resolveForWrite(fresh:existing:mergeExisting:noteAuthoritative:editAuthoritative:)`
  (new param, default `false`); `Sidecar.build(from:tags:updatedAt:note:edit:)` (new param
  `edit: (stack: String, updatedAt: Int64)? = nil`).

- [ ] **Step 1: Read the current file**

`grep -n "struct Sidecar\|func merge\|func resolveForWrite\|func build" Muse/Muse/Filesystem/Sidecar.swift`
to get exact current signatures before editing (spec cites `note` precedent around line 45
and `resolveForWrite` around line 168 — confirm).

- [ ] **Step 2: Write the failing test**

```swift
import XCTest
@testable import Muse

final class EditSidecarTests: XCTestCase {
    func testPreEditSidecarDecodesWithNilEditFields() throws {
        let json = "{\"tags\":[]}" // shape from before edit_stack existed
        let sidecar = try Sidecar.decode(json) // adjust to actual decode entry point
        XCTAssertNil(sidecar.edit_stack)
        XCTAssertNil(sidecar.edit_updated_at)
    }

    func testMergeNewerEditUpdatedAtWins() {
        var a = Sidecar.empty(); a.edit_stack = "{\"a\":1}"; a.edit_updated_at = 100
        var b = Sidecar.empty(); b.edit_stack = "{\"b\":1}"; b.edit_updated_at = 500
        let winner = Sidecar.merge(a, b)
        XCTAssertEqual(winner.edit_stack, "{\"b\":1}")
    }

    func testMergeNilIncomingNeverClobbers() {
        var a = Sidecar.empty(); a.edit_stack = "{\"a\":1}"; a.edit_updated_at = 100
        let b = Sidecar.empty() // never edited on this device
        let winner = Sidecar.merge(a, b)
        XCTAssertEqual(winner.edit_stack, "{\"a\":1}")
    }

    func testResolveForWritePreservesOnDiskEditWhenNotAuthoritative() {
        var existing = Sidecar.empty(); existing.edit_stack = "{\"disk\":1}"
        var fresh = Sidecar.empty(); fresh.edit_stack = "{\"fresh\":1}"
        let resolved = Sidecar.resolveForWrite(fresh: fresh, existing: existing,
                                               mergeExisting: false, noteAuthoritative: false,
                                               editAuthoritative: false)
        XCTAssertEqual(resolved.edit_stack, "{\"disk\":1}")
    }

    func testResolveForWriteFreshWinsWhenEditAuthoritative() {
        var existing = Sidecar.empty(); existing.edit_stack = "{\"disk\":1}"
        var fresh = Sidecar.empty(); fresh.edit_stack = nil // an explicit Reset/clear
        let resolved = Sidecar.resolveForWrite(fresh: fresh, existing: existing,
                                               mergeExisting: false, noteAuthoritative: false,
                                               editAuthoritative: true)
        XCTAssertNil(resolved.edit_stack) // fresh wins INCLUDING a clear
    }
}
```

- [ ] **Step 3: Run test to verify it fails**

Run: `xcodebuild -scheme Muse -only-testing:MuseTests/EditSidecarTests test`
Expected: FAIL — fields/params don't exist. (Adjust the test's exact API calls —
`Sidecar.decode`/`.empty()` — to match whatever `Sidecar.swift` actually exposes; read the
file first, since these names are illustrative of the intent, not confirmed literal names.)

- [ ] **Step 4: Implement**

- Add `var edit_stack: String? = nil` and `var edit_updated_at: Int64? = nil` to the
  `Sidecar` struct, beside the existing `note` field (same "optional with nil default"
  pattern so old sidecars decode unchanged).
- In `merge(_:_:)`: add the edit resolution rule beside the existing note rule —
  `winner.edit_stack/edit_updated_at = (side with greater non-nil edit_updated_at) ??
  (the other side)`.
- In `resolveForWrite`: add `editAuthoritative: Bool = false` parameter; when true, `fresh`
  wins for `edit_stack`/`edit_updated_at` including a clear (`fresh.edit_stack` even if nil);
  otherwise `out.edit_stack = existing.edit_stack ?? fresh.edit_stack` (existing preserved).
- In `build(from:tags:updatedAt:note:...)`: add `edit: (stack: String, updatedAt: Int64)? =
  nil` parameter, setting `edit_stack`/`edit_updated_at` from it when non-nil.

- [ ] **Step 5: Run test to verify it passes**

Run: `xcodebuild -scheme Muse -only-testing:MuseTests/EditSidecarTests test`
Expected: PASS. Also run existing `SidecarTests`/`SidecarHydratorTests` to confirm they stay
green (no behavior change for non-edit fields).

- [ ] **Step 6: Commit**

```bash
git add "Muse/Muse/Filesystem/Sidecar.swift" "Muse/MuseTests/EditSidecarTests.swift"
git commit -m "feat(editing): Sidecar edit_stack/edit_updated_at fields + merge/resolveForWrite rules"
```

### Task 2.4: `AnalyzePipeline.exportSidecarsAfterEditChange` + hydration wiring

**Files:**
- Modify: `Muse/Muse/Intelligence/AnalyzePipeline.swift` (mirror
  `exportSidecarsAfterTagEdit`; add the `edits` row read inside `writeSidecarIfICloud`'s
  existing bundle `queue.read`)
- Modify: `Muse/Muse/Filesystem/SidecarHydrator.swift` (call
  `EditRecordStore.applyHydrated` on hydrate, mirroring `NoteStore.applyHydrated` usage)
- Test: extend `Muse/MuseTests/EditSidecarTests.swift` with the export-path matrix from
  spec-04 §2.4.

**Interfaces:**
- Consumes: `EditRecordStore` (Task 2.2), `Sidecar.resolveForWrite(...editAuthoritative:)`
  (Task 2.3).
- Produces: `AnalyzePipeline.exportSidecarsAfterEditChange(for urls: [URL])`.

- [ ] **Step 1: Read the existing `exportSidecarsAfterTagEdit`**

`grep -n "func exportSidecarsAfterTagEdit\|func writeSidecarIfICloud" Muse/Muse/Intelligence/AnalyzePipeline.swift`
— copy its exact shape (it's cited around line 379 for the export fn and line 340 for the
bundle read).

- [ ] **Step 2: Write the failing test** (add to `EditSidecarTests.swift`)

```swift
func testExportSidecarsAfterEditChangePassesEditAuthoritativeTrue() {
    // A behavioral pin at the call-site level: exportSidecarsAfterEditChange must route
    // through resolveForWrite(..., editAuthoritative: true) — verified indirectly via
    // Sidecar.resolveForWrite's own unit coverage (Task 2.3) plus an integration check
    // once AnalyzePipeline is wired: this test documents the required call-site contract
    // for the code reviewer, and is filled in with a live AnalyzePipeline fixture once
    // Task 2.4 Step 3 lands (AnalyzePipeline needs a folder+file fixture harness that
    // likely already exists for the tag-edit sidecar tests — reuse it, don't duplicate).
    XCTAssertTrue(true) // placeholder assertion removed once the fixture harness is wired
}
```

(This step's test is intentionally light — `AnalyzePipeline`'s sidecar export is already
covered by existing `exportSidecarsAfterTagEdit`-style tests; find that fixture harness via
`grep -rl "exportSidecarsAfterTagEdit" Muse/MuseTests/` and extend it with an edit-change case
rather than building a new one from scratch. Replace this placeholder with a real assertion
using that harness before Step 5.)

- [ ] **Step 3: Implement `exportSidecarsAfterEditChange`**, mirroring
`exportSidecarsAfterTagEdit`'s exact structure but passing `editAuthoritative: true`:

```swift
extension AnalyzePipeline {
    func exportSidecarsAfterEditChange(for urls: [URL]) async {
        // Same shape as exportSidecarsAfterTagEdit: resolve scope, read current DB state,
        // Sidecar.resolveForWrite(..., mergeExisting: false, editAuthoritative: true),
        // write to the .muse/<hash>.json sidecar path. Copy exportSidecarsAfterTagEdit's
        // body and change only the resolveForWrite call's editAuthoritative argument and
        // the fields being read (edits row instead of tags).
    }
}
```

- [ ] **Step 4: Wire the `edits` row into `writeSidecarIfICloud`'s bundle read**, and wire
`SidecarHydrator` to call `EditRecordStore.applyHydrated` on hydrate (mirroring the existing
`NoteStore.applyHydrated` call site — `grep -n "NoteStore.applyHydrated"
Muse/Muse/Filesystem/SidecarHydrator.swift` for the exact insertion point), followed by a
provider-index refresh + thumbnail invalidation for the path (the index refresh is a no-op
stub until Task 4.1 installs the real provider — call
`EditStackIndex.installProvider`'s current no-op safely, or leave a `// TODO(Phase 4)`
comment only if the call truly can't be made yet; prefer adding the call now so Phase 4 has
nothing left to wire here).

- [ ] **Step 5: Fill in the real assertion from Step 2, run tests**

Run: `xcodebuild -scheme Muse -only-testing:MuseTests/EditSidecarTests test`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add "Muse/Muse/Intelligence/AnalyzePipeline.swift" "Muse/Muse/Filesystem/SidecarHydrator.swift" \
  "Muse/MuseTests/EditSidecarTests.swift"
git commit -m "feat(editing): exportSidecarsAfterEditChange + hydration applies EditRecordStore"
```

### Task 2.5: Five carry seams (Indexer ×3, FileMoveMigration, FolderRenameMigration)

**Files:**
- Modify: `Muse/Muse/Indexing/Indexer.swift` (three sites — hash-collision sole-path,
  hash-collision shared-row, shared-row split)
- Modify: `Muse/Muse/Filesystem/FileMoveMigration.swift`
- Modify: `Muse/Muse/Filesystem/FolderRenameMigration.swift`
- Test: `Muse/MuseTests/EditCarrySeamTests.swift`

**Interfaces:**
- Consumes: `EditRecordStore.carry`/`.carryAll` (Task 2.2).

- [ ] **Step 1: Locate the five exact call sites**

Run: `grep -n "NoteStore.carryAll\|NoteStore.carry" Muse/Muse/Indexing/Indexer.swift
Muse/Muse/Filesystem/FileMoveMigration.swift Muse/Muse/Filesystem/FolderRenameMigration.swift`
— spec-04 cites: Indexer.swift:201 (`carryAll`), Indexer.swift:207 (`carry`),
Indexer.swift:297 (`carry`), FileMoveMigration.swift:67 (`carry`),
FolderRenameMigration.swift:38 (`apply`, tags/notes prefix rewrite at lines ~70-101).
Re-confirm each against the actual grep output before editing (line numbers may have moved).

- [ ] **Step 2: Write the failing test** (mirrors the existing `NoteStore` carry-seam
coverage — find it via `grep -rl "NoteStore.carry" Muse/MuseTests/` and copy its fixture
setup, swapping assertions to `EditRecordStore.read`):

```swift
import XCTest
import GRDB
@testable import Muse

final class EditCarrySeamTests: XCTestCase {
    // Fixture setup mirrors whatever IndexerReconcileTests/FileMoveMigrationTests/
    // FolderRenameMigrationTests already use for the equivalent NoteStore carry
    // assertions — reuse those harnesses, adding an edits-row seed + assertion
    // alongside each existing notes-row one, rather than building parallel fixtures.

    func testIndexerHashCollisionSolePathCarriesEditViaCarryAll() throws {
        // Seed: file f1 at sole alive path /a/x.jpg with an edits row.
        // Trigger: Indexer reconcile collides f1's new hash onto existing file target.
        // Assert: EditRecordStore.read for target.id/parentDir returns f1's stack;
        // EditRecordStore.read for f1/parentDir is nil (carryAll deletes source).
    }

    func testIndexerHashCollisionSharedRowCarriesViaCarryScopedToSameDirSibling() throws {
        // Mirrors the NoteStore.carry shared-row collision test shape exactly.
    }

    func testIndexerSharedRowSplitCarriesOntoNewFileID() throws {
        // Mirrors the NoteStore.carry split test shape exactly.
    }

    func testFileMoveMigrationCarriesEditOldDirToNewDir() throws {
        // Same file_id, oldDir -> newDir, same sibling rule as NoteStore.
    }

    func testFolderRenameMigrationRewritesParentDirPrefixAndPreClearsStaleTarget() throws {
        // edits + edit_versions get the SAME stale-target pre-clear (DELETE at the new
        // prefix — composite PK collides exactly like notes') and the SAME SUBSTR-prefix
        // parent_dir rewrite as tags/notes.
    }
}
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `xcodebuild -scheme Muse -only-testing:MuseTests/EditCarrySeamTests test`
Expected: FAIL (or compile error if the fixture harness needs real bodies — fill in each test
body using the equivalent existing `NoteStore` test as a template before running).

- [ ] **Step 4: Add the five `EditRecordStore` calls**, each directly beside its existing
`NoteStore` call, same arguments, same copy-vs-move flag:

- `Indexer.swift` (hash-collision, sole alive path): add
  `try EditRecordStore.carryAll(fromFileID: file.id, toFileID: target.id, db: db)` beside the
  `NoteStore.carryAll` call.
- `Indexer.swift` (hash-collision, shared row): add
  `try EditRecordStore.carry(fromFileID: ..., fromDir: ..., toFileID: target.id, toDir: ...,
  deleteOriginal: !keepsSiblingInDir, db: db)` beside `NoteStore.carry`, matching its exact
  argument expressions (read them at the call site — don't invent new variable names).
- `Indexer.swift` (shared-row split): add the same-shape `EditRecordStore.carry` onto
  `newFile.id`, beside `NoteStore.carry`.
- `FileMoveMigration.swift` (`apply`, line ~67): add `EditRecordStore.carry` with the same
  file_id, oldDir → newDir, same sibling rule, beside `NoteStore.carry`.
- `FolderRenameMigration.swift` (`apply`, line ~38): add the SAME stale-target pre-clear
  (`DELETE FROM edits WHERE ...` / `DELETE FROM edit_versions WHERE ...` at the new prefix)
  and the SAME `SUBSTR`-prefix `parent_dir` UPDATE for both `edits` and `edit_versions`,
  matching the tags/notes SQL shape exactly (read lines ~70-101 for the precise SQL to copy).

- [ ] **Step 5: Run tests to verify they pass**

Run: `xcodebuild -scheme Muse -only-testing:MuseTests/EditCarrySeamTests test`
Expected: PASS. Also re-run `IndexerReconcileTests`, `FileMoveMigrationTests`,
`FolderRenameMigrationTests` in full to confirm the additions didn't disturb existing
tags/notes carry behavior.

- [ ] **Step 6: Commit**

```bash
git add "Muse/Muse/Indexing/Indexer.swift" "Muse/Muse/Filesystem/FileMoveMigration.swift" \
  "Muse/Muse/Filesystem/FolderRenameMigration.swift" "Muse/MuseTests/EditCarrySeamTests.swift"
git commit -m "feat(editing): carry edits/edit_versions through all 5 identity/folder rewrite seams"
```


## Phase 3 — Renderer core (`Editing/Render/`)

*This phase is the highest-risk part of the project (Core Image + Metal, scene-referred
color, RAW hybrid). Build bottom-up: type safety → pure math (curve) → kernels → chain →
RAW → the golden consistency tests that gate everything after. Nothing in this phase touches
the app yet — Phase 4 wires it to `EditStore`/consumers.*

### Task 3.1: `Editing/Render/WorkingImage.swift` — type-safe working space

**Files:**
- Create: `Muse/Muse/Editing/Render/WorkingImage.swift`
- Test: `Muse/MuseTests/WorkingImageTests.swift`

**Interfaces:**
- Produces: `struct EncodedImage` (wraps a `CIImage` known to be display/file-referred),
  `struct LinearImage` (wraps a `CIImage` known to be linear working-space),
  `EncodedImage.toLinearWorkingSpace() -> LinearImage`, `LinearImage.oriented(forExifOrientation:
  Int32) -> LinearImage`, `static LinearImage.alreadyDecodedFromFile(_ image: CIImage) ->
  LinearImage`.

- [ ] **Step 1: Read Surface Camera's source for the exact port target**

Run: `find "/Users/carlostarrats/Documents/Projects/Surface Camera" -iname
"WorkingSpaceImage.swift" 2>/dev/null` (adjust the repo path if it differs) and read it in
full before writing — this task is a near-verbatim 50-LOC port, not a fresh design.

- [ ] **Step 2: Write the failing test**

```swift
import XCTest
import CoreImage
@testable import Muse

final class WorkingImageTests: XCTestCase {
    func testToLinearWorkingSpaceProducesLinearImage() {
        let ci = CIImage(color: .white).cropped(to: CGRect(x: 0, y: 0, width: 4, height: 4))
        let encoded = EncodedImage(ci)
        let linear = encoded.toLinearWorkingSpace()
        XCTAssertNotNil(linear.ciImage)
    }

    func testAlreadyDecodedFromFileSkipsTheEncodedCrossing() {
        let ci = CIImage(color: .gray).cropped(to: CGRect(x: 0, y: 0, width: 4, height: 4))
        let linear = LinearImage.alreadyDecodedFromFile(ci)
        XCTAssertNotNil(linear.ciImage)
    }

    func testOrientedAppliesExifTransform() {
        let ci = CIImage(color: .red).cropped(to: CGRect(x: 0, y: 0, width: 4, height: 8))
        let linear = LinearImage.alreadyDecodedFromFile(ci)
        let rotated = linear.oriented(forExifOrientation: 6) // 90° CW
        XCTAssertNotEqual(rotated.ciImage.extent.size, linear.ciImage.extent.size == rotated.ciImage.extent.size ? .zero : linear.ciImage.extent.size)
        // Loosened: just assert the extent's width/height swapped for a 90° orientation.
        XCTAssertEqual(rotated.ciImage.extent.width, linear.ciImage.extent.height, accuracy: 0.5)
    }
}
```

- [ ] **Step 3: Run test to verify it fails**

Run: `xcodebuild -scheme Muse -only-testing:MuseTests/WorkingImageTests test`
Expected: FAIL — types don't exist.

- [ ] **Step 4: Port the implementation** from Surface's `WorkingSpaceImage.swift`, adapting
only namespacing (keep the doc comment about the 2.3×-too-dark bug — it travels with the
port, per spec-04 §4.1):

```swift
import CoreImage

/// A CIImage known to be display/file-referred (sRGB-encoded, gamma-applied). The ONLY
/// crossing into linear working space is toLinearWorkingSpace() below — ported from
/// Surface Camera's WorkingSpaceImage.swift. Core Image applies the file's transfer
/// function on load, so decoding again (e.g. via a manual gamma pass) double-applies it —
/// the documented 2.3×-too-dark bug this type exists to prevent.
struct EncodedImage {
    let ciImage: CIImage
    init(_ ciImage: CIImage) { self.ciImage = ciImage }

    func toLinearWorkingSpace() -> LinearImage {
        guard let workingSpace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB) else {
            return LinearImage(ciImage)
        }
        let matched = ciImage.matchedToWorkingSpace(from: ciImage.colorSpace ??
            CGColorSpace(name: CGColorSpace.sRGB)!) ?? ciImage
        return LinearImage(matched.matchedFromWorkingSpace(to: workingSpace) ?? matched)
    }
}

/// A CIImage known to be linear working-space. Adjustment methods (Task 3.5) exist ONLY
/// on this type — an EncodedImage cannot be adjusted, by type (compile-time guarantee,
/// foundation §3).
struct LinearImage {
    let ciImage: CIImage
    init(_ ciImage: CIImage) { self.ciImage = ciImage }

    /// For CIImage(contentsOf:) sources (RAW's outputImage, or any source Core Image
    /// already decoded applying the file's transfer function) — the file is ALREADY
    /// linear working space; wrapping it directly is correct, re-deriving it via
    /// EncodedImage.toLinearWorkingSpace() would double-transform.
    static func alreadyDecodedFromFile(_ image: CIImage) -> LinearImage {
        LinearImage(image)
    }

    func oriented(forExifOrientation orientation: Int32) -> LinearImage {
        LinearImage(ciImage.oriented(forExifOrientation: orientation))
    }
}
```

- [ ] **Step 5: Run test to verify it passes**

Run: `xcodebuild -scheme Muse -only-testing:MuseTests/WorkingImageTests test`
Expected: PASS

- [ ] **Step 6: Commit**

```bash
git add "Muse/Muse/Editing/Render/WorkingImage.swift" "Muse/MuseTests/WorkingImageTests.swift"
git commit -m "feat(editing): WorkingImage — EncodedImage/LinearImage type-safe crossing (Surface port)"
```

### Task 3.2: `Editing/CurveLUT.swift` — monotone-cubic spline

**Files:**
- Create: `Muse/Muse/Editing/CurveLUT.swift`
- Test: `Muse/MuseTests/CurveLUTTests.swift`

**Interfaces:**
- Consumes: `CurveParams.Point` (Task 1.1).
- Produces: `enum CurveLUT { static func build(points: [CurveParams.Point]) -> [Float] // 1024 entries }`.

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import Muse

final class CurveLUTTests: XCTestCase {
    func testEmptyPointsProducesIdentityLUT() {
        let lut = CurveLUT.build(points: [])
        XCTAssertEqual(lut.count, 1024)
        XCTAssertEqual(lut.first!, 0, accuracy: 0.01)
        XCTAssertEqual(lut.last!, 1, accuracy: 0.01)
        // spot-check identity at the midpoint
        XCTAssertEqual(lut[512], Float(512) / Float(1023), accuracy: 0.02)
    }

    func testEndpointsAreExact() {
        let points = [CurveParams.Point(x: 0, y: 0.2), CurveParams.Point(x: 1, y: 0.9)]
        let lut = CurveLUT.build(points: points)
        XCTAssertEqual(lut.first!, 0.2, accuracy: 0.01)
        XCTAssertEqual(lut.last!, 0.9, accuracy: 0.01)
    }

    func testMonotoneInputProducesMonotoneOutput() {
        let points = [
            CurveParams.Point(x: 0, y: 0.0), CurveParams.Point(x: 0.3, y: 0.35),
            CurveParams.Point(x: 0.7, y: 0.6), CurveParams.Point(x: 1, y: 1.0)
        ]
        let lut = CurveLUT.build(points: points)
        for i in 1..<lut.count {
            XCTAssertGreaterThanOrEqual(lut[i], lut[i - 1] - 0.001) // allow float noise
        }
    }

    func testMaxPointsClamp() {
        var points: [CurveParams.Point] = []
        for i in 0...30 { points.append(CurveParams.Point(x: Double(i) / 30, y: Double(i) / 30)) }
        // build() must tolerate over-cap input gracefully (clamped by the caller normally;
        // the LUT builder itself should not crash on more than maxPoints).
        XCTAssertNoThrow(CurveLUT.build(points: points))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -scheme Muse -only-testing:MuseTests/CurveLUTTests test`
Expected: FAIL — type doesn't exist.

- [ ] **Step 3: Implement the Fritsch–Carlson monotone cubic spline**

```swift
import Foundation

nonisolated enum CurveLUT {
    static let entryCount = 1024

    /// 1024-entry LUT via a monotone-cubic (Fritsch–Carlson) spline through `points`.
    /// Empty points = identity ramp. Points are expected pre-sorted strictly increasing
    /// in x (CurveParams' invariant) — this function does not re-sort or dedupe.
    static func build(points: [CurveParams.Point]) -> [Float] {
        guard points.count >= 2 else {
            return (0..<entryCount).map { Float($0) / Float(entryCount - 1) }
        }
        let xs = points.map { $0.x }
        let ys = points.map { $0.y }
        let n = xs.count
        var deltas = [Double](repeating: 0, count: n - 1)
        var slopes = [Double](repeating: 0, count: n - 1)
        for i in 0..<(n - 1) {
            deltas[i] = xs[i + 1] - xs[i]
            slopes[i] = deltas[i] > 0 ? (ys[i + 1] - ys[i]) / deltas[i] : 0
        }
        var tangents = [Double](repeating: 0, count: n)
        tangents[0] = slopes[0]
        tangents[n - 1] = slopes[n - 2]
        for i in 1..<(n - 1) {
            if slopes[i - 1] * slopes[i] <= 0 {
                tangents[i] = 0
            } else {
                tangents[i] = (slopes[i - 1] + slopes[i]) / 2
            }
        }
        // Fritsch-Carlson monotonicity constraint
        for i in 0..<(n - 1) where slopes[i] != 0 {
            let a = tangents[i] / slopes[i]
            let b = tangents[i + 1] / slopes[i]
            let s = a * a + b * b
            if s > 9 {
                let t = 3 / sqrt(s)
                tangents[i] = t * a * slopes[i]
                tangents[i + 1] = t * b * slopes[i]
            }
        }

        var lut = [Float](repeating: 0, count: entryCount)
        var segment = 0
        for i in 0..<entryCount {
            let x = Double(i) / Double(entryCount - 1)
            while segment < n - 2 && x > xs[segment + 1] { segment += 1 }
            if x <= xs[0] { lut[i] = Float(ys[0]); continue }
            if x >= xs[n - 1] { lut[i] = Float(ys[n - 1]); continue }
            let h = deltas[segment]
            let t = h > 0 ? (x - xs[segment]) / h : 0
            let t2 = t * t, t3 = t2 * t
            let h00 = 2 * t3 - 3 * t2 + 1
            let h10 = t3 - 2 * t2 + t
            let h01 = -2 * t3 + 3 * t2
            let h11 = t3 - t2
            let y = h00 * ys[segment] + h10 * h * tangents[segment]
                  + h01 * ys[segment + 1] + h11 * h * tangents[segment + 1]
            lut[i] = Float(y)
        }
        return lut
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild -scheme Muse -only-testing:MuseTests/CurveLUTTests test`
Expected: PASS (tune the spline implementation if monotonicity or endpoint tests fail —
the Fritsch–Carlson constraint above is the standard fix for cubic-Hermite overshoot).

- [ ] **Step 5: Commit**

```bash
git add "Muse/Muse/Editing/CurveLUT.swift" "Muse/MuseTests/CurveLUTTests.swift"
git commit -m "feat(editing): CurveLUT — monotone-cubic (Fritsch-Carlson) 1024-entry spline"
```

### Task 3.3: `Editing/Render/EditKernels.metal` — toneBands + clarity/texture kernels

**Files:**
- Create: `Muse/Muse/Editing/Render/EditKernels.metal`
- Create: `Muse/Muse/Editing/Render/EditKernels.swift` (Swift wrapper: named constants +
  `CIColorKernel`/`CIBlendKernel` loading)
- Test: `Muse/MuseTests/EditKernelLoadTests.swift`

**Interfaces:**
- Produces: `enum EditKernels { static let toneBands: CIColorKernel; static let clarityTexture:
  CIBlendKernel (or CIColorKernel, per the chosen kernel signature) }` plus named tuning
  constants (band centers/widths, max gain, clarity/texture radius fractions — see Task 3.5's
  chain for where these are consumed).

- [ ] **Step 1: Note the build-system change this task requires**

The target currently has ZERO `.metal` files (water/burn shaders were removed — CLAUDE.md
durable constraint). Adding `EditKernels.metal` gives the Muse target a Metal compile phase
again. In Xcode: add the new `.metal` file to the `Muse` target's "Compile Sources" build
phase (NOT "Copy Bundle Resources") — stitchable kernels compile into the default metallib
automatically; do NOT add `-fcikernel` (that flag is for the deprecated CIKL path).

- [ ] **Step 2: Write the failing test**

```swift
import XCTest
import CoreImage
@testable import Muse

final class EditKernelLoadTests: XCTestCase {
    func testToneBandsKernelLoadsFromDefaultMetallib() {
        XCTAssertNoThrow(_ = EditKernels.toneBands)
    }

    func testClarityTextureKernelLoadsFromDefaultMetallib() {
        XCTAssertNoThrow(_ = EditKernels.clarityTexture)
    }
}
```

- [ ] **Step 3: Run test to verify it fails**

Run: `xcodebuild -scheme Muse -only-testing:MuseTests/EditKernelLoadTests test`
Expected: FAIL (build error — no such file/type yet).

- [ ] **Step 4: Write the Metal source**

```metal
#include <CoreImage/CoreImage.h>
using namespace metal;

/// toneBands: per-pixel luminance-weighted exposure-space gains for Highlights/Shadows/
/// Whites/Blacks. Smooth raised-cosine weight bands over log2 luminance; gains multiply
/// un-clamped linear RGB (never per-channel curves here — hue-preserving by construction).
/// Neutral at all-zero params is an exact identity (all gains 1).
extern "C" float4 toneBands(coreimage::sample_t s, float highlights, float shadows,
                             float whites, float blacks) {
    float luma = dot(s.rgb, float3(0.2126, 0.7152, 0.0722));
    float logLuma = log2(max(luma, 1e-6));
    // Named band centers/widths — OWNER-TUNED, expected to move (spec-04 §4.4/§14.1).
    const float highlightsCenter = -1.0, highlightsWidth = 2.0;
    const float shadowsCenter = -5.0, shadowsWidth = 2.0;
    const float maxGainEV = 1.5;

    float highlightsWeight = clamp(1.0 - abs(logLuma - highlightsCenter) / highlightsWidth, 0.0, 1.0);
    float shadowsWeight = clamp(1.0 - abs(logLuma - shadowsCenter) / shadowsWidth, 0.0, 1.0);
    float whitesWeight = clamp((logLuma - (-1.0)) / 2.0, 0.0, 1.0);
    float blacksWeight = clamp(1.0 - (logLuma - (-7.0)) / 2.0, 0.0, 1.0);

    float gainEV = highlights * highlightsWeight * maxGainEV
                 + shadows * shadowsWeight * maxGainEV
                 + whites * whitesWeight * maxGainEV
                 + blacks * blacksWeight * maxGainEV;
    float gain = pow(2.0, gainEV);
    return float4(s.rgb * gain, s.a);
}

/// clarityTexture: midtone-weighted local contrast (Pat David formulation).
/// result = base + amount * midtoneWeight(luma) * (base - blurred). Invoked twice by the
/// Swift side at different blur radii/weights for Clarity vs Texture.
extern "C" float4 clarityTexture(coreimage::sample_t base, coreimage::sample_t blurred,
                                  float amount) {
    float luma = dot(base.rgb, float3(0.2126, 0.7152, 0.0722));
    float midtoneWeight = 1.0 - abs(luma * 2.0 - 1.0); // peaks at luma=0.5, 0 at extremes
    float3 result = base.rgb + amount * midtoneWeight * (base.rgb - blurred.rgb);
    return float4(result, base.a);
}
```

- [ ] **Step 5: Write the Swift wrapper**

```swift
import CoreImage

nonisolated enum EditKernels {
    // Owner-tunable constants (spec-04 §4.4, §14.1 — first guesses WILL move).
    static let clarityRadiusFraction: CGFloat = 0.015
    static let textureRadiusFraction: CGFloat = 0.003
    static let sharpenRadiusFraction: CGFloat = 0.0008

    static let toneBands: CIColorKernel = {
        guard let url = Bundle.main.url(forResource: "default", withExtension: "metallib"),
              let data = try? Data(contentsOf: url),
              let kernel = try? CIColorKernel(functionName: "toneBands", fromMetalLibraryData: data)
        else { fatalError("toneBands kernel failed to load from default metallib") }
        return kernel
    }()

    static let clarityTexture: CIBlendKernel = {
        guard let url = Bundle.main.url(forResource: "default", withExtension: "metallib"),
              let data = try? Data(contentsOf: url),
              let kernel = try? CIBlendKernel(functionName: "clarityTexture", fromMetalLibraryData: data)
        else { fatalError("clarityTexture kernel failed to load from default metallib") }
        return kernel
    }()
}
```

(Confirm `CIBlendKernel(functionName:fromMetalLibraryData:)` is the correct API for a
two-image kernel — `CIColorKernel` takes one sample; `clarityTexture` takes base+blurred, so
it needs `CIKernel`/`CIBlendKernel`'s multi-image entry point. Adjust the wrapper's type to
whichever CI kernel subclass matches a two-sampler stitchable function signature at build
time — this is exactly the kind of detail that surfaces as a compile error, not a design
choice, so let the build guide the final type.)

- [ ] **Step 6: Run test to verify it passes**

Run: `xcodebuild -scheme Muse -only-testing:MuseTests/EditKernelLoadTests test`
Expected: PASS. This is a real build-phase smoke test — if the Metal compile phase isn't
wired correctly in the Xcode project, this fails at build time, which is the point (catches a
broken build phase in CI instead of at first slider drag).

- [ ] **Step 7: Commit**

```bash
git add "Muse/Muse/Editing/Render/EditKernels.metal" "Muse/Muse/Editing/Render/EditKernels.swift" \
  "Muse/MuseTests/EditKernelLoadTests.swift" "Muse/Muse.xcodeproj/project.pbxproj"
git commit -m "feat(editing): toneBands + clarityTexture stitchable Metal kernels"
```

### Task 3.4: `Editing/Render/RawSource.swift` — CIRAWFilter hybrid

**Files:**
- Create: `Muse/Muse/Editing/Render/RawSource.swift`
- Test: `Muse/MuseTests/MiredMappingTests.swift` (the pure mired-math portion only — the
  `CIRAWFilter` integration itself needs a real RAW fixture and is owner-verified per
  Task 14.2, not unit-testable without one)

**Interfaces:**
- Produces: `enum RawSource { static func decode(url: URL, params: RawParams?, color:
  ColorParams, presence: PresenceParams) -> LinearImage? }`, plus a pure
  `MiredMapping.offset(fromSliderValue: Double) -> Double` (or equivalent) the kernel/filter
  glue calls — this is the part with real unit-testable math (Surface's warm/cool asymmetry
  bug, pinned against recurrence).

- [ ] **Step 1: Write the failing test** (mired symmetry only — pure math)

```swift
import XCTest
@testable import Muse

final class MiredMappingTests: XCTestCase {
    func testWarmAndCoolAreSymmetricInMiredSpace() {
        let warmMired = MiredMapping.miredOffset(forSliderValue: 1.0)
        let coolMired = MiredMapping.miredOffset(forSliderValue: -1.0)
        XCTAssertEqual(warmMired, -coolMired, accuracy: 0.5) // symmetric magnitude, opposite sign
    }

    func testClampFloorPreventsExtremeMired() {
        let extreme = MiredMapping.miredOffset(forSliderValue: 1.0)
        // "clamped >= 25 mired" per spec-04 §4.4 — assert the mapping never produces a
        // target mired below the 25-mired floor from a neutral D65 base (~154 mired).
        XCTAssertGreaterThanOrEqual(154 + extreme, 25 - 0.5)
    }

    func testZeroSliderIsIdentity() {
        XCTAssertEqual(MiredMapping.miredOffset(forSliderValue: 0), 0, accuracy: 0.01)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -scheme Muse -only-testing:MuseTests/MiredMappingTests test`
Expected: FAIL — type doesn't exist.

- [ ] **Step 3: Implement the pure mired mapping**

```swift
/// Temperature slider -> mired offset. +1 <-> 3000K-equivalent warm; the cool side the
/// SAME mired distance (Surface's ToneFilterStage.swift lesson: naive Kelvin-space
/// mapping is warm/cool-asymmetric because Kelvin and perceived warmth are non-linear —
/// mired space is where equal slider steps read as equal perceptual steps).
nonisolated enum MiredMapping {
    private static let d65Mired = 1_000_000.0 / 6500.0 // ~154 mired
    private static let warmTargetKelvin = 3000.0
    private static let miredFloor = 25.0

    static func miredOffset(forSliderValue value: Double) -> Double {
        let warmMiredDistance = (1_000_000.0 / warmTargetKelvin) - d65Mired
        let offset = value * warmMiredDistance
        let target = d65Mired + offset
        let clampedTarget = max(target, miredFloor)
        return clampedTarget - d65Mired
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild -scheme Muse -only-testing:MuseTests/MiredMappingTests test`
Expected: PASS

- [ ] **Step 5: Implement `RawSource.decode`** — this part is NOT independently unit-testable
without a real RAW fixture (owner-verified per Task 14.2), so write it directly against the
spec's exact list (spec-04 §4.5 / DECISIONS "Render pipeline"):

```swift
import CoreImage

nonisolated enum RawSource {
    /// Decodes a RAW/DNG source into linear working-space, neutralizing Apple's default
    /// look (WWDC21 §10160) and routing the SAME slider values the encoded path uses
    /// (ColorParams.temperature/tint, PresenceParams.noiseReduction/sharpen) into
    /// CIRAWFilter's own params — never CITemperatureAndTint on a RAW source's output.
    static func decode(url: URL, params: RawParams?, color: ColorParams,
                       presence: PresenceParams) -> LinearImage? {
        guard let filter = CIRAWFilter(imageURL: url) else { return nil }
        func setIfSupported<T>(_ option: String, _ value: T) {
            guard filter.isSupported(option: option) else { return }
            filter.setValue(value, forKey: option)
        }
        setIfSupported(kCIInputBaselineExposureKey, 0.0)
        setIfSupported("inputShadowBias", 0.0)
        setIfSupported("inputBoostAmount", 0.0)
        setIfSupported("inputLocalToneMapAmount", 0.0)
        setIfSupported("inputGamutMappingEnabled", false)

        let miredOffset = MiredMapping.miredOffset(forSliderValue: color.temperature)
        if filter.isSupported(option: kCIInputNeutralTemperatureKey) {
            let asShotTemp = filter.value(forKey: kCIInputNeutralTemperatureKey) as? Double ?? 6500
            setIfSupported(kCIInputNeutralTemperatureKey, 1_000_000.0 / (1_000_000.0 / asShotTemp + miredOffset))
        }
        setIfSupported(kCIInputNeutralTintKey, color.tint * 50)
        setIfSupported("inputLuminanceNoiseReductionAmount", presence.noiseReduction)
        setIfSupported("inputSharpnessAmount", presence.sharpen)
        setIfSupported("inputEnableLensCorrection", params?.lensCorrection ?? true)

        guard let output = filter.outputImage else { return nil }
        return LinearImage.alreadyDecodedFromFile(output)
    }
}
```

(Exact `CIRAWFilter` key names vary by SDK version — `grep` Apple's `CoreImage` header via
`xcrun --sdk macosx --show-sdk-path` + search `CIRAWFilter.h` for the real constant names
before finalizing; the string literals above are placeholders for keys not exposed as typed
constants in older SDKs.)

- [ ] **Step 6: Commit**

```bash
git add "Muse/Muse/Editing/Render/RawSource.swift" "Muse/MuseTests/MiredMappingTests.swift"
git commit -m "feat(editing): RawSource — CIRAWFilter hybrid decode + mired temperature mapping"
```

### Task 3.5: `Editing/Render/EditRenderer.swift` — the fixed chain

**Files:**
- Create: `Muse/Muse/Editing/Render/EditRenderer.swift`
- Test: extend `Muse/MuseTests/EditRenderNeutralityTests.swift`,
  `Muse/MuseTests/HighlightRecoveryTests.swift`, `Muse/MuseTests/GeometryParamsTests.swift`

**Interfaces:**
- Consumes: `EditStack`, `LinearImage`/`EncodedImage` (3.1), `CurveLUT` (3.2), `EditKernels`
  (3.3), `RawSource` (3.4).
- Produces:
  ```swift
  nonisolated enum EditRenderer {
      static func apply(_ stack: EditStack, to image: LinearImage, sourceLongEdge: CGFloat) -> LinearImage
      static func canRender(_ stack: EditStack) -> Bool
      static func render(url: URL, stack: EditStack, maxPixel: Int) -> CGImage?
      static func exportFile(url: URL, stack: EditStack, to dest: URL, format: OutputFormat) throws
  }
  ```

- [ ] **Step 1: Write `GeometryParamsTests`** (pure, independent of the renderer):

```swift
import XCTest
@testable import Muse

final class GeometryParamsTests: XCTestCase {
    func testAppliedDisplaySizeNoOpAtIdentity() {
        let g = GeometryParams()
        XCTAssertEqual(g.appliedDisplaySize(to: CGSize(width: 100, height: 50)),
                       CGSize(width: 100, height: 50))
    }

    func testQuarterTurnsSwapDimensions() {
        var g = GeometryParams(); g.quarterTurns = 1
        let result = g.appliedDisplaySize(to: CGSize(width: 100, height: 50))
        XCTAssertEqual(result, CGSize(width: 50, height: 100))
    }

    func testCropAppliesUnitRectToSize() {
        var g = GeometryParams()
        g.crop = CropRect(x: 0.25, y: 0.25, w: 0.5, h: 0.5)
        let result = g.appliedDisplaySize(to: CGSize(width: 200, height: 200))
        XCTAssertEqual(result, CGSize(width: 100, height: 100))
    }

    func testFlipsDoNotChangeSize() {
        var g = GeometryParams(); g.flipH = true; g.flipV = true
        XCTAssertEqual(g.appliedDisplaySize(to: CGSize(width: 80, height: 40)),
                       CGSize(width: 80, height: 40))
    }
}
```

Run + expect FAIL (no `appliedDisplaySize` body yet, only the signature stub from Task 1.1
if left unimplemented — implement it now in `EditStack.swift`):

```swift
extension GeometryParams {
    func appliedDisplaySize(to source: CGSize) -> CGSize {
        var size = source
        if let crop { size = CGSize(width: size.width * crop.w, height: size.height * crop.h) }
        if quarterTurns % 2 == 1 { size = CGSize(width: size.height, height: size.width) }
        return size
    }
}
```

Run again, expect PASS, commit alongside Task 1.1's file (`git commit -m "feat(editing):
GeometryParams.appliedDisplaySize — post-geometry layout size"`).

- [ ] **Step 2: Write `HighlightRecoveryTests`** (the scene-referred pin):

```swift
import XCTest
import CoreImage
@testable import Muse

final class HighlightRecoveryTests: XCTestCase {
    func testNegativeExposureRecoversClippedHighlightDetail() {
        // Synthetic linear fixture with data > 1.0 in a region (simulating scene-referred
        // highlight headroom a scene-referred pipeline must preserve).
        let hot = CIImage(color: CIColor(red: 2.0, green: 2.0, blue: 2.0)).cropped(
            to: CGRect(x: 0, y: 0, width: 8, height: 8))
        let linear = LinearImage.alreadyDecodedFromFile(hot)
        var stack = EditStack.fresh()
        var tone = ToneParams.neutral; tone.exposureEV = -2
        stack.adjustments = [.tone(tone)]
        let result = EditRenderer.apply(stack, to: linear, sourceLongEdge: 8)
        // Rendering to a bitmap context and reading pixels is the only way to assert this
        // for real; a CIContext render + pixel readback belongs here once the chain (Task
        // 3.5 Step 4) exists. This test's SHAPE is the required pin; fill in the pixel
        // readback assertion once EditRenderer.apply compiles.
        XCTAssertNotNil(result.ciImage)
    }
}
```

- [ ] **Step 3: Write `EditRenderNeutralityTests`**:

```swift
import XCTest
import CoreImage
@testable import Muse

final class EditRenderNeutralityTests: XCTestCase {
    func testAllNeutralStackIsVisuallyIdentityWithinTolerance() {
        let source = CIImage(color: .gray).cropped(to: CGRect(x: 0, y: 0, width: 16, height: 16))
        let linear = LinearImage.alreadyDecodedFromFile(source)
        let neutral = EditStack.fresh()
        let result = EditRenderer.apply(neutral, to: linear, sourceLongEdge: 16)
        // Pixel-level comparison via a shared CIContext render — fill in with real
        // readback once the render context (Task 3.6) exists; the SHAPE (apply a fully
        // neutral stack, assert byte-tolerant identity) is what's pinned here.
        XCTAssertNotNil(result.ciImage)
    }
}
```

- [ ] **Step 4: Run all three test files to verify they fail/compile-error**

Run: `xcodebuild -scheme Muse -only-testing:MuseTests/HighlightRecoveryTests
-only-testing:MuseTests/EditRenderNeutralityTests test`
Expected: FAIL — `EditRenderer` doesn't exist yet.

- [ ] **Step 5: Implement `EditRenderer.apply` — the fixed chain**, per spec-04 §4.3 (this
is the render pipeline's core; wire each stage using the pieces already built):

```swift
import CoreImage

nonisolated enum EditRenderer {
    /// Fixed chain order — CODE, never data. See spec-04 §4.3.
    static func apply(_ stack: EditStack, to image: LinearImage, sourceLongEdge: CGFloat) -> LinearImage {
        var current = image.ciImage
        let radiusScale = sourceLongEdge

        // 1. geometry
        if let geo = stack.geometryParams {
            current = applyGeometry(geo, to: current)
        }
        // 2. tone: exposure -> temperature/tint (encoded only, handled upstream for RAW) -> toneBands -> contrast
        if let tone = stack.toneParams {
            current = current.applyingFilter("CIExposureAdjust", parameters: ["inputEV": tone.exposureEV])
            current = applyToneBands(tone, to: current)
            current = current.applyingFilter("CIColorControls",
                parameters: ["inputContrast": 1 + 0.75 * tone.contrast, "inputSaturation": 1, "inputBrightness": 0])
        }
        // 3. curve (display-referred exception)
        if let curve = stack.curveParams { current = applyCurve(curve, to: current) }
        // 4. color: vibrance -> saturation
        if let color = stack.colorParams {
            current = current.applyingFilter("CIVibrance", parameters: ["inputAmount": color.vibrance])
            current = current.applyingFilter("CIColorControls",
                parameters: ["inputSaturation": 1 + color.saturation, "inputContrast": 1, "inputBrightness": 0])
        }
        // 5. presence: NR -> clarity -> texture -> sharpen
        if let presence = stack.presenceParams {
            current = applyPresence(presence, to: current, radiusScale: radiusScale)
        }
        // 6. vignette (on the cropped frame)
        if let vignette = stack.vignetteParams { current = applyVignette(vignette, to: current) }

        return LinearImage(current)
    }

    static func canRender(_ stack: EditStack) -> Bool {
        stack.processVersion <= EditStack.currentProcessVersion
    }
}
```

(Add small private helpers `applyGeometry`/`applyToneBands`/`applyCurve`/`applyPresence`/
`applyVignette` in the same file, each implementing exactly one bullet from spec-04 §4.4 —
`applyCurve` uses `CurveLUT.build` → `CIColorCurves` with explicit `inputColorSpace = sRGB`;
`applyPresence`'s clarity/texture calls `EditKernels.clarityTexture` at
`EditKernels.clarityRadiusFraction × radiusScale` and
`EditKernels.textureRadiusFraction × radiusScale`; sharpen uses `CIUnsharpMask` at
`EditKernels.sharpenRadiusFraction × radiusScale`. Add convenience accessors
`stack.toneParams`/`.colorParams`/etc. on `EditStack` in Task 1.1's file if not already
present, each pulling the matching case out of `adjustments` or returning nil.)

- [ ] **Step 6: Run tests, iterate until PASS**

Run: `xcodebuild -scheme Muse -only-testing:MuseTests/HighlightRecoveryTests
-only-testing:MuseTests/EditRenderNeutralityTests -only-testing:MuseTests/GeometryParamsTests test`
Expected: PASS. Fill in the pixel-readback assertions noted in Steps 2–3 now that
`EditRenderer.apply` compiles (render via a throwaway `CIContext` + `CGImage` +
`CGDataProvider` byte read, compare against tolerance).

- [ ] **Step 7: Commit**

```bash
git add "Muse/Muse/Editing/Render/EditRenderer.swift" "Muse/Muse/Editing/EditStack.swift" \
  "Muse/MuseTests/HighlightRecoveryTests.swift" "Muse/MuseTests/EditRenderNeutralityTests.swift" \
  "Muse/MuseTests/GeometryParamsTests.swift"
git commit -m "feat(editing): EditRenderer.apply — fixed chain (geometry/tone/curve/color/presence/vignette)"
```

### Task 3.6: `Editing/Render/RenderContexts.swift` + `Views/Editor/EditCanvasView.swift`

**Files:**
- Create: `Muse/Muse/Editing/Render/RenderContexts.swift`
- Create: `Muse/Muse/Views/Editor/EditCanvasView.swift`

**Interfaces:**
- Produces: `enum RenderContexts { static let preview: CIContext; static func makeExportContext() -> CIContext }`,
  `struct EditCanvasView: NSViewRepresentable` (MTKView-backed).

- [ ] **Step 1: Implement `RenderContexts`** (no test — a `CIContext` construction has no
meaningful pure-logic assertion beyond "it doesn't crash"; covered by the
`EditRenderConsistencyTests` golden in Task 3.8, which exercises it end-to-end):

```swift
import CoreImage
import Metal

nonisolated enum RenderContexts {
    static let preview: CIContext = {
        let device = MTLCreateSystemDefaultDevice()
        let options: [CIContextOption: Any] = [
            .cacheIntermediates: true,
            .workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB) as Any,
            .name: "muse.edit.preview"
        ]
        return device.map { CIContext(mtlDevice: $0, options: options) } ?? CIContext(options: options)
    }()

    /// Fresh per export, released after — NOT cached_intermediates, 1 GB memory limit
    /// (no Extended Virtual Addressing entitlement on macOS — deviation D4, spec-04 §4.7).
    static func makeExportContext() -> CIContext {
        let device = MTLCreateSystemDefaultDevice()
        let options: [CIContextOption: Any] = [
            .cacheIntermediates: false,
            .memoryTarget: 1_073_741_824
        ]
        return device.map { CIContext(mtlDevice: $0, options: options) } ?? CIContext(options: options)
    }
}
```

(Confirm the exact `CIContextOption` key for the 1 GB memory limit in the target SDK —
`.memoryTarget` vs a differently-named constant — via Xcode's Quick Help before finalizing.)

- [ ] **Step 2: Implement `EditCanvasView`** — an `NSViewRepresentable` wrapping an
`MTKView` (`isPaused = true`, `enableSetNeedsDisplay = true`, `framebufferOnly = false`),
drawing via `CIRenderDestination` at screen scale. This is a thin AppKit shell with no pure
logic to unit test (house convention: no UI unit tests); wire it to accept a `CIImage`
binding that the coalescer (Task 3.7) updates, and trigger `setNeedsDisplay` on change.

```swift
import SwiftUI
import MetalKit
import CoreImage

struct EditCanvasView: NSViewRepresentable {
    @Binding var image: CIImage?

    func makeNSView(context: Context) -> MTKView {
        let view = MTKView()
        view.device = MTLCreateSystemDefaultDevice()
        view.isPaused = true
        view.enableSetNeedsDisplay = true
        view.framebufferOnly = false
        view.delegate = context.coordinator
        return view
    }

    func updateNSView(_ nsView: MTKView, context: Context) {
        context.coordinator.image = image
        nsView.setNeedsDisplay(nsView.bounds)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, MTKViewDelegate {
        var image: CIImage?
        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}
        func draw(in view: MTKView) {
            guard let image, let drawable = view.currentDrawable,
                  let commandBuffer = view.device?.makeCommandQueue()?.makeCommandBuffer()
            else { return }
            let destination = CIRenderDestination(width: Int(view.drawableSize.width),
                                                   height: Int(view.drawableSize.height),
                                                   pixelFormat: view.colorPixelFormat,
                                                   commandBuffer: commandBuffer) { () -> MTLTexture in
                drawable.texture
            }
            try? RenderContexts.preview.startTask(toRender: image, to: destination)
            commandBuffer.present(drawable)
            commandBuffer.commit()
        }
    }
}
```

- [ ] **Step 3: Build to confirm it compiles**

Run: `xcodebuild -scheme Muse build`
Expected: BUILD SUCCEEDED.

- [ ] **Step 4: Commit**

```bash
git add "Muse/Muse/Editing/Render/RenderContexts.swift" "Muse/Muse/Views/Editor/EditCanvasView.swift"
git commit -m "feat(editing): RenderContexts (preview/export CIContext) + EditCanvasView MTKView"
```

### Task 3.7: `Editing/Render/RenderCoalescer.swift` — slider render throttling

**Files:**
- Create: `Muse/Muse/Editing/Render/RenderCoalescer.swift`
- Test: `Muse/MuseTests/RenderCoalescerTests.swift`

**Interfaces:**
- Produces: `actor RenderCoalescer { func request(_ stack: EditStack, render: @Sendable
  (EditStack) async -> CGImage?) async -> CGImage? }` (or an equivalent shape: at most one
  render in flight, latest params win, no queue).

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import Muse

final class RenderCoalescerTests: XCTestCase {
    func testOnlyLatestRequestRendersWhenBurstSubmitted() async {
        let coalescer = RenderCoalescer()
        actor Counter { var renderedValues: [Int] = []; func record(_ v: Int) { renderedValues.append(v) } }
        let counter = Counter()
        // Submit a burst; the coalescer must render at most one-in-flight and the LAST
        // submitted value must be among the rendered ones (never dropped silently).
        await withTaskGroup(of: Void.self) { group in
            for i in 1...5 {
                group.addTask {
                    _ = await coalescer.request(i) { v in
                        try? await Task.sleep(nanoseconds: 5_000_000)
                        await counter.record(v)
                        return v
                    }
                }
            }
        }
        let rendered = await counter.renderedValues
        XCTAssertTrue(rendered.contains(5) || rendered.last == 5)
        XCTAssertLessThan(rendered.count, 5) // coalesced — not every request rendered
    }
}
```

(Adjust the generic type from `EditStack` to a plain `Int` in the test for simplicity if
`RenderCoalescer` is written generically — decide the concrete signature in Step 2 and match
the test to it.)

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -scheme Muse -only-testing:MuseTests/RenderCoalescerTests test`
Expected: FAIL — type doesn't exist.

- [ ] **Step 3: Implement**

```swift
/// At most ONE render in flight; a newer request overwrites the pending slot; on
/// completion the pending (latest) params render next. Slider drags render at whatever
/// rate the GPU sustains, never queueing (Surface's unthrottled per-tick loop is the
/// named anti-pattern this replaces).
actor RenderCoalescer<Params: Sendable, Output: Sendable> {
    private var inFlight = false
    private var pending: Params?
    private var pendingContinuations: [CheckedContinuation<Output?, Never>] = []

    func request(_ params: Params, render: @Sendable (Params) async -> Output?) async -> Output? {
        if inFlight {
            pending = params
            return await withCheckedContinuation { cont in
                pendingContinuations.append(cont)
            }
        }
        inFlight = true
        let result = await render(params)
        inFlight = false
        if let next = pending {
            pending = nil
            let conts = pendingContinuations
            pendingContinuations = []
            let nextResult = await request(next, render: render)
            for c in conts { c.resume(returning: nextResult) }
        }
        return result
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild -scheme Muse -only-testing:MuseTests/RenderCoalescerTests test`
Expected: PASS (iterate the actor's recursion/continuation-fanout logic if the test reveals a
race — this is inherently concurrency-sensitive code; run the test multiple times, e.g. `-repeat-count 20`).

- [ ] **Step 5: Wire it into `EditSession`'s render pipeline** — deferred to Task 5.2 (the
`EditSession` doesn't exist until Phase 5); note here only that `RenderCoalescer<EditStack,
CGImage>` is the concrete type Task 5.2 instantiates.

- [ ] **Step 6: Commit**

```bash
git add "Muse/Muse/Editing/Render/RenderCoalescer.swift" "Muse/MuseTests/RenderCoalescerTests.swift"
git commit -m "feat(editing): RenderCoalescer actor — at-most-one-in-flight slider render throttling"
```

### Task 3.8: `EditRenderConsistencyTests` — the required golden gate

**Files:**
- Create: `Muse/MuseTests/EditRenderConsistencyTests.swift`
- Create: `Muse/MuseTests/Fixtures/` (two fixture images: one landscape, one portrait with
  EXIF rotation — check whichever existing fixture-image convention `MuseTests` already uses,
  e.g. `grep -rl "Bundle(for:" Muse/MuseTests/*.swift` for how other tests load test images,
  and follow that pattern rather than inventing a new one)

**Interfaces:**
- Consumes: `EditRenderer.apply` (3.5), `RenderContexts` (3.6).

- [ ] **Step 1: Write the test** — this is the spec's REQUIRED gate (§4.6/§12): one
all-groups-non-neutral fixture stack, two fixture images (landscape + portrait-EXIF-rotated),
rendered at 256/1024/full, downsampled to 256, mean per-channel error below tolerance:

```swift
import XCTest
import CoreImage
@testable import Muse

final class EditRenderConsistencyTests: XCTestCase {
    let tolerance: Double = 3.0 / 255.0 // starting tolerance; goldens regenerate via a flag

    func allGroupsStack() -> EditStack {
        var stack = EditStack.fresh()
        var tone = ToneParams.neutral; tone.exposureEV = 0.5; tone.contrast = 0.2
        var color = ColorParams.neutral; color.vibrance = 0.3; color.saturation = 0.1
        var presence = PresenceParams.neutral; presence.clarity = 0.3; presence.sharpen = 0.4
        var vignette = VignetteParams.neutral; vignette.amount = -0.3
        stack.adjustments = [.tone(tone), .color(color), .presence(presence), .vignette(vignette)]
        return stack
    }

    func renderDownsampledTo256(fixtureName: String, longEdgeDecode: Int) throws -> CGImage {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: fixtureName, withExtension: "jpg"))
        let cgImage = try XCTUnwrap(EditRenderer.render(url: url, stack: allGroupsStack(), maxPixel: longEdgeDecode))
        // downsample cgImage to 256 long edge via CGContext for comparison
        return try downsample(cgImage, to: 256)
    }

    func downsample(_ image: CGImage, to longEdge: Int) throws -> CGImage {
        let scale = CGFloat(longEdge) / CGFloat(max(image.width, image.height))
        let w = Int(CGFloat(image.width) * scale), h = Int(CGFloat(image.height) * scale)
        let ctx = try XCTUnwrap(CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                                          bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return try XCTUnwrap(ctx.makeImage())
    }

    func meanChannelError(_ a: CGImage, _ b: CGImage) throws -> Double {
        // Read both images' pixel buffers and compute mean |a-b| per channel, normalized
        // to 0...1. Implementation reads raw bytes via CGDataProvider — same technique
        // Task 3.5's readback helper uses; factor a shared XCTestCase extension if both
        // need it.
        0.0 // filled in once the readback helper exists
    }

    func testLandscapeFixtureAgreesAcrossResolutions() throws {
        let r256 = try renderDownsampledTo256(fixtureName: "landscape", longEdgeDecode: 256)
        let r1024 = try renderDownsampledTo256(fixtureName: "landscape", longEdgeDecode: 1024)
        let rFull = try renderDownsampledTo256(fixtureName: "landscape", longEdgeDecode: 4096)
        XCTAssertLessThan(try meanChannelError(r256, r1024), tolerance)
        XCTAssertLessThan(try meanChannelError(r1024, rFull), tolerance)
    }

    func testPortraitExifRotatedFixtureAgreesAcrossResolutions() throws {
        let r256 = try renderDownsampledTo256(fixtureName: "portrait-exif6", longEdgeDecode: 256)
        let r1024 = try renderDownsampledTo256(fixtureName: "portrait-exif6", longEdgeDecode: 1024)
        let rFull = try renderDownsampledTo256(fixtureName: "portrait-exif6", longEdgeDecode: 4096)
        XCTAssertLessThan(try meanChannelError(r256, r1024), tolerance)
        XCTAssertLessThan(try meanChannelError(r1024, rFull), tolerance)
    }
}
```

- [ ] **Step 2: Add the two fixture images** to the test bundle (a real landscape JPEG and a
real portrait JPEG saved with EXIF orientation 6 — source these from any existing test
fixture directory, or generate synthetically via a small script that writes a gradient JPEG
with the orientation tag set; register them in the `MuseTests` target's "Copy Bundle
Resources" build phase).

- [ ] **Step 3: Fill in `meanChannelError`'s pixel readback**, run, and iterate

Run: `xcodebuild -scheme Muse -only-testing:MuseTests/EditRenderConsistencyTests test`
Expected: initially likely FAIL — this test is what drives fixing the scale-normalization
bugs in Task 3.5's `applyPresence`/`applyVignette` radius math (every scale-dependent
parameter must be `fraction × sourceLongEdge`, scaled by the actual decode ratio — go back
and fix `EditRenderer`'s radius calculations until this passes, per the Global Constraint).
Expected once fixed: PASS.

- [ ] **Step 4: Commit**

```bash
git add "Muse/MuseTests/EditRenderConsistencyTests.swift" "Muse/MuseTests/Fixtures/"
git commit -m "test(editing): EditRenderConsistencyTests — the required thumbnail/screen/export golden gate"
```

*(This is the phase-3 exit gate per spec-04 §13: it must be green before Phase 4 lands.)*


## Phase 4 — `EditStore`, live provider, consumer sweep (first user-visible commit)

### Task 4.1: `LiveEditStackProvider` + install at launch

**Files:**
- Modify: `Muse/Muse/Models/EditStackIndex.swift` (add `LiveEditStackProvider`,
  `resolvedStack(for:)`)
- Modify: `Muse/Muse/MuseApp.swift` (`.task`, ~line 102 — install before backfills)
- Test: extend `Muse/MuseTests/EditStackIndexTests.swift`

**Interfaces:**
- Consumes: `EditRecordStore.read` (2.2), `ImageHeaderSizeCache.cached` (existing),
  `GeometryParams.appliedDisplaySize` (3.5 Step 1).
- Produces: `struct LiveEditStackProvider: EditStackProviding`, `EditStackIndex.resolvedStack(for:
  URL) -> EditStack?`, `EditStackIndex.rebuild(from rows: [(path: String, row: EditRow)])`
  (or equivalent bulk-load entry the store calls).

- [ ] **Step 1: Write the failing test**

```swift
func testResolvedStackReturnsDecodedStackFromRebuiltIndex() {
    let path = "/tmp/edited.jpg"
    var stack = EditStack.fresh()
    var tone = ToneParams.neutral; tone.exposureEV = 1
    stack.adjustments = [.tone(tone)]
    let json = try! EditStackCodec.encode(stack)
    EditStackIndex.rebuild(entries: [(path: path, stackJSON: json, hash: EditStackCodec.hash(stack))])
    XCTAssertEqual(EditStackIndex.resolvedStack(for: URL(fileURLWithPath: path)), stack)
}
```

(Add to `EditStackIndexTests.swift`; adjust `rebuild(entries:)`'s parameter shape once Step 3
below settles the exact signature — the test's job is to pin the observable contract:
rebuild → resolvedStack returns the decoded stack for a matching path.)

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -scheme Muse -only-testing:MuseTests/EditStackIndexTests test`
Expected: FAIL.

- [ ] **Step 3: Implement** — add to `EditStackIndex.swift`:

```swift
private struct IndexEntry {
    let stackJSON: String
    let hash: String
    let geometry: GeometryParams?
    let processRenderable: Bool
    var decodedStack: EditStack? // lazily populated
}

extension EditStackIndex {
    private static nonisolated(unsafe) var entries: [String: IndexEntry] = [:]

    static func rebuild(entries newEntries: [(path: String, stackJSON: String, hash: String)]) {
        lock.lock(); defer { lock.unlock() }
        var built: [String: IndexEntry] = [:]
        for e in newEntries {
            let decoded = EditStackCodec.decode(e.stackJSON)
            built[e.path] = IndexEntry(stackJSON: e.stackJSON, hash: e.hash,
                                       geometry: decoded?.geometryParams,
                                       processRenderable: decoded.map(EditRenderer.canRender) ?? false,
                                       decodedStack: decoded)
        }
        entries = built
    }

    static func resolvedStack(for url: URL) -> EditStack? {
        lock.lock(); defer { lock.unlock() }
        return entries[url.standardizedFileURL.path]?.decodedStack
    }
}

/// No I/O, ever — read from the thumbnail pipeline off-main. Keyed by standardized path.
struct LiveEditStackProvider: EditStackProviding {
    func stackHash(for url: URL) -> String? {
        EditStackIndex.hashOnly(for: url) // small internal lookup into `entries`
    }
    func croppedSize(for url: URL) -> CGSize? {
        guard let geometry = EditStackIndex.geometryOnly(for: url),
              let headerSize = ImageHeaderSizeCache.cached(url)
        else { return nil }
        return geometry.appliedDisplaySize(to: headerSize)
    }
}
```

(`lock` must be the SAME `NSLock` already declared in Task 0.1 — add `hashOnly`/
`geometryOnly` as small private accessors into the same `entries` dictionary under the
existing lock, not a second lock.)

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild -scheme Muse -only-testing:MuseTests/EditStackIndexTests test`
Expected: PASS

- [ ] **Step 5: Install at launch** — in `MuseApp.swift`'s `.task` (before the existing
backfills, per spec-04 §3.3):

```swift
EditStackIndex.installProvider(LiveEditStackProvider())
Task.detached(priority: .utility) {
    await EditStore.shared.rebuildIndex() // Task 4.2 implements this
}
```

- [ ] **Step 6: Build to confirm it compiles** (full `EditStore.shared.rebuildIndex()` lands
in Task 4.2 — stub it as an empty async func here if sequencing this task first, or do Tasks
4.1/4.2 as one combined commit; sequencing them separately risks an intermediate non-compiling
state, so prefer combining 4.1+4.2 into one PR/commit in practice even though they're written
as separate tasks here for review-granularity).

- [ ] **Step 7: Commit** (deferred to end of Task 4.2 — see that task's Step 6)

### Task 4.2: `Models/EditStore.swift` — Pattern B store + save sequence

**Files:**
- Create: `Muse/Muse/Models/EditStore.swift`
- Test: `Muse/MuseTests/EditStoreTests.swift`

**Interfaces:**
- Consumes: `EditRecordStore` (2.2), `EditStackIndex.rebuild` (4.1),
  `AppState.markContentChanged` (existing, `AppState.swift:119`),
  `AnalyzePipeline.exportSidecarsAfterEditChange` (2.4).
- Produces:
  ```swift
  @MainActor final class EditStore: ObservableObject {
      static let shared = EditStore()
      @Published private(set) var generation = 0
      func stack(for url: URL) async -> EditStack?
      func save(_ stack: EditStack, for url: URL) async
      func reset(for url: URL) async
      func versions(for url: URL) async -> [EditVersionRow]
      func saveVersion(name: String, kind: String, stack: EditStack, for url: URL) async
      func switchToVersion(_ id: String, for url: URL) async
      func rebuildIndex() async
      func warmIndex(paths: [String]) async
  }
  ```

- [ ] **Step 1: Write the failing test** (drive it against a real in-memory `DatabaseQueue`
via whatever test-seam the app already uses to inject a test DB — `grep -rn "DatabaseQueue()"
Muse/MuseTests/*.swift` for the existing pattern other Pattern-B store tests use, e.g.
`CompareStoreTests`/`RediscoveryQueriesTests`, and follow it):

```swift
import XCTest
@testable import Muse

@MainActor
final class EditStoreTests: XCTestCase {
    func testSaveThenStackReturnsSavedValue() async throws {
        // Seed a test DB + a resolvable (fileID, parentDir) for a fixture URL via
        // whatever harness TagStoreTests/NoteStoreTests already use to fake tagScopes —
        // reuse it rather than reinventing file/path resolution.
        let url = try makeTestFile() // helper from the shared test harness
        var stack = EditStack.fresh()
        var tone = ToneParams.neutral; tone.exposureEV = 1
        stack.adjustments = [.tone(tone)]

        await EditStore.shared.save(stack, for: url)
        let read = await EditStore.shared.stack(for: url)
        XCTAssertEqual(read, stack)
    }

    func testResetDeletesTheRow() async throws {
        let url = try makeTestFile()
        var stack = EditStack.fresh()
        var tone = ToneParams.neutral; tone.exposureEV = 1
        stack.adjustments = [.tone(tone)]
        await EditStore.shared.save(stack, for: url)
        await EditStore.shared.reset(for: url)
        let read = await EditStore.shared.stack(for: url)
        XCTAssertNil(read)
    }

    func testSaveBumpsGeneration() async throws {
        let url = try makeTestFile()
        let before = EditStore.shared.generation
        await EditStore.shared.save(EditStack.fresh(), for: url)
        XCTAssertGreaterThan(EditStore.shared.generation, before)
    }

    func testSaveOfNeutralStackDeletesRatherThanWritesNoOp() async throws {
        let url = try makeTestFile()
        await EditStore.shared.save(EditStack.fresh(), for: url) // fully neutral
        let read = await EditStore.shared.stack(for: url)
        XCTAssertNil(read) // "no edit" is the absence of a row
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -scheme Muse -only-testing:MuseTests/EditStoreTests test`
Expected: FAIL — type doesn't exist (and `makeTestFile()`'s harness needs writing/reusing
first — check for an existing shared fixture helper via `grep -rl "func makeTestFile"
Muse/MuseTests/` before authoring a new one).

- [ ] **Step 3: Implement `EditStore`** — the save sequence in one place, in order, per
spec-04 §3.5:

```swift
import Foundation

@MainActor final class EditStore: ObservableObject {
    static let shared = EditStore()
    @Published private(set) var generation = 0
    private init() {}

    func stack(for url: URL) async -> EditStack? {
        guard let scope = await resolveScope(for: url) else { return nil }
        return await Database.shared.read { db in
            try EditRecordStore.read(fileID: scope.fileID, parentDir: scope.parentDir, db: db)
        }.flatMap { EditStackCodec.decode($0.stack) }
    }

    func save(_ stack: EditStack, for url: URL) async {
        guard let scope = await resolveScope(for: url) else { return } // can't happen: file was open
        let normalized = stack.normalized()
        if normalized.isNeutral {
            await Database.shared.write { db in
                try EditRecordStore.delete(fileID: scope.fileID, parentDir: scope.parentDir, db: db)
            }
        } else {
            let json = try! EditStackCodec.encode(normalized)
            let hash = EditStackCodec.hash(normalized)
            let now = Int64(Date().timeIntervalSince1970)
            await Database.shared.write { db in
                try EditRecordStore.write(stackJSON: json, hash: hash,
                                          processVersion: normalized.processVersion,
                                          fileID: scope.fileID, parentDir: scope.parentDir,
                                          updatedAt: now, db: db)
            }
        }
        await warmIndex(paths: [url.standardizedFileURL.path])
        AppState.shared.markContentChanged([url.standardizedFileURL.path])
        generation += 1
        await AnalyzePipeline.shared.exportSidecarsAfterEditChange(for: [url])
    }

    func reset(for url: URL) async {
        await save(EditStack.fresh(), for: url)
    }

    func versions(for url: URL) async -> [EditVersionRow] {
        guard let scope = await resolveScope(for: url) else { return [] }
        return (try? await Database.shared.read { db in
            try EditRecordStore.versions(fileID: scope.fileID, parentDir: scope.parentDir, db: db)
        }) ?? []
    }

    func saveVersion(name: String, kind: String, stack: EditStack, for url: URL) async {
        guard let scope = await resolveScope(for: url) else { return }
        let json = try! EditStackCodec.encode(stack.normalized())
        let row = EditVersionRow(id: UUID().uuidString, file_id: scope.fileID,
                                 parent_dir: scope.parentDir, kind: kind, name: name,
                                 stack: json, created_at: Int64(Date().timeIntervalSince1970))
        await Database.shared.write { db in try EditRecordStore.addVersion(row, db: db) }
    }

    func switchToVersion(_ id: String, for url: URL) async {
        guard let scope = await resolveScope(for: url) else { return }
        let current = await stack(for: url) ?? EditStack.fresh()
        // Auto-preserve current as a version first if it isn't already one (§1.4).
        await saveVersion(name: "Before switch", kind: "version", stack: current, for: url)
        let versionsList = await versions(for: url)
        guard let target = versionsList.first(where: { $0.id == id }),
              let targetStack = EditStackCodec.decode(target.stack)
        else { return }
        await save(targetStack, for: url)
    }

    func rebuildIndex() async {
        let rows = (try? await Database.shared.read { db in
            try EditRow.fetchAll(db)
        }) ?? []
        // Resolve each row's (fileID, parentDir) back to a live alive-path — reuse
        // whatever TagStore/NoteStore's scope-to-path resolution already does (grep
        // "tagScopes" per CLAUDE.md's "TagStore.swift:18-30" pattern reference).
        let entries = await resolvePathsForRows(rows)
        EditStackIndex.rebuild(entries: entries)
    }

    func warmIndex(paths: [String]) async {
        // Incremental version of rebuildIndex scoped to `paths` — same resolution,
        // smaller set; called after a folder load and after each save.
        let rows = (try? await Database.shared.read { db in
            try EditRow.fetchAll(db) // filtered by the resolved fileIDs for `paths` in the real impl
        }) ?? []
        let entries = await resolvePathsForRows(rows)
        EditStackIndex.rebuild(entries: entries) // merge semantics TBD — see Step 4 note
    }

    private struct Scope { let fileID: String; let parentDir: String }
    private func resolveScope(for url: URL) async -> Scope? {
        // Mirrors the tagScopes pattern (TagStore.swift:18-30): resolve (fileID,
        // parentDir) from the alive path. Implement by reusing TagStore's existing
        // resolution helper if it's exposed, or duplicating its exact query shape.
        nil // filled in against the real TagStore helper during implementation
    }
    private func resolvePathsForRows(_ rows: [EditRow]) async -> [(path: String, stackJSON: String, hash: String)] {
        [] // filled in against the real alive-paths join during implementation
    }
}
```

(The two private resolution helpers are marked with their real implementation deferred to
match against `TagStore`'s actual scope-resolution code, which this task's author must read
first — `grep -n "func tagScopes\|func resolveScope" Muse/Muse/Database/TagStore.swift` — and
copy the join shape from, not invent independently. This is the one place in the plan where
the exact SQL genuinely depends on reading sibling code first.)

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcodebuild -scheme Muse -only-testing:MuseTests/EditStoreTests
-only-testing:MuseTests/EditStackIndexTests test`
Expected: PASS once `resolveScope`/`resolvePathsForRows` are filled in against the real
`TagStore` pattern.

- [ ] **Step 5: Confirm `MuseApp.swift`'s install line (Task 4.1 Step 5) now compiles fully**

Run: `xcodebuild -scheme Muse build`
Expected: BUILD SUCCEEDED. `stat` the built `.app`'s executable mtime to confirm a fresh
build landed (durable constraint).

- [ ] **Step 6: Commit** (combines Tasks 4.1 + 4.2)

```bash
git add "Muse/Muse/Models/EditStackIndex.swift" "Muse/Muse/Models/EditStore.swift" \
  "Muse/Muse/MuseApp.swift" "Muse/MuseTests/EditStackIndexTests.swift" \
  "Muse/MuseTests/EditStoreTests.swift"
git commit -m "feat(editing): EditStore Pattern-B store + LiveEditStackProvider installed at launch"
```

### Task 4.3: Consumer sweep — thumbnails, hero, OutputRender go live

**Files:**
- Modify: `Muse/Muse/Filesystem/ThumbnailCache.swift` (`generate`, image-kind branch,
  before `imageIOThumbnail`)
- Modify: `Muse/Muse/Views/Viewer/HeroStage.swift` (`loadFullRes`, both mid-res and sharp
  decode passes)
- Modify: `Muse/Muse/Viewers/HeroImageViewer.swift` (`loadDetails`'s `naturalSize`)
- Modify: `Muse/Muse/Export/OutputRender.swift` (`forOutput`/`image` — replace the Phase-0
  identity bodies with real rendering)
- Modify: `Muse/Muse/Export/CollectionPDFExporter.swift` (`imageIOThumbnail` →
  `OutputRender.image`)
- Test: extend `Muse/MuseTests/OutputRenderTests.swift`, add integration cases to
  `Muse/MuseTests/EditStoreTests.swift`

**Interfaces:**
- Consumes: `EditStackIndex.stackHash`/`.resolvedStack` (4.1), `EditRenderer.render`/
  `.exportFile` (3.5).

- [ ] **Step 1: Write the failing test** (extends `OutputRenderTests`):

```swift
func testForOutputRendersThroughEditStackWhenOneExists() async throws {
    let url = try makeTestFile()
    var stack = EditStack.fresh()
    var tone = ToneParams.neutral; tone.exposureEV = 2
    stack.adjustments = [.tone(tone)]
    await EditStore.shared.save(stack, for: url)

    let out = try OutputRender.forOutput(url)
    XCTAssertNotEqual(out.url, url) // a rendered temp file, not the original
    XCTAssertEqual(out.stackHash, EditStackIndex.stackHash(for: url))
}

func testForOutputStillIdentityWhenNoStackExists() throws {
    let url = URL(fileURLWithPath: "/tmp/unedited.jpg")
    let out = try OutputRender.forOutput(url)
    XCTAssertEqual(out.url, url)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -scheme Muse -only-testing:MuseTests/OutputRenderTests test`
Expected: FAIL (still identity today).

- [ ] **Step 3: Implement `OutputRender.forOutput`/`.image` for real**

```swift
enum OutputRender {
    static func forOutput(_ url: URL) throws -> RenderedOutput {
        guard let hash = EditStackIndex.stackHash(for: url),
              let stack = EditStackIndex.resolvedStack(for: url),
              EditRenderer.canRender(stack)
        else { return RenderedOutput(url: url, stackHash: nil) }
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("muse-render/\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let dest = tempDir.appendingPathComponent(url.lastPathComponent)
        try EditRenderer.exportFile(url: url, stack: stack, to: dest, format: .matchingSource(url))
        return RenderedOutput(url: dest, stackHash: hash)
    }

    static func forOutput(_ urls: [URL]) throws -> [RenderedOutput] { try urls.map { try forOutput($0) } }

    static func image(_ out: RenderedOutput, maxPixel: Int) -> CGImage? {
        guard out.stackHash != nil, let stack = EditStackIndex.resolvedStack(for: out.url) else {
            return ThumbnailCache.imageIOThumbnail(url: out.url, maxPixel: maxPixel)
        }
        return EditRenderer.render(url: out.url, stack: stack, maxPixel: maxPixel)
    }
}
```

(`OutputFormat.matchingSource(_:)` and the exact `EditRenderer.exportFile` format table are
Task 8's/§5.3's concern — for THIS task, stub `OutputFormat` minimally with the container
mapping from spec-04 §5.3: JPEG q0.92 / PNG / TIFF / HEIC q0.9, RAW → JPEG q0.92 sRGB on
share paths. A >1-day launch sweep of `tmp/muse-render/` is a small addition beside the
existing `enforceDiskCap` launch call in `MuseApp.swift` — add it in this task's Step 5, not
deferred.)

- [ ] **Step 4: Wire `ThumbnailCache.generate`'s image branch**, `HeroStage.loadFullRes`'s two
decode rungs, and `HeroImageViewer.loadDetails`'s `naturalSize` per spec-04 §5.1/§5.2 — each
is a small `if let hash = EditStackIndex.stackHash(for: url), let stack =
EditStackIndex.resolvedStack(for: url) { /* render via EditRenderer */ } else { /* existing
path, unchanged */ }` guard inserted at the cited call site, with the existing
`withinDecodeBudget`-first check, `!isClosing` guard, and `HeroFlightMotion.settling` writes
in `HeroStage` left completely untouched (per the durable constraint: "every guard in that
function is a named durable constraint" — do not restructure `loadFullRes`, only swap the
decode closure's body).

- [ ] **Step 5: Add the `tmp/muse-render/` launch sweep**

`grep -n "enforceDiskCap" Muse/Muse/MuseApp.swift` and add a sibling call deleting
`muse-render/` subdirectories older than 1 day, same launch-task shape.

- [ ] **Step 6: Convert `CollectionPDFExporter.imageIOThumbnail`** to call
`OutputRender.image(_:maxPixel:)` instead of its own bounded decode (Task 0.4 already
threaded `RenderedOutput` through this call site as identity; this step is the "now it
renders" flip, no signature change needed).

- [ ] **Step 7: Run tests to verify they pass**

Run: `xcodebuild -scheme Muse -only-testing:MuseTests/OutputRenderTests
-only-testing:MuseTests/EditStoreTests test`
Expected: PASS. Also run `ThumbnailVariantTests`, `EditRenderConsistencyTests` in full — no
new thumbnail variant should appear (edited renders use the enumerated sizes).

- [ ] **Step 8: Manual verification in the running app** (per the verify-runtime-not-just-tests
rule — a render pipeline touching Metal/CIContext needs a real run, not just green tests):
build, run, open a photo, save a test stack via a temporary debug hook or the not-yet-built
editor UI (Phase 5) — if Phase 5 isn't built yet, verify via a unit test that calls
`EditStore.shared.save` directly against a real sample image on disk and confirms the grid
thumbnail visibly changes after `invalidate`. Note in the commit message that full visual
verification is deferred to Phase 5's manual QA pass once the editor UI exists.

- [ ] **Step 9: Commit**

```bash
git add "Muse/Muse/Filesystem/ThumbnailCache.swift" "Muse/Muse/Views/Viewer/HeroStage.swift" \
  "Muse/Muse/Viewers/HeroImageViewer.swift" "Muse/Muse/Export/OutputRender.swift" \
  "Muse/Muse/Export/CollectionPDFExporter.swift" "Muse/Muse/MuseApp.swift" \
  "Muse/MuseTests/OutputRenderTests.swift"
git commit -m "feat(editing): consumer sweep — thumbnails/hero/OutputRender render through edit stack"
```

### Task 4.4: Grid badge (bottom-trailing "Edited")

**Files:**
- Modify: `Muse/Muse/Views/GridView.swift` (badge corners, `gridSignature`,
  `TileView.drawnAspectRatio` — the last is already done in Task 0.3, confirm no regression)

**Interfaces:**
- Consumes: `EditStore.generation`, `EditStore.shared.versions` (4.2).

- [ ] **Step 1: Add `EditStore.generation` to `gridSignature`**

`grep -n "var gridSignature" Muse/Muse/Views/GridView.swift` (cited ~line 677) — append
`\(EditStore.shared.generation)` to the computed string alongside the existing components.

- [ ] **Step 2: Add the bottom-trailing "Edited" badge** — glyph `slider.horizontal.3`, 10pt,
capsule, `badgeInset = 6` (matching the existing star-badge visual family, cited
`GridView.swift:911`). Data source: a small published `[String: Int]` map on `EditStore`
(path → version count for paths currently in view), refreshed alongside `warmIndex(paths:)`
(add this map + refresh call to `EditStore.swift` from Task 4.2 as a small follow-up edit in
this task, not a separate task — it's the same store). Not a click target; VoiceOver label
`String(localized: "Edited")` / `String(localized: "Edited, %lld versions")` via
`.accessibilityLabel`.

- [ ] **Step 3: Manual verification in the running app**

Build and run; save a test edit via a unit test or temporary debug affordance against a real
sample photo in a folder the app has open; confirm the badge appears on the correct tile and
the grid relayouts correctly if the stack crops (aspect change via `EffectiveDimensions`,
already wired in Task 0.3).

- [ ] **Step 4: Commit**

```bash
git add "Muse/Muse/Views/GridView.swift" "Muse/Muse/Models/EditStore.swift"
git commit -m "feat(editing): grid Edited badge (bottom-trailing) + gridSignature EditStore.generation"
```


## Phase 5 — Theme layer + editor shell

### Task 5.1: `Views/Theme/Theme.swift`

**Files:**
- Create: `Muse/Muse/Views/Theme/Theme.swift`
- Modify: `Muse/Muse/ContentView.swift` (inject once via `.environment(\.theme, ...)`)

**Interfaces:**
- Produces: `struct Theme { panelFill, panelStroke, controlAccent, textPrimary, textSecondary:
  Color; spacingS/M/L: CGFloat; radius: CGFloat; labelFont, valueFont: Font; static func
  resolve(palette: MoodPalette) -> Theme }`, `EnvironmentValues.theme`.

- [ ] **Step 1: Implement** (per spec-04 §6.1, verbatim structure):

```swift
import SwiftUI

struct Theme {
    var panelFill: Color
    var panelStroke: Color
    var controlAccent: Color
    var textPrimary: Color
    var textSecondary: Color
    var spacingS: CGFloat = 6, spacingM: CGFloat = 12, spacingL: CGFloat = 20
    var radius: CGFloat = 10
    var labelFont: Font = .system(size: 11, weight: .medium)
    var valueFont: Font = .system(size: 11, weight: .regular, design: .monospaced)

    static func resolve(palette: MoodPalette) -> Theme {
        Theme(panelFill: Color(nsColor: .windowBackgroundColor).opacity(0.85),
             panelStroke: Color(nsColor: .separatorColor),
             controlAccent: palette.accent,
             textPrimary: .primary,
             textSecondary: .secondary)
    }
}

private struct ThemeKey: EnvironmentKey {
    static let defaultValue = Theme.resolve(palette: .default)
}

extension EnvironmentValues {
    var theme: Theme {
        get { self[ThemeKey.self] }
        set { self[ThemeKey.self] = newValue }
    }
}
```

(Confirm `MoodPalette`'s real accent-color accessor and a sensible `.default` static via
`grep -n "struct MoodPalette\|accent" Muse/Muse/Models/Mood.swift` before finalizing — the
literal above is illustrative.)

- [ ] **Step 2: Inject once in `ContentView`**

```swift
.environment(\.theme, Theme.resolve(palette: appState.moodPalette))
```

- [ ] **Step 3: Build to confirm it compiles**

Run: `xcodebuild -scheme Muse build`
Expected: BUILD SUCCEEDED. (No unit test — this is a pure SwiftUI environment plumbing task;
correctness is visual, verified once editor surfaces consume it in later tasks.)

- [ ] **Step 4: Commit**

```bash
git add "Muse/Muse/Views/Theme/Theme.swift" "Muse/Muse/ContentView.swift"
git commit -m "feat(editing): minimal semantic Theme environment layer (Spec 02 D12 prerequisite)"
```

### Task 5.2: `Views/Editor/EditSession.swift`

**Files:**
- Create: `Muse/Muse/Views/Editor/EditSession.swift`
- Test: `Muse/MuseTests/EditSessionTests.swift` (the pure parts only — history/draft
  transitions; autosave debounce timing is not meaningfully unit-testable without a real
  clock/Task harness, so it's verified manually in Task 5.5)

**Interfaces:**
- Consumes: `EditHistory` (1.3), `EditStore.save`/`.stack` (4.2), `RenderCoalescer` (3.7).
- Produces:
  ```swift
  @MainActor final class EditSession: ObservableObject {
      let url: URL
      @Published var draft: EditStack
      @Published private(set) var history: EditHistory
      @Published var beforePeek = false
      @Published var compareMode: CompareMode
      @Published var wipeAgainst: EditStack?
      @Published var canvasZoom: CGFloat = 1
      @Published var canvasPan: CGSize = .zero
      init(url: URL, stack: EditStack?)
      func commitGesture()
      func undo(); func redo()
      func save() async
      func resetAll()
  }
  enum CompareMode: Equatable { case off, sideBySide, wipe(Double) }
  ```

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import Muse

@MainActor
final class EditSessionTests: XCTestCase {
    func testInitSeedsDraftFromProvidedStack() {
        var stack = EditStack.fresh()
        var tone = ToneParams.neutral; tone.exposureEV = 1
        stack.adjustments = [.tone(tone)]
        let session = EditSession(url: URL(fileURLWithPath: "/tmp/x.jpg"), stack: stack)
        XCTAssertEqual(session.draft, stack)
    }

    func testInitWithNilStackSeedsFresh() {
        let session = EditSession(url: URL(fileURLWithPath: "/tmp/x.jpg"), stack: nil)
        XCTAssertTrue(session.draft.isNeutral)
    }

    func testCommitGestureIsTheOnlyHistoryPushSite() {
        let session = EditSession(url: URL(fileURLWithPath: "/tmp/x.jpg"), stack: nil)
        var t = ToneParams.neutral; t.exposureEV = 1
        session.draft.adjustments = [.tone(t)]
        XCTAssertFalse(session.history.canUndo) // no push yet — draft mutation alone doesn't push
        session.commitGesture()
        XCTAssertTrue(session.history.canUndo)
    }

    func testUndoRedoUpdateDraft() {
        let session = EditSession(url: URL(fileURLWithPath: "/tmp/x.jpg"), stack: nil)
        var t = ToneParams.neutral; t.exposureEV = 1
        session.draft.adjustments = [.tone(t)]
        session.commitGesture()
        session.undo()
        XCTAssertTrue(session.draft.isNeutral)
        session.redo()
        XCTAssertFalse(session.draft.isNeutral)
    }

    func testResetAllReturnsToFresh() {
        let session = EditSession(url: URL(fileURLWithPath: "/tmp/x.jpg"), stack: nil)
        var t = ToneParams.neutral; t.exposureEV = 3
        session.draft.adjustments = [.tone(t)]
        session.commitGesture()
        session.resetAll()
        XCTAssertTrue(session.draft.isNeutral)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -scheme Muse -only-testing:MuseTests/EditSessionTests test`
Expected: FAIL — type doesn't exist.

- [ ] **Step 3: Implement**

```swift
import Foundation

enum CompareMode: Equatable {
    case off, sideBySide, wipe(Double)
}

@MainActor final class EditSession: ObservableObject {
    let url: URL
    @Published var draft: EditStack {
        didSet { scheduleAutosave() }
    }
    @Published private(set) var history: EditHistory
    @Published var beforePeek = false
    @Published var compareMode: CompareMode = .off
    @Published var wipeAgainst: EditStack?
    @Published var canvasZoom: CGFloat = 1
    @Published var canvasPan: CGSize = .zero

    private var autosaveTask: Task<Void, Never>?

    init(url: URL, stack: EditStack?) {
        self.url = url
        let seed = stack ?? EditStack.fresh()
        self.draft = seed
        self.history = EditHistory(initial: seed)
    }

    func commitGesture() {
        history.push(draft)
    }

    func undo() {
        guard let previous = history.undo() else { return }
        draft = previous
    }

    func redo() {
        guard let next = history.redo() else { return }
        draft = next
    }

    func save() async {
        await EditStore.shared.save(draft, for: url)
    }

    func resetAll() {
        draft = EditStack.fresh()
        commitGesture()
        Task { await save() } // reset autosaves immediately, not debounced
    }

    private func scheduleAutosave() {
        autosaveTask?.cancel()
        autosaveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled, let self else { return }
            await self.save()
        }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild -scheme Muse -only-testing:MuseTests/EditSessionTests test`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add "Muse/Muse/Views/Editor/EditSession.swift" "Muse/MuseTests/EditSessionTests.swift"
git commit -m "feat(editing): EditSession — per-file editor state, autosave, history binding"
```

### Task 5.3: Mode toggle + backdrop + `EditorView` layout

**Files:**
- Create: `Muse/Muse/Views/Editor/EditorView.swift`
- Create: `Muse/Muse/Views/Editor/EditorBackdrop.swift`
- Modify: `Muse/Muse/Viewers/HeroImageViewer.swift` (mount the (Preview | Edit) segmented
  control + `editMode` state + `EditSession` creation)
- Modify: `Muse/Muse/Settings/AppSettings.swift` (`editorBackdropKey`)

**Interfaces:**
- Consumes: `EditSession` (5.2), `Theme` (5.1).
- Produces: `EditorView(session: EditSession)`, `EditorBackdrop(level: EditorBackdropLevel)`,
  `enum EditorBackdropLevel: String { case white, light, mid, dark, black }` with `mid` as
  spec's `AppSettings.editorBackdropKey` default `"mid"`.

- [ ] **Step 1: Add the `AppSettings` key** (follow the existing accessor pattern — `grep -n
"static let.*Key" Muse/Muse/Settings/AppSettings.swift` for the convention):

```swift
static let editorBackdropKey = "editorBackdrop" // default "mid"
```

- [ ] **Step 2: Implement `EditorBackdrop`**

```swift
import SwiftUI

enum EditorBackdropLevel: String, CaseIterable {
    case white, light, mid, dark, black
    var brightness: Double {
        switch self { case .white: 1.0; case .light: 0.85; case .mid: 0.48; case .dark: 0.18; case .black: 0.0 }
    }
    var label: String {
        switch self {
        case .white: String(localized: "White")
        case .light: String(localized: "Light Gray")
        case .mid: String(localized: "Mid Gray")
        case .dark: String(localized: "Dark Gray")
        case .black: String(localized: "Black")
        }
    }
}

struct EditorBackdrop: View {
    @Binding var level: EditorBackdropLevel
    var body: some View {
        Color(white: level.brightness)
            .contextMenu {
                ForEach(EditorBackdropLevel.allCases, id: \.self) { l in
                    Button(l.label) { level = l }
                }
            }
    }
}
```

- [ ] **Step 3: Mount the (Preview | Edit) segmented control in `HeroImageViewer`**

Add `@State private var editMode = false` and `@StateObject` (or lazily-created
`@State private var editSession: EditSession?`) beside the existing chrome state; a
top-center 2-segment capsule (`Text("Preview")`/`Text("Edit")`, white-glass fills matching the
chrome family), hidden for non-`.image`/`.raw` kinds and while `isClosing`/burning (reuse
whatever flags already gate other chrome elements — `grep -n "isClosing\|burning"
Muse/Muse/Viewers/HeroImageViewer.swift`). Entering Edit mode: create `EditSession(url:
selectedFile.url, stack: await EditStore.shared.stack(for: url))`, apply the 0.25s ease
scaling the fitted stage rect by 0.94, and swap the stage content to `EditorView(session:)`.
Leave `ViewerInfoColumn` and the parting-ripple/flight machinery completely untouched (Global
Constraint: "the hero close/open choreography is untouched" — Edit mode replaces the STAGE
content only).

- [ ] **Step 4: Implement `EditorView`'s layout skeleton** (center canvas placeholder +
anchored floating card frames for now — Tasks 6/7/8 fill in the actual controls):

```swift
import SwiftUI

struct EditorView: View {
    @ObservedObject var session: EditSession
    @Environment(\.theme) private var theme
    @State private var backdropLevel: EditorBackdropLevel = .mid

    var body: some View {
        ZStack {
            EditorBackdrop(level: $backdropLevel)
            HStack {
                editorCard(title: String(localized: "Info")) // left card — Info/History/Scopes tabs, Task 7
                Spacer()
                EditCanvasView(image: .constant(nil)) // wired to session's coalesced render in Task 5.4
                Spacer()
                editorCard(title: String(localized: "Light")) // right card — Light/Color/Looks tabs, Tasks 5.4/6/8
            }
            .padding(theme.spacingL)
        }
    }

    private func editorCard(title: String) -> some View {
        VStack {
            Text(title).font(theme.labelFont).foregroundStyle(theme.textPrimary)
            Spacer()
        }
        .padding(theme.spacingM)
        .background(theme.panelFill, in: RoundedRectangle(cornerRadius: theme.radius))
        .overlay(RoundedRectangle(cornerRadius: theme.radius).stroke(theme.panelStroke))
        .frame(width: 260)
    }
}
```

(The rubber-band drag-with-snap-back for anchored cards is a `DragGesture` whose offset
animates to `.zero` on end — add it to `editorCard` as a `.offset(dragOffset).gesture(...)`
once the card's real content exists in Task 5.4; a placeholder card doesn't need drag yet.)

- [ ] **Step 5: Manual verification in the running app**

Build, run, double-click a photo, confirm the (Preview | Edit) toggle appears for image/raw
kinds only and is absent for video/PDF/etc; confirm entering Edit mode shows the neutral
backdrop and two placeholder cards without disturbing the open flight or info column.

- [ ] **Step 6: Commit**

```bash
git add "Muse/Muse/Views/Editor/EditorView.swift" "Muse/Muse/Views/Editor/EditorBackdrop.swift" \
  "Muse/Muse/Viewers/HeroImageViewer.swift" "Muse/Muse/Settings/AppSettings.swift"
git commit -m "feat(editing): (Preview | Edit) mode toggle + neutral backdrop + editor shell layout"
```

### Task 5.4: `Views/Editor/EditSlider.swift` + wiring the Light/Color tabs

**Files:**
- Create: `Muse/Muse/Views/Editor/EditSlider.swift`
- Modify: `Muse/Muse/Views/Editor/EditorView.swift` (replace the placeholder right card with
  real Light/Color tabbed content)

**Interfaces:**
- Consumes: `EditSession.draft` (5.2), `Theme` (5.1).
- Produces: `EditSlider(label: String, value: Binding<Double>, range: ClosedRange<Double>,
  neutral: Double, onCommit: () -> Void)`.

- [ ] **Step 1: Implement `EditSlider`**

```swift
import SwiftUI

struct EditSlider: View {
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let neutral: Double
    let onCommit: () -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(label).font(theme.labelFont).foregroundStyle(theme.textPrimary)
                    .onTapGesture(count: 2) { value = neutral; onCommit() }
                Spacer()
                Text(String(format: "%.2f", value)).font(theme.valueFont)
                    .foregroundStyle(theme.textSecondary)
                    .onTapGesture(count: 2) { value = neutral; onCommit() }
            }
            Slider(value: $value, in: range, onEditingChanged: { editing in
                if !editing { onCommit() }
            })
            .tint(theme.controlAccent)
        }
    }
}
```

(Option-drag fine steps is a small `DragGesture` modifier over the `Slider`'s track that
scales delta by 0.1 while `NSEvent.modifierFlags.contains(.option)` — add as a follow-up
refinement once the basic slider is wired and visually confirmed; it's a UX nicety, not a
correctness requirement, so it can land in the same commit without its own TDD cycle since
there's no pure logic to test.)

- [ ] **Step 2: Wire the Light tab** (Exposure, Contrast, Highlights, Shadows, Whites, Blacks,
then Clarity, Texture, Sharpen, Noise Reduction — each an `EditSlider` bound through a small
computed `Binding<Double>` that reads/writes the matching field inside
`session.draft`'s `.tone`/`.presence` case, creating the case if absent on first non-neutral
write):

```swift
private func toneBinding(_ keyPath: WritableKeyPath<ToneParams, Double>, range: ClosedRange<Double>) -> Binding<Double> {
    Binding(
        get: { session.draft.toneParams?[keyPath: keyPath] ?? 0 },
        set: { session.draft.setTone { $0[keyPath: keyPath] = $1 } (newValue: $0) }
    )
}
```

(Add `EditStack.setTone(_:)`/`.setColor(_:)`/`.setPresence(_:)`/`.setVignette(_:)` mutating
helpers to `EditStack.swift` — each finds-or-inserts the matching `Adjustment` case, applies
a mutation closure, and writes it back; this is straightforward plumbing, add it alongside
`toneParams`/`colorParams`/etc. accessors from Task 3.5.)

- [ ] **Step 3: Wire the Color tab** (Temperature, Tint, Vibrance, Saturation) the same way,
plus the RAW-only "Auto Lens Correction" toggle (`rawParams.lensCorrection`) shown only when
the open file's kind is `.raw`.

- [ ] **Step 4: Wire the canvas to the coalesced render**

Replace `EditorView`'s placeholder `EditCanvasView(image: .constant(nil))` with a
`@State private var canvasImage: CIImage?` updated by a `RenderCoalescer<EditStack,
CGImage>` (Task 3.7) instance owned by `EditSession`, triggered by `.onChange(of:
session.draft)`. The proxy source is `min(canvasLongEdge × scale × 2.5, 4096)` (the hero
ladder's exact formula, `HeroStage.swift:446-447`), re-decoded only on zoom past its
resolution — never full-res for preview (M1 Air rule).

- [ ] **Step 5: Manual verification in the running app**

Build, run, enter Edit mode on a real photo, drag a few sliders, confirm the canvas updates
live and the double-click-to-reset gesture works. This is the first fully interactive editor
commit — a real hands-on pass is required (verify-runtime rule), not just a build check.

- [ ] **Step 6: Commit**

```bash
git add "Muse/Muse/Views/Editor/EditSlider.swift" "Muse/Muse/Views/Editor/EditorView.swift" \
  "Muse/Muse/Editing/EditStack.swift"
git commit -m "feat(editing): EditSlider + Light/Color tabs wired to coalesced canvas render"
```

### Task 5.5: Escape, keys, `modalPresented` gating

**Files:**
- Modify: `Muse/Muse/Viewers/HeroImageViewer.swift` (`viewerClosing` onChange, ~lines
  161-183 — add the `editMode` first-branch consume)
- Modify: `Muse/Muse/Views/KeyCaptureView.swift` (`onLeft`/`onRight` early-return while
  `editMode`)
- Modify: `Muse/Muse/Models/AppState.swift` (`modalPresented` gains `openWithForkRequest`,
  `editCopyRequest` — the latter used by Phase 8; add both flags now, wire only what Phase 5
  needs)

**Interfaces:**
- Consumes: `EditSession` (5.2).

- [ ] **Step 1: Add the Edit-mode Escape branch**

`grep -n "viewerClosing" Muse/Muse/Viewers/HeroImageViewer.swift` (cited ~161-183). Add, as
the FIRST branch after the existing immediate `appState.viewerClosing = false`:

```swift
if editMode {
    exitEditMode()
    return
}
```

`exitEditMode()` sets `editMode = false`, tears down `editSession` (autosaving via its
`deinit`-adjacent explicit `await session.save()` before dropping the reference — call it
synchronously enough that a fast re-open doesn't race; use a `Task { await session.save() }`
fire-and-forget consistent with the autosave-on-exit rule in spec-04 §6.3). The rest of the
close sequence (`startClose()`, etc.) is untouched — this branch RETURNS before it runs.

- [ ] **Step 2: Disable arrow-key file flips in Edit mode**

`grep -n "onLeft\|onRight" Muse/Muse/Views/KeyCaptureView.swift` — add an early return (`guard
!editMode else { return }`, threaded in via whatever binding/closure the catcher already
takes) at the top of both handlers, sourced from a binding passed down from
`HeroImageViewer`.

- [ ] **Step 3: Register the two modal flags on `AppState`**

`grep -n "var modalPresented" Muse/Muse/Models/AppState.swift` (cited line 514) — add
`openWithForkRequest: OpenWithForkRequest?` and `editCopyRequest: EditCopyGroupRequest?` (the
latter's real type lands in Phase 8; declare it here as a forward-compatible optional so
`modalPresented`'s computed bool only needs one edit across both phases) to the existing
computed-bool's OR-chain. Leave both types as forward declarations (`struct
OpenWithForkRequest { let fileURL: URL; let appURL: URL }`, empty `struct
EditCopyGroupRequest {}` placeholder refined in Phase 8) since `AppState` itself must not gain
new `@Published` properties beyond what these two additions require — confirm both are
declared on `AppState` as ALREADY-sanctioned per DECISIONS' `modalPresented` gating pattern
(not a NEW `@Published`, just new cases feeding the existing gate) before adding; if
`modalPresented` is a computed property reading several optional `@Published` fields, these
two ARE new `@Published` fields and must be justified against the "AppState frozen" rule —
resolve this by checking whether Spec 01-03 already established a precedent (e.g.
`collectionModal`) for adding request flags to `AppState` despite the freeze; if so, follow
that exact precedent's shape.

- [ ] **Step 4: Manual verification**

Build, run, enter Edit mode, press Escape — confirm it returns to Preview (not close viewer);
press again — confirm normal close. Confirm arrow keys are inert in Edit mode and resume
flipping files in Preview.

- [ ] **Step 5: Commit**

```bash
git add "Muse/Muse/Viewers/HeroImageViewer.swift" "Muse/Muse/Views/KeyCaptureView.swift" \
  "Muse/Muse/Models/AppState.swift"
git commit -m "feat(editing): Edit-mode Escape consumed before close; arrow flips disabled while editing"
```

## Phase 6 — Curve editor + WB eyedropper

### Task 6.1: `Views/Editor/CurveEditorView.swift`

**Files:**
- Create: `Muse/Muse/Views/Editor/CurveEditorView.swift`
- Modify: `Muse/Muse/Views/Editor/EditorView.swift` (mount under Light tab)

**Interfaces:**
- Consumes: `CurveParams` (1.1), `CurveLUT` (3.2), `Theme` (5.1).
- Produces: `CurveEditorView(points: Binding<[CurveParams.Point]>, histogram:
  CurveHistogram?, onCommit: () -> Void)`, `struct CurveHistogram { let bins: [Float] //
  64 luminance bins }` (the seam Spec 04 always passes `nil` for; Spec 05 fills it).

- [ ] **Step 1: Implement** — unit-square canvas; click adds a point (clamped to `≤
CurveParams.maxPoints`), drag moves with x clamped between neighbors (monotone by
construction), double-click removes, per-channel segmented control (RGB/R/G/B), identity
reset. No pure-logic test needed beyond what `CurveLUTTests` (3.2) already covers — the point
manipulation IS the model, and the view is UI (house convention: no UI unit tests). Verify
manually.

```swift
import SwiftUI

struct CurveHistogram {
    let bins: [Float] // 64 luminance bins, drawn as a silent backdrop when non-nil
}

struct CurveEditorView: View {
    @Binding var points: [CurveParams.Point]
    let histogram: CurveHistogram?
    let onCommit: () -> Void
    @Environment(\.theme) private var theme
    @State private var channel: Channel = .rgb
    enum Channel: String, CaseIterable { case rgb = "RGB", r = "R", g = "G", b = "B" }

    var body: some View {
        VStack {
            Picker("", selection: $channel) {
                ForEach(Channel.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.segmented)
            GeometryReader { geo in
                ZStack {
                    if let histogram { histogramBackdrop(histogram, size: geo.size) }
                    curvePath(size: geo.size)
                    ForEach(points.indices, id: \.self) { i in
                        pointHandle(at: points[i], size: geo.size, index: i)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { location in removePoint(near: location, size: geo.size) }
                .gesture(DragGesture(minimumDistance: 0).onChanged { addOrMovePoint($0, size: geo.size) }
                    .onEnded { _ in onCommit() })
            }
            .aspectRatio(1, contentMode: .fit)
        }
    }

    private func curvePath(size: CGSize) -> some View {
        let lut = CurveLUT.build(points: points)
        return Path { path in
            for (i, v) in lut.enumerated() {
                let x = CGFloat(i) / CGFloat(lut.count - 1) * size.width
                let y = (1 - CGFloat(v)) * size.height
                if i == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
            }
        }.stroke(theme.controlAccent, lineWidth: 1.5)
    }

    private func histogramBackdrop(_ histogram: CurveHistogram, size: CGSize) -> some View {
        HStack(alignment: .bottom, spacing: 0) {
            ForEach(histogram.bins.indices, id: \.self) { i in
                Rectangle().fill(theme.textSecondary.opacity(0.15))
                    .frame(width: size.width / CGFloat(histogram.bins.count),
                          height: CGFloat(histogram.bins[i]) * size.height)
            }
        }
    }

    private func pointHandle(at point: CurveParams.Point, size: CGSize, index: Int) -> some View {
        Circle().fill(theme.controlAccent).frame(width: 8, height: 8)
            .position(x: CGFloat(point.x) * size.width, y: (1 - CGFloat(point.y)) * size.height)
    }

    private func addOrMovePoint(_ drag: DragGesture.Value, size: CGSize) {
        let x = min(max(drag.location.x / size.width, 0), 1)
        let y = min(max(1 - drag.location.y / size.height, 0), 1)
        // find nearest existing point within a grab radius, else insert new (capped at maxPoints)
        if let nearest = points.enumerated().min(by: {
            abs($0.element.x - Double(x)) < abs($1.element.x - Double(x))
        }), abs(nearest.element.x - Double(x)) < 0.03 {
            let lowerBound = nearest.offset > 0 ? points[nearest.offset - 1].x : 0
            let upperBound = nearest.offset < points.count - 1 ? points[nearest.offset + 1].x : 1
            points[nearest.offset] = CurveParams.Point(x: min(max(Double(x), lowerBound), upperBound), y: Double(y))
        } else if points.count < CurveParams.maxPoints {
            points.append(CurveParams.Point(x: Double(x), y: Double(y)))
            points.sort { $0.x < $1.x }
        }
    }

    private func removePoint(near location: CGPoint, size: CGSize) {
        let x = location.x / size.width
        if let idx = points.firstIndex(where: { abs($0.x - Double(x)) < 0.03 }) {
            points.remove(at: idx)
            onCommit()
        }
    }
}
```

- [ ] **Step 2: Mount under the Light tab** in `EditorView`, bound to
`session.draft.curveParams?.rgb` (or the selected channel's array) via a computed `Binding`
mirroring the pattern from Task 5.4 Step 2, passing `histogram: nil` per this spec (Spec 05's
seam).

- [ ] **Step 3: Manual verification**

Build, run, open the curve editor, add/move/remove points, confirm the canvas render updates
and monotonicity holds visually (no crossed points).

- [ ] **Step 4: Commit**

```bash
git add "Muse/Muse/Views/Editor/CurveEditorView.swift" "Muse/Muse/Views/Editor/EditorView.swift"
git commit -m "feat(editing): CurveEditorView — point curve with histogram-behind seam (Spec 05 fills it)"
```

### Task 6.2: `Components/CanvasPointMath.swift` + WB eyedropper

**Files:**
- Create: `Muse/Muse/Components/CanvasPointMath.swift`
- Modify: `Muse/Muse/Views/Editor/EditorView.swift` (eyedropper button + crosshair state)
- Test: `Muse/MuseTests/CanvasPointMathTests.swift`

**Interfaces:**
- Produces: `enum CanvasPointMath { static func imagePoint(fromCanvasPoint: CGPoint, fit:
  CGRect, zoom: CGFloat, pan: CGSize) -> CGPoint? }` (nil when out-of-image).

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import Muse

final class CanvasPointMathTests: XCTestCase {
    func testCenterCanvasPointMapsToCenterOfImageAtFitZoom() {
        let fit = CGRect(x: 0, y: 0, width: 100, height: 100)
        let result = CanvasPointMath.imagePoint(fromCanvasPoint: CGPoint(x: 50, y: 50),
                                                fit: fit, zoom: 1, pan: .zero)
        XCTAssertEqual(result?.x ?? -1, 0.5, accuracy: 0.01)
        XCTAssertEqual(result?.y ?? -1, 0.5, accuracy: 0.01)
    }

    func testOutOfImagePointReturnsNil() {
        let fit = CGRect(x: 0, y: 0, width: 100, height: 100)
        let result = CanvasPointMath.imagePoint(fromCanvasPoint: CGPoint(x: 500, y: 500),
                                                fit: fit, zoom: 1, pan: .zero)
        XCTAssertNil(result)
    }

    func testZoomScalesTheMapping() {
        let fit = CGRect(x: 0, y: 0, width: 100, height: 100)
        let result = CanvasPointMath.imagePoint(fromCanvasPoint: CGPoint(x: 50, y: 50),
                                                fit: fit, zoom: 2, pan: .zero)
        XCTAssertEqual(result?.x ?? -1, 0.5, accuracy: 0.01) // canvas center still maps to image center
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -scheme Muse -only-testing:MuseTests/CanvasPointMathTests test`
Expected: FAIL — type doesn't exist.

- [ ] **Step 3: Implement**

```swift
import CoreGraphics

/// Canvas point -> unit image-space point, under fit/zoom/pan. Returns nil out-of-image.
/// The RegionMath class of pure small helper (Spec 03 precedent).
nonisolated enum CanvasPointMath {
    static func imagePoint(fromCanvasPoint point: CGPoint, fit: CGRect, zoom: CGFloat,
                           pan: CGSize) -> CGPoint? {
        let effectiveRect = CGRect(x: fit.minX * zoom + pan.width, y: fit.minY * zoom + pan.height,
                                   width: fit.width * zoom, height: fit.height * zoom)
        guard effectiveRect.width > 0, effectiveRect.height > 0, effectiveRect.contains(point) else { return nil }
        let u = (point.x - effectiveRect.minX) / effectiveRect.width
        let v = (point.y - effectiveRect.minY) / effectiveRect.height
        guard (0...1).contains(u), (0...1).contains(v) else { return nil }
        return CGPoint(x: u, y: v)
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild -scheme Muse -only-testing:MuseTests/CanvasPointMathTests test`
Expected: PASS

- [ ] **Step 5: Wire the WB eyedropper** — a toggle button beside Temperature; active state
shows a crosshair cursor over the canvas; a click samples the session's decoded proxy at the
mapped image point. Encoded sources solve the mired/tint offset closed-form (add a small pure
helper `WBEyedropper.solve(sampledColor: (r: Double, g: Double, b: Double)) -> (temperature:
Double, tint: Double)` beside `MiredMapping` in `RawSource.swift` or a new
`Editing/WBEyedropper.swift` — pure and unit-testable the same way `MiredMappingTests` is;
add 2-3 cases pinning a known neutral-gray sample resolves to near-zero offsets). RAW sources
set `CIRAWFilter.neutralLocation` and re-read the resulting `neutralTemperature`/
`neutralTint` to store as equivalent slider offsets (the stack stays declarative — never a
stored click location).

- [ ] **Step 6: Manual verification**

Build, run, toggle the eyedropper, click a neutral gray area in a real photo, confirm
Temperature/Tint sliders move sensibly.

- [ ] **Step 7: Commit**

```bash
git add "Muse/Muse/Components/CanvasPointMath.swift" "Muse/MuseTests/CanvasPointMathTests.swift" \
  "Muse/Muse/Views/Editor/EditorView.swift" "Muse/Muse/Editing/Render/RawSource.swift"
git commit -m "feat(editing): WB eyedropper — CanvasPointMath + mired/tint solve (encoded + RAW paths)"
```


## Phase 7 — Before/after suite + snapshots + versions

### Task 7.1: Before/after (peek, side-by-side, split-wipe)

**Files:**
- Modify: `Muse/Muse/Views/Editor/EditorView.swift` (compare chrome buttons)
- Modify: `Muse/Muse/Views/Editor/EditCanvasView.swift` (composite rendering for
  side-by-side/wipe)
- Modify: `Muse/Muse/Views/Editor/EditSession.swift` (cache the last original-render CIImage)
- Modify: `Muse/Muse/Views/KeyCaptureView.swift` (extend with `onKey: (NSEvent) -> Bool`
  passthrough for `\`/⌘Y — the same extension Spec 03's cull keys need; add it here if this
  spec lands first, per spec-04 §6.8's note)

**Interfaces:**
- Consumes: `EditSession.beforePeek/.compareMode/.wipeAgainst` (5.2).

- [ ] **Step 1: Cache the original-render texture in `EditSession`**

Add `@Published private(set) var originalRender: CIImage?`, populated once per proxy change
(not per slider tick) by rendering `EditStack.fresh()` through the same coalesced pipeline.

- [ ] **Step 2: Wire hold-to-peek** — press-and-hold `\` (via the `onKey` passthrough) or
mouse-down on a "Before" chrome button sets `session.beforePeek = true`; the canvas swaps to
`session.originalRender` while true; release restores. No pure logic to test (a hold gesture
+ boolean flip); verify manually.

- [ ] **Step 3: Wire ⌘Y side-by-side** — `session.compareMode = .sideBySide` renders two
half-width panes (original | current) with shared zoom/pan (reuse `CanvasPointMath`'s
normalized-center idea locally, or a small local struct if the shapes diverge enough to not
share code cleanly — don't force a shared abstraction if it doesn't fit).

- [ ] **Step 4: Wire split-wipe** — `session.compareMode = .wipe(fraction)`, one canvas
compositing original/current via a mask split at a draggable divider. Implement as a small
CI composite (`CIBlendWithMask` or a manual crop-and-overlay in the `EditCanvasView`
coordinator's `draw(in:)`) using the two cached textures.

- [ ] **Step 5: Add "Save Snapshot…"** — a name prompt via the existing shell
`ModalPromptCard` pattern (the same seam other name prompts use — `grep -rn "ModalPromptCard"
Muse/Muse/Views/` for the exact call convention), on confirm calls
`EditStore.shared.saveVersion(name:, kind: "snapshot", stack: session.draft, for:
session.url)`.

- [ ] **Step 6: Wire the wipe-against picker** — Original + every snapshot from
`EditStore.shared.versions(for: url).filter { $0.kind == "snapshot" }`, setting
`session.wipeAgainst`.

- [ ] **Step 7: Manual verification**

Build, run, exercise hold-peek, ⌘Y, split-wipe drag, save a snapshot, compare against it.
This entire task is UI/gesture behavior with no meaningful pure-logic surface — verify
hands-on per the house convention (no UI unit tests) and the verify-runtime rule.

- [ ] **Step 8: Commit**

```bash
git add "Muse/Muse/Views/Editor/EditorView.swift" "Muse/Muse/Views/Editor/EditCanvasView.swift" \
  "Muse/Muse/Views/Editor/EditSession.swift" "Muse/Muse/Views/KeyCaptureView.swift"
git commit -m "feat(editing): before/after suite — hold-peek, side-by-side, split-wipe, snapshots"
```

### Task 7.2: Versions UI

**Files:**
- Modify: `Muse/Muse/Views/Editor/EditorView.swift` (version menu, top-right of canvas)

**Interfaces:**
- Consumes: `EditStore.shared.versions`/`.switchToVersion`/`.saveVersion` (4.2).

- [ ] **Step 1: Implement the version menu** — current marker, saved versions by name,
"Save as Version…" (name prompt, `kind: "version"`), "Delete Version" on hover rows
(`EditStore` needs a small `deleteVersion(id:)` pass-through to `EditRecordStore.deleteVersion`
— add it to `EditStore.swift` in this task).

- [ ] **Step 2: Wire switching** — selecting a version calls
`EditStore.shared.switchToVersion(id, for: url)`; the session must reseed (`draft =
await EditStore.shared.stack(for: url) ?? .fresh()`, fresh `EditHistory`) and the canvas
re-renders. The grid badge count (Task 4.4) updates via the existing `warmIndex` refresh.

- [ ] **Step 3: Manual verification**

Build, run, save two versions on a test photo, switch between them, confirm the grid badge
count and the canvas both reflect the switch, and that switching auto-preserves the
previously-current stack as a version (per `EditStore.switchToVersion`'s Task 4.2
implementation).

- [ ] **Step 4: Commit**

```bash
git add "Muse/Muse/Views/Editor/EditorView.swift" "Muse/Muse/Models/EditStore.swift"
git commit -m "feat(editing): versions UI — switcher menu, save-as-version, delete"
```

## Phase 8 — v21 schema, presets, copy/paste/sync

### Task 8.1: `v21_edit_presets` migration + `EditPresetStore`

**Files:**
- Modify: `Muse/Muse/Database/Database.swift` (append after v20)
- Modify: `Muse/Muse/Database/Records.swift` (add `EditPresetRow`)
- Create: `Muse/Muse/Models/EditPresetStore.swift`
- Test: extend `Muse/MuseTests/EditMigrationTests.swift`, create
  `Muse/MuseTests/EditPresetStoreTests.swift`

**Interfaces:**
- Produces: `struct EditPresetRow` (schema per DECISIONS §"Spec 04 schema (v20–v21)"),
  `@MainActor final class EditPresetStore: ObservableObject { @Published var presets:
  [EditPresetRow]; func create(name:, stack:) async; func update(id:, from stack: EditStack)
  async; func rename(id:, to:) async; func delete(id:) async; func load() async }`.

- [ ] **Step 1: Write the failing migration test** (add to `EditMigrationTests.swift`)

```swift
func testV21CreatesEditPresetsTable() throws {
    let queue = try makeMigratedQueue()
    try queue.read { db in XCTAssertTrue(try db.tableExists("edit_presets")) }
}

func testEditPresetsAllowsDuplicateNames() throws {
    let queue = try makeMigratedQueue()
    try queue.write { db in
        try db.execute(sql: "INSERT INTO edit_presets (id, name, stack, created_at, updated_at) VALUES ('p1', 'Warm', '{}', 0, 0)")
        try db.execute(sql: "INSERT INTO edit_presets (id, name, stack, created_at, updated_at) VALUES ('p2', 'Warm', '{}', 0, 0)")
    }
    try queue.read { db in
        let count = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM edit_presets") ?? 0
        XCTAssertEqual(count, 2) // no UNIQUE on name — duplicates are the user's business
    }
}
```

- [ ] **Step 2: Run test to verify it fails, then add the migration**

```swift
migrator.registerMigration("v21_edit_presets") { db in
    try db.create(table: "edit_presets") { t in
        t.column("id", .text).primaryKey()
        t.column("name", .text).notNull()
        t.column("stack", .text).notNull()
        t.column("created_at", .integer).notNull()
        t.column("updated_at", .integer).notNull()
    }
}
```

Add `EditPresetRow` to `Records.swift` matching the columns. Run again, expect PASS.

- [ ] **Step 3: Write the failing `EditPresetStoreTests`**

```swift
import XCTest
@testable import Muse

@MainActor
final class EditPresetStoreTests: XCTestCase {
    func testCreateThenLoadReturnsPreset() async throws {
        let store = EditPresetStore()
        var stack = EditStack.fresh()
        var tone = ToneParams.neutral; tone.exposureEV = 1
        stack.adjustments = [.tone(tone)]
        await store.create(name: "Test Look", stack: stack)
        await store.load()
        XCTAssertTrue(store.presets.contains { $0.name == "Test Look" })
    }

    func testCreateExcludesGeometryGroup() async throws {
        let store = EditPresetStore()
        var stack = EditStack.fresh()
        var geo = GeometryParams(); geo.straightenDegrees = 5
        stack.adjustments = [.geometry(geo)]
        await store.create(name: "Cropped Look", stack: stack)
        await store.load()
        let saved = store.presets.first { $0.name == "Cropped Look" }
        let decoded = saved.flatMap { EditStackCodec.decode($0.stack) }
        XCTAssertFalse(EditTransfer.adjustedGroups(of: decoded ?? .fresh()).contains(.geometry))
    }

    func testDeleteRemovesPreset() async throws {
        let store = EditPresetStore()
        await store.create(name: "Temp", stack: .fresh())
        await store.load()
        let id = try XCTUnwrap(store.presets.first { $0.name == "Temp" }?.id)
        await store.delete(id: id)
        await store.load()
        XCTAssertFalse(store.presets.contains { $0.id == id })
    }
}
```

- [ ] **Step 4: Implement `EditPresetStore`**

```swift
import Foundation

@MainActor final class EditPresetStore: ObservableObject {
    @Published var presets: [EditPresetRow] = []

    func load() async {
        presets = (try? await Database.shared.read { db in
            try EditPresetRow.fetchAll(db, sql: "SELECT * FROM edit_presets ORDER BY name COLLATE NOCASE")
        }) ?? []
    }

    func create(name: String, stack: EditStack) async {
        var forPreset = stack
        forPreset.adjustments.removeAll { if case .geometry = $0 { true } else { false } }
        let json = (try? EditStackCodec.encode(forPreset.normalized())) ?? "{}"
        let now = Int64(Date().timeIntervalSince1970)
        let row = EditPresetRow(id: UUID().uuidString, name: name, stack: json,
                                created_at: now, updated_at: now)
        try? await Database.shared.write { db in var r = row; try r.insert(db) }
    }

    func update(id: String, from stack: EditStack) async {
        var forPreset = stack
        forPreset.adjustments.removeAll { if case .geometry = $0 { true } else { false } }
        let json = (try? EditStackCodec.encode(forPreset.normalized())) ?? "{}"
        let now = Int64(Date().timeIntervalSince1970)
        try? await Database.shared.write { db in
            try db.execute(sql: "UPDATE edit_presets SET stack = ?, updated_at = ? WHERE id = ?",
                           arguments: [json, now, id])
        }
    }

    func rename(id: String, to name: String) async {
        try? await Database.shared.write { db in
            try db.execute(sql: "UPDATE edit_presets SET name = ? WHERE id = ?", arguments: [name, id])
        }
    }

    func delete(id: String) async {
        try? await Database.shared.write { db in
            try db.execute(sql: "DELETE FROM edit_presets WHERE id = ?", arguments: [id])
        }
    }
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `xcodebuild -scheme Muse -only-testing:MuseTests/EditMigrationTests
-only-testing:MuseTests/EditPresetStoreTests test`
Expected: PASS

- [ ] **Step 6: Wire the Looks tab** in `EditorView` to list `presets` with Apply/Save/Update/
Delete (Apply = `EditTransfer.apply(groups: EditTransfer.adjustedGroups(of: presetStack),
from: presetStack, onto: session.draft)`, then `session.commitGesture()`).

- [ ] **Step 7: Commit**

```bash
git add "Muse/Muse/Database/Database.swift" "Muse/Muse/Database/Records.swift" \
  "Muse/Muse/Models/EditPresetStore.swift" "Muse/Muse/Views/Editor/EditorView.swift" \
  "Muse/MuseTests/EditMigrationTests.swift" "Muse/MuseTests/EditPresetStoreTests.swift"
git commit -m "feat(editing): v21_edit_presets + EditPresetStore + Looks tab (copy-by-value apply)"
```

### Task 8.2: `EditClipboard` + copy/paste surfaces + batch sync

**Files:**
- Create: `Muse/Muse/Models/EditClipboard.swift`
- Modify: `Muse/Muse/Views/Editor/EditorView.swift` (Copy/Paste Adjustments chrome + group
  picker card)
- Modify: `Muse/Muse/MuseApp.swift` (Edit-menu commands, `CommandGroup(after: .pasteboard)`,
  cited line 171)
- Modify: `Muse/Muse/Views/SelectionMenu.swift` ("Paste Adjustments" batch sync)

**Interfaces:**
- Consumes: `EditTransfer` (1.4), `EditStore.save` (4.2).
- Produces: `@MainActor final class EditClipboard: ObservableObject { static let shared:
  EditClipboard; var stack: EditStack?; var groups: Set<AdjustmentGroup> }`.

- [ ] **Step 1: Implement `EditClipboard`** — in-memory only, no test needed (a plain
singleton holding two properties has no logic to verify beyond what `EditTransferTests`
already covers):

```swift
@MainActor final class EditClipboard: ObservableObject {
    static let shared = EditClipboard()
    var stack: EditStack?
    var groups: Set<AdjustmentGroup> = []
    private init() {}
}
```

- [ ] **Step 2: Wire editor chrome Copy/Paste (⌥⌘C / ⌥⌘V)**

Copy opens a small shell card (a new `AppState.editCopyRequest` flag, per Task 5.5 Step 3's
forward-declared placeholder — refine its type now to `struct EditCopyGroupRequest { let
sourceStack: EditStack }`) listing the seven `AdjustmentGroup` cases as toggles, pre-checked
to `EditTransfer.adjustedGroups(of: session.draft)`; confirming sets
`EditClipboard.shared.stack = session.draft; .groups = selectedGroups`. Paste applies
`EditTransfer.apply(groups: EditClipboard.shared.groups, from: EditClipboard.shared.stack!,
onto: session.draft)` then `session.commitGesture()` (one history push, per spec-04 §7.3).

- [ ] **Step 3: Wire Edit-menu commands** — same two actions, enabled when an editor session
is open (copy) / clipboard non-empty (paste), beside the existing selection commands at
`MuseApp.swift:171`.

- [ ] **Step 4: Wire grid context-menu "Paste Adjustments" batch sync**

In `SelectionMenu.swift`, beside the Rating menu: visible when
`EditClipboard.shared.stack != nil` AND the effective selection contains image-kind editable
files (`.image`/`.raw`, reuse the existing `fileURLs` guard pattern). On invoke, for each
target URL sequentially off-main: read its current stack via `EditStore.shared.stack(for:)`,
apply `EditTransfer.apply`, save via `EditStore.shared.save` (the full save sequence runs per
file, so tiles refresh as the sweep progresses — no separate progress UI, per the status-pill
durable rule).

- [ ] **Step 5: Manual verification**

Build, run, copy adjustments from one photo, paste onto another single photo AND onto a
multi-selection via the grid context menu; confirm tiles update live during the batch sweep
and the source stack is untouched (copy-by-value).

- [ ] **Step 6: Commit**

```bash
git add "Muse/Muse/Models/EditClipboard.swift" "Muse/Muse/Views/Editor/EditorView.swift" \
  "Muse/Muse/MuseApp.swift" "Muse/Muse/Views/SelectionMenu.swift" "Muse/Muse/Models/AppState.swift"
git commit -m "feat(editing): EditClipboard + copy/paste chrome + batch 'Paste Adjustments' sync"
```

## Phase 9 — Edit-a-Copy

### Task 9.1: `Editing/EditCopyNaming.swift`

**Files:**
- Create: `Muse/Muse/Editing/EditCopyNaming.swift`
- Test: `Muse/MuseTests/EditCopyNamingTests.swift`

**Interfaces:**
- Produces: `enum EditCopyNaming { static func candidate(stem: String, ext: String, existing:
  Set<String>) -> String }`.

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import Muse

final class EditCopyNamingTests: XCTestCase {
    func testFirstCandidateIsStemDashEdit() {
        let result = EditCopyNaming.candidate(stem: "photo", ext: "jpg", existing: [])
        XCTAssertEqual(result, "photo-Edit.jpg")
    }

    func testCollisionLadderIncrements() {
        let existing: Set<String> = ["photo-Edit.jpg"]
        let result = EditCopyNaming.candidate(stem: "photo", ext: "jpg", existing: existing)
        XCTAssertEqual(result, "photo-Edit-2.jpg")
    }

    func testCollisionLadderIsCaseInsensitive() {
        let existing: Set<String> = ["PHOTO-EDIT.JPG"]
        let result = EditCopyNaming.candidate(stem: "photo", ext: "jpg", existing: existing)
        XCTAssertEqual(result, "photo-Edit-2.jpg")
    }

    func testRawExtensionMapsToTif() {
        // Extension mapping is the CALLER's job per spec (jpeg->jpg/png->png/tif->tif/
        // heic->heic pass through; RAW/DNG -> "tif") — candidate() itself just formats
        // whatever ext string it's given; this test documents the caller contract.
        let result = EditCopyNaming.candidate(stem: "IMG_0001", ext: "tif", existing: [])
        XCTAssertEqual(result, "IMG_0001-Edit.tif")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -scheme Muse -only-testing:MuseTests/EditCopyNamingTests test`
Expected: FAIL — type doesn't exist.

- [ ] **Step 3: Implement**

```swift
nonisolated enum EditCopyNaming {
    static func candidate(stem: String, ext: String, existing: Set<String>) -> String {
        let existingLower = Set(existing.map { $0.lowercased() })
        var name = "\(stem)-Edit.\(ext)"
        if !existingLower.contains(name.lowercased()) { return name }
        var n = 2
        repeat {
            name = "\(stem)-Edit-\(n).\(ext)"
            n += 1
        } while existingLower.contains(name.lowercased())
        return name
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild -scheme Muse -only-testing:MuseTests/EditCopyNamingTests test`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add "Muse/Muse/Editing/EditCopyNaming.swift" "Muse/MuseTests/EditCopyNamingTests.swift"
git commit -m "feat(editing): EditCopyNaming — collision ladder for Edit-a-Copy filenames"
```

### Task 9.2: `OpenWithItems` fork routing + fork card

**Files:**
- Modify: `Muse/Muse/Views/OpenWithMenu.swift` (`OpenWithItems.open(with:)`, cited
  lines 85-88; add `@EnvironmentObject var appState`)
- Modify: `Muse/Muse/Models/AppState.swift` (refine `OpenWithForkRequest` — already
  forward-declared in Task 5.5 Step 3 — to `{ fileURL: URL; appURL: URL }`)
- Create: `Muse/Muse/Views/Editor/OpenWithForkCard.swift`

**Interfaces:**
- Consumes: `EditStackIndex.stackHash` (0.1/4.1).

- [ ] **Step 1: Convert `OpenWithItems.open(with:)`**

```swift
private func open(with appURL: URL) {
    if EditStackIndex.stackHash(for: url) != nil {
        appState.openWithForkRequest = OpenWithForkRequest(fileURL: url, appURL: appURL)
    } else {
        NSWorkspace.shared.open([url], withApplicationAt: appURL,
                                configuration: NSWorkspace.OpenConfiguration()) { _, _ in }
    }
}
```

Apply the SAME guard to the bare "Open" rows (double-click default app, the explicit "Open"
item) — `grep -n "NSWorkspace.shared.open" Muse/Muse/Views/OpenWithMenu.swift` to find every
call site and wrap each.

- [ ] **Step 2: Implement `OpenWithForkCard`** — presented at the shell via `.museModal`
(shell-presented, `ModalButton` footer, no `.alert` — durable constraint), title `"This photo
has Muse edits"`, buttons **Edit a Copy with Muse Adjustments** (`.prominent`) / **Edit
Original** (`.normal`) / Cancel. "Edit Original" = the plain `NSWorkspace` open (external
edits then flow through the normal edit-in-place reconcile; the Muse stack survives per the
Task 2.5 carry-seam rule).

- [ ] **Step 3: Wire the card into `ContentView`'s modal stack**, gated on
`appState.openWithForkRequest != nil`, same pattern as other `.museModal`-presented request
flags.

- [ ] **Step 4: Manual verification**

Build, run, save a test edit on a photo, right-click → Open With → an external app; confirm
the fork card appears; confirm "Edit Original" opens the unedited original directly.

- [ ] **Step 5: Commit**

```bash
git add "Muse/Muse/Views/OpenWithMenu.swift" "Muse/Muse/Models/AppState.swift" \
  "Muse/Muse/Views/Editor/OpenWithForkCard.swift" "Muse/Muse/ContentView.swift"
git commit -m "feat(editing): OpenWithItems forks to Edit Original / Edit a Copy when edits exist"
```

### Task 9.3: The Edit-a-Copy flow

**Files:**
- Create: `Muse/Muse/Editing/EditCopyFlow.swift`
- Modify: `Muse/Muse/Views/Editor/OpenWithForkCard.swift` (wire "Edit a Copy" button)

**Interfaces:**
- Consumes: `EditRenderer.exportFile` (3.5), `EditCopyNaming.candidate` (9.1),
  `Indexer.indexFile` (existing, `Indexing/Indexer.swift:68`), `StackStore.createStack`
  (Spec 02 — soft dependency; skip and record if not yet built, per spec-04 §0/§8.4).

- [ ] **Step 1: Check whether `StackStore` exists yet**

Run: `grep -rn "struct StackStore\|class StackStore" Muse/Muse/`. If absent (Spec 02 not yet
built), the flow's step 4 is a documented no-op (matches spec-04 §8.4's explicit "until then:
skip, recorded" — leave a `// TODO(Spec 02): StackStore.createStack once v17 lands` comment,
do not stub a fake stacking mechanism).

- [ ] **Step 2: Implement the ordered, fail-closed flow**

```swift
import Foundation

nonisolated enum EditCopyFlow {
    enum FlowError: Error { case renderFailed, moveFailed }

    /// Ordered, fail-closed: render -> move -> index -> stack (when available) -> caller
    /// reloads + opens. A failure at render/move surfaces via the caller's MuseAlert seam
    /// and writes nothing; failure after the move is on-disk-but-not-yet-reconciled,
    /// never data loss (the next reconcile finds the file).
    static func run(originalURL: URL, appURL: URL) async throws -> URL {
        guard let hash = EditStackIndex.stackHash(for: originalURL),
              let stack = EditStackIndex.resolvedStack(for: originalURL)
        else { throw FlowError.renderFailed }

        let folder = originalURL.deletingLastPathComponent()
        let stem = originalURL.deletingPathExtension().lastPathComponent
        let sourceExt = originalURL.pathExtension.lowercased()
        let isRAW = ["raw", "dng", "cr2", "cr3", "nef", "arw", "raf"].contains(sourceExt)
        let targetExt = isRAW ? "tif" : sourceExt
        let existingNames = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        let filename = EditCopyNaming.candidate(stem: stem, ext: targetExt, existing: Set(existingNames))
        let destURL = folder.appendingPathComponent(filename)

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("muse-editcopy-\(UUID().uuidString).\(targetExt)")
        do {
            try EditRenderer.exportFile(url: originalURL, stack: stack, to: tempURL,
                                        format: isRAW ? .tiff16 : .matchingSource(originalURL))
        } catch { throw FlowError.renderFailed }

        // Copy original EXIF/IPTC minus orientation onto the export (CGImageDestination
        // property forwarding) — a local edit-copy is not a share export, no strip.
        try? EditCopyMetadata.copyMetadata(from: originalURL, to: tempURL, dropOrientation: true)

        do {
            try FileManager.default.moveItem(at: tempURL, to: destURL)
        } catch { throw FlowError.moveFailed }

        let copyFileID = try? await Indexer.shared.indexFile(at: destURL, kind: isRAW ? .image : nil)
        _ = hash // (retained for a future stacking call; not otherwise consumed post-render)

        // Step 4: stack with parent when StackStore exists (Spec 02) — else skip, recorded.
        // if let parentID = ..., let copyID = copyFileID {
        //     try? await StackStore.createStack(kind: "manual", memberIDs: [parentID, copyID], pick: parentID)
        // }

        return destURL
    }
}
```

(`.tiff16`/`.matchingSource(_:)` `OutputFormat` cases and `EditCopyMetadata.copyMetadata`
are small additions to `Editing/Render/EditRenderer.swift`'s `OutputFormat` enum and a new
`Editing/EditCopyMetadata.swift` respectively — implement `copyMetadata` via
`CGImageDestinationAddImageFromSource` property forwarding minus the orientation key, per
spec-04 §8.4 Step 1.)

- [ ] **Step 3: Wire the fork card's "Edit a Copy" button**

```swift
Task {
    do {
        let copyURL = try await EditCopyFlow.run(originalURL: request.fileURL, appURL: request.appURL)
        await AppState.shared.reloadCurrentFiles() // the standard path — the copy appears in place
        NSWorkspace.shared.open([copyURL], withApplicationAt: request.appURL,
                                configuration: NSWorkspace.OpenConfiguration()) { _, _ in }
    } catch {
        AppState.shared.alertRequest = MuseAlert(title: String(localized: "Couldn't create the copy"),
                                                 message: String(localized: "\(error)"))
    }
}
```

- [ ] **Step 4: Manual verification (owner acceptance step, Task 14.4 territory but a basic
pass belongs here)**

Build, run, save an edit on a real photo, Open With → an external app (Preview is sufficient
for a smoke test even though full round-trip acceptance through Affinity/Pixelmator is an
owner-only step per spec-04 §14.4) → "Edit a Copy" → confirm the copy appears in the folder
named per the collision ladder, opens in the external app, and shows up in the Muse grid.

- [ ] **Step 5: Commit**

```bash
git add "Muse/Muse/Editing/EditCopyFlow.swift" "Muse/Muse/Editing/EditCopyMetadata.swift" \
  "Muse/Muse/Editing/Render/EditRenderer.swift" "Muse/Muse/Views/Editor/OpenWithForkCard.swift"
git commit -m "feat(editing): Edit-a-Copy flow — render, name, move, index, open (fail-closed)"
```

## Phase 10 — Docs + localization export pass

### Task 10.1: Update `CLAUDE.md`, `architecture-map.md`, `session-log.md`

**Files:**
- Modify: `CLAUDE.md` (add the 9 new durable constraints from spec-04 §11 verbatim; add a
  Polish/Phase row for "Editing engine"; rewrite the stale "No editing UI — every 'edit this'
  path goes through Open With…" convention line per Spec 01 §1.1's doctrine table)
- Modify: `docs/architecture-map.md` (add `Editing/`, `Editing/Render/`, `Views/Editor/`,
  `Views/Theme/` to the file index)
- Modify: `docs/session-log.md` (a dated entry summarizing the editing-engine build, branch
  name, and key decisions — the narrative home for anything trimmed from `CLAUDE.md`)
- Modify: `docs/new-build/DECISIONS.md` (confirm the existing Spec 04 section already covers
  everything shipped; add any deviations discovered during implementation that weren't
  anticipated in the spec, following the existing "Deliberate deviations" pattern)

- [ ] **Step 1: Copy the 9 durable constraints from spec-04 §11 into `CLAUDE.md`**'s "Durable
constraints & gotchas" section, in the same terse one-two-line style as the surrounding
entries (not the spec's fuller prose — compress, per CLAUDE.md's own "Keep docs lean" rule).

- [ ] **Step 2: Add the Implementation Status table row**

`| Editing engine — non-destructive adjustments, editor UI, before/after, presets, Edit-a-Copy | ✅ shipped | <branch name> |`

- [ ] **Step 3: Rewrite the "No editing UI" convention line** in `CLAUDE.md`'s "Working with
this codebase" or wherever it currently lives (`grep -n "No editing UI" CLAUDE.md`) to
reflect Path A (in-app editing for `.image`/`.raw`) + Path B (Edit-a-Copy for everything
else, incl. `.psd`).

- [ ] **Step 4: Update `architecture-map.md`** with the new module folders per DECISIONS'
"Architecture & module structure": `Editing/` + `Editing/Render/`, `Views/Editor/`,
`Views/Theme/`.

- [ ] **Step 5: Add the session-log entry** — date, branch, one paragraph per major phase
(model, schema, renderer, consumer sweep, editor UI, before/after, presets, Edit-a-Copy),
matching the existing entries' voice.

- [ ] **Step 6: Commit**

```bash
git add CLAUDE.md docs/architecture-map.md docs/session-log.md docs/new-build/DECISIONS.md
git commit -m "docs: spec-04 editing engine — durable constraints, phase table, architecture map"
```

### Task 10.2: Localization export pass

**Files:**
- Modify: `Muse/Muse/Localizable.xcstrings`

- [ ] **Step 1: Grep for un-wrapped literals in new editor files**

Run: `grep -rn '"[A-Z][a-z].*"' Muse/Muse/Views/Editor/ Muse/Muse/Views/Theme/
Muse/Muse/Editing/ | grep -v 'String(localized:'` and manually confirm every match is either
a SwiftUI text-literal position (auto-extracted) or already wrapped — fix any bare `String`
params (AppKit setters, custom-view `title:`/`label:` params, enum `displayName`-style
properties) per the CLAUDE.md localization rule.

- [ ] **Step 2: Run the export**

```bash
xcodebuild -exportLocalizations -project Muse/Muse.xcodeproj -localizationPath /tmp/muse-l10n -exportLanguage fr
```

- [ ] **Step 3: Fill in the empty `fr` values** for every new key introduced by this plan
(editor chrome labels, backdrop level names, fork card copy, version/snapshot prompts, preset
CRUD labels, "Edited"/"Edited, %lld versions" VoiceOver labels).

- [ ] **Step 4: Re-run the export to confirm 0 untranslated**

Run: `xcodebuild -exportLocalizations -project Muse/Muse.xcodeproj -localizationPath /tmp/muse-l10n-verify -exportLanguage fr`
and grep the output `.xliff` for any remaining empty `<target>` elements among the new keys.
Expected: 0.

- [ ] **Step 5: Commit**

```bash
git add Muse/Muse/Localizable.xcstrings
git commit -m "docs(i18n): French translations for the editing engine's new strings"
```

---

## Self-review notes (writing-plans skill, applied at plan-authoring time)

- **Spec coverage**: every numbered section of spec-04-implementation.md (§0–§16) maps to at
  least one task above — model (§1 → 1.1–1.4), schema (§2 → 2.1, 8.1), store/provider/carry
  (§3 → 0.1, 2.2, 2.5, 4.1, 4.2), renderer (§4 → 3.1–3.8), consumer sweep (§5 → 4.3, 4.4),
  editor UI (§6 → 5.1–5.5, 6.1–6.2, 7.1–7.2), copy/paste/presets (§7 → 8.1–8.2), Edit-a-Copy
  (§8 → 9.1–9.3), what's excluded (§9 → respected throughout, no tasks touch those areas),
  perf (§10 → noted inline at Tasks 3.6/4.3/5.4 as manual-verification points, not a
  separate task since `PerfBaseline` rows are additive data, not new code structure — a
  follow-up task can be added if the owner wants the recorded-rows infrastructure built out
  explicitly), durable constraints (§11 → Global Constraints + Task 10.1), tests (§12 → one
  test file per row, threaded through every phase), build order (§13 → this plan's phase
  structure, verbatim), owner-only steps (§14 → called out at Tasks 3.4/3.8/4.3/9.3 as
  manual-verification steps, never silently assumed done by a green test), deviations (§15 →
  preserved as Global Constraints and inline task comments), acceptance mapping (§16 → each
  row traceable to the task that satisfies it).
- **Placeholder scan**: two spots intentionally defer a literal value pending a live run
  (Task 1.2 Step 4's pinned hash, Task 3.8's tolerance/fixture iteration) — both are standard
  TDD "run once, pin the golden" patterns, not vague placeholders; each has a concrete
  mechanical instruction for filling them in. Task 2.4 Step 2's test is the one genuinely
  soft spot (explicitly says so) — flagged rather than hidden, with a concrete instruction
  to find and extend the existing tag-edit sidecar test harness before Step 5.
  Task 4.2's `resolveScope`/`resolvePathsForRows` are the other acknowledged soft spot —
  flagged with the exact `grep` needed to resolve them against `TagStore`'s real code, since
  guessing GRDB join SQL without reading the sibling implementation first risks a subtly
  wrong query.
- **Type consistency**: `AdjustmentGroup`, `EditStack`, `EditStackCodec`, `EditHistory`,
  `EditTransfer`, `EditRecordStore`, `EditStore`, `EditStackIndex`/`LiveEditStackProvider`,
  `EditRenderer`, `EditSession`, `EditClipboard`, `EditPresetStore`, `EditCopyNaming`,
  `EditCopyFlow` — names and signatures are consistent from first introduction (Phase 1)
  through every later consumer (Phases 4–9); cross-checked against spec-04's own interface
  tables, which this plan follows rather than diverges from except where explicitly flagged
  (e.g. the `RenderCoalescer` generic signature, left more general than the spec's sketch
  because the spec didn't fully specify it).
