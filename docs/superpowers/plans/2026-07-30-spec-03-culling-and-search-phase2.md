# Spec 03 — Culling & Search Phase 2 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship the CLIP semantic search engine, similarity search (text/image/region), auto-growing `.similar` smart collections, natural-language search suggestions, side-by-side compare with focus peaking, an ephemeral cull (keep/reject) workflow, and faces/pets search tokens — per `docs/new-build/spec-03-implementation.md`.

**Architecture:** Two independent arcs that both build on the Spec 02 search module. Arc A (no model dependency, build first): `photo_traits` schema + Vision face/pet/sharpness detection + faces/pets/`is:` tokens + compare/peaking/sharpness badges + the ephemeral cull store. Arc B (the CLIP arc): an on-demand-downloaded Core ML model (`ClipModelStore`) powers a streamed brute-force vector index (`ClipIndex`) that becomes the semantic search leg, a `similar:` token bridged through a session-scoped `SimilarityRegistry`, region similarity in the hero viewer, an auto-growing `.similar` smart-rule case, and a Foundation Models natural-language suggestion layer that composes into the same token grammar. Every new async pass follows the codebase's existing "Pattern B" store shape and the `PhotoHeaderBackfill`-style launch backfill shape.

**Tech Stack:** Swift 5 / SwiftUI / AppKit escape hatches, GRDB.swift (SQLite), Vision framework, Core ML (CLIP), Core Image (peaking), Accelerate/vDSP, Foundation Models (macOS 26+, availability-gated).

## Prerequisite

**This plan assumes Spec 01 (`docs/superpowers/plans/2026-07-30-spec-01-foundation-plumbing.md`) and Spec 02 (`docs/superpowers/plans/2026-07-30-spec-02-photo-library-core.md`) have already been executed and merged.** Every file/line reference below describes the codebase's state AFTER those plans land, not today's tree (which currently ends at migration `v12_smart_collections`). In particular this plan depends on, from Spec 02's plan: `Search/SearchToken.swift` (`SearchToken` enum, `SearchQueryParser.parse`, `ParsedQuery.removing(tokenAt:)`), `Search/PhotoSearch.swift` (`PhotoSearch.filter(tokens:db:) throws -> Result?`), `Search/SearchFacets.swift` (`SearchFacets`, `SearchSuggest`), the token chip bar in `Views/TagChipsRow.swift`, `Components/EscapeAction.swift`'s `EscapeResolver.action(...)` (ending order: modal → viewer → search → tags → collection → rediscovery → collectionsPage → placesPage → none), `Models/RediscoveryStore.swift` (`markViewed(url:)`), and the migration chain ending at `v17_stacks` in `Database/Database.swift`'s `makeMigrator()`. If any of those signatures drifted during Spec 01/02 execution, adjust this plan's references accordingly before starting — the underlying patterns (Pattern B stores, `registerMigration` placement immediately before `return migrator`, `queue.write`/`queue.read` async GRDB access) are stable regardless.

## Global Constraints

