# Muse — Photo Repositioning: Foundation Document

*July 29, 2026. This document consolidates the full strategy/feature conversation into a single reference for spec development. It is written to be handed to a spec/build agent. Decisions marked **DECIDED** were made explicitly by Carlos and must not be re-asked. Items marked **OPEN** are genuinely undecided. Items marked **DEFERRED** are wanted later, not in initial scope. Items marked **NEVER** are out permanently.*

---

## 1. Product definition & positioning

**Muse is a local-first, Mac-native photo library app for people who take photography seriously as a hobby — with real utility (viewing, sorting, searching, light editing, sharing) delivered at inspo-app design quality.**

### The thesis (DECIDED)

The gap is **craft, not features**. The inspiration-library category (Eagle, Cosmos, Savee, Atlas, Gather) is crowded and well-made. The photo-library category has massive functional overlap with it — grids, tags, collections, color search, dedupe, ratings — but is served almost entirely by badly designed, dated, or heavyweight software: Photo Mechanic ($299–399, Qt, Apple Silicon native only since Oct 2024, "dated/complicated/busy"), digiKam (KDE app on Mac), Immich/PhotoPrism (Docker+Postgres), IMatch (Windows-only), Excire ($249, cross-platform, not crafted). Peakto is the only Mac-native entry and it's subscription + positioned as a meta-catalog on top of Lightroom.

**Nobody occupies: Mac-native + one-time purchase + affordable + library-first + well-designed.** Every existing product has at most three of those five.

Supporting evidence worth keeping in mind:
- The two closest apps fail at the same seam: Peakto's editor round-trips are one-way (changes don't sync back — users lose trust); Eagle's top user complaint is verbatim "no face recognition, no Maps view, no agenda view." The open lane is exactly the intersection: Eagle's capture-and-browse polish + real photo semantics + edits that never leave or lose the original.
- Market tailwind: CIPA 2025 compact camera shipments +29.6% units, +49.8% value — X100VI/Q3/GR-class buyers. The exact persona.
- Adobe demand shock: new-subscriber Photography Plan entry went $119.88/yr → $239.88/yr in Jan 2025; regional increases ran 12–68%; June 2024 ToS controversy still colors sentiment.

### Positioning rules (DECIDED)

- **This is NOT positioned against Lightroom.** Most of the target audience has never opened Lightroom and doesn't know what it is. Lightroom is a market-sizing reference only — never marketing copy. The pitch is closer to: *"your photos deserve better than Photos, without turning into a project."*
- Lightroom-adjacent users (people who use LR or similar but would be just as happy with something lighter, nicer, cheaper) are a welcome secondary audience — served by the import/migration path, not by positioning.
- **Photographers-first, versatile for everyone.** The foundation of Muse is "group images visually so you can SEE them together — viewing, editing, sorting, all nicely, quickly, efficiently." Photo utility is a branch off that foundation, not a separate path. Designers and general users remain valid users. Do NOT amputate the general-purpose library nature. (Explicitly decided against the earlier "pick designers or photographers" recommendation.)
- It is NOT a moodboard/canvas app. Atlas/Gather-style freeform canvases are their thing, not Muse's. Muse is image-forward like them, but with far more functionality underneath.
- **Lead marketing with the no-catalog story**: files stay where they are, nothing is imported into a proprietary library, metadata lives beside the photo, moving a file doesn't orphan it. (This answers the most-repeated real-world complaint about catalog apps: "I don't want to 'import' photos, just copy them onto my hard drive"; "catalogs don't allow incremental backup.")
- **Position as additive, not replacement**: ratings/keywords port in cleanly via XMP; Muse can sit alongside whatever editor someone already uses. Near-zero switching cost is a structural advantage — full replacements (Capture One, DxO) ask users to abandon years of edits; Muse doesn't.
- **Plain vocabulary everywhere.** No invented terms (Cosmos gets punished for "clusters"/"elements"). Folders, albums, tags, people, places.

### Who the user is (from Carlos's working notes — canonical)

- Shoots a phone and/or a "fun" camera (X100-style compact, mirrorless, point-and-shoot)
- Photography is an active interest, not memory-keeping — wants to get better, wants to feel close to the craft
- Curious about the technical side (exposure, film stocks, camera history) but not fluent; doesn't want to become a power user to enjoy the hobby
- Doesn't need archival metadata discipline or multi-drive cataloging
- Wants control Apple Photos doesn't give, without pro-tool cost/complexity
- **Wants their best shots to look good and get shared, not just filed away**

### Business facts (context for the spec)

- Current users: ~4 (light user testing; 1 known friend). Effectively zero-user, pre-launch. No launch has been spent; no marketing done yet. This is a first positioning, not a repositioning — no existing audience to protect or convert.
- License: PolyForm Shield (not open source). GitHub going private.
- Distribution today: direct (Developer ID, notarized, Sparkle self-update), free, downloadable from GitHub. **DECIDED: this ends. Distribution moves to the Mac App Store EXCLUSIVELY — no more GitHub download, no more Sparkle.** All commercial plumbing is StoreKit 2 / App Store (see §11). Sparkle and the direct-release tooling (DMG scripts, `release.sh`, appcast) are to be removed.

---

## 2. Current codebase state (v1.4)

Repo: `Muse App/` — 204 Swift files, ~33,370 LOC app target; 126 test files. `CLAUDE.md` (446 lines) is the authoritative constraints doc; `docs/architecture-map.md` is an accurate current-state index.

### Stack
- SwiftUI-first with AppKit escape hatches (`PageScrollCatcher`, `OutsideClickDeselect`, `KeyCaptureView`, `GridFilterPopover`, AppDelegate `selectAll`)
- Min macOS **14.6**; `MuseShareExtension` target is pinned to **26.5** (inconsistent — reconcile); Swift 5 mode, `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`; accepted Swift-6 concurrency warning backlog
- Persistence: **GRDB.swift 7.10** (SQLite at `~/Library/Application Support/Muse/muse.sqlite`), 12 migrations (`v1_schema`…`v12_smart_collections`), FTS5 (`files_fts`); JSON sidecars (`.muse/<hash>.json`) for portable per-file metadata + iCloud sync; UserDefaults for UI prefs
- Dependencies: **exactly two** — GRDB and Sparkle. **Sparkle is removed with the Mac App Store move (§11) — target state is ONE dependency (GRDB).** Keep it that way wherever possible.

### Data model
- **Reference-in-place, never imports/copies.** Security-scoped bookmarks (`BookmarkStore`), live enumeration (`FolderTree`/`FolderReader` → `FileNode`)
- **Content-hash identity**: `FileRow` (id, `content_hash` UNIQUE, kind, size, dimensions, caption, `dominant_color`, `palette`, `feature_print`, `analyzed_hash`, `intent`) + `PathRow` (absolute_path, bookmark, is_alive). Byte-identical files share one FileRow; `Indexer.reconcile` splits on edit-in-place
- **Tags are per-location**, scoped `(file_id, parent_dir)`; `source` manual/vision, manual beats vision. `TagScope.swift` is the single source of truth for the scope key
- **Ratings are tags**: mutually-exclusive manual tags labeled 1–5 ★ (`StarRating.swift`). No rating column
- Notes: per `(file_id, parent_dir)`, LWW
- Collections: auto/emergent, intent buckets, manual, and **smart collections** via `SmartRule.swift` (`SmartRuleSet` all/any over `.rating/.color/.tag/.kind/.date/.filename/.size`) — **no location rule exists yet**
- Thumbnail cache: `ThumbnailCache.swift` — NSCache 512MB + disk LRU 2GB, **path-keyed**, every requested size must be in `renderedVariants` or invalidation leaks stale bitmaps. Plus `ImageHeaderSizeCache` (header-derived dimensions, never evicts) and `AspectRatioCache`

