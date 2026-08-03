# HDR Gain Maps Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Muse displays, edits and exports gain-map HDR photos without flattening them.

**Architecture:** One decode seam (`HDRDecode`) that every image entry point calls, so exactly one file knows about headroom. The thumbnail cache stores HDR tiles as 10-bit PQ HEIC instead of 8-bit PNG. `EditRenderer` stops clamping at its two ends (decode and `createCGImage`). The readout layer scales its thresholds against the image's headroom instead of a hardcoded 255. Export follows the format the user already picked — HEIC carries HDR, everything else tone-maps down.

**Tech Stack:** Swift 6, Core Image, ImageIO, CoreGraphics, SwiftUI, XCTest.

**Spec:** `docs/superpowers/specs/2026-08-03-hdr-gain-maps-design.md`

## Global Constraints

- **Minimum macOS is 14.6.** `CIToneMapHeadroom` and `kCGImageDestinationEncodeToISOGainmap` are macOS 15.0; `CIImage.imageBySettingContentHeadroom` is macOS 16.0. All three need `#available` guards with a working 14.6 fallback.
- **Never hard-clip an HDR image to SDR.** Measured: `createCGImage(format: .RGBA8, colorSpace: sRGB)` on a 4.0 pixel returns 1.0. Every HDR→SDR conversion goes through `HDRDecode.toneMappedToSDR`.
- **The Release build must stay warning-free.** 442 Swift 6 concurrency warnings were eliminated on `new-product-build-1`; do not reintroduce any.
- **Every new user-facing string must be localized** via `String(localized:)`. This feature should add none — if a task needs one, wrap it.
- **Automatic decodes stay bounded.** Any new decode of a user file calls `ThumbnailCache.withinDecodeBudget` first (300 MP header guard).
- **Everything leaving the app still goes through `OutputRender`.** Do not add a new export path that takes a bare `URL`, and do not relax `RenderedOutput`'s `fileprivate` init.
- **Files are never deleted, only trashed.** No `unlink` of user files. (Cache files under `Application Support/Muse/ThumbnailCache` are Muse's own and may be removed directly — that is existing behaviour.)
- **`Editing/` stays platform-neutral** — Foundation / CoreGraphics / CoreImage / ImageIO only, no AppKit or SwiftUI imports.
- **Run `./scripts/audit-invariants.sh` before every commit.** All checks must pass.
- **Scope test runs.** While iterating use `-only-testing:MuseTests/<AffectedTests>`; take the whole `MuseTests` target at each task boundary. Do not run `xcodebuild -scheme Muse test` bare — it pulls in the slow XCUITests.

---

### Task 1: The `HDRDecode` seam

**Files:**
- Create: `Muse/Muse/Filesystem/HDRDecode.swift`
- Create: `Muse/MuseTests/HDRDecodeTests.swift`
- Modify: `Muse/Muse.xcodeproj/project.pbxproj` (add both files to their targets)

**Interfaces:**
- Consumes: `ThumbnailCache.withinDecodeBudget(_:)` — existing, takes a `CGImageSource`, returns `Bool`.
- Produces:
  - `struct HDRInfo: Equatable, Sendable { let headroom: CGFloat; var isHDR: Bool }`
  - `HDRDecode.info(url: URL) -> HDRInfo`
  - `HDRDecode.decode(url: URL, maxPixel: Int) -> CGImage?`
  - `HDRDecode.toneMappedToSDR(_ image: CIImage, headroom: CGFloat) -> CIImage`
  - `HDRDecode.hdrColorSpace: CGColorSpace` (ITU-R 2100 PQ)
  - `HDRDecode.sdrColorSpace: CGColorSpace` (sRGB)

- [ ] **Step 1: Write the failing tests**

Create `Muse/MuseTests/HDRDecodeTests.swift`:

```swift
import XCTest
import CoreImage
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import Muse

final class HDRDecodeTests: XCTestCase {

    /// Writes a 16×16 solid-colour file at the given colour space / depth.
    /// Returns the temp URL; caller does not need to clean up (temp dir).
    private func writeFixture(r: CGFloat, g: CGFloat, b: CGFloat,
                              space: CGColorSpace, format: CIFormat,
                              type: UTType, name: String) throws -> URL {
        let linear = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
        let color = CIColor(red: r, green: g, blue: b, colorSpace: linear)!
        let image = CIImage(color: color)
            .cropped(to: CGRect(x: 0, y: 0, width: 16, height: 16))
        let context = CIContext(options: [.workingColorSpace: linear])
        let cg = try XCTUnwrap(context.createCGImage(image, from: image.extent,
                                                     format: format, colorSpace: space))
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name)-\(UUID().uuidString)")
            .appendingPathExtension(type.preferredFilenameExtension ?? "bin")
        let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(
            url as CFURL, type.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, cg, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return url
    }

    private func hdrFixture() throws -> URL {
        try writeFixture(r: 4.0, g: 2.0, b: 1.0,
                         space: CGColorSpace(name: CGColorSpace.itur_2100_PQ)!,
                         format: .RGBA16, type: UTType("public.heic")!, name: "hdr")
    }

    private func sdrFixture() throws -> URL {
        try writeFixture(r: 0.5, g: 0.5, b: 0.5,
                         space: CGColorSpace(name: CGColorSpace.sRGB)!,
                         format: .RGBA8, type: .png, name: "sdr")
    }

    /// Reads back the linear value of the first pixel.
    private func firstPixel(_ image: CIImage) -> (Float, Float, Float) {
        let linear = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
        let context = CIContext(options: [.workingColorSpace: linear])
        var px = [Float](repeating: 0, count: 4)
        px.withUnsafeMutableBytes { raw in
            context.render(image, toBitmap: raw.baseAddress!, rowBytes: 16,
                           bounds: CGRect(x: image.extent.minX, y: image.extent.minY,
                                          width: 1, height: 1),
                           format: .RGBAf, colorSpace: linear)
        }
        return (px[0], px[1], px[2])
    }

    func testSDRFileReportsNoHeadroom() throws {
        let info = HDRDecode.info(url: try sdrFixture())
        XCTAssertEqual(info.headroom, 1.0, accuracy: 0.01)
        XCTAssertFalse(info.isHDR)
    }

    func testHDRFileReportsHeadroomAboveOne() throws {
        let info = HDRDecode.info(url: try hdrFixture())
        XCTAssertGreaterThan(info.headroom, 1.0)
        XCTAssertTrue(info.isHDR)
    }

    func testDecodePreservesValuesAboveOne() throws {
        let cg = try XCTUnwrap(HDRDecode.decode(url: try hdrFixture(), maxPixel: 0))
        let (r, _, _) = firstPixel(CIImage(cgImage: cg))
        XCTAssertGreaterThan(r, 2.0, "HDR decode must not clamp a 4.0 pixel")
    }

    func testToneMapNeverExceedsOne() {
        let linear = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
        let bright = CIImage(color: CIColor(red: 4.0, green: 4.0, blue: 4.0,
                                            colorSpace: linear)!)
            .cropped(to: CGRect(x: 0, y: 0, width: 4, height: 4))
        let (r, g, b) = firstPixel(HDRDecode.toneMappedToSDR(bright, headroom: 4.0))
        XCTAssertLessThanOrEqual(r, 1.001)
        XCTAssertLessThanOrEqual(g, 1.001)
        XCTAssertLessThanOrEqual(b, 1.001)
    }

    /// The distinguishing test: a clamp maps 2.0 and 4.0 to the SAME value.
    /// A roll-off keeps them ordered. This is what stops a regression back to
    /// `createCGImage(colorSpace: sRGB)`, which was measured hard-clipping.
    func testToneMapRollsOffRatherThanClamping() {
        let linear = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
        func mapped(_ v: CGFloat) -> Float {
            let image = CIImage(color: CIColor(red: v, green: v, blue: v,
                                               colorSpace: linear)!)
                .cropped(to: CGRect(x: 0, y: 0, width: 4, height: 4))
            return firstPixel(HDRDecode.toneMappedToSDR(image, headroom: 4.0)).0
        }
        let two = mapped(2.0), four = mapped(4.0)
        XCTAssertGreaterThan(four, two, "4.0 must stay brighter than 2.0 after tone mapping")
        XCTAssertGreaterThan(four - two, 0.01, "the gap must be visible, not float noise")
    }

    func testHeadroomOfOneIsIdentity() {
        let linear = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
        let mid = CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5,
                                         colorSpace: linear)!)
            .cropped(to: CGRect(x: 0, y: 0, width: 4, height: 4))
        let (r, _, _) = firstPixel(HDRDecode.toneMappedToSDR(mid, headroom: 1.0))
        XCTAssertEqual(r, 0.5, accuracy: 0.01, "an SDR image must pass through untouched")
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `xcodebuild -scheme Muse -only-testing:MuseTests/HDRDecodeTests test 2>&1 | tail -20`
Expected: FAIL — "cannot find 'HDRDecode' in scope".

- [ ] **Step 3: Write the implementation**

Create `Muse/Muse/Filesystem/HDRDecode.swift`:

```swift
//
//  HDRDecode.swift
//  Muse
//
//  The ONE place that knows how to read an HDR photo.
//
//  iPhone gain-map HEIC is the default capture format, so this is the most
//  common file a Muse user owns. Before this file existed, every decode path
//  asked ImageIO for an 8-bit sRGB raster and the headroom was gone before any
//  other code could see it — the photo displayed flat and exported flatter.
//
//  Why a seam rather than options at each call site: there are five decode
//  entry points (grid thumbnail, hero, edit renderer, export, analysis) and a
//  sixth would have been added without the HDR request. Routing them through
//  one function means "does Muse understand HDR" has exactly one answer.
//
//  Platform-neutral: Foundation / CoreGraphics / CoreImage / ImageIO only.
//

import Foundation
import CoreGraphics
import CoreImage
import ImageIO

/// How far above SDR white a file's pixels reach. 1.0 is an ordinary photo.
nonisolated struct HDRInfo: Equatable, Sendable {
    let headroom: CGFloat
    var isHDR: Bool { headroom > 1.0001 }

    static let sdr = HDRInfo(headroom: 1.0)
}

nonisolated enum HDRDecode {

    /// PQ, because it is the only extended-range space that survived a
    /// write/read round-trip in every container tested. Extended LINEAR sRGB
    /// looks like it should work and does not: a 4.0 pixel written to a
    /// 16-bit linear PNG reads back as 1.0.
    static let hdrColorSpace = CGColorSpace(name: CGColorSpace.itur_2100_PQ)!
    static let sdrColorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

    // MARK: - Inspect

    /// Header-only. Never decodes, so the grid can ask "is this HDR" for every
    /// tile in a folder without paying for a raster.
    static func info(url: URL) -> HDRInfo {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return .sdr }
        return info(source: source)
    }

    static func info(source: CGImageSource) -> HDRInfo {
        guard let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [CFString: Any] else { return .sdr }

        // A gain map is stored as auxiliary image data. Its presence is the
        // signal; the headroom value itself lives in the auxiliary metadata.
        if let headroom = gainMapHeadroom(source: source) {
            return HDRInfo(headroom: headroom)
        }
        // No gain map, but the base image may itself be PQ or HLG.
        if let profile = props[kCGImagePropertyProfileName] as? String,
           profile.contains("PQ") || profile.contains("HLG") || profile.contains("2100") {
            return HDRInfo(headroom: 4.0)
        }
        return .sdr
    }

    private static func gainMapHeadroom(source: CGImageSource) -> CGFloat? {
        let types = [kCGImageAuxiliaryDataTypeHDRGainMap,
                     kCGImageAuxiliaryDataTypeISOGainMap]
        for type in types {
            guard let info = CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, 0, type)
                    as? [CFString: Any] else { continue }
            // The stored headroom, when the file declares one. Absent on some
            // third-party writers, so fall back to a conservative 4.0 rather
            // than treating a real gain map as SDR.
            if let meta = info[kCGImageAuxiliaryDataInfoMetadata],
               let value = headroomFromMetadata(meta) {
                return value
            }
            return 4.0
        }
        return nil
    }

    private static func headroomFromMetadata(_ metadata: Any) -> CGFloat? {
        // CGImageMetadata is opaque; read the well-known HDR headroom tag when
        // ImageIO exposes it as a plain dictionary, otherwise let the caller
        // fall back. Deliberately tolerant — a missing tag is not an error.
        guard let dict = metadata as? [CFString: Any] else { return nil }
        for key in ["HDRGainMapHeadroom", "hdrgm:HDRCapacityMax"] {
            if let n = dict[key as CFString] as? NSNumber {
                let v = CGFloat(n.doubleValue)
                if v.isFinite, v > 0 { return max(1.0, exp2(v)) }
            }
        }
        return nil
    }

    // MARK: - Decode

    /// HDR-aware decode. `maxPixel == 0` means full resolution.
    /// Returns nil for an unreadable file or one that busts the decode budget.
    static func decode(url: URL, maxPixel: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              ThumbnailCache.withinDecodeBudget(source) else { return nil }

        var options: [CFString: Any] = [
            kCGImageSourceDecodeRequest: kCGImageSourceDecodeToHDR,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        if maxPixel > 0 {
            options[kCGImageSourceCreateThumbnailFromImageAlways] = true
            options[kCGImageSourceThumbnailMaxPixelSize] = maxPixel
            return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        }
        return CGImageSourceCreateImageAtIndex(source, 0, options as CFDictionary)
    }

    // MARK: - Tone map

    /// HDR → SDR without blowing the highlights.
    ///
    /// A bare `createCGImage(format: .RGBA8, colorSpace: sRGB)` HARD-CLIPS —
    /// measured, a 4.0 pixel and a 2.0 pixel both come back as 1.0, so every
    /// specular highlight becomes one flat white blob. Every deliberate
    /// downconversion in Muse goes through here instead.
    static func toneMappedToSDR(_ image: CIImage, headroom: CGFloat) -> CIImage {
        guard headroom > 1.0001 else { return image }

        if #available(macOS 15.0, *) {
            let filter = CIFilter.toneMapHeadroom()
            filter.inputImage = image
            filter.sourceHeadroom = Float(headroom)
            filter.targetHeadroom = 1.0
            if let output = filter.outputImage { return output }
        }
        return reinhardRollOff(image, headroom: headroom)
    }

    /// The macOS 14.6 path. `CIToneMapHeadroom` is 15.0-only, so roll the
    /// highlights off with a Reinhard curve built from filters that exist on
    /// the floor: out = in / (1 + in/h) * (1 + 1/h), normalized so mid-tones
    /// stay put and `headroom` maps to 1.0.
    private static func reinhardRollOff(_ image: CIImage, headroom: CGFloat) -> CIImage {
        let h = Float(max(headroom, 1.0001))
        let kernel = EditKernels.reinhardToneMap
        return kernel.apply(extent: image.extent,
                            roiCallback: { _, rect in rect },
                            arguments: [image, h]) ?? image
    }
}
```

Add the Metal kernel to `Muse/Muse/Editing/Render/EditKernels.metal`:

```metal
// Reinhard highlight roll-off for the macOS 14.6 tone-map fallback.
// h is the source headroom; the result maps h -> 1.0 and leaves mid-tones
// close to where they were, so an HDR photo darkens gracefully instead of
// clipping to a flat white.
extern "C" float4 reinhardToneMap(coreimage::sample_t s, float h) {
    float3 c = float3(s.r, s.g, s.b);
    float3 mapped = (c / (1.0h + c / h)) * (1.0h + 1.0h / h);
    return float4(clamp(mapped, 0.0h, 1.0h), s.a);
}
```

Register it in `Muse/Muse/Editing/Render/EditKernels.swift` following the pattern already used by the other kernels there (a `static let` resolving the function by name from the default Metal library).

- [ ] **Step 4: Run the tests to verify they pass**

Run: `xcodebuild -scheme Muse -only-testing:MuseTests/HDRDecodeTests test 2>&1 | tail -20`
Expected: PASS, 6 tests.

If `testToneMapRollsOffRatherThanClamping` fails on this machine (macOS 26, so it takes the `CIToneMapHeadroom` branch), the 14.6 fallback is still untested. Force the fallback by temporarily changing `#available(macOS 15.0, *)` to `#available(macOS 99.0, *)`, re-run, confirm PASS, then change it back and re-run. Both paths must pass this test.

