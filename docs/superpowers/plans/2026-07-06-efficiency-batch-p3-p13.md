# Efficiency Batch (P3 + P13) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Cut always-on background CPU/battery by vectorizing the embedding cosine (P3) and by dropping the TIFF round-trip from the thumbnail PNG write (P13).

**Architecture:** Two independent, self-contained changes. P3 rewrites `VectorMath.cosine`'s scalar loop with Accelerate vDSP over the Float32 arrays. P13 replaces `ThumbnailCache.writePNG`'s `tiffRepresentation → NSBitmapImageRep → PNG` with a direct `CGImage → CGImageDestination(PNG)` encode into an in-memory buffer, then an atomic write. No public interface changes; no new user-facing strings; no new linked dependencies.

**Tech Stack:** Swift, Accelerate (`vDSP`), ImageIO/CoreGraphics (`CGImageDestination`), AppKit (`NSImage`), XCTest.

**Spec:** `docs/superpowers/specs/2026-07-06-efficiency-batch-p3-p13-design.md`

## Global Constraints

- Signatures unchanged: `VectorMath.cosine(_ a: [Float], _ b: [Float]) -> Double`; `ThumbnailCache.writePNG(_ image: NSImage, to url: URL)` stays `private nonisolated static`.
- Guard/early-return semantics preserved verbatim: cosine returns `0` on count-mismatch/empty and on zero-norm; the PNG write is fail-closed (any failure → write nothing).
- Atomic write preserved: PNG bytes land via `Data.write(to: url, options: .atomic)`.
- `xcodebuild -scheme Muse test` must stay green (503+ unit tests). Run in an English host locale.
- No new dependencies — Accelerate, ImageIO, and UniformTypeIdentifiers are already available (ImageIO + UniformTypeIdentifiers already imported in `ThumbnailCache.swift:21–22`).
- Verify P13 in the running app after tests pass (repo rule: green tests necessary but not sufficient).

---

### Task 1: P3 — Vectorize `VectorMath.cosine`

**Files:**
- Modify: `Muse/Muse/Intelligence/Core/VectorMath.swift:1-14`
- Test: `Muse/MuseTests/EmbedderTests.swift:5-9` (extend `testCosine`)

**Interfaces:**
- Consumes: nothing new.
- Produces: unchanged `VectorMath.cosine(_ a: [Float], _ b: [Float]) -> Double`. Callers `HybridClusterer.cluster` and `SemanticSearch.semanticIDs` are untouched.

- [ ] **Step 1: Write the failing test**

Add a numerical-equivalence case to `EmbedderTests` (below the existing `testCosine`). It computes the reference cosine with an explicit Double-precision loop (the mathematical definition) and asserts the production function matches within `1e-6`. This encodes the reference so the vDSP body can be swapped safely.

```swift
func testCosineVectorizedMatchesDoubleReference() {
    let a: [Float] = [0.2, 0.5, -0.3, 0.9]
    let b: [Float] = [0.7, -0.1, 0.4, 0.2]
    var dot = 0.0, na = 0.0, nb = 0.0
    for i in a.indices {
        dot += Double(a[i]) * Double(b[i])
        na  += Double(a[i]) * Double(a[i])
        nb  += Double(b[i]) * Double(b[i])
    }
    let expected = dot / (na.squareRoot() * nb.squareRoot())
    XCTAssertEqual(VectorMath.cosine(a, b), expected, accuracy: 1e-6)
    // Non-equal-length and empty guards still hold.
    XCTAssertEqual(VectorMath.cosine([1, 2, 3], [1, 2]), 0.0, accuracy: 1e-6)
}
```

- [ ] **Step 2: Run the test to verify it passes against the CURRENT scalar impl**

Run: `xcodebuild -scheme Muse -destination 'platform=macOS' test -only-testing:MuseTests/EmbedderTests/testCosineVectorizedMatchesDoubleReference`
Expected: PASS (the current scalar loop already satisfies it). This is the baseline the refactor must not break. (The `1e-6` tolerance is what makes it a swap-safety guard rather than a bit-exact pin.)

- [ ] **Step 3: Vectorize the implementation**

Replace the body of `VectorMath.swift`:

```swift
import Foundation
import Accelerate

nonisolated enum VectorMath {
    static func cosine(_ a: [Float], _ b: [Float]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        let n = vDSP_Length(a.count)
        var dot: Float = 0, na: Float = 0, nb: Float = 0
        vDSP_dotpr(a, 1, b, 1, &dot, n)   // dot = a·b
        vDSP_svesq(a, 1, &na, n)          // na  = Σ aᵢ²
        vDSP_svesq(b, 1, &nb, n)          // nb  = Σ bᵢ²
        guard na > 0, nb > 0 else { return 0 }
        return Double(dot) / (Double(na).squareRoot() * Double(nb).squareRoot())
    }
    static func toData(_ v: [Float]) -> Data {
        v.withUnsafeBufferPointer { Data(buffer: $0) }
    }
    static func fromData(_ d: Data) -> [Float] {
        d.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }
}
```

- [ ] **Step 4: Run the cosine tests to verify they pass**

Run: `xcodebuild -scheme Muse -destination 'platform=macOS' test -only-testing:MuseTests/EmbedderTests/testCosine -only-testing:MuseTests/EmbedderTests/testCosineVectorizedMatchesDoubleReference`
Expected: PASS — both the original `testCosine` (`1,0`/`0,1`/`-1,0`/empty cases) and the new equivalence case hold within `1e-6`.

- [ ] **Step 5: Commit**

