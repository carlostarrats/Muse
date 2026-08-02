# Image Export Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give Muse a general image export — format, quality, bit depth, resize and metadata — reachable from the grid, the hero viewer, the editor and a collection, so a RAW (or anything else) can leave the app as a normal file.

**Architecture:** One card. `SocialExportCard` is renamed `ExportCard` and its preset dropdown gains a Format section above the existing 12 social presets and a My Presets section below. The render pipeline `SocialRender` already owns is factored into a shared `ExportPipeline`, and a sibling `ImageExportRender` uses it for the format path. Everything still enters through `OutputRender.forOutput`, so edits ride out and the audited choke point holds.

**Tech Stack:** Swift 6, SwiftUI, CoreImage, ImageIO, GRDB (untouched — no migrations), `libwebp` via SPM in the final task.

**Spec:** `docs/superpowers/specs/2026-08-02-image-export-design.md`

## Global Constraints

- **Deployment floor macOS 14.6; universal binary — Intel must keep working.** A Debug build compiles only the active arch; verify arch-sensitive work with `-configuration Release`.
- **No network.** Nothing in this feature opens a socket. `libwebp` is a codec with no network surface; that is why it clears the dependency rule.
- **Everything leaving the app goes through `OutputRender.forOutput`.** `RenderedOutput`'s `fileprivate` init stays fileprivate — audit check `OUT-1`. Add overloads, never a bypass.
- **Every automatic full-raster decode calls `ThumbnailCache.withinDecodeBudget` first** — audit check `DEC-1`.
- **Never overwrite a user's file.** Collisions take the `-2`, `-3` ladder. There is no overwrite option and no filename template.
- **Never `unlink` a user file** — audit check `DEL-1`.
- **Every new user-facing string is localized** at declaration, with French filled in. Anything passed as a `String` (AppKit setters, `title:` params, computed display names, ternaries) is **not** auto-extracted and must be hand-wrapped in `String(localized:)`.
- **`Export/` stays platform-neutral**: Foundation / CoreGraphics / CoreImage / ImageIO / UniformTypeIdentifiers. Never AppKit. (`Views/Export/` is the UI layer and may use AppKit.)
- **Test tiers:** iterate with `-only-testing:MuseTests/<TheAffectedTests>`; take the whole unit target at a checkpoint. Never plain `xcodebuild -scheme Muse test` (it drags in the slow UI target).
- **Run `./scripts/audit-invariants.sh` before any commit.**
- **`BUILD SUCCEEDED` is not proof the app changed** — `stat` the binary's mtime before showing the owner a build.

---

## File Structure

**Create:**

| Path | Responsibility |
|---|---|
| `Muse/Muse/Export/ExportPipeline.swift` | The steps `SocialRender` and `ImageExportRender` share: export `CIContext`, budget-gated oriented decode, exact Lanczos scale, collision-safe naming, `RenderError`. |
| `Muse/Muse/Export/Image/ExportFormat.swift` | `ExportFormat`, `ExportResize`, `ExportSettings`. Pure data + the runtime writability check. |
| `Muse/Muse/Export/Image/ImageExportRender.swift` | The format render: choke point → budget → decode → resize → encode → verify → write. |
| `Muse/Muse/Export/Image/WebPEncoder.swift` | `libwebp` wrapper (Task 8 only). |
| `Muse/Muse/Models/ExportPresetStore.swift` | Saved user presets, `AppSettings` JSON, Pattern B store. |
| `Muse/MuseTests/ExportFormatTests.swift` | Format availability, extensions, resolution. |
| `Muse/MuseTests/ExportResizeTests.swift` | Resize maths, never-upscale. |
| `Muse/MuseTests/ImageExportRenderTests.swift` | Output dimensions, alpha, metadata, depth, collisions. |
| `Muse/MuseTests/ExportPresetStoreTests.swift` | Round-trip, rename, delete, corrupt-blob degradation. |

**Modify:**

| Path | Change |
|---|---|
| `Muse/Muse/Export/Social/SocialRender.swift` | Delegate the five shared steps to `ExportPipeline`; behaviour unchanged. |
| `Muse/Muse/Export/Social/SocialMetadata.swift` | Rename to `ExportMetadata` (no longer social-only). |
| `Muse/Muse/Export/OutputRender.swift` | Add `forOutput(_:preferring:)`. |
| `Muse/Muse/Editing/Render/EditRenderer.swift` | Real 16-bit branch for `.tiff16`. |
| `Muse/Muse/Views/Export/SocialExportCard.swift` | → `ExportCard.swift`: dropdown sections, format controls, advisories. |
| `Muse/Muse/Views/SelectionMenu.swift:105` | "Export for Social…" → "Export…" |
| `Muse/Muse/Views/Viewer/ShareButton.swift:35` | same |
| `Muse/Muse/Views/ShareCollectionButton.swift:83` | same |
| `Muse/Muse/Settings/AppSettings.swift` | `exportPresets` + `lastExportSettings` keys. |
| `Muse/Muse/Localizable.xcstrings` | New strings, French filled. |
| `docs/new-build/FEATURE-LEDGER.md` | New row. |
| `CLAUDE.md` | One-line polish row. |

---

## Task 1: Extract the shared render pipeline

Nothing user-visible. This is the refactor that lets two renderers exist without duplicating 80 lines. Its contract is that Spec 07's tests pass untouched.

**Files:**
- Create: `Muse/Muse/Export/ExportPipeline.swift`
- Modify: `Muse/Muse/Export/Social/SocialRender.swift`
- Test: the existing `Muse/MuseTests/SocialRenderTests.swift` (unchanged — that IS the test)

**Interfaces:**
- Produces: `ExportPipeline.context`, `ExportPipeline.RenderError`, `ExportPipeline.DecodedSource`, `ExportPipeline.load(url:decodeLongEdgeMax:)`, `ExportPipeline.scale(_:to:)`, `ExportPipeline.collisionSafeURL(base:ext:in:)`

- [ ] **Step 1: Run the social tests first, to have a baseline**

Run: `xcodebuild -project Muse/Muse.xcodeproj -scheme Muse test -only-testing:MuseTests/SocialRenderTests -only-testing:MuseTests/SocialCropMathTests -only-testing:MuseTests/SocialMetadataTests -only-testing:MuseTests/SocialPresetTests 2>&1 | tail -5`

Expected: `** TEST SUCCEEDED **`. Note the test count — it must not drop.

- [ ] **Step 2: Create `ExportPipeline.swift`**