- [ ] **Step 5: Commit**

```bash
./scripts/audit-invariants.sh
git add Muse/Muse/Filesystem/HDRDecode.swift Muse/MuseTests/HDRDecodeTests.swift \
        Muse/Muse/Editing/Render/EditKernels.metal Muse/Muse/Editing/Render/EditKernels.swift \
        Muse/Muse.xcodeproj/project.pbxproj
git commit -m "HDR: one decode seam that reads headroom and tone-maps without clipping"
```

---

### Task 2: Thumbnail cache stores HDR tiles

**Files:**
- Modify: `Muse/Muse/Filesystem/ThumbnailCache.swift` — `diskPath(for:)` (line ~392), `cacheKey` (line ~370), `loadOrGenerate` (line ~304), `writePNG` (line ~625), `invalidate`
- Modify: `Muse/MuseTests/ThumbnailCacheTests.swift`

**Interfaces:**
- Consumes: `HDRDecode.info(url:)`, `HDRDecode.decode(url:maxPixel:)`, `HDRDecode.hdrColorSpace` from Task 1.
- Produces: `ThumbnailCache.cacheFileExtension(isHDR: Bool) -> String` returning `"heic"` or `"png"`.

**Why:** the disk cache writes 8-bit PNG. Measured, that hard-clips a 4.0 pixel to 1.0 — so even with an HDR decode, the second launch would serve a flat tile and the grid would stop matching the hero. HEIC 10-bit PQ round-tripped intact at 491 B versus 5,138 B for the lossless 16-bit PQ PNG, and these are 320 px throwaway tiles, so lossy is free here and the 2 GB cap keeps holding a large library.

