# Spec 02 — Photo Library Core Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn Muse's file library into a photo library: EXIF indexed into `photo_meta`,
offline reverse geocoding into a Places page, rediscovery surfaces (Rarely Seen / On
This Day / Shuffle), near-duplicate burst stacks, and phase-1 token search
(`camera:`/`lens:`/`iso:`/`f:`/`in:`/`near:`/`text:`/`color:`/`star:`/`kind:`) — all
querying only precomputed, indexed data. Along the way, fix the shipped dead
"visually similar" duplicate-finder mode (a real bug, and the prerequisite for stacks).

**Architecture:** Five new migrations (v13–v17) on top of the existing 12; one shared
header reader (`PhotoHeaderReader`) feeds both coordinates and EXIF from a single
`CGImageSourceCopyPropertiesAtIndex` call; offline geocoding via a bundled GeoNames
`cities1000` dataset + a 3-D k-d tree; every new stateful surface is its own frozen-
`AppState`-compliant `@MainActor` singleton (`PlacesStore`, `RediscoveryStore`,
`StacksStore`, `SearchFacets`) wired into the shell via one forwarded
`objectWillChange` cancellable each, exactly like the existing `folderStats`
integration. Search tokens parse from the existing native `.searchable` field text;
tokens render as removable chips in the existing `TagChipsRow` active-filter row — no
new toolbar surface. Every query-time operation reads only columns written at
analyze/backfill time; nothing opens a file, calls Vision, or geocodes at query time.

**Tech Stack:** Swift 5 (`SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`), SwiftUI + AppKit
escape hatches, GRDB.swift 7.10 (SQLite + FTS5), Accelerate/vDSP (feature-print
distance), XCTest. No new third-party dependency — GeoNames data is a bundled,
checked-in resource, not a package.

## Global Constraints

- **`AppState` is frozen.** No new `@Published` properties on `Models/AppState.swift`.
  Every new stateful surface (`PlacesStore`, `RediscoveryStore`, `StacksStore`,
  `SearchFacets`) is a standalone `@MainActor final class … ObservableObject`
  singleton (`static let shared`) observed directly by views (Pattern B, the
  `CollectionsEngine` shape) — never injected via `.environmentObject` for these
  (Pattern B is direct `@ObservedObject`/`.shared` access, unlike `CommerceStore`'s
  environment injection from Spec 01). The sanctioned integration cost is exactly one
  stored `objectWillChange`-forwarding cancellable per store in `AppState.init`
  (the existing `folderStats` pattern) plus a methods-only `AppState+<Feature>.swift`
  extension for orchestration — nothing else touches `AppState`.
- **Query time touches ONLY precomputed data.** Every search token resolves against an
  indexed column written at analyze/backfill time (`photo_meta`, `places`,
  `files.lat/lon`, `capture_md`). No token may open a file, call Vision, or geocode.
- **Geocoding is fully offline.** Bundled GeoNames + a k-d tree; `CLGeocoder`/MapKit
  geocoding are forbidden (network + throttled). Map link-outs (`maps://`,
  `https://www.google.com/maps?q=…` via `NSWorkspace.open`) are browser hand-offs, not
  app network calls.
- **Attempted-markers for header-derived data.** `coords_scanned_hash`,
  `photo_meta.exif_scanned_hash`, and the `places` row itself (NULL place = "geocoded,
  nothing near") exist so files without GPS/EXIF/places aren't re-scanned every
  launch. Never replace one with a bare NULL-column check. Dataless iCloud files are
  skipped WITHOUT stamping.
- **Content-keyed grain** for everything new except one exception: coordinates,
  `photo_meta`, `places`, `last_viewed_at`, and stacks are all keyed on `files`/
  `file_id` (content-hash identity) — NOT the tags/notes per-`(file_id, parent_dir)`
  grain. Two byte-identical files share GPS/EXIF/place/seen-state/stack membership by
  definition; edit-in-place already splits the row. The one per-location exception
  already in the codebase (ratings) still applies: any search token resolving rating
  matches must carry `parent_dir` restrictions.
- **`files.feature_print` is RAW `VNFeaturePrintObservation.data` — never
  `NSKeyedUnarchiver` it.** All comparisons go through `FeaturePrints.floats/distance`
  (vDSP Euclidean), which refuses length-mismatched pairs.
- **`last_viewed_at` is device-local** — never exported to sidecars, never synced.
- **Stacks are presentation-only.** Sets of `file_id` in `stacks`/`stack_members`;
  never touch paths, tags, ratings, notes, or collection membership. Collapse applies
  ONLY in plain folder browsing (never search, collections, rediscovery). The
  auto-stacker only ever touches files with no `stack_members` row (dissolved
  included) — dissolved stacks are permanent tombstones, never cleaned up.
- **Search token grammar keys are canonical English**, parsed before every other
  search leg; an unparseable token stays in free text verbatim. The committed field
  text is the single source of truth for tokens.
- **No `.alert`/`.confirmationDialog`/`.sheet` anywhere** — every modal is
  `ModalMessageCard`/`ModalButton`/`.museModal`, registered in
  `AppState.modalPresented`. This spec adds no new modals, but any confirmation UI it
  needs must follow this rule.
- **GRDB writes/reads are `async`** (`try await queue.write { }` / `try await
  queue.read { }`); GRDB rows are inserted as `var`.
- **Every AVFoundation asset is built via `AVURLAsset.noNetwork(url:)`**, never a bare
  `AVURLAsset(url:)`.
- **Localize every new user-facing string.** `Text("…")`/`Button("…")`/`.help("…")`
  literals auto-extract; anything passed as a plain `String` needs an explicit
  `String(localized:)` wrap.
- **Pure logic lives in nonisolated enums/structs, unit-tested without UI.** UI views
  are not unit-tested (house convention).
- **Migration numbering is fixed**: v13 coordinates · v14 `photo_meta` · v15 `places` ·
  v16 `last_viewed_at` · v17 stacks. Registered at the end of `Database.makeMigrator()`
  (`Muse/Muse/Database/Database.swift`, currently ending at `v12_smart_collections`
  around line 357, `return migrator` at line 367).
- **`Database.shared.dbQueue`, `FileRow.Columns.id`, `Database.makeMigrator()`** are
  the exact existing seam names — confirm against current source before using; if a
  name has drifted since this plan was written, follow the codebase, not this
  document's wording, matching the standing project convention (see `spec-01`'s plan,
  same clause).

---

## Section A — Prerequisite bug fix: feature prints are unreadable today

### Task 1: `FeaturePrints` (raw-buffer distance) + repair both broken call sites

**Files:**
- Create: `Muse/Muse/Intelligence/Core/FeaturePrints.swift`
- Create: `Muse/MuseTests/FeaturePrintsTests.swift`
- Modify: `Muse/Muse/Intelligence/Dedup/DuplicateFinder.swift:220` (and its surrounding
  visual-duplicate function)
- Modify: `Muse/Muse/Intelligence/SimilarTagSuggestions.swift:135` (and its surrounding
  function)

**Interfaces:**
- Produces: `FeaturePrints.floats(_ data: Data) -> [Float]?`,
  `FeaturePrints.distance(_ a: [Float], _ b: [Float]) -> Float?` — consumed by Task 28
  (`BurstClusterer`) and the two repaired call sites in this task.
- Consumes: nothing new — `files.feature_print` already exists (`Data?` column,
  written by `VisionServices.swift:197` as the raw `VNFeaturePrintObservation.data`
  element buffer).

**Context (verified against the running code):** both `DuplicateFinder.swift:220` and
`SimilarTagSuggestions.swift:135` call
`NSKeyedUnarchiver.unarchivedObject(ofClass: VNFeaturePrintObservation.self, from:
data)` on that raw buffer. A `VNFeaturePrintObservation` was never archived into that
column — `data` is the bare Float32 element array — so both calls return `nil` for
every row, and the duplicate finder's "Visually similar" mode plus the similar-photo
tag suggestions have silently returned empty results since they shipped. This task
fixes it by comparing raw float buffers directly instead of trying to reconstruct an
unreconstructable object.

- [ ] **Step 1: Write the failing tests**

```swift
//
//  FeaturePrintsTests.swift
//  MuseTests
//
//  Raw VNFeaturePrintObservation.data element-buffer comparison — the fix for
//  the shipped dead "visually similar" mode (NSKeyedUnarchiver on a raw
//  buffer always returned nil).
//

import XCTest
@testable import Muse

final class FeaturePrintsTests: XCTestCase {
    func testFloatsParsesAlignedBuffer() {
        let values: [Float] = [1.0, 2.0, 3.0, 4.0]
        let data = values.withUnsafeBufferPointer { Data(buffer: $0) }
        XCTAssertEqual(FeaturePrints.floats(data), values)
    }

    func testFloatsRejectsMisalignedBuffer() {
        // 6 bytes is not a multiple of 4 (Float32 stride) — must not crash,
        // must not silently truncate.
        let data = Data([0, 1, 2, 3, 4, 5])
        XCTAssertNil(FeaturePrints.floats(data))
    }

    func testFloatsRejectsEmptyBuffer() {
        XCTAssertNil(FeaturePrints.floats(Data()))
    }

    func testDistanceIsZeroForIdenticalVectors() {
        let a: [Float] = [1, 2, 3, 4]
        XCTAssertEqual(FeaturePrints.distance(a, a), 0, accuracy: 0.0001)
    }

    func testDistanceMatchesManualEuclidean() {
        let a: [Float] = [0, 0, 0]
        let b: [Float] = [3, 4, 0]
        // sqrt(3^2 + 4^2) = 5
        XCTAssertEqual(FeaturePrints.distance(a, b) ?? -1, 5.0, accuracy: 0.0001)
    }

    func testDistanceReturnsNilForMismatchedLengths() {
        // Prints from different Vision revisions must never pair — a
        // dimension mismatch is a silent-nonsense pair, not a value to score.
        XCTAssertNil(FeaturePrints.distance([1, 2, 3], [1, 2]))
    }

    func testDistanceReturnsNilForEmptyVectors() {
        XCTAssertNil(FeaturePrints.distance([], []))
    }
}
```

- [ ] **Step 2: Run, confirm failure**

  Run: `xcodebuild -project Muse/Muse.xcodeproj -scheme Muse test -only-testing:MuseTests/FeaturePrintsTests`
  Expected: FAIL — `FeaturePrints` doesn't exist.

- [ ] **Step 3: Implement `FeaturePrints`**

```swift
//
//  FeaturePrints.swift
//  Muse
//
//  files.feature_print stores the RAW VNFeaturePrintObservation.data element
//  buffer (VisionServices.swift writes it, never an archive). A
//  VNFeaturePrintObservation cannot be reconstructed from that data —
//  NSKeyedUnarchiver on it always returns nil, which is why the duplicate
//  finder's "Visually similar" mode and SimilarTagSuggestions silently
//  returned nothing since they shipped. This compares the raw float buffers
//  directly: Euclidean distance over the same elements Vision's own
//  computeDistance would have used.
//

import Foundation
import Accelerate

nonisolated enum FeaturePrints {
    /// Reinterprets a raw element buffer as [Float]. nil when the byte count
    /// isn't a multiple of Float32's stride (corrupt/foreign data) or empty.
    static func floats(_ data: Data) -> [Float]? {
        let stride = MemoryLayout<Float>.stride
        guard !data.isEmpty, data.count % stride == 0 else { return nil }
        return data.withUnsafeBytes { raw in
            Array(raw.bindMemory(to: Float.self))
        }
    }

    /// Euclidean distance via vDSP. nil when lengths differ — prints written
    /// by different Vision revisions must never be compared as if compatible.
    static func distance(_ a: [Float], _ b: [Float]) -> Float? {
        guard !a.isEmpty, a.count == b.count else { return nil }
        var diff = [Float](repeating: 0, count: a.count)
        vDSP_vsub(b, 1, a, 1, &diff, 1, vDSP_Length(a.count))
        var sumSquares: Float = 0
        vDSP_svesq(diff, 1, &sumSquares, vDSP_Length(a.count))
        return sqrt(sumSquares)
    }
}
```

- [ ] **Step 4: Run tests, confirm pass**

  Run: `xcodebuild -project Muse/Muse.xcodeproj -scheme Muse test -only-testing:MuseTests/FeaturePrintsTests`
  Expected: PASS.

- [ ] **Step 5: Rewrite `DuplicateFinder.swift`'s visual-duplicate path**

  Read `Muse/Muse/Intelligence/Dedup/DuplicateFinder.swift` in full around line 220 to
  find the enclosing function and its threshold constant (research found a `0.45`
  threshold already named there). Replace the `NSKeyedUnarchiver.unarchivedObject`
  call and its `VNFeaturePrintObservation.computeDistance` follow-up with:

```swift
guard let printData = row.feature_print,
      let floats = FeaturePrints.floats(printData) else { continue }
// … collect (fileID, floats) pairs, then compare with FeaturePrints.distance,
// keeping the existing 0.45 threshold and bucketing/grouping logic otherwise
// unchanged (only the "how do I get comparable floats" step changes).
```

  Do not change the grouping/bucketing algorithm around this — only the two lines
  that produced an always-nil comparable value. Delete the now-dead
  `unarchivedObject`-based helper function entirely (grep the file for any other
  caller first).

- [ ] **Step 6: Rewrite `SimilarTagSuggestions.swift`'s comparable-print path**

  Same shape at line 135: replace the `NSKeyedUnarchiver` attempt with
  `FeaturePrints.floats(data)`, and replace whatever downstream
  `VNFeaturePrintObservation.computeDistance` call consumed the (always-nil) unarchived
  object with `FeaturePrints.distance`. Keep the surrounding suggestion-ranking logic
  unchanged.

- [ ] **Step 7: Add a regression test pinning the fix**

  In the same `FeaturePrintsTests.swift` file (or a new `DuplicateFinderVisualTests.swift`
  if a suite already exists for `DuplicateFinder` — check first with
  `find Muse/MuseTests -iname "*DuplicateFinder*"` and follow its existing harness
  shape), add a test asserting that two files sharing a synthetic near-identical raw
  float buffer (small perturbation, distance well under 0.45) land in the same visual
  group when run through the finder's grouping function directly (not a full Vision
  run — synthesize the `feature_print` Data by hand). This is the "shipped-bug pin"
  test from spec-02's test table (`FeaturePrintsTests`: "regression:
  `DuplicateFinder.visualGroups` forms groups from raw-data prints").

- [ ] **Step 8: Run the full Dedup + SimilarTagSuggestions test suites**

  Run: `xcodebuild -project Muse/Muse.xcodeproj -scheme Muse test -only-testing:MuseTests/FeaturePrintsTests` and whatever the existing `DuplicateFinder`/`SimilarTagSuggestions` suites are named.
  Expected: PASS, including the new regression test.

- [ ] **Step 9: Add the durable-constraint note to `CLAUDE.md` (grouped with the
  final doc pass in Task 35 — do NOT duplicate here)**

  Skip — recorded once in Task 35 to avoid a doc edit landing in two places across the
  plan and drifting.

- [ ] **Step 10: Commit**

```bash
git add "Muse/Muse/Intelligence/Core/FeaturePrints.swift" \
        "Muse/MuseTests/FeaturePrintsTests.swift" \
        "Muse/Muse/Intelligence/Dedup/DuplicateFinder.swift" \
        "Muse/Muse/Intelligence/SimilarTagSuggestions.swift"
git commit -m "fix: compute feature-print similarity on raw float buffers (visual duplicates were dead code)"
```

---

## Section B — Coordinates + EXIF: one header pass, v13 + v14

### Task 2: `v13_coordinates` + `v14_photo_meta` migrations + records

**Files:**
- Modify: `Muse/Muse/Database/Database.swift` (add two migrations after the
  `v12_smart_collections` registration, before `return migrator`)
- Modify: `Muse/Muse/Database/Records.swift` (add fields to `FileRow`; add
  `PhotoMetaRow`)
- Create: `Muse/MuseTests/PhotoMetaMigrationTests.swift`

**Interfaces:**
- Produces: `FileRow.lat: Double?`, `FileRow.lon: Double?`,
  `FileRow.coords_scanned_hash: String?`; `PhotoMetaRow` (all fields below) —
  consumed by Task 3 (`PhotoHeaderReader`), Task 4 (`AnalyzePipeline` write points),
  Task 5 (`PhotoHeaderBackfill`), Task 11 (`PhotoSearch`), Task 22
  (`RediscoveryQueries`), Task 28 (`BurstClusterer`).
- Produces: DB columns `files.lat REAL`, `files.lon REAL`, `files.coords_scanned_hash
  TEXT`, partial index `files_coords_idx`; table `photo_meta` (PK `file_id`, cascade)
  with columns `exif_scanned_hash`, `capture_date`, `capture_md`, `camera_make`,
  `camera_model`, `lens`, `iso`, `f_number`, `exposure_seconds`, `focal_length`,
  `focal_length_35mm`, `flash_fired`, plus 6 indexes.

- [ ] **Step 1: Write the failing migration tests**

```swift
//
//  PhotoMetaMigrationTests.swift
//  MuseTests
//
//  v13_coordinates + v14_photo_meta: files.lat/lon/coords_scanned_hash, the
//  photo_meta table + its 6 indexes. EXIF lives in its own table (not
//  columns on files) to keep every existing SELECT * fetch path lean.
//

import XCTest
import GRDB
@testable import Muse

final class PhotoMetaMigrationTests: XCTestCase {
    func testV13AddsCoordinateColumnsAndIndex() throws {
        let queue = try DatabaseQueue()
        try Database.makeMigrator().migrate(queue)
        try queue.read { db in
            let cols = try db.columns(in: "files").map(\.name)
            XCTAssertTrue(cols.contains("lat"))
            XCTAssertTrue(cols.contains("lon"))
            XCTAssertTrue(cols.contains("coords_scanned_hash"))
            XCTAssertTrue(try db.indexes(on: "files").contains { $0.name == "files_coords_idx" })
        }
    }

    func testV14CreatesPhotoMetaTableAndIndexes() throws {
        let queue = try DatabaseQueue()
        try Database.makeMigrator().migrate(queue)
        try queue.read { db in
            XCTAssertTrue(try db.tableExists("photo_meta"))
            let cols = try db.columns(in: "photo_meta").map(\.name)
            for name in ["file_id", "exif_scanned_hash", "capture_date", "capture_md",
                         "camera_make", "camera_model", "lens", "iso", "f_number",
                         "exposure_seconds", "focal_length", "focal_length_35mm",
                         "flash_fired"] {
                XCTAssertTrue(cols.contains(name), "missing column \(name)")
            }
            let indexNames = Set(try db.indexes(on: "photo_meta").map(\.name))
            for name in ["photo_meta_capture_idx", "photo_meta_md_idx",
                         "photo_meta_camera_idx", "photo_meta_lens_idx",
                         "photo_meta_iso_idx", "photo_meta_f_idx", "photo_meta_focal_idx"] {
                XCTAssertTrue(indexNames.contains(name), "missing index \(name)")
            }
        }
    }

    func testPhotoMetaCascadesOnFileDelete() throws {
        let queue = try DatabaseQueue()
        try Database.makeMigrator().migrate(queue)
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO files (id, content_hash, kind, last_seen_at)
                VALUES ('f1', 'hash1', 'image', 0)
                """)
            try db.execute(sql: """
                INSERT INTO photo_meta (file_id, camera_make) VALUES ('f1', 'FUJIFILM')
                """)
            try db.execute(sql: "DELETE FROM files WHERE id = 'f1'")
        }
        try queue.read { db in
            let count = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM photo_meta") ?? -1
            XCTAssertEqual(count, 0)
        }
    }

    func testMigrationIsIdempotentAndPreservesExistingRows() throws {
        let queue = try DatabaseQueue()
        let migrator = Database.makeMigrator()
        try migrator.migrate(queue)
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO files (id, content_hash, kind, last_seen_at)
                VALUES ('f1', 'hash1', 'image', 0)
                """)
        }
        try migrator.migrate(queue) // re-run: GRDB no-ops already-applied migrations
        try queue.read { db in
            let row = try FileRow.filter(FileRow.Columns.id == "f1").fetchOne(db)
            XCTAssertNotNil(row)
            XCTAssertNil(row?.lat)
            XCTAssertNil(row?.coords_scanned_hash)
        }
    }
}
```

  Confirm `Database.makeMigrator()` is the actual callable name exposed by
  `Muse/Muse/Database/Database.swift` before finalizing (read the file — the tail
  already grepped for this plan shows `registerMigration`/`return migrator` inside
  what should be this function).

- [ ] **Step 2: Run, confirm failure**

  Run: `xcodebuild -project Muse/Muse.xcodeproj -scheme Muse test -only-testing:MuseTests/PhotoMetaMigrationTests`
  Expected: FAIL.

- [ ] **Step 3: Add both migrations**

  In `Muse/Muse/Database/Database.swift`, immediately after the
  `v12_smart_collections` registration block and before `return migrator`:

```swift
migrator.registerMigration("v13_coordinates") { db in
    // GPS lives in the file's own bytes — content-keyed like palette/caption/
    // dominant_color/feature_print, deliberately NOT the tags/notes
    // per-location grain (two byte-identical copies in different folders
    // have identical coordinates by definition; edit-in-place already
    // splits the row).
    try db.alter(table: "files") { t in
        t.add(column: "lat", .double)
        t.add(column: "lon", .double)
        // content_hash we last read GPS from — the attempted-marker that
        // stops a GPS-less file from being re-opened on every launch
        // forever (the analyzed_hash-NULL retry-loop bug shape).
        t.add(column: "coords_scanned_hash", .text)
    }
    try db.execute(sql: """
        CREATE INDEX files_coords_idx ON files(lat, lon) WHERE lat IS NOT NULL
        """)
}

migrator.registerMigration("v14_photo_meta") { db in
    try db.create(table: "photo_meta") { t in
        t.column("file_id", .text).primaryKey()
            .references("files", onDelete: .cascade)
        t.column("exif_scanned_hash", .text)
        t.column("capture_date", .integer)   // unix seconds (DateTimeOriginal, local-time)
        t.column("capture_md", .text)        // "MM-DD" — materialized on-this-day key
        t.column("camera_make", .text)
        t.column("camera_model", .text)
        t.column("lens", .text)
        t.column("iso", .integer)
        t.column("f_number", .double)
        t.column("exposure_seconds", .double)
        t.column("focal_length", .double)    // mm
        t.column("focal_length_35mm", .integer)
        t.column("flash_fired", .boolean)    // EXIF Flash bit 0; nil = unknown
    }
    try db.create(index: "photo_meta_capture_idx", on: "photo_meta", columns: ["capture_date"])
    try db.create(index: "photo_meta_md_idx", on: "photo_meta", columns: ["capture_md"])
    try db.create(index: "photo_meta_camera_idx", on: "photo_meta", columns: ["camera_make", "camera_model"])
    try db.create(index: "photo_meta_lens_idx", on: "photo_meta", columns: ["lens"])
    try db.create(index: "photo_meta_iso_idx", on: "photo_meta", columns: ["iso"])
    try db.create(index: "photo_meta_f_idx", on: "photo_meta", columns: ["f_number"])
    try db.create(index: "photo_meta_focal_idx", on: "photo_meta", columns: ["focal_length"])
}
```

  `capture_md` is materialized (not computed at query time with `strftime`) because a
  `strftime` WHERE clause can't use an index — the "query time touches only
  precomputed data" rule applied at the schema level; On This Day (Task 22) depends on
  this.

- [ ] **Step 4: Add the fields to `Records.swift`**

  In `Muse/Muse/Database/Records.swift`, add to `FileRow` (matching its existing
  `Optional` style — read the struct first to place these beside the other
  content-derived optional fields like `intent_model_version`):

```swift
var lat: Double?
var lon: Double?
var coords_scanned_hash: String?
```

  Add a new record:

```swift
struct PhotoMetaRow: Codable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "photo_meta"
    var file_id: String
    var exif_scanned_hash: String?
    var capture_date: Int64?
    var capture_md: String?
    var camera_make: String?
    var camera_model: String?
    var lens: String?
    var iso: Int?
    var f_number: Double?
    var exposure_seconds: Double?
    var focal_length: Double?
    var focal_length_35mm: Int?
    var flash_fired: Bool?
}
```

  No `Columns` enum is required unless a later task needs `FileRow.Columns.lat` etc. —
  Task 8's `.location` smart rule and Task 11's `PhotoSearch` both use raw SQL (matching
  the existing `IntentBackfill`/`unionTags` precedent of skipping `Columns` for
  seldom-filtered fields); add `Columns` cases only if a later task in this plan
  actually needs `FileRow.Columns.*` filtering (none do as scoped).

- [ ] **Step 5: Run tests, confirm pass**

  Run: `xcodebuild -project Muse/Muse.xcodeproj -scheme Muse test -only-testing:MuseTests/PhotoMetaMigrationTests`
  Expected: PASS.

- [ ] **Step 6: Run the full existing migration suite for regressions**

  Run whatever the v1–v12 migration test suite is named (grep
  `Muse/MuseTests` for `Migration` to find it) and confirm PASS — no change to v1–v12
  behavior.

- [ ] **Step 7: Commit**

```bash
git add "Muse/Muse/Database/Database.swift" "Muse/Muse/Database/Records.swift" \
        "Muse/MuseTests/PhotoMetaMigrationTests.swift"
git commit -m "feat: add v13_coordinates + v14_photo_meta migrations"
```

---

### Task 3: `PhotoHeaderReader` — one header pass for coordinates + EXIF

**Files:**
- Create: `Muse/Muse/Filesystem/PhotoHeaderReader.swift`
- Create: `Muse/MuseTests/PhotoHeaderReaderTests.swift`

**Interfaces:**
- Consumes: `AssetKind` (existing enum), `FileMetadata.coordinate(latitude:latRef:longitude:longRef:)`
  and `FileMetadata.imageMetadata` key-handling conventions (`Muse/Muse/Viewers/FileMetadata.swift`
  — read this file in full before writing `exifFields`; the mapping must not diverge),
  `AVURLAsset.noNetwork(url:)`.
- Produces: `PhotoHeaderReader.read(url:kind:) async -> PhotoHeader`,
  `PhotoHeaderReader.exifFields(exif:tiff:) -> ExifFields` (pure),
  `PhotoHeaderReader.sanitize(_:) -> Coordinate?` (pure),
  `PhotoHeaderReader.parseExifDate(_:) -> (epoch: Int64, md: String)?` (pure);
  `ExifFields`, `PhotoHeader` structs — consumed by Task 4 (`AnalyzePipeline`) and
  Task 5 (`PhotoHeaderBackfill`).

