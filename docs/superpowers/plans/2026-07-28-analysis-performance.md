# Analysis Performance Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make Muse's automatic analysis pass fast on large images (scanner TIFFs, RAW) and on large libraries, without changing what it produces — except for one colour-correctness fix that is called out explicitly.

**Architecture:** Six independent changes to the analysis pipeline. The load-bearing one is bounding the raster handed to Vision (a 115 MP scan currently decodes at full resolution and takes 111 seconds; bounded it takes under a second with identical results). The rest remove a duplicate decode, fix an unmanaged colour space, parallelize a serial loop, replace an all-pairs scalar cosine with a tiled BLAS matmul, and make the thumbnail concurrency gate size-aware.

**Tech Stack:** Swift 6, SwiftUI, ImageIO, Vision, CoreImage, Accelerate (vDSP + BLAS), GRDB, XCTest.

**Spec:** `docs/superpowers/specs/2026-07-28-analysis-performance-design.md` — read it first. It carries the measured baseline and the reasoning for two designs that were considered and rejected (OCR probe, incremental clustering).

## Global Constraints

- **Branch:** `feat/next-140`, cut from `main` (`2edd1d9`). Do not rebase onto `feat/next-139`.
- **Min macOS 14.6.** No API newer than that without an availability guard.
- **No new dependencies.** Accelerate and ImageIO are already linked.
- **No network calls.** Nothing in this work touches a network path.
- **`withinDecodeBudget` stays.** It is the decompression-bomb guard at every automatic decode site; bounding the decode does not replace it.
- **GRDB writes are async** — `try await queue.write { }`. Rows insert as `var`.
- **Tests must stay green.** `xcodebuild -scheme Muse test` — 505 tests at branch point. Run in an English host locale (a French override makes `displayName` tests fail by design).
- **No new user-facing strings.** If one becomes necessary, it must be localized per CLAUDE.md and added to `Localizable.xcstrings` for `fr`.
- **Verify in the running app, not only via tests.** Every task's final step includes a real-app check against `~/Desktop/Raw Files` and the scan fixtures.

## Fixtures

Generated during spec work; regenerate with the scripts in the scratchpad if missing.

- `scratchpad/perf/fixtures/scan_20mp.tif`, `scan_65mp.tif`, `scan_115mp.tif` — 16-bit uncompressed TIFFs at scan dimensions (113 / 373 / 659 MB), photographic content, **no text**.
- `scratchpad/perf/fixtures_doc/scan_document.tif` — 5100×6600 16-bit uncompressed TIFF of a page of body text (193 MB). Current pipeline reads **918 characters** from it. This is the regression fixture for OCR.
- `~/Desktop/Raw Files` — seven real RAW files (CR2, DNG, ARW, SRW, 3FR, plus a RAF that cannot be decoded and an MEF that macOS only sees a 144×192 preview of — both expected, see spec D4).
- `scratchpad/perf/Bench.swift` — before/after harness. Re-run after each task.

---

### Task 1: Bound the raster handed to Vision

The headline fix. `VisionServices.loadCGImage` decodes at full resolution via `NSImage(contentsOf:)`; replace with a bounded ImageIO thumbnail at 4096 max pixel.

**Files:**
- Modify: `Muse/Muse/Intelligence/Vision/VisionServices.swift:57-70`
- Test: `Muse/MuseTests/VisionDecodeTests.swift` (create)

**Interfaces:**
- Consumes: `ThumbnailCache.withinDecodeBudget(_:)` (unchanged).
- Produces: `VisionServices.analysisMaxPixel: Int` (= 4096) and `VisionServices.boundedDecode(url:maxPixel:) -> CGImage?`, both `internal static` so tests reach them via `@testable import Muse`. Task 3 calls `boundedDecode`.

- [ ] **Step 1: Write the failing test**

Create `Muse/MuseTests/VisionDecodeTests.swift`:

```swift
import XCTest
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers
@testable import Muse

final class VisionDecodeTests: XCTestCase {

    /// Write a solid-colour TIFF of the given size to a temp URL.
    private func makeTIFF(width: Int, height: Int,
                          rgb: (UInt8, UInt8, UInt8) = (90, 69, 35)) throws -> URL {
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: width, height: height,
                            bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(red: CGFloat(rgb.0) / 255, green: CGFloat(rgb.1) / 255,
                         blue: CGFloat(rgb.2) / 255, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let img = ctx.makeImage()!
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("muse-test-\(UUID().uuidString).tif")
        let dest = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.tiff.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, img, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testBoundedDecodeCapsLongEdge() throws {
        let url = try makeTIFF(width: 6000, height: 3000)
        let img = try XCTUnwrap(VisionServices.boundedDecode(url: url, maxPixel: 4096))
        XCTAssertEqual(max(img.width, img.height), 4096,
                       "long edge must be clamped to maxPixel")
        // Aspect ratio preserved.
        XCTAssertEqual(Double(img.width) / Double(img.height), 2.0, accuracy: 0.01)
    }

    func testBoundedDecodeLeavesSmallImagesAlone() throws {
        let url = try makeTIFF(width: 800, height: 600)
        let img = try XCTUnwrap(VisionServices.boundedDecode(url: url, maxPixel: 4096))
        XCTAssertEqual(img.width, 800)
        XCTAssertEqual(img.height, 600)
    }

    func testBoundedDecodeRefusesDecompressionBomb() throws {
        // Declared pixel count over the 300 MP budget must be refused before decode.
        let url = try makeTIFF(width: 40_000, height: 20_000)   // 800 MP
        XCTAssertNil(VisionServices.boundedDecode(url: url, maxPixel: 4096),
                     "withinDecodeBudget must still reject an over-budget image")
    }

    func testBoundedDecodeReturnsNilForNonImage() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("muse-test-\(UUID().uuidString).txt")
        try "not an image".write(to: url, atomically: true, encoding: .utf8)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        XCTAssertNil(VisionServices.boundedDecode(url: url, maxPixel: 4096))
    }

    func testAnalysisMaxPixelIsFourK() {
        XCTAssertEqual(VisionServices.analysisMaxPixel, 4096)
    }
}
```

Note: `testBoundedDecodeRefusesDecompressionBomb` writes an 800 MP TIFF. Solid-colour TIFF compresses poorly — if the write is slow or fills the disk, reduce to 20000×16000 (320 MP, still over budget) and leave a comment saying why the number is what it is.

- [ ] **Step 2: Run the tests to verify they fail**

```bash
xcodebuild -scheme Muse -destination 'platform=macOS' \
  -only-testing:MuseTests/VisionDecodeTests test 2>&1 | tail -30
```

Expected: FAIL — `VisionServices.boundedDecode` and `analysisMaxPixel` do not exist.

- [ ] **Step 3: Implement**

In `VisionServices.swift`, replace the `loadCGImage` block (lines 57–70) with:

```swift
    // MARK: - CGImage loader

    /// Longest edge, in pixels, of the raster handed to the Vision requests.
    ///
    /// Measured (see the 2026-07-28 analysis-performance spec): every request's
    /// output is unchanged between 2048 and full resolution, while full
    /// resolution costs 111 SECONDS and ~1 GB of peak memory on a 115 MP scan
    /// vs well under a second at 4096. 4096 rather than 2048 because the extra
    /// decode is ~200 ms and it leaves headroom for documents with dense text:
    /// at 1024 a 5100x6600 document scan lost 25% of its OCR characters, at
    /// 2048 and 4096 it matched full resolution exactly (918 chars).
    static let analysisMaxPixel = 4096

    /// Decode `url` downsampled so its longest edge is at most `maxPixel`.
    ///
    /// ImageIO downsamples during decode where the format allows it, and never
    /// materializes more than it must. The decompression-bomb guard still runs
    /// FIRST: a tiny file can declare enormous dimensions, and for formats
    /// ImageIO cannot stream-downsample (PNG/TIFF/BMP) even a thumbnail request
    /// materializes the full raster, so the header check is what stands between
    /// an automatic no-click analyze pass and an OOM.
    static func boundedDecode(url: URL, maxPixel: Int) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              ThumbnailCache.withinDecodeBudget(src) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(src, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ] as CFDictionary)
    }

    private static func loadCGImage(url: URL) async -> CGImage? {
        await Task.detached(priority: .userInitiated) {
            boundedDecode(url: url, maxPixel: analysisMaxPixel)
        }.value
    }
```

`import AppKit` is now unused by this file only if nothing else in it needs AppKit — check before removing it; leave it if anything else references `NS*`.

- [ ] **Step 4: Run the tests to verify they pass**

```bash
xcodebuild -scheme Muse -destination 'platform=macOS' \
  -only-testing:MuseTests/VisionDecodeTests test 2>&1 | tail -20
```

Expected: PASS, 5 tests.

- [ ] **Step 5: Verify the speedup and the no-regression claim with the harness**

```bash
cd scratchpad/perf
swift Bench.swift ./fixtures/scan_115mp.tif ./fixtures_doc/scan_document.tif
```

Expected, from the spec's baseline table:
- `scan_115mp.tif`: CURRENT ~111,000 ms; the bounded path under 1,000 ms.
- `scan_document.tif`: OCR character count must be **918** on the bounded path — the same as CURRENT. If it is lower, the raster is too small; stop and re-run `Sweep.swift` before proceeding.

- [ ] **Step 6: Verify in the running app**

Build and run. Add `scratchpad/perf/fixtures` as a folder. Confirm:
- Analysis of the three scan TIFFs completes in seconds, not minutes.
- The app stays responsive throughout (no beachball).
- Tags appear on all three tiles.

- [ ] **Step 7: Full suite + commit**