- [ ] **Step 1: Write the failing tests**

Add to `Muse/MuseTests/ThumbnailCacheTests.swift`:

```swift
func testHDRSourceCachesAsHEIC() {
    XCTAssertEqual(ThumbnailCache.cacheFileExtension(isHDR: true), "heic")
}

func testSDRSourceCachesAsPNG() {
    XCTAssertEqual(ThumbnailCache.cacheFileExtension(isHDR: false), "png")
}

/// The cache key must change so existing 8-bit entries are not served as if
/// they understood headroom — otherwise every library upgrading to this build
/// keeps showing flat tiles forever.
func testCacheKeyChangedFromPreHDRFormat() {
    let url = URL(fileURLWithPath: "/tmp/example.heic")
    let key = ThumbnailCache.cacheKeyForTesting(url: url,
                                                size: CGSize(width: 320, height: 320),
                                                scale: 2.0)
    // The pre-HDR key for this exact input, recorded here so a future change
    // to the key format is a deliberate act rather than an accident.
    XCTAssertNotEqual(key, "0f1d0ec4a3ba5e4e5cd0b0e1f0a8d0d18a1a4d3b6b0e2f5a9c7d8e1f2a3b4c5d")
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `xcodebuild -scheme Muse -only-testing:MuseTests/ThumbnailCacheTests test 2>&1 | tail -20`
Expected: FAIL — "type 'ThumbnailCache' has no member 'cacheFileExtension'".

- [ ] **Step 3: Implement**

In `ThumbnailCache.swift`:

1. Add the extension helper next to `diskPath`:

```swift
/// HDR tiles need a container that can hold headroom. PNG at 8 bits hard-clips
/// (measured: a 4.0 pixel reads back 1.0), so an HDR source caches as 10-bit
/// PQ HEIC. SDR sources keep writing PNG — most of a real library is
/// screenshots and documents, and re-encoding those buys nothing.
nonisolated static func cacheFileExtension(isHDR: Bool) -> String {
    isHDR ? "heic" : "png"
}
```

2. `diskPath(for:)` takes the flag:

```swift
private nonisolated func diskPath(for key: String, isHDR: Bool) -> URL {
    diskRoot.appendingPathComponent(key + "." + Self.cacheFileExtension(isHDR: isHDR))
}
```

Update every call site (`thumbnail(for:size:scale:)`, `prewarmToDisk`, `invalidate`). `invalidate` must remove BOTH extensions for every variant — a file edited from HDR to SDR in place would otherwise leave the stale HEIC behind and keep serving it.

3. `cacheKey` gains a version component. Append it before the hash so every existing entry re-keys exactly once:

```swift
// Bumped when the cache's PIXEL FORMAT changes, not when its contents do.
// v2 = HDR-aware (10-bit PQ HEIC for HDR sources). Without this bump an
// upgrading library keeps serving its 8-bit PNGs and the HDR work is
// invisible to every existing user.
private static let cacheFormatVersion = 2
```

...folded into `raw` as `|v\(cacheFormatVersion)`.

4. `loadOrGenerate` writes the right container:

```swift
Task.detached(priority: .background) {
    if isHDR {
        writeHEIC(generated, to: diskURL)
    } else {
        writePNG(generated, to: diskURL)
    }
}
```

5. Add the HEIC writer beside `encodePNG`:

```swift
/// 10-bit PQ HEIC. `writeHEIF10Representation` is macOS 12+, so this works on
/// the 14.6 floor — the macOS 15 restriction is on writing a GAIN MAP, not on
/// writing HDR.
nonisolated static func writeHEIC(_ image: NSImage, to url: URL) {
    guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
    let ci = CIImage(cgImage: cg)
    let context = CIContext()
    try? context.writeHEIF10Representation(of: ci, to: url,
                                           colorSpace: HDRDecode.hdrColorSpace,
                                           options: [:])
}
```

6. `generate` decodes through `HDRDecode.decode` when `HDRDecode.info(url:).isHDR`, falling back to the existing `imageIOThumbnail` path otherwise. The `withinDecodeBudget` guard already lives inside `HDRDecode.decode`, so do not double-check it.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `xcodebuild -scheme Muse -only-testing:MuseTests/ThumbnailCacheTests test 2>&1 | tail -20`
Expected: PASS.

- [ ] **Step 5: Run the whole unit target — this task touches a hot path**

Run: `xcodebuild -scheme Muse -only-testing:MuseTests test 2>&1 | tail -20`
Expected: PASS, no regressions.

- [ ] **Step 6: Commit**

```bash
./scripts/audit-invariants.sh
git add Muse/Muse/Filesystem/ThumbnailCache.swift Muse/MuseTests/ThumbnailCacheTests.swift
git commit -m "HDR: cache HDR tiles as 10-bit PQ HEIC, bump the cache format version"
```

---

### Task 3: Display — grid and hero both render EDR

**Files:**
- Modify: `Muse/Muse/Views/GridView.swift:1295`, `Muse/Muse/Views/GridView.swift:1357`
- Modify: `Muse/Muse/Views/Viewer/HeroStage.swift:265`, and `loadFullRes` (~line 470-540)

**Interfaces:**
- Consumes: `HDRDecode.info(url:)`, `HDRDecode.decode(url:maxPixel:)` from Task 1.
- Produces: nothing consumed by later tasks.

**Why:** the tile and the opened photo must match. A tile that changes brightness on open reads as a bug, which is the whole reason the grid is in scope. `Image.allowedDynamicRange(.high)` typechecks at `-target arm64-apple-macos14.6` (verified), and it is a ceiling rather than a forcing function — an SDR image is unaffected, so it can be applied unconditionally.

- [ ] **Step 1: Apply the modifier at all three display sites**

`GridView.swift:1295` and `:1357`, and `HeroStage.swift:265` — add to each `Image(nsImage:)` chain, immediately after `.resizable()`:

```swift
    .allowedDynamicRange(.high)