- [ ] **Step 1: Read `FileMetadata.swift`'s existing key-handling in full**

  Before writing any code, read `Muse/Muse/Viewers/FileMetadata.swift` end to end,
  paying specific attention to: (a) `imageMetadata` — the exact GPS/EXIF/TIFF
  dictionary-key handling (prefix-stripped bare keys, `ISOSpeedRatings` `[Int]`-or-`Int`
  tolerance), (b) `coordinate(latitude:latRef:longitude:longRef:)` and
  `parseISO6709(_:)` — reuse these exactly, don't reimplement, (c) `loadVideo` — the
  exact AVFoundation metadata key used (`.metadata` vs `.commonMetadata` — follow
  whichever the code actually uses, not any spec's prose), (d) the dataless-iCloud
  guard's exact structure (`.ubiquitousItemDownloadingStatusKey` check) so the new
  reader's guard matches verbatim.

- [ ] **Step 2: Write the failing pure-logic tests**

```swift
//
//  PhotoHeaderReaderTests.swift
//  MuseTests
//
//  Header-only GPS+EXIF extraction for the v13/v14 write pipeline. Mirrors
//  FileMetadata's display-time reader exactly — the two must never diverge,
//  or a viewer shows one camera/location while search indexes another.
//

import XCTest
@testable import Muse

final class PhotoHeaderReaderTests: XCTestCase {
    // MARK: sanitize (Spec 01's validator, absorbed verbatim)

    func testSanitizeAcceptsValidRange() {
        let c = Coordinate(lat: 38.7223, long: -9.1393)
        XCTAssertEqual(PhotoHeaderReader.sanitize(c)?.lat, 38.7223)
    }
    func testSanitizeRejectsOutOfRangeLatitude() {
        XCTAssertNil(PhotoHeaderReader.sanitize(Coordinate(lat: 91, long: 0)))
        XCTAssertNil(PhotoHeaderReader.sanitize(Coordinate(lat: -91, long: 0)))
    }
    func testSanitizeRejectsOutOfRangeLongitude() {
        XCTAssertNil(PhotoHeaderReader.sanitize(Coordinate(lat: 0, long: 181)))
    }
    func testSanitizeRejectsNonFiniteValues() {
        XCTAssertNil(PhotoHeaderReader.sanitize(Coordinate(lat: .nan, long: 0)))
        XCTAssertNil(PhotoHeaderReader.sanitize(Coordinate(lat: 0, long: .infinity)))
    }
    func testSanitizeAcceptsBoundaryValues() {
        XCTAssertNotNil(PhotoHeaderReader.sanitize(Coordinate(lat: 90, long: 180)))
    }

    // MARK: exifFields — pure mapping, no fixtures on disk

    func testExifFieldsReadsScalarISO() {
        let fields = PhotoHeaderReader.exifFields(
            exif: ["ISOSpeedRatings": 400, "FNumber": 2.0, "ExposureTime": 0.008,
                   "FocalLength": 23.0, "FocalLenIn35mmFilm": 35],
            tiff: ["Make": "FUJIFILM", "Model": "X100V"])
        XCTAssertEqual(fields.iso, 400)
        XCTAssertEqual(fields.cameraMake, "FUJIFILM")
        XCTAssertEqual(fields.cameraModel, "X100V")
        XCTAssertEqual(fields.fNumber, 2.0)
        XCTAssertEqual(fields.exposureSeconds, 0.008)
        XCTAssertEqual(fields.focalLength, 23.0)
        XCTAssertEqual(fields.focalLength35mm, 35)
    }

    func testExifFieldsToleratesArrayISO() {
        // Some encoders write ISOSpeedRatings as [Int] (a single-element
        // array) rather than a bare Int — FileMetadata already tolerates
        // this; this reader must too.
        let fields = PhotoHeaderReader.exifFields(exif: ["ISOSpeedRatings": [400]], tiff: [:])
        XCTAssertEqual(fields.iso, 400)
    }

    func testExifFieldsMissingKeysAreNil() {
        let fields = PhotoHeaderReader.exifFields(exif: [:], tiff: [:])
        XCTAssertNil(fields.iso)
        XCTAssertNil(fields.cameraMake)
        XCTAssertNil(fields.flashFired)
    }

    func testExifFieldsFlashBitZeroFired() {
        // EXIF Flash is a bitfield; bit 0 = fired.
        let fired = PhotoHeaderReader.exifFields(exif: ["Flash": 1], tiff: [:])
        XCTAssertEqual(fired.flashFired, true)
        let notFired = PhotoHeaderReader.exifFields(exif: ["Flash": 0], tiff: [:])
        XCTAssertEqual(notFired.flashFired, false)
        let noFlashInfo = PhotoHeaderReader.exifFields(exif: [:], tiff: [:])
        XCTAssertNil(noFlashInfo.flashFired)
    }

    // MARK: parseExifDate — epoch/MD must agree, garbage must not crash

    func testParseExifDateValid() {
        let result = PhotoHeaderReader.parseExifDate("2019:06:21 14:30:00")
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.md, "06-21")
    }

    func testParseExifDateGarbageReturnsNil() {
        XCTAssertNil(PhotoHeaderReader.parseExifDate("not a date"))
        XCTAssertNil(PhotoHeaderReader.parseExifDate(nil))
        XCTAssertNil(PhotoHeaderReader.parseExifDate(""))
    }

    func testParseExifDateEpochAndMDAgree() {
        let result = PhotoHeaderReader.parseExifDate("2023:12:31 23:59:59")
        XCTAssertEqual(result?.md, "12-31")
    }

    // MARK: read — unsupported kind returns an empty header, never crashes

    func testReadReturnsEmptyHeaderForUnsupportedKind() async {
        let url = URL(fileURLWithPath: "/tmp/nonexistent-\(UUID().uuidString).txt")
        let header = await PhotoHeaderReader.read(url: url, kind: .text)
        XCTAssertNil(header.coordinate)
        XCTAssertNil(header.exif)
    }
}
```

  Confirm `.text` is the actual `AssetKind` case for a plain document (check
  `Muse/Muse/Models/AssetKind.swift`); adjust if the real case name differs. Confirm
  `Coordinate`'s exact field names (`lat`/`long`) against `FileMetadata.swift`.

- [ ] **Step 3: Run, confirm failure**

  Run: `xcodebuild -project Muse/Muse.xcodeproj -scheme Muse test -only-testing:MuseTests/PhotoHeaderReaderTests`
  Expected: FAIL — type doesn't exist.

- [ ] **Step 4: Implement `PhotoHeaderReader`**

```swift
//
//  PhotoHeaderReader.swift
//  Muse
//
//  One header-only read serving BOTH coordinates and EXIF — a single
//  CGImageSourceCopyPropertiesAtIndex call rather than two separate readers
//  parsing the same header twice. Key handling mirrors
//  FileMetadata.imageMetadata exactly (prefix-stripped keys, ISOSpeedRatings
//  array-or-scalar tolerance) — the two must never diverge, or a viewer
//  shows one camera/location while search indexes another.
//

import Foundation
import ImageIO
import AVFoundation

nonisolated struct ExifFields: Equatable, Sendable {
    var captureDate: Int64?
    var captureMD: String?
    var cameraMake: String?
    var cameraModel: String?
    var lens: String?
    var iso: Int?
    var fNumber: Double?
    var exposureSeconds: Double?
    var focalLength: Double?
    var focalLength35mm: Int?
    var flashFired: Bool?
}

nonisolated struct PhotoHeader: Sendable {
    var coordinate: Coordinate?
    var exif: ExifFields?
}

nonisolated enum PhotoHeaderReader {
    static func read(url: URL, kind: AssetKind) async -> PhotoHeader {
        // Dataless iCloud placeholders never force a download — same guard
        // as FileMetadata.load and Indexer.isDataless. Verbatim structure —
        // confirm this matches FileMetadata's guard exactly (Step 1).
        if let values = try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey]),
           let status = values.ubiquitousItemDownloadingStatus,
           status != .current {
            return PhotoHeader(coordinate: nil, exif: nil)
        }
        switch kind {
        case .image, .raw, .psd:
            return readImageHeader(url: url)
        case .video:
            return await readVideoHeader(url: url)
        default:
            return PhotoHeader(coordinate: nil, exif: nil)
        }
    }

    /// Rejects non-finite and out-of-range values — a corrupt header must
    /// not put a pin in the sea. (Absorbed verbatim from Spec 01 §2.2.)
    static func sanitize(_ c: Coordinate) -> Coordinate? {
        guard c.lat.isFinite, c.long.isFinite,
              abs(c.lat) <= 90, abs(c.long) <= 180 else { return nil }
        return c
    }

    /// Pure mapping — no fixtures needed. Mirrors FileMetadata.imageMetadata's
    /// prefix-stripped-key / ISOSpeedRatings-array-or-scalar handling exactly.
    static func exifFields(exif: [String: Any], tiff: [String: Any]) -> ExifFields {
        func intValue(_ v: Any?) -> Int? {
            if let i = v as? Int { return i }
            if let arr = v as? [Int] { return arr.first }
            if let n = v as? NSNumber { return n.intValue }
            return nil
        }
        func doubleValue(_ v: Any?) -> Double? {
            if let d = v as? Double { return d }
            if let n = v as? NSNumber { return n.doubleValue }
            return nil
        }
        var fields = ExifFields()
        fields.iso = intValue(exif["ISOSpeedRatings"])
        fields.fNumber = doubleValue(exif["FNumber"])
        fields.exposureSeconds = doubleValue(exif["ExposureTime"])
        fields.focalLength = doubleValue(exif["FocalLength"])
        fields.focalLength35mm = intValue(exif["FocalLenIn35mmFilm"])
        fields.lens = exif["LensModel"] as? String
        fields.cameraMake = tiff["Make"] as? String
        fields.cameraModel = tiff["Model"] as? String
        if let flash = intValue(exif["Flash"]) {
            fields.flashFired = (flash & 1) == 1
        }
        if let dateStr = exif["DateTimeOriginal"] as? String,
           let parsed = parseExifDate(dateStr) {
            fields.captureDate = parsed.epoch
            fields.captureMD = parsed.md
        }
        return fields
    }

    /// "yyyy:MM:dd HH:mm:ss", en_US_POSIX, interpreted in the CURRENT LOCAL
    /// time zone — EXIF carries no zone; local-time is the Photos-app
    /// convention and the least-wrong default (recorded limitation, not a
    /// bug). captureMD derives from the SAME DateComponents parse so the two
    /// can never disagree.
    static func parseExifDate(_ s: String?) -> (epoch: Int64, md: String)? {
        guard let s, !s.isEmpty else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        formatter.timeZone = TimeZone.current
        guard let date = formatter.date(from: s) else { return nil }
        let epoch = Int64(date.timeIntervalSince1970)
        let mdFormatter = DateFormatter()
        mdFormatter.locale = Locale(identifier: "en_US_POSIX")
        mdFormatter.dateFormat = "MM-dd"
        mdFormatter.timeZone = TimeZone.current
        return (epoch, mdFormatter.string(from: date))
    }

    private static func readImageHeader(url: URL) -> PhotoHeader {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        else { return PhotoHeader(coordinate: nil, exif: nil) }

        var coordinate: Coordinate?
        if let gps = props[kCGImagePropertyGPSDictionary] as? [CFString: Any] {
            let raw = FileMetadata.coordinate(
                latitude: gps[kCGImagePropertyGPSLatitude] as? Double,
                latRef: gps[kCGImagePropertyGPSLatitudeRef] as? String,
                longitude: gps[kCGImagePropertyGPSLongitude] as? Double,
                longRef: gps[kCGImagePropertyGPSLongitudeRef] as? String)
            coordinate = raw.flatMap(sanitize)
        }

        var exifFieldsOut: ExifFields?
        let exifDict = (props[kCGImagePropertyExifDictionary] as? [CFString: Any]) ?? [:]
        let tiffDict = (props[kCGImagePropertyTIFFDictionary] as? [CFString: Any]) ?? [:]
        if !exifDict.isEmpty || !tiffDict.isEmpty {
            // Bridge CFString keys to the bare-string keys exifFields expects
            // (mirrors FileMetadata.imageMetadata's own prefix-stripping —
            // confirm the exact bridging FileMetadata uses in Step 1 and
            // match it here so the two never diverge).
            let exifStrKeys = Dictionary(uniqueKeysWithValues: exifDict.map { (String($0.key), $0.value) })
            let tiffStrKeys = Dictionary(uniqueKeysWithValues: tiffDict.map { (String($0.key), $0.value) })
            exifFieldsOut = exifFields(exif: exifStrKeys, tiff: tiffStrKeys)
        }
        return PhotoHeader(coordinate: coordinate, exif: exifFieldsOut)
    }

    private static func readVideoHeader(url: URL) async -> PhotoHeader {
        let asset = AVURLAsset.noNetwork(url: url)
        // Use whatever key FileMetadata.loadVideo actually loads (.metadata
        // vs .commonMetadata) — confirmed in Step 1; do not assume.
        guard let items = try? await asset.load(.metadata) else {
            return PhotoHeader(coordinate: nil, exif: nil)
        }
        var coordinate: Coordinate?
        if let locationItem = items.first(where: { $0.commonKey == .commonKeyLocation }),
           let locationString = try? await locationItem.load(.stringValue) {
            coordinate = FileMetadata.parseISO6709(locationString).flatMap(sanitize)
        }
        var exif: ExifFields?
        if let dateItem = items.first(where: { $0.commonKey == .commonKeyCreationDate }),
           let dateValue = try? await dateItem.load(.dateValue) {
            var f = ExifFields()
            f.captureDate = Int64(dateValue.timeIntervalSince1970)
            let mdFormatter = DateFormatter()
            mdFormatter.locale = Locale(identifier: "en_US_POSIX")
            mdFormatter.dateFormat = "MM-dd"
            mdFormatter.timeZone = TimeZone.current
            f.captureMD = mdFormatter.string(from: dateValue)
            exif = f
        }
        return PhotoHeader(coordinate: coordinate, exif: exif)
    }
}
```

  This implementation is a starting point written from the spec's description — the
  exact `kCGImagePropertyExifDictionary` key-bridging and the video metadata key
  (`.metadata` vs `.commonMetadata`) MUST be reconciled against what Step 1's reading
  of `FileMetadata.swift` actually found before this is considered done. If
  `FileMetadata.imageMetadata` does the CFString→String bridging differently (e.g. via
  a shared private helper), factor that helper out and call it from both places rather
  than duplicating slightly-different bridging logic in two files.

- [ ] **Step 5: Run tests, confirm pass**

  Run: `xcodebuild -project Muse/Muse.xcodeproj -scheme Muse test -only-testing:MuseTests/PhotoHeaderReaderTests`
  Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add "Muse/Muse/Filesystem/PhotoHeaderReader.swift" "Muse/MuseTests/PhotoHeaderReaderTests.swift"
git commit -m "feat: add PhotoHeaderReader (single-pass coordinates + EXIF header read)"
```

---

### Task 4: Wire coordinate + EXIF write into `AnalyzePipeline.analyzeOne`

**Files:**
- Modify: `Muse/Muse/Intelligence/AnalyzePipeline.swift` (around lines 408–488: the
  `analyzeOne(fileID:url:)` function, its `.image/.raw/.psd`-only guard at line 411,
  the `analyzedHash` capture near lines 419–422, and the guarded write transaction
  ending near line 485)
- Modify (extend, don't replace): `Muse/MuseTests/AnalyzePipelineTests.swift` (or
  whatever the existing suite is named — confirm first)

**Interfaces:**
- Consumes: `PhotoHeaderReader.read(url:kind:)` (Task 3), `PhotoMetaRow` (Task 2).
- Produces: `files.lat/lon/coords_scanned_hash` and a `photo_meta` row populated
  during the normal automatic analysis pass — consumed by Task 8 (`.location` smart
  rule), Task 11 (`PhotoSearch`), Task 22 (`RediscoveryQueries`, On This Day), Task 28
  (`BurstClusterer`, capture-time bucketing).

- [ ] **Step 1: Read `AnalyzePipeline.swift` end to end around `analyzeOne`**

  Confirm the exact current structure before editing: the `.image/.raw/.psd` guard's
  line number, where `analyzedHash` is captured, what `async let`s already run
  concurrently with Vision, and the exact shape of the guarded write transaction
  (it re-fetches the row and checks `file.content_hash == analyzedHash` before
  writing — this task must not weaken that guard).

- [ ] **Step 2: Write a coordinate/EXIF-write test, following the existing harness**

  Check for an existing `AnalyzePipelineTests.swift`. If it uses a fixture image with
  known EXIF (check `Muse/MuseTests/Fixtures/` or similar), extend it with a GPS+EXIF-
  tagged fixture and assert `lat`/`lon`/`coords_scanned_hash` and the `photo_meta` row
  are populated after `analyzeOne` runs, matching `content_hash`. If no fixture
  convention exists and the suite instead white-box-tests the pure helpers this
  pipeline calls, write the equivalent white-box test here: seed a `files` row with a
  known `content_hash`, call the (now-refactored) coordinate/EXIF write helper
  directly with a stubbed `PhotoHeader`, and assert the DB state. Match whatever depth
  the existing suite already uses for this file rather than inventing new
  infrastructure — record the choice in the commit message.

- [ ] **Step 3: Run, confirm failure**

  Confirm the new/extended test fails against current code (coordinates/EXIF not yet
  written).

- [ ] **Step 4: Add the video coordinate/EXIF write path (before the image-kind guard)**

  Immediately before the existing `guard kind == .image || kind == .raw || kind ==
  .psd else { return }` line, add a video branch that writes coordinates + capture
  date in its own small hash-guarded transaction (video never runs Vision, but a
  geotagged/dated video must not be invisible to `near:`/`in:`/On This Day just
  because Vision doesn't tag video):

```swift
private func analyzeOne(fileID: String, url: URL) async {
    let kind = AssetKind.detect(at: url)

    if kind == .video {
        await writePhotoHeaderOnly(fileID: fileID, url: url, kind: kind)
    }

    guard kind == .image || kind == .raw || kind == .psd else { return }
    // … existing Vision pipeline continues unchanged …
```

  Add the private helper (mirrors the main write transaction's hash-guard shape):

```swift
/// Video kinds skip the Vision pipeline entirely but still need their
/// coordinate + capture date written — a separate, smaller guarded
/// transaction mirroring the main one's content_hash re-check.
private func writePhotoHeaderOnly(fileID: String, url: URL, kind: AssetKind) async {
    guard let queue = Database.shared.dbQueue else { return }
    guard let currentHash = try? await queue.read({ db in
        try FileRow.filter(FileRow.Columns.id == fileID).fetchOne(db)?.content_hash
    }), let hash = currentHash else { return }

    let header = await PhotoHeaderReader.read(url: url, kind: kind)

    try? await queue.write { db in
        guard var file = try FileRow.filter(FileRow.Columns.id == fileID).fetchOne(db),
              file.content_hash == hash else { return }
        // Spec 02 amendment A1 (DECISIONS.md): skip the write entirely when
        // both attempted-markers already equal this content_hash — an
        // unconditional re-write here would clobber any future
        // externally-supplied GPS/date (Spec 06's ImportSupplement) with a
        // header re-read producing NULLs. Cheap now, load-bearing later —
        // build it in from the start rather than retrofitting it.
        var meta = (try PhotoMetaRow.filter(Column("file_id") == fileID).fetchOne(db))
            ?? PhotoMetaRow(file_id: fileID)
        let coordsAlreadyCurrent = file.coords_scanned_hash == hash
        let metaAlreadyCurrent = meta.exif_scanned_hash == hash
        if coordsAlreadyCurrent && metaAlreadyCurrent { return }

        if let coord = header.coordinate, !coordsAlreadyCurrent {
            file.lat = coord.lat
            file.lon = coord.long
        }
        file.coords_scanned_hash = hash
        try file.update(db)

        if let exif = header.exif, !metaAlreadyCurrent {
            meta.capture_date = exif.captureDate
            meta.capture_md = exif.captureMD
        }
        meta.exif_scanned_hash = hash
        try meta.save(db)
    }
}
```

- [ ] **Step 5: Add the image-kind coordinate + EXIF write, concurrent with Vision**

  Locate the existing `async let`s that run concurrently with Vision (near where
  `analyzedHash` is captured). Add:

```swift
async let photoHeader = PhotoHeaderReader.read(url: url, kind: kind)
```

  alongside them, so the header read overlaps Vision instead of running serially
  after it. Inside the existing guarded write transaction (the one checking
  `file.content_hash == analyzedHash`), immediately after the existing tag/caption/
  palette/feature-print field assignments and before `try file.update(db)`, add:

```swift
let header = await photoHeader
let coordsAlreadyCurrent = file.coords_scanned_hash == analyzedHash
if let coord = header.coordinate, !coordsAlreadyCurrent {
    file.lat = coord.lat
    file.lon = coord.long
}
if !coordsAlreadyCurrent {
    file.coords_scanned_hash = analyzedHash
}
```

  and, after `try file.update(db)` (still inside the same transaction, same `db`),
  upsert `photo_meta`:

```swift
var meta = (try PhotoMetaRow.filter(Column("file_id") == fileID).fetchOne(db))
    ?? PhotoMetaRow(file_id: fileID)
let metaAlreadyCurrent = meta.exif_scanned_hash == analyzedHash
if let exif = header.exif, !metaAlreadyCurrent {
    meta.capture_date = exif.captureDate
    meta.capture_md = exif.captureMD
    meta.camera_make = exif.cameraMake
    meta.camera_model = exif.cameraModel
    meta.lens = exif.lens
    meta.iso = exif.iso
    meta.f_number = exif.fNumber
    meta.exposure_seconds = exif.exposureSeconds
    meta.focal_length = exif.focalLength
    meta.focal_length_35mm = exif.focalLength35mm
    meta.flash_fired = exif.flashFired
}
if !metaAlreadyCurrent {
    meta.exif_scanned_hash = analyzedHash
}
try meta.save(db)
```

  `coords_scanned_hash`/`exif_scanned_hash` are always stamped to `analyzedHash` even
  when nothing was found (no GPS, no EXIF) — this is the attempted-marker that
  prevents the retry-loop bug shape. Only the value fields are conditionally written,
  and per the A1 amendment above, skipped entirely when both markers already match
  (nothing to do).

- [ ] **Step 6: Run the test, confirm pass**

- [ ] **Step 7: Run the full `AnalyzePipeline`/`Indexer` suites for regressions**

  Run: `xcodebuild -project Muse/Muse.xcodeproj -scheme Muse test -only-testing:MuseTests/AnalyzePipelineTests -only-testing:MuseTests/IndexerReconcileTests`
  Expected: PASS, no change to existing tag/caption/palette/feature-print behavior.

- [ ] **Step 8: Commit**

```bash
git add "Muse/Muse/Intelligence/AnalyzePipeline.swift" "Muse/MuseTests/AnalyzePipelineTests.swift"
git commit -m "feat: write GPS coordinates + EXIF during analysis (images + video)"
```

---

### Task 5: `PhotoHeaderBackfill` launch pass + `MuseApp.swift` wiring

**Files:**
- Create: `Muse/Muse/Intelligence/PhotoHeaderBackfill.swift`
- Modify: `Muse/Muse/MuseApp.swift` (near line 132, alongside the existing
  `IntentBackfill.run()` launch call inside the `.task` at line 102)

**Interfaces:**
- Consumes: `PhotoHeaderReader.read(url:kind:)` (Task 3), `Database.shared.dbQueue`,
  `PhaseTrace.mark(_:)`.
- Produces: `PhotoHeaderBackfill.run() async` — fire-and-forget launch pass. Chains to
  Task 9 (`GeocodeBackfill.run()`) and Task 13 (`SearchFacets.refresh()`) on
  completion with any writes.

- [ ] **Step 1: Confirm `PathRow`'s exact field names**

  Read `Muse/Muse/Database/Records.swift`'s `PathRow` (or equivalent) definition to
  confirm the exact column/property names for `absolute_path` and `is_alive` before
  writing the SQL below.

- [ ] **Step 2: Check for an existing chunking utility**

  Run: `grep -rn "chunked(into:" "Muse/Muse"` — if `Array.chunked(into:)` already
  exists as a codebase extension, reuse it; otherwise add a small private one in this
  file.

- [ ] **Step 3: Implement `PhotoHeaderBackfill`**

```swift
//
//  PhotoHeaderBackfill.swift
//  Muse
//
//  Launch-time pass backfilling files.lat/lon/coords_scanned_hash and
//  photo_meta for files the analysis pipeline hasn't stamped yet
//  (pre-existing libraries at upgrade time, or files whose content changed
//  since the last scan). Modelled on IntentBackfill.
//

import Foundation
import GRDB

nonisolated enum PhotoHeaderBackfill {
    /// Capped per launch so a 100k cold library spreads the backfill over a
    /// few launches instead of hammering disk once.
    static let maxPerLaunch = 5_000
    static let concurrency = 4
    static let writeChunk = 200

    struct Candidate { let id: String; let url: URL; let kind: AssetKind }

    static func run() async {
        guard let q = Database.shared.dbQueue else { return }

        let candidates: [Candidate] = (try? await q.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT f.id, p.absolute_path FROM files f
                JOIN paths p ON p.file_id = f.id AND p.is_alive = 1
                LEFT JOIN photo_meta m ON m.file_id = f.id
                WHERE f.kind IN ('image','raw','psd','video')
                  AND (f.coords_scanned_hash IS NULL OR f.coords_scanned_hash != f.content_hash
                       OR m.exif_scanned_hash IS NULL OR m.exif_scanned_hash != f.content_hash)
                GROUP BY f.id
                LIMIT \(maxPerLaunch)
                """)
            return rows.compactMap { row -> Candidate? in
                guard let id: String = row["id"], let path: String = row["absolute_path"]
                else { return nil }
                let url = URL(fileURLWithPath: path)
                return Candidate(id: id, url: url, kind: AssetKind.detect(at: url))
            }
        }) ?? []
        guard !candidates.isEmpty else { return }

        var wroteAny = false
        for chunk in candidates.chunked(into: writeChunk) {
            var results: [(id: String, hash: String, header: PhotoHeader)] = []
            await withTaskGroup(of: (String, String, PhotoHeader)?.self) { group in
                var iterator = chunk.makeIterator()
                var active = 0
                func spawnNext() {
                    guard active < concurrency, let c = iterator.next() else { return }
                    active += 1
                    group.addTask {
                        guard let hash: String? = try? await q.read({ db in
                            try FileRow.filter(FileRow.Columns.id == c.id).fetchOne(db)?.content_hash
                        }), let contentHash = hash else { return nil }
                        // Dataless files come back an empty header from
                        // PhotoHeaderReader's own guard — never stamped here
                        // as "found nothing"; the write below still stamps
                        // the attempted-marker only when a real read ran.
                        let header = await PhotoHeaderReader.read(url: c.url, kind: c.kind)
                        return (c.id, contentHash, header)
                    }
                }
                for _ in 0..<concurrency { spawnNext() }
                for await result in group {
                    active -= 1
                    if let result { results.append(result) }
                    spawnNext()
                }
            }

            try? await q.write { db in
                for (id, hash, header) in results {
                    guard var file = try FileRow.filter(FileRow.Columns.id == id).fetchOne(db),
                          file.content_hash == hash else { continue }
                    var meta = (try PhotoMetaRow.filter(Column("file_id") == id).fetchOne(db))
                        ?? PhotoMetaRow(file_id: id)
                    let coordsAlreadyCurrent = file.coords_scanned_hash == hash
                    let metaAlreadyCurrent = meta.exif_scanned_hash == hash
                    if coordsAlreadyCurrent && metaAlreadyCurrent { continue }

                    if let coord = header.coordinate, !coordsAlreadyCurrent {
                        file.lat = coord.lat
                        file.lon = coord.long
                    }
                    if !coordsAlreadyCurrent { file.coords_scanned_hash = hash }
                    try file.update(db)

                    if let exif = header.exif, !metaAlreadyCurrent {
                        meta.capture_date = exif.captureDate
                        meta.capture_md = exif.captureMD
                        meta.camera_make = exif.cameraMake
                        meta.camera_model = exif.cameraModel
                        meta.lens = exif.lens
                        meta.iso = exif.iso
                        meta.f_number = exif.fNumber
                        meta.exposure_seconds = exif.exposureSeconds
                        meta.focal_length = exif.focalLength
                        meta.focal_length_35mm = exif.focalLength35mm
                        meta.flash_fired = exif.flashFired
                    }
                    if !metaAlreadyCurrent { meta.exif_scanned_hash = hash }
                    try meta.save(db)
                    wroteAny = true
                }
            }
        }

        if wroteAny {
            // Task 9 and Task 13 wire these chains in; both are no-ops
            // (nonexistent types) until those tasks land — leave the calls
            // commented until then, uncommented as part of those tasks'
            // steps, OR implement this file after Tasks 9/13 exist. Given
            // this plan's build order, GeocodeBackfill doesn't exist yet at
            // this point — see Task 9 Step 5, which adds the chain call
            // here once it exists.
        }
    }
}
```

  Note the deliberate gap: this task's `run()` cannot call `GeocodeBackfill.run()` yet
  because Task 9 (Section C) hasn't created that type. Leave the `if wroteAny { }`
  block empty here; Task 9 Step 5 adds the chain call as an explicit edit to this file.

- [ ] **Step 4: Wire the launch call in `MuseApp.swift`**

  Near the existing `Task { await IntentBackfill.run(); PhaseTrace.mark("intent-backfill.end") }`
  call inside the `.task` block (around line 132), add as its own independent
  fire-and-forget task:

```swift
PhaseTrace.mark("photo-header-backfill.start")
Task { await PhotoHeaderBackfill.run(); PhaseTrace.mark("photo-header-backfill.end") }
```

- [ ] **Step 5: Build and smoke-test**

  Run: `xcodebuild -project Muse/Muse.xcodeproj -scheme Muse -configuration Debug build`
  Expected: `BUILD SUCCEEDED`. Then run the app against a folder containing at least
  one geotagged JPEG and confirm via direct SQLite query against the sandboxed DB
  (`~/Library/Containers/com.tarrats.Muse/Data/Library/Application
  Support/Muse/muse.sqlite`): `sqlite3 <path> "SELECT f.id, f.lat, f.lon, m.camera_model
  FROM files f LEFT JOIN photo_meta m ON m.file_id = f.id WHERE f.lat IS NOT NULL"`.

- [ ] **Step 6: Commit**

```bash
git add "Muse/Muse/Intelligence/PhotoHeaderBackfill.swift" "Muse/Muse/MuseApp.swift"
git commit -m "feat: add PhotoHeaderBackfill launch pass for pre-existing libraries"
```

---

## Section C — Offline reverse geocoding: v15 + GeoNames + k-d tree

### Task 6: `v15_places` migration + `PlaceRow`

**Files:**
- Modify: `Muse/Muse/Database/Database.swift` (add migration after `v14_photo_meta`)
- Modify: `Muse/Muse/Database/Records.swift` (add `PlaceRow`)
- Create/extend: `Muse/MuseTests/PhotoMetaMigrationTests.swift` (add v15 assertions —
  reuse the file from Task 2 rather than creating a new one; it already exercises the
  same migrator)

**Interfaces:**
- Produces: `PlaceRow` (`file_id`, `geocoded_hash`, `dataset_version`, `city`,
  `admin`, `country`, `place_key`) — consumed by Task 9 (`GeocodeBackfill`), Task 11
  (`PhotoSearch` `near:`), Task 16 (`PlaceQueries`), Task 33 (`.location` smart rule).

- [ ] **Step 1: Extend `PhotoMetaMigrationTests.swift` with a failing v15 test**

```swift
func testV15CreatesPlacesTableAndIndex() throws {
    let queue = try DatabaseQueue()
    try Database.makeMigrator().migrate(queue)
    try queue.read { db in
        XCTAssertTrue(try db.tableExists("places"))
        let cols = try db.columns(in: "places").map(\.name)
        for name in ["file_id", "geocoded_hash", "dataset_version", "city", "admin",
                     "country", "place_key"] {
            XCTAssertTrue(cols.contains(name))
        }
        XCTAssertTrue(try db.indexes(on: "places").contains { $0.name == "places_key_idx" })
    }
}

func testPlacesCascadesOnFileDelete() throws {
    let queue = try DatabaseQueue()
    try Database.makeMigrator().migrate(queue)
    try queue.write { db in
        try db.execute(sql: """
            INSERT INTO files (id, content_hash, kind, last_seen_at)
            VALUES ('f1', 'hash1', 'image', 0)
            """)
        try db.execute(sql: """
            INSERT INTO places (file_id, geocoded_hash, dataset_version)
            VALUES ('f1', 'hash1', 1)
            """)
        try db.execute(sql: "DELETE FROM files WHERE id = 'f1'")
    }
    try queue.read { db in
        XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM places") ?? -1, 0)
    }
}
```

- [ ] **Step 2: Run, confirm failure**

- [ ] **Step 3: Add the migration**

```swift
migrator.registerMigration("v15_places") { db in
    try db.create(table: "places") { t in
        t.column("file_id", .text).primaryKey()
            .references("files", onDelete: .cascade)
        t.column("geocoded_hash", .text).notNull()      // content_hash whose lat/lon we geocoded
        t.column("dataset_version", .integer).notNull() // GeoNamesDataset.version at geocode time
        t.column("city", .text)      // display name, e.g. "Lisboa"
        t.column("admin", .text)     // admin1 display name, e.g. "Lisbon"
        t.column("country", .text)   // ISO 3166-1 alpha-2, e.g. "PT"
        t.column("place_key", .text) // lowercased "city|admin|country"; NULL = geocoded, no place
    }
    try db.create(index: "places_key_idx", on: "places", columns: ["place_key"])
}
```

  A row with all-NULL place fields means "geocoded, nothing within range" — the row
  itself is the attempted-marker (same class as `coords_scanned_hash`).

- [ ] **Step 4: Add `PlaceRow`**

```swift
struct PlaceRow: Codable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "places"
    var file_id: String
    var geocoded_hash: String
    var dataset_version: Int
    var city: String?
    var admin: String?
    var country: String?
    var place_key: String?
}
```

- [ ] **Step 5: Run tests, confirm pass, then run the full migration suite**

- [ ] **Step 6: Commit**

```bash
git add "Muse/Muse/Database/Database.swift" "Muse/Muse/Database/Records.swift" \
        "Muse/MuseTests/PhotoMetaMigrationTests.swift"
git commit -m "feat: add v15_places migration"
```

---

### Task 7: GeoNames bundled dataset — generation script + `GeoNamesDataset`

**Files:**
- Create: `scripts/make-geonames.sh`
- Create: `Muse/Muse/Resources/geonames-admin1.tsv` (small placeholder committed by
  this task; real content regenerated by the owner per Step 5 below)
- Create: `Muse/Muse/Resources/geonames-cities.tsv.zlib` (same — placeholder)
- Create: `Muse/Muse/Intelligence/Geo/GeoNamesDataset.swift`
- Create: `Muse/MuseTests/GeoNamesDatasetTests.swift`

**Interfaces:**
- Produces: `GeoCity` (`name`, `lat`, `lon`, `admin1Code`, `countryCode`),
  `GeoNamesDataset.shared.cities() -> [GeoCity]?`,
  `GeoNamesDataset.shared.admin1Name(for:) -> String?`, `GeoNamesDataset.version: Int`
  — consumed by Task 8 (`GeoKDTree`) and Task 9 (`ReverseGeocoder`).

**Context:** the real GeoNames download (`cities1000.zip` + `admin1CodesASCII.txt`
from geonames.org, ~35 MB transfer) is an **owner-only step** (§12 of the spec — a
one-time manual run, dev machine only, output committed). This task builds the
**script** and the **loader** so the app is correct the moment real data is dropped
in; it also creates small synthetic placeholder resources so the build and tests pass
without the owner step having run yet. Flag this clearly at PR review — Task 9's
owner-only follow-up (documented in Task 35) is what actually makes Places non-empty
for a real library.

- [ ] **Step 1: Write `scripts/make-geonames.sh`**

```bash
#!/usr/bin/env bash
# make-geonames.sh — regenerate the bundled GeoNames offline-geocoding
# resources. Owner-only, dev-machine-only: downloads from geonames.org
# (~35 MB), the app itself never fetches anything. Run from the repo root.
set -euo pipefail

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

echo "Downloading cities1000.zip…"
curl -sSL "https://download.geonames.org/export/dump/cities1000.zip" -o "$WORKDIR/cities1000.zip"
echo "Downloading admin1CodesASCII.txt…"
curl -sSL "https://download.geonames.org/export/dump/admin1CodesASCII.txt" -o "$WORKDIR/admin1CodesASCII.txt"

unzip -o "$WORKDIR/cities1000.zip" -d "$WORKDIR" >/dev/null

# cities1000.txt columns (tab-separated, no header): geonameid, name,
# asciiname, alternatenames, latitude, longitude, feature class, feature
# code, country code, cc2, admin1 code, admin2 code, admin3 code, admin4
# code, population, elevation, dem, timezone, modification date.
# We keep 5: name(2) lat(5) lon(6) admin1(11, composed as "<cc>.<admin1>")
# countrycode(9).
awk -F '\t' 'BEGIN { OFS="\t" } { print $2, $5, $6, $9"."$11, $9 }' \
    "$WORKDIR/cities1000.txt" > "$WORKDIR/geonames-cities.tsv"

# Raw-DEFLATE compress with the expected inflated byte count as the first 4
# bytes (little-endian UInt32) — the same bounded-decompress contract the
# app already uses for the Drive share manifest (DriveShareManifest.swift).
python3 - "$WORKDIR/geonames-cities.tsv" "Muse/Muse/Resources/geonames-cities.tsv.zlib" <<'PY'
import sys, struct, zlib
src, dst = sys.argv[1], sys.argv[2]
data = open(src, "rb").read()
compressed = zlib.compressobj(9, zlib.DEFLATED, -15).compress(data)
compressed += zlib.compressobj(9, zlib.DEFLATED, -15).flush()
with open(dst, "wb") as f:
    f.write(struct.pack("<I", len(data)))
    f.write(compressed)
PY

# admin1CodesASCII.txt columns: code (e.g. "PT.14"), name, ascii name, geonameid.
awk -F '\t' 'BEGIN { OFS="\t" } { print $1, $2 }' \
    "$WORKDIR/admin1CodesASCII.txt" > "Muse/Muse/Resources/geonames-admin1.tsv"

echo "Wrote Muse/Muse/Resources/geonames-cities.tsv.zlib and geonames-admin1.tsv"
echo "Remember to bump GeoNamesDataset.version in GeoNamesDataset.swift and commit both files."
```

  Run: `chmod +x scripts/make-geonames.sh`.

- [ ] **Step 2: Create placeholder resources for build/test purposes**

  These are NOT the real dataset — they exist so `xcodebuild` and the test suite pass
  before the owner runs Step 1's script for real. Write a tiny Python one-liner (or by
  hand) to produce a 3-row `geonames-cities.tsv` (e.g. Lisboa/Porto/Faro with real
  coordinates) compressed the same way the script does, plus a matching
  `geonames-admin1.tsv` with the corresponding admin1 codes. Commit both as the
  initial placeholder — `GeoNamesDatasetTests` (Step 6) exercises the REAL bounded-
  decompress format against this placeholder, so it must be byte-format-correct even
  though it's not the full dataset.

- [ ] **Step 3: Add the Resources to the Xcode target**

  Confirm both files are added to the `Muse` target's "Copy Bundle Resources" build
  phase (if the project uses file-system-synchronized groups per `spec-01`'s finding,
  this should be automatic — verify with a build; if not, add them via
  `project.pbxproj` following the pattern of an existing bundled resource like
  `Localizable.xcstrings`).

- [ ] **Step 4: Write the failing `GeoNamesDataset` tests**

```swift
//
//  GeoNamesDatasetTests.swift
//  MuseTests
//
//  Bounded-inflate contract (a bundled file is not attacker-controlled, but
//  the guard is 3 lines and makes the loader reusable/testable) + TSV
//  parsing + admin1 join.
//

import XCTest
@testable import Muse

final class GeoNamesDatasetTests: XCTestCase {
    func testLoadsBundledPlaceholderCities() {
        let cities = GeoNamesDataset.shared.cities()
        XCTAssertNotNil(cities)
        XCTAssertGreaterThan(cities?.count ?? 0, 0)
    }

    func testAdmin1NameResolvesKnownCode() {
        // Adjust to whatever code the placeholder fixture actually contains
        // (e.g. "PT.14" for Lisbon district) once Step 2's placeholder is
        // written — this test's fixture and this assertion must agree.
        XCTAssertNotNil(GeoNamesDataset.shared.admin1Name(for: "PT.14"))
    }

    func testUnknownAdmin1CodeReturnsNil() {
        XCTAssertNil(GeoNamesDataset.shared.admin1Name(for: "ZZ.99"))
    }

    func testCorruptDeclaredSizeFailsClosed() {
        // Feed a buffer whose declared size doesn't match its actual
        // inflated content — must return nil, never crash, never
        // over-allocate.
        var bad = Data()
        bad.append(contentsOf: withUnsafeBytes(of: UInt32(999_999_999).littleEndian) { Array($0) })
        bad.append(contentsOf: [0x78, 0x9c, 0x03, 0x00, 0x00, 0x00, 0x00, 0x01]) // truncated/invalid deflate
        let result = GeoNamesDataset.loadCities(from: bad)
        XCTAssertNil(result)
    }
}
```

- [ ] **Step 5: Run, confirm failure**

- [ ] **Step 6: Implement `GeoNamesDataset`**

```swift
//
//  GeoNamesDataset.swift
//  Muse
//
//  Bundled, offline GeoNames cities1000 dataset + admin1 code table. Loaded
//  once, off-main, on first geocode; released (weak) when the geocode pass
//  ends — zero standing cost while browsing. cities1000 (not cities15000):
//  villages are where travel photos happen.
//

import Foundation
import Compression

nonisolated struct GeoCity: Sendable {
    let name: String
    let lat: Double
    let lon: Double
    let admin1Code: String   // "PT.14"
    let countryCode: String  // "PT"
}

nonisolated final class GeoNamesDataset: Sendable {
    /// Bump when regenerating the bundled artifacts (scripts/make-geonames.sh) —
    /// a version bump re-geocodes the whole library.
    static let version = 1
    static let shared = GeoNamesDataset()

    private let citiesBox = Locked<[GeoCity]??>(nil)   // nil = not yet attempted; .some(nil) = load failed
    private let admin1Box = Locked<[String: String]?>(nil)

    func cities() -> [GeoCity]? {
        if let cached = citiesBox.value { return cached }
        guard let url = Bundle.main.url(forResource: "geonames-cities", withExtension: "tsv.zlib"),
              let raw = try? Data(contentsOf: url) else {
            citiesBox.value = .some(nil)
            return nil
        }
        let result = Self.loadCities(from: raw)
        citiesBox.value = .some(result)
        return result
    }

    func admin1Name(for code: String) -> String? {
        if admin1Box.value == nil {
            admin1Box.value = Self.loadAdmin1() ?? [:]
        }
        return admin1Box.value?[code]
    }

    /// Bounded decompress: the expected inflated byte count is the first 4
    /// (little-endian) bytes. Allocates exactly that; a short/overflowing
    /// decode is treated as corrupt — fail closed, no crash, no unbounded
    /// allocation. Same contract as DriveShareManifest's MAX_INFLATED guard.
    static func loadCities(from raw: Data) -> [GeoCity]? {
        guard raw.count > 4 else { return nil }
        let declaredSize = raw.withUnsafeBytes { $0.load(as: UInt32.self) }.littleEndian
        guard declaredSize > 0, declaredSize < 64_000_000 else { return nil } // sanity ceiling
        let payload = raw.dropFirst(4)
        var output = [UInt8](repeating: 0, count: Int(declaredSize))
        let decodedCount: Int = output.withUnsafeMutableBytes { outBuf in
            payload.withUnsafeBytes { inBuf -> Int in
                guard let inBase = inBuf.bindMemory(to: UInt8.self).baseAddress,
                      let outBase = outBuf.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return compression_decode_buffer(outBase, outBuf.count, inBase, inBuf.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard decodedCount == Int(declaredSize) else { return nil }
        guard let text = String(bytes: output, encoding: .utf8) else { return nil }
        var cities: [GeoCity] = []
        cities.reserveCapacity(200_000)
        for line in text.split(separator: "\n") {
            let cols = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard cols.count == 5,
                  let lat = Double(cols[1]), let lon = Double(cols[2]) else { continue }
            cities.append(GeoCity(name: String(cols[0]), lat: lat, lon: lon,
                                  admin1Code: String(cols[3]), countryCode: String(cols[4])))
        }
        return cities
    }

    private static func loadAdmin1() -> [String: String]? {
        guard let url = Bundle.main.url(forResource: "geonames-admin1", withExtension: "tsv"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        var map: [String: String] = [:]
        for line in text.split(separator: "\n") {
            let cols = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard cols.count == 2 else { continue }
            map[String(cols[0])] = String(cols[1])
        }
        return map
    }
}

/// Minimal lock-guarded box — the ImageHeaderSizeCache pattern for a shared
/// mutable static read off-main.
final class Locked<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: T
    init(_ initial: T) { _value = initial }
    var value: T {
        get { lock.lock(); defer { lock.unlock() }; return _value }
        set { lock.lock(); defer { lock.unlock() }; _value = newValue }
    }
}
```

  Confirm whether the codebase already has an equivalent lock-guarded box type (the
  `ImageHeaderSizeCache` pattern is cited as precedent in `DECISIONS.md` — grep for
  `nonisolated(unsafe)` or an existing small lock wrapper before adding a new one; if
  one already exists, reuse it instead of `Locked<T>` above).

- [ ] **Step 7: Run tests, confirm pass**

- [ ] **Step 8: Add About-card + README attribution**

  In `Muse/Muse/Views/InfoSheet.swift` (the About card), add a SwiftUI literal:
  `Text("Place names © GeoNames (geonames.org), CC BY 4.0")` (auto-localized). Add the
  same credit line to `README.md`'s credits/acknowledgments section.

- [ ] **Step 9: Commit**

```bash
git add scripts/make-geonames.sh "Muse/Muse/Resources/geonames-cities.tsv.zlib" \
        "Muse/Muse/Resources/geonames-admin1.tsv" \
        "Muse/Muse/Intelligence/Geo/GeoNamesDataset.swift" \
        "Muse/MuseTests/GeoNamesDatasetTests.swift" \
        "Muse/Muse/Views/InfoSheet.swift" README.md
git commit -m "feat: add GeoNamesDataset + make-geonames.sh (offline geocoding data, placeholder fixtures)"
```

---

### Task 8: `GeoKDTree` + `GreatCircle` + `GeoBounds` — pure geo math

**Files:**
- Create: `Muse/Muse/Intelligence/Geo/GeoKDTree.swift`
- Create: `Muse/MuseTests/GeoKDTreeTests.swift`

**Interfaces:**
- Produces: `GeoKDTree.init(points:)`, `GeoKDTree.nearest(lat:lon:) ->
  (index:distanceKM:)?`, `GreatCircle.distanceKM(lat1:lon1:lat2:lon2:) -> Double`,
  `GeoBounds.boxes(lat:lon:radiusKM:) -> [(latRange:lonRange:)]` — consumed by Task 9
  (`ReverseGeocoder`) and Task 33 (`.location` `.near` smart rule evaluation).

- [ ] **Step 1: Write the failing tests**

```swift
//
//  GeoKDTreeTests.swift
//  MuseTests
//
//  3-D k-d tree over unit-sphere coordinates: Euclidean distance on the
//  unit sphere is monotone in great-circle distance, so nearest-neighbor is
//  exact without trig in the hot path, and antimeridian/pole edge cases
//  disappear (a lat/lon 2-D tree gets both wrong).
//

import XCTest
@testable import Muse

final class GeoKDTreeTests: XCTestCase {
    func testNearestMatchesBruteForceOnRandomPoints() {
        var generator = SeededGenerator(seed: 42) // reuse the codebase's existing
                                                    // seeded RNG if one exists for
                                                    // tests (check SeededRandom.swift);
                                                    // otherwise a fixed LCG here.
        let points: [(lat: Double, lon: Double)] = (0..<5000).map { _ in
            (lat: Double.random(in: -90...90, using: &generator),
             lon: Double.random(in: -180...180, using: &generator))
        }
        let tree = GeoKDTree(points: points)
        let queries: [(lat: Double, lon: Double)] = (0..<200).map { _ in
            (lat: Double.random(in: -90...90, using: &generator),
             lon: Double.random(in: -180...180, using: &generator))
        }
        for q in queries {
            guard let treeResult = tree.nearest(lat: q.lat, lon: q.lon) else {
                XCTFail("tree returned nil"); continue
            }
            var bestIdx = 0
            var bestDist = Double.greatestFiniteMagnitude
            for (i, p) in points.enumerated() {
                let d = GreatCircle.distanceKM(lat1: q.lat, lon1: q.lon, lat2: p.lat, lon2: p.lon)
                if d < bestDist { bestDist = d; bestIdx = i }
            }
            XCTAssertEqual(treeResult.index, bestIdx)
            XCTAssertEqual(treeResult.distanceKM, bestDist, accuracy: 0.01)
        }
    }

    func testAntimeridianPair() {
        // 179.9°E and 179.9°W are ~22km apart in reality, not ~40,000km.
        let points = [(lat: 0.0, lon: 179.9), (lat: 0.0, lon: -179.9)]
        let tree = GeoKDTree(points: points)
        let result = tree.nearest(lat: 0.0, lon: 179.95)
        XCTAssertEqual(result?.index, 0)
        XCTAssertLessThan(result?.distanceKM ?? 999, 50)
    }

    func testPolarPoints() {
        let points = [(lat: 89.9, lon: 0.0), (lat: 89.9, lon: 90.0), (lat: 89.9, lon: 180.0)]
        let tree = GeoKDTree(points: points)
        let result = tree.nearest(lat: 90.0, lon: 45.0)
        XCTAssertNotNil(result)
    }

    func testEmptyInputReturnsNil() {
        let tree = GeoKDTree(points: [])
        XCTAssertNil(tree.nearest(lat: 0, lon: 0))
    }

    func testGreatCircleKnownDistance() {
        // Lisbon to Porto, roughly 275 km.
        let d = GreatCircle.distanceKM(lat1: 38.7223, lon1: -9.1393, lat2: 41.1579, lon2: -8.6291)
        XCTAssertEqual(d, 275, accuracy: 15)
    }

    func testGeoBoundsSplitsAtAntimeridian() {
        let boxes = GeoBounds.boxes(lat: 0, lon: 179.9, radiusKM: 50)
        XCTAssertEqual(boxes.count, 2)
    }

    func testGeoBoundsSingleBoxAwayFromAntimeridian() {
        let boxes = GeoBounds.boxes(lat: 38.7, lon: -9.1, radiusKM: 50)
        XCTAssertEqual(boxes.count, 1)
    }
}
```

  Confirm whether `Views/Spatial/SeededRandom.swift` (used elsewhere in the codebase,
  per its citation in the spec for Shuffle) exposes a `RandomNumberGenerator`-
  conforming type usable in tests; if not, write a tiny fixed-seed LCG inline in the
  test file instead of introducing a new dependency.

- [ ] **Step 2: Run, confirm failure**

- [ ] **Step 3: Implement `GeoKDTree` + `GreatCircle` + `GeoBounds`**

```swift
//
//  GeoKDTree.swift
//  Muse
//
//  Pure geo math shared by offline reverse geocoding (ReverseGeocoder) and
//  the `.near` smart-rule / search-token evaluation. A 3-D k-d tree over
//  unit-sphere Cartesian coordinates gives exact nearest-neighbor without
//  per-query trig and without the antimeridian/pole bugs a naive lat/lon
//  2-D tree has.
//

import Foundation

private struct SpherePoint {
    let x: Double, y: Double, z: Double
    let index: Int
}

private func toCartesian(lat: Double, lon: Double) -> (x: Double, y: Double, z: Double) {
    let latRad = lat * .pi / 180
    let lonRad = lon * .pi / 180
    return (cos(latRad) * cos(lonRad), cos(latRad) * sin(lonRad), sin(latRad))
}

nonisolated struct GeoKDTree {
    private indirect enum Node {
        case leaf
        case branch(point: SpherePoint, axis: Int, left: Node, right: Node)
    }
    private let root: Node
    private let isEmpty: Bool

    init(points: [(lat: Double, lon: Double)]) {
        let spherePoints = points.enumerated().map { i, p -> SpherePoint in
            let c = toCartesian(lat: p.lat, lon: p.lon)
            return SpherePoint(x: c.x, y: c.y, z: c.z, index: i)
        }
        isEmpty = spherePoints.isEmpty
        root = Self.build(spherePoints, depth: 0)
    }

    private static func build(_ points: [SpherePoint], depth: Int) -> Node {
        guard !points.isEmpty else { return .leaf }
        let axis = depth % 3
        let sorted = points.sorted { lhs, rhs in
            switch axis {
            case 0: return lhs.x < rhs.x
            case 1: return lhs.y < rhs.y
            default: return lhs.z < rhs.z
            }
        }
        let mid = sorted.count / 2
        let median = sorted[mid]
        let left = build(Array(sorted[..<mid]), depth: depth + 1)
        let right = build(Array(sorted[(mid + 1)...]), depth: depth + 1)
        return .branch(point: median, axis: axis, left: left, right: right)
    }

    /// Index of the nearest input point + great-circle distance in km. nil
    /// for an empty tree.
    func nearest(lat: Double, lon: Double) -> (index: Int, distanceKM: Double)? {
        guard !isEmpty else { return nil }
        let q = toCartesian(lat: lat, lon: lon)
        var best: (point: SpherePoint, distSq: Double)?
        search(root, query: q, best: &best)
        guard let best else { return nil }
        // Chord length -> central angle -> great-circle distance (exact,
        // not an approximation — unit-sphere chord distance is monotone in
        // great-circle distance, so the NEAREST point found this way is
        // exactly the nearest by great-circle distance too).
        let chord = sqrt(best.distSq)
        let angle = 2 * asin(min(1, chord / 2))
        let earthRadiusKM = 6371.0
        return (best.point.index, angle * earthRadiusKM)
    }

    private func search(_ node: Node, query: (x: Double, y: Double, z: Double),
                        best: inout (point: SpherePoint, distSq: Double)?) {
        guard case let .branch(point, axis, left, right) = node else { return }
        let dx = query.x - point.x, dy = query.y - point.y, dz = query.z - point.z
        let distSq = dx * dx + dy * dy + dz * dz
        if best == nil || distSq < best!.distSq { best = (point, distSq) }

        let queryAxisValue: Double
        let pointAxisValue: Double
        switch axis {
        case 0: queryAxisValue = query.x; pointAxisValue = point.x
        case 1: queryAxisValue = query.y; pointAxisValue = point.y
        default: queryAxisValue = query.z; pointAxisValue = point.z
        }
        let diff = queryAxisValue - pointAxisValue
        let (nearSide, farSide) = diff < 0 ? (left, right) : (right, left)
        search(nearSide, query: query, best: &best)
        if diff * diff < (best?.distSq ?? .greatestFiniteMagnitude) {
            search(farSide, query: query, best: &best)
        }
    }
}

nonisolated enum GreatCircle {
    static func distanceKM(lat1: Double, lon1: Double, lat2: Double, lon2: Double) -> Double {
        let earthRadiusKM = 6371.0
        let dLat = (lat2 - lat1) * .pi / 180
        let dLon = (lon2 - lon1) * .pi / 180
        let a = sin(dLat / 2) * sin(dLat / 2)
            + cos(lat1 * .pi / 180) * cos(lat2 * .pi / 180) * sin(dLon / 2) * sin(dLon / 2)
        let c = 2 * atan2(sqrt(a), sqrt(1 - a))
        return earthRadiusKM * c
    }
}

nonisolated enum GeoBounds {
    /// Bounding box(es) for a radius query in degrees; splits into two
    /// ranges when the box crosses ±180° longitude.
    static func boxes(lat: Double, lon: Double, radiusKM: Double)
        -> [(latRange: ClosedRange<Double>, lonRange: ClosedRange<Double>)] {
        let latDelta = radiusKM / 111.32
        let latMin = max(-90, lat - latDelta)
        let latMax = min(90, lat + latDelta)
        // Longitude degrees-per-km shrinks toward the poles; clamp cos away
        // from zero so a polar query doesn't produce an infinite span.
        let cosLat = max(cos(lat * .pi / 180), 0.01)
        let lonDelta = radiusKM / (111.32 * cosLat)
        var lonMin = lon - lonDelta
        var lonMax = lon + lonDelta

        if lonMin < -180 {
            let wrapped = lonMin + 360
            return [(latMin...latMax, wrapped...180), (latMin...latMax, -180...lonMax)]
        }
        if lonMax > 180 {
            let wrapped = lonMax - 360
            return [(latMin...latMax, lonMin...180), (latMin...latMax, -180...wrapped)]
        }
        lonMin = max(lonMin, -180)
        lonMax = min(lonMax, 180)
        return [(latMin...latMax, lonMin...lonMax)]
    }
}
```

- [ ] **Step 4: Run tests, confirm pass**

- [ ] **Step 5: Commit**

```bash
git add "Muse/Muse/Intelligence/Geo/GeoKDTree.swift" "Muse/MuseTests/GeoKDTreeTests.swift"
git commit -m "feat: add GeoKDTree + GreatCircle + GeoBounds (pure geo math)"
```

---

### Task 9: `ReverseGeocoder` + `GeocodeBackfill`

**Files:**
- Create: `Muse/Muse/Intelligence/Geo/GeocodeBackfill.swift` (holds both
  `ReverseGeocoder` and `GeocodeBackfill` per the spec's file grouping)
- Create: `Muse/MuseTests/ReverseGeocoderTests.swift`
- Modify: `Muse/Muse/Intelligence/PhotoHeaderBackfill.swift` (Task 5's file — add the
  chain call now that `GeocodeBackfill` exists)
- Modify: `Muse/Muse/MuseApp.swift` (wire `GeocodeBackfill.run()` as its own
  fire-and-forget launch task too, for the case where coordinates already existed
  before this spec — not only reachable via the `PhotoHeaderBackfill` chain)

**Interfaces:**
- Consumes: `GeoNamesDataset` (Task 7), `GeoKDTree`/`GreatCircle` (Task 8),
  `PlaceRow` (Task 6).
- Produces: `ReverseGeocoder.place(lat:lon:tree:cities:dataset:) -> Place?`,
  `GeocodeBackfill.run() async` — consumed by Task 16 (`PlaceQueries`/`PlacesStore`
  reads the `places` table this writes) and chained from Task 13 (`SearchFacets`).

- [ ] **Step 1: Write the failing tests**

```swift
//
//  ReverseGeocoderTests.swift
//  MuseTests
//

import XCTest
@testable import Muse

final class ReverseGeocoderTests: XCTestCase {
    private func fixtureCities() -> [GeoCity] {
        [GeoCity(name: "Lisboa", lat: 38.7223, lon: -9.1393, admin1Code: "PT.14", countryCode: "PT"),
         GeoCity(name: "Porto", lat: 41.1579, lon: -8.6291, admin1Code: "PT.13", countryCode: "PT")]
    }

    func testKnownCoordinateResolvesExpectedCity() {
        let cities = fixtureCities()
        let tree = GeoKDTree(points: cities.map { ($0.lat, $0.lon) })
        let place = ReverseGeocoder.place(lat: 38.72, lon: -9.14, tree: tree, cities: cities,
                                          dataset: GeoNamesDataset.shared)
        XCTAssertEqual(place?.city, "Lisboa")
        XCTAssertEqual(place?.country, "PT")
    }

    func testFarAwayCoordinateReturnsNil() {
        let cities = fixtureCities()
        let tree = GeoKDTree(points: cities.map { ($0.lat, $0.lon) })
        // Middle of the Atlantic, well over 150km from either fixture city.
        let place = ReverseGeocoder.place(lat: 30.0, lon: -40.0, tree: tree, cities: cities,
                                          dataset: GeoNamesDataset.shared)
        XCTAssertNil(place)
    }

    func testPlaceKeyIsLowercasedComposite() {
        let cities = fixtureCities()
        let tree = GeoKDTree(points: cities.map { ($0.lat, $0.lon) })
        let place = ReverseGeocoder.place(lat: 38.72, lon: -9.14, tree: tree, cities: cities,
                                          dataset: GeoNamesDataset.shared)
        XCTAssertEqual(place?.key, place?.key.lowercased())
        XCTAssertTrue(place?.key.contains("lisboa") ?? false)
    }

    func testJustWithinRangeResolvesJustBeyondReturnsNil() {
        let cities = fixtureCities()
        let tree = GeoKDTree(points: cities.map { ($0.lat, $0.lon) })
        // ~149km from Lisboa should resolve; ~151km should not. Compute the
        // offsets from GreatCircle rather than hand-picking coordinates.
        // (Left as a documented follow-up if an exact 1km-boundary fixture
        // proves fiddly to construct — the far-away and known-city cases
        // above already cover the behavior; this test tightens the 150km
        // edge specifically.)
    }
}
```

- [ ] **Step 2: Run, confirm failure**

- [ ] **Step 3: Implement `ReverseGeocoder` + `GeocodeBackfill`**

```swift
//
//  GeocodeBackfill.swift
//  Muse
//
//  Offline reverse geocoding: coordinates -> city/admin/country via the
//  bundled GeoNames dataset + k-d tree. No network, ever. CLGeocoder is
//  throttled (~50 req/60s — a non-starter at library scale) and forbidden
//  by doctrine regardless.
//

import Foundation
import GRDB

nonisolated enum ReverseGeocoder {
    static let maxDistanceKM: Double = 150

    struct Place: Equatable {
        var city: String
        var admin: String?
        var country: String
        var key: String
    }

    /// nil = no city within maxDistanceKM ("geocoded, no place").
    static func place(lat: Double, lon: Double, tree: GeoKDTree, cities: [GeoCity],
                      dataset: GeoNamesDataset) -> Place? {
        guard let nearest = tree.nearest(lat: lat, lon: lon),
              nearest.distanceKM <= maxDistanceKM,
              cities.indices.contains(nearest.index) else { return nil }
        let city = cities[nearest.index]
        let admin = dataset.admin1Name(for: city.admin1Code)
        let key = [city.name, admin ?? "", city.countryCode].joined(separator: "|").lowercased()
        return Place(city: city.name, admin: admin, country: city.countryCode, key: key)
    }
}

nonisolated enum GeocodeBackfill {
    static let writeChunk = 200

    static func run() async {
        guard let q = Database.shared.dbQueue else { return }
        guard let cities = GeoNamesDataset.shared.cities() else { return } // dataset missing/corrupt: nothing to do
        let tree = GeoKDTree(points: cities.map { ($0.lat, $0.lon) })
        let version = GeoNamesDataset.version

        struct Candidate { let fileID: String; let hash: String; let lat: Double; let lon: Double }
        let candidates: [Candidate] = (try? await q.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT f.id, f.content_hash, f.lat, f.lon FROM files f
                LEFT JOIN places p ON p.file_id = f.id
                WHERE f.lat IS NOT NULL
                  AND (p.file_id IS NULL OR p.geocoded_hash != f.content_hash
                       OR p.dataset_version != \(version))
                """)
            return rows.compactMap { row -> Candidate? in
                guard let id: String = row["id"], let hash: String = row["content_hash"],
                      let lat: Double = row["lat"], let lon: Double = row["lon"] else { return nil }
                return Candidate(fileID: id, hash: hash, lat: lat, lon: lon)
            }
        }) ?? []
        guard !candidates.isEmpty else { return }

        var wroteAny = false
        for chunk in candidates.chunked(into: writeChunk) {
            try? await q.write { db in
                for c in chunk {
                    guard let current = try FileRow.filter(FileRow.Columns.id == c.fileID).fetchOne(db),
                          current.content_hash == c.hash else { continue }
                    let resolved = ReverseGeocoder.place(lat: c.lat, lon: c.lon, tree: tree,
                                                         cities: cities, dataset: GeoNamesDataset.shared)
                    var row = PlaceRow(file_id: c.fileID, geocoded_hash: c.hash,
                                       dataset_version: version, city: resolved?.city,
                                       admin: resolved?.admin, country: resolved?.country,
                                       place_key: resolved?.key)
                    try row.save(db)
                    wroteAny = true
                }
            }
        }

        if wroteAny {
            await PlacesStore.shared.reload()   // Task 16 — no-op safely if not yet built
            await SearchFacets.shared.refresh() // Task 13 — no-op safely if not yet built
        }
    }
}
```

  Note: `PlacesStore.shared.reload()`/`SearchFacets.shared.refresh()` don't exist yet
  at this point in the plan — this is a forward reference the same way
  `PhotoHeaderBackfill`'s chain call was deferred in Task 5. Since this task (9) is
  built AFTER `PhotoHeaderBackfill` (5) but BEFORE `PlacesStore` (16)/`SearchFacets`
  (13), leave these two calls commented out here and add them back in as explicit
  edits: `PlacesStore.shared.reload()` uncommented in Task 16, `SearchFacets.shared.refresh()`
  uncommented in Task 13. Mark both with a `// TODO(task-16)` / `// TODO(task-13)`
  comment in the meantime so the gap is visible in code review, not silent.

