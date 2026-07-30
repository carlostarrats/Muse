# Spec 03 — Culling & Search Phase 2: full implementation spec

*Derived from `pre-spec-03-culling-and-search-phase2.md` + `muse-photo-foundation.md`
(§13 decision log is authoritative) + `DECISIONS.md` (the binding build-level layer from
Specs 01–02). Build-level expansion: exact files, exact schema, exact seams, exact tests.
Written before implementation. Verified against the codebase at `6fdce05` (`feat/editing`)
— as of that commit **no Spec 01/02 code exists in the tree** (migrations end at
`v12_smart_collections`); everything referenced from Specs 01–02 is referenced as
specified there, and every reference to existing code was read from the actual source.*

---

## 0. What this spec does, does not, and depends on

**Does:** the CLIP semantic engine (on-demand model download, image+text encoders, a
`clip_embeddings` table, brute-force retrieval structured for later memory-mapping);
similar-image search (`similar:` token, Find Similar, image-drop, region similarity in
the viewer); auto-growing albums (a `.similar` smart-rule case with a threshold slider);
the natural-language search layer (Foundation Models, macOS 26+, always rendered as
editable tokens); side-by-side compare (2–4-up, synchronized zoom/pan, keyboard rating);
focus peaking (ported from Surface Camera); a sharpness score; the ephemeral cull state
(keep/reject → stars/trash, then gone); and faces-lite (face/pet counts + portrait/group,
as search tokens).

**Does not:** face identity/clustering/naming (deferred project — AuraFace path in
foundation §4; InsightFace/EdgeFace are non-commercial, never). Any editing (Specs
04–05). Import surfaces (Spec 06). Sharing changes. Battery/thermal-aware throttling
(Spec 06 — the `.utility`-priority + per-launch-cap posture is the baseline here, per
DECISIONS).

**Depends on:**

| Dependency | Needed by | Nature |
|---|---|---|
| Spec 02 §7 (Search phase 1: `SearchToken`/`SearchQueryParser`/`PhotoSearch`/`SearchFacets`/chip bar) | `similar:`/`faces:`/`pets:`/`is:` tokens, NL layer, Places-style programmatic search | **Hard** — these tokens are grammar + SQL additions to that module |
| Spec 02 §1 migrations (v13–v17) | migration numbering only | This spec registers **v18–v19**; it does not read v13–v17 columns except `photo_meta.capture_date` for token-result ordering, which Spec 02 already owns |
| Spec 01 §3 seams (`EditStackIndex` etc.) | nothing | Compare/cull/CLIP all read originals; when Spec 04 lands, compare's decode path must route through the same effective-dimensions/consumer rules — noted in §8, no work here |
| Existing code | everything else | verified line references throughout |

Compare, peaking, sharpness, and the cull state have **no** Spec 01/02 dependency and
can land first if build order demands it (§13).

**Migration numbering:** v18 = `clip_embeddings` · v19 = `photo_traits`. Future specs
continue at v20.

---

## 1. CLIP engine

### 1.1 Model choice and the license gate (pre-spec ⚠ GATE)

Primary: **MobileCLIP-S2** (Apple, Core ML, ~3.6 ms/image on ANE, 512-d joint space).
The *code* (apple/ml-mobileclip) is MIT; the *weights* are under Apple's ML Research
Model TOU — **a legal read is required before shipping them in a paid app** (owner step,
§14). Fallback with clean terms: self-converted **OpenCLIP ViT-B/32** (512-d as well).

The build is **model-agnostic by construction** so the gate never blocks code:

```swift
// Intelligence/Clip/ClipModel.swift
nonisolated struct ClipModel: Sendable {
    let name: String            // "mobileclip-s2" | "openclip-vitb32"
    let generation: Int         // bumped on ANY artifact change; drives re-embed
    let dimension: Int          // 512 for both candidates
    let imageInputSide: Int     // 256 (MobileCLIP-S2) / 224 (ViT-B/32)
    let downloadBytes: Int64    // shown in the offer UI; measured at conversion time
    let manifestURL: URL        // ClipConfig.modelBaseURL + "/\(name)-g\(generation)/manifest.json"

    /// The one shipped model. Swapping = edit this constant + bump generation.
    static let current: ClipModel = …
}
```