```swift
//
//  ExportPipeline.swift
//  Muse
//
//  The render steps every export path shares. Extracted from SocialRender when
//  the general image export (Spec: 2026-08-02-image-export-design) needed the
//  same decode, scale and naming — one copy, so a fix to the budget gate or the
//  orientation bake can't land in one exporter and miss the other.
//
//  Platform-neutral: Foundation / CoreGraphics / CoreImage / ImageIO only.
//

import Foundation
import CoreGraphics
import CoreImage
import ImageIO

nonisolated enum ExportPipeline {
    enum RenderError: Error {
        case decodeFailed
        case tooLarge
        case encodeFailed
        case verifyFailed
    }

    /// One CIContext for every export in a run. Not the editor's live context —
    /// this one doesn't cache intermediates (each image is seen once).
    static let context = CIContext(options: [
        .workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB) as Any,
        .cacheIntermediates: false,
    ])

    /// A decoded, display-oriented source plus the header facts a caller needs
    /// to reason about size before it looks at pixels.
    struct DecodedSource {
        let image: CGImage
        /// The decoded image's own size (orientation already applied).
        let decodedSize: CGSize
        /// The FULL source size, orientation applied — what "original size"
        /// means, and what never-upscale is measured against.
        let sourceSize: CGSize
        /// Raw header properties, for metadata merging at encode time.
        let sourceProperties: [String: Any]
    }

    /// Steps 2–3 of every export: bomb guard, then a bounded decode with the
    /// EXIF orientation BAKED IN (`…WithTransform`), so no output can carry an
    /// orientation tag.
    ///
    /// `decodeLongEdgeMax == nil` decodes at full source resolution.
    static func load(url: URL, decodeLongEdgeMax: Int?) throws -> DecodedSource {
        guard let cgSource = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw RenderError.decodeFailed
        }
        guard ThumbnailCache.withinDecodeBudget(cgSource) else { throw RenderError.tooLarge }
        guard let props = CGImageSourceCopyPropertiesAtIndex(cgSource, 0, nil) as? [String: Any],
              let w = props[kCGImagePropertyPixelWidth as String] as? Int,
              let h = props[kCGImagePropertyPixelHeight as String] as? Int,
              w > 0, h > 0
        else { throw RenderError.decodeFailed }

        // The header reports STORED dimensions; an EXIF-rotated source decodes
        // transposed, so swap before anything reasons about aspect.
        let orientation = (props[kCGImagePropertyOrientation as String] as? UInt32) ?? 1
        let transposed = (5...8).contains(Int(orientation))
        let sourceSize = transposed ? CGSize(width: h, height: w) : CGSize(width: w, height: h)

        let maxPixel = decodeLongEdgeMax ?? Int(max(sourceSize.width, sourceSize.height))
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, maxPixel),
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let decoded = CGImageSourceCreateThumbnailAtIndex(cgSource, 0, options as CFDictionary) else {
            throw RenderError.decodeFailed
        }
        return DecodedSource(image: decoded,
                             decodedSize: CGSize(width: decoded.width, height: decoded.height),
                             sourceSize: sourceSize,
                             sourceProperties: props)
    }

    /// Exact-dimension scale. `CILanczosScaleTransform` alone lands a fraction
    /// of a pixel off on some ratios, so the result is cropped to the integral
    /// target — output dims must be EXACT.
    static func scale(_ image: CIImage, to size: CGSize) -> CIImage {
        let extent = image.extent
        guard extent.width > 0, extent.height > 0 else { return image }
        let scaleY = size.height / extent.height
        let scaleX = size.width / extent.width
        let scaled = image.applyingFilter("CILanczosScaleTransform",
            parameters: [kCIInputScaleKey: scaleY, kCIInputAspectRatioKey: scaleX / scaleY])
        return scaled
            .transformed(by: CGAffineTransform(translationX: -scaled.extent.minX,
                                               y: -scaled.extent.minY))
            .cropped(to: CGRect(origin: .zero, size: size))
    }

    /// `<base>.<ext>`, then `-2`, `-3`… Never returns a path that exists, so an
    /// export can never overwrite a file the user already has.
    static func collisionSafeURL(base: String, ext: String, in directory: URL) -> URL {
        var candidate = directory.appendingPathComponent("\(base).\(ext)")
        var n = 2
        let fm = FileManager.default
        while fm.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(base)-\(n).\(ext)")
            n += 1
        }
        return candidate
    }
}
```

- [ ] **Step 3: Point `SocialRender` at it**

In `SocialRender.swift`: delete the private `context`, `scale` and `collisionSafeURL`; replace their call sites with `ExportPipeline.context`, `ExportPipeline.scale`, `ExportPipeline.collisionSafeURL`. Replace the decode preamble (the block from `CGImageSourceCreateWithURL` through `CGImageSourceCreateThumbnailAtIndex`) with a call to `ExportPipeline.load`, mapping its errors onto `SocialRender.RenderError` so the enum's public cases don't change:

```swift
let source: ExportPipeline.DecodedSource
do {
    source = try ExportPipeline.load(url: out.url, decodeLongEdgeMax: decodeMax)
} catch ExportPipeline.RenderError.tooLarge {
    throw RenderError.tooLarge
} catch {
    throw RenderError.decodeFailed
}
```

`decodeMax` is computed from `source.sourceSize`, which `load` needs — so compute the target in two stages: call `ExportPipeline.load(url:decodeLongEdgeMax:nil)` **only** for `.original` presets, and for the others read the header first via a small `ExportPipeline.headerSize(url:)` helper, then load bounded. Add that helper:

```swift
    /// Header-only size (orientation applied), for callers that must choose a
    /// decode ceiling before decoding.
    static func headerSize(url: URL) throws -> CGSize {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw RenderError.decodeFailed
        }
        guard ThumbnailCache.withinDecodeBudget(src) else { throw RenderError.tooLarge }
        guard let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [String: Any],
              let w = props[kCGImagePropertyPixelWidth as String] as? Int,
              let h = props[kCGImagePropertyPixelHeight as String] as? Int,
              w > 0, h > 0
        else { throw RenderError.decodeFailed }
        let orientation = (props[kCGImagePropertyOrientation as String] as? UInt32) ?? 1
        return (5...8).contains(Int(orientation))
            ? CGSize(width: h, height: w) : CGSize(width: w, height: h)
    }
```

Keep `SocialRender.fixedFrame`, `Job`, `Result`, `RenderError` and `verifyXInvariants` exactly as they are — the card and its tests use them.

- [ ] **Step 4: Run the four social test files**

Run: `xcodebuild -project Muse/Muse.xcodeproj -scheme Muse test -only-testing:MuseTests/SocialRenderTests -only-testing:MuseTests/SocialCropMathTests -only-testing:MuseTests/SocialMetadataTests -only-testing:MuseTests/SocialPresetTests 2>&1 | tail -5`

Expected: `** TEST SUCCEEDED **`, same count as Step 1. A behaviour change here is a bug in the extraction, not a test to update.

- [ ] **Step 5: Audit, then commit**

```bash
./scripts/audit-invariants.sh
git add -A && git commit -m "export: factor the shared render steps out of SocialRender"
```

---

## Task 2: The format value types

**Files:**
- Create: `Muse/Muse/Export/Image/ExportFormat.swift`
- Test: `Muse/MuseTests/ExportFormatTests.swift`, `Muse/MuseTests/ExportResizeTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `ExportFormat` (`.sameAsOriginal .jpeg .png .tiff .heic .webp`) with `displayName: String`, `supportsQuality: Bool`, `supportsBitDepth: Bool`, `static var available: [ExportFormat]`, `func resolved(for: URL) -> ExportFormat`, `func fileExtension(for: URL) -> String`, `func utType(for: URL) -> UTType`; `ExportResize` (`.original`, `.longEdge(Int)`, `.fitWithin(width:height:)`) with `func targetSize(for: CGSize) -> CGSize`; `ExportSettings`.

- [ ] **Step 1: Write the failing tests**

`Muse/MuseTests/ExportResizeTests.swift`:

```swift
import XCTest
@testable import Muse

final class ExportResizeTests: XCTestCase {
    func testOriginalReturnsSourceSize() {
        let s = CGSize(width: 4000, height: 3000)
        XCTAssertEqual(ExportResize.original.targetSize(for: s), s)
    }

    func testLongEdgeScalesTheLongSideAndKeepsAspect() {
        let s = CGSize(width: 4000, height: 3000)
        let t = ExportResize.longEdge(2000).targetSize(for: s)
        XCTAssertEqual(t.width, 2000, accuracy: 0.5)
        XCTAssertEqual(t.height, 1500, accuracy: 0.5)
    }

    func testLongEdgeUsesTheTallSideForAPortraitSource() {
        let t = ExportResize.longEdge(1000).targetSize(for: CGSize(width: 600, height: 1200))
        XCTAssertEqual(t.height, 1000, accuracy: 0.5)
        XCTAssertEqual(t.width, 500, accuracy: 0.5)
    }

    /// The global rule: a source under the target exports at its own size.
    func testNeverUpscalesOnLongEdge() {
        let s = CGSize(width: 800, height: 600)
        XCTAssertEqual(ExportResize.longEdge(4000).targetSize(for: s), s)
    }

    func testFitWithinShrinksToTheTighterBound() {
        let t = ExportResize.fitWithin(width: 1000, height: 1000)
            .targetSize(for: CGSize(width: 4000, height: 2000))
        XCTAssertEqual(t.width, 1000, accuracy: 0.5)
        XCTAssertEqual(t.height, 500, accuracy: 0.5)
    }

    func testNeverUpscalesOnFitWithin() {
        let s = CGSize(width: 300, height: 200)
        XCTAssertEqual(ExportResize.fitWithin(width: 4000, height: 4000).targetSize(for: s), s)
    }

    func testDegenerateSourceDoesNotDivideByZero() {
        let t = ExportResize.longEdge(1000).targetSize(for: CGSize(width: 0, height: 0))
        XCTAssertTrue(t.width >= 1 && t.height >= 1)
    }
}
```

`Muse/MuseTests/ExportFormatTests.swift`:

```swift
import XCTest
import ImageIO
import UniformTypeIdentifiers
@testable import Muse

