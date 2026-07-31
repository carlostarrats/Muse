# Spec 01 — Foundation & Plumbing Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

> **Distribution stays Sparkle/direct for now.** The Mac App Store move (doctrine
> revisions, Sparkle excision, Apple Silicon–only build settings — formerly this plan's
> Section A) is deferred at the owner's request and split out into its own standalone
> plan: `deferred-mac-app-store-migration.md`. Run that plan whenever the owner decides
> to make the MAS move — no fixed date. Nothing below depends on it landing first.

**Goal:** Land the non-visible foundation work that unblocks the photo-repositioning
roadmap: a v13 GPS-coordinates migration, the three edit-aware seams (thumbnail cache
key, layout geometry, export choke point) that make Spec 04's editor a 3–5 week job
instead of a rewrite, StoreKit 2 commercial plumbing (unenforced trial gate, tested via
a local StoreKit Configuration file — no App Store record needed yet), the
announcements channel, and a performance-baseline harness.

**Architecture:** Every new stateful piece is its own store/module — `AppState` is frozen
(1380 LOC / ~70 `@Published`, DECIDED #26) and gains nothing. Three seams
(`EditStackIndex`, `EffectiveDimensions`, `OutputRender`) are introduced as **identity
functions today** — nil provider, pass-through, no-op — so Spec 04 changes exactly one
implementation per seam and every consumer is already wired correctly. No user-visible
behavior changes except the (locked-open) trial gate plumbing and the announcements
banner infrastructure (empty feed until the owner deploys `announcements.json`).

**Tech Stack:** Swift 5 (`SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`), SwiftUI + AppKit
escape hatches, GRDB.swift 7.10 (SQLite + FTS5), StoreKit 2, XCTest. Dependency count
stays at **two** (GRDB + Sparkle) — Sparkle removal is deferred to the standalone MAS
migration plan.

## Global Constraints

- **AppState is frozen.** No new `@Published` properties on `Models/AppState.swift`. New
  features (`CommerceStore`, `AnnouncementStore`) are standalone `ObservableObject`s
  injected via `.environmentObject`, following the `GoogleOAuth` pattern exactly
  (`Muse/Muse/Sharing/Drive/GoogleOAuth.swift:16`, injected `MuseApp.swift:22,100`,
  consumed via `@EnvironmentObject`).
- **Never modify user files.** Files move to Trash only, never `unlink`'d
  (`NSWorkspace.shared.recycle`). This spec touches zero file-mutation code paths.
- **No EXIF/XMP writes.** All new metadata (coordinates) is DB-only, read-only against
  source files.
- **Network policy after this spec: Sparkle's feed fetch, plus three app-initiated
  paths.** (1) Drive share (user-initiated, unchanged), (2) `announcements.json`
  (launch, off-able, this spec), (3) custom-domain provisioning Worker (future spec, not
  built here). StoreKit traffic is OS-level. Sparkle removal is deferred (see above).
- **No new third-party package is added anywhere in this spec.** Dependency count stays
  at two (GRDB + Sparkle) until the deferred MAS migration plan removes Sparkle.
- **Every modal is `ModalMessageCard`/`ModalButton`/`.museModal`, never `.alert` or
  `.sheet`** (durable constraint, `Muse/Muse/Views/Modal/ModalMessageCard.swift`,
  registration pattern at `Muse/Muse/ContentView.swift:304-313`).
- **Pure logic lives in testable, `nonisolated`/free-standing types; UI views are not
  unit-tested** — matches the existing `MuseTests` convention (`TagScopeTests.swift`,
  `StarRatingTests.swift`: `import XCTest`, `@testable import Muse`, `final class
  <Type>Tests: XCTestCase`, `test<Behavior>()` methods).
- **GRDB writes/reads are `async`** (`try await queue.write { }` / `try await
  queue.read { }`); GRDB rows are inserted as `var` (`MutablePersistableRecord.insert`
  mutates `id` in place).
- **Every AVFoundation asset is built via `AVURLAsset.noNetwork(url:)` /
  `AVPlayer.noNetwork(url:)`** (`Muse/Muse/Filesystem/AVURLAsset+NoNetwork.swift`),
  never a bare `AVURLAsset(url:)` — a QuickTime reference movie can beacon the user's IP
  otherwise.
- **Localize every new user-facing string.** `Text("…")`/`Button("…")`/`.help("…")`
  literals auto-extract; anything passed as a plain `String` (AppKit setters, custom
  view params) needs an explicit `String(localized:)` wrap.

---

## Section A — DEFERRED (Mac App Store migration)

> Formerly Tasks 1–8 (doctrine revisions, deployment-target/Apple-Silicon-only build
> settings, Sparkle excision, direct-distribution tooling removal, RELEASING.md/README
> rewrite). Split out to `deferred-mac-app-store-migration.md` on 2026-07-31 at the
> owner's request — the app stays on direct distribution (Sparkle self-update) for now.
> That plan is self-contained and standalone; run it whenever the MAS move actually
> happens. Do not run it as part of this plan. Task numbering below (Section B onward)
> is unchanged from the original plan, so those Task 1–8 numbers are intentionally
> skipped here — they now belong to the deferred plan.

---

## Section B — Coordinates: migration, reader, backfill

### Task 9: `v13_coordinates` migration + `FileRow` fields

**Files:**
- Modify: `Muse/Muse/Database/Database.swift` (add migration after line 365, before
  `return migrator` at line 367)
- Modify: `Muse/Muse/Database/Records.swift` (add fields to `FileRow`, lines 13-44)
- Create: `Muse/MuseTests/CoordinateMigrationTests.swift`

**Interfaces:**
- Produces: `FileRow.lat: Double?`, `FileRow.lon: Double?`,
  `FileRow.coords_scanned_hash: String?` — consumed by Task 10 (`CoordinateReader`),
  Task 11 (`AnalyzePipeline` write point), Task 12 (`CoordinateBackfill`).
- Produces: DB columns `files.lat REAL`, `files.lon REAL`, `files.coords_scanned_hash
  TEXT`, and partial index `files_coords_idx ON files(lat, lon) WHERE lat IS NOT NULL`.

- [ ] **Step 1: Write the failing migration test**

```swift
//
//  CoordinateMigrationTests.swift
//  MuseTests
//
//  v13_coordinates: files.lat/lon/coords_scanned_hash + a partial index.
//

import XCTest
import GRDB
@testable import Muse

final class CoordinateMigrationTests: XCTestCase {
    func testV13AddsCoordinateColumnsAndIndex() throws {
        let queue = try DatabaseQueue()
        let migrator = Database.makeMigrator()
        try migrator.migrate(queue)

        try queue.read { db in
            XCTAssertTrue(try db.columns(in: "files").contains { $0.name == "lat" })
            XCTAssertTrue(try db.columns(in: "files").contains { $0.name == "lon" })
            XCTAssertTrue(try db.columns(in: "files").contains { $0.name == "coords_scanned_hash" })
            let indexes = try db.indexes(on: "files")
            XCTAssertTrue(indexes.contains { $0.name == "files_coords_idx" })
        }
    }

    func testV13IsIdempotentAndPreservesExistingRows() throws {
        let queue = try DatabaseQueue()
        let migrator = Database.makeMigrator()
        try migrator.migrate(queue)

        try queue.write { db in
            try db.execute(sql: """
                INSERT INTO files (id, content_hash, kind, last_seen_at)
                VALUES ('f1', 'hash1', 'image', 0)
                """)
        }
        // Re-running migrate on an already-migrated queue is a no-op (GRDB's
        // registered-migration tracking), and existing rows must survive with
        // NULL coordinate columns.
        try migrator.migrate(queue)

        try queue.read { db in
            let row = try FileRow.filter(FileRow.Columns.id == "f1").fetchOne(db)
            XCTAssertNotNil(row)
            XCTAssertNil(row?.lat)
            XCTAssertNil(row?.lon)
            XCTAssertNil(row?.coords_scanned_hash)
        }
    }
}
```

  This test requires `Database.makeMigrator()` to be a callable static/class function
  that returns the configured `DatabaseMigrator` — check
  `Muse/Muse/Database/Database.swift` for how the migrator is currently exposed (the
  research pass found it built inline at line 64 inside what is presumably a function;
  confirm the function's name/signature before writing this test — if it's not already
  a standalone testable function, extract it as one in Step 2, since the existing test
  suite likely already needs this seam for its own migration tests — check for an
  existing `DatabaseMigrationTests.swift` or similar and follow its exact pattern
  instead of inventing a new one if it already tests v1-v12 this way).

- [ ] **Step 2: Run the test, confirm it fails**

  Run: `xcodebuild -project Muse/Muse.xcodeproj -scheme Muse test -only-testing:MuseTests/CoordinateMigrationTests`
  Expected: FAIL — columns don't exist yet.

- [ ] **Step 3: Add the migration**

  In `Muse/Muse/Database/Database.swift`, immediately after the `v12_smart_collections`
  registration block (after line 365) and before `return migrator` (line 367), add:

```swift
migrator.registerMigration("v13_coordinates") { db in
    // GPS lives in the file's own bytes — content-keyed like palette/caption/
    // dominant_color/feature_print, deliberately NOT the tags/notes per-location
    // grain (two byte-identical copies in different folders have identical
    // coordinates by definition; edit-in-place already splits the row).
    try db.alter(table: "files") { t in
        t.add(column: "lat", .double)
        t.add(column: "lon", .double)
        // The content_hash we last read GPS from. Storing the hash (not a bare
        // bool) means an edit-in-place re-reads new bytes for new GPS, mirroring
        // analyzed_hash — and avoids the analyzed_hash-NULL retry-loop bug shape
        // (2026-07-28): without an attempted-marker, every GPS-less file would
        // be re-opened on every launch forever.
        t.add(column: "coords_scanned_hash", .text)
    }
    // Partial index — a library with no geotagged photos costs nothing.
    try db.execute(sql: """
        CREATE INDEX files_coords_idx ON files(lat, lon) WHERE lat IS NOT NULL
        """)
}
```

- [ ] **Step 4: Add the fields to `FileRow`**

  In `Muse/Muse/Database/Records.swift`, add three new properties to `FileRow` (after
  `intent_model_version` at line 30 area, matching the existing `Optional` style):

```swift
var lat: Double?
var lon: Double?
var coords_scanned_hash: String?
```

  No new `Columns` enum cases are needed unless a later task filters by `lat`/`lon`/
  `coords_scanned_hash` via `FileRow.Columns.*` — Task 12's `CoordinateBackfill` uses
  raw SQL (matching `IntentBackfill`'s pattern, which also skips `Columns` for
  `intent_model_version`), so skip adding `Columns` cases here unless a later task in
  this plan needs one (none do).

- [ ] **Step 5: Run the test, confirm it passes**

  Run: `xcodebuild -project Muse/Muse.xcodeproj -scheme Muse test -only-testing:MuseTests/CoordinateMigrationTests`
  Expected: PASS.

- [ ] **Step 6: Run the full existing DB/migration test suite**

  Run: `xcodebuild -project Muse/Muse.xcodeproj -scheme Muse test -only-testing:MuseTests/DatabaseTests` (or whatever the existing migration suite is named — confirm the name from Step 1's investigation). Expected: PASS, no regression on v1-v12.

- [ ] **Step 7: Commit**

```bash
git add "Muse/Muse/Database/Database.swift" "Muse/Muse/Database/Records.swift" \
        "Muse/MuseTests/CoordinateMigrationTests.swift"
git commit -m "feat: add v13_coordinates migration (files.lat/lon/coords_scanned_hash)"
```

---

### Task 10: `CoordinateReader` + `sanitize` validator

**Files:**
- Create: `Muse/Muse/Filesystem/CoordinateReader.swift`
- Create: `Muse/MuseTests/CoordinateReaderTests.swift`

**Interfaces:**
- Consumes: `AssetKind` (existing enum), `FileMetadata.coordinate(latitude:latRef:longitude:longRef:)`
  (`Muse/Muse/Viewers/FileMetadata.swift:123-129`), `FileMetadata.parseISO6709(_:)`
  (`FileMetadata.swift:184-193`), `AVURLAsset.noNetwork(url:)`
  (`Muse/Muse/Filesystem/AVURLAsset+NoNetwork.swift`).
- Produces: `CoordinateReader.read(url:kind:) async -> Coordinate?`,
  `CoordinateReader.sanitize(_:) -> Coordinate?` — consumed by Task 11
  (`AnalyzePipeline`) and Task 12 (`CoordinateBackfill`). `Coordinate` is the existing
  type from `FileMetadata.swift` (`struct Coordinate { let lat: Double; let long:
  Double }` — confirm exact field names by reading `FileMetadata.swift` before writing;
  the research snippets used `lat`/`long`).

- [ ] **Step 1: Write the failing tests for `sanitize`**

```swift
//
//  CoordinateReaderTests.swift
//  MuseTests
//
//  Header-only GPS extraction, shared with FileMetadata's display-time reader —
//  must never diverge (a viewer showing one location while the DB stores
//  another is worse than no column).
//

import XCTest
@testable import Muse

final class CoordinateReaderTests: XCTestCase {
    func testSanitizeAcceptsValidRange() {
        let c = Coordinate(lat: 38.7223, long: -9.1393)
        XCTAssertEqual(CoordinateReader.sanitize(c)?.lat, 38.7223)
        XCTAssertEqual(CoordinateReader.sanitize(c)?.long, -9.1393)
    }

    func testSanitizeRejectsOutOfRangeLatitude() {
        XCTAssertNil(CoordinateReader.sanitize(Coordinate(lat: 91, long: 0)))
        XCTAssertNil(CoordinateReader.sanitize(Coordinate(lat: -91, long: 0)))
    }

    func testSanitizeRejectsOutOfRangeLongitude() {
        XCTAssertNil(CoordinateReader.sanitize(Coordinate(lat: 0, long: 181)))
        XCTAssertNil(CoordinateReader.sanitize(Coordinate(lat: 0, long: -181)))
    }

    func testSanitizeRejectsNonFiniteValues() {
        XCTAssertNil(CoordinateReader.sanitize(Coordinate(lat: .nan, long: 0)))
        XCTAssertNil(CoordinateReader.sanitize(Coordinate(lat: 0, long: .infinity)))
    }

    func testSanitizeAcceptsBoundaryValues() {
        XCTAssertNotNil(CoordinateReader.sanitize(Coordinate(lat: 90, long: 180)))
        XCTAssertNotNil(CoordinateReader.sanitize(Coordinate(lat: -90, long: -180)))
    }

    func testReadReturnsNilForUnsupportedKind() async {
        let url = URL(fileURLWithPath: "/tmp/nonexistent.txt")
        let result = await CoordinateReader.read(url: url, kind: .document)
        XCTAssertNil(result)
    }
}
```

  Adjust `.document` to whatever `AssetKind` case actually exists for a plain
  non-image/video file (check `Muse/Muse/Models/AssetKind.swift`) — the point of this
  test is "a kind CoordinateReader doesn't handle returns nil, not a crash."

- [ ] **Step 2: Run, confirm failure**

  Run: `xcodebuild -project Muse/Muse.xcodeproj -scheme Muse test -only-testing:MuseTests/CoordinateReaderTests`
  Expected: FAIL — `CoordinateReader` doesn't exist.

- [ ] **Step 3: Implement `CoordinateReader`**

```swift
//
//  CoordinateReader.swift
//  Muse
//
//  Header-only GPS read for the coordinate-persistence pipeline (v13). Mirrors
//  FileMetadata's display-time coordinate/ISO-6709 parsing exactly — the two
//  must never diverge, or a viewer shows one location while the DB stores
//  another.
//

import Foundation
import ImageIO
import AVFoundation

enum CoordinateReader {
    static func read(url: URL, kind: AssetKind) async -> Coordinate? {
        switch kind {
        case .image, .raw, .psd:
            return readImageGPS(url: url)
        case .video:
            return await readVideoGPS(url: url)
        default:
            return nil
        }
    }

    /// Rejects non-finite and out-of-range values — a corrupt header must not
    /// put a pin in the sea.
    static func sanitize(_ c: Coordinate) -> Coordinate? {
        guard c.lat.isFinite, c.long.isFinite,
              abs(c.lat) <= 90, abs(c.long) <= 180 else { return nil }
        return c
    }

    private static func readImageGPS(url: URL) -> Coordinate? {
        // Dataless iCloud placeholders never force a download — same guard as
        // FileMetadata.load and Indexer.isDataless.
        if let values = try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey]),
           let status = values.ubiquitousItemDownloadingStatus,
           status != .current {
            return nil
        }
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let gps = props[kCGImagePropertyGPSDictionary] as? [CFString: Any]
        else { return nil }
        let coord = FileMetadata.coordinate(
            latitude: gps[kCGImagePropertyGPSLatitude] as? Double,
            latRef: gps[kCGImagePropertyGPSLatitudeRef] as? String,
            longitude: gps[kCGImagePropertyGPSLongitude] as? Double,
            longRef: gps[kCGImagePropertyGPSLongitudeRef] as? String)
        return coord.flatMap(sanitize)
    }

    private static func readVideoGPS(url: URL) async -> Coordinate? {
        if let values = try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey]),
           let status = values.ubiquitousItemDownloadingStatus,
           status != .current {
            return nil
        }
        let asset = AVURLAsset.noNetwork(url: url)
        guard let items = try? await asset.load(.commonMetadata) else { return nil }
        let locationItem = items.first { $0.commonKey == .commonKeyLocation }
        guard let locationString = try? await locationItem?.load(.stringValue) else { return nil }
        let coord = FileMetadata.parseISO6709(locationString)
        return coord.flatMap(sanitize)
    }
}
```

  Confirm the exact `AVMetadataItem` async-loading API against the Swift/AVFoundation
  version in use (`.load(.commonMetadata)` / `.load(.stringValue)` is the modern async
  API — if the codebase's `FileMetadata.loadVideo` uses the older synchronous
  `.commonMetadata`/`.value(forKey:)` pattern instead, per research at
  `FileMetadata.swift:395+`, match THAT pattern exactly instead, since consistency with
  the existing display-time reader matters more than using the newest API. Read
  `FileMetadata.swift:395-420` before finalizing this function.

- [ ] **Step 4: Run tests, confirm pass**

  Run: `xcodebuild -project Muse/Muse.xcodeproj -scheme Muse test -only-testing:MuseTests/CoordinateReaderTests`
  Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add "Muse/Muse/Filesystem/CoordinateReader.swift" "Muse/MuseTests/CoordinateReaderTests.swift"
git commit -m "feat: add CoordinateReader (header-only GPS read, mirrors FileMetadata)"
```

---

### Task 11: Wire coordinate write into `AnalyzePipeline.analyzeOne` (images + video)

**Files:**
- Modify: `Muse/Muse/Intelligence/AnalyzePipeline.swift` (around line 409-488)

**Interfaces:**
- Consumes: `CoordinateReader.read(url:kind:)` (Task 10).
- Produces: `files.lat`/`lon`/`coords_scanned_hash` populated during the normal
  analysis pass — consumed by Spec 02's `.location` smart rule and place-grouped grid
  (not built in this spec).

- [ ] **Step 1: Add a coordinate-write test at the AnalyzePipeline level**

  Check for an existing `AnalyzePipelineTests.swift` — if one exists, follow its setup
  (likely an in-memory `DatabaseQueue` + a fixture image with known EXIF GPS, or a
  mocked `CoordinateReader` — since `CoordinateReader.read` isn't a protocol-based seam
  like `EditStackIndex` will be, the test most likely needs a real fixture file with
  embedded GPS EXIF, OR `AnalyzePipeline` needs a small internal seam for injecting a
  reader in tests). Given `AnalyzePipeline` is a large existing file or actor, prefer
  **not** inventing a new DI seam beyond what's needed — write an integration-style test
  using a tiny real JPEG fixture with known GPS tags if the test target already has an
  images/fixtures directory (check `Muse/MuseTests/Fixtures/` or similar). If no such
  fixture convention exists, add the coordinate assertions to whatever the closest
  existing `AnalyzePipeline` write-transaction test already does (extend it) rather than
  building new fixture infrastructure — match the codebase's actual testing depth for
  this pipeline (likely white-box unit tests of the pure formatting/threshold helpers,
  not full end-to-end Vision runs, since Vision itself isn't mocked anywhere else in the
  suite per the research pass).

  Minimal safe version — verify the guard logic directly:
```swift
func testAnalyzeOneWritesCoordinatesUnderContentHashGuard() async throws {
    // Arrange: seed a files row with content_hash == analyzedHash-to-be,
    // stub CoordinateReader indirectly via a real GPS-tagged fixture,
    // run analyzeOne, assert lat/lon/coords_scanned_hash are set and match
    // the file's content_hash (not a stale value).
}
```
  Write the concrete version once the actual test scaffolding for
  `AnalyzePipeline` is confirmed by reading the file in full — this step's deliverable
  is a real, passing test exercising the guarded write path, following whatever harness
  the existing `AnalyzePipeline` tests already use.

- [ ] **Step 2: Run, confirm failure (coordinates not yet written)**

- [ ] **Step 3: Add the coordinate read + write to `analyzeOne`**

  Two write sites are needed because `analyzeOne` currently returns early for
  non-image/raw/psd kinds at line 411 (`guard kind == .image || kind == .raw || kind ==
  .psd else { return }`), and video needs its own tiny transaction that runs BEFORE that
  guard:

  Immediately **before** line 411's guard, add:
```swift
private func analyzeOne(fileID: String, url: URL) async {
    let kind = AssetKind.detect(at: url)

    // Coordinates are read for image AND video kinds — this runs before the
    // image-only Vision guard below so a geotagged video isn't invisible to
    // location search just because Vision doesn't tag videos.
    if kind == .video {
        await writeCoordinatesOnly(fileID: fileID, url: url, kind: kind)
    }

    guard kind == .image || kind == .raw || kind == .psd else { return }
    // ... existing Vision pipeline continues unchanged ...
```

  Add the coordinate read for image kinds **concurrently with** the existing Vision
  work (not serially after it — the spec requires "off-main, concurrent with it").
  Locate where `analyzedHash` is captured (around line 414-422 per research) and add a
  concurrent `async let coordinate = CoordinateReader.read(url: url, kind: kind)`
  alongside whatever `async let`s already exist for the Vision outputs. Then inside the
  existing guarded write transaction (lines 465-488), add the three field assignments
  right after `file.intent_model_version = finalIntentVersion` (before `try
  file.update(db)`):

```swift
if let coord = await coordinate {
    file.lat = coord.lat
    file.lon = coord.long
}
file.coords_scanned_hash = analyzedHash
```

  Note: `coords_scanned_hash` is always stamped to `analyzedHash` even when `coord` is
  nil (no GPS found) — this is the attempted-marker that prevents the retry-loop bug
  shape (mirrors `analyzed_hash` itself). Only `lat`/`lon` are conditionally written.

  Add the new private helper for the video-only path:
```swift
/// Video kinds skip the Vision pipeline entirely but still need their
/// coordinate written — a separate, smaller guarded transaction mirroring
/// the main one's content_hash re-check.
private func writeCoordinatesOnly(fileID: String, url: URL, kind: AssetKind) async {
    guard let queue = Database.shared.dbQueue else { return }
    guard let currentHash: String? = try? await queue.read({ db in
        try FileRow.filter(FileRow.Columns.id == fileID).fetchOne(db)?.content_hash
    }), let hash = currentHash else { return }

    let coord = await CoordinateReader.read(url: url, kind: kind)

    try? await queue.write { db in
        guard var file = try FileRow.filter(FileRow.Columns.id == fileID).fetchOne(db),
              file.content_hash == hash else { return }
        if let coord {
            file.lat = coord.lat
            file.lon = coord.long
        }
        file.coords_scanned_hash = hash
        try file.update(db)
    }
}
```

  Confirm `Database.shared.dbQueue` and `FileRow.Columns.id`/`content_hash` match the
  actual names used elsewhere in `AnalyzePipeline.swift` (the research snippet used
  `FileRow.Columns.id` for the main write's fetch — reuse exactly that spelling).

- [ ] **Step 4: Run the test, confirm pass**

- [ ] **Step 5: Run the full `AnalyzePipeline`/Indexer test suites for regressions**

  Run: `xcodebuild -project Muse/Muse.xcodeproj -scheme Muse test -only-testing:MuseTests/AnalyzePipelineTests -only-testing:MuseTests/IndexerReconcileTests`
  Expected: PASS, no change to existing analysis behavior for non-GPS fields.

- [ ] **Step 6: Commit**

```bash
git add "Muse/Muse/Intelligence/AnalyzePipeline.swift" "Muse/MuseTests/AnalyzePipelineTests.swift"
git commit -m "feat: write GPS coordinates during analysis (images + video)"
```

---

### Task 12: `CoordinateBackfill` launch pass + `MuseApp.swift` wiring

**Files:**
- Create: `Muse/Muse/Intelligence/CoordinateBackfill.swift`
- Modify: `Muse/Muse/MuseApp.swift` (near line 131-132, alongside the existing
  `IntentBackfill` launch)

**Interfaces:**
- Consumes: `CoordinateReader.read(url:kind:)` (Task 10), `Database.shared.dbQueue`,
  `PhaseTrace.mark(_:)` (`Muse/Muse/Components/PhaseTrace.swift`).
- Produces: `CoordinateBackfill.run() async` — a fire-and-forget launch-time pass, no
  return value consumed elsewhere.

- [ ] **Step 1: Write a test for the candidate-selection SQL**

  Following `IntentBackfill`'s untested-at-the-integration-level pattern (research
  found no `IntentBackfillTests.swift` — it's exercised indirectly), check first: `find
  Muse/MuseTests -iname "*Backfill*"`. If a precedent test exists, follow its shape
  exactly. If none exists (matching research findings), this task's correctness rests
  on the guarded-write pattern already proven correct in Task 11 (same query shape) —
  write one focused test instead, isolating the pure "which rows are candidates" SQL
  logic if it can be extracted as a pure predicate, OR skip a dedicated unit test here
  and rely on Task 9's migration test + Task 10's `CoordinateReader` tests + Task 11's
  write-guard test as the coverage for this pass's building blocks, matching the
  precedent that `IntentBackfill` itself has none. State this decision explicitly in
  the commit message rather than silently skipping.

- [ ] **Step 2: Implement `CoordinateBackfill`**

```swift
//
//  CoordinateBackfill.swift
//  Muse
//
//  Launch-time pass backfilling files.lat/lon/coords_scanned_hash for files
//  the analysis pipeline hasn't stamped yet (pre-Spec-01 libraries, or files
//  whose content changed since the last scan). Mirrors IntentBackfill.
//

import Foundation

enum CoordinateBackfill {
    /// Capped per launch so a 100k cold library spreads the backfill over a
    /// few launches instead of hammering disk once.
    private static let maxPerLaunch = 5_000
    private static let chunkSize = 200

    static func run() async {
        guard let q = Database.shared.dbQueue else { return }

        struct Candidate { let id: String; let url: URL; let kind: AssetKind }
        let candidates: [Candidate] = (try? await q.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT f.id, p.absolute_path FROM files f
                JOIN paths p ON p.file_id = f.id AND p.is_alive = 1
                WHERE (f.coords_scanned_hash IS NULL
                       OR f.coords_scanned_hash != f.content_hash)
                  AND f.content_hash IS NOT NULL
                GROUP BY f.id
                LIMIT \(maxPerLaunch)
                """)
            return rows.compactMap { row -> Candidate? in
                guard let id: String = row["id"],
                      let path: String = row["absolute_path"] else { return nil }
                let url = URL(fileURLWithPath: path)
                let kind = AssetKind.detect(at: url)
                guard kind == .image || kind == .raw || kind == .psd || kind == .video
                else { return nil }
                return Candidate(id: id, url: url, kind: kind)
            }
        }) ?? []
        guard !candidates.isEmpty else { return }

        for chunk in candidates.chunked(into: chunkSize) {
            var results: [(id: String, hash: String, coord: Coordinate?)] = []
            await withTaskGroup(of: (String, String, Coordinate?)?.self) { group in
                for c in chunk {
                    group.addTask {
                        guard let hash: String? = try? await q.read({ db in
                            try FileRow.filter(FileRow.Columns.id == c.id).fetchOne(db)?.content_hash
                        }), let contentHash = hash else { return nil }
                        let coord = await CoordinateReader.read(url: c.url, kind: c.kind)
                        return (c.id, contentHash, coord)
                    }
                }
                for await result in group {
                    if let result { results.append(result) }
                }
            }
            try? await q.write { db in
                for (id, hash, coord) in results {
                    guard var file = try FileRow.filter(FileRow.Columns.id == id).fetchOne(db),
                          file.content_hash == hash else { continue }
                    if let coord {
                        file.lat = coord.lat
                        file.lon = coord.long
                    }
                    file.coords_scanned_hash = hash
                    try file.update(db)
                }
            }
        }
    }
}
```

  Confirm `paths`/`absolute_path`/`is_alive` column and table names exactly against
  `Muse/Muse/Database/Records.swift`'s `PathRow` definition before finalizing (research
  cited `PathRow(absolute_path, bookmark, is_alive)` in `CLAUDE.md`'s architecture
  notes — verify by reading the actual struct). Confirm `Array.chunked(into:)` already
  exists as a codebase utility (used elsewhere for chunked writes — grep `chunked(into:`
  across `Muse/Muse`) or add a small private extension if it doesn't.

  Bounded concurrency (4) is required per spec — if `withTaskGroup` above spawns all of
  `chunk` (200) concurrently, that exceeds "concurrency 4." Cap it explicitly:

```swift
await withTaskGroup(of: (String, String, Coordinate?)?.self) { group in
    var iterator = chunk.makeIterator()
    var active = 0
    func spawnNext() {
        guard active < 4, let c = iterator.next() else { return }
        active += 1
        group.addTask {
            guard let hash: String? = try? await q.read({ db in
                try FileRow.filter(FileRow.Columns.id == c.id).fetchOne(db)?.content_hash
            }), let contentHash = hash else { return nil }
            let coord = await CoordinateReader.read(url: c.url, kind: c.kind)
            return (c.id, contentHash, coord)
        }
    }
    for _ in 0..<4 { spawnNext() }
    for await result in group {
        active -= 1
        if let result { results.append(result) }
        spawnNext()
    }
}
```

  Replace the earlier unbounded version with this bounded one in the final file.

- [ ] **Step 3: Wire the launch call in `MuseApp.swift`**

  Near line 131-132, alongside the existing `IntentBackfill` launch:

```swift
PhaseTrace.mark("coordinate-backfill.start")
Task { await CoordinateBackfill.run(); PhaseTrace.mark("coordinate-backfill.end") }
```

  Add this as its own line, not nested inside the `IntentBackfill` task — both are
  independent fire-and-forget passes.

- [ ] **Step 4: Build and smoke-test**

  Run: `xcodebuild -project Muse/Muse.xcodeproj -scheme Muse -configuration Debug build`
  Expected: `BUILD SUCCEEDED`. Then run the app once against a real folder containing at
  least one geotagged JPEG (any phone photo with location services on at capture time)
  and confirm — via a direct SQLite query against the sandboxed DB path
  (`~/Library/Containers/com.tarrats.Muse/Data/Library/Application
  Support/Muse/muse.sqlite`) — that `lat`/`lon` are populated for that file after
  launch: `sqlite3 <path> "SELECT id, lat, lon, coords_scanned_hash FROM files WHERE lat
  IS NOT NULL"`.

- [ ] **Step 5: Commit**

```bash
git add "Muse/Muse/Intelligence/CoordinateBackfill.swift" "Muse/Muse/MuseApp.swift"
git commit -m "feat: add CoordinateBackfill launch pass for pre-existing libraries"
```

---

## Section C — Edit-aware seams

### Task 13: `EditStackIndex` — the stack-hash seam (identity function today)

**Files:**
- Create: `Muse/Muse/Models/EditStackIndex.swift`
- Create: `Muse/MuseTests/EditStackIndexTests.swift`

**Interfaces:**
- Produces: `EditStackIndex.stackHash(for: URL) -> String?`,
  `EditStackIndex.croppedSize(for: URL) -> CGSize?`,
  `EditStackIndex.installProvider(_: (any EditStackProviding)?)`, and the
  `EditStackProviding` protocol — consumed by Task 14 (`ThumbnailCache`), Task 15
  (`EffectiveDimensions`), and (in Spec 04, not this plan) the real edit-stack provider.

- [ ] **Step 1: Write the failing tests**

```swift
//
//  EditStackIndexTests.swift
//  MuseTests
//
//  Identity-function seam today (no provider installed = nil everywhere).
//  Spec 04 installs a real provider; every consumer of this type is already
//  wired correctly when that happens.
//

import XCTest
@testable import Muse

final class EditStackIndexTests: XCTestCase {
    override func tearDown() {
        EditStackIndex.installProvider(nil)
        super.tearDown()
    }

    func testNilProviderReturnsNilHashAndSize() {
        let url = URL(fileURLWithPath: "/tmp/photo.jpg")
        XCTAssertNil(EditStackIndex.stackHash(for: url))
        XCTAssertNil(EditStackIndex.croppedSize(for: url))
    }

    func testInstalledProviderIsConsulted() {
        struct StubProvider: EditStackProviding {
            func stackHash(for url: URL) -> String? { "abc123" }
            func croppedSize(for url: URL) -> CGSize? { CGSize(width: 100, height: 200) }
        }
        EditStackIndex.installProvider(StubProvider())
        let url = URL(fileURLWithPath: "/tmp/photo.jpg")
        XCTAssertEqual(EditStackIndex.stackHash(for: url), "abc123")
        XCTAssertEqual(EditStackIndex.croppedSize(for: url), CGSize(width: 100, height: 200))
    }

    func testProviderRemovalRestoresIdentity() {
        struct StubProvider: EditStackProviding {
            func stackHash(for url: URL) -> String? { "abc123" }
            func croppedSize(for url: URL) -> CGSize? { nil }
        }
        EditStackIndex.installProvider(StubProvider())
        EditStackIndex.installProvider(nil)
        let url = URL(fileURLWithPath: "/tmp/photo.jpg")
        XCTAssertNil(EditStackIndex.stackHash(for: url))
    }
}
```

- [ ] **Step 2: Run, confirm failure**

  Run: `xcodebuild -project Muse/Muse.xcodeproj -scheme Muse test -only-testing:MuseTests/EditStackIndexTests`
  Expected: FAIL — type doesn't exist.

- [ ] **Step 3: Implement `EditStackIndex`**

```swift
//
//  EditStackIndex.swift
//  Muse
//
//  The identity of a file's non-destructive edit stack. nil = unedited
//  (original bytes). Identity function today (no provider installed);
//  Spec 04 installs the real (file, parent_dir)-keyed provider and every
//  consumer (ThumbnailCache, EffectiveDimensions, OutputRender) is already
//  correct. Keyed by URL, NOT files.id — an edit stack is per file LOCATION
//  like tags/notes, since files.content_hash is UNIQUE and a column there
//  would force one stack to be shared by the same photo in two folders.
//

import Foundation
import CoreGraphics

protocol EditStackProviding: Sendable {
    func stackHash(for url: URL) -> String?
    func croppedSize(for url: URL) -> CGSize?
}

enum EditStackIndex {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var provider: (any EditStackProviding)?

    static func stackHash(for url: URL) -> String? {
        lock.lock(); defer { lock.unlock() }
        return provider?.stackHash(for: url)
    }

    static func croppedSize(for url: URL) -> CGSize? {
        lock.lock(); defer { lock.unlock() }
        return provider?.croppedSize(for: url)
    }

    /// Test/Spec-04 seam: install the real provider.
    static func installProvider(_ p: (any EditStackProviding)?) {
        lock.lock(); defer { lock.unlock() }
        provider = p
    }
}
```

- [ ] **Step 4: Run tests, confirm pass**

- [ ] **Step 5: Commit**

```bash
git add "Muse/Muse/Models/EditStackIndex.swift" "Muse/MuseTests/EditStackIndexTests.swift"
git commit -m "feat: add EditStackIndex seam (identity function; Spec 04 installs real provider)"
```

---

### Task 14: `ThumbnailCache` cache key incorporates stack hash

**Files:**
- Modify: `Muse/Muse/Filesystem/ThumbnailCache.swift` (`cacheKey(url:size:scale:)`
  around line 341-350, `invalidate(_:)` around line 197-217)
- Create: `Muse/MuseTests/ThumbnailStackKeyTests.swift`

**Interfaces:**
- Consumes: `EditStackIndex.stackHash(for:)` (Task 13).
- Modifies existing: `ThumbnailCache.cacheKey(url:size:scale:)` signature is unchanged
  (still `(URL, CGSize, CGFloat) -> String`) — the stack hash is read internally, not
  passed as a parameter, so every existing call site keeps compiling unmodified.

- [ ] **Step 1: Write the failing tests**

```swift
//
//  ThumbnailStackKeyTests.swift
//  MuseTests
//
//  The cache key must incorporate the edit-stack hash when one exists, and
//  be byte-identical to the pre-change key when it doesn't — proving no
//  library-wide thumbnail regeneration happens on upgrade.
//

import XCTest
@testable import Muse

final class ThumbnailStackKeyTests: XCTestCase {
    override func tearDown() {
        EditStackIndex.installProvider(nil)
        super.tearDown()
    }

    func testKeyUnchangedWhenNoStackHash() {
        let url = URL(fileURLWithPath: "/tmp/photo.jpg")
        let size = CGSize(width: 320, height: 320)
        let before = ThumbnailCache.cacheKeyForTesting(url: url, size: size, scale: 2.0)

        struct NilProvider: EditStackProviding {
            func stackHash(for url: URL) -> String? { nil }
            func croppedSize(for url: URL) -> CGSize? { nil }
        }
        EditStackIndex.installProvider(NilProvider())
        let after = ThumbnailCache.cacheKeyForTesting(url: url, size: size, scale: 2.0)

        XCTAssertEqual(before, after, "nil stack hash must not change the raw key string")
    }

    func testKeyDiffersWhenStackHashDiffers() {
        let url = URL(fileURLWithPath: "/tmp/photo.jpg")
        let size = CGSize(width: 320, height: 320)

        struct HashProvider: EditStackProviding {
            let hash: String
            func stackHash(for url: URL) -> String? { hash }
            func croppedSize(for url: URL) -> CGSize? { nil }
        }
        EditStackIndex.installProvider(HashProvider(hash: "aaa"))
        let keyA = ThumbnailCache.cacheKeyForTesting(url: url, size: size, scale: 2.0)
        EditStackIndex.installProvider(HashProvider(hash: "bbb"))
        let keyB = ThumbnailCache.cacheKeyForTesting(url: url, size: size, scale: 2.0)

        XCTAssertNotEqual(keyA, keyB)
    }
}
```

  `cacheKeyForTesting` is a small test-only wrapper needed because `cacheKey` is
  `private` — add `#if DEBUG` internal exposure or a `@testable`-visible `internal`
  function. Since `cacheKey` is `private nonisolated static`, change its access level to
  `internal nonisolated static` (or add a thin `internal` wrapper named
  `cacheKeyForTesting` that just calls the private one) — prefer the wrapper to avoid
  loosening the real API's access level for non-test reasons.

- [ ] **Step 2: Run, confirm failure**

- [ ] **Step 3: Modify `cacheKey` to incorporate the stack hash**

  Replace the function body (keeping the signature and the standardized-path comment):

```swift
private nonisolated static func cacheKey(url: URL, size: CGSize, scale: CGFloat) -> String {
    var raw = "\(url.standardizedFileURL.path)|\(Int(size.width))x\(Int(size.height))@\(scale)"
    // Appended ONLY when a stack hash exists — the nil case must be
    // byte-identical to the pre-edit-aware key, or every cached PNG in every
    // library re-keys on upgrade (forcing a full-library thumbnail
    // regeneration). NOT "|<hash ?? "">" — that appends a trailing "|" even
    // when nil.
    if let stackHash = EditStackIndex.stackHash(for: url) {
        raw += "|\(stackHash)"
    }
    let hash = SHA256.hash(data: Data(raw.utf8))
    return hash.map { String(format: "%02x", $0) }.joined()
}

#if DEBUG
nonisolated static func cacheKeyForTesting(url: URL, size: CGSize, scale: CGFloat) -> String {
    cacheKey(url: url, size: size, scale: scale)
}
#endif
```

- [ ] **Step 4: Update `invalidate(_:)` to drop both stack variants**

  Read the current `invalidate(_:)` body (lines 197-217) in full before editing. It
  currently loops `Self.renderedVariants`, computing one `cacheKey` per variant. Change
  it to loop `renderedVariants × {current stack hash, nil}` so reverting an edit doesn't
  orphan the pre-edit PNGs:

```swift
static func invalidate(_ url: URL) {
    ImageHeaderSizeCache.invalidate(url)
    let currentHash = EditStackIndex.stackHash(for: url)
    let hashesToClear: [String?] = currentHash == nil ? [nil] : [currentHash, nil]
    for variant in Self.renderedVariants {
        for hashCase in hashesToClear {
            let key = keyForInvalidation(url: url, size: variant.size, scale: variant.scale, stackHashOverride: hashCase)
            memCache.removeObject(forKey: key as NSString)
            let path = diskPath(forKey: key)
            if fm.fileExists(atPath: path) {
                try? fm.removeItem(atPath: path)
            }
        }
    }
}
```

  This requires `cacheKey` to accept an optional override so `invalidate` can compute
  the key for a hash that ISN'T the currently-installed one (e.g. clearing the "nil"
  variant while a stack hash is currently active, or vice versa). Add an internal
  overload:

```swift
private nonisolated static func cacheKey(url: URL, size: CGSize, scale: CGFloat, stackHashOverride: String??) -> String {
    var raw = "\(url.standardizedFileURL.path)|\(Int(size.width))x\(Int(size.height))@\(scale)"
    let hash: String? = stackHashOverride ?? EditStackIndex.stackHash(for: url)
    if let hash { raw += "|\(hash)" }
    let hashed = SHA256.hash(data: Data(raw.utf8))
    return hashed.map { String(format: "%02x", $0) }.joined()
}
```

  Note the `stackHashOverride: String??` double-optional: outer optional = "was an
  override even passed," inner optional = "the hash value itself (nil = unedited)."
  Simplify naming as needed once the actual existing `invalidate`/`removeItem`/
  `diskPath` helper names are confirmed by reading the real file — the above is
  illustrative of the required BEHAVIOR (loop both hash states × every variant), not a
  literal drop-in given the exact private helper names weren't all captured by the
  research pass. Read `ThumbnailCache.swift` lines 150-220 in full before implementing
  this step.

- [ ] **Step 5: Run the stack-key tests, confirm pass**

- [ ] **Step 6: Run the existing `ThumbnailVariantTests` for regressions**

  Run: `xcodebuild -project Muse/Muse.xcodeproj -scheme Muse test -only-testing:MuseTests/ThumbnailVariantTests`
  Expected: PASS — the `renderedVariants` discipline test must be unaffected by this
  change (it tests variant coverage, not key content).

- [ ] **Step 7: Manual regression check — confirm no mass thumbnail regeneration**

  Run the app against an existing populated library (or a test fixture folder with
  cached thumbnails from before this change). Confirm existing cached PNGs on disk are
  still hit (no visible "everything re-thumbnails" flash on folder open) — this is the
  "no mass-regeneration on upgrade" guarantee the nil-case test proves at the unit
  level; this step proves it at the app level per the `verify-runtime-not-just-tests`
  practice.

- [ ] **Step 8: Commit**

```bash
git add "Muse/Muse/Filesystem/ThumbnailCache.swift" "Muse/MuseTests/ThumbnailStackKeyTests.swift"
git commit -m "feat: incorporate edit-stack hash into ThumbnailCache key; invalidate both stack variants"
```

---

### Task 15: `EffectiveDimensions` seam + consumer conversions

**Files:**
- Create: `Muse/Muse/Components/EffectiveDimensions.swift`
- Create: `Muse/MuseTests/EffectiveDimensionsTests.swift`
- Modify: `Muse/Muse/Views/GridView.swift` (`TileView.drawnAspectRatio`, lines ~887-893)
- Modify: `Muse/Muse/Views/Viewer/HeroStage.swift` (`resolveHeaderSize()` lines 233-244,
  the >40MP gate lines 458-460)
- Modify: `Muse/Muse/Viewers/FileMetadata.swift` (Dimensions/MP row, lines ~291-296)
- Modify: `Muse/Muse/Views/AspectRatioCache.swift` (`imageIOAspect` cold path, lines
  186-196 — confirm whether this needs to consult `EffectiveDimensions` directly or
  whether it's fine as-is since it's the header-read fallback; per spec §3.3 it's in the
  converted-consumers table, so it needs the check added)

**Interfaces:**
- Consumes: `EditStackIndex.croppedSize(for:)` (Task 13), `ImageHeaderSizeCache.cached(_:)`
  / `.resolve(_:)` (existing).
- Produces: `EffectiveDimensions.cached(_ url: URL) -> CGSize?` (no I/O, safe from a view
  body), `EffectiveDimensions.resolve(_ url: URL) -> CGSize?` (may do I/O, off-main
  only), `EffectiveDimensions.aspect(_ url: URL) -> CGFloat?`.

- [ ] **Step 1: Write the failing tests**

```swift
//
//  EffectiveDimensionsTests.swift
//  MuseTests
//
//  Falls back to ImageHeaderSizeCache; a crop (via EditStackIndex) overrides
//  it. Orientation stays ImageHeaderSizeCache's job — this layer sits above.
//

import XCTest
@testable import Muse

final class EffectiveDimensionsTests: XCTestCase {
    override func tearDown() {
        EditStackIndex.installProvider(nil)
        let url = URL(fileURLWithPath: "/tmp/edt-photo.jpg")
        ImageHeaderSizeCache.invalidate(url)
        super.tearDown()
    }

    func testFallsBackToHeaderCacheWhenNoCrop() {
        let url = URL(fileURLWithPath: "/tmp/edt-photo.jpg")
        ImageHeaderSizeCache.record(url, width: 4000, height: 3000)
        XCTAssertEqual(EffectiveDimensions.cached(url), CGSize(width: 4000, height: 3000))
    }

    func testCropOverridesHeaderCache() {
        let url = URL(fileURLWithPath: "/tmp/edt-photo.jpg")
        ImageHeaderSizeCache.record(url, width: 4000, height: 3000)
        struct CropProvider: EditStackProviding {
            func stackHash(for url: URL) -> String? { "h1" }
            func croppedSize(for url: URL) -> CGSize? { CGSize(width: 2000, height: 3000) }
        }
        EditStackIndex.installProvider(CropProvider())
        XCTAssertEqual(EffectiveDimensions.cached(url), CGSize(width: 2000, height: 3000))
    }

    func testAspectDerivesFromEffectiveSize() {
        let url = URL(fileURLWithPath: "/tmp/edt-photo.jpg")
        ImageHeaderSizeCache.record(url, width: 4000, height: 2000)
        XCTAssertEqual(EffectiveDimensions.aspect(url), 2.0)
    }

    func testAspectNilWhenNoDataAvailable() {
        let url = URL(fileURLWithPath: "/tmp/edt-nonexistent.jpg")
        XCTAssertNil(EffectiveDimensions.aspect(url))
    }
}
```

  Confirm `ImageHeaderSizeCache.record(_:width:height:)` is the actual public spelling
  (research quoted `record(_ url: URL, width: Int, height: Int)`) before finalizing.

- [ ] **Step 2: Run, confirm failure**

- [ ] **Step 3: Implement `EffectiveDimensions`**

```swift
//
//  EffectiveDimensions.swift
//  Muse
//
//  The crop-aware layer above ImageHeaderSizeCache. ImageHeaderSizeCache
//  remains the single orientation-applied truth for the ORIGINAL file;
//  this is the only thing layout consumers should call, so a Spec-04 crop
//  is reflected everywhere (grid tile aspect, hero flight geometry, the
//  Info card) without touching each call site again.
//

import Foundation
import CoreGraphics

enum EffectiveDimensions {
    /// No I/O — safe to call from a SwiftUI view body.
    static func cached(_ url: URL) -> CGSize? {
        EditStackIndex.croppedSize(for: url) ?? ImageHeaderSizeCache.cached(url)
    }

    /// May perform I/O (a header read) on a cache miss — call off-main only.
    static func resolve(_ url: URL) -> CGSize? {
        EditStackIndex.croppedSize(for: url) ?? ImageHeaderSizeCache.resolve(url)
    }

    static func aspect(_ url: URL) -> CGFloat? {
        guard let size = cached(url) ?? resolve(url), size.height > 0 else { return nil }
        return size.width / size.height
    }
}
```

  Confirm `ImageHeaderSizeCache.resolve(_:)` exists with this exact signature (research
  noted it as "cached-or-header-read" but didn't quote its body) — if its actual name or
  async-ness differs, adjust `EffectiveDimensions.resolve` to match rather than
  inventing a divergent contract.

- [ ] **Step 4: Run tests, confirm pass**

- [ ] **Step 5: Convert `GridView.swift`'s `drawnAspectRatio`**

  Read lines 880-900 in full first. Replace the body to prefer `EffectiveDimensions`:

```swift
private var drawnAspectRatio: CGFloat {
    if let ratio = EffectiveDimensions.aspect(file.url) {
        return ratio
    }
    return imageAspect > 0 ? 1 / imageAspect : 1
}
```

- [ ] **Step 6: Convert `HeroStage.swift`'s `resolveHeaderSize()` and the >40MP gate**

  Read lines 225-260 and 450-465 in full first (the exact surrounding logic wasn't
  fully quoted by research — confirm before editing). Replace direct
  `ImageHeaderSizeCache.cached(u)`/`.resolve` reads used for LAYOUT purposes (flight
  take-off/landing rect, the mid-res decode gate) with `EffectiveDimensions.cached(u)`/
  `.resolve(u)`. Do **not** touch any call in this file that reads the header for
  DECODE-BUDGET purposes (there shouldn't be one in `HeroStage` — that's
  `ThumbnailCache.declaredPixelCount`'s job, unaffected by this task) — per §3.3 of
  spec-01, `ImageHeaderSizeCache`'s direct callers stay for decode-budget and
  analysis-original-bytes purposes; `HeroStage`'s callers are layout, so they convert.

- [ ] **Step 7: Convert `FileMetadata.swift`'s Dimensions/MP row**

  Read lines 280-300 in full. The Info card must state what the user SEES (per spec),
  so change the dimensions source to prefer `EffectiveDimensions`:

```swift
let dimensions = EffectiveDimensions.cached(url) ?? /* existing fallback expression */
```

  Preserve the existing fallback chain for when neither the header cache nor a crop
  provider has data — read the surrounding function (`withFileFacts` or similar) to
  confirm exactly what `dimensions` was previously sourced from before making this
  substitution minimal and correct.

- [ ] **Step 8: Convert `AspectRatioCache.swift`'s cold path**

  Read lines 100-200 in full (the `imageIOAspect` function at 186-196 is the pure
  header-read fallback called from inside a `TaskGroup` at line 116). Per spec §3.3,
  `EffectiveDimensions` should be consulted FIRST so a cropped file overrides the DB
  path, with `AspectRatioCache`'s own `files.width/height` DB read staying
  original-dimensioned. Add the check at the call site (line 116's `TaskGroup` body),
  not inside `imageIOAspect` itself (which is correctly a pure header reader and should
  stay that way — it's the caller's job to prefer the effective value first):

```swift
group.addTask {
    if let effective = EffectiveDimensions.cached(url), effective.height > 0 {
        return (index, effective.width / effective.height)
    }
    return (index, Self.imageIOAspect(url: url))
}
```

  Adjust to match the actual surrounding tuple/index shape in the real `TaskGroup` body
  — read it in full before editing.

- [ ] **Step 9: Build and run the affected UI paths manually**

  Run: `xcodebuild -project Muse/Muse.xcodeproj -scheme Muse -configuration Debug build`
  Then launch the app, open a folder with images, confirm the grid renders with correct
  aspect ratios (no visual regression — since no provider is installed yet, this must
  be pixel-identical to pre-change behavior). Open the hero viewer on a few images and
  confirm the flight animation and Info card dimensions are unchanged.

- [ ] **Step 10: Run the full existing regression suites named in spec §6**

  Run: `xcodebuild -project Muse/Muse.xcodeproj -scheme Muse test -only-testing:MuseTests/ImageHeaderSizeCacheTests -only-testing:MuseTests/FileMetadataLoadTests -only-testing:MuseTests/CollectionPDFLayoutTests`
  Expected: all PASS, unchanged.

- [ ] **Step 11: Commit**

```bash
git add "Muse/Muse/Components/EffectiveDimensions.swift" "Muse/MuseTests/EffectiveDimensionsTests.swift" \
        "Muse/Muse/Views/GridView.swift" "Muse/Muse/Views/Viewer/HeroStage.swift" \
        "Muse/Muse/Viewers/FileMetadata.swift" "Muse/Muse/Views/AspectRatioCache.swift"
git commit -m "feat: add EffectiveDimensions seam; convert layout consumers off ImageHeaderSizeCache directly"
```

---

### Task 16: `OutputRender` export choke point

**Files:**
- Create: `Muse/Muse/Export/OutputRender.swift`
- Create: `Muse/MuseTests/OutputRenderTests.swift`
- Modify: `Muse/Muse/Export/CollectionPDFExporter.swift` (`imageIOThumbnail`, lines
  ~197-209, and the `urls` mapping at the caller)
- Modify: `Muse/Muse/Sharing/Drive/DriveClient.swift` (`uploadFile`, line 62)
- Modify: `Muse/Muse/Sharing/Drive/ImageMetadataStripper.swift` (`strip`, line 121)
- Modify: `Muse/Muse/Views/SelectionMenu.swift` (line 168)
- Modify: `Muse/Muse/Views/Viewer/ShareButton.swift` (line 46)

**Interfaces:**
- Produces: `RenderedOutput` (struct, `fileprivate init`), `OutputRender.forOutput(_
  url: URL) throws -> RenderedOutput`, `OutputRender.forOutput(_ urls: [URL]) throws ->
  [RenderedOutput]`, `OutputRender.image(_ out: RenderedOutput, maxPixel: Int) ->
  CGImage?` — consumed by every export/share call site.

- [ ] **Step 1: Write the failing tests**

```swift
//
//  OutputRenderTests.swift
//  MuseTests
//
//  forOutput is identity today (renders original bytes). RenderedOutput
//  cannot be constructed outside OutputRender.swift — the ONLY way this
//  test file obtains one is by calling forOutput, which is the compile-time
//  proof the export choke point can't be bypassed.
//

import XCTest
@testable import Muse

final class OutputRenderTests: XCTestCase {
    func testForOutputIsIdentityToday() throws {
        let url = URL(fileURLWithPath: "/tmp/output-test.jpg")
        let out = try OutputRender.forOutput(url)
        XCTAssertEqual(out.url, url)
        XCTAssertNil(out.stackHash)
    }

    func testForOutputArrayPreservesOrder() throws {
        let urls = [
            URL(fileURLWithPath: "/tmp/a.jpg"),
            URL(fileURLWithPath: "/tmp/b.jpg"),
        ]
        let outs = try OutputRender.forOutput(urls)
        XCTAssertEqual(outs.map(\.url), urls)
    }

    func testForOutputCarriesStackHashWhenProviderInstalled() throws {
        struct StubProvider: EditStackProviding {
            func stackHash(for url: URL) -> String? { "zzz" }
            func croppedSize(for url: URL) -> CGSize? { nil }
        }
        EditStackIndex.installProvider(StubProvider())
        defer { EditStackIndex.installProvider(nil) }

        let url = URL(fileURLWithPath: "/tmp/output-test.jpg")
        let out = try OutputRender.forOutput(url)
        XCTAssertEqual(out.stackHash, "zzz")
    }
}
```

- [ ] **Step 2: Run, confirm failure**

- [ ] **Step 3: Implement `OutputRender`**

```swift
//
//  OutputRender.swift
//  Muse
//
//  Every path that ships pixels out of the app renders through here. Today
//  it's identity (originals pass through unrendered); Spec 04 renders the
//  edit stack when one exists. RenderedOutput's fileprivate init is the
//  enforcement — a new export/share/publish path physically cannot compile
//  without going through OutputRender. Backup is the one deliberate
//  exclusion: it restores originals by content hash, and rendering edits
//  into it would corrupt the restore.
//

import Foundation
import CoreGraphics
import ImageIO

/// Bytes approved for leaving the app. The ONLY way to obtain one is
/// OutputRender.
struct RenderedOutput: Sendable {
    let url: URL          // file to read (the original today; a rendered temp later)
    let stackHash: String?
    fileprivate init(url: URL, stackHash: String?) {
        self.url = url
        self.stackHash = stackHash
    }
}

enum OutputRender {
    static func forOutput(_ url: URL) throws -> RenderedOutput {
        RenderedOutput(url: url, stackHash: EditStackIndex.stackHash(for: url))
    }

    static func forOutput(_ urls: [URL]) throws -> [RenderedOutput] {
        try urls.map { try forOutput($0) }
    }

    /// Decoded, downsampled image for a rendering export (PDF).
    static func image(_ out: RenderedOutput, maxPixel: Int) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(out.url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary)
    }
}
```

- [ ] **Step 4: Run tests, confirm pass**

- [ ] **Step 5: Convert `CollectionPDFExporter`**

  Read the full `imageIOThumbnail` function (lines 197-209) and the `urls`
  consumption/`TaskGroup` (lines 89-106) before editing. Change `imageIOThumbnail` to
  take `RenderedOutput` instead of `URL`:

```swift
private static func imageIOThumbnail(_ out: RenderedOutput, maxPixel: Int) -> CGImage? {
    guard let src = CGImageSourceCreateWithURL(out.url as CFURL, nil),
          ThumbnailCache.withinDecodeBudget(src) else { return nil }
    return OutputRender.image(out, maxPixel: maxPixel)
}
```

  At the top of `makePDF(urls:...)` (or wherever `urls: [URL]` first enters the
  exporter, around line 52), map once up front:

```swift
let rendered = try OutputRender.forOutput(urls)
```

  Then thread `rendered` (an array of `RenderedOutput`, index-aligned with the original
  `urls`) through the existing `TaskGroup` in place of `urls`, updating index-keyed
  slot/image building accordingly. The QuickLook/video/audio fallback paths (noted in
  the spec as NOT rendering paths — a video frame or type icon carries no edit stack)
  keep taking `URL` — locate those fallback call sites in the same file and leave them
  untouched, extracting `.url` from the `RenderedOutput` where a fallback still needs a
  bare `URL` for `AVAsset`/`QLThumbnailGenerator` construction.

- [ ] **Step 6: Convert `DriveClient.uploadFile` and `ImageMetadataStripper.strip`**

  Change signatures:
```swift
// DriveClient.swift
func uploadFile(_ out: RenderedOutput, name: String, mime: String, parent: String) async throws -> String {
    let stripped = try ImageMetadataStripper.strip(out, mime: mime)
    // ... rest of upload unchanged, reading `stripped.data`/whatever the
    // existing Output type exposes ...
}
```
```swift
// ImageMetadataStripper.swift
static func strip(_ out: RenderedOutput, mime: String) throws -> Output {
    // existing body, replacing every `url` read with `out.url` —
    // the strip still runs on the RENDERED bytes: render first (today,
    // identity), strip second, so a future edit can't reintroduce
    // metadata past the stripper.
}
```

  Read both functions in full before converting — `strip`'s existing body reads `Data(
  contentsOf: url, options: .mappedIfSafe)` and several other `url`-keyed operations
  (lines 100-160ish per research); every one becomes `out.url`. Find every CALLER of
  `uploadFile` and `strip` (likely inside `Sharing/Drive/DriveShareService.swift` or
  similar publish-flow orchestrator — grep `uploadFile(` and `ImageMetadataStripper.strip(`
  across `Muse/Muse/Sharing`) and update each call site to first obtain a
  `RenderedOutput` via `OutputRender.forOutput(url)`.

- [ ] **Step 7: Convert `SelectionMenu.swift` and `ShareButton.swift`**

```swift
// SelectionMenu.swift, was: NSSharingServicePicker(items: fileURLs)
let rendered = try OutputRender.forOutput(fileURLs)
let picker = NSSharingServicePicker(items: rendered.map(\.url))
```
```swift
// ShareButton.swift, was: NSSharingServicePicker(items: [url])
let rendered = try OutputRender.forOutput(url)
let picker = NSSharingServicePicker(items: [rendered.url])
```

  Handle the `throws` — both call sites are inside button/menu actions, so wrap in
  `do/catch` or `try?` matching the surrounding error-handling style already used
  nearby in each file (read the immediate surrounding function before choosing).

- [ ] **Step 8: Confirm `DriveShareForm.swift` is untouched**

  Per research, this file shares a text link (not pixels) via `DriveConfig.shareBaseURL`
  — the actual pixel upload happens through `DriveClient.uploadFile` called from
  elsewhere. Grep the file to confirm no `NSSharingServicePicker`/raw `URL` pixel path
  exists inside it; if none does (expected), no change needed here — this step is a
  verification, not an edit.

- [ ] **Step 9: Add a doc-comment note to `Backup/` explaining the exclusion**

  Find the top-level file in `Muse/Muse/Backup/` that orchestrates restore (likely
  `BackupRestorer.swift` or similar). Add a short doc comment near its file read/write
  path stating explicitly that Backup is NOT an OutputRender consumer — it restores
  originals and their metadata by content hash, and rendering edits into it would
  corrupt the restore. This mirrors `OutputRender.swift`'s own header comment (Step 3)
  so a future reader finds the exclusion from either direction.

- [ ] **Step 10: Build and run the affected flows manually**

  Run: `xcodebuild -project Muse/Muse.xcodeproj -scheme Muse -configuration Debug build`
  Then in the running app: export a small collection to PDF and confirm it opens
  correctly; use the hero viewer's Share button on one image and confirm the share
  sheet appears with the correct file; if a Google account is signed in, publish a
  tiny test collection via Drive share and confirm the resulting page shows the
  correct (still metadata-stripped) image.

- [ ] **Step 11: Run the existing `DriveMultipartTests` and any PDF export tests**

  Run: `xcodebuild -project Muse/Muse.xcodeproj -scheme Muse test -only-testing:MuseTests/DriveMultipartTests -only-testing:MuseTests/CollectionPDFLayoutTests`
  Expected: PASS.

- [ ] **Step 12: Commit**

```bash
git add "Muse/Muse/Export/OutputRender.swift" "Muse/MuseTests/OutputRenderTests.swift" \
        "Muse/Muse/Export/CollectionPDFExporter.swift" \
        "Muse/Muse/Sharing/Drive/DriveClient.swift" "Muse/Muse/Sharing/Drive/ImageMetadataStripper.swift" \
        "Muse/Muse/Views/SelectionMenu.swift" "Muse/Muse/Views/Viewer/ShareButton.swift"
git commit -m "feat: add OutputRender export choke point; convert PDF/Drive/share call sites"
```

---

### Task 17: Add the three new durable constraints to `CLAUDE.md`

**Files:**
- Modify: `CLAUDE.md`

**Interfaces:** None — documentation only, records the seams built in Tasks 13-16.

- [ ] **Step 1: Add the three bullets**

  In "### Durable constraints & gotchas (DO NOT BREAK)", add:

  1. **Everything that leaves the app goes through `OutputRender`.**
     `RenderedOutput`'s `fileprivate` init is the enforcement; don't relax it, don't
     add a public initializer, and don't let a new share/export/publish path take a
     bare `URL`. Backup is the one deliberate exclusion (it restores originals).
  2. **Layout reads `EffectiveDimensions`, analysis and decode budgets read
     `ImageHeaderSizeCache`.** The header cache stays the single orientation truth;
     `EffectiveDimensions` is the crop-aware layer above it. `files.width/height`,
     `analyzed_hash` and `Indexer.reconcile` stay keyed on ORIGINAL bytes — an edit
     never changes content identity.
  3. **The thumbnail cache key carries the edit-stack hash, and `invalidate` drops
     both the current and the original stack's variants.** Dropping only one leaves
     live orphaned PNGs that resurface on revert.

- [ ] **Step 2: Commit**

```bash
git add CLAUDE.md
git commit -m "docs: record edit-aware seam durable constraints (OutputRender, EffectiveDimensions, ThumbnailCache stack key)"
```

---

## Section D — Commercial plumbing (StoreKit 2)

### Task 18: `Commerce/CommerceConfig.swift` + `Entitlements` type

**Files:**
- Create: `Muse/Muse/Commerce/CommerceConfig.swift`

**Interfaces:**
- Produces: `CommerceConfig.unlockProductID: String`,
  `CommerceConfig.sharingYearlyProductID: String`,
  `CommerceConfig.announcementsURL: URL`, `struct Entitlements { var unlocked: Bool; var
  sharing: Bool }` — consumed by Task 19 (`CommerceStore`) and Task 22
  (`AnnouncementStore`).

- [ ] **Step 1: Create the directory and config file**

```bash
mkdir -p "Muse/Muse/Commerce"
```

```swift
//
//  CommerceConfig.swift
//  Muse
//
//  Product identifiers and endpoints. The only place these strings appear —
//  every StoreKit/announcements call site reads from here, never a literal.
//

import Foundation

enum CommerceConfig {
    static let unlockProductID = "com.tarrats.Muse.unlock"
    static let sharingYearlyProductID = "com.tarrats.Muse.sharing.yearly"
    static let sharingSubscriptionGroupID = "sharing"

    /// Same Cloudflare Pages host that serves the Drive share page — no new
    /// infrastructure, no new domain.
    static let announcementsURL = URL(string: "\(DriveConfig.shareBaseURL)/announcements.json")!
}

struct Entitlements: Equatable, Sendable {
    var unlocked: Bool = false
    var sharing: Bool = false
}
```

  Confirm `DriveConfig.shareBaseURL` is accessible from this new file (same module, no
  import needed beyond Foundation — `DriveConfig` is presumably `internal`, confirm by
  reading `Muse/Muse/Sharing/Drive/DriveConfig.swift`'s access modifiers).

- [ ] **Step 2: Build**

  Run: `xcodebuild -project Muse/Muse.xcodeproj -scheme Muse -configuration Debug build`
  Expected: `BUILD SUCCEEDED` (nothing consumes this yet, but it must compile standalone).

- [ ] **Step 3: Commit**

```bash
git add "Muse/Muse/Commerce/CommerceConfig.swift"
git commit -m "feat: add Commerce module scaffold (product ids, Entitlements type)"
```

---

### Task 19: `Commerce/TrialGate.swift` — pure, tested trial-state logic

**Files:**
- Create: `Muse/Muse/Commerce/TrialGate.swift`
- Create: `Muse/MuseTests/TrialGateTests.swift`

**Interfaces:**
- Produces: `struct TrialPolicy { var duration: TimeInterval = 14 * 86400; var enforced:
  Bool = false }`, `enum TrialState { case unlocked; case trial(daysLeft: Int); case
  expired }`, `TrialGate.state(now:firstLaunch:entitled:policy:) -> TrialState` —
  consumed by Task 20 (`CommerceStore`, for exposing trial UI state) and, later, Spec 09
  (not this plan).

- [ ] **Step 1: Write the failing tests**

```swift
//
//  TrialGateTests.swift
//  MuseTests
//
//  Pure trial-state resolution. `enforced: false` (this spec's default —
//  pricing is OPEN, Spec 09) must never expire, so the UI can read state
//  without anything being blocked.
//

import XCTest
@testable import Muse

final class TrialGateTests: XCTestCase {
    let day: TimeInterval = 86_400

    func testEntitledShortCircuitsToUnlockedRegardlessOfClock() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let state = TrialGate.state(now: now, firstLaunch: now, entitled: true,
                                     policy: TrialPolicy(duration: 14 * day, enforced: true))
        XCTAssertEqual(state, .unlocked)
    }

    func testUnenforcedNeverExpiresEvenPastDuration() {
        let firstLaunch = Date(timeIntervalSince1970: 0)
        let now = firstLaunch.addingTimeInterval(365 * day)
        let state = TrialGate.state(now: now, firstLaunch: firstLaunch, entitled: false,
                                     policy: TrialPolicy(duration: 14 * day, enforced: false))
        switch state {
        case .expired: XCTFail("unenforced policy must never expire")
        default: break
        }
    }

    func testEnforcedExpiresPastDuration() {
        let firstLaunch = Date(timeIntervalSince1970: 0)
        let now = firstLaunch.addingTimeInterval(15 * day)
        let state = TrialGate.state(now: now, firstLaunch: firstLaunch, entitled: false,
                                     policy: TrialPolicy(duration: 14 * day, enforced: true))
        XCTAssertEqual(state, .expired)
    }

    func testEnforcedWithinDurationReportsDaysLeft() {
        let firstLaunch = Date(timeIntervalSince1970: 0)
        let now = firstLaunch.addingTimeInterval(3 * day)
        let state = TrialGate.state(now: now, firstLaunch: firstLaunch, entitled: false,
                                     policy: TrialPolicy(duration: 14 * day, enforced: true))
        XCTAssertEqual(state, .trial(daysLeft: 11))
    }

    func testMissingAnchorTreatedAsFirstLaunchNow() {
        // No anchor recorded yet (very first run) — must not crash or read
        // as expired; treat as day 0 of the trial.
        let now = Date(timeIntervalSince1970: 1_000_000)
        let state = TrialGate.state(now: now, firstLaunch: nil, entitled: false,
                                     policy: TrialPolicy(duration: 14 * day, enforced: true))
        XCTAssertEqual(state, .trial(daysLeft: 14))
    }

    func testClockRollbackDoesNotGrantExtraDays() {
        // now < firstLaunch (clock set backward) must clamp to daysLeft ==
        // duration, not go negative/huge.
        let firstLaunch = Date(timeIntervalSince1970: 100_000)
        let now = Date(timeIntervalSince1970: 0)
        let state = TrialGate.state(now: now, firstLaunch: firstLaunch, entitled: false,
                                     policy: TrialPolicy(duration: 14 * day, enforced: true))
        XCTAssertEqual(state, .trial(daysLeft: 14))
    }

    func testDayBoundaryRoundsDownRemainingDays() {
        let firstLaunch = Date(timeIntervalSince1970: 0)
        let now = firstLaunch.addingTimeInterval(13.5 * day)
        let state = TrialGate.state(now: now, firstLaunch: firstLaunch, entitled: false,
                                     policy: TrialPolicy(duration: 14 * day, enforced: true))
        XCTAssertEqual(state, .trial(daysLeft: 0))
    }
}
```

  Add `TrialState: Equatable` conformance so `XCTAssertEqual` on it works.

- [ ] **Step 2: Run, confirm failure**

- [ ] **Step 3: Implement `TrialGate`**

```swift
//
//  TrialGate.swift
//  Muse
//
//  MAS forbids paid-upfront-with-trial, so the structure is forced: free
//  download -> trial -> unlock IAP. Policy is OPEN (Spec 09); this gate
//  computes state so the UI can read it, with `enforced: false` as the
//  shipped default until pricing is decided — nothing is blocked by this
//  spec.
//

import Foundation

struct TrialPolicy: Sendable {
    var duration: TimeInterval = 14 * 86_400
    var enforced: Bool = false
}

enum TrialState: Equatable, Sendable {
    case unlocked
    case trial(daysLeft: Int)
    case expired
}

enum TrialGate {
    static func state(now: Date, firstLaunch: Date?, entitled: Bool,
                       policy: TrialPolicy) -> TrialState {
        if entitled { return .unlocked }
        let anchor = firstLaunch ?? now
        let elapsed = max(0, now.timeIntervalSince(anchor))
        let remaining = policy.duration - elapsed
        if remaining <= 0 {
            return policy.enforced ? .expired : .trial(daysLeft: 0)
        }
        let daysLeft = Int(remaining / 86_400)
        return .trial(daysLeft: daysLeft)
    }
}
```

- [ ] **Step 4: Run tests, confirm pass**

- [ ] **Step 5: Commit**

```bash
git add "Muse/Muse/Commerce/TrialGate.swift" "Muse/MuseTests/TrialGateTests.swift"
git commit -m "feat: add TrialGate (pure trial-state resolution, ships unenforced)"
```

---

### Task 20: `Commerce/CommerceStore.swift` — StoreKit 2 + Keychain anchor + offline cache

**Files:**
- Create: `Muse/Muse/Commerce/CommerceStore.swift`
- Create: `Muse/Muse/Commerce/CommerceCache.swift`
- Create: `Muse/MuseTests/CommerceEntitlementTests.swift`
- Modify: `Muse/Muse/MuseApp.swift` (inject `commerceStore` alongside `googleAuth`,
  lines ~22, 100)

**Interfaces:**
- Consumes: `CommerceConfig` (Task 18), StoreKit 2 (`Product`, `Transaction`,
  `AppStore`), the existing Keychain access pattern used by Drive tokens (find it —
  likely `Muse/Muse/Sharing/Drive/KeychainTokenStore.swift` or similar; reuse its access
  class `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` rather than reinventing
  Keychain code).
- Produces: `@MainActor final class CommerceStore: ObservableObject` with `@Published
  private(set) var entitlements: Entitlements`, `products() async ->
  [Product]`, `purchase(_ id: String) async`, `restore() async`, `refresh() async`,
  `trialState(now: Date) -> TrialState` — consumed by Task 21 (Settings surface).

- [ ] **Step 1: Write the pure entitlement-resolution tests first**

  `CommerceEntitlementTests` targets the PURE parts that don't require a live
  StoreKit environment (StoreKit's `Transaction`/`Product` types can't be trivially
  constructed in a unit test without `StoreKitTest`/`SKTestSession` — if the codebase
  has no existing StoreKit test harness, keep this test file scoped to what's testable
  without one):

```swift
//
//  CommerceEntitlementTests.swift
//  MuseTests
//
//  CommerceCache is permissive-only: it can grant an entitlement StoreKit
//  hasn't confirmed yet (offline tolerance), and must never revoke one on
//  its own — revocation happens only on a verified StoreKit read that
//  lacks the entitlement.
//

import XCTest
@testable import Muse

final class CommerceEntitlementTests: XCTestCase {
    func testCacheGrantsAreLocalOnly() {
        var cache = CommerceCache(unlocked: false, sharing: false)
        cache.grant(unlocked: true)
        XCTAssertTrue(cache.unlocked)
    }

    func testCacheNeverSelfRevokes() {
        var cache = CommerceCache(unlocked: true, sharing: false)
        // Merging an entitlement snapshot that LACKS unlocked must not
        // clear it locally — only an explicit `.revoke` (driven by a
        // verified StoreKit read) does.
        cache.merge(remoteGrants: Entitlements(unlocked: false, sharing: false))
        XCTAssertTrue(cache.unlocked, "merge must be permissive-only (grant-or-keep, never auto-revoke)")
    }

    func testExplicitRevokeClearsEntitlement() {
        var cache = CommerceCache(unlocked: true, sharing: false)
        cache.revoke(unlocked: true)
        XCTAssertFalse(cache.unlocked)
    }
}
```

  This requires `CommerceCache` to be a small, pure, mutable struct (not the
  `UserDefaults`/Keychain-backed object itself) with `grant`/`merge`/`revoke` methods —
  design it as the pure logic core that `CommerceStore` wraps around actual
  persistence, matching the codebase's convention of separating pure logic from I/O
  (e.g. `AnnouncementFeed.parse` vs. the fetch, per Task 22).

- [ ] **Step 2: Run, confirm failure**

- [ ] **Step 3: Implement `CommerceCache`**

```swift
//
//  CommerceCache.swift
//  Muse
//
//  Permissive-only local mirror of entitlements: can grant ahead of a
//  verified StoreKit read (offline tolerance — a purchased user on a
//  plane is never locked out while StoreKit warms up), never revokes on
//  its own. Revocation only follows an explicit verified-absence signal.
//  Persisted via UserDefaults (booleans) + Keychain (the unlock flag,
//  matching the Drive token access class).
//

import Foundation

struct CommerceCache: Equatable {
    private(set) var unlocked: Bool
    private(set) var sharing: Bool

    init(unlocked: Bool, sharing: Bool) {
        self.unlocked = unlocked
        self.sharing = sharing
    }

    mutating func grant(unlocked: Bool? = nil, sharing: Bool? = nil) {
        if let unlocked, unlocked { self.unlocked = true }
        if let sharing, sharing { self.sharing = true }
    }

    /// Permissive-only: only ever ADDS entitlements the remote snapshot
    /// grants; never removes one the remote snapshot happens not to list.
    mutating func merge(remoteGrants: Entitlements) {
        if remoteGrants.unlocked { unlocked = true }
        if remoteGrants.sharing { sharing = true }
    }

    /// The only way an entitlement is cleared — called only after a
    /// verified StoreKit read confirms its absence.
    mutating func revoke(unlocked: Bool = false, sharing: Bool = false) {
        if unlocked { self.unlocked = false }
        if sharing { self.sharing = false }
    }

    var entitlements: Entitlements { Entitlements(unlocked: unlocked, sharing: sharing) }
}
```

- [ ] **Step 4: Run tests, confirm pass**

- [ ] **Step 5: Find the existing Keychain access pattern and reuse it**

  Read `Muse/Muse/Sharing/Drive/GoogleOAuth.swift`'s `TokenStoring`/
  `KeychainTokenStore` (referenced in research at `GoogleOAuth.swift:16` — `init(store:
  TokenStoring = KeychainTokenStore())`). Find `KeychainTokenStore`'s actual file (grep
  `KeychainTokenStore` across `Muse/Muse/Sharing`) and confirm its access-class constant
  (`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, per `CLAUDE.md`'s durable
  constraints). `CommerceStore` needs a small Keychain wrapper for a first-launch-date
  anchor and the unlock-flag mirror — either reuse `KeychainTokenStore`'s generic
  read/write helpers if they're generic enough, or write a minimal parallel one in
  `Commerce/CommerceCache.swift` using the SAME access class. Do not invent a new
  Keychain access pattern.

- [ ] **Step 6: Implement `CommerceStore`**

```swift
//
//  CommerceStore.swift
//  Muse
//
//  Own store object (AppState is frozen) — injected as an
//  @EnvironmentObject exactly like GoogleOAuth. Offline-tolerant: reads a
//  local cache synchronously at launch, refreshes from StoreKit
//  asynchronously. No identifiers sent anywhere; no receipt posted to any
//  server; no appAccountToken.
//

import Foundation
import StoreKit

@MainActor
final class CommerceStore: ObservableObject {
    @Published private(set) var entitlements: Entitlements
    @Published private(set) var trialPolicy: TrialPolicy

    private var cache: CommerceCache
    private var updatesTask: Task<Void, Never>?
    private let firstLaunchAnchor: Date

    init() {
        let loadedCache = Self.loadCache()
        self.cache = loadedCache
        self.entitlements = loadedCache.entitlements
        self.trialPolicy = TrialPolicy() // duration 14d, enforced: false (this spec's default)
        self.firstLaunchAnchor = Self.loadOrCreateFirstLaunchAnchor()

        updatesTask = Task { [weak self] in
            for await update in Transaction.updates {
                await self?.handle(update)
            }
        }
        Task { [weak self] in await self?.refresh() }
    }

    deinit {
        updatesTask?.cancel()
    }

    func trialState(now: Date = Date()) -> TrialState {
        TrialGate.state(now: now, firstLaunch: firstLaunchAnchor,
                         entitled: entitlements.unlocked, policy: trialPolicy)
    }

    func products() async -> [Product] {
        (try? await Product.products(for: [
            CommerceConfig.unlockProductID, CommerceConfig.sharingYearlyProductID,
        ])) ?? []
    }

    func purchase(_ productID: String) async {
        guard let product = await products().first(where: { $0.id == productID }) else { return }
        guard let result = try? await product.purchase() else { return }
        switch result {
        case .success(let verification):
            await handle(verification)
        case .userCancelled, .pending:
            break
        @unknown default:
            break
        }
    }

    func restore() async {
        try? await AppStore.sync()
        await refresh()
    }

    func refresh() async {
        var remote = Entitlements()
        for await entitlement in Transaction.currentEntitlements {
            guard case .verified(let transaction) = entitlement else { continue }
            if transaction.productID == CommerceConfig.unlockProductID {
                remote.unlocked = true
            } else if transaction.productID == CommerceConfig.sharingYearlyProductID {
                remote.sharing = true
            }
        }
        cache.merge(remoteGrants: remote)
        // Explicit revoke only on a verified read that LACKS an
        // entitlement the cache currently grants.
        if !remote.unlocked, cache.unlocked, wasVerifiedAbsence: true {
            cache.revoke(unlocked: true)
        }
        entitlements = cache.entitlements
        Self.saveCache(cache)
    }

    private func handle(_ verification: VerificationResult<Transaction>) async {
        guard case .verified(let transaction) = verification else { return }
        if transaction.productID == CommerceConfig.unlockProductID {
            cache.grant(unlocked: true)
        } else if transaction.productID == CommerceConfig.sharingYearlyProductID {
            cache.grant(sharing: true)
        }
        entitlements = cache.entitlements
        Self.saveCache(cache)
        await transaction.finish()
    }

    // MARK: - Persistence (UserDefaults mirror + Keychain unlock flag)

    private static func loadCache() -> CommerceCache {
        let defaults = UserDefaults.standard
        let sharing = defaults.bool(forKey: "commerce.sharing")
        let unlocked = KeychainCommerceStore.readUnlockFlag() || defaults.bool(forKey: "commerce.unlocked")
        return CommerceCache(unlocked: unlocked, sharing: sharing)
    }

    private static func saveCache(_ cache: CommerceCache) {
        UserDefaults.standard.set(cache.sharing, forKey: "commerce.sharing")
        UserDefaults.standard.set(cache.unlocked, forKey: "commerce.unlocked")
        if cache.unlocked { KeychainCommerceStore.writeUnlockFlag(true) }
        else { KeychainCommerceStore.clearUnlockFlag() }
    }

    private static func loadOrCreateFirstLaunchAnchor() -> Date {
        // Earliest-wins: if a Keychain anchor and a UserDefaults mirror
        // disagree, use the earlier one; never move the anchor forward.
        let keychainDate = KeychainCommerceStore.readFirstLaunchAnchor()
        let defaultsDate = UserDefaults.standard.object(forKey: "commerce.firstLaunch") as? Date
        let earliest = [keychainDate, defaultsDate].compactMap { $0 }.min()
        let anchor = earliest ?? Date()
        if keychainDate == nil { KeychainCommerceStore.writeFirstLaunchAnchor(anchor) }
        if defaultsDate == nil { UserDefaults.standard.set(anchor, forKey: "commerce.firstLaunch") }
        return anchor
    }
}
```

  This is illustrative of the required BEHAVIOR — the `if !remote.unlocked, cache.unlocked,
  wasVerifiedAbsence: true` line has a syntax placeholder (`wasVerifiedAbsence:` isn't a
  real label) that must be replaced with real logic: the actual revoke condition is
  "the `Transaction.currentEntitlements` walk completed successfully (no thrown error)
  AND did not include the unlock product." Since the `for await` loop over
  `Transaction.currentEntitlements` doesn't naturally distinguish "walked and found
  nothing" from "walk failed," structure `refresh()` to track a `sawAnyEntitlement`
  bool or wrap the loop in a way that only calls `revoke` when the enumeration itself
  didn't throw. Finalize this against the actual StoreKit 2 API shape (verify
  `Transaction.currentEntitlements` is a non-throwing `AsyncSequence` — if so, absence
  after a full walk IS the verified-absence signal and the guard can simplify to `if
  !remote.unlocked && cache.unlocked { cache.revoke(unlocked: true) }`).

  Add a small `KeychainCommerceStore` enum (in `CommerceCache.swift` or a new
  `Commerce/KeychainCommerceStore.swift`) wrapping `readUnlockFlag`/`writeUnlockFlag`/
  `clearUnlockFlag`/`readFirstLaunchAnchor`/`writeFirstLaunchAnchor`, built on
  whatever generic Keychain read/write helper Step 5 found reusable from the Drive
  token store (`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` access class).

- [ ] **Step 7: Inject `CommerceStore` in `MuseApp.swift`**

  Following the `googleAuth` pattern exactly:

```swift
@StateObject private var commerceStore = CommerceStore()
```

  placed near line 22, and in the `WindowGroup`'s `ContentView()` modifier chain near
  line 100:

```swift
.environmentObject(commerceStore)
```

- [ ] **Step 8: Build**

  Run: `xcodebuild -project Muse/Muse.xcodeproj -scheme Muse -configuration Debug build`
  Expected: `BUILD SUCCEEDED`. `Product.products(for:)` will return empty (no App Store
  Connect records exist yet — owner step §8 of the spec) but this must not crash or
  hang; `CommerceStore.init()` must complete synchronously and cheaply regardless of
  network state (per the offline-tolerant design).

- [ ] **Step 9: Commit**

```bash
git add "Muse/Muse/Commerce/CommerceStore.swift" "Muse/Muse/Commerce/CommerceCache.swift" \
        "Muse/MuseTests/CommerceEntitlementTests.swift" "Muse/Muse/MuseApp.swift"
git commit -m "feat: add CommerceStore (StoreKit 2 + offline-tolerant entitlement cache)"
```

---

### Task 21: Settings surface — "Muse" commerce section + Redeem Code

**Files:**
- Modify: `Muse/Muse/Settings/SettingsView.swift` (new `Section`, added before or after
  the existing "Google Drive" section at lines 166-190)

**Interfaces:**
- Consumes: `CommerceStore` (Task 20, via `@EnvironmentObject`), `ModalButton`
  (existing, `Views/Modal/`).

- [ ] **Step 1: Add `@EnvironmentObject` and the new section**

  In `Muse/Muse/Settings/SettingsView.swift`, add near the existing `@EnvironmentObject
  private var googleAuth: GoogleOAuth` (line 16):

```swift
@EnvironmentObject private var commerceStore: CommerceStore
```

  Add a new `Section` before the "Google Drive" section (or after — match whatever
  visual ordering reads best; place it first since it's the primary commerce surface):

```swift
Section {
    HStack {
        Text(commerceStore.entitlements.unlocked
             ? String(localized: "Unlocked")
             : trialStatusLine)
        Spacer()
        if !commerceStore.entitlements.unlocked {
            ModalButton(title: String(localized: "Unlock")) {
                Task { await commerceStore.purchase(CommerceConfig.unlockProductID) }
            }
        }
        ModalButton(title: String(localized: "Restore Purchases")) {
            Task { await commerceStore.restore() }
        }
    }
    HStack {
        Text(String(localized: "Have a code?"))
        Spacer()
        ModalButton(title: String(localized: "Redeem Code…")) {
            NSWorkspace.shared.open(URL(string: "https://apps.apple.com/redeem")!)
        }
    }
    Toggle(String(localized: "Show announcements"), isOn: announcementsEnabledBinding)
} header: {
    Text("Muse")
} footer: {
    Text("Unlock the full app, or restore a previous purchase. Redeeming a promo code opens the App Store.")
        .font(.callout)
        .foregroundStyle(.secondary)
}
```

  Add the small computed helpers needed:

```swift
private var trialStatusLine: String {
    switch commerceStore.trialState() {
    case .unlocked: return String(localized: "Unlocked")
    case .trial(let daysLeft): return String(localized: "Trial — \(daysLeft) days left")
    case .expired: return String(localized: "Trial expired")
    }
}

private var announcementsEnabledBinding: Binding<Bool> {
    Binding(
        get: { AppSettings.announcementsEnabled },
        set: { UserDefaults.standard.set($0, forKey: AppSettings.announcementsEnabledKey) })
}
```

  Match the exact `ModalButton` initializer signature used by the existing Google Drive
  section (`ModalButton(title:)` with a trailing closure, per the research quote) — do
  not invent a different call shape.

- [ ] **Step 2: Build and manually verify in Settings**

  Run: `xcodebuild -project Muse/Muse.xcodeproj -scheme Muse -configuration Debug build`
  Launch the app, open Settings, confirm the new "Muse" section renders (showing "Trial
  — 14 days left" or similar, since `enforced: false` never actually blocks anything but
  the state still displays), the Unlock button attempts a purchase (fails gracefully
  with no App Store Connect record yet — confirm no crash), Restore Purchases runs
  without crashing, Redeem Code opens the App Store redemption page in a browser, and
  the announcements toggle persists across a Settings close/reopen.

- [ ] **Step 3: Commit**

```bash
git add "Muse/Muse/Settings/SettingsView.swift"
git commit -m "feat: add Muse commerce section to Settings (unlock, restore, redeem, announcements toggle)"
```

---

### Task 22: `Commerce/AnnouncementStore.swift` + `AnnouncementFeed` pure parser

**Files:**
- Create: `Muse/Muse/Commerce/AnnouncementFeed.swift` (pure parsing/selection logic)
- Create: `Muse/Muse/Commerce/AnnouncementStore.swift` (fetch + presentation state)
- Create: `Muse/MuseTests/AnnouncementFeedTests.swift`
- Modify: `Muse/Muse/Settings/AppSettings.swift` (add `announcementsEnabledKey` +
  `announcementsEnabled`, mirroring `showStarsOnGridKey`/`showStarsOnGrid`)
- Modify: `Muse/Muse/Models/AppState.swift` (OR into `modalPresented`, line ~528 — see
  note below on how the announcement card is actually presented without growing
  `AppState`)
- Modify: `Muse/Muse/ContentView.swift` (register the announcement card presentation)
- Modify: `Muse/Muse/MuseApp.swift` (inject `AnnouncementStore`, trigger the once-per-
  launch fetch)

**Interfaces:**
- Produces: `struct AnnouncementFeed: Codable { let version: Int; let messages:
  [Announcement] }`, `struct Announcement: Codable, Identifiable { let id: String; let
  title: String; let body: String; let url: String?; let minAppVersion: String? }`,
  `AnnouncementFeed.parse(_ data: Data) -> AnnouncementFeed?`,
  `AnnouncementFeed.unseen(_ feed: AnnouncementFeed, seen: Set<String>, appVersion:
  String) -> [Announcement]`, `@MainActor final class AnnouncementStore: ObservableObject`
  with `@Published private(set) var pending: Announcement?`, `func fetchIfNeeded() async`,
  `func dismiss(_ id: String)`.

- [ ] **Step 1: Write the failing pure-parser tests**

```swift
//
//  AnnouncementFeedTests.swift
//  MuseTests
//
//  Pure parse/selection logic, separated from the fetch so it's fully
//  unit-testable — matching every other pure component in this codebase.
//

import XCTest
@testable import Muse

final class AnnouncementFeedTests: XCTestCase {
    func testParsesValidFeed() {
        let json = """
        { "version": 1, "messages": [
          { "id": "a", "title": "Hello", "body": "World", "url": "https://example.com", "minAppVersion": "1.6" }
        ] }
        """.data(using: .utf8)!
        let feed = AnnouncementFeed.parse(json)
        XCTAssertEqual(feed?.messages.first?.id, "a")
    }

    func testRejectsInvalidJSON() {
        XCTAssertNil(AnnouncementFeed.parse(Data("not json".utf8)))
    }

    func testRejectsOversizedPayload() {
        // Capped at 64 KB before decode.
        let huge = Data(repeating: 0x41, count: 70_000)
        XCTAssertNil(AnnouncementFeed.parse(huge))
    }

    func testIgnoresUnknownVersion() {
        let json = """
        { "version": 99, "messages": [] }
        """.data(using: .utf8)!
        XCTAssertNil(AnnouncementFeed.parse(json))
    }

    func testUnseenFiltersAlreadySeenIDs() {
        let feed = AnnouncementFeed(version: 1, messages: [
            Announcement(id: "a", title: "A", body: "", url: nil, minAppVersion: nil),
            Announcement(id: "b", title: "B", body: "", url: nil, minAppVersion: nil),
        ])
        let unseen = AnnouncementFeed.unseen(feed, seen: ["a"], appVersion: "1.6")
        XCTAssertEqual(unseen.map(\.id), ["b"])
    }

    func testMinAppVersionGating() {
        let feed = AnnouncementFeed(version: 1, messages: [
            Announcement(id: "a", title: "A", body: "", url: nil, minAppVersion: "2.0"),
        ])
        let unseen = AnnouncementFeed.unseen(feed, seen: [], appVersion: "1.6")
        XCTAssertTrue(unseen.isEmpty, "a message requiring a newer app version must be withheld")
    }

    func testSanitizesHostileTitleAndBody() {
        let json = """
        { "version": 1, "messages": [
          { "id": "a", "title": "\\u202Eevil", "body": "hi\\u200Bthere", "url": null, "minAppVersion": null }
        ] }
        """.data(using: .utf8)!
        let feed = AnnouncementFeed.parse(json)
        XCTAssertFalse(feed?.messages.first?.title.contains("\u{202E}") ?? true)
        XCTAssertFalse(feed?.messages.first?.body.contains("\u{200B}") ?? true)
    }

    func testRejectsNonHTTPSURL() {
        let json = """
        { "version": 1, "messages": [
          { "id": "a", "title": "A", "body": "B", "url": "http://example.com", "minAppVersion": null }
        ] }
        """.data(using: .utf8)!
        let feed = AnnouncementFeed.parse(json)
        XCTAssertNil(feed?.messages.first?.url, "non-https urls must be dropped, not opened")
    }
}
```

  Find the existing sanitization helper used by the Drive share page's manifest
  decoding (bidi/zero-width/control-char stripping — per `CLAUDE.md`'s durable
  constraints, this exists somewhere in `Sharing/Drive/` for the share manifest, e.g. a
  `sanitizeText`-equivalent on the Swift side, or purely in the web page's JS — if the
  sanitization is JS-only (web/share side), this task needs a NEW Swift-side
  equivalent, since `AnnouncementFeed` is parsed in-app, not on a web page. Check for an
  existing Swift sanitizer before writing a new one; if none exists, add a small pure
  `AnnouncementSanitizer.strip(_:) -> String` function stripping bidi override
  characters (U+202A-U+202E, U+2066-U+2069), zero-width characters (U+200B-U+200D,
  U+FEFF), and C0/C1 control characters, with a length cap (e.g. 500 chars for title,
  2000 for body — pick reasonable caps and document them in the function).

- [ ] **Step 2: Run, confirm failure**

- [ ] **Step 3: Implement `AnnouncementFeed`**

```swift
//
//  AnnouncementFeed.swift
//  Muse
//
//  Pure parse/selection logic for the announcements channel (DECIDED #28).
//  Nothing is sent to fetch this — a plain GET of a static file. Hardened
//  like the Drive share page's manifest: size-capped before decode,
//  length-capped and sanitized fields, https-only urls, unknown version
//  values ignored rather than guessed at.
//

import Foundation

struct Announcement: Codable, Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let body: String
    let url: String?
    let minAppVersion: String?
}

struct AnnouncementFeed: Codable, Equatable, Sendable {
    let version: Int
    let messages: [Announcement]
}

enum AnnouncementFeedParseError: Error { case tooLarge, badVersion, malformed }

extension AnnouncementFeed {
    static let maxPayloadBytes = 64 * 1024
    private static let currentVersion = 1
    private static let maxTitleLength = 200
    private static let maxBodyLength = 2000
    private static let maxIDLength = 100

    static func parse(_ data: Data) -> AnnouncementFeed? {
        guard data.count <= maxPayloadBytes else { return nil }
        guard let raw = try? JSONDecoder().decode(AnnouncementFeed.self, from: data) else { return nil }
        guard raw.version == currentVersion else { return nil }
        let cleaned = raw.messages.compactMap { m -> Announcement? in
            guard !m.id.isEmpty, m.id.count <= maxIDLength else { return nil }
            let title = AnnouncementSanitizer.strip(m.title, maxLength: maxTitleLength)
            let body = AnnouncementSanitizer.strip(m.body, maxLength: maxBodyLength)
            let safeURL: String? = m.url.flatMap { urlString in
                guard let u = URL(string: urlString), u.scheme == "https" else { return nil }
                return urlString
            }
            return Announcement(id: m.id, title: title, body: body, url: safeURL, minAppVersion: m.minAppVersion)
        }
        return AnnouncementFeed(version: raw.version, messages: cleaned)
    }

    static func unseen(_ feed: AnnouncementFeed, seen: Set<String>, appVersion: String) -> [Announcement] {
        feed.messages.filter { msg in
            guard !seen.contains(msg.id) else { return false }
            if let minVersion = msg.minAppVersion,
               minVersion.compare(appVersion, options: .numeric) == .orderedDescending {
                return false
            }
            return true
        }
    }
}

enum AnnouncementSanitizer {
    private static let stripSet: CharacterSet = {
        var set = CharacterSet()
        // Bidi override + isolate controls.
        for scalar in 0x202A...0x202E { set.insert(UnicodeScalar(scalar)!) }
        for scalar in 0x2066...0x2069 { set.insert(UnicodeScalar(scalar)!) }
        // Zero-width characters.
        for scalar in 0x200B...0x200D { set.insert(UnicodeScalar(scalar)!) }
        set.insert(UnicodeScalar(0xFEFF)!)
        set.formUnion(.controlCharacters)
        return set
    }()

    static func strip(_ s: String, maxLength: Int) -> String {
        let cleaned = String(s.unicodeScalars.filter { !stripSet.contains($0) })
        return String(cleaned.prefix(maxLength))
    }
}
```

  Confirm `.compare(_:options: .numeric)` correctly orders version strings like "1.6"
  vs "1.10" (numeric comparison handles multi-digit segments — verify with a quick
  manual check or add a dedicated test if the existing test suite doesn't already trust
  this pattern elsewhere).

- [ ] **Step 4: Run tests, confirm pass**

- [ ] **Step 5: Add the Settings toggle backing to `AppSettings.swift`**

  Mirroring `showStarsOnGridKey`/`showStarsOnGrid` exactly:

```swift
static let announcementsEnabledKey = "announcementsEnabled"

/// Off disables the announcements.json fetch entirely (not just the
/// display). Default true. Unset -> treated as on.
static var announcementsEnabled: Bool {
    UserDefaults.standard.object(forKey: announcementsEnabledKey) as? Bool ?? true
}
```

- [ ] **Step 6: Implement `AnnouncementStore`**

```swift
//
//  AnnouncementStore.swift
//  Muse
//
//  Own store object (AppState is frozen). Fetched once per launch; each
//  message shown once by id. Nothing is sent — a plain GET of a static
//  file, ephemeral session config, no query string/identifiers/cookies.
//

import Foundation

@MainActor
final class AnnouncementStore: ObservableObject {
    @Published private(set) var pending: Announcement?

    private static let seenIDsKey = "announcementsSeenIDs"
    private static let maxSeenIDs = 200

    func fetchIfNeeded() async {
        guard AppSettings.announcementsEnabled else { return }
        var config = URLSessionConfiguration.ephemeral
        config.httpAdditionalHeaders = [:]
        let session = URLSession(configuration: config)
        var request = URLRequest(url: CommerceConfig.announcementsURL,
                                  cachePolicy: .reloadIgnoringLocalCacheData,
                                  timeoutInterval: 10)
        request.httpMethod = "GET"
        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              let feed = AnnouncementFeed.parse(data) else { return }

        let appVersion = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0"
        let seen = loadSeenIDs()
        let unseen = AnnouncementFeed.unseen(feed, seen: seen, appVersion: appVersion)
        pending = unseen.first
    }

    func dismiss(_ id: String) {
        var seen = loadSeenIDs()
        seen.insert(id)
        if seen.count > Self.maxSeenIDs {
            // Cap enforcement: drop is acceptable here — worst case a very
            // old id is shown again, never a crash or unbounded growth.
            seen = Set(seen.prefix(Self.maxSeenIDs))
        }
        UserDefaults.standard.set(Array(seen), forKey: Self.seenIDsKey)
        pending = nil
    }

    private func loadSeenIDs() -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: Self.seenIDsKey) ?? [])
    }
}
```

- [ ] **Step 7: Inject `AnnouncementStore` and trigger the fetch**

  In `Muse/Muse/MuseApp.swift`, add `@StateObject private var announcementStore =
  AnnouncementStore()` and `.environmentObject(announcementStore)` beside the
  `commerceStore` wiring from Task 20. Trigger the fetch inside the same `.task` block
  that launches `IntentBackfill`/`CoordinateBackfill` (near line 131-132):

```swift
Task { await announcementStore.fetchIfNeeded() }
```

- [ ] **Step 8: Present the announcement as a `ModalMessageCard`-style card**

  Per the durable constraint (never `.alert`), and since `AppState.modalPresented`
  gates the grid's key catcher, the announcement card needs to participate in that gate
  WITHOUT adding a new `@Published` to `AppState`. The cleanest fit: `ContentView`
  already holds `@EnvironmentObject` references to feature stores; compute a combined
  presented-state in `ContentView` itself rather than inside `AppState`:

  In `Muse/Muse/ContentView.swift`, add `@EnvironmentObject private var
  announcementStore: AnnouncementStore`, and register a new `.museModal` presentation
  alongside the existing `alertRequest` one (near line 304-313):

```swift
.museModal(isPresented: Binding(
    get: { announcementStore.pending != nil },
    set: { if !$0 { announcementStore.dismiss(announcementStore.pending?.id ?? "") } }),
           width: ModalMessageCardWidth.standard,
           palette: appState.moodPalette) {
    if let a = announcementStore.pending {
        AnnouncementCard(announcement: a) { announcementStore.dismiss(a.id) }
            .id(a.id)
    }
}
```

  Add a small `AnnouncementCard: View` (in `Commerce/AnnouncementStore.swift` or a new
  `Views/Modal/AnnouncementCard.swift`, matching wherever `ModalMessageCard` itself
  lives) rendering `title`/`body` as `Text`, an optional "Learn More" `ModalButton` that
  opens `url` via `NSWorkspace.shared.open` when present, and a "Dismiss" `ModalButton`.

  For the grid-key-catcher gate: since `AppState.modalPresented` is read from
  `PageScrollCatcher`/similar AppKit escape hatches that may not have easy access to
  `ContentView`'s local state, check whether `AppState.modalPresented`'s consumers are
  all inside SwiftUI view bodies (where an environment-object-derived local `Bool` can
  substitute) or whether an AppKit-side representable reads it directly. If the latter,
  a minimal, justified exception to the "AppState is frozen" rule may be needed — but
  first check whether `.museModal`'s own presentation machinery already gates key input
  independently of `AppState.modalPresented` (it's an in-window overlay — SwiftUI focus
  routing behind an active `.museModal` is likely already handled at the `.museModal`
  modifier level, since every OTHER modal already works this way without a plain
  boolean check). Read `Muse/Muse/Views/Modal/` and the `.museModal` modifier
  definition in full to resolve this before finalizing — do not add a new `AppState`
  `@Published` property unless the investigation proves no alternative exists, and
  if one truly is required, add a SINGLE plain (non-`@Published`, computed from the
  environment) property rather than growing `AppState`'s stored-property count.

- [ ] **Step 9: Build and manually verify**

  Run: `xcodebuild -project Muse/Muse.xcodeproj -scheme Muse -configuration Debug build`
  Launch the app with no `announcements.json` deployed yet (expected 404 or connection
  failure since the owner hasn't deployed it — §8 of the spec) and confirm the app
  launches normally with no error UI, no hang, no console spam beyond a single silent
  failure. To test the presentation path itself, temporarily point
  `CommerceConfig.announcementsURL` at a local test server or a `data:` URL substitute
  during manual testing only (revert before commit), or write a small manual JSON
  fixture and verify `AnnouncementFeed.parse`/`unseen` behavior is already covered by
  Step 1's tests (sufficient — the fetch plumbing itself is thin enough that the unit
  tests plus a clean-404 smoke test cover this).

- [ ] **Step 10: Commit**

```bash
git add "Muse/Muse/Commerce/AnnouncementFeed.swift" "Muse/Muse/Commerce/AnnouncementStore.swift" \
        "Muse/MuseTests/AnnouncementFeedTests.swift" "Muse/Muse/Settings/AppSettings.swift" \
        "Muse/Muse/ContentView.swift" "Muse/Muse/MuseApp.swift"
git commit -m "feat: add announcements channel (fetch-once-per-launch, off-able, sanitized)"
```

---

## Section E — Performance baseline + known-issue fixes

### Task 23: Semantic-search cancellation threading

**Files:**
- Modify: `Muse/Muse/Database/SearchService.swift` (around lines 146-158, the
  `SemanticSearch.semanticIDs` call and merge loop)
- Modify: `Muse/Muse/Models/AppState+Search.swift` (thread the token into `search(...)`,
  lines 14-47)

**Interfaces:**
- Modifies existing: `SearchService.search(query:scope:)` gains a way to observe
  cancellation mid-flight — either an additional `isStale: @Sendable () -> Bool`
  closure parameter, or by making the function `Task`-cancellation-aware via
  `Task.checkCancellation()` if the caller wraps the whole call in a cancellable `Task`
  that's cancelled on a superseded request (simpler — prefer this if `runSearch` already
  runs inside a `Task` that can be tracked and cancelled, rather than adding a new
  closure parameter to `SearchService`).

- [ ] **Step 1: Read the current flow in full before choosing an approach**

  Read `Muse/Muse/Database/SearchService.swift` in full (especially the FTS leg, the
  semantic leg at lines ~146-158, and how they're combined) and
  `Muse/Muse/Models/AppState+Search.swift` in full (lines 14-47 per research, plus
  wherever `runSearchNow`/the debounce timer calls `runSearch`). Confirm: is `runSearch`
  invoked from inside a `Task` stored somewhere cancellable (e.g. an `AppState`
  property holding the in-flight `Task<Void, Never>`), or is it a bare `async func`
  called via `Task { await appState.runSearch(...) }` at the call site with no handle
  kept? This determines which of the two approaches (Task-cancellation vs. explicit
  token closure) is less invasive.

- [ ] **Step 2: Write a test proving the wasted-work fix**

  Since this is a performance/waste fix, not a correctness fix (the spec is explicit:
  "What remains is wasted work, not a wrong result... a superseded pass CANNOT land"),
  the test should prove CANCELLATION happens, not that results change:

```swift
func testSupersededSemanticSearchIsCancelledMidFlight() async {
    // Arrange a synthetic index large enough that the semantic leg takes
    // measurable time (or inject a slow stub embedding provider if
    // SemanticSearch already supports dependency injection for tests —
    // check SemanticSearchTests.swift for the existing seam before adding
    // a new one).
    // Act: fire two committed queries back-to-back, the first with a
    // deliberately slow semantic leg.
    // Assert: the first query's semantic work is observably cancelled
    // (either via a cancellation-count counter on the stub, or by timing:
    // total wall-clock is close to ONE full semantic pass, not two).
}
```

  Write the concrete version once Step 1 reveals whether `SemanticSearch` already has
  an injectable/stubbable seam (check `Muse/MuseTests/SemanticSearchTests.swift` or
  similar for precedent). If no seam exists, this task may need a small one added
  specifically to make the cancellation observable in a test — keep it minimal (a
  closure-based "did work start"/"was cancelled" hook is enough, don't over-engineer a
  full mock framework here).

- [ ] **Step 3: Run, confirm the test fails against current behavior**

- [ ] **Step 4: Implement the fix**

  If Task-cancellation is the chosen approach (preferred if `AppState` already tracks
  an in-flight search `Task`): ensure `runSearch`'s callers cancel the PREVIOUS
  in-flight `Task` before starting a new one (if not already done — check whether the
  existing `searchRequestToken` increment already implies this or whether it's purely
  a post-hoc staleness check with no actual cancellation signal sent). Then, inside
  `SearchService.search`, insert `try Task.checkCancellation()` (or the non-throwing
  `Task.isCancelled` check, returning early) at the boundary BEFORE the expensive
  embedding + cosine walk begins (right before the `SemanticSearch.semanticIDs(...)`
  call at the identified line), so a cancelled predecessor task exits before doing the
  expensive work rather than after.

  If no cancellable `Task` handle exists today, add one: store the in-flight search
  `Task<Void, Never>?` as a new property — but per the Global Constraints, `AppState`
  is frozen, so this MUST NOT become a new `@Published` on `AppState`. Since
  `AppState+Search.swift` is an extension file, check whether a plain (non-`@Published`,
  stored via an associated-object-free mechanism — e.g. a `nonisolated(unsafe)` static
  or a small dedicated `SearchTaskTracker` object referenced from `AppState`) can hold
  this without growing `AppState`'s published surface. A stored non-`@Published`
  `private var` on `AppState` itself is likely fine (the freeze rule targets
  `@Published` re-render fan-out, not all stored properties) — confirm this reading
  against the existing codebase's precedent (are there other non-`@Published` stored
  vars on `AppState`? `searchRequestToken` itself, per the research quote at
  `AppState+Search.swift:20`, is very likely one such example: `searchRequestToken +=
  1` reads as a plain `Int`, not obviously `@Published`). If `searchRequestToken` is
  indeed plain, add a sibling plain `private var inFlightSearchTask: Task<Void,
  Never>?` alongside it, cancelling the previous one at the top of `runSearch`.

- [ ] **Step 5: Run the test, confirm pass**

- [ ] **Step 6: Run the full search test suite for regressions**

  Run: `xcodebuild -project Muse/Muse.xcodeproj -scheme Muse test -only-testing:MuseTests -only-testing:SearchServiceTests` (adjust target names to match what actually exists — grep `MuseTests` for `Search` to find the real suite names).
  Expected: PASS, no change to committed-query RESULTS (only to wasted intermediate
  work).

- [ ] **Step 7: Manual verification**

  Run the app against a folder with several thousand indexed images. Type a query,
  wait for results, immediately type a very different query before the first
  completes. Confirm results reflect only the SECOND query (already guaranteed by the
  existing token guard) and confirm — via `MUSE_TRACE=1` if `PhaseTrace` covers search,
  or via a quick Instruments/Time Profiler sample if not — that the first query's
  semantic walk doesn't run to completion after being superseded.

- [ ] **Step 8: Commit**

```bash
git add "Muse/Muse/Database/SearchService.swift" "Muse/Muse/Models/AppState+Search.swift" \
        "Muse/MuseTests/SearchServiceTests.swift"
git commit -m "perf: cancel superseded semantic search mid-flight instead of running it to completion"
```

---

### Task 24: `Perf/PerfBaseline.swift` — measurement harness

**Files:**
- Create: `Muse/Muse/Perf/PerfBaseline.swift`
- Create: `Muse/MuseTests/PerfBaselineTests.swift`
- Modify: `Muse/Muse/MuseApp.swift` (gate a `PerfBaseline.run()` call behind
  `ProcessInfo.processInfo.environment["MUSE_PERF"] == "1"`, mirroring the existing
  `PhaseTrace.enabled` env-var pattern)

**Interfaces:**
- Produces: `PerfBaseline.run() async -> PerfReport`, `struct PerfReport { let
  machine: String; let os: String; let librarySize: Int; let measurements:
  [PerfMeasurement] }`, `struct PerfMeasurement { let name: String; let value: Double;
  let unit: String; let budget: Double }`, `PerfReport.markdown() -> String`.

- [ ] **Step 1: Write a test for the report-formatting logic (the pure part)**

```swift
//
//  PerfBaselineTests.swift
//  MuseTests
//
//  This suite RECORDS rather than asserts pass/fail on the timing numbers
//  themselves (a failing perf test on a busy CI machine is noise); it only
//  asserts the pure report-formatting logic and that every metric in the
//  spec's table is present in a run's output.
//

import XCTest
@testable import Muse

final class PerfBaselineTests: XCTestCase {
    func testMarkdownIncludesAllMeasurements() {
        let report = PerfReport(
            machine: "Test Machine", os: "macOS 14.6", librarySize: 100,
            measurements: [
                PerfMeasurement(name: "cold start", value: 1200, unit: "ms", budget: 1500),
                PerfMeasurement(name: "search latency", value: 90, unit: "ms", budget: 150),
            ])
        let md = report.markdown()
        XCTAssertTrue(md.contains("cold start"))
        XCTAssertTrue(md.contains("search latency"))
        XCTAssertTrue(md.contains("Test Machine"))
    }

    func testMarkdownFlagsOverBudgetMeasurements() {
        let report = PerfReport(
            machine: "M", os: "macOS 14.6", librarySize: 1,
            measurements: [PerfMeasurement(name: "slow thing", value: 200, unit: "ms", budget: 60)])
        XCTAssertTrue(report.markdown().contains("OVER BUDGET") || report.markdown().contains("⚠"))
    }
}
```

  Match the exact flagging convention (`OVER BUDGET` text vs. an emoji) to whatever
  reads cleanest in a plain Markdown file — pick one and keep the test aligned with the
  implementation.

- [ ] **Step 2: Run, confirm failure**

- [ ] **Step 3: Implement `PerfBaseline`**

  Four measurements per spec §5's table: cold start → first grid paint (budget 1500ms,
  via existing `PhaseTrace` marks), grid scroll frame time (budget 16.7ms p95),
  search latency (budget 150ms p95, over a synthetic 10k index), thumbnail decode
  (budget 60ms, single 24MP JPEG, cache cleared).

```swift
//
//  PerfBaseline.swift
//  Muse
//
//  Developer command (MUSE_PERF=1 at launch), not wired into app UI.
//  Measures against the M1 Air 8GB reference machine (DECIDED #24).
//  Writes docs/perf-baseline-<date>.md with each number beside its budget.
//

import Foundation

struct PerfMeasurement: Sendable {
    let name: String
    let value: Double
    let unit: String
    let budget: Double
    var overBudget: Bool { value > budget }
}

struct PerfReport: Sendable {
    let machine: String
    let os: String
    let librarySize: Int
    let measurements: [PerfMeasurement]

    func markdown() -> String {
        var lines = [
            "# Muse Performance Baseline",
            "",
            "Machine: \(machine)",
            "OS: \(os)",
            "Library size: \(librarySize) files",
            "",
            "| Metric | Value | Budget | Status |",
            "|---|---|---|---|",
        ]
        for m in measurements {
            let status = m.overBudget ? "⚠ OVER BUDGET" : "OK"
            lines.append("| \(m.name) | \(String(format: "%.1f", m.value)) \(m.unit) | \(String(format: "%.1f", m.budget)) \(m.unit) | \(status) |")
        }
        return lines.joined(separator: "\n")
    }
}

enum PerfBaseline {
    static func run() async -> PerfReport {
        let machine = ProcessInfo.processInfo.hostName
        let os = ProcessInfo.processInfo.operatingSystemVersionString
        let librarySize = (try? await Database.shared.dbQueue?.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM files") ?? 0
        }) ?? 0

        var measurements: [PerfMeasurement] = []
        measurements.append(await measureColdStart())
        measurements.append(await measureSearchLatency())
        measurements.append(await measureThumbnailDecode())
        // Grid scroll frame time requires a live scripted scroll against a
        // mounted view — this one is recorded via a manual/UI-driven pass
        // (see Step 4) rather than computed headlessly here; a placeholder
        // budget-only row is emitted so the report's shape is stable even
        // when this harness runs headlessly (e.g. from a test target with
        // no window).
        measurements.append(PerfMeasurement(name: "grid scroll frame time (manual)", value: 0, unit: "ms p95", budget: 16.7))

        let report = PerfReport(machine: machine ?? "unknown", os: os,
                                 librarySize: librarySize ?? 0, measurements: measurements)
        writeReport(report)
        return report
    }

    private static func measureColdStart() async -> PerfMeasurement {
        let elapsed = PhaseTrace.elapsed(from: "app.start", to: "grid.firstPaint") ?? 0
        return PerfMeasurement(name: "cold start -> first grid paint", value: elapsed * 1000, unit: "ms", budget: 1500)
    }

    private static func measureSearchLatency() async -> PerfMeasurement {
        let start = DispatchTime.now()
        _ = await SearchService.search(query: "test", scope: .everywhere)
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000
        return PerfMeasurement(name: "search latency", value: elapsed, unit: "ms", budget: 150)
    }

    private static func measureThumbnailDecode() async -> PerfMeasurement {
        // Caller supplies a known 24MP fixture path via env var so this
        // harness doesn't ship a large binary fixture in the repo.
        guard let path = ProcessInfo.processInfo.environment["MUSE_PERF_FIXTURE_24MP"] else {
            return PerfMeasurement(name: "thumbnail decode (24MP, no fixture set)", value: 0, unit: "ms", budget: 60)
        }
        let url = URL(fileURLWithPath: path)
        ThumbnailCache.invalidate(url)
        let start = DispatchTime.now()
        _ = await ThumbnailCache.thumbnail(for: url, size: CGSize(width: 320, height: 320), scale: 2.0)
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000
        return PerfMeasurement(name: "thumbnail decode (24MP)", value: elapsed, unit: "ms", budget: 60)
    }

    private static func writeReport(_ report: PerfReport) {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let dateString = formatter.string(from: Date())
        let path = "docs/perf-baseline-\(dateString).md"
        try? report.markdown().write(toFile: path, atomically: true, encoding: .utf8)
    }
}
```

  Confirm `PhaseTrace.elapsed(from:to:)` exists or needs adding (research only quoted
  `PhaseTrace.mark`/`.begin` — if no elapsed-between-marks query exists, add one small
  method to `PhaseTrace.swift` that computes the delta between two recorded mark
  timestamps, since that's exactly what "measured against `PhaseTrace` marks" in the
  spec requires and shouldn't be invented ad hoc inside `PerfBaseline`). Confirm
  `ThumbnailCache.thumbnail(for:size:scale:)`'s actual async signature by reading the
  file (the research pass didn't quote the public fetch API, only `cacheKey`/
  `invalidate`/`renderedVariants`) before finalizing this call.

- [ ] **Step 4: Wire the `MUSE_PERF=1` launch gate**

  In `Muse/Muse/MuseApp.swift`, near the `PhaseTrace`/backfill launch block:

```swift
if ProcessInfo.processInfo.environment["MUSE_PERF"] == "1" {
    Task { _ = await PerfBaseline.run() }
}
```

- [ ] **Step 5: Run tests, confirm pass**

- [ ] **Step 6: Manual run against a real library**

  Run: `MUSE_PERF=1 <path to built Muse.app>/Contents/MacOS/Muse` (or launch via Xcode
  with the env var set in the scheme's Run configuration). Confirm
  `docs/perf-baseline-<today>.md` is written with real numbers. This can only be
  meaningfully validated on the actual M1 Air 8GB reference machine — record here that
  the FULL validation (owner step §8 item 7 of the spec) is out of scope for this
  codebase task; this task's deliverable is the harness existing and producing a
  well-formed report on whatever machine it runs on.

- [ ] **Step 7: Commit**

```bash
git add "Muse/Muse/Perf/PerfBaseline.swift" "Muse/MuseTests/PerfBaselineTests.swift" "Muse/Muse/MuseApp.swift"
git commit -m "feat: add PerfBaseline harness (MUSE_PERF=1, writes docs/perf-baseline-<date>.md)"
```

---

## Section F — Final documentation sweep

### Task 25: Close out doc updates and flip the phase-table status

**Files:**
- Modify: `CLAUDE.md` (add a phase-table row for this spec, status ✅; update the
  "Implementation status" summary line if one exists — the deferred MAS migration plan
  adds its own row when it eventually runs, not this task)
- Modify: `docs/architecture-map.md` (add entries for `Commerce/`, `Perf/`,
  `CoordinateReader.swift`, `CoordinateBackfill.swift`, `EditStackIndex.swift`,
  `EffectiveDimensions.swift`, `OutputRender.swift`)
- Modify: `docs/session-log.md` (append a dated entry summarizing this spec's work,
  matching the existing entry format/length)

**Interfaces:** None — documentation only. This is the final task; run it only after
every prior task in this plan is merged and green.

- [ ] **Step 1: Run the full test suite one more time as the gate for this task**

  Run: `xcodebuild -project Muse/Muse.xcodeproj -scheme Muse test`
  Expected: 100% pass, including every new suite added across this plan
  (`CoordinateMigrationTests`, `CoordinateReaderTests`, `EditStackIndexTests`,
  `ThumbnailStackKeyTests`, `EffectiveDimensionsTests`, `OutputRenderTests`,
  `TrialGateTests`, `AnnouncementFeedTests`, `CommerceEntitlementTests`,
  `PerfBaselineTests`) plus every pre-existing suite named in spec §6
  (`ImageHeaderSizeCacheTests`, `ThumbnailVariantTests`, `FileMetadataLoadTests`,
  `CollectionPDFLayoutTests`, `DriveMultipartTests`).

- [ ] **Step 2: Update `docs/architecture-map.md`**

  Add one line per new file/module under the appropriate existing section (or a new
  "Commerce" / "Perf" section matching the doc's existing structure), naming the file
  and a one-line purpose — matching the doc's existing terseness convention.

- [ ] **Step 3: Append a `docs/session-log.md` entry**

  Dated `2026-07-30` (or the actual merge date), summarizing: v13 coordinates migration
  + backfill, the three edit-aware seams (why they matter for Spec 04), StoreKit 2
  plumbing (unenforced trial gate — note explicitly WHY it's unenforced), the
  announcements channel, and the perf baseline harness + semantic-search cancellation
  fix. Note explicitly that Mac App Store migration (doctrine revisions, Sparkle
  excision, Apple Silicon–only build settings) was deliberately deferred out of this
  spec to `deferred-mac-app-store-migration.md` — the app still ships Sparkle/direct
  distribution as of this entry. Match the length and tone of recent entries (e.g. the
  Polish 25-28 entries) — a few paragraphs, not a full restatement of this plan.

- [ ] **Step 4: Add the `CLAUDE.md` phase-table row for this spec**

  In the "## Implementation status" table, add a row: `| Foundation 1 — Spec-01
  foundation & plumbing (v13 coordinates, edit-aware seams, StoreKit 2 plumbing,
  announcements) | ✅ shipped | <branch> |`. Note: this deliberately omits Sparkle
  removal / MAS build config — that's the deferred migration plan's own row, added when
  it runs.

- [ ] **Step 5: Final grep sweep for stray TODOs or placeholder text introduced by this
  plan**

  Run: `git diff main... -- '*.swift' | grep -n "TODO\|FIXME\|placeholder"`
  Expected: no matches (every implementation task above resolved its own
  investigation-required spots with real code, per each task's own instructions to
  read the surrounding file before finalizing).

- [ ] **Step 6: Commit**

```bash
git add CLAUDE.md docs/architecture-map.md docs/session-log.md
git commit -m "docs: close out Spec 01 foundation & plumbing (architecture map, session log, phase table)"
```

---

## What this plan deliberately does not build

Matching spec-01-implementation.md §0 and §9 exactly — do not add these as tasks, they
belong to other specs or are owner-only:

- Any editor UI (Spec 04), any search UI beyond the token/query plumbing already
  present (Spec 02/03), places/rediscovery/near-duplicate stacks (Spec 02), faces
  (Spec 03), sharing UI changes beyond what already exists (Spec 06/10 territory).
- `HybridClusterer` time-bucketing — measured by `PerfBaseline`, not changed here
  (belongs with Spec 02's near-duplicate stacks; changes clustering semantics).
- Doctrine revisions, Sparkle excision, and Apple Silicon–only build settings (the Mac
  App Store move) — deliberately deferred, see `deferred-mac-app-store-migration.md`.
- Owner-only steps: App Store Connect app record + IAP records + pricing, Small
  Business Program enrollment, MAS distribution certificate/provisioning profile
  selection, TestFlight upload/verification, sandbox purchase/restore/promo-code
  testing, running `PerfBaseline` on the actual M1 Air 8GB reference machine and
  committing that report, deploying `announcements.json` to Cloudflare Pages. These are
  tracked in spec-01-implementation.md §8 and are NOT tasks in this plan — they require
  the owner's Apple Developer account access.