```bash
xcodebuild -scheme Muse -destination 'platform=macOS' test 2>&1 | tail -5
git add Muse/Muse/Intelligence/Vision/VisionServices.swift Muse/MuseTests/VisionDecodeTests.swift
git commit -m "perf: bound the raster handed to Vision (111s -> <1s on a 115MP scan)

VisionServices.loadCGImage decoded at full resolution via NSImage(contentsOf:),
then handed that raster to five concurrent Vision requests. Only feature print
downsamples internally; classify, faces, OCR and CIAreaAverage all scale with
input pixels, so a 115 MP scanner TIFF cost 111 SECONDS and ~1 GB peak memory
per file against a strictly serial analyze loop.

Decode is now bounded to a 4096px long edge via CGImageSourceCreateThumbnailAtIndex.
Measured identical output (same labels, feature print, dominant colour, face
count, and 918/918 OCR characters on a document scan) at 1/148th the time.
withinDecodeBudget still runs first as the decompression-bomb guard.

Spec: docs/superpowers/specs/2026-07-28-analysis-performance-design.md"
```

---

### Task 2: Extract colour in sRGB, not whatever the decoder returned

A correctness fix, not a performance one — see spec D3. `dominantColor` renders through CoreImage with colour management explicitly disabled, so RAW files (which decode as ITU-R 2100 PQ) currently produce wrong hex values.

**Files:**
- Modify: `Muse/Muse/Intelligence/Vision/VisionServices.swift` (`dominantColor`)
- Modify: `Muse/Muse/Intelligence/Core/PaletteExtractor.swift` (`downsampledRGB`)
- Test: `Muse/MuseTests/ColorSpaceTests.swift` (create)

**Interfaces:**
- Produces: `VisionServices.dominantColorHex(cgImage:) -> String?` (renamed from the private `dominantColor` and made `internal static` for testing). Signature and return format (`"#rrggbb"`) are unchanged.

- [ ] **Step 1: Write the failing test**

Create `Muse/MuseTests/ColorSpaceTests.swift`:

```swift
import XCTest
import CoreGraphics
@testable import Muse

final class ColorSpaceTests: XCTestCase {

    /// A solid image of one colour, tagged with the given colour space.
    private func solid(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat,
                       space: CGColorSpace) -> CGImage {
        let ctx = CGContext(data: nil, width: 64, height: 64,
                            bitsPerComponent: 8, bytesPerRow: 0, space: space,
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(red: r, green: g, blue: b, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        return ctx.makeImage()!
    }

    private func hexToRGB(_ hex: String) -> (Int, Int, Int)? {
        var s = hex
        guard s.hasPrefix("#") else { return nil }
        s.removeFirst()
        guard s.count == 6, let v = Int(s, radix: 16) else { return nil }
        return ((v >> 16) & 0xff, (v >> 8) & 0xff, v & 0xff)
    }

    func testDominantColorOfSRGBImageIsThatColor() throws {
        let img = solid(0.5, 0.25, 0.75, space: CGColorSpace(name: CGColorSpace.sRGB)!)
        let hex = try XCTUnwrap(VisionServices.dominantColorHex(cgImage: img))
        let (r, g, b) = try XCTUnwrap(hexToRGB(hex))
        XCTAssertEqual(r, 128, accuracy: 3)
        XCTAssertEqual(g, 64, accuracy: 3)
        XCTAssertEqual(b, 191, accuracy: 3)
    }

    /// The regression this task exists for: the same VISUAL colour authored in a
    /// wide-gamut space must yield (close to) the same sRGB hex. Before the fix
    /// the component values were read unmanaged, so P3 and sRGB disagreed badly.
    func testDominantColorConvertsWideGamutToSRGB() throws {
        let p3 = CGColorSpace(name: CGColorSpace.displayP3)!
        // Pure P3 red is OUTSIDE sRGB; it must clamp toward sRGB red (255,0,0),
        // not be reinterpreted as if its components were already sRGB.
        let img = solid(1.0, 0.0, 0.0, space: p3)
        let hex = try XCTUnwrap(VisionServices.dominantColorHex(cgImage: img))
        let (r, g, b) = try XCTUnwrap(hexToRGB(hex))
        XCTAssertGreaterThan(r, 240, "P3 red must map to near-max sRGB red")
        XCTAssertLessThan(g, 60)
        XCTAssertLessThan(b, 60)
    }

    func testMidGrayRoundTripsAcrossSpaces() throws {
        let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
        let p3 = CGColorSpace(name: CGColorSpace.displayP3)!
        // Neutral grey is identical in both spaces, so both must give the same hex.
        let a = try XCTUnwrap(VisionServices.dominantColorHex(cgImage: solid(0.5, 0.5, 0.5, space: srgb)))
        let b = try XCTUnwrap(VisionServices.dominantColorHex(cgImage: solid(0.5, 0.5, 0.5, space: p3)))
        let (ar, _, _) = try XCTUnwrap(hexToRGB(a))
        let (br, _, _) = try XCTUnwrap(hexToRGB(b))
        XCTAssertEqual(ar, br, accuracy: 4, "neutral grey must not depend on the tagged space")
    }
}
```

- [ ] **Step 2: Run to verify failure**

```bash
xcodebuild -scheme Muse -destination 'platform=macOS' \
  -only-testing:MuseTests/ColorSpaceTests test 2>&1 | tail -30
```

Expected: FAIL — `dominantColorHex` does not exist; once it does, `testDominantColorConvertsWideGamutToSRGB` and `testMidGrayRoundTripsAcrossSpaces` fail on the unmanaged render.

- [ ] **Step 3: Implement**

In `VisionServices.swift`, replace the `dominantColor` function with:

```swift
    // MARK: - Dominant color

    /// Average colour as `#rrggbb`, computed **in sRGB**.
    ///
    /// This used to render with `workingColorSpace: NSNull()` and
    /// `colorSpace: nil` — i.e. no colour management at all — which read raw
    /// component values in whatever space the decoder happened to return. RAW
    /// files decode as ITU-R 2100 PQ (an HDR space), so every RAW file's stored
    /// dominant colour was wrong, and that feeds colour tags and colour search.
    /// Pinning the render to sRGB makes the result both correct and consistent
    /// across formats. Don't drop the colour spaces back to nil/NSNull.
    static func dominantColorHex(cgImage: CGImage) -> String? {
        let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
        let ci = CIImage(cgImage: cgImage)
        guard let filter = CIFilter(name: "CIAreaAverage") else { return nil }
        filter.setValue(ci, forKey: kCIInputImageKey)
        filter.setValue(CIVector(cgRect: ci.extent), forKey: kCIInputExtentKey)
        guard let out = filter.outputImage else { return nil }
        var bitmap = [UInt8](repeating: 0, count: 4)
        let context = CIContext(options: [.workingColorSpace: srgb])
        context.render(out,
                       toBitmap: &bitmap,
                       rowBytes: 4,
                       bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                       format: .RGBA8,
                       colorSpace: srgb)
        return String(format: "#%02x%02x%02x", bitmap[0], bitmap[1], bitmap[2])
    }

    private static func dominantColor(cgImage: CGImage) async -> String? {
        await Task.detached(priority: .userInitiated) {
            dominantColorHex(cgImage: cgImage)
        }.value
    }
```

In `PaletteExtractor.swift`, change the drawing context's colour space so the palette is pinned to the same space. Replace `space: CGColorSpaceCreateDeviceRGB()` in `downsampledRGB` with:

```swift
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
```

and add above the `CGContext` construction:

```swift
        // sRGB (not DeviceRGB) so the palette matches dominantColorHex and does
        // not vary with whatever space the decoder tagged the source with.
        // DeviceRGB is unspecified-by-definition; two files could yield
        // different hexes for the same visual colour.
```

- [ ] **Step 4: Run to verify pass**

```bash
xcodebuild -scheme Muse -destination 'platform=macOS' \
  -only-testing:MuseTests/ColorSpaceTests test 2>&1 | tail -20
```

Expected: PASS, 3 tests.

- [ ] **Step 5: Check the existing colour suites still pass**

Colour search and colour tagging have their own tests that may encode old values.

```bash
xcodebuild -scheme Muse -destination 'platform=macOS' \
  -only-testing:MuseTests/ColorDistanceTests \
  -only-testing:MuseTests/ColorQueryTests \
  -only-testing:MuseTests/ColorTaggerTests \
  -only-testing:MuseTests/NamedColorTests \
  -only-testing:MuseTests/PaletteExtractorTests \
  -only-testing:MuseTests/PaletteMatchTests \
  -only-testing:MuseTests/HeroPaletteTests test 2>&1 | tail -20
```

Expected: PASS. `PaletteExtractorTests` only exercises the pure k-means functions (`kmeansHex`/`kmeansWeighted`) on hand-built pixel arrays, so it is untouched by the colour-space change. The others operate on hex strings and distance math. If any of them fails, it is a real signal — investigate rather than adjust.

If a test fails on a changed hex: confirm by hand that the NEW value is the correct sRGB rendering of that fixture before updating the expectation. Do not update an expectation just to make it green — the point of this task is that the old values were wrong, so each change must be individually justified in the commit message.

- [ ] **Step 6: Verify in the running app**

Run, open `~/Desktop/Raw Files`, force a re-analysis (File → Regenerate Tags after deleting tags, or delete `muse.sqlite` and re-index). Confirm RAW files' colour swatches in the hero viewer's Colors card look like the actual photograph. Before this fix the CR2's dominant colour was `#4a3c44` (dark mauve) for an image whose bounded-decode average is `#67555a`.

- [ ] **Step 7: Full suite + commit**

```bash
xcodebuild -scheme Muse -destination 'platform=macOS' test 2>&1 | tail -5
git add Muse/Muse/Intelligence/Vision/VisionServices.swift \
        Muse/Muse/Intelligence/Core/PaletteExtractor.swift \
        Muse/MuseTests/ColorSpaceTests.swift
git commit -m "fix: extract colour in sRGB instead of unmanaged component values

dominantColor rendered with workingColorSpace: NSNull() and colorSpace: nil, so
it read whatever space the decoder returned as if it were sRGB. RAW files decode
as ITU-R 2100 PQ, so every RAW file's dominant_color was wrong — and that feeds
colour tags and colour search. PaletteExtractor drew into DeviceRGB, which is
unspecified by definition and varies per file.

Both are now pinned to sRGB. RAW colour values change on re-analysis; the new
values are correct.

Spec: docs/superpowers/specs/2026-07-28-analysis-performance-design.md (D3)"
```

---

### Task 3: Decode each file once, not twice