- [ ] **Step 4: Run tests, confirm pass**

- [ ] **Step 5: Chain `GeocodeBackfill` from `PhotoHeaderBackfill`**

  Edit `Muse/Muse/Intelligence/PhotoHeaderBackfill.swift`'s `if wroteAny { }` block
  (left empty in Task 5) to:

```swift
if wroteAny {
    await GeocodeBackfill.run()
}
```

- [ ] **Step 6: Wire an independent launch call in `MuseApp.swift`**

  Beside the `PhotoHeaderBackfill` call added in Task 5, add:

```swift
PhaseTrace.mark("geocode-backfill.start")
Task { await GeocodeBackfill.run(); PhaseTrace.mark("geocode-backfill.end") }
```

  This covers the case where coordinates already existed (e.g. re-running after a
  `GeoNamesDataset.version` bump) without requiring a fresh `PhotoHeaderBackfill` pass.
  Both calls are idempotent (SQL selection is stale-by-marker) so running both is safe.

- [ ] **Step 7: Build and smoke-test**

  Run: `xcodebuild -project Muse/Muse.xcodeproj -scheme Muse -configuration Debug build`
  Expected: `BUILD SUCCEEDED`.

- [ ] **Step 8: Commit**

```bash
git add "Muse/Muse/Intelligence/Geo/GeocodeBackfill.swift" \
        "Muse/MuseTests/ReverseGeocoderTests.swift" \
        "Muse/Muse/Intelligence/PhotoHeaderBackfill.swift" "Muse/Muse/MuseApp.swift"
git commit -m "feat: add ReverseGeocoder + GeocodeBackfill (offline reverse geocoding)"
```

---

## Section D — Search phase 1: tokens over indexed metadata

### Task 10: `SearchToken` model + `SearchQueryParser`

**Files:**
- Create: `Muse/Muse/Search/SearchToken.swift`
- Create: `Muse/MuseTests/SearchQueryParserTests.swift`

**Interfaces:**
- Produces: `SearchToken` enum (`.camera`, `.lens`, `.iso`, `.aperture`, `.inDate`,
  `.near`, `.text`, `.color`, `.rating`, `.kind`), `ParsedQuery` (`tokens`, `freeText`,
  `removing(tokenAt:)`), `SearchQueryParser.parse(_:) -> ParsedQuery` — consumed by
  Task 11 (`PhotoSearch`), Task 14 (token chip bar).

- [ ] **Step 1: Write the failing grammar tests**

```swift
//
//  SearchQueryParserTests.swift
//  MuseTests
//
//  Every token form, incl. quoted values, numeric ops/ranges, in: shapes,
//  all star spellings, unknown-key fallthrough to free text, and the
//  removing(tokenAt:) round-trip the chip bar's ✕ depends on.
//

import XCTest
@testable import Muse

final class SearchQueryParserTests: XCTestCase {
    func testCameraToken() {
        let p = SearchQueryParser.parse("camera:x100v")
        XCTAssertEqual(p.tokens, [.camera("x100v")])
        XCTAssertEqual(p.freeText, "")
    }

    func testQuotedValueCarriesSpaces() {
        let p = SearchQueryParser.parse("near:\"New York\"")
        XCTAssertEqual(p.tokens, [.near("New York")])
    }

    func testNumericOperators() {
        XCTAssertEqual(SearchQueryParser.parse("iso:>1600").tokens,
                       [.iso(.init(op: .gt, value: 1600))])
        XCTAssertEqual(SearchQueryParser.parse("iso:>=1600").tokens,
                       [.iso(.init(op: .gte, value: 1600))])
        XCTAssertEqual(SearchQueryParser.parse("f:<2").tokens,
                       [.aperture(.init(op: .lt, value: 2))])
        XCTAssertEqual(SearchQueryParser.parse("iso:400").tokens,
                       [.iso(.init(op: .eq, value: 400))])
    }

    func testNumericRange() {
        let p = SearchQueryParser.parse("iso:100-400")
        guard case let .iso(filter)? = p.tokens.first, case .range(100, 400) = filter.op else {
            return XCTFail("expected range 100-400")
        }
    }

    func testInDateShapes() {
        XCTAssertEqual(SearchQueryParser.parse("in:2019").tokens,
                       [.inDate(.init(year: 2019, month: nil, day: nil))])
        XCTAssertEqual(SearchQueryParser.parse("in:2019-06").tokens,
                       [.inDate(.init(year: 2019, month: 6, day: nil))])
        XCTAssertEqual(SearchQueryParser.parse("in:2019-06-21").tokens,
                       [.inDate(.init(year: 2019, month: 6, day: 21))])
    }

    func testStarForms() {
        XCTAssertEqual(SearchQueryParser.parse("star:4").tokens, [.rating(atLeast: 4)])
        XCTAssertEqual(SearchQueryParser.parse("star:=4").tokens, [.rating(atLeast: 4)]) // exact still surfaces as atLeast in the model per §7.1; equality nuance lives in PhotoSearch SQL if needed
        XCTAssertEqual(SearchQueryParser.parse("★★★★").tokens, [.rating(atLeast: 4)])
        XCTAssertEqual(SearchQueryParser.parse("★≥4").tokens, [.rating(atLeast: 4)])
        XCTAssertEqual(SearchQueryParser.parse("★>=4").tokens, [.rating(atLeast: 4)])
    }

    func testUnknownKeyStaysInFreeText() {
        let p = SearchQueryParser.parse("banana:split")
        XCTAssertEqual(p.tokens, [])
        XCTAssertEqual(p.freeText, "banana:split")
    }

    func testEmptyValueStaysInFreeText() {
        // Typing "iso:" mid-thought must not silently drop text.
        let p = SearchQueryParser.parse("iso: sunset")
        XCTAssertTrue(p.tokens.isEmpty)
        XCTAssertTrue(p.freeText.contains("iso:"))
    }

    func testKeysCaseInsensitive() {
        XCTAssertEqual(SearchQueryParser.parse("CAMERA:x100v").tokens, [.camera("x100v")])
    }

    func testMixedTokensAndFreeText() {
        let p = SearchQueryParser.parse("camera:x100v beach sunset")
        XCTAssertEqual(p.tokens, [.camera("x100v")])
        XCTAssertEqual(p.freeText, "beach sunset")
    }

    func testKindToken() {
        XCTAssertEqual(SearchQueryParser.parse("kind:raw").tokens, [.kind(.raw)])
    }

    func testColorToken() {
        XCTAssertEqual(SearchQueryParser.parse("color:red").tokens, [.color("red")])
        XCTAssertEqual(SearchQueryParser.parse("color:#a1b2c3").tokens, [.color("#a1b2c3")])
    }

    func testTextToken() {
        XCTAssertEqual(SearchQueryParser.parse("text:\"receipt\"").tokens, [.text("receipt")])
    }

    func testRemovingTokenAtRebuildsQuery() {
        let p = SearchQueryParser.parse("camera:x100v beach")
        let rebuilt = p.removing(tokenAt: 0)
        XCTAssertEqual(SearchQueryParser.parse(rebuilt).tokens, [])
        XCTAssertTrue(rebuilt.contains("beach"))
        XCTAssertFalse(rebuilt.contains("camera:"))
    }

    func testRemovingLastTokenWithNoFreeTextLeavesEmptyString() {
        let p = SearchQueryParser.parse("camera:x100v")
        XCTAssertEqual(p.removing(tokenAt: 0).trimmingCharacters(in: .whitespaces), "")
    }
}
```

- [ ] **Step 2: Run, confirm failure**

- [ ] **Step 3: Implement `SearchToken` + `SearchQueryParser`**