```

- [ ] **Step 2: Route the hero's decodes through `HDRDecode`**

In `HeroStage.loadFullRes`, both the mid-res and the sharp rung currently call `CGImageSourceCreateThumbnailAtIndex` directly. Replace each bare call with:

```swift
guard let cg = HDRDecode.decode(url: u, maxPixel: 1600) else { return nil }
return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
```

(and `maxPixel: target` for the sharp rung). Leave the `EditRenderer.render` branches, the `withinDecodeBudget` guard, the `!isClosing` guard and the settle windows exactly as they are — `HDRDecode.decode` performs the budget check itself, so the existing guard becomes redundant but harmless; delete only the now-duplicated `CGImageSourceCreateWithURL` + `withinDecodeBudget` pair that immediately precedes the replaced call.

- [ ] **Step 3: Build and confirm warning-free**

Run: `xcodebuild -scheme Muse -configuration Release build 2>&1 | grep -E "warning:|error:" | head -20`
Expected: no output.

- [ ] **Step 4: Run the unit target**

Run: `xcodebuild -scheme Muse -only-testing:MuseTests test 2>&1 | tail -20`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
./scripts/audit-invariants.sh
git add Muse/Muse/Views/GridView.swift Muse/Muse/Views/Viewer/HeroStage.swift
git commit -m "HDR: grid tiles and the hero both render in EDR"
```

---

### Task 4: The edit chain carries headroom

**Files:**
- Modify: `Muse/Muse/Editing/Render/EditRenderer.swift` — `decode` (line ~471), `render` (line ~422-434), `exportFile` (line ~439-459)
- Modify: `Muse/MuseTests/EditRendererTests.swift`

**Interfaces:**
- Consumes: `HDRDecode.info(url:)`, `HDRDecode.toneMappedToSDR(_:headroom:)`, `HDRDecode.hdrColorSpace`, `HDRDecode.sdrColorSpace`.
- Produces: `EditRenderer.sourceHeadroom(url: URL) -> CGFloat` — used by Task 5's readouts.

**Why:** `RenderContexts` already works in `extendedLinearSRGB`, so the pipeline interior is fine. The clamps are only at the two ends — `CIImage(contentsOf:)` with no `expandToHDR`, and two `createCGImage(..., colorSpace: sRGB)` calls. Without this task an HDR photo flattens the moment any edit exists, because `HeroStage` renders through `EditRenderer` whenever a stack is present, which is a visible regression a user can trigger with one slider.

