# Efficiency batch (P3 + P13) — design spec

**Date:** 2026-07-06
**Branch context:** off `feat/next-115` (clean, `main`-equivalent)
**Source:** `docs/perf-and-feature-review-2026-07-03.md` (approved items P3 + P13)
**Scope:** two independent, self-contained performance-efficiency changes, spec'd
together as the "cheap/safe" pair to build momentum. One implementation session,
but each change is separately implementable and separately testable.

Neither change alters any public interface, adds a dependency, or touches the
AI/collection/tag semantics. Both are always-on background CPU/battery savings
with no user-visible behavior change (identical outputs, faster path).

---

## P3 — Vectorize `VectorMath.cosine`

### Problem
`VectorMath.cosine` (`Muse/Muse/Intelligence/Core/VectorMath.swift:4–14`) is a
scalar loop that converts each `Float` to `Double` element-by-element and
accumulates the dot product and both norms in `Double`. It is the inner loop of
BOTH:
- the clusterer's all-pairs cosine (`HybridClusterer.swift:21`), which runs after
  every analyze pass at any moderate library size, and
- semantic search scoring (`SemanticSearch.swift:32`), one pass per committed
  search.

The always-on cost is the clusterer: vectorizing the cosine cuts real background
CPU (and battery) whenever clustering runs, independent of P1/P2 (both deferred).

### Change
Rewrite the body of `cosine(_ a: [Float], _ b: [Float]) -> Double` to use
Accelerate (`import Accelerate`) over the `Float32` arrays:

- `vDSP_dotpr(a, 1, b, 1, &dot, vDSP_Length(n))` → dot product `a·b`
- `vDSP_svesq(a, 1, &na, vDSP_Length(n))` → `Σ aᵢ²`
- `vDSP_svesq(b, 1, &nb, vDSP_Length(n))` → `Σ bᵢ²`

where `dot`, `na`, `nb` are `Float`. Compute the final result in `Double` by
casting the three scalars up:

```
return Double(dot) / (Double(na).squareRoot() * Double(nb).squareRoot())
```

Access the arrays via `withUnsafeBufferPointer` (or pass directly — `[Float]`
bridges to `UnsafePointer<Float>` at the call boundary).

### Invariants preserved (do NOT change)
- **Signature unchanged:** `static func cosine(_ a: [Float], _ b: [Float]) -> Double`.
- **Guards unchanged:** `guard a.count == b.count, !a.isEmpty else { return 0 }`
  stays first; `guard na > 0, nb > 0 else { return 0 }` (zero-norm → 0) stays.
- **Callers untouched:** `HybridClusterer.swift:21`, `SemanticSearch.swift:32` —
  no signature change means no call-site edits.
- `toData` / `fromData` in the same enum are unrelated — leave them.

### Why it's safe
Float-vs-Double accumulation differs on the order of ~1e-6. The consuming
thresholds are coarse — `HybridClusterer.textThreshold = 0.62`,
search threshold `0.45` — so a borderline pair flipping across the threshold is
measure-zero and quality-neutral. No behavior a user can observe.

### TDD
1. **First**, strengthen `EmbedderTests.testCosine`
   (`Muse/MuseTests/EmbedderTests.swift:5`):
   - Add a non-trivial vector equivalence case: pick a fixed non-unit vector pair
     (e.g. `[0.2, 0.5, -0.3, 0.9]` vs `[0.7, -0.1, 0.4, 0.2]`), compute the cosine
     by hand (or with the current scalar reference), and assert the result within
     `accuracy: 1e-6`.
   - Keep the existing `[1,0]/[1,0] → 1`, `/[0,1] → 0`, `/[-1,0] → -1`, `[],[] → 0`
     cases.
   - Confirm the directional relation still holds
     (`EmbedderTests.swift:22–23`: `soccer/football` near > `soccer/teapot` far).
2. **Then** swap the body to the vDSP implementation.
3. All cosine cases stay green at `1e-6`.

---

## P13 — Thumbnail write via `CGImageDestination`