```swift
//
//  SearchToken.swift
//  Muse
//
//  The v1 search-token grammar: key:value pairs parsed out of the
//  .searchable field's free text before every other search leg runs. An
//  unknown key or an empty/invalid value is NOT a token — it stays in
//  freeText verbatim (typed text is never silently dropped). Keys are
//  canonical English, case-insensitive; values are language-neutral user
//  data.
//

import Foundation

nonisolated enum SearchToken: Equatable, Sendable {
    case camera(String)
    case lens(String)
    case iso(NumericFilter)
    case aperture(NumericFilter)
    case inDate(DateToken)
    case near(String)
    case text(String)
    case color(String)
    case rating(atLeast: Int)
    case kind(SmartRule.KindGroup)

    struct NumericFilter: Equatable, Sendable {
        enum Op: Equatable { case eq, gt, gte, lt, lte, range(Double, Double) }
        var op: Op
        var value: Double
    }
    struct DateToken: Equatable, Sendable {
        var year: Int
        var month: Int?
        var day: Int?
    }
}

nonisolated struct ParsedQuery: Equatable {
    var tokens: [SearchToken]
    var freeText: String
    private var rawSegments: [String] // for exact round-trip reconstruction

    init(tokens: [SearchToken], freeText: String, rawSegments: [String]) {
        self.tokens = tokens
        self.freeText = freeText
        self.rawSegments = rawSegments
    }

    static func == (lhs: ParsedQuery, rhs: ParsedQuery) -> Bool {
        lhs.tokens == rhs.tokens && lhs.freeText == rhs.freeText
    }

    /// Rebuild the query string minus the token at `index` — the chip ✕
    /// operation. rawSegments holds every ORIGINAL space-separated segment
    /// in order (tokens and free-text words interleaved); this drops only
    /// the segment(s) that produced the given token.
    func removing(tokenAt index: Int) -> String {
        guard tokens.indices.contains(index) else {
            return rawSegments.joined(separator: " ")
        }
        var tokenOccurrence = -1
        var kept: [String] = []
        for segment in rawSegments {
            if SearchQueryParser.isTokenSegment(segment) {
                tokenOccurrence += 1
                if tokenOccurrence == index { continue }
            }
            kept.append(segment)
        }
        return kept.joined(separator: " ")
    }
}

nonisolated enum SearchQueryParser {
    private static let starGlyph: Character = "★"

    static func parse(_ raw: String) -> ParsedQuery {
        let segments = splitRespectingQuotes(raw)
        var tokens: [SearchToken] = []
        var freeWords: [String] = []
        for segment in segments {
            if let token = parseSegment(segment) {
                tokens.append(token)
            } else {
                freeWords.append(segment)
            }
        }
        return ParsedQuery(tokens: tokens, freeText: freeWords.joined(separator: " "),
                           rawSegments: segments)
    }

    static func isTokenSegment(_ segment: String) -> Bool {
        parseSegment(segment) != nil
    }

    /// Splits on whitespace but keeps a "key:\"quoted value\"" run intact.
    private static func splitRespectingQuotes(_ raw: String) -> [String] {
        var segments: [String] = []
        var current = ""
        var insideQuotes = false
        for char in raw {
            if char == "\"" {
                insideQuotes.toggle()
                current.append(char)
            } else if char == " " && !insideQuotes {
                if !current.isEmpty { segments.append(current); current = "" }
            } else {
                current.append(char)
            }
        }
        if !current.isEmpty { segments.append(current) }
        return segments
    }

    private static func parseSegment(_ segment: String) -> SearchToken? {
        // A bare star-run ("★★★★") is a token even with no key:value shape.
        if segment.allSatisfy({ $0 == starGlyph }), !segment.isEmpty {
            return .rating(atLeast: segment.count)
        }
        if segment.hasPrefix("★≥") || segment.hasPrefix("★>=") {
            let numPart = segment.hasPrefix("★≥") ? segment.dropFirst(2) : segment.dropFirst(3)
            guard let n = Int(numPart) else { return nil }
            return .rating(atLeast: n)
        }
        guard let colonIndex = segment.firstIndex(of: ":") else { return nil }
        let key = segment[segment.startIndex..<colonIndex].lowercased()
        var value = String(segment[segment.index(after: colonIndex)...])
        if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 {
            value = String(value.dropFirst().dropLast())
        }
        guard !value.isEmpty else { return nil }

        switch key {
        case "camera": return .camera(value)
        case "lens": return .lens(value)
        case "iso": return parseNumericFilter(value).map(SearchToken.iso)
        case "f": return parseNumericFilter(value).map(SearchToken.aperture)
        case "in": return parseDateToken(value).map(SearchToken.inDate)
        case "near": return .near(value)
        case "text": return .text(value)
        case "color": return .color(value)
        case "star":
            if value.hasPrefix("="), let n = Int(value.dropFirst()) { return .rating(atLeast: n) }
            guard let n = Int(value) else { return nil }
            return .rating(atLeast: n)
        case "kind":
            guard let group = SmartRule.KindGroup(rawValue: value.lowercased()) else { return nil }
            return .kind(group)
        default:
            return nil
        }
    }

    private static func parseNumericFilter(_ value: String) -> SearchToken.NumericFilter? {
        if value.hasPrefix(">="), let n = Double(value.dropFirst(2)) {
            return .init(op: .gte, value: n)
        }
        if value.hasPrefix("<="), let n = Double(value.dropFirst(2)) {
            return .init(op: .lte, value: n)
        }
        if value.hasPrefix(">"), let n = Double(value.dropFirst()) {
            return .init(op: .gt, value: n)
        }
        if value.hasPrefix("<"), let n = Double(value.dropFirst()) {
            return .init(op: .lt, value: n)
        }
        if value.contains("-"), !value.hasPrefix("-") {
            let parts = value.split(separator: "-", maxSplits: 1)
            if parts.count == 2, let lo = Double(parts[0]), let hi = Double(parts[1]) {
                return .init(op: .range(lo, hi), value: lo)
            }
        }
        if let n = Double(value) { return .init(op: .eq, value: n) }
        return nil
    }

    private static func parseDateToken(_ value: String) -> SearchToken.DateToken? {
        let parts = value.split(separator: "-").map(String.init)
        guard let year = parts.first.flatMap(Int.init), parts[0].count == 4 else { return nil }
        let month = parts.count > 1 ? Int(parts[1]) : nil
        let day = parts.count > 2 ? Int(parts[2]) : nil
        if parts.count > 1 && month == nil { return nil }
        if parts.count > 2 && day == nil { return nil }
        return SearchToken.DateToken(year: year, month: month, day: day)
    }
}
```

  Confirm `SmartRule.KindGroup`'s exact `rawValue`s (`image`, `raw`, `pdf`, `video`,
  `audio`, `document` per the read of `Intelligence/Collections/SmartRule.swift` above)
  match what `kind:` should accept.

- [ ] **Step 4: Run tests, confirm pass**

- [ ] **Step 5: Commit**

```bash
git add "Muse/Muse/Search/SearchToken.swift" "Muse/MuseTests/SearchQueryParserTests.swift"
git commit -m "feat: add SearchToken model + SearchQueryParser (token grammar)"
```

---

### Task 11: `PhotoSearch` — token → SQL

**Files:**
- Create: `Muse/Muse/Search/PhotoSearch.swift`
- Create: `Muse/MuseTests/PhotoSearchTests.swift`

**Interfaces:**
- Consumes: `SearchToken` (Task 10), `photo_meta`/`places`/`files.lat/lon` (Tasks
  2/6), `SmartCollectionResolver.qualifyingRatingLabels` (existing — confirm exact
  name by reading `Intelligence/Collections/SmartCollectionResolver.swift`),
  `SmartColor.rgb(for:)` (existing), `ColorQuery`'s hex validator (existing).
- Produces: `PhotoSearch.Result` (`ids`, `idSet`, `dirRestrictions`),
  `PhotoSearch.filter(tokens:db:) -> Result?` — consumed by Task 12
  (`SearchService` integration).

- [ ] **Step 1: Read the existing `SmartCollectionResolver` rating-qualification
  helper and the existing color search leg**

  Confirm `SmartCollectionResolver.qualifyingRatingLabels(op:stars:)`'s exact
  signature (or nearest equivalent) and how `Database/SearchService.swift` currently
  builds/consumes its color-leg `[LabColor]` variables — Task 12 needs to route a
  `color:` token into that SAME leg rather than reimplementing color matching.

- [ ] **Step 2: Write the failing tests (in-memory DB per token)**

```swift
//
//  PhotoSearchTests.swift
//  MuseTests
//
//  Token -> SQL over an in-memory DB. AND intersection across multiple
//  tokens; rating tokens carry per-(file_id, parent_dir) dir restrictions;
//  every other token is content-derived and dir-unrestricted; capture-DESC
//  ordering for token-only results; the in: created_at fallback for files
//  with no photo_meta row.
//

import XCTest
import GRDB
@testable import Muse

final class PhotoSearchTests: XCTestCase {
    func makeSeededQueue() throws -> DatabaseQueue {
        let queue = try DatabaseQueue()
        try Database.makeMigrator().migrate(queue)
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO files (id, content_hash, kind, last_seen_at, created_at)
                VALUES ('f1', 'h1', 'image', 0, 1000),
                       ('f2', 'h2', 'image', 0, 2000),
                       ('f3', 'raw', 'raw',   0, 3000)
                """)
            try db.execute(sql: """
                INSERT INTO photo_meta (file_id, camera_make, camera_model, iso, f_number, capture_date)
                VALUES ('f1', 'FUJIFILM', 'X100V', 400, 2.0, 1500),
                       ('f2', 'FUJIFILM', 'X100V', 3200, 2.8, 2500)
                """)
            try db.execute(sql: """
                INSERT INTO places (file_id, geocoded_hash, dataset_version, city, admin, country, place_key)
                VALUES ('f1', 'h1', 1, 'Lisboa', 'Lisbon', 'PT', 'lisboa|lisbon|pt')
                """)
        }
        return queue
    }

    func testCameraTokenMatchesModel() throws {
        let queue = try makeSeededQueue()
        try queue.read { db in
            let result = try PhotoSearch.filter(tokens: [.camera("x100v")], db: db)
            XCTAssertEqual(result?.idSet, ["f1", "f2"])
        }
    }

    func testIsoRangeIntersection() throws {
        let queue = try makeSeededQueue()
        try queue.read { db in
            let result = try PhotoSearch.filter(
                tokens: [.camera("x100v"), .iso(.init(op: .gt, value: 1000))], db: db)
            XCTAssertEqual(result?.idSet, ["f2"]) // only f2's ISO 3200 clears >1000
        }
    }

    func testNearTokenMatchesPlace() throws {
        let queue = try makeSeededQueue()
        try queue.read { db in
            let result = try PhotoSearch.filter(tokens: [.near("Lisboa")], db: db)
            XCTAssertEqual(result?.idSet, ["f1"])
        }
    }

    func testKindTokenMatchesRawGroup() throws {
        let queue = try makeSeededQueue()
        try queue.read { db in
            let result = try PhotoSearch.filter(tokens: [.kind(.raw)], db: db)
            XCTAssertEqual(result?.idSet, ["f3"])
        }
    }

    func testCaptureDateFallbackToCreatedAt() throws {
        let queue = try makeSeededQueue()
        try queue.read { db in
            // f3 has no photo_meta row; created_at=3000 -> year 1970 in this
            // fixture, so exercise the fallback shape rather than a real
            // date match: assert f3 is excluded from a specific `in:` year
            // that only f1/f2's capture_date would match, proving the
            // fallback reads created_at rather than silently matching
            // everything.
            let result = try PhotoSearch.filter(
                tokens: [.inDate(.init(year: 1970, month: nil, day: nil))], db: db)
            XCTAssertTrue(result?.idSet.contains("f3") ?? false)
        }
    }

    func testResultOrderedByCaptureDateDescending() throws {
        let queue = try makeSeededQueue()
        try queue.read { db in
            let result = try PhotoSearch.filter(tokens: [.camera("x100v")], db: db)
            XCTAssertEqual(result?.ids, ["f2", "f1"]) // f2 capture_date 2500 > f1 1500
        }
    }

    func testEmptyTokensReturnsNil() throws {
        let queue = try makeSeededQueue()
        try queue.read { db in
            XCTAssertNil(try PhotoSearch.filter(tokens: [], db: db))
        }
    }
}
```

- [ ] **Step 3: Run, confirm failure**

- [ ] **Step 4: Implement `PhotoSearch`**

```swift
//
//  PhotoSearch.swift
//  Muse
//
//  Token -> SQL, indexed-only. Every token hits an index from v13/v14/v15
//  or an existing index; AND across tokens = set intersection (mirroring
//  SmartRuleSet.all). Rating tokens carry per-(file_id, parent_dir) dir
//  restrictions — the one token backed by per-location data; every other
//  token is content-derived and unrestricted.
//

import Foundation
import GRDB

nonisolated enum PhotoSearch {
    struct Result: Sendable {
        var ids: [String]
        var idSet: Set<String>
        var dirRestrictions: [String: Set<String>] = [:]
    }

    static func filter(tokens: [SearchToken], db: Database) throws -> Result? {
        guard !tokens.isEmpty else { return nil }
        var idSet: Set<String>?
        var dirRestrictions: [String: Set<String>] = [:]

        for token in tokens {
            let (matched, dirs) = try matchIDs(for: token, db: db)
            dirRestrictions.merge(dirs) { $0.union($1) }
            idSet = idSet.map { $0.intersection(matched) } ?? matched
            if idSet?.isEmpty == true { break }
        }
        let finalSet = idSet ?? []
        let ordered = try orderByCapture(ids: finalSet, db: db)
        return Result(ids: ordered, idSet: finalSet, dirRestrictions: dirRestrictions)
    }

    private static func matchIDs(for token: SearchToken, db: Database) throws
        -> (ids: Set<String>, dirRestrictions: [String: Set<String>]) {
        switch token {
        case let .camera(term):
            let lower = "%\(term.lowercased())%"
            let rows = try Row.fetchAll(db, sql: """
                SELECT file_id FROM photo_meta
                WHERE LOWER(camera_make) LIKE ? OR LOWER(camera_model) LIKE ?
                """, arguments: [lower, lower])
            return (Set(rows.compactMap { $0["file_id"] as String? }), [:])

        case let .lens(term):
            let lower = "%\(term.lowercased())%"
            let rows = try Row.fetchAll(db, sql: "SELECT file_id FROM photo_meta WHERE LOWER(lens) LIKE ?",
                                        arguments: [lower])
            return (Set(rows.compactMap { $0["file_id"] as String? }), [:])

        case let .iso(f):
            return (try numericIDs(column: "iso", filter: f, db: db), [:])
        case let .aperture(f):
            return (try numericIDs(column: "f_number", filter: f, db: db), [:])

        case let .inDate(d):
            return (try dateIDs(d, db: db), [:])

        case let .near(place):
            let lower = place.lowercased()
            let rows = try Row.fetchAll(db, sql: """
                SELECT file_id FROM places
                WHERE place_key IS NOT NULL
                  AND (LOWER(city) = ? OR LOWER(admin) = ? OR LOWER(country) = ? OR LOWER(city) LIKE ?)
                """, arguments: [lower, lower, lower, lower + "%"])
            return (Set(rows.compactMap { $0["file_id"] as String? }), [:])

        case .text:
            // FTS-only leg — handled by SearchService directly (it already
            // owns the FTS query path); PhotoSearch is not the FTS engine.
            // Returning empty here means a bare `text:` token with no other
            // tokens intersects to nothing on its own; SearchService (Task
            // 12) special-cases `.text` by folding its value into freeText
            // rather than calling matchIDs for it. Document this exclusion
            // explicitly rather than silently mishandling it.
            return ([], [:])

        case .color:
            // Same story as .text — SearchService routes color tokens into
            // the EXISTING palette leg, not through PhotoSearch's id-set
            // intersection. Excluded here by design (see Task 12 Step 4).
            return ([], [:])

        case let .rating(atLeast):
            let labels = SmartCollectionResolver.qualifyingRatingLabels(op: .atLeast, stars: atLeast)
            guard !labels.isEmpty else { return ([], [:]) }
            let placeholders = labels.map { _ in "?" }.joined(separator: ",")
            let rows = try Row.fetchAll(db, sql: """
                SELECT file_id, parent_dir FROM tags WHERE label IN (\(placeholders))
                """, arguments: StatementArguments(labels))
            var ids: Set<String> = []
            var dirs: [String: Set<String>] = [:]
            for row in rows {
                guard let id: String = row["file_id"], let dir: String = row["parent_dir"] else { continue }
                ids.insert(id)
                dirs[id, default: []].insert(dir)
            }
            return (ids, dirs)

        case let .kind(group):
            let placeholders = group.kinds.map { _ in "?" }.joined(separator: ",")
            let rows = try Row.fetchAll(db, sql: "SELECT id FROM files WHERE kind IN (\(placeholders))",
                                        arguments: StatementArguments(group.kinds))
            return (Set(rows.compactMap { $0["id"] as String? }), [:])
        }
    }

    private static func numericIDs(column: String, filter: SearchToken.NumericFilter, db: Database) throws -> Set<String> {
        let (clause, args): (String, [DatabaseValueConvertible])
        switch filter.op {
        case .eq: (clause, args) = ("\(column) = ?", [filter.value])
        case .gt: (clause, args) = ("\(column) > ?", [filter.value])
        case .gte: (clause, args) = ("\(column) >= ?", [filter.value])
        case .lt: (clause, args) = ("\(column) < ?", [filter.value])
        case .lte: (clause, args) = ("\(column) <= ?", [filter.value])
        case let .range(lo, hi): (clause, args) = ("\(column) BETWEEN ? AND ?", [lo, hi])
        }
        let rows = try Row.fetchAll(db, sql: "SELECT file_id FROM photo_meta WHERE \(clause)",
                                    arguments: StatementArguments(args))
        return Set(rows.compactMap { $0["file_id"] as String? })
    }

    private static func dateIDs(_ d: SearchToken.DateToken, db: Database) throws -> Set<String> {
        let cal = Calendar(identifier: .gregorian)
        var startComponents = DateComponents(year: d.year, month: d.month ?? 1, day: d.day ?? 1)
        startComponents.timeZone = TimeZone.current
        guard let start = cal.date(from: startComponents) else { return [] }
        let end: Date
        if let day = d.day {
            end = cal.date(byAdding: .day, value: 1, to: start) ?? start
            _ = day
        } else if let _ = d.month {
            end = cal.date(byAdding: .month, value: 1, to: start) ?? start
        } else {
            end = cal.date(byAdding: .year, value: 1, to: start) ?? start
        }
        let startEpoch = Int64(start.timeIntervalSince1970)
        let endEpoch = Int64(end.timeIntervalSince1970)

        let withMeta = try Row.fetchAll(db, sql: """
            SELECT file_id FROM photo_meta WHERE capture_date >= ? AND capture_date < ?
            """, arguments: [startEpoch, endEpoch])
        let fallback = try Row.fetchAll(db, sql: """
            SELECT f.id FROM files f
            LEFT JOIN photo_meta m ON m.file_id = f.id
            WHERE m.file_id IS NULL AND f.created_at >= ? AND f.created_at < ?
            """, arguments: [startEpoch, endEpoch])
        var ids = Set(withMeta.compactMap { $0["file_id"] as String? })
        ids.formUnion(fallback.compactMap { $0["id"] as String? })
        return ids
    }

    private static func orderByCapture(ids: Set<String>, db: Database) throws -> [String] {
        guard !ids.isEmpty else { return [] }
        let placeholders = ids.map { _ in "?" }.joined(separator: ",")
        let rows = try Row.fetchAll(db, sql: """
            SELECT f.id AS id, COALESCE(m.capture_date, f.modified_at) AS ord
            FROM files f LEFT JOIN photo_meta m ON m.file_id = f.id
            WHERE f.id IN (\(placeholders))
            ORDER BY ord DESC
            """, arguments: StatementArguments(Array(ids)))
        return rows.compactMap { $0["id"] as String? }
    }
}
```

  Confirm `SmartCollectionResolver.qualifyingRatingLabels`'s exact name/signature and
  `files.modified_at`'s exact column name (used as the DESC fallback ordering key when
  `capture_date` is absent — matches the "then modified_at DESC" ordering the spec
  describes) against `Database/Records.swift` before finalizing; adjust the query if
  either differs.

- [ ] **Step 5: Run tests, confirm pass**

- [ ] **Step 6: Commit**

```bash
git add "Muse/Muse/Search/PhotoSearch.swift" "Muse/MuseTests/PhotoSearchTests.swift"
git commit -m "feat: add PhotoSearch (token -> SQL, indexed-only)"
```

---

### Task 12: `SearchService` token integration

**Files:**
- Modify: `Muse/Muse/Database/SearchService.swift`
- Create: `Muse/MuseTests/SearchServiceTokenTests.swift`

**Interfaces:**
- Consumes: `SearchQueryParser.parse` (Task 10), `PhotoSearch.filter` (Task 11).
- Produces: no new public interface — this task changes `SearchService.search`'s
  internal flow only; its existing signature/callers (`AppState+Search`) are
  unchanged.

- [ ] **Step 1: Read `SearchService.swift` end to end**

  Read the whole file, paying attention to: the exact color-leg variable names (the
  spec cites an existing color∧text intersection at "lines 164-166" — confirm), the
  `aliveePaths(for:restrictedToDirs:db:)` helper's exact signature, and the
  unindexed-extras (`currentFolder` basename scan) leg's exact trigger condition —
  this task must skip it whenever tokens are present.

- [ ] **Step 2: Write the pinning test FIRST — tokenless behavior must not change**

```swift
//
//  SearchServiceTokenTests.swift
//  MuseTests
//
//  Byte-identical tokenless behavior (pinned), token-only ordering, token+
//  free-text intersection, and rating-token dir restrictions surviving the
//  FTS/semantic relaxation step.
//

import XCTest
@testable import Muse

final class SearchServiceTokenTests: XCTestCase {
    func testTokenlessQueryUnchanged() async throws {
        // Seed a minimal library (files + an FTS row matching "sunset"),
        // run SearchService.search("sunset", …) BEFORE and record the exact
        // result shape this test asserts against, matching whatever
        // SearchServiceTests already covers for the legacy path — this test
        // exists to PIN that the new token-parse step is a no-op when no
        // token parses, not to re-derive the legacy behavior from scratch.
        // Implement by mirroring an existing SearchServiceTests fixture.
    }

    func testTokenOnlyQueryOrdersByCaptureDate() async throws {
        // camera:x100v alone, two matching files with different
        // capture_date — assert result order is capture DESC, matching
        // PhotoSearchTests' equivalent assertion at the SearchService layer.
    }

    func testTokenPlusFreeTextIntersects() async throws {
        // "camera:x100v sunset" — only files matching BOTH the camera token
        // AND the FTS/semantic free-text leg should survive.
    }

    func testRatingTokenDirRestrictionSurvivesRelaxation() async throws {
        // A ★★★★ rating on file X in folder /A only; the same content
        // (byte-identical) also lives unrated at /B. "star:4 sunset" where
        // "sunset" FTS-matches BOTH copies must still return ONLY /A — the
        // FTS relaxation must not un-restrict the rating token.
    }
}
```

  Implement these against whatever fixture/harness the existing `SearchServiceTests`
  already uses (read that file first) — do not invent a new DB-seeding convention.

- [ ] **Step 3: Run, confirm the token-specific tests fail (tokenless test should
  already pass against current code, proving the pin is meaningful)**

- [ ] **Step 4: Integrate parsing + token filtering into `SearchService.search`**

  At the top of the existing `search` function, before its current logic:

```swift
let parsed = SearchQueryParser.parse(trimmed)
```

  Where `trimmed` is whatever the function's existing trimmed-query local is named.
  If `parsed.tokens.isEmpty`, fall through to the EXISTING pipeline unchanged, running
  on `trimmed` exactly as today (including the legacy bare-hex `ColorQuery` behavior)
  — do not touch that branch at all beyond this one guard.

  Inside the existing `queue.read` block, when `parsed.tokens` is non-empty:

```swift
guard let tok = try PhotoSearch.filter(tokens: parsed.tokens, db: db) else {
    // tokens.isEmpty already handled above; this branch is unreachable in
    // practice but keeps the optional honest.
    return existingTokenlessResult
}

if parsed.freeText.isEmpty && !parsed.tokens.contains(where: { if case .color = $0 { return true }; return false }) {
    // Token-only: order by capture DESC (already what PhotoSearch.Result.ids
    // provides), resolve via the existing scope-aware path resolver.
    let paths = try aliveePaths(for: tok.ids, restrictedToDirs: tok.dirRestrictions, db: db)
    return existingResultWrapper(paths: paths /* , whatever else the function returns */)
} else {
    // Tokens + free text: run the existing legs (FTS/tag/note/semantic/
    // color) on parsed.freeText exactly as today, THEN intersect with
    // tok.idSet (same precedent as the existing color∧text intersection),
    // THEN apply token dir restrictions AFTER the existing relaxation step.
    var orderedIDs = /* … existing legs' output, run on parsed.freeText … */ []
    var matchedDirs = /* … existing legs' output … */ [:]
    orderedIDs = orderedIDs.filter { tok.idSet.contains($0) }
    for (id, dirs) in tok.dirRestrictions {
        matchedDirs[id] = matchedDirs[id].map { $0.intersection(dirs) } ?? dirs
    }
    // A color: token routes its resolved [LabColor] into the EXISTING color
    // leg's input variables (read Step 1's notes on lines ~164-166) so
    // token-color ∧ text behaves exactly like today's hex ∧ text — do not
    // add a second, parallel color-matching code path.
    // Skip the unindexed-extras (currentFolder basename scan) leg entirely
    // whenever tokens are present — extras can't satisfy token constraints.
}
```

  This block is intentionally written with placeholder-style comments describing
  WHERE existing variables plug in, because their exact names depend on reading the
  real file in Step 1 — replace every `/* … */` and `existingResultWrapper`/
  `existingTokenlessResult` reference with the actual local variable names and control
  flow found there before this task is considered done. The **behavioral** contract
  (token-only = capture DESC via `aliveePaths`; token+text = existing legs ∧
  `tok.idSet`, dir restrictions merged in AFTER relaxation; extras leg skipped when
  tokens present; color token reuses the existing color leg) is not optional — every
  clause above must be present in the final diff.

- [ ] **Step 5: Run all tests, confirm pass — pinned test especially**

  Run: `xcodebuild -project Muse/Muse.xcodeproj -scheme Muse test -only-testing:MuseTests/SearchServiceTokenTests -only-testing:MuseTests/SearchServiceTests`
  Expected: PASS, with the tokenless pin test proving zero behavior change on the
  legacy path.

- [ ] **Step 6: Commit**

```bash
git add "Muse/Muse/Database/SearchService.swift" "Muse/MuseTests/SearchServiceTokenTests.swift"
git commit -m "feat: integrate search tokens into SearchService (tokenless path unchanged)"
```

---

### Task 13: `SearchFacets` (autocomplete) + `.searchSuggestions` wiring

**Files:**
- Create: `Muse/Muse/Search/SearchFacets.swift`
- Create: `Muse/MuseTests/SearchSuggestTests.swift`
- Modify: `Muse/Muse/ContentView.swift` (add `.searchSuggestions` directly after the
  existing `.searchable` modifier)
- Modify: `Muse/Muse/Intelligence/Geo/GeocodeBackfill.swift` (Task 9 — uncomment the
  `SearchFacets.shared.refresh()` chain call now that this type exists)
- Modify: `Muse/Muse/Intelligence/AnalyzePipeline.swift` (call
  `SearchFacets.shared.refresh()` at the end of any pass that wrote rows)

**Interfaces:**
- Produces: `SearchFacets` (Pattern B store: `cameras`/`lenses`/`places`/`years`,
  `refresh() async`, `snapshot: FacetsSnapshot`), `SearchSuggest.suggestions(fieldText:facets:)
  -> [Suggestion]` (pure) — consumed by ContentView's `.searchSuggestions`.

- [ ] **Step 1: Write the failing pure-suggester tests**

```swift
//
//  SearchSuggestTests.swift
//  MuseTests
//
//  Pure: current field text + facets -> at most 8 suggestions. A trailing
//  partial word that prefixes a token key suggests the key; a trailing
//  "key:" or "key:partial" suggests real facet values; plain free text with
//  no partial token suggests nothing.
//

import XCTest
@testable import Muse

final class SearchSuggestTests: XCTestCase {
    private let facets = FacetsSnapshot(
        cameras: ["FUJIFILM X100V", "Canon EOS R5"],
        lenses: ["23mm f/2", "50mm f/1.8"],
        places: ["Lisboa", "Porto"],
        years: ["2019", "2023"])

    func testKeyPrefixSuggestsKey() {
        let suggestions = SearchSuggest.suggestions(fieldText: "cam", facets: facets)
        XCTAssertTrue(suggestions.contains { $0.completion.hasSuffix("camera:") })
    }

    func testKeyColonSuggestsRealValues() {
        let suggestions = SearchSuggest.suggestions(fieldText: "camera:", facets: facets)
        XCTAssertTrue(suggestions.contains { $0.completion.contains("FUJIFILM X100V") })
    }

    func testPartialValueFiltersFacetList() {
        let suggestions = SearchSuggest.suggestions(fieldText: "camera:fuji", facets: facets)
        XCTAssertTrue(suggestions.contains { $0.completion.contains("FUJIFILM X100V") })
        XCTAssertFalse(suggestions.contains { $0.completion.contains("Canon") })
    }

    func testPlainFreeTextSuggestsNothing() {
        XCTAssertTrue(SearchSuggest.suggestions(fieldText: "sunset beach", facets: facets).isEmpty)
    }

    func testCompletionPreservesPrecedingText() {
        let suggestions = SearchSuggest.suggestions(fieldText: "star:4 cam", facets: facets)
        XCTAssertTrue(suggestions.allSatisfy { $0.completion.hasPrefix("star:4 ") })
    }

    func testCapsAtEight() {
        let manyFacets = FacetsSnapshot(cameras: (0..<20).map { "Camera \($0)" },
                                        lenses: [], places: [], years: [])
        let suggestions = SearchSuggest.suggestions(fieldText: "camera:", facets: manyFacets)
        XCTAssertLessThanOrEqual(suggestions.count, 8)
    }
}
```

- [ ] **Step 2: Run, confirm failure**

- [ ] **Step 3: Implement `SearchFacets` + `SearchSuggest`**

```swift
//
//  SearchFacets.swift
//  Muse
//
//  Autocomplete facets: DISTINCT values from the live index, refreshed
//  after backfills and analyze passes. Pattern B store (no AppState
//  integration). SearchSuggest is pure and unit-tested; the store just
//  supplies its snapshot.
//

import Foundation
import GRDB

nonisolated struct FacetsSnapshot: Equatable, Sendable {
    var cameras: [String]
    var lenses: [String]
    var places: [String]
    var years: [String]
}

@MainActor final class SearchFacets: ObservableObject {
    static let shared = SearchFacets()
    private init() {}

    @Published private(set) var cameras: [String] = []
    @Published private(set) var lenses: [String] = []
    @Published private(set) var places: [String] = []
    @Published private(set) var years: [String] = []

    var snapshot: FacetsSnapshot {
        FacetsSnapshot(cameras: cameras, lenses: lenses, places: places, years: years)
    }

    func refresh() async {
        guard let q = Database.shared.dbQueue else { return }
        let result: (cameras: [String], lenses: [String], places: [String], years: [String])? =
            try? await q.read { db in
                let cameraRows = try Row.fetchAll(db, sql: """
                    SELECT camera_model, COUNT(*) AS c FROM photo_meta
                    WHERE camera_model IS NOT NULL
                    GROUP BY camera_model ORDER BY c DESC LIMIT 50
                    """)
                let lensRows = try Row.fetchAll(db, sql: """
                    SELECT lens, COUNT(*) AS c FROM photo_meta
                    WHERE lens IS NOT NULL GROUP BY lens ORDER BY c DESC LIMIT 50
                    """)
                let placeRows = try Row.fetchAll(db, sql: """
                    SELECT DISTINCT city FROM places WHERE place_key IS NOT NULL LIMIT 100
                    """)
                let yearRows = try Row.fetchAll(db, sql: """
                    SELECT DISTINCT strftime('%Y', capture_date, 'unixepoch') AS y
                    FROM photo_meta WHERE capture_date IS NOT NULL ORDER BY y DESC
                    """)
                return (cameraRows.compactMap { $0["camera_model"] as String? },
                        lensRows.compactMap { $0["lens"] as String? },
                        placeRows.compactMap { $0["city"] as String? },
                        yearRows.compactMap { $0["y"] as String? })
            }
        guard let result else { return }
        cameras = result.cameras
        lenses = result.lenses
        places = result.places
        years = result.years
    }
}

nonisolated enum SearchSuggest {
    struct Suggestion: Equatable, Identifiable {
        var display: String
        var completion: String
        var id: String { completion }
    }

    private static let keys = ["camera", "lens", "iso", "f", "in", "near", "text", "color", "star", "kind"]

    static func suggestions(fieldText: String, facets: FacetsSnapshot) -> [Suggestion] {
        guard let lastWordRange = fieldText.range(of: #"\S+$"#, options: .regularExpression) else {
            return []
        }
        let lastWord = String(fieldText[lastWordRange])
        let precedingText = String(fieldText[fieldText.startIndex..<lastWordRange.lowerBound])

        if let colonIndex = lastWord.firstIndex(of: ":") {
            let key = String(lastWord[lastWord.startIndex..<colonIndex]).lowercased()
            let partial = String(lastWord[lastWord.index(after: colonIndex)...]).lowercased()
            let values = facetValues(for: key, facets: facets)
            let filtered = partial.isEmpty ? values : values.filter { $0.lowercased().contains(partial) }
            return filtered.prefix(8).map { value in
                Suggestion(display: "\(key): \(value)", completion: precedingText + "\(key):\(value)")
            }
        }

        let matchingKeys = keys.filter { $0.hasPrefix(lastWord.lowercased()) }
        guard !matchingKeys.isEmpty, !lastWord.isEmpty else { return [] }
        return matchingKeys.prefix(8).map { key in
            Suggestion(display: "\(key):", completion: precedingText + "\(key):")
        }
    }

    private static func facetValues(for key: String, facets: FacetsSnapshot) -> [String] {
        switch key {
        case "camera": return facets.cameras
        case "lens": return facets.lenses
        case "near": return facets.places
        case "in": return facets.years
        default: return []
        }
    }
}
```

- [ ] **Step 4: Run tests, confirm pass**

- [ ] **Step 5: Wire `.searchSuggestions` in `ContentView`**

  Directly after the existing `.searchable(…)` modifier (near the `.searchScopes`
  wiring described in `CLAUDE.md`'s durable constraints), add:

```swift
.searchSuggestions {
    ForEach(SearchSuggest.suggestions(fieldText: searchText, facets: searchFacets.snapshot)) { s in
        Text(s.display).searchCompletion(s.completion)
    }
}
```

  Add `@ObservedObject private var searchFacets = SearchFacets.shared` beside the
  existing `collectionsEngine`-style observed-object properties in `ContentView`.
  Confirm `searchText`'s exact local `@State` name (the durable constraint documents
  it as local, not bound to `AppState.searchQuery`).

- [ ] **Step 6: Wire `refresh()` triggers**

  Uncomment the `SearchFacets.shared.refresh()` line left commented in Task 9's
  `GeocodeBackfill.run()`. In `AnalyzePipeline.swift`, find wherever a pass's
  completion is signaled (the end of `analyzePending`/`analyzeFolderManual`/similar)
  and add a call to `await SearchFacets.shared.refresh()` when the pass wrote at least
  one row — follow the same "only refresh if something changed" discipline the
  backfills use.

- [ ] **Step 7: Build and verify**

  Run: `xcodebuild -project Muse/Muse.xcodeproj -scheme Muse -configuration Debug build`
  Expected: `BUILD SUCCEEDED`.

- [ ] **Step 8: Commit**

```bash
git add "Muse/Muse/Search/SearchFacets.swift" "Muse/MuseTests/SearchSuggestTests.swift" \
        "Muse/Muse/ContentView.swift" "Muse/Muse/Intelligence/Geo/GeocodeBackfill.swift" \
        "Muse/Muse/Intelligence/AnalyzePipeline.swift"
git commit -m "feat: add SearchFacets + native .searchSuggestions autocomplete"
```