final class ExportFormatTests: XCTestCase {
    /// The card must never offer an output this machine cannot produce.
    func testAvailableNeverListsATypeImageIOCannotWrite() {
        let writable = Set((CGImageDestinationCopyTypeIdentifiers() as? [String]) ?? [])
        for format in ExportFormat.available {
            switch format {
            case .sameAsOriginal:
                continue                     // resolves per-file
            case .webp:
                continue                     // libwebp, not ImageIO
            default:
                XCTAssertTrue(writable.contains(format.utType(for: URL(fileURLWithPath: "/x.jpg")).identifier),
                              "\(format) is offered but ImageIO can't write it")
            }
        }
    }

    func testAvailableAlwaysIncludesJPEGAndPNG() {
        XCTAssertTrue(ExportFormat.available.contains(.jpeg))
        XCTAssertTrue(ExportFormat.available.contains(.png))
    }

    func testSameAsOriginalResolvesToTheSourceContainer() {
        XCTAssertEqual(ExportFormat.sameAsOriginal.resolved(for: URL(fileURLWithPath: "/a/b.png")), .png)
        XCTAssertEqual(ExportFormat.sameAsOriginal.resolved(for: URL(fileURLWithPath: "/a/b.TIF")), .tiff)
        XCTAssertEqual(ExportFormat.sameAsOriginal.resolved(for: URL(fileURLWithPath: "/a/b.heic")), .heic)
    }

    /// RAW can't be written back — every RAW resolves to JPEG.
    func testSameAsOriginalResolvesRawToJPEG() {
        for ext in ["cr2", "nef", "arw", "dng", "raf"] {
            XCTAssertEqual(ExportFormat.sameAsOriginal.resolved(for: URL(fileURLWithPath: "/a/b.\(ext)")),
                           .jpeg, "\(ext) should resolve to JPEG")
        }
    }

    func testFileExtensions() {
        let jpg = URL(fileURLWithPath: "/a/b.jpg")
        XCTAssertEqual(ExportFormat.jpeg.fileExtension(for: jpg), "jpg")
        XCTAssertEqual(ExportFormat.png.fileExtension(for: jpg), "png")
        XCTAssertEqual(ExportFormat.tiff.fileExtension(for: jpg), "tif")
        XCTAssertEqual(ExportFormat.heic.fileExtension(for: jpg), "heic")
        XCTAssertEqual(ExportFormat.webp.fileExtension(for: jpg), "webp")
    }

    func testOnlyLossyFormatsCarryQuality() {
        XCTAssertTrue(ExportFormat.jpeg.supportsQuality)
        XCTAssertTrue(ExportFormat.heic.supportsQuality)
        XCTAssertTrue(ExportFormat.webp.supportsQuality)
        XCTAssertFalse(ExportFormat.png.supportsQuality)
        XCTAssertFalse(ExportFormat.tiff.supportsQuality)
    }

    func testOnlyTIFFCarriesBitDepth() {
        XCTAssertTrue(ExportFormat.tiff.supportsBitDepth)
        XCTAssertFalse(ExportFormat.jpeg.supportsBitDepth)
        XCTAssertFalse(ExportFormat.png.supportsBitDepth)
    }

    func testSettingsRoundTripThroughCodable() throws {
        let s = ExportSettings(format: .tiff, quality: 0.8, tiff16: true,
                               resize: .fitWithin(width: 1200, height: 900),
                               includeEXIF: true, includeLocation: false)
        let data = try JSONEncoder().encode(s)
        XCTAssertEqual(try JSONDecoder().decode(ExportSettings.self, from: data), s)
    }
}
```

- [ ] **Step 2: Run them to verify they fail**

Run: `xcodebuild -project Muse/Muse.xcodeproj -scheme Muse test -only-testing:MuseTests/ExportFormatTests -only-testing:MuseTests/ExportResizeTests 2>&1 | tail -8`

Expected: compile failure — `Cannot find 'ExportFormat' in scope`.

- [ ] **Step 3: Write `ExportFormat.swift`**

```swift
//
//  ExportFormat.swift
//  Muse
//
//  What a general export can produce, and how big. Pure data — the render
//  lives in ImageExportRender.
//
//  The available list is built from what the RUNNING OS reports writable, not
//  from a hard-coded table: ImageIO reads far more formats than it writes (it
//  reads WebP and DNG and writes neither), and a card that offers an output the
//  machine can't produce is a card that fails at the last step. WebP is the one
//  entry that doesn't come from ImageIO — it's ours, via libwebp.
//
//  Platform-neutral: Foundation / CoreGraphics / ImageIO / UTType only.
//

import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

nonisolated enum ExportFormat: String, CaseIterable, Codable, Sendable {
    case sameAsOriginal, jpeg, png, tiff, heic, webp

    /// Not auto-extracted — a computed String is invisible to the compiler's
    /// literal scan, so each of these is wrapped by hand.
    var displayName: String {
        switch self {
        case .sameAsOriginal: String(localized: "Same as original")
        case .jpeg: String(localized: "JPEG")
        case .png: String(localized: "PNG")
        case .tiff: String(localized: "TIFF")
        case .heic: String(localized: "HEIC")
        case .webp: String(localized: "WebP")
        }
    }

    var supportsQuality: Bool {
        switch self {
        case .jpeg, .heic, .webp: true
        case .sameAsOriginal, .png, .tiff: false
        }
    }

    var supportsBitDepth: Bool { self == .tiff }

    /// JPEG and HEIC have no usable alpha, so those exports flatten. PNG, TIFF
    /// and WebP keep it — flattening them would be a silent data loss.
    var keepsAlpha: Bool {
        switch self {
        case .jpeg, .heic: false
        case .png, .tiff, .webp: true
        case .sameAsOriginal: true          // resolve first; never asked directly
        }
    }

    /// RAW extensions resolve to JPEG: a RAW cannot be written back, so "same
    /// as original" has to mean something, and JPEG is what EditRenderer
    /// already produces for a RAW.
    private static let rawExtensions: Set<String> = [
        "cr2", "cr3", "crw", "nef", "nrw", "arw", "srf", "sr2", "raf", "orf",
        "rw2", "pef", "dng", "raw", "dcr", "kdc", "erf", "mrw", "3fr", "iiq",
    ]

    /// The concrete format this one means for a given source. Identity for
    /// everything except `.sameAsOriginal`.
    func resolved(for url: URL) -> ExportFormat {
        guard self == .sameAsOriginal else { return self }
        let ext = url.pathExtension.lowercased()
        if Self.rawExtensions.contains(ext) { return .jpeg }
        switch ext {
        case "png": return .png
        case "tif", "tiff": return .tiff
        case "heic", "heif": return .heic
        default: return .jpeg
        }
    }

    func fileExtension(for url: URL) -> String {
        switch resolved(for: url) {
        case .png: "png"
        case .tiff: "tif"
        case .heic: "heic"
        case .webp: "webp"
        case .jpeg, .sameAsOriginal: "jpg"
        }
    }

    func utType(for url: URL) -> UTType {
        switch resolved(for: url) {
        case .png: .png
        case .tiff: .tiff
        case .heic: UTType("public.heic") ?? .jpeg
        case .webp: UTType("org.webmproject.webp") ?? .png
        case .jpeg, .sameAsOriginal: .jpeg
        }
    }

    /// Formats this machine can actually write, in menu order. `.sameAsOriginal`
    /// is always offered (it resolves to a concrete format per file, and JPEG —
    /// its fallback — is always writable).
    static var available: [ExportFormat] {
        let writable = Set((CGImageDestinationCopyTypeIdentifiers() as? [String]) ?? [])
        let probe = URL(fileURLWithPath: "/probe.jpg")
        return [.sameAsOriginal, .jpeg, .png, .tiff, .heic, .webp].filter { format in
            switch format {
            case .sameAsOriginal: true
            case .webp: WebPEncoder.isAvailable
            default: writable.contains(format.utType(for: probe).identifier)
            }
        }
    }
}