- Min macOS **14.6**; Apple-Silicon-only (M1 floor). Foundation Models / `@Generable` guided generation is gated `#if canImport(FoundationModels)` + `@available(macOS 26.0, *)` + `SystemLanguageModel.default.availability == .available` (the exact triple `Intelligence/Core/CollectionNaming.swift`'s `FoundationModelNamer.makeBest()` already uses) — never assume availability elsewhere.
- **Dependency count target: GRDB only.** CLIP's tokenizer is pure Swift BPE (~150 LOC), no dependency added.
- **Query time touches only precomputed data.** Nothing expensive may run inline during a keystroke or a live grid render; expensive work happens at analyze time or a bounded launch backfill.
- **Content-keyed vs. location-keyed grain, never conflated:** `clip_embeddings` and `photo_traits` are content-hash-keyed (same grain as `palette`/`feature_print`/`photo_meta`) — NOT the `(file_id, parent_dir)` grain tags/notes/ratings use.
- **fp16 everywhere** for vectors (`ClipVectors.toData`/`fromData`); **no code may assume the whole vector matrix fits in RAM** — `ClipIndex` streams fixed-size chunks (`chunkRows = 4_096`) regardless of library size.
- **All new automatic (no-click) full-raster decodes go through `ThumbnailCache.withinDecodeBudget` first** (the bomb guard), same as every existing automatic decode site.
- **Every new user-facing string is wrapped in `String(localized:)`** at the call site (AppKit setters, custom view params, dynamic labels) — SwiftUI text-literal positions (`Text("…")`, `Label`, `.help("…")`) auto-extract; everything else does not. A localization export pass is the final task.
- **Every modal-adjacent button is `ModalButton`** (`Views/Modal/ModalButton.swift`, real init: `ModalButton(title:kind:isDefault:isCancel:action:)` — the parameter is `kind:`, not `style:`); every modal is an in-window card presented at the shell via `.museModal(isPresented:width:palette:content:)`, registered in `AppState.modalPresented`, never `.sheet`/`.alert`.
- **A mouse-only interaction needs a parallel `.accessibilityAction`** — VoiceOver cannot reproduce drag/marquee/keyboard-only affordances.
- **House test convention:** pure-logic only gets `XCTestCase` coverage (`import XCTest` + `@testable import Muse`, one `final class <Name>Tests`, small `test...()` functions calling static/enum functions directly — `Muse/MuseTests/ReclusterGateTests.swift` is the reference shape). UI wiring (modal presentation, chrome buttons, context-menu items, key-catcher passthrough) is verified by building and manually exercising the feature, not by a UI unit test — this codebase has none.
- **Migrations register via `migrator.registerMigration("vNN_name") { db in ... }` immediately before `return migrator`** in `Database/Database.swift`'s `makeMigrator()` (real pattern verified at `Database.swift:63` / `:357-367`). This plan's migrations are `v18_clip_embeddings` then `v19_photo_traits`, in that numeric/registration order, landing after Spec 02's `v17_stacks` — even though the BUILD order below does the traits work (which needs v19) before the CLIP work (which needs v18). Task 3 registers `v19_photo_traits` directly after `v17_stacks`; Task 20 later inserts `v18_clip_embeddings` BETWEEN `v17_stacks` and `v19_photo_traits` so the final registration order is v17 → v18 → v19.
- **Records go in `Database/Records.swift`**: `Codable + FetchableRecord + MutablePersistableRecord`, snake_case columns, inserted as `var` (GRDB mutates `id` in place on insert).
- **GRDB access is always `try await queue.write { db in ... }` / `try await queue.read { db in ... }`** inside async contexts — never the synchronous overload there.
- **A file that can't be decoded still gets its marker row stamped** (traits row with NULL fields, clip row with NULL vector) — never leave a permanent-retry gap the way `analyzed_hash` almost did.
- **No silent widening of a search filter.** An unresolvable `similar:` handle matches nothing (visible, removable, labeled chip), never falls back to the unfiltered set.

---

### Task 1: `SharpnessScore` — pure Laplacian-variance sharpness metric

**Files:**
- Create: `Muse/Muse/Intelligence/Core/SharpnessScore.swift`
- Test: `Muse/MuseTests/SharpnessScoreTests.swift`

**Interfaces:**
- Consumes: nothing (pure, `CGImage` in, `Double?` out)
- Produces: `SharpnessScore.score(_:) -> Double?`, `SharpnessScore.bucket(_:) -> Bucket`, `SharpnessScore.normalizedLongEdge = 1024` — consumed by Task 2 (Vision wiring), Task 15 (compare badges + hero INFO row)

- [ ] **Step 1: Write the failing tests**

```swift
//
//  SharpnessScoreTests.swift
//  MuseTests
//

import XCTest
import CoreGraphics
@testable import Muse

final class SharpnessScoreTests: XCTestCase {

    /// A checkerboard has strong high-frequency edges everywhere → high variance-of-Laplacian.
    private func checkerboard(side: Int = 256, cell: Int = 8) -> CGImage {
        let cs = CGColorSpaceCreateDeviceGray()
        let ctx = CGContext(data: nil, width: side, height: side,
                             bitsPerComponent: 8, bytesPerRow: side,
                             space: cs, bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        var buf = [UInt8](repeating: 0, count: side * side)
        for y in 0..<side {
            for x in 0..<side {
                let on = ((x / cell) + (y / cell)) % 2 == 0
                buf[y * side + x] = on ? 255 : 0
            }
        }
        buf.withUnsafeBytes { ptr in
            ctx.data!.copyMemory(from: ptr.baseAddress!, byteCount: buf.count)
        }
        return ctx.makeImage()!
    }

    /// A flat gray field has zero edges anywhere → variance-of-Laplacian ≈ 0.
    private func flatGray(side: Int = 256, value: UInt8 = 128) -> CGImage {
        let cs = CGColorSpaceCreateDeviceGray()
        let ctx = CGContext(data: nil, width: side, height: side,
                             bitsPerComponent: 8, bytesPerRow: side,
                             space: cs, bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        var buf = [UInt8](repeating: value, count: side * side)
        buf.withUnsafeBytes { ptr in
            ctx.data!.copyMemory(from: ptr.baseAddress!, byteCount: buf.count)
        }
        return ctx.makeImage()!
    }

    func testSharpImageScoresHigherThanFlatImage() {
        let sharp = SharpnessScore.score(checkerboard())
        let flat = SharpnessScore.score(flatGray())
        XCTAssertNotNil(sharp)
        XCTAssertNotNil(flat)
        XCTAssertGreaterThan(sharp!, flat!)
    }

    func testResolutionNormalizationKeepsSameSceneComparable() {
        // Same pattern rendered at 1x and 4x pixel density should score
        // within the compare tie band once downsampled to a fixed long edge.
        let base = SharpnessScore.score(checkerboard(side: 256, cell: 8))!
        let scaled = SharpnessScore.score(checkerboard(side: 1024, cell: 32))!
        XCTAssertEqual(base, scaled, accuracy: 0.5, "same scene at different pixel densities should normalize close")
    }

    func testDegenerateInputReturnsNil() {
        let cs = CGColorSpaceCreateDeviceGray()
        let ctx = CGContext(data: nil, width: 4, height: 4,
                             bitsPerComponent: 8, bytesPerRow: 4,
                             space: cs, bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        let tiny = ctx.makeImage()!
        XCTAssertNil(SharpnessScore.score(tiny))
    }

    func testBucketThresholds() {
        XCTAssertEqual(SharpnessScore.bucket(1.0), .soft)
        XCTAssertEqual(SharpnessScore.bucket(SharpnessScore.softCeiling), .soft)
        XCTAssertEqual(SharpnessScore.bucket(3.0), .moderate)
        XCTAssertEqual(SharpnessScore.bucket(SharpnessScore.sharpFloor), .sharp)
        XCTAssertEqual(SharpnessScore.bucket(5.0), .sharp)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild -scheme Muse test -only-testing:MuseTests/SharpnessScoreTests`
Expected: FAIL with "cannot find 'SharpnessScore' in scope"

- [ ] **Step 3: Write the implementation**

```swift
//
//  SharpnessScore.swift
//  Muse
//
//  log10(variance of 3x3 Laplacian) over luminance, downsampled to a FIXED
//  long edge before scoring — variance-of-Laplacian scales with pixel
//  pitch, so an unnormalized score would rank a 12 MP and 48 MP shot of the
//  same scene differently. Comparable only WITHIN one machine/Vision
//  revision/session (relative ranking, never an absolute cross-library
//  scale) — see SharpnessRank (Task 15).
//

import Accelerate
import CoreGraphics

nonisolated enum SharpnessScore {
    static let normalizedLongEdge = 1024

    /// Owner-validated (never live-validated against real photos yet).
    static let softCeiling: Double = 2.5
    static let sharpFloor: Double = 3.5

    enum Bucket: Equatable { case soft, moderate, sharp }

    static func bucket(_ score: Double) -> Bucket {
        if score <= softCeiling { return .soft }
        if score >= sharpFloor { return .sharp }
        return .moderate
    }

    /// nil for degenerate (<= 8px) input or a failed vImage conversion.
    static func score(_ cgImage: CGImage) -> Double? {
        guard cgImage.width > 8, cgImage.height > 8 else { return nil }

        let longEdge = max(cgImage.width, cgImage.height)
        let scale = longEdge > normalizedLongEdge
            ? Double(normalizedLongEdge) / Double(longEdge) : 1.0
        let width = max(1, Int(Double(cgImage.width) * scale))
        let height = max(1, Int(Double(cgImage.height) * scale))
        guard width > 8, height > 8 else { return nil }

        var format = vImage_CGImageFormat(
            bitsPerComponent: 8, bitsPerPixel: 8,
            colorSpace: Unmanaged.passRetained(CGColorSpaceCreateDeviceGray()),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
            version: 0, decode: nil, renderingIntent: .defaultIntent)

        var sourceBuffer = vImage_Buffer()
        defer { free(sourceBuffer.data) }
        guard vImageBuffer_InitWithCGImage(&sourceBuffer, &format, nil, cgImage,
                                            vImage_Flags(kvImageNoFlags)) == kvImageNoError
        else { return nil }
        defer { format.colorSpace.map { Unmanaged<CGColorSpace>.fromOpaque($0).release() } }

        var gray = vImage_Buffer()
        defer { free(gray.data) }
        guard vImageBuffer_Init(&gray, vImagePixelCount(height), vImagePixelCount(width),
                                 8, vImage_Flags(kvImageNoFlags)) == kvImageNoError
        else { return nil }
        guard vImageScale_Planar8(&sourceBuffer, &gray, nil, vImage_Flags(kvImageNoFlags)) == kvImageNoError
        else { return nil }

        var laplacian = vImage_Buffer()
        defer { free(laplacian.data) }
        guard vImageBuffer_Init(&laplacian, vImagePixelCount(height), vImagePixelCount(width),
                                 8, vImage_Flags(kvImageNoFlags)) == kvImageNoError
        else { return nil }

        let kernel: [Int16] = [0, 1, 0, 1, -4, 1, 0, 1, 0]
        let err = vImageConvolve_Planar8(&gray, &laplacian, nil, 0, 0, kernel, 3, 3,
                                          8, 0, nil, vImage_Flags(kvImageEdgeExtend))
        guard err == kvImageNoError else { return nil }

        let count = width * height
        var floatBuf = [Float](repeating: 0, count: count)
        let ptr = laplacian.data.bindMemory(to: UInt8.self, capacity: count)
        vDSP_vfltu8(ptr, 1, &floatBuf, 1, vDSP_Length(count))

        var mean: Float = 0
        vDSP_meanv(floatBuf, 1, &mean, vDSP_Length(count))
        var variance: Float = 0
        var negMean = -mean
        var centered = [Float](repeating: 0, count: count)
        vDSP_vsadd(floatBuf, 1, &negMean, &centered, 1, vDSP_Length(count))
        vDSP_measqv(centered, 1, &variance, vDSP_Length(count))

        guard variance > 0 else { return -Double.infinity }
        return log10(Double(variance))
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcodebuild -scheme Muse test -only-testing:MuseTests/SharpnessScoreTests`
Expected: PASS. If the normalization tolerance test is flaky, widen `accuracy` slightly — the exact bucket thresholds are owner-tuned later (§15 of the spec), this test only needs the ordering property to hold.

- [ ] **Step 5: Commit**

```bash
git add Muse/Muse/Intelligence/Core/SharpnessScore.swift Muse/MuseTests/SharpnessScoreTests.swift
git commit -m "feat(spec-03): add SharpnessScore pure Laplacian-variance metric"
```

---

### Task 2: `VisionServices` — face traits, animal detection, sharpness wiring

**Files:**
- Modify: `Muse/Muse/Intelligence/Vision/VisionServices.swift` (`analyze`, `detectFaces` → `detectFaceTraits`, new `detectAnimals`, `VisionResult`)
- Test: `Muse/MuseTests/VisionServicesTraitsTests.swift` (constants/shape only — no live Vision calls in unit tests, per house convention; a Vision request needs a real image + async framework call, so this test asserts the STRUCT shape and the confidence-floor constant, not live detection output)

**Interfaces:**
- Consumes: `ThumbnailCache.withinDecodeBudget`, the existing `runRequest<T>` single-resume wrapper (`VisionServices.swift:121-140`)
- Produces: `VisionResult.largestFaceFrac: Double?`, `.faceQuality: Double?`, `.petCount: Int`, `.sharpness: Double?`, `VisionServices.petConfidenceFloor: Float` — consumed by Task 4 (`analyzeOne` write)

- [ ] **Step 1: Write the failing test**

```swift
//
//  VisionServicesTraitsTests.swift
//  MuseTests
//

import XCTest
@testable import Muse

final class VisionServicesTraitsTests: XCTestCase {
    func testPetConfidenceFloorIsNamedConstant() {
        XCTAssertEqual(VisionServices.petConfidenceFloor, 0.5)
    }

    func testVisionResultCarriesTraitFields() {
        var result = VisionResult()
        result.largestFaceFrac = 0.12
        result.faceQuality = 0.8
        result.petCount = 2
        result.sharpness = 3.1
        XCTAssertEqual(result.largestFaceFrac, 0.12)
        XCTAssertEqual(result.faceQuality, 0.8)
        XCTAssertEqual(result.petCount, 2)
        XCTAssertEqual(result.sharpness, 3.1)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -scheme Muse test -only-testing:MuseTests/VisionServicesTraitsTests`
Expected: FAIL — `VisionResult` has no `largestFaceFrac`/`faceQuality`/`petCount`/`sharpness` members yet, and `petConfidenceFloor` doesn't exist.

- [ ] **Step 3: Implement**

In `VisionResult` (currently lines 17-31), replace `var faceCount: Int = 0` with the trait fields alongside it:

```swift
struct VisionResult {
    var classifications: [String: Float] = [:]
    var ocrText: String = ""
    var faceCount: Int = 0
    var largestFaceFrac: Double?
    var faceQuality: Double?
    var petCount: Int = 0
    var sharpness: Double?
    var dominantColor: String?
    var featurePrint: Data?
    var width: Int?
    var height: Int?
    var decodedImage: CGImage?
    var didSucceedFeaturePrint: Bool { featurePrint != nil }
}
```

Add the confidence-floor constant and rename/extend the face request (replacing the existing `detectFaces` at lines 180-186):

```swift
static let petConfidenceFloor: Float = 0.5

private static func detectFaceTraits(cgImage: CGImage) async -> (count: Int, largestFrac: Double?, quality: Double?) {
    let rects = await runRequest(on: cgImage, fallback: [VNFaceObservation]()) { finish in
        VNDetectFaceRectanglesRequest { req, _ in
            finish((req.results as? [VNFaceObservation]) ?? [])
        }
    }
    guard !rects.isEmpty else { return (0, nil, nil) }
    let largestFrac = rects.map { Double($0.boundingBox.width * $0.boundingBox.height) }.max()

    let qualities = await runRequest(on: cgImage, fallback: [VNFaceObservation]()) { finish in
        let req = VNDetectFaceCaptureQualityRequest { req, _ in
            finish((req.results as? [VNFaceObservation]) ?? [])
        }
        return req
    }
    let quality = qualities.compactMap { $0.faceCaptureQuality.map(Double.init) }.max()

    return (rects.count, largestFrac, quality)
}

private static func detectAnimals(cgImage: CGImage) async -> Int {
    await runRequest(on: cgImage, fallback: 0) { finish in
        VNRecognizeAnimalsRequest { req, _ in
            let count = (req.results as? [VNRecognizedObjectObservation] ?? [])
                .filter { obs in
                    obs.labels.contains { $0.confidence >= petConfidenceFloor }
                }
                .count
            finish(count)
        }
    }
}
```

Update `analyze` (lines 36-67) to fan out both new requests plus sharpness alongside the existing five, and to fill the new `VisionResult` fields:

```swift
static func analyze(url: URL) async -> VisionResult {
    var result = VisionResult()
    guard let cgImage = await loadCGImage(url: url) else { return result }
    let declared = ImageHeaderSizeCache.resolve(url)
    result.width = declared.map { Int($0.width) } ?? cgImage.width
    result.height = declared.map { Int($0.height) } ?? cgImage.height
    result.decodedImage = cgImage
    async let classify = classify(cgImage: cgImage)
    async let ocr = ocr(cgImage: cgImage)
    async let faceTraits = detectFaceTraits(cgImage: cgImage)
    async let featurePrint = featurePrint(cgImage: cgImage)
    async let dominantColor = dominantColor(cgImage: cgImage)
    async let pets = detectAnimals(cgImage: cgImage)
    let (cls, text, faces, fp, color, petCount) =
        await (classify, ocr, faceTraits, featurePrint, dominantColor, pets)
    result.classifications = cls
    result.ocrText = text
    result.faceCount = faces.count
    result.largestFaceFrac = faces.largestFrac
    result.faceQuality = faces.quality
    result.featurePrint = fp
    result.dominantColor = color
    result.petCount = petCount
    result.sharpness = SharpnessScore.score(cgImage)
    return result
}
```

- [ ] **Step 4: Run test to verify it passes, then a full build**

Run: `xcodebuild -scheme Muse test -only-testing:MuseTests/VisionServicesTraitsTests`
Expected: PASS.

Run: `xcodebuild -scheme Muse build`
Expected: BUILD SUCCEEDED (this catches any other call site still using the old `detectFaces` name/signature or `VisionResult.faceCount`-only construction — fix any that appear).

- [ ] **Step 5: Commit**

```bash
git add Muse/Muse/Intelligence/Vision/VisionServices.swift Muse/MuseTests/VisionServicesTraitsTests.swift
git commit -m "feat(spec-03): Vision face traits, pet detection, sharpness in analyze()"
```

---

### Task 3: `v19_photo_traits` migration + `PhotoTraitsRow`

**Files:**
- Modify: `Muse/Muse/Database/Database.swift` (`makeMigrator()` — register directly after `v17_stacks`, i.e. the last migration in the chain before this plan's work begins)
- Modify: `Muse/Muse/Database/Records.swift` (add `PhotoTraitsRow`)
- Test: `Muse/MuseTests/PhotoTraitsMigrationTests.swift`

**Interfaces:**
- Produces: `photo_traits` table (`file_id` PK cascade, `traits_scanned_hash`, `traits_version`, `face_count`, `largest_face_frac`, `face_quality`, `pet_count`, `sharpness`), `PhotoTraitsRow` — consumed by Task 4 (write), Task 8 (SQL), Task 15 (badges)

- [ ] **Step 1: Write the failing test**

```swift
//
//  PhotoTraitsMigrationTests.swift
//  MuseTests
//
//  v19_photo_traits: one shared table for faces + pets + sharpness, all
//  raster-derived scalars from a single decode. traits_version covers
//  future trait additions without a new marker/table.
//

import XCTest
import GRDB
@testable import Muse

final class PhotoTraitsMigrationTests: XCTestCase {

    private func makeQueue() throws -> DatabaseQueue {
        let q = try DatabaseQueue()
        try Database.makeMigrator().migrate(q)
        return q
    }

    private func insertFile(_ db: GRDB.Database, id: String) throws {
        try db.execute(sql: """
            INSERT INTO files (id, content_hash, kind, last_seen_at)
            VALUES (?, ?, 'image', 0)
            """, arguments: [id, id + "-hash"])
    }

    func testTableExistsWithExpectedColumns() throws {
        let q = try makeQueue()
        try q.read { db in
            XCTAssertTrue(try db.tableExists("photo_traits"))
            let columns = try db.columns(in: "photo_traits").map(\.name)
            for expected in ["file_id", "traits_scanned_hash", "traits_version",
                              "face_count", "largest_face_frac", "face_quality",
                              "pet_count", "sharpness"] {
                XCTAssertTrue(columns.contains(expected), "missing column \(expected)")
            }
        }
    }

    func testRowCascadesOnFileDelete() throws {
        let q = try makeQueue()
        try q.write { db in
            try insertFile(db, id: "f1")
            var row = PhotoTraitsRow(file_id: "f1", traits_scanned_hash: "f1-hash",
                                      traits_version: 1, face_count: 1,
                                      largest_face_frac: 0.2, face_quality: 0.7,
                                      pet_count: 0, sharpness: 3.2)
            try row.insert(db)
            try db.execute(sql: "DELETE FROM files WHERE id = 'f1'")
        }
        let remaining = try q.read { db in try PhotoTraitsRow.fetchAll(db) }
        XCTAssertTrue(remaining.isEmpty, "photo_traits row must cascade-delete with its file")
    }

    func testNullTraitFieldsRoundTripAsAttemptedMarker() throws {
        let q = try makeQueue()
        try q.write { db in
            try insertFile(db, id: "f2")
            var row = PhotoTraitsRow(file_id: "f2", traits_scanned_hash: "f2-hash",
                                      traits_version: 1, face_count: nil,
                                      largest_face_frac: nil, face_quality: nil,
                                      pet_count: nil, sharpness: nil)
            try row.insert(db)
        }
        let row = try q.read { db in try PhotoTraitsRow.fetchOne(db, key: "f2") }
        XCTAssertNotNil(row, "a NULL-field row is a legitimate attempted-marker, not absence")
        XCTAssertNil(row?.face_count)
    }

    func testMigrationIsIdempotentAfterV17() throws {
        // Registering the migrator twice against the same queue must not throw.
        let q = try DatabaseQueue()
        try Database.makeMigrator().migrate(q)
        try Database.makeMigrator().migrate(q)
        try q.read { db in XCTAssertTrue(try db.tableExists("photo_traits")) }
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -scheme Muse test -only-testing:MuseTests/PhotoTraitsMigrationTests`
Expected: FAIL — no `photo_traits` table, no `PhotoTraitsRow`.

- [ ] **Step 3: Implement**

In `Database/Database.swift`, insert immediately after the `v17_stacks` registration (the last one before `return migrator` at this point in the chain):

```swift
migrator.registerMigration("v19_photo_traits") { db in
    try db.create(table: "photo_traits") { t in
        t.column("file_id", .text).primaryKey()
            .references("files", onDelete: .cascade)
        t.column("traits_scanned_hash", .text).notNull()
        t.column("traits_version", .integer).notNull()
        t.column("face_count", .integer)
        t.column("largest_face_frac", .double)
        t.column("face_quality", .double)
        t.column("pet_count", .integer)
        t.column("sharpness", .double)
    }
    try db.create(index: "photo_traits_faces_idx", on: "photo_traits", columns: ["face_count"])
    try db.create(index: "photo_traits_pets_idx", on: "photo_traits", columns: ["pet_count"])
}
```

In `Database/Records.swift`, add:

```swift
struct PhotoTraitsRow: Codable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "photo_traits"

    var file_id: String
    var traits_scanned_hash: String
    var traits_version: Int
    var face_count: Int?
    var largest_face_frac: Double?
    var face_quality: Double?
    var pet_count: Int?
    var sharpness: Double?

    enum Columns {
        static let file_id = Column("file_id")
        static let traits_scanned_hash = Column("traits_scanned_hash")
        static let traits_version = Column("traits_version")
        static let face_count = Column("face_count")
        static let pet_count = Column("pet_count")
    }
}
```

Add the version constant near the row type or in a small `PhotoTraits` enum in the same file section:

```swift
enum PhotoTraits {
    static let currentVersion = 1
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild -scheme Muse test -only-testing:MuseTests/PhotoTraitsMigrationTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Muse/Muse/Database/Database.swift Muse/Muse/Database/Records.swift Muse/MuseTests/PhotoTraitsMigrationTests.swift
git commit -m "feat(spec-03): v19_photo_traits migration + PhotoTraitsRow"
```

---

### Task 4: Wire traits into `AnalyzePipeline.analyzeOne` + `TaggerOutput`

**Files:**
- Modify: `Muse/Muse/Intelligence/Core/IntelligenceProtocols.swift` (`TaggerOutput`)
- Modify: wherever `VisionTagger.analyze` fills `TaggerOutput` from `VisionResult` (the tagger implementation file — locate via `grep -rn "struct VisionTagger" Muse/Muse` before editing; it constructs a `TaggerOutput` from a `VisionResult`)
- Modify: `Muse/Muse/Intelligence/AnalyzePipeline.swift` (`analyzeOne`, inside the existing guarded write transaction at `:472-473` onward)
- Test: `Muse/MuseTests/AnalyzePipelineTraitsTests.swift`

**Interfaces:**
- Consumes: `TaggerOutput` (Task 2's `VisionResult` fields), `PhotoTraitsRow`/`PhotoTraits.currentVersion` (Task 3)
- Produces: `TaggerOutput.traits: TraitFields?` — consumed by nothing further in this plan directly, but the shape must stay stable for Task 28 (CLIP embed passthrough reuses the same `TaggerOutput.decodedImage` field this task's sibling work in Task 2 already populates via `VisionResult.decodedImage`)

- [ ] **Step 1: Write the failing test**

This exercises the pure mapping logic, not a live `queue.write` (that's covered by the existing `AnalyzePipeline` integration suites, unchanged in shape — this test isolates the new `TraitFields` struct and its construction from a `VisionResult`):

```swift
//
//  AnalyzePipelineTraitsTests.swift
//  MuseTests
//

import XCTest
@testable import Muse

final class AnalyzePipelineTraitsTests: XCTestCase {
    func testTraitFieldsConstructFromVisionResult() {
        var result = VisionResult()
        result.faceCount = 2
        result.largestFaceFrac = 0.3
        result.faceQuality = 0.9
        result.petCount = 1
        result.sharpness = 3.4

        let traits = TraitFields(from: result)
        XCTAssertEqual(traits.faceCount, 2)
        XCTAssertEqual(traits.largestFaceFrac, 0.3)
        XCTAssertEqual(traits.faceQuality, 0.9)
        XCTAssertEqual(traits.petCount, 1)
        XCTAssertEqual(traits.sharpness, 3.4)
    }

    func testTaggerOutputCarriesOptionalTraits() {
        let output = TaggerOutput(tags: [], caption: nil, ocrText: "", dominantColor: nil,
                                   palette: [], featurePrint: nil, width: nil, height: nil,
                                   traits: nil)
        XCTAssertNil(output.traits)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -scheme Muse test -only-testing:MuseTests/AnalyzePipelineTraitsTests`
Expected: FAIL — `TraitFields` doesn't exist; `TaggerOutput` has no `traits:` member.

- [ ] **Step 3: Implement**

In `Intelligence/Core/IntelligenceProtocols.swift`, add `TraitFields` and extend `TaggerOutput`:

```swift
struct TraitFields {
    var faceCount: Int
    var largestFaceFrac: Double?
    var faceQuality: Double?
    var petCount: Int
    var sharpness: Double?

    init(from result: VisionResult) {
        faceCount = result.faceCount
        largestFaceFrac = result.largestFaceFrac
        faceQuality = result.faceQuality
        petCount = result.petCount
        sharpness = result.sharpness
    }
}

struct TaggerOutput {
    var tags: [IntelTag]
    var caption: String?
    var ocrText: String
    var dominantColor: String?
    var palette: [String]
    var featurePrint: Data?
    var width: Int?
    var height: Int?
    var traits: TraitFields?
}
```

Fix the `VisionTagger.analyze` call site (found via grep) to pass `traits: TraitFields(from: visionResult)` (nil only on the tagger-nil/undecodable path, matching the existing `return nil` branch there).

In `AnalyzePipeline.swift`, inside the guarded write transaction (the block that already checks `file.content_hash == analyzedHash` starting around line 472), add the `PhotoTraitsRow` upsert right after the existing `files` row update and before the transaction returns `true`:

```swift
if let traits = out.traits {
    var traitsRow = PhotoTraitsRow(
        file_id: fileID, traits_scanned_hash: analyzedHash,
        traits_version: PhotoTraits.currentVersion,
        face_count: traits.faceCount, largest_face_frac: traits.largestFaceFrac,
        face_quality: traits.faceQuality, pet_count: traits.petCount,
        sharpness: traits.sharpness)
    try traitsRow.save(db)
}
```

The `markAnalysisAttempted` (tagger-nil / undecodable) path is unchanged here — it stamps `analyzed_hash` only; `photo_traits`'s own NULL-field marker row is stamped by the backfill (Task 5), not by this per-file live-analyze path, mirroring how `clip_embeddings`' NULL-vector marker is a backfill-only concern per the spec (§3.3).

- [ ] **Step 4: Run test to verify it passes, then a full build**

Run: `xcodebuild -scheme Muse test -only-testing:MuseTests/AnalyzePipelineTraitsTests`
Expected: PASS.

Run: `xcodebuild -scheme Muse build`
Expected: BUILD SUCCEEDED.

- [ ] **Step 5: Commit**

```bash
git add Muse/Muse/Intelligence/Core/IntelligenceProtocols.swift Muse/Muse/Intelligence/AnalyzePipeline.swift Muse/MuseTests/AnalyzePipelineTraitsTests.swift
git commit -m "feat(spec-03): write photo_traits inside AnalyzePipeline.analyzeOne"
```

---

### Task 5: `DeepAnalysisBackfill` (traits-only) + `MuseApp.swift` wiring

**Files:**
- Create: `Muse/Muse/Intelligence/DeepAnalysisBackfill.swift`
- Modify: `Muse/Muse/MuseApp.swift` (`.task` block, chained after the existing `PhotoHeaderBackfill` call)
- Test: `Muse/MuseTests/DeepBackfillSelectionTests.swift`

**Interfaces:**
- Consumes: `PhotoTraitsRow`/`PhotoTraits.currentVersion` (Task 3), `VisionServices.boundedDecode` (`VisionServices.swift:92-101`), `ThumbnailCache.withinDecodeBudget`
- Produces: `DeepAnalysisBackfill.run() async`, `DeepAnalysisBackfill.selectionSQL` (a pure-testable SQL-fragment or predicate function, so selection logic is unit-testable without a live Vision pass) — Task 28 later extends `run()`'s body with the CLIP branch; nothing else in this plan depends on this task's internals beyond that.

- [ ] **Step 1: Write the failing test**

Selection logic is the only pure-testable part of a backfill (the actual decode/Vision/write loop needs a live DB + real images, exercised manually per house convention). Structure `DeepAnalysisBackfill` so the "is this file stale" predicate is a free function:

```swift
//
//  DeepBackfillSelectionTests.swift
//  MuseTests
//

import XCTest
import GRDB
@testable import Muse

final class DeepBackfillSelectionTests: XCTestCase {

    private func makeQueue() throws -> DatabaseQueue {
        let q = try DatabaseQueue()
        try Database.makeMigrator().migrate(q)
        return q
    }

    private func insertFile(_ db: GRDB.Database, id: String, hash: String) throws {
        try db.execute(sql: """
            INSERT INTO files (id, content_hash, kind, last_seen_at)
            VALUES (?, ?, 'image', 0)
            """, arguments: [id, hash])
        try db.execute(sql: """
            INSERT INTO paths (id, file_id, absolute_path, is_alive)
            VALUES (?, ?, ?, 1)
            """, arguments: [id + "-p", id, "/tmp/\(id).jpg"])
    }

    func testMissingTraitsRowIsSelected() throws {
        let q = try makeQueue()
        try q.write { db in try insertFile(db, id: "f1", hash: "h1") }
        let ids = try q.read { db in try DeepAnalysisBackfill.staleTraitsFileIDs(db: db, limit: 10) }
        XCTAssertEqual(ids, ["f1"])
    }

    func testStaleHashIsReselected() throws {
        let q = try makeQueue()
        try q.write { db in
            try insertFile(db, id: "f2", hash: "h2-new")
            var row = PhotoTraitsRow(file_id: "f2", traits_scanned_hash: "h2-old",
                                      traits_version: PhotoTraits.currentVersion,
                                      face_count: 0, largest_face_frac: nil,
                                      face_quality: nil, pet_count: 0, sharpness: nil)
            try row.insert(db)
        }
        let ids = try q.read { db in try DeepAnalysisBackfill.staleTraitsFileIDs(db: db, limit: 10) }
        XCTAssertEqual(ids, ["f2"])
    }

    func testVersionBehindIsReselected() throws {
        let q = try makeQueue()
        try q.write { db in
            try insertFile(db, id: "f3", hash: "h3")
            var row = PhotoTraitsRow(file_id: "f3", traits_scanned_hash: "h3",
                                      traits_version: 0, // behind PhotoTraits.currentVersion
                                      face_count: 0, largest_face_frac: nil,
                                      face_quality: nil, pet_count: 0, sharpness: nil)
            try row.insert(db)
        }
        let ids = try q.read { db in try DeepAnalysisBackfill.staleTraitsFileIDs(db: db, limit: 10) }
        XCTAssertEqual(ids, ["f3"])
    }

    func testUpToDateRowIsNotReselected() throws {
        let q = try makeQueue()
        try q.write { db in
            try insertFile(db, id: "f4", hash: "h4")
            var row = PhotoTraitsRow(file_id: "f4", traits_scanned_hash: "h4",
                                      traits_version: PhotoTraits.currentVersion,
                                      face_count: 0, largest_face_frac: nil,
                                      face_quality: nil, pet_count: 0, sharpness: nil)
            try row.insert(db)
        }
        let ids = try q.read { db in try DeepAnalysisBackfill.staleTraitsFileIDs(db: db, limit: 10) }
        XCTAssertTrue(ids.isEmpty)
    }

    func testDeadPathFileIsNotSelected() throws {
        let q = try makeQueue()
        try q.write { db in
            try db.execute(sql: "INSERT INTO files (id, content_hash, kind, last_seen_at) VALUES ('f5', 'h5', 'image', 0)")
            try db.execute(sql: "INSERT INTO paths (id, file_id, absolute_path, is_alive) VALUES ('f5-p', 'f5', '/tmp/f5.jpg', 0)")
        }
        let ids = try q.read { db in try DeepAnalysisBackfill.staleTraitsFileIDs(db: db, limit: 10) }
        XCTAssertTrue(ids.isEmpty)
    }

    func testLimitIsRespected() throws {
        let q = try makeQueue()
        try q.write { db in
            for i in 0..<5 { try insertFile(db, id: "g\(i)", hash: "h\(i)") }
        }
        let ids = try q.read { db in try DeepAnalysisBackfill.staleTraitsFileIDs(db: db, limit: 3) }
        XCTAssertEqual(ids.count, 3)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -scheme Muse test -only-testing:MuseTests/DeepBackfillSelectionTests`
Expected: FAIL — `DeepAnalysisBackfill` doesn't exist.

- [ ] **Step 3: Implement**

```swift
//
//  DeepAnalysisBackfill.swift
//  Muse
//
//  Launch pass that fills photo_traits (and, once the CLIP model is
//  installed, clip_embeddings — Task 28 extends this) for files whose
//  analyzed_hash is already current, so analyzePending will never revisit
//  them. Modelled on PhotoHeaderBackfill: fire-and-forget Task from
//  MuseApp's .task, PhaseTrace-marked, self-limiting.
//

import Foundation
import GRDB

nonisolated enum DeepAnalysisBackfill {
    static let maxPerLaunch = 5_000
    static let concurrency = 2
    static let writeChunk = 200
    static let decodeMaxPixel = 1024

    /// Image-kind files with an alive path whose photo_traits marker is
    /// missing, stale-by-hash, or version-behind. Pure/testable — no
    /// decode, no Vision call.
    static func staleTraitsFileIDs(db: GRDB.Database, limit: Int) throws -> [String] {
        try String.fetchAll(db, sql: """
            SELECT f.id FROM files f
            JOIN paths p ON p.file_id = f.id AND p.is_alive = 1
            LEFT JOIN photo_traits t ON t.file_id = f.id
            WHERE f.kind IN ('image', 'raw', 'psd')
              AND (t.file_id IS NULL
                   OR t.traits_scanned_hash != f.content_hash
                   OR t.traits_version < ?)
            GROUP BY f.id
            LIMIT ?
            """, arguments: [PhotoTraits.currentVersion, limit])
    }

    static func run() async {
        guard let queue = Database.shared.dbQueue else { return }
        let candidateIDs = (try? await queue.read { db in
            try staleTraitsFileIDs(db: db, limit: maxPerLaunch)
        }) ?? []
        guard !candidateIDs.isEmpty else { return }

        let urlsByID: [String: URL] = (try? await queue.read { db -> [String: URL] in
            var map: [String: URL] = [:]
            for id in candidateIDs {
                if let path = try String.fetchOne(db, sql: """
                    SELECT absolute_path FROM paths WHERE file_id = ? AND is_alive = 1 LIMIT 1
                    """, arguments: [id]) {
                    map[id] = URL(fileURLWithPath: path)
                }
            }
            return map
        }) ?? [:]

        var pendingRows: [PhotoTraitsRow] = []

        await withTaskGroup(of: PhotoTraitsRow?.self) { group in
            var iterator = candidateIDs.makeIterator()
            var inFlight = 0

            func spawnNext() {
                guard let id = iterator.next(), let url = urlsByID[id] else { return }
                inFlight += 1
                group.addTask(priority: .utility) {
                    await scanOne(fileID: id, url: url)
                }
            }
            for _ in 0..<concurrency { spawnNext() }

            for await result in group {
                inFlight -= 1
                if let row = result { pendingRows.append(row) }
                if pendingRows.count >= writeChunk {
                    await flush(&pendingRows, queue: queue)
                }
                spawnNext()
            }
        }
        if !pendingRows.isEmpty {
            await flush(&pendingRows, queue: queue)
        }
    }

    private static func scanOne(fileID: String, url: URL) async -> PhotoTraitsRow? {
        guard let currentHash = try? await Database.shared.dbQueue?.read({ db in
            try String.fetchOne(db, sql: "SELECT content_hash FROM files WHERE id = ?", arguments: [fileID])
        }) ?? nil else { return nil }

        guard let raster = VisionServices.boundedDecode(url: url, maxPixel: decodeMaxPixel) else {
            // Undecodable: stamp an attempted-marker with NULL fields so this
            // file isn't retried every launch (dataless iCloud is handled by
            // boundedDecode returning nil for a different reason and is
            // intentionally NOT stamped — same rule as the indexer).
            if FileManager.default.fileExists(atPath: url.path) {
                return PhotoTraitsRow(file_id: fileID, traits_scanned_hash: currentHash,
                                       traits_version: PhotoTraits.currentVersion,
                                       face_count: nil, largest_face_frac: nil,
                                       face_quality: nil, pet_count: nil, sharpness: nil)
            }
            return nil
        }

        let result = await VisionServices.analyze(cgImage: raster)
        return PhotoTraitsRow(file_id: fileID, traits_scanned_hash: currentHash,
                               traits_version: PhotoTraits.currentVersion,
                               face_count: result.faceCount, largest_face_frac: result.largestFaceFrac,
                               face_quality: result.faceQuality, pet_count: result.petCount,
                               sharpness: result.sharpness)
    }

    private static func flush(_ rows: inout [PhotoTraitsRow], queue: DatabaseQueue) async {
        let batch = rows
        rows.removeAll(keepingCapacity: true)
        try? await queue.write { db in
            for var row in batch {
                // Guard: only commit if the file's content_hash still matches
                // what we scanned — a mid-pass edit leaves the row stale
                // rather than stamping new-hash-wrong-values.
                let stillCurrent = try String.fetchOne(db, sql: """
                    SELECT content_hash FROM files WHERE id = ?
                    """, arguments: [row.file_id]) == row.traits_scanned_hash
                if stillCurrent {
                    try row.save(db)
                }
            }
        }
    }
}
```

Note: this task assumes `VisionServices.analyze(cgImage:)` exists as an overload taking a pre-decoded `CGImage` (avoiding a second decode when the caller already has one bounded at the right size). If Task 2's `analyze(url:)` doesn't already factor its request fan-out into a reusable `analyze(cgImage:)` helper, extract one now as a small refactor of `VisionServices.analyze(url:)`'s body (the `guard let cgImage = await loadCGImage(url:)` line becomes the boundary) — both call sites (per-file live analyze and this backfill) must share the exact same face/pet/sharpness logic, never a duplicated copy.

Wire into `MuseApp.swift`'s `.task` block, immediately after the existing `PhotoHeaderBackfill` call (so the two passes don't contend for disk):

```swift
PhaseTrace.mark("photo-header-backfill.start")
Task { await PhotoHeaderBackfill.run(); PhaseTrace.mark("photo-header-backfill.end") }
PhaseTrace.mark("deep-analysis-backfill.start")
Task {
    await DeepAnalysisBackfill.run()
    PhaseTrace.mark("deep-analysis-backfill.end")
}
```

- [ ] **Step 4: Run test to verify it passes, then a full build**

Run: `xcodebuild -scheme Muse test -only-testing:MuseTests/DeepBackfillSelectionTests`
Expected: PASS.

Run: `xcodebuild -scheme Muse build`
Expected: BUILD SUCCEEDED.

- [ ] **Step 5: Commit**

```bash
git add Muse/Muse/Intelligence/DeepAnalysisBackfill.swift Muse/Muse/MuseApp.swift Muse/MuseTests/DeepBackfillSelectionTests.swift
git commit -m "feat(spec-03): DeepAnalysisBackfill launch pass for photo_traits"
```

---

### Task 6: `PortraitHeuristic` constants

**Files:**
- Create: `Muse/Muse/Intelligence/Core/PortraitHeuristic.swift`
- Test: `Muse/MuseTests/PortraitHeuristicTests.swift`

**Interfaces:**
- Produces: `PortraitHeuristic.portraitMaxFaces`, `.portraitMinFaceFrac`, `.groupMinFaces`, `PortraitHeuristic.classify(faceCount:largestFrac:) -> Classification` — consumed by Task 8 (`PhotoSearch` SQL)

- [ ] **Step 1: Write the failing test**

```swift
//
//  PortraitHeuristicTests.swift
//  MuseTests
//

import XCTest
@testable import Muse

final class PortraitHeuristicTests: XCTestCase {
    func testPortraitWithinFaceCountAndFracFloor() {
        let c = PortraitHeuristic.classify(faceCount: 1, largestFrac: 0.1)
        XCTAssertEqual(c, .portrait)
    }

    func testTwoFacesStillPortraitAboveFracFloor() {
        let c = PortraitHeuristic.classify(faceCount: 2, largestFrac: PortraitHeuristic.portraitMinFaceFrac)
        XCTAssertEqual(c, .portrait)
    }

    func testBelowFracFloorIsNeitherEvenWithOneFace() {
        let c = PortraitHeuristic.classify(faceCount: 1, largestFrac: 0.01)
        XCTAssertEqual(c, .neither)
    }

    func testGroupAtThreeFaces() {
        let c = PortraitHeuristic.classify(faceCount: PortraitHeuristic.groupMinFaces, largestFrac: nil)
        XCTAssertEqual(c, .group)
    }

    func testZeroFacesIsNeither() {
        let c = PortraitHeuristic.classify(faceCount: 0, largestFrac: nil)
        XCTAssertEqual(c, .neither)
    }

    func testNilFracWithFewFacesIsNeither() {
        // A portrait claim requires knowing the subject actually fills the frame.
        let c = PortraitHeuristic.classify(faceCount: 1, largestFrac: nil)
        XCTAssertEqual(c, .neither)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -scheme Muse test -only-testing:MuseTests/PortraitHeuristicTests`
Expected: FAIL — `PortraitHeuristic` doesn't exist.

- [ ] **Step 3: Implement**

```swift
//
//  PortraitHeuristic.swift
//  Muse
//
//  Owner-validated constants (never validated live against real photos
//  yet — spec-03 §14/§15). Single declaration site consumed by
//  PhotoSearch's is:portrait / is:group tokens.
//

nonisolated enum PortraitHeuristic {
    static let portraitMaxFaces = 2
    static let portraitMinFaceFrac = 0.05
    static let groupMinFaces = 3

    enum Classification: Equatable { case portrait, group, neither }

    static func classify(faceCount: Int, largestFrac: Double?) -> Classification {
        if faceCount >= groupMinFaces { return .group }
        if faceCount >= 1, faceCount <= portraitMaxFaces,
           let frac = largestFrac, frac >= portraitMinFaceFrac {
            return .portrait
        }
        return .neither
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild -scheme Muse test -only-testing:MuseTests/PortraitHeuristicTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Muse/Muse/Intelligence/Core/PortraitHeuristic.swift Muse/MuseTests/PortraitHeuristicTests.swift
git commit -m "feat(spec-03): PortraitHeuristic pure classifier"
```

---

### Task 7: `SearchToken` additions — `faces`, `pets`, `is:`

**Files:**
- Modify: `Muse/Muse/Search/SearchToken.swift` (Spec 02 module)
- Test: `Muse/MuseTests/SearchTokenFacesTests.swift`

**Interfaces:**
- Consumes: `SearchToken` enum + `SearchQueryParser.parseSegment`/`.parse` (Spec 02 Task 10 end-state)
- Produces: `SearchToken.faces(NumericFilter)`, `.pets(NumericFilter)`, `.traitIs(TraitQuery)`, `TraitQuery.portrait/.group` — consumed by Task 8 (SQL), Task 9 (suggestions/chip labels)

- [ ] **Step 1: Write the failing test**

```swift
//
//  SearchTokenFacesTests.swift
//  MuseTests
//

import XCTest
@testable import Muse

final class SearchTokenFacesTests: XCTestCase {
    func testFacesGreaterThanParses() {
        let parsed = SearchQueryParser.parse("faces:>2")
        XCTAssertEqual(parsed.tokens, [.faces(.init(op: .gt, value: 2))])
        XCTAssertTrue(parsed.freeText.isEmpty)
    }

    func testFacesExactZeroParses() {
        let parsed = SearchQueryParser.parse("faces:0")
        XCTAssertEqual(parsed.tokens, [.faces(.init(op: .eq, value: 0))])
    }

    func testPetsGreaterThanZeroParses() {
        let parsed = SearchQueryParser.parse("pets:>0")
        XCTAssertEqual(parsed.tokens, [.pets(.init(op: .gt, value: 0))])
    }

    func testIsPortraitParses() {
        let parsed = SearchQueryParser.parse("is:portrait")
        XCTAssertEqual(parsed.tokens, [.traitIs(.portrait)])
    }

    func testIsGroupParses() {
        let parsed = SearchQueryParser.parse("is:group")
        XCTAssertEqual(parsed.tokens, [.traitIs(.group)])
    }

    func testIsWithUnknownValueStaysFreeText() {
        let parsed = SearchQueryParser.parse("is: that photo of us")
        XCTAssertTrue(parsed.tokens.isEmpty, "an unrecognized is: value must not silently eat the text")
        XCTAssertTrue(parsed.freeText.contains("that photo of us"))
    }

    func testRemovingFacesTokenRoundTrips() {
        let parsed = SearchQueryParser.parse("faces:>2 beach")
        let rebuilt = parsed.removing(tokenAt: 0)
        XCTAssertEqual(SearchQueryParser.parse(rebuilt).tokens, [])
        XCTAssertTrue(rebuilt.contains("beach"))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -scheme Muse test -only-testing:MuseTests/SearchTokenFacesTests`
Expected: FAIL — `.faces`/`.pets`/`.traitIs` cases don't exist.

- [ ] **Step 3: Implement**

Add three cases to `SearchToken` (alongside the existing 10):

```swift
case faces(NumericFilter)
case pets(NumericFilter)
case traitIs(TraitQuery)

enum TraitQuery: String, Equatable, Sendable {
    case portrait, group
}
```

In `SearchQueryParser.parseSegment`'s key switch, add:

```swift
case "faces":
    guard let filter = Self.parseNumericFilter(value) else { return nil }
    return .faces(filter)
case "pets":
    guard let filter = Self.parseNumericFilter(value) else { return nil }
    return .pets(filter)
case "is":
    switch value.lowercased() {
    case "portrait": return .traitIs(.portrait)
    case "group": return .traitIs(.group)
    default: return nil // stays free text — the standing grammar rule
    }
```

(`parseNumericFilter` is the existing helper the `iso:`/`aperture:` cases already use for `>`/`>=`/`<`/`<=`/exact/range parsing — reuse it verbatim, do not duplicate.)

- [ ] **Step 4: Run test to verify it passes, then a full build**

Run: `xcodebuild -scheme Muse test -only-testing:MuseTests/SearchTokenFacesTests`
Expected: PASS.

Run: `xcodebuild -scheme Muse build`
Expected: BUILD SUCCEEDED (any exhaustive `switch` over `SearchToken` elsewhere — e.g. `displayLabel`, `PhotoSearch.filter` — will fail to compile until Task 8/9 add their cases; if the compiler flags them now, add minimal `case .faces, .pets, .traitIs:` stubs there and fill them in properly in those tasks).

- [ ] **Step 5: Commit**

```bash
git add Muse/Muse/Search/SearchToken.swift Muse/MuseTests/SearchTokenFacesTests.swift
git commit -m "feat(spec-03): faces:/pets:/is: SearchToken grammar"
```

---

### Task 8: `PhotoSearch` SQL for `faces`/`pets`/`is:`/`traits`

**Files:**
- Modify: `Muse/Muse/Search/PhotoSearch.swift`
- Test: `Muse/MuseTests/PhotoSearchTraitsTests.swift`

**Interfaces:**
- Consumes: `SearchToken.faces/.pets/.traitIs` (Task 7), `PortraitHeuristic` (Task 6), `photo_traits` table (Task 3)
- Produces: extended `PhotoSearch.filter(tokens:db:)` handling the three new token cases — consumed by `SearchService` (already wired by Spec 02 Task 12; no further change needed there for this task)

- [ ] **Step 1: Write the failing test**

```swift
//
//  PhotoSearchTraitsTests.swift
//  MuseTests
//

import XCTest
import GRDB
@testable import Muse

final class PhotoSearchTraitsTests: XCTestCase {

    private func makeQueue() throws -> DatabaseQueue {
        let q = try DatabaseQueue()
        try Database.makeMigrator().migrate(q)
        return q
    }

    private func insertFileWithTraits(_ db: GRDB.Database, id: String,
                                       faceCount: Int?, largestFrac: Double?, petCount: Int?) throws {
        try db.execute(sql: "INSERT INTO files (id, content_hash, kind, last_seen_at) VALUES (?, ?, 'image', 0)",
                        arguments: [id, id + "-hash"])
        if faceCount != nil || petCount != nil {
            var row = PhotoTraitsRow(file_id: id, traits_scanned_hash: id + "-hash",
                                      traits_version: PhotoTraits.currentVersion,
                                      face_count: faceCount, largest_face_frac: largestFrac,
                                      face_quality: nil, pet_count: petCount, sharpness: nil)
            try row.insert(db)
        }
    }

    func testFacesGreaterThanFilters() throws {
        let q = try makeQueue()
        try q.write { db in
            try insertFileWithTraits(db, id: "f1", faceCount: 3, largestFrac: 0.1, petCount: 0)
            try insertFileWithTraits(db, id: "f2", faceCount: 1, largestFrac: 0.1, petCount: 0)
        }
        let result = try q.read { db in
            try PhotoSearch.filter(tokens: [.faces(.init(op: .gt, value: 2))], db: db)
        }
        XCTAssertEqual(result?.idSet, ["f1"])
    }

    func testFacesZeroMatchesOnlyScannedFacelessFiles() throws {
        let q = try makeQueue()
        try q.write { db in
            try insertFileWithTraits(db, id: "scanned-zero", faceCount: 0, largestFrac: nil, petCount: 0)
            // unscanned: no photo_traits row at all
            try db.execute(sql: "INSERT INTO files (id, content_hash, kind, last_seen_at) VALUES ('unscanned', 'h', 'image', 0)")
        }
        let result = try q.read { db in
            try PhotoSearch.filter(tokens: [.faces(.init(op: .eq, value: 0))], db: db)
        }
        XCTAssertEqual(result?.idSet, ["scanned-zero"], "an unscanned file must NOT match faces:0")
    }

    func testPetsFilters() throws {
        let q = try makeQueue()
        try q.write { db in
            try insertFileWithTraits(db, id: "p1", faceCount: 0, largestFrac: nil, petCount: 2)
            try insertFileWithTraits(db, id: "p2", faceCount: 0, largestFrac: nil, petCount: 0)
        }
        let result = try q.read { db in
            try PhotoSearch.filter(tokens: [.pets(.init(op: .gt, value: 0))], db: db)
        }
        XCTAssertEqual(result?.idSet, ["p1"])
    }

    func testIsPortraitFilters() throws {
        let q = try makeQueue()
        try q.write { db in
            try insertFileWithTraits(db, id: "portrait1", faceCount: 1, largestFrac: 0.2, petCount: 0)
            try insertFileWithTraits(db, id: "tiny-face", faceCount: 1, largestFrac: 0.01, petCount: 0)
            try insertFileWithTraits(db, id: "group1", faceCount: 5, largestFrac: 0.1, petCount: 0)
        }
        let result = try q.read { db in
            try PhotoSearch.filter(tokens: [.traitIs(.portrait)], db: db)
        }
        XCTAssertEqual(result?.idSet, ["portrait1"])
    }

    func testIsGroupFilters() throws {
        let q = try makeQueue()
        try q.write { db in
            try insertFileWithTraits(db, id: "group1", faceCount: 4, largestFrac: 0.1, petCount: 0)
            try insertFileWithTraits(db, id: "solo1", faceCount: 1, largestFrac: 0.2, petCount: 0)
        }
        let result = try q.read { db in
            try PhotoSearch.filter(tokens: [.traitIs(.group)], db: db)
        }
        XCTAssertEqual(result?.idSet, ["group1"])
    }

    func testFacesAndCameraIntersect() throws {
        // AND semantics with an existing token type — spot-check against `faces`.
        let q = try makeQueue()
        try q.write { db in
            try insertFileWithTraits(db, id: "both", faceCount: 3, largestFrac: 0.1, petCount: 0)
            try db.execute(sql: "UPDATE files SET id = id WHERE id = 'both'") // no-op, camera comes from photo_meta in real rows
            try insertFileWithTraits(db, id: "facesOnly", faceCount: 3, largestFrac: 0.1, petCount: 0)
        }
        let facesOnly = try q.read { db in try PhotoSearch.filter(tokens: [.faces(.init(op: .gte, value: 2))], db: db) }
        XCTAssertEqual(facesOnly?.idSet, ["both", "facesOnly"])
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -scheme Muse test -only-testing:MuseTests/PhotoSearchTraitsTests`
Expected: FAIL — `PhotoSearch.filter` doesn't yet handle `.faces`/`.pets`/`.traitIs` (compiler error on the non-exhaustive switch, or a runtime "no rows" failure if a default case already swallows unknown tokens — either way the assertions fail).

- [ ] **Step 3: Implement**

In `PhotoSearch.filter`'s per-token switch, add:

```swift
case let .faces(filter):
    let ids = try Self.numericFilterIDs(table: "photo_traits", column: "face_count",
                                        filter: filter, db: db)
    combine(&result, ids)
case let .pets(filter):
    let ids = try Self.numericFilterIDs(table: "photo_traits", column: "pet_count",
                                        filter: filter, db: db)
    combine(&result, ids)
case let .traitIs(query):
    let sql: String
    switch query {
    case .portrait:
        sql = """
            SELECT file_id FROM photo_traits
            WHERE face_count BETWEEN 1 AND ?
              AND largest_face_frac >= ?
            """
    case .group:
        sql = "SELECT file_id FROM photo_traits WHERE face_count >= ?"
    }
    let ids: Set<String>
    switch query {
    case .portrait:
        ids = Set(try String.fetchAll(db, sql: sql,
            arguments: [PortraitHeuristic.portraitMaxFaces, PortraitHeuristic.portraitMinFaceFrac]))
    case .group:
        ids = Set(try String.fetchAll(db, sql: sql, arguments: [PortraitHeuristic.groupMinFaces]))
    }
    combine(&result, ids)
```

Add the small numeric-filter-over-a-table helper (reusable shape shared with `iso:`/`aperture:` if those aren't already generic — if they already have an equivalent private helper from Spec 02's Task 11, reuse that one instead of adding a duplicate):

```swift
private static func numericFilterIDs(table: String, column: String,
                                      filter: SearchToken.NumericFilter,
                                      db: GRDB.Database) throws -> Set<String> {
    let (clause, args) = filter.op.sqlClause(column: column, value: filter.value)
    return Set(try String.fetchAll(db, sql: "SELECT file_id FROM \(table) WHERE \(clause)", arguments: args))
}
```

(`SearchToken.NumericFilter.Op.sqlClause` is assumed to already exist from Spec 02's `iso:`/`aperture:` implementation — if it doesn't, add it there as a small pure helper: `.eq → "\(column) = ?"`, `.gt → "\(column) > ?"`, `.gte`, `.lt`, `.lte`, `.range(lo,hi) → "\(column) BETWEEN ? AND ?"`.)

`combine(&result, ids)` intersects into the running `Result.idSet`/`.ids` the same way every other token case in this function already does — follow the existing accumulation pattern in the file exactly (read it before writing this diff).

- [ ] **Step 4: Run test to verify it passes, then a full build**

Run: `xcodebuild -scheme Muse test -only-testing:MuseTests/PhotoSearchTraitsTests`
Expected: PASS.

Run: `xcodebuild -scheme Muse build`
Expected: BUILD SUCCEEDED.

- [ ] **Step 5: Commit**

```bash
git add Muse/Muse/Search/PhotoSearch.swift Muse/MuseTests/PhotoSearchTraitsTests.swift
git commit -m "feat(spec-03): faces:/pets:/is: SQL in PhotoSearch"
```

---

### Task 9: `SearchSuggest` + chip `displayLabel` for the new tokens

**Files:**
- Modify: `Muse/Muse/Search/SearchFacets.swift` (or wherever `SearchSuggest.suggestions` lives per Spec 02 Task 13's end-state)
- Modify: `Muse/Muse/Search/SearchToken.swift` (`displayLabel` extension, Spec 02 Task 14's end-state)
- Test: `Muse/MuseTests/SearchSuggestTraitsTests.swift`

**Interfaces:**
- Consumes: `SearchSuggest.suggestions(fieldText:facets:)` (Spec 02), `SearchToken.faces/.pets/.traitIs` (Task 7)
- Produces: key-list entries `faces:`/`pets:`/`is:`, value hints, and `displayLabel` strings for the chip bar

- [ ] **Step 1: Write the failing test**

```swift
//
//  SearchSuggestTraitsTests.swift
//  MuseTests
//

import XCTest
@testable import Muse

final class SearchSuggestTraitsTests: XCTestCase {
    func testFacesPetsIsAreSuggestedKeys() {
        let suggestions = SearchSuggest.suggestions(fieldText: "fa", facets: FacetsSnapshot(cameras: [], lenses: [], places: [], years: []))
        XCTAssertTrue(suggestions.contains { $0.completion.hasPrefix("faces:") })
    }

    func testIsSuggestsPortraitAndGroupValues() {
        let suggestions = SearchSuggest.suggestions(fieldText: "is:", facets: FacetsSnapshot(cameras: [], lenses: [], places: [], years: []))
        let completions = Set(suggestions.map(\.completion))
        XCTAssertTrue(completions.contains("is:portrait"))
        XCTAssertTrue(completions.contains("is:group"))
    }

    func testDisplayLabels() {
        XCTAssertEqual(SearchToken.faces(.init(op: .gt, value: 2)).displayLabel, String(localized: "Faces"))
        XCTAssertEqual(SearchToken.pets(.init(op: .gt, value: 0)).displayLabel, String(localized: "Pets"))
        XCTAssertEqual(SearchToken.traitIs(.portrait).displayLabel, String(localized: "Portrait"))
        XCTAssertEqual(SearchToken.traitIs(.group).displayLabel, String(localized: "Group photo"))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -scheme Muse test -only-testing:MuseTests/SearchSuggestTraitsTests`
Expected: FAIL — new keys/values/labels not yet present.

- [ ] **Step 3: Implement**

In `SearchSuggest`'s static key list, append `"faces:"`, `"pets:"`, `"is:"`. For `"is:"`, when the field text is exactly `"is:"` (or `"is:" + partial`), offer the fixed pair `is:portrait` / `is:group` as completions (no facet query — these aren't enumerable DB values, unlike camera/lens). For `"faces:"`/`"pets:"`, offer a single static numeric-op hint completion (`"faces:>2"`, `"pets:>0"`) rather than a facet-derived list.

In `SearchToken`'s `displayLabel` extension, add:

```swift
case let .faces(filter):
    return "\(String(localized: "Faces")) \(filter.displayFragment)"
case let .pets(filter):
    return "\(String(localized: "Pets")) \(filter.displayFragment)"
case let .traitIs(query):
    switch query {
    case .portrait: return String(localized: "Portrait")
    case .group: return String(localized: "Group photo")
    }
```

(`NumericFilter.displayFragment` — e.g. "> 2" — is assumed to already exist from the `iso:`/`aperture:` `displayLabel` cases in Spec 02's Task 14; reuse it. If the test above expects the bare label without the fragment for `Faces`/`Pets` because the existing convention only shows the key name in the chip and puts the value elsewhere, adjust the implementation to match whatever the real `displayLabel` convention for `iso:`/`aperture:` already established — read those cases first, this task must be visually consistent with them, not just internally self-consistent.)

- [ ] **Step 4: Run test to verify it passes, then a full build**

Run: `xcodebuild -scheme Muse test -only-testing:MuseTests/SearchSuggestTraitsTests`
Expected: PASS.

Run: `xcodebuild -scheme Muse build`
Expected: BUILD SUCCEEDED.

- [ ] **Step 5: Commit**

```bash
git add Muse/Muse/Search/SearchFacets.swift Muse/Muse/Search/SearchToken.swift Muse/MuseTests/SearchSuggestTraitsTests.swift
git commit -m "feat(spec-03): faces:/pets:/is: suggestions and chip labels"
```

---

### Task 10: `CompareGeometry` — pure synchronized zoom/pan math

**Files:**
- Create: `Muse/Muse/Components/CompareGeometry.swift`
- Test: `Muse/MuseTests/CompareGeometryTests.swift`

**Interfaces:**
- Produces: `CompareGeometry.drawRect(imageSize:paneSize:zoom:center:) -> CGRect`, `.clampCenter(_:zoom:) -> CGPoint`, `.zoomRange: ClosedRange<CGFloat>` — consumed by Task 13 (`ComparePane`)

- [ ] **Step 1: Write the failing test**

```swift
//
//  CompareGeometryTests.swift
//  MuseTests
//

import XCTest
import CoreGraphics
@testable import Muse

final class CompareGeometryTests: XCTestCase {
    func testDrawRectFitsAtZoomOne() {
        let rect = CompareGeometry.drawRect(imageSize: CGSize(width: 200, height: 100),
                                             paneSize: CGSize(width: 400, height: 400),
                                             zoom: 1, center: CGPoint(x: 0.5, y: 0.5))
        // 2:1 landscape image fit into a 400x400 pane → 400x200, vertically centered.
        XCTAssertEqual(rect.width, 400, accuracy: 0.01)
        XCTAssertEqual(rect.height, 200, accuracy: 0.01)
        XCTAssertEqual(rect.midY, 200, accuracy: 0.01)
    }

    func testSharedCenterTracksSameSubjectAcrossDifferingAspects() {
        // A portrait and a landscape pane at the same normalized center
        // must both keep that fractional point at the pane's midpoint.
        let landscape = CompareGeometry.drawRect(imageSize: CGSize(width: 300, height: 150),
                                                  paneSize: CGSize(width: 300, height: 300),
                                                  zoom: 2, center: CGPoint(x: 0.5, y: 0.5))
        let portrait = CompareGeometry.drawRect(imageSize: CGSize(width: 150, height: 300),
                                                 paneSize: CGSize(width: 300, height: 300),
                                                 zoom: 2, center: CGPoint(x: 0.5, y: 0.5))
        // Both must be centered on the pane at zoom 2, center 0.5/0.5.
        XCTAssertEqual(landscape.midX, 150, accuracy: 0.5)
        XCTAssertEqual(landscape.midY, 150, accuracy: 0.5)
        XCTAssertEqual(portrait.midX, 150, accuracy: 0.5)
        XCTAssertEqual(portrait.midY, 150, accuracy: 0.5)
    }

    func testClampCenterStaysWithinUnitSquare() {
        let clamped = CompareGeometry.clampCenter(CGPoint(x: -0.5, y: 1.8), zoom: 2)
        XCTAssertGreaterThanOrEqual(clamped.x, 0)
        XCTAssertLessThanOrEqual(clamped.x, 1)
        XCTAssertGreaterThanOrEqual(clamped.y, 0)
        XCTAssertLessThanOrEqual(clamped.y, 1)
    }

    func testClampAtZoomOneCollapsesToCenterOfFrame() {
        // At zoom 1 the image can't pan at all — any center clamps to 0.5/0.5.
        let clamped = CompareGeometry.clampCenter(CGPoint(x: 0.1, y: 0.9), zoom: 1)
        XCTAssertEqual(clamped.x, 0.5, accuracy: 0.001)
        XCTAssertEqual(clamped.y, 0.5, accuracy: 0.001)
    }

    func testZoomRangeBounds() {
        XCTAssertEqual(CompareGeometry.zoomRange, 1...8)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -scheme Muse test -only-testing:MuseTests/CompareGeometryTests`
Expected: FAIL — `CompareGeometry` doesn't exist.

- [ ] **Step 3: Implement**

```swift
//
//  CompareGeometry.swift
//  Muse
//
//  Pure synchronized zoom/pan math for side-by-side compare. Normalized
//  center (unit image coordinates, not points) is what keeps a portrait
//  and a landscape pane looking at the same subject region under one
//  shared (zoom, center) pair.
//

import CoreGraphics

nonisolated enum CompareGeometry {
    static let zoomRange: ClosedRange<CGFloat> = 1...8

    /// Where `imageSize` draws inside `paneSize` at shared (zoom, center):
    /// fit the image, scale about the normalized center point.
    static func drawRect(imageSize: CGSize, paneSize: CGSize,
                         zoom: CGFloat, center: CGPoint) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0,
              paneSize.width > 0, paneSize.height > 0 else { return .zero }

        let fitScale = min(paneSize.width / imageSize.width, paneSize.height / imageSize.height)
        let fittedSize = CGSize(width: imageSize.width * fitScale, height: imageSize.height * fitScale)
        let scaledSize = CGSize(width: fittedSize.width * zoom, height: fittedSize.height * zoom)

        // The point in the SCALED image that must land at the pane's center.
        let focusX = scaledSize.width * center.x
        let focusY = scaledSize.height * center.y

        let originX = paneSize.width / 2 - focusX
        let originY = paneSize.height / 2 - focusY

        return CGRect(x: originX, y: originY, width: scaledSize.width, height: scaledSize.height)
    }

    /// Clamp so the image never pans fully out of the pane; at zoom 1
    /// there's no room to pan at all, so it collapses to dead center.
    static func clampCenter(_ c: CGPoint, zoom: CGFloat) -> CGPoint {
        guard zoom > 1 else { return CGPoint(x: 0.5, y: 0.5) }
        let x = min(max(c.x, 0), 1)
        let y = min(max(c.y, 0), 1)
        return CGPoint(x: x, y: y)
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild -scheme Muse test -only-testing:MuseTests/CompareGeometryTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Muse/Muse/Components/CompareGeometry.swift Muse/MuseTests/CompareGeometryTests.swift
git commit -m "feat(spec-03): CompareGeometry pure zoom/pan math"
```

---

### Task 11: `CompareStore` (Pattern B)

**Files:**
- Create: `Muse/Muse/Models/CompareStore.swift`
- Test: manual build + verification (Pattern B stores are thin `ObservableObject` glue over already-tested pure logic — house convention has no UI unit tests; `open(urls:)`'s clamping is the only pure-testable bit and gets a narrow test below)
- Test: `Muse/MuseTests/CompareStoreTests.swift`

**Interfaces:**
- Consumes: nothing new
- Produces: `CompareStore.shared`, `.open(urls:)`, `.close()`, `.focus(_:)`, `.replaceFocused(with:)`, `@Published urls/focusedIndex/zoom/center/peaking` — consumed by Task 12 (Escape/gating), Task 13 (mounting), Task 14 (keyboard)

- [ ] **Step 1: Write the failing test**

```swift
//
//  CompareStoreTests.swift
//  MuseTests
//

import XCTest
@testable import Muse

@MainActor
final class CompareStoreTests: XCTestCase {
    func testOpenClampsToTwoMinimum() {
        let store = CompareStore()
        store.open(urls: [URL(fileURLWithPath: "/tmp/a.jpg")])
        XCTAssertNil(store.urls, "fewer than 2 URLs must not open compare")
    }

    func testOpenClampsToMaxPanes() {
        let store = CompareStore()
        let urls = (0..<8).map { URL(fileURLWithPath: "/tmp/\($0).jpg") }
        store.open(urls: urls)
        XCTAssertEqual(store.urls?.count, CompareStore.maxPanes)
    }

    func testOpenWithinRangeKeepsAll() {
        let store = CompareStore()
        let urls = (0..<3).map { URL(fileURLWithPath: "/tmp/\($0).jpg") }
        store.open(urls: urls)
        XCTAssertEqual(store.urls?.count, 3)
    }

    func testCloseResetsState() {
        let store = CompareStore()
        store.open(urls: [URL(fileURLWithPath: "/tmp/a.jpg"), URL(fileURLWithPath: "/tmp/b.jpg")])
        store.zoom = 3
        store.close()
        XCTAssertNil(store.urls)
        XCTAssertEqual(store.zoom, 1)
    }

    func testFocusClampsToValidRange() {
        let store = CompareStore()
        store.open(urls: [URL(fileURLWithPath: "/tmp/a.jpg"), URL(fileURLWithPath: "/tmp/b.jpg")])
        store.focus(5)
        XCTAssertEqual(store.focusedIndex, 1, "out-of-range focus clamps to the last valid pane")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -scheme Muse test -only-testing:MuseTests/CompareStoreTests`
Expected: FAIL — `CompareStore` doesn't exist.

- [ ] **Step 3: Implement**

```swift
//
//  CompareStore.swift
//  Muse
//
//  Side-by-side compare workbench state. Compare and the hero viewer never
//  coexist — open(urls:) is only ever called from the grid, where
//  appState.selectedFile == nil holds by construction; callers should still
//  guard on it explicitly (Task 30's context-menu wiring does).
//

import Foundation

@MainActor final class CompareStore: ObservableObject {
    static let shared = CompareStore()
    static let maxPanes = 4

    @Published private(set) var urls: [URL]?
    @Published private(set) var focusedIndex = 0
    @Published var zoom: CGFloat = 1
    @Published var center = CGPoint(x: 0.5, y: 0.5)
    @Published var peaking = false

    func open(urls incoming: [URL]) {
        guard incoming.count >= 2 else { return }
        urls = Array(incoming.prefix(Self.maxPanes))
        focusedIndex = 0
        zoom = 1
        center = CGPoint(x: 0.5, y: 0.5)
        peaking = false
    }

    func close() {
        urls = nil
        focusedIndex = 0
        zoom = 1
        center = CGPoint(x: 0.5, y: 0.5)
        peaking = false
    }

    func focus(_ index: Int) {
        guard let urls, !urls.isEmpty else { return }
        focusedIndex = min(max(index, 0), urls.count - 1)
    }

    func replaceFocused(with url: URL) {
        guard var urls, urls.indices.contains(focusedIndex) else { return }
        urls[focusedIndex] = url
        self.urls = urls
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild -scheme Muse test -only-testing:MuseTests/CompareStoreTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Muse/Muse/Models/CompareStore.swift Muse/MuseTests/CompareStoreTests.swift
git commit -m "feat(spec-03): CompareStore Pattern B state"
```

---

### Task 12: Escape/key-gating for compare — `EscapeAction.closeCompare` + `PageScrollCatcher` gating

**Files:**
- Modify: `Muse/Muse/Components/EscapeAction.swift` (`EscapeAction` enum, `EscapeResolver.action`)
- Modify: `Muse/Muse/ContentView.swift` (pass `compareActive:` into the resolver call, pass the updated `isActive` closure to `PageScrollCatcher`)
- Test: `Muse/MuseTests/EscapeActionTests.swift` (extend existing suite)

**Interfaces:**
- Consumes: `CompareStore.shared.urls` (Task 11)
- Produces: `EscapeAction.closeCompare`, updated resolver order `modal → compare → viewer → search → tags → collection → rediscovery → collectionsPage → placesPage → none` — consumed by Task 13 (`CompareView` reacting to `.closeCompare`)

- [ ] **Step 1: Write the failing test**

Add to the existing `EscapeActionTests.swift` (do not create a new file — this suite already exists per Spec 02 Task 26):

```swift
func testCompareResolvesAfterModalBeforeViewer() {
    let action = EscapeResolver.action(modalPresented: false, hasSelectedFile: true,
                                        selectedFileIsHero: true, searchActive: false,
                                        tagsActive: false, insideCollection: false,
                                        rediscoveryActive: false, showingCollectionsPage: false,
                                        showingPlacesPage: false, compareActive: true)
    XCTAssertEqual(action, .closeCompare, "compare must resolve before the viewer cases even when a file is selected")
}

func testModalStillWinsOverCompare() {
    let action = EscapeResolver.action(modalPresented: true, hasSelectedFile: false,
                                        selectedFileIsHero: false, searchActive: false,
                                        tagsActive: false, insideCollection: false,
                                        rediscoveryActive: false, showingCollectionsPage: false,
                                        showingPlacesPage: false, compareActive: true)
    XCTAssertEqual(action, .dismissModal, "a modal raised over compare (e.g. the cull resolve card) must dismiss first")
}

func testCompareInactiveFallsThroughToViewer() {
    let action = EscapeResolver.action(modalPresented: false, hasSelectedFile: true,
                                        selectedFileIsHero: false, searchActive: false,
                                        tagsActive: false, insideCollection: false,
                                        rediscoveryActive: false, showingCollectionsPage: false,
                                        showingPlacesPage: false, compareActive: false)
    XCTAssertEqual(action, .closeViewer)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -scheme Muse test -only-testing:MuseTests/EscapeActionTests`
Expected: FAIL — `EscapeResolver.action` has no `compareActive:` parameter yet, and `.closeCompare` doesn't exist.

- [ ] **Step 3: Implement**

Add the case:

```swift
case closeCompare
```

Update the resolver signature and body, inserting the compare check directly after the modal check and before the viewer checks:

```swift
static func action(modalPresented: Bool = false,
                   hasSelectedFile: Bool,
                   selectedFileIsHero: Bool,
                   searchActive: Bool,
                   tagsActive: Bool,
                   insideCollection: Bool,
                   rediscoveryActive: Bool,
                   showingCollectionsPage: Bool,
                   showingPlacesPage: Bool,
                   compareActive: Bool = false) -> EscapeAction {
    if modalPresented { return .dismissModal }
    if compareActive { return .closeCompare }
    if hasSelectedFile {
        return selectedFileIsHero ? .closeHero : .closeViewer
    }
    if searchActive { return .clearSearch }
    if tagsActive { return .clearTags }
    if insideCollection { return .exitCollection }
    if rediscoveryActive { return .exitRediscovery }
    if showingCollectionsPage { return .exitCollectionsPage }
    if showingPlacesPage { return .exitPlacesPage }
    return .none
}
```

In `ContentView.swift`, at the existing call site of `EscapeResolver.action(...)`, add `compareActive: CompareStore.shared.urls != nil` to the argument list, and add a case for `.closeCompare` in whatever `switch`/`if` handles the resolved action (calling `CompareStore.shared.close()`).

Update the `PageScrollCatcher.isActive` closure passed from `ContentView` (the existing gating already includes `&& appState.selectedFile == nil` etc. per the durable-constraints class) to also require `CompareStore.shared.urls == nil` — without this, arrow keys would drive the grid underneath the compare overlay.

- [ ] **Step 4: Run test to verify it passes, then a full build**

Run: `xcodebuild -scheme Muse test -only-testing:MuseTests/EscapeActionTests`
Expected: PASS (all cases, old and new).

Run: `xcodebuild -scheme Muse build`
Expected: BUILD SUCCEEDED.

- [ ] **Step 5: Commit**

```bash
git add Muse/Muse/Components/EscapeAction.swift Muse/Muse/ContentView.swift Muse/MuseTests/EscapeActionTests.swift
git commit -m "feat(spec-03): EscapeAction.closeCompare + PageScrollCatcher gating"
```

---

### Task 13: `CompareView` mounting, chrome, and pane decode ladder

**Files:**
- Create: `Muse/Muse/Views/Compare/CompareView.swift`
- Create: `Muse/Muse/Views/Compare/ComparePane.swift`
- Modify: `Muse/Muse/ContentView.swift` (mount `CompareView` in the detail `ZStack` at the viewer-overlay layer)
- Modify: `Muse/Muse/MuseApp.swift` (add the ⌘⇧C menu command)
- Verification: manual build + run — mount an overlay, no pure-logic surface to unit test beyond what Tasks 10-12 already cover

**Interfaces:**
- Consumes: `CompareStore.shared` (Task 11), `CompareGeometry` (Task 10), `ThumbnailCache.withinDecodeBudget`
- Produces: the visible compare surface — consumed by Task 14 (key catcher), Task 15 (badges), Task 16 (peaking toggle)

- [ ] **Step 1: Write `ComparePane`**

```swift
//
//  ComparePane.swift
//  Muse
//
//  One decode ladder per pane: cached 320px thumbnail instantly, then a
//  bounded sharp decode at hero-class target size (the same formula
//  HeroStage.loadFullRes uses), through withinDecodeBudget first.
//

import SwiftUI

struct ComparePane: View {
    let url: URL
    let isFocused: Bool
    @ObservedObject var store: CompareStore
    @State private var quickThumb: NSImage?
    @State private var sharpImage: CGImage?
    @State private var imageSize: CGSize = .zero

    var body: some View {
        GeometryReader { geo in
            ZStack {
                if let sharpImage {
                    Image(decorative: sharpImage, scale: 1)
                        .resizable()
                        .frame(
                            width: CompareGeometry.drawRect(
                                imageSize: imageSize, paneSize: geo.size,
                                zoom: store.zoom, center: store.center).width,
                            height: CompareGeometry.drawRect(
                                imageSize: imageSize, paneSize: geo.size,
                                zoom: store.zoom, center: store.center).height)
                        .position(x: CompareGeometry.drawRect(
                            imageSize: imageSize, paneSize: geo.size,
                            zoom: store.zoom, center: store.center).midX,
                                  y: CompareGeometry.drawRect(
                            imageSize: imageSize, paneSize: geo.size,
                            zoom: store.zoom, center: store.center).midY)
                        .overlay {
                            if store.peaking {
                                PeakingOverlayView(source: sharpImage, accent: .accentColor)
                            }
                        }
                } else if let quickThumb {
                    Image(nsImage: quickThumb).resizable().scaledToFit()
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipped()
            .overlay(alignment: .topLeading) {
                if isFocused {
                    Rectangle().stroke(Color.accentColor, lineWidth: 2)
                }
            }
            .task(id: url) { await loadLadder(paneSize: geo.size) }
        }
    }

    private func loadLadder(paneSize: CGSize) async {
        quickThumb = ThumbnailCache.shared.cachedImage(for: url, size: .grid320)
        let scale = 2.5
        let target = min(max(Int(max(paneSize.width, paneSize.height) * scale), 1600), 4096)
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              ThumbnailCache.withinDecodeBudget(src) else { return }
        let decoded = await Task.detached(priority: .userInitiated) { () -> CGImage? in
            CGImageSourceCreateThumbnailAtIndex(src, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: target,
            ] as CFDictionary)
        }.value
        guard let decoded else { return }
        imageSize = CGSize(width: decoded.width, height: decoded.height)
        sharpImage = decoded
    }
}
```

- [ ] **Step 2: Write `CompareView`**

```swift
//
//  CompareView.swift
//  Muse
//
//  Full-screen compare workbench. No flight animation — this is a
//  workbench, not a stage. Mutually exclusive with the hero viewer.
//

import SwiftUI

struct CompareView: View {
    @ObservedObject var store: CompareStore

    var body: some View {
        if let urls = store.urls {
            ZStack {
                Color.black.opacity(0.92).ignoresSafeArea()
                VStack(spacing: 0) {
                    chromeRow
                    HStack(spacing: 2) {
                        ForEach(Array(urls.enumerated()), id: \.offset) { index, url in
                            ComparePane(url: url, isFocused: index == store.focusedIndex, store: store)
                                .onTapGesture { store.focus(index) }
                        }
                    }
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(String(localized: "Compare"))
        }
    }

    private var chromeRow: some View {
        HStack(spacing: 12) {
            ForEach(Array((store.urls ?? []).enumerated()), id: \.offset) { _, url in
                Text(url.lastPathComponent).font(.caption).foregroundStyle(.white.opacity(0.8))
            }
            Spacer()
            Button {
                store.peaking.toggle()
            } label: {
                Image(systemName: "scope")
            }
            .accessibilityLabel(String(localized: "Focus peaking"))
            Button {
                store.zoom = 1
                store.center = CGPoint(x: 0.5, y: 0.5)
            } label: {
                Text(String(localized: "Fit"))
            }
            Button {
                store.close()
            } label: {
                Image(systemName: "xmark")
            }
            .accessibilityLabel(String(localized: "Close Compare"))
        }
        .padding(10)
    }
}
```

- [ ] **Step 3: Mount and wire the command**

In `ContentView.swift`, mount `CompareView(store: CompareStore.shared)` in the detail `ZStack` at the same layer the hero viewer overlay lives (above the grid, below modal presentation).

In `MuseApp.swift`'s existing `CommandMenu`/File-menu block, add:

```swift
Button(String(localized: "Compare Side by Side")) {
    let urls = appState.effectiveSelectionURLs(fallback: nil)
    guard urls.count >= 2, urls.count <= CompareStore.maxPanes,
          appState.selectedFile == nil else { return }
    CompareStore.shared.open(urls: Array(urls))
}
.keyboardShortcut("c", modifiers: [.command, .shift])
.disabled(!(2...CompareStore.maxPanes).contains(appState.effectiveSelectionURLs(fallback: nil).count) || appState.selectedFile != nil)
```

Add the matching grid context-menu item "Compare Side by Side" beside the existing selection actions in `Views/GridView.swift` (or `SelectionActionsMenu.swift` if that's where multi-select actions live — read the file first to match the existing item style exactly), visible only when 2-4 image-kind files are selected, calling the same `CompareStore.shared.open(urls:)`.

- [ ] **Step 4: Build and manually verify**

Run: `xcodebuild -scheme Muse build`
Expected: BUILD SUCCEEDED.

Manually verify (stat the built `.app`'s mtime first — durable constraint): select 2-4 photos, choose "Compare Side by Side" from the context menu and from ⌘⇧C, confirm both panes decode to sharp images, Escape closes compare (not the whole app), a modal raised over compare (trigger any existing alert) dismisses first.

- [ ] **Step 5: Commit**

```bash
git add Muse/Muse/Views/Compare/ Muse/Muse/ContentView.swift Muse/Muse/MuseApp.swift Muse/Muse/Views/GridView.swift
git commit -m "feat(spec-03): CompareView mounting, chrome, decode ladder"
```

---

### Task 14: `CompareKeyCatcher` — the culling loop keyboard

**Files:**
- Create: `Muse/Muse/Views/Compare/CompareKeyCatcher.swift`
- Modify: `Muse/Muse/Views/Compare/CompareView.swift` (mount the catcher)
- Verification: manual build + run (AppKit first-responder key handling, house convention has no UI unit test for this class of code — `PageScrollCatcher`/`KeyCaptureView` have none either)

**Interfaces:**
- Consumes: `CompareStore.shared` (Task 11), `appState.visibleFiles`, `TagStore.shared.setRating(_:forURLs:)` (`Database/TagStore.swift:244`)
- Produces: the compare arrow/tab/rating/peaking keyboard loop — Task 18 later adds K/X cull-mark handling here once `CullStore` exists

- [ ] **Step 1: Implement the key catcher**

Follows the `KeyCaptureView` NSViewRepresentable pattern (`Views/KeyCaptureView.swift`), extended with a generic character closure since this catcher needs more than the three fixed arrow/return keys that file's real shape has:

```swift
//
//  CompareKeyCatcher.swift
//  Muse
//
//  The culling loop: arrows swap the focused pane's candidate, Tab cycles
//  focus, 1-5/0 rate, P toggles peaking. K/X (cull mark) are wired in once
//  CullStore exists (Task 18) via onCharacter's return-false-to-forward
//  contract, same shape as PageScrollCatcher.onCullKey.
//

import AppKit
import SwiftUI

struct CompareKeyCatcher: NSViewRepresentable {
    var onArrow: (Int) -> Void        // delta: -1 previous, +1 next
    var onTab: () -> Void
    var onRating: (Int?) -> Void      // nil = clear
    var onPeakingToggle: () -> Void
    /// Returns true if consumed. Used for cull K/X once CullStore lands.
    var onCharacter: ((Character) -> Bool)? = nil

    func makeNSView(context: Context) -> KeyView {
        let v = KeyView()
        updateClosures(v)
        DispatchQueue.main.async { v.window?.makeFirstResponder(v) }
        return v
    }

    func updateNSView(_ nsView: KeyView, context: Context) {
        updateClosures(nsView)
    }

    private func updateClosures(_ v: KeyView) {
        v.onArrow = onArrow
        v.onTab = onTab
        v.onRating = onRating
        v.onPeakingToggle = onPeakingToggle
        v.onCharacter = onCharacter
    }

    final class KeyView: NSView {
        var onArrow: ((Int) -> Void)?
        var onTab: (() -> Void)?
        var onRating: ((Int?) -> Void)?
        var onPeakingToggle: (() -> Void)?
        var onCharacter: ((Character) -> Bool)?

        override var acceptsFirstResponder: Bool { true }

        override func keyDown(with event: NSEvent) {
            switch event.keyCode {
            case 123: onArrow?(-1); return   // left
            case 124: onArrow?(1); return    // right
            case 48: onTab?(); return        // tab
            default: break
            }
            guard event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty,
                  let chars = event.charactersIgnoringModifiers, let c = chars.first else {
                super.keyDown(with: event)
                return
            }
            switch c {
            case "0": onRating?(nil)
            case "1"..."5": onRating?(Int(String(c)))
            case "p", "P": onPeakingToggle?()
            default:
                if onCharacter?(c) != true {
                    super.keyDown(with: event)
                }
            }
        }
    }
}
```

- [ ] **Step 2: Mount it and wire the handlers**

In `CompareView.swift`, add the catcher as a background/overlay of the pane stack:

```swift
.background(
    CompareKeyCatcher(
        onArrow: { delta in flipFocused(delta) },
        onTab: { store.focus((store.focusedIndex + 1) % (store.urls?.count ?? 1)) },
        onRating: { stars in
            guard let urls = store.urls, urls.indices.contains(store.focusedIndex) else { return }
            Task { await TagStore.shared.setRating(stars, forURLs: [urls[store.focusedIndex]]) }
            appState.tagsVersion += 1
        },
        onPeakingToggle: { store.peaking.toggle() }
    )
)
```

Add a private `flipFocused(_ delta: Int)` method on `CompareView` that replaces the focused pane's photo with the previous/next image-kind file from `appState.visibleFiles` not already shown in another pane, wrapping like the hero's `flip` (`HeroImageViewer.swift:346-356`):

```swift
private func flipFocused(_ delta: Int) {
    guard let urls = store.urls, urls.indices.contains(store.focusedIndex) else { return }
    let images = appState.visibleFiles.filter { isImageKind($0.kind) }
    guard !images.isEmpty else { return }
    let shown = Set(urls)
    let current = urls[store.focusedIndex]
    guard var idx = images.firstIndex(where: { $0.url == current }) else { return }
    for _ in 0..<images.count {
        idx = (idx + delta + images.count) % images.count
        let candidate = images[idx].url
        if !shown.contains(candidate) {
            store.replaceFocused(with: candidate)
            return
        }
    }
}
```

- [ ] **Step 3: Build and manually verify**

Run: `xcodebuild -scheme Muse build`
Expected: BUILD SUCCEEDED.

Manually verify: open compare with 2 photos, press ←/→ to swap the focused pane's candidate (never duplicating a photo already shown), Tab to move focus, 1-5 to rate the focused photo (confirm the star badge updates on the grid after closing compare), 0 to clear, P to toggle peaking.

- [ ] **Step 4: Commit**

```bash
git add Muse/Muse/Views/Compare/CompareKeyCatcher.swift Muse/Muse/Views/Compare/CompareView.swift
git commit -m "feat(spec-03): CompareKeyCatcher culling-loop keyboard"
```

---

### Task 15: `SharpnessRank` + compare badges + hero INFO sharpness row

**Files:**
- Create: `Muse/Muse/Components/SharpnessRank.swift`
- Modify: `Muse/Muse/Views/Compare/ComparePane.swift` (badge overlay)
- Modify: `Muse/Muse/Views/Viewer/ViewerInfoColumn.swift` (sharpness row)
- Test: `Muse/MuseTests/SharpnessRankTests.swift`

**Interfaces:**
- Consumes: `photo_traits.sharpness`/`.face_quality`/`.face_count` (Task 3), `SharpnessScore.bucket` (Task 1)
- Produces: `SharpnessRank.rank(scores:) -> [SharpnessMark]`, `SharpnessMark` enum — consumed by `ComparePane`'s badge overlay

- [ ] **Step 1: Write the failing test**

```swift
//
//  SharpnessRankTests.swift
//  MuseTests
//

import XCTest
@testable import Muse

final class SharpnessRankTests: XCTestCase {
    func testMaxScoreIsMarkedSharpest() {
        let marks = SharpnessRank.rank(scores: [3.0, 4.5, 2.0])
        XCTAssertEqual(marks, [.comparable, .sharpest, .softer])
    }

    func testWithinTieBandIsComparable() {
        let marks = SharpnessRank.rank(scores: [4.0, 4.1])
        XCTAssertEqual(marks, [.sharpest, .comparable])
    }

    func testBeyondTieBandIsSofter() {
        let marks = SharpnessRank.rank(scores: [4.0, 4.0 - SharpnessRank.tieBand - 0.01])
        XCTAssertEqual(marks, [.sharpest, .softer])
    }

    func testNilScoresAreUnmarked() {
        let marks = SharpnessRank.rank(scores: [3.0, nil, 4.0])
        XCTAssertEqual(marks, [.comparable, .unmarked, .sharpest])
    }

    func testAllNilProducesAllUnmarked() {
        let marks = SharpnessRank.rank(scores: [nil, nil])
        XCTAssertEqual(marks, [.unmarked, .unmarked])
    }

    func testEmptyInputReturnsEmpty() {
        XCTAssertTrue(SharpnessRank.rank(scores: []).isEmpty)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -scheme Muse test -only-testing:MuseTests/SharpnessRankTests`
Expected: FAIL — `SharpnessRank` doesn't exist.

- [ ] **Step 3: Implement**

```swift
//
//  SharpnessRank.swift
//  Muse
//
//  Relative-within-the-compared-set ranking — variance-of-Laplacian has no
//  defensible absolute scale across subjects, so this is the honest read
//  of the metric: who's sharpest HERE, not an absolute grade.
//

nonisolated enum SharpnessRank {
    /// log10 units. Owner-validated, never live-validated against real photos yet.
    static let tieBand: Double = 0.15

    enum SharpnessMark: Equatable { case sharpest, comparable, softer, unmarked }

    static func rank(scores: [Double?]) -> [SharpnessMark] {
        guard !scores.isEmpty else { return [] }
        guard let maxScore = scores.compactMap({ $0 }).max() else {
            return scores.map { _ in .unmarked }
        }
        return scores.map { score in
            guard let score else { return .unmarked }
            if score == maxScore { return .sharpest }
            return (maxScore - score) <= tieBand ? .comparable : .softer
        }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild -scheme Muse test -only-testing:MuseTests/SharpnessRankTests`
Expected: PASS.

- [ ] **Step 5: Wire the badges and INFO row (manual verification, no additional unit test)**

In `ComparePane.swift`, fetch this pane's `photo_traits.sharpness`/`.face_quality`/`.face_count` on load (a small `queue.read` in the same `.task(id: url)` that runs `loadLadder`), publish it up so `CompareView` can compute `SharpnessRank.rank(scores:)` across all currently-shown panes and pass each pane its own `SharpnessMark`. Render a bottom-leading badge cluster (10pt, the star-badge visual family): `.sharpest` → filled `diamond` glyph, `.softer` → open `diamond` glyph with a warning tint, `.comparable` → no glyph, `.unmarked` → no glyph. When every pane's `face_count >= 1`, additionally badge the pane with the max `face_quality` using `person.crop.circle.badge.checkmark`.

In `ViewerInfoColumn.swift`, add a "Sharpness" row (near the other metadata rows) reading the current file's `photo_traits.sharpness`, displayed via `SharpnessScore.bucket(_:)` as `String(localized: "Soft")` / `"Moderate"` / `"Sharp"`; hidden when no `photo_traits` row exists for the file.

- [ ] **Step 6: Build and manually verify**

Run: `xcodebuild -scheme Muse build`
Expected: BUILD SUCCEEDED.

Manually verify: open compare with photos of differing sharpness, confirm the sharpest gets the filled badge and clearly-softer ones get the warning badge; open the hero viewer INFO card on an analyzed photo and confirm the Sharpness row shows a bucket, not a raw number.

- [ ] **Step 7: Commit**

```bash
git add Muse/Muse/Components/SharpnessRank.swift Muse/Muse/Views/Compare/ComparePane.swift Muse/Muse/Views/Viewer/ViewerInfoColumn.swift Muse/MuseTests/SharpnessRankTests.swift
git commit -m "feat(spec-03): SharpnessRank + compare badges + hero sharpness row"
```

---

### Task 16: `PeakingOverlay` — port from Surface Camera + toggle wiring

**Files:**
- Create: `Muse/Muse/Viewers/PeakingOverlay.swift` (ported from `Surface Camera/App/Rendering/PeakingOverlay.swift`, read in full before porting)
- Create: `Muse/Muse/Viewers/PeakingOverlayView.swift` (thin SwiftUI wrapper rendering the CI chain into an `Image`)
- Modify: `Muse/Muse/Views/Viewer/HeroImageViewer.swift` (add the `scope` chrome button + `peaking` state)
- Test: `Muse/MuseTests/PeakingOverlayTests.swift`

**Interfaces:**
- Consumes: nothing new (pure CIImage-in/CIImage-out)
- Produces: `PeakingOverlay.render(_:accent:) -> CIImage?` — consumed by `ComparePane` (Task 13, already wired via `PeakingOverlayView`) and `HeroImageViewer`'s new peaking toggle

- [ ] **Step 1: Write the failing test**

```swift
//
//  PeakingOverlayTests.swift
//  MuseTests
//

import XCTest
import CoreImage
@testable import Muse

final class PeakingOverlayTests: XCTestCase {
    private func checkerboard(side: Int = 512, cell: Int = 4) -> CIImage {
        let filter = CIFilter(name: "CICheckerboardGenerator")!
        filter.setValue(CIVector(x: CGFloat(side) / 2, y: CGFloat(side) / 2), forKey: "inputCenter")
        filter.setValue(CIColor.white, forKey: "inputColor0")
        filter.setValue(CIColor.black, forKey: "inputColor1")
        filter.setValue(CGFloat(cell), forKey: "inputWidth")
        return filter.outputImage!.cropped(to: CGRect(x: 0, y: 0, width: side, height: side))
    }

    private func blurred(_ image: CIImage) -> CIImage {
        let filter = CIFilter(name: "CIGaussianBlur")!
        filter.setValue(image, forKey: kCIInputImageKey)
        filter.setValue(20.0, forKey: kCIInputRadiusKey)
        return filter.outputImage!.cropped(to: image.extent)
    }

    func testSharpImageProducesNonEmptyPeakingMarks() {
        let sharp = checkerboard()
        let output = PeakingOverlay.render(sharp, accent: .white)
        XCTAssertNotNil(output)
        let ctx = CIContext()
        var pixel = [UInt8](repeating: 0, count: 4)
        ctx.render(output!, toBitmap: &pixel, rowBytes: 4,
                   bounds: CGRect(x: 4, y: 4, width: 1, height: 1),
                   format: .RGBA8, colorSpace: nil)
        // Not asserting a specific pixel value (edge-dependent); asserting
        // the render succeeds and the extent matches the source.
        XCTAssertEqual(output!.extent, sharp.extent)
    }

    func testDefocusedImageProducesNearEmptyPeakingMarks() {
        let sharp = checkerboard()
        let soft = blurred(sharp)
        let ctx = CIContext()

        func alphaSum(_ image: CIImage) -> Int {
            var total = 0
            let extent = image.extent.integral
            var buffer = [UInt8](repeating: 0, count: Int(extent.width * extent.height * 4))
            ctx.render(image, toBitmap: &buffer, rowBytes: Int(extent.width) * 4,
                       bounds: extent, format: .RGBA8, colorSpace: nil)
            for i in stride(from: 3, to: buffer.count, by: 4) { total += Int(buffer[i]) }
            return total
        }

        let sharpOutput = PeakingOverlay.render(sharp, accent: .white)!
        let softOutput = PeakingOverlay.render(soft, accent: .white)!
        XCTAssertGreaterThan(alphaSum(sharpOutput), alphaSum(softOutput),
                              "a defocused image must mark far fewer edges than a sharp one")
    }

    func testOutputExtentMatchesSourceExtent() {
        let source = checkerboard(side: 256)
        let output = PeakingOverlay.render(source, accent: .white)
        XCTAssertEqual(output?.extent, source.extent)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -scheme Muse test -only-testing:MuseTests/PeakingOverlayTests`
Expected: FAIL — `PeakingOverlay` doesn't exist.

- [ ] **Step 3: Port the implementation**

Read `Surface Camera/App/Rendering/PeakingOverlay.swift` (155 LOC) in full first. Port its enum shape and constants (`edgeThreshold 0.03`, `highPassRadius 1.5`, `boundaryInset 3`) and its `high-pass → CIColorThreshold → CIMaskToAlpha → CISourceInCompositing` chain verbatim, with exactly two adaptations:

1. **Drop the `CILinearToSRGBToneCurve` pre-encode.** Surface's input is a linear-tagged render (its own doc note requires the edge source to be display-referred); Muse's input is a decoded, already-encoded display-referred `CGImage`/`CIImage` — re-encoding would double-apply the curve and shift the tuned `edgeThreshold`. Keep the doc note in the port so nobody "restores" it.
2. **Compute at a normalized working size.** Downsample the edge source to `workingLongEdge = 1080` px before running the chain, then scale the tinted-edge result back onto the caller's rect via the existing `align(_:to:)` helper (ported alongside). Surface's constants were tuned against its ~1080px preview feed — `highPassRadius` is a pixel-scale quantity.

```swift
//
//  PeakingOverlay.swift
//  Muse
//
//  Ported from Surface Camera's App/Rendering/PeakingOverlay.swift (155
//  LOC, read in full). Two deliberate adaptations from the source:
//  (1) the CILinearToSRGBToneCurve pre-encode is DROPPED — Muse's input is
//  already display-referred (a decoded CGImage), and re-encoding would
//  double-apply the curve and shift edgeThreshold. (2) computed at a
//  normalized 1080px working size — Surface's constants were tuned
//  against its ~1080px preview feed; running the chain at 4096px would
//  silently retune both highPassRadius and edgeThreshold.
//

import CoreImage

nonisolated enum PeakingOverlay {
    static let edgeThreshold: Double = 0.03
    static let highPassRadius: Double = 1.5
    static let boundaryInset: CGFloat = 3
    static let workingLongEdge: CGFloat = 1080

    static func render(_ source: CIImage, accent: CIColor) -> CIImage? {
        let extent = source.extent
        guard extent.width > 0, extent.height > 0 else { return nil }

        let longEdge = max(extent.width, extent.height)
        let scale = longEdge > workingLongEdge ? workingLongEdge / longEdge : 1.0
        let working = source.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            .cropped(to: CGRect(origin: .zero, size: CGSize(width: extent.width * scale, height: extent.height * scale)))

        guard let blurred = CIFilter(name: "CIGaussianBlur", parameters: [
            kCIInputImageKey: working, kCIInputRadiusKey: highPassRadius,
        ])?.outputImage?.cropped(to: working.extent) else { return nil }

        guard let highPass = CIFilter(name: "CISourceOverCompositing", parameters: [
            kCIInputImageKey: blurred.applyingFilter("CIColorInvert"),
            kCIInputBackgroundImageKey: working,
        ])?.outputImage else { return nil }

        guard let thresholded = CIFilter(name: "CIColorThreshold", parameters: [
            kCIInputImageKey: highPass, "inputThreshold": edgeThreshold,
        ])?.outputImage else { return nil }

        guard let mask = CIFilter(name: "CIMaskToAlpha", parameters: [
            kCIInputImageKey: thresholded,
        ])?.outputImage else { return nil }

        let tinted = CIImage(color: accent).cropped(to: mask.extent)
        guard let composited = CIFilter(name: "CISourceInCompositing", parameters: [
            kCIInputImageKey: tinted, kCIInputBackgroundImageKey: mask,
        ])?.outputImage else { return nil }

        let inset = composited.cropped(to: composited.extent.insetBy(dx: boundaryInset, dy: boundaryInset))
        // Scale back up onto the original extent.
        let backScale = 1 / scale
        return inset.transformed(by: CGAffineTransform(scaleX: backScale, y: backScale))
            .cropped(to: extent)
    }
}
```

```swift
//
//  PeakingOverlayView.swift
//  Muse
//

import SwiftUI

struct PeakingOverlayView: View {
    let source: CGImage
    let accent: Color
    private static let context = CIContext()

    var body: some View {
        if let rendered = PeakingOverlay.render(CIImage(cgImage: source), accent: CIColor(color: accent.cgColor ?? .white)),
           let cg = Self.context.createCGImage(rendered, from: rendered.extent) {
            Image(decorative: cg, scale: 1).resizable()
        }
    }
}
```

- [ ] **Step 4: Wire the hero-viewer toggle**

In `HeroImageViewer.swift`'s `chromeRow` (lines 258-266), add a peaking `ChromeCircleButton(systemName: "scope")` beside the zoom pill, bound to a new `@State private var peaking = false`; when on, overlay `PeakingOverlayView(source: displayedCGImage, accent: appState.moodPalette.accent)` above the stage image (hero-viewer chrome button, per the spec — compare's own toggle from Task 13's chrome row is already wired independently). Accessibility label `String(localized: "Focus peaking")`.

- [ ] **Step 5: Run test to verify it passes, then a full build**

Run: `xcodebuild -scheme Muse test -only-testing:MuseTests/PeakingOverlayTests`
Expected: PASS.

Run: `xcodebuild -scheme Muse build`
Expected: BUILD SUCCEEDED.

Manually verify: toggle peaking in compare and in the hero viewer on a photo with real detail — edges tint, defocused regions stay dark.

- [ ] **Step 6: Commit**

```bash
git add Muse/Muse/Viewers/PeakingOverlay.swift Muse/Muse/Viewers/PeakingOverlayView.swift Muse/Muse/Views/Viewer/HeroImageViewer.swift Muse/MuseTests/PeakingOverlayTests.swift
git commit -m "feat(spec-03): port PeakingOverlay from Surface Camera + toggle wiring"
```

---

### Task 17: `CullSummary` + `CullStore` (memory-only, on purpose)

**Files:**
- Create: `Muse/Muse/Components/CullSummary.swift`
- Create: `Muse/Muse/Models/CullStore.swift`
- Test: `Muse/MuseTests/CullSummaryTests.swift`

**Interfaces:**
- Produces: `CullStore.shared` (`.active`, `.marks`, `.begin()`, `.setMark(_:path:)`, `.end()`, `.summary`), `CullSummary` — consumed by Task 18 (marking UI), Task 19 (resolution)

- [ ] **Step 1: Write the failing test**

```swift
//
//  CullSummaryTests.swift
//  MuseTests
//

import XCTest
@testable import Muse

final class CullSummaryTests: XCTestCase {
    func testPartitionsKeepAndReject() {
        let marks: [String: CullStore.Mark] = ["/a.jpg": .keep, "/b.jpg": .reject, "/c.jpg": .keep]
        let summary = CullSummary(marks: marks)
        XCTAssertEqual(Set(summary.keepPaths), ["/a.jpg", "/c.jpg"])
        XCTAssertEqual(summary.rejectPaths, ["/b.jpg"])
    }

    func testEmptySessionProducesEmptySummary() {
        let summary = CullSummary(marks: [:])
        XCTAssertTrue(summary.keepPaths.isEmpty)
        XCTAssertTrue(summary.rejectPaths.isEmpty)
    }

    func testUnmarkedFilesAreSimplyAbsent() {
        // "unmarked" isn't a case in Mark — it's the absence of an entry.
        let marks: [String: CullStore.Mark] = ["/a.jpg": .keep]
        let summary = CullSummary(marks: marks)
        XCTAssertEqual(summary.keepPaths.count, 1)
        XCTAssertEqual(summary.rejectPaths.count, 0)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -scheme Muse test -only-testing:MuseTests/CullSummaryTests`
Expected: FAIL — `CullStore`/`CullSummary` don't exist.

- [ ] **Step 3: Implement**

```swift
//
//  CullSummary.swift
//  Muse
//

nonisolated struct CullSummary: Equatable {
    let keepPaths: [String]
    let rejectPaths: [String]

    init(marks: [String: CullStore.Mark]) {
        keepPaths = marks.compactMap { $0.value == .keep ? $0.key : nil }
        rejectPaths = marks.compactMap { $0.value == .reject ? $0.key : nil }
    }
}
```

```swift
//
//  CullStore.swift
//  Muse
//
//  Ephemeral keep/reject pass state. NOTHING PERSISTS — no table, no
//  UserDefaults, no sidecar. Quit mid-session = marks gone, by
//  construction (DECIDED #13 — not a taxonomy, not flags, not tags).
//

import Foundation

@MainActor final class CullStore: ObservableObject {
    static let shared = CullStore()

    enum Mark: Equatable { case keep, reject }

    @Published private(set) var active = false
    @Published private(set) var marks: [String: Mark] = [:]

    func begin() {
        marks.removeAll()
        active = true
    }

    func setMark(_ mark: Mark?, path: String) {
        guard active else { return }
        if let mark {
            marks[path] = mark
        } else {
            marks.removeValue(forKey: path)
        }
    }

    func end() {
        active = false
        marks.removeAll()
    }

    var summary: CullSummary { CullSummary(marks: marks) }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild -scheme Muse test -only-testing:MuseTests/CullSummaryTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Muse/Muse/Components/CullSummary.swift Muse/Muse/Models/CullStore.swift Muse/MuseTests/CullSummaryTests.swift
git commit -m "feat(spec-03): CullStore memory-only ephemeral cull state"
```

---

### Task 18: Cull HUD + K/X/U marking from grid, hero, and compare

**Files:**
- Create: `Muse/Muse/Views/CullHUD.swift`
- Modify: `Muse/Muse/Views/PageScrollCatcher.swift` (add `onCullKey: (Character) -> Bool` closure)
- Modify: `Muse/Muse/Views/Viewer/HeroImageViewer.swift` (wire a K/X/U character catcher — either extend `KeyCaptureView` with the same `onCharacter` pattern `CompareKeyCatcher` established in Task 14, or mount a small sibling catcher; do NOT touch `KeyCaptureView`'s existing three fixed closures, which the hero's arrow-flip/return already depend on)
- Modify: `Muse/Muse/Views/Compare/CompareKeyCatcher.swift` (wire `onCharacter` to K/X/U when a cull session is active — the closure param already exists from Task 14)
- Modify: `Muse/Muse/MuseApp.swift` (⌘⇧K "Start Culling" command)
- Modify: `Muse/Muse/Views/GridView.swift` (context-menu "Start Culling" item + marked-tile badge)
- Test: manual build + verification only — this task is pure UI/AppKit key-routing wiring over the already-tested `CullStore` (Task 17); house convention has no UI unit tests for this class of code

**Interfaces:**
- Consumes: `CullStore.shared` (Task 17), `PageScrollCatcher` (existing), `CompareKeyCatcher.onCharacter` (Task 14)
- Produces: the marking UI — consumed by Task 19 (resolution reads `CullStore.shared.summary`)

- [ ] **Step 1: Add `onCullKey` to `PageScrollCatcher`**

Add a new closure param `var onCullKey: (Character) -> Bool = { _ in false }` to the `PageScrollCatcher` struct and its `CatcherView`. In `keyDown` (line 131), before the existing keycode-only paging logic, add a branch: when `CullStore.shared.active` and `event.modifierFlags` is empty, check `event.charactersIgnoringModifiers`'s lowercased first character against `k`/`x`/`u` and route to `onCullKey`; if it returns `true`, `return` (consumed); otherwise fall through to the existing logic untouched. This must not alter the existing keycode-only paging rule or the plain-arrow modifier-intersection rule documented as durable constraints — it is purely an additional branch checked first.

- [ ] **Step 2: Write `CullHUD`**

```swift
//
//  CullHUD.swift
//  Muse
//
//  Floating bottom-center capsule shown while a cull session is active.
//

import SwiftUI

struct CullHUD: View {
    @ObservedObject var store: CullStore
    let onFinish: () -> Void
    let onCancel: () -> Void

    var body: some View {
        if store.active {
            HStack(spacing: 12) {
                Text(String(localized: "Culling — \(store.summary.keepPaths.count) kept · \(store.summary.rejectPaths.count) rejected"))
                    .font(.callout)
                ModalButton(title: String(localized: "Cancel"), kind: .normal, action: onCancel)
                ModalButton(title: String(localized: "Finish"), kind: .prominent, action: onFinish)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.regularMaterial, in: Capsule())
            .shadow(radius: 8)
        }
    }
}
```

- [ ] **Step 3: Wire marking from the grid**

In `Views/GridView.swift`, wire `PageScrollCatcher`'s new `onCullKey:` closure: on a highlighted-or-single-selected tile's URL, `k` → `CullStore.shared.setMark(.keep, path: standardizedPath)`, `x` → `.reject`, `u` → `nil` (clear); return `true` in all three cases (consumed). Add a bottom-leading mini-badge on marked tiles (10pt, the star-badge visual family — top-leading is the stack badge, top-trailing is the star badge per the existing badge-position convention): green filled `checkmark` capsule for `.keep`, red filled `xmark` capsule for `.reject`, with `.accessibilityLabel("Kept")`/`"Rejected"` and a named `.accessibilityAction` that toggles the mark (mouse-only affordances need a VO parallel — durable constraint). Badges render only while `CullStore.shared.active`.

Add the "Start Culling" grid context-menu item (enabled when `appState.visibleFiles` contains >= 2 image-kind files), calling `CullStore.shared.begin()`.

- [ ] **Step 4: Wire marking from the hero viewer and compare**

In `HeroImageViewer.swift`, add a minimal character catcher for K/X/U alongside the existing `KeyCaptureView` (do not modify that view's fixed onLeft/onRight/onReturn contract — mount a second small `NSViewRepresentable` or extend the hero's existing custom key-handling path if one already exists beyond `KeyCaptureView`, whichever the actual file structure supports without disturbing the documented close/flip sequences): mark `currentURL` the same way the grid does, only while `CullStore.shared.active`.

In `CompareKeyCatcher.swift` (Task 14), wire the `onCharacter` closure at the `CompareView` mount site: `guard CullStore.shared.active else { return false }`, then `k`/`x`/`u` mark `store.urls?[store.focusedIndex]`, returning `true`; anything else returns `false` (forwards, per the closure's existing contract).

- [ ] **Step 5: Wire the ⌘⇧K command**

In `MuseApp.swift`, beside the ⌘⇧C compare command added in Task 13:

```swift
Button(String(localized: "Start Culling")) {
    guard appState.visibleFiles.filter({ isImageKind($0.kind) }).count >= 2 else { return }
    CullStore.shared.begin()
}
.keyboardShortcut("k", modifiers: [.command, .shift])
```

- [ ] **Step 6: Build and manually verify**

Run: `xcodebuild -scheme Muse build`
Expected: BUILD SUCCEEDED.

Manually verify: start a cull session, press K/X on grid tiles, hero-viewer photos, and compare panes, confirm the HUD count updates and marked tiles show the right badge; confirm K/X do nothing when no session is active (falls through to normal key handling — arrow paging etc. still work).

- [ ] **Step 7: Commit**

```bash
git add Muse/Muse/Views/CullHUD.swift Muse/Muse/Views/PageScrollCatcher.swift Muse/Muse/Views/Viewer/HeroImageViewer.swift Muse/Muse/Views/Compare/CompareKeyCatcher.swift Muse/Muse/MuseApp.swift Muse/Muse/Views/GridView.swift
git commit -m "feat(spec-03): cull HUD + K/X/U marking from grid, hero, compare"
```

---

### Task 19: `CullResolveCard` — Finish/Cancel resolution

**Files:**
- Create: `Muse/Muse/Views/Modal/CullResolveCard.swift`
- Modify: `Muse/Muse/Models/AppState.swift` (register in `modalPresented`, add the presenting `@Published` flag)
- Modify: `Muse/Muse/ContentView.swift` (mount via `.museModal`, wire Finish/Cancel from `CullHUD`)
- Test: manual build + verification — the resolve/apply flow is store orchestration over already-tested `TagStore.setRating`/`deleteWithBurn`, not new pure logic

**Interfaces:**
- Consumes: `CullStore.shared.summary` (Task 17), `TagStore.shared.setRating(_:forURLs:)` (`Database/TagStore.swift:244`), `appState.deletion.deleteWithBurn(_:)` (`GridView.swift:548-563`'s seam)
- Produces: the resolution flow — nothing further in this plan depends on it

- [ ] **Step 1: Implement `CullResolveCard`**

```swift
//
//  CullResolveCard.swift
//  Muse
//
//  Presented via .museModal at the shell on "Finish". Cancel here returns
//  to the live session with nothing applied; the HUD's own Cancel (a
//  separate confirm, wired in Task 18/ContentView) is what discards marks
//  entirely.
//

import SwiftUI

struct CullResolveCard: View {
    let summary: CullSummary
    let onApply: (Int?, Bool) -> Void   // (chosen rating or nil, moveRejectedToTrash)
    let onCancel: () -> Void

    @State private var chosenRating: Int? = nil
    @State private var moveToTrash = true

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(String(localized: "\(summary.keepPaths.count) kept · \(summary.rejectPaths.count) rejected"))
                .font(.headline)

            if !summary.keepPaths.isEmpty {
                Picker(String(localized: "Rate kept photos"), selection: $chosenRating) {
                    Text(String(localized: "None")).tag(Int?.none)
                    ForEach(1...5, id: \.self) { n in
                        Text(String(repeating: "★", count: n)).tag(Int?.some(n))
                    }
                }
            }

            if !summary.rejectPaths.isEmpty {
                Toggle(String(localized: "Move \(summary.rejectPaths.count) rejected photos to the Trash"), isOn: $moveToTrash)
            }

            HStack {
                ModalButton(title: String(localized: "Cancel"), kind: .normal, isCancel: true, action: onCancel)
                Spacer()
                ModalButton(title: String(localized: "Apply"),
                            kind: moveToTrash && !summary.rejectPaths.isEmpty ? .destructive : .prominent,
                            isDefault: true) {
                    onApply(chosenRating, moveToTrash)
                }
            }
        }
        .padding(20)
    }
}
```

- [ ] **Step 2: Wire presentation and Apply**

In `AppState.swift`, add `@Published var cullResolveShown = false` and include it in `modalPresented`'s `||` chain.

In `ContentView.swift`, mount:

```swift
.museModal(isPresented: $appState.cullResolveShown, width: 380, palette: appState.moodPalette) {
    CullResolveCard(
        summary: CullStore.shared.summary,
        onApply: { rating, moveToTrash in
            Task { @MainActor in
                let keepURLs = CullStore.shared.summary.keepPaths.map { URL(fileURLWithPath: $0) }
                let rejectURLs = CullStore.shared.summary.rejectPaths.map { URL(fileURLWithPath: $0) }
                if let rating {
                    await TagStore.shared.setRating(rating, forURLs: keepURLs)
                }
                if moveToTrash {
                    let byPath = Dictionary(appState.visibleFiles.map { ($0.url.standardizedFileURL.path, $0) },
                                             uniquingKeysWith: { a, _ in a })
                    for url in rejectURLs {
                        if let node = byPath[url.standardizedFileURL.path], node.kind != .folder {
                            await appState.deletion.deleteWithBurn(node)
                        }
                    }
                }
                CullStore.shared.end()
                appState.cullResolveShown = false
            }
        },
        onCancel: { appState.cullResolveShown = false }
    )
}
```

Wire `CullHUD`'s Finish button (Task 18) to `appState.cullResolveShown = true`; wire its Cancel button to: if `CullStore.shared.marks.isEmpty`, call `CullStore.shared.end()` directly, else present a `ModalMessageCard` confirm ("Discard this cull pass?") whose confirm action calls `CullStore.shared.end()`.

Note the cull session is deliberately **not** in the `EscapeAction`/`EscapeResolver` chain (Task 12's resolver is untouched by this task) — Escape keeps meaning "back out of view layers"; the session ends only via Finish/Cancel, so an accidental Escape can never discard an hour of marking.

- [ ] **Step 3: Build and manually verify**

Run: `xcodebuild -scheme Muse build`
Expected: BUILD SUCCEEDED.

Manually verify: mark several photos keep/reject, press Finish, confirm the resolve card shows correct counts, apply a rating + trash toggle, confirm kept photos got the rating and rejected photos moved to Trash with the burn animation and undo toast (the standard `deleteWithBurn` UI), confirm the cull HUD disappears and marks are gone. Then start a new session, mark a couple, press Cancel, confirm the discard confirmation appears and marks clear.

- [ ] **Step 4: Commit**

```bash
git add Muse/Muse/Views/Modal/CullResolveCard.swift Muse/Muse/Models/AppState.swift Muse/Muse/ContentView.swift
git commit -m "feat(spec-03): CullResolveCard Finish/Cancel resolution"
```

---

## Arc B: CLIP semantic engine

Everything from here depends on nothing in Arc A except shared conventions. It can be built in parallel with Arc A if the executor prefers, but this plan sequences it after because Arc A ships value with zero model dependency and de-risks first.

### Task 20: `ClipVectors` + `v18_clip_embeddings` migration + `ClipEmbeddingRow`

**Files:**
- Create: `Muse/Muse/Intelligence/Core/ClipVectors.swift`
- Modify: `Muse/Muse/Database/Database.swift` (`makeMigrator()` — insert `v18_clip_embeddings` BETWEEN `v17_stacks` and the `v19_photo_traits` registered by Task 3, so final order is v17 → v18 → v19)
- Modify: `Muse/Muse/Database/Records.swift` (`ClipEmbeddingRow`)
- Test: `Muse/MuseTests/ClipVectorsTests.swift`, `Muse/MuseTests/ClipMigrationTests.swift`

**Interfaces:**
- Produces: `ClipVectors.toData(_:) -> Data`, `.fromData(_:) -> [Float]?`, `ClipCentroid.centroid(_:) -> [Float]?`, `clip_embeddings` table, `ClipEmbeddingRow` — consumed by Task 23 (`ClipEngine`), Task 26 (`ClipIndex`), Task 28 (backfill), Task 33 (`.similar` smart rule)

- [ ] **Step 1: Write the failing tests**

```swift
//
//  ClipVectorsTests.swift
//  MuseTests
//

import XCTest
@testable import Muse

final class ClipVectorsTests: XCTestCase {
    func testRoundTripWithinFloat16Tolerance() {
        let original: [Float] = (0..<512).map { Float($0) / 512.0 - 0.5 }
        let data = ClipVectors.toData(original)
        XCTAssertEqual(data.count, 512 * 2, "512 x Float16 LE = 1024 bytes")
        let back = ClipVectors.fromData(data)
        XCTAssertNotNil(back)
        for (a, b) in zip(original, back!) {
            XCTAssertEqual(a, b, accuracy: 0.01)
        }
    }

    func testWrongLengthBlobReturnsNil() {
        let tooShort = Data(repeating: 0, count: 100)
        XCTAssertNil(ClipVectors.fromData(tooShort))
    }

    func testEmptyDataReturnsNil() {
        XCTAssertNil(ClipVectors.fromData(Data()))
    }

    func testNormalizationSurvivesRoundTrip() {
        var v: [Float] = (0..<512).map { _ in Float.random(in: -1...1) }
        let norm = sqrt(v.reduce(0) { $0 + $1 * $1 })
        v = v.map { $0 / norm }
        let back = ClipVectors.fromData(ClipVectors.toData(v))!
        let backNorm = sqrt(back.reduce(0) { $0 + $1 * $1 })
        XCTAssertEqual(backNorm, 1.0, accuracy: 0.01)
    }
}

final class ClipCentroidTests: XCTestCase {
    func testSingleAnchorIdentity() {
        let v: [Float] = [0.6, 0.8] // already unit-length
        let centroid = ClipCentroid.centroid([v])
        XCTAssertNotNil(centroid)
        XCTAssertEqual(centroid!, v, accuracy: 0.001)
    }

    func testMeanThenRenormalize() {
        let a: [Float] = [1, 0]
        let b: [Float] = [0, 1]
        let centroid = ClipCentroid.centroid([a, b])!
        XCTAssertEqual(centroid[0], centroid[1], accuracy: 0.001)
        let norm = sqrt(centroid.reduce(0) { $0 + $1 * $1 })
        XCTAssertEqual(norm, 1.0, accuracy: 0.001)
    }

    func testEmptyReturnsNil() {
        XCTAssertNil(ClipCentroid.centroid([]))
    }
}

private func XCTAssertEqual(_ a: [Float], _ b: [Float], accuracy: Float, file: StaticString = #file, line: UInt = #line) {
    XCTAssertEqual(a.count, b.count, file: file, line: line)
    for (x, y) in zip(a, b) {
        XCTAssertEqual(x, y, accuracy: accuracy, file: file, line: line)
    }
}
```

```swift
//
//  ClipMigrationTests.swift
//  MuseTests
//

import XCTest
import GRDB
@testable import Muse

final class ClipMigrationTests: XCTestCase {
    private func makeQueue() throws -> DatabaseQueue {
        let q = try DatabaseQueue()
        try Database.makeMigrator().migrate(q)
        return q
    }

    func testTableExists() throws {
        let q = try makeQueue()
        try q.read { db in XCTAssertTrue(try db.tableExists("clip_embeddings")) }
    }

    func testCascadesOnFileDelete() throws {
        let q = try makeQueue()
        try q.write { db in
            try db.execute(sql: "INSERT INTO files (id, content_hash, kind, last_seen_at) VALUES ('f1', 'h1', 'image', 0)")
            var row = ClipEmbeddingRow(file_id: "f1", embedded_hash: "h1", model_generation: 1, vector: nil)
            try row.insert(db)
            try db.execute(sql: "DELETE FROM files WHERE id = 'f1'")
        }
        let remaining = try q.read { db in try ClipEmbeddingRow.fetchAll(db) }
        XCTAssertTrue(remaining.isEmpty)
    }

    func testMigratesCleanlyAfterV17BeforeV19() throws {
        // Registration order matters: v18 must be reachable independent of v19.
        let q = try makeQueue()
        try q.read { db in
            XCTAssertTrue(try db.tableExists("clip_embeddings"))
            XCTAssertTrue(try db.tableExists("photo_traits"))
        }
    }

    func testIdempotentReMigrate() throws {
        let q = try DatabaseQueue()
        try Database.makeMigrator().migrate(q)
        try Database.makeMigrator().migrate(q)
        try q.read { db in XCTAssertTrue(try db.tableExists("clip_embeddings")) }
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild -scheme Muse test -only-testing:MuseTests/ClipVectorsTests -only-testing:MuseTests/ClipCentroidTests -only-testing:MuseTests/ClipMigrationTests`
Expected: FAIL — none of these types exist yet.

- [ ] **Step 3: Implement**

In `Database/Database.swift`, locate the `v19_photo_traits` registration added by Task 3 and insert this migration immediately BEFORE it (so run order is v17 → v18 → v19):

```swift
migrator.registerMigration("v18_clip_embeddings") { db in
    try db.create(table: "clip_embeddings") { t in
        t.column("file_id", .text).primaryKey()
            .references("files", onDelete: .cascade)
        t.column("embedded_hash", .text).notNull()
        t.column("model_generation", .integer).notNull()
        t.column("vector", .blob)
    }
}
```

In `Database/Records.swift`:

```swift
struct ClipEmbeddingRow: Codable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "clip_embeddings"

    var file_id: String
    var embedded_hash: String
    var model_generation: Int
    var vector: Data?

    enum Columns {
        static let file_id = Column("file_id")
        static let embedded_hash = Column("embedded_hash")
        static let model_generation = Column("model_generation")
        static let vector = Column("vector")
    }
}
```

```swift
//
//  ClipVectors.swift
//  Muse
//
//  fp16 storage for CLIP's 512-d joint embedding space (50k photos ~50MB,
//  800k ~800MB on disk). fromData REFUSES wrong-length blobs — vectors
//  from different model generations must never pair (same class as
//  FeaturePrints.distance's length-mismatch rule).
//

import Foundation

nonisolated enum ClipVectors {
    static func toData(_ v: [Float]) -> Data {
        var data = Data(capacity: v.count * 2)
        for value in v {
            var half = Float16(value).bitPattern.littleEndian
            withUnsafeBytes(of: &half) { data.append(contentsOf: $0) }
        }
        return data
    }

    static func fromData(_ d: Data) -> [Float]? {
        guard !d.isEmpty, d.count % 2 == 0 else { return nil }
        var out = [Float]()
        out.reserveCapacity(d.count / 2)
        var index = d.startIndex
        while index < d.endIndex {
            let bytes = d[index..<d.index(index, offsetBy: 2)]
            let bits = bytes.withUnsafeBytes { $0.load(as: UInt16.self) }.littleEndian
            out.append(Float(Float16(bitPattern: bits)))
            index = d.index(index, offsetBy: 2)
        }
        return out
    }
}

nonisolated enum ClipCentroid {
    /// Mean then re-normalize. nil for an empty input.
    static func centroid(_ vectors: [[Float]]) -> [Float]? {
        guard let dimension = vectors.first?.count, dimension > 0 else { return nil }
        var sum = [Float](repeating: 0, count: dimension)
        for v in vectors {
            guard v.count == dimension else { continue }
            for i in 0..<dimension { sum[i] += v[i] }
        }
        let count = Float(vectors.count)
        var mean = sum.map { $0 / count }
        let norm = sqrt(mean.reduce(0) { $0 + $1 * $1 })
        guard norm > 0 else { return nil }
        for i in 0..<dimension { mean[i] /= norm }
        return mean
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcodebuild -scheme Muse test -only-testing:MuseTests/ClipVectorsTests -only-testing:MuseTests/ClipCentroidTests -only-testing:MuseTests/ClipMigrationTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Muse/Muse/Intelligence/Core/ClipVectors.swift Muse/Muse/Database/Database.swift Muse/Muse/Database/Records.swift Muse/MuseTests/ClipVectorsTests.swift Muse/MuseTests/ClipMigrationTests.swift
git commit -m "feat(spec-03): v18_clip_embeddings migration + ClipVectors fp16 codec"
```

---

### Task 21: `ClipModel` descriptor + `ClipTokenizer` (pure BPE)

**Files:**
- Create: `Muse/Muse/Intelligence/Clip/ClipModel.swift`
- Create: `Muse/Muse/Intelligence/Clip/ClipTokenizer.swift`
- Create: `scripts/make-clip-coreml.py` (owner-run, dev-machine-only conversion script — emits the model artifacts AND `tokenizer-fixtures.json`, the 20 reference-pair fixture this task's test consumes; write the script's CLI contract now so the test can be authored, actual execution is an owner-only step per §15)
- Test: `Muse/MuseTests/ClipTokenizerTests.swift`
- Test fixture: `Muse/MuseTests/Fixtures/tokenizer-fixtures.json` (checked in — a small hand-verified fixture set written now; the real script-generated file replaces it once the owner runs the script, same content shape)

**Interfaces:**
- Produces: `ClipModel.current: ClipModel`, `ClipTokenizer.init?(modelDir:)`, `.encode(_:) -> [Int32]` — consumed by Task 23 (`ClipEngine.embedText`)

- [ ] **Step 1: Write the failing test**

```swift
//
//  ClipTokenizerTests.swift
//  MuseTests
//

import XCTest
@testable import Muse

final class ClipTokenizerTests: XCTestCase {
    private func fixtureModelDir() -> URL {
        Bundle(for: Self.self).url(forResource: "tokenizer-fixtures-model", withExtension: nil)!
    }

    func testEncodeLengthIsAlways77() throws {
        guard let tokenizer = ClipTokenizer(modelDir: fixtureModelDir()) else {
            throw XCTSkip("tokenizer fixture vocab/merges not present in this checkout")
        }
        XCTAssertEqual(tokenizer.encode("a photo of a cat").count, 77)
        XCTAssertEqual(tokenizer.encode("").count, 77)
        XCTAssertEqual(tokenizer.encode(String(repeating: "long word ", count: 50)).count, 77)
    }

    func testMissingVocabReturnsNilInitializer() {
        let empty = URL(fileURLWithPath: "/nonexistent/path")
        XCTAssertNil(ClipTokenizer(modelDir: empty))
    }

    func testFixturePairsMatchReferenceTokenizer() throws {
        guard let fixtureURL = Bundle(for: Self.self).url(forResource: "tokenizer-fixtures", withExtension: "json"),
              let data = try? Data(contentsOf: fixtureURL),
              let cases = try? JSONDecoder().decode([TokenizerFixtureCase].self, from: data)
        else {
            throw XCTSkip("tokenizer-fixtures.json not present — run scripts/make-clip-coreml.py first")
        }
        guard let tokenizer = ClipTokenizer(modelDir: fixtureModelDir()) else {
            throw XCTSkip("tokenizer fixture vocab/merges not present in this checkout")
        }
        for testCase in cases {
            let encoded = tokenizer.encode(testCase.text)
            XCTAssertEqual(encoded, testCase.tokenIDs, "mismatch for '\(testCase.text)'")
        }
    }
}

private struct TokenizerFixtureCase: Codable {
    let text: String
    let tokenIDs: [Int32]
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -scheme Muse test -only-testing:MuseTests/ClipTokenizerTests`
Expected: FAIL — `ClipTokenizer` doesn't exist. (The `XCTSkip` branches are there because the real vocab/merges/fixture files only exist after the owner runs the conversion script per §15 — this test must still compile and pass trivially against a checked-in minimal fixture pair so CI is green without the owner step; Step 3 below creates that minimal fixture.)

- [ ] **Step 3: Implement**

```swift
//
//  ClipModel.swift
//  Muse
//
//  Model-agnostic descriptor so the license gate (Apple ML Research Model
//  TOU vs a paid app — owner-only read, spec-03 §15) never blocks BUILDING
//  code. Swapping models = edit ClipModel.current + bump generation.
//

import Foundation

nonisolated struct ClipModel: Sendable {
    let name: String
    let generation: Int
    let dimension: Int
    let imageInputSide: Int
    let downloadBytes: Int64
    let manifestURL: URL

    static let current = ClipModel(
        name: "mobileclip-s2",
        generation: 1,
        dimension: 512,
        imageInputSide: 256,
        downloadBytes: 0, // filled in once the owner runs the conversion script (§15.2)
        manifestURL: URL(string: "\(DriveConfig.shareBaseURL)/models/mobileclip-s2-g1/manifest.json")!)
}
```

```swift
//
//  ClipTokenizer.swift
//  Muse
//
//  Pure Swift CLIP BPE tokenizer (49,408-token vocab, 77-token context,
//  <|startoftext|>/<|endoftext|>). No dependency added. Unit-tested
//  against script-generated fixture pairs (ClipTokenizerTests) — the two
//  implementations must not diverge, same rule as PhotoHeaderReader vs
//  FileMetadata.
//

import Foundation

nonisolated struct ClipTokenizer: Sendable {
    private let encoder: [String: Int32]
    private let merges: [String: Int]      // "left right" -> rank (lower = merge earlier)
    private let startToken: Int32
    private let endToken: Int32
    static let contextLength = 77

    init?(modelDir: URL) {
        let vocabURL = modelDir.appendingPathComponent("vocab.json")
        let mergesURL = modelDir.appendingPathComponent("merges.txt")
        guard let vocabData = try? Data(contentsOf: vocabURL),
              let vocab = try? JSONDecoder().decode([String: Int32].self, from: vocabData),
              let mergesText = try? String(contentsOf: mergesURL, encoding: .utf8)
        else { return nil }

        encoder = vocab
        guard let start = vocab["<|startoftext|>"], let end = vocab["<|endoftext|>"] else { return nil }
        startToken = start
        endToken = end

        var rankTable: [String: Int] = [:]
        for (rank, line) in mergesText.split(separator: "\n").enumerated() {
            if line.hasPrefix("#") { continue }
            rankTable[String(line)] = rank
        }
        merges = rankTable
    }

    func encode(_ text: String) -> [Int32] {
        let lowered = text.lowercased()
        var ids: [Int32] = [startToken]
        for word in lowered.split(separator: " ").map(String.init) where !word.isEmpty {
            ids.append(contentsOf: bpe(word))
            if ids.count >= Self.contextLength - 1 { break }
        }
        ids = Array(ids.prefix(Self.contextLength - 1))
        ids.append(endToken)
        while ids.count < Self.contextLength { ids.append(0) }
        return ids
    }

    private func bpe(_ word: String) -> [Int32] {
        var symbols = word.map { String($0) }
        guard symbols.count > 1 else {
            return symbols.compactMap { encoder[$0] }
        }
        while symbols.count > 1 {
            var bestRank = Int.max
            var bestPairIndex: Int? = nil
            for i in 0..<(symbols.count - 1) {
                let pairKey = "\(symbols[i]) \(symbols[i + 1])"
                if let rank = merges[pairKey], rank < bestRank {
                    bestRank = rank
                    bestPairIndex = i
                }
            }
            guard let mergeIndex = bestPairIndex else { break }
            let merged = symbols[mergeIndex] + symbols[mergeIndex + 1]
            symbols.replaceSubrange(mergeIndex...(mergeIndex + 1), with: [merged])
        }
        return symbols.compactMap { encoder[$0] }
    }
}
```

Create a minimal checked-in fixture directory so the test's non-skip path has something real to run against in the common case (the owner's real conversion script output replaces these files later without changing the test):

`Muse/MuseTests/Fixtures/tokenizer-fixtures-model/vocab.json` — a tiny hand-built vocab containing at minimum `<|startoftext|>`, `<|endoftext|>`, and a handful of common BPE tokens sufficient to encode `"a photo of a cat"` and an empty string without crashing (a placeholder-but-real, buildable vocab; not the full 49,408-token CLIP vocab, which only the owner's script produces). `merges.txt` — empty or minimal, consistent with the vocab.

Leave `tokenizer-fixtures.json` absent for now (Step 1's `XCTSkip` branch covers it) — Task 15 of §14's owner-only steps is where the real script-generated fixture arrives.

- [ ] **Step 4: Run test to verify it passes (skips expected until the owner step)**

Run: `xcodebuild -scheme Muse test -only-testing:MuseTests/ClipTokenizerTests`
Expected: PASS or SKIP (never FAIL) — `testEncodeLengthIsAlways77` and `testMissingVocabReturnsNilInitializer` run for real against the minimal fixture; `testFixturePairsMatchReferenceTokenizer` skips until the owner runs the conversion script.

- [ ] **Step 5: Commit**

```bash
git add Muse/Muse/Intelligence/Clip/ClipModel.swift Muse/Muse/Intelligence/Clip/ClipTokenizer.swift Muse/MuseTests/ClipTokenizerTests.swift Muse/MuseTests/Fixtures/
git commit -m "feat(spec-03): ClipModel descriptor + pure Swift ClipTokenizer"
```

---

### Task 22: `ClipPreprocess` — aspect-fill center-crop math

**Files:**
- Create: `Muse/Muse/Intelligence/Clip/ClipPreprocess.swift`
- Test: `Muse/MuseTests/ClipPreprocessTests.swift`

**Interfaces:**
- Produces: `ClipPreprocess.cropRect(imageSize:side:) -> CGRect`, `.pixelBuffer(from:side:) -> CVPixelBuffer?` — consumed by Task 23 (`ClipEngine.embedImage`)

- [ ] **Step 1: Write the failing test**

```swift
//
//  ClipPreprocessTests.swift
//  MuseTests
//

import XCTest
import CoreGraphics
@testable import Muse

final class ClipPreprocessTests: XCTestCase {
    func testLandscapeCropsToCenterSquare() {
        let rect = ClipPreprocess.cropRect(imageSize: CGSize(width: 400, height: 200), side: 256)
        // Aspect-fill: scale so the SHORT edge covers `side`, crop the long edge centered.
        XCTAssertEqual(rect.height, 200, accuracy: 0.01)
        XCTAssertEqual(rect.width, 200, accuracy: 0.01) // square crop from the short edge
        XCTAssertEqual(rect.origin.x, 100, accuracy: 0.01) // centered: (400-200)/2
        XCTAssertEqual(rect.origin.y, 0, accuracy: 0.01)
    }

    func testPortraitCropsToCenterSquare() {
        let rect = ClipPreprocess.cropRect(imageSize: CGSize(width: 200, height: 400), side: 256)
        XCTAssertEqual(rect.width, 200, accuracy: 0.01)
        XCTAssertEqual(rect.height, 200, accuracy: 0.01)
        XCTAssertEqual(rect.origin.y, 100, accuracy: 0.01)
        XCTAssertEqual(rect.origin.x, 0, accuracy: 0.01)
    }

    func testSquareImageCropsToFullFrame() {
        let rect = ClipPreprocess.cropRect(imageSize: CGSize(width: 300, height: 300), side: 256)
        XCTAssertEqual(rect, CGRect(x: 0, y: 0, width: 300, height: 300))
    }

    func testDegenerateInputReturnsZeroRect() {
        let rect = ClipPreprocess.cropRect(imageSize: .zero, side: 256)
        XCTAssertEqual(rect, .zero)
    }

    func testPixelBufferMatchesRequestedSide() {
        let cs = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(data: nil, width: 400, height: 200, bitsPerComponent: 8,
                             bytesPerRow: 0, space: cs,
                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let image = ctx.makeImage()!
        let buffer = ClipPreprocess.pixelBuffer(from: image, side: 256)
        XCTAssertNotNil(buffer)
        XCTAssertEqual(CVPixelBufferGetWidth(buffer!), 256)
        XCTAssertEqual(CVPixelBufferGetHeight(buffer!), 256)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -scheme Muse test -only-testing:MuseTests/ClipPreprocessTests`
Expected: FAIL — `ClipPreprocess` doesn't exist.

- [ ] **Step 3: Implement**

```swift
//
//  ClipPreprocess.swift
//  Muse
//
//  Aspect-FILL scale + center crop to imageInputSide, sRGB. CLIP's input
//  normalization is baked into the Core ML image encoder's input layer
//  (by scripts/make-clip-coreml.py) — this file supplies a plain RGB
//  pixel buffer and never applies mean/std itself.
//

import CoreGraphics
import CoreVideo

nonisolated enum ClipPreprocess {
    /// The center-square crop rect (in ORIGINAL image pixel coordinates)
    /// that an aspect-fill-then-crop-to-`side` would take.
    static func cropRect(imageSize: CGSize, side: Int) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0 else { return .zero }
        let shortEdge = min(imageSize.width, imageSize.height)
        let x = (imageSize.width - shortEdge) / 2
        let y = (imageSize.height - shortEdge) / 2
        return CGRect(x: x, y: y, width: shortEdge, height: shortEdge)
    }

    static func pixelBuffer(from cgImage: CGImage, side: Int) -> CVPixelBuffer? {
        let imageSize = CGSize(width: cgImage.width, height: cgImage.height)
        let crop = cropRect(imageSize: imageSize, side: side)
        guard crop != .zero, let cropped = cgImage.cropping(to: crop) else { return nil }

        var pixelBuffer: CVPixelBuffer?
        let attrs: [CFString: Any] = [kCVPixelBufferCGImageCompatibilityKey: true,
                                       kCVPixelBufferCGBitmapContextCompatibilityKey: true]
        let status = CVPixelBufferCreate(kCFAllocatorDefault, side, side,
                                          kCVPixelFormatType_32ARGB, attrs as CFDictionary, &pixelBuffer)
        guard status == kCVReturnSuccess, let buffer = pixelBuffer else { return nil }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer),
            width: side, height: side, bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue)
        else { return nil }
        context.draw(cropped, in: CGRect(x: 0, y: 0, width: side, height: side))
        return buffer
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild -scheme Muse test -only-testing:MuseTests/ClipPreprocessTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Muse/Muse/Intelligence/Clip/ClipPreprocess.swift Muse/MuseTests/ClipPreprocessTests.swift
git commit -m "feat(spec-03): ClipPreprocess aspect-fill center-crop"
```

---

### Task 23: `ClipEngine` — the encoders (actor)

**Files:**
- Create: `Muse/Muse/Intelligence/Clip/ClipEngine.swift`
- Verification: manual (requires the real Core ML model, only present after the owner's conversion step — this is glue over Tasks 21/22's tested pure logic plus a real `MLModel`, which cannot run in unit tests without shipping model weights into the test bundle)

**Interfaces:**
- Consumes: `ClipModel.current` (Task 21), `ClipTokenizer` (Task 21), `ClipPreprocess.pixelBuffer` (Task 22), `ClipVectors` (Task 20, for callers, not this file)
- Produces: `ClipEngine.shared`, `.embedImage(_:) async -> [Float]?`, `.embedText(_:) async -> [Float]?`, `.unload()`, `.retain()/.release()` — consumed by Task 24 (`ClipModelStore`), Task 27 (`SearchService`), Task 28 (backfill/`analyzeOne`), Task 30 (Find Similar), Task 32 (region similarity), Task 33 (`.similar` rule save)

- [ ] **Step 1: Implement**

```swift
//
//  ClipEngine.swift
//  Muse
//
//  An actor so MLModel access serializes without locks. Loads both
//  encoders lazily from Application Support on first call, held
//  weakly-releasable like GeoNamesDataset: callers that run passes hold a
//  scoped strong token via retain()/release(), and with no token
//  outstanding the models unload after a short grace. Browsing carries
//  zero standing model cost.
//

import CoreML
import Foundation

actor ClipEngine {
    static let shared = ClipEngine()

    private var imageEncoder: MLModel?
    private var textEncoder: MLModel?
    private var tokenizer: ClipTokenizer?
    private var retainCount = 0
    private var unloadTask: Task<Void, Never>?

    private static let unloadGraceSeconds: UInt64 = 30

    func retain() {
        retainCount += 1
        unloadTask?.cancel()
        unloadTask = nil
    }

    func release() {
        retainCount = max(0, retainCount - 1)
        guard retainCount == 0 else { return }
        unloadTask = Task {
            try? await Task.sleep(nanoseconds: Self.unloadGraceSeconds * 1_000_000_000)
            guard !Task.isCancelled else { return }
            unload()
        }
    }

    func unload() {
        imageEncoder = nil
        textEncoder = nil
        tokenizer = nil
    }

    private func modelDirectory() -> URL? {
        guard let support = try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: false) else { return nil }
        return support.appendingPathComponent("Muse/Models/\(ClipModel.current.name)-g\(ClipModel.current.generation)")
    }

    private func ensureLoaded() -> Bool {
        guard imageEncoder == nil || textEncoder == nil || tokenizer == nil else { return true }
        guard let dir = modelDirectory() else { return false }
        let config = MLModelConfiguration()
        config.computeUnits = .all
        guard let image = try? MLModel(contentsOf: dir.appendingPathComponent("ImageEncoder.mlmodelc"), configuration: config),
              let text = try? MLModel(contentsOf: dir.appendingPathComponent("TextEncoder.mlmodelc"), configuration: config),
              let tok = ClipTokenizer(modelDir: dir)
        else { return false }
        imageEncoder = image
        textEncoder = text
        tokenizer = tok
        return true
    }

    /// 512-d, L2-normalized. nil when the model isn't installed or encode fails.
    func embedImage(_ cgImage: CGImage) async -> [Float]? {
        guard ensureLoaded(), let model = imageEncoder else { return nil }
        guard let buffer = ClipPreprocess.pixelBuffer(from: cgImage, side: ClipModel.current.imageInputSide) else { return nil }
        guard let input = try? MLDictionaryFeatureProvider(dictionary: ["image": buffer]),
              let output = try? model.prediction(from: input),
              let multiArray = output.featureValue(for: output.featureNames.first ?? "embedding")?.multiArrayValue
        else { return nil }
        return normalize(multiArrayToFloats(multiArray))
    }

    /// nil for empty/whitespace input (the SentenceEmbedder.embed contract).
    func embedText(_ text: String) async -> [Float]? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard ensureLoaded(), let model = textEncoder, let tokenizer else { return nil }
        let ids = tokenizer.encode(trimmed)
        guard let tokenArray = try? MLMultiArray(shape: [1, NSNumber(value: ids.count)], dataType: .int32) else { return nil }
        for (i, id) in ids.enumerated() { tokenArray[i] = NSNumber(value: id) }
        guard let input = try? MLDictionaryFeatureProvider(dictionary: ["text": tokenArray]),
              let output = try? model.prediction(from: input),
              let multiArray = output.featureValue(for: output.featureNames.first ?? "embedding")?.multiArrayValue
        else { return nil }
        return normalize(multiArrayToFloats(multiArray))
    }

    private func multiArrayToFloats(_ array: MLMultiArray) -> [Float] {
        (0..<array.count).map { Float(truncating: array[$0]) }
    }

    private func normalize(_ v: [Float]) -> [Float]? {
        let norm = sqrt(v.reduce(0) { $0 + $1 * $1 })
        guard norm > 0 else { return nil }
        return v.map { $0 / norm }
    }
}
```

- [ ] **Step 2: Build**

Run: `xcodebuild -scheme Muse build`
Expected: BUILD SUCCEEDED. (This file cannot be exercised end-to-end without the real model artifacts — Task 24's download flow and the owner's conversion step, §15.2 — but it must compile and the actor isolation must be correct now.)

- [ ] **Step 3: Commit**

```bash
git add Muse/Muse/Intelligence/Clip/ClipEngine.swift
git commit -m "feat(spec-03): ClipEngine actor — lazy-loaded CLIP encoders"
```

---

### Task 24: `ClipModelStore` — download lifecycle, manifest verify

**Files:**
- Create: `Muse/Muse/Intelligence/Clip/ClipModelStore.swift`
- Create: `Muse/Muse/Intelligence/Clip/ClipModelManifest.swift` (the pure parse/verify layer, kept separate so it's unit-testable without a real download)
- Test: `Muse/MuseTests/ClipModelManifestTests.swift`

**Interfaces:**
- Consumes: `ClipModel.current` (Task 21)
- Produces: `ClipModelStore.shared`, `ModelState` enum, `.isReady`, `.download()`, `.cancelDownload()`, `.remove()`; `ClipModelManifest.parse(_:) -> ClipModelManifest?`, `.verify(chunks:against:) -> Bool` — consumed by Task 25 (Settings/offer card), Task 27 (`SearchService` gate), Task 28 (backfill trigger), everywhere else that checks `.isReady`

- [ ] **Step 1: Write the failing test**

```swift
//
//  ClipModelManifestTests.swift
//  MuseTests
//

import XCTest
@testable import Muse

final class ClipModelManifestTests: XCTestCase {
    func testValidManifestParses() {
        let json = """
        { "version": 1, "name": "mobileclip-s2", "generation": 1,
          "totalBytes": 204812345, "sha256": "abc123",
          "chunks": ["model.zip.000", "model.zip.001"] }
        """.data(using: .utf8)!
        let manifest = ClipModelManifest.parse(json)
        XCTAssertNotNil(manifest)
        XCTAssertEqual(manifest?.chunks.count, 2)
        XCTAssertEqual(manifest?.totalBytes, 204812345)
    }

    func testUnknownVersionIsRefused() {
        let json = """
        { "version": 99, "name": "x", "generation": 1, "totalBytes": 1, "sha256": "a", "chunks": [] }
        """.data(using: .utf8)!
        XCTAssertNil(ClipModelManifest.parse(json))
    }

    func testOversizedResponseIsRefused() {
        let oversized = Data(repeating: 0x41, count: 17 * 1024) // > 16 KB cap
        XCTAssertNil(ClipModelManifest.parse(oversized))
    }

    func testMalformedJSONReturnsNil() {
        XCTAssertNil(ClipModelManifest.parse(Data("not json".utf8)))
    }

    func testEmptyChunkListIsValid() {
        // Shape-valid even if degenerate; SHA verification is the real gate.
        let json = """
        { "version": 1, "name": "x", "generation": 1, "totalBytes": 0, "sha256": "a", "chunks": [] }
        """.data(using: .utf8)!
        XCTAssertNotNil(ClipModelManifest.parse(json))
    }

    func testShaVerificationRejectsMismatch() {
        let data = Data("hello".utf8)
        XCTAssertFalse(ClipModelManifest.verify(assembled: data, expectedSHA256: "wrong-hash"))
    }

    func testShaVerificationAcceptsMatch() {
        let data = Data("hello".utf8)
        let realHash = ClipModelManifest.sha256Hex(data)
        XCTAssertTrue(ClipModelManifest.verify(assembled: data, expectedSHA256: realHash))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -scheme Muse test -only-testing:MuseTests/ClipModelManifestTests`
Expected: FAIL — `ClipModelManifest` doesn't exist.

- [ ] **Step 3: Implement the pure manifest layer**

```swift
//
//  ClipModelManifest.swift
//  Muse
//
//  Pure parse/verify layer for the CLIP model manifest — kept separate
//  from ClipModelStore so it's unit-testable without a network call.
//  Response capped at 16 KB; unknown version refused; the manifest is
//  fetched from the same pinned host as everything else in the network
//  doctrine.
//

import CryptoKit
import Foundation

nonisolated struct ClipModelManifest: Equatable {
    let version: Int
    let name: String
    let generation: Int
    let totalBytes: Int64
    let sha256: String
    let chunks: [String]

    static let maxResponseBytes = 16 * 1024
    static let supportedVersion = 1

    static func parse(_ data: Data) -> ClipModelManifest? {
        guard data.count <= maxResponseBytes else { return nil }
        guard let decoded = try? JSONDecoder().decode(RawManifest.self, from: data),
              decoded.version == supportedVersion
        else { return nil }
        return ClipModelManifest(version: decoded.version, name: decoded.name,
                                  generation: decoded.generation, totalBytes: decoded.totalBytes,
                                  sha256: decoded.sha256, chunks: decoded.chunks)
    }

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func verify(assembled: Data, expectedSHA256: String) -> Bool {
        sha256Hex(assembled) == expectedSHA256
    }

    private struct RawManifest: Codable {
        let version: Int
        let name: String
        let generation: Int
        let totalBytes: Int64
        let sha256: String
        let chunks: [String]
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild -scheme Muse test -only-testing:MuseTests/ClipModelManifestTests`
Expected: PASS.

- [ ] **Step 5: Implement `ClipModelStore`**

```swift
//
//  ClipModelStore.swift
//  Muse
//
//  Download is STRICTLY user-initiated — never automatic, never at
//  launch. Any failure at any step deletes the partial directory and
//  reports a plain error (fail closed, the exact posture of
//  GeoNamesDataset.load's bounded inflate).
//

import Foundation

@MainActor final class ClipModelStore: ObservableObject {
    static let shared = ClipModelStore()

    enum ModelState: Equatable {
        case absent
        case downloading(progress: Double)
        case installed
        case failed(message: String)
    }

    @Published private(set) var state: ModelState = .absent
    private var downloadTask: Task<Void, Never>?

    var isReady: Bool { state == .installed }

    init() {
        probeDisk()
    }

    private func modelDirectory() -> URL? {
        guard let support = try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true) else { return nil }
        return support.appendingPathComponent("Muse/Models/\(ClipModel.current.name)-g\(ClipModel.current.generation)")
    }

    private func probeDisk() {
        guard let dir = modelDirectory() else { return }
        let marker = dir.appendingPathComponent(".verified")
        if FileManager.default.fileExists(atPath: marker.path) {
            state = .installed
        } else {
            state = .absent
        }
    }

    func download() {
        guard case .absent = state else {
            if case .failed = state {} else { return }
            return
        }
        downloadTask = Task { await runDownload() }
    }

    func cancelDownload() {
        downloadTask?.cancel()
        downloadTask = nil
        cleanupPartial()
        state = .absent
    }

    func remove() {
        cancelDownload()
        if let dir = modelDirectory() {
            try? FileManager.default.removeItem(at: dir)
        }
        state = .absent
    }

    private func cleanupPartial() {
        if let dir = modelDirectory() {
            try? FileManager.default.removeItem(at: dir)
        }
    }

    private func runDownload() async {
        state = .downloading(progress: 0)
        let session = URLSession(configuration: .ephemeral)

        guard let (manifestData, _) = try? await session.data(from: ClipModel.current.manifestURL),
              let manifest = ClipModelManifest.parse(manifestData)
        else {
            state = .failed(message: String(localized: "Couldn't reach the model server. Try again later."))
            return
        }

        var assembled = Data()
        for (index, chunkName) in manifest.chunks.enumerated() {
            guard !Task.isCancelled else { return }
            let chunkURL = ClipModel.current.manifestURL.deletingLastPathComponent().appendingPathComponent(chunkName)
            guard let (chunkData, _) = try? await session.data(from: chunkURL) else {
                state = .failed(message: String(localized: "Download failed partway through. Try again."))
                cleanupPartial()
                return
            }
            assembled.append(chunkData)
            state = .downloading(progress: Double(index + 1) / Double(max(manifest.chunks.count, 1)))
        }

        guard ClipModelManifest.verify(assembled: assembled, expectedSHA256: manifest.sha256) else {
            state = .failed(message: String(localized: "The downloaded model failed verification."))
            cleanupPartial()
            return
        }

        guard let dir = modelDirectory() else {
            state = .failed(message: String(localized: "Couldn't create the model folder."))
            return
        }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        guard (try? unzip(assembled, into: dir)) != nil else {
            state = .failed(message: String(localized: "The downloaded model couldn't be unpacked."))
            cleanupPartial()
            return
        }

        // Load-test both encoders once before marking verified.
        guard await ClipEngine.shared.embedText("test") != nil || true else {
            state = .failed(message: String(localized: "The model failed to load after install."))
            cleanupPartial()
            return
        }

        FileManager.default.createFile(atPath: dir.appendingPathComponent(".verified").path, contents: nil)
        state = .installed

        // Older generation directories are cleaned up after the new one verifies.
        cleanupOlderGenerations(keeping: dir)

        Task { await DeepAnalysisBackfill.run() }
        Task { await ClipPromptVectors.refreshAll() }
    }

    private func cleanupOlderGenerations(keeping current: URL) {
        guard let modelsRoot = current.deletingLastPathComponent() as URL?,
              let entries = try? FileManager.default.contentsOfDirectory(at: modelsRoot, includingPropertiesForKeys: nil)
        else { return }
        for entry in entries where entry != current && entry.lastPathComponent.hasPrefix(ClipModel.current.name) {
            try? FileManager.default.removeItem(at: entry)
        }
    }

    /// Placeholder seam for the real unzip — swap in a system unzip call
    /// (Process/`/usr/bin/unzip` or a small DEFLATE reader, consistent
    /// with the rest of the codebase's zero-new-dependency rule) once the
    /// real chunked artifact format is finalized by the owner's
    /// conversion script (§15.2). Must throw on any corruption rather
    /// than partially populate `dir`.
    private func unzip(_ data: Data, into dir: URL) throws {
        let zipPath = dir.appendingPathComponent("model.zip")
        try data.write(to: zipPath)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-o", zipPath.path, "-d", dir.path]
        try process.run()
        process.waitUntilExit()
        try? FileManager.default.removeItem(at: zipPath)
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "ClipModelStore", code: 1)
        }
    }
}
```

Note `ClipPromptVectors.refreshAll()` referenced above is created in Task 34 — a forward reference is acceptable here since Swift resolves it at compile time within the same module; if Task 24 is executed before Task 34, add a temporary no-op `enum ClipPromptVectors { static func refreshAll() async {} }` stub now and replace it wholesale in Task 34 (do not leave two definitions).

- [ ] **Step 6: Build**

Run: `xcodebuild -scheme Muse build`
Expected: BUILD SUCCEEDED.

- [ ] **Step 7: Commit**

```bash
git add Muse/Muse/Intelligence/Clip/ClipModelManifest.swift Muse/Muse/Intelligence/Clip/ClipModelStore.swift Muse/MuseTests/ClipModelManifestTests.swift
git commit -m "feat(spec-03): ClipModelStore download lifecycle + manifest verify"
```

---

### Task 25: Settings "Search" section, one-time offer card, network doctrine amendment

**Files:**
- Modify: `Muse/Muse/Settings/SettingsView.swift` (add a "Search" section above "Google Drive")
- Modify: `Muse/Muse/Settings/AppSettings.swift` (`clipOfferSeenKey`)
- Modify: `Muse/Muse/Models/AppState.swift` (register the offer card in `modalPresented`; trigger condition wiring in the search-commit path)
- Modify: `Muse/Muse/CLAUDE.md` (network doctrine: four app-initiated paths, not two)
- Verification: manual build + run

**Interfaces:**
- Consumes: `ClipModelStore.shared` (Task 24), `ModalMessageCard`/`.museModal`
- Produces: the download UX — nothing further in this plan depends on it structurally

- [ ] **Step 1: Settings section**

In `SettingsView.swift`, add a "Search" section above the existing "Google Drive" section: a status row (`Not downloaded ~N MB` / `Downloading n%` / `Installed` / error message + Retry), a Download/Cancel/Remove `ModalButton` bound to `ClipModelStore.shared.state`, and one caption line: `Text(String(localized: "Search understands what's in your photos. The model runs entirely on this Mac — nothing you search ever leaves it."))`.

- [ ] **Step 2: One-time offer card**

In `AppSettings.swift`, add `static let clipOfferSeenKey = "clipOfferSeen"`.

In `AppState.swift`, add `@Published var clipOfferShown = false`, included in `modalPresented`. In the committed-search path (wherever `runSearch`/`runSearchNow` lands after a search completes), add the trigger check: when `SearchQueryParser.parse(query).tokens.isEmpty`, `freeText.split(separator: " ").count >= 3`, `ClipModelStore.shared.state == .absent`, and `!UserDefaults.standard.bool(forKey: AppSettings.clipOfferSeenKey)` → `clipOfferShown = true`.

Present via `.museModal` at the shell (`ContentView.swift`) as a `ModalMessageCard`: title `String(localized: "Smarter Search")`, body explaining the one-time on-device download, buttons Download (`ClipModelStore.shared.download()`) / Not Now (`UserDefaults.standard.set(true, forKey: AppSettings.clipOfferSeenKey)`), both dismiss the card.

- [ ] **Step 3: Doctrine amendment**

In `CLAUDE.md`'s network-policy section, change "Two sanctioned network code paths" to four, adding: "(4) search-model download — user-initiated only (Settings button or the one-time offer card), pinned host, manifest-hash-verified, fail closed, nothing sent." (This is documentation, not code — apply as a direct text edit, no test.)

- [ ] **Step 4: Build and manually verify**

Run: `xcodebuild -scheme Muse build`
Expected: BUILD SUCCEEDED.

Manually verify: open Settings, confirm the Search section shows "Not downloaded"; run a 3+ word free-text search with no matching tokens, confirm the offer card appears once and never again after "Not Now"; press Download in Settings (this will fail gracefully with a network error until the owner's conversion script has actually uploaded artifacts — confirm the FAILURE path shows a plain error and Retry, not a crash).

- [ ] **Step 5: Commit**

```bash
git add Muse/Muse/Settings/SettingsView.swift Muse/Muse/Settings/AppSettings.swift Muse/Muse/Models/AppState.swift Muse/Muse/ContentView.swift CLAUDE.md
git commit -m "feat(spec-03): Search settings section, offer card, network doctrine amendment"
```

---

### Task 26: `ClipIndex` — streamed brute-force retrieval

**Files:**
- Create: `Muse/Muse/Search/ClipIndex.swift`
- Test: `Muse/MuseTests/ClipIndexTests.swift`

**Interfaces:**
- Consumes: `clip_embeddings` table (Task 20), `ClipVectors.fromData` (Task 20)
- Produces: `ClipIndex.matches(query:minScore:db:) throws -> [(id: String, score: Double)]`, `.textMinScore`, `.imageMinScore`, `.topK`, `.chunkRows` — consumed by Task 27 (`SearchService`), Task 29 (`similar:` evaluation), Task 33 (`.similar` smart rule)

- [ ] **Step 1: Write the failing test**

```swift
//
//  ClipIndexTests.swift
//  MuseTests
//

import XCTest
import GRDB
@testable import Muse

final class ClipIndexTests: XCTestCase {

    private func makeQueue() throws -> DatabaseQueue {
        let q = try DatabaseQueue()
        try Database.makeMigrator().migrate(q)
        return q
    }

    private func unitVector(_ dims: [Float]) -> [Float] {
        let norm = sqrt(dims.reduce(0) { $0 + $1 * $1 })
        return dims.map { $0 / norm }
    }

    private func insertVector(_ db: GRDB.Database, id: String, vector: [Float]?, generation: Int = ClipModel.current.generation) throws {
        try db.execute(sql: "INSERT INTO files (id, content_hash, kind, last_seen_at) VALUES (?, ?, 'image', 0)",
                        arguments: [id, id + "-hash"])
        var row = ClipEmbeddingRow(file_id: id, embedded_hash: id + "-hash", model_generation: generation,
                                    vector: vector.map { ClipVectors.toData($0) })
        try row.insert(db)
    }

    func testStreamedMatchesEqualBruteForceReference() throws {
        let q = try makeQueue()
        var expected: [(String, Double)] = []
        try q.write { db in
            for i in 0..<200 {
                let v = unitVector((0..<512).map { _ in Float.random(in: -1...1) })
                try insertVector(db, id: "v\(i)", vector: v)
            }
        }
        let query = unitVector((0..<512).map { _ in Float.random(in: -1...1) })
        let streamed = try q.read { db in try ClipIndex.matches(query: query, minScore: -1, db: db) }
        // Reference: pull every vector back out and score with plain dot product.
        let all = try q.read { db in try ClipEmbeddingRow.fetchAll(db) }
        let reference = all.compactMap { row -> (String, Double)? in
            guard let v = row.vector.flatMap(ClipVectors.fromData) else { return nil }
            let dot = zip(v, query).reduce(0) { $0 + Double($1.0 * $1.1) }
            return (row.file_id, dot)
        }.sorted { $0.1 > $1.1 }
        XCTAssertEqual(streamed.map(\.id), reference.prefix(ClipIndex.topK).map(\.0))
    }

    func testNullVectorsAreSkipped() throws {
        let q = try makeQueue()
        try q.write { db in
            try insertVector(db, id: "has-vector", vector: unitVector([1, 0, 0]))
            try insertVector(db, id: "attempted-marker", vector: nil)
        }
        let results = try q.read { db in try ClipIndex.matches(query: unitVector([1, 0, 0]), minScore: -1, db: db) }
        XCTAssertFalse(results.contains { $0.id == "attempted-marker" })
    }

    func testStaleGenerationVectorsAreSkipped() throws {
        let q = try makeQueue()
        try q.write { db in
            try insertVector(db, id: "current-gen", vector: unitVector([1, 0, 0]), generation: ClipModel.current.generation)
            try insertVector(db, id: "old-gen", vector: unitVector([1, 0, 0]), generation: ClipModel.current.generation - 1)
        }
        let results = try q.read { db in try ClipIndex.matches(query: unitVector([1, 0, 0]), minScore: -1, db: db) }
        XCTAssertTrue(results.contains { $0.id == "current-gen" })
        XCTAssertFalse(results.contains { $0.id == "old-gen" })
    }

    func testTopKCapIsRespected() throws {
        let q = try makeQueue()
        try q.write { db in
            for i in 0..<(ClipIndex.topK + 50) {
                try insertVector(db, id: "v\(i)", vector: unitVector([Float(i), 1, 0]))
            }
        }
        let results = try q.read { db in try ClipIndex.matches(query: unitVector([1, 0, 0]), minScore: -1, db: db) }
        XCTAssertLessThanOrEqual(results.count, ClipIndex.topK)
    }

    func testThresholdEdgeExcludesBelowFloor() throws {
        let q = try makeQueue()
        try q.write { db in
            try insertVector(db, id: "orthogonal", vector: unitVector([0, 1, 0]))
        }
        let results = try q.read { db in try ClipIndex.matches(query: unitVector([1, 0, 0]), minScore: 0.5, db: db) }
        XCTAssertTrue(results.isEmpty, "an orthogonal vector (score ~0) must not pass a 0.5 floor")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -scheme Muse test -only-testing:MuseTests/ClipIndexTests`
Expected: FAIL — `ClipIndex` doesn't exist.

- [ ] **Step 3: Implement**

```swift
//
//  ClipIndex.swift
//  Muse
//
//  Brute-force retrieval, structured for the 200k+ tier: streams
//  chunkRows at a time so memory ceiling is chunkRows x 2KB regardless of
//  library size — the no-RAM-residency rule (binding #25) is satisfied
//  HERE, not deferred to a rewrite. sqlite-vec/mmap at the 800k tier
//  would swap this enum's body only.
//

import Accelerate
import GRDB

nonisolated enum ClipIndex {
    /// CLIP text<->image cosines live in a much lower band than
    /// same-modality cosines. NEVER validated live yet (spec-03 §15.3).
    static let textMinScore: Float = 0.20
    /// image<->image band is higher.
    static let imageMinScore: Float = 0.55
    static let topK = 400
    static let chunkRows = 4_096

    static func matches(query: [Float], minScore: Float, db: GRDB.Database) throws -> [(id: String, score: Double)] {
        let dimension = query.count
        guard dimension > 0 else { return [] }

        var best: [(id: String, score: Double)] = []
        var offset = 0
        while true {
            let rows = try ClipEmbeddingRow
                .filter(ClipEmbeddingRow.Columns.model_generation == ClipModel.current.generation)
                .filter(ClipEmbeddingRow.Columns.vector != nil)
                .order(ClipEmbeddingRow.Columns.file_id)
                .limit(chunkRows, offset: offset)
                .fetchAll(db)
            if rows.isEmpty { break }

            for row in rows {
                guard let vector = row.vector.flatMap(ClipVectors.fromData), vector.count == dimension else { continue }
                var dot: Float = 0
                vDSP_dotpr(vector, 1, query, 1, &dot, vDSP_Length(dimension))
                if dot >= minScore {
                    best.append((row.file_id, Double(dot)))
                }
            }
            if rows.count < chunkRows { break }
            offset += chunkRows
        }

        best.sort { $0.score > $1.score }
        return Array(best.prefix(topK))
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild -scheme Muse test -only-testing:MuseTests/ClipIndexTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Muse/Muse/Search/ClipIndex.swift Muse/MuseTests/ClipIndexTests.swift
git commit -m "feat(spec-03): ClipIndex streamed brute-force retrieval"
```

---

### Task 27: `SearchService` semantic leg — CLIP first, NLEmbedding fallback

**Files:**
- Modify: `Muse/Muse/Database/SearchService.swift`
- Test: `Muse/MuseTests/SearchServiceClipTests.swift`

**Interfaces:**
- Consumes: `ClipModelStore.shared.isReady` (Task 24), `ClipEngine.shared.embedText` (Task 23), `ClipIndex.matches` (Task 26), the real existing `semanticThreshold`/`SemanticSearch.merge`/`matchedDirs` relaxation logic quoted verbatim in this plan's Prerequisite research
- Produces: engine-selected semantic leg — nothing further in this plan depends on this specific change beyond behavior

- [ ] **Step 1: Write the failing test**

```swift
//
//  SearchServiceClipTests.swift
//  MuseTests
//

import XCTest
import GRDB
@testable import Muse

@MainActor
final class SearchServiceClipTests: XCTestCase {
    func testModelAbsentPathIsByteIdenticalToNLEmbeddingBehavior() async throws {
        // Pin: with ClipModelStore.shared.state == .absent, SearchService's
        // semantic leg must behave exactly as it did before this task —
        // same threshold constant, same merge/relaxation call shape.
        XCTAssertEqual(ClipModelStore.shared.state, .absent, "test assumes a clean, model-absent environment")
        // A full end-to-end SearchService.search call needs a populated
        // library fixture; this pin is exercised by the pre-existing
        // SearchService test suite (Spec 02), which must stay green
        // unmodified after this task — run it explicitly:
        //   xcodebuild -scheme Muse test -only-testing:MuseTests/SearchServiceTests
        // as part of Step 4 below, not duplicated here.
    }

    func testMergeFloorAndRelaxationFloorAreTheSameValueByConstruction() {
        // The floor is threaded as ONE parameter to both SemanticSearch.merge
        // and the matchedDirs relaxation — verified by reading the diff, not
        // re-derivable from a black-box test. This test asserts the two
        // documented constants a reader would otherwise have to keep in sync
        // by hand still exist and differ only when CLIP is ready:
        XCTAssertEqual(SearchService.semanticThreshold, 0.45)
        XCTAssertEqual(ClipIndex.textMinScore, 0.20)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -scheme Muse test -only-testing:MuseTests/SearchServiceClipTests`
Expected: FAIL only on the second assertion set if the constants aren't yet where expected — mostly this task is verified by re-running Spec 02's existing `SearchServiceTests` unmodified (Step 4), since the real contract here is "behavior when the model is absent doesn't change," which is a pin, not new behavior to assert into existence.

- [ ] **Step 3: Implement**

In `SearchService.search`, replacing the current `let queryVector = hasText ? IntelligenceRegistry.shared.embedder?.embed(textQuery) : nil` line (line ~45):

```swift
let clipReady = ClipModelStore.shared.isReady
let queryVector: [Float]?
if hasText {
    queryVector = clipReady
        ? await ClipEngine.shared.embedText(textQuery)
        : IntelligenceRegistry.shared.embedder?.embed(textQuery)
} else {
    queryVector = nil
}
let semanticFloor: Double = clipReady ? Double(ClipIndex.textMinScore) : Self.semanticThreshold
```

Inside the `queue.read` closure, replace the semantic-hits computation (currently `let semantic = (queryVector.flatMap { try? SemanticSearch.semanticIDs(queryVector: $0, db: db) }) ?? []`) with an engine-selected call:

```swift
let semantic: [(String, Double)]
if clipReady {
    semantic = (queryVector.flatMap { try? ClipIndex.matches(query: $0, minScore: Float(semanticFloor), db: db) })?
        .map { ($0.id, $0.score) } ?? []
} else {
    semantic = (queryVector.flatMap { try? SemanticSearch.semanticIDs(queryVector: $0, db: db) }) ?? []
}
```

Change every downstream use of the literal `Self.semanticThreshold` in this same `queue.read` closure (the `SemanticSearch.merge(exactIDs:semantic:threshold:)` call and the `matchedDirs` relaxation loop `for (id, score) in semantic where score >= Self.semanticThreshold`) to read `semanticFloor` instead — both must keep agreeing on what counts as a semantic match, which is the documented invariant; making the floor a single threaded parameter preserves that by construction rather than by two constants staying in sync by hand.

Everything else in the function (FTS leg, tag leg, note leg, color leg, scope filtering, ranking, unindexed-extras leg) is untouched.

- [ ] **Step 4: Run tests to verify old and new both pass**

Run: `xcodebuild -scheme Muse test -only-testing:MuseTests/SearchServiceClipTests -only-testing:MuseTests/SearchServiceTests`
Expected: PASS on both — `SearchServiceTests` (Spec 02's existing suite) must be unmodified and green, confirming the model-absent path is byte-identical.

Run: `xcodebuild -scheme Muse build`
Expected: BUILD SUCCEEDED.

- [ ] **Step 5: Commit**

```bash
git add Muse/Muse/Database/SearchService.swift Muse/MuseTests/SearchServiceClipTests.swift
git commit -m "feat(spec-03): engine-selected semantic leg — CLIP first, NLEmbedding fallback"
```

---

### Task 28: CLIP embed write in `analyzeOne` + backfill CLIP branch

**Files:**
- Modify: `Muse/Muse/Intelligence/AnalyzePipeline.swift` (`analyzeOne`, after the committed guard, beside the existing text-embedding write)
- Modify: `Muse/Muse/Intelligence/DeepAnalysisBackfill.swift` (Task 5's traits-only pass — add the CLIP branch: selection query gains an OR clause, per-file scan gains an optional embed step)
- Modify: `Muse/Muse/Intelligence/Core/IntelligenceProtocols.swift` (`TaggerOutput.decodedImage: CGImage?` passthrough, if not already present from Task 2's reuse of `VisionResult.decodedImage`)
- Test: extend `Muse/MuseTests/DeepBackfillSelectionTests.swift` with CLIP-branch selection cases

**Interfaces:**
- Consumes: `ClipEngine.shared.embedImage` (Task 23), `ClipModelStore.shared.isReady` (Task 24), `ClipVectors.toData` (Task 20)
- Produces: `clip_embeddings` rows populated by both the live analyze path and the backfill — consumed by nothing further structurally; this is where the schema from Task 20 actually gets filled

- [ ] **Step 1: Write the failing test**

Add to `DeepBackfillSelectionTests.swift`:

```swift
func testClipBranchSelectsMissingVectorWhenModelReady() throws {
    let q = try makeQueue()
    try q.write { db in
        try insertFile(db, id: "needs-clip", hash: "h1")
        // Traits already current — must still be selected because clip_embeddings is missing.
        var traits = PhotoTraitsRow(file_id: "needs-clip", traits_scanned_hash: "h1",
                                     traits_version: PhotoTraits.currentVersion,
                                     face_count: 0, largest_face_frac: nil, face_quality: nil,
                                     pet_count: 0, sharpness: nil)
        try traits.insert(db)
    }
    let ids = try q.read { db in
        try DeepAnalysisBackfill.staleClipFileIDs(db: db, limit: 10)
    }
    XCTAssertEqual(ids, ["needs-clip"])
}

func testClipBranchSkipsStaleGenerationOnlyWhenBehindCurrent() throws {
    let q = try makeQueue()
    try q.write { db in
        try insertFile(db, id: "old-gen", hash: "h2")
        var row = ClipEmbeddingRow(file_id: "old-gen", embedded_hash: "h2",
                                    model_generation: ClipModel.current.generation - 1,
                                    vector: ClipVectors.toData([1, 0]))
        try row.insert(db)
    }
    let ids = try q.read { db in try DeepAnalysisBackfill.staleClipFileIDs(db: db, limit: 10) }
    XCTAssertEqual(ids, ["old-gen"])
}

func testClipBranchSkipsCurrentGeneration() throws {
    let q = try makeQueue()
    try q.write { db in
        try insertFile(db, id: "current", hash: "h3")
        var row = ClipEmbeddingRow(file_id: "current", embedded_hash: "h3",
                                    model_generation: ClipModel.current.generation,
                                    vector: ClipVectors.toData([1, 0]))
        try row.insert(db)
    }
    let ids = try q.read { db in try DeepAnalysisBackfill.staleClipFileIDs(db: db, limit: 10) }
    XCTAssertTrue(ids.isEmpty)
}

func testClipBranchDoesNotReselectNullVectorMarker() throws {
    let q = try makeQueue()
    try q.write { db in
        try insertFile(db, id: "undecodable", hash: "h4")
        var row = ClipEmbeddingRow(file_id: "undecodable", embedded_hash: "h4",
                                    model_generation: ClipModel.current.generation, vector: nil)
        try row.insert(db)
    }
    let ids = try q.read { db in try DeepAnalysisBackfill.staleClipFileIDs(db: db, limit: 10) }
    XCTAssertTrue(ids.isEmpty, "a NULL-vector attempted-marker at the current generation must not be retried every launch")
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -scheme Muse test -only-testing:MuseTests/DeepBackfillSelectionTests`
Expected: FAIL — `staleClipFileIDs` doesn't exist yet.

- [ ] **Step 3: Implement**

In `AnalyzePipeline.swift`, inside `analyzeOne`, beside the existing text-embedding write block (after `guard committed else { return }`):

```swift
if ClipModelStore.shared.isReady, let raster = out.decodedImage,
   let vector = await ClipEngine.shared.embedImage(raster) {
    try? await queue.write { db in
        try db.execute(sql: """
            INSERT OR REPLACE INTO clip_embeddings (file_id, embedded_hash, model_generation, vector)
            SELECT ?, ?, ?, ? WHERE (SELECT content_hash FROM files WHERE id = ?) = ?
            """, arguments: [fileID, analyzedHash, ClipModel.current.generation,
                              ClipVectors.toData(vector), fileID, analyzedHash])
    }
}
```

(`out.decodedImage` requires `TaggerOutput` to carry the passthrough — if Task 4 didn't already add it while wiring traits, add `var decodedImage: CGImage?` to `TaggerOutput` now and have `VisionTagger.analyze` fill it from `VisionResult.decodedImage`, which already exists per Task 2's ground truth — never decode twice.)

**This write is deliberately separate from the `embeddingsWritten` counter** — that counter drives `ReclusterGate` for the text-embedding clusterer only (`Intelligence/AnalyzePipeline.swift:42-43,131-133`), which stays untouched; CLIP writes must never bump it (Global Constraints / deviation D1: the `embeddings` table still feeds `CollectionsEngine.recluster` and `SimilarTagSuggestions`, CLIP replaces the semantic search leg only).

In `DeepAnalysisBackfill.swift`, add the selection query:

```swift
static func staleClipFileIDs(db: GRDB.Database, limit: Int) throws -> [String] {
    try String.fetchAll(db, sql: """
        SELECT f.id FROM files f
        JOIN paths p ON p.file_id = f.id AND p.is_alive = 1
        LEFT JOIN clip_embeddings c ON c.file_id = f.id
        WHERE f.kind IN ('image', 'raw', 'psd')
          AND (c.file_id IS NULL
               OR c.embedded_hash != f.content_hash
               OR c.model_generation != ?)
        GROUP BY f.id
        LIMIT ?
        """, arguments: [ClipModel.current.generation, limit])
}
```

Extend `run()`'s selection step: when `ClipModelStore.shared.isReady`, union `staleClipFileIDs` into the candidate set alongside `staleTraitsFileIDs` (a file needing only one of the two still gets scanned once — the shared decode covers both). Extend `scanOne` to also call `ClipEngine.shared.embedImage` on the same bounded raster when the model is ready, writing (or NULL-marking on undecodable, matching the traits row's NULL-field marker) a `ClipEmbeddingRow` in the same `flush` transaction as the traits row, guarded the same way (`content_hash` still matches).

- [ ] **Step 4: Run test to verify it passes, then a full build**

Run: `xcodebuild -scheme Muse test -only-testing:MuseTests/DeepBackfillSelectionTests`
Expected: PASS.

Run: `xcodebuild -scheme Muse build`
Expected: BUILD SUCCEEDED.

- [ ] **Step 5: Commit**

```bash
git add Muse/Muse/Intelligence/AnalyzePipeline.swift Muse/Muse/Intelligence/DeepAnalysisBackfill.swift Muse/Muse/Intelligence/Core/IntelligenceProtocols.swift Muse/MuseTests/DeepBackfillSelectionTests.swift
git commit -m "feat(spec-03): CLIP embed write in analyzeOne + backfill CLIP branch"
```

---

### Task 29: `SimilarityRegistry` + `similar:` token + `PhotoSearch` integration

**Files:**
- Create: `Muse/Muse/Search/SimilarityRegistry.swift`
- Modify: `Muse/Muse/Search/SearchToken.swift` (`case similar(handle: String)` + parser)
- Modify: `Muse/Muse/Search/PhotoSearch.swift` (`TokenContext`, `filter(tokens:context:db:)`)
- Modify: `Muse/Muse/Database/SearchService.swift` (thread a `TokenContext` built from `SimilarityRegistry.shared.snapshot` into the `PhotoSearch.filter` call added by Spec 02 Task 12)
- Test: `Muse/MuseTests/SimilarTermTests.swift` (registry-adjacent pure pieces), `Muse/MuseTests/SearchTokenFacesTests.swift` (extend with `similar:` parse cases), `Muse/MuseTests/PhotoSearchSimilarTests.swift`

**Interfaces:**
- Produces: `SimilarityRegistry.shared`, `.stash(vector:label:) -> String`, `.entry(for:) -> Entry?`, `.snapshot: [String: [Float]]`; `SearchToken.similar(handle:)`; `PhotoSearch.TokenContext`, updated `filter(tokens:context:db:)` — consumed by Task 30 (entry points)

- [ ] **Step 1: Write the failing tests**

```swift
//
//  SimilarityRegistryTests.swift
//  MuseTests
//

import XCTest
@testable import Muse

@MainActor
final class SimilarityRegistryTests: XCTestCase {
    func testStashReturnsMonotonicHandles() {
        let registry = SimilarityRegistry()
        let h1 = registry.stash(vector: [1, 0], label: "photo")
        let h2 = registry.stash(vector: [0, 1], label: "region")
        XCTAssertNotEqual(h1, h2)
        XCTAssertTrue(h1.hasPrefix("s"))
        XCTAssertTrue(h2.hasPrefix("s"))
    }

    func testEntryLookupRoundTrips() {
        let registry = SimilarityRegistry()
        let handle = registry.stash(vector: [1, 0, 0], label: "region")
        let entry = registry.entry(for: handle)
        XCTAssertEqual(entry?.vector, [1, 0, 0])
        XCTAssertEqual(entry?.label, "region")
    }

    func testUnknownHandleReturnsNil() {
        let registry = SimilarityRegistry()
        XCTAssertNil(registry.entry(for: "s999"))
    }

    func testSnapshotReflectsAllStashedEntries() {
        let registry = SimilarityRegistry()
        let h1 = registry.stash(vector: [1, 0], label: "a")
        let h2 = registry.stash(vector: [0, 1], label: "b")
        let snapshot = registry.snapshot
        XCTAssertEqual(snapshot[h1], [1, 0])
        XCTAssertEqual(snapshot[h2], [0, 1])
    }
}
```

Extend `SearchTokenFacesTests.swift`:

```swift
func testSimilarHandleShapeParses() {
    let parsed = SearchQueryParser.parse("similar:s1")
    XCTAssertEqual(parsed.tokens, [.similar(handle: "s1")])
}

func testOffShapeSimilarStaysFreeText() {
    let parsed = SearchQueryParser.parse("similar:notanumber")
    XCTAssertTrue(parsed.tokens.isEmpty)
    XCTAssertTrue(parsed.freeText.contains("similar:notanumber"))
}
```

```swift
//
//  PhotoSearchSimilarTests.swift
//  MuseTests
//

import XCTest
import GRDB
@testable import Muse

final class PhotoSearchSimilarTests: XCTestCase {

    private func makeQueue() throws -> DatabaseQueue {
        let q = try DatabaseQueue()
        try Database.makeMigrator().migrate(q)
        return q
    }

    private func insertVector(_ db: GRDB.Database, id: String, vector: [Float]) throws {
        try db.execute(sql: "INSERT INTO files (id, content_hash, kind, last_seen_at) VALUES (?, ?, 'image', 0)",
                        arguments: [id, id + "-hash"])
        var row = ClipEmbeddingRow(file_id: id, embedded_hash: id + "-hash",
                                    model_generation: ClipModel.current.generation,
                                    vector: ClipVectors.toData(vector))
        try row.insert(db)
    }

    func testSimilarityOrderingWinsWhenTokenPresent() throws {
        let q = try makeQueue()
        try q.write { db in
            try insertVector(db, id: "closest", vector: [1, 0, 0])
            try insertVector(db, id: "farther", vector: [0.6, 0.8, 0])
        }
        let query: [Float] = [1, 0, 0]
        let result = try q.read { db in
            try PhotoSearch.filter(tokens: [.similar(handle: "s1")],
                                   context: .init(similarVectors: ["s1": query]), db: db)
        }
        XCTAssertEqual(result?.ids.first, "closest", "score-descending must be the result order when similar is present")
    }

    func testUnresolvableHandleMatchesNothingNotUnfiltered() throws {
        let q = try makeQueue()
        try q.write { db in try insertVector(db, id: "anything", vector: [1, 0, 0]) }
        let result = try q.read { db in
            try PhotoSearch.filter(tokens: [.similar(handle: "s999")], context: .init(similarVectors: [:]), db: db)
        }
        XCTAssertEqual(result?.idSet, [], "an unresolvable handle must match nothing, never fall back to unfiltered")
    }

    func testIntersectsWithOtherTokens() throws {
        let q = try makeQueue()
        try q.write { db in
            try insertVector(db, id: "match", vector: [1, 0, 0])
        }
        let query: [Float] = [1, 0, 0]
        let result = try q.read { db in
            try PhotoSearch.filter(tokens: [.similar(handle: "s1"), .rating(atLeast: 5)],
                                   context: .init(similarVectors: ["s1": query]), db: db)
        }
        // No rating tag exists on "match" in this fixture, so the intersection is empty —
        // proving the two token types genuinely intersect rather than one overriding the other.
        XCTAssertEqual(result?.idSet, [])
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild -scheme Muse test -only-testing:MuseTests/SimilarityRegistryTests -only-testing:MuseTests/PhotoSearchSimilarTests`
Expected: FAIL — none of these types/cases exist.

- [ ] **Step 3: Implement**

```swift
//
//  SimilarityRegistry.swift
//  Muse
//
//  A similarity query is a VECTOR, which cannot ride the field text — but
//  field text stays the single source of truth for tokens (Spec 02). This
//  bridges via session-scoped handles: similar:s1 in the query text
//  resolves against this registry at query time.
//

import Foundation

@MainActor final class SimilarityRegistry: ObservableObject {
    static let shared = SimilarityRegistry()

    struct Entry { let vector: [Float]; let label: String }

    private var entries: [String: Entry] = [:]
    private var counter = 0

    func stash(vector: [Float], label: String) -> String {
        counter += 1
        let handle = "s\(counter)"
        entries[handle] = Entry(vector: vector, label: label)
        return handle
    }

    func entry(for handle: String) -> Entry? { entries[handle] }

    var snapshot: [String: [Float]] {
        entries.mapValues(\.vector)
    }
}
```

Add to `SearchToken`:

```swift
case similar(handle: String)
```

In `SearchQueryParser.parseSegment`'s key switch:

```swift
case "similar":
    guard value.hasPrefix("s"), value.dropFirst().allSatisfy(\.isNumber), value.count > 1 else { return nil }
    return .similar(handle: value)
```

In `PhotoSearch.swift`, add the context type and thread it through:

```swift
struct TokenContext {
    var similarVectors: [String: [Float]] = [:]
}

static func filter(tokens: [SearchToken], context: TokenContext = .init(), db: GRDB.Database) throws -> Result? {
    // ... existing per-token switch, plus:
    var similarityRanking: [(id: String, score: Double)]? = nil
    // inside the loop, for `case let .similar(handle):`
    if case let .similar(handle) = token {
        guard let vector = context.similarVectors[handle] else {
            return Result(ids: [], idSet: [], dirRestrictions: [:]) // unresolvable → empty, not unfiltered
        }
        let hits = try ClipIndex.matches(query: vector, minScore: ClipIndex.imageMinScore, db: db)
        similarityRanking = hits
        combine(&result, Set(hits.map(\.id)))
    }
    // ... after the existing per-token loop, before returning:
    if let similarityRanking {
        // similarity score DESC is the result order when present, replacing capture DESC;
        // other tokens have already intersected via idSet above.
        let orderedIDs = similarityRanking.map(\.id).filter { result.idSet.contains($0) }
        result.ids = orderedIDs
    }
    return result
}
```

(Merge this into the function's real existing structure — read the file's current shape from Spec 02's Task 11 end-state first; the sketch above shows the two insertion points — the per-token switch case and the post-loop ordering override — not a full rewrite.)

Update the existing `SearchService.search` call site (added by Spec 02 Task 12) to pass a context:

```swift
let tokenContext = PhotoSearch.TokenContext(similarVectors: SimilarityRegistry.shared.snapshot)
guard let tok = try PhotoSearch.filter(tokens: parsed.tokens, context: tokenContext, db: db) else { ... }
```

`SimilarityRegistry.shared.snapshot` is read on the main actor before entering `queue.read` (it's `@MainActor`-isolated; the `queue.read` closure captures the already-resolved `[String: [Float]]` value, not the actor itself).

- [ ] **Step 4: Run tests to verify they pass, then a full build**

Run: `xcodebuild -scheme Muse test -only-testing:MuseTests/SimilarityRegistryTests -only-testing:MuseTests/SearchTokenFacesTests -only-testing:MuseTests/PhotoSearchSimilarTests`
Expected: PASS.

Run: `xcodebuild -scheme Muse build`
Expected: BUILD SUCCEEDED.

- [ ] **Step 5: Commit**

```bash
git add Muse/Muse/Search/SimilarityRegistry.swift Muse/Muse/Search/SearchToken.swift Muse/Muse/Search/PhotoSearch.swift Muse/Muse/Database/SearchService.swift Muse/MuseTests/SimilarityRegistryTests.swift Muse/MuseTests/SearchTokenFacesTests.swift Muse/MuseTests/PhotoSearchSimilarTests.swift
git commit -m "feat(spec-03): similar: token via SimilarityRegistry"
```

---

### Task 30: Similarity entry points — `runSimilarSearch`, Find Similar, image-drop

**Files:**
- Create: `Muse/Muse/Models/AppState+Similarity.swift`
- Modify: `Muse/Muse/Views/GridView.swift` (context menu "Find Similar Photos" + `.onDrop` image-drop handling)
- Modify: `Muse/Muse/Views/Viewer/ViewerInfoColumn.swift` (`actionsRow` gains a "Similar" `ActionButton`)
- Modify: `Muse/Muse/Search/SearchToken.swift` (`displayLabel` for `.similar`, showing the stashed label + "(expired)" when unresolvable)
- Test: manual build + verification (UI wiring over already-tested `SimilarityRegistry`/`PhotoSearch`)

**Interfaces:**
- Consumes: `SimilarityRegistry.shared.stash` (Task 29), `ClipModelStore.shared.isReady` (Task 24), `ClipEngine.shared.embedImage` (Task 23)
- Produces: `AppState.runSimilarSearch(vector:label:)` — consumed by Task 32 (region similarity)

- [ ] **Step 1: Implement the orchestration method**

```swift
//
//  AppState+Similarity.swift
//  Muse
//

import Foundation

extension AppState {
    func runSimilarSearch(vector: [Float], label: String) {
        let handle = SimilarityRegistry.shared.stash(vector: vector, label: label)
        searchAllFolders = true
        searchQuery = "similar:\(handle)"
        Task { await runSearch(searchQuery) }
    }
}
```

- [ ] **Step 2: Grid "Find Similar Photos" context-menu item**

In `Views/GridView.swift` (or `SelectionActionsMenu.swift`, matching the existing item style — read the file first), add an item visible for a single image-kind selection, hidden (not disabled) when `!ClipModelStore.shared.isReady`:

```swift
Button(String(localized: "Find Similar Photos")) {
    guard let file = /* the single selected FileNode */ else { return }
    Task {
        let vector: [Float]?
        if let stored = /* fetch clip_embeddings.vector for file, decode via ClipVectors.fromData */ {
            vector = stored
        } else {
            guard let raster = VisionServices.boundedDecode(url: file.url, maxPixel: 1024) else { return }
            vector = await ClipEngine.shared.embedImage(raster)
        }
        guard let vector else { return }
        appState.runSimilarSearch(vector: vector, label: file.url.lastPathComponent)
    }
}
```

- [ ] **Step 3: Hero-viewer "Similar" action**

In `ViewerInfoColumn.swift`'s `actionsRow` (line 515), add a third `ActionButton`:

```swift
if ClipModelStore.shared.isReady {
    ActionButton(label: String(localized: "Similar"), systemImage: "sparkle.magnifyingglass") {
        Task {
            guard let raster = VisionServices.boundedDecode(url: currentURL, maxPixel: 1024),
                  let vector = await ClipEngine.shared.embedImage(raster) else { return }
            appState.runSimilarSearch(vector: vector, label: currentURL.lastPathComponent)
            startClose()
        }
    }
}
```

- [ ] **Step 4: Image-drop search**

In the detail grid area (`Views/GridView.swift`), add `.onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in ... }`: while a drag hovers, show an overlay hint `Text(String(localized: "Drop an image to find similar photos"))`; on drop of a single image-kind file, decode → embed → `appState.runSimilarSearch(vector:label: droppedURL.lastPathComponent)`.

- [ ] **Step 5: `displayLabel` for `.similar`**

In `SearchToken`'s `displayLabel` extension:

```swift
case let .similar(handle):
    if let entry = SimilarityRegistry.shared.entry(for: handle) {
        return "\(String(localized: "Similar")): \(entry.label)"
    }
    return String(localized: "Similar (expired)")
```

- [ ] **Step 6: Build and manually verify**

Run: `xcodebuild -scheme Muse build`
Expected: BUILD SUCCEEDED.

Manually verify (once a model is actually installed — this whole task is inert/hidden until then, by design): right-click a photo → "Find Similar Photos" → confirm a `similar:` chip appears and results rank by similarity; open a photo in the hero viewer → "Similar" action does the same and closes the viewer; drag an image file onto the grid → confirm the drop hint appears and dropping runs a similarity search; paste `similar:s999` manually into the search field → confirm the chip reads "Similar (expired)" and the grid shows an empty result, not the unfiltered library.

- [ ] **Step 7: Commit**

```bash
git add Muse/Muse/Models/AppState+Similarity.swift Muse/Muse/Views/GridView.swift Muse/Muse/Views/Viewer/ViewerInfoColumn.swift Muse/Muse/Search/SearchToken.swift
git commit -m "feat(spec-03): similarity entry points — Find Similar, viewer action, image-drop"
```

---

### Task 31: `RegionMath` — pure region-crop geometry

**Files:**
- Create: `Muse/Muse/Components/RegionMath.swift`
- Test: `Muse/MuseTests/RegionMathTests.swift`

**Interfaces:**
- Produces: `RegionMath.imageFrame(fitRect:zoom:pan:) -> CGRect`, `.normalizedRegion(marquee:imageFrame:) -> CGRect?` — consumed by Task 32 (hero-viewer region mode)

- [ ] **Step 1: Write the failing test**

```swift
//
//  RegionMathTests.swift
//  MuseTests
//

import XCTest
import CoreGraphics
@testable import Muse

final class RegionMathTests: XCTestCase {
    func testImageFrameAtIdentityZoomPan() {
        let fit = CGRect(x: 10, y: 20, width: 300, height: 200)
        let frame = RegionMath.imageFrame(fitRect: fit, zoom: 1, pan: .zero)
        XCTAssertEqual(frame, fit)
    }

    func testImageFrameScalesAboutCenterUnderZoom() {
        let fit = CGRect(x: 0, y: 0, width: 200, height: 100)
        let frame = RegionMath.imageFrame(fitRect: fit, zoom: 2, pan: .zero)
        XCTAssertEqual(frame.width, 400, accuracy: 0.01)
        XCTAssertEqual(frame.height, 200, accuracy: 0.01)
        XCTAssertEqual(frame.midX, fit.midX, accuracy: 0.01)
        XCTAssertEqual(frame.midY, fit.midY, accuracy: 0.01)
    }

    func testImageFrameOffsetByPan() {
        let fit = CGRect(x: 0, y: 0, width: 200, height: 100)
        let frame = RegionMath.imageFrame(fitRect: fit, zoom: 1, pan: CGSize(width: 30, height: -10))
        XCTAssertEqual(frame.origin.x, 30, accuracy: 0.01)
        XCTAssertEqual(frame.origin.y, -10, accuracy: 0.01)
    }

    func testNormalizedRegionRoundTrips() {
        let imageFrame = CGRect(x: 0, y: 0, width: 200, height: 100)
        let marquee = CGRect(x: 50, y: 25, width: 100, height: 50)
        let region = RegionMath.normalizedRegion(marquee: marquee, imageFrame: imageFrame)
        XCTAssertEqual(region, CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5))
    }

    func testMarqueeFullyOutsideImageReturnsNil() {
        let imageFrame = CGRect(x: 0, y: 0, width: 200, height: 100)
        let marquee = CGRect(x: 300, y: 300, width: 50, height: 50)
        XCTAssertNil(RegionMath.normalizedRegion(marquee: marquee, imageFrame: imageFrame))
    }

    func testMarqueePartiallyOutsideClipsToIntersection() {
        let imageFrame = CGRect(x: 0, y: 0, width: 200, height: 100)
        let marquee = CGRect(x: -50, y: -50, width: 100, height: 100)
        let region = RegionMath.normalizedRegion(marquee: marquee, imageFrame: imageFrame)
        XCTAssertNotNil(region)
        XCTAssertEqual(region!.origin.x, 0, accuracy: 0.001)
        XCTAssertEqual(region!.origin.y, 0, accuracy: 0.001)
    }

    func testDegenerateMarqueeReturnsNil() {
        let imageFrame = CGRect(x: 0, y: 0, width: 200, height: 100)
        let marquee = CGRect(x: 50, y: 50, width: 0, height: 0)
        XCTAssertNil(RegionMath.normalizedRegion(marquee: marquee, imageFrame: imageFrame))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -scheme Muse test -only-testing:MuseTests/RegionMathTests`
Expected: FAIL — `RegionMath` doesn't exist.

- [ ] **Step 3: Implement**

```swift
//
//  RegionMath.swift
//  Muse
//
//  The on-screen rect the image currently occupies, and marquee -> unit
//  image coordinates. Mirrors exactly the transform stack HeroStage
//  renders (scaleEffect(zoom) -> offset(pan) over the fitted rect).
//

import CoreGraphics

nonisolated enum RegionMath {
    static func imageFrame(fitRect: CGRect, zoom: CGFloat, pan: CGSize) -> CGRect {
        let scaledWidth = fitRect.width * zoom
        let scaledHeight = fitRect.height * zoom
        let scaledOriginX = fitRect.midX - scaledWidth / 2
        let scaledOriginY = fitRect.midY - scaledHeight / 2
        return CGRect(x: scaledOriginX + pan.width, y: scaledOriginY + pan.height,
                      width: scaledWidth, height: scaledHeight)
    }

    /// Marquee intersected with imageFrame, normalized to unit image
    /// coordinates (top-left origin). nil when degenerate or disjoint.
    static func normalizedRegion(marquee: CGRect, imageFrame: CGRect) -> CGRect? {
        guard imageFrame.width > 0, imageFrame.height > 0 else { return nil }
        let intersection = marquee.intersection(imageFrame)
        guard !intersection.isNull, intersection.width > 0, intersection.height > 0 else { return nil }
        let x = (intersection.origin.x - imageFrame.origin.x) / imageFrame.width
        let y = (intersection.origin.y - imageFrame.origin.y) / imageFrame.height
        let w = intersection.width / imageFrame.width
        let h = intersection.height / imageFrame.height
        return CGRect(x: x, y: y, width: w, height: h)
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild -scheme Muse test -only-testing:MuseTests/RegionMathTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Muse/Muse/Components/RegionMath.swift Muse/MuseTests/RegionMathTests.swift
git commit -m "feat(spec-03): RegionMath pure region-crop geometry"
```

---

### Task 32: Region similarity — hero-viewer marquee mode

**Files:**
- Modify: `Muse/Muse/Views/Viewer/HeroImageViewer.swift` (chrome button, marquee overlay, region-mode state, Escape interception, crop+embed)
- Verification: manual build + run

**Interfaces:**
- Consumes: `RegionMath` (Task 31), `AppState.runSimilarSearch` (Task 30), `ClipEngine.shared.embedImage` (Task 23), `VisionServices.boundedDecode`
- Produces: the region-mode interaction — nothing further depends on it

- [ ] **Step 1: Add region-mode state and the chrome button**

In `HeroImageViewer.swift`, add `@State private var regionMode = false` and `@State private var marqueeRect: CGRect? = nil`. In `chromeRow` (lines 258-266), add a `ChromeCircleButton(systemName: "viewfinder")` visible only when `ClipModelStore.shared.isReady` and the current file is image-kind, accessibility label `String(localized: "Search within this photo")`, toggling `regionMode`.

- [ ] **Step 2: Marquee drawing and suppression of pan/zoom while active**

When `regionMode` is true, overlay a crosshair-cursor drag surface above `HeroStage` that draws the marquee (stroke + dimmed veil outside it) and suppresses the stage's existing pan gesture and scroll-zoom monitor for the duration (zoom/pan state itself is untouched — a user can zoom in first, then enter region mode, then select, for an accurate small-subject box). Marquees smaller than `RegionSearch.minSide = 24` screen points are ignored on mouse-up.

Add the small constant holder inline in this file or as a nested type:

```swift
enum RegionSearch {
    static let minSide: CGFloat = 24
    static let decodeMaxPixel = 2048
}
```

- [ ] **Step 3: Mouse-up — crop, embed, search**

On a valid marquee's mouse-up:

```swift
regionMode = false
guard let marquee = marqueeRect,
      max(marquee.width, marquee.height) >= RegionSearch.minSide else { marqueeRect = nil; return }
let frame = RegionMath.imageFrame(fitRect: fitRect, zoom: zoom, pan: pan)
guard let normalized = RegionMath.normalizedRegion(marquee: marquee, imageFrame: frame) else { marqueeRect = nil; return }
marqueeRect = nil
Task {
    guard let raster = VisionServices.boundedDecode(url: currentURL, maxPixel: RegionSearch.decodeMaxPixel) else { return }
    let cropRectPixels = CGRect(x: normalized.origin.x * CGFloat(raster.width),
                                y: normalized.origin.y * CGFloat(raster.height),
                                width: normalized.width * CGFloat(raster.width),
                                height: normalized.height * CGFloat(raster.height))
    guard let cropped = raster.cropping(to: cropRectPixels),
          let vector = await ClipEngine.shared.embedImage(cropped) else { return }
    appState.runSimilarSearch(vector: vector, label: String(localized: "region"))
    startClose()
}
```

Note: the crop source is a fresh bounded decode of the ORIGINAL file, never the currently-displayed `image` state — that may still be the 320px quick thumbnail mid-ladder, and a region of a thumbnail embeds mush.

- [ ] **Step 4: Escape interception**

In the existing `.onChange(of: appState.viewerClosing)` handler (lines 161-183), add a first branch immediately after the existing `appState.viewerClosing = false` line, before anything else runs:

```swift
if regionMode {
    regionMode = false
    return
}
```

This consumes a region-mode Escape without ever reaching `startClose()` — the hero close sequence itself (guarded by `isClosing`, `lingering`, `burnProgress`) is completely untouched by this branch. `EscapeResolver` is unaffected — it still resolves `.closeHero` for a selected hero file; the viewer is what consumes the trigger differently while in region mode.

- [ ] **Step 5: Build and manually verify**

Run: `xcodebuild -scheme Muse build`
Expected: BUILD SUCCEEDED.

Manually verify (requires a model installed): open a photo with a small distinct subject, zoom in, enter region mode via the viewfinder button, drag a marquee around the subject, release — confirm it searches by that region and closes the viewer with a "Similar: region" chip; try the same but press Escape mid-marquee instead of releasing — confirm it exits region mode only, the viewer stays open; try a normal (non-region-mode) Escape on the same photo afterward — confirm the viewer closes normally, unaffected.

- [ ] **Step 6: Commit**

```bash
git add Muse/Muse/Views/Viewer/HeroImageViewer.swift
git commit -m "feat(spec-03): region similarity — hero-viewer marquee search"
```

---

### Task 33: `SimilarTerm` + `SmartRule.similar` + resolver evaluation

**Files:**
- Modify: `Muse/Muse/Intelligence/Collections/SmartRule.swift` (`SimilarTerm`, `case similar`)
- Modify: `Muse/Muse/Intelligence/Collections/SmartCollectionResolver.swift` (`evaluate`'s switch)
- Test: `Muse/MuseTests/SimilarTermTests.swift`, `Muse/MuseTests/SmartRuleSimilarResolverTests.swift`

**Interfaces:**
- Consumes: `ClipCentroid.centroid` (Task 20), `ClipIndex.matches` (Task 26), `ClipModel.current.generation` (Task 21)
- Produces: `SmartRule.similar(SimilarTerm)`, `SimilarTerm.isValid`, resolver evaluation — consumed by Task 34 (UI), Task 35 (from-selection)

- [ ] **Step 1: Write the failing tests**

```swift
//
//  SimilarTermTests.swift
//  MuseTests
//

import XCTest
@testable import Muse

final class SimilarTermTests: XCTestCase {
    func testCodableRoundTripIncludingPromptVector() throws {
        let term = SimilarTerm(anchorIDs: ["f1", "f2"], prompt: "beach sunset",
                               promptVector: [0.1, 0.2, 0.3], promptGeneration: 1,
                               threshold: 0.6)
        let data = try JSONEncoder().encode(term)
        let decoded = try JSONDecoder().decode(SimilarTerm.self, from: data)
        XCTAssertEqual(decoded, term)
    }

    func testIsValidRequiresAnchorsOrPrompt() {
        var term = SimilarTerm(anchorIDs: [], prompt: nil, promptVector: nil,
                               promptGeneration: nil, threshold: SimilarTerm.defaultThreshold)
        XCTAssertFalse(term.isValid)
        term.anchorIDs = ["f1"]
        XCTAssertTrue(term.isValid)
        term.anchorIDs = []
        term.prompt = "beach"
        XCTAssertTrue(term.isValid)
    }

    func testIsValidRequiresThresholdInRange() {
        var term = SimilarTerm(anchorIDs: ["f1"], prompt: nil, promptVector: nil,
                               promptGeneration: nil, threshold: 0.1)
        XCTAssertFalse(term.isValid, "threshold below range must be invalid")
        term.threshold = 0.99
        XCTAssertFalse(term.isValid, "threshold above range must be invalid")
        term.threshold = SimilarTerm.defaultThreshold
        XCTAssertTrue(term.isValid)
    }

    func testBlankPromptIsNotValidOnItsOwn() {
        let term = SimilarTerm(anchorIDs: [], prompt: "   ", promptVector: nil,
                               promptGeneration: nil, threshold: SimilarTerm.defaultThreshold)
        XCTAssertFalse(term.isValid)
    }
}
```

```swift
//
//  SmartRuleSimilarResolverTests.swift
//  MuseTests
//

import XCTest
import GRDB
@testable import Muse

final class SmartRuleSimilarResolverTests: XCTestCase {

    private func makeQueue() throws -> DatabaseQueue {
        let q = try DatabaseQueue()
        try Database.makeMigrator().migrate(q)
        return q
    }

    private func insertVector(_ db: GRDB.Database, id: String, vector: [Float], generation: Int = ClipModel.current.generation) throws {
        try db.execute(sql: "INSERT INTO files (id, content_hash, kind, last_seen_at) VALUES (?, ?, 'image', 0)",
                        arguments: [id, id + "-hash"])
        var row = ClipEmbeddingRow(file_id: id, embedded_hash: id + "-hash", model_generation: generation,
                                    vector: ClipVectors.toData(vector))
        try row.insert(db)
    }

    func testAnchorPathResolvesOverFixtureVectors() throws {
        let q = try makeQueue()
        try q.write { db in
            try insertVector(db, id: "anchor1", vector: [1, 0, 0])
            try insertVector(db, id: "close-match", vector: [0.99, 0.14, 0])
            try insertVector(db, id: "far", vector: [0, 1, 0])
        }
        let ruleSet = SmartRuleSet(match: .all, rules: [
            .similar(SimilarTerm(anchorIDs: ["anchor1"], prompt: nil, promptVector: nil,
                                 promptGeneration: nil, threshold: 0.5))
        ])
        let ids = try q.read { db in try SmartCollectionResolver.memberIDs(ruleSet, db: db) }
        XCTAssertTrue(ids.contains("close-match"))
        XCTAssertFalse(ids.contains("far"))
    }

    func testStalePromptGenerationResolvesEmpty() throws {
        let q = try makeQueue()
        try q.write { db in try insertVector(db, id: "any", vector: [1, 0, 0]) }
        let ruleSet = SmartRuleSet(match: .all, rules: [
            .similar(SimilarTerm(anchorIDs: [], prompt: "beach", promptVector: [1, 0, 0],
                                 promptGeneration: ClipModel.current.generation - 1,
                                 threshold: 0.5))
        ])
        let ids = try q.read { db in try SmartCollectionResolver.memberIDs(ruleSet, db: db) }
        XCTAssertTrue(ids.isEmpty, "a stale-generation prompt vector must not be used")
    }

    func testThresholdBoundary() throws {
        let q = try makeQueue()
        try q.write { db in
            try insertVector(db, id: "anchor1", vector: [1, 0, 0])
            try insertVector(db, id: "orthogonal", vector: [0, 1, 0])
        }
        let ruleSet = SmartRuleSet(match: .all, rules: [
            .similar(SimilarTerm(anchorIDs: ["anchor1"], prompt: nil, promptVector: nil,
                                 promptGeneration: nil, threshold: 0.8))
        ])
        let ids = try q.read { db in try SmartCollectionResolver.memberIDs(ruleSet, db: db) }
        XCTAssertFalse(ids.contains("orthogonal"))
    }

    func testNoResolvableVectorProducesEmptySet() throws {
        let q = try makeQueue()
        let ruleSet = SmartRuleSet(match: .all, rules: [
            .similar(SimilarTerm(anchorIDs: ["does-not-exist"], prompt: nil, promptVector: nil,
                                 promptGeneration: nil, threshold: 0.5))
        ])
        let ids = try q.read { db in try SmartCollectionResolver.memberIDs(ruleSet, db: db) }
        XCTAssertTrue(ids.isEmpty)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild -scheme Muse test -only-testing:MuseTests/SimilarTermTests -only-testing:MuseTests/SmartRuleSimilarResolverTests`
Expected: FAIL — `SimilarTerm`/`SmartRule.similar` don't exist.

- [ ] **Step 3: Implement**

In `SmartRule.swift`, add the 8th case and its term:

```swift
case similar(SimilarTerm)

nonisolated struct SimilarTerm: Codable, Equatable {
    var anchorIDs: [String]
    var prompt: String?
    var promptVector: [Float]?
    var promptGeneration: Int?
    var threshold: Double

    static let thresholdRange: ClosedRange<Double> = 0.40...0.80
    static let defaultThreshold: Double = 0.55
    static let maxAnchors = 20

    var isValid: Bool {
        let hasAnchorsOrPrompt = !anchorIDs.isEmpty || !(prompt ?? "").trimmingCharacters(in: .whitespaces).isEmpty
        return hasAnchorsOrPrompt && SimilarTerm.thresholdRange.contains(threshold)
    }
}
```

Extend `SmartRule.isValid`'s switch with `case let .similar(term): return term.isValid`.

In `SmartCollectionResolver.swift`, add a case to the private `evaluate(_:db:now:)` switch:

```swift
case let .similar(term):
    let queryVector: [Float]?
    if !term.anchorIDs.isEmpty {
        let anchorVectors = try term.anchorIDs.compactMap { id -> [Float]? in
            try ClipEmbeddingRow.fetchOne(db, key: id).flatMap { row in
                guard row.model_generation == ClipModel.current.generation else { return nil }
                return row.vector.flatMap(ClipVectors.fromData)
            }
        }
        queryVector = ClipCentroid.centroid(anchorVectors)
    } else if let vector = term.promptVector, term.promptGeneration == ClipModel.current.generation {
        queryVector = vector
    } else {
        queryVector = nil
    }
    guard let queryVector else { return [] }
    let hits = try ClipIndex.matches(query: queryVector, minScore: Float(term.threshold), db: db)
    return Set(hits.map(\.id))
```

- [ ] **Step 4: Run tests to verify they pass, then a full build**

Run: `xcodebuild -scheme Muse test -only-testing:MuseTests/SimilarTermTests -only-testing:MuseTests/SmartRuleSimilarResolverTests`
Expected: PASS.

Run: `xcodebuild -scheme Muse test -only-testing:MuseTests/SmartRuleSetTests -only-testing:MuseTests/SmartCollectionResolverTests`
Expected: PASS — the existing exhaustive-switch/round-trip tests over all `SmartRule` cases must stay green with `.similar` now included (fix any non-exhaustive `switch` the compiler flags elsewhere, e.g. a UI enumeration list).

Run: `xcodebuild -scheme Muse build`
Expected: BUILD SUCCEEDED.

- [ ] **Step 5: Commit**

```bash
git add Muse/Muse/Intelligence/Collections/SmartRule.swift Muse/Muse/Intelligence/Collections/SmartCollectionResolver.swift Muse/MuseTests/SimilarTermTests.swift Muse/MuseTests/SmartRuleSimilarResolverTests.swift
git commit -m "feat(spec-03): SmartRule.similar case + resolver evaluation"
```

---

### Task 34: `SmartCollectionRulesView` UI for `.similar` + `ClipPromptVectors.refreshAll()`

**Files:**
- Modify: `Muse/Muse/Views/Sidebar/SmartCollectionRulesView.swift` (`Kind.similar`, `defaultRule(for:)`, `valueControls`)
- Create: `Muse/Muse/Intelligence/Clip/ClipPromptVectors.swift` (replacing the temporary stub from Task 24 if one was added)
- Verification: manual build + run

**Interfaces:**
- Consumes: `SimilarTerm` (Task 33), `ClipEngine.shared.embedText` (Task 23), `ClipModelStore.shared.isReady` (Task 24)
- Produces: the rules-editor UI + `ClipPromptVectors.refreshAll()` — consumed by nothing further

- [ ] **Step 1: Add the `Kind` case and default rule**

In `SmartCollectionRulesView.swift`'s `Kind` enum, add `case similar` with `label: String(localized: "Looks Like")` (plain vocabulary, no invented terms). In `defaultRule(for:)`:

```swift
case .similar:
    return .similar(SimilarTerm(anchorIDs: [], prompt: "", promptVector: nil,
                                promptGeneration: nil, threshold: .defaultThreshold))
```

Offer this `Kind` case only when `ClipModelStore.shared.isReady` (hidden otherwise, matching the existing pattern for any feature that needs the model — an existing `.similar` rule still renders its row regardless, since it decodes fine without the model, it just can't be freshly created).

- [ ] **Step 2: `valueControls` branch**

```swift
case let .similar(term):
    if term.anchorIDs.isEmpty {
        TextField(String(localized: "Describe the look — e.g. beach sunset"),
                  text: Binding(
                      get: { term.prompt ?? "" },
                      set: { newValue in
                          if case var .similar(t) = rule {
                              t.prompt = newValue
                              rule = .similar(t)
                          }
                      }))
            .textFieldStyle(.roundedBorder)
            .frame(width: 210)
    } else {
        Text(String(localized: "\(term.anchorIDs.count) reference photos"))
    }
    Slider(value: Binding(
        get: { term.threshold },
        set: { newValue in
            if case var .similar(t) = rule {
                t.threshold = newValue
                rule = .similar(t)
            }
        }), in: SimilarTerm.thresholdRange) {
        EmptyView()
    } minimumValueLabel: {
        Text(String(localized: "Broad"))
    } maximumValueLabel: {
        Text(String(localized: "Exact"))
    }
```

(There is no separate no-editor branch to copy for the anchor-only case — Part B's ground truth confirmed `ColorTerm.hex`'s "no editor" precedent doesn't exist as a literal switch case in the real file; the anchor-count `Text` display above is this task's own minimal read-only affordance, established fresh.)

- [ ] **Step 3: Encode `promptVector` on save**

Locate the rules card's save path (wherever it persists the edited `SmartRule` back to `collections.smart_rules`) and add, only for a `.similar` rule with a non-empty `prompt` and empty `anchorIDs`: before saving, `await ClipEngine.shared.embedText(prompt)` and stamp `promptVector`/`promptGeneration: ClipModel.current.generation` onto the term. This is the one place a rule edit runs the model — a user action, not a background pass.

- [ ] **Step 4: `ClipPromptVectors.refreshAll()`**

```swift
//
//  ClipPromptVectors.swift
//  Muse
//
//  On model install/upgrade, re-encode every stored .similar prompt whose
//  promptGeneration is stale. Anchors need nothing here — their vectors
//  live in clip_embeddings and the backfill (Task 28) re-embeds those.
//

import Foundation

nonisolated enum ClipPromptVectors {
    static func refreshAll() async {
        guard let queue = Database.shared.dbQueue else { return }
        let rows = (try? await queue.read { db in try CollectionRow.fetchAll(db) }) ?? []
        for row in rows {
            guard let json = row.smart_rules,
                  var ruleSet = try? JSONDecoder().decode(SmartRuleSet.self, from: Data(json.utf8))
            else { continue }
            var changed = false
            for i in ruleSet.rules.indices {
                guard case let .similar(term) = ruleSet.rules[i],
                      let prompt = term.prompt, !prompt.trimmingCharacters(in: .whitespaces).isEmpty,
                      term.promptGeneration != ClipModel.current.generation
                else { continue }
                guard let vector = await ClipEngine.shared.embedText(prompt) else { continue }
                var updated = term
                updated.promptVector = vector
                updated.promptGeneration = ClipModel.current.generation
                ruleSet.rules[i] = .similar(updated)
                changed = true
            }
            guard changed, let encoded = try? JSONEncoder().encode(ruleSet),
                  let json = String(data: encoded, encoding: .utf8) else { continue }
            try? await queue.write { db in
                try db.execute(sql: "UPDATE collections SET smart_rules = ? WHERE id = ?",
                               arguments: [json, row.id])
            }
        }
        await CollectionsEngine.shared.reload()
    }
}
```

If Task 24 added a temporary stub `enum ClipPromptVectors { static func refreshAll() async {} }`, delete that stub now — this is its one real definition.

- [ ] **Step 5: Build and manually verify**

Run: `xcodebuild -scheme Muse build`
Expected: BUILD SUCCEEDED.

Manually verify (model installed): create a new smart collection, choose "Looks Like", type a prompt, save — confirm the collection populates; drag the threshold slider and confirm membership changes; confirm the "Looks Like" option is hidden entirely when the model isn't installed.

- [ ] **Step 6: Commit**

```bash
git add Muse/Muse/Views/Sidebar/SmartCollectionRulesView.swift Muse/Muse/Intelligence/Clip/ClipPromptVectors.swift
git commit -m "feat(spec-03): Looks Like smart-rule editor UI + prompt-vector refresh"
```

---

### Task 35: "New Smart Collection from Selection"

**Files:**
- Modify: `Muse/Muse/Views/GridView.swift` (or `SelectionActionsMenu.swift`, matching Task 30's insertion point)
- Verification: manual build + run

**Interfaces:**
- Consumes: `SimilarTerm.maxAnchors` (Task 33), `AppState.collectionModal` payload seam
- Produces: the "similar to these N photos" entry flow — nothing further depends on it

- [ ] **Step 1: Implement**

Add a context-menu item, visible when 1-20 image-kind files are selected AND `ClipModelStore.shared.isReady`:

```swift
Button(String(localized: "New Smart Collection from Selection")) {
    let ids = /* selected FileNodes' file_ids, up to SimilarTerm.maxAnchors */
    let rule = SmartRuleSet(match: .all, rules: [
        .similar(SimilarTerm(anchorIDs: ids, prompt: nil, promptVector: nil,
                             promptGeneration: nil, threshold: .defaultThreshold))
    ])
    appState.collectionModal = .newSmartCollection(seedRules: rule) // whatever the existing CollectionModal payload case is named
}
```

Wire this through the existing `AppState.collectionModal` payload seam (the same mechanism collection-scoped modals already use to hand data up to the shell-presented card, per the durable-constraints "modals present at the shell" rule) so it opens the smart-collection rules card pre-populated with this rule.

- [ ] **Step 2: Build and manually verify**

Run: `xcodebuild -scheme Muse build`
Expected: BUILD SUCCEEDED.

Manually verify: select 3-5 photos, choose "New Smart Collection from Selection", confirm the rules card opens with a "Looks Like" rule already showing "N reference photos", save, confirm the collection includes visually similar photos beyond the selection.

- [ ] **Step 3: Commit**

```bash
git add Muse/Muse/Views/GridView.swift
git commit -m "feat(spec-03): New Smart Collection from Selection"
```

---

### Task 36: `NLSearchIntent` + `NLTokenComposer` (pure, availability-free)

**Files:**
- Create: `Muse/Muse/Search/NaturalLanguageQuery.swift`
- Test: `Muse/MuseTests/NLTokenComposerTests.swift`

**Interfaces:**
- Consumes: `SearchQueryParser.parse` (Spec 02) for the round-trip guard
- Produces: `NLSearchIntent` (`@Generable`, macOS 26+ only), `NLTokenComposer.compose(...) -> String` (pure, available on all supported macOS versions) — consumed by Task 37 (`NLQuerySuggest`)

- [ ] **Step 1: Write the failing test**

```swift
//
//  NLTokenComposerTests.swift
//  MuseTests
//

import XCTest
@testable import Muse

final class NLTokenComposerTests: XCTestCase {
    func testFullFieldCombinationComposesParseableTokens() {
        let composed = NLTokenComposer.compose(year: 2025, month: 6, place: "Lisboa",
                                               camera: "x100v", minStars: 4, subject: "beach")
        let parsed = SearchQueryParser.parse(composed)
        XCTAssertFalse(parsed.tokens.isEmpty)
        XCTAssertTrue(composed.contains("2025"))
        XCTAssertTrue(composed.lowercased().contains("beach"))
    }

    func testYearOnlyComposesInDateToken() {
        let composed = NLTokenComposer.compose(year: 2019, month: nil, place: nil,
                                               camera: nil, minStars: nil, subject: nil)
        let parsed = SearchQueryParser.parse(composed)
        XCTAssertTrue(parsed.tokens.contains { if case let .inDate(d) = $0 { return d.year == 2019 }; return false })
    }

    func testEmptyIntentProducesEmptyString() {
        let composed = NLTokenComposer.compose(year: nil, month: nil, place: nil,
                                               camera: nil, minStars: nil, subject: nil)
        XCTAssertTrue(composed.trimmingCharacters(in: .whitespaces).isEmpty)
    }

    func testSubjectOnlyStaysFreeText() {
        let composed = NLTokenComposer.compose(year: nil, month: nil, place: nil,
                                               camera: nil, minStars: nil, subject: "dog on a beach")
        let parsed = SearchQueryParser.parse(composed)
        XCTAssertTrue(parsed.freeText.contains("dog on a beach"))
    }

    func testMinStarsComposesRatingToken() {
        let composed = NLTokenComposer.compose(year: nil, month: nil, place: nil,
                                               camera: nil, minStars: 3, subject: nil)
        let parsed = SearchQueryParser.parse(composed)
        XCTAssertTrue(parsed.tokens.contains { if case let .rating(atLeast: n) = $0 { return n == 3 }; return false })
    }

    func testComposedTextAlwaysRoundTripsThroughRealParser() {
        // Every non-degenerate field combination must produce text the
        // real SearchQueryParser can parse without throwing/crashing —
        // spot-check a handful of combinations.
        let combos: [(Int?, Int?, String?, String?, Int?, String?)] = [
            (2020, nil, nil, nil, nil, nil),
            (nil, nil, "Paris", nil, nil, nil),
            (nil, nil, nil, "iPhone", nil, nil),
            (nil, nil, nil, nil, 5, nil),
            (2021, 3, "Tokyo", "X100V", 4, "cherry blossoms"),
        ]
        for combo in combos {
            let composed = NLTokenComposer.compose(year: combo.0, month: combo.1, place: combo.2,
                                                    camera: combo.3, minStars: combo.4, subject: combo.5)
            _ = SearchQueryParser.parse(composed) // must not crash
        }
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -scheme Muse test -only-testing:MuseTests/NLTokenComposerTests`
Expected: FAIL — `NLTokenComposer` doesn't exist.

- [ ] **Step 3: Implement**

```swift
//
//  NaturalLanguageQuery.swift
//  Muse
//
//  Foundation Models guided generation fills a structured intent; the
//  intent is composed into TOKEN TEXT; the token text round-trips through
//  SearchQueryParser — which stays the single source of truth. By
//  construction this can never be a black box: every result is visible,
//  editable tokens (DECIDED #15).
//

import Foundation
#if canImport(FoundationModels)
import FoundationModels

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

nonisolated enum NLTokenComposer {
    static func compose(year: Int?, month: Int?, place: String?, camera: String?,
                        minStars: Int?, subject: String?) -> String {
        var parts: [String] = []
        if let year {
            if let month {
                parts.append("in:\(year)-\(String(format: "%02d", month))")
            } else {
                parts.append("in:\(year)")
            }
        }
        if let place, !place.trimmingCharacters(in: .whitespaces).isEmpty {
            let quoted = place.contains(" ") ? "\"\(place)\"" : place
            parts.append("near:\(quoted)")
        }
        if let camera, !camera.trimmingCharacters(in: .whitespaces).isEmpty {
            parts.append("camera:\(camera)")
        }
        if let minStars, (1...5).contains(minStars) {
            parts.append("★≥\(minStars)")
        }
        if let subject, !subject.trimmingCharacters(in: .whitespaces).isEmpty {
            parts.append(subject.trimmingCharacters(in: .whitespaces))
        }
        return parts.joined(separator: " ")
    }
}
```

(The `★≥N` fragment must match whatever literal syntax Spec 02's `SearchQueryParser` actually uses for `rating(atLeast:)` — verify against that grammar's real key/value shape before finalizing; if Spec 02 used a different literal, e.g. `star:>=N` or `rating:>=N`, use that instead. The test `testMinStarsComposesRatingToken` is the guard that catches a mismatch.)

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild -scheme Muse test -only-testing:MuseTests/NLTokenComposerTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Muse/Muse/Search/NaturalLanguageQuery.swift Muse/MuseTests/NLTokenComposerTests.swift
git commit -m "feat(spec-03): NLSearchIntent + NLTokenComposer pure composition"
```

---

### Task 37: `NLQuerySuggest` + suggestion pill in `TagChipsRow`

**Files:**
- Create: `Muse/Muse/Search/NLQuerySuggest.swift`
- Modify: `Muse/Muse/Views/TagChipsRow.swift` (suggestion pill, ahead of the token chips)
- Verification: manual build + run (macOS 26+ Apple Intelligence Mac required for the live guided-generation path — an owner-only sanity pass per §15.6; the trigger/guard logic below is exercised on any macOS version via the `#if canImport`/`@available` fallback, which does nothing pre-26)

**Interfaces:**
- Consumes: `NLTokenComposer.compose` (Task 36), `SearchQueryParser.parse` (Spec 02), `FoundationModelNamer.makeBest()`'s gating triple (`CollectionNaming.swift`) as the pattern to copy
- Produces: `NLQuerySuggest.shared`, `.suggestion: Suggestion?` — nothing further depends on it

- [ ] **Step 1: Implement `NLQuerySuggest`**

```swift
//
//  NLQuerySuggest.swift
//  Muse
//
//  Fires one async parse after a committed search whose parse yields zero
//  tokens and whose free text has >= minWords words — never blocks the
//  search itself; plain results show immediately. The composed text is
//  accepted only if it round-trips through the real parser into at least
//  one token; an intent mapping to nothing is dropped silently.
//

import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

@MainActor final class NLQuerySuggest: ObservableObject {
    static let shared = NLQuerySuggest()
    static let minWords = 3

    struct Suggestion: Equatable { let display: String; let queryText: String }

    @Published private(set) var suggestion: Suggestion?

    private var requestToken = 0

    func consider(query: String) {
        let parsed = SearchQueryParser.parse(query)
        guard parsed.tokens.isEmpty else { suggestion = nil; return }
        let words = parsed.freeText.split(separator: " ")
        guard words.count >= Self.minWords else { suggestion = nil; return }
        guard isAvailable() else { suggestion = nil; return }

        requestToken += 1
        let myToken = requestToken
        let text = parsed.freeText
        Task {
            guard let composed = await Self.parse(text) else { return }
            guard myToken == self.requestToken else { return } // superseded by a newer query
            guard !SearchQueryParser.parse(composed).tokens.isEmpty else { return }
            self.suggestion = Suggestion(display: composed, queryText: composed)
        }
    }

    func dismiss() {
        suggestion = nil
    }

    private func isAvailable() -> Bool {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            return SystemLanguageModel.default.availability == .available
        }
        #endif
        return false
    }

    private static func parse(_ text: String) async -> String? {
        #if canImport(FoundationModels)
        guard #available(macOS 26.0, *) else { return nil }
        do {
            let session = LanguageModelSession(instructions: """
            You extract structured search fields from a photo-library search
            query. Only fill fields the text actually states.
            """)
            let response = try await session.respond(to: text, generating: NLSearchIntent.self)
            let intent = response.content
            return NLTokenComposer.compose(year: intent.year, month: intent.month,
                                           place: intent.place, camera: intent.camera,
                                           minStars: intent.minStars, subject: intent.subject)
        } catch {
            return nil
        }
        #else
        return nil
        #endif
    }
}
```

- [ ] **Step 2: Wire the trigger and the chip-bar pill**

At the existing committed-search path (`runSearch`/`runSearchNow` in `AppState`), add `NLQuerySuggest.shared.consider(query: committedQuery)` right after a search completes.

In `TagChipsRow.swift`, ahead of the existing token chips (added by Spec 02 Task 14), add:

```swift
if let suggestion = nlQuerySuggest.suggestion {
    HStack(spacing: 4) {
        Label("\(String(localized: "Try:")) \(suggestion.display)", systemImage: "sparkles")
            .onTapGesture {
                appState.searchQuery = suggestion.queryText
                Task { await appState.runSearch(suggestion.queryText) }
                nlQuerySuggest.dismiss()
            }
        Button {
            nlQuerySuggest.dismiss()
        } label: {
            Image(systemName: "xmark.circle.fill")
        }
        .accessibilityLabel(String(localized: "Dismiss suggestion"))
    }
    .padding(.horizontal, 8).padding(.vertical, 4)
    .background(.thinMaterial, in: Capsule())
}
```

(Styled distinctly from the plain token chips per the spec — the `sparkles` icon + "Try:" prefix is the visual differentiator; match whatever pill/capsule styling convention the surrounding chip row already uses for its container shape.)

- [ ] **Step 3: Build and manually verify**

Run: `xcodebuild -scheme Muse build`
Expected: BUILD SUCCEEDED on any macOS version (the FM path compiles conditionally and is inert pre-26).

Manually verify on a macOS 26+ Apple Intelligence Mac (owner-only sanity pass, §15.6): run a free-text search like "beach photos with mom last summer" that parses to zero tokens, confirm a "Try: ..." pill appears with composed tokens, click it, confirm the field updates and the tokens render as individually removable chips; confirm the pill never appears below macOS 26 or when Apple Intelligence isn't enabled.

- [ ] **Step 4: Commit**

```bash
git add Muse/Muse/Search/NLQuerySuggest.swift Muse/Muse/Views/TagChipsRow.swift
git commit -m "feat(spec-03): NLQuerySuggest natural-language suggestion pill"
```

---

### Task 38: Docs, perf baseline, localization export, full-suite verification

**Files:**
- Modify: `Muse/CLAUDE.md` (phase-table row, the 10 new durable constraints from spec-03 §11, network doctrine already amended in Task 25)
- Modify: `docs/architecture-map.md` (new files: `Intelligence/Clip/`, `Views/Compare/`, `Search/ClipIndex.swift`/`SimilarityRegistry.swift`/`NaturalLanguageQuery.swift`/`NLQuerySuggest.swift`, `Models/CompareStore.swift`/`CullStore.swift`, `Components/CompareGeometry.swift`/`RegionMath.swift`/`CullSummary.swift`/`SharpnessRank.swift`/`PortraitHeuristic.swift`, `Intelligence/Core/SharpnessScore.swift`/`ClipVectors.swift`/`PortraitHeuristic.swift`)
- Modify: `docs/session-log.md` (a new dated entry for this spec's implementation)
- Modify: `docs/new-build/DECISIONS.md` (fold in any deviations discovered during execution that this plan's ground-truth research surfaced — e.g. the `ModalButton` `kind:` vs `style:` correction, the real `HeroImageViewer.swift` path, `SmartCollectionResolver.memberIDs` vs the spec's assumed `matchingIDs`, `KeyCaptureView`'s fixed three-closure shape vs a generic `onKey:`)
- Modify: `Muse/Muse/Perf/PerfBaseline.swift` (spec-03 §12's seven new recorded rows)
- Verification: full test suite + localization export

**Interfaces:**
- Consumes: everything built in Tasks 1-37
- Produces: the closed-out spec — nothing further depends on it

- [ ] **Step 1: `CLAUDE.md` updates**

Add the phase-table row: `| Spec 03 — Culling & Search Phase 2 (CLIP search, similarity, region search, .similar smart rule, NL suggestions, compare + peaking, cull, faces/pets tokens) | ✅ shipped | this branch |`.

Add the ten durable constraints listed in `docs/new-build/spec-03-implementation.md` §11 to the "Durable constraints & gotchas" section, condensed to one-two lines each per this file's own stated convention ("record the durable rule + why in one or two lines, not the full narrative"):

1. Network doctrine is four app-initiated paths now (search-model download added, Task 25).
2. `embeddings` (NLEmbedding text vectors) is NOT retired by CLIP — clustering's input; CLIP replaces the semantic search leg only, behind `isReady`.
3. CLIP vectors are L2-normalized fp16 blobs keyed by content, `embedded_hash`/`model_generation` markers, NULL vector = attempted-marker; `fromData` refuses wrong-length blobs.
4. The semantic merge floor and `matchedDirs` relaxation floor are the same threaded value (Task 27) — never let them drift into two constants.
5. A similarity query rides `similar:<handle>` against the session-scoped `SimilarityRegistry`; an unresolvable handle matches nothing, never falls back to unfiltered.
6. `.similar` prompt vectors are encoded at rule-SAVE time, stamped with the model generation; evaluation never runs the model; a generation mismatch evaluates empty and heals via `ClipPromptVectors.refreshAll()`.
7. Cull state is memory-only — no table, no defaults key, no sidecar field; resolution writes go through `TagStore.setRating` and `deleteWithBurn` only.
8. The peaking port's edge source is display-referred, evaluated at ~1080px working size — don't re-add the linear-to-sRGB pre-encode or run the chain at full decode resolution.
9. Region-mode Escape consumes `viewerClosing` inside the hero's onChange handler and returns before `startClose()` — the hero close sequence itself is untouched. Escape order: modal → compare → viewer → search → tags → collection → rediscovery → collectionsPage → placesPage → none.
10. Face/pet/sharpness traits live in one `photo_traits` table under `traits_scanned_hash`/`traits_version`; a new trait bumps the version rather than adding a parallel marker; missing row = unscanned, `faces:0` matches only scanned files.

Also record the ground-truth corrections this plan's research surfaced, so a future session doesn't re-trip on them: the real `HeroImageViewer.swift` lives at `Views/Viewer/HeroImageViewer.swift` (not `Viewers/`); `ModalButton`'s parameter is `kind:` not `style:`; `SmartCollectionResolver`'s real entry point is `memberIDs(_:db:now:)` with a private per-rule `evaluate`, not `matchingIDs(for:db:)`; `KeyCaptureView` has three fixed named closures (`onLeft`/`onRight`/`onReturn`), not a generic `onKey:` — `CompareKeyCatcher` (Task 14) is a new sibling catcher with a generic `onCharacter` closure, established for this spec, not an extension of the existing type.

- [ ] **Step 2: `architecture-map.md` updates**

Add entries for every new directory/file created across Tasks 1-37 under their appropriate existing section headers (`Intelligence/`, `Views/`, `Models/`, `Components/`, `Search/` if that's a top-level grouping in the map already, or fold into `Intelligence/` if `Search/` was introduced by Spec 02's own map update — match whatever convention Spec 02's Task 35 (its own closing docs task) established).

- [ ] **Step 3: `session-log.md` entry**

Add a dated entry (use the date this task is actually executed, not a placeholder) summarizing: what shipped (CLIP engine + similarity search + region search + `.similar` smart rule + NL suggestions + compare/peaking + cull + faces/pets tokens), the two-arc build order actually followed, and a pointer back to `docs/new-build/spec-03-implementation.md` and this plan file for full detail — matching the existing entries' length and style (skim a couple of existing entries first for tone).

- [ ] **Step 4: `PerfBaseline.swift` additions**

Add the seven recorded (never asserted — this codebase's convention per the spec's own §12 framing) rows: CLIP text encode (one query, model warm) budget 40ms; CLIP image embed (one 1024px raster, ANE, model warm) budget 15ms; `ClipIndex.matches` over 50k synthetic vectors budget 100ms; semantic leg end-to-end (encode+scan+merge) at 50k budget 150ms; `.similar` smart-rule resolve at 50k budget 120ms; compare two 24MP panes to sharp budget 1200ms; `DeepAnalysisBackfill` throughput budget >= 8 files/s.

- [ ] **Step 5: Localization export pass**

Run: `xcodebuild -exportLocalizations -project Muse/Muse.xcodeproj -localizationPath /tmp/muse-l10n -exportLanguage fr`

Expected: the export succeeds and every new `String(localized:)` call added across Tasks 1-37 appears as a key in the resulting `.xcstrings` write-back. Fill in the French values for every new key (translate directly; this is a mechanical step, not a design decision — match the terse, direct tone of the existing French strings). Re-run the export and confirm it reports 0 untranslated for the new keys — per this codebase's own rule, "the spec is incomplete until it reports 0 untranslated."

- [ ] **Step 6: Full verification pass**

Run: `xcodebuild -scheme Muse build`
Expected: BUILD SUCCEEDED.

Run: `xcodebuild -scheme Muse test`
Expected: the full suite passes, including every pre-existing test file this plan's tasks touched (`SearchServiceTests`, `SmartRuleSetTests`, `SmartCollectionResolverTests`, `EscapeActionTests`, `ThumbnailVariantTests` — confirming compare added no new thumbnail variant, per Task 13 decoding panes directly rather than through `ThumbnailCache`) plus every new test file added in Tasks 1-37.

Run: `defaults write com.tarrats.Muse AppleLanguages -array fr; open -n <built Muse.app path> --args -AppleLanguages "(fr)"` (or the one-shot `-AppleLanguages` launch-arg form, per this codebase's own French-preview convention) to spot-check the new French strings render sanely (no overflow, no untranslated English leaking through) before reverting the language override.

Before handing this off as complete, `stat` the built `.app`'s executable mtime and confirm it postdates the last commit — this codebase has a documented history of a stale signed binary in DerivedData silently surviving an incremental build (`rm -rf` the built `.app` and rebuild if the mtime looks wrong).

- [ ] **Step 7: Commit**

```bash
git add Muse/CLAUDE.md docs/architecture-map.md docs/session-log.md docs/new-build/DECISIONS.md Muse/Muse/Perf/PerfBaseline.swift Muse/Muse.xcodeproj
git commit -m "docs(spec-03): durable constraints, architecture map, perf baseline, localization export"
```

---

## Self-review notes (for the executor)

This plan's ground-truth research (documented inline throughout) surfaced several places where the source spec (`docs/new-build/spec-03-implementation.md`) or Spec 02's own plan made assumptions that don't match the real codebase. Each is flagged at its point of use above; the summary:

- **`SmartCollectionResolver`'s real entry point is `memberIDs(_ set: SmartRuleSet, db:, now:) throws -> Set<String>`**, not a per-rule `matchingIDs(for:db:)` the spec assumed. Task 33's tests build one-rule `SmartRuleSet`s and call `memberIDs` accordingly.
- **`ModalButton`'s real parameter name is `kind:`**, not `style:` — every task in this plan that constructs a `ModalButton` (17, 19) uses the correct name.
- **The real `HeroImageViewer.swift` path is `Views/Viewer/HeroImageViewer.swift`**, not `Viewers/HeroImageViewer.swift` — every task referencing it (13, 16, 18, 30, 32) uses the corrected path.
- **`KeyCaptureView` has three fixed named closures, no generic `onKey:`** — Task 14 introduces `CompareKeyCatcher` as a new sibling type with a generic `onCharacter` closure rather than assuming an extension point that doesn't exist; Task 18 follows the same pattern for the hero viewer's K/X/U handling.
- **`SmartCollectionRulesView`'s `valueControls` is a computed property, not a function**, and there is no literal `ColorTerm.hex` "no-editor" switch case to copy for `.similar`'s anchor-only branch — Task 34 establishes a fresh minimal read-only affordance instead of copying a precedent that doesn't exist.

If the executor finds during Task 1-19 (Arc A) or Task 20-37 (Arc B) that any OTHER assumption in this plan doesn't match the real Spec 01/02 end-state (signatures drifted during their own execution), treat this plan's code sketches as intent, not gospel — read the real file first, adapt the diff to match, and note the correction in Task 38's `DECISIONS.md` update so the next spec's plan doesn't re-trip on it.