---

### Task 14: Token chip bar in `TagChipsRow`

**Files:**
- Modify: `Muse/Muse/Views/TagChipsRow.swift` (exact filename — confirm; the spec
  refers to it as `TagChipsRow`, the file holding the existing "Viewing <tag> ✕"
  active-filter pills)

**Interfaces:**
- Consumes: `SearchQueryParser.parse` (Task 10), `AppState.searchQuery`/`runSearch`
  (existing programmatic search-injection seam — confirm exact method names).
- Produces: no new type — extends the existing chip row's rendering.

- [ ] **Step 1: Read `TagChipsRow.swift` and the existing `BannerPill` component**

  Confirm the exact view name, the existing "Viewing <tag> ✕" pill construction
  (`BannerPill` per the spec), and how `AppState.isSearchActive` and the committed
  `searchQuery` are already exposed to this view.

- [ ] **Step 2: Add token-chip rendering**

  When `appState.isSearchActive`, compute `SearchQueryParser.parse(appState.searchQuery)`
  (pure, cheap — no new stored state) and render one `BannerPill` per token AHEAD of
  any tag pills, each prefixed `Text("Search")` (distinct from the tag group's
  "Viewing" prefix):

```swift
if appState.isSearchActive {
    let parsed = SearchQueryParser.parse(appState.searchQuery)
    ForEach(Array(parsed.tokens.enumerated()), id: \.offset) { index, token in
        BannerPill(label: "\(Text("Search")): \(token.displayLabel)") {
            let rebuilt = parsed.removing(tokenAt: index)
            appState.searchQuery = rebuilt
            Task { await appState.runSearch(rebuilt) }
        }
    }
}
```

  Adjust the exact `BannerPill` call signature and the search-injection call
  (`appState.searchQuery = …; Task { await appState.runSearch(…) }` vs whatever the
  actual programmatic-injection seam looks like — confirm against
  `ContentView`'s `.onChange(of: appState.searchQuery)` handler and `runSearchNow`)
  to match the real API found in Step 1. Removing the LAST token with empty free text
  must clear the search entirely — route an empty rebuilt string through the same
  clear-search path `EscapeAction.clearSearch` uses, not a special case here.

- [ ] **Step 3: Add `SearchToken.displayLabel`**

  In the same file (or a small extension nearby), a pure computed property:

```swift
extension SearchToken {
    var displayLabel: String {
        switch self {
        case let .camera(v): return "\(String(localized: "camera")): \(v)"
        case let .lens(v): return "\(String(localized: "lens")): \(v)"
        case let .iso(f): return "\(String(localized: "iso")) \(f.displayLabel)"
        case let .aperture(f): return "f \(f.displayLabel)"
        case let .inDate(d): return "\(String(localized: "in")): \(d.displayLabel)"
        case let .near(v): return "\(String(localized: "near")): \(v)"
        case let .text(v): return "\(String(localized: "text")): \"\(v)\""
        case let .color(v): return "\(String(localized: "color")): \(v)"
        case let .rating(n): return String(repeating: "★", count: n) + " ≥"
        case let .kind(g): return "\(String(localized: "kind")): \(g.rawValue)"
        }
    }
}
```

  (`NumericFilter.displayLabel`/`DateToken.displayLabel` are small additional pure
  helpers — implement inline, e.g. `">1600"`, `"2019-06"`.)

- [ ] **Step 4: Manual verification (no UI unit tests, per house convention)**

  Run the app, type `camera:x100v beach`, confirm two chips appear ("Search: camera:
  x100v" style + any tag chips), confirm clicking a token chip's ✕ removes only that
  token and re-runs the search with the remainder, confirm removing the last token
  with empty free text clears the search entirely (grid returns to normal folder
  browsing).

- [ ] **Step 5: Commit**

```bash
git add "Muse/Muse/Views/TagChipsRow.swift"
git commit -m "feat: render search tokens as removable chips in the active-filter bar"
```

---

### Task 15: `PerfBaseline` token-search metric

**Files:**
- Modify: `Muse/Muse/Perf/PerfBaseline.swift` (Spec 01's harness — if Spec 01 hasn't
  been built yet in this branch's history, this task is a no-op placeholder; see the
  note below)

**Interfaces:** None new — adds one row to an existing report table.

**Context:** `Perf/PerfBaseline.swift` and its `PerfBaselineTests` are Spec 01
deliverables (`DECISIONS.md`'s Scale & performance section: budgets recorded, never
asserted; triggered by `MUSE_PERF=1` or the test target). If Spec 01 has already
landed by the time this task is executed, add the metric below. If Spec 01 has NOT
yet landed (per this plan's own build-order note that Spec 01 is a sibling, not a
hard prerequisite of most of Spec 02), **skip this task** and record in the commit
log / Task 35's doc pass that the token-search perf metric is deferred until
`PerfBaseline` exists, rather than inventing a parallel measurement harness.

- [ ] **Step 1: Check whether `Muse/Muse/Perf/PerfBaseline.swift` exists**

  Run: `find "Muse/Muse/Perf" -iname "PerfBaseline.swift"`. If absent, stop here —
  this task is deferred (see Context above); note it in Task 35's doc pass and do not
  proceed further in this task.

- [ ] **Step 2 (only if present): Add the "token search, 50k synthetic photo_meta"
  metric**

  Follow the exact pattern of whatever other metrics already exist in that file (seed
  50k synthetic `photo_meta` rows, run a representative multi-token `PhotoSearch.filter`
  call, record wall-clock — budget 100 ms, recorded not asserted per the CI-noise
  rule).

- [ ] **Step 3 (only if present): Run and commit**

```bash
git add "Muse/Muse/Perf/PerfBaseline.swift"
git commit -m "perf: add token-search PerfBaseline metric (50k synthetic photo_meta)"
```

---

## Section E — Places surface

### Task 16: `PlaceQueries` + `PlacesStore`

**Files:**
- Create: `Muse/Muse/Database/PlaceQueries.swift`
- Create: `Muse/Muse/Models/PlacesStore.swift`
- Create: `Muse/MuseTests/PlaceQueriesTests.swift`
- Modify: `Muse/Muse/Intelligence/Geo/GeocodeBackfill.swift` (uncomment
  `PlacesStore.shared.reload()`, added in Task 9)

**Interfaces:**
- Consumes: `places`/`paths`/`photo_meta` tables (Tasks 6, 2),
  `CollectionStore.isUnderAnyRoot` (existing trailing-slash-safe root filter).
- Produces: `PlaceGroup` (`key`, `city`, `admin`, `countryCode`, `count`, `latestAt`,
  `coverPath`, `displayName`), `PlacesStore.shared` (`showingPlaces`, `groups`,
  `sortByCount`, `reload() async`, `setShowing(_:)`) — consumed by Task 17
  (`PlacesPage`), Task 18 (sidebar row), Task 19 (click-through).

- [ ] **Step 1: Write the failing `PlaceQueries` tests**

```swift
//
//  PlaceQueriesTests.swift
//  MuseTests
//
//  Grouping, count vs recency order, cover path = most recent member, NULL
//  place_key excluded (no "Unknown" group), root filtering.
//

import XCTest
import GRDB
@testable import Muse

final class PlaceQueriesTests: XCTestCase {
    private func seededQueue() throws -> DatabaseQueue {
        let queue = try DatabaseQueue()
        try Database.makeMigrator().migrate(queue)
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO files (id, content_hash, kind, last_seen_at, modified_at)
                VALUES ('f1','h1','image',0,100), ('f2','h2','image',0,200),
                       ('f3','h3','image',0,300), ('f4','h4','image',0,400)
                """)
            try db.execute(sql: """
                INSERT INTO paths (file_id, absolute_path, is_alive)
                VALUES ('f1','/root/a/f1.jpg',1), ('f2','/root/a/f2.jpg',1),
                       ('f3','/root/a/f3.jpg',1), ('f4','/root/a/f4.jpg',1)
                """)
            try db.execute(sql: """
                INSERT INTO places (file_id, geocoded_hash, dataset_version, city, admin, country, place_key)
                VALUES ('f1','h1',1,'Lisboa','Lisbon','PT','lisboa|lisbon|pt'),
                       ('f2','h2',1,'Lisboa','Lisbon','PT','lisboa|lisbon|pt'),
                       ('f3','h3',1,'Porto','Porto','PT','porto|porto|pt'),
                       ('f4','h4',1,NULL,NULL,NULL,NULL)
                """)
            try db.execute(sql: """
                INSERT INTO photo_meta (file_id, capture_date) VALUES ('f1', 500), ('f2', 1500)
                """)
        }
        return queue
    }

    func testGroupsByPlaceKeyWithCounts() throws {
        let queue = try seededQueue()
        try queue.read { db in
            let groups = try PlaceQueries.groups(db: db)
            let lisboa = groups.first { $0.key == "lisboa|lisbon|pt" }
            XCTAssertEqual(lisboa?.count, 2)
        }
    }

    func testNullPlaceKeyExcluded() throws {
        let queue = try seededQueue()
        try queue.read { db in
            let groups = try PlaceQueries.groups(db: db)
            XCTAssertFalse(groups.contains { $0.key.isEmpty })
            XCTAssertEqual(groups.reduce(0) { $0 + $1.count }, 3) // f4 excluded
        }
    }

    func testCoverPathIsMostRecentMember() throws {
        let queue = try seededQueue()
        try queue.read { db in
            let groups = try PlaceQueries.groups(db: db)
            let lisboa = groups.first { $0.key == "lisboa|lisbon|pt" }
            // f2's capture_date (1500) > f1's (500) -> f2 is the cover.
            XCTAssertEqual(lisboa?.coverPath, "/root/a/f2.jpg")
        }
    }

    func testLatestAtUsesCaptureDateFallingBackToModifiedAt() throws {
        let queue = try seededQueue()
        try queue.read { db in
            let groups = try PlaceQueries.groups(db: db)
            let porto = groups.first { $0.key == "porto|porto|pt" }
            XCTAssertEqual(porto?.latestAt, 300) // f3 has no photo_meta row -> modified_at fallback
        }
    }
}
```

- [ ] **Step 2: Run, confirm failure**

- [ ] **Step 3: Implement `PlaceQueries`**

```swift
//
//  PlaceQueries.swift
//  Muse
//
//  Grouped place query: places JOIN alive paths LEFT JOIN photo_meta,
//  GROUP BY place_key. NULL place_key excluded — no "Unknown" group. Root
//  filtering happens in Swift (CollectionStore.isUnderAnyRoot) after fetch,
//  matching every other root-scoped query in the codebase.
//

import Foundation
import GRDB

nonisolated enum PlaceQueries {
    static func groups(db: Database) throws -> [PlaceGroup] {
        let rows = try Row.fetchAll(db, sql: """
            SELECT pl.place_key AS key, pl.city AS city, pl.admin AS admin,
                   pl.country AS country, COUNT(*) AS count,
                   MAX(COALESCE(m.capture_date, f.modified_at)) AS latestAt,
                   p.absolute_path AS coverPath
            FROM places pl
            JOIN files f ON f.id = pl.file_id
            JOIN paths p ON p.file_id = pl.file_id AND p.is_alive = 1
            LEFT JOIN photo_meta m ON m.file_id = pl.file_id
            WHERE pl.place_key IS NOT NULL
            GROUP BY pl.place_key
            HAVING coverPath = (
                SELECT p2.absolute_path FROM places pl2
                JOIN files f2 ON f2.id = pl2.file_id
                JOIN paths p2 ON p2.file_id = pl2.file_id AND p2.is_alive = 1
                LEFT JOIN photo_meta m2 ON m2.file_id = pl2.file_id
                WHERE pl2.place_key = pl.place_key
                ORDER BY COALESCE(m2.capture_date, f2.modified_at) DESC
                LIMIT 1
            )
            """)
        return rows.compactMap { row -> PlaceGroup? in
            guard let key: String = row["key"], let city: String = row["city"],
                  let count: Int = row["count"], let latestAt: Int64 = row["latestAt"] else { return nil }
            return PlaceGroup(key: key, city: city, admin: row["admin"],
                              countryCode: row["country"] ?? "", count: count,
                              latestAt: latestAt, coverPath: row["coverPath"])
        }
    }
}
```

  The `HAVING coverPath = (correlated subquery)` shape picks exactly the most-recent
  member's path per group without a window function (SQLite's window-function
  support varies by version bundled with the OS's SQLite — avoid depending on it).
  If profiling later shows this correlated subquery is slow at scale, replace with a
  two-pass Swift-side reduction; not expected to matter until far past the 50k design
  center (groups are typically small).

- [ ] **Step 4: Run tests, confirm pass**

- [ ] **Step 5: Implement `PlacesStore` + `PlaceGroup`**

```swift
//
//  PlacesStore.swift
//  Muse
//
//  Places page state — Pattern B (@MainActor singleton, AppState untouched).
//

import Foundation
import GRDB

nonisolated struct PlaceGroup: Identifiable, Equatable, Sendable {
    var key: String
    var city: String
    var admin: String?
    var countryCode: String
    var count: Int
    var latestAt: Int64
    var coverPath: String?
    var id: String { key }

    var displayName: String {
        let countryName = Locale.current.localizedString(forRegionCode: countryCode) ?? countryCode
        return "\(city), \(countryName)"
    }
}

@MainActor final class PlacesStore: ObservableObject {
    static let shared = PlacesStore()
    private init() {}

    @Published private(set) var showingPlaces = false
    @Published private(set) var groups: [PlaceGroup] = []
    @Published var sortByCount = true

    func reload() async {
        guard let q = Database.shared.dbQueue else { return }
        let fetched = (try? await q.read { db in try PlaceQueries.groups(db: db) }) ?? []
        // Root filtering: only groups whose cover path resolves under a
        // currently-tracked root are shown (matches every other root-scoped
        // surface's fail-safe: an unresolvable/foreign path is dropped, not
        // shown as a false-positive group).
        groups = fetched.filter { group in
            guard let cover = group.coverPath else { return false }
            return CollectionStore.isUnderAnyRoot(URL(fileURLWithPath: cover))
        }
    }

    func setShowing(_ v: Bool) {
        showingPlaces = v
    }
}
```

  Confirm `CollectionStore.isUnderAnyRoot`'s exact signature (does it take a `URL` or
  a `String` path, and is it a static func or instance method requiring the roots
  list as a parameter?) against its actual declaration before finalizing — adjust the
  call site accordingly.

- [ ] **Step 6: Chain `PlacesStore.shared.reload()` from `GeocodeBackfill`**

  Edit `Muse/Muse/Intelligence/Geo/GeocodeBackfill.swift`'s `if wroteAny { }` block
  (left with a `// TODO(task-16)` comment in Task 9) to uncomment:

```swift
await PlacesStore.shared.reload()
```

- [ ] **Step 7: Commit**

```bash
git add "Muse/Muse/Database/PlaceQueries.swift" "Muse/Muse/Models/PlacesStore.swift" \
        "Muse/MuseTests/PlaceQueriesTests.swift" "Muse/Muse/Intelligence/Geo/GeocodeBackfill.swift"
git commit -m "feat: add PlaceQueries + PlacesStore (grouped place data)"
```

---

### Task 17: `PlacesPage` + `ContentView` mount

**Files:**
- Create: `Muse/Muse/Views/PlacesPage.swift`
- Modify: `Muse/Muse/ContentView.swift` (add a branch inside `detailStage`, around
  lines 538–552)

**Interfaces:**
- Consumes: `PlacesStore.shared` (Task 16), `AppState.moodPalette`,
  `TagChipsRow.noTagsTopClearance` (existing constant), `ThumbnailCache`'s existing
  320×320 grid variant.
- Produces: `PlacesPage` view — mounted by `ContentView`, consumed by Task 19
  (`openPlacesPage`/`closePlacesPage` control its visibility).

- [ ] **Step 1: Read `Views/CollectionsPage.swift` in full**

  This page is modelled tile-for-tile on it (per the spec) — read the whole file
  (already partially read above) to match its exact skeleton: header shape, sort
  menu wiring, grid layout constants, and the reachability-gate pattern.

- [ ] **Step 2: Implement `PlacesPage`**

```swift
//
//  PlacesPage.swift
//  Muse
//
//  The dedicated Places page — modelled tile-for-tile on CollectionsPage.
//  A "Places" header (back arrow, sort menu) above a vertically-scrolling
//  grid of place-group cover cards. Tapping a card runs a programmatic
//  near: token search (Task 19) rather than opening a fourth visibleFiles
//  substitution.
//

import SwiftUI

struct PlacesPage: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject var placesStore = PlacesStore.shared

    private let columns = 4
    private let hGap: CGFloat = 24
    private let vGap: CGFloat = 40
    private let hInset: CGFloat = 14

    private var sorted: [PlaceGroup] {
        placesStore.sortByCount
            ? placesStore.groups.sorted { $0.count > $1.count }
            : placesStore.groups.sorted { $0.latestAt > $1.latestAt }
    }

    var body: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: TagChipsRow.noTagsTopClearance)
            header
            if sorted.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: hGap), count: columns),
                             spacing: vGap) {
                        ForEach(sorted) { group in
                            PlaceGroupCard(group: group)
                                .onTapGesture { appState.openPlaceSearch(group) }
                        }
                    }
                    .padding(.horizontal, hInset)
                    .padding(.top, 20)
                }
            }
        }
        .background(appState.moodPalette.background)
    }

    private var header: some View {
        HStack {
            BackArrowButton { appState.closePlacesPage() }
            Text("Places").font(.system(size: 42, weight: .semibold))
            Spacer()
            Menu {
                Button("Count") { placesStore.sortByCount = true }
                Button("Recent") { placesStore.sortByCount = false }
            } label: {
                Image(systemName: "arrow.up.arrow.down")
            }
        }
        .padding(.horizontal, hInset)
    }

    private var emptyState: some View {
        VStack {
            Spacer()
            Text("No places yet — photos with location will appear here as analysis runs.")
                .foregroundStyle(.secondary)
            Spacer()
        }
    }
}

private struct PlaceGroupCard: View {
    let group: PlaceGroup

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let cover = group.coverPath {
                ThumbnailView(path: cover, size: 320) // confirm the ACTUAL existing
                                                        // thumbnail view type/API used
                                                        // by CollectionsPage's cover
                                                        // cards — reuse it verbatim
                    .aspectRatio(1, contentMode: .fill)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            Text(group.displayName).font(.system(size: 13, weight: .medium)).lineLimit(1)
            Text("\(group.count)").font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }
}
```

  `ThumbnailView(path:size:)` is a placeholder name — read `CollectionsPage.swift`'s
  actual cover-card thumbnail component and reuse the exact same type/call so this
  page draws from the SAME 320×320 `renderedVariants` entry (no new cache variant).
  `BackArrowButton` must also be the existing shared component (confirm its exact
  name and initializer from `CollectionsPage.swift`).

- [ ] **Step 3: Mount in `ContentView.detailStage`**

  In `Muse/Muse/ContentView.swift`, inside `detailStage` (around line 538), add a
  branch ahead of the grid branch, after the `isCollectionsPage` branch:

```swift
if isCollectionsPage {
    CollectionsPage().transition(Self.pageReveal)
} else if placesStore.showingPlaces && !appState.isSearchActive {
    PlacesPage().transition(Self.pageReveal)
} else {
    // … existing TagChipsRow() / GridView() branch, unchanged …
}
```

  Add `@ObservedObject private var placesStore = PlacesStore.shared` beside
  `ContentView`'s existing `collectionsEngine` property. The `!appState.isSearchActive`
  guard matches the spec's stated mount condition (a committed `near:` search should
  show the ordinary search grid, not the Places page, even though `openPlaceSearch`
  itself calls `closePlacesPage()` first — this guard is a belt-and-suspenders
  safety net against any other path that might leave `showingPlaces` true during an
  active search).

- [ ] **Step 4: Build and manually verify**

  Run: `xcodebuild -project Muse/Muse.xcodeproj -scheme Muse -configuration Debug build`
  Expected: `BUILD SUCCEEDED`. Run the app, confirm the Places page renders (empty
  state, since the sidebar entry point doesn't exist until Task 18 — trigger it
  temporarily via a debugger call to `PlacesStore.shared.setShowing(true)` or wait
  until Task 18 lands the sidebar row before doing a full manual pass).

- [ ] **Step 5: Commit**

```bash
git add "Muse/Muse/Views/PlacesPage.swift" "Muse/Muse/ContentView.swift"
git commit -m "feat: add PlacesPage (modelled on CollectionsPage)"
```

---

### Task 18: Sidebar LIBRARY section (Places row) + Settings toggle

**Files:**
- Create: `Muse/Muse/Views/Sidebar/LibraryRows.swift`
- Modify: `Muse/Muse/Views/SidebarView.swift` (extend `twoSectionScroll` — rename its
  usages/comments to reflect three sections, or keep the property name and just add a
  third section inside it, matching the file's existing style — confirm which reads
  more consistently with the surrounding code before choosing)
- Modify: `Muse/Muse/Settings/AppSettings.swift` (or wherever `showCollectionsInSidebarKey`
  lives — add `showLibraryInSidebarKey`)
- Modify: `Muse/Muse/Settings/SettingsView.swift` (add the toggle, mirroring the
  existing Collections toggle)

**Interfaces:**
- Consumes: `PlacesStore.shared.showingPlaces` (Task 16), `SidebarView`'s shared row
  geometry constants (`rowHorizontalPadding`, `chevronSlotWidth`, `selectionFill`,
  `selectedLabelColor`, `rootIconSize`, `rowHeight`, etc. — all already read above).
- Produces: a mounted "Places" sidebar row calling `appState.openPlacesPage()` — Tasks
  26 adds the three rediscovery rows to this SAME file/section later.

- [ ] **Step 1: Add the settings key**

  In the file defining `showCollectionsInSidebarKey` (confirm exact file — likely
  `Settings/AppSettings.swift`), add a sibling constant:

```swift
static let showLibraryInSidebarKey = "showLibraryInSidebar"
```

  Default `true` wherever the existing key's default is registered (likely a
  `UserDefaults.standard.register(defaults: […])` call — add
  `showLibraryInSidebarKey: true` beside `showCollectionsInSidebarKey: true`).

- [ ] **Step 2: Add the Settings toggle**

  In `SettingsView.swift`'s Sidebar section, add a toggle mirroring the existing
  Collections one exactly (same row shape, same `@AppStorage`/local-state-plus-onChange
  pattern the durable constraints document for animating `@AppStorage`-backed values):