nonisolated enum ExportResize: Equatable, Codable, Sendable {
    case original
    case longEdge(Int)
    case fitWithin(width: Int, height: Int)

    /// The output size for a source. NEVER upscales — a source smaller than the
    /// target exports at its own size, the same global rule SocialRender holds.
    func targetSize(for source: CGSize) -> CGSize {
        let w = max(1, source.width), h = max(1, source.height)
        let safe = CGSize(width: w, height: h)
        switch self {
        case .original:
            return safe
        case .longEdge(let cap):
            let long = max(w, h)
            let factor = min(1, CGFloat(cap) / long)
            guard factor < 1 else { return safe }
            return CGSize(width: max(1, (w * factor).rounded()),
                          height: max(1, (h * factor).rounded()))
        case .fitWithin(let bw, let bh):
            let factor = min(1, min(CGFloat(bw) / w, CGFloat(bh) / h))
            guard factor < 1 else { return safe }
            return CGSize(width: max(1, (w * factor).rounded()),
                          height: max(1, (h * factor).rounded()))
        }
    }
}

nonisolated struct ExportSettings: Equatable, Codable, Sendable {
    var format: ExportFormat = .jpeg
    var quality: Double = 0.9
    var tiff16: Bool = false
    var resize: ExportResize = .original
    var includeEXIF: Bool = false
    var includeLocation: Bool = false

    init(format: ExportFormat = .jpeg, quality: Double = 0.9, tiff16: Bool = false,
         resize: ExportResize = .original, includeEXIF: Bool = false,
         includeLocation: Bool = false) {
        self.format = format
        self.quality = quality
        self.tiff16 = tiff16
        self.resize = resize
        self.includeEXIF = includeEXIF
        self.includeLocation = includeLocation
    }
}
```

- [ ] **Step 4: Add a WebP availability stub so this compiles before Task 8**

Create `Muse/Muse/Export/Image/WebPEncoder.swift`:

```swift
//
//  WebPEncoder.swift
//  Muse
//
//  WebP is the one export format ImageIO can't write — verified, not assumed:
//  CGImageDestinationCopyTypeIdentifiers() lists 22 writable types on macOS
//  26.5 and WebP isn't among them. The encoder is therefore ours, via libwebp.
//
//  Until that dependency lands (plan Task 8) this reports unavailable, and
//  ExportFormat.available simply doesn't offer WebP — the rest of export works.
//

import Foundation
import CoreGraphics

nonisolated enum WebPEncoder {
    /// Whether a WebP encoder is linked in this build.
    static var isAvailable: Bool { false }

    static func encode(_ image: CGImage, quality: Double) throws -> Data {
        throw ExportPipeline.RenderError.encodeFailed
    }
}
```

- [ ] **Step 5: Run the tests**

Run: `xcodebuild -project Muse/Muse.xcodeproj -scheme Muse test -only-testing:MuseTests/ExportFormatTests -only-testing:MuseTests/ExportResizeTests 2>&1 | tail -5`

Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 6: Commit**

```bash
./scripts/audit-invariants.sh
git add -A && git commit -m "export: format, resize and settings value types"
```

---

## Task 3: The format renderer

**Files:**
- Create: `Muse/Muse/Export/Image/ImageExportRender.swift`
- Modify: `Muse/Muse/Export/Social/SocialMetadata.swift` (rename type to `ExportMetadata`; update the one call site in `SocialRender.encodeJPEG`)
- Test: `Muse/MuseTests/ImageExportRenderTests.swift`

**Interfaces:**
- Consumes: `ExportPipeline.*` (Task 1), `ExportFormat`/`ExportResize`/`ExportSettings` (Task 2).
- Produces: `ImageExportRender.Job(sourceURL:settings:)`, `ImageExportRender.Result(url:pixelSize:bytes:)`, `ImageExportRender.export(_:to:) throws -> Result`.

- [ ] **Step 1: Write the failing tests**

`Muse/MuseTests/ImageExportRenderTests.swift`:

```swift
import XCTest
import ImageIO
import UniformTypeIdentifiers
@testable import Muse

final class ImageExportRenderTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("export-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func props(_ url: URL) throws -> [String: Any] {
        let src = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        return try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [String: Any])
    }

    func testLongEdgeProducesExactDimensions() throws {
        let src = try SocialFixtures.makeJPEG(width: 4000, height: 3000,
                                              name: "wide", in: dir)
        let job = ImageExportRender.Job(
            sourceURL: src,
            settings: ExportSettings(format: .jpeg, resize: .longEdge(1000)))
        let result = try ImageExportRender.export(job, to: dir)
        XCTAssertEqual(result.pixelSize.width, 1000, accuracy: 0.5)
        XCTAssertEqual(result.pixelSize.height, 750, accuracy: 0.5)
    }

    func testNeverUpscales() throws {
        let src = try SocialFixtures.makeJPEG(width: 400, height: 300,
                                              name: "small", in: dir)
        let job = ImageExportRender.Job(
            sourceURL: src,
            settings: ExportSettings(format: .jpeg, resize: .longEdge(4000)))
        let result = try ImageExportRender.export(job, to: dir)
        XCTAssertEqual(result.pixelSize.width, 400, accuracy: 0.5)
    }

    func testPNGOutputIsAPNG() throws {
        let src = try SocialFixtures.makeJPEG(width: 800, height: 600,
                                              name: "topng", in: dir)
        let job = ImageExportRender.Job(sourceURL: src,
                                        settings: ExportSettings(format: .png))
        let result = try ImageExportRender.export(job, to: dir)
        XCTAssertEqual(result.url.pathExtension, "png")
        let src2 = try XCTUnwrap(CGImageSourceCreateWithURL(result.url as CFURL, nil))
        XCTAssertEqual(CGImageSourceGetType(src2) as String?, UTType.png.identifier)
    }

    func testSixteenBitTIFFIsActuallySixteenBit() throws {
        let src = try SocialFixtures.makeJPEG(width: 600, height: 400,
                                              name: "deep", in: dir)
        let job = ImageExportRender.Job(
            sourceURL: src,
            settings: ExportSettings(format: .tiff, tiff16: true))
        let result = try ImageExportRender.export(job, to: dir)
        let depth = try props(result.url)[kCGImagePropertyDepth as String] as? Int
        XCTAssertEqual(depth, 16)
    }

    func testEightBitTIFFIsEightBit() throws {
        let src = try SocialFixtures.makeJPEG(width: 600, height: 400,
                                              name: "shallow", in: dir)
        let job = ImageExportRender.Job(
            sourceURL: src,
            settings: ExportSettings(format: .tiff, tiff16: false))
        let result = try ImageExportRender.export(job, to: dir)
        let depth = try props(result.url)[kCGImagePropertyDepth as String] as? Int
        XCTAssertEqual(depth, 8)
    }

    /// EXIF off must be PROVABLY clean, not merely constructed to be.
    func testMetadataOffProducesACleanFile() throws {
        let src = try SocialFixtures.makeJPEG(width: 800, height: 600,
                                              name: "stripped", in: dir)
        let job = ImageExportRender.Job(
            sourceURL: src,
            settings: ExportSettings(format: .jpeg, includeEXIF: false))
        let result = try ImageExportRender.export(job, to: dir)
        let data = try Data(contentsOf: result.url)
        XCTAssertTrue(ImageMetadataStripper.isClean(data))
    }

    /// The whole point of the feature: a RAW leaves as a real image file.
    func testSameAsOriginalOnARawNameProducesJPEG() {
        XCTAssertEqual(ExportFormat.sameAsOriginal.fileExtension(
            for: URL(fileURLWithPath: "/a/shot.CR2")), "jpg")
    }

    /// Never overwrite. Two exports of the same source into one folder produce
    /// two files.
    func testCollisionAddsASuffixRatherThanOverwriting() throws {
        let src = try SocialFixtures.makeJPEG(width: 400, height: 300,
                                              name: "twice", in: dir)
        let job = ImageExportRender.Job(sourceURL: src,
                                        settings: ExportSettings(format: .png))
        let first = try ImageExportRender.export(job, to: dir)
        let second = try ImageExportRender.export(job, to: dir)
        XCTAssertNotEqual(first.url, second.url)
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.url.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.url.path))
        XCTAssertEqual(second.url.lastPathComponent, "twice-2.png")
    }

    func testOutputCarriesNoOrientationTag() throws {
        // Orientation 6 = rotate 90°. It must be BAKED, never re-emitted.
        let src = try SocialFixtures.makeJPEG(width: 800, height: 600,
                                              orientation: 6, name: "rot", in: dir)
        let job = ImageExportRender.Job(sourceURL: src,
                                        settings: ExportSettings(format: .jpeg))
        let result = try ImageExportRender.export(job, to: dir)
        XCTAssertNil(try props(result.url)[kCGImagePropertyOrientation as String])
        // Baked: the 600×800 display orientation is what lands on disk.
        XCTAssertEqual(result.pixelSize.width, 600, accuracy: 0.5)
    }
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `xcodebuild -project Muse/Muse.xcodeproj -scheme Muse test -only-testing:MuseTests/ImageExportRenderTests 2>&1 | tail -8`