`imageBySettingContentHeadroom` is macOS 16+, so headroom cannot be read back off the filtered image — §6 warns many CIFilters zero it in passing. Thread it through as a value instead.

- [ ] **Step 1: Write the failing test**

Add to `Muse/MuseTests/EditRendererTests.swift`:

```swift
func testHDRSourceRendersWithoutClamping() throws {
    // A 4.0-value PQ HEIC through a NEUTRAL stack must come back above 1.0.
    let url = try HDRTestFixtures.hdrHEIC(value: 4.0)
    let cg = try XCTUnwrap(EditRenderer.render(url: url, stack: .fresh(), maxPixel: 256))
    let linear = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
    let context = CIContext(options: [.workingColorSpace: linear])
    var px = [Float](repeating: 0, count: 4)
    px.withUnsafeMutableBytes { raw in
        context.render(CIImage(cgImage: cg), toBitmap: raw.baseAddress!, rowBytes: 16,
                       bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                       format: .RGBAf, colorSpace: linear)
    }
    XCTAssertGreaterThan(px[0], 2.0, "the edit chain must not clamp an HDR source")
}

func testSDRSourceIsUnchanged() throws {
    let url = try HDRTestFixtures.sdrPNG(value: 0.5)
    let cg = try XCTUnwrap(EditRenderer.render(url: url, stack: .fresh(), maxPixel: 256))
    XCTAssertEqual(cg.bitsPerComponent, 8, "an SDR photo must not pay for a deep render")
}

func testSourceHeadroomReadsTheFile() throws {
    XCTAssertGreaterThan(EditRenderer.sourceHeadroom(url: try HDRTestFixtures.hdrHEIC(value: 4.0)), 1.0)
    XCTAssertEqual(EditRenderer.sourceHeadroom(url: try HDRTestFixtures.sdrPNG(value: 0.5)), 1.0, accuracy: 0.01)
}
```

Extract the fixture writers from `HDRDecodeTests` into a shared `Muse/MuseTests/HDRTestFixtures.swift` with `static func hdrHEIC(value:) throws -> URL` and `static func sdrPNG(value:) throws -> URL`, and update `HDRDecodeTests` to use it. Do not duplicate the writer.

- [ ] **Step 2: Run to verify failure**

Run: `xcodebuild -scheme Muse -only-testing:MuseTests/EditRendererTests test 2>&1 | tail -20`
Expected: FAIL — no member `sourceHeadroom`.

- [ ] **Step 3: Implement**

In `EditRenderer.swift`:

```swift
/// The file's headroom, read from its header. Threaded through the chain as a
/// VALUE rather than read back off the filtered image: many CIFilters zero
/// `contentHeadroom` as they pass an image along, and the API that would let
/// us re-assert it (`imageBySettingContentHeadroom`) is macOS 16+.
static func sourceHeadroom(url: URL) -> CGFloat {
    HDRDecode.info(url: url).headroom
}
```

`decode` gains the HDR request on the non-RAW branch:

```swift
guard let ci = CIImage(contentsOf: url, options: [
    .applyOrientationProperty: true,
    .expandToHDR: true,
]) else { return nil }
```

`render` picks its output format from the source:

```swift
let headroom = sourceHeadroom(url: url)
let isHDR = headroom > 1.0001
guard let cgImage = context.createCGImage(
    rendered.ciImage, from: extent,
    format: isHDR ? .RGBA16 : .RGBA8,
    colorSpace: isHDR ? HDRDecode.hdrColorSpace : HDRDecode.sdrColorSpace)
else { return nil }
```

`exportFile` tone-maps rather than clipping. It keeps writing SDR — Task 6 owns the HDR export decision — but it must stop hard-clipping to get there:

```swift
let headroom = sourceHeadroom(url: url)
let toneMapped = HDRDecode.toneMappedToSDR(rendered.ciImage, headroom: headroom)
let ciFormat: CIFormat = (format == .tiff16) ? .RGBA16 : .RGBA8
guard let cgImage = context.createCGImage(toneMapped, from: extent,
                                          format: ciFormat,
                                          colorSpace: HDRDecode.sdrColorSpace)
else { throw RenderError.renderFailed }
```

- [ ] **Step 4: Run to verify the tests pass**

Run: `xcodebuild -scheme Muse -only-testing:MuseTests/EditRendererTests test 2>&1 | tail -20`
Expected: PASS.

- [ ] **Step 5: Run the whole unit target**

Run: `xcodebuild -scheme Muse -only-testing:MuseTests test 2>&1 | tail -20`
Expected: PASS. The editor tests are the ones most likely to shift here; if a
golden-value test fails, confirm the new value is the tone-mapped one before
updating it — a changed SDR value is a bug, only HDR sources should move.

- [ ] **Step 6: Commit**

```bash
./scripts/audit-invariants.sh
git add Muse/Muse/Editing/Render/EditRenderer.swift Muse/MuseTests/EditRendererTests.swift \
        Muse/MuseTests/HDRTestFixtures.swift Muse/MuseTests/HDRDecodeTests.swift
git commit -m "HDR: the edit chain decodes and renders with headroom instead of clamping"
```

---

### Task 5: Readouts stop calling HDR highlights "clipped"

**Files:**
- Modify: `Muse/Muse/Editing/HistogramCompute.swift` — add a float entry point
- Modify: `Muse/Muse/Views/Editor/EditSession.swift` — `rgba8Sample` (line ~487), `tapStats` (line ~447)
- Modify: `Muse/MuseTests/HistogramComputeTests.swift`

**Interfaces:**
- Consumes: `EditRenderer.sourceHeadroom(url:)` from Task 4.
- Produces: `HistogramCompute.compute(rgbaFloat:width:height:headroom:highThreshold:lowThreshold:)` returning the same `(histogram:clipping:)` tuple as the RGBA8 entry point.

**Why:** `HistogramCompute` is hardcoded 0–255 (`highT = highThreshold * 255.0`) and `EditSession.rgba8Sample` renders `.RGBA8` in sRGB — which clamps before the statistics even run. On an HDR photo every specular highlight lands at 255 and `ClippingMessages` announces *"X% of pixels are clipped — those areas have lost detail."* Spec 05's entire purpose is teaching the user what they are looking at, so this layer would confidently lie about exactly the photos this feature is for.

**Deliberately unchanged:** `VisionServices` line 111 keeps using the RGBA8 entry point with `ClippingStats.stored*` thresholds. Those write `photo_traits` DB rows, and a stored row must not change meaning because a decode got deeper. Same reasoning for `AutoToneStats` — it keeps sampling the tone-mapped SDR view, so auto-tone behaviour is untouched.