Both encoders share one embedding space, so text→image and image→image are the same
retrieval path with different query vectors (foundation §4 — "search-by-image = embed
the image instead of the text — free").

### 1.2 Artifacts, conversion, hosting

Checked-in `scripts/make-clip-coreml.py` (run on the dev machine, coremltools):
converts the chosen weights to **fp16** Core ML — `ImageEncoder.mlmodelc`,
`TextEncoder.mlmodelc` — plus the CLIP BPE `vocab.json` + `merges.txt`. CLIP's input
normalization (mean `0.48145466, 0.4578275, 0.40821073`, std `0.26862954, 0.26130258,
0.27577711`) is **baked into the image encoder's input layer** by the script, so the app
supplies a plain RGB pixel buffer and cannot drift from the training preprocessing.

Packaging: one `model.zip` of the four artifacts, split into **≤ 20 MiB chunks**
(`model.zip.000`, `.001`, …) plus a `manifest.json`:

```json
{ "version": 1, "name": "mobileclip-s2", "generation": 1,
  "totalBytes": 204812345, "sha256": "…", "chunks": ["model.zip.000", "…"] }
```

Hosting: the **existing Cloudflare Pages site** (`DriveConfig.shareBaseURL`,
`Sharing/Drive/DriveConfig.swift:25` — `https://muse-share.pages.dev`), under
`/models/<name>-g<generation>/`. Chunking exists because Pages caps individual assets at
25 MiB; the alternative (an R2 bucket) is acceptable if the owner prefers, with the same
manifest contract — the client code is identical either way. Zero new infrastructure by
default, same rationale as the announcements channel.

Client rules (all in `ClipModelStore`, §1.3):

- Download is **strictly user-initiated** (§1.6) — never automatic, never at launch.
- Reassemble chunks → verify the **whole-file SHA-256 against the manifest** → unzip
  into `Application Support/Muse/Models/<name>-g<generation>/` → load-test both encoders
  once. Any failure at any step deletes the partial directory and reports a plain error
  (**fail closed** — the exact posture of `GeoNamesDataset.load`'s bounded inflate).
- The manifest itself is fetched from the same pinned host; response capped at 16 KB;
  unknown `version` refused. `.ephemeral` `URLSession`, nothing sent beyond the GET.
- On a generation upgrade, older `Models/<name>-g<n>/` directories are deleted after the
  new one verifies.

### 1.3 `Intelligence/Clip/ClipModelStore.swift` — download/lifecycle store (Pattern B)

```swift
@MainActor final class ClipModelStore: ObservableObject {
    static let shared = ClipModelStore()
    enum ModelState: Equatable {
        case absent
        case downloading(progress: Double)   // 0…1, chunk-weighted
        case installed                       // verified on disk, ClipModel.current.generation
        case failed(message: String)         // shown in Settings; retryable
    }
    @Published private(set) var state: ModelState
    /// True when `state == .installed` — the single gate every CLIP feature checks.
    var isReady: Bool { … }
    func download()      // user-initiated only; no-op unless .absent/.failed
    func cancelDownload()
    func remove()        // Settings "Remove Model" — deletes the directory, state → .absent
}
```

- `init` probes the disk synchronously (directory exists + a `verified` marker file
  written after the post-install load test) — no model load at launch.
- On `state → .installed`: kick `DeepAnalysisBackfill.run()` (§3.3) and
  `ClipPromptVectors.refreshAll()` (§6.4) as fire-and-forget `Task`s, then
  `SearchFacets.shared.refresh()` when the backfill completes (existing Spec 02 chain
  shape).
- AppState integration cost: **zero** — no view reads this through AppState; Settings
  and the offer card observe the store directly.

### 1.4 `Intelligence/Clip/ClipTokenizer.swift` — pure Swift BPE

The CLIP text encoder needs CLIP's byte-pair-encoding tokenizer (49,408-token vocab,
77-token context, `<|startoftext|>`/`<|endoftext|>`). No dependency is added (DECISIONS:
dependency count target is one): a pure `nonisolated struct ClipTokenizer` (~150 LOC)
loads `vocab.json`/`merges.txt` from the model directory, implements lowercasing + the
published BPE merge loop, pads/truncates to 77.

```swift
nonisolated struct ClipTokenizer: Sendable {
    init?(modelDir: URL)                       // nil if vocab/merges missing/corrupt
    func encode(_ text: String) -> [Int32]     // length exactly 77
}
```

Unit-tested against **fixture pairs generated by the conversion script** (the script
writes `tokenizer-fixtures.json`: 20 strings with their reference token ids from the
Python tokenizer) — the two implementations must not diverge, same rule as
`PhotoHeaderReader` vs `FileMetadata`.

### 1.5 `Intelligence/Clip/ClipEngine.swift` — the encoders

```swift
actor ClipEngine {
    static let shared = ClipEngine()
    /// 512-d, L2-NORMALIZED. nil when the model isn't installed or encode fails.
    func embedImage(_ cgImage: CGImage) async -> [Float]?
    func embedText(_ text: String) async -> [Float]?
    /// Drop the loaded MLModels (called when a pass ends; also on memory pressure).
    func unload()
}
```

- An `actor`, so `MLModel` access serializes without locks; loads both encoders lazily
  from `Application Support` on first call (`MLModelConfiguration.computeUnits = .all`
  → ANE), holds them **weakly-releasable like `GeoNamesDataset`**: the callers that run
  passes (`DeepAnalysisBackfill`, `analyzeOne`) hold a scoped strong token
  (`ClipEngine.retain()` → `defer { release() }`), and with no token outstanding
  `unload()` after a short grace. Browsing carries zero standing model cost.
- `embedImage` preprocessing: `ClipPreprocess.pixelBuffer(from:side:)` — aspect-**fill**
  scale + center crop to `imageInputSide`, sRGB. Pure, unit-tested for crop math.
- Output vectors are **L2-normalized at the engine boundary** so cosine similarity
  downstream is a plain dot product (`VectorMath.normalizedMatrix` precedent,
  `Intelligence/Core/VectorMath.swift:32`). Zero-norm output → nil.
- `embedText` returns nil for empty/whitespace input (the `SentenceEmbedder.embed`
  contract, `SentenceEmbedder.swift:19-23`).

### 1.6 Download UX + network-doctrine amendment

**Settings** gains a "Search" section (above "Google Drive", `SettingsView`): a status
row (Not downloaded ~size / Downloading n% / Installed / error + Retry), a
Download / Cancel / Remove `ModalButton` (durable constraint: every modal-adjacent
button is `ModalButton`), and one caption line: *"Search understands what's in your
photos. The model runs entirely on this Mac — nothing you search ever leaves it."*
(all `String(localized:)`).

**One-time offer card:** the first time a committed search parses to **no tokens** with
free text of ≥ 3 words while `ClipModelStore.state == .absent` and the offer was never
shown, present a `ModalMessageCard` at the shell: title "Smarter Search", body explains
the one-time ~N MB on-device download, buttons Download / Not Now. "Not Now" sets
`AppSettings.clipOfferSeenKey` and the card never auto-shows again (Settings remains the
path). Registered in `AppState.modalPresented` (computed at `AppState.swift:514-522`)
like every card. This is the moment the feature matters, which beats a buried toggle;
it is still strictly opt-in.

**Doctrine change (CLAUDE.md network policy + DECISIONS amendment):** app-initiated
network paths become **four**: (1) Drive share, (2) `announcements.json`,
(3) custom-domain Worker (future), **(4) search-model download — user-initiated only
(Settings button or the one-time offer card), pinned host, manifest-hash-verified, fail
closed, nothing sent**. DECIDED #26 ("models downloaded on demand, never bundled")
forced this path to exist; recording it keeps "everything else stays blocked" true.

---

## 2. Schema

House rules per DECISIONS: registered at the end of `Database.makeMigrator()`
(`Database/Database.swift:63`), GRDB DSL, records in `Database/Records.swift`
(snake_case, `Codable + FetchableRecord + MutablePersistableRecord`, inserted as `var`),
every child table cascades on file delete (`Housekeeping.pruneUnreachable` unchanged).

### 2.1 `v18_clip_embeddings`

```swift
migrator.registerMigration("v18_clip_embeddings") { db in
    try db.create(table: "clip_embeddings") { t in
        t.column("file_id", .text).primaryKey()
            .references("files", onDelete: .cascade)
        t.column("embedded_hash", .text).notNull()      // content_hash we embedded
        t.column("model_generation", .integer).notNull() // ClipModel.current.generation
        t.column("vector", .blob)                        // 512 × Float16 LE = 1024 bytes; NULL = undecodable
    }
}
```

- **Content-keyed** (same grain as `palette`/`feature_print`/`photo_meta`): the
  embedding derives from the bytes; byte-identical copies share it; edit-in-place splits
  the row and the `embedded_hash` mismatch triggers re-embed. Deliberately NOT the
  tags/notes grain.
- **`vector` is nullable — a NULL vector is the attempted-marker for an undecodable
  file** (the `places` NULL-place pattern, per DECISIONS "attempted-markers for all
  header-derived data"). Without it, a Fuji `.RAF` Apple's codec can't open would be
  re-tried by the backfill every launch — the `analyzed_hash`-NULL retry-loop bug shape.
  Dataless iCloud files are skipped **without stamping** (they embed once local).
- Re-embed selection: row missing, `embedded_hash != content_hash`, or
  `model_generation != ClipModel.current.generation` (a model upgrade re-embeds the
  library — decode-bound, spread across launches by the backfill cap).
- **fp16 storage** (binding #24 "fp16 everywhere"): 50k photos ≈ 50 MB, 800k ≈ 800 MB
  on disk — and the retrieval path never assumes it fits in RAM (§4.1). Arm64 Swift has
  native `Float16`; converters live beside the other vector helpers:

```swift
// Intelligence/Core/ClipVectors.swift — nonisolated enum, unit-tested
static func toData(_ v: [Float]) -> Data        // Float → Float16 LE
static func fromData(_ d: Data) -> [Float]?     // nil when byteCount != dimension*2
```

`fromData` refuses wrong-length blobs — vectors from different generations must never
pair (the `FeaturePrints.distance` length-mismatch rule from Spec 02 §6.1, same class).

Record: `ClipEmbeddingRow` (`file_id`, `embedded_hash`, `model_generation`,
`vector: Data?`).

### 2.2 `v19_photo_traits`

```swift
migrator.registerMigration("v19_photo_traits") { db in
    try db.create(table: "photo_traits") { t in
        t.column("file_id", .text).primaryKey()
            .references("files", onDelete: .cascade)
        t.column("traits_scanned_hash", .text).notNull() // content_hash we scanned
        t.column("traits_version", .integer).notNull()   // PhotoTraits.currentVersion
        t.column("face_count", .integer)                 // nil = detection failed
        t.column("largest_face_frac", .real)             // largest face bbox area ÷ image area
        t.column("face_quality", .real)                  // max VNFaceCaptureQuality in the image
        t.column("pet_count", .integer)                  // VNRecognizeAnimalsRequest (cat/dog)
        t.column("sharpness", .real)                     // log10 variance-of-Laplacian @1024px
    }
    try db.create(index: "photo_traits_faces_idx", on: "photo_traits", columns: ["face_count"])
    try db.create(index: "photo_traits_pets_idx", on: "photo_traits", columns: ["pet_count"])
}
```

- **One table for faces + pets + sharpness, deliberately** (deviation D2): all three are
  Vision/raster-derived per-photo scalars computed from the **same single bounded
  decode** in the same pass, backfilled by the same launch pass, guarded by the same
  marker. Splitting them into per-feature tables doubles markers and decode passes for
  nothing. `traits_version` (`PhotoTraits.currentVersion = 1`) covers future trait
  additions: a version bump makes the backfill re-scan, so a later spec can add a column
  without a new marker. Content-keyed like `photo_meta`, same rationale.
- No index on `sharpness`/`face_quality`/`largest_face_frac` — they have no v1 token;
  they're read per-file (compare, INFO card) and inside `is:` queries that already
  narrow on the indexed `face_count`.
- `face_count = 0` is a real answer ("scanned, no faces"); a missing row means
  "never scanned" — `faces:0` matches only scanned files (§10.2, recorded).

Record: `PhotoTraitsRow` (all eight fields).

---

## 3. Analysis integration + backfill

### 3.1 `VisionServices` additions

`VisionServices.analyze` (`Intelligence/Vision/VisionServices.swift:36-67`) already runs
five concurrent requests on one bounded 4096px raster, including
`VNDetectFaceRectanglesRequest` (count only, `:180-186`). Changes:

- `detectFaces` becomes `detectFaceTraits` returning
  `(count: Int, largestFrac: Double?, maxQuality: Double?)`: the same
  `VNDetectFaceRectanglesRequest` results now also yield
  `max(boundingBox.width * boundingBox.height)` (Vision boxes are normalized, so the
  product IS the area fraction — orientation-safe), and a second
  `VNDetectFaceCaptureQualityRequest` performed on the same handler yields
  `faceCaptureQuality` (max across faces). Quality scores are comparable only within a
  Vision revision — acceptable, because Muse uses them **relatively within one compare
  session on one machine** (§8.5); recorded limitation.
- New `detectAnimals`: `VNRecognizeAnimalsRequest`, `pet_count` = observations with
  confidence ≥ `VisionServices.petConfidenceFloor = 0.5` (named constant).
- Both run inside the existing `async let` fan-out (seven concurrent requests instead of
  five) via the existing single-resume `runRequest` wrapper (`:121-140` — the
  double-resume trap is already solved there; new requests must go through it).
- `VisionResult` gains `largestFaceFrac: Double?`, `faceQuality: Double?`,
  `petCount: Int`, `sharpness: Double?`.
- Sharpness is computed from the same decoded raster (`decodedImage` reuse rule,
  `VisionResult.decodedImage` doc `:25-29` — never decode twice):

```swift
// Intelligence/Core/SharpnessScore.swift — nonisolated enum, pure, unit-tested
/// log10(variance of 3×3 Laplacian) over the LUMINANCE of the image downsampled
/// to at most `normalizedLongEdge` (1024) px. Downsampling to a FIXED long edge is
/// what makes scores comparable across resolutions — variance-of-Laplacian scales
/// with pixel pitch, so an unnormalized score would rank a 12 MP and 48 MP shot of
/// the same scene differently. nil for degenerate (≤ 8px) input.
static let normalizedLongEdge = 1024
static func score(_ cgImage: CGImage) -> Double?
```

Implementation: vImage grayscale + `vImageConvolve_Planar8` with the Laplacian kernel,
variance via `vDSP_normalize`. ~5 ms at 1024px, off-main inside the Vision fan-out.

### 3.2 Write points in `AnalyzePipeline.analyzeOne`

`analyzeOne` (`Intelligence/AnalyzePipeline.swift:408`) — additions ride the existing
structure; nothing about the claim gate, hash-capture (`:419-422`), or the guarded write
(`:467-473`, `file.content_hash == analyzedHash`) changes:

1. `TaggerOutput` (`Intelligence/Core/IntelligenceProtocols.swift:9-18`) gains
   `traits: TraitFields?` (`faceCount/largestFaceFrac/faceQuality/petCount/sharpness`);
   `VisionTagger.analyze` fills it from `VisionResult`.
2. Inside the existing guarded write transaction: upsert `PhotoTraitsRow` with
   `traits_scanned_hash = analyzedHash`, `traits_version = PhotoTraits.currentVersion`.
   (~6 more column writes; no new transaction.)
3. **CLIP embed** — after the committed guard (`guard committed else { return }`,
   `:550`), beside the existing text-embedding write (`:552-567`), when
   `ClipModelStore.shared.isReady`: embed the **already-decoded raster**
   (`out` carries it via a new `TaggerOutput.decodedImage: CGImage?` passthrough —
   `VisionResult.decodedImage` already exists precisely to prevent second decodes) via
   `ClipEngine.shared.embedImage`, then one small write:

   ```swift
   try? await queue.write { db in
       try db.execute(sql: """
           INSERT OR REPLACE INTO clip_embeddings (file_id, embedded_hash, model_generation, vector)
           SELECT ?, ?, ?, ? WHERE (SELECT content_hash FROM files WHERE id = ?) = ?
           """, arguments: [fileID, analyzedHash, gen, ClipVectors.toData(vec), fileID, analyzedHash])
   }
   ```

   The `WHERE content_hash still matches` guard mirrors `markAnalysisAttempted`
   (`:399-406`) — a mid-pass edit must leave the row stale, not stamp new-hash-wrong-
   vector. Tagger-nil files (undecodable) already return via
   `markAnalysisAttempted`; the backfill stamps their NULL-vector marker (§3.3).
4. **`embeddingsWritten` is NOT bumped by CLIP writes.** That counter drives
   `ReclusterGate` for the **text**-embedding clusterer (`:42-43`, `:131-133`), which is
   untouched. The existing `embeddings` table (NLEmbedding text vectors,
   `Database.swift:174-180`) keeps feeding `CollectionsEngine.recluster`
   (`CollectionsEngine.swift:112-120`, `ClusterItem.textVector`) and
   `SimilarTagSuggestions` exactly as today — **CLIP replaces the semantic SEARCH leg
   only** (§4.2). Deviation D1, load-bearing.

### 3.3 `Intelligence/DeepAnalysisBackfill.swift` — one decode, both tables

Existing libraries are full of files whose `analyzed_hash` is current — `analyzePending`
will never revisit them, so traits and CLIP vectors need a launch pass. Modelled on
Spec 02's `PhotoHeaderBackfill` (which is modelled on `IntentBackfill` — fire-and-forget
`Task` from `MuseApp`'s `.task`, `PhaseTrace`-marked, self-limiting):

```swift
nonisolated enum DeepAnalysisBackfill {
    static let maxPerLaunch = 5_000
    static let concurrency = 2          // decode-bound; ANE serializes embeds anyway
    static let writeChunk = 200
    static let decodeMaxPixel = 1024    // faces/quality/pets/sharpness are stable at 1024;
                                        // CLIP input is 256 — no need for the analyze pass's 4096
    static func run() async
}
```

- Selection (one query): image-kind (`image/raw/psd`) files with an alive path where
  the `photo_traits` marker is missing/stale/version-behind, **or** — only when
  `ClipModelStore.isReady` — the `clip_embeddings` row is missing/stale/
  generation-behind.
- Per file: **one** bounded decode at 1024 (`VisionServices.boundedDecode`, `:92-101` —
  the `withinDecodeBudget` bomb guard runs first, durable constraint for any automatic
  decode) → face/pet/quality requests + `SharpnessScore` → optional CLIP embed of the
  same raster. Undecodable → traits row with NULL trait fields + NULL-vector clip row
  (attempted-markers, stamped **only** for a genuine decode failure; dataless iCloud
  files skip without stamping, same as the indexer).
- Writes chunked 200/transaction, every row guarded on `content_hash` still matching.
- Priority `.utility`; the cap spreads a 100k cold library across launches. This is the
  DECISIONS "background, throttled" baseline — battery/thermal pausing stays Spec 06.
- Triggers: launch (`MuseApp.task`, after Spec 02's `PhotoHeaderBackfill` in the same
  chain so the two passes don't contend for disk), and `ClipModelStore` on
  `state → .installed`. On completion with any writes: `SearchFacets.shared.refresh()`
  + `CollectionsEngine.shared.reload()` (so `.similar` smart collections pick up new
  vectors — reload re-resolves smart rules via `CollectionStore.fetchAll`,
  `CollectionStore.swift:353-358`).

---

## 4. Retrieval

### 4.1 `Search/ClipIndex.swift` — brute force, structured for the 200k+ tier

```swift
nonisolated enum ClipIndex {
    /// Cosine floor for a text-query hit. CLIP text↔image cosines live in a much
    /// lower band than same-modality cosines — typical relevant matches score
    /// ~0.2–0.35 raw. NEVER validated live yet; owner validation step (§14).
    static let textMinScore: Float = 0.20
    /// Cosine floor for an image/region-query hit (image↔image band is higher).
    static let imageMinScore: Float = 0.55
    /// Hard cap on returned matches — a browse result, not an archive.
    static let topK = 400
    /// Rows per streamed chunk. Memory ceiling = chunkRows × 2 KB, independent of
    /// library size — THE no-RAM-residency rule (#25) is satisfied here, not by a
    /// future rewrite. sqlite-vec/mmap at the 800k tier swaps this enum's body only.
    static let chunkRows = 4_096

    /// Score every current-generation, non-NULL vector against `query` (already
    /// L2-normalized ⇒ cosine = dot), streaming chunkRows at a time via a cursor;
    /// per chunk: Float16→Float32 unpack + one vDSP_mmul (vector × chunk matrix).
    /// Returns ≥ minScore hits, score-descending, capped topK.
    static func matches(query: [Float], minScore: Float,
                        db: GRDB.Database) throws -> [(id: String, score: Double)]
}
```

Measured expectation (recorded into `PerfBaseline`, §12): 50k × 512 fp16 ≈ 50 MB
streamed + ~25 M multiply-adds ≈ tens of ms on the M1 Air — inside the < 300 ms
perceived acceptance with the text encode. **No in-memory matrix cache in v1**
(deviation D6): the streamed scan already meets budget at the design center; a cache is
a measured optimization for later, and building one now adds an invalidation surface
(edit-in-place, backfill writes, generation bumps) with no evidence it's needed.

### 4.2 `SearchService` semantic leg: CLIP first, NLEmbedding fallback

Verified current flow (`Database/SearchService.swift`): the query text is embedded on
the main actor via the registry's `SentenceEmbedder` (`:45`), scored off-main by
`SemanticSearch.semanticIDs` over the `embeddings` table (`:148-152`), merged
exact-first (`SemanticSearch.merge`, threshold `semanticThreshold = 0.45`, `:25`), and
semantic hits above threshold un-restrict `matchedDirs` (`:158-160`).

Change — the leg becomes engine-selected:

```swift
// before queue.read, replacing line 45:
let clipReady = ClipModelStore.shared.isReady
let queryVector: [Float]? = hasText
    ? (clipReady ? await ClipEngine.shared.embedText(textQuery)
                 : IntelligenceRegistry.shared.embedder?.embed(textQuery))
    : nil
let semanticFloor = clipReady ? Double(ClipIndex.textMinScore) : Self.semanticThreshold
```

Inside `queue.read`, the scoring call routes by the same flag:
`ClipIndex.matches(query:minScore:db:)` when ready (already thresholded + capped), else
the existing `SemanticSearch.semanticIDs`. `SemanticSearch.merge` and the
`matchedDirs` relaxation both take `semanticFloor` instead of the constant — **the merge
and the relaxation must keep agreeing on what counts as a semantic match** (the
documented invariant at `:21-25`); making the floor a parameter preserves that by
construction. Everything else — FTS, tags, notes, color, scope filter, extras leg,
`aliveePaths` — is untouched. CLIP hits are content-derived ⇒ folder-unrestricted, like
today's semantic hits.

The text encode is `await`ed off the main actor (a model call is milliseconds, not
sub-µs like NLEmbedding — it must not ride the `@MainActor` method inline). Spec 01's
semantic-cancellation deliverable (thread the `searchRequestToken` into the expensive
leg) applies to this leg identically and is not duplicated here.

The `embeddings` table, `SentenceEmbedder`, and `IntelligenceRegistry.embedder` are
**not removed** — clustering depends on them (§3.2, deviation D1). The pre-spec's
"replaces NLEmbedding path" is delivered as "replaces it *for search*, retires nothing".

### 4.3 `similar:` token + `SimilarityRegistry`

A similarity query is a *vector*, which cannot ride the field text — but the field text
is the single source of truth for tokens (DECISIONS, Spec 02 §7.5). Bridge: a
session-scoped registry of vectors addressed by small handles, referenced from the query
text.

```swift
// Search/SimilarityRegistry.swift
@MainActor final class SimilarityRegistry {
    static let shared = SimilarityRegistry()
    struct Entry { let vector: [Float]; let label: String }   // label: "photo" / "region" / filename
    /// Returns the handle, e.g. "s1", "s2" … (monotonic per session).
    func stash(vector: [Float], label: String) -> String
    func entry(for handle: String) -> Entry?
    /// Value snapshot for the nonisolated query layer.
    var snapshot: [String: [Float]] { … }
}
```

Grammar (`SearchToken` gains `case similar(handle: String)`): value shape `s<digits>`
(`similar:s1`). The parser is pure and cannot consult the registry, so **shape-valid
parses as a token; resolution happens at query time**. An unresolvable handle (pasted
into a new session) matches **nothing** — an empty result with a visible, removable
chip labeled `String(localized: "Similar (expired)")` — rather than silently dropping
the constraint and returning the un-filtered set (deviation D5; silently widening a
filter is the worse failure). Off-shape values stay free text per the Spec 02 grammar
rule.

`PhotoSearch.filter` (Spec 02 §7.2) gains a context parameter — an amendment to the
not-yet-built Spec 02 signature, recorded there is nothing to migrate:

```swift
struct TokenContext { var similarVectors: [String: [Float]] = [:] }
static func filter(tokens: [SearchToken], context: TokenContext,
                   db: Database) throws -> Result?
```

`similar` evaluation: `ClipIndex.matches(query: v, minScore: ClipIndex.imageMinScore)`
→ ids + scores. **When a `similar` token is present, its similarity ranking is the
result order** (score DESC), replacing the capture-DESC default; other tokens intersect
into it (the color-only ranking precedent, `SearchService.swift:78-85`). Content-derived
⇒ no dir restrictions.

### 4.4 Entry points that mint a similarity search

All funnel through one orchestration method (methods-only extension, house rule):

```swift
// Models/AppState+Similarity.swift
func runSimilarSearch(vector: [Float], label: String) {
    let handle = SimilarityRegistry.shared.stash(vector: vector, label: label)
    searchAllFolders = true                       // similar is a library-wide question
    searchQuery = "similar:\(handle)"
    Task { await runSearch(searchQuery) }         // the existing programmatic seam
}
```

(The `ContentView` `.onChange(of: appState.searchQuery)` mirror-into-field seam already
exists — it's the same programmatic path the hero viewer's `onTagTap` uses,
`HeroImageViewer.swift:213-216`, and Spec 02's Places click-through.)

| Surface | Behavior |
|---|---|
| **Grid tile context menu — "Find Similar Photos"** | Visible for a single image-kind selection, only when `ClipModelStore.isReady` (hidden, not disabled — the stack-menu precedent). Uses the stored `clip_embeddings` vector when present; else embeds the file's 1024px bounded decode on the spot (user-initiated single decode — the query-time-precomputed rule governs *tokens*, and the token still resolves against a registry vector; the click that mints the vector may compute). |
| **Hero viewer — "Similar" action** | An `ActionButton` in `ViewerInfoColumn.actionsRow` (`ViewerInfoColumn.swift:515`), systemImage `sparkle.magnifyingglass`; same vector sourcing; then `runSimilarSearch` + `startClose()` (the `onTagTap` close pattern). Hidden when the model isn't ready. |
| **Image-drop onto the grid** (the pre-spec "image-drop search") | `.onDrop(of: [.fileURL])` on the detail grid area. While a drag hovers, an overlay hint: `String(localized: "Drop an image to find similar photos")`. On drop of a single image-kind file: bounded decode → embed → `runSimilarSearch(label: filename)`. A tile dragged from Muse's own grid and dropped back also triggers it — accepted (the result is a coherent, escapable search, and drop-targets can't reliably distinguish source; recorded). The native `.searchable` field can't take drops — durable constraint stands; the grid is the drop surface. |
| **Region similarity** | §5. |

### 4.5 What stays byte-identical

A query with no `similar:`/`faces:`/`pets:`/`is:` token and the model absent runs the
**pre-Spec-03 pipeline unchanged** — Spec 02's tokenless-byte-identical pin extends: the
new engine only activates behind `isReady`, and `SearchServiceClipTests` pins the
model-absent path to the NLEmbedding behavior.

---

## 5. Region similarity — "find similar inside a photo"

### 5.1 Interaction (hero viewer)

A new chrome control in the hero viewer's `chromeRow`
(`HeroImageViewer.swift:258-266`): `ChromeCircleButton(systemName: "viewfinder")`,
accessibility label `String(localized: "Search within this photo")`, visible only when
`ClipModelStore.isReady` and the current file is image-kind. Clicking toggles
**region mode**:

- Crosshair cursor over the stage; a drag draws a marquee (stroke + dimmed veil outside
  it, drawn in an overlay above `HeroStage`).
- Marquees smaller than `RegionSearch.minSide = 24` screen points are ignored (a tiny
  crop embeds noise).
- Mouse-up with a valid marquee: embed the crop, `runSimilarSearch(label:
  String(localized: "region"))`, exit region mode, `startClose()` — the results are the
  standard search grid (pre-spec: "result surface = the standard grid").
- The stage's pan gesture and scroll-zoom monitor are suppressed while region mode is
  on (the marquee owns the drag); zoom/pan REMAIN as entered — you can zoom in first,
  then select, which is how a small subject gets an accurate box.

**Escape in region mode exits the mode, not the viewer.** The hero close path is the
most protected sequence in the app (durable constraints); the interception uses the
already-established consume-the-trigger pattern in the `viewerClosing` handler
(`HeroImageViewer.swift:161-183`): after the existing immediate
`appState.viewerClosing = false`, a new first branch — `if regionMode { regionMode =
false; return }` — so a region-mode Escape never reaches `startClose()` and the
close sequence is untouched. `EscapeResolver` is unchanged by region mode (it still
returns `.closeHero`; the viewer consumes it).

### 5.2 Geometry + crop

```swift
// Components/RegionMath.swift — pure, unit-tested
/// The on-screen rect the image currently occupies: fitRect scaled by `zoom`
/// about its center, then offset by `pan` — exactly the transform stack HeroStage
/// renders (scaleEffect(zoom) → offset(pan) over the fitted rect).
static func imageFrame(fitRect: CGRect, zoom: CGFloat, pan: CGSize) -> CGRect
/// Marquee ∩ imageFrame, normalized to unit image coordinates (top-left origin).
/// nil when the intersection is degenerate.
static func normalizedRegion(marquee: CGRect, imageFrame: CGRect) -> CGRect?
```

Crop + embed (off-main): bounded decode of the ORIGINAL at
`RegionSearch.decodeMaxPixel = 2048` (`boundedDecode` — bomb-guarded), `CGImage.cropping`
to the normalized rect scaled into raster coordinates, → `ClipEngine.embedImage`. The
displayed `image` is not used as the crop source — it may be the 320px quick thumbnail
mid-ladder (`HeroStage.open()`), and a region of a thumbnail embeds mush.

---

## 6. Auto-growing albums — the `.similar` smart rule

### 6.1 Model (`Intelligence/Collections/SmartRule.swift`)

```swift
case similar(SimilarTerm)                       // 8th case (9th if Spec 02's .location lands first)

nonisolated struct SimilarTerm: Codable, Equatable {
    /// Anchor photos ("similar to these N") — file_ids whose stored CLIP vectors
    /// average into the query centroid. Empty when prompt-driven.
    var anchorIDs: [String]
    /// Text prompt alternative ("beach sunsets"). nil when anchor-driven.
    var prompt: String?
    /// The prompt's encoded vector, written at SAVE time so evaluation never runs
    /// the model (query time touches only precomputed data — the rule applied to
    /// rules). 512 floats ≈ 5 KB of JSON; acceptable in collections.smart_rules.
    var promptVector: [Float]?
    /// ClipModel generation promptVector was encoded under.
    var promptGeneration: Int?
    /// Cosine floor. Slider range SimilarTerm.thresholdRange (0.40…0.80), default
    /// SimilarTerm.defaultThreshold (0.55) — same band as ClipIndex.imageMinScore;
    /// never validated live; owner validation step (§14).
    var threshold: Double
}
```

`isValid`: `(!anchorIDs.isEmpty || !(prompt ?? "").isBlank)` ∧ `thresholdRange`
contains `threshold`. Codable stays **fully synthesized** (house style); the accepted
consequence carries verbatim from DECISIONS' `.location` note: a rule set containing
`.similar` decodes as empty on older builds; the collection survives.

### 6.2 Evaluation (`SmartCollectionResolver.evaluate`)

New case in the switch (`SmartCollectionResolver.swift:55`):

- Query vector: anchors → fetch their `clip_embeddings` vectors (PK lookups, current
  generation, non-NULL), mean, re-normalize (`ClipCentroid.centroid([[Float]])` — pure,
  in `Intelligence/Core/ClipVectors.swift`); prompt → `promptVector` **only if**
  `promptGeneration == ClipModel.current.generation`, else no vector.
- No resolvable vector (model never installed, anchors unembedded, stale prompt
  generation) → **empty set** — the collection shows empty rather than wrong, and heals
  when the backfill/re-encode completes.
- With a vector: `ClipIndex.matches(query:minScore: Float(threshold), db:)` → id set.

Cost note: `CollectionStore.fetchAll` resolves smart rules on every reload
(`CollectionStore.swift:353-358`), so each `.similar` collection costs one streamed scan
(~tens of ms at 50k) per reload — reloads happen at launch, after recluster, and after
backfills, never per keystroke. Recorded in `PerfBaseline`; the 800k answer is the same
`ClipIndex` swap as search (§4.1).

Re-evaluating as new photos are analyzed comes free: analyze pass → recluster →
`CollectionsEngine.reload()` → `fetchAll` re-resolves; plus the backfill-completion
reload (§3.3). That is the pre-spec's "collection re-evaluates as new photos are
analyzed" with zero new machinery.

### 6.3 Editor UI (`SmartCollectionRulesView`)

`Kind` (`Views/Sidebar/SmartCollectionRulesView.swift:189`) gains `case similar`, label
`String(localized: "Looks Like")` — plain vocabulary, no invented terms (foundation §1).
Offered **only when `ClipModelStore.isReady`** (hidden otherwise — a rule you can't
encode is a dead control; existing `.similar` rules still render their row).
`defaultRule(for: .similar)` → `.similar(SimilarTerm(anchorIDs: [], prompt: "",
promptVector: nil, promptGeneration: nil, threshold: .defaultThreshold))`.

`valueControls` for `.similar`:

- Prompt-driven: `TextField` (width 210, the filename precedent), placeholder
  `String(localized: "Describe the look — e.g. beach sunset")`, plus a `Slider` bound to
  `threshold` over `thresholdRange`, labeled `String(localized: "Broad")` /
  `String(localized: "Exact")` at the ends.
- Anchor-driven rules render `Text("\(n) reference photos")` + the same slider — the
  anchor list itself has **no editor in v1** (the `ColorTerm.hex` decodes-no-UI
  precedent, noted in the same comment style). Anchors are created from selection
  (§6.5).
- **`promptVector` is (re)encoded on save**: the rules card's save path calls
  `await ClipEngine.shared.embedText(prompt)` before persisting — the one place a rule
  edit runs the model, which is a user action.

### 6.4 `ClipPromptVectors.refreshAll()` — generation maintenance

On model install/upgrade (`ClipModelStore` → `.installed`), a small pass re-encodes
every stored `.similar` prompt whose `promptGeneration` is stale: read all
`collections.smart_rules` JSON, decode, re-embed prompts, write back. Runs off-main,
guarded by generation equality so it's idempotent; anchors need nothing (their vectors
live in `clip_embeddings` and the backfill re-embeds them).

### 6.5 "New Smart Collection from Selection"

Grid context menu item (beside the existing collection actions in `SelectionActionsMenu`),
visible when 1–20 image-kind files are selected AND `ClipModelStore.isReady`:
seeds a smart collection whose rule set is
`.all([.similar(anchorIDs: <selected file_ids>, threshold: default)])` and opens the
existing smart-collection rules card (via the established `AppState.collectionModal`
payload seam — modals present at the shell, durable constraint). This is the
"similar to these N photos" flow; the 20-anchor cap keeps the centroid meaningful
(named constant `SimilarTerm.maxAnchors = 20`; more selected → item hidden).

---

## 7. Natural-language search (macOS 26+ enhancement layer)

### 7.1 Shape

Foundation Models guided generation fills a structured intent; the intent is composed
into **token text**; the token text round-trips through `SearchQueryParser` — the parser
stays the single source of truth, and the result is by construction "visible, editable
tokens", never a black box (DECIDED #15). Below macOS 26 (or model unavailable),
nothing happens — free text keeps going to CLIP + FTS (§4.2), which is the pre-spec's
stated degradation.

```swift
// Search/NaturalLanguageQuery.swift
#if canImport(FoundationModels)
@available(macOS 26.0, *)
@Generable struct NLSearchIntent {
    @Guide(description: "Four-digit year the photos were taken, if stated")
    var year: Int?
    @Guide(description: "Month 1-12, only if a specific month is stated")
    var month: Int?
    @Guide(description: "City, region or country named in the query")
    var place: String?
    @Guide(description: "Camera make or model named in the query")
    var camera: String?
    @Guide(description: "Minimum star rating 1-5, only if the query asks for rated/best photos")
    var minStars: Int?
    @Guide(description: "What the photos should look like or contain, in a few words")
    var subject: String?
}
#endif

// Pure, tested, availability-free:
nonisolated enum NLTokenComposer {
    /// intent → query text, e.g. `in:2025-06 near:"Lisboa" camera:x100v star:4 beach sunset`.
    /// Fields that don't map cleanly stay in the free-text remainder (subject).
    static func compose(year: Int?, month: Int?, place: String?, camera: String?,
                        minStars: Int?, subject: String?) -> String
}
```

Gating mirrors `FoundationModelNamer` exactly (`Intelligence/Core/CollectionNaming.swift`
— `#if canImport(FoundationModels)` + `#available(macOS 26.0, *)` +
`SystemLanguageModel.default.availability == .available`).

### 7.2 Trigger + surface

`Search/NLQuerySuggest.swift` — `@MainActor final class NLQuerySuggest: ObservableObject`
(Pattern B), `@Published private(set) var suggestion: Suggestion?`
(`Suggestion { display: String; queryText: String }`), request-token-guarded like every
async publisher in this codebase.

- **Trigger:** after a committed search (the `runSearch` path) whose parse yields **zero
  tokens** and whose free text has ≥ `NLQuerySuggest.minWords = 3` words, and the FM
  gate passes → fire one async parse (never blocks the search itself — plain results
  show immediately). A newer committed query invalidates the in-flight one.
- **Guard:** the composed text is accepted only if
  `SearchQueryParser.parse(composed).tokens.isEmpty == false` — an intent that maps to
  no real token is dropped silently (no "AI suggested nothing" noise).
- **Surface:** one suggestion pill in the `TagChipsRow` active-filter row (the chip
  bar), ahead of the token chips, styled distinctly:
  `Label(display, systemImage: "sparkles")` + prefix `Text("Try:")` — e.g.
  `Try: in: 2025-06 · near: Lisboa · beach sunset`. Clicking runs `queryText` through
  the existing programmatic path (field text rewritten → chips render the tokens →
  every chip individually removable — fully editable, as required). A ✕ dismisses the
  suggestion for that query.
- The suggestion is advisory — it never rewrites the user's query unclicked (token
  grammar remains the primary path, FM the enhancement; DECIDED #15).

Values pass through the same canonicalization the tokens already do (e.g. a localized
country display name → ISO code happens inside the `near:` evaluation per DECISIONS —
nothing NL-specific).

---

## 8. Side-by-side compare

### 8.1 Entry + store

```swift
// Models/CompareStore.swift — Pattern B
@MainActor final class CompareStore: ObservableObject {
    static let shared = CompareStore()
    static let maxPanes = 4
    @Published private(set) var urls: [URL]?          // nil = compare closed; 2…4 entries
    @Published private(set) var focusedIndex = 0
    // Synchronized view state — normalized so panes of different aspects track together.
    @Published var zoom: CGFloat = 1                  // 1 = fit
    @Published var center = CGPoint(x: 0.5, y: 0.5)   // normalized image coords
    @Published var peaking = false
    func open(urls: [URL])        // clamps to 2…maxPanes
    func close()
    func focus(_ i: Int)
    func replaceFocused(with url: URL)
}
```

Entry points:

- Grid context menu **"Compare Side by Side"** — visible when 2–4 image-kind files are
  selected (kind guards per the folder-exclusion precedent; hidden otherwise).
- Menu-bar command (beside the existing File-menu commands in `MuseApp`), **⌘⇧C**,
  disabled unless the selection qualifies.

Compare and the hero viewer never coexist: `open(urls:)` requires
`appState.selectedFile == nil` (the context menu can only fire from the grid, so this
holds by construction; the command validates it).

### 8.2 Mounting, chrome, Escape, key gating

`Views/Compare/CompareView.swift` mounts in `ContentView`'s detail `ZStack` at the same
layer the viewer overlay lives, shown when `CompareStore.shared.urls != nil`: a full
dark backdrop (plain `Color.black.opacity(0.92)` — no flight animation; compare is a
workbench, not a stage), an `HStack` of panes with 2 pt gutters, and one top chrome row:
per-pane filename, a peaking toggle (`ChromeCircleButton(systemName: "scope")`), a Fit
button (resets zoom/center), ✕.

- **Escape:** `EscapeAction` gains `case closeCompare`; `EscapeResolver.action` gains
  `compareActive: Bool`, resolved **after `.dismissModal`, before the viewer cases**
  (a modal over compare — e.g. the cull resolve card — must dismiss first; compare and
  viewer are mutually exclusive but the resolver keeps a total order). Order becomes:
  modal → **compare** → viewer → search → tags → collection → [rediscovery →
  collections page → places page, per Spec 02] → none. `EscapeActionTests` extended.
- **Grid key gating:** `PageScrollCatcher`'s `isActive` closure (ContentView passes it)
  gains `&& CompareStore.shared.urls == nil` — the window keeps key focus behind the
  overlay, so without this arrows would drive the grid underneath (the documented
  `modalPresented` gating class).
- Compare registers in **`appState.modalPresented`? No** — it is a full-screen surface
  like the viewer, not a card; it gates the catcher directly (above) and the resolver
  handles Escape. (Modal cards raised *over* compare still win via `.dismissModal`.)

### 8.3 Panes: decode ladder + synchronized geometry

Each `ComparePane` follows the hero's proven ladder (`HeroStage.loadFullRes`,
`HeroStage.swift:441-497`): cached 320 thumbnail instantly → bounded sharp decode at
`target = min(max(paneDim × scale × 2.5, 1600), 4096)` — the hero's exact formula
(`:446-447`) — through `ThumbnailCache.withinDecodeBudget` first (durable constraint),
off-main, stale-guarded on the pane's URL. This *is* the pre-spec's "decode at higher
`kCGImageSourceThumbnailMaxPixelSize` in compare mode specifically": panes get
full-window-class decode targets, not grid thumbnails, so 100% judgment is real.
Worst case (4 × 24 MP-class decodes ≈ 4 × ~100 MB transient) is bounded and sequential
per pane; recorded in `PerfBaseline`.

Synchronized zoom/pan — pure math, unit-tested:

```swift
// Components/CompareGeometry.swift
/// Where `imageSize` draws inside `paneSize` at shared (zoom, center): fit the
/// image, scale about the NORMALIZED center point, clamp so the image never
/// pans fully out of the pane. Normalized center (not points) is what keeps a
/// portrait and a landscape pane looking at the same subject region.
static func drawRect(imageSize: CGSize, paneSize: CGSize,
                     zoom: CGFloat, center: CGPoint) -> CGRect
static func clampCenter(_ c: CGPoint, zoom: CGFloat) -> CGPoint
static let zoomRange: ClosedRange<CGFloat> = 1...8
```

Scroll wheel over any pane zooms ALL panes (shared `zoom`); drag pans all (shared
`center`). One gesture writes the store; every pane re-derives its own rect.

### 8.4 Keyboard (the culling loop)

A `CompareKeyCatcher` (the `KeyCaptureView` first-responder pattern,
`Views/KeyCaptureView.swift` — proven in the hero viewer) mounted while compare is open:

| Key | Action |
|---|---|
| `←` / `→` | Replace the **focused pane's** photo with the previous/next image-kind file from `visibleFiles` not already shown in another pane (the "arrows swap candidates" requirement; wraps like the hero's `flip`, `HeroImageViewer.swift:346-356`) |
| `Tab` | Cycle the focused pane |
| `1`–`5` | Set that star rating on the focused pane's photo — `TagStore.shared.setRating(n, forURLs: [url])` (`Database/TagStore.swift:244` — the ONLY rating write seam; mutual exclusion built in) |
| `0` | Clear the rating (`setRating(nil, …)`) |
| `K` / `X` | Cull-mark keep/reject on the focused photo — only while a cull session is active (§9) |
| `P` | Toggle peaking |
| `Esc` | Via the resolver (§8.2) |

Letters/digits are matched on `charactersIgnoringModifiers` with empty modifier set;
everything else forwards down the chain. Focused pane wears a 2 pt accent ring.
Rating changes bump `appState.tagsVersion` through the store as every rating write does.

Each pane also calls `RediscoveryStore.shared.markViewed(url:)` in its `.task(id:)`
(Spec 02 §5.2's view-hook rule — compare is a real viewing surface; the 5 s dedupe
absorbs double-fires). If Spec 02 hasn't landed, this line is added with it.

### 8.5 Sharpness + face-quality badges

Per pane, a bottom-leading badge cluster (10 pt, the star-badge visual family):

- **Sharpness (relative):** `SharpnessRank.rank(scores: [Double?]) -> [SharpnessMark]`
  (pure, in `Components/`) — the highest score in the compared set gets `sharpest`
  (filled `diamond` glyph), any pane more than `SharpnessRank.tieBand = 0.15` (log10
  units) below the max gets `softer` (open glyph + warning tint), within the band =
  `comparable`. Relative-within-the-set is the honest v1 read of a metric with no
  defensible absolute scale; tooltips show the raw score.
- **Face quality:** when every compared photo has `face_count ≥ 1`, the pane with the
  max `face_quality` gets a small `person.crop.circle.badge.checkmark` (best-face
  indicator) — the Narrative-Select-style "which frame has the good face". Same-machine,
  same-revision comparability holds within a session (§3.1's recorded limitation).
- Scores come from `photo_traits`; a pane whose row is missing shows no badge (never a
  fake neutral).

The hero viewer's INFO card additionally gains a Sharpness row displaying the bucketed
score (`SharpnessScore.bucket(_:) -> soft|moderate|sharp` with named thresholds
`softCeiling = 2.5`, `sharpFloor = 3.5` — owner-validated, §14) — the "culling contexts"
badge without inventing an absolute grid badge (deviation D7).

### 8.6 Focus peaking (the Surface Camera port)

`Viewers/PeakingOverlay.swift` — ported from
`Surface Camera/App/Rendering/PeakingOverlay.swift` (155 LOC, read in full), same
CIImage-in/CIImage-out pure-enum shape, same constants (`edgeThreshold 0.03`,
`highPassRadius 1.5`, `boundaryInset 3`), same
high-pass → `CIColorThreshold` → `CIMaskToAlpha` → `CISourceInCompositing` chain, with
**two deliberate port adaptations**:

1. **The `CILinearToSRGBToneCurve` pre-encode is dropped.** Surface's input is a
   linear-TAGGED render; its doc block (the "peaking is not working half the time"
   record) requires the edge source to be *display-referred*. Muse's input is a decoded
   display-referred CGImage — already encoded — so re-encoding would double-apply the
   curve and shift the tuned threshold. The doc note travels with the port so nobody
   "restores" it.
2. **Peaking is computed at a normalized working size** — the edge source is the pane's
   image downsampled to ≤ `PeakingOverlay.workingLongEdge = 1080` px before the chain
   runs, then the tinted-edge image is scaled onto the pane rect by the existing
   `align(_:to:)`. Surface's constants were tuned against its ~1080px preview feed
   (`highPassRadius` is a pixel-scale quantity — 1.5 px means "sharp detail" only at
   that scale); running the chain at 4096 would silently retune both knobs.

Rendering: a shared `CIContext` (sRGB working space), recompute per (image, accent)
— the overlay rides the same transform as the pane image, so zoom/pan need no
recompute. Toggles: compare chrome + a hero-viewer chrome button
(`ChromeCircleButton(systemName: "scope")` beside the zoom pill), both bound to their
surface's own flag; accessibility label `String(localized: "Focus peaking")`. Accent
color: `appState.moodPalette` accent (no raw hex — DECISIONS theme rule).

`PeakingOverlayTests` port with it (fixture: checkerboard vs blurred checkerboard —
sharp marks, defocused ≈ 0; the top/bottom-split orientation pin comes too).

### 8.7 Spec 04 forward note

Compare panes decode originals. When the editor lands, panes must render through the
edit stack like every display surface (and the >40 MP mid-res gate should consult
`EffectiveDimensions`). Nothing to build now; noted so Spec 04's consumer sweep
includes `ComparePane`.

---

## 9. Ephemeral cull state (DECIDED #13)

### 9.1 Store — memory only, on purpose

```swift
// Models/CullStore.swift — Pattern B
@MainActor final class CullStore: ObservableObject {
    static let shared = CullStore()
    enum Mark: Equatable { case keep, reject }
    @Published private(set) var active = false
    @Published private(set) var marks: [String: Mark] = [:]   // standardized path → mark
    func begin()                     // clears marks, active = true
    func setMark(_ m: Mark?, path: String)   // nil clears
    func end()                       // active = false, marks removed
    var summary: CullSummary { CullSummary(marks: marks) }
}

// Components/CullSummary.swift — pure, tested
struct CullSummary: Equatable {
    let keepPaths: [String]; let rejectPaths: [String]
    init(marks: [String: CullStore.Mark])
}
```

**Nothing persists** — no table, no UserDefaults, no sidecar. Quit mid-session = marks
gone. That is the decision ("resolves to stars and/or trash on completion, then
disappears — NOT a persisted taxonomy, NOT flags, NOT tags"), implemented as the absence
of a persistence layer rather than a cleanup step.

### 9.2 Session flow

- **Begin:** menu-bar command **"Start Culling"** (⌘⇧K, beside the compare command) +
  grid context-menu item; enabled when `visibleFiles` contains ≥ 2 image-kind files.
- **During:** a floating bottom-center HUD capsule (`Views/CullHUD.swift`, mounted in
  the detail ZStack above the grid, below modals):
  `Culling — 12 kept · 5 rejected` + `ModalButton` Finish (`.prominent`) and Cancel.
  Marks apply from three surfaces, all writing `CullStore.setMark`:
  - **Grid:** `K`/`X`/`U` (clear) act on the highlighted-or-single-selected tile.
    `PageScrollCatcher.keyDown` (`Views/PageScrollCatcher.swift:131`) gains a branch —
    when `CullStore.shared.active` and modifiers are empty, `charactersIgnoringModifiers`
    k/x/u are consumed via a new `onCullKey: (Character) -> Bool` closure (returns
    false → forward down the chain as today). Everything else about the catcher
    (keycode-only paging, arrow rules) is untouched.
  - **Hero viewer:** same keys via its `KeyCaptureView` (add `onKey:` passthrough) —
    the natural loop is arrow-flip + K/X without leaving the viewer.
  - **Compare:** §8.4.
  - Marked tiles wear a **bottom-leading** mini-badge (top-leading belongs to the stack
    badge per Spec 02, top-trailing to the star badge): green `checkmark` capsule /
    red `xmark` capsule, with `.accessibilityLabel` "Kept"/"Rejected" and a named
    `.accessibilityAction` to toggle (mouse/keyboard-only affordances need a VO
    parallel — durable constraint). Badges render only while `active`.
- **Cancel:** if any marks exist, a `ModalMessageCard` confirm ("Discard this cull
  pass?") — an accidental Escape/misclick must not silently discard an hour of marking.
  Which is also why **the cull session is NOT in the Escape chain** (deviation D8):
  Escape keeps meaning "back out of view layers"; the session ends only via
  Finish/Cancel.

### 9.3 Resolution

Finish presents `Views/Modal/CullResolveCard.swift` via `.museModal` at the shell
(durable constraints: in-window card, presented at the shell, registered in
`modalPresented`, `ModalButton` footer, no inner ScrollView):

- Summary line: "N kept · M rejected · R unmarked (untouched)".
- **Kept:** a rating `Picker` — None (default) / ★…★★★★★. "None" makes a
  keep-pass-without-rating valid (marks just evaporate).
- **Rejected:** a `Toggle` "Move M rejected photos to the Trash", default ON.
- Footer: Cancel (returns to the live session, nothing applied) / Apply — `.destructive`
  styling when the trash toggle is on.

Apply, in order:

1. Rating: `TagStore.shared.setRating(stars, forURLs: keptURLs)` when a rating was
   chosen — the single write seam; per-location scoping, mutual exclusion, sidecar
   re-export and `tagsVersion` semantics all come with it.
2. Trash: iterate `appState.deletion.deleteWithBurn(node)` over the rejected
   `FileNode`s — the exact seam the grid's multi-select "Move to Trash" uses
   (`Views/GridView.swift:548-563`), so burn animation, undo toast,
   `dropFromActiveCollection`, and selection-pruning bookkeeping are inherited, not
   reimplemented. Files are never unlinked (`NSWorkspace.recycle` under
   `TrashManager` — house law).
3. `CullStore.end()`.

URLs for kept/rejected paths that scrolled out of `visibleFiles` are rebuilt
`URL(fileURLWithPath:)` from the standardized path (the `effectiveSelectionURLs`
precedent) — a mark made in folder A survives browsing to folder B within the session.

---

## 10. Faces-lite search tokens

### 10.1 Grammar (`Search/SearchToken.swift`, Spec 02 module)

Three additions, keys canonical-English + case-insensitive like the rest:

```swift
case faces(NumericFilter)      // faces:>2  faces:0  faces:1-3
case pets(NumericFilter)       // pets:>0
case traitIs(TraitQuery)       // is:portrait  is:group
enum TraitQuery: String, Equatable, Sendable { case portrait, group }
```

`is:` with any other value is not a token → stays free text verbatim (the grammar's
standing rule — "is: that photo of us" must not eat text).

### 10.2 SQL (`Search/PhotoSearch.swift`)

| Token | Query (all on the v19 indexes) |
|---|---|
| `faces` | `SELECT file_id FROM photo_traits WHERE face_count >= ?` (op-mapped like `iso:`) |
| `pets` | same shape on `pet_count` |
| `is:portrait` | `WHERE face_count BETWEEN 1 AND :maxP AND largest_face_frac >= :minFrac` |
| `is:group` | `WHERE face_count >= :minGroup` |

Heuristic constants — one declaration site, owner-validated (§14):

```swift
// Intelligence/Core/PortraitHeuristic.swift — nonisolated enum
static let portraitMaxFaces = 2       // one subject, maybe two
static let portraitMinFaceFrac = 0.05 // the face is a SUBJECT, not a bystander
static let groupMinFaces = 3
```

Recorded semantics: a file with **no** `photo_traits` row matches none of these tokens —
including `faces:0`, which means "scanned and faceless", not "unknown". The backfill
shrinks the unscanned set toward zero; matching unknowns as zero would silently flip
results as scanning progresses, which is worse than a smaller-but-stable result set.

All three are content-derived → no dir restrictions; they intersect with every other
token per the standing AND semantics. "Works with tags off" holds — none reads `tags`.

### 10.3 Suggestions

`SearchSuggest` key list gains `faces:`, `pets:`, `is:`; `is:` value suggestions are the
fixed pair (`is:portrait`, `is:group`); `faces:`/`pets:` suggest the numeric-op forms
(`faces:>2`) as static hints (no facet query — counts aren't enumerable values). Chip
bar display labels via the token `displayLabel` extension:
`String(localized: "Faces")`, `String(localized: "Pets")`,
`String(localized: "Portrait")` / `String(localized: "Group photo")`.

---

## 11. New durable constraints (added to `CLAUDE.md`)

1. **Network doctrine is now four app-initiated paths** — the fourth is the search-model
   download: user-initiated only, pinned host, manifest SHA-256 verified, fail closed,
   nothing sent. No other code may fetch a model or anything else.
2. **The `embeddings` table (NLEmbedding text vectors) is clustering's input and is not
   retired by CLIP.** `clip_embeddings` is a separate, additive table; CLIP replaces the
   semantic *search* leg only, behind `ClipModelStore.isReady`, with the NLEmbedding
   path as the model-absent fallback. `ReclusterGate`/`embeddingsWritten` count text
   embeddings only.
3. **CLIP vectors are L2-normalized Float16 blobs keyed by content, with
   `embedded_hash` + `model_generation` markers; a NULL vector is the attempted-marker
   for an undecodable file.** `ClipVectors.fromData` refuses wrong-length blobs —
   vectors from different generations must never pair. Retrieval streams
   `ClipIndex.chunkRows` at a time and must never assume the matrix fits in RAM.
4. **The semantic merge floor and the `matchedDirs` relaxation floor are the same
   value** — engine-selected (`ClipIndex.textMinScore` vs
   `SearchService.semanticThreshold`), passed as one parameter to both. Two constants
   drifting apart re-opens the folder-restriction bleed the current comment warns about.
5. **A similarity query rides the field text as `similar:<handle>` against the
   session-scoped `SimilarityRegistry`** — the field text stays the single source of
   truth for tokens. An unresolvable handle matches nothing (visible empty result +
   removable chip), never silently drops the constraint.
6. **`SmartRule.similar` prompt vectors are encoded at rule-SAVE time and stamped with
   the model generation; evaluation never runs the model.** A generation mismatch
   evaluates empty and heals via `ClipPromptVectors.refreshAll()` — never encode inside
   `SmartCollectionResolver`.
7. **Cull state is memory-only.** No table, no defaults key, no sidecar field — if a
   persistence surface for keep/reject appears, it violates DECIDED #13. Resolution
   writes go through `TagStore.setRating` and `DeleteCoordinator.deleteWithBurn` only.
8. **The peaking port's edge source is display-referred and evaluated at the ~1080px
   working size.** Surface's `CILinearToSRGBToneCurve` pre-encode was dropped because
   Muse's decoded images are already encoded; re-adding it (or running the chain at
   full decode resolution) silently de-tunes `edgeThreshold`/`highPassRadius`.
9. **Region-mode Escape consumes `viewerClosing` inside the hero's onChange handler and
   returns before `startClose()`** — the hero close sequence itself is untouched.
   Escape resolver order is: modal → compare → viewer → search → tags → collection →
   rediscovery → collections page → places page → none.
10. **Face/pet/sharpness traits live in `photo_traits` under one
    `traits_scanned_hash` + `traits_version`;** a new trait bumps the version (re-scan)
    rather than adding a parallel marker. Missing row = unscanned; `faces:0` matches
    only scanned files.

---

## 12. Performance baseline additions

Additive rows in the Spec 01 harness (record, never assert):

| Metric | Budget | How |
|---|---|---|
| CLIP text encode (one query) | 40 ms | `ClipEngine.embedText`, model warm |
| CLIP image embed (one 1024px raster) | 15 ms | ANE, model warm |
| `ClipIndex.matches` over 50k synthetic vectors | 100 ms | in-memory DB fixture |
| Semantic leg end-to-end (encode + scan + merge) at 50k | 150 ms | supports the < 300 ms perceived acceptance |
| `.similar` smart-rule resolve at 50k | 120 ms | fetchAll path |
| Compare: two 24 MP panes to sharp | 1200 ms | decode ladder, cold cache |
| DeepAnalysisBackfill throughput | ≥ 8 files/s | 1024px decode + traits (+ embed when installed) |

---

## 13. Tests

All pure-logic (house convention; no UI unit tests). New files:

| File | Covers |
|---|---|
| `ClipVectorsTests` | Float→Float16→Float round-trip within tolerance; wrong-length `fromData` → nil; normalization preserved |
| `ClipTokenizerTests` | script-generated fixture pairs match exactly; 77-token pad/truncate; empty input |
| `ClipPreprocessTests` | aspect-fill center-crop math for portrait/landscape/square into 256; degenerate input |
| `ClipModelManifestTests` | manifest parse (valid/oversized/unknown-version refused); chunk-list validation; SHA mismatch → fail closed (pure verifier fed fixture data) |
| `ClipIndexTests` | streamed matches == brute-force reference on 5k random vectors; NULL vectors and stale generations skipped; topK cap; threshold edge |
| `ClipMigrationTests` | v18+v19 run clean on a v17-shaped library; idempotent re-migrate; cascade on file delete for both tables |
| `DeepBackfillSelectionTests` | stale-by-any-marker selection; generation bump reselects; NULL-vector marker not reselected; dataless skip stamps nothing |
| `SharpnessScoreTests` | sharp synthetic > blurred synthetic (same content); resolution normalization (same scene at 1× and 4× within tie band); degenerate input nil; `bucket` thresholds |
| `SharpnessRankTests` | max marked sharpest; tie band; nil scores unmarked |
| `PortraitHeuristicTests` | portrait/group/neither across the constant boundaries |
| `SearchTokenFacesTests` | `faces:`/`pets:` numeric forms; `is:portrait`/`is:group`; `is:junk` stays free text; `similar:s1` shape parse; off-shape stays text; `removing(tokenAt:)` round-trips all new tokens |
| `PhotoSearchTraitsTests` | in-memory DB per token; unscanned rows match nothing incl. `faces:0`; AND intersection with existing tokens |
| `PhotoSearchSimilarTests` | similarity ordering wins when the token is present; unresolvable handle → empty, not unfiltered; intersection with `camera:` |
| `SearchServiceClipTests` | model-absent path byte-identical to the NLEmbedding pipeline (pin); merge floor == relaxation floor by construction (one parameter) |
| `SimilarTermTests` | Codable round-trip (incl. promptVector); `isValid` branches; centroid math (`ClipCentroid`) incl. renormalization + single-anchor identity |
| `SmartRuleSimilarResolverTests` | anchor path over fixture vectors; stale promptGeneration → empty; threshold boundary |
| `NLTokenComposerTests` | field combinations compose to parseable token text; composed text round-trips through `SearchQueryParser` with ≥ 1 token; empty intent → empty string |
| `RegionMathTests` | imageFrame under zoom/pan; normalized region round-trip; marquee outside image → nil; min-side rejection |
| `CompareGeometryTests` | drawRect fit at zoom 1; shared center tracks the same subject region across differing aspects; clamp at edges; zoom range |
| `CullSummaryTests` | keep/reject partition; unmarked untouched; empty session |
| `PeakingOverlayTests` | ported: sharp fixture marks, defocused ≈ 0; top/bottom orientation pin; extent == rendered extent |
| `EscapeActionTests` (extended) | `.closeCompare` ordering |

Existing suites that must stay green and are touched: `SearchQueryParserTests` /
`PhotoSearchTests` / `SearchSuggestTests` (Spec 02, gain cases), `SmartRuleSetTests` +
`SmartCollectionResolverTests` (+ `.similar` in the round-trip/enumeration lists),
`EscapeActionTests`, `AnalyzePipeline`-adjacent suites (`IndexerReconcileTests` etc.
untouched but run), `ThumbnailVariantTests` (compare adds **no** new thumbnail variant —
panes decode directly, not through `ThumbnailCache` render sizes, except the existing
320 quick-thumb).

---

## 14. Build order

1. **v19 + traits** (`VisionServices` additions, `SharpnessScore`, `analyzeOne` traits
   write, `DeepAnalysisBackfill` without the CLIP branch) — no model dependency,
   unblocks faces tokens and compare badges
2. **Faces/pets/`is:` tokens** (§10) — lands on Spec 02's search module
3. **Compare + peaking + sharpness badges** (§8) — no CLIP dependency
4. **Cull state** (§9) — no CLIP dependency
5. **v18 + CLIP plumbing** (`ClipModel`/`ClipModelStore`/`ClipTokenizer`/`ClipEngine`/
   conversion script/Settings + offer card) — the license read (§15) can run in
   parallel; only the *artifact choice* blocks on it
6. **Retrieval + semantic swap** (§4.1–4.2) + backfill CLIP branch
7. **`similar:` token + Find Similar + image-drop** (§4.3–4.5)
8. **Region similarity** (§5)
9. **`.similar` smart rule + from-selection** (§6)
10. **NL layer** (§7)
11. Docs (`CLAUDE.md` constraints §11 + phase-table row + network doctrine,
    `architecture-map.md`, `session-log.md`, DECISIONS.md refresh) + localization export
    pass (`xcodebuild -exportLocalizations … fr`; the spec is incomplete until it
    reports 0 untranslated)

1–4 are shippable with no model on any machine; 5–10 are the CLIP arc. Steps 2, 7, 10
require Spec 02's search module to exist first.

---

## 15. Owner-only steps

1. **Resolve the MobileCLIP weights license** (Apple ML Research Model TOU vs a paid
   app). Outcome picks the artifact for `ClipModel.current`; the fallback conversion
   path (OpenCLIP ViT-B/32) is the same script with a different source checkpoint.
   **This gates shipping, not building.**
2. Run `scripts/make-clip-coreml.py` on the dev machine (downloads weights, converts,
   emits artifacts + tokenizer fixtures + manifest), upload the chunked artifacts to
   the Pages site (or an R2 bucket — same manifest contract), and record the measured
   `downloadBytes` in `ClipModel.current`.
3. **Validate the never-live thresholds against real photos:** `ClipIndex.textMinScore`
   / `imageMinScore`, `SimilarTerm.defaultThreshold` + slider range,
   `PortraitHeuristic` constants, `SharpnessScore` buckets + `SharpnessRank.tieBand`.
   All are named constants with one declaration site; tuning them is judgment only real
   libraries can settle (the `BurstClusterer.similarityThreshold` precedent).
4. Re-run `PerfBaseline` (with the §12 rows) on the M1 Air 8 GB; commit the report —
   the "<300 ms perceived at 50k" acceptance is measured there.
5. French translations for the new keys (the export pass emits them).
6. Sanity-pass the NL layer on a macOS 26 Apple Intelligence Mac (guided generation
   availability + a dozen real phrases) — the parse path is testable, the model's
   judgment is not.

---

## 16. Deliberate deviations from the source specs

Recorded so they read as decisions, not drift:

1. **CLIP does not replace the NLEmbedding infrastructure** — it replaces the semantic
   *search leg* only, behind an installed-model gate with the existing path as
   fallback. The `embeddings` table feeds `HybridClusterer`/`CollectionsEngine` and
   `SimilarTagSuggestions` (verified: `CollectionsEngine.swift:112-120` reads
   `EmbeddingRow` as `ClusterItem.textVector`); ripping it out to satisfy the
   pre-spec's "replaces NLEmbedding path" wording would break auto-collections. §3.2,
   §4.2.
2. **Faces, pets, and sharpness share one `photo_traits` table, marker, and backfill**
   — all raster-derived scalars from one decode; `traits_version` covers future
   columns. Separate per-feature tables double the decode passes for nothing. §2.2.
3. **The network doctrine grows a fourth path** (model download) — forced by DECIDED
   #26; constrained to user-initiated + hash-verified + fail-closed so "everything else
   stays blocked" stays true. §1.6.
4. **Model artifacts are chunked ≤ 20 MiB on the existing Pages site** — Pages caps
   assets at 25 MiB, and zero-new-infrastructure beats a new bucket by default; R2 is an
   equivalent owner option under the same manifest contract. §1.2.
5. **An unresolvable `similar:` handle matches nothing** rather than falling back to
   free text or dropping the constraint — silently widening a filter is the worst
   failure mode; the chip stays visible and removable. §4.3.
6. **No in-memory vector cache in v1** — the streamed scan meets budget at the design
   center; a cache is a measured optimization with a real invalidation surface, and
   no-RAM-residency is satisfied by streaming, not deferred to a rewrite. §4.1.
7. **The sharpness badge is relative within a compare set** (+ a bucketed INFO-card
   row), not an absolute grid badge — variance-of-Laplacian has no defensible absolute
   scale across subjects; the pre-spec's "subtle badge in compare/culling contexts" is
   delivered where relative comparison is honest. §8.5.
8. **The cull session is not in the Escape chain** — Escape means "back out of view
   layers", and an accidental Escape discarding hundreds of marks is unrecoverable;
   sessions end via Finish/Cancel (Cancel confirms when marks exist). §9.2.
9. **The offer card is the only unprompted CLIP surface, shown once** — download stays
   strictly user-initiated (doctrine), but a buried Settings row alone would hide the
   headline feature; the card fires at the moment a semantic search would have
   benefited. §1.6.
10. **Compare is capped at 4 panes and never coexists with the hero viewer** — the 2-up
    requirement plus the 3–4-up nice-to-have, bounded by 8 GB decode reality; one
    full-screen surface at a time keeps the Escape order total. §8.
11. **`similar:` handles are session-scoped, not persisted** — persisting query vectors
    in the DB for pasteable links is not a v1 need and would add a growth surface to
    the schema for a chip that regenerates in two clicks. §4.3.
12. **NL parsing is suggestion-only** — it never rewrites the committed query without a
    click, which is the strict reading of "token grammar remains the primary path; FM
    is the enhancement layer". §7.2.

---

## 17. Acceptance mapping (from `pre-spec-03-culling-and-search-phase2.md`)

| Acceptance item | Where satisfied |
|---|---|
| "dog on a beach" correct in < 300 ms perceived at 50k | §4.1–4.2 (CLIP text→image over streamed index), measured §12/§15.4 |
| Image-drop search works | §4.4 grid `.onDrop` → embed → `similar:` search |
| Region similarity works from the viewer | §5 |
| Auto-growing album fills as new photos are imported | §6.2 — live resolve on reload + backfill/analyze-completion reloads |
| NL phrase becomes visible editable tokens on macOS 26; degrades below | §7 — composed token text through the real parser; below 26 the path is inert |
| Compare: two 24 MP side by side, synchronized zoom, peaking toggle, star from keyboard | §8.3 (hero-class decode targets), §8.3 geometry, §8.6, §8.4 |
| Cull session ends with stars/trash applied and no residual state | §9.3 + constraint §11.7 (memory-only by construction) |
| `faces:>2` filters correctly on a real library | §10 + `DeepAnalysisBackfill` populating existing libraries (§3.3) |