Expected: compile failure — `Cannot find 'ImageExportRender' in scope`.

- [ ] **Step 3: Rename `SocialMetadata` → `ExportMetadata`**

It is no longer social-only. Rename the type in `Muse/Muse/Export/Social/SocialMetadata.swift`, move the file to `Muse/Muse/Export/ExportMetadata.swift`, update the header comment, and fix the call site in `SocialRender.encodeJPEG` and the test file `SocialMetadataTests.swift`. Keep the function signature `outputProperties(source:includeLocation:)` unchanged.

- [ ] **Step 4: Write `ImageExportRender.swift`**

```swift
//
//  ImageExportRender.swift
//  Muse
//
//  The general export pipeline. Same discipline as SocialRender — the ORDER is
//  code, never data:
//
//    1  OutputRender.forOutput   — the choke point first, so edits ride out
//    2  budget gate + oriented decode (ExportPipeline.load) — orientation BAKED
//    3  resize                   — never upscales
//    4  flatten, but only for formats with no usable alpha
//    5  encode at the chosen format / quality / depth
//    6  verify clean when metadata is off, then write without overwriting
//
//  It deliberately does NOT sharpen, which is the one divergence from
//  SocialRender: a social export is being fitted to a platform, and unsharp
//  masking undoes the resampling softness that fitting causes. A general export
//  is a faithful conversion, and a sharpening pass nobody asked for is a
//  surprise in someone's pixels. darktable doesn't sharpen on export either.
//
//  Platform-neutral: Foundation / CoreGraphics / CoreImage / ImageIO only.
//

import Foundation
import CoreGraphics
import CoreImage
import ImageIO
import UniformTypeIdentifiers

nonisolated enum ImageExportRender {
    struct Job: Sendable {
        /// The ORIGINAL library URL — forOutput resolves any edit stack.
        var sourceURL: URL
        var settings: ExportSettings
    }

    struct Result: Sendable {
        let url: URL
        let pixelSize: CGSize
        let bytes: Int
    }

    static func export(_ job: Job, to directory: URL) throws -> Result {
        let format = job.settings.format.resolved(for: job.sourceURL)

        // 1. Choke point. A 16-bit request renders its temp at 16-bit rather
        //    than inflating an 8-bit one and calling it deep.
        let preferred: OutputFormat? = (format == .tiff && job.settings.tiff16) ? .tiff16 : nil
        let out = try OutputRender.forOutput(job.sourceURL, preferring: preferred)
        defer { OutputRender.discard(out) }

        // 2. Budget gate + bounded, orientation-baked decode.
        let headerSize = try ExportPipeline.headerSize(url: out.url)
        let target = job.settings.resize.targetSize(for: headerSize)
        let source = try ExportPipeline.load(
            url: out.url,
            decodeLongEdgeMax: Int(max(target.width, target.height).rounded()))

        // 3. Resize. targetSize is recomputed against what actually decoded —
        //    the decode ceiling can land a pixel or two off on odd ratios, and
        //    the OUTPUT dimensions must be exact.
        var image = CIImage(cgImage: source.image)
        let finalSize = job.settings.resize.targetSize(for: source.decodedSize)
        if finalSize != source.decodedSize {
            image = ExportPipeline.scale(image, to: finalSize)
        }

        // 4. Flatten only where the container can't carry alpha. PNG/TIFF/WebP
        //    keep it; compositing them over white would be a silent data loss.
        let extent = image.extent.integral
        guard extent.width >= 1, extent.height >= 1 else {
            throw ExportPipeline.RenderError.encodeFailed
        }
        if format.keepsAlpha == false {
            image = image.composited(over: CIImage(color: .white).cropped(to: extent))
        }

        // 5. Encode. sRGB throughout — wide-gamut RAW converted here is what
        //    makes an export look the same wherever it lands.
        guard let sRGB = CGColorSpace(name: CGColorSpace.sRGB) else {
            throw ExportPipeline.RenderError.encodeFailed
        }
        let deep = (format == .tiff && job.settings.tiff16)
        guard let cgImage = ExportPipeline.context.createCGImage(
            image, from: extent,
            format: deep ? .RGBA16 : .RGBA8,
            colorSpace: sRGB)
        else { throw ExportPipeline.RenderError.encodeFailed }

        let data = try encode(cgImage, format: format, job: job,
                              sourceProperties: source.sourceProperties)

        // 6. Verify, then write. A default-metadata output must be PROVABLY
        //    clean, not merely constructed to be — the same rule the social and
        //    Drive paths hold.
        if job.settings.includeEXIF == false {
            guard ImageMetadataStripper.isClean(data) else {
                throw ExportPipeline.RenderError.verifyFailed
            }
        }
        let stem = job.sourceURL.deletingPathExtension().lastPathComponent
        let dest = ExportPipeline.collisionSafeURL(
            base: stem,
            ext: job.settings.format.fileExtension(for: job.sourceURL),
            in: directory)
        try data.write(to: dest, options: .atomic)
        return Result(url: dest,
                      pixelSize: CGSize(width: cgImage.width, height: cgImage.height),
                      bytes: data.count)
    }

    private static func encode(_ image: CGImage, format: ExportFormat, job: Job,
                               sourceProperties: [String: Any]) throws -> Data {
        if format == .webp {
            return try WebPEncoder.encode(image, quality: job.settings.quality)
        }
        let type = format.utType(for: job.sourceURL).identifier as CFString
        guard let mutable = CFDataCreateMutable(nil, 0),
              let dest = CGImageDestinationCreateWithData(mutable, type, 1, nil)
        else { throw ExportPipeline.RenderError.encodeFailed }

        var properties: [String: Any] = [:]
        if format.supportsQuality {
            properties[kCGImageDestinationLossyCompressionQuality as String] = job.settings.quality
        }
        if job.settings.includeEXIF,
           let merged = ExportMetadata.outputProperties(
                source: sourceProperties as CFDictionary,
                includeLocation: job.settings.includeLocation) as? [String: Any] {
            properties.merge(merged) { _, new in new }
        }
        CGImageDestinationAddImage(dest, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(dest) else {
            throw ExportPipeline.RenderError.encodeFailed
        }
        return mutable as Data
    }
}
```

- [ ] **Step 5: Run — expect the 16-bit test to fail**

Run: `xcodebuild -project Muse/Muse.xcodeproj -scheme Muse test -only-testing:MuseTests/ImageExportRenderTests 2>&1 | tail -12`

Expected: everything passes **except** `testSixteenBitTIFFIsActuallySixteenBit`, and the build fails on `forOutput(_:preferring:)` not existing. Task 4 supplies both. If you prefer a green intermediate, temporarily call `OutputRender.forOutput(job.sourceURL)` and restore the overload in Task 4 — but do not commit the temporary form.

- [ ] **Step 6: Do not commit yet — Task 4 completes this**

---

## Task 4: Real 16-bit output

`OutputFormat.tiff16` exists but is nominal: `EditRenderer.exportFile` always builds `.RGBA8` and `write` sets no depth. This task makes it mean what it says, and gives `OutputRender` a format-aware overload so an edited photo destined for 16-bit doesn't get rendered to an 8-bit temp first.

**Files:**
- Modify: `Muse/Muse/Export/OutputRender.swift`, `Muse/Muse/Editing/Render/EditRenderer.swift:360-374,422-432`
- Test: `Muse/MuseTests/ImageExportRenderTests.swift` (already written), `Muse/MuseTests/OutputRenderTests.swift` (add one)

**Interfaces:**
- Produces: `OutputRender.forOutput(_ url: URL, preferring: OutputFormat?) throws -> RenderedOutput`