### Shipped feature surface (all shipped unless noted)
Multi-root sidebar with drag reorder + starred pins; 3 grid layouts (masonry/justified/square) fully virtualized; column/spacing sliders; folder cards; faceted kind filter; 7 sort modes incl. Color and Shape; keyboard nav; multi-select bulk actions; drag-to-move; trash-with-undo. Viewer router by kind: hero image viewer (flight animation, zoom/pan, palette backdrop, info column), video, PDF, audio, 3D, font, Markdown, code, SVG (network-blocked), Quick Look fallback, Open With. Vision analysis pipeline (`AnalyzePipeline`, incremental, automatic): tags, caption, OCR, dominant color, k-means palette, feature prints. FTS5 + `NLEmbedding` semantic + tag + **color search** (hex/palette, CIEDE2000, `ColorSearch.swift`). Duplicate finder (byte/visual/filename). Screenshot intent buckets. Foundation Models used to name collections (gated macOS 26+). French localization. IPTC/XMP/sidecar keyword+rating **import** (read-only, `MetadataKeywordReader`). Collection → 11×14 PDF export. **Google Drive collection share** (see §7). macOS share sheet; Finder Share→Muse extension; iCloud folder sync via sidecars; backup/restore (`.muselibrary`); App Intents/Shortcuts/Siri.

Stubbed: `ImageDetailPanel.swift` is an explicit placeholder. Previously built and REMOVED (twice): Metal shaders, globe/galaxy/cloud spatial views, chat panel, iCloud share links. Deliberately dropped: list view, color labels ("redundant"), side-by-side compare (to be revisited — see §5), slideshow.

### Existing doctrine that this project REVISES
`CLAUDE.md` currently says: never modify user files (KEEP); EXIF/XMP write rejected 2026-06-27 (KEEP — edits live in DB + sidecars, never written into image files); "No editing UI — every 'edit this' path goes through Open With…" (**REVISED** — see §6); two sanctioned network paths: Sparkle + Drive share (**REVISED** — Sparkle is removed entirely with the App Store move; the final list is three app-initiated paths: (1) Drive share (user-initiated), (2) announcements.json (launch, off-able), (3) custom-domain provisioning Worker (paid feature, user-initiated) — plus StoreKit/App Store system traffic which is OS-level, not an app network path); persona "generalist — Downloads/Documents" (**REVISED** to the photographer-first persona above).

### Known latent issues to fix along the way
- O(n²) clustering at ~50k files
- Per-keystroke semantic search (needs debounce + async)
- `AppState.swift` 1380 LOC / ~70 `@Published` props — DO NOT GROW (see §9)
- Share extension deployment target mismatch (26.5 vs 14.6)

---

## 3. Assets available from Surface Camera (Carlos's other app)

Repo: `Surface Camera/`. A film-simulation camera app with a production-grade Metal + Core Image pipeline. Directly relevant, portable pieces:

- **`PhotoRecipe` / `ToneAdjustments` / `EditHistory` / `RecipeAdjustmentData`** (in `Packages/SurfaceCore`): clean, versioned, Codable non-destructive edit model with real back-compat (v3 field decoded into legacy slot; decoding never bumps version). **This IS the process-version architecture — port it.**
- `RecipeRenderSettings` zeroes tone fields before bake so they can't double-apply — keep this correctness pattern.
- **`PeakingOverlay.swift`** (155 LOC): focus peaking via high-pass + `CIColorThreshold`, correct doc note that input must be display-referred. **Ports directly to the culling feature.**
- `WorkingSpaceImage.swift` type-level invariant (`EncodedImage`/`LinearImage`, single `.toLinearWorkingSpace()` crossing) — fixed a real 2.3×-too-dark bug; reuse the pattern.
- Resolution-normalized parameter lesson: grain cell size `(1.5 + 4.5·grainSize) · longEdge / 4032` — **apply this normalization to every scale-dependent radius in the Muse editor** (clarity, sharpen, vignette feather).
- Test culture: golden tests, `ToneFilterStageTests`, `EditHistoryTests` etc. — replicate.