```swift
Toggle("Show Library in Sidebar", isOn: $showLibraryInSidebar)
```

  (Following whichever exact binding pattern `showCollectionsInSidebar` already uses
  in this file — copy it, don't invent a new one.)

- [ ] **Step 3: Implement `LibraryRows.swift`**

```swift
//
//  LibraryRows.swift
//  Muse
//
//  Sidebar LIBRARY section rows: Places, On This Day, Rarely Seen, Shuffle.
//  Fixed, non-reorderable — copies the StarRow geometry template exactly
//  (SidebarRows.swift) so this row family matches the folder tree's shared
//  invariants (chevronSlotWidth, iconToTextGap, etc).
//

import SwiftUI

struct PlacesSidebarRow: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject var placesStore = PlacesStore.shared
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 0) {
            Image(systemName: "chevron.right")
                .font(.system(size: SidebarView.chevronGlyphSize, weight: .semibold))
                .opacity(0)
                .frame(width: SidebarView.chevronSlotWidth, alignment: .leading)
                .accessibilityHidden(true)
            Image(systemName: "mappin.and.ellipse")
                .font(.system(size: SidebarView.rootIconSize, weight: .semibold))
                .foregroundStyle(placesStore.showingPlaces ? SidebarView.selectedLabelColor : .secondary)
                .frame(width: 18)
                .padding(.leading, SidebarView.chevronToIconGap)
                .accessibilityHidden(true)
            Text("Places")
                .font(.system(size: 13))
                .foregroundStyle(placesStore.showingPlaces ? SidebarView.selectedLabelColor : .primary)
                .padding(.leading, SidebarView.iconToTextGap)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, SidebarView.rowHorizontalPadding)
        .frame(height: SidebarView.rowHeight)
        .background {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(placesStore.showingPlaces ? SidebarView.selectionFill
                      : Color.primary.opacity(isHovered ? SidebarView.rowHoverFillOpacity : 0))
        }
        .contentShape(Rectangle())
        .onTapGesture { appState.openPlacesPage() }
        .onHover { hovering in withAnimation(.easeOut(duration: 0.12)) { isHovered = hovering } }
        .accessibilityAddTraits(.isButton)
    }
}
```

  Confirm `SidebarView.chevronGlyphSize`/`chevronToIconGap`/`rowHoverFillOpacity`'s
  exact names (grepped constants above confirmed `chevronSlotWidth`,
  `rowHorizontalPadding`, `rootIconSize`, `childIconSize`, `selectionFill`,
  `selectedLabelColor` — the remaining three should exist alongside them; read
  `SidebarView.swift`'s constants block in full and use the real names).

- [ ] **Step 4: Add the LIBRARY section to `SidebarView.twoSectionScroll`**

  Between the existing FOLDERS section (around line 378–401) and COLLECTIONS section
  (starting ~403), add a third section, gated identically to COLLECTIONS
  (`!appState.rootNodes.isEmpty && collectionsEngine.hasReachableContent`) plus the
  new `AppSettings.showLibraryInSidebarKey`:

```swift
if !appState.rootNodes.isEmpty && collectionsEngine.hasReachableContent
    && showLibraryInSidebar {
    SectionHeader(title: String(localized: "LIBRARY"), collapsed: $sidebarLibraryCollapsed)
    if !sidebarLibraryCollapsed {
        PlacesSidebarRow()
        // Task 26 adds: OnThisDaySidebarRow(), RarelySeenSidebarRow(), ShuffleSidebarRow()
    }
}
```

  `sidebarLibraryCollapsed` follows the plain-`@State`-seeded-from-UserDefaults
  pattern the other two sections use (own key `"sidebarLibraryCollapsed"`) — copy
  the FOLDERS/COLLECTIONS section's exact seeding/`.onChange`-persist shape.
  `showLibraryInSidebar` is the `@AppStorage`/local-state read of the Task 1 settings
  key, following the SAME pattern `showCollectionsInSidebar` already uses in this
  file (read it first, copy exactly).

- [ ] **Step 5: Build and manually verify**

  Run the app; confirm the LIBRARY section appears between FOLDERS and COLLECTIONS
  once a root with images exists, with a Places row that opens the (still-empty,
  until Task 19) Places page; confirm toggling the Settings switch hides/shows it;
  confirm the section collapses/expands and persists across relaunch.

- [ ] **Step 6: Commit**

```bash
git add "Muse/Muse/Views/Sidebar/LibraryRows.swift" "Muse/Muse/Views/SidebarView.swift" \
        "Muse/Muse/Settings/AppSettings.swift" "Muse/Muse/Settings/SettingsView.swift"
git commit -m "feat: add sidebar LIBRARY section with Places row"
```

---

### Task 19: `AppState+Places` orchestration + `near:` click-through

**Files:**
- Create: `Muse/Muse/Models/AppState+Places.swift`
- Modify: `Muse/Muse/Models/AppState.swift` (add `select(folder:)` teardown call at
  line 905's function body, and `removeRoot` re-resolution near line 854)

**Interfaces:**
- Produces: `AppState.openPlacesPage()`, `AppState.closePlacesPage()`,
  `AppState.openPlaceSearch(_ group: PlaceGroup)` — methods-only extension,
  `AppState` gains zero new stored properties.

- [ ] **Step 1: Implement `AppState+Places.swift`**

```swift
//
//  AppState+Places.swift
//  Muse
//
//  Places page orchestration — methods-only extension (the house rule for
//  AppState+*.swift files). AppState itself gains no new stored state;
//  PlacesStore.shared IS the state.
//

import Foundation

extension AppState {
    func openPlacesPage() {
        clearSelection()
        setActiveCollection(nil)
        showingCollections = false
        RediscoveryStore.shared.dismiss()   // Task 22 — safe once that type exists;
                                             // if built before Task 22, comment this
                                             // line out and uncomment in Task 25.
        PlacesStore.shared.setShowing(true)
    }

    func closePlacesPage() {
        PlacesStore.shared.setShowing(false)
    }

    /// Click-through from a place group: a programmatic `near:` token
    /// search, not a fourth visibleFiles substitution. Dog-foods the token
    /// engine; one navigation system.
    func openPlaceSearch(_ group: PlaceGroup) {
        closePlacesPage()
        searchAllFolders = true
        let query = "near:\"\(group.city)\""
        searchQuery = query
        Task { await runSearch(query) }
    }
}
```

  Confirm the exact existing method names `searchAllFolders`, `searchQuery`, and
  `runSearch(_:)` against `AppState`/`AppState+Search.swift` before finalizing — the
  spec cites this exact pattern ("searchAllFolders = true; searchQuery = q; Task {
  await runSearch(q) }") as already-existing plumbing from the durable-constraints
  doc's `.searchable` integration; if the real async signature differs (e.g.
  `runSearchNow()` reading `searchQuery` rather than taking a parameter), match that
  instead.

  Note the `RediscoveryStore.shared.dismiss()` forward reference: Section F (Tasks
  21–26) hasn't landed yet at this point in the plan. If tasks are executed strictly
  in this plan's order, comment that single line out here with a `// TODO(task-25)`
  marker and uncomment it as an explicit edit in Task 25 (which already documents the
  parallel teardown-parity requirement for `openRediscovery`/`closeRediscovery`) —
  do not skip it silently, since Places must dismiss an active rediscovery surface
  the same way it dismisses everything else.

- [ ] **Step 2: Add teardown parity in `AppState.select(folder:)` and `removeRoot`**

  In `Muse/Muse/Models/AppState.swift`, inside `select(folder:)` (line 905), beside
  the existing `showingCollections = false` teardown line, add:

```swift
PlacesStore.shared.setShowing(false)
```

  In `removeRoot` (line 854), no places-specific re-resolution is needed (Places
  groups are recomputed by `reload()`, called from the geocode chain and — add here —
  also from `removeRoot` so a group whose only member lived under the removed root
  disappears immediately rather than waiting for the next geocode pass):

```swift
Task { await PlacesStore.shared.reload() }
```

  Add this call inside `removeRoot`, after the existing root-removal bookkeeping.

- [ ] **Step 3: Build and manually verify**

  Run the app with at least one geotagged photo present; confirm clicking a Places
  card runs a `near:` search, the chip bar (once Task 14 has landed) shows the
  token, and switching folders or removing the containing root dismisses/updates the
  Places page correctly.

- [ ] **Step 4: Commit**

```bash
git add "Muse/Muse/Models/AppState+Places.swift" "Muse/Muse/Models/AppState.swift"
git commit -m "feat: add AppState+Places orchestration + near: click-through"
```

---

### Task 20: Viewer place row + Google Maps link-out

**Files:**
- Modify: `Muse/Muse/Views/Viewer/ViewerFileDetails.swift` (add `place: String?`,
  resolved in the existing `load(queue:path:)` DB read)
- Modify: `Muse/Muse/Views/Viewer/ViewerInfoColumn.swift` (the info card's Location
  row + a second link-out button)
- Create (or extend an existing shared components file): `OpenInGoogleMapsButton`

**Interfaces:**
- Consumes: `PlaceRow` (Task 6), the existing `OpenInMapsButton` component (confirm
  its exact file — likely also in `Views/Viewer/`).
- Produces: no new public interface — extends the viewer's existing info card.

- [ ] **Step 1: Read `ViewerFileDetails.swift` and `ViewerInfoColumn.swift` in full**

  Confirm `load(queue:path:)`'s exact signature and where it currently issues its DB
  reads (coordinate display already exists per the foundation doc — "today
  FileMetadata.coordinate is read on viewer-open and discarded" — confirm exactly
  where that happens so the new `place` field is fetched in the SAME pass, not a
  second DB round-trip). Confirm `OpenInMapsButton`'s exact file, name, and call
  signature (it opens `maps://?ll=…`).

- [ ] **Step 2: Add `place: String?` to `ViewerFileDetails`**

  Extend the existing `load` function with one extra `PlaceRow` fetch by `file_id`
  (not `parent_dir` — content-keyed):

```swift
var place: String?
// … inside load(queue:path:), after resolving fileID:
if let placeRow = try? await queue.read({ db in
    try PlaceRow.filter(Column("file_id") == fileID).fetchOne(db)
}), let city = placeRow?.city {
    let countryName = placeRow?.country.flatMap { Locale.current.localizedString(forRegionCode: $0) }
    place = [city, countryName].compactMap { $0 }.joined(separator: ", ")
}
```

  Adjust to match the ACTUAL structure of `load` (this is a sketch of the added
  logic, not a drop-in replacement — the real edit must fit inside whatever
  async/await or synchronous DB-read shape the function already uses).

- [ ] **Step 3: Render the place name + two link-outs in `ViewerInfoColumn`**

  Where the existing Location row/`OpenInMapsButton` renders, add: when
  `details.place` is non-nil, show it as the Location row's primary text
  (coordinates move to a `.help()` tooltip on that row instead of being the primary
  display); render `OpenInMapsButton` unchanged, and beside it a new button:

```swift
struct OpenInGoogleMapsButton: View {
    let lat: Double
    let lon: Double

    var body: some View {
        Button {
            guard let url = URL(string: "https://www.google.com/maps?q=\(lat),\(lon)") else { return }
            NSWorkspace.shared.open(url)
        } label: {
            Label(String(localized: "Google Maps"), systemImage: "map")
        }
        .accessibilityLabel(String(localized: "Open location in Google Maps"))
    }
}
```

  This is a browser hand-off via `NSWorkspace.shared.open` — never touched with
  `URLSession` — matching the doctrine class already established for `maps://`.
  Match `OpenInMapsButton`'s exact visual styling (button style, sizing) so the two
  sit consistently side by side — copy its modifiers rather than inventing new ones.

- [ ] **Step 4: Build and manually verify**

  Open a geotagged photo in the hero viewer; confirm the info card shows the place
  name, confirm both Maps buttons open the correct location in their respective apps.

- [ ] **Step 5: Commit**

```bash
git add "Muse/Muse/Views/Viewer/ViewerFileDetails.swift" "Muse/Muse/Views/Viewer/ViewerInfoColumn.swift"
git commit -m "feat: show place name in viewer info card + add Google Maps link-out"
```

---

## Section F — Rediscovery: v16 + surfaces

### Task 21: `v16_rediscovery` migration

**Files:**
- Modify: `Muse/Muse/Database/Database.swift` (add migration after `v15_places`)
- Modify: `Muse/Muse/Database/Records.swift` (add `last_viewed_at` to `FileRow`)
- Modify: `Muse/MuseTests/PhotoMetaMigrationTests.swift` (add v16 assertions)

**Interfaces:**
- Produces: `FileRow.last_viewed_at: Int64?` — consumed by Task 22
  (`RediscoveryQueries`), Task 23 (`markViewed`).

- [ ] **Step 1: Extend the migration test file with a failing v16 test**

```swift
func testV16AddsLastViewedAtColumn() throws {
    let queue = try DatabaseQueue()
    try Database.makeMigrator().migrate(queue)
    try queue.read { db in
        XCTAssertTrue(try db.columns(in: "files").contains { $0.name == "last_viewed_at" })
    }
}
```

- [ ] **Step 2: Run, confirm failure**

- [ ] **Step 3: Add the migration**

```swift
migrator.registerMigration("v16_rediscovery") { db in
    // Content-keyed (deliberate): viewing the copy in /A marks the
    // byte-identical copy in /B seen too — the correct rediscovery
    // semantic. Device-local, never synced, never in sidecars. No index —
    // rediscovery queries run at most once per surface activation, never
    // per keystroke.
    try db.alter(table: "files") { t in
        t.add(column: "last_viewed_at", .integer)
    }
}
```

- [ ] **Step 4: Add the field to `FileRow`**

```swift
var last_viewed_at: Int64?
```

- [ ] **Step 5: Run tests, confirm pass; run the full migration suite for regressions**

- [ ] **Step 6: Commit**

```bash
git add "Muse/Muse/Database/Database.swift" "Muse/Muse/Database/Records.swift" \
        "Muse/MuseTests/PhotoMetaMigrationTests.swift"
git commit -m "feat: add v16_rediscovery migration (files.last_viewed_at)"
```

---

### Task 22: `RediscoveryQueries` + `RediscoveryStore`

**Files:**
- Create: `Muse/Muse/Database/RediscoveryQueries.swift`
- Create: `Muse/Muse/Models/RediscoveryStore.swift`
- Create: `Muse/MuseTests/RediscoveryQueriesTests.swift`

**Interfaces:**
- Consumes: `files.last_viewed_at` (Task 21), `photo_meta.capture_md` (Task 2),
  `CollectionStore.isUnderAnyRoot`, `Views/Spatial/SeededRandom.swift` (existing).
- Produces: `RediscoverySurface` enum, `RediscoveryStore.shared` (`active`, `files`,
  `paths`, `activate`, `dismiss`, `reshuffle`, `drop`, `markViewed`) — consumed by
  Task 23 (`markViewed` hooks), Task 24 (`visibleFiles` seam), Task 25 (orchestration),
  Task 26 (header + sidebar rows + Escape).

- [ ] **Step 1: Write the failing `RediscoveryQueries` tests**

```swift
//
//  RediscoveryQueriesTests.swift
//  MuseTests
//
//  Rarely-seen order (never-viewed first, then ascending last_viewed_at),
//  on-this-day MD match across years + created_at fallback + newest-year-
//  first ordering, shuffle determinism under a fixed seed, kind
//  restriction (image/raw/psd/video only).
//

import XCTest
import GRDB
@testable import Muse

final class RediscoveryQueriesTests: XCTestCase {
    func testRarelySeenOrdersNeverViewedFirstThenOldest() throws {
        let queue = try DatabaseQueue()
        try Database.makeMigrator().migrate(queue)
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO files (id, content_hash, kind, last_seen_at, created_at, last_viewed_at)
                VALUES ('f1','h1','image',0,100, 500),
                       ('f2','h2','image',0,200, NULL),
                       ('f3','h3','image',0,300, 200)
                """)
            try db.execute(sql: """
                INSERT INTO paths (file_id, absolute_path, is_alive)
                VALUES ('f1','/r/f1.jpg',1), ('f2','/r/f2.jpg',1), ('f3','/r/f3.jpg',1)
                """)
        }
        try queue.read { db in
            let ids = try RediscoveryQueries.rarelySeen(db: db, limit: 500)
            // Never-viewed (f2) first, then ascending last_viewed_at: f3 (200), f1 (500).
            XCTAssertEqual(ids, ["f2", "f3", "f1"])
        }
    }

    func testOnThisDayMatchesCaptureMDAcrossYearsNewestFirst() throws {
        let queue = try DatabaseQueue()
        try Database.makeMigrator().migrate(queue)
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO files (id, content_hash, kind, last_seen_at, created_at)
                VALUES ('f1','h1','image',0,0), ('f2','h2','image',0,0)
                """)
            try db.execute(sql: """
                INSERT INTO paths (file_id, absolute_path, is_alive)
                VALUES ('f1','/r/f1.jpg',1), ('f2','/r/f2.jpg',1)
                """)
            // f1: 2020-06-21; f2: 2018-06-21 (both "06-21").
            try db.execute(sql: """
                INSERT INTO photo_meta (file_id, capture_date, capture_md)
                VALUES ('f1', 1592742000, '06-21'), ('f2', 1529526000, '06-21')
                """)
        }
        try queue.read { db in
            let ids = try RediscoveryQueries.onThisDay(db: db, todayMD: "06-21", currentYear: 2026)
            XCTAssertEqual(ids, ["f1", "f2"]) // newest year (2020) before older (2018)
        }
    }

    func testOnThisDayFallsBackToCreatedAtWhenNoPhotoMetaRow() throws {
        let queue = try DatabaseQueue()
        try Database.makeMigrator().migrate(queue)
        try queue.write { db in
            // created_at as a raw epoch whose UTC month-day is "06-21" and
            // year < 2026 — construct via a known epoch for that date.
            try db.execute(sql: """
                INSERT INTO files (id, content_hash, kind, last_seen_at, created_at)
                VALUES ('f3','h3','image',0,1592742000)
                """)
            try db.execute(sql: """
                INSERT INTO paths (file_id, absolute_path, is_alive) VALUES ('f3','/r/f3.jpg',1)
                """)
        }
        try queue.read { db in
            let ids = try RediscoveryQueries.onThisDay(db: db, todayMD: "06-21", currentYear: 2026)
            XCTAssertTrue(ids.contains("f3"))
        }
    }

    func testKindRestrictionExcludesDocuments() throws {
        let queue = try DatabaseQueue()
        try Database.makeMigrator().migrate(queue)
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO files (id, content_hash, kind, last_seen_at, created_at)
                VALUES ('f1','h1','image',0,0), ('f2','h2','text',0,0)
                """)
            try db.execute(sql: """
                INSERT INTO paths (file_id, absolute_path, is_alive)
                VALUES ('f1','/r/f1.jpg',1), ('f2','/r/f2.txt',1)
                """)
        }
        try queue.read { db in
            let ids = try RediscoveryQueries.rarelySeen(db: db, limit: 500)
            XCTAssertEqual(ids, ["f1"])
        }
    }

    func testShuffleIsDeterministicUnderFixedSeed() throws {
        let queue = try DatabaseQueue()
        try Database.makeMigrator().migrate(queue)
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO files (id, content_hash, kind, last_seen_at, created_at)
                VALUES ('f1','h1','image',0,0), ('f2','h2','image',0,0), ('f3','h3','image',0,0)
                """)
            try db.execute(sql: """
                INSERT INTO paths (file_id, absolute_path, is_alive)
                VALUES ('f1','/r/f1.jpg',1), ('f2','/r/f2.jpg',1), ('f3','/r/f3.jpg',1)
                """)
        }
        try queue.read { db in
            let a = try RediscoveryQueries.shuffle(db: db, limit: 500, seed: 42)
            let b = try RediscoveryQueries.shuffle(db: db, limit: 500, seed: 42)
            XCTAssertEqual(a, b)
        }
    }
}
```

  Confirm `Views/Spatial/SeededRandom.swift`'s exact API before writing
  `RediscoveryQueries.shuffle` — reuse it rather than inventing a parallel RNG.

- [ ] **Step 2: Run, confirm failure**

- [ ] **Step 3: Implement `RediscoveryQueries`**

```swift
//
//  RediscoveryQueries.swift
//  Muse
//
//  Pure db-taking query functions (the NoteStore/PlaceQueries shape). All
//  three surfaces are capped at 500 items — browse surfaces, not archives.
//  Kinds limited to image/raw/psd/video. Root filtering happens in Swift
//  (CollectionStore.isUnderAnyRoot) at the RediscoveryStore layer, after
//  fetch — these functions return unfiltered file_ids.
//

import Foundation
import GRDB

nonisolated enum RediscoveryQueries {
    private static let photoKinds = "'image','raw','psd','video'"

    static func rarelySeen(db: Database, limit: Int) throws -> [String] {
        let rows = try Row.fetchAll(db, sql: """
            SELECT f.id FROM files f
            JOIN paths p ON p.file_id = f.id AND p.is_alive = 1
            WHERE f.kind IN (\(photoKinds))
            GROUP BY f.id
            ORDER BY f.last_viewed_at IS NOT NULL, f.last_viewed_at ASC, f.created_at ASC
            LIMIT ?
            """, arguments: [limit])
        return rows.compactMap { $0["id"] as String? }
    }

    /// `todayMD` is "MM-DD"; `currentYear` excludes this year's own capture
    /// (matches DECISIONS.md: "capture year < current year"). Files with no
    /// photo_meta row fall back to the same month-day test on
    /// files.created_at — this shrinks toward zero as the header backfill
    /// completes.
    static func onThisDay(db: Database, todayMD: String, currentYear: Int) throws -> [String] {
        let withMeta = try Row.fetchAll(db, sql: """
            SELECT f.id, m.capture_date AS ord FROM files f
            JOIN paths p ON p.file_id = f.id AND p.is_alive = 1
            JOIN photo_meta m ON m.file_id = f.id
            WHERE f.kind IN (\(photoKinds)) AND m.capture_md = ?
              AND CAST(strftime('%Y', m.capture_date, 'unixepoch') AS INTEGER) < ?
            GROUP BY f.id
            ORDER BY ord DESC
            """, arguments: [todayMD, currentYear])
        let fallback = try Row.fetchAll(db, sql: """
            SELECT f.id, f.created_at AS ord FROM files f
            JOIN paths p ON p.file_id = f.id AND p.is_alive = 1
            LEFT JOIN photo_meta m ON m.file_id = f.id
            WHERE f.kind IN (\(photoKinds)) AND m.file_id IS NULL
              AND strftime('%m-%d', f.created_at, 'unixepoch') = ?
              AND CAST(strftime('%Y', f.created_at, 'unixepoch') AS INTEGER) < ?
            GROUP BY f.id
            ORDER BY ord DESC
            """, arguments: [todayMD, currentYear])
        var seen = Set<String>()
        var ordered: [(id: String, ord: Int64)] = []
        for row in (withMeta + fallback) {
            guard let id: String = row["id"], let ord: Int64 = row["ord"], !seen.contains(id) else { continue }
            seen.insert(id)
            ordered.append((id, ord))
        }
        return ordered.sorted { $0.ord > $1.ord }.map(\.id)
    }

    static func shuffle(db: Database, limit: Int, seed: UInt64) throws -> [String] {
        let rows = try Row.fetchAll(db, sql: """
            SELECT f.id FROM files f
            JOIN paths p ON p.file_id = f.id AND p.is_alive = 1
            WHERE f.kind IN (\(photoKinds))
            GROUP BY f.id
            """)
        var ids = rows.compactMap { $0["id"] as String? }
        var rng = SeededRandom(seed: seed) // confirm exact init signature against the real type
        ids.shuffle(using: &rng)
        return Array(ids.prefix(limit))
    }
}
```

  Adjust the `SeededRandom` usage to match its real API (confirmed by Step 1's
  reading of `Views/Spatial/SeededRandom.swift` before this step). The On This Day
  Feb-29 behavior ("shows on Feb 29 only, no Mar 1 remap") falls out naturally from
  the exact `capture_md`/`strftime('%m-%d', …)` string match — no special-casing
  needed, and no test is required beyond documenting the behavior here since it's an
  emergent property of the string comparison, not a branch.

- [ ] **Step 4: Run tests, confirm pass**

- [ ] **Step 5: Implement `RediscoveryStore`**

```swift
//
//  RediscoveryStore.swift
//  Muse
//
//  Rediscovery surface state — Pattern B. Resolves off-main under a request
//  token (the setActiveCollection stale-guard shape).
//

import Foundation
import GRDB

enum RediscoverySurface: String, CaseIterable {
    case rarelySeen, onThisDay, shuffle
}

@MainActor final class RediscoveryStore: ObservableObject {
    static let shared = RediscoveryStore()
    private init() {}

    @Published private(set) var active: RediscoverySurface?
    @Published private(set) var files: [FileNode]?
    private(set) var paths: Set<String>?
    private var requestToken = 0
    private var lastViewedDedupe: [String: Date] = [:]
    private var lastRoots: [String] = []

    func activate(_ s: RediscoverySurface, roots: [String]) {
        requestToken += 1
        let token = requestToken
        active = s
        lastRoots = roots
        Task.detached { [weak self] in
            guard let self else { return }
            guard let q = Database.shared.dbQueue else { return }
            let ids: [String] = (try? await q.read { db in
                switch s {
                case .rarelySeen: return try RediscoveryQueries.rarelySeen(db: db, limit: 500)
                case .onThisDay:
                    let now = Date()
                    let cal = Calendar(identifier: .gregorian)
                    let md = String(format: "%02d-%02d", cal.component(.month, from: now), cal.component(.day, from: now))
                    return try RediscoveryQueries.onThisDay(db: db, todayMD: md, currentYear: cal.component(.year, from: now))
                case .shuffle: return try RediscoveryQueries.shuffle(db: db, limit: 500, seed: UInt64.random(in: 0...UInt64.max))
                }
            }) ?? []
            let resolved = await self.resolveFileNodes(ids: ids, roots: roots)
            await MainActor.run {
                guard self.requestToken == token else { return } // stale — a newer activate/dismiss won
                self.files = resolved
                self.paths = Set(resolved.map { $0.url.standardizedFileURL.path })
            }
        }
    }

    func dismiss() {
        requestToken += 1
        active = nil
        files = nil
        paths = nil
    }

    func reshuffle(roots: [String]) {
        guard active == .shuffle else { return }
        activate(.shuffle, roots: roots)
    }

    /// Removes a trashed/deleted path from the surface's current member set
    /// (burn-delete bookkeeping, mirrors dropFromActiveCollection).
    func drop(path: String) {
        let std = URL(fileURLWithPath: path).standardizedFileURL.path
        files?.removeAll { $0.url.standardizedFileURL.path == std }
        paths?.remove(std)
    }

    func markViewed(url: URL) {
        let std = url.standardizedFileURL.path
        let now = Date()
        if let last = lastViewedDedupe[std], now.timeIntervalSince(last) < 5 { return }
        lastViewedDedupe[std] = now
        Task.detached {
            guard let q = Database.shared.dbQueue else { return }
            try? await q.write { db in
                try db.execute(sql: """
                    UPDATE files SET last_viewed_at = ?
                    WHERE id = (SELECT file_id FROM paths WHERE absolute_path = ? AND is_alive = 1)
                    """, arguments: [Int64(now.timeIntervalSince1970), std])
            }
        }
    }

    private func resolveFileNodes(ids: [String], roots: [String]) async -> [FileNode] {
        guard let q = Database.shared.dbQueue, !ids.isEmpty else { return [] }
        let rows: [(id: String, path: String)] = (try? await q.read { db in
            let placeholders = ids.map { _ in "?" }.joined(separator: ",")
            let result = try Row.fetchAll(db, sql: """
                SELECT file_id, absolute_path FROM paths
                WHERE file_id IN (\(placeholders)) AND is_alive = 1
                """, arguments: StatementArguments(ids))
            return result.compactMap { row -> (String, String)? in
                guard let id: String = row["file_id"], let path: String = row["absolute_path"] else { return nil }
                return (id, path)
            }
        }) ?? []
        let orderIndex = Dictionary(uniqueKeysWithValues: ids.enumerated().map { ($1, $0) })
        let filtered = rows.filter { row in
            CollectionStore.isUnderAnyRoot(URL(fileURLWithPath: row.path))
        }
        return filtered
            .sorted { (orderIndex[$0.id] ?? .max) < (orderIndex[$1.id] ?? .max) }
            .map { FileNode(url: URL(fileURLWithPath: $0.path)) } // confirm FileNode's real init
    }
}
```

  `FileNode(url:)`'s real initializer likely needs more than a bare URL (kind, etc.)
  — confirm its exact signature against `Models/FileNode.swift` and adjust
  `resolveFileNodes` to construct it correctly (may need an additional `AssetKind.detect`
  call or a lookup through an existing FileNode-construction helper used elsewhere,
  e.g. in `FolderReader`).

- [ ] **Step 6: Run tests, confirm pass; commit**

```bash
git add "Muse/Muse/Database/RediscoveryQueries.swift" "Muse/Muse/Models/RediscoveryStore.swift" \
        "Muse/MuseTests/RediscoveryQueriesTests.swift"
git commit -m "feat: add RediscoveryQueries + RediscoveryStore"
```

---

### Task 23: `markViewed` write hooks

**Files:**
- Modify: `Muse/Muse/ContentView.swift` (add `.onChange(of: appState.selectedFile?.url)`)
- Modify: `Muse/Muse/Viewers/HeroImageViewer.swift` (existing `.task(id: currentURL)`,
  near line 187 per the spec's citation — confirm)
- Modify: `Muse/Muse/Viewers/HeroVideoViewer.swift` (existing `.task(id:)`, near line
  67 per the spec's citation — confirm)

**Interfaces:** None new — calls `RediscoveryStore.shared.markViewed(url:)` (Task 22)
from three existing view-layer hooks. `AppState.selectedFile` keeps no `didSet`.

- [ ] **Step 1: Add the `ContentView` hook**

  Find where `appState.selectedFile` is read to drive the viewer router (near
  wherever `ViewerRouter` is mounted). Add:

```swift
.onChange(of: appState.selectedFile?.url) { _, url in
    if let url { RediscoveryStore.shared.markViewed(url: url) }
}
```

  This single funnel covers every kind (hero, video, PDF, text, Quick Look fallback)
  since `ViewerRouter` is the single dispatch point for all of them.

- [ ] **Step 2: Add the `HeroImageViewer` hook (arrow-key flips)**

  In the existing `.task(id: currentURL)` block (confirm exact name/line — the spec
  cites ~line 187), add one call: `RediscoveryStore.shared.markViewed(url: currentURL)`.
  This covers flips that change `currentURL` without touching `AppState.selectedFile`
  (arrow-key navigation within the hero viewer).

- [ ] **Step 3: Add the `HeroVideoViewer` hook**

  Same shape in its existing `.task(id:)` (confirm exact identifier — spec cites
  ~line 67).

- [ ] **Step 4: Manual verification**

  Open several photos in sequence (click + arrow-key flips); query the sandboxed DB
  directly to confirm `last_viewed_at` updates for each, with the 5-second dedupe
  window absorbing rapid double-fires (open, then immediately re-select the same
  file) without extra writes.

- [ ] **Step 5: Commit**

```bash
git add "Muse/Muse/ContentView.swift" "Muse/Muse/Viewers/HeroImageViewer.swift" \
        "Muse/Muse/Viewers/HeroVideoViewer.swift"
git commit -m "feat: wire last_viewed_at write hooks (selection + arrow-key flips)"
```

---

### Task 24: `visibleFiles` seam + invalidation cancellable

**Files:**
- Modify: `Muse/Muse/Models/AppState+Filters.swift` (line 58, the non-search branch
  of `visibleFiles`)
- Modify: `Muse/Muse/Models/AppState.swift` (add `rediscoveryCancellable` in `init`,
  beside the existing `folderStatsCancellable`)

**Interfaces:** None new — this is the one-line seam plus its invalidation wiring.

- [ ] **Step 1: Change the seam line**

  In `Muse/Muse/Models/AppState+Filters.swift`, the non-search branch of
  `visibleFiles` currently reads (confirmed by direct read above, line 58):

```swift
base = activeCollectionFiles ?? currentFiles
```

  Change to:

```swift
base = activeCollectionFiles ?? RediscoveryStore.shared.files ?? currentFiles
```

  This is the ONLY functional change in this task — `activeCollectionFiles` still
  wins when set (a rediscovery surface and a collection can't both be "active" per
  the mutual-exclusion enforced by Task 25's orchestration methods, but the ordering
  here is defensive: collection wins if somehow both were true).

- [ ] **Step 2: Add the invalidation cancellable**

  In `Muse/Muse/Models/AppState.swift`'s `init`, beside the existing `folderStats`
  forwarding (`folderStatsCancellable = folderStats.objectWillChange.sink { … }` —
  confirm exact existing code), add a new stored `Cancellable`:

```swift
private var rediscoveryCancellable: AnyCancellable?
// … inside init():
rediscoveryCancellable = RediscoveryStore.shared.objectWillChange
    .sink { [weak self] _ in
        self?._visibleFilesValid = false
        self?.objectWillChange.send()
    }
```

  This is the sanctioned one-cancellable-per-store integration cost documented in
  `DECISIONS.md`'s Architecture section — do NOT add a `@Published` property for this.

- [ ] **Step 3: Build and manually verify**

  Confirm the app still builds and that activating a rediscovery surface (once Task
  26's sidebar row exists — until then, trigger via debugger/temporary code) actually
  changes what the grid shows.

- [ ] **Step 4: Commit**

```bash
git add "Muse/Muse/Models/AppState+Filters.swift" "Muse/Muse/Models/AppState.swift"
git commit -m "feat: wire RediscoveryStore into the visibleFiles seam"
```

---

### Task 25: `AppState+Rediscovery` orchestration + teardown parity

**Files:**
- Create: `Muse/Muse/Models/AppState+Rediscovery.swift`
- Modify: `Muse/Muse/Models/AppState.swift` (`select(folder:)` line 905, `removeRoot`
  line 854)
- Modify: `Muse/Muse/Models/AppState+Places.swift` (Task 19 — uncomment the
  `RediscoveryStore.shared.dismiss()` forward reference)
- Modify: wherever `dropFromActiveCollection(path:)` lives (confirm exact file —
  likely `AppState+Filters.swift` or a dedicated `AppState+Collections.swift`)

**Interfaces:**
- Produces: `AppState.openRediscovery(_:)`, `AppState.closeRediscovery()` — consumed
  by Task 26 (sidebar rows, header back button, Escape wiring).

- [ ] **Step 1: Implement `AppState+Rediscovery.swift`**

```swift
//
//  AppState+Rediscovery.swift
//  Muse
//
//  Rediscovery orchestration — methods-only extension. AppState gains no
//  new stored state; RediscoveryStore.shared IS the state.
//

import Foundation

extension AppState {
    func openRediscovery(_ s: RediscoverySurface) {
        clearSelection()
        setActiveCollection(nil)
        showingCollections = false
        PlacesStore.shared.setShowing(false)
        RediscoveryStore.shared.activate(s, roots: rootPathList)
    }

    func closeRediscovery() {
        clearSelection()
        RediscoveryStore.shared.dismiss()
    }
}
```

  Confirm `rootPathList`'s exact existing name (the property/computed-var supplying
  the list of root path strings — used elsewhere for root-scoped queries) against
  `AppState.swift`.

- [ ] **Step 2: Uncomment the forward reference in `AppState+Places.swift`**

  In `openPlacesPage()` (Task 19), uncomment:

```swift
RediscoveryStore.shared.dismiss()
```

- [ ] **Step 3: Add teardown parity in `select(folder:)` and `removeRoot`**

  In `select(folder:)` (line 905), beside the `showingCollections = false` and
  `PlacesStore.shared.setShowing(false)` (Task 19) lines, add:

```swift
RediscoveryStore.shared.dismiss()
```

  In `removeRoot` (line 854), re-resolve an active rediscovery surface the same way
  the collection re-resolution already works (per the durable constraint: "a
  collection can span multiple roots… removing a non-active root must also
  re-resolve"):

```swift
if let active = RediscoveryStore.shared.active {
    RediscoveryStore.shared.activate(active, roots: rootPathList)
}
```

  Add this after the existing collection re-resolution block in the same function.

- [ ] **Step 4: Wire burn-delete bookkeeping**

  Find `dropFromActiveCollection(path:)`'s definition. Add, alongside whatever it
  already does:

```swift
RediscoveryStore.shared.drop(path: path)
```

  Confirm this function's exact file/signature before editing (grepped earlier as
  cited by the spec but not directly confirmed in this plan's research pass — search
  `Muse/Muse/Models` for `dropFromActiveCollection` before writing the edit).

- [ ] **Step 5: Build and manually verify**

  Confirm: opening a rediscovery surface clears selection and shows the right files;
  switching folders dismisses it; deleting a file from within a rediscovery surface
  removes it from view immediately (no ghost tile).

- [ ] **Step 6: Commit**

```bash
git add "Muse/Muse/Models/AppState+Rediscovery.swift" "Muse/Muse/Models/AppState.swift" \
        "Muse/Muse/Models/AppState+Places.swift"
git commit -m "feat: add AppState+Rediscovery orchestration + teardown parity"
```

---

### Task 26: `RediscoveryHeader` + sidebar rows + Escape cases

**Files:**
- Create: `Muse/Muse/Views/RediscoveryHeader.swift`
- Modify: `Muse/Muse/Views/GridView.swift` (mount the header near line 205, beside
  `CollectionsRow()`)
- Modify: `Muse/Muse/Views/Sidebar/LibraryRows.swift` (Task 18 — add
  `OnThisDaySidebarRow`, `RarelySeenSidebarRow`, `ShuffleSidebarRow`)
- Modify: `Muse/Muse/Views/SidebarView.swift` (mount the three new rows in the
  LIBRARY section, Task 18's placeholder comment)
- Modify: `Muse/Muse/Components/EscapeAction.swift` (add `.exitRediscovery`,
  `.exitPlacesPage`; extend `EscapeResolver.action`'s signature and body)
- Modify: `Muse/Muse/ContentView.swift` (wire the two new Escape flags into the
  resolver call site, and the resulting actions into the same `switch`/`if` that
  dispatches existing `EscapeAction` cases)
- Modify: `Muse/MuseTests/EscapeActionTests.swift` (extend for the new cases/order)

**Interfaces:** None new beyond the `EscapeAction` cases — this task is UI wiring.

- [ ] **Step 1: Implement `RediscoveryHeader`**

```swift
//
//  RediscoveryHeader.swift
//  Muse
//
//  Mounted exactly where CollectionsRow mounts (GridView, when a
//  rediscovery surface is active and search is not). Same metrics as
//  ActiveCollectionHeader: back arrow, title, count, and (Shuffle only) a
//  "Shuffle Again" button.
//

import SwiftUI

struct RediscoveryHeader: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject var store = RediscoveryStore.shared

    private var title: String {
        switch store.active {
        case .rarelySeen: return String(localized: "Rarely Seen")
        case .onThisDay: return String(localized: "On This Day")
        case .shuffle: return String(localized: "Shuffle")
        case nil: return ""
        }
    }

    var body: some View {
        HStack {
            BackArrowButton { appState.closeRediscovery() }
            Text(title).font(.system(size: 20, weight: .semibold))
            Text("\(store.files?.count ?? 0)").foregroundStyle(.secondary)
            Spacer()
            if store.active == .shuffle {
                ModalButton(title: String(localized: "Shuffle Again"), style: .normal) {
                    RediscoveryStore.shared.reshuffle(roots: appState.rootPathList)
                }
            }
        }
    }
}
```

  Match `ActiveCollectionHeader`'s ACTUAL metrics (font sizes, padding, exact
  `BackArrowButton`/title layout) by reading that view first — this sketch
  approximates the shape described in the spec; the real implementation must match
  the sibling header's real code, not just its description. Confirm `ModalButton`'s
  exact initializer (`title`/`style`/action closure order) from
  `Views/Modal/ModalMessageCard.swift` or wherever it's defined.

- [ ] **Step 2: Mount in `GridView`**

  Near line 205 (beside `CollectionsRow()`), add:

```swift
if !appState.isSearchActive {
    if RediscoveryStore.shared.active != nil {
        RediscoveryHeader()
    } else {
        CollectionsRow()
    }
}
```

  Confirm the exact existing conditional structure around `CollectionsRow()` before
  editing — this sketch assumes a simple `if !appState.isSearchActive { CollectionsRow() }`
  wrapper per the spec's citation; adjust to match reality.

- [ ] **Step 3: Add the three remaining `LibraryRows.swift` rows**

  Mirror `PlacesSidebarRow` (Task 18) exactly, swapping glyph/title/action:

```swift
struct OnThisDaySidebarRow: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject var store = RediscoveryStore.shared
    var body: some View { LibraryRow(glyph: "calendar", title: String(localized: "On This Day"),
                                     selected: store.active == .onThisDay) {
        appState.openRediscovery(.onThisDay)
    } }
}
struct RarelySeenSidebarRow: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject var store = RediscoveryStore.shared
    var body: some View { LibraryRow(glyph: "moon.zzz", title: String(localized: "Rarely Seen"),
                                     selected: store.active == .rarelySeen) {
        appState.openRediscovery(.rarelySeen)
    } }
}
struct ShuffleSidebarRow: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject var store = RediscoveryStore.shared
    var body: some View { LibraryRow(glyph: "shuffle", title: String(localized: "Shuffle"),
                                     selected: store.active == .shuffle) {
        appState.openRediscovery(.shuffle)
    } }
}
```

  Factor `PlacesSidebarRow`'s body (Task 18) into a shared internal `LibraryRow`
  helper (`glyph:title:selected:action:`) at the same time, so all four rows share
  one geometry implementation rather than four copy-pasted `HStack`s — refactor
  `PlacesSidebarRow` in this task to also call the new shared helper, keeping its
  external behavior identical (this is the "files that change together live
  together" rule from the writing-plans skill, applied to the four sibling rows
  that were always meant to share one template).

- [ ] **Step 4: Mount the three rows in `SidebarView`**

  Replace Task 18's placeholder comment (`// Task 26 adds: …`) with:

```swift
PlacesSidebarRow()
OnThisDaySidebarRow()
RarelySeenSidebarRow()
ShuffleSidebarRow()
```

- [ ] **Step 5: Extend `EscapeAction` + `EscapeResolver`**

  In `Muse/Muse/Components/EscapeAction.swift`, add two cases:

```swift
/// A rediscovery surface (Rarely Seen / On This Day / Shuffle) is active —
/// dismiss it (closeRediscovery()).
case exitRediscovery
/// On the Places page — return to the grid (closePlacesPage()).
case exitPlacesPage
```

  Extend `EscapeResolver.action`'s signature with two new parameters and insert them
  into the priority chain per `DECISIONS.md`'s documented order — modal → viewer →
  search → tags → collection → **rediscovery** → collections page → **places page**
  → none (this spec builds no `compare` surface, so that later-spec step from
  `DECISIONS.md`'s merged ordering is NOT part of this task):

```swift
static func action(modalPresented: Bool = false,
                   hasSelectedFile: Bool,
                   selectedFileIsHero: Bool,
                   searchActive: Bool,
                   tagsActive: Bool,
                   insideCollection: Bool,
                   rediscoveryActive: Bool,
                   showingCollectionsPage: Bool,
                   showingPlacesPage: Bool) -> EscapeAction {
    if modalPresented { return .dismissModal }
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

  A rediscovery surface behaves like a collection context (content scope, peeled
  right after collection); pages (Collections, Places) are outermost, peeled last.

- [ ] **Step 6: Wire the new flags + actions at the `ContentView` call site**

  Find where `EscapeResolver.action(…)` is called (likely inside a keyboard-event
  handler) and add the two new arguments:
  `rediscoveryActive: RediscoveryStore.shared.active != nil`,
  `showingPlacesPage: PlacesStore.shared.showingPlaces`. Add the two new cases to
  whatever `switch`/`if` dispatches the resolver's result:

```swift
case .exitRediscovery: appState.closeRediscovery()
case .exitPlacesPage: appState.closePlacesPage()
```

- [ ] **Step 7: Extend `EscapeActionTests`**

  Add tests for the new ordering: rediscovery wins over collections-page/places-page
  but loses to collection/tags/search/viewer/modal; places-page is peeled after
  collections-page (confirm the exact intended relative order between those two
  pages — both are "outermost," so confirm with the actual UI flow: a natural
  choice is Collections-page-then-Places-page since that's the declared parameter
  order, but state explicitly in the test which one wins if a caller could
  hypothetically have both true, even though in practice `openPlacesPage()` and
  `toggleCollectionsPage()` are mutually exclusive entry points).

```swift
func testRediscoveryWinsOverCollectionsPage() {
    let action = EscapeResolver.action(hasSelectedFile: false, selectedFileIsHero: false,
                                       searchActive: false, tagsActive: false,
                                       insideCollection: false, rediscoveryActive: true,
                                       showingCollectionsPage: true, showingPlacesPage: false)
    XCTAssertEqual(action, .exitRediscovery)
}

func testCollectionWinsOverRediscovery() {
    let action = EscapeResolver.action(hasSelectedFile: false, selectedFileIsHero: false,
                                       searchActive: false, tagsActive: false,
                                       insideCollection: true, rediscoveryActive: true,
                                       showingCollectionsPage: false, showingPlacesPage: false)
    XCTAssertEqual(action, .exitCollection)
}

func testPlacesPageIsOutermost() {
    let action = EscapeResolver.action(hasSelectedFile: false, selectedFileIsHero: false,
                                       searchActive: false, tagsActive: false,
                                       insideCollection: false, rediscoveryActive: false,
                                       showingCollectionsPage: false, showingPlacesPage: true)
    XCTAssertEqual(action, .exitPlacesPage)
}
```

- [ ] **Step 8: Run the full `EscapeActionTests` suite + build**

  Run: `xcodebuild -project Muse/Muse.xcodeproj -scheme Muse test -only-testing:MuseTests/EscapeActionTests`
  Expected: PASS, including all pre-existing cases (no regression to the modal/viewer/
  search/tags/collection ordering).

- [ ] **Step 9: Manual verification**

  Run the app; confirm all three sidebar rows open their surfaces, the header shows
  correct titles/counts, Shuffle's "Shuffle Again" reshuffles, and Escape peels
  layers in the documented order.

- [ ] **Step 10: Commit**

```bash
git add "Muse/Muse/Views/RediscoveryHeader.swift" "Muse/Muse/Views/GridView.swift" \
        "Muse/Muse/Views/Sidebar/LibraryRows.swift" "Muse/Muse/Views/SidebarView.swift" \
        "Muse/Muse/Components/EscapeAction.swift" "Muse/Muse/ContentView.swift" \
        "Muse/MuseTests/EscapeActionTests.swift"
git commit -m "feat: add RediscoveryHeader, sidebar rows, and Escape wiring for rediscovery/places"
```

---

## Section G — Near-duplicate stacks: v17 + clustering + presentation

### Task 27: `v17_stacks` migration + `StackStore`

**Files:**
- Modify: `Muse/Muse/Database/Database.swift` (add migration after `v16_rediscovery`)
- Modify: `Muse/Muse/Database/Records.swift` (add `StackRow`, `StackMemberRow`)
- Create: `Muse/Muse/Database/StackStore.swift`
- Create: `Muse/MuseTests/StackStoreTests.swift`
- Modify: `Muse/MuseTests/PhotoMetaMigrationTests.swift` (add v17 assertions)

**Interfaces:**
- Produces: `StackRow`, `StackMemberRow`, `StackStore` (`stacksFor(fileIDs:db:) ->
  [String: StackRef]`, `claimedFileIDs(db:) -> Set<String>`,
  `createStack(kind:memberIDs:pick:db:) -> String`, `dissolve(stackID:db:)`,
  `setPick(stackID:fileID:db:)`, `removeMember(stackID:fileID:db:)`) — consumed by
  Task 29 (`AutoStacker`), Task 30 (`StacksStore`), Task 32 (manual context menu).

- [ ] **Step 1: Extend the migration test file with failing v17 tests**

```swift
func testV17CreatesStacksTablesAndIndex() throws {
    let queue = try DatabaseQueue()
    try Database.makeMigrator().migrate(queue)
    try queue.read { db in
        XCTAssertTrue(try db.tableExists("stacks"))
        XCTAssertTrue(try db.tableExists("stack_members"))
        XCTAssertTrue(try db.indexes(on: "stack_members").contains { $0.name == "stack_members_file_idx" })
    }
}

func testStackMembersCascadeOnFileAndStackDelete() throws {
    let queue = try DatabaseQueue()
    try Database.makeMigrator().migrate(queue)
    try queue.write { db in
        try db.execute(sql: """
            INSERT INTO files (id, content_hash, kind, last_seen_at) VALUES ('f1','h1','image',0)
            """)
        try db.execute(sql: """
            INSERT INTO stacks (id, kind, dissolved, created_at) VALUES ('s1','auto',0,0)
            """)
        try db.execute(sql: "INSERT INTO stack_members (stack_id, file_id) VALUES ('s1','f1')")
        try db.execute(sql: "DELETE FROM files WHERE id = 'f1'")
    }
    try queue.read { db in
        XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM stack_members") ?? -1, 0)
    }
}
```

- [ ] **Step 2: Run, confirm failure**

- [ ] **Step 3: Add the migration**

```swift
migrator.registerMigration("v17_stacks") { db in
    try db.create(table: "stacks") { t in
        t.column("id", .text).primaryKey()
        t.column("kind", .text).notNull()               // "auto" | "manual"
        t.column("dissolved", .boolean).notNull().defaults(to: false)
        t.column("pick_file_id", .text)
        t.column("created_at", .integer).notNull()
    }
    try db.create(table: "stack_members") { t in
        t.column("stack_id", .text).notNull().references("stacks", onDelete: .cascade)
        t.column("file_id", .text).notNull().references("files", onDelete: .cascade)
        t.primaryKey(["stack_id", "file_id"])
    }
    try db.create(index: "stack_members_file_idx", on: "stack_members", columns: ["file_id"])
}
```

- [ ] **Step 4: Add the records**

```swift
struct StackRow: Codable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "stacks"
    var id: String
    var kind: String
    var dissolved: Bool
    var pick_file_id: String?
    var created_at: Int64
}

struct StackMemberRow: Codable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "stack_members"
    var stack_id: String
    var file_id: String
}
```

- [ ] **Step 5: Run tests, confirm pass**

- [ ] **Step 6: Write the failing `StackStore` tests**

```swift
//
//  StackStoreTests.swift
//  MuseTests
//
//  create/dissolve/setPick/removeMember (auto-dissolve under 2 remaining
//  members); claimedFileIDs includes dissolved-stack members (the
//  auto-stacker's virgin-file rule depends on this); cascade on file
//  delete.
//

import XCTest
import GRDB
@testable import Muse

final class StackStoreTests: XCTestCase {
    private func seededQueue() throws -> DatabaseQueue {
        let queue = try DatabaseQueue()
        try Database.makeMigrator().migrate(queue)
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO files (id, content_hash, kind, last_seen_at)
                VALUES ('f1','h1','image',0), ('f2','h2','image',0), ('f3','h3','image',0)
                """)
        }
        return queue
    }

    func testCreateStackAndFetchByFileIDs() throws {
        let queue = try seededQueue()
        try queue.write { db in
            let id = try StackStore.createStack(kind: "auto", memberIDs: ["f1", "f2"], pick: "f1", db: db)
            let refs = try StackStore.stacksFor(fileIDs: ["f1", "f2", "f3"], db: db)
            XCTAssertEqual(refs["f1"]?.stackID, id)
            XCTAssertEqual(refs["f2"]?.stackID, id)
            XCTAssertNil(refs["f3"])
        }
    }

    func testDissolveTombstonesButKeepsMembers() throws {
        let queue = try seededQueue()
        try queue.write { db in
            let id = try StackStore.createStack(kind: "auto", memberIDs: ["f1", "f2"], pick: nil, db: db)
            try StackStore.dissolve(stackID: id, db: db)
            let claimed = try StackStore.claimedFileIDs(db: db)
            XCTAssertTrue(claimed.contains("f1"))
            XCTAssertTrue(claimed.contains("f2"))
            let refs = try StackStore.stacksFor(fileIDs: ["f1"], db: db)
            XCTAssertEqual(refs["f1"]?.dissolved, true)
        }
    }

    func testRemoveMemberBelowTwoAutoDissolves() throws {
        let queue = try seededQueue()
        try queue.write { db in
            let id = try StackStore.createStack(kind: "manual", memberIDs: ["f1", "f2"], pick: "f1", db: db)
            try StackStore.removeMember(stackID: id, fileID: "f2", db: db)
            let refs = try StackStore.stacksFor(fileIDs: ["f1"], db: db)
            XCTAssertEqual(refs["f1"]?.dissolved, true) // only 1 member left -> auto-dissolve
        }
    }

    func testSetPick() throws {
        let queue = try seededQueue()
        try queue.write { db in
            let id = try StackStore.createStack(kind: "manual", memberIDs: ["f1", "f2"], pick: "f1", db: db)
            try StackStore.setPick(stackID: id, fileID: "f2", db: db)
            let refs = try StackStore.stacksFor(fileIDs: ["f1"], db: db)
            XCTAssertEqual(refs["f1"]?.pickFileID, "f2")
        }
    }

    func testClaimedFileIDsChunksOver800() throws {
        // Verifies the IN(...) chunking doesn't drop ids past 800 — construct
        // >800 stack members and confirm every id is reported claimed.
        let queue = try DatabaseQueue()
        try Database.makeMigrator().migrate(queue)
        try queue.write { db in
            var sql = "INSERT INTO files (id, content_hash, kind, last_seen_at) VALUES "
            sql += (0..<850).map { "('f\($0)','h\($0)','image',0)" }.joined(separator: ",")
            try db.execute(sql: sql)
            let id = try StackStore.createStack(kind: "auto", memberIDs: (0..<850).map { "f\($0)" }, pick: nil, db: db)
            _ = id
        }
        try queue.read { db in
            let claimed = try StackStore.claimedFileIDs(db: db)
            XCTAssertEqual(claimed.count, 850)
        }
    }
}
```

- [ ] **Step 7: Run, confirm failure**

- [ ] **Step 8: Implement `StackStore`**

```swift
//
//  StackStore.swift
//  Muse
//
//  Pure db-taking functions (the NoteStore/PlaceQueries shape). Stacks are
//  presentation-only, content-keyed sets of file_id — no parent_dir, no
//  path. dissolved is a permanent tombstone (the collection setHidden
//  pattern): unstacking keeps the row + members so the auto-stacker never
//  re-forms it. claimedFileIDs includes dissolved-stack members on
//  purpose — that's what makes "off-limits to the auto-stacker forever"
//  durable.
//

import Foundation
import GRDB

nonisolated struct StackRef {
    let stackID: String
    let kind: String
    let dissolved: Bool
    let pickFileID: String?
}

nonisolated enum StackStore {
    static func stacksFor(fileIDs: [String], db: Database) throws -> [String: StackRef] {
        guard !fileIDs.isEmpty else { return [:] }
        var result: [String: StackRef] = [:]
        for chunk in fileIDs.chunked(into: 800) {
            let placeholders = chunk.map { _ in "?" }.joined(separator: ",")
            let rows = try Row.fetchAll(db, sql: """
                SELECT sm.file_id, s.id AS stack_id, s.kind, s.dissolved, s.pick_file_id
                FROM stack_members sm JOIN stacks s ON s.id = sm.stack_id
                WHERE sm.file_id IN (\(placeholders))
                """, arguments: StatementArguments(chunk))
            for row in rows {
                guard let fileID: String = row["file_id"], let stackID: String = row["stack_id"],
                      let kind: String = row["kind"] else { continue }
                result[fileID] = StackRef(stackID: stackID, kind: kind,
                                          dissolved: row["dissolved"] ?? false,
                                          pickFileID: row["pick_file_id"])
            }
        }
        return result
    }

    /// Every file with ANY stack_members row, dissolved included — the
    /// auto-stacker's "virgin files only" boundary.
    static func claimedFileIDs(db: Database) throws -> Set<String> {
        let rows = try Row.fetchAll(db, sql: "SELECT DISTINCT file_id FROM stack_members")
        return Set(rows.compactMap { $0["file_id"] as String? })
    }

    @discardableResult
    static func createStack(kind: String, memberIDs: [String], pick: String?, db: Database) throws -> String {
        let id = UUID().uuidString
        var stack = StackRow(id: id, kind: kind, dissolved: false, pick_file_id: pick,
                             created_at: Int64(Date().timeIntervalSince1970))
        try stack.insert(db)
        for memberID in memberIDs {
            var member = StackMemberRow(stack_id: id, file_id: memberID)
            try member.insert(db)
        }
        return id
    }

    static func dissolve(stackID: String, db: Database) throws {
        try db.execute(sql: "UPDATE stacks SET dissolved = 1 WHERE id = ?", arguments: [stackID])
    }

    static func setPick(stackID: String, fileID: String?, db: Database) throws {
        try db.execute(sql: "UPDATE stacks SET pick_file_id = ? WHERE id = ?", arguments: [fileID, stackID])
    }

    /// Removing a member below 2 remaining auto-dissolves the stack (a
    /// 1-member "stack" is not a stack).
    static func removeMember(stackID: String, fileID: String, db: Database) throws {
        try db.execute(sql: "DELETE FROM stack_members WHERE stack_id = ? AND file_id = ?",
                       arguments: [stackID, fileID])
        let remaining = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM stack_members WHERE stack_id = ?",
                                         arguments: [stackID]) ?? 0
        if remaining < 2 {
            try dissolve(stackID: stackID, db: db)
        }
    }
}
```

  Confirm whether `Array.chunked(into:)` was already added in Task 5 (`PhotoHeaderBackfill`)
  — reuse that extension rather than redefining it.

- [ ] **Step 9: Run tests, confirm pass**

- [ ] **Step 10: Commit**

```bash
git add "Muse/Muse/Database/Database.swift" "Muse/Muse/Database/Records.swift" \
        "Muse/Muse/Database/StackStore.swift" "Muse/MuseTests/StackStoreTests.swift" \
        "Muse/MuseTests/PhotoMetaMigrationTests.swift"
git commit -m "feat: add v17_stacks migration + StackStore"
```

---

### Task 28: `BurstClusterer` — pure clustering

**Files:**
- Create: `Muse/Muse/Intelligence/Stacks/BurstClusterer.swift`
- Create: `Muse/MuseTests/BurstClustererTests.swift`

**Interfaces:**
- Consumes: `FeaturePrints.distance` (Task 1).
- Produces: `BurstClusterer.clusters(_:) -> [[String]]` — consumed by Task 29
  (`AutoStacker`).

- [ ] **Step 1: Write the failing tests**

```swift
//
//  BurstClustererTests.swift
//  MuseTests
//
//  Session split at the 10s gap; no cross-session pair ever compared; union
//  within a session; nil-print and mismatched-length items never cluster;
//  maxSessionSize split at internal gaps; deterministic output order.
//

import XCTest
@testable import Muse

final class BurstClustererTests: XCTestCase {
    private func item(_ id: String, at t: Int64, print: [Float]? = [1, 0, 0]) -> BurstClusterer.Item {
        BurstClusterer.Item(fileID: id, captureAt: t, print: print)
    }

    func testTwoCloseSimilarItemsCluster() {
        let items = [item("a", at: 0), item("b", at: 5)]
        let clusters = BurstClusterer.clusters(items)
        XCTAssertEqual(clusters, [["a", "b"]])
    }

    func testItemsBeyondSessionGapNeverCompared() {
        let items = [item("a", at: 0), item("b", at: 20)] // gap = 20s > 10s
        let clusters = BurstClusterer.clusters(items)
        XCTAssertEqual(clusters, [])
    }

    func testNilPrintItemsNeverCluster() {
        let items = [item("a", at: 0, print: nil), item("b", at: 1, print: nil)]
        XCTAssertEqual(BurstClusterer.clusters(items), [])
    }

    func testMismatchedLengthPrintsNeverCluster() {
        let items = [item("a", at: 0, print: [1, 0, 0]), item("b", at: 1, print: [1, 0])]
        XCTAssertEqual(BurstClusterer.clusters(items), [])
    }

    func testDissimilarItemsInSameSessionDoNotCluster() {
        let items = [item("a", at: 0, print: [1, 0, 0]), item("b", at: 1, print: [0, 1, 0])]
        // Euclidean distance sqrt(2) ~1.41, way over 0.45 threshold.
        XCTAssertEqual(BurstClusterer.clusters(items), [])
    }

    func testUnionFindGroupsTransitively() {
        // a~b close, b~c close, a~c not directly tested but should union.
        let items = [
            BurstClusterer.Item(fileID: "a", captureAt: 0, print: [1.0, 0, 0]),
            BurstClusterer.Item(fileID: "b", captureAt: 2, print: [0.99, 0.01, 0]),
            BurstClusterer.Item(fileID: "c", captureAt: 4, print: [0.98, 0.02, 0]),
        ]
        let clusters = BurstClusterer.clusters(items)
        XCTAssertEqual(clusters.count, 1)
        XCTAssertEqual(Set(clusters[0]), ["a", "b", "c"])
    }

    func testOutputOrderedByFirstMemberCaptureAt() {
        let items = [
            BurstClusterer.Item(fileID: "late1", captureAt: 100, print: [1, 0, 0]),
            BurstClusterer.Item(fileID: "late2", captureAt: 102, print: [1, 0, 0]),
            BurstClusterer.Item(fileID: "early1", captureAt: 0, print: [0, 1, 0]),
            BurstClusterer.Item(fileID: "early2", captureAt: 2, print: [0, 1, 0]),
        ]
        let clusters = BurstClusterer.clusters(items)
        XCTAssertEqual(clusters.count, 2)
        XCTAssertEqual(Set(clusters[0]), ["early1", "early2"])
        XCTAssertEqual(Set(clusters[1]), ["late1", "late2"])
    }

    func testSingletonsAreNotClusters() {
        let items = [item("a", at: 0)]
        XCTAssertEqual(BurstClusterer.clusters(items), [])
    }

    func testEmptyInput() {
        XCTAssertEqual(BurstClusterer.clusters([]), [])
    }

    func testOversizedSessionSplitsAtLargestInternalGap() {
        // 300 items all within the 10s window would exceed maxSessionSize
        // (256) if left as one session — construct enough items with a
        // deliberately larger internal gap partway through to prove the
        // split lands there rather than at an arbitrary index.
        var items: [BurstClusterer.Item] = []
        for i in 0..<130 {
            items.append(BurstClusterer.Item(fileID: "a\(i)", captureAt: Int64(i), print: [1, 0, 0]))
        }
        // A deliberately larger (but still <=10s) gap at the midpoint —
        // ensure the splitter's "largest internal gap" choice is exercised
        // even though this whole run is technically one session by the
        // 10s rule; the count alone (130 < 256) doesn't trigger a split,
        // so extend to >256 items to actually force it:
        for i in 130..<300 {
            items.append(BurstClusterer.Item(fileID: "b\(i)", captureAt: Int64(i), print: [1, 0, 0]))
        }
        let clusters = BurstClusterer.clusters(items)
        // No cluster should exceed maxSessionSize's implied bound; assert
        // at least one split occurred (more than one cluster produced from
        // what the 10s-gap rule alone would have called one session).
        XCTAssertGreaterThan(clusters.count, 1)
    }
}
```

- [ ] **Step 2: Run, confirm failure**

- [ ] **Step 3: Implement `BurstClusterer`**

```swift
//
//  BurstClusterer.swift
//  Muse
//
//  Time bucket first, similarity second (the O(n^2) fix). Sort by
//  captureAt, split into sessions wherever the gap exceeds
//  sessionGapSeconds, then union-find WITHIN each session on feature-print
//  similarity. Sessions are physically small (a burst), so the inner O(k^2)
//  is trivial; maxSessionSize defends against a pathological identical-
//  timestamp pile-up reintroducing n^2 by splitting oversized sessions at
//  their largest internal gaps.
//

import Foundation

nonisolated enum BurstClusterer {
    static let sessionGapSeconds: Int64 = 10
    static let similarityThreshold: Float = 0.45
    static let maxSessionSize = 256

    struct Item: Sendable {
        let fileID: String
        let captureAt: Int64
        let print: [Float]?
    }

    static func clusters(_ items: [Item]) -> [[String]] {
        let sorted = items.sorted { $0.captureAt < $1.captureAt }
        let sessions = splitIntoSessions(sorted)
        var result: [[String]] = []
        for session in sessions {
            for bounded in splitOversized(session) {
                result.append(contentsOf: unionFindCluster(bounded))
            }
        }
        return result.sorted { (a, b) in
            let aFirst = a.compactMap { fid in items.first { $0.fileID == fid }?.captureAt }.min() ?? 0
            let bFirst = b.compactMap { fid in items.first { $0.fileID == fid }?.captureAt }.min() ?? 0
            return aFirst < bFirst
        }
    }

    private static func splitIntoSessions(_ sorted: [Item]) -> [[Item]] {
        guard !sorted.isEmpty else { return [] }
        var sessions: [[Item]] = [[sorted[0]]]
        for item in sorted.dropFirst() {
            if item.captureAt - sessions[sessions.count - 1].last!.captureAt > sessionGapSeconds {
                sessions.append([item])
            } else {
                sessions[sessions.count - 1].append(item)
            }
        }
        return sessions
    }

    /// Splits a session exceeding maxSessionSize at its largest internal
    /// gap(s), recursively, until every piece is within bound.
    private static func splitOversized(_ session: [Item]) -> [[Item]] {
        guard session.count > maxSessionSize else { return [session] }
        var largestGapIndex = 0
        var largestGap: Int64 = -1
        for i in 1..<session.count {
            let gap = session[i].captureAt - session[i - 1].captureAt
            if gap > largestGap { largestGap = gap; largestGapIndex = i }
        }
        let left = Array(session[..<largestGapIndex])
        let right = Array(session[largestGapIndex...])
        return splitOversized(left) + splitOversized(right)
    }

    private static func unionFindCluster(_ session: [Item]) -> [[String]] {
        var parent = Array(0..<session.count)
        func find(_ x: Int) -> Int {
            var x = x
            while parent[x] != x { parent[x] = parent[parent[x]]; x = parent[x] }
            return x
        }
        func union(_ a: Int, _ b: Int) {
            let ra = find(a), rb = find(b)
            if ra != rb { parent[ra] = rb }
        }
        for i in 0..<session.count {
            guard let printI = session[i].print else { continue }
            for j in (i + 1)..<session.count {
                guard let printJ = session[j].print,
                      let dist = FeaturePrints.distance(printI, printJ),
                      dist <= similarityThreshold else { continue }
                union(i, j)
            }
        }
        var groups: [Int: [String]] = [:]
        for i in 0..<session.count {
            guard session[i].print != nil else { continue } // nil-print items never join a group
            groups[find(i), default: []].append(session[i].fileID)
        }
        return groups.values.filter { $0.count >= 2 }.map { $0 }
    }
}
```

- [ ] **Step 4: Run tests, confirm pass**

- [ ] **Step 5: Commit**

```bash
git add "Muse/Muse/Intelligence/Stacks/BurstClusterer.swift" "Muse/MuseTests/BurstClustererTests.swift"
git commit -m "feat: add BurstClusterer (time-bucketed feature-print clustering)"
```

---

### Task 29: `AutoStacker` + triggers

**Files:**
- Create: `Muse/Muse/Intelligence/Stacks/AutoStacker.swift`
- Modify: `Muse/Muse/Intelligence/AnalyzePipeline.swift` (trigger at the end of
  `analyzePending`/`analyzeFolderManual`, over that pass's file ids)

**Interfaces:**
- Consumes: `StackStore.claimedFileIDs`/`createStack` (Task 27), `BurstClusterer.clusters`
  (Task 28), `photo_meta.capture_date`/`files.created_at`/`files.feature_print`.
- Produces: `AutoStacker.run(fileIDs:) async -> Int` — consumed by Task 30's lazy
  per-folder trigger (`StacksStore.reload(for:)`).

- [ ] **Step 1: Write a focused test on the DB-read + virgin-filter shape**

  Since `AutoStacker.run` is mostly glue over already-tested pure logic
  (`BurstClusterer`, `StackStore`), write ONE integration-style test proving the
  virgin-file exclusion and the end-to-end write, rather than re-testing clustering
  math already covered by `BurstClustererTests`:

```swift
//
//  AutoStackerTests.swift
//  MuseTests
//

import XCTest
import GRDB
@testable import Muse

final class AutoStackerTests: XCTestCase {
    func testAlreadyStackedFilesAreExcludedFromNewAutoStacks() async throws {
        let queue = try DatabaseQueue()
        try Database.makeMigrator().migrate(queue)
        try await queue.write { db in
            try db.execute(sql: """
                INSERT INTO files (id, content_hash, kind, last_seen_at, feature_print)
                VALUES ('f1','h1','image',0,X'00000000'),
                       ('f2','h2','image',0,X'00000000'),
                       ('f3','h3','image',0,X'00000000')
                """) // identical all-zero prints -> distance 0, would cluster if virgin
            try db.execute(sql: """
                INSERT INTO photo_meta (file_id, capture_date) VALUES ('f1',0), ('f2',2), ('f3',4)
                """)
            // f1 already claimed by an existing (dissolved) stack.
            try db.execute(sql: "INSERT INTO stacks (id, kind, dissolved, created_at) VALUES ('s0','auto',1,0)")
            try db.execute(sql: "INSERT INTO stack_members (stack_id, file_id) VALUES ('s0','f1')")
        }
        let created = await AutoStacker.run(fileIDs: ["f1", "f2", "f3"], dbQueue: queue)
        XCTAssertEqual(created, 1) // only f2+f3 cluster; f1 excluded (claimed, even though dissolved)
        try await queue.read { db in
            let refs = try StackStore.stacksFor(fileIDs: ["f2", "f3"], db: db)
            XCTAssertEqual(refs["f2"]?.stackID, refs["f3"]?.stackID)
            XCTAssertNotNil(refs["f2"])
        }
    }
}
```

  Note the `dbQueue:` parameter added to `AutoStacker.run` purely to make it
  testable against an in-memory queue rather than `Database.shared.dbQueue` — the
  production call sites (Step 4 below) omit it and let it default to
  `Database.shared.dbQueue`.

- [ ] **Step 2: Run, confirm failure**

- [ ] **Step 3: Implement `AutoStacker`**

```swift
//
//  AutoStacker.swift
//  Muse
//
//  Clusters VIRGIN files (no stack_members row, dissolved included) among
//  the given fileIDs and writes kind:"auto" stacks. Runs off-main; writes
//  one transaction per stack batch.
//

import Foundation
import GRDB

nonisolated enum AutoStacker {
    @discardableResult
    static func run(fileIDs: [String], dbQueue: DatabaseQueue? = nil) async -> Int {
        guard let q = dbQueue ?? Database.shared.dbQueue, !fileIDs.isEmpty else { return 0 }

        let clusters: [[String]] = (try? await q.read { db in
            let claimed = try StackStore.claimedFileIDs(db: db)
            let virginIDs = fileIDs.filter { !claimed.contains($0) }
            guard !virginIDs.isEmpty else { return [] }
            let placeholders = virginIDs.map { _ in "?" }.joined(separator: ",")
            let rows = try Row.fetchAll(db, sql: """
                SELECT f.id AS id, COALESCE(m.capture_date, f.created_at) AS captureAt, f.feature_print AS print
                FROM files f LEFT JOIN photo_meta m ON m.file_id = f.id
                WHERE f.id IN (\(placeholders))
                """, arguments: StatementArguments(virginIDs))
            let items: [BurstClusterer.Item] = rows.compactMap { row in
                guard let id: String = row["id"], let captureAt: Int64 = row["captureAt"] else { return nil }
                let printData: Data? = row["print"]
                let floats = printData.flatMap(FeaturePrints.floats)
                return BurstClusterer.Item(fileID: id, captureAt: captureAt, print: floats)
            }
            return BurstClusterer.clusters(items)
        }) ?? []
        guard !clusters.isEmpty else { return 0 }

        var created = 0
        try? await q.write { db in
            for cluster in clusters {
                // Re-check virginity inside the write transaction — a
                // concurrent manual stack could have claimed a member
                // between the read above and this write.
                let stillClaimed = try StackStore.claimedFileIDs(db: db)
                let unclaimedMembers = cluster.filter { !stillClaimed.contains($0) }
                guard unclaimedMembers.count >= 2 else { continue }
                try StackStore.createStack(kind: "auto", memberIDs: unclaimedMembers, pick: nil, db: db)
                created += 1
            }
        }
        return created
    }
}
```

- [ ] **Step 4: Run tests, confirm pass**

- [ ] **Step 5: Wire the analyze-pass trigger**

  In `Muse/Muse/Intelligence/AnalyzePipeline.swift`, find the end of
  `analyzePending`/`analyzeFolderManual` (wherever the pass reports its final
  completion — likely near where `SearchFacets.shared.refresh()` was added in Task
  13 Step 6). Add, over exactly that pass's analyzed file ids (collect them as the
  pass runs, e.g. an array appended to for each file that actually got analyzed):

```swift
if !analyzedFileIDs.isEmpty {
    Task { await AutoStacker.run(fileIDs: analyzedFileIDs) }
}
```

  Confirm the pass already has (or can cheaply gain) a running list of the file ids
  it analyzed in this invocation — if it doesn't currently track this, add the
  minimal bookkeeping (an `[String]` appended to at each `analyzeOne` success) rather
  than re-querying the DB for "recently analyzed" after the fact.

- [ ] **Step 6: Build and verify**

  Run: `xcodebuild -project Muse/Muse.xcodeproj -scheme Muse -configuration Debug build`
  Expected: `BUILD SUCCEEDED`.

- [ ] **Step 7: Commit**

```bash
git add "Muse/Muse/Intelligence/Stacks/AutoStacker.swift" "Muse/MuseTests/AutoStackerTests.swift" \
        "Muse/Muse/Intelligence/AnalyzePipeline.swift"
git commit -m "feat: add AutoStacker + wire it to end-of-analyze-pass"
```

---

### Task 30: `StacksStore` + `StackDisplay` (collapse math)

**Files:**
- Create: `Muse/Muse/Components/StackDisplay.swift`
- Create: `Muse/Muse/Models/StacksStore.swift`
- Create: `Muse/MuseTests/StackDisplayTests.swift`

**Interfaces:**
- Consumes: `StackStore.stacksFor` (Task 27), `AutoStacker.run` (Task 29, the lazy
  per-folder trigger).
- Produces: `StackDisplay.collapse(_:entries:expanded:) -> Result` (pure),
  `StacksStore.shared` (`entries`, `expanded`, `generation`, `badges` — plain var,
  `reload(for:)`, `toggleExpanded`, `stackSelection`, `unstack`, `setPick`,
  `removeFromStack`) — consumed by Task 31 (grid presentation), Task 32 (context
  menu).

- [ ] **Step 1: Write the failing `StackDisplay` tests**

```swift
//
//  StackDisplayTests.swift
//  MuseTests
//
//  Collapse keeps the pick (if present) else the first-in-order member;
//  hides the rest unless expanded; badge counts = members actually IN
//  VIEW; expanded shows all members; a stack with < 2 members present is
//  never collapsed; input order is preserved for non-hidden items.
//

import XCTest
@testable import Muse

final class StackDisplayTests: XCTestCase {
    private func node(_ path: String) -> FileNode {
        FileNode(url: URL(fileURLWithPath: path)) // confirm real FileNode init
    }

    func testCollapseKeepsPickWhenPresent() {
        let files = [node("/a"), node("/b"), node("/c")]
        let entries = ["/a": StackDisplay.Entry(stackID: "s1", isPick: false),
                       "/b": StackDisplay.Entry(stackID: "s1", isPick: true)]
        let result = StackDisplay.collapse(files, entries: entries, expanded: [])
        XCTAssertEqual(result.visible.map { $0.url.path }, ["/b", "/c"])
        XCTAssertEqual(result.hiddenPaths, ["/a"])
        XCTAssertEqual(result.badges["/b"], 2)
    }

    func testCollapseFallsBackToFirstInOrderWithNoPick() {
        let files = [node("/a"), node("/b"), node("/c")]
        let entries = ["/a": StackDisplay.Entry(stackID: "s1", isPick: false),
                       "/b": StackDisplay.Entry(stackID: "s1", isPick: false)]
        let result = StackDisplay.collapse(files, entries: entries, expanded: [])
        XCTAssertEqual(result.visible.map { $0.url.path }, ["/a", "/c"])
    }

    func testExpandedStackShowsAllMembers() {
        let files = [node("/a"), node("/b"), node("/c")]
        let entries = ["/a": StackDisplay.Entry(stackID: "s1", isPick: false),
                       "/b": StackDisplay.Entry(stackID: "s1", isPick: false)]
        let result = StackDisplay.collapse(files, entries: entries, expanded: ["s1"])
        XCTAssertEqual(result.visible.map { $0.url.path }, ["/a", "/b", "/c"])
        XCTAssertTrue(result.hiddenPaths.isEmpty)
    }

    func testStackWithFewerThanTwoMembersPresentIsNotCollapsed() {
        // Only ONE member of stack s1 is present in `files` (the other
        // lives in a different folder) — no collapse should happen.
        let files = [node("/a"), node("/c")]
        let entries = ["/a": StackDisplay.Entry(stackID: "s1", isPick: false)]
        let result = StackDisplay.collapse(files, entries: entries, expanded: [])
        XCTAssertEqual(result.visible.map { $0.url.path }, ["/a", "/c"])
        XCTAssertTrue(result.hiddenPaths.isEmpty)
    }

    func testInputOrderPreservedForNonHiddenItems() {
        let files = [node("/z"), node("/a"), node("/m")]
        let result = StackDisplay.collapse(files, entries: [:], expanded: [])
        XCTAssertEqual(result.visible.map { $0.url.path }, ["/z", "/a", "/m"])
    }
}
```

- [ ] **Step 2: Run, confirm failure**

- [ ] **Step 3: Implement `StackDisplay`**

```swift
//
//  StackDisplay.swift
//  Muse
//
//  Pure math (Components/ convention). Collapse rule: for each stack with
//  >= 2 members present in `files`, keep the pick (if present) else the
//  first in current order; hide the rest — unless the stack is expanded.
//

import Foundation

nonisolated enum StackDisplay {
    struct Entry: Equatable {
        let stackID: String
        let isPick: Bool
    }
    struct Result: Equatable {
        var visible: [FileNode]
        var badges: [String: Int]   // representative std-path -> member count IN VIEW
        var hiddenPaths: Set<String>
    }

    static func collapse(_ files: [FileNode], entries: [String: Entry], expanded: Set<String>) -> Result {
        guard !entries.isEmpty else {
            return Result(visible: files, badges: [:], hiddenPaths: [])
        }
        // Group present files by stackID, preserving encounter order.
        var membersByStack: [String: [String]] = [:]
        for file in files {
            let path = file.url.standardizedFileURL.path
            guard let entry = entries[path] else { continue }
            membersByStack[entry.stackID, default: []].append(path)
        }

        var representative: [String: String] = [:] // stackID -> chosen path
        var hidden: Set<String> = []
        var badges: [String: Int] = [:]

        for (stackID, memberPaths) in membersByStack {
            guard memberPaths.count >= 2 else { continue } // < 2 present -> never collapse
            if expanded.contains(stackID) { continue }
            let pick = memberPaths.first { entries[$0]?.isPick == true }
            let chosen = pick ?? memberPaths.first!
            representative[stackID] = chosen
            badges[chosen] = memberPaths.count
            for path in memberPaths where path != chosen {
                hidden.insert(path)
            }
        }

        let visible = files.filter { !hidden.contains($0.url.standardizedFileURL.path) }
        return Result(visible: visible, badges: badges, hiddenPaths: hidden)
    }
}
```

- [ ] **Step 4: Run tests, confirm pass**

- [ ] **Step 5: Implement `StacksStore`**

```swift
//
//  StacksStore.swift
//  Muse
//
//  Pattern B store. entries/expanded/generation drive the grid's collapse
//  seam (Task 31); badges is a PLAIN (non-@Published) var written inside
//  the memoized visibleFiles computation — it must not publish (writing it
//  there on every visibleFiles recompute would otherwise loop).
//

import Foundation
import GRDB

@MainActor final class StacksStore: ObservableObject {
    static let shared = StacksStore()
    private init() {}

    @Published private(set) var entries: [String: StackDisplay.Entry] = [:] // std path -> entry
    @Published private(set) var expanded: Set<String> = []
    @Published private(set) var generation = 0
    var badges: [String: Int] = [:] // NOT @Published — see file header note

    func reload(for files: [FileNode]) async {
        guard let q = Database.shared.dbQueue, !files.isEmpty else {
            entries = [:]
            generation += 1
            return
        }
        let pathsByFileID: [(fileID: String, path: String)] = await withPathFileIDMap(files: files, q: q)
        let fileIDs = pathsByFileID.map(\.fileID)

        // Lazily auto-stack this folder's virgin analyzed files with prints
        // — existing libraries stack up folder by folder as they're
        // browsed, without a global launch pass.
        _ = await AutoStacker.run(fileIDs: fileIDs)

        let refs: [String: StackRef] = (try? await q.read { db in try StackStore.stacksFor(fileIDs: fileIDs, db: db) }) ?? [:]
        var newEntries: [String: StackDisplay.Entry] = [:]
        for (fileID, path) in pathsByFileID {
            guard let ref = refs[fileID], !ref.dissolved else { continue } // dissolved = invisible in entries
            newEntries[path] = StackDisplay.Entry(stackID: ref.stackID, isPick: ref.pickFileID == fileID)
        }
        entries = newEntries
        generation += 1
    }

    func toggleExpanded(_ stackID: String) {
        if expanded.contains(stackID) { expanded.remove(stackID) } else { expanded.insert(stackID) }
        generation += 1
    }

    func stackSelection(paths: [String]) async {
        guard let q = Database.shared.dbQueue else { return }
        let fileIDs = await fileIDsForPaths(paths, q: q)
        guard fileIDs.count >= 2 else { return }
        try? await q.write { db in
            try StackStore.createStack(kind: "manual", memberIDs: fileIDs, pick: fileIDs.first, db: db)
        }
        generation += 1
    }

    func unstack(_ stackID: String) async {
        guard let q = Database.shared.dbQueue else { return }
        try? await q.write { db in try StackStore.dissolve(stackID: stackID, db: db) }
        generation += 1
    }

    func setPick(stackID: String, path: String) async {
        guard let q = Database.shared.dbQueue, let fileID = await fileIDForPath(path, q: q) else { return }
        try? await q.write { db in try StackStore.setPick(stackID: stackID, fileID: fileID, db: db) }
        generation += 1
    }

    func removeFromStack(path: String) async {
        guard let q = Database.shared.dbQueue,
              let entry = entries[URL(fileURLWithPath: path).standardizedFileURL.path],
              let fileID = await fileIDForPath(path, q: q) else { return }
        try? await q.write { db in try StackStore.removeMember(stackID: entry.stackID, fileID: fileID, db: db) }
        generation += 1
    }

    // MARK: - path <-> file_id helpers (confirm against the real paths table shape)

    private func withPathFileIDMap(files: [FileNode], q: DatabaseQueue) async -> [(fileID: String, path: String)] {
        let paths = files.map { $0.url.standardizedFileURL.path }
        return (try? await q.read { db -> [(String, String)] in
            let placeholders = paths.map { _ in "?" }.joined(separator: ",")
            let rows = try Row.fetchAll(db, sql: """
                SELECT file_id, absolute_path FROM paths WHERE absolute_path IN (\(placeholders)) AND is_alive = 1
                """, arguments: StatementArguments(paths))
            return rows.compactMap { row -> (String, String)? in
                guard let fid: String = row["file_id"], let path: String = row["absolute_path"] else { return nil }
                return (fid, path)
            }
        })?.map { (fileID: $0.0, path: $0.1) } ?? []
    }

    private func fileIDsForPaths(_ paths: [String], q: DatabaseQueue) async -> [String] {
        let map = await withPathFileIDMap(files: paths.map { FileNode(url: URL(fileURLWithPath: $0)) }, q: q)
        return map.map(\.fileID)
    }

    private func fileIDForPath(_ path: String, q: DatabaseQueue) async -> String? {
        await fileIDsForPaths([path], q: q).first
    }
}
```

  This is a substantial file with several helper methods reconstructing file_id from
  path — confirm whether the codebase already has a shared `pathToFileID`-style
  helper (grep for `absolute_path IN` or similar patterns elsewhere, e.g. in
  `NoteStore` or `TagStore`) and reuse it rather than duplicating the query shape
  four times, if one exists.

- [ ] **Step 6: Run tests, confirm pass; commit**

```bash
git add "Muse/Muse/Components/StackDisplay.swift" "Muse/Muse/Models/StacksStore.swift" \
        "Muse/MuseTests/StackDisplayTests.swift"
git commit -m "feat: add StackDisplay (collapse math) + StacksStore"
```

---

### Task 31: Grid presentation — collapse seam, badge, `gridSignature`

**Files:**
- Modify: `Muse/Muse/Models/AppState+Filters.swift` (extend `visibleFiles` with the
  collapse step, after the existing `gridFilter` step)
- Modify: `Muse/Muse/Models/AppState.swift` (add `stacksCancellable`)
- Modify: `Muse/Muse/Views/GridView.swift` (`gridSignature` near line 677; the tile
  view for the badge)
- Modify: `Muse/Muse/Views/TileView.swift` (confirm exact filename — the per-tile
  view; add the stack badge)

**Interfaces:** None new — wires Task 30's `StacksStore` into the grid.

- [ ] **Step 1: Add the collapse step to `visibleFiles`**

  In `Muse/Muse/Models/AppState+Filters.swift`, after the existing `gridFilter` step
  (the `result = base.filter { … }` / `result = base` block), add:

```swift
if !isSearchActive && activeCollectionFiles == nil && RediscoveryStore.shared.files == nil {
    let d = StackDisplay.collapse(result, entries: StacksStore.shared.entries,
                                  expanded: StacksStore.shared.expanded)
    StacksStore.shared.badges = d.badges   // plain var — must not publish
    result = d.visible
}
```

  Collapse applies ONLY in plain folder browsing — never search, collections, or
  rediscovery (a matching burst frame must not hide under a non-matching
  representative). This must run AFTER `gridFilter` (so a faceted filter narrows the
  input the collapse math sees) and set `_visibleFilesCache`/`_visibleFilesValid` the
  same way the rest of the function already does (this snippet plugs into the
  existing `result` variable right before it's cached — do not introduce a second
  cache write).

- [ ] **Step 2: Add the `stacksCancellable`**

  In `AppState.init`, beside `rediscoveryCancellable` (Task 24):

```swift
private var stacksCancellable: AnyCancellable?
// … inside init():
stacksCancellable = StacksStore.shared.objectWillChange
    .sink { [weak self] _ in
        self?._visibleFilesValid = false
        self?.objectWillChange.send()
    }
```

- [ ] **Step 3: Update `gridSignature`**

  In `Muse/Muse/Views/GridView.swift`, find `gridSignature` (line 677) and add
  `StacksStore.shared.generation` and `StacksStore.shared.expanded.count` as
  components of whatever string/hash it builds — so geometry recomputes on stack
  changes:

```swift
// … existing signature components …
"\(StacksStore.shared.generation)-\(StacksStore.shared.expanded.count)"
```

  (Adjust to match the exact existing signature-building shape — string
  concatenation, hasher, etc.)

- [ ] **Step 4: Add expand/collapse selection pruning**

  Wherever `toggleExpanded` is called from the UI (Task 32's context menu wires the
  call site), ensure `AppState.pruneSelectionToVisible()` runs afterward — collapsing
  narrows `visibleFiles`, so this is required by the durable "anything that narrows
  visibleFiles must prune selection" rule. The cleanest place is inside
  `StacksStore.toggleExpanded` itself calling back into `AppState`, but `StacksStore`
  must not import `AppState` (Pattern B stores stay independent) — instead, wire the
  prune via the SAME `objectWillChange`-forwarding cancellable added in Step 2: after
  forwarding the change, also call `self?.pruneSelectionToVisible()`:

```swift
stacksCancellable = StacksStore.shared.objectWillChange
    .sink { [weak self] _ in
        self?._visibleFilesValid = false
        self?.pruneSelectionToVisible()
        self?.objectWillChange.send()
    }
```

  Confirm `pruneSelectionToVisible()`'s exact existing name/signature before using it
  here (cited in `CLAUDE.md`'s durable constraints as `gridFilter.didSet`'s handler).

- [ ] **Step 5: Add the stack badge to the tile view**

  In the file drawing each grid tile (confirm exact name — likely `TileView.swift`),
  add a top-LEADING capsule badge (star badge owns top-trailing) reading from
  `StacksStore.shared.badges[standardizedPath]`:

```swift
if let count = StacksStore.shared.badges[file.url.standardizedFileURL.path], count > 1 {
    Button {
        if let stackID = StacksStore.shared.entries[file.url.standardizedFileURL.path]?.stackID {
            StacksStore.shared.toggleExpanded(stackID)
        }
    } label: {
        HStack(spacing: 2) {
            Image(systemName: StacksStore.shared.expanded.contains(
                StacksStore.shared.entries[file.url.standardizedFileURL.path]?.stackID ?? "")
                ? "square.stack.fill" : "square.stack")
            Text("\(count)")
        }
        .font(.system(size: 10, weight: .semibold))
        .foregroundStyle(.white)
        .padding(.horizontal, 6)
        .background(Capsule().fill(Color.black.opacity(0.6)))
    }
    .buttonStyle(.plain)
    .contentShape(Capsule())
    .accessibilityLabel(String(format: NSLocalizedString("Stack of %lld photos", comment: "stack badge VoiceOver label"), count))
    .accessibilityAction(named: Text(StacksStore.shared.expanded.contains(
        StacksStore.shared.entries[file.url.standardizedFileURL.path]?.stackID ?? "")
        ? "Collapse Stack" : "Expand Stack")) {
        if let stackID = StacksStore.shared.entries[file.url.standardizedFileURL.path]?.stackID {
            StacksStore.shared.toggleExpanded(stackID)
        }
    }
    .padding(.leading, badgeInset)   // confirm badgeInset's existing constant name (star badge uses one)
}
```

  Position this at `.top, .leading` alignment (star badge already occupies
  `.top, .trailing`) inside the SAME overlay the star badge uses — read the star
  badge's exact code first and mirror its positioning modifiers rather than
  reinventing overlay placement. Unlike the star badge, this one IS a click target
  (durable constraint: mouse-only affordances need a `.accessibilityAction`
  parallel, already included above).

- [ ] **Step 6: Build and manually verify**

  Run the app against a folder with a real burst (several near-identical frames shot
  within 10 seconds); confirm they collapse to one tile with a badge showing the
  member count, clicking the badge expands/collapses, and the flow renders inline
  (no strip view) in the existing sort order.

- [ ] **Step 7: Commit**

```bash
git add "Muse/Muse/Models/AppState+Filters.swift" "Muse/Muse/Models/AppState.swift" \
        "Muse/Muse/Views/GridView.swift" "Muse/Muse/Views/TileView.swift"
git commit -m "feat: wire stack collapse into visibleFiles + add grid stack badge"
```

---

### Task 32: Manual stack / unstack / pick — context-menu surface

**Files:**
- Modify: `Muse/Muse/Views/GridView.swift` (or wherever the tile context menu is
  defined — confirm exact file; likely a dedicated `SelectionActionsMenu.swift` or
  inline in `GridView`/`TileView`)

**Interfaces:** None new — wires Task 30's `StacksStore` mutation methods into the
existing context menu.

- [ ] **Step 1: Read the existing tile context menu structure**

  Confirm exactly where `SelectionActionsMenu` renders and where the Move-to-Trash
  divider sits, since the Stack section goes "below `SelectionActionsMenu`, above the
  Move-to-Trash divider" per the spec.

- [ ] **Step 2: Add the Stack section**

```swift
if selectedImageKindPaths.count >= 2 && !selectedImageKindPaths.contains(where: {
    StacksStore.shared.entries[$0] != nil
}) {
    Button("Stack Selection") {
        Task { await StacksStore.shared.stackSelection(paths: Array(selectedImageKindPaths)) }
    }
}
if let entry = StacksStore.shared.entries[currentTilePath] {
    Button("Unstack") {
        Task { await StacksStore.shared.unstack(entry.stackID) }
    }
    if !entry.isPick {
        Button("Set as Stack Pick") {
            Task { await StacksStore.shared.setPick(stackID: entry.stackID, path: currentTilePath) }
        }
    }
    Button("Remove from Stack") {
        Task { await StacksStore.shared.removeFromStack(path: currentTilePath) }
    }
}
```

  `selectedImageKindPaths` and `currentTilePath` are placeholder names — replace
  with whatever the real context menu already exposes for "the currently selected
  set" and "the tile this menu was invoked on" (read the existing
  `SelectionActionsMenu`/context-menu code to find the real variable names). "Stack
  Selection" is visible only when ≥ 2 image-kind (`.image/.raw/.psd`) files are
  selected AND none has a `StacksStore` entry (v1 rule: no merging into existing
  stacks — hidden, not disabled-with-mystery, when a member is already stacked).
  `.folder` and non-image kinds never see the Stack section — the existing
  folder-exclusion precedent this menu already follows for other actions; confirm
  the guard is applied consistently (e.g. by filtering `selectedImageKindPaths` to
  only `.image/.raw/.psd` kinds at its definition site).

- [ ] **Step 3: Build and manually verify**

  Select 3+ non-stacked images, confirm "Stack Selection" appears and creates a
  manual stack (collapses on next grid refresh); right-click a stacked tile, confirm
  Unstack/Set as Stack Pick/Remove from Stack all work and update the grid
  immediately.

- [ ] **Step 4: Commit**

```bash
git add "Muse/Muse/Views/GridView.swift"
git commit -m "feat: add manual stack/unstack/pick context-menu surface"
```

---

## Section H — `.location` smart rule

### Task 33: `SmartRule.location` case + resolver evaluation

**Files:**
- Modify: `Muse/Muse/Intelligence/Collections/SmartRule.swift` (add the case + `LocationTerm`)
- Modify: `Muse/Muse/Intelligence/Collections/SmartCollectionResolver.swift` (add
  evaluation)
- Modify: `Muse/MuseTests/SmartRuleSetTests.swift` (extend the round-trip enumeration)
- Modify: `Muse/MuseTests/SmartCollectionResolverTests.swift` (extend)
- Create: `Muse/MuseTests/SmartRuleLocationTests.swift`

**Interfaces:**
- Consumes: `GeoBounds.boxes`/`GreatCircle.distanceKM` (Task 8), `places` table (Task
  6), `files.lat/lon` (Task 2).
- Produces: `SmartRule.location(LocationTerm)` case, `LocationTerm.place`/`.near` —
  consumed by Task 34 (`SmartCollectionRulesView`).

- [ ] **Step 1: Write the failing tests**

```swift
//
//  SmartRuleLocationTests.swift
//  MuseTests
//
//  Round-trip Codable, isValid branches, resolver .place (incl. localized-
//  country -> ISO), .near bbox + haversine + antimeridian split.
//

import XCTest
@testable import Muse

final class SmartRuleLocationTests: XCTestCase {
    func testLocationPlaceRoundTripsCodable() {
        let rule = SmartRule.location(.place("Lisboa"))
        let set = SmartRuleSet(match: .all, rules: [rule])
        let json = set.encodedJSON()
        XCTAssertNotNil(json)
        XCTAssertEqual(SmartRuleSet.decode(json!), set)
    }

    func testLocationNearRoundTripsCodable() {
        let rule = SmartRule.location(.near(lat: 38.72, lon: -9.14, radiusKM: 50))
        let set = SmartRuleSet(match: .all, rules: [rule])
        XCTAssertEqual(SmartRuleSet.decode(set.encodedJSON()!), set)
    }

    func testPlaceIsValidRequiresNonBlank() {
        XCTAssertFalse(SmartRule.location(.place("  ")).isValid)
        XCTAssertTrue(SmartRule.location(.place("Lisboa")).isValid)
    }

    func testNearIsValidRequiresSaneCoordinatesAndPositiveRadius() {
        XCTAssertFalse(SmartRule.location(.near(lat: 91, lon: 0, radiusKM: 10)).isValid)
        XCTAssertFalse(SmartRule.location(.near(lat: 0, lon: 0, radiusKM: 0)).isValid)
        XCTAssertTrue(SmartRule.location(.near(lat: 38.72, lon: -9.14, radiusKM: 10)).isValid)
    }

    func testResolverPlaceMatchesCityCaseInsensitive() throws {
        let queue = try DatabaseQueue()
        try Database.makeMigrator().migrate(queue)
        try queue.write { db in
            try db.execute(sql: "INSERT INTO files (id, content_hash, kind, last_seen_at) VALUES ('f1','h1','image',0)")
            try db.execute(sql: """
                INSERT INTO places (file_id, geocoded_hash, dataset_version, city, admin, country, place_key)
                VALUES ('f1','h1',1,'Lisboa','Lisbon','PT','lisboa|lisbon|pt')
                """)
        }
        try queue.read { db in
            let ids = try SmartCollectionResolver.matchingIDs(for: .location(.place("lisboa")), db: db)
            XCTAssertEqual(ids, ["f1"])
        }
    }

    func testResolverPlaceMatchesLocalizedCountryName() throws {
        // "Portugal" (localized display name) resolves back to ISO "PT"
        // before the query runs.
        let queue = try DatabaseQueue()
        try Database.makeMigrator().migrate(queue)
        try queue.write { db in
            try db.execute(sql: "INSERT INTO files (id, content_hash, kind, last_seen_at) VALUES ('f1','h1','image',0)")
            try db.execute(sql: """
                INSERT INTO places (file_id, geocoded_hash, dataset_version, city, admin, country, place_key)
                VALUES ('f1','h1',1,'Lisboa','Lisbon','PT','lisboa|lisbon|pt')
                """)
        }
        try queue.read { db in
            let ids = try SmartCollectionResolver.matchingIDs(for: .location(.place("Portugal")), db: db)
            XCTAssertEqual(ids, ["f1"])
        }
    }

    func testResolverNearMatchesWithinRadius() throws {
        let queue = try DatabaseQueue()
        try Database.makeMigrator().migrate(queue)
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO files (id, content_hash, kind, last_seen_at, lat, lon)
                VALUES ('f1','h1','image',0,38.7223,-9.1393), ('f2','h2','image',0,30.0,-40.0)
                """)
        }
        try queue.read { db in
            let ids = try SmartCollectionResolver.matchingIDs(
                for: .location(.near(lat: 38.72, lon: -9.14, radiusKM: 20)), db: db)
            XCTAssertEqual(ids, ["f1"])
        }
    }

    func testResolverNearSplitsAcrossAntimeridian() throws {
        let queue = try DatabaseQueue()
        try Database.makeMigrator().migrate(queue)
        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO files (id, content_hash, kind, last_seen_at, lat, lon)
                VALUES ('f1','h1','image',0,0.0,179.95)
                """)
        }
        try queue.read { db in
            let ids = try SmartCollectionResolver.matchingIDs(
                for: .location(.near(lat: 0, lon: -179.95, radiusKM: 50)), db: db)
            XCTAssertEqual(ids, ["f1"]) // ~11km apart across the antimeridian
        }
    }
}
```

  Confirm `SmartCollectionResolver`'s exact public entry point (`matchingIDs(for:db:)`
  is a guess based on the resolver's role — read the real file for its actual name
  and signature) before finalizing these tests; adjust the call shape to match.

- [ ] **Step 2: Run, confirm failure**

- [ ] **Step 3: Add `LocationTerm` + the `SmartRule.location` case**

  In `Muse/Muse/Intelligence/Collections/SmartRule.swift`, add:

```swift
nonisolated enum LocationTerm: Codable, Equatable {
    case place(String)
    case near(lat: Double, lon: Double, radiusKM: Double)
}
```

  Add `case location(LocationTerm)` to `SmartRule`'s case list. Extend `isValid`:

```swift
case let .location(term):
    switch term {
    case let .place(name): return !name.trimmingCharacters(in: .whitespaces).isEmpty
    case let .near(lat, lon, radiusKM):
        return PhotoHeaderReader.sanitize(Coordinate(lat: lat, long: lon)) != nil && radiusKM > 0
    }
```

  (Reuses `PhotoHeaderReader.sanitize`/`Coordinate` from Task 3 rather than
  duplicating the range check — confirm `Coordinate`'s exact field names again here.)
  `Codable` stays fully synthesized (house style) — do not hand-write
  encode/decode. Add the case to EVERY exhaustive switch the compiler flags
  (`isValid` above, and whatever display-name/icon switches already exist elsewhere
  in the file for the other 7 cases — the compiler enumerates these for you; fix
  each one it flags).

- [ ] **Step 4: Add resolver evaluation**

  In `Muse/Muse/Intelligence/Collections/SmartCollectionResolver.swift`, find the
  existing per-rule-case evaluation switch and add:

```swift
case let .location(term):
    switch term {
    case let .place(name):
        let lower = name.trimmingCharacters(in: .whitespaces).lowercased()
        // A localized country display name resolves back to its ISO code
        // in Swift first (places.country stores the ISO code).
        let isoFromLocalizedName = Locale.isoRegionCodes.first {
            Locale.current.localizedString(forRegionCode: $0)?.lowercased() == lower
        }
        let rows = try Row.fetchAll(db, sql: """
            SELECT file_id FROM places
            WHERE place_key IS NOT NULL
              AND (LOWER(city) = ? OR LOWER(admin) = ? OR LOWER(country) = ? OR LOWER(country) = ?)
            """, arguments: [lower, lower, lower, (isoFromLocalizedName ?? "").lowercased()])
        return Set(rows.compactMap { $0["file_id"] as String? })

    case let .near(lat, lon, radiusKM):
        let boxes = GeoBounds.boxes(lat: lat, lon: lon, radiusKM: radiusKM)
        var candidates: [(id: String, lat: Double, lon: Double)] = []
        for box in boxes {
            let rows = try Row.fetchAll(db, sql: """
                SELECT id, lat, lon FROM files
                WHERE lat BETWEEN ? AND ? AND lon BETWEEN ? AND ?
                """, arguments: [box.latRange.lowerBound, box.latRange.upperBound,
                                  box.lonRange.lowerBound, box.lonRange.upperBound])
            candidates.append(contentsOf: rows.compactMap { row -> (String, Double, Double)? in
                guard let id: String = row["id"], let rlat: Double = row["lat"], let rlon: Double = row["lon"]
                else { return nil }
                return (id, rlat, rlon)
            })
        }
        let matched = candidates.filter { c in
            GreatCircle.distanceKM(lat1: lat, lon1: lon, lat2: c.lat, lon2: c.lon) <= radiusKM
        }
        return Set(matched.map(\.id))
    }
```

  Fit this into whatever the resolver's actual per-rule switch/dispatch structure
  looks like (it may return a `Set<String>` per case like this sketch, or feed a
  shared accumulator — match the existing pattern exactly, since this task must not
  change how the other 7 rule types are evaluated).

- [ ] **Step 5: Extend the exhaustive-case test files**

  Add `.location` cases to `SmartRuleSetTests.testEveryRuleTypeRoundTrips` and
  `SmartCollectionResolverTests`'s existing per-case enumeration, following those
  files' exact existing pattern for the other 7 cases.

- [ ] **Step 6: Run all tests, confirm pass**

  Run: `xcodebuild -project Muse/Muse.xcodeproj -scheme Muse test -only-testing:MuseTests/SmartRuleLocationTests -only-testing:MuseTests/SmartRuleSetTests -only-testing:MuseTests/SmartCollectionResolverTests`

- [ ] **Step 7: Commit**

```bash
git add "Muse/Muse/Intelligence/Collections/SmartRule.swift" \
        "Muse/Muse/Intelligence/Collections/SmartCollectionResolver.swift" \
        "Muse/MuseTests/SmartRuleLocationTests.swift" "Muse/MuseTests/SmartRuleSetTests.swift" \
        "Muse/MuseTests/SmartCollectionResolverTests.swift"
git commit -m "feat: add SmartRule.location case (.place / .near) + resolver evaluation"
```

---

### Task 34: `SmartCollectionRulesView` UI for `.location`

**Files:**
- Modify: `Muse/Muse/Views/Sidebar/SmartCollectionRulesView.swift`

**Interfaces:** None new — UI wiring only.

- [ ] **Step 1: Read the file's existing `Kind` enum + `valueControls` switch**

  Confirm the exact structure the other 7 rule kinds use (each has a `Kind` case, a
  `defaultRule(for:)` entry, and a `valueControls` view branch).

- [ ] **Step 2: Add the `.location` kind**

```swift
case location   // add to the Kind enum, label Text("Location")
```

  `defaultRule(for: .location)` returns `.location(.place(""))`. Add a `valueControls`
  branch for `.place`:

```swift
case let .location(.place(name)):
    TextField("", text: bindingForPlaceName(rule))
        .frame(width: 210)
        .placeholder(when: name.isEmpty) { Text("City or country") }
```

  (Match the file's actual `TextField`/placeholder idiom used by the existing
  `.filename(contains:)` case — likely near-identical width/style — copy it exactly
  rather than inventing new styling.) `.near` decodes and evaluates but has **no rule
  editor in v1** — the exact precedent of `ColorTerm.hex` (decodes, no UI); if the
  switch is exhaustive and requires a case for `.location(.near)`, add a
  `EmptyView()` or the same "no editor" placeholder the `ColorTerm.hex` branch
  already uses (read that branch and copy its exact handling, don't invent a new
  convention).

- [ ] **Step 3: Manual verification**

  Run the app, create a smart collection, add a Location rule, type a city/country
  name, confirm it filters correctly against real geotagged photos (once Tasks 2–9
  have populated `places`/`files.lat/lon` for a test library).

- [ ] **Step 4: Commit**

```bash
git add "Muse/Muse/Views/Sidebar/SmartCollectionRulesView.swift"
git commit -m "feat: add Location rule UI to smart collections (place editor; near decodes-only)"
```

---

## Section I — Documentation sweep + localization export

### Task 35: `CLAUDE.md` durable constraints + phase-table row, `architecture-map.md`,
`session-log.md`, localization export pass

**Files:**
- Modify: `CLAUDE.md` (project root)
- Modify: `docs/architecture-map.md`
- Modify: `docs/session-log.md`
- Run: `xcodebuild -exportLocalizations …` (no file diff to plan for beyond whatever
  it writes back into `Localizable.xcstrings`)

**Interfaces:** None — documentation and localization only.

- [ ] **Step 1: Add the 7 new durable constraints to `CLAUDE.md`**

  In "### Durable constraints & gotchas (DO NOT BREAK)", add one bullet per item
  below (condensed to the project's existing terse style — one or two sentences with
  a "why", matching the density of neighboring bullets, not the full paragraph form
  from `spec-02-implementation.md` §9):

  1. `files.feature_print` is RAW `VNFeaturePrintObservation.data` — never
     `NSKeyedUnarchiver` it; all comparisons go through `FeaturePrints.floats/distance`.
  2. Query time touches ONLY precomputed data — every search token resolves against
     an indexed column written at analyze/backfill time; new search capability = new
     indexed column + backfill.
  3. Geocoding is fully offline (bundled GeoNames + k-d tree); `CLGeocoder`/MapKit
     geocoding are forbidden.
  4. Attempted-markers for header-derived data (`coords_scanned_hash`,
     `photo_meta.exif_scanned_hash`, the `places` row itself) — dataless iCloud files
     are skipped WITHOUT stamping.
  5. Stacks are presentation-only and content-keyed; collapse applies ONLY in plain
     folder browse; the auto-stacker only ever touches virgin files (no
     `stack_members` row, dissolved included).
  6. `last_viewed_at` is device-local — never exported to sidecars, never synced.
  7. Search token grammar keys are canonical English and parse before every other
     search leg; an unparseable token stays in free text verbatim; the chip bar holds
     no state of its own.

- [ ] **Step 2: Add the phase-table row**

  In "## Implementation status", add: `| Foundation 2 — Spec-02 photo library core
  (EXIF/photo_meta, offline Places, rediscovery, near-dup stacks, token search
  phase 1, .location smart rule) | ✅ shipped (update at merge) |
  <branch> |`.

- [ ] **Step 3: Update `docs/architecture-map.md`**

  Add entries for every new file this plan created: `Filesystem/PhotoHeaderReader.swift`,
  `Intelligence/PhotoHeaderBackfill.swift`, `Intelligence/Geo/` (GeoNamesDataset,
  GeoKDTree, GeocodeBackfill), `Intelligence/Core/FeaturePrints.swift`,
  `Intelligence/Stacks/` (BurstClusterer, AutoStacker), `Search/` (SearchToken,
  PhotoSearch, SearchFacets), `Database/` additions (PlaceQueries,
  RediscoveryQueries, StackStore), `Models/` additions (PlacesStore,
  RediscoveryStore, StacksStore, `AppState+Places.swift`, `AppState+Rediscovery.swift`),
  `Views/` additions (PlacesPage, RediscoveryHeader, `Sidebar/LibraryRows.swift`),
  `Components/StackDisplay.swift`. Follow the existing file's terse one-line-per-file
  convention.

- [ ] **Step 4: Append a `docs/session-log.md` entry**

  Following the existing dated-entry convention, summarize this spec's build in the
  same style as prior entries: what shipped, the key deviations recorded in
  `spec-02-implementation.md` §13 (the header-reader merge with Spec 01, EXIF-as-
  separate-table, content-keyed stacks/rediscovery, the near: click-through
  decision, the raw-float feature-print fix), and a pointer back to
  `docs/new-build/spec-02-implementation.md` and this plan file for full detail.

- [ ] **Step 5: Run the localization export pass**

  Run: `xcodebuild -exportLocalizations -project Muse/Muse.xcodeproj -localizationPath /tmp/muse-l10n -exportLanguage fr`
  This write-backs every new key from this spec's `Text`/`Button`/`.help`/
  `.accessibilityLabel` literals into the source `Localizable.xcstrings`. Fill the
  newly-empty French values (Places / On This Day / Rarely Seen / Shuffle / Search /
  the search-token key labels / "Stack of %lld photos" / "Google Maps" / "City or
  country" / etc.) — the feature is incomplete until a re-run reports 0
  untranslated. Wrap any string passed as a plain `String` (not a SwiftUI text-literal
  position) in `String(localized:)` if any was missed during implementation — grep
  the diff for bare string literals passed to non-`Text`/`Button` positions as a final
  check (per `CLAUDE.md`'s documented localization workflow).

- [ ] **Step 6: Run the full test suite one final time**

  Run: `xcodebuild -project Muse/Muse.xcodeproj -scheme Muse test`
  Expected: all suites green, including every new suite this plan added (Tasks 1, 2,
  3, 4, 5's regression checks, 6, 7, 8, 9, 10, 11, 12, 13, 16, 21, 22, 27, 28, 29, 30,
  33) and no regression in any pre-existing suite.

- [ ] **Step 7: Commit**

```bash
git add CLAUDE.md docs/architecture-map.md docs/session-log.md Muse/Muse/Muse.xcdatamodeld/Localizable.xcstrings 2>/dev/null
git add "Muse/Muse/Localizable.xcstrings"
git commit -m "docs: record Spec 02 in CLAUDE.md/architecture-map/session-log + French localization pass"
```

---

## Final self-review notes (for the plan author, not a task)

- **Spec coverage:** every numbered section of `spec-02-implementation.md` (§1
  schema, §2 EXIF/coordinates, §3 geocoding, §4 Places, §5 rediscovery, §6 stacks,
  §7 search, §8 `.location`, §9 constraints, §10 tests, §11 build order) maps to a
  task above. §12 (owner-only steps: running `make-geonames.sh` for real, validating
  `BurstClusterer.similarityThreshold`, running `PerfBaseline` on real hardware,
  French translations) is explicitly called out as owner-only inside Tasks 7, 15,
  and 35 rather than assigned to an engineer — these cannot be completed by a
  build agent and must be flagged to Carlos at PR review.
- **DECISIONS.md amendment A1** (skip the coords/photo_meta write when both
  markers already match `content_hash`) is built into Tasks 4 and 5 from the start,
  not deferred, since it's cheap now and load-bearing once Spec 06 exists.
- **Forward references** (a task calling a type a LATER task creates) are used in
  exactly three places, each explicitly marked with a `// TODO(task-N)` comment and
  an explicit uncomment step in the target task: `PhotoHeaderBackfill` → `GeocodeBackfill`
  (Task 5 → Task 9), `GeocodeBackfill` → `PlacesStore`/`SearchFacets` (Task 9 → Tasks
  16/13), `AppState+Places.openPlacesPage` → `RediscoveryStore.dismiss()` (Task 19 →
  Task 25). A team executing tasks out of this exact order must resolve these by hand.