- [ ] **Step 1: Add the overload to `OutputRender`**

Change the existing `forOutput(_:)` to delegate, so there is still one implementation:

```swift
    static func forOutput(_ url: URL) throws -> RenderedOutput {
        try forOutput(url, preferring: nil)
    }

    /// `preferring` overrides the container the render temp is written in.
    /// The general export uses it so a 16-bit request renders a 16-bit temp
    /// rather than inflating an 8-bit one and calling it deep.
    ///
    /// An ADDED overload, never a bypass: `RenderedOutput`'s init stays
    /// fileprivate and this is still the only way to obtain one (audit OUT-1).
    static func forOutput(_ url: URL, preferring: OutputFormat?) throws -> RenderedOutput {
        guard let hash = EditStackIndex.stackHash(for: url),
              let stack = EditStackIndex.resolvedStack(for: url),
              EditRenderer.canRender(stack)
        else { return RenderedOutput(url: url, stackHash: nil) }

        let format: OutputFormat = preferring
            ?? (EditRenderer.isRawURL(url) ? .jpeg : .matchingSource(url))
        // …the existing body from here down, unchanged.
    }
```

- [ ] **Step 2: Make `EditRenderer` honour the depth**

In `exportFile`, pick the CI format from the output format:

```swift
        let context = RenderContexts.makeExportContext()
        // .tiff16 is the only deep container Muse writes. Building RGBA8 and
        // labelling it 16-bit is a quality claim the bytes don't support.
        let ciFormat: CIFormat = (format == .tiff16) ? .RGBA16 : .RGBA8
        guard let cgImage = context.createCGImage(rendered.ciImage, from: extent,
                                                  format: ciFormat,
                                                  colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        else { throw RenderError.renderFailed }
```

`write` needs no change — `CGImageDestination` carries the depth from the `CGImage` itself.

- [ ] **Step 3: Add the `OutputRenderTests` case**

```swift
    /// The added overload must not become a second way to construct a
    /// RenderedOutput for an unedited file — it takes the same pass-through.
    func testPreferringLeavesAnUneditedFileUntouched() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let src = try SocialFixtures.makeJPEG(width: 100, height: 100, name: "plain", in: dir)
        let out = try OutputRender.forOutput(src, preferring: .tiff16)
        XCTAssertEqual(out.url, src)
        XCTAssertNil(out.stackHash)
    }
```

- [ ] **Step 4: Run both test files**

Run: `xcodebuild -project Muse/Muse.xcodeproj -scheme Muse test -only-testing:MuseTests/ImageExportRenderTests -only-testing:MuseTests/OutputRenderTests 2>&1 | tail -6`

Expected: `** TEST SUCCEEDED **`, including `testSixteenBitTIFFIsActuallySixteenBit`.

- [ ] **Step 5: Audit and commit Tasks 3 + 4 together**

`OUT-1` must still pass — that is the point of using an overload.

```bash
./scripts/audit-invariants.sh
git add -A && git commit -m "export: the format renderer, with 16-bit that means it"
```

---

## Task 5: Saved presets

**Files:**
- Create: `Muse/Muse/Models/ExportPresetStore.swift`
- Modify: `Muse/Muse/Settings/AppSettings.swift`
- Test: `Muse/MuseTests/ExportPresetStoreTests.swift`

**Interfaces:**
- Consumes: `ExportSettings` (Task 2).
- Produces: `SavedExportPreset(id:name:settings:)`; `ExportPresetStore.shared` with `presets: [SavedExportPreset]`, `save(name:settings:)`, `delete(id:)`, `rename(id:to:)`; `AppSettings.exportPresets`, `AppSettings.lastExportSettings`.

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
@testable import Muse

@MainActor
final class ExportPresetStoreTests: XCTestCase {
    private let key = "exportPresets"

    override func setUp() async throws {
        UserDefaults.standard.removeObject(forKey: key)
        ExportPresetStore.shared.reload()
    }

    override func tearDown() async throws {
        UserDefaults.standard.removeObject(forKey: key)
        ExportPresetStore.shared.reload()
    }

    func testSaveThenReloadRoundTrips() {
        let settings = ExportSettings(format: .tiff, quality: 0.5, tiff16: true,
                                      resize: .longEdge(2048),
                                      includeEXIF: true, includeLocation: true)
        ExportPresetStore.shared.save(name: "Archive", settings: settings)
        ExportPresetStore.shared.reload()
        XCTAssertEqual(ExportPresetStore.shared.presets.count, 1)
        XCTAssertEqual(ExportPresetStore.shared.presets[0].name, "Archive")
        XCTAssertEqual(ExportPresetStore.shared.presets[0].settings, settings)
    }

    func testSavingTheSameNameTwiceKeepsBothWithDistinctIDs() {
        ExportPresetStore.shared.save(name: "Web", settings: ExportSettings())
        ExportPresetStore.shared.save(name: "Web", settings: ExportSettings(format: .png))
        XCTAssertEqual(ExportPresetStore.shared.presets.count, 2)
        XCTAssertNotEqual(ExportPresetStore.shared.presets[0].id,
                          ExportPresetStore.shared.presets[1].id)
    }

    func testDeleteRemovesOnlyThatPreset() {
        ExportPresetStore.shared.save(name: "A", settings: ExportSettings())
        ExportPresetStore.shared.save(name: "B", settings: ExportSettings(format: .png))
        let target = ExportPresetStore.shared.presets[0].id
        ExportPresetStore.shared.delete(id: target)
        XCTAssertEqual(ExportPresetStore.shared.presets.map(\.name), ["B"])
    }

    func testRename() {
        ExportPresetStore.shared.save(name: "Old", settings: ExportSettings())
        let id = ExportPresetStore.shared.presets[0].id
        ExportPresetStore.shared.rename(id: id, to: "New")
        XCTAssertEqual(ExportPresetStore.shared.presets[0].name, "New")
    }

    func testPresetsAreSortedByName() {
        ExportPresetStore.shared.save(name: "zeta", settings: ExportSettings())
        ExportPresetStore.shared.save(name: "Alpha", settings: ExportSettings())
        XCTAssertEqual(ExportPresetStore.shared.presets.map(\.name), ["Alpha", "zeta"])
    }

