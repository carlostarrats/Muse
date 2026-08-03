# HDR gain maps — display, edit, export

**Date:** 2026-08-03
**Branch:** `feat/next-153`
**Status:** design approved, not built

## Why

`docs/new-build/muse-photo-foundation.md` §6 line 196 requires it:

> HDR/EDR (iPhone gain-map HEIC is default capture now): load with
> `.expandToHDR`, don't clamp at 1.0, `CIToneMapHeadroom` before display, note
> many CIFilters zero `contentHeadroom`; export must round-trip the gain map

None of it was built. Verified by grep — `gainmap|expandToHDR|toneMapHeadroom|
contentHeadroom` has zero hits in `Muse/`.

Gain-map HEIC is the default iPhone capture format, and Muse's persona shoots a
phone. So the single most common file the user owns is one Muse displays flat
and exports flatter. Side by side with Photos on the same display, the same
photo looks worse in Muse.

Three concrete defects today:

1. **Display is SDR.** `HeroStage.loadFullRes` decodes via
   `CGImageSourceCreateThumbnailAtIndex` into an `NSImage` with no HDR decode
   request, and nothing in the view chain asks for EDR.
2. **The edit chain clamps at both ends.** `RenderContexts` works in
   `extendedLinearSRGB` (correct), but `EditRenderer.decode` uses
   `CIImage(contentsOf:)` with no `expandToHDR`, and both `render` (line 431)
   and `exportFile` (line 454) call `createCGImage(..., colorSpace: sRGB)`.
3. **Export destroys the gain map even when nothing was edited.**
   `ExportFormat.sameAsOriginal` resolves to a concrete format and
   `ImageExportRender` re-encodes at `format: .RGBA8, colorSpace: sRGB`
   (line 110-113). Exporting an untouched iPhone photo returns a flat file.

## What was measured, not assumed

A synthetic HDR pixel (R=4.0, G=2.0, B=1.0 in extended linear sRGB) was written
four ways and read back through `kCGImageSourceDecodeToHDR`:

| Written as | Read back | File size |
|---|---|---|
| PNG 8-bit sRGB | 1.0, 1.0, 1.0 — hard clip | 323 B |
| PNG 16-bit linear sRGB | 1.0, 1.0, 1.0 — hard clip | 779 B |
| PNG 16-bit PQ | 4.00, 2.00, 1.00 — intact | 5,138 B |
| HEIC 10-bit PQ | 4.02, 2.00, 1.01 — intact | 491 B |

Two conclusions this drove:

- **Container is not the constraint; bit depth and colour space are.** PNG
  holds HDR fine at 16-bit PQ. The reason Muse loses HDR is that it writes
  8-bit sRGB everywhere, not that it writes PNG.
- **8-bit sRGB hard-clips rather than tone-maps.** So every deliberate
  HDR→SDR conversion in this design must tone-map explicitly. Handing an
  out-of-range image to `createCGImage` and letting it clamp blows highlights.

## API availability (verified against the MacOSX26.5 SDK)

Muse's floor is macOS 14.6.

| API | Available from | On 14.6 |
|---|---|---|
| `kCGImageSourceDecodeToHDR` | macOS 14.0 | ✅ |
| `kCIImageExpandToHDR` | macOS 14.0 | ✅ |
| `NSImageView.preferredImageDynamicRange` | macOS 14.0 | ✅ |
| SwiftUI `Image.allowedDynamicRange(_:)` | macOS 14.0 (typechecked at 14.6) | ✅ |
| `CIContext.writeHEIF10Representation` | macOS 12.0 | ✅ |
| `CIToneMapHeadroom` filter | macOS 15.0 | ❌ |
| `kCGImageDestinationEncodeToISOGainmap` | macOS 15.0 | ❌ |
| `CIImage.imageBySettingContentHeadroom` | macOS 16.0 | ❌ |

**Consequence:** every leg of this feature works on 14.6 except writing a
*gain-map* HEIC. 14.6 could write PQ HEIC, but a PQ file looks wrong on an
ordinary SDR display, whereas a gain-map file degrades gracefully. So on 14.6
the HDR HEIC export stays SDR rather than shipping a file that looks broken
elsewhere. That is a compatibility choice, not an API wall.

## Design

### 1. One HDR decode seam

New `Muse/Filesystem/HDRDecode.swift`. Platform-neutral (Foundation /
CoreGraphics / CoreImage / ImageIO only), `nonisolated`, unit-testable.

```
struct HDRInfo { let headroom: CGFloat; var isHDR: Bool { headroom > 1.0 } }

static func info(url: URL) -> HDRInfo            // header-only, no full decode
static func decode(url: URL, maxPixel: Int) -> CGImage?   // HDR-aware
static func toneMappedToSDR(_ image: CIImage, headroom: CGFloat) -> CIImage
```

Every image entry point calls this rather than open-coding a decode request.
One place knows about HDR, not five. `info` is header-only so the grid can ask
"is this HDR" without paying for a decode.

`toneMappedToSDR` uses `CIToneMapHeadroom` on macOS 15+, and on 14.6 falls back
to a Reinhard-style highlight roll-off implemented with existing CIFilters. It
must never be a bare clamp — see the measured hard-clip above.

**Decode budget still applies.** `HDRDecode.decode` calls
`ThumbnailCache.withinDecodeBudget` before decoding, same as every other
automatic decode path. HDR does not exempt a file from the 300 MP guard.

### 2. Display — grid and hero must match

The tile and the opened photo have to look the same. A tile that changes
brightness on open reads as a bug.