`VisionTagger` calls `PaletteExtractor.weightedPalette(for: url)`, which opens and decodes the file a second time. Measured at 851 ms on the 115 MP fixture. Pass the already-decoded image through instead.

**Files:**
- Modify: `Muse/Muse/Intelligence/Vision/VisionServices.swift` (`VisionResult`, `analyze`)
- Modify: `Muse/Muse/Intelligence/Core/PaletteExtractor.swift`
- Modify: `Muse/Muse/Intelligence/Core/VisionTagger.swift:21`
- Test: `Muse/MuseTests/PaletteFromImageTests.swift` (create)

**Interfaces:**
- Consumes: `VisionServices.boundedDecode` (Task 1), sRGB palette context (Task 2).
- Produces:
  - `PaletteExtractor.weightedPalette(image: CGImage, k: Int = 5) -> [(String, Double)]` — new image-taking overload.
  - `PaletteExtractor.downsampledRGB(image: CGImage) -> [(Double, Double, Double)]?` — `internal static`, used by the above and by tests.
  - `VisionResult.decodedImage: CGImage?` — the raster `analyze` used, so the caller can reuse it.
  - The existing `weightedPalette(for url: URL, k: Int)` stays, delegating to the new overload.

**On keeping the URL overload:** `VisionTagger:21` is its **only** production caller, so after this task it has none. (`HeroPalette` looks like a caller but is not — it has its own independent `quickPalette`/`paletteHexes` path for the hero backdrop wash.) It is kept deliberately, for one reason: it is the reference implementation the equivalence test compares the new image overload against. Do not delete it without also rewriting `testImageOverloadMatchesURLOverload`, which is the only thing proving this refactor is faithful.

- [ ] **Step 1: Write the failing test**

Create `Muse/MuseTests/PaletteFromImageTests.swift`:

```swift
import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import Muse

final class PaletteFromImageTests: XCTestCase {

    /// Half red, half blue — a deterministic two-cluster palette.
    private func twoTone() -> CGImage {
        let ctx = CGContext(data: nil, width: 64, height: 64,
                            bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: 64, height: 32))
        ctx.setFillColor(red: 0, green: 0, blue: 1, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 32, width: 64, height: 32))
        return ctx.makeImage()!
    }

    private func writeTIFF(_ img: CGImage) throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("muse-pal-\(UUID().uuidString).tif")
        let dest = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.tiff.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, img, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    /// The whole point: the image overload must agree with the URL overload.
    func testImageOverloadMatchesURLOverload() throws {
        let img = twoTone()
        let url = try writeTIFF(img)
        let fromURL = PaletteExtractor.weightedPalette(for: url)
        let fromImage = PaletteExtractor.weightedPalette(image: img)
        XCTAssertFalse(fromImage.isEmpty)
        XCTAssertEqual(fromURL.count, fromImage.count)
        for (a, b) in zip(fromURL, fromImage) {
            XCTAssertEqual(a.0, b.0, "hex must match between overloads")
            XCTAssertEqual(a.1, b.1, accuracy: 0.02, "share must match between overloads")
        }
    }

    func testTwoToneImageYieldsBothColors() {
        let out = PaletteExtractor.weightedPalette(image: twoTone())
        let hexes = out.map { $0.0 }
        XCTAssertTrue(hexes.contains { $0.hasPrefix("#f") || $0.hasPrefix("#e") },
                      "expected a red-ish cluster, got \(hexes)")
        XCTAssertTrue(hexes.contains { $0.hasSuffix("ff") || $0.hasSuffix("fe") },
                      "expected a blue-ish cluster, got \(hexes)")
    }

    func testDownsampledRGBFromImageReturnsPixels() throws {
        let px = try XCTUnwrap(PaletteExtractor.downsampledRGB(image: twoTone()))
        XCTAssertFalse(px.isEmpty)
        for p in px {
            XCTAssertTrue((0...1).contains(p.0))
            XCTAssertTrue((0...1).contains(p.1))
            XCTAssertTrue((0...1).contains(p.2))
        }
    }
}
```

- [ ] **Step 2: Run to verify failure**

```bash
xcodebuild -scheme Muse -destination 'platform=macOS' \
  -only-testing:MuseTests/PaletteFromImageTests test 2>&1 | tail -30
```

Expected: FAIL — no `weightedPalette(image:)` / `downsampledRGB(image:)`.

- [ ] **Step 3: Implement `PaletteExtractor` overloads**

In `PaletteExtractor.swift`, replace `weightedPalette(for:)` and `downsampledRGB(for:)` with:

```swift
    /// Downsample an image to ~32x32 and extract its palette as (hex, share),
    /// sorted by share descending. The stored palette is `map { $0.0 }`; color
    /// tagging uses the shares (see `ColorTagger`).
    static func weightedPalette(for url: URL, k: Int = 5) -> [(String, Double)] {
        guard let pixels = downsampledRGB(for: url) else { return [] }
        return kmeansWeighted(pixels: pixels, k: k, seed: 7)
    }

    /// As above, from an ALREADY-DECODED image. The analyze pass decodes the
    /// file once for Vision and reuses that raster here — decoding a second
    /// time cost 851 ms on a 115 MP scan and produced the same answer.
    static func weightedPalette(image: CGImage, k: Int = 5) -> [(String, Double)] {
        guard let pixels = downsampledRGB(image: image) else { return [] }
        return kmeansWeighted(pixels: pixels, k: k, seed: 7)
    }

    /// Decode an image, downsample to ~32x32, and return its RGB pixels in a
    /// known layout. Backs `weightedPalette(for:)`.
    private static func downsampledRGB(for url: URL) -> [(Double, Double, Double)]? {
        // Decompression-bomb guard: palette extraction runs AUTOMATICALLY on
        // index of a freshly-added file (the same no-click trigger the grid
        // thumbnail guard closes), and this thumbnail request materializes the
        // full raster for PNG/TIFF/BMP just like `imageIOThumbnail` — so refuse
        // an absurd declared pixel count before decoding.
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              ThumbnailCache.withinDecodeBudget(src),
              let thumb = CGImageSourceCreateThumbnailAtIndex(src, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceThumbnailMaxPixelSize: 32,
              ] as CFDictionary) else { return nil }
        return downsampledRGB(image: thumb)
    }

    /// Redraw into a known 32x32-max sRGB RGBA layout and read the pixels.
    ///
    /// Reading a thumbnail's raw dataProvider assumed R,G,B at bytes 0,1,2 —
    /// ImageIO thumbnails are typically BGRA, which swapped red and blue in
    /// every palette. sRGB (not DeviceRGB) so the result matches
    /// `VisionServices.dominantColorHex` and doesn't vary with the space the
    /// decoder tagged the source with.
    static func downsampledRGB(image: CGImage) -> [(Double, Double, Double)]? {
        // Cap the working size so a full-resolution raster (the analyze path
        // now passes one straight in) still costs the same ~32x32 k-means.
        let longest = max(image.width, image.height)
        let scale = longest > 32 ? 32.0 / Double(longest) : 1.0
        let w = max(1, Int((Double(image.width) * scale).rounded()))
        let h = max(1, Int((Double(image.height) * scale).rounded()))

        var data = [UInt8](repeating: 0, count: w * h * 4)
        let drew = data.withUnsafeMutableBytes { buf -> Bool in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h,
                                      bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            ctx.interpolationQuality = .medium
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drew else { return nil }
        var px: [(Double, Double, Double)] = []
        px.reserveCapacity(w * h)
        for o in stride(from: 0, to: data.count, by: 4) {
            px.append((Double(data[o]) / 255, Double(data[o + 1]) / 255, Double(data[o + 2]) / 255))
        }
        return px
    }
```

`PaletteExtractor.swift` needs `import CoreGraphics` (already present) and `import ImageIO` (already present).

- [ ] **Step 4: Run the palette tests to verify pass**

```bash
xcodebuild -scheme Muse -destination 'platform=macOS' \
  -only-testing:MuseTests/PaletteFromImageTests test 2>&1 | tail -20
```

Expected: PASS, 3 tests.

- [ ] **Step 5: Thread the decoded image through to the tagger**

In `VisionServices.swift`, add to `VisionResult`:

```swift
    /// The (bounded) raster the pipeline decoded. Callers reuse it instead of
    /// decoding the file a second time. nil when the image couldn't be loaded.
    var decodedImage: CGImage?
```

and in `analyze(url:)`, after the guard:

```swift
        result.decodedImage = cgImage
```

In `VisionTagger.swift`, replace line 21:

```swift
        let weighted = PaletteExtractor.weightedPalette(for: url)
```

with:

```swift
        // Reuse the raster VisionServices already decoded — a second decode of
        // the same file cost 851 ms on a 115 MP scan for an identical answer.
        // Fall back to the URL path only if the image somehow didn't survive
        // (it always should; `v.width != nil` above already proves it decoded).
        let weighted = v.decodedImage.map { PaletteExtractor.weightedPalette(image: $0) }
            ?? PaletteExtractor.weightedPalette(for: url)
```

- [ ] **Step 6: Verify equivalence with the harness**

```bash
cd scratchpad/perf
swift Bench.swift ./fixtures/scan_115mp.tif "/Users/carlostarrats/Desktop/Raw Files"
```

The `palette-2nd-decode` line should no longer be part of the app's cost. Confirm total per-file time dropped by roughly that amount.

- [ ] **Step 7: Verify in the running app**

Re-analyze `scratchpad/perf/fixtures` and `~/Desktop/Raw Files`. Open a file in the hero viewer and expand the Colors card. Confirm swatches are present, plausible for the image, and that colour tags still attach.

- [ ] **Step 8: Full suite + commit**