    /// A corrupt defaults blob degrades to empty rather than throwing — a user
    /// whose presets can't decode should still be able to export.
    func testCorruptBlobDegradesToEmpty() {
        UserDefaults.standard.set(Data("not json".utf8), forKey: key)
        ExportPresetStore.shared.reload()
        XCTAssertTrue(ExportPresetStore.shared.presets.isEmpty)
    }
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `xcodebuild -project Muse/Muse.xcodeproj -scheme Muse test -only-testing:MuseTests/ExportPresetStoreTests 2>&1 | tail -8`

Expected: `Cannot find 'ExportPresetStore' in scope`.

- [ ] **Step 3: Add the `AppSettings` keys**

Beside `socialExifChoices` in `AppSettings.swift`:

```swift
    /// Saved export presets, JSON. Defaults, not database — presets are a
    /// working preference, so there's no migration and no schema.
    static var exportPresets: Data? {
        get { UserDefaults.standard.data(forKey: "exportPresets") }
        set { UserDefaults.standard.set(newValue, forKey: "exportPresets") }
    }
    /// The last settings used in the export card, so it reopens where you left
    /// it. Separate from the presets: this one is implicit, they're explicit.
    static var lastExportSettings: Data? {
        get { UserDefaults.standard.data(forKey: "lastExportSettings") }
        set { UserDefaults.standard.set(newValue, forKey: "lastExportSettings") }
    }
```

- [ ] **Step 4: Write `ExportPresetStore.swift`**

```swift
//
//  ExportPresetStore.swift
//  Muse
//
//  Saved export settings. Defaults-backed rather than a table: a preset is a
//  working preference like the editor backdrop, not library data, so it needs
//  no migration and doesn't belong in a backup.
//
//  A corrupt blob degrades to an empty list. Someone whose presets can't decode
//  should still be able to export — losing the shortcuts is recoverable, being
//  unable to export is not.
//

import Foundation

struct SavedExportPreset: Identifiable, Equatable, Codable, Sendable {
    var id: UUID
    var name: String
    var settings: ExportSettings

    init(id: UUID = UUID(), name: String, settings: ExportSettings) {
        self.id = id
        self.name = name
        self.settings = settings
    }
}

@MainActor
final class ExportPresetStore: ObservableObject {
    static let shared = ExportPresetStore()

    @Published private(set) var presets: [SavedExportPreset] = []

    init() { reload() }

    func reload() {
        guard let data = AppSettings.exportPresets,
              let decoded = try? JSONDecoder().decode([SavedExportPreset].self, from: data)
        else { presets = []; return }
        presets = Self.sorted(decoded)
    }

    func save(name: String, settings: ExportSettings) {
        presets = Self.sorted(presets + [SavedExportPreset(name: name, settings: settings)])
        persist()
    }

    func delete(id: UUID) {
        presets.removeAll { $0.id == id }
        persist()
    }

    func rename(id: UUID, to name: String) {
        guard let i = presets.firstIndex(where: { $0.id == id }) else { return }
        presets[i].name = name
        presets = Self.sorted(presets)
        persist()
    }

    private func persist() {
        AppSettings.exportPresets = try? JSONEncoder().encode(presets)
    }

    private static func sorted(_ list: [SavedExportPreset]) -> [SavedExportPreset] {
        list.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}
```

- [ ] **Step 5: Run the tests, then commit**

Run: `xcodebuild -project Muse/Muse.xcodeproj -scheme Muse test -only-testing:MuseTests/ExportPresetStoreTests 2>&1 | tail -5`

Expected: `** TEST SUCCEEDED **`.

```bash
./scripts/audit-invariants.sh
git add -A && git commit -m "export: saved presets"
```

---

## Task 6: The card

**Files:**
- Modify → rename: `Muse/Muse/Views/Export/SocialExportCard.swift` → `Muse/Muse/Views/Export/ExportCard.swift`
- Modify: wherever `SocialExportCard` / `SocialExportRequest` are referenced (`AppState`, the shell that presents modals — find with `grep -rn "SocialExport" --include="*.swift" Muse/Muse`)

**Interfaces:**
- Consumes: `ExportFormat`/`ExportSettings` (2), `ImageExportRender` (3), `ExportPresetStore` (5), existing `SocialPreset`/`SocialRender`.
- Produces: `ExportCard`, `ExportRequest` (renamed from `SocialExportRequest`), `ExportModel`.

- [ ] **Step 1: Rename the type and file, no behaviour change**

`SocialExportCard` → `ExportCard`, `SocialExportModel` → `ExportModel`, `SocialExportRequest` → `ExportRequest`, `appState.socialExportRequest` → `appState.exportRequest`. Title `Text("Export for Social")` → `Text("Export")`. Build; fix call sites. Commit this rename alone so the next diff is readable:

```bash
git add -A && git commit -m "export: rename the social card to ExportCard"
```

- [ ] **Step 2: Add the selection type to `ExportModel`**

```swift
    /// What the dropdown is on. A format and a social platform are different
    /// enough — one has a crop stage, the other a quality slider — that the
    /// card branches on this rather than pretending they're one preset type.
    enum Selection: Equatable {
        case format(ExportFormat)
        case social(SocialPreset)
        case saved(SavedExportPreset)

        var settings: ExportSettings? {
            switch self {
            case .format: nil          // the model's own `settings` is the truth
            case .social: nil
            case .saved(let p): p.settings
            }
        }
    }

    @Published var selection: Selection = .format(.jpeg)
    @Published var settings = ExportSettings()

    var isSocial: Bool { if case .social = selection { true } else { false } }
```

Keep the existing `preset` property, driven from `selection` when it's `.social`, so the crop stage and `willNotUpscale` keep working untouched.

Selecting `.saved(p)` sets `settings = p.settings` and `selection = .format(p.settings.format)` semantics — i.e. a saved preset is a way to *load* settings, and the dropdown then shows the saved name until a control is touched.

- [ ] **Step 3: Sectioned dropdown**

Replace `presetPicker`'s flat `ForEach` with:

```swift
            Picker("", selection: pickerBinding) {
                Section("Format") {
                    ForEach(ExportFormat.available, id: \.self) { f in
                        Text(f.displayName).tag(PickerTag.format(f))
                    }
                }
                Section("Social") {
                    ForEach(SocialPreset.all) { p in
                        Text(String(localized: String.LocalizationValue(p.nameKey)))
                            .tag(PickerTag.social(p.id))
                    }
                }
                if !presetStore.presets.isEmpty {
                    Section("My Presets") {
                        ForEach(presetStore.presets) { p in
                            Text(p.name).tag(PickerTag.saved(p.id))
                        }
                    }
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .accessibilityLabel(Text("Export preset"))
```

`PickerTag` is a small `Hashable` enum (`.format(ExportFormat)`, `.social(String)`, `.saved(UUID)`) so tags stay comparable; `pickerBinding` maps it to and from `Selection`.

- [ ] **Step 4: Format controls**

In `controls`, branch: `if model.isSocial { …existing… } else { formatControls }`.

```swift
    private var formatControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            if model.resolvedFormat.supportsQuality {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Quality").font(.system(size: 12)).foregroundStyle(.secondary)
                    Slider(value: $model.settings.quality, in: 0.3...1.0)
                        .accessibilityLabel(Text("Quality"))
                }
            }
            if model.resolvedFormat.supportsBitDepth {
                Picker("", selection: $model.settings.tiff16) {
                    Text("8-bit").tag(false)
                    Text("16-bit").tag(true)
                }
                .pickerStyle(.segmented).labelsHidden()
                .accessibilityLabel(Text("Bit depth"))
            }
            resizeControls
            exifToggle
        }
    }
```

`resizeControls` is a `.menu` `Picker` over `Original size` / `Long edge` / `Fit within`, with `TextField`s bound to integer state that appear only for the latter two. Clamp entered values to `1...100_000` on commit so a pasted nonsense number can't reach the renderer.

- [ ] **Step 5: The two new advisories**

Reuse the slot the social `warningKey` uses:

```swift
    /// Not built by concatenation: a `String(localized:) + name` phrase ships
    /// the name's half untranslated and no grep catches it.
    private var formatAdvisory: String? {
        guard !model.isSocial, let url = model.currentURL else { return nil }
        if ExportFormat.sameAsOriginal.resolved(for: url) == .jpeg,
           model.settings.format == .sameAsOriginal,
           url.pathExtension.lowercased() != "jpg",
           url.pathExtension.lowercased() != "jpeg" {
            return String(localized: "RAW can’t be written back — this exports as JPEG.")
        }
        if model.settings.format == .tiff, model.settings.tiff16,
           EditStackIndex.stackHash(for: url) != nil {
            return String(localized: "This photo has edits, which render at 8-bit — 16-bit adds depth the data doesn’t have.")
        }
        return nil
    }
```

- [ ] **Step 6: Save-as-preset button**

Under the format controls only (never for a social selection — a platform is already a preset):

```swift
            if !model.isSocial {
                ModalButton(title: String(localized: "Save Settings as Preset…")) {
                    model.presetNamePrompt = true
                }
            }
```

Presented as a small inline `TextField` + Save/Cancel row inside the card, not a nested sheet — the card is already a modal and a modal over a modal is where focus goes wrong.

- [ ] **Step 7: Route the export**

`ExportModel.export(to:)` branches:

```swift
            if case .social(let preset) = selection {
                // …the existing SocialRender.Job path, unchanged…
            } else {
                let job = ImageExportRender.Job(sourceURL: url, settings: settings)
                _ = try await Task.detached(priority: .userInitiated) {
                    try ImageExportRender.export(job, to: directory)
                }.value
            }
```

Per-file failures keep collecting into `failures` rather than aborting. Persist `settings` to `AppSettings.lastExportSettings` in `rememberChoices()`.

- [ ] **Step 8: Build, drive it, commit**

```bash
xcodebuild -project Muse/Muse.xcodeproj -scheme Muse -configuration Debug build 2>&1 | tail -3
stat -f "%Sm" <path>/Muse.app/Contents/MacOS/Muse    # must be NOW
```

Open the app, export one JPEG from the grid and one from the editor, confirm the files land. Then:

```bash
./scripts/audit-invariants.sh
git add -A && git commit -m "export: format family in the card"
```

---

## Task 7: Surfaces, strings, docs

**Files:**
- Modify: `Muse/Muse/Views/SelectionMenu.swift:105`, `Muse/Muse/Views/Viewer/ShareButton.swift:35`, `Muse/Muse/Views/ShareCollectionButton.swift:83`
- Modify: `Muse/Muse/Localizable.xcstrings`, `docs/new-build/FEATURE-LEDGER.md`, `CLAUDE.md`

- [ ] **Step 1: Rename the three menu items**

`Button("Export for Social…")` → `Button("Export…")` at all three sites. The editor gets its export from `ShareButton`, which it already hosts (`EditorView.swift:355`) — no fourth edit.

- [ ] **Step 2: Extract and translate**

```bash
xcodebuild -exportLocalizations -project Muse/Muse.xcodeproj \
  -localizationPath /tmp/muse-loc -exportLanguage fr
```

Fill every new French value in `Localizable.xcstrings`. Re-run and confirm **0 untranslated**. Check specifically that `ExportFormat.displayName`, the two advisories and the panel prompt/message came through — those are the `String`-position ones the compiler can't see.

- [ ] **Step 3: Whole unit target**

Run: `xcodebuild -project Muse/Muse.xcodeproj -scheme Muse test -only-testing:MuseTests 2>&1 | tail -6`

Expected: `** TEST SUCCEEDED **`, count up by roughly 30 from 1,811.

- [ ] **Step 4: Release build, warning-free**

Run: `xcodebuild -project Muse/Muse.xcodeproj -scheme Muse -configuration Release build 2>&1 | grep -c "warning:"`

Expected: `0`. This is also the arch check — Release builds both slices, so an Intel-hostile construct surfaces here and nowhere else.

- [ ] **Step 5: Docs and commit**

Add the `FEATURE-LEDGER.md` row (automated / static / runtime columns, runtime = the GUI test plan for this card) and the one-line Polish row in `CLAUDE.md`.

```bash
./scripts/audit-invariants.sh
git add -A && git commit -m "export: one door called Export, localized"
```

---

## Task 8: WebP

Last on purpose. Everything above ships without it; if the dependency turns out badly, `ExportFormat.available` just doesn't list WebP and nothing else changes.

**Files:**
- Modify: `Muse/Muse.xcodeproj` (SPM dependency), `Muse/Muse/Export/Image/WebPEncoder.swift`
- Test: `Muse/MuseTests/ImageExportRenderTests.swift` (add two)

- [ ] **Step 1: Add `libwebp`**

Xcode ▸ File ▸ Add Package Dependencies ▸ `https://github.com/SDWebImage/libwebp-Xcode`. Pin to an exact version. **Link it statically** — an embedded dynamic framework has to be signed, and a stale signed copy in DerivedData is the exact failure that once cost a whole session (`CLAUDE.md`). Confirm in the target's Frameworks phase that it is not embedded.

- [ ] **Step 2: Write the failing tests**

```swift
    func testWebPExportProducesAWebPFile() throws {
        try XCTSkipUnless(WebPEncoder.isAvailable)
        let src = try SocialFixtures.makeJPEG(width: 800, height: 600,
                                              name: "towebp", in: dir)
        let job = ImageExportRender.Job(sourceURL: src,
                                        settings: ExportSettings(format: .webp))
        let result = try ImageExportRender.export(job, to: dir)
        XCTAssertEqual(result.url.pathExtension, "webp")
        // RIFF....WEBP — check the container, not the extension.
        let head = try Data(contentsOf: result.url).prefix(12)
        XCTAssertEqual(head.prefix(4), Data("RIFF".utf8))
        XCTAssertEqual(head.suffix(4), Data("WEBP".utf8))
    }

    func testWebPRespectsQuality() throws {
        try XCTSkipUnless(WebPEncoder.isAvailable)
        let src = try SocialFixtures.makeJPEG(width: 1200, height: 900,
                                              content: .noise, name: "q", in: dir)
        let low = try ImageExportRender.export(
            .init(sourceURL: src, settings: ExportSettings(format: .webp, quality: 0.3)), to: dir)
        let high = try ImageExportRender.export(
            .init(sourceURL: src, settings: ExportSettings(format: .webp, quality: 0.95)), to: dir)
        XCTAssertLessThan(low.bytes, high.bytes)
    }
```

- [ ] **Step 3: Implement the encoder**

```swift
import Foundation
import CoreGraphics
import libwebp

nonisolated enum WebPEncoder {
    static var isAvailable: Bool { true }

    /// Encodes RGBA8. The pipeline hands us an sRGB CGImage; libwebp wants a
    /// tightly-packed buffer, so the rows are copied through a CGContext rather
    /// than trusting the source's stride.
    static func encode(_ image: CGImage, quality: Double) throws -> Data {
        let w = image.width, h = image.height
        guard w > 0, h > 0 else { throw ExportPipeline.RenderError.encodeFailed }
        let bytesPerRow = w * 4
        var buffer = [UInt8](repeating: 0, count: bytesPerRow * h)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = buffer.withUnsafeMutableBytes({ raw in
                  CGContext(data: raw.baseAddress, width: w, height: h,
                            bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                            space: space,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
              })
        else { throw ExportPipeline.RenderError.encodeFailed }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))

        var output: UnsafeMutablePointer<UInt8>?
        let size = buffer.withUnsafeBufferPointer { src -> Int in
            WebPEncodeRGBA(src.baseAddress, Int32(w), Int32(h), Int32(bytesPerRow),
                           Float(max(0, min(1, quality)) * 100), &output)
        }
        guard size > 0, let output else { throw ExportPipeline.RenderError.encodeFailed }
        defer { WebPFree(output) }
        return Data(bytes: output, count: size)
    }
}
```

- [ ] **Step 4: Run the tests**

Run: `xcodebuild -project Muse/Muse.xcodeproj -scheme Muse test -only-testing:MuseTests/ImageExportRenderTests -only-testing:MuseTests/ExportFormatTests 2>&1 | tail -5`

Expected: `** TEST SUCCEEDED **`, with the two WebP tests running rather than skipping.

- [ ] **Step 5: Release build — the arch gate**

Run: `xcodebuild -project Muse/Muse.xcodeproj -scheme Muse -configuration Release build 2>&1 | tail -3`
Then: `lipo -archs <path>/Muse.app/Contents/MacOS/Muse`

Expected: `x86_64 arm64`. A Debug build compiles one slice and would hide a dependency that only builds for the host arch — Intel Macs must keep working.

- [ ] **Step 6: Commit**

```bash
./scripts/audit-invariants.sh
git add -A && git commit -m "export: WebP via libwebp"
```

---

## Self-review

**Spec coverage.** §4 surfaces → Task 7. §5 UI (dropdown, controls, advisories, no-filename, no-destination) → Task 6. §6 data model → Tasks 2 and 5. §7 shared core → Task 1; `ImageExportRender` → Task 3; 16-bit → Task 4; WebP → Task 8. §8 errors → Task 3 (`ExportPipeline.RenderError`) and Task 6 (collected failures). §9 localization → Task 7 step 2. §10 testing → each task's tests plus Task 7's full run. §11 no migrations → nothing to do, asserted by the absence of any `Database/` file in the table. §12 risks → each has a step (social tests at every stage, `OUT-1` re-run, WebP sequenced last, controls split noted in Task 6).

**Placeholders.** None: every code step carries the code, every test step carries the assertions, every run step carries the command and the expected output.

**Type consistency.** `ExportSettings` fields (`format`, `quality`, `tiff16`, `resize`, `includeEXIF`, `includeLocation`) are identical in Tasks 2, 3, 5 and 6. `ImageExportRender.Job(sourceURL:settings:)` matches between Task 3's definition and Tasks 6 and 8's use. `ExportPipeline.load(url:decodeLongEdgeMax:)`, `headerSize(url:)`, `scale(_:to:)`, `collisionSafeURL(base:ext:in:)` match between Task 1 and Task 3. `WebPEncoder.isAvailable`/`encode(_:quality:)` match between the Task 2 stub and the Task 8 implementation. `ExportPresetStore.save/delete/rename/reload` match between Tasks 5 and 6.

One gap found and fixed while reviewing: Task 1's `ExportPipeline.load` needs the caller to know the source size *before* choosing a decode ceiling, which the original draft didn't provide — `headerSize(url:)` was added, and Task 3 uses it.
