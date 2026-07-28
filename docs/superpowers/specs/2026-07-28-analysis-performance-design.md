# Analysis performance — design spec

**Date:** 2026-07-28
**Branch context:** `feat/next-140`, cut from `main` (`2edd1d9`). NOT off
`feat/next-139` — the menu-bar-icons work there is unmerged and this must land
independently.
**Trigger:** a user reported Muse hanging while analyzing TIFFs from LaserSoft
SilverFast (scanner output). Investigation found the cost is not TIFF-specific —
it is the whole analyze path, and large scans are simply the case that made it
visible.
**Scope:** seven changes to the automatic analysis pipeline. No new
dependencies, no new user-facing UI, no schema change.

---

## Measured baseline

All numbers from `scratchpad/perf/Bench.swift`, a standalone harness that
transcribes the real code path (`VisionServices.loadCGImage:57`,
`VisionServices.analyze:31`, `PaletteExtractor.downsampledRGB:66`) so the timings
describe Muse and not a toy. Fixtures are synthetic 16-bit uncompressed TIFFs
generated from a real 24MP photo at scan dimensions — reproducing SilverFast's
three cost drivers (pixel count, bit depth, non-streamable container) — plus the
seven real RAW files in `~/Desktop/Raw Files`.

Machine: this Mac, Apple Silicon, macOS 26. Timings are wall-clock per file,
memory is `phys_footprint` delta, first-file-in-process (later files in the same
process give polluted deltas and are not quoted).

| Fixture | Current total | Proposed total | Current peak mem | Proposed peak mem |
|---|---|---|---|---|
| `scan_115mp.tif` (9600×12000, 659 MB) | **111,147 ms** | **750 ms** | +1,077 MB | +105 MB |
| `scan_65mp.tif` (8800×7400, 373 MB) | 36,790 ms | 431 ms | +382 MB | +23 MB |
| `scan_20mp.tif` (5500×3600, 113 MB) | 3,901 ms | 196 ms | +396 MB | — |
| `RAW_CANON_1DSM3.CR2` (21 MP) | 1,191 ms | 174 ms | **+3,557 MB** | — |
| `RAW_LEICA_M240.DNG` (24 MP) | 701 ms | 555 ms | **+3,888 MB** | — |

**111 seconds for one file.** Against Muse's strictly serial analyze loop, a
folder of a dozen such scans is ~22 minutes of an app that looks hung. That
matches the report exactly.

The proposed path produced **identical analysis results** on the TIFF fixtures —
same 5 classification labels, same feature print, same dominant color
(`#594523`), same face count, same (zero) OCR text. The speedup is not a quality
tradeoff on this evidence; it is work that was never contributing anything.

### Correction to the initial diagnosis

The pre-measurement hypothesis was "OCR is the dominant cost; the other four
Vision requests downsample internally so full resolution is merely wasted on
them." **The first half is wrong.** Per-request serial timings on the 115 MP
fixture:

| Request | Time |
|---|---|
| `VNClassifyImageRequest` | 21,436 ms |
| `CIAreaAverage` (dominant color) | 20,132 ms |
| `VNRecognizeTextRequest` (.accurate) | 19,827 ms |
| `VNDetectFaceRectanglesRequest` | 11,878 ms |
| `VNGenerateImageFeaturePrintRequest` | **55 ms** |

Only feature print downsamples internally. Classify, faces, and dominant color
all scale with input pixels just as OCR does. So **bounding the decode is the
dominant fix and OCR handling is secondary** — the reverse of the original
ranking. The plan is ordered accordingly.

---

## Decisions taken

### D1 — OCR needs no special-casing at all; bounding the decode is sufficient

The user's instinct (large photographic formats rarely have text worth indexing)
correctly identified the symptom: OCR returned **0 characters** on every
photographic fixture while costing ~20 s on the largest.

Rejected: skipping OCR by format (TIFF/DNG/RAW). SilverFast is scanner software,
and scanning *documents* produces byte-identical 16-bit TIFFs to scanning photos.
A format rule would silently make scanned documents unsearchable with no signal.