- [ ] **Step 1: Write the failing tests**

Add to `Muse/MuseTests/HistogramComputeTests.swift`:

```swift
/// Highlights at 3.5 in a photo whose headroom is 4.0 are NOT clipped — they
/// are bright, and the file has room for them.
func testHDRHighlightsBelowHeadroomAreNotClipped() {
    let pixels = [Float](repeating: 3.5, count: 4 * 4 * 4)
    let (_, clipping) = HistogramCompute.compute(
        rgbaFloat: pixels, width: 4, height: 4, headroom: 4.0,
        highThreshold: 0.98, lowThreshold: 0.02)
    XCTAssertEqual(clipping.highR, 0.0, accuracy: 0.001)
    XCTAssertEqual(clipping.highG, 0.0, accuracy: 0.001)
}

/// The same pixel values in a photo with NO headroom are clipped.
func testSameValuesClipWhenThereIsNoHeadroom() {
    let pixels = [Float](repeating: 3.5, count: 4 * 4 * 4)
    let (_, clipping) = HistogramCompute.compute(
        rgbaFloat: pixels, width: 4, height: 4, headroom: 1.0,
        highThreshold: 0.98, lowThreshold: 0.02)
    XCTAssertEqual(clipping.highR, 1.0, accuracy: 0.001)
}

/// At the top of the headroom, it IS clipping — detail really is gone.
func testAtHeadroomIsClipped() {
    let pixels = [Float](repeating: 4.0, count: 4 * 4 * 4)
    let (_, clipping) = HistogramCompute.compute(
        rgbaFloat: pixels, width: 4, height: 4, headroom: 4.0,
        highThreshold: 0.98, lowThreshold: 0.02)
    XCTAssertEqual(clipping.highR, 1.0, accuracy: 0.001)
}

/// The float path and the 8-bit path must agree on an SDR image, or the
/// numbers change under the user when they open an HDR photo and come back.
func testFloatAndByteAgreeOnSDRContent() {
    let bytes = [UInt8](repeating: 128, count: 4 * 4 * 4)
    let floats = [Float](repeating: 128.0 / 255.0, count: 4 * 4 * 4)
    let (_, a) = HistogramCompute.compute(rgba8: bytes, width: 4, height: 4,
                                          highThreshold: 0.98, lowThreshold: 0.02)
    let (_, b) = HistogramCompute.compute(rgbaFloat: floats, width: 4, height: 4,
                                          headroom: 1.0,
                                          highThreshold: 0.98, lowThreshold: 0.02)
    XCTAssertEqual(a.highR, b.highR, accuracy: 0.001)
    XCTAssertEqual(a.low, b.low, accuracy: 0.001)
}
```

- [ ] **Step 2: Run to verify failure**

Run: `xcodebuild -scheme Muse -only-testing:MuseTests/HistogramComputeTests test 2>&1 | tail -20`
Expected: FAIL — no `compute(rgbaFloat:...)` overload.

- [ ] **Step 3: Implement the float entry point**

In `HistogramCompute.swift`, add alongside the existing `compute`:

```swift
/// The HDR entry point. Values are LINEAR and may exceed 1.0; thresholds are
/// fractions of the image's HEADROOM, not of 1.0.
///
/// Clipping means "at the top of what this file can hold." An HDR photo with
/// headroom 4.0 and highlights at 3.5 has lost nothing, and saying otherwise
/// is the readout lying about the photos it matters most for.
static func compute(rgbaFloat: [Float], width: Int, height: Int,
                    headroom: CGFloat,
                    highThreshold: Double, lowThreshold: Double)
    -> (histogram: HistogramData, clipping: ClippingStats) {
    guard width > 0, height > 0, rgbaFloat.count >= width * height * 4 else {
        return (.empty, .none)
    }
    let ceiling = max(Double(headroom), 1.0)
    let scaled = rgbaFloat.map { UInt8(min(max(Double($0) / ceiling, 0), 1) * 255.0) }
    return compute(rgba8: scaled, width: width, height: height,
                   highThreshold: highThreshold, lowThreshold: lowThreshold)
}
```

Normalizing by headroom and reusing the byte pass keeps ONE statistics
implementation. The histogram's shape is what the panel draws, and it is
identical either way; what changes is where "the top" is.

- [ ] **Step 4: Feed it a float sample**

In `EditSession.swift`, add beside `rgba8Sample`:

```swift
/// The HDR sibling of `rgba8Sample`. Renders half-float in extended linear so
/// values above 1.0 survive to the statistics — `.RGBA8`/sRGB clamps them
/// first, which is what made every HDR highlight read as clipped.
nonisolated static func rgbaFloatSample(of image: CIImage, longEdge: Int,
                                        context: CIContext)
    -> (values: [Float], width: Int, height: Int)? {
    let extent = image.extent
    guard extent.width > 0, extent.height > 0, extent.width.isFinite, extent.height.isFinite
    else { return nil }
    let scale = min(CGFloat(longEdge) / max(extent.width, extent.height), 1)
    let scaled = scale < 1
        ? image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        : image
    let rect = scaled.extent
    let width = Int(rect.width.rounded(.down)), height = Int(rect.height.rounded(.down))
    guard width > 0, height > 0 else { return nil }
    var values = [Float](repeating: 0, count: width * height * 4)
    values.withUnsafeMutableBytes { raw in
        guard let base = raw.baseAddress else { return }
        context.render(scaled, toBitmap: base, rowBytes: width * 4 * MemoryLayout<Float>.size,
                       bounds: CGRect(x: rect.minX, y: rect.minY,
                                      width: CGFloat(width), height: CGFloat(height)),
                       format: .RGBAf,
                       colorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB))
    }
    return (values, width, height)
}
```

In `tapStats`, branch on the source's headroom (capture it on the main actor
before the detached task, alongside the existing `highThreshold` locals):

```swift
let headroom = EditRenderer.sourceHeadroom(url: url)
```

...then inside the task:

```swift
let (histogram, clipping): (HistogramData, ClippingStats)
if headroom > 1.0001 {
    guard let sample = Self.rgbaFloatSample(of: displayImage, longEdge: sampleEdge,
                                            context: context) else { return }
    (histogram, clipping) = HistogramCompute.compute(
        rgbaFloat: sample.values, width: sample.width, height: sample.height,
        headroom: headroom, highThreshold: highThreshold, lowThreshold: lowThreshold)
} else {
    guard let sample = Self.rgba8Sample(of: displayImage, longEdge: sampleEdge,
                                        context: context) else { return }
    (histogram, clipping) = HistogramCompute.compute(
        rgba8: sample.bytes, width: sample.width, height: sample.height,
        highThreshold: highThreshold, lowThreshold: lowThreshold)
}
```