**What does NOT port (learn from, don't copy):**
- `ToneFilterStage` runs AFTER the Metal film pipeline on a `saturate()`-clamped rgba16Float texture — highlight data >1.0 destroyed before `CIExposureAdjust` sees it. Fine for a film sim; **wrong for an editor**. In Muse, tone adjustments must run on un-clamped scene-referred data (highlight recovery must work).
- Surface's preview ≠ export by design (`.preview` drops grain) and thumbnails read PhotoKit's baked JPEG. **Muse cannot dodge this: the grid IS the product — an edit must render identically at thumbnail, screen, and export.** Requires normalization above + a test asserting preview/full agreement at multiple resolutions (Surface lacks this test; write it).
- Surface's preview loop is unthrottled (re-renders per slider tick via CGImage/UIImage round-trip). Muse editor should render into a persistent `MTKView`/`CIContext` at screen resolution with proper debouncing/coalescing.

---

## 4. Search (highest priority pillar)

**DECIDED: search must be superpowered — accurate, instant at 10,000+ images.** Benchmark: the in-development Angles app (@angles_hq, Tyler Angert) demos an 80,000-photo camera roll searched in realtime with local models: text-to-image, image-to-image, find-similar-within-a-photo, all private/on-device. That's the bar, and it's achievable.

### Architecture rule
**Query time touches ONLY precomputed data.** Everything expensive happens once, at analyze time, in the background. Apps feel slow for two reasons: per-keystroke work without debouncing, and computing at query time what belongs at index time.

### The index (one GRDB database)
- `photos`: EXIF columns, all indexed — camera make/model, lens, ISO, aperture, shutter, focal length, flash, date, dimensions, GPS lat/lon
- `fts_photos` (FTS5): OCR text, filename, caption, keywords
- `embeddings`: CLIP image vectors (512-d float16) + later face vectors, as BLOBs
- `places`: offline-reverse-geocoded city/admin/country per photo
- `people`/`faces`: deferred (see below)

Cost realities: EXIF extraction via `CGImageSourceCopyPropertiesAtIndex` (no decode) runs thousands/minute — full metadata pass on 100k is minutes. 100k × 512-d fp16 ≈ 100MB; brute-force cosine via Accelerate ≈ 10–50ms on Apple Silicon. **No vector DB needed at design-center scale**; `sqlite-vec`/`SQLiteVec` available later for the 800k tier.

### Semantic engine (upgrade from NLEmbedding)
- **MobileCLIP** (Apple, Core ML). S2 ≈ 3.6ms/image, 74.4% zero-shot. One embedding space serves text-to-image AND image-to-image (search-by-image = embed the image instead of the text — free).
- **LICENSE FLAG (must resolve before ship):** apple/ml-mobileclip *code* is MIT but the *weights* are under Apple's ML Research Model TOU (data CC-BY-NC-ND). Have this read before shipping in a paid app. Fallback with clean terms: self-converted OpenCLIP ViT-B/32.
- **Region similarity ("find similar inside a photo")** — steal from Angles: user selects/taps a region → embed the crop → search library with it. ~2 days on top of CLIP. Pairs with existing color search.
- **Auto-growing albums** — a smart collection whose rule is an embedding query ("similar to these 5 photos" / a text prompt). One new rule type on the existing `SmartRule` tree; collection fills itself as imports arrive.

### Token search UX
- One search field; typed terms become **editable filter tokens** (Apple Photos pattern): `camera: X100V`, `lens:`, `iso: >1600`, `f: <2`, `in: 2019`, `near: Lisbon`, `person: Ana` (later), `text: "receipt"`, `color: red`, `★≥4`. Free text falls through to CLIP + FTS.
- AppKit's NSSearchField has no native tokens; Finder's token UI is private → **custom SwiftUI token bar**.
- **Natural-language parsing via Foundation Models** (macOS 26+): `@Generable` guided generation fills a `SearchQuery` struct (dateRange, place, people, camera constraints, semanticText) from phrases like "beach photos with mom last summer" — constrained decoding can't hallucinate schema. **Always render the parsed result as visible tokens the user can edit** — never a black box. Deterministic token grammar remains the primary path; FM is the enhancement layer, with graceful fallback below macOS 26.
- **None of this is tags.** All search attributes are derived, indexed metadata — works identically for users who turn tags off. (DECIDED: photo info must NOT be surfaced as tags.)

### Reverse geocoding (DECIDED: offline)
Apple's geocoder throttles ~50 req/60s (100k photos ≈ 33 hours — non-starter). Bundle GeoNames cities1000/cities15000 (CC-BY 4.0, a few MB), k-d tree lookup, city/admin/country granularity. Optionally refine on-demand via MapKit for photos the user actually opens.

### Faces & people (DEFERRED — "not a deal breaker; if easy/cheap and Apple-approved, great")
- **Hard wall:** Apple's People clusters are NOT accessible (no PhotoKit API, confirmed macOS 26; `VNGenerateFaceprint` is private = App Store rejection). Cannot tap into Apple's people data.
- **Ship now (cheap, Apple-approved):** Vision face *detection* (public): "has faces," face count, group vs portrait, face quality — days of work, search-token-ready (`faces: >2`).
- **Ship later (the real project):** identity clustering. License-safe path: Vision detect/landmarks → aligned crops → **AuraFace-v1 embeddings (Apache 2.0** — InsightFace/buffalo and EdgeFace are non-commercial; do NOT use) → cosine + HAC/DBSCAN clustering → GRDB BLOBs. Model inference is the easy 20%; naming/merge/split/hide UX is the 80%. Budget 2–3 months. Steal digiKam's loop: rejecting a suggested match immediately shows next-best; confirming triggers incremental background re-recognition. Steal Immich details: face-chip hover highlights bounding box; optional birthdate → "age in this photo."
- Pets: Vision animal detection = "pets" category filter free. Named-pet identity has no permissive model — don't attempt.

---

## 5. Library & culling features

### Tier 1 (build)
1. **Near-duplicate stacks.** Burst/near-identical frames collapse to one expandable tile (Google Photos pattern + manual stacking). Nobody Mac-native has it. Foundation exists (feature prints + duplicate finder); this is clustering (time-proximity + perceptual similarity) + presentation. *Medium.*
2. **Rediscovery.** Track `lastViewedAt`; surface coldest assets ("rarely seen"), shuffle/random mode, on-this-day. One column + queries + a sidebar entry. Gather markets exactly this ("Rediscover") as a headline; Eagle's Random Mode is beloved. *Easy — best value/hour in the plan.*
3. **Location, phase 1 (DECIDED — no map yet).** Persist coordinates: add `files.lat/lon` (v13 migration) + backfill in `AnalyzePipeline` (today `FileMetadata.coordinate` is read on viewer-open and discarded). Add `.location` case to `SmartRule`. Ship a **place-grouped grid** (Apple Photos "Places → Grid" pattern: thumbnails grouped by geocoded place name — the cheap 80% of a map, zero network). Keep/extend the existing `OpenInMapsButton` link-out (`maps://`) — **add a Google Maps option** (trivial). Clustered in-app map (MKMapView + ClusterMap lib) is DEFERRED; globe is NEVER (CobeKit = decorative single-commit repo; ImmersiveMap = alpha/unstable/one maintainer; spatial views already removed twice; at most CobeKit as an ambient "shot in N countries" stats panel someday).
4. **Auto-Trips.** Cluster on time+place gaps; name via Foundation Models (already used for collection naming). Depends on (3). *Medium.*
5. **Side-by-side compare + focus peaking (culling).** Revisit the earlier "previews only" objection: decode at higher `kCGImageSourceThumbnailMaxPixelSize` in compare mode specifically. Port `PeakingOverlay` from Surface. Add sharpness scoring (Laplacian/Vision) as a badge — "which of the twelve frames is actually sharp" (FastRawViewer's pitch; Narrative Select's focus score UX). *Medium.*
6. **Ephemeral cull state.** A keep/reject pass state that resolves to stars-or-trash when done, then disappears. NOT a new permanent taxonomy (DECIDED: minimal sorting systems — see §8).

### Tier 2
- **Negative curation feedback** ("show this place less") once auto-collections exist. *Easy.*
- **SD-card/camera ingest** via ImageCaptureCore (no ingest story today beyond add-folder). *Medium.*
- Immich-style structured filter sheet as a discoverable alternative to typed tokens.

### Explicitly out
- Moodboard canvas (NEVER — that's Atlas/Milanote; Muse is a library, not a canvas)
- Browser extension (deprioritized — that's how inspo libraries fill, not photo libraries)
- Public share links requiring a server (NEVER — breaks local-first; Drive share covers it)
- Social-media bookmark sync à la Gather (NOT NOW; see §10 future ideas)

---

## 6. Editing

### The two-path model (DECIDED)
- **Path A — edit in Muse**, for JPEG/HEIC/PNG/TIFF/RAW/DNG: non-destructive adjustment stack, originals never touched, edits stored in DB + sidecars (never written into image files).
- **Path B — "Edit a Copy" in external apps** (Affinity, Canva, Photoshop, Pixelmator, anything): Lightroom's pattern. On Open With, when Muse edits exist, present the explicit fork: **Edit Original / Edit a Copy with Muse Adjustments**. The copy is rendered with adjustments applied, handed to the external app, and **comes back into the library as a new asset stacked with its parent** (critical — Peakto's one-way round-trip is its most trust-destroying flaw). Path B permanently protects Path A's scope: masking/healing/layers are answered by "do it there, it comes back," not by growing the editor.

### Prerequisite plumbing (do FIRST, in isolation, with tests — ~1 week)
The identity/cache layer assumes rendered pixels == original file bytes. An edit breaks that:
- `ThumbnailCache` is path-keyed with fixed `renderedVariants` → key must incorporate an edit-stack hash (`stack_hash` column) so edited thumbnails invalidate correctly
- `ImageHeaderSizeCache`/`AspectRatioCache` read header dimensions → a crop desyncs masonry frames, hero flight geometry, PDF pagination. Layout consumers must consult effective (post-crop) dimensions
- Export paths (`CollectionPDFExporter`, `DriveClient.uploadFile`, share sheet) re-read the original URL → would silently ship unedited pixels. All exports must render through the edit stack
- `Indexer.reconcile` and `analyzed_hash` stay keyed on ORIGINAL bytes (edits don't change content identity — correct; just don't let anything conflate "rendered" with "original")

### Edit model (port from Surface, extend)
```swift
struct EditStack: Codable {
  var schemaVersion: Int
  var processVersion: Int      // rendering-semantics version — NEVER mutate old stacks
  var rawParams: RawParams?    // CIRAWFilter-side params
  var adjustments: [Adjustment]// fixed order, enum-tagged (NOT reorderable — NEVER)
  var masks: [Mask]            // empty in v1; slot reserved
}
```
- One JSON blob per photo (per (file, parent_dir) consistent with tag scoping), GRDB `edits` table + `stack_hash`; mirrored into sidecars (mobile-later prerequisite)
- **Process versions are non-negotiable**: macOS 27's RAW decoder v9 drops `detailAmount`, `colorNoiseReductionAmount`, `moireReductionAmount` — old stacks must keep rendering with old semantics; offer explicit opt-in upgrade with badge
- Every scale-dependent parameter normalized as fraction of long edge; **test asserting thumbnail/screen/export renders agree**
- Virtual copies/versions: multiple edit stacks per photo, surfaced in grid as a stacked badge (digiKam pattern), persistent (RawTherapee's session-only history is the anti-pattern)

### Pipeline (DECIDED: Core Image + Metal, zero third-party image dependencies)
- Working space: linear, extended-range, explicit everywhere (`workingColorSpace` set deliberately; custom Metal kernels receive working-space values — must not assume sRGB 0–1). Port Surface's `WorkingSpaceImage` type-safety pattern
- Scene-referred: adjustments operate on un-clamped linear data; single display transform at the end. **Highlight recovery must actually work** (Surface's clamp-then-adjust ordering is the documented mistake to avoid)
- RAW: **hybrid split** — drive `CIRAWFilter`'s own params for demosaic-stage operations (WB via `neutralTemperature`/`neutralTint`, highlight recovery, boost/baselineExposure, sharpness, luminance NR, `isLensCorrectionEnabled`), then generic CIFilter chain on `outputImage`. Neutralize Apple's default look for a clean start (`baselineExposure=0; shadowBias=0; boostAmount=0; localToneMapAmount=0; isGamutMappingEnabled=false` — WWDC21 session 10160). Never white-balance post-demosaic with `CITemperatureAndTint` (loses highlight headroom). Gate every RAW param on `filter.isSupported(option:)`; opt into decoder v9 where available (`supportedDecoderVersions.contains(.version9)`) — v9 is Neural Engine demosaic+denoise, 784 cameras, beat DxO DeepPrime in beta; Apple absorbs camera-profile churn
- HDR/EDR (iPhone gain-map HEIC is default capture now): load with `.expandToHDR`, don't clamp at 1.0, `CIToneMapHeadroom` before display, note many CIFilters zero `contentHeadroom`; export must round-trip the gain map
- Live canvas: persistent `MTKView` + long-lived `CIContext(cacheIntermediates: true)` at screen resolution with `scaleFactor`; separate export context (`cacheIntermediates: false`, `memoryLimit` 512–1024MB); export via `heifRepresentation`/`jpegRepresentation`; Extended Virtual Addressing entitlement; debounced/coalesced slider rendering (Surface's per-tick re-render is the anti-pattern)
- Known filter gaps + solutions: point tone curve — `CIToneCurve` is unusable (5-pt cap, undocumented spline, black-output bug) → evaluate monotone-cubic spline on CPU into 1024-entry LUT → `CIColorCurves` (~150 lines, no shaders). HSL → one Metal `CIColorKernel` (~120 lines MSL, published formulation). Clarity/Texture → one shared Metal blend kernel (midtone-weighted local contrast, Pat David formulation). Kernels in Metal (`[[stitchable]]`), never CIKL
- Open-source audit (all evaluated — final): darktable/RawTherapee/librtprocess/rawspeed = GPL/LGPL = **NEVER** (fatal for closed commercial app). PhotoDemon = VB6/Windows. scap = not actually open source. swift-png/swift-jpeg = slower than ImageIO, no color management. MetalPetal/GPUImage3 = dormant. LibRaw CDDL = viable but pointless vs RAW v9. **AsyncGraphics (MIT) = only one worth keeping in pocket, solely for bespoke Metal effects, never as the pipeline.**

### v1 adjustment set (DECIDED: manual, user-driven controls — NOT a preset-pack; user edits how THEY want)
Tone: Exposure, Contrast, Highlights, Shadows, Whites, Blacks. Color: Temperature, Tint (+ eyedropper), Vibrance, Saturation. Presence: Clarity, Texture, Sharpen, Noise Reduction. Curve: point tone curve, RGB + per-channel, **histogram drawn behind it**. Geometry: Crop, straighten, rotate, flip, aspect presets. Character: Vignette. RAW: auto lens-correction toggle. Workflow: per-slider reset, before/after, edit history, copy/paste/sync (below).

### The distinctive layer — readouts & learning tools (this is the differentiation; the audience is "curious about the technical side but not fluent")
Ranked; sizes for a solo dev on this stack:
1. **Tone-zone control (darktable tone-equalizer mechanic):** hover over image → readout shows that pixel's brightness zone (EV); scroll to lift/drop that zone; edge-aware mask (guided-filter style) preserves local contrast. The Zone System as direct manipulation; no consumer app has it. ~2 weeks Metal
2. **Teaching histogram:** RGB (not just luminance — single-channel clipping is the classic trap), waveform toggle, **plain-English clipping messages** under the graph (Darkroom's documented design), drag-histogram-to-adjust (darktable). ~1–2 weeks
3. **Before/after suite (DECIDED — required):** hold-to-peek original; ⌘Y side-by-side; split-wipe with draggable divider; **snapshots** (freeze current state, compare any two states via wipe — darktable). Cheap: cached rendered textures + mask composite. <1 week
4. **"Why it looks this way":** deterministic, rule-based plain-language notes from EXIF + image stats — "1/15s handheld → motion blur likely; shadows noisy because ISO 6400; 0.4% of pixels clipped." Nearly zero competition (only Adobe Project Indigo's experimental AI critique, Jul 2026, may never ship). Rule-based = cheap, private, on-brand. ~1–2 weeks
5. **Looks browser with live thumbnails (PhotoDemon pattern):** every preset/look rendered on YOUR image as a browsable grid. <1 week
6. **Clipping zebras** on-image (over/under, per-channel display clipping; raw-sensor clipping only if pipeline exposes pre-demosaic data — else skip). Days
7. **Zone overlay** (Silver Efex pattern): hover a zone strip → hatch matching image areas. Days (shares tone-eq mask)
8. Waveform/RGB parade as scope options. ~4 days on top of (2)
9. **Reference view** (LR Shift+R): pin any library photo beside the one being edited to match looks. Days
10. **ΔE spot adjustment** (RawTherapee Locallab mechanic / U-Point UX): click a color/region → Lab-distance × radial falloff mask → attach 3–4 adjustments. The one "local" tool that isn't a masking system. ~2 weeks. (v2 candidate)
11. Simplified 3-way grade wheels (shadows/mids/highlights). ~1 week (v2)
12. HSL chips with image eyedropper. 2–3 days (v2)
13. Film negative inversion (RawTherapee tool; two-point neutral sampling). ~1 week (DEFERRED unless film-scanning users appear; on-brand with Surface audience)
Skip: CIECAM, full filmic UI, Fattal DRC, true raw-clipping overlay (unless cheap).

### Editor layout (Carlos's sketch, validated + refined — DECIDED direction)
- Double-click image → large single-image view with info column right (exists today as hero viewer)
- **(Preview | Edit) segmented control, top-center.** Entering Edit: image shrinks slightly (mode-change transition, as Photos does), background becomes a **controllable neutral backdrop** — default 18% gray, right-click to switch white/light/mid/dark/black (Lightroom's exact convention; photographers know it; mid-gray is the color-judgment standard)
- Panels flanking the image: **anchored floating cards** — visually detached (shadow, margin) but positionally fixed with snap-back if dragged. NOT free-floating (Pixelmator Pro's headline redesign was *abandoning* floating palettes: occlusion, drift, lost-on-resize; Capture One's magnetic snapping is the acceptable middle). Internal tabs where needed
- Right side, tabbed: **Light** (tone sliders, tone-zone control, B&W) / **Color** (WB, vibrance/saturation, HSL chips later, grade wheels later) / **Looks** (preset browser grid, LUT strength slider)
- Left side: **scopes** (histogram/waveform), **info/EXIF** (plain-language mode), **history + snapshots**

### Copy/paste/sync + presets (DECIDED: required, v1)
- Copy adjustments → paste to selection, with **partial selection** (only tone / only color / only crop). Default = Capture One's "auto-select only what was actually adjusted" (NOT Lightroom's 60-checkbox wall)
- Batch sync across a shoot
- **User-saved presets:** named recipes. **Application is copy-by-value** — applying a preset copies values into the photo's edit stack; subsequent slider tweaks touch only the photo, never the preset. Preset mutation is a separate explicit action ("Update preset from this photo" / "Save as new"). This data-design rule delivers Carlos's requirement ("adjust for a certain image but not change the preset") automatically
- ~1 week total given the Codable stack; the #2 most-cited dealbreaker in light editors; Apple Photos can't batch at all

### Importing color settings & presets from elsewhere (DECIDED: wanted)
- **`.cube` 3D LUT import** — the universal format film companies/camera companies sell look packs in. ~100-line parser (LUT_3D_SIZE n, n³ RGB floats, R fastest) → `CIColorCubeWithColorSpace` (NEVER bare `CIColorCube` — color shifts on P3), `inputExtrapolate=true` for HDR, 0–100 strength slider. Reference impl: SwiftCube (MIT) — read, then write your own
- **Lightroom presets (.xmp)** — same crs: fields as edit import (§7); comes nearly free with that work; same "approximated" badge and envelope
- Capture One `.costyle` (XML): parseable subset, smaller audience — DEFERRED

### Editing estimate
**3–5 weeks to credible v1** (Carlos challenged the earlier 14–17-week figure; the revision is honest: the model layer is ported, sliders are days, the real cost is the cache/geometry plumbing + render-consistency tests + color management discipline). Readouts are each days, additive. Ongoing: budget 1–2 weeks of remediation per macOS major, forever (decoder changes, deprecated params, EDR shifts).

### NEVER build (editing)
Masking/brush systems (Path B covers it) · healing beyond a simple dust-spot clone-with-color-match · layers · AI subject/sky selection · camera calibration panel · manual lens-distortion sliders (profile DB = second product) · dehaze (research project for one slider) · parametric curve alongside point curve · reorderable stack · own demosaic/RAW engine · anything GPL · custom Metal pipeline replacing Core Image.

---

## 7. Import & migration from other apps

One coherent "Import from…" surface. Philosophy (DECIDED): **never pretend a translation is lossless; always show what happened; always leave the user able to redo it their way.**

### What ports losslessly (all sources)
`xmp:Rating` → stars · `dc:subject` + `lr:hierarchicalSubject` → tags · IPTC caption/title/creator · EXIF GPS · capture metadata. (Already partially shipped via `MetadataKeywordReader`.)

### Lightroom (.xmp sidecars / embedded XMP)
- crs: namespace is publicly documented. Import as **badged "approximated" starting points**: crop/angle/orientation (exact — pure geometry), white balance, exposure (within fraction of a stop), contrast, vibrance, saturation (directional), point tone curve (portable as a curve; noted caveat: applied post-Adobe-base-look so results shift)
- Do NOT attempt: Highlights/Shadows/Whites/Blacks/Clarity/Dehaze (adaptive, image-dependent operators — darktable skips them; Capture One approximates only ~6 global sliders; Luminar disclaims visible differences). This is the industry envelope; matching it is defensible, exceeding it is not
- One-click compare against the file's embedded rendered preview after import

### Color labels — the semantic collision (DECIDED)
LR's red *label* = workflow marker; Muse's red = content attribute (color search). **Never merge silently — it poisons color semantics.** Import-time mapping sheet, per color: **skip** / **import as namespaced label tag** (`Label: Red` — visually distinct chip, excluded from content-flavored search, collision-proof) / **map to a user-chosen tag** (e.g. their own `portfolio`). Remember choice; show post-import report ("312 ratings, 1,840 keywords, 47 red labels → `Label: Red`"). Note: LR pick/reject flags do NOT export to XMP — nothing to handle.

### Apple Photos
AAE/`PHAdjustmentData` blobs are Apple-private (zlib'd binary plist, no spec; osxphotos decodes but doesn't interpret; only crop *maybe* recoverable, fragile). **Supported path: import the RENDERED current image via PhotoKit (current-version request) + metadata.** State plainly: slider recovery is not possible (private format).

### Google Photos
Edits are server-side. Import = Takeout JSON metadata merge (photoTakenTime, geoData, description, people names, favorited — often stripped from the image files themselves) + treat edited JPEG as the picture.

### Eagle
`docs/future-features/eagle-library-import.md` exists already — .library format is readable; fold into the same Import surface.

### Import-size language (DECIDED)
- Analysis is ALWAYS ON — no off switch, no skip state
- Import is instant (photos browsable immediately); analysis runs in background, throttled on battery/Low Power Mode, paused under thermal pressure; finishes overnight-style
- **FYI notice, one button, gated on ESTIMATED TIME not count** (show when estimate > ~20–30 min; self-adjusts to machine speed — 8k photos might warrant it on M1 Air, non-event on M4 Pro): *"Heads up: analyzing 40,000 photos will take about 2 hours. They're ready to browse now — search and colors get smarter as it finishes."*
- Estimate calibrated on-device: analyze first ~200 files, measure, extrapolate (M1 Air vs M4 Pro differ 3–4×; hardcoded estimates will embarrass)
- Progress visible + findable: "34,000 of 100,000 analyzed" in Settings/sidebar footer with pause/resume; search results improve as index fills (unanalyzed photos still match filename/date/EXIF — cheap fields are immediate)
- Below the threshold: silent, no dialog

---

## 8. Sorting & organization principles

**DECIDED: minimal taxonomies. Resist adding sorting systems.**
- Stars stay (as-is, tag-implemented)
- Colors/shapes stay derived attributes — NOT taxonomy, NOT tags
- No permanent color-label system (dropped once already; incoming LR labels handled by the mapping in §7)
- No pick/reject permanent flags — only the ephemeral cull state (§5.6) that resolves to stars/trash and disappears
- Tags remain optional; every photo feature must work with tags off (search on derived metadata, §4)

---

## 9. Architecture, performance & platform requirements

### Platform (DECIDED)
- **Tuned for Apple Silicon, M1 as the reference floor — but the app SHIPS UNIVERSAL and must keep building for x86_64** (owner correction, 2026-08-01; the original text here read "Apple Silicon only" and that is what let Spec 03's `Float16` break the Release build entirely). Intel Macs must work; Silicon is where it is optimized (the ML stack leans on the Neural Engine). Arch-specific code needs a portable path — see `ClipVectors`.
- Two-tier performance envelope:
  - **Design center: ~10k–50k photos on any M1, including M1 Air 8GB.** Everything instant; embeddings RAM-resident (50k ≈ 50MB); brute-force search a few ms. This case must be flawless. **Reference test machine: M1 Air 8GB** with hard budgets (grid scroll, search latency, slider-to-render latency, cold start)
  - **Accommodated edge: ~200k–800k+.** A pro/edge case on pro hardware. Degrade gracefully — never crash, never corrupt, never beachball; indexing may take hours, search may take ~0.5s. Mechanical (not architectural) fixes when needed: embeddings memory-mapped or sqlite-vec; clustering time-bucketed before comparison; search debounced + paged. **Rule now: never write code that assumes everything fits in RAM** — big-library support must be a tuning pass, not a rewrite. (Marketing note: "tested with libraries of 500k+" is credible and cheap to earn.)
- M1-specific risks are RAM pressure (8GB) and fanless-Air thermals, not compute: fp16 everywhere, decode budgets (extend existing `DecodePermit`), indexing throttle on battery/Low Power, edit preview at screen resolution never full-res

### Code architecture (DECIDED)
- **Files must not balloon as features land.** `AppState` (1380 LOC/~70 @Published) is frozen — new features get their OWN state objects/modules (editing store, search store, import store). Every new @Published on AppState invalidates more UI
- **Platform-neutral core package** (SurfaceCore pattern): edit recipes, search/query logic, sidecar I/O, import mapping — zero AppKit imports. This is the cheap insurance for iOS-later
- **Mobile-later prerequisites (design now, build later):** edit stacks mirrored in JSON sidecars; per-field sidecar clock (already flagged in Muse docs as the iOS blocker — stays deferred but nothing may make it harder)
- Dependencies stay minimal (currently 2). Editing adds zero. Additions require justification; models (CLIP, later faces) downloaded on-demand, not bundled in the binary, to keep the app lightweight
- **Fast and lightweight is a product feature.** Perceived-speed rules: precompute at analyze time, query only indexes; debounce; virtualized everything (already true of the grid)

### UI theming (DECIDED: tokenized, future-proof)
- Single semantic theme layer: one `Theme` type via Environment — surface/accent/spacing/radius/typography by ROLE. No raw hex/magic numbers scattered in views
- Prefer system-provided primitives: semantic colors (`.primary`, `.separator`), SF Symbols, system materials, standard controls — the parts Apple restyles for free when design language shifts (Liquid Glass being the live example: system-material apps got it free, hand-drawn chrome went stale)
- Rule of thumb: **custom layouts, system skin.** Goal: a design refresh in year 5 is a token-file change, not a rewrite

---

## 10. Sharing

### Existing system (shipped — the most differentiated feature in the app; understand before touching)
Drive collection share: manifest (signature text, expiry, ordered Drive image ids, filenames, optional PDF id) is base64url'd (optionally DEFLATE'd) into the **URL fragment** — never reaches any server. Static page on Cloudflare Pages renders it; images from the user's own Drive (`drive.file` scope, OAuth PKCE); EXIF/GPS stripped on upload (`ImageMetadataStripper`); expiry sweeper; decompression-bomb cap (`MAX_INFLATED`, do not remove); bidi/zero-width sanitization; strict CSP. Recipient's PDF = the printed page. **Zero infrastructure, zero marginal cost, developer receives no data.** Nobody in either category has this (Immich needs your own server; Savee charges $15/MO for hosted portfolio — the closest analogue).

### Decisions on sharing (all DECIDED)
- **Backends: Google Drive ONLY.** iCloud links were explored before — too many complications. Dropbox = more friction than Google. Most people have or will accept a Google account (known/trusted). Improvement direction: smooth in-app Google sign-up/on-ramp flow, and explain in UI that recipients wanting originals can be sent a normal Drive link by the owner
- **No download-originals feature.** The user's Drive already gates that; explain the option, don't build it
- **No server-side share state, ever**

### Expansions (build, in rough order)
1. **Layout options** for the share page: grid / contact sheet / single-column essay. Cheap; changes what a share IS
2. **Portfolio mode:** a persistent (non-expiring, updatable) share that reads as a small site. This is Savee's $15/mo top-tier feature — offered here as part of the upsell tier
3. **Custom domains (the paid tier):**
   - **Cloudflare for SaaS**: verified pricing — **100 custom hostnames FREE on every plan, then $0.10/hostname/month** ($0 at 100 customers; ~$90/mo at 1,000 — wildly margin-positive against a domain upsell)
   - Architecture: ONE ~50-line provisioning Worker (verify app-issued license/JWT → rate-limit one active hostname per license → forward create/status/delete to CF API with token in Worker secret). **NEVER ship the CF API token in the app.** Workers free tier (100k req/day) covers it forever
   - UX fits in an in-app modal (no web portal needed): user enters `photos.theirdomain.com` → Worker creates custom hostname → app shows copy-paste CNAME (+DCV) instructions → app polls status until active (minutes–hour) → share links flip to the custom domain. Same Pages deployment serves every hostname (fragment-based data needs zero changes)
   - Subdomains only (`photos.domain.com`) — apex requires CF Enterprise; note CNAME-flattening workaround for users on Cloudflare DNS
   - **Free/cheap middle tier:** `username.muse-photo.com` via wildcard DNS — zero provisioning cost, gate behind paid accounts (abuse/Safe-Browsing risk), takedown path required
   - **The username applies to ALL of a user's links, not just their portfolio (owner decision 2026-08-04).** Spec 07 built sharing on one host and Spec 08 later added a username to portfolio mode alone; that split was an artifact of the order the specs were written, NOT a design decision, and the owner rejected it as incoherent — a user with a name should not send trip photos from one hostname and their portfolio from another. Nothing technical forces the split: the manifest rides the URL fragment and the same Pages deployment serves every hostname unchanged. So once a user has a name, every new link they create is `carlos.muse-photo.com/#<manifest>`.
   - **`share.muse-photo.com` is the DEFAULT hostname** — what every link uses when the user has no username, which is everyone until Spec 08 ships. It is permanent and can never be retired: links already sent are immutable, and the same is true of the original `muse-share.pages.dev`, so that Pages project must never be deleted either. Adopting a username moves NEW links only.
   - **DEFERRED to Spec 08/09 — do NOT cut the app over early (owner decision 2026-08-04).** `muse-share.pages.dev` works today and every link minted from it stays valid forever, so there is no reason to touch app code before the custom-domain work actually runs. Flipping the constant before the new host serves would mint dead links. When Spec 08/09 is built, the switchover is one pass:
     - `DriveConfig.shareBaseURL` — the live constant every link is built from. `CommerceConfig.announcementsURL` derives from it, so `announcements.json` must already exist at the new host or the launch fetch 404s.
     - `InfoSheet.swift` — the privacy deep link is hardcoded separately and will NOT follow the constant.
     - `DriveShareStoreTests.swift` — two fixture URLs, cosmetic.
     - **The Google OAuth console** — `consentScreenVerified` is still `false`, and `web/share/robots.txt` keeps `/about` crawlable specifically so Google can reach it for verification. The console's homepage/privacy/terms URLs point at the old host; changing them mid-review restarts verification, so settle the hostname BEFORE submitting.
     - `web/share/_headers` — HSTS is `includeSubDomains; preload`. Fine on a subdomain; never serve that header from the apex or every future `muse-photo.com` subdomain is committed to HTTPS-only before it exists.
     - The `RESERVED` username list in Spec 08's `validate.js` must be live before the wildcard tier opens, or a customer could claim `share`/`domains`/`admin` and take down your own infrastructure hostname.
   - Market anchor: manual CNAME + verify button is the standard (SmugMug, Adobe Portfolio); Savee bundles portfolio+domain at $15/mo — evidence of willingness to pay
4. **Social export presets** (see below) feeding the share/export flow

### Social export (DECIDED: big deal — optimize seriously)
- **Aspect-mismatch UX (DECIDED):** an interactive crop step INSIDE the export flow — show the target frame, let the user position it, persist nothing unless asked ("temporary social version"). Never force a master crop; never auto-accumulate permanent social versions (LR users make a virtual copy, crop, export, DELETE it — they're telling you they want ephemeral)
- **Matte/border option** per preset: Crop / Matte (white/black — the culturally dominant IG "no crop" look) / Blur-extend. Standing unanswered Adobe feature request; desktop-underserved; people use janky phone apps today
- All presets: sRGB, baked orientation, JPEG. "Sharpen" = output sharpening for downscale. Metadata stripped by default EXCEPT photography platforms (toggle):

| Preset | Dims | Quality | Sharpen | Notes |
|---|---|---|---|---|
| IG Feed Portrait (default) | 1080×1350 (4:5) | q88, target <1MB | Standard | 4:5 remains correct post-2025 grid change; keep key content center-safe (grid previews crop to 3:4) |
| IG Grid-optimized | 1080×1440 (3:4) | q88 | Standard | Warn: feed crops to 4:5 |
| IG Square / Landscape | 1080×1080 / 1080×566 | q88 | Standard | |
| IG/Threads Story-Reel | 1080×1920 | q88 | Standard | 250px top/bottom safe zone |
| IG Carousel | 1080×1350 all slides | q88 | Standard | First slide's ratio locks carousel — enforce uniform |
| Threads | 1080×1350 | q88 | Standard | IG pipeline |
| X | ≤4096 long edge | q90 | Light | **Hit X's documented no-recompress rule** (≤4096², <5MB, RGB, no EXIF-orientation, bytes < W×H): original bytes served untouched — a real marketing line |
| 2000×2000-ish note | | | | IG recompresses everything to ~q70–75 at 1080w; PNG/HEIC get converted (PNG more aggressively) — always hand IG a finished sRGB JPEG at exactly 1080w, 300–800KB, so its encoder has nothing to do |
| Facebook | 2048 long edge | q85, <1MB | Standard | FB's high-res bucket |
| Pinterest | 1000×1500 (2:3) | q90 | Standard | |
| Flickr / 500px | original size | q95 | None | Keep EXIF toggle ON |
| Glass | 2560–4096 long edge | q92 | Light | Glass WANTS EXIF (shows gear info) — keep metadata ON by default |

---

## 11. Commercial plumbing (one workstream — slot EARLY; least design risk, real lead time)

**DECIDED: Mac App Store EXCLUSIVELY.** Rationale: discoverability — "photo library" is a term people actually search in the App Store; a self-hosted download no one will ever find. GitHub download and Sparkle are removed. Consequences below are binding.

- **Payments/licensing = StoreKit 2, nothing else.** Apple handles tax/VAT/refunds. Fee: 15% via the App Store Small Business Program (under $1M/yr — enroll; otherwise 30%)
- **Purchase structure (forced by MAS — no paid-upfront-with-trial exists):** **free download → built-in trial → one-time non-consumable IAP unlock** for the app's paid tier; the sharing tier (custom domain + portfolio) = **auto-renewable subscription** via IAP (it's a digital service — must go through Apple)
- **Gift/redemption codes (DECIDED: wanted):** Apple **promo codes** — 100 per IAP per app version. No coupon system to build
- **Sparkle removal tasks:** drop the dependency (target: GRDB is the only third-party dep), delete DMG/appcast/`release.sh` tooling, App Store Connect submission flow replaces it. **TestFlight for Mac** becomes the beta channel (use it for the 10-photographer validation pass)
- **Sandboxing:** already done (Muse is sandboxed with security-scoped bookmarks) — the biggest MAS hurdle for a files-based app is already cleared. Google Drive OAuth is a feature connecting the user's own account, not an app login — Sign-in-with-Apple requirement (guideline 4.8) should not apply; verify at review time
- **Announcements channel (DECIDED: wanted** — e.g. "mobile app now available"): static `announcements.json` on the existing Cloudflare Pages domain, fetched once per launch, each message shown once (by id), **off-able in Settings**, documented as a sanctioned network path. No server, no accounts, no tracking. (App Store "What's New" covers version notes; this covers everything else)
- **Network-path doctrine after this project (app-initiated):** Drive share (user-initiated) · announcements.json (launch, off-able) · custom-domain provisioning Worker (paid feature, user-initiated). Document all three in CLAUDE.md; everything else stays blocked. StoreKit/App Store traffic is OS-level
- **Trial:** built-in trial on the free download (time-limited default; exact shape OPEN — see Spec 09)
- **Review-cycle note:** App Review adds days of latency to every release — plan hotfix discipline accordingly

### Pricing (OPEN — final decision deferred until the feature set is real; current leaning + constraints)
- **Constraint (DECIDED): nothing over $100.** Affordable is the point
- Carlos's stated options: cheaper yearly plan AND/OR a just-own-it price
- Research anchors: Eagle $34.95 one-time/400k users · Atlas $39 · Photomator $29.99/yr or $79.99–119.99 lifetime · Darkroom $39.99/yr or $99.99 lifetime · Nitro $99.99 · Excire $249 (no editing!) · Photo Mechanic $299+ (called "well out of hobbyist territory" by its own fans). Perpetual/paid-upgrades is the photo-category norm; subscription-on-the-pricing-page slightly undercuts anti-subscription positioning even if optional
- Current leaning discussed: free download + **~$49 one-time IAP unlock** (Eagle/Atlas territory) · **sharing tier** (custom domain + portfolio) as the one legitimately recurring piece, **~$15–20/YEAR auto-renewable** (vs Savee's $15/MONTH — 10× undercut on the only feature with a real competitor) · free `username.muse.app` tier included with the unlock
- The free download is a TRIAL vehicle, not a free tier — the app's paid feature set sits behind the unlock (exact trial gating OPEN, Spec 09)
- Setapp: N/A — App Store exclusive

---

## 12. Future ideas (parked by Carlos — do not build now, do not preclude)

- **Mobile app** — if the Mac app takes off. Prerequisites already encoded: platform-neutral core package, edit stacks in sidecars, per-field sidecar clock
- **Inspo/learning layer** ("school"): plugin-ish features that pull saved things from social/web into an inspo space; walkthroughs ("ideas for portraits, lighting, how to get this look"); possibly a paid AI feature. Related pattern to adopt WHEN relevant: Eagle 5.0's single shared AI-config hub (configure provider once — local or API — every feature inherits) + MCP support. NOT a launch thing
- In-app clustered map (MKMapView + ClusterMap (MIT) — native clustering collapses past a few thousand annotations; 2–3 days when wanted); ambient globe stats panel (CobeKit) for marketing someday
- Capture One `.costyle` import; film-negative inversion tool; C1-style structured filter sheet
- Named-people face recognition (the 2–3-month AuraFace project, §4)

---

## 13. Decision log (quick reference — do not re-ask)

| # | Question | Decision |
|---|---|---|
| 1 | Product direction | Photo-focused repositioning of Muse itself; one app, not two |
| 2 | Audience | Enthusiast photographers first; versatile library for everyone; designers welcome; no amputation |
| 3 | Lightroom in positioning | No — market-sizing reference only; audience mostly doesn't know LR |
| 4 | Canvas/moodboard | Never — Muse is a library, image-forward, not a canvas |
| 5 | Editing scope | Real manual user-driven adjustments (NOT preset-pack-only — explicitly rejected); global adjustments + readouts; masking/healing/layers answered by Edit-a-Copy |
| 6 | Edit-a-Copy | Yes — LR-style explicit fork for external editors; copy returns stacked with parent |
| 7 | In-app edit formats | JPEG/HEIC/PNG/TIFF + RAW/DNG via CIRAWFilter hybrid |
| 8 | Before/after | Required (peek, split, snapshots) |
| 9 | Copy/paste/sync + own presets | Required v1; presets copy-by-value; per-image tweaks never mutate preset |
| 10 | Preset/LUT import | .cube required; LR .xmp presets via the approximation envelope; .costyle deferred |
| 11 | Edit import from apps | LR: approximated + badged (industry envelope only); Apple/Google: rendered image + metadata, stated plainly |
| 12 | Color labels | Never silently merged into color semantics; mapping sheet (skip / `Label: X` namespaced / user-chosen tag) + post-import report |
| 13 | Sorting systems | Minimal. Stars stay; no new permanent taxonomies; ephemeral cull state only; everything works with tags off |
| 14 | Photo info as tags | No — derived, indexed metadata; not tags |
| 15 | Search | Superpowered, local, instant at 10k+; tokens + CLIP + region-similarity + auto-growing albums; FM natural-language → visible editable tokens |
| 16 | Faces | Detection-level now (cheap, Apple-approved); identity clustering deferred (AuraFace path when demanded); Apple People data inaccessible — accepted |
| 17 | Geocoding | Offline (bundled GeoNames); no per-photo network |
| 18 | Map | Not now — place-grouped grid + maps:// link-out (add Google Maps option); clustered map deferred; globe never |
| 19 | Sharing backend | Google Drive only; no iCloud/Dropbox; no download-originals feature; no server state ever |
| 20 | Custom domains | Yes, paid tier — CF for SaaS + ~50-line Worker + in-app modal UX; `username.muse-photo.com` free tier. **Domain purchased 2026-08-04: `muse-photo.com`, via Cloudflare Registrar (zone already on CF DNS).** `share.muse-photo.com` = the permanent default host for ALL share links; a username replaces it for ALL of that user's new links, not just their portfolio (see §10.3) |
| 21 | Social export | Required; ephemeral in-flow crop; matte/border option; preset table in §10; X no-recompress target |
| 22 | Analysis | Always on; never off, never skippable; background, throttled, pausable |
| 23 | Import-size notice | FYI only (one button), gated on estimated time > ~20–30 min (not count), estimate measured on-device |
| 24 | Platform floor | **REVISED 2026-08-01: universal build — Intel must work; Apple Silicon is the TUNING target, M1 minimum for the performance envelope; M1 Air 8GB = reference machine for the 10k–50k design center.** (Was "Apple Silicon only".) |
| 25 | Scale envelope | Design center 10k–50k flawless; 200k–800k accommodated gracefully (pro edge case, pro hardware); no code may assume RAM-residency |
| 26 | Architecture | AppState frozen; feature modules with own stores; platform-neutral core package; sidecar-mirrored edit stacks; ≤ minimal dependencies; on-demand model downloads |
| 27 | UI theming | Semantic token layer + system primitives ("custom layouts, system skin") so future Apple design shifts are cheap |
| 28 | Announcements | Static JSON on existing domain, shown once per id, off-able |
| 29 | Gift codes | Apple promo codes (100 per IAP per version) |
| 30 | Price ceiling | ≤ $100; leaning free download + ~$49 one-time IAP unlock + ~$15–20/yr sharing subscription; final call after features are real |
| 31 | License/repo | PolyForm Shield; GitHub going private |
| 32 | GPL code | Never (also MAS-incompatible) |
| 33 | Distribution | **Mac App Store EXCLUSIVELY.** No GitHub download, no Sparkle, no direct distribution. StoreKit 2 for all payments; TestFlight for betas; Small Business Program (15%) |

---

## 14. Suggested build order

1. **Foundation & plumbing:** persona/doctrine update in CLAUDE.md · share-extension target fix · coordinates persisted (v13) + backfill · edit-aware cache/geometry work (isolated, tested) · commercial plumbing start (StoreKit 2 products, trial gate, Sparkle removal, MAS submission pipeline, announcements path) — long lead, low risk
2. **Library becomes a photo library:** place-grouped grid + `.location` smart rule · rediscovery (lastViewedAt, shuffle, on-this-day) · near-duplicate stacks · search upgrade phase 1 (EXIF token search + debounced semantic + offline geocode)
3. **Culling & search phase 2:** side-by-side compare + focus peaking + sharpness badges · ephemeral cull state · MobileCLIP swap-in (license check first) · region similarity · auto-growing albums · face detection (not identity)
4. **Editing:** model port from Surface → v1 adjustment set → before/after suite → copy/paste/sync + presets → Looks browser + .cube import → teaching histogram + clipping → tone-zone control → "why it looks this way" → Edit-a-Copy round-trip
5. **Import & migration:** unified Import-from surface (LR XMP incl. approximated edits + label mapping · Apple rendered · Google Takeout · Eagle) · import-size FYI
6. **Sharing expansion:** layout options → portfolio mode → username.muse.app tier → custom domains (Worker + modal) → social export presets + matte/border
7. **Launch prep:** pricing final call (IAP structure) · trial mechanics · App Review readiness · perf validation against M1 Air 8GB budgets · "tested with 500k" validation pass · site rewrite around no-catalog positioning (site markets; App Store distributes)

*(Phases 2–3 and 4 can interleave; 1 unblocks everything and should start immediately. Validation with ~10 real photographers using the current app should run in parallel with phase 1–2 — the readouts/learning-layer bets in particular want a reality check.)*

---

## 15. Key technical references

- WWDC26 §305 (RAW v9 / Core Image RAW) · WWDC21 §10160 (CIRAWFilter neutralization) · WWDC24 §10177 + WWDC23 §10181 (HDR/gain maps) · WWDC20 §10021 (Metal CI kernels) · WWDC25 §286/§301 + WWDC26 §241 (Foundation Models guided generation)
- Adobe crs: namespace docs (github.com/adobe/xmp-docs …/crs.md; exiv2.org/tags-xmp-crs.html) · darktable LR-import mapping (docs.darktable.org 4.2 sidecar-import) · Capture One LR importer support article
- Cloudflare for SaaS: developers.cloudflare.com/cloudflare-for-platforms (plans page: 100 free, $0.10/hostname/mo)
- Models: apple/ml-mobileclip (weights TOU — legal review) · fal/AuraFace-v1 (Apache 2.0, HF) · GeoNames cities datasets (CC-BY 4.0) · ClusterMap (MIT, github.com/vospennikov/ClusterMap) · SwiftCube (MIT, .cube parser reference)
- X no-recompress rule: compress-or-die.com Twitter analysis · IG spec/compression: sammapix.com; metricool.com · Glass upload FAQ (glass.photo) · Flickr upload requirements
- UX precedents: Darkroom histogram design post (darkroom.co/blog/2019-08-histogram) · darktable tone equalizer/scopes/snapshots manuals (docs.darktable.org) · Pixelmator Pro floating→docked history (MacStories first-impressions) · digiKam versioning (userbase.kde.org) & face pipeline (8.5/8.7 release notes) · Immich search/faces docs (docs.immich.app) · Silver Efex zone map · FastRawViewer feature set