Also rejected (initially adopted, then disproved by measurement): a `.fast` OCR
probe on a ~1024px raster with escalation to `.accurate` on a hit. Built the
document fixture to test it and **it failed** — the probe found 0 characters on
a real 5100×6600 document scan that the current path reads 918 characters from,
because at 1024px the body text is ~9px tall. `.fast` is unreliable at low
resolution and is the wrong instrument.

Adopted: **no probe, no format rule.** Measured OCR quality/cost against raster
size on the document fixture (`scratchpad/perf/Sweep.swift`):

| Raster | `.accurate` chars | Time (document) | Time (115 MP photo) |
|---|---|---|---|
| 1024px | 692 / 918 | 208 ms | 14 ms |
| 2048px | **918 / 918** | 95 ms | 18 ms |
| 4096px | **918 / 918** | 112 ms | 35 ms |
| full res | 918 | 1,699 ms | 19,827 ms |

`.accurate` OCR at 4096px is **character-for-character identical to the
full-resolution result** on the document, at 112 ms instead of 1,699 ms — and
costs 35 ms instead of 19,827 ms on the photograph. Bounding the decode makes OCR
cheap enough that no special-casing is warranted. This is strictly better than
the probe: simpler, no threshold to tune, no escalation path, and no risk of a
misjudged probe silently dropping a document's text.

Consequence: none. `StyleKind`'s `ocrLength` inputs (`StyleKind.swift:13,16,28`)
see the same text they see today, so the classification ladder is unchanged.

### D1a — One raster at 4096 for every request

Follow-on measurement (`scratchpad/perf/Raster.swift`) settled whether the
non-OCR requests need a smaller raster than OCR does:

| Fixture | Raster | decode | classify | faces | color |
|---|---|---|---|---|---|
| `scan_115mp.tif` | 2048px | 337 ms | 59 ms (5 labels) | 35 ms | 6 ms |
| `scan_115mp.tif` | 4096px | 537 ms | 17 ms (5 labels) | 13 ms | 14 ms |
| `RAW_SONY.ARW` | 2048px | 238 ms | 7 ms (5 labels) | 5 ms | 3 ms |
| `RAW_SONY.ARW` | 4096px | 321 ms | 17 ms (5 labels) | 12 ms | 13 ms |

Classification results are identical at both sizes, and the per-request cost
difference is single-digit milliseconds. Only the decode differs, by ~200 ms on
the largest file. So a second raster (or an in-memory downscale, measured at
22–108 ms) buys nothing.

**Decision: one `CGImageSourceCreateThumbnailAtIndex` at `maxPixelSize` 4096,
shared by all five Vision requests and the palette extractor.** 4096 rather than
2048 because it costs almost nothing and leaves headroom for documents with
denser text than the fixture's (at 1024px the same document lost 25% of its
characters, so the margin matters).

### D2 — Clustering: vectorize the exact algorithm, do NOT go incremental

`HybridClusterer.cluster` (`HybridClusterer.swift:19–24`) is all-pairs cosine
over every embedding in the library, run after every analyze pass. It is
single-linkage connected components at a 0.62 threshold.

Rejected: incremental/centroid assignment. It is a *different* algorithm —
clusters can no longer merge or split retroactively and results become dependent
on insertion order. For a user-visible feature the failure mode is silent quality
drift, which is the worst kind.

Adopted: keep the algorithm bit-identical and make it fast.
`VectorMath.cosine` recomputes **both vectors' magnitudes on every pair**, so for
an N-file library each vector's norm is recomputed N times. Normalize once up
front, and the similarity collapses to a dot product; compute the dot products as
a tiled `cblas_sgemm` through Accelerate rather than a scalar pair loop. Same
threshold, same union-find, same collections.

Plus a gate: skip `recluster()` entirely when a pass produced no new embeddings,
and stop `analyze(file:)` from rebuilding the whole library after every single
file (`AnalyzePipeline.swift:118`).

Deferred: an approximate-nearest-neighbour prefilter. Additive later if a very
large library ever needs it; not worth the complexity or the approximation now.

### D3 — RAW colour handling is an existing correctness bug, fix it here

Not a performance issue, but discovered by the measurements and entangled with
the decode change, so it must be resolved in the same work.