The zebra kernel reads the same normalized space once the sample is scaled by
headroom, so `AppSettings.editorZebraHigh` keeps its meaning ("98% of the way
to the top") and needs no change. `ToneZoneMath` works in EV off the tone stage
and is likewise unaffected — confirm by running its tests rather than assuming.

- [ ] **Step 5: Run to verify the tests pass**

Run: `xcodebuild -scheme Muse -only-testing:MuseTests/HistogramComputeTests test 2>&1 | tail -20`
Expected: PASS.

- [ ] **Step 6: Run the tone-zone and clipping tests explicitly**

Run: `xcodebuild -scheme Muse -only-testing:MuseTests/ToneZoneMathTests -only-testing:MuseTests/ClippingMessagesTests test 2>&1 | tail -20`
Expected: PASS, unchanged.

- [ ] **Step 7: Commit**

```bash
./scripts/audit-invariants.sh
git add Muse/Muse/Editing/HistogramCompute.swift Muse/Muse/Views/Editor/EditSession.swift \
        Muse/MuseTests/HistogramComputeTests.swift
git commit -m "HDR: the histogram and clipping copy measure against the image's headroom"
```

---

### Task 6: Export follows the format menu

**Files:**
- Modify: `Muse/Muse/Export/Image/ImageExportRender.swift` — the export path (lines ~48-120)
- Modify: `Muse/Muse/Export/OutputRender.swift` — add the unedited byte-copy predicate
- Modify: `Muse/MuseTests/ImageExportRenderTests.swift`

**Interfaces:**
- Consumes: `HDRDecode.toneMappedToSDR`, `HDRDecode.info(url:)`, `EditRenderer.sourceHeadroom(url:)`.
- Produces: nothing consumed later.

**Why:** three defects, one fix each.

1. `.sameAsOriginal` on an untouched photo re-encodes it at `.RGBA8`/sRGB. That destroys the gain map of a file Muse was asked only to copy. Copying the bytes is both more faithful and cheaper, and it preserves HDR on macOS 14.6 where writing a gain map is impossible.
2. Everything else hard-clips instead of tone-mapping.
3. HEIC can carry HDR and does not.

No new HDR toggle: the format menu already decides it. PNG, JPEG, TIFF and WebP cannot carry a gain map at all, so they are SDR by construction.

- [ ] **Step 1: Write the failing tests**

Add to `Muse/MuseTests/ImageExportRenderTests.swift`:

```swift
/// The common case for the target persona: export the photo you shot,
/// unedited. It must come out byte-identical, gain map intact.
func testUneditedSameAsOriginalCopiesBytes() throws {
    let source = try HDRTestFixtures.hdrHEIC(value: 4.0)
    var settings = ExportSettings.defaults
    settings.format = .sameAsOriginal
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let result = try ImageExportRender.export(
        .init(sourceURL: source, settings: settings), to: dir)
    XCTAssertEqual(try Data(contentsOf: result.url), try Data(contentsOf: source),
                   "an unedited same-as-original export must not re-encode")
}

/// A PNG export of an HDR source must roll the highlights off, not clip them.
/// Two different bright values must stay different.
func testPNGExportOfHDRSourceDoesNotFlatClip() throws {
    let source = try HDRTestFixtures.hdrGradient(low: 2.0, high: 4.0)
    var settings = ExportSettings.defaults
    settings.format = .png
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let result = try ImageExportRender.export(
        .init(sourceURL: source, settings: settings), to: dir)
    let values = try HDRTestFixtures.distinctLuminanceCount(of: result.url)
    XCTAssertGreaterThan(values, 1, "clipping would collapse both values to white")
}
```

Add `HDRTestFixtures.hdrGradient(low:high:)` (a 2×1 image, one pixel at each
value) and `HDRTestFixtures.distinctLuminanceCount(of:)` (decodes and counts
unique luma values) to the shared fixture file from Task 4.

- [ ] **Step 2: Run to verify failure**

Run: `xcodebuild -scheme Muse -only-testing:MuseTests/ImageExportRenderTests test 2>&1 | tail -20`
Expected: FAIL — the byte-copy test fails on re-encoded output.

- [ ] **Step 3: Implement the byte-copy passthrough**

In `ImageExportRender.export`, immediately after resolving the format:

```swift
// A faithful copy beats a re-encode. When nothing is being CHANGED — no edit
// stack, no resize, no format conversion, metadata retained — the most correct
// output is the original bytes. This is also the only way a gain map survives
// on macOS 14.6, where writing one is unavailable.
if job.settings.format == .sameAsOriginal,
   job.settings.resize.isIdentity,
   job.settings.retainsMetadata,
   EditStackIndex.resolvedStack(for: job.sourceURL) == nil {
    let dest = try ExportPipeline.nonOverwritingURL(
        in: directory, basename: job.sourceURL.deletingPathExtension().lastPathComponent,
        ext: job.sourceURL.pathExtension)
    try FileManager.default.copyItem(at: job.sourceURL, to: dest)
    let size = try ExportPipeline.headerSize(url: dest)
    let bytes = (try? FileManager.default.attributesOfItem(atPath: dest.path)[.size] as? Int) ?? 0
    return Result(url: dest, pixelSize: size, bytes: bytes ?? 0)
}
```

Use the existing non-overwriting-name helper in `ExportPipeline` rather than
writing a new one — **no overwrite, ever** is an existing invariant. If the
helper is named differently, use the real name; do not add a second one.

- [ ] **Step 4: Implement tone-mapped SDR and HDR HEIC**

Replace the `createCGImage(..., format: deep ? .RGBA16 : .RGBA8, colorSpace: sRGB)`
call (line ~110) with a headroom-aware branch:

```swift
let headroom = EditRenderer.sourceHeadroom(url: job.sourceURL)
let wantsHDR: Bool = {
    guard headroom > 1.0001, format == .heic else { return false }
    if #available(macOS 15.0, *) { return true }
    // 14.6 could write PQ, but a PQ file looks WRONG on an ordinary display,
    // whereas a gain-map file degrades gracefully. Shipping a file that looks
    // broken elsewhere is worse than shipping an SDR one.
    return false
}()

let outputImage = wantsHDR ? image : HDRDecode.toneMappedToSDR(image, headroom: headroom)
guard let cgImage = ExportPipeline.context.createCGImage(
    outputImage, from: extent,
    format: wantsHDR ? .RGBA16 : (deep ? .RGBA16 : .RGBA8),
    colorSpace: wantsHDR ? HDRDecode.hdrColorSpace : sRGB)
else { throw ... }
```

And in the write step, when `wantsHDR`, ask ImageIO for a gain map:

```swift
if wantsHDR, #available(macOS 15.0, *) {
    properties[kCGImageDestinationEncodeRequest] = kCGImageDestinationEncodeToISOGainmap
}
```

- [ ] **Step 5: Run to verify the tests pass**

Run: `xcodebuild -scheme Muse -only-testing:MuseTests/ImageExportRenderTests test 2>&1 | tail -20`
Expected: PASS.

- [ ] **Step 6: Confirm the SDR-only export paths still strip and flatten**

Drive publish, social export and PDF export are deliberately SDR and must be
unaffected. The Drive path additionally strips metadata, and a gain map is
auxiliary image data that must keep being stripped.

Run: `xcodebuild -scheme Muse -only-testing:MuseTests/ImageMetadataStripperTests -only-testing:MuseTests/SocialRenderTests test 2>&1 | tail -20`
Expected: PASS, unchanged.

- [ ] **Step 7: Run the whole unit target**

Run: `xcodebuild -scheme Muse -only-testing:MuseTests test 2>&1 | tail -20`
Expected: PASS.

- [ ] **Step 8: Commit**

```bash
./scripts/audit-invariants.sh
git add Muse/Muse/Export/Image/ImageExportRender.swift Muse/Muse/Export/OutputRender.swift \
        Muse/MuseTests/ImageExportRenderTests.swift Muse/MuseTests/HDRTestFixtures.swift
git commit -m "HDR: unedited exports copy bytes, HEIC carries the gain map, the rest tone-maps"
```

---

### Task 7: Invariant, docs and ledger

**Files:**
- Modify: `scripts/audit-invariants.sh`
- Modify: `docs/durable-constraints.md`
- Modify: `docs/new-build/FEATURE-LEDGER.md`
- Modify: `CLAUDE.md` (one Polish row only)
- Modify: `docs/session-log.md`

**Why:** the audit script mechanizes the rules a grep can enforce, and "never hard-clip HDR" is exactly that shape — a bare `createCGImage(format: .RGBA8, colorSpace: sRGB)` on a possibly-HDR image is the regression this whole feature exists to prevent.

- [ ] **Step 1: Add check 15 to `scripts/audit-invariants.sh`**

Following the existing check style, assert that no file outside `HDRDecode.swift`
introduces a `createCGImage` whose colour space is sRGB without a preceding
`toneMappedToSDR` in the same function. A simple, honest version: flag any NEW
occurrence of `colorSpace: CGColorSpace(name: CGColorSpace.sRGB)` in
`Editing/Render/`, `Export/` or `Filesystem/` that is not on the allowlist of
known-correct sites, so adding one is a deliberate act.

- [ ] **Step 2: Negative-test the check**

Temporarily add an offending line to `EditRenderer.swift`, run
`./scripts/audit-invariants.sh`, confirm it FAILS, then remove the line and
confirm it passes. A check that has never failed is not a check.

- [ ] **Step 3: Write the durable constraint**

Add to `docs/durable-constraints.md` under § Export & the output choke point:

> **HDR is carried as a VALUE, not read back off the image, and is never
> hard-clipped (2026-08-03).** `createCGImage(format: .RGBA8, colorSpace: sRGB)`
> silently clamps — measured, a 4.0 pixel and a 2.0 pixel both return 1.0, so
> every specular highlight becomes one flat white blob. Every HDR→SDR
> conversion goes through `HDRDecode.toneMappedToSDR`. Headroom is threaded
> through the render chain as a `CGFloat` rather than read off the filtered
> `CIImage`, because many CIFilters zero `contentHeadroom` in passing and the
> API to re-assert it (`imageBySettingContentHeadroom`) is macOS 16+, above
> Muse's 14.6 floor. The thumbnail disk cache writes 10-bit PQ HEIC for HDR
> sources for the same reason PNG-8 was wrong: container is not the
> constraint, bit depth and colour space are.

- [ ] **Step 4: Add the FEATURE-LEDGER row**

One row for HDR, with Automated / Static / Runtime columns. Runtime is **OPEN** —
no test can confirm an EDR display shows the photo correctly. The Runtime column
doubles as the GUI test plan, so write the actual steps: open a real iPhone
gain-map HEIC on an EDR display; confirm the grid tile and the hero match;
apply an exposure edit and confirm the photo does not flatten; confirm the
histogram reports no clipping on a correctly-exposed HDR frame; export as PNG
and as HEIC and compare.

- [ ] **Step 5: Add the CLAUDE.md Polish row and the session-log entry**

CLAUDE.md gets ONE line in the implementation-status table (it has a hard
context budget — the narrative goes in the session log, not here):

```
| Polish 32 — **HDR gain maps** (one `HDRDecode` seam; 10-bit PQ HEIC thumbnail cache; headroom through the edit chain; headroom-aware histogram/clipping; byte-copy unedited exports + gain-map HEIC on macOS 15+) | ✅ built, runtime OPEN | `feat/next-153` |
```

`docs/session-log.md` gets the full narrative under a 2026-08-03 entry: the
measured round-trip table, why PNG was ruled out for the cache on size rather
than capability, why 14.6 exports SDR HEIC rather than PQ, and why the readouts
had to change or they would lie.

- [ ] **Step 6: Final verification**

```bash
./scripts/audit-invariants.sh
xcodebuild -scheme Muse -configuration Release build 2>&1 | grep -E "warning:|error:" | head
xcodebuild -scheme Muse -only-testing:MuseTests test 2>&1 | tail -5
```

Expected: audit 15/15, no warnings, full unit target green.

- [ ] **Step 7: Commit**

```bash
git add scripts/audit-invariants.sh docs/durable-constraints.md \
        docs/new-build/FEATURE-LEDGER.md CLAUDE.md docs/session-log.md
git commit -m "HDR: audit check, durable constraint, ledger row and session log"
```

---

## Runtime verification (cannot be closed by tests)

Per `verify-runtime-not-just-tests`: a green suite does not prove an HDR photo
looks right. After Task 7, build Release, **`stat` the binary's mtime** to
confirm the running app is actually the new one, and drive it:

1. Open a folder containing a real iPhone gain-map HEIC on an EDR display.
2. The grid tile and the opened hero must look the same brightness.
3. Apply an exposure edit — the photo must not flatten.
4. The histogram must not report clipping on a correctly-exposed HDR frame.
5. Export as PNG (highlights rolled off, not blown) and as HEIC (still HDR).
6. Export the same photo unedited as "Same as original" and confirm the output
   is byte-identical to the input.

Only step 6 is testable; the rest need eyes on an EDR display.