### Problem
`ThumbnailCache.writePNG` (`Muse/Muse/Filesystem/ThumbnailCache.swift:420–425`)
serializes every generated thumbnail as
`NSImage → tiffRepresentation → NSBitmapImageRep → PNG`. `tiffRepresentation` is
AppKit's generic in-memory bitmap serialization used for EVERY thumbnail write
regardless of the source file's format (JPEG/PNG/HEIC/RAW all hit it) — so it is
a source-format-agnostic waste: a full intermediate TIFF encode plus a ~1MB
transient allocation on each write. Thumbnails are written in bulk during prewarm
and first-open of a large folder; the work is off-main so invisible, but it is
real CPU/battery.

### Change
Replace the body of `writePNG(_ image: NSImage, to url: URL)` with a direct
CGImage → PNG encode, following the `CGImageDestination` pattern already used
in-repo at `Muse/Muse/Sharing/Drive/ImageMetadataStripper.swift:168–185`:

1. Extract the `CGImage` from the `NSImage`
   (`image.cgImage(forProposedRect: nil, context: nil, hints: nil)`).
2. Encode into an in-memory `CFMutableData` destination with `UTType.png` as the
   type and image count 1 (`CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil)`),
   `CGImageDestinationAddImage(dest, cg, nil)`, then `CGImageDestinationFinalize(dest)`.
3. `Data.write(to: url, options: .atomic)` on the finalized `CFMutableData`.

**Decision:** encode to an in-memory `CFMutableData` and then `Data.write(…,
options: .atomic)` — NOT a direct `CGImageDestinationCreateWithURL`. This
preserves the current `.atomic` write guarantee exactly and mirrors the
in-repo `ImageMetadataStripper` pattern.

### Invariants preserved (do NOT change)
- **Atomic write to the same URL** via `Data.write(to: url, options: .atomic)` on
  the in-memory-encoded bytes (see Decision above).
- **Fail-closed guard.** Any step failing (`cgImage` nil, destination create nil,
  `Finalize` false) → return, write nothing. Same shape as today's
  `guard … else { return }`.
- **Signature unchanged:** `private nonisolated static func writePNG(_ image: NSImage, to url: URL)`.
- Output stays a PNG at the same pixel dimensions the caller produced.

### Color-profile sanity
`tiffRepresentation`/`NSBitmapImageRep` may carry a color profile that the direct
CGImage path could drop. During implementation, sanity-check that a written
thumbnail looks identical (no color shift) to the current output on a
wide-gamut source image; if a profile must be preserved, pass it through the
destination properties. Thumbnails are display-only, so exact profile fidelity is
not critical, but a visible shift is a regression.

### TDD / verify
1. **Unit round-trip test** (new, in `ThumbnailCacheTests` or a new file):
   construct a known `NSImage` of fixed dimensions, call the write path (extract a
   testable seam if `writePNG` is private — a small internal helper, or test via a
   public generate entry point that lands on disk), read the file back with
   `CGImageSourceCreateWithURL`, and assert: (a) it is a valid PNG
   (`CGImageSourceGetType` == PNG), (b) the pixel dimensions match.
2. **Verify in the running app** (repo rule — green tests are necessary but not
   sufficient): open a fresh, previously-unthumbnailed folder, confirm thumbnails
   generate and render correctly with no color shift or corruption.

---

## Shared guardrails
- No public interface changes; no new linked dependencies (Accelerate and
  ImageIO/CoreGraphics are already linked).
- `xcodebuild -scheme Muse test` must stay green (503+ unit tests).
- Grid virtualization, thumbnail two-tier cache, decode-budget guards, and all
  CLAUDE.md "Durable constraints & gotchas" are untouched by both changes.
- No new user-facing strings → no localization work for this batch.

## Out of scope (explicitly deferred, per the review doc)
- P1 (incremental clustering) and P2 (warm embedding matrix) — deferred to real
  large-library scale. P3 front-runs part of their value but does not attempt
  either fix.
- The thumbnail *decode/downsample* half of prewarm — P13 only cuts the
  write-encode half.