```bash
xcodebuild -scheme Muse -destination 'platform=macOS' test 2>&1 | tail -5
git add Muse/Muse/Intelligence/Vision/VisionServices.swift \
        Muse/Muse/Intelligence/Core/PaletteExtractor.swift \
        Muse/Muse/Intelligence/Core/VisionTagger.swift \
        Muse/MuseTests/PaletteFromImageTests.swift
git commit -m "perf: decode each file once per analyze pass, not twice

VisionTagger called PaletteExtractor.weightedPalette(for: url), which opened and
decoded the file a second time — 851 ms on a 115 MP scan, for an answer identical
to the raster VisionServices had just decoded. VisionResult now carries the
decoded image and the palette is computed from it.

Adds PaletteExtractor.weightedPalette(image:) alongside the URL overload (kept:
HeroPalette still decodes by URL). The image overload caps its own working size,
so passing a full raster still costs one ~32x32 k-means."
```

---

### Task 4: Parallelize the analyze loop

`AnalyzePipeline.analyze(folder:)` processes one file at a time. Indexing runs 2-wide and thumbnails 8-wide; analysis runs 1-wide.

**Files:**
- Modify: `Muse/Muse/Intelligence/AnalyzePipeline.swift:265-273`
- Create: `Muse/Muse/Components/AnalyzeProgress.swift`
- Test: `Muse/MuseTests/AnalyzeProgressTests.swift` (create)

**Interfaces:**
- Produces: `AnalyzeProgress` — a pure value type owning the completion accounting, so the concurrency change can't corrupt the "N of M" pill.
  - `init(total: Int)`
  - `mutating func complete() -> (completed: Int, fraction: Double)`
  - `var isFinished: Bool`
- Produces: `AnalyzePipeline.analyzeConcurrency: Int` (= 3).

**Why a separate type:** the current loop derives `completed` and `progress` from the loop INDEX (`idx + 1`). Under concurrency, index order is not completion order, so the pill would jump backwards. The accounting has to become completion-count based, and that logic is worth testing without spinning up Vision.

- [ ] **Step 1: Write the failing test**

Create `Muse/MuseTests/AnalyzeProgressTests.swift`:

```swift
import XCTest
@testable import Muse

final class AnalyzeProgressTests: XCTestCase {

    func testCountsUpMonotonically() {
        var p = AnalyzeProgress(total: 4)
        let a = p.complete(); XCTAssertEqual(a.completed, 1); XCTAssertEqual(a.fraction, 0.25, accuracy: 1e-9)
        let b = p.complete(); XCTAssertEqual(b.completed, 2); XCTAssertEqual(b.fraction, 0.50, accuracy: 1e-9)
        let c = p.complete(); XCTAssertEqual(c.completed, 3); XCTAssertEqual(c.fraction, 0.75, accuracy: 1e-9)
        let d = p.complete(); XCTAssertEqual(d.completed, 4); XCTAssertEqual(d.fraction, 1.00, accuracy: 1e-9)
        XCTAssertTrue(p.isFinished)
    }

    /// The bug this type exists to prevent: with a concurrent loop, completion
    /// order is not index order. Progress must never go backwards.
    func testNeverExceedsTotalOrGoesBackwards() {
        var p = AnalyzeProgress(total: 3)
        var seen: [Double] = []
        for _ in 0..<10 { seen.append(p.complete().fraction) }
        XCTAssertEqual(seen, seen.sorted(), "fraction must be monotonically non-decreasing")
        XCTAssertLessThanOrEqual(seen.max() ?? 0, 1.0, "fraction must never exceed 1")
        XCTAssertEqual(p.complete().completed, 3, "completed must clamp at total")
    }

    func testZeroTotalIsFinishedAndSafe() {
        var p = AnalyzeProgress(total: 0)
        XCTAssertTrue(p.isFinished)
        let r = p.complete()
        XCTAssertEqual(r.completed, 0)
        XCTAssertEqual(r.fraction, 0, accuracy: 1e-9, "no division by zero")
    }

    func testNegativeTotalIsTreatedAsZero() {
        var p = AnalyzeProgress(total: -5)
        XCTAssertTrue(p.isFinished)
        XCTAssertEqual(p.complete().fraction, 0, accuracy: 1e-9)
    }
}
```

- [ ] **Step 2: Run to verify failure**

```bash
xcodebuild -scheme Muse -destination 'platform=macOS' \
  -only-testing:MuseTests/AnalyzeProgressTests test 2>&1 | tail -30
```

Expected: FAIL — no such type.

- [ ] **Step 3: Implement `AnalyzeProgress`**

Create `Muse/Muse/Components/AnalyzeProgress.swift`:

```swift
//
//  AnalyzeProgress.swift
//  Muse
//
//  Completion accounting for the analyze pass.
//
//  The pass used to be a serial `for (idx, pair) in pairs.enumerated()` loop
//  that derived progress from the loop INDEX. Under a concurrent loop, index
//  order is not completion order, so an index-derived fraction jumps backwards
//  whenever a later-started file finishes first. This type counts COMPLETIONS
//  instead, and clamps, so the pill can only ever move forward.
//

import Foundation

struct AnalyzeProgress {
    let total: Int
    private(set) var completed: Int = 0

    init(total: Int) {
        self.total = max(0, total)
    }

    var isFinished: Bool { completed >= total }

    /// Record one finished file. Returns the new count and the 0...1 fraction.
    /// Safe to over-call: both outputs clamp at `total`.
    @discardableResult
    mutating func complete() -> (completed: Int, fraction: Double) {
        completed = min(total, completed + 1)
        let fraction = total > 0 ? Double(completed) / Double(total) : 0
        return (completed, fraction)
    }
}
```

- [ ] **Step 4: Run to verify pass**

```bash
xcodebuild -scheme Muse -destination 'platform=macOS' \
  -only-testing:MuseTests/AnalyzeProgressTests test 2>&1 | tail -20
```

Expected: PASS, 4 tests.

- [ ] **Step 5: Rewrite the loop concurrently**

In `AnalyzePipeline.swift`, add near `analysisMaxPixel`-style constants at the top of the class:

```swift
    /// How many files analyze at once. Vision already parallelizes its five
    /// requests WITHIN one image, so this is deliberately modest — it fills the
    /// gaps between those requests rather than trying to saturate the machine,
    /// and keeps peak memory to a few bounded rasters. Indexing runs 2-wide and
    /// thumbnails 8-wide; analysis ran 1-wide before this.
    static let analyzeConcurrency = 3
```

Replace the loop (lines 265–273) with:

```swift
        // Bounded-concurrency pass. `analyzeOne` is @MainActor and its DB writes
        // serialize on the GRDB queue regardless, so the win is overlapping the
        // off-main Vision work — which is where essentially all the time goes.
        var progress = AnalyzeProgress(total: pairs.count)
        await withTaskGroup(of: Void.self) { group in
            var iterator = pairs.makeIterator()
            var running = 0

            @Sendable func spawn() -> Bool {
                guard !shouldStop, let pair = iterator.next() else { return false }
                group.addTask { @MainActor in
                    await self.analyzeOne(fileID: pair.id, url: pair.url)
                }
                current = pair.url.lastPathComponent
                return true
            }

            while running < Self.analyzeConcurrency, spawn() { running += 1 }
            while await group.next() != nil {
                let step = progress.complete()
                completed = step.completed
                self.progress = step.fraction
                _ = spawn()
            }
        }
```

Notes for the implementer:
- `self.progress` is disambiguated from the local `progress` value — do not rename the `@Published` property.
- `shouldStop` is checked in `spawn()`, so a cancel stops NEW work while in-flight files finish. That matches the old `if shouldStop { break }` semantics (which also let the current file finish).
- `current` is now "most recently started", not "the one file running". That is the honest label under concurrency; leave the pill's "N of M" as the primary signal.
- Do not remove the `isRunning = false; current = ""; ...` reset after the loop, or the `defer` that duplicates it.

- [ ] **Step 6: Verify no double-analysis regression**

The `acquirePass()` gate must still prevent two PASSES overlapping — this task makes files within ONE pass concurrent, which is different. Confirm:

```bash
xcodebuild -scheme Muse -destination 'platform=macOS' \
  -only-testing:MuseTests/AnalyzePipelineTests test 2>&1 | tail -20
```

If no such suite exists, skip — the gate is exercised in the running-app check below.

- [ ] **Step 7: Verify in the running app**

- Add a folder of ~50 images. Confirm the "N of M" pill counts up smoothly and never goes backwards or exceeds M.
- While a pass runs, remove the folder from the sidebar. Confirm the pass stops promptly and the app does not crash (this is the `cancelActivePass` path that historically double-resumed a continuation).
- Confirm total wall-clock for the folder is meaningfully below the pre-change time.

- [ ] **Step 8: Full suite + commit**

```bash
xcodebuild -scheme Muse -destination 'platform=macOS' test 2>&1 | tail -5
git add Muse/Muse/Intelligence/AnalyzePipeline.swift \
        Muse/Muse/Components/AnalyzeProgress.swift \
        Muse/MuseTests/AnalyzeProgressTests.swift
git commit -m "perf: analyze 3 files at a time instead of strictly serially

analyze(folder:) was a plain serial for-loop while indexing ran 2-wide and
thumbnails 8-wide. Now a bounded task group.

Progress accounting moves from the loop INDEX to a completion count
(AnalyzeProgress) — under concurrency, completion order is not index order, so
an index-derived fraction would jump backwards. The pure type is unit-tested for
monotonicity, clamping, and zero/negative totals.

Cancellation semantics preserved: shouldStop halts new spawns, in-flight files
finish, matching the old loop's break."
```

---

### Task 5: Replace the all-pairs scalar cosine with a tiled BLAS matmul

`HybridClusterer.cluster` compares every embedding to every other one, and `VectorMath.cosine` recomputes both vectors' magnitudes on every pair — so each vector's norm is recomputed N times per pass.

**Files:**
- Modify: `Muse/Muse/Intelligence/Core/VectorMath.swift`
- Modify: `Muse/Muse/Intelligence/Core/HybridClusterer.swift`
- Test: `Muse/MuseTests/SimilarityMatrixTests.swift` (create)