The two decode paths disagree on dominant colour for RAW files
(`#4a3c44` → `#67555a` on the CR2, `#383d45` → `#6d7275` on the DNG). Cause,
measured directly (`scratchpad/perf/CS.swift`):

| File | Current full decode | Bounded decode |
|---|---|---|
| `RAW_CANON_1DSM3.CR2` | **ITU-R 2100 PQ**, 16 bpc | Display P3, 8 bpc |
| `RAW_LEICA_M240.DNG` | **ITU-R 2100 PQ**, 16 bpc | Display P3, 8 bpc |
| `RAW_SAMSUNG_NX100.SRW` | **ITU-R 2100 PQ**, 16 bpc | sRGB, 8 bpc |
| `RAW_HASSELBLAD_CFV.3FR` | Generic RGB, 8 bpc | Display P3, 16 bpc |

`VisionServices.dominantColor` renders through `CIAreaAverage` with
`workingColorSpace: NSNull()` and `colorSpace: nil` — i.e. **no colour
management at all**. So today Muse reads PQ-encoded HDR component values and
writes them out as if they were sRGB hex. Every RAW file's `dominant_color` in
the database is currently wrong, and that feeds colour tags and colour search
(Polish 23).

Adopted: **explicitly convert to sRGB before any colour extraction**, in both
`dominantColor` and `PaletteExtractor`.

**Correction, measured after implementation** (`scratchpad/perf/ColorCheck.swift`,
which computes an independent CoreGraphics-only reference by drawing into an sRGB
context and averaging by hand — no CoreImage, so it cannot share a bug with the
implementation):

Most of this error was caused by the **decode path, not the colour-management
setting**. The full decode returned PQ; the bounded decode (C1) returns P3 or
sRGB. So C1 alone moved the CR2 from `#4a3c44` to `#67555a` against a reference
of `#6a545a` — from off-by-78 to off-by-4 (sum of absolute channel deltas).

Pinning sRGB on top of the bounded decode is a real but much smaller
improvement:

| File | Unmanaged on bounded decode | sRGB-pinned | Reference |
|---|---|---|---|
| `RAW_CANON_1DSM3.CR2` | `#67555a` (off 4) | `#6a5459` (off **1**) | `#6a545a` |
| `RAW_HASSELBLAD_CFV.3FR` | `#584d31` (off 10) | `#5a4c2c` (off **2**) | `#5a4b2b` |
| `RAW_LEICA_M240.DNG` | `#6d7174` (off 2) | `#6b7274` (off **1**) | `#6b7174` |
| `RAW_SONY_ILCA-77M2.ARW` | `#564627` (off 7) | `#59451e` (off **6**) | `#584523` |
| `RAW_SAMSUNG_NX100.SRW` | `#6a645e` (off 0) | `#6a645e` (off 0) | `#6a645e` |

So the honest statement is: **C1 fixed the large RAW colour error; D3 removes the
remaining drift and, more importantly, makes correctness structural rather than
incidental** — the bounded decoder's output space is a lottery (P3 for some
files, sRGB for others), so without pinning, correctness depends on which space
ImageIO happens to pick per format.

Consequence to accept and disclose: existing RAW files produce different
(correct) colour values on re-analysis. Colour tags and colour-search results for
RAW will shift. This is a fix, not a regression, but it is user-visible.

### D4 — Out of scope, documented not fixed

Two decode failures found while probing, both pre-existing and unrelated to
performance:

- **`RAW_FUJI_E900.RAF` cannot be decoded at all.** Header reports `-1×-1`,
  `NSImage` yields no `CGImage`, thumbnail returns nil. It is silently never
  analyzed. This is layer 2 of the three-layer RAW model (decode = Apple's
  codec); Muse cannot fix it.
- **`RAW_MAMIYA_ZD.MEF` opens as `public.tiff` at 144×192.** macOS has no Mamiya
  codec, so ImageIO sees only the container's embedded preview. Muse analyzes the
  preview, not the photo.

Both belong in the known-limitations list, not this change.