- **Thumbnail cache format changes from PNG 8-bit to HEIC 10-bit PQ** for
  images whose `HDRInfo.isHDR` is true. SDR images keep writing PNG — no reason
  to re-encode a library that is mostly screenshots and documents.
  `ThumbnailCache.diskPath` currently hardcodes `key + ".png"`; it becomes
  extension-aware, and the loader accepts either.
- **Cache invalidation.** The disk cache key (`cacheKey`) gains a version
  component so existing entries are not served as if they were HDR-aware.
  Cost: up to 2 GB of thumbnails regenerate on first launch after the update.
  This is a one-time cost and the cache regenerates lazily on demand, not in a
  startup sweep.
- **The three display sites get `.allowedDynamicRange(.high)`:**
  `GridView.swift:1295`, `GridView.swift:1357`, `HeroStage.swift:265`.
  Applied unconditionally — it is a ceiling, not a forcing function, so an SDR
  image is unaffected.

HEIC was chosen over PNG 16-bit PQ for the cache on the measured size
difference (491 B vs 5,138 B on the synthetic case — PNG is lossless). These
are 320 px throwaway tiles regenerated on demand; lossy compression at that
size is invisible, and the 2 GB cap has to hold a large library.

### 3. Edit chain carries headroom

`RenderContexts` already works in `extendedLinearSRGB`, so the pipeline
interior needs no change. The clamps are only at the two ends.

- `EditRenderer.decode` passes `.expandToHDR: true` to `CIImage(contentsOf:)`.
  The RAW branch is unaffected — `CIRAWFilter` already produces extended-range
  output.
- `EditRenderer.render` (the preview/display path) stops forcing sRGB. It
  renders to `itur_2100_PQ` at `.RGBA16` when the source is HDR, sRGB `.RGBA8`
  otherwise.
- **Headroom is re-asserted at the end of the chain.** §6 warns that many
  CIFilters zero `contentHeadroom` as they pass an image along. Since
  `imageBySettingContentHeadroom` is macOS 16+, the renderer instead threads
  the source headroom through as a value and hands it to the display/encode
  step explicitly, rather than reading it back off the filtered image.

### 4. Readouts become headroom-aware

`HistogramCompute` is hardcoded 0–255 (`storedHighThreshold = 254.0/255.0`,
lines 46-47, 108-109, 155) and `ClippingMessages` renders copy like *"X% of
pixels are clipped — those areas have lost detail."*

Left alone, an HDR photo's specular highlights sit above 1.0 and every one gets
reported as lost detail. Spec 05's entire purpose is teaching the user what
they are looking at, so this layer would confidently lie about exactly the
photos that matter most.

`HistogramCompute`, `ClippingMessages`, the zebra kernel
(`AppSettings.editorZebraHigh`, default 0.98) and `ToneZoneMath` all take the
image's headroom and scale their thresholds against it. Clipping means "above
the image's headroom," not "above 1.0."

### 5. Export follows the format menu

No new HDR toggle. The format the user already picks decides it:

| Format | Result |
|---|---|
| HEIC | Carries HDR — gain map on macOS 15+, SDR on 14.6 |
| PNG / JPEG / TIFF / WebP | Tone-mapped to SDR (not clipped) |

**Unedited exports copy bytes.** `ExportFormat.sameAsOriginal` on a file with
no edit stack, no resize and metadata retained copies the original file instead
of re-encoding. This preserves the gain map on every OS version including 14.6,
and it is the common case for the target persona. It is also strictly more
faithful than what happens today for SDR files.

**Out of scope, deliberately SDR:** Drive publish, social export, PDF export.
All three target destinations that do not reliably render HDR, and the Drive
path additionally strips metadata — a gain map is auxiliary image data and must
continue to be stripped there.

### 6. `OutputRender` is unchanged

Everything leaving the app still goes through the choke point. HDR changes what
the render *produces*, not who is allowed to call it. The `fileprivate` init
stays as-is.

## Testing

Unit (`MuseTests`), following the existing pure-logic convention:

- `HDRDecodeTests` — headroom detection on an HDR fixture and an SDR fixture;
  round-trip through each cache format; `toneMappedToSDR` never returns values
  above 1.0 and never hard-clips (a 4.0 input must land below 1.0 but above the
  value a 2.0 input lands at — monotonic roll-off, not a clamp).
- `HistogramComputeTests` — an image with headroom 4.0 and highlights at 3.5
  reports 0% clipped; the same image with headroom 1.0 reports clipping.
- `ThumbnailCacheTests` — HDR source writes `.heic`, SDR source writes `.png`,
  loader reads both, `invalidate` drops both extensions.
- `ImageExportRenderTests` — unedited `sameAsOriginal` produces a byte-identical
  file; PNG export of an HDR source contains no values at 1.0-clip; HEIC export
  on 15+ carries a gain map.

Runtime (the part tests cannot close, per
`docs/new-build/FEATURE-LEDGER.md`): an actual iPhone gain-map HEIC opened on
an EDR display, confirming the grid tile and the hero match, that the photo
does not flatten when an edit is applied, and that the histogram does not
report clipping on a correctly-exposed HDR frame.

**14.6 cannot be verified on the development machine.** The `#available`
branches are structured so the 14.6 path is the same code the app runs today
(SDR), which bounds the risk: a 14.6 regression would have to be a
compile-time or availability error, not a behavioural one.

## Non-goals

- Video HDR. Untouched.
- HDR in Drive publish, social export or PDF export.
- Any HDR authoring control (no "make this HDR" slider). Muse carries the
  headroom a photo already has; it does not invent it.
- Raising the minimum macOS version.