**Interfaces:**
- Produces: `VectorMath.normalizedMatrix(_ vectors: [[Float]], dimension: Int) -> [Float]` — row-major `n × dimension`, each row L2-normalized; an all-zero or wrong-length row becomes all zeros (so its similarity to everything is 0, matching `cosine`'s zero-norm guard).
- Produces: `VectorMath.forEachPairAbove(threshold: Double, matrix: [Float], count: Int, dimension: Int, tileRows: Int = 512, _ body: (Int, Int) -> Void)` — invokes `body(i, j)` for every `i < j` whose cosine similarity is `>= threshold`.
- `VectorMath.cosine` is unchanged — `SemanticSearch` still uses it.

- [ ] **Step 1: Write the failing test**

Create `Muse/MuseTests/SimilarityMatrixTests.swift`:

```swift
import XCTest
@testable import Muse

final class SimilarityMatrixTests: XCTestCase {

    private func randomVectors(count: Int, dim: Int, seed: UInt64) -> [[Float]] {
        var rng = seed
        func next() -> Float {
            rng = rng &* 6364136223846793005 &+ 1442695040888963407
            return Float(Int((rng >> 33) % 2000)) / 1000.0 - 1.0   // -1...1
        }
        return (0..<count).map { _ in (0..<dim).map { _ in next() } }
    }

    func testNormalizedRowsAreUnitLength() {
        let vs = randomVectors(count: 5, dim: 8, seed: 11)
        let m = VectorMath.normalizedMatrix(vs, dimension: 8)
        XCTAssertEqual(m.count, 5 * 8)
        for i in 0..<5 {
            let row = Array(m[(i * 8)..<((i + 1) * 8)])
            let norm = row.reduce(0) { $0 + Double($1) * Double($1) }.squareRoot()
            XCTAssertEqual(norm, 1.0, accuracy: 1e-5)
        }
    }

    func testZeroAndWrongLengthRowsBecomeZero() {
        let vs: [[Float]] = [[0, 0, 0, 0], [1, 2], [1, 0, 0, 0]]
        let m = VectorMath.normalizedMatrix(vs, dimension: 4)
        XCTAssertEqual(Array(m[0..<4]), [0, 0, 0, 0], "zero vector stays zero")
        XCTAssertEqual(Array(m[4..<8]), [0, 0, 0, 0], "wrong-length vector is zeroed")
        XCTAssertEqual(Array(m[8..<12]), [1, 0, 0, 0])
    }

    /// The load-bearing test: the fast path must find EXACTLY the pairs the
    /// scalar reference finds. If this ever fails, collections have changed.
    func testMatchesScalarCosineReferenceExactly() {
        let n = 120, dim = 64, threshold = 0.62
        let vs = randomVectors(count: n, dim: dim, seed: 7)

        var expected = Set<String>()
        for i in 0..<n {
            for j in (i + 1)..<n where VectorMath.cosine(vs[i], vs[j]) >= threshold {
                expected.insert("\(i)-\(j)")
            }
        }

        var actual = Set<String>()
        let m = VectorMath.normalizedMatrix(vs, dimension: dim)
        VectorMath.forEachPairAbove(threshold: threshold, matrix: m,
                                    count: n, dimension: dim) { i, j in
            actual.insert("\(i)-\(j)")
        }

        XCTAssertFalse(expected.isEmpty, "fixture must actually produce some pairs")
        XCTAssertEqual(actual, expected)
    }

    /// Tiling must not change the answer — exercise a tile size that does not
    /// divide the row count evenly.
    func testTilingDoesNotChangeResults() {
        let n = 77, dim = 32, threshold = 0.5
        let vs = randomVectors(count: n, dim: dim, seed: 99)
        let m = VectorMath.normalizedMatrix(vs, dimension: dim)

        func pairs(tile: Int) -> Set<String> {
            var s = Set<String>()
            VectorMath.forEachPairAbove(threshold: threshold, matrix: m, count: n,
                                        dimension: dim, tileRows: tile) { i, j in
                s.insert("\(i)-\(j)")
            }
            return s
        }
        XCTAssertEqual(pairs(tile: 512), pairs(tile: 10))
        XCTAssertEqual(pairs(tile: 512), pairs(tile: 1))
        XCTAssertEqual(pairs(tile: 512), pairs(tile: 77))
    }

    func testEmptyAndSingleAreSafe() {
        var called = 0
        VectorMath.forEachPairAbove(threshold: 0.5, matrix: [], count: 0, dimension: 4) { _, _ in called += 1 }
        XCTAssertEqual(called, 0)
        let one = VectorMath.normalizedMatrix([[1, 0, 0, 0]], dimension: 4)
        VectorMath.forEachPairAbove(threshold: 0.5, matrix: one, count: 1, dimension: 4) { _, _ in called += 1 }
        XCTAssertEqual(called, 0, "a single item has no pairs")
    }
}
```

- [ ] **Step 2: Run to verify failure**

```bash
xcodebuild -scheme Muse -destination 'platform=macOS' \
  -only-testing:MuseTests/SimilarityMatrixTests test 2>&1 | tail -30
```

Expected: FAIL — `normalizedMatrix` / `forEachPairAbove` do not exist.

- [ ] **Step 3: Implement the batch similarity API**

Append to `VectorMath.swift`:

```swift
    // MARK: - Batch similarity

    /// Pack `vectors` into a row-major `count x dimension` matrix with every row
    /// L2-normalized, so cosine similarity between two rows is just their dot
    /// product. Rows that are all-zero, empty, or the wrong length become all
    /// zeros — matching `cosine`'s zero-norm and length-mismatch guards, which
    /// both return 0.
    static func normalizedMatrix(_ vectors: [[Float]], dimension: Int) -> [Float] {
        guard dimension > 0 else { return [] }
        var out = [Float](repeating: 0, count: vectors.count * dimension)
        for (i, v) in vectors.enumerated() {
            guard v.count == dimension else { continue }   // leaves zeros
            var sumsq: Float = 0
            vDSP_svesq(v, 1, &sumsq, vDSP_Length(dimension))
            guard sumsq > 0 else { continue }              // leaves zeros
            var inv = 1 / sumsq.squareRoot()
            v.withUnsafeBufferPointer { src in
                out.withUnsafeMutableBufferPointer { dst in
                    vDSP_vsmul(src.baseAddress!, 1, &inv,
                               dst.baseAddress! + i * dimension, 1,
                               vDSP_Length(dimension))
                }
            }
        }
        return out
    }

    /// Call `body(i, j)` for every pair `i < j` whose cosine similarity is at
    /// least `threshold`.
    ///
    /// The similarities come from one `cblas_sgemm` per tile of rows rather than
    /// a scalar loop per pair. The clusterer's old inner loop called `cosine`
    /// once per pair, and `cosine` recomputes BOTH vectors' magnitudes every
    /// time — so each vector's norm was recomputed `count` times per pass.
    /// Normalizing once turns the whole thing into one matrix multiply.
    ///
    /// Tiling keeps the intermediate at `tileRows x count` floats instead of
    /// materializing the full `count x count` matrix (which is 400 MB at 10k
    /// items). `tileRows` only affects memory, never the result.
    static func forEachPairAbove(threshold: Double,
                                 matrix: [Float],
                                 count: Int,
                                 dimension: Int,
                                 tileRows: Int = 512,
                                 _ body: (Int, Int) -> Void) {
        guard count > 1, dimension > 0, matrix.count >= count * dimension else { return }
        let tile = max(1, tileRows)
        let thresholdF = Float(threshold)
        var scratch = [Float](repeating: 0, count: tile * count)

        matrix.withUnsafeBufferPointer { m in
            let base = m.baseAddress!
            var start = 0
            while start < count {
                let rows = min(tile, count - start)
                scratch.withUnsafeMutableBufferPointer { s in
                    // S = A(rows x dim) * B^T(dim x count)  ->  rows x count
                    cblas_sgemm(CblasRowMajor, CblasNoTrans, CblasTrans,
                                Int32(rows), Int32(count), Int32(dimension),
                                1.0,
                                base + start * dimension, Int32(dimension),
                                base, Int32(dimension),
                                0.0,
                                s.baseAddress!, Int32(count))
                    for r in 0..<rows {
                        let i = start + r
                        let rowBase = r * count
                        // Only j > i — the matrix is symmetric.
                        for j in (i + 1)..<count where s[rowBase + j] >= thresholdF {
                            body(i, j)
                        }
                    }
                }
                start += rows
            }
        }
    }
```

`VectorMath.swift` already has `import Accelerate`, which provides both vDSP and BLAS.

- [ ] **Step 4: Run to verify pass**

```bash
xcodebuild -scheme Muse -destination 'platform=macOS' \
  -only-testing:MuseTests/SimilarityMatrixTests test 2>&1 | tail -20
```

Expected: PASS, 5 tests.

If `testMatchesScalarCosineReferenceExactly` fails on a small number of pairs, the cause is Float-vs-Double rounding at the threshold boundary (sgemm accumulates in Float; `cosine` divides in Double). Do NOT paper over it with an epsilon. Instead, widen the fixture (more vectors, different seed) and confirm the disagreement is confined to pairs whose similarity is within ~1e-6 of the threshold; if so, record that in the test as a documented tolerance with an explicit comment. If disagreements are larger than that, the implementation is wrong.

- [ ] **Step 5: Rewire the clusterer**

Replace the pair loop in `HybridClusterer.swift` (lines 19–24):

```swift
        for i in 0..<usable.count {
            for j in (i + 1)..<usable.count {
                let sim = VectorMath.cosine(usable[i].textVector!, usable[j].textVector!)
                if sim >= textThreshold { union(i, j) }
            }
        }
```

with:

```swift
        // One tiled matrix multiply instead of N^2 scalar cosines. Same
        // threshold, same union-find, same clusters — see SimilarityMatrixTests.
        let dimension = usable[0].textVector!.count
        let matrix = VectorMath.normalizedMatrix(usable.map { $0.textVector! },
                                                 dimension: dimension)
        VectorMath.forEachPairAbove(threshold: textThreshold, matrix: matrix,
                                    count: usable.count, dimension: dimension) { i, j in
            union(i, j)
        }
```

- [ ] **Step 6: Pin cluster equivalence end-to-end**

Add to `Muse/MuseTests/SimilarityMatrixTests.swift`:

```swift
    /// End-to-end: the clusterer must produce the same clusters it produced with
    /// the scalar loop. Reference is computed here with the scalar cosine.
    func testClustererMatchesScalarReference() {
        let n = 200, dim = 48
        let vs = randomVectors(count: n, dim: dim, seed: 4242)
        let items = vs.enumerated().map {
            ClusterItem(id: "f\($0.offset)", textVector: $0.element, featurePrint: nil)
        }
        let clusterer = HybridClusterer()

        // Scalar reference: same union-find, same threshold, cosine per pair.
        var parent = Array(0..<n)
        func find(_ i: Int) -> Int {
            var i = i
            while parent[i] != i { parent[i] = parent[parent[i]]; i = parent[i] }
            return i
        }
        for i in 0..<n {
            for j in (i + 1)..<n where VectorMath.cosine(vs[i], vs[j]) >= clusterer.textThreshold {
                parent[find(i)] = find(j)
            }
        }
        var groups: [Int: [String]] = [:]
        for i in 0..<n { groups[find(i), default: []].append("f\(i)") }
        let expected = Set(groups.values
            .filter { $0.count >= clusterer.minClusterSize }
            .map { $0.sorted().joined(separator: ",") })

        let actual = Set(clusterer.cluster(items).map { $0.memberIDs.sorted().joined(separator: ",") })
        XCTAssertEqual(actual, expected)
    }
```

Run it:

```bash
xcodebuild -scheme Muse -destination 'platform=macOS' \
  -only-testing:MuseTests/SimilarityMatrixTests test 2>&1 | tail -20
```

Expected: PASS, 6 tests.

- [ ] **Step 7: Verify in the running app**

Open a library with enough analyzed images to form collections. Confirm the Collections page shows the same collections, with the same members, as before the change. This is the "no silent drift" check the spec's D2 is built around.

- [ ] **Step 8: Full suite + commit**

```bash
xcodebuild -scheme Muse -destination 'platform=macOS' test 2>&1 | tail -5
git add Muse/Muse/Intelligence/Core/VectorMath.swift \
        Muse/Muse/Intelligence/Core/HybridClusterer.swift \
        Muse/MuseTests/SimilarityMatrixTests.swift
git commit -m "perf: cluster via tiled BLAS matmul instead of all-pairs scalar cosine

HybridClusterer compared every embedding to every other one, and VectorMath.cosine
recomputes BOTH vectors' magnitudes on every pair — so each vector's norm was
recomputed N times per pass. At 10k files that is 50M pair comparisons after
every analyze pass.

Vectors are now normalized once (cosine collapses to a dot product) and the dot
products come from one cblas_sgemm per tile of rows. Tiling caps the intermediate
at tileRows x count instead of the full count x count matrix (400 MB at 10k).

Algorithm unchanged: same 0.62 threshold, same single-linkage union-find, same
clusters. Pinned by a test that computes the reference with the scalar cosine and
asserts set equality, at both the pair level and the cluster level.

VectorMath.cosine is untouched — SemanticSearch still uses it.

Spec: docs/superpowers/specs/2026-07-28-analysis-performance-design.md (D2)"
```

---

### Task 6: Stop reclustering when there is nothing new to cluster

`recluster()` runs after every pass, and `analyze(file:)` runs it after every single file.

**Files:**
- Modify: `Muse/Muse/Intelligence/AnalyzePipeline.swift` (`analyzeOne`, `analyze(file:)`, `analyze(folder:)`)
- Modify: `Muse/Muse/Intelligence/Collections/CollectionsEngine.swift` (`recluster`)
- Test: `Muse/MuseTests/ReclusterGateTests.swift` (create)

**Interfaces:**
- Produces: `AnalyzePipeline.embeddingsWritten: Int` — count of embedding rows written by the pass just finished (reset at pass start). `private(set)`, `internal` for tests.
- Produces: `CollectionsEngine.recluster(force: Bool = false)` — `force: true` preserves today's unconditional behavior for the manual/menu path.

- [ ] **Step 1: Write the failing test**

Create `Muse/MuseTests/ReclusterGateTests.swift`:

```swift
import XCTest
@testable import Muse

final class ReclusterGateTests: XCTestCase {

    /// Pure decision: should a finished pass trigger a recluster?
    func testGateSkipsWhenNothingNewWasEmbedded() {
        XCTAssertFalse(ReclusterGate.shouldRecluster(embeddingsWritten: 0, force: false))
    }

    func testGateRunsWhenSomethingWasEmbedded() {
        XCTAssertTrue(ReclusterGate.shouldRecluster(embeddingsWritten: 1, force: false))
        XCTAssertTrue(ReclusterGate.shouldRecluster(embeddingsWritten: 250, force: false))
    }

    func testForceAlwaysRuns() {
        XCTAssertTrue(ReclusterGate.shouldRecluster(embeddingsWritten: 0, force: true))
    }

    func testNegativeCountIsTreatedAsNothing() {
        XCTAssertFalse(ReclusterGate.shouldRecluster(embeddingsWritten: -3, force: false))
    }
}
```

- [ ] **Step 2: Run to verify failure**

```bash
xcodebuild -scheme Muse -destination 'platform=macOS' \
  -only-testing:MuseTests/ReclusterGateTests test 2>&1 | tail -30
```

Expected: FAIL — no `ReclusterGate`.

- [ ] **Step 3: Implement the gate**

Create `Muse/Muse/Components/ReclusterGate.swift`:

```swift
//
//  ReclusterGate.swift
//  Muse
//
//  Whether a finished analyze pass needs to rebuild collections.
//
//  Reclustering reads every embedding in the library and runs single-linkage
//  connected components over all pairs. That cost scales with LIBRARY size, not
//  with how much the pass just added — so a pass that embedded nothing (every
//  file already analyzed, or every file a non-image) used to pay the full
//  rebuild for no possible change in the result.
//

import Foundation

enum ReclusterGate {
    /// `force` is the manual/menu path, which must still rebuild on demand.
    static func shouldRecluster(embeddingsWritten: Int, force: Bool) -> Bool {
        force || embeddingsWritten > 0
    }
}
```

- [ ] **Step 4: Run to verify pass**

```bash
xcodebuild -scheme Muse -destination 'platform=macOS' \
  -only-testing:MuseTests/ReclusterGateTests test 2>&1 | tail -20
```

Expected: PASS, 4 tests.

- [ ] **Step 5: Wire the counter and the gate**

In `AnalyzePipeline.swift`, add a property beside `cancelRequested`:

```swift
    /// Embedding rows written by the pass in flight. Drives the recluster gate:
    /// a pass that embedded nothing cannot change the clustering, and clustering
    /// costs scale with LIBRARY size rather than pass size.
    private(set) var embeddingsWritten = 0
```

In `analyzeOne`, inside the embedding block, after the successful `queue.write`:

```swift
            if let vec = embedder.embed(doc) {
                try? await queue.write { db in
                    var row = EmbeddingRow(file_id: fileID,
                                           vector: VectorMath.toData(vec),
                                           model_version: embedderVersion,
                                           updated_at: Int64(Date().timeIntervalSince1970))
                    try row.save(db)
                }
                embeddingsWritten += 1
            }
```

In `analyze(folder:)`, reset at the start (next to `progress = 0`):

```swift
        embeddingsWritten = 0
```

and change the tail:

```swift
        if shouldStop { return }
        if ReclusterGate.shouldRecluster(embeddingsWritten: embeddingsWritten, force: false) {
            await CollectionsEngine.shared.recluster()
        }
```

In `analyze(file:)`, do the same — reset `embeddingsWritten = 0` after `cancelRequested = false`, and replace the unconditional `await CollectionsEngine.shared.recluster()` with the gated call. This is the path that used to rebuild the whole library after every single file.

In `CollectionsEngine.swift`, change the signature so a future manual caller can force:

```swift
    func recluster(force: Bool = false) async {
```

and leave the body unchanged (the `AppSettings.autoCollections` and `isClustering` guards still apply). The `force` parameter is currently only meaningful to callers; do not add a second gate inside.

- [ ] **Step 6: Verify in the running app**

- Open an already-fully-analyzed folder. Confirm no clustering work happens (the Collections page does not flicker/rebuild, and there is no CPU spike).
- Add one new image to that folder. Confirm clustering DOES run and the new file can join a collection.
- Confirm collections are unchanged from before the task.

- [ ] **Step 7: Full suite + commit**

```bash
xcodebuild -scheme Muse -destination 'platform=macOS' test 2>&1 | tail -5
git add Muse/Muse/Intelligence/AnalyzePipeline.swift \
        Muse/Muse/Intelligence/Collections/CollectionsEngine.swift \
        Muse/Muse/Components/ReclusterGate.swift \
        Muse/MuseTests/ReclusterGateTests.swift
git commit -m "perf: skip the recluster when a pass embedded nothing

recluster() reads every embedding in the library and runs all-pairs connected
components — cost scales with LIBRARY size, not with what the pass added. It ran
after every pass regardless, and analyze(file:) ran it after every SINGLE file.

Passes now count the embedding rows they write and skip the rebuild when that is
zero. ReclusterGate is a pure, tested decision; recluster(force:) keeps an
unconditional path available for manual callers."
```

---

### Task 7: Make the thumbnail gate size-aware

`ThumbnailGate` grants 8 permits regardless of image size, so eight 659 MB scans decode simultaneously on folder open.

**Files:**
- Modify: `Muse/Muse/Filesystem/ThumbnailCache.swift` (gate + `loadOrGenerate`)
- Test: `Muse/MuseTests/DecodePermitTests.swift` (create)

**Interfaces:**
- Produces: `DecodePermit.cost(forDeclaredPixels: Int?, limit: Int) -> Int` — how many of the gate's permits one image should consume, `1...limit`. `nil` pixels (unknown) → 1, so an unreadable header never deadlocks the gate.

- [ ] **Step 1: Write the failing test**

Create `Muse/MuseTests/DecodePermitTests.swift`:

```swift
import XCTest
@testable import Muse

final class DecodePermitTests: XCTestCase {

    func testOrdinaryPhotoCostsOnePermit() {
        // 12 MP phone photo
        XCTAssertEqual(DecodePermit.cost(forDeclaredPixels: 12_000_000, limit: 8), 1)
        // 24 MP RAW
        XCTAssertEqual(DecodePermit.cost(forDeclaredPixels: 24_000_000, limit: 8), 1)
    }

    func testLargeScanCostsMore() {
        let mid = DecodePermit.cost(forDeclaredPixels: 65_000_000, limit: 8)
        let big = DecodePermit.cost(forDeclaredPixels: 115_000_000, limit: 8)
        XCTAssertGreaterThan(mid, 1, "a 65 MP scan must not be treated like a snapshot")
        XCTAssertGreaterThan(big, mid, "cost must grow with pixel count")
    }

    func testCostNeverExceedsLimit() {
        XCTAssertLessThanOrEqual(DecodePermit.cost(forDeclaredPixels: 299_000_000, limit: 8), 8)
        XCTAssertLessThanOrEqual(DecodePermit.cost(forDeclaredPixels: Int.max, limit: 8), 8)
        XCTAssertLessThanOrEqual(DecodePermit.cost(forDeclaredPixels: 115_000_000, limit: 1), 1)
    }

    func testUnknownOrDegenerateSizeCostsOne() {
        XCTAssertEqual(DecodePermit.cost(forDeclaredPixels: nil, limit: 8), 1,
                       "unknown header must not deadlock the gate")
        XCTAssertEqual(DecodePermit.cost(forDeclaredPixels: 0, limit: 8), 1)
        XCTAssertEqual(DecodePermit.cost(forDeclaredPixels: -5, limit: 8), 1)
    }

    func testCostIsAtLeastOne() {
        for px in [1, 1000, 1_000_000, 50_000_000, 200_000_000] {
            XCTAssertGreaterThanOrEqual(DecodePermit.cost(forDeclaredPixels: px, limit: 8), 1)
        }
    }
}
```

- [ ] **Step 2: Run to verify failure**

```bash
xcodebuild -scheme Muse -destination 'platform=macOS' \
  -only-testing:MuseTests/DecodePermitTests test 2>&1 | tail -30
```

Expected: FAIL — no `DecodePermit`.

- [ ] **Step 3: Implement the cost function**

Create `Muse/Muse/Components/DecodePermit.swift`:

```swift
//
//  DecodePermit.swift
//  Muse
//
//  How much of the thumbnail gate's concurrency budget one image consumes.
//
//  The gate granted a flat 8 permits regardless of image size. For formats
//  ImageIO cannot stream-downsample (PNG/TIFF/BMP) even a thumbnail request
//  materializes the FULL raster, so eight 115 MP scanner TIFFs decoding at once
//  is multiple GB of simultaneous rasters on mere folder open — enough to push
//  the machine into swap and make the app look hung.
//
//  Weighting by declared pixel count keeps ordinary photos at full parallelism
//  while letting a few huge scans serialize themselves.
//

import Foundation

enum DecodePermit {
    /// Images at or under this cost one permit — the overwhelming majority.
    static let ordinaryPixels = 30_000_000   // 30 MP: above any consumer camera

    /// Permits one image should hold, clamped to `1...limit`.
    /// `nil`/degenerate pixel counts cost 1 so an unreadable header can never
    /// request more than the gate can ever grant (which would deadlock it).
    static func cost(forDeclaredPixels pixels: Int?, limit: Int) -> Int {
        let cap = max(1, limit)
        guard let pixels, pixels > ordinaryPixels else { return 1 }
        // Linear in units of `ordinaryPixels`: 65 MP -> 2, 115 MP -> 3, 300 MP -> 8 (capped).
        let units = (pixels + ordinaryPixels - 1) / ordinaryPixels
        return min(cap, max(1, units))
    }
}
```

- [ ] **Step 4: Run to verify pass**

```bash
xcodebuild -scheme Muse -destination 'platform=macOS' \
  -only-testing:MuseTests/DecodePermitTests test 2>&1 | tail -20
```

Expected: PASS, 5 tests.

- [ ] **Step 5: Teach the gate to take weighted permits**

In `ThumbnailCache.swift`, change `ThumbnailGate` to acquire/release `n` permits. Replace `available` handling:

```swift
private actor ThumbnailGate {
    private var available: Int
    private let limit: Int
    private struct Waiter {
        let order: Int
        let id: UInt64
        let cost: Int
        let cont: CheckedContinuation<Void, Error>
    }
    private var waiters: [Waiter] = []
    private var nextID: UInt64 = 0
    init(limit: Int) { available = limit; self.limit = limit }

    private func acquire(order: Int, cost: Int) async throws {
        // Clamp so an over-large request can never wait forever.
        let need = min(max(1, cost), limit)
        if available >= need { available -= need; return }
        let id = nextID; nextID += 1
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { cont in
                waiters.append(Waiter(order: order, id: id, cost: need, cont: cont))
            }
        } onCancel: {
            Task { await self.dropWaiter(id) }
        }
    }

    private func dropWaiter(_ id: UInt64) {
        guard let idx = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: idx).cont.resume(throwing: CancellationError())
    }

    /// Return `cost` permits, then serve as many lowest-order waiters as now fit.
    private func releaseNow(cost: Int) {
        available = min(limit, available + max(1, cost))
        // Serve repeatedly: freeing a big permit may unblock several small ones.
        while let next = waiters.indices
            .filter({ waiters[$0].cost <= available })
            .min(by: { waiters[$0].order < waiters[$1].order }) {
            let w = waiters.remove(at: next)
            available -= w.cost
            w.cont.resume()
        }
    }

    nonisolated func withSlot<T: Sendable>(order: Int, cost: Int = 1,
                                           _ body: @Sendable () async -> T?) async -> T? {
        if Task.isCancelled { return nil }
        do {
            try await acquire(order: order, cost: cost)
        } catch {
            return nil
        }
        if Task.isCancelled { await releaseNow(cost: cost); return nil }
        let result = await body()
        await releaseNow(cost: cost)
        return result
    }
}
```

**Important:** the old `releaseNow()` served exactly one waiter. The new one loops, because returning a 3-permit release may unblock three 1-permit waiters. Missing that would leak concurrency and slowly starve the gate.

- [ ] **Step 6: Pass the cost at the call site**

In `loadOrGenerate` (`ThumbnailCache.swift:262`), read the declared pixel count from the header before acquiring:

```swift
    private nonisolated static func loadOrGenerate(
        url: URL, diskURL: URL, size: CGSize, scale: CGFloat, order: Int
    ) async -> NSImage? {
        // Header-only read (no decode) so a huge image can take a bigger share
        // of the gate than a snapshot. Cheap enough to do before queueing.
        let declaredPixels = declaredPixelCount(url: url)
        let cost = DecodePermit.cost(forDeclaredPixels: declaredPixels, limit: gateLimit)
        return await gate.withSlot(order: order, cost: cost) {
            // ... unchanged body ...
        }
    }

    /// Declared pixel count from the image header, or nil if unreadable/not an
    /// image. Header-only — never decodes.
    private nonisolated static func declaredPixelCount(url: URL) -> Int? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let h = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue
        else { return nil }
        let (product, overflow) = w.multipliedReportingOverflow(by: h)
        return overflow ? nil : product
    }
```

Add the shared limit constant next to the gate so the two cannot drift:

```swift
    private static let gateLimit = 8
    private static let gate = ThumbnailGate(limit: gateLimit)
```

- [ ] **Step 7: Verify in the running app**

- Open `scratchpad/perf/fixtures` (three large scan TIFFs). Confirm thumbnails appear and the app stays responsive.
- Open a folder of several hundred ordinary photos. Confirm thumbnail fill speed is **not** worse than before — ordinary photos must still run 8-wide. If it regressed, `ordinaryPixels` is set too low.
- Scroll fast through a large folder and confirm the cancellation path still drops off-screen work (no stalling behind a huge permit).

- [ ] **Step 8: Full suite + commit**

```bash
xcodebuild -scheme Muse -destination 'platform=macOS' test 2>&1 | tail -5
git add Muse/Muse/Filesystem/ThumbnailCache.swift \
        Muse/Muse/Components/DecodePermit.swift \
        Muse/MuseTests/DecodePermitTests.swift
git commit -m "perf: weight thumbnail-gate permits by image size

The gate granted a flat 8 permits regardless of size, so eight 115 MP scanner
TIFFs could decode at once on folder open — and for formats ImageIO cannot
stream-downsample, each materializes its FULL raster. That is multiple GB of
simultaneous rasters with no click involved.

Permits are now weighted by declared pixel count (header read, no decode).
Ordinary photos still cost 1 and keep full 8-wide parallelism; a 65 MP scan
costs 2, a 115 MP scan 3.

releaseNow now serves waiters in a loop rather than one at a time — returning a
multi-permit release can unblock several small waiters, and serving only one
would leak concurrency."
```

---

### Task 8: Batch the per-file DB writes and widen hashing

The smallest items, folded into one task since neither justifies its own review.

**Files:**
- Modify: `Muse/Muse/Indexing/Indexer.swift` (in-flight window)
- Test: `Muse/MuseTests/IndexerConcurrencyTests.swift` (create)

**Interfaces:**
- Produces: `Indexer.hashConcurrency: Int` (= 4).

**Scope note:** the "batch the analyze write transactions" half of spec C7 is **dropped**. After Tasks 1 and 3 the per-file cost is a few hundred milliseconds of decode plus Vision, against which two small transactions are noise; batching them would trade real complexity (partial-failure semantics across a batch, interaction with the mid-pass content-hash guard in `analyzeOne`) for an unmeasurable win. Revisit only if profiling later shows DB time is material. This is recorded in the spec as a deliberate cut, not an oversight.

- [ ] **Step 1: Write the failing test**

Create `Muse/MuseTests/IndexerConcurrencyTests.swift`:

```swift
import XCTest
@testable import Muse

final class IndexerConcurrencyTests: XCTestCase {
    func testHashConcurrencyIsFourWide() {
        XCTAssertEqual(Indexer.hashConcurrency, 4)
    }

    func testHashConcurrencyIsBoundedAndPositive() {
        // A window this small must never be zero (no work would start) and must
        // stay modest — hashing is I/O bound and an unbounded fan-out of
        // userInitiated tasks was the original UI-stutter bug.
        XCTAssertGreaterThan(Indexer.hashConcurrency, 0)
        XCTAssertLessThanOrEqual(Indexer.hashConcurrency, 8)
    }
}
```

- [ ] **Step 2: Run to verify failure**

```bash
xcodebuild -scheme Muse -destination 'platform=macOS' \
  -only-testing:MuseTests/IndexerConcurrencyTests test 2>&1 | tail -30
```

Expected: FAIL — no `hashConcurrency`.

- [ ] **Step 3: Implement**

In `Indexer.swift`, add near the `Priority` enum:

```swift
    /// Files hashed at once. SHA-256 here is I/O bound, so a slightly wider
    /// window helps import throughput on an SSD. Deliberately still small: an
    /// unbounded fan-out of userInitiated hashing tasks was the original
    /// large-library UI-stutter bug.
    static let hashConcurrency = 4
```

In `indexBatch`, replace:

```swift
            while inFlight < 2, enqueueNext() { inFlight += 1 }
```

with:

```swift
            while inFlight < Self.hashConcurrency, enqueueNext() { inFlight += 1 }
```

While here, note that `inFlight` is incremented but never decremented — it is only used to prime the initial window, and the `while let result = await group.next()` loop maintains the window thereafter. Leave the behavior alone but add a clarifying comment:

```swift
            // `inFlight` only primes the initial window; the drain loop below
            // maintains it by enqueueing one replacement per completion.
```

- [ ] **Step 4: Run to verify pass**

```bash
xcodebuild -scheme Muse -destination 'platform=macOS' \
  -only-testing:MuseTests/IndexerConcurrencyTests test 2>&1 | tail -20
```

Expected: PASS, 2 tests.

- [ ] **Step 5: Verify in the running app**

Add a folder of large files (the scan fixtures plus the RAW folder). Confirm the "Indexing N of M" pill advances faster than before and the UI stays responsive during the pass. If the UI stutters, drop `hashConcurrency` back to 3 and note it.

- [ ] **Step 6: Full suite + commit**

```bash
xcodebuild -scheme Muse -destination 'platform=macOS' test 2>&1 | tail -5
git add Muse/Muse/Indexing/Indexer.swift Muse/MuseTests/IndexerConcurrencyTests.swift
git commit -m "perf: hash 4 files at a time during indexing

SHA-256 here is I/O bound, so a slightly wider window helps import throughput for
large files. Still deliberately small — an unbounded fan-out of userInitiated
hashing tasks was the original large-library UI-stutter bug.

The analyze-side write batching from the spec's C7 is deliberately dropped: after
the decode fixes the per-file cost is dominated by decode + Vision, against which
two small transactions are noise, and batching would complicate the mid-pass
content-hash guard for no measurable gain."
```

---

### Task 9: Documentation

**Files:**
- Modify: `CLAUDE.md` (Durable constraints, Implementation status)
- Modify: `docs/session-log.md`
- Modify: `docs/architecture-map.md`

- [ ] **Step 1: Add the durable constraints**

Append to CLAUDE.md's "Durable constraints & gotchas", keeping the house one-or-two-line style:

```markdown
- **The analyze pass decodes at a BOUNDED 4096px long edge (`VisionServices.analysisMaxPixel`) — never full resolution.** `loadCGImage` used `NSImage(contentsOf:)`, handing a full raster to five concurrent Vision requests; only feature print downsamples internally, so classify/faces/OCR/`CIAreaAverage` all scaled with pixel count. A 115 MP scanner TIFF cost **111 seconds and ~1 GB peak** per file against a then-serial loop. Measured identical output at 4096 (same labels, feature print, dominant colour, and 918/918 OCR chars on a document scan) — 4096 not 2048 because a document at 1024 lost 25% of its characters and the extra decode is ~200 ms. Don't raise it to "full quality"; there is no quality there to get. `withinDecodeBudget` still runs FIRST (bomb guard). Don't re-add a format blacklist or an OCR probe — both were designed, and the probe was built and **disproved** (a `.fast` probe at 1024px read 0 of a real document's 918 characters).
- **Colour extraction is pinned to sRGB, in BOTH `VisionServices.dominantColorHex` and `PaletteExtractor`.** `dominantColor` rendered with `workingColorSpace: NSNull()` + `colorSpace: nil` — no colour management — so it read whatever space the decoder returned as if it were sRGB. RAW decodes as **ITU-R 2100 PQ**, so every RAW file's `dominant_color` was wrong, feeding colour tags and colour search. The palette drew into `DeviceRGB`, which is unspecified by definition. Don't set either back to nil/NSNull/DeviceRGB.
- **Clustering is an exact tiled `cblas_sgemm`, NOT incremental.** `HybridClusterer` was all-pairs `VectorMath.cosine`, which recomputes BOTH magnitudes per pair (each vector's norm recomputed N times per pass) — 50M comparisons at 10k files, after every analyze pass. Now: normalize once (cosine → dot product), one sgemm per row tile, same 0.62 threshold and same union-find, **bit-identical clusters** (pinned by `SimilarityMatrixTests` against a scalar reference at both pair and cluster level). Incremental/centroid clustering was rejected — it is a different algorithm (no retroactive merge/split, order-dependent) whose failure mode is silent quality drift. Tiling is memory-only; don't remove it (the full matrix is 400 MB at 10k). `VectorMath.cosine` stays for `SemanticSearch`.
- **A pass that embedded nothing must not recluster** (`ReclusterGate`). Reclustering scales with LIBRARY size, not pass size; `analyze(file:)` used to rebuild the whole library after every single file.
- **The analyze loop is concurrent (3-wide) and progress is COMPLETION-counted, not index-derived** (`AnalyzeProgress`). Completion order ≠ index order, so the old `idx + 1` fraction would jump backwards. Cancellation stops new spawns and lets in-flight files finish, matching the old loop's `break`.
- **Thumbnail-gate permits are weighted by declared pixel count** (`DecodePermit`), because formats ImageIO can't stream-downsample materialize the FULL raster even for a thumbnail — eight 115 MP TIFFs at once was GB of rasters on mere folder open. `ThumbnailGate.releaseNow` must serve waiters in a LOOP (one multi-permit release can unblock several small waiters); serving one leaks concurrency.
```

Add to the Implementation status table:

```markdown
| Polish 25 — **Analysis performance** (bounded Vision raster, sRGB colour fix, concurrent pass, exact vectorized clustering, size-aware thumbnail gate) | ✅ shipped | `feat/next-140` |
```

- [ ] **Step 2: Write the session-log entry**

Append a dated entry to `docs/session-log.md` covering: the user report, the measured baseline (111 s / +1 GB on a 115 MP scan), the corrected diagnosis (OCR was not the dominant cost — classify, colour and faces all scale too; only feature print downsamples internally), the two rejected designs and **why measurement killed the OCR probe specifically**, the RAW colour-space bug found along the way, the D4 known limitations (RAF undecodable, MEF preview-only), and the dropped C7 write-batching with its reason.

- [ ] **Step 3: Update the architecture map**

Add the four new pure components to `docs/architecture-map.md` under `Components/`: `AnalyzeProgress`, `ReclusterGate`, `DecodePermit`, and note `VectorMath`'s new batch similarity API.

- [ ] **Step 4: Commit**

```bash
git add CLAUDE.md docs/session-log.md docs/architecture-map.md \
        docs/superpowers/specs/2026-07-28-analysis-performance-design.md \
        docs/superpowers/plans/2026-07-28-analysis-performance.md
git commit -m "docs: analysis-performance spec, plan, session log, durable constraints"
```

---

## Final verification

- [ ] Full suite green: `xcodebuild -scheme Muse -destination 'platform=macOS' test`
- [ ] `swift Bench.swift ./fixtures ./fixtures_doc "$HOME/Desktop/Raw Files"` — every fixture faster, `scan_document.tif` still yields **918** OCR characters.
- [ ] Running app: analyzing the three scan TIFFs takes seconds, app stays responsive, no beachball.
- [ ] Running app: collections are unchanged from before the branch.
- [ ] Running app: a scanned document is still findable by searching a word from its body.
- [ ] Running app: RAW colour swatches look like the photograph.
- [ ] Memory: peak footprint during a scan-folder analyze stays in the hundreds of MB, not GB.

## Self-review notes

Checked against the spec:
- C1 → Task 1. C2 withdrawn (spec D1) → no task, recorded in Task 9 docs.
- C3 → Tasks 5 (vectorize) and 6 (gate). C4 → Task 4. C5 → Task 3. C6 → Task 7.
- C7 → Task 8, **half dropped** with reasoning recorded in the task and its commit.
- D1/D1a → Task 1. D2 → Task 5. D3 → Task 2. D4 → documentation only (Task 9).

Type consistency: `boundedDecode`/`analysisMaxPixel` (Task 1) are used by Task 3; `dominantColorHex` (Task 2) is referenced by Task 3's palette work and Task 9's constraint text; `normalizedMatrix`/`forEachPairAbove` (Task 5) are used only within Task 5; `gateLimit` (Task 7) is shared by the gate and the cost call. `weightedPalette(for:)` is retained as the equivalence-test reference — verified that `VisionTagger` is its only production caller and that `HeroPalette` does **not** use it (an earlier draft of this plan claimed it did; that was wrong).

Verified against the real tree rather than assumed: the colour test suites are `ColorDistanceTests`, `ColorQueryTests`, `ColorTaggerTests`, `NamedColorTests`, `PaletteExtractorTests`, `PaletteMatchTests`, `HeroPaletteTests` (there is no `ColorSearchTests` or `PaletteTests`), and `PaletteExtractorTests` touches only the pure k-means core.

**Known out of scope, recorded so it isn't mistaken for an oversight:** `HeroPalette.paletteHexes` reads RGBA bytes without pinning a colour space, the same class of issue Task 2 fixes. It is left alone because it is display-only — it tints the hero backdrop wash and never writes to the database, so it cannot corrupt colour tags or colour search. Worth revisiting if the hero wash ever looks wrong on RAW.