**Also checked and found NOT to be a problem:** the concern that
`withinDecodeBudget` reads `CGImageSourceCopyPropertiesAtIndex(src, 0, …)` and
might be measuring an embedded preview rather than the real raster for RAW. Probed
directly — every supported RAW container reports one image at index 0 with the
true full dimensions and `GetPrimaryImageIndex == 0`. The guard is sound. (The
MEF's 144×192 is the D4 codec gap, not an index bug.)

---

## The seven changes

Ordered by measured impact.

### C1 — Bound the decode fed to Vision
`VisionServices.loadCGImage` (`VisionServices.swift:57–70`) replaces
`NSImage(contentsOf:)` + `cgImage(forProposedRect:)` with
`CGImageSourceCreateThumbnailAtIndex` at `maxPixelSize` 4096 (per D1a).
This is the single largest win — it subsumes what the OCR probe was for — and it
is the whole of C1: 111 s → sub-second on the 115 MP fixture, peak memory from
+1,077 MB to +105 MB. Keep `withinDecodeBudget` as the bomb guard; it is still
the only thing standing between the app and a declared-enormous file, and the
probe confirmed it reads true dimensions (D4).

### C2 — *(withdrawn)* OCR probe
Per D1, disproved by measurement before implementation. OCR stays exactly as it
is today — same request, same `.accurate` level, same language correction, same
position in the five-way `async let` fan-out. It simply runs on the bounded
raster from C1 and becomes ~560× cheaper on a large photo as a side effect. No
code change of its own. Retained as a numbered item so the spec, the plan, and
the session log agree on why there is no probe.

### C3 — Vectorized clustering + recluster gate
Per D2. Touches `VectorMath` (add a batch similarity entry point),
`HybridClusterer.cluster`, and `CollectionsEngine.recluster`/
`AnalyzePipeline.analyze(file:)` for the gate.

### C4 — Parallelize the analyze loop
`AnalyzePipeline.analyze(folder:)` (`AnalyzePipeline.swift:265–273`) is a plain
serial `for`. Move to a bounded-concurrency task group. Constraint: the progress
counters (`completed`/`progress`/`current`) are `@Published` on a `@MainActor`
class and currently assume serial ordering — they must be updated to a
completion-count model, not an index model, or the pill will jump around.

### C5 — One decode per file
`VisionTagger.swift:21` calls `PaletteExtractor.weightedPalette(for: url)`,
which opens and decodes the file a second time (`PaletteExtractor.swift:72`).
Pass the already-decoded `CGImage` through instead. Measured second-decode cost
on the 115 MP fixture: 851 ms. Fold the D3 sRGB conversion in here.

### C6 — Size-aware thumbnail gate
`ThumbnailCache.gate` is a flat 8 permits regardless of image size
(`ThumbnailCache.swift:122`), so eight 659 MB scans decode simultaneously on
folder open. Weight a permit by declared pixel count from the (cheap) header
read so large images take more of the budget.

### C7 — Batched DB writes + wider hashing
`analyzeOne` performs 2–3 separate write transactions per file (main row,
embedding, sidecar). Batch across files. Separately, `Indexer.indexBatch` hashes
2 files in flight (`Indexer.swift`); raise to 4 for import throughput. Both are
small; they ride along rather than justifying their own change.

---

## Non-goals

- No change to what is analyzed, or to tag/collection semantics beyond the D3
  colour correction.
- No new Preferences toggle. The probe is automatic.
- No change to the Vision model set or thresholds.
- No attempt to fix RAF/MEF decode (D4).

## Verification

Per the standing rule that a green build and green units are not evidence a
runtime feature works: every change is verified in the **running app** against
`~/Desktop/Raw Files` and the synthetic scan fixtures, not only by unit test.
The harness stays in the scratchpad for before/after comparison at each step.

Specifically required before this is called done:
1. Re-analysis of a scan-TIFF folder completes in seconds, verified in-app.
2. Collections produced by the vectorized clusterer are **identical** to the
   scalar clusterer on the same embedding set — pinned by a unit test, not by eye.
3. A scanned-document TIFF still produces full OCR text (918 characters on the
   fixture — an exact match against the pre-change result, not "roughly the
   same") and is still findable by a word from its body via search.
4. RAW dominant colour matches an independently-computed sRGB reference.