```bash
git add Muse/Muse/Intelligence/Core/VectorMath.swift Muse/MuseTests/EmbedderTests.swift
git commit -m "perf(P3): vectorize VectorMath.cosine with Accelerate vDSP"
```

---

### Task 2: P13 — Thumbnail PNG write via `CGImageDestination`

**Files:**
- Modify: `Muse/Muse/Filesystem/ThumbnailCache.swift:420-425` (`writePNG`), adding an internal, testable `encodePNG` helper.
- Test: `Muse/MuseTests/ThumbnailWriteTests.swift` (new file)

**Interfaces:**
- Consumes: nothing new (`ImageIO` + `UniformTypeIdentifiers` already imported at `ThumbnailCache.swift:21–22`).
- Produces: a new `nonisolated static func encodePNG(_ image: NSImage) -> Data?` on `ThumbnailCache` (internal access — `@testable` reachable). `writePNG` now delegates to it. `writePNG` signature unchanged.

- [ ] **Step 1: Write the failing test**

Create `Muse/MuseTests/ThumbnailWriteTests.swift`. It builds a known solid-color `NSImage` from a `CGImage` of exact dimensions, encodes it via the new `encodePNG` seam, and asserts the bytes are a valid PNG at the expected pixel size.

```swift
import XCTest
import AppKit
import ImageIO
import UniformTypeIdentifiers
@testable import Muse

final class ThumbnailWriteTests: XCTestCase {
    private func makeImage(width: Int, height: Int) -> NSImage {
        let cs = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(data: nil, width: width, height: height,
                            bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let cg = ctx.makeImage()!
        return NSImage(cgImage: cg, size: NSSize(width: width, height: height))
    }

    func testEncodePNGProducesValidPNGAtExpectedSize() {
        let image = makeImage(width: 12, height: 9)
        guard let data = ThumbnailCache.encodePNG(image) else {
            return XCTFail("encodePNG returned nil")
        }
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else {
            return XCTFail("bytes were not a decodable image")
        }
        XCTAssertEqual(CGImageSourceGetType(src), UTType.png.identifier as CFString)
        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        XCTAssertEqual(props?[kCGImagePropertyPixelWidth] as? Int, 12)
        XCTAssertEqual(props?[kCGImagePropertyPixelHeight] as? Int, 9)
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `xcodebuild -scheme Muse -destination 'platform=macOS' test -only-testing:MuseTests/ThumbnailWriteTests/testEncodePNGProducesValidPNGAtExpectedSize`
Expected: FAIL to compile — `ThumbnailCache.encodePNG` does not exist yet ("type 'ThumbnailCache' has no member 'encodePNG'").

- [ ] **Step 3: Add `encodePNG` and route `writePNG` through it**

Replace `writePNG` (`ThumbnailCache.swift:420-425`) with the delegating pair. No new imports (ImageIO + UniformTypeIdentifiers already present).

```swift
/// Encode an NSImage to PNG bytes via CGImageDestination — no TIFF round-trip.
/// Returns nil (fail-closed) if the image has no CGImage or encoding fails.
nonisolated static func encodePNG(_ image: NSImage) -> Data? {
    guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
    let out = NSMutableData()
    guard let dest = CGImageDestinationCreateWithData(
        out as CFMutableData, UTType.png.identifier as CFString, 1, nil
    ) else { return nil }
    CGImageDestinationAddImage(dest, cg, nil)
    guard CGImageDestinationFinalize(dest) else { return nil }
    return out as Data
}

private nonisolated static func writePNG(_ image: NSImage, to url: URL) {
    guard let data = encodePNG(image) else { return }
    try? data.write(to: url, options: .atomic)
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `xcodebuild -scheme Muse -destination 'platform=macOS' test -only-testing:MuseTests/ThumbnailWriteTests/testEncodePNGProducesValidPNGAtExpectedSize`
Expected: PASS — valid PNG, 12×9.

- [ ] **Step 5: Run the full suite**

Run: `xcodebuild -scheme Muse -destination 'platform=macOS' test`
Expected: PASS — all 503+ tests green (no thumbnail-dependent test regressed).

- [ ] **Step 6: Verify in the running app**

Build & run. Add (or re-open) a folder that has NOT been thumbnailed before so the write path executes on fresh generation. Confirm: thumbnails generate and render correctly in the grid, with no color shift, banding, or corruption versus a wide-gamut source image. (This is the color-profile sanity check the spec calls for; `tiffRepresentation` carried a profile the direct path may not — if a shift appears, pass the source profile through the destination properties before shipping.)

- [ ] **Step 7: Commit**

```bash
git add Muse/Muse/Filesystem/ThumbnailCache.swift Muse/MuseTests/ThumbnailWriteTests.swift
git commit -m "perf(P13): write thumbnails via CGImageDestination, drop TIFF round-trip"
```

---

## Self-Review

**Spec coverage:**
- P3 vDSP cosine (spec §P3) → Task 1. ✅ Signature/guards preserved; equivalence test added first.
- P13 CGImageDestination write (spec §P13) → Task 2. ✅ In-memory encode + atomic write (the spec's explicit Decision); fail-closed guard preserved; round-trip test + running-app color-profile verify.
- Shared guardrails (no interface change, no new deps, tests green) → Global Constraints + Task steps. ✅

**Placeholder scan:** none — every code step shows complete code; every run step gives an exact command + expected result.

**Type consistency:** `encodePNG(_:) -> Data?` defined in Task 2 Step 3 and consumed by both `writePNG` and the Task 2 test under the same name/signature. `cosine(_:_:)` unchanged throughout. ✅
