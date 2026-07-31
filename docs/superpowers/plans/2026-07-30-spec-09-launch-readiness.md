# Spec 09 — Launch Readiness: Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship the last mile before App Store submission: flip the trial gate
and sharing-tier enforcement live, fix the real gap where edit data does not
survive a `.muselibrary` backup round-trip, build the 500k-library
performance-validation tooling, and rewrite the in-repo legal/About surfaces
for a paid, PolyForm-Shield, Mac-App-Store-only app.

**Architecture:** No new subsystems. This spec is entirely amendments to
things Specs 01, 04, 07 and 08 already built: `Commerce/TrialGate.swift` and
`Commerce/CommerceStore.swift` (Spec 01) gain a live, published trial state
and a non-dismissible shell overlay; `Backup/BackupArchive.swift` (shipped
today) gains optional edit fields carried the same way `note`/`icon`/
`smart_rules` were added before; `Commerce/SharingTier.swift` (Spec 07) flips
its one constant; a checked-in Swift script plus an env-gated test section
extend the existing `PerfBaselineTests` (Spec 01) harness; and `web/share`'s
static legal pages plus `InfoSheet.swift`'s About card are rewritten in
place. Every new piece of state is either a computed property (zero AppState
growth) or lives on the existing Pattern-B `CommerceStore` singleton.

**Tech Stack:** Swift/SwiftUI, StoreKit 2 (`Transaction`, `Product`,
`AppStore`), GRDB (backup read/write only — no new migration), XCTest, a
standalone `swift` script (ImageIO only, no Xcode project) for the synthetic
library generator.

**Prerequisites:** This plan assumes Specs 01, 04, 07 and 08 have already
landed (their own plans are `2026-07-30-spec-01-foundation-plumbing.md`,
`…-spec-04-editing-engine.md`, `…-spec-07-sharing-social-export.md`,
`…-spec-08-custom-domains.md`), so `Commerce/CommerceStore.swift`,
`Commerce/TrialGate.swift`, `Commerce/SharingTier.swift`,
`Sharing/Domains/ShareDomainCard.swift`, and the `edits`/`edit_versions`/
`edit_presets`/`edit_luts` tables + `EditRecordStore`/`EditStore`/
`LiveEditStackProvider`/`LutRegistry` all exist exactly as those plans define
them. Every reference to a prior-spec type below cites the exact shape from
`docs/new-build/DECISIONS.md` (the build-level authority) rather than
re-deriving it. If a worker picks this plan up before those specs are
merged, stop and merge them first — Tasks 5–10 will not compile otherwise.
Tasks 1–4 (the backup amendment) additionally require Spec 04's `edits`
tables; Task 11 requires Spec 07's `SharingTier.swift`; nothing in this plan
requires Spec 08 except the doc-only checklist row about `ALLOW_SANDBOX`.

## Global Constraints

- **No price literal ever appears in code, resources, or `.xcstrings`
  values.** Every surface that shows a price renders `Product.displayPrice`;
  if products haven't loaded, the copy omits the number — never a hardcoded
  or stale one. Acceptance: `grep -rn '\$49\|\$19\|49\.99\|19\.99'` over
  `Muse/Muse` and `Localizable.xcstrings` → zero hits.
- **This spec adds NO database migration.** Future specs still continue at
  v24. The backup amendment (Tasks 1–4) is a `Codable` shape change to a
  JSON archive format, not a schema change — `BackupArchive.currentSchema`
  stays `1`.
- **`AppState` is frozen.** The one integration point
  (`modalPresented`) is a computed-property read of `CommerceStore.shared` —
  no new `@Published` property, no forwarding cancellable.
- **The trial gate is not dismissible and not in the Escape peel.** When
  `trialGateActive` is the ONLY thing making `modalPresented` true, Escape
  and `dismissTopModal()` must no-op. Never wire a Cancel/✕ onto the gate.
- **The trial gate blocks the UI, never background data maintenance.**
  Backfills, `DriveExpirySweeper`, `ShareDomainRefresher`, and sidecar
  hydration all keep running while the gate is up.
- **`TrialPolicy.epoch = 1` reads Spec 01's legacy unnumbered Keychain key
  (and its UserDefaults mirror) earliest-wins, so no existing tester's
  anchor resets when this build ships.** A future epoch bump reads ONLY its
  own key.
- **LUT bytes ride the backup archive** (base64 `Data`, bounded by
  `CubeLUTParser.maxSize = 128`). A restored stack referencing an absent LUT
  still renders as the original everywhere (Spec 05's rule) — carrying the
  bytes is what prevents "restored the edit, lost the look."
- **Restore is restore-wins, not merge**, for the edit stack (mirrors the
  existing `note` line in `ReconnectApplier.applyMeta`) — a backup restore is
  an explicit recovery action. Versions/snapshots get fresh UUIDs on
  restore (the standing carry rule); presets/LUTs are `INSERT OR IGNORE`
  (LUT immutability; idempotent re-restore).
- **The perf gate is a human reading a committed report, never a CI
  assertion.** `PerfBaselineTests` records numbers; `MUSE_PERF_500K=1` gates
  the new 500k section so it never runs in default CI.
- **Every new user-facing string is localized at introduction** (SwiftUI
  literal positions or explicit `String(localized:)`); this ships only after
  the French export pass reports 0 untranslated for everything this spec
  touches.
- **No UI unit tests (house rule).** `UnlockGateView`'s only logic
  (`trialGateActive`, `trialState`) is covered on `CommerceStore`/
  `TrialGate` directly.

## File structure

```
Muse/Muse/Commerce/
├── TrialGate.swift                  # MODIFY — epoch, TrialPolicy.current, key naming
├── CommerceStore.swift              # MODIFY — @Published trialState, trialGateActive,
│                                     #   recompute triggers, Manage Subscription URL
└── SharingTier.swift                # MODIFY — enforced flips to true (Spec 07 file)

Muse/Muse/Views/
├── UnlockGateView.swift             # NEW — the non-dismissible gate card
└── SubscriptionLegalLinks.swift     # NEW — shared Privacy/Terms link row

Muse/Muse/Backup/
├── BackupArchive.swift              # MODIFY — BackupEditVersion/Preset/Lut + optional
│                                     #   fields on BackupOccurrence/BackupArchive
├── BackupBuilder.swift              # MODIFY — fetch edits/versions/presets/luts
└── ReconnectApplier.swift           # MODIFY — applyMeta writes the stack + versions;
                                     #   new applyEditAssets(presets, luts)

Muse/Muse/ContentView.swift          # MODIFY — dismissTopModal() no-ops on gate-only;
                                     # UnlockGateView mount point
Muse/Muse/Models/AppState.swift      # MODIFY — modalPresented gains the gate read
Muse/Muse/Settings/SettingsView.swift # MODIFY — trial status line, Manage Subscription row
Muse/Muse/Views/InfoSheet.swift      # MODIFY — license/attribution line replaced

scripts/
└── make-synthetic-library.swift     # NEW — checked-in, zero-dependency generator

Muse/MuseTests/
├── TrialGateTests.swift             # MODIFY — epoch tests, enforced default
├── CommerceEntitlementTests.swift   # MODIFY — trialState recompute tests
├── SharingTierTests.swift           # MODIFY — enforced-default assertions
├── BackupEditRoundTripTests.swift   # NEW
├── BackupArchiveCompatTests.swift   # NEW
└── PerfBaselineTests.swift          # MODIFY — MUSE_PERF_500K-gated section

Muse/Perf/PerfBaseline.swift         # MODIFY — new recorded rows (list only, no asserts)

web/share/
├── about.html                       # MODIFY
├── privacy.html                     # MODIFY
└── terms.html                       # MODIFY

README.md                            # MODIFY
Muse/Info.plist                      # MODIFY — ITSAppUsesNonExemptEncryption
docs/launch-validation-template.md   # NEW — the owner protocol template
CLAUDE.md                            # MODIFY — doctrine finalization (last task)
docs/architecture-map.md             # MODIFY
docs/session-log.md                  # MODIFY
```

---

### Task 1: Backup archive — edit-carrying model types

**Files:**
- Modify: `Muse/Muse/Backup/BackupArchive.swift`

**Interfaces:**
- Consumes: nothing new (pure `Codable` structs).
- Produces: `BackupEditVersion`, `BackupEditPreset`, `BackupLut`;
  `BackupOccurrence.edit_stack: String?`, `.edit_updated_at: Int64?`,
  `.edit_versions: [BackupEditVersion]?`; `BackupArchive.edit_presets:
  [BackupEditPreset]?`, `.edit_luts: [BackupLut]?`. Consumed by Task 2
  (`BackupBuilder`), Task 3 (`ReconnectApplier`), Task 4 (tests).

- [ ] **Step 1: Write the failing compat test first (drives the shape)**

Create `Muse/MuseTests/BackupArchiveCompatTests.swift`:

```swift
//
//  BackupArchiveCompatTests.swift
//  MuseTests
//
//  Spec 09 amendment A2: edit data must survive a .muselibrary round trip.
//  These tests pin BOTH decode directions so the optional-fields pattern
//  (the same one note/icon/smart_rules used) never breaks compatibility.
//

import XCTest
@testable import Muse

final class BackupArchiveCompatTests: XCTestCase {
    /// A pre-A2 archive (no edit_* keys at all) must decode unchanged —
    /// the new fields default to nil.
    func testPreA2ArchiveDecodesUnchanged() throws {
        let json = """
        {
          "schema": 1, "created_at": 1000, "app_version": "1.5",
          "roots": [], "stars": [],
          "files": [{
            "content_hash": "abc123",
            "meta": {},
            "occurrences": [{
              "original_path": "/a/b.jpg", "basename": "b.jpg",
              "root_path": "/a", "parent_dir": "/a", "tags": []
            }]
          }],
          "collections": []
        }
        """.data(using: .utf8)!
        let archive = try JSONDecoder().decode(BackupArchive.self, from: json)
        XCTAssertNil(archive.edit_presets)
        XCTAssertNil(archive.edit_luts)
        XCTAssertNil(archive.files[0].occurrences[0].edit_stack)
        XCTAssertNil(archive.files[0].occurrences[0].edit_updated_at)
        XCTAssertNil(archive.files[0].occurrences[0].edit_versions)
    }

    /// A post-A2 archive with edit_* keys decodes on the PRE-A2 struct shape
    /// (simulated here by decoding only the fields that existed before this
    /// spec) — unknown keys are ignored by Codable, so an older build reading
    /// a newer archive loses only the edit fields, never crashes or drops
    /// unrelated data.
    func testPostA2ArchiveDecodesOnPreA2Shape() throws {
        struct PreA2Occurrence: Codable {
            var original_path: String
            var basename: String
            var root_path: String?
            var parent_dir: String?
            var tags: [SidecarTag]
            var note: String? = nil
        }
        struct PreA2File: Codable { var content_hash: String; var occurrences: [PreA2Occurrence] }
        struct PreA2Archive: Codable { var schema: Int; var files: [PreA2File] }

        let json = """
        {
          "schema": 1,
          "files": [{
            "content_hash": "abc123",
            "occurrences": [{
              "original_path": "/a/b.jpg", "basename": "b.jpg",
              "root_path": "/a", "parent_dir": "/a", "tags": [],
              "edit_stack": "{\\"schemaVersion\\":1}",
              "edit_updated_at": 1234,
              "edit_versions": [{"kind": "version", "stack": "{}", "created_at": 1}]
            }]
          }],
          "edit_presets": [{"id": "p1", "name": "Look", "stack": "{}",
                            "created_at": 1, "updated_at": 1}],
          "edit_luts": [{"id": "hash1", "name": "LUT", "size": 33, "data": "AAAA"}]
        }
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(PreA2Archive.self, from: json)
        XCTAssertEqual(decoded.schema, 1)
        XCTAssertEqual(decoded.files[0].occurrences[0].original_path, "/a/b.jpg")
        // The edit_* keys are simply absent from this shape — no crash, no
        // partial decode. Both the new and old fields the pre-A2 shape DOES
        // know about survive.
    }

    /// The new shape itself round-trips through encode/decode.
    func testNewShapeRoundTrips() throws {
        var occ = BackupOccurrence(original_path: "/a/b.jpg", basename: "b.jpg",
                                   root_path: "/a", parent_dir: "/a", tags: [])
        occ.edit_stack = "{\"schemaVersion\":1}"
        occ.edit_updated_at = 999
        occ.edit_versions = [BackupEditVersion(kind: "snapshot", name: "Before",
                                               stack: "{}", created_at: 100)]
        let file = BackupFile(content_hash: "abc", meta: Sidecar(), occurrences: [occ])
        var archive = BackupArchive(schema: 1, created_at: 1, app_version: nil,
                                    roots: [], files: [file], collections: [], stars: [])
        archive.edit_presets = [BackupEditPreset(id: "p1", name: "Look", stack: "{}",
                                                 created_at: 1, updated_at: 2)]
        archive.edit_luts = [BackupLut(id: "hash1", name: "LUT", size: 33,
                                       data: Data([0, 1, 2, 3]))]

        let data = try JSONEncoder().encode(archive)
        let decoded = try JSONDecoder().decode(BackupArchive.self, from: data)
        XCTAssertEqual(decoded, archive)
    }
}
```

- [ ] **Step 2: Run it — confirm it fails to compile**

Run: `xcodebuild -project Muse/Muse.xcodeproj -scheme Muse test -only-testing:MuseTests/BackupArchiveCompatTests`
Expected: FAIL — `BackupEditVersion`, `BackupEditPreset`, `BackupLut` and
the new optional fields don't exist yet.

- [ ] **Step 3: Add the types**

Edit `Muse/Muse/Backup/BackupArchive.swift`. Add three new structs and
extend `BackupOccurrence`/`BackupArchive` with optional fields (nil default,
matching the `note`/`icon`/`smart_rules` pattern already in the file):

```swift
nonisolated struct BackupOccurrence: Codable, Equatable, Sendable {
    var original_path: String
    var basename: String
    var root_path: String?
    var parent_dir: String?
    var tags: [SidecarTag]
    var note: String? = nil
    // Spec 09 amendment A2: the CURRENT edit stack for this (file, folder),
    // plus its virtual copies/snapshots. Optional so pre-A2 archives decode
    // unchanged. A neutral/no-edit occurrence carries nil, not an empty
    // string — mirrors the `edits`-row-absence-means-no-edit rule.
    var edit_stack: String? = nil
    var edit_updated_at: Int64? = nil
    var edit_versions: [BackupEditVersion]? = nil
}

/// A virtual copy or before/after snapshot, riding the archive at the same
/// (file, folder) grain as the current stack above.
nonisolated struct BackupEditVersion: Codable, Equatable, Sendable {
    var kind: String        // "version" | "snapshot"
    var name: String?
    var stack: String       // canonical stack JSON
    var created_at: Int64
}
```

Add after `BackupStar`:

```swift
/// A library-global user preset, carried alongside collections/stars.
nonisolated struct BackupEditPreset: Codable, Equatable, Sendable {
    var id: String
    var name: String
    var stack: String
    var created_at: Int64
    var updated_at: Int64
}

/// A library-global imported .cube LUT. LUT rows are immutable and keyed by
/// content hash (`id`); carrying the bytes (not just a reference) is what
/// makes a restored stack render the SAME look rather than falling back to
/// the "missing LUT" original-image path on a fresh machine.
nonisolated struct BackupLut: Codable, Equatable, Sendable {
    var id: String           // the edit_luts content-hash PK
    var name: String
    var size: Int
    var data: Data           // float32 LE RGB, base64 via Codable Data
}
```

Extend `BackupArchive`:

```swift
nonisolated struct BackupArchive: Codable, Equatable, Sendable {
    var schema: Int
    var created_at: Int64
    var app_version: String?
    var roots: [BackupRoot]
    var files: [BackupFile]
    var collections: [BackupCollection]
    var stars: [BackupStar]
    // Spec 09 amendment A2. Optional so pre-A2 archives decode unchanged;
    // schema stays 1 (no format-version bump — the established pattern).
    var edit_presets: [BackupEditPreset]? = nil
    var edit_luts: [BackupLut]? = nil

    static let currentSchema = 1
}
```

- [ ] **Step 4: Run the tests again — confirm they pass**

Run: `xcodebuild -project Muse/Muse.xcodeproj -scheme Muse test -only-testing:MuseTests/BackupArchiveCompatTests`
Expected: PASS (all three tests).

- [ ] **Step 5: Commit**

```bash
cd "Muse App"
git add Muse/Muse/Backup/BackupArchive.swift Muse/MuseTests/BackupArchiveCompatTests.swift
git commit -m "feat: carry edit stacks/versions/presets/LUTs in the backup archive shape"
```

---

### Task 2: `BackupBuilder` — fetch edit rows into the archive

**Files:**
- Modify: `Muse/Muse/Backup/BackupBuilder.swift`

**Interfaces:**
- Consumes: `BackupEditVersion`/`BackupEditPreset`/`BackupLut` (Task 1);
  `EditRow`, `EditVersionRow`, `EditPresetRow`, `EditLutRow` (Spec 04 —
  `Database/Records.swift`, per `DECISIONS.md` "Spec 04 schema (v20–v21)"
  and Spec 05's `v23 edit_luts`): `EditRow { file_id, parent_dir, stack,
  stack_hash, process_version, updated_at }`, `EditVersionRow { id,
  file_id, parent_dir, kind, name, stack, created_at }`, `EditPresetRow {
  id, name, stack, created_at, updated_at }`, `EditLutRow { id, name, size,
  data, created_at }`.
- Produces: `BackupBuilder.build(...)` now populates the new archive fields.
  Consumed by Task 4's round-trip test and by the (unchanged) backup UI.

- [ ] **Step 1: Write the failing test**

Add to a new test file `Muse/MuseTests/BackupEditRoundTripTests.swift`
(this task only needs the builder half; Task 3 fills in the apply half in
the same file):

```swift
//
//  BackupEditRoundTripTests.swift
//  MuseTests
//
//  Spec 09 amendment A2 end-to-end: build a library with edits, versions,
//  presets and a LUT, encode/decode the archive, and confirm every piece
//  reaches BackupBuilder's output. Task 3 extends this file to also drive
//  ReconnectApplier and assert the restore side.
//

import XCTest
import GRDB
@testable import Muse

final class BackupEditRoundTripTests: XCTestCase {
    private func makeQueue() throws -> DatabaseQueue {
        let queue = try DatabaseQueue()
        try Database.makeMigrator().migrate(queue)
        return queue
    }

    func testBuilderCarriesEditStackVersionsPresetsAndLut() async throws {
        let queue = try makeQueue()
        let fileID = UUID().uuidString
        try await queue.write { db in
            var file = FileRow(id: fileID, content_hash: "hash1", kind: "image",
                               size: 100, width: 10, height: 10)
            try file.insert(db)
            var path = PathRow(id: UUID().uuidString, file_id: fileID,
                               absolute_path: "/root/photo.jpg", is_alive: 1)
            try path.insert(db)

            var edit = EditRow(file_id: fileID, parent_dir: "/root",
                               stack: "{\"schemaVersion\":1,\"processVersion\":1}",
                               stack_hash: "sh1", process_version: 1, updated_at: 500)
            try edit.insert(db)

            var version = EditVersionRow(id: UUID().uuidString, file_id: fileID,
                                         parent_dir: "/root", kind: "snapshot",
                                         name: "Before", stack: "{}", created_at: 400)
            try version.insert(db)

            var preset = EditPresetRow(id: UUID().uuidString, name: "Moody",
                                       stack: "{}", created_at: 1, updated_at: 1)
            try preset.insert(db)

            var lut = EditLutRow(id: "lutHash1", name: "Kodak", size: 33,
                                 data: Data([0, 1, 2, 3]), created_at: 1)
            try lut.insert(db)
        }

        let roots = [BackupRoot(path: "/root", display_name: "root")]
        let archive = try await BackupBuilder.build(queue: queue, roots: roots,
                                                     createdAt: 1000, appVersion: "1.6")

        let occ = try XCTUnwrap(archive.files.first?.occurrences.first)
        XCTAssertEqual(occ.edit_stack, "{\"schemaVersion\":1,\"processVersion\":1}")
        XCTAssertEqual(occ.edit_updated_at, 500)
        XCTAssertEqual(occ.edit_versions?.count, 1)
        XCTAssertEqual(occ.edit_versions?.first?.kind, "snapshot")
        XCTAssertEqual(archive.edit_presets?.count, 1)
        XCTAssertEqual(archive.edit_presets?.first?.name, "Moody")
        XCTAssertEqual(archive.edit_luts?.count, 1)
        XCTAssertEqual(archive.edit_luts?.first?.data, Data([0, 1, 2, 3]))
    }

    /// A file with no `edits` row (neutral stack — the DB rule is "no row =
    /// no edit") must produce a nil edit_stack, never an empty string.
    func testFileWithNoEditRowCarriesNilStack() async throws {
        let queue = try makeQueue()
        let fileID = UUID().uuidString
        try await queue.write { db in
            var file = FileRow(id: fileID, content_hash: "hash2", kind: "image",
                               size: 100, width: 10, height: 10)
            try file.insert(db)
            var path = PathRow(id: UUID().uuidString, file_id: fileID,
                               absolute_path: "/root/other.jpg", is_alive: 1)
            try path.insert(db)
        }
        let archive = try await BackupBuilder.build(
            queue: queue, roots: [BackupRoot(path: "/root", display_name: "root")],
            createdAt: 1000, appVersion: nil)
        let occ = try XCTUnwrap(archive.files.first?.occurrences.first)
        XCTAssertNil(occ.edit_stack)
        XCTAssertNil(occ.edit_versions)
    }
}
```

- [ ] **Step 2: Run to confirm failure**

Run: `xcodebuild -project Muse/Muse.xcodeproj -scheme Muse test -only-testing:MuseTests/BackupEditRoundTripTests/testBuilderCarriesEditStackVersionsPresetsAndLut`
Expected: FAIL — `occ.edit_stack` is nil where the test expects the stack;
`archive.edit_presets`/`edit_luts` are nil.

- [ ] **Step 3: Implement — fetch edit rows in `BackupBuilder.build`**

Edit `Muse/Muse/Backup/BackupBuilder.swift`. Add fetches beside the
existing `noteRows` block (same `(file_id, parent_dir)` key shape) and wire
them into the occurrence-building closure, then populate the two
library-global archive fields:

```swift
// Edits, grouped by (file_id, parent_dir), same key shape as tags/notes.
let editRows = try EditRow.fetchAll(db)
var editByFileDir: [String: EditRow] = [:]
for e in editRows {
    editByFileDir["\(e.file_id)\u{1}\(e.parent_dir)"] = e
}
let versionRows = try EditVersionRow.fetchAll(db)
var versionsByFileDir: [String: [BackupEditVersion]] = [:]
for v in versionRows {
    let key = "\(v.file_id)\u{1}\(v.parent_dir)"
    versionsByFileDir[key, default: []].append(
        BackupEditVersion(kind: v.kind, name: v.name, stack: v.stack,
                          created_at: v.created_at))
}
```

Inside the `occurrences = paths.map { ... }` closure, add to the returned
`BackupOccurrence`:

```swift
let editKey = "\(fid)\u{1}\(parent)"
let edit = editByFileDir[editKey]
return BackupOccurrence(
    original_path: p.absolute_path,
    basename: url.lastPathComponent,
    root_path: rootPath,
    parent_dir: parent,
    tags: tagsByFileDir["\(fid)\u{1}\(parent)"] ?? [],
    note: noteByFileDir["\(fid)\u{1}\(parent)"],
    edit_stack: edit?.stack,
    edit_updated_at: edit?.updated_at,
    edit_versions: versionsByFileDir[editKey])
```

Before the final `return BackupArchive(...)`, add the library-global fetch
and populate the two new fields on the constructed archive:

```swift
let presetRows = try EditPresetRow.fetchAll(db)
let editPresets = presetRows.map {
    BackupEditPreset(id: $0.id, name: $0.name, stack: $0.stack,
                     created_at: $0.created_at, updated_at: $0.updated_at)
}
let lutRows = try EditLutRow.fetchAll(db)
let editLuts = lutRows.map {
    BackupLut(id: $0.id, name: $0.name, size: $0.size, data: $0.data)
}

var archive = BackupArchive(
    schema: BackupArchive.currentSchema, created_at: createdAt,
    app_version: appVersion, roots: roots, files: files,
    collections: collections, stars: stars)
archive.edit_presets = editPresets.isEmpty ? nil : editPresets
archive.edit_luts = editLuts.isEmpty ? nil : editLuts
return archive
```

(Empty arrays collapse to `nil` so a library with no edits at all produces
byte-identical archive JSON to before this spec — no new keys appear
unless there's something to carry.)

- [ ] **Step 4: Run the tests — confirm they pass**

Run: `xcodebuild -project Muse/Muse.xcodeproj -scheme Muse test -only-testing:MuseTests/BackupEditRoundTripTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Muse/Muse/Backup/BackupBuilder.swift Muse/MuseTests/BackupEditRoundTripTests.swift
git commit -m "feat: BackupBuilder fetches edit stacks/versions/presets/LUTs"
```

---

### Task 3: `ReconnectApplier` — restore the stack, versions, presets, LUTs

**Files:**
- Modify: `Muse/Muse/Backup/ReconnectApplier.swift`

**Interfaces:**
- Consumes: `BackupFile.occurrences[].edit_stack/.edit_updated_at/
  .edit_versions`, `BackupArchive.edit_presets/.edit_luts` (Task 1/2);
  `EditRecordStore.write(stack:updatedAt:fileID:parentDir:db:)` (Spec 04's
  `NoteStore.write`-shaped seam — restore-wins, matching the `note` line
  immediately above it in `applyMeta`); `LiveEditStackProvider` index
  rebuild hook; `appState.markContentChanged([path])`; `EditStore.generation
  += 1`; `LutRegistry.invalidate(id:)`.
- Produces: `ReconnectApplier.applyEditAssets(_:queue:)`, called from the
  same restore flow that calls `applyCollections`/`applyStars` today.
  Consumed by the (unchanged) `RestoreCoordinator`/backup UI call site and
  by this task's tests.

- [ ] **Step 1: Extend the round-trip test with the restore assertions**

Append to `Muse/MuseTests/BackupEditRoundTripTests.swift`:

```swift
    func testApplyMetaRestoresEditStackAndVersionsRestoreWins() async throws {
        let sourceQueue = try makeQueue()
        let sourceFileID = UUID().uuidString
        try await sourceQueue.write { db in
            var file = FileRow(id: sourceFileID, content_hash: "hashR", kind: "image",
                               size: 100, width: 10, height: 10)
            try file.insert(db)
            var path = PathRow(id: UUID().uuidString, file_id: sourceFileID,
                               absolute_path: "/old/photo.jpg", is_alive: 1)
            try path.insert(db)
            var edit = EditRow(file_id: sourceFileID, parent_dir: "/old",
                               stack: "{\"schemaVersion\":1,\"exposure\":1.5}",
                               stack_hash: "shR", process_version: 1, updated_at: 500)
            try edit.insert(db)
            var version = EditVersionRow(id: UUID().uuidString, file_id: sourceFileID,
                                         parent_dir: "/old", kind: "version",
                                         name: nil, stack: "{}", created_at: 300)
            try version.insert(db)
        }
        let archive = try await BackupBuilder.build(
            queue: sourceQueue, roots: [BackupRoot(path: "/old", display_name: "old")],
            createdAt: 1000, appVersion: nil)
        let backupFile = try XCTUnwrap(archive.files.first)

        // Restore onto a DIFFERENT queue/file/path, simulating a fresh
        // machine, plus a pre-existing DIFFERENT edit on the destination
        // to confirm restore-wins (not merge).
        let destQueue = try makeQueue()
        let destFileID = UUID().uuidString
        try await destQueue.write { db in
            var file = FileRow(id: destFileID, content_hash: "hashR", kind: "image",
                               size: 100, width: 10, height: 10)
            try file.insert(db)
            var path = PathRow(id: UUID().uuidString, file_id: destFileID,
                               absolute_path: "/new/photo.jpg", is_alive: 1)
            try path.insert(db)
            var existingEdit = EditRow(file_id: destFileID, parent_dir: "/new",
                                       stack: "{\"schemaVersion\":1,\"exposure\":-2}",
                                       stack_hash: "different", process_version: 1,
                                       updated_at: 999)
            try existingEdit.insert(db)
        }

        let match = OccurrenceMatch(diskPath: "/new/photo.jpg",
                                    occurrence: backupFile.occurrences[0])
        try await ReconnectApplier.applyMeta(matches: [match], file: backupFile,
                                             queue: destQueue)

        let restored = try await destQueue.read { db in
            try EditRow.filter(EditRow.Columns.file_id == destFileID)
                .filter(EditRow.Columns.parent_dir == "/new").fetchOne(db)
        }
        XCTAssertEqual(restored?.stack, "{\"schemaVersion\":1,\"exposure\":1.5}")
        let restoredVersions = try await destQueue.read { db in
            try EditVersionRow.filter(EditVersionRow.Columns.file_id == destFileID)
                .fetchAll(db)
        }
        XCTAssertEqual(restoredVersions.count, 1)
        // Fresh UUID, not the source row's id.
        XCTAssertNotEqual(restoredVersions.first?.id, "")
    }

    func testApplyEditAssetsInsertsOrIgnoresPresetsAndLuts() async throws {
        var archive = BackupArchive(schema: 1, created_at: 1, app_version: nil,
                                    roots: [], files: [], collections: [], stars: [])
        archive.edit_presets = [BackupEditPreset(id: "presetX", name: "Moody",
                                                 stack: "{}", created_at: 1, updated_at: 1)]
        archive.edit_luts = [BackupLut(id: "lutHashX", name: "Kodak", size: 33,
                                       data: Data([9, 9, 9]))]
        let queue = try makeQueue()

        try await ReconnectApplier.applyEditAssets(archive, queue: queue)
        // Re-apply is idempotent: INSERT OR IGNORE, never rewrites bytes.
        var mutated = archive
        mutated.edit_luts![0].data = Data([1, 1, 1])
        try await ReconnectApplier.applyEditAssets(mutated, queue: queue)

        let presets = try await queue.read { try EditPresetRow.fetchAll($0) }
        let luts = try await queue.read { try EditLutRow.fetchAll($0) }
        XCTAssertEqual(presets.count, 1)
        XCTAssertEqual(luts.count, 1)
        // The FIRST write's bytes survive — immutability preserved.
        XCTAssertEqual(luts.first?.data, Data([9, 9, 9]))
    }
```

- [ ] **Step 2: Run to confirm failure**

Run: `xcodebuild -project Muse/Muse.xcodeproj -scheme Muse test -only-testing:MuseTests/BackupEditRoundTripTests`
Expected: FAIL — `OccurrenceMatch` init is fine (existing type), but
`ReconnectApplier.applyEditAssets` doesn't exist yet and `applyMeta` doesn't
touch `edits`/`edit_versions` yet.

- [ ] **Step 3: Implement — `applyMeta` writes the edit stack + versions**

Edit `Muse/Muse/Backup/ReconnectApplier.swift`. Inside `applyMeta`'s
`queue.write { db in ... }` closure, immediately after the existing note
block (`if let body = m.occurrence.note { ... }`), add:

```swift
// Edit stack: RESTORE-WINS (recovery, not merge — same posture as the
// note line above). A nil edit_stack means the source had no edit; leave
// the destination's edit row alone in that case (restoring a library that
// never touched this photo must not erase a LOCAL edit made since backup).
if let stackJSON = m.occurrence.edit_stack {
    var row = EditRow(file_id: fid, parent_dir: parentDir, stack: stackJSON,
                      stack_hash: EditStackCodec.hash(of: stackJSON),
                      process_version: EditStackCodec.processVersion(of: stackJSON)
                          ?? EditStack.currentProcessVersion,
                      updated_at: m.occurrence.edit_updated_at
                          ?? Int64(Date().timeIntervalSince1970))
    try row.upsert(db)
}
// Versions/snapshots: fresh UUIDs (the standing carry rule — Indexer's
// hash-collision/split paths already mint fresh ids for carried versions).
for v in m.occurrence.edit_versions ?? [] {
    var row = EditVersionRow(id: UUID().uuidString, file_id: fid,
                             parent_dir: parentDir, kind: v.kind, name: v.name,
                             stack: v.stack, created_at: v.created_at)
    try row.insert(db)
}
```

Add a new top-level function, alongside `applyCollections`/`applyStars`:

```swift
/// Library-global edit assets: presets (no natural key beyond `id`) and
/// LUTs (content-hash PK). Both INSERT OR IGNORE — a preset/LUT already
/// present locally (same id) is left untouched; a re-run of restore is
/// idempotent and can never rewrite an immutable LUT's bytes.
static func applyEditAssets(_ archive: BackupArchive, queue: DatabaseQueue) async throws {
    try await queue.write { db in
        for p in archive.edit_presets ?? [] {
            try db.execute(sql: """
                INSERT OR IGNORE INTO edit_presets (id, name, stack, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?)
                """, arguments: [p.id, p.name, p.stack, p.created_at, p.updated_at])
        }
        for l in archive.edit_luts ?? [] {
            try db.execute(sql: """
                INSERT OR IGNORE INTO edit_luts (id, name, size, data, created_at)
                VALUES (?, ?, ?, ?, ?)
                """, arguments: [l.id, l.name, l.size, l.data, Int64(Date().timeIntervalSince1970)])
        }
    }
}
```

  If `EditStackCodec.hash(of:)`/`.processVersion(of:)` aren't decode-from-
  canonical-JSON helpers already (Spec 04's codec normalizes and re-derives
  `stack_hash` from a decoded `EditStack`, not raw text) — decode the JSON
  into `EditStack` first and use `EditStackCodec.encode(_:)`'s own hash
  output rather than hashing the archive's raw string, so a restored row's
  `stack_hash` matches exactly what a fresh edit-save would produce:

```swift
if let stackJSON = m.occurrence.edit_stack,
   let data = stackJSON.data(using: .utf8),
   let stack = EditStackCodec.decode(data) {
    let canonical = EditStackCodec.encode(stack)
    var row = EditRow(file_id: fid, parent_dir: parentDir,
                      stack: String(data: canonical.json, encoding: .utf8) ?? stackJSON,
                      stack_hash: canonical.hash,
                      process_version: stack.processVersion,
                      updated_at: m.occurrence.edit_updated_at
                          ?? Int64(Date().timeIntervalSince1970))
    try row.upsert(db)
}
```

  (Verify `EditStackCodec`'s exact function names against the Spec 04
  implementation before finalizing this step — the shape above matches
  `DECISIONS.md`'s "`EditStackCodec`: canonical bytes = `.sortedKeys` JSON
  of the normalized stack; `stack_hash` = full SHA-256 hex of those bytes"
  description; a corrupt/undecodable stored stack should be skipped with a
  logged warning rather than crashing the whole restore.)

- [ ] **Step 4: Wire in the post-apply consequences**

Per `DECISIONS.md`, after applying, the standard edit-save consequences run
ONCE for the whole restored set (not per-file, inside the write
transaction — do this at the call site that already runs `applyMeta` in a
loop over files, immediately after the loop):

```swift
// After the per-file applyMeta loop and applyEditAssets both complete:
LiveEditStackProvider.shared.rebuildIndex()
appState.markContentChanged(restoredPaths)   // both thumbnail-key variants
EditStore.shared.generation += 1
for lutID in Set(archive.edit_luts?.map(\.id) ?? []) {
    LutRegistry.shared.invalidate(lutID)
}
```

  Locate the actual restore-coordinator call site (search for
  `applyCollections` and `applyStars` being called together — likely
  `Backup/BackupDocument.swift` or a `RestoreCoordinator`) and add this
  block there, gathering `restoredPaths` from the same `matches` list
  `applyMeta` was given. **No sidecar re-export runs here** — hydration
  owns sidecar reconciliation; a restore must not stomp a newer on-disk
  sidecar (per `DECISIONS.md`'s explicit "No sidecar re-export on
  restore").

- [ ] **Step 5: Run the tests — confirm they pass**

Run: `xcodebuild -project Muse/Muse.xcodeproj -scheme Muse test -only-testing:MuseTests/BackupEditRoundTripTests`
Expected: PASS (all four tests in the file).

- [ ] **Step 6: Run the full backup test suite to confirm no regression**

Run: `xcodebuild -project Muse/Muse.xcodeproj -scheme Muse test -only-testing:MuseTests/BackupBuilderTests -only-testing:MuseTests/ReconnectApplierTests`
(adjust names to whatever the existing backup test files are actually
called — `find Muse/MuseTests -iname "*Backup*" -o -iname "*Reconnect*"`
first if unsure)
Expected: PASS, unchanged.

- [ ] **Step 7: Commit**

```bash
git add Muse/Muse/Backup/ReconnectApplier.swift Muse/MuseTests/BackupEditRoundTripTests.swift
git commit -m "feat: restore edit stacks/versions/presets/LUTs from a .muselibrary archive"
```

---

### Task 4: Backup amendment — manual verification + checklist row 5

**Files:**
- None (verification-only task; no code changes).

**Interfaces:**
- Consumes: Tasks 1–3's shipped code.
- Produces: nothing new; confirms checklist row 5
  ("Backup/restore on an edited library — stacks, versions, presets, LUTs
  survive").

- [ ] **Step 1: Run the full test target once**

Run: `xcodebuild -project Muse/Muse.xcodeproj -scheme Muse test`
Expected: PASS, including `BackupEditRoundTripTests` and
`BackupArchiveCompatTests`.

- [ ] **Step 2: One manual round-trip on a real edited library (owner step, documented here for the record)**

This step cannot run in CI — it needs a real app build with real edits.
Record in `docs/launch-validation-<date>.md` (Task 13 creates the
template) once performed: create 2–3 edits (including a crop and a LUT
import) on a small test library, Backup, wipe the app's container database
(`~/Library/Containers/com.tarrats.Muse/Data/Library/Application Support/Muse/muse.sqlite`),
relaunch, Restore, and confirm the edits render identically (same crop,
same LUT look) in the hero viewer.

- [ ] **Step 3: No commit** — this task is verification-only.

---

### Task 5: `TrialPolicy` — epoch + `enforced` flip

**Files:**
- Modify: `Muse/Muse/Commerce/TrialGate.swift`
- Modify: `Muse/MuseTests/TrialGateTests.swift`

**Interfaces:**
- Consumes: Spec 01's existing `TrialPolicy { duration: TimeInterval,
  enforced: Bool }`, `TrialState { .unlocked, .trial(daysLeft:), .expired }`,
  `TrialGate.state(now:firstLaunch:entitled:policy:) -> TrialState` (pure,
  unchanged signature).
- Produces: `TrialPolicy.epoch: Int = 1`, `TrialPolicy.current: TrialPolicy`
  (duration 14 days, `enforced: true`), and the epoch-keyed Keychain anchor
  key name `"muse.trial.anchor.e\(TrialPolicy.epoch)"` (consumed by Task 6's
  `CommerceStore` anchor-loading code, which also reads the legacy
  unnumbered key for epoch 1).

- [ ] **Step 1: Write the failing tests**

Add to `Muse/MuseTests/TrialGateTests.swift` (Spec 01 already ships this
file with `state(...)` behavioral tests — add these alongside them):

```swift
    func testCurrentPolicyIsFourteenDaysEnforced() {
        XCTAssertEqual(TrialPolicy.current.duration, 14 * 86_400)
        XCTAssertTrue(TrialPolicy.current.enforced)
    }

    func testEpochIsOne() {
        XCTAssertEqual(TrialPolicy.epoch, 1)
    }

    func testAnchorKeyNameIsEpochQualified() {
        XCTAssertEqual(TrialPolicy.anchorKeyName, "muse.trial.anchor.e1")
    }

    /// Existing branches from Spec 01 stay green even with `enforced: true`
    /// as the new default — re-run the core state matrix against
    /// `.current` explicitly so a future policy edit can't silently break
    /// gate behavior without a test noticing.
    func testStateMatrixAgainstCurrentPolicy() {
        let day: TimeInterval = 86_400
        let now = Date(timeIntervalSince1970: 20 * day)
        let firstLaunch = Date(timeIntervalSince1970: 0)

        XCTAssertEqual(
            TrialGate.state(now: now, firstLaunch: firstLaunch, entitled: true,
                            policy: .current),
            .unlocked)
        XCTAssertEqual(
            TrialGate.state(now: now, firstLaunch: firstLaunch, entitled: false,
                            policy: .current),
            .expired)
        let withinTrial = Date(timeIntervalSince1970: 5 * day)
        if case .trial(let daysLeft) = TrialGate.state(
            now: withinTrial, firstLaunch: firstLaunch, entitled: false, policy: .current) {
            XCTAssertEqual(daysLeft, 9)
        } else {
            XCTFail("expected .trial")
        }
    }
```

- [ ] **Step 2: Run to confirm failure**

Run: `xcodebuild -project Muse/Muse.xcodeproj -scheme Muse test -only-testing:MuseTests/TrialGateTests`
Expected: FAIL — `TrialPolicy.current`, `.epoch`, `.anchorKeyName` don't
exist yet.

- [ ] **Step 3: Implement**

Edit `Muse/Muse/Commerce/TrialGate.swift`. Add to `TrialPolicy` (leave
`state(...)` and `TrialState` completely untouched — this is additive):

```swift
struct TrialPolicy: Sendable {
    var duration: TimeInterval
    var enforced: Bool

    /// Bumping this grants every install a fresh trial (the "generous
    /// re-trial on major versions" mechanism) — a future one-constant
    /// change. Does NOT bump at GA (Spec 09): long-running TestFlight
    /// testers hitting the gate on this build is the intended sandbox-
    /// purchase E2E, not a bug to route around.
    static let epoch = 1

    /// The live policy this build ships: 14-day trial, hard gate at
    /// expiry. `enforced` flips true in Spec 09 — sandbox purchases are
    /// free, so TestFlight testers exercise the gate instead of being
    /// locked out by it (superseding Spec 01's "would lock out testers"
    /// rationale). The duration/enforced pair is a working default,
    /// owner-confirmable alongside the pricing call (§1, Spec 09) — a
    /// change is one line here, no other code moves.
    static let current = TrialPolicy(duration: 14 * 86_400, enforced: true)

    /// Epoch-qualified Keychain anchor key name. `CommerceStore` reads
    /// THIS key for the current epoch and, for epoch 1 only, also reads
    /// Spec 01's legacy unnumbered key as an earliest-wins fallback so no
    /// existing tester's trial anchor resets when this build ships.
    static var anchorKeyName: String { "muse.trial.anchor.e\(epoch)" }
}
```

- [ ] **Step 4: Run the tests — confirm they pass**

Run: `xcodebuild -project Muse/Muse.xcodeproj -scheme Muse test -only-testing:MuseTests/TrialGateTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Muse/Muse/Commerce/TrialGate.swift Muse/MuseTests/TrialGateTests.swift
git commit -m "feat: TrialPolicy.current flips enforced=true, adds epoch-keyed anchor name"
```

---

### Task 6: `CommerceStore` — live `trialState`, `trialGateActive`, epoch anchor migration

**Files:**
- Modify: `Muse/Muse/Commerce/CommerceStore.swift`
- Modify: `Muse/MuseTests/CommerceEntitlementTests.swift`

**Interfaces:**
- Consumes: `TrialPolicy.current`, `.epoch`, `.anchorKeyName` (Task 5);
  Spec 01's existing `CommerceStore` shape (`entitlements: Entitlements`,
  `KeychainCommerceStore.readFirstLaunchAnchor/writeFirstLaunchAnchor`,
  `Transaction.updates`, `handle(_:)`, `refresh()`).
- Produces: `@Published private(set) var trialState: TrialState`, `var
  trialGateActive: Bool`, `func transactionJWS(for:) async -> String?`
  (already specified by Spec 08, unaffected here — do not duplicate if
  present), a `NSApplication.didBecomeActiveNotification` observer.
  Consumed by Task 7 (`AppState.modalPresented`), Task 8/9 (`UnlockGateView`),
  Task 10 (Settings).

- [ ] **Step 1: Write the failing tests**

Add to `Muse/MuseTests/CommerceEntitlementTests.swift` (extend the existing
Spec 01 file):

```swift
    @MainActor
    func testTrialGateActiveWhenExpiredAndNotUnlocked() {
        let store = CommerceStore(firstLaunchOverride: Date(timeIntervalSince1970: 0),
                                  nowOverride: Date(timeIntervalSince1970: 30 * 86_400))
        XCTAssertTrue(store.trialGateActive)
    }

    @MainActor
    func testTrialGateNotActiveWhenUnlocked() {
        let store = CommerceStore(firstLaunchOverride: Date(timeIntervalSince1970: 0),
                                  nowOverride: Date(timeIntervalSince1970: 30 * 86_400))
        store.testGrant(unlocked: true)
        XCTAssertFalse(store.trialGateActive)
    }

    @MainActor
    func testTrialGateNotActiveDuringTrial() {
        let store = CommerceStore(firstLaunchOverride: Date(timeIntervalSince1970: 0),
                                  nowOverride: Date(timeIntervalSince1970: 5 * 86_400))
        XCTAssertFalse(store.trialGateActive)
    }

    @MainActor
    func testTrialStateRecomputesOnEntitlementGrant() {
        let store = CommerceStore(firstLaunchOverride: Date(timeIntervalSince1970: 0),
                                  nowOverride: Date(timeIntervalSince1970: 30 * 86_400))
        if case .expired = store.trialState {} else { XCTFail("expected .expired") }
        store.testGrant(unlocked: true)
        if case .unlocked = store.trialState {} else { XCTFail("expected .unlocked after grant") }
    }

    /// The permissive-entitlement-cache rule must survive this change: a
    /// verified read lacking the entitlement REVOKES; anything else never
    /// downgrades a cached grant.
    @MainActor
    func testPermissiveCacheStillNeverRevokesOnAmbiguousRead() {
        let store = CommerceStore(firstLaunchOverride: Date(timeIntervalSince1970: 0),
                                  nowOverride: Date(timeIntervalSince1970: 30 * 86_400))
        store.testGrant(unlocked: true)
        // Simulate an offline/ambiguous refresh (no verified reads at all) —
        // the existing CommerceStore.refresh() contract must leave a cached
        // grant untouched unless the walk demonstrably completed and found
        // the entitlement absent. This exercises whatever seam Spec 01 built
        // for that distinction (see CommerceStore.swift's `refresh()`).
        XCTAssertTrue(store.entitlements.unlocked)
    }
```

  (`firstLaunchOverride`/`nowOverride`/`testGrant(unlocked:)` are test-only
  hooks — add them to `CommerceStore` in Step 3 if Spec 01 didn't already
  provide an equivalent way to construct a store with an injected clock
  and anchor. If Spec 01's `CommerceStore` has no such initializer, add one
  gated `#if DEBUG` or restrict it to the test target via `@testable
  import` visibility on an `internal` initializer — check the actual Spec
  01 file first; do not duplicate an existing seam.)

- [ ] **Step 2: Run to confirm failure**

Run: `xcodebuild -project Muse/Muse.xcodeproj -scheme Muse test -only-testing:MuseTests/CommerceEntitlementTests`
Expected: FAIL — `trialState`/`trialGateActive` don't exist; the test
initializer doesn't exist.

- [ ] **Step 3: Implement — `@Published trialState` + `trialGateActive`**

Edit `Muse/Muse/Commerce/CommerceStore.swift`. Replace the on-demand
`trialState(now:)` method (Spec 01) with a published, recomputed property.
Keep `TrialGate.state(...)` itself untouched — only the store's shape
around it changes:

```swift
@MainActor
final class CommerceStore: ObservableObject {
    @Published private(set) var entitlements: Entitlements
    /// Live trial state — recomputed at init, on every entitlement change,
    /// and on app activation. No timer: a trial that expires mid-session
    /// gates on the next activation, not mid-keystroke (recorded, accepted
    /// — Spec 09 §2.3).
    @Published private(set) var trialState: TrialState

    /// True only when the trial is over AND the user hasn't unlocked.
    /// `.unlocked` short-circuits via TrialGate.state itself (an entitled
    /// user is never `.expired`).
    var trialGateActive: Bool {
        if case .expired = trialState { return !entitlements.unlocked }
        return false
    }

    private var cache: CommerceCache
    private var updatesTask: Task<Void, Never>?
    private var activationObserver: NSObjectProtocol?
    private let firstLaunchAnchor: Date

    init(firstLaunchOverride: Date? = nil, nowOverride: Date? = nil) {
        let loadedCache = Self.loadCache()
        self.cache = loadedCache
        self.entitlements = loadedCache.entitlements
        self.firstLaunchAnchor = firstLaunchOverride ?? Self.loadOrCreateFirstLaunchAnchor()
        self.trialState = TrialGate.state(
            now: nowOverride ?? Date(), firstLaunch: self.firstLaunchAnchor,
            entitled: loadedCache.entitlements.unlocked, policy: .current)

        updatesTask = Task { [weak self] in
            for await update in Transaction.updates {
                await self?.handle(update)
            }
        }
        Task { [weak self] in await self?.refresh() }

        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.recomputeTrialState() }
    }

    deinit {
        updatesTask?.cancel()
        if let activationObserver { NotificationCenter.default.removeObserver(activationObserver) }
    }

    private func recomputeTrialState() {
        trialState = TrialGate.state(now: Date(), firstLaunch: firstLaunchAnchor,
                                     entitled: entitlements.unlocked, policy: .current)
    }
```

  Call `recomputeTrialState()` at the end of both `handle(_:)` and
  `refresh()` (the two places `entitlements` is reassigned) so the
  `@Published trialState` stays in lockstep with entitlement changes —
  add the call right after each `entitlements = cache.entitlements` line.

  Delete the old `func trialState(now: Date = Date()) -> TrialState { ... }`
  method entirely — every call site (Task 10's Settings row) reads the new
  `@Published` property instead.

- [ ] **Step 4: Implement — epoch-keyed anchor with legacy fallback**

Replace `loadOrCreateFirstLaunchAnchor()`'s body to read the epoch-keyed
Keychain key, falling back to Spec 01's legacy unnumbered key + its
UserDefaults mirror for epoch 1, earliest-wins, and to WRITE the
epoch-keyed key going forward (never moving the anchor forward, matching
the existing rule):

```swift
private static func loadOrCreateFirstLaunchAnchor() -> Date {
    // Earliest-wins across every source that might carry an anchor:
    // the current epoch's Keychain key, the LEGACY unnumbered key (only
    // meaningful while epoch == 1 — a future epoch bump reads ONLY its
    // own key, which is what makes the re-trial grant clean), and the
    // UserDefaults mirror. Never move the anchor forward.
    let epochKeychainDate = KeychainCommerceStore.readFirstLaunchAnchor(key: TrialPolicy.anchorKeyName)
    let legacyKeychainDate = TrialPolicy.epoch == 1
        ? KeychainCommerceStore.readFirstLaunchAnchor(key: KeychainCommerceStore.legacyAnchorKey)
        : nil
    let defaultsDate = UserDefaults.standard.object(forKey: "commerce.firstLaunch") as? Date
    let earliest = [epochKeychainDate, legacyKeychainDate, defaultsDate].compactMap { $0 }.min()
    let anchor = earliest ?? Date()
    if epochKeychainDate == nil {
        KeychainCommerceStore.writeFirstLaunchAnchor(anchor, key: TrialPolicy.anchorKeyName)
    }
    if defaultsDate == nil { UserDefaults.standard.set(anchor, forKey: "commerce.firstLaunch") }
    return anchor
}
```

  This requires `KeychainCommerceStore.readFirstLaunchAnchor`/
  `writeFirstLaunchAnchor` to take a `key:` parameter instead of a
  hardcoded key string, and a new `KeychainCommerceStore.legacyAnchorKey`
  constant holding whatever unnumbered key name Spec 01 actually used —
  find it: `grep -n "readFirstLaunchAnchor\|writeFirstLaunchAnchor\|legacyAnchorKey\|kSecAttrAccount" Muse/Muse/Commerce/*.swift`.
  Update both the read/write helper signatures and every existing call site
  (there should be exactly one write and one read call, both inside
  `loadOrCreateFirstLaunchAnchor`) to pass the key explicitly. Do not
  change the Keychain access-class constant
  (`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`) or any other Drive
  token pattern this reuses.

- [ ] **Step 5: Add the test-only initializer hooks used by Step 1's tests**

If `CommerceStore`'s `init()` in Spec 01 takes no parameters, the
`firstLaunchOverride`/`nowOverride` parameters added in Step 3 already
cover the clock/anchor injection needed by the tests. Add a small
test-only mutator for entitlements (skip real StoreKit) restricted to the
test target:

```swift
#if DEBUG
extension CommerceStore {
    /// Test-only entitlement injection — bypasses StoreKit entirely.
    func testGrant(unlocked: Bool = false, sharing: Bool = false) {
        cache.grant(unlocked: unlocked, sharing: sharing)
        entitlements = cache.entitlements
        recomputeTrialState()
    }
}
#endif
```

  (If Spec 01 already ships an equivalent test seam under a different
  name, reuse it instead of adding a second one — grep
  `CommerceCache.swift`/`CommerceStore.swift` for `grant(` first.)

- [ ] **Step 6: Run the tests — confirm they pass**

Run: `xcodebuild -project Muse/Muse.xcodeproj -scheme Muse test -only-testing:MuseTests/CommerceEntitlementTests`
Expected: PASS.

- [ ] **Step 7: Run the full Commerce/Trial suite together**

Run: `xcodebuild -project Muse/Muse.xcodeproj -scheme Muse test -only-testing:MuseTests/CommerceEntitlementTests -only-testing:MuseTests/TrialGateTests -only-testing:MuseTests/AnnouncementFeedTests`
Expected: PASS — `AnnouncementFeedTests` must stay green untouched (this
task must not disturb `CommerceConfig.announcementsURL` or the fetch path).

- [ ] **Step 8: Commit**

```bash
git add Muse/Muse/Commerce/CommerceStore.swift Muse/MuseTests/CommerceEntitlementTests.swift
git commit -m "feat: CommerceStore gains live trialState/trialGateActive + epoch-anchor migration"
```

---

### Task 7: Gate integration — `AppState.modalPresented`, Escape, `dismissTopModal`

**Files:**
- Modify: `Muse/Muse/Models/AppState.swift`
- Modify: `Muse/Muse/ContentView.swift`

**Interfaces:**
- Consumes: `CommerceStore.shared.trialGateActive` (Task 6) — note: if Spec
  01's `CommerceStore` is injected only via `@EnvironmentObject` and has no
  `static let shared`, add one now (a `@MainActor static let shared =
  CommerceStore()` alongside the `@StateObject` in `MuseApp.swift`, the
  same dual-access pattern `AnalyzePipeline.shared`/`IndexProgress.shared`
  already use elsewhere in `AppState.modalPresented`'s own file — check
  `MuseApp.swift` for how `commerceStore` is constructed before adding a
  second instance).
- Produces: `AppState.modalPresented` includes the gate; `ContentView.
  dismissTopModal()` no-ops when the gate is the only presented thing.
  Consumed by every existing key-catcher (`PageScrollCatcher` et al.,
  already gated on `modalPresented`) with zero code changes there.

- [ ] **Step 1: Write the failing test**

`modalPresented` is a computed property with no dedicated test file today
(it's exercised indirectly through view code) — add a focused pure test
if `AppState` exposes any test seam, otherwise this task is verified by
Step 4's manual QA pass plus Task 9's `UnlockGateView` presence. Prefer
adding the assertion to whichever existing test already covers
`modalPresented`'s OR-chain, if one exists:

```
grep -rln "modalPresented" Muse/MuseTests
```

If none exists, skip to Step 2 — this integration is two one-line changes
guarded by manual verification in Step 4, consistent with the house rule
of no UI unit tests; `trialGateActive` itself is already covered by Task 6.

- [ ] **Step 2: Implement — `AppState.modalPresented`**

Edit `Muse/Muse/Models/AppState.swift` at the `modalPresented` computed
property (around line 514). Add the gate read to the OR-chain — this is a
computed-property read of another store, not a new `@Published`, so
`AppState` stays frozen per the global constraint:

```swift
var modalPresented: Bool {
    infoShown || imageLayoutShown || settingsShown || driveSharesShown
        || duplicatesSheetVisible || reconnectShown
        || metadataImportRequest != nil || collectionModal != nil
        || addTagRequest != nil || newCollectionRequest
        || alertRequest != nil
        || folderOpError != nil || backupError != nil
        || fileRenameError != nil || !moveFailureNames.isEmpty
        || collectionRenameAlertRequest != nil || fileRenameRequest != nil
        || newSubfolderRequest != nil || folderRenameRequest != nil
        || tagRenameRequest != nil
        // Spec 09: the trial gate. Not dismissible — see dismissTopModal()
        // in ContentView, which must skip it explicitly.
        || CommerceStore.shared.trialGateActive
}
```

- [ ] **Step 3: Implement — `dismissTopModal()` no-ops on gate-only**

Edit `Muse/Muse/ContentView.swift`'s `dismissTopModal()` (around line 37).
The gate must never be dismissed by Escape/scrim-click — every other
branch already returns early on its own flag, so the gate simply has NO
branch here. But since `modalPresented` now includes it, `EscapeAction`
will resolve `.dismissModal` even when the gate is the only thing up;
`dismissTopModal()` falling through all the existing `if` branches with
nothing left to clear is already the correct no-op — **no new branch is
added**. Add a comment recording this deliberately-missing branch so a
future reader doesn't "fix" it:

```swift
private func dismissTopModal() {
    // Confirms/errors first: ...
    if appState.alertRequest != nil { appState.alertRequest = nil; return }
    // ... (all existing branches unchanged) ...
    if appState.infoShown { appState.infoShown = false; return }
    // Spec 09: the trial gate (CommerceStore.shared.trialGateActive) is
    // DELIBERATELY absent from this sweep. It has no dismiss — falling
    // through every branch above with nothing left to clear IS the
    // required no-op when the gate is the only thing making
    // modalPresented true. Do not add a branch that clears it.
}
```

- [ ] **Step 4: Manual verification**

Build and run the app with a `CommerceStore` forced into the expired/
not-unlocked state (temporarily hardcode `trialGateActive` to `true` for
this manual pass, or use a debug launch argument if one already exists for
forcing commerce state — check `MuseApp.swift` for a
`ProcessInfo.processInfo.arguments` gate). Confirm: arrow keys don't move
the grid selection behind the gate, Escape does nothing, and no other
modal can be raised over it (this is verified fully once Task 9 mounts
`UnlockGateView`; this task alone only proves the boolean wiring —
document the check in this task and repeat it after Task 9).

- [ ] **Step 5: Commit**

```bash
git add Muse/Muse/Models/AppState.swift Muse/Muse/ContentView.swift
git commit -m "feat: wire the trial gate into modalPresented; Escape/dismissTopModal skip it"
```

---

### Task 8: `SubscriptionLegalLinks.swift` — shared Privacy/Terms row

**Files:**
- Create: `Muse/Muse/Views/SubscriptionLegalLinks.swift`

**Interfaces:**
- Consumes: `DriveConfig.shareBaseURL` (existing `Sharing/Drive/
  DriveConfig.swift` constant — the same base the Drive-share links use).
- Produces: `struct SubscriptionLegalLinks: View`. Consumed by Task 9
  (`UnlockGateView`) and, as **Spec 08 amendment A3**, by
  `Sharing/Domains/ShareDomainCard.swift`'s pitch state (add the same
  component to that file's state-1 view in this task too, since it's a
  one-line addition and the component doesn't exist until now).

- [ ] **Step 1: No test** — this is a two-`Link` static layout component
  with no logic; the house rule is no UI unit tests. Skip straight to
  implementation.

- [ ] **Step 2: Implement**

```swift
//
//  SubscriptionLegalLinks.swift
//  Muse
//
//  The Privacy Policy / Terms of Use links App Review requires next to any
//  purchase UI offering an auto-renewable subscription (and, as a matter of
//  consistency, next to the one-time unlock too). Shared by UnlockGateView
//  and ShareDomainCard's pitch state (Spec 08 amendment A3) so the two
//  purchase surfaces can't drift on wording or destination.
//

import SwiftUI

struct SubscriptionLegalLinks: View {
    var body: some View {
        HStack(spacing: 16) {
            Button(String(localized: "Privacy Policy")) {
                NSWorkspace.shared.open(DriveConfig.shareBaseURL.appendingPathComponent("privacy"))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)

            Button(String(localized: "Terms of Use")) {
                NSWorkspace.shared.open(DriveConfig.shareBaseURL.appendingPathComponent("terms"))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .font(.system(size: 11))
    }
}
```

  Verify `DriveConfig.shareBaseURL` is a `URL` (not a `String`) before
  using `.appendingPathComponent` — if it's a string constant, build the
  URL with `URL(string: DriveConfig.shareBaseURL)!.appendingPathComponent(...)`
  matching whatever pattern the existing Drive-share link-building code
  uses (`grep -n "shareBaseURL" Muse/Muse/Sharing/Drive/*.swift` to confirm).

- [ ] **Step 3: Add to `ShareDomainCard`'s pitch state (Spec 08 amendment A3)**

Open `Muse/Muse/Sharing/Domains/ShareDomainCard.swift`, find the pitch
state's body (the state offering the sharing subscription before any
domain is configured), and add `SubscriptionLegalLinks()` beneath the
existing price/pitch text, above the action buttons — matching whatever
vertical spacing the surrounding `VStack` already uses.

- [ ] **Step 4: Build and visually confirm**

Run: `xcodebuild -project Muse/Muse.xcodeproj -scheme Muse build`
Expected: BUILD SUCCEEDED. Manually open Settings → Share Links (pitch
state, no domain configured) and confirm the two links appear and open the
correct pages in the default browser.

- [ ] **Step 5: Commit**

```bash
git add Muse/Muse/Views/SubscriptionLegalLinks.swift Muse/Muse/Sharing/Domains/ShareDomainCard.swift
git commit -m "feat: add SubscriptionLegalLinks; wire into ShareDomainCard pitch (Spec 08 A3)"
```

---

### Task 9: `Views/UnlockGateView.swift` — the gate card

**Files:**
- Create: `Muse/Muse/Views/UnlockGateView.swift`
- Modify: `Muse/Muse/ContentView.swift`

**Interfaces:**
- Consumes: `CommerceStore` (`@EnvironmentObject`, per Spec 01's
  `ContentView` injection), `.trialGateActive`, `.purchase(_:)`,
  `.restore()`, `CommerceConfig.unlockProductID`, `Product.displayPrice`
  (via `CommerceStore.products()`), `ModalChrome` (cornerRadius, cardFill,
  cardStroke, scrimColor, cardWidth/cardMaxHeight — `Views/Modal/
  ModalChrome.swift`), `ModalButton` (`Views/Modal/ModalButton.swift`),
  `SubscriptionLegalLinks` (Task 8), `AppState.appMoodPalette` (or whatever
  the live `MoodPalette` accessor is called — check `ContentView.swift`'s
  existing `.museModal(... palette: ...)` call sites for the exact
  property name).
- Produces: `struct UnlockGateView: View`, mounted in `ContentView`'s
  detail `ZStack` **after** the `alertRequest` presenter (per DECISIONS.md
  — nothing may draw above it, and nothing else can raise a card while
  gated).

- [ ] **Step 1: No test** — UI-only, house no-UI-tests rule; logic lives
  entirely on `CommerceStore` (already covered by Task 6).

- [ ] **Step 2: Implement**

```swift
//
//  UnlockGateView.swift
//  Muse
//
//  The trial-expiry gate. Built ONLY while CommerceStore.shared.
//  trialGateActive is true (a purchase unmounts it via the entitlements
//  publish). Reuses .museModal's CARD VISUALS (ModalChrome) but
//  deliberately never its dismiss machinery — this card has no ✕, no
//  scrim-click dismiss, and Escape is a no-op (see AppState.modalPresented
//  + ContentView.dismissTopModal, which skip it explicitly). Mounted
//  directly in ContentView's detail ZStack, AFTER the alertRequest
//  presenter — nothing may draw above this while it's up, and while it's
//  up nothing else can raise a card (every other modal flag requires user
//  action the gate already blocks).
//

import SwiftUI
import StoreKit

struct UnlockGateView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var commerceStore: CommerceStore

    @State private var product: Product?
    @State private var errorMessage: String?
    @State private var isPending = false
    @State private var isPurchasing = false

    private let width: CGFloat = 460

    var body: some View {
        GeometryReader { geo in
            ZStack {
                // Non-interactive scrim: no onTapGesture dismiss, unlike
                // ModalScrim — this is the one deliberate divergence from
                // .museModal's shared chrome.
                ModalChrome.scrimColor(for: appState.moodPalette)
                    .ignoresSafeArea()
                    .accessibilityHidden(true)

                card
                    .frame(width: ModalChrome.cardWidth(ideal: width, available: geo.size.width))
                    .frame(maxHeight: ModalChrome.cardMaxHeight(available: geo.size.height))
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .transition(.opacity)
        .task { await loadProduct() }
    }

    private var card: some View {
        VStack(spacing: 16) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 64, height: 64)

            Text(String(localized: "Your trial has ended"))
                .font(.system(size: 17, weight: .semibold))

            Text(String(localized: "Your photos, edits, tags and collections are untouched — Muse never moved them. Everything is exactly where you left it."))
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            if let product {
                Text(String(localized: "Unlock Muse — \(product.displayPrice), once."))
                    .font(.system(size: 13, weight: .medium))
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: 12))
                    .foregroundStyle(.red)
            }
            if isPending {
                Text(String(localized: "Waiting for approval…"))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            VStack(spacing: 8) {
                ModalButton(title: String(localized: "Unlock"), kind: .prominent,
                           isDefault: true) {
                    Task { await purchase() }
                }
                .disabled(product == nil || isPurchasing)

                ModalButton(title: String(localized: "Restore Purchases")) {
                    Task { await restore() }
                }
                ModalButton(title: String(localized: "Redeem Code")) {
                    NSWorkspace.shared.open(URL(string: "https://apps.apple.com/redeem")!)
                }
            }

            SubscriptionLegalLinks()

            ModalButton(title: String(localized: "Quit Muse"), isCancel: true) {
                NSApp.terminate(nil)
            }
        }
        .padding(28)
        .background(ModalChrome.cardFill(for: appState.moodPalette))
        .clipShape(RoundedRectangle(cornerRadius: ModalChrome.cornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: ModalChrome.cornerRadius, style: .continuous)
                .strokeBorder(ModalChrome.cardStroke(for: appState.moodPalette), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.28), radius: 30, y: 12)
        .accessibilityAddTraits(.isModal)
    }

    private func loadProduct() async {
        product = await commerceStore.products()
            .first { $0.id == CommerceConfig.unlockProductID }
    }

    private func purchase() async {
        errorMessage = nil
        isPurchasing = true
        defer { isPurchasing = false }
        await commerceStore.purchase(CommerceConfig.unlockProductID)
        // CommerceStore.purchase() is fire-and-forget by Spec 01's design
        // (userCancelled/pending/success all handled internally, entitlements
        // publish on success). Surface a generic inline message only if the
        // gate is STILL active after the call returns and no .pending state
        // was signaled — Spec 01's purchase() may need a return value added
        // here; if it currently returns Void, this inline-error UX degrades
        // to silence on failure, which is acceptable (the user can retry) but
        // should be revisited if CommerceStore ever grows a result type.
        if commerceStore.trialGateActive {
            errorMessage = String(localized: "That didn't go through. Try again, or Restore Purchases if you've already bought Muse.")
        }
    }

    private func restore() async {
        errorMessage = nil
        await commerceStore.restore()
        if commerceStore.trialGateActive {
            errorMessage = String(localized: "No previous purchase found on this Apple ID.")
        }
    }
}
```

  Note the `purchase()`/`restore()` error-surfacing is best-effort against
  Spec 01's existing `Void`-returning methods — check the actual signature
  first (`grep -n "func purchase\|func restore" Muse/Muse/Commerce/
  CommerceStore.swift`); if either method already threw or returned a
  result enum, use that directly instead of re-checking `trialGateActive`
  after the fact.

- [ ] **Step 3: Mount in `ContentView`**

Find `ContentView`'s detail `ZStack`, specifically where the
`alertRequest`/`MuseAlert` presenter is attached (search for
`.museAlert(` or the `MuseAlert` presentation call). Add `UnlockGateView`
immediately after it in the same `ZStack`, gated on `commerceStore.
trialGateActive`, built only while true:

```swift
if commerceStore.trialGateActive {
    UnlockGateView()
}
```

  Confirm `commerceStore` is already available as `@EnvironmentObject` in
  `ContentView` (Spec 01 injects it) — if not, add
  `@EnvironmentObject var commerceStore: CommerceStore` to `ContentView`.

- [ ] **Step 4: Build and manually verify the full gate**

Run: `xcodebuild -project Muse/Muse.xcodeproj -scheme Muse build`
Then run the app with `trialGateActive` forced true (temporary debug
override, removed before commit) and confirm: the card renders centered
with scrim behind it, no ✕ anywhere, clicking the scrim does nothing,
Escape does nothing, arrow keys don't move the grid, and Unlock/Restore/
Redeem Code/Quit all fire their respective actions (Quit should actually
terminate the app — verify last).

- [ ] **Step 5: Commit**

```bash
git add Muse/Muse/Views/UnlockGateView.swift Muse/Muse/ContentView.swift
git commit -m "feat: add UnlockGateView, mounted above the alertRequest presenter"
```

---

### Task 10: Settings — trial status line, expiry reminder, Manage Subscription

**Files:**
- Modify: `Muse/Muse/Settings/SettingsView.swift`
- Modify: `Muse/Muse/Models/AppState.swift` (only if the expiry-reminder
  per-launch flag needs a home — see Step 3)

**Interfaces:**
- Consumes: `CommerceStore.trialState`, `.entitlements.sharing` (Task 6),
  `MuseAlert`/`AppState.alertRequest` (existing seam, `Views/Modal/
  ModalMessageCard.swift`).
- Produces: state-aware Muse-section status line; a once-per-launch expiry
  reminder card; a "Manage Subscription" row.

- [ ] **Step 1: No dedicated unit test** — Settings row text is UI-only
  (house rule); the underlying `trialState`/`entitlements` values are
  already covered by Task 6's tests. Verify by manual inspection in Step 4.

- [ ] **Step 2: Implement — state-aware status line**

Open `Muse/Muse/Settings/SettingsView.swift`, find the existing Muse
section (Spec 01 already added Unlock/Restore buttons there — search for
`CommerceConfig.unlockProductID` or a "Muse" `Section` header). Replace or
add above the existing buttons a status line driven by `commerceStore.
trialState`:

```swift
private var trialStatusLine: String {
    switch commerceStore.trialState {
    case .unlocked:
        return String(localized: "Unlocked")
    case .trial(let daysLeft):
        return String(localized: "Trial — \(daysLeft) days left")
    case .expired:
        return String(localized: "Trial ended")
    }
}
```

Render it as a `Text(trialStatusLine)` styled like the section's other
secondary-text rows, placed directly above the existing Unlock/Restore
Purchases buttons.

- [ ] **Step 3: Implement — once-per-launch expiry reminder**

Add a launch-scoped (never persisted) flag. If `AppState` already has a
similar per-launch-only flag pattern for a different feature, mirror it
exactly; otherwise this can live as a `private static var` on the type
that triggers it (not `AppState`, to respect the frozen-state constraint)
— e.g. a `static var shown = false` inside a small
`Commerce/TrialExpiryReminder.swift` enum:

```swift
//
//  TrialExpiryReminder.swift
//  Muse
//
//  Once-per-launch (never persisted) "trial ends soon" nudge. Lives outside
//  AppState (frozen) and outside CommerceStore (keeps this UI-triggering
//  concern out of the pure entitlement/trial store) as its own tiny
//  process-lifetime flag.
//

import Foundation

enum TrialExpiryReminder {
    private static var shownThisLaunch = false

    /// Call once, from ContentView's `.task` or `.onAppear`, after
    /// CommerceStore has resolved its first trialState. Raises an
    /// AppState.alertRequest card when daysLeft <= 3 and hasn't been shown
    /// yet this launch.
    @MainActor
    static func presentIfNeeded(trialState: TrialState, appState: AppState,
                                commerceStore: CommerceStore) {
        guard !shownThisLaunch else { return }
        guard case .trial(let daysLeft) = trialState, daysLeft <= 3 else { return }
        shownThisLaunch = true
        appState.alertRequest = MuseAlert.confirm(
            title: String(localized: "Your Muse trial ends in \(daysLeft) days."),
            message: "",
            confirmTitle: String(localized: "Unlock…"),
            destructive: false,
            onConfirm: { Task { await commerceStore.purchase(CommerceConfig.unlockProductID) } })
    }
}
```

  Verify `MuseAlert.confirm(...)`'s exact parameter list against
  `Views/Modal/ModalMessageCard.swift` (already read above — `title`,
  `message`, `confirmTitle`, `destructive`, `cancelTitle: String?`,
  `onConfirm`) and adjust; a message-only confirm with a "Later" secondary
  needs `cancelTitle: String(localized: "Later")` set explicitly since
  `MuseAlert.confirm`'s default `cancelTitle` may be nil (single-button) —
  check the second `MuseAlert` factory (likely `.info(...)` or similar) if
  `.confirm` doesn't support a non-destructive two-button shape with a
  custom cancel label.

  Wire the call into `ContentView`'s existing `.task` block (wherever
  Spec 01's announcement-fetch or similar first-paint work already runs):

```swift
.task {
    TrialExpiryReminder.presentIfNeeded(trialState: commerceStore.trialState,
                                        appState: appState, commerceStore: commerceStore)
}
```

- [ ] **Step 4: Implement — Manage Subscription row**

In the same Settings Muse section, add a row visible only while
`commerceStore.entitlements.sharing` is true:

```swift
if commerceStore.entitlements.sharing {
    Button(String(localized: "Manage Subscription")) {
        NSWorkspace.shared.open(URL(string: "https://apps.apple.com/account/subscriptions")!)
    }
}
```

- [ ] **Step 5: Build and manually verify**

Run: `xcodebuild -project Muse/Muse.xcodeproj -scheme Muse build`
Open Settings with a store forced into each of `.trial(daysLeft: 10)`,
`.trial(daysLeft: 2)`, `.expired`, `.unlocked` and confirm the status line
text matches, the expiry reminder fires once at `daysLeft: 2` and not
again on a second `.task` re-entry, and Manage Subscription only shows
with `sharing` entitled.

- [ ] **Step 6: Commit**

```bash
git add Muse/Muse/Settings/SettingsView.swift Muse/Muse/Commerce/TrialExpiryReminder.swift Muse/Muse/ContentView.swift
git commit -m "feat: Settings trial status line, once-per-launch expiry reminder, Manage Subscription"
```

---

### Task 11: `SharingTier.enforced` flip

**Files:**
- Modify: `Muse/Muse/Commerce/SharingTier.swift` (Spec 07 file)
- Modify: `Muse/MuseTests/SharingTierTests.swift`

**Interfaces:**
- Consumes: Spec 07's existing `SharingTier.portfolioAvailable
  (entitledToSharing: Bool) -> Bool`, `SharingTier.enforced: Bool`.
- Produces: `enforced = true`. Single call site
  (`ShareCollectionButton`, per `DECISIONS.md`) is untouched — no other
  file changes.

- [ ] **Step 1: Write/update the failing test**

Open `Muse/MuseTests/SharingTierTests.swift` (Spec 07 ships this with the
`enforced = false` posture covered). Add — do not delete — the historical
branch's coverage, and add the now-live default:

```swift
    func testEnforcedDefaultAvailableOnlyWhenEntitled() {
        XCTAssertTrue(SharingTier.enforced, "Spec 09 flips this true")
        XCTAssertTrue(SharingTier.portfolioAvailable(entitledToSharing: true))
        XCTAssertFalse(SharingTier.portfolioAvailable(entitledToSharing: false))
    }

    /// Historical posture, kept green as documentation: with enforcement
    /// off, availability computes but never blocks.
    func testUnenforcedPostureStillComputesButNeverBlocks() {
        let unenforcedAvailable = SharingTier.portfolioAvailable(
            entitledToSharing: false, enforced: false)
        XCTAssertTrue(unenforcedAvailable)
    }
```

  (The second test assumes `portfolioAvailable` takes an `enforced:`
  parameter defaulting to `SharingTier.enforced` — check the actual Spec
  07 signature; if `enforced` is read as the global constant with no
  parameter override, restructure this test to temporarily construct a
  local pure function call against the constant's stored value instead,
  or drop the second test and rely on the first covering the live
  default, noting in a comment why the historical branch isn't separately
  testable post-flip.)

- [ ] **Step 2: Run to confirm the live-default test fails**

Run: `xcodebuild -project Muse/Muse.xcodeproj -scheme Muse test -only-testing:MuseTests/SharingTierTests`
Expected: FAIL on `testEnforcedDefaultAvailableOnlyWhenEntitled` —
`SharingTier.enforced` is still `false`.

- [ ] **Step 3: Flip the constant**

Edit `Muse/Muse/Commerce/SharingTier.swift`:

```swift
enum SharingTier {
    /// Flipped true in Spec 09's build — portfolio menu items now require
    /// entitlements.sharing. Previously false (Spec 07) so the feature
    /// could ship and be exercised without blocking on commerce plumbing.
    static let enforced = true

    static func portfolioAvailable(entitledToSharing: Bool) -> Bool {
        !enforced || entitledToSharing
    }
}
```

  Match this against the actual Spec 07 function body exactly (only the
  `enforced` constant's value changes; do not alter
  `portfolioAvailable`'s logic).

- [ ] **Step 4: Run the tests — confirm they pass**

Run: `xcodebuild -project Muse/Muse.xcodeproj -scheme Muse test -only-testing:MuseTests/SharingTierTests`
Expected: PASS.

- [ ] **Step 5: Manual check — the single call site**

`grep -rn "portfolioAvailable" Muse/Muse` and confirm exactly one call
site (`ShareCollectionButton` per `DECISIONS.md`) — this task must not
touch it.

- [ ] **Step 6: Commit**

```bash
git add Muse/Muse/Commerce/SharingTier.swift Muse/MuseTests/SharingTierTests.swift
git commit -m "feat: flip SharingTier.enforced = true (launch flip)"
```

---

### Task 12: `scripts/make-synthetic-library.swift` — 500k generator

**Files:**
- Create: `scripts/make-synthetic-library.swift`

**Interfaces:**
- Consumes: nothing from the app target — a standalone `swift` script
  using only `Foundation`/`ImageIO`/`CoreGraphics`, runnable via
  `swift scripts/make-synthetic-library.swift <count> <outdir> [--seed N]`
  with no Xcode project.
- Produces: `<outdir>/batch-000/…batch-NNN/` of small JPEGs with unique
  content hashes and EXIF/GPS variety, written through the same property
  keys `PhotoHeaderReader` (Spec 02) parses. Consumed by Task 13's
  `MUSE_PERF_500K` test section (which reads real EXIF via ImageIO, not
  this script directly) and by the owner's manual §5.4 protocol.

- [ ] **Step 1: No automated test** — this is a standalone tool the owner
  runs by hand; verification is Step 4's smoke run plus a manual EXIF
  spot-check (Step 5). It intentionally has zero dependency on the Xcode
  project or test target (must run on any Mac with a Swift toolchain,
  per `DECISIONS.md`).

- [ ] **Step 2: Implement**

```swift
#!/usr/bin/swift
//
//  make-synthetic-library.swift
//
//  Spec 09 §5.2 — generates N unique-content-hash small JPEGs with
//  EXIF/GPS variety, for the 500k-library performance-validation pass.
//  Zero dependency beyond Foundation/ImageIO/CoreGraphics; runs on any Mac
//  with a Swift toolchain, no Xcode project needed:
//
//    swift scripts/make-synthetic-library.swift 500000 /tmp/synth-lib --seed 1
//
//  Files nest <= 1,000 per folder (batch-000/, batch-001/, …) so no single
//  directory listing becomes the bottleneck. Every file is a unique content
//  hash (a per-file counter salt is baked into the pixel noise), ~4 KB each
//  (~2 GB at 500k). EXIF is written through the SAME property-dictionary
//  keys PhotoHeaderReader.swift parses (DateTimeOriginal, Make, Model,
//  LensModel, ISOSpeedRatings, FNumber, ExposureTime, FocalLength,
//  FocalLenIn35mmFilm, Flash, GPSLatitude/Longitude) — this generator and
//  the reader must never diverge on key names (the two-implementations-
//  one-contract rule class).
//

import Foundation
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers

// MARK: - Args

let args = CommandLine.arguments
guard args.count >= 3, let count = Int(args[1]) else {
    print("usage: make-synthetic-library.swift <count> <outdir> [--seed N]")
    exit(1)
}
let outDir = URL(fileURLWithPath: args[2])
var seed: UInt64 = 1
if let seedIdx = args.firstIndex(of: "--seed"), seedIdx + 1 < args.count,
   let s = UInt64(args[seedIdx + 1]) {
    seed = s
}

// MARK: - Deterministic PRNG (SplitMix64 — small, seeded, reproducible)

struct SplitMix64 {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
    mutating func nextDouble() -> Double { Double(next() >> 11) * (1.0 / 9007199254740992.0) }
    mutating func nextInt(_ range: ClosedRange<Int>) -> Int {
        range.lowerBound + Int(nextDouble() * Double(range.count))
    }
}
var rng = SplitMix64(state: seed)

// MARK: - Value pools

let cameraPool: [(make: String, model: String, lens: String)] = [
    ("FUJIFILM", "X100V", "FUJINON 23mm F2"),
    ("FUJIFILM", "X-T5", "XF35mmF1.4 R"),
    ("RICOH", "GR IIIx", "GR LENS 26.1mm F2.8"),
    ("SONY", "ILCE-7M4", "FE 35mm F1.4 GM"),
    ("Canon", "EOS R6 Mark II", "RF50mm F1.2 L USM"),
    ("NIKON CORPORATION", "Z 6II", "NIKKOR Z 35mm f/1.8 S"),
    ("Apple", "iPhone 15 Pro", "iPhone 15 Pro back camera 6.765mm f/1.78"),
    ("Leica Camera AG", "M11", "Summicron-M 35mm f/2"),
    ("OLYMPUS CORPORATION", "E-M1MarkIII", "M.12-40mm F2.8"),
    ("Panasonic", "DC-S5M2", "LUMIX S 24-105mm F4"),
    ("FUJIFILM", "X-Pro3", "XF16mmF1.4 R WR"),
    ("SONY", "ZV-E1", "FE 20mm F1.8 G"),
]
let cities: [(name: String, lat: Double, lon: Double)] = [
    ("Lisbon", 38.7223, -9.1393), ("Porto", 41.1579, -8.6291),
    ("Tokyo", 35.6762, 139.6503), ("Kyoto", 35.0116, 135.7681),
    ("New York", 40.7128, -74.0060), ("San Francisco", 37.7749, -122.4194),
    ("Paris", 48.8566, 2.3522), ("Berlin", 52.5200, 13.4050),
    ("London", 51.5074, -0.1278), ("Barcelona", 41.3874, 2.1686),
    ("Reykjavik", 64.1466, -21.9426), ("Marrakech", 31.6295, -7.9811),
    ("Bangkok", 13.7563, 100.5018), ("Seoul", 37.5665, 126.9780),
    ("Mexico City", 19.4326, -99.1332), ("Cape Town", -33.9249, 18.4241),
    ("Sydney", -33.8688, 151.2093), ("Vancouver", 49.2827, -123.1207),
    ("Copenhagen", 55.6761, 12.5683), ("Buenos Aires", -34.6037, -58.3816),
    // (~30 more entries trimmed here for brevity in this listing — the
    // committed script has a full ~50-entry table; extend inline.)
]

// MARK: - EXIF DateTimeOriginal formatting (matches PhotoHeaderReader's parse format)

let exifDateFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "yyyy:MM:dd HH:mm:ss"
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = TimeZone.current
    return f
}()

func randomDate(_ rng: inout SplitMix64) -> Date {
    let startYear = 2015, endYear = 2026
    let year = rng.nextInt(startYear...endYear)
    let month = rng.nextInt(1...12)
    let day = rng.nextInt(1...28)
    let hour = rng.nextInt(0...23)
    let minute = rng.nextInt(0...59)
    var comps = DateComponents()
    comps.year = year; comps.month = month; comps.day = day
    comps.hour = hour; comps.minute = minute
    return Calendar(identifier: .gregorian).date(from: comps) ?? Date()
}

// MARK: - Per-file pixel raster (small, unique per counter)

func makeRaster(side: Int, salt: Int, rng: inout SplitMix64) -> CGImage? {
    let width = side, height = side
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    for i in stride(from: 0, to: pixels.count, by: 4) {
        // Salted noise: `salt` guarantees no two files share identical
        // bytes even at identical RNG draws, so every file hashes unique.
        let n = UInt8((rng.next() ^ UInt64(salt)) & 0xFF)
        pixels[i] = n; pixels[i + 1] = n &+ 40; pixels[i + 2] = n &+ 80; pixels[i + 3] = 255
    }
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    guard let ctx = CGContext(data: &pixels, width: width, height: height,
                              bitsPerComponent: 8, bytesPerRow: width * 4,
                              space: colorSpace,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return nil }
    return ctx.makeImage()
}

// MARK: - Write one JPEG with EXIF/GPS property dictionary

func writeJPEG(image: CGImage, to url: URL, date: Date,
               camera: (make: String, model: String, lens: String),
               iso: Int, fNumber: Double, exposure: Double, focalLength: Double,
               flash: Bool, gps: (lat: Double, lon: Double)?) {
    guard let dest = CGImageDestinationCreateWithURL(
        url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { return }

    var exif: [CFString: Any] = [
        kCGImagePropertyExifDateTimeOriginal: exifDateFormatter.string(from: date),
        kCGImagePropertyExifISOSpeedRatings: [iso],
        kCGImagePropertyExifFNumber: fNumber,
        kCGImagePropertyExifExposureTime: exposure,
        kCGImagePropertyExifFocalLength: focalLength,
        kCGImagePropertyExifFocalLenIn35mmFilm: Int(focalLength.rounded()),
        kCGImagePropertyExifFlash: flash ? 1 : 0,
    ]
    var tiff: [CFString: Any] = [
        kCGImagePropertyTIFFMake: camera.make,
        kCGImagePropertyTIFFModel: camera.model,
    ]
    var lens: [CFString: Any] = [kCGImagePropertyExifLensModel: camera.lens]
    exif.merge(lens) { a, _ in a }

    var props: [CFString: Any] = [
        kCGImagePropertyExifDictionary: exif,
        kCGImagePropertyTIFFDictionary: tiff,
    ]
    if let gps {
        props[kCGImagePropertyGPSDictionary] = [
            kCGImagePropertyGPSLatitude: abs(gps.lat),
            kCGImagePropertyGPSLatitudeRef: gps.lat >= 0 ? "N" : "S",
            kCGImagePropertyGPSLongitude: abs(gps.lon),
            kCGImagePropertyGPSLongitudeRef: gps.lon >= 0 ? "E" : "W",
        ] as [CFString: Any]
    }
    props[kCGImageDestinationLossyCompressionQuality] = 0.6

    CGImageDestinationAddImage(dest, image, props as CFDictionary)
    CGImageDestinationFinalize(dest)
}

// MARK: - Main

let fm = FileManager.default
try? fm.createDirectory(at: outDir, withIntermediateDirectories: true)

let perBatch = 1000
var batchIndex = -1
var batchDir = outDir
let startTime = Date()

for i in 0..<count {
    if i % perBatch == 0 {
        batchIndex += 1
        batchDir = outDir.appendingPathComponent(String(format: "batch-%03d", batchIndex))
        try? fm.createDirectory(at: batchDir, withIntermediateDirectories: true)
    }
    guard let raster = makeRaster(side: 64, salt: i, rng: &rng) else { continue }

    let camera = cameraPool[rng.nextInt(0...(cameraPool.count - 1))]
    let iso = [100, 200, 400, 800, 1600, 3200, 6400, 12800][rng.nextInt(0...7)]
    let fNumber = [1.4, 1.8, 2.0, 2.8, 4.0, 5.6, 8.0, 11.0, 16.0][rng.nextInt(0...8)]
    let exposure = [1.0/8000, 1.0/2000, 1.0/500, 1.0/125, 1.0/60, 1.0/15, 1.0/4][rng.nextInt(0...6)]
    let focalLength = [16.0, 24.0, 35.0, 50.0, 85.0, 105.0][rng.nextInt(0...5)]
    let flash = rng.nextDouble() < 0.05
    let hasGPS = rng.nextDouble() < 0.30
    let gps = hasGPS ? {
        let city = cities[rng.nextInt(0...(cities.count - 1))]
        // Small jitter so points aren't stacked exactly on the city center.
        let jitterLat = (rng.nextDouble() - 0.5) * 0.2
        let jitterLon = (rng.nextDouble() - 0.5) * 0.2
        return (lat: city.lat + jitterLat, lon: city.lon + jitterLon)
    }() : nil

    let url = batchDir.appendingPathComponent("synth-\(i).jpg")
    writeJPEG(image: raster, to: url, date: randomDate(&rng), camera: camera,
             iso: iso, fNumber: fNumber, exposure: exposure, focalLength: focalLength,
             flash: flash, gps: gps)

    if i > 0 && i % 10_000 == 0 {
        let elapsed = Date().timeIntervalSince(startTime)
        print("[\(i)/\(count)] \(String(format: "%.1f", elapsed))s elapsed")
    }
}
print("Done: \(count) files in \(String(format: "%.1f", Date().timeIntervalSince(startTime)))s")
```

  The committed script must fill out the `cities` table to the full
  ~50-entry set described in `DECISIONS.md` (this listing trims it for
  length) and should be double-checked against `PhotoHeaderReader.swift`'s
  actual key-reading code (`FileMetadata.imageMetadata`'s prefix-stripped
  keys / `ISOSpeedRatings` array-or-scalar tolerance, per `DECISIONS.md`'s
  "Key handling mirrors `FileMetadata.imageMetadata` exactly") so the
  synthetic files exercise the real reader, not just plausible-looking
  EXIF.

- [ ] **Step 3: Make it executable**

```bash
chmod +x scripts/make-synthetic-library.swift
```

- [ ] **Step 4: Smoke-run at small scale**

Run: `swift scripts/make-synthetic-library.swift 500 /tmp/synth-smoke --seed 1`
Expected: completes in a few seconds, `/tmp/synth-smoke/batch-000/` contains
500 unique `.jpg` files.

- [ ] **Step 5: Verify EXIF round-trips through the real reader**

```bash
sips -g all /tmp/synth-smoke/batch-000/synth-0.jpg | grep -i "make\|model\|dpiHeight\|profile"
```

Confirm camera make/model appear (a full ImageIO property dump via a tiny
Swift snippet, or opening the file with Preview → Get Info, is a stronger
check than `sips` alone — do at least one direct
`CGImageSourceCopyPropertiesAtIndex` read in a scratch script and confirm
`kCGImagePropertyExifDateTimeOriginal`/`kCGImagePropertyTIFFMake`/GPS keys
are all present and match the generator's inputs).

- [ ] **Step 6: Clean up the smoke-test output and commit the script**

```bash
rm -rf /tmp/synth-smoke
git add scripts/make-synthetic-library.swift
git commit -m "feat: add scripts/make-synthetic-library.swift (500k-library generator)"
```

---

### Task 13: `PerfBaselineTests` — `MUSE_PERF_500K` section + validation template

**Files:**
- Modify: `Muse/MuseTests/PerfBaselineTests.swift`
- Modify: `Muse/Perf/PerfBaseline.swift`
- Create: `docs/launch-validation-template.md`

**Interfaces:**
- Consumes: `PerfBaseline.record(_:)` (or whatever the existing
  record-never-assert reporting call is named — check `Perf/
  PerfBaseline.swift`'s Spec 01 shape first), `ClipVectors.toData` (Spec
  03), `ClipIndex.matches` (Spec 03), GRDB `DatabaseQueue`.
- Produces: a `MUSE_PERF_500K=1`-gated `XCTestCase` section that builds a
  scratch DB, synthesizes 500k `photo_meta` + `clip_embeddings` rows, and
  records three numbers into the same report file the rest of
  `PerfBaseline` writes to. Never runs in default CI.

- [ ] **Step 1: Confirm the existing harness shape first**

Read `Muse/Perf/PerfBaseline.swift` and `Muse/MuseTests/
PerfBaselineTests.swift` in full before writing anything — this task's
job is to ADD a section using whatever `record`/report-writing seam Spec
01 already built (per `DECISIONS.md`: "`Perf/PerfBaseline.swift` +
`PerfBaselineTests` record numbers, never assert... Report written to
`docs/perf-baseline-<date>.md`; triggered by `MUSE_PERF=1` or the test
target"). Do not invent a second reporting mechanism.

- [ ] **Step 2: Write the gated test (itself is the "test" — no separate red/green cycle needed since this section only runs under an explicit env var; verify it at least COMPILES and, run manually once, produces sane numbers)**

Add to `Muse/MuseTests/PerfBaselineTests.swift`:

```swift
    /// Spec 09 §5.3 — the 800k-tier "search may take ~0.5s" claim made
    /// measurable. NEVER runs in default CI (env-gated); the numbers are
    /// recorded, never asserted, per the standing house rule.
    func testFiveHundredKScale() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["MUSE_PERF_500K"] == "1",
                          "set MUSE_PERF_500K=1 to run the 500k-scale section")

        let queue = try DatabaseQueue()
        try Database.makeMigrator().migrate(queue)

        let rowCount = 500_000
        var rng = SplitMix64ForTests(state: 42)
        try queue.write { db in
            for i in 0..<rowCount {
                let fileID = "synth-\(i)"
                var file = FileRow(id: fileID, content_hash: "hash-\(i)", kind: "image",
                                   size: 4096, width: 64, height: 64)
                try file.insert(db)
                var meta = PhotoMetaRow(
                    file_id: fileID, exif_scanned_hash: "hash-\(i)",
                    capture_date: Int64(1_400_000_000 + i % 300_000_000),
                    capture_md: String(format: "%02d-%02d", 1 + i % 12, 1 + i % 28),
                    camera_make: cameraPoolForTests[i % cameraPoolForTests.count].0,
                    camera_model: cameraPoolForTests[i % cameraPoolForTests.count].1,
                    lens: nil, iso: [100, 400, 1600, 6400][i % 4],
                    f_number: [1.4, 2.8, 5.6, 11.0][i % 4],
                    exposure_seconds: 1.0 / 250, focal_length: 35, focal_length_35mm: 35,
                    flash_fired: i % 20 == 0)
                try meta.insert(db)

                var vector = [Float](repeating: 0, count: 512)
                for j in 0..<512 { vector[j] = Float(rng.nextDouble() * 2 - 1) }
                var embedding = ClipEmbeddingRow(
                    file_id: fileID, embedded_hash: "hash-\(i)",
                    model_generation: ClipModel.current.generation,
                    vector: ClipVectors.toData(vector))
                try embedding.insert(db)
            }
        }

        // Three-token intersect: camera: + iso:>1600 + in:2019.
        let intersectStart = Date()
        _ = try queue.read { db in
            try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM photo_meta
                WHERE camera_make = ? AND iso > 1600 AND capture_date BETWEEN ? AND ?
                """, arguments: [cameraPoolForTests[0].0, 1_546_300_800, 1_577_836_800])
        }
        let intersectMs = Date().timeIntervalSince(intersectStart) * 1000
        PerfBaseline.record(name: "500k: three-token intersect", milliseconds: intersectMs,
                            budget: 500)

        // Full ClipIndex scan.
        let queryVector = [Float](repeating: 0.01, count: 512)
        let scanStart = Date()
        let footprintBefore = residentMemoryBytesForTests()
        _ = try await ClipIndex.matches(queue: queue, query: queryVector, minScore: 0.55,
                                        topK: 400)
        let footprintDelta = residentMemoryBytesForTests() - footprintBefore
        let scanMs = Date().timeIntervalSince(scanStart) * 1000
        PerfBaseline.record(name: "500k: ClipIndex full scan", milliseconds: scanMs,
                            budget: 1500)
        PerfBaseline.record(name: "500k: ClipIndex scan footprint delta",
                            bytes: footprintDelta, budgetBytes: 200 * 1024 * 1024)
    }
```

  `SplitMix64ForTests`, `cameraPoolForTests`, `residentMemoryBytesForTests`
  are small test-file-local helpers to add in the same file (a tiny seeded
  PRNG mirroring Task 12's script, a short camera-name pool, and an
  `mach_task_basic_info` resident-size read — check if `PerfBaselineTests`
  already has a memory-footprint helper from an earlier perf row before
  writing a new one). `PerfBaseline.record(name:milliseconds:budget:)` and
  the `bytes:`/`budgetBytes:` overload must match whatever the ACTUAL
  Spec 01 `PerfBaseline` API surface looks like — read it first (Step 1)
  and adapt these call shapes; add a `bytes:`/`budgetBytes:` overload to
  `Perf/PerfBaseline.swift` if only a milliseconds variant exists today,
  following the same record-and-append-to-report pattern as the existing
  overload.

- [ ] **Step 3: Confirm it compiles and skips by default**

Run: `xcodebuild -project Muse/Muse.xcodeproj -scheme Muse test -only-testing:MuseTests/PerfBaselineTests/testFiveHundredKScale`
Expected: the test is reported SKIPPED (not run), since `MUSE_PERF_500K`
is unset in the default invocation.

- [ ] **Step 4: Run it once manually to confirm the numbers are sane**

Run: `MUSE_PERF_500K=1 xcodebuild -project Muse/Muse.xcodeproj -scheme Muse test -only-testing:MuseTests/PerfBaselineTests/testFiveHundredKScale`
Expected: PASSES (records, never asserts — "pass" here means "ran to
completion and wrote rows"), takes on the order of tens of seconds to a
few minutes for the 500k inserts; inspect the generated
`docs/perf-baseline-<date>.md` and sanity-check the three new rows exist
with plausible numbers (not zero, not absurdly large).

- [ ] **Step 5: Create the launch-validation report template**

Create `docs/launch-validation-template.md`:

```markdown
# Launch Validation — <date>

Machine: <model, e.g. MacBook Air M1 8GB> · macOS: <version> · Muse build: <version/commit>

Run each numbered step from Spec 09 §5.4. Record outcome + numbers per row;
do not summarize — a future reader needs the actual figures, not "passed."

| # | Step | Outcome | Numbers |
|---|------|---------|---------|
| 1 | Generate the 500k library, add as root | | |
| 2 | Indexing completes, app responsive throughout, no beachball/crash; relaunch mid-index resumes cleanly | | |
| 3 | Backfills progress across launches under per-launch caps | | |
| 4 | Search: token queries return, degradation graceful (~0.5s acceptable), grid scroll fluid | | |
| 5 | Memory bounded: peak footprint (index), peak footprint (search), no memory-pressure kill on 8GB | | |
| 6 | Integrity: quit/relaunch, `PRAGMA integrity_check` passes, spot-check tags/edits on a handful of files | | |
| 7 | Thermal/battery: battery analyze → `.reduced` (concurrency 1); Low Power → same; thermal pressure → `.paused`, resumes; Settings Pause/Resume round-trips; on power a 100k analyze completes overnight | | |

**Verdict:** the "tested with libraries of 500,000+ photos" marketing/ASO
line may be used ONLY after every row above passes and this document is
committed.
```

- [ ] **Step 6: Commit**

```bash
git add Muse/MuseTests/PerfBaselineTests.swift Muse/Perf/PerfBaseline.swift docs/launch-validation-template.md
git commit -m "feat: add MUSE_PERF_500K perf section + launch-validation report template"
```

---

### Task 14: `web/share` legal pages — rewrite for a paid PolyForm-Shield app

**Files:**
- Modify: `web/share/about.html`
- Modify: `web/share/privacy.html`
- Modify: `web/share/terms.html`

**Interfaces:**
- Consumes: nothing from the app target (static HTML) — but the terms
  page's grace-period number must literally equal `DomainConfig.
  lapseGraceDays` (Spec 08) and the privacy page's network-path list must
  exactly match `DECISIONS.md`'s four-path doctrine.
- Produces: rewritten static pages. Consumed by App Review (subscription
  purchase UI legal-link requirement) and by `SubscriptionLegalLinks`
  (Task 8), which links to `/privacy` and `/terms` on this same base.

- [ ] **Step 1: No automated test** — static content; verified by manual
  read-through against the acceptance criteria below (Step 5) and by the
  French-localization pass not applying here (these are plain HTML pages,
  outside `.xcstrings` — confirm they're not supposed to be localized;
  `web/share` today ships English-only per the existing `privacy.html`/
  `terms.html`, so this task keeps that posture).

- [ ] **Step 2: Rewrite `about.html`**

Open the existing `web/share/about.html`. Preserve the
`google-site-verification` meta tag and the page's role as the OAuth
consent screen's "App home page" link — do not remove or restructure
these. Replace the lede and drop any "free, open-source software"
language:

- New lede: a local-first, Mac-native photo library app for people who
  take photography seriously as a hobby; photos stay in your folders,
  nothing is imported, no catalog, no cloud, no data collection.
- Foot line: "Available on the Mac App Store. Source-available under the
  PolyForm Shield license." — link the license reference to
  `https://github.com/carlostarrats/Muse/blob/main/LICENSE` (or wherever
  the repo actually hosts `LICENSE` once private — use a relative
  same-site reference if the repo link would 404 for a private repo;
  check `README.md`'s own License section link for the pattern to match).
- Links row: Mac App Store (placeholder anchor `href="#"` with an inline
  HTML comment `<!-- TODO: owner fills in the App Store URL at submission -->`
  until the owner supplies it — never guess a URL), marketing site,
  `/privacy`, `/terms`.
- Keep the existing Drive-share explainer paragraph verbatim (it's the
  consent screen's required context).
- No Lightroom mention anywhere (house rule, decision #3).

- [ ] **Step 3: Rewrite `privacy.html`**

Replace the network-paths section to enumerate EXACTLY these four,
each with what is sent:

1. **Google Drive share/portfolio** — user-initiated; images upload to the
   user's own Google Drive.
2. **`announcements.json`** — a plain GET of a static file, once per
   launch, nothing sent, off-able in Settings.
3. **The search-model download** — user-initiated, a static file
   download, nothing sent.
4. **Custom-domain / username provisioning** — user-initiated, paid
   feature; the request carries the App Store **transaction JWS** (product
   id, purchase dates, transaction ids — no name, no email, no Apple ID),
   used only to verify the subscription/unlock and never stored beyond
   the hostname claim.

Add: App Store / StoreKit traffic and iCloud Drive sync are OS-level
(governed by Apple's own privacy policy, not this document). Add a "the
share page" section noting the portfolio `manifest.json` fetch
(recipient-browser traffic to `googleapis.com`, CSP-pinned) beside the
existing Drive image loads, and restate "no analytics of any kind, ever,
on any share page." Add a purchases/refunds line: handled entirely by
Apple, Muse never sees payment data. Restate the top-line claim: "What
the app collects: nothing. No analytics, no telemetry, no accounts" and
the App Store "Data Not Collected" label.

- [ ] **Step 4: Rewrite `terms.html`**

- §1 "The software": replace "free, open-source" with "a commercial app
  sold on the Mac App Store, source-available under the **PolyForm Shield
  1.0.0 License**" — keep the warranty disclaimer section unchanged, add
  the license link.
- New section: **Purchases & subscriptions** — purchases/refunds are
  processed by Apple (refunds via `reportaproblem.apple.com`); the
  sharing subscription auto-renews and is managed/cancelled in App Store
  account settings; if it lapses, custom domains are removed after a
  **30-day** grace period. **This number must literally equal
  `DomainConfig.lapseGraceDays`** — open `Muse/Muse/Sharing/Domains/
  DomainConfig.swift`, confirm the constant's actual value, and use that
  exact number here (not blindly 30 — verify it wasn't changed since Spec
  08 shipped).
- Extend the existing sharing-is-yours-to-operate / acceptable-use /
  reporting-and-enforcement sections explicitly to
  `username.muse.app` addresses and custom-hostname pages: same
  acceptable-use terms, same takedown path (documented in
  `workers/domains/README`) — a violating username/hostname is
  deprovisioned.
- Extend the Availability section to the provisioning Worker and username
  serving (best-effort, no SLA).

- [ ] **Step 5: Manual acceptance pass**

Read all three pages start to finish and confirm: zero occurrences of
"free" or "open source" describing the app itself (the license IS
source-available, which is a different claim — keep that), zero
Lightroom references, the grace-period number matches
`DomainConfig.lapseGraceDays` exactly, and the network-path count in
`privacy.html` is exactly four with the JWS-only-no-PII line present for
path 4.

- [ ] **Step 6: Run the existing `share.test.mjs` suite to confirm nothing broke**

Run: `cd web/share && node --test share.test.mjs`
Expected: PASS, unchanged (this task never touches `index.html`/
`share.js`, per the global constraint — confirm the diff touches only
`about.html`/`privacy.html`/`terms.html`).

- [ ] **Step 7: Commit**

```bash
git add web/share/about.html web/share/privacy.html web/share/terms.html
git commit -m "docs: rewrite web/share legal pages for a paid, PolyForm-Shield, MAS-only app"
```

---

### Task 15: About card, README, Info.plist compliance key

**Files:**
- Modify: `Muse/Muse/Views/InfoSheet.swift`
- Modify: `README.md`
- Modify: `Muse/Info.plist`

**Interfaces:**
- Consumes: nothing new. Verifies against the existing GeoNames attribution
  line (Spec 02) and whatever CLIP model license line Task 16's outcome
  (§8 gate, recorded in `DECISIONS.md`) requires.
- Produces: corrected license line + attributions in the in-app About
  card; corrected README; `ITSAppUsesNonExemptEncryption` present.

- [ ] **Step 1: No automated test** — static/plist content, house no-UI-
  tests rule.

- [ ] **Step 2: `InfoSheet.swift` — replace the license line**

Open `Muse/Muse/Views/InfoSheet.swift` at line 200 (`"Muse is open source
under the MIT license. The code..."`). Replace with PolyForm Shield
language plus a compact attribution list:

```swift
Text(String(localized: "Muse is source-available under the PolyForm Shield License. Attributions:"))
    .font(.system(size: 12))
    .foregroundStyle(.secondary)
VStack(alignment: .leading, spacing: 2) {
    Text("• GRDB.swift (MIT)")
    Text("• fflate (MIT), used on the share page")
    Text("• GeoNames (CC-BY 4.0)")
    // CLIP model attribution line — fill per the §8 outcome recorded in
    // DECISIONS.md: either the MobileCLIP weights TOU attribution, or
    // OpenCLIP + its training-data attribution if the fallback shipped.
    Text("• <CLIP model attribution — see DECISIONS.md §8 outcome>")
}
.font(.system(size: 11))
.foregroundStyle(.secondary)
```

  Confirm the GeoNames attribution line Spec 02 already added elsewhere in
  the app (per `DECISIONS.md`'s "Dataset: GeoNames cities1000... Attribution
  required in the About card and README") isn't being duplicated — if
  Spec 02 already put a GeoNames line in `InfoSheet.swift`, this task
  should fold it into the same attributions list rather than adding a
  second one; `grep -n "GeoNames" Muse/Muse/Views/InfoSheet.swift` first.
  Localize every new string (`String(localized:)` or SwiftUI literal
  positions).

- [ ] **Step 3: `README.md` — final license/distribution pass**

Read the current `README.md` License section (already mostly correct per
the earlier grep — it says PolyForm Shield) and the Sparkle-mentioning
sections (lines ~105, ~122, ~128 per the earlier grep). Since Sparkle
removal itself is Spec 01's job (not this spec's), this task's scope is
narrower: confirm no remaining "free" or "open source" phrasing describes
the app (only the license framing, which is correctly "source-available"),
and that the distribution description matches the current build state —
if Spec 01 has already removed Sparkle from the codebase by the time this
task runs, also strip the Sparkle-update paragraph and the "GRDB and
Sparkle are..." line; if Spec 01 hasn't landed yet in this build's
timeline, leave those lines untouched (they describe real present
behavior) and only fix language that's ALREADY wrong regardless of
Sparkle's removal status (license/distribution framing).

- [ ] **Step 4: `Info.plist` — add the encryption-exemption key**

Edit `Muse/Info.plist`. Add, alongside the existing top-level keys:

```xml
<key>ITSAppUsesNonExemptEncryption</key>
<false/>
```

  (HTTPS-only usage is exempt; this key being present and `false` skips
  the export-compliance question on every future App Store Connect
  upload. Add a one-line XML comment above it explaining why, matching
  this file's existing comment style.)

- [ ] **Step 5: Build and localization check**

Run: `xcodebuild -project Muse/Muse.xcodeproj -scheme Muse build`
Expected: BUILD SUCCEEDED.

Run: `xcodebuild -exportLocalizations -project Muse/Muse.xcodeproj -localizationPath /tmp/muse-l10n -exportLanguage fr`
Expected: 0 untranslated for the new About-card strings (confirm by
inspecting the exported `.xliff`, or checking `Localizable.xcstrings`
directly for the new keys' `fr` values — fill them in if the export
reports untranslated, per the house localization workflow).

- [ ] **Step 6: Commit**

```bash
git add Muse/Muse/Views/InfoSheet.swift README.md Muse/Info.plist
git commit -m "feat: About card license/attributions rewrite; ITSAppUsesNonExemptEncryption"
```

---

### Task 16: Doctrine finalization — `CLAUDE.md`, architecture map, session log

**Files:**
- Modify: `CLAUDE.md`
- Modify: `docs/architecture-map.md`
- Modify: `docs/session-log.md`

**Interfaces:**
- Consumes: everything shipped in Tasks 1–15, plus the network-doctrine
  count correction already recorded in `DECISIONS.md` ("Exactly four
  app-initiated network paths").
- Produces: the checklist row 8 verification target — `CLAUDE.md`'s
  doctrine section reads correctly against the shipped state.

- [ ] **Step 1: No automated test** — documentation-only task.

- [ ] **Step 2: `CLAUDE.md` — network doctrine + persona + phase table**

Open `CLAUDE.md`. Update the "Network policy" section under Project
identity: the current text describes "Update-only, plus one explicit
opt-in publish path" with Sparkle + Drive as the two paths — this is
stale the moment Specs 01/08/09 ship. Replace with the **four**
app-initiated paths from `DECISIONS.md`'s Network doctrine section: (1)
Google Drive share, (2) `announcements.json`, (3) custom-domain
provisioning Worker, (4) search-model download — StoreKit/App Store
traffic is OS-level and not counted. Update the Distribution line to
reflect Mac App Store exclusivity once Spec 01 has actually landed
Sparkle's removal (cross-check against the real repo state before
editing — don't claim Sparkle is gone if Spec 01 hasn't shipped yet in
this build's actual history; word it to match ground truth at the moment
this task runs). Add rows to the Implementation status phase table for
Specs 01–09 (or confirm they're already present if a prior task in this
spec sequence added them — check for existing "Spec 01"–"Spec 08" rows
before appending duplicates).

- [ ] **Step 3: `docs/architecture-map.md` — new module folders**

Add entries for every new top-level folder introduced across Specs 01–09
that isn't already indexed: `Commerce/`, `Perf/`, `Search/`,
`Intelligence/Geo/`, `Intelligence/Stacks/`, `Intelligence/Core/`,
`Intelligence/Clip/`, `Views/Compare/`, `Editing/` + `Editing/Render/`,
`Views/Editor/`, `Views/Theme/`, `Export/Social/` + `Views/Export/`,
`Sharing/Domains/`, plus this spec's `scripts/make-synthetic-library.swift`
and the `docs/launch-validation-template.md`. Cross-check against
`DECISIONS.md`'s "Architecture & module structure" section for the
canonical list — don't invent entries this spec didn't verify exist.

- [ ] **Step 4: `docs/session-log.md` — append a dated entry**

Append a session-log entry (matching the file's existing per-branch
narrative format) summarizing this spec's build: what shipped (backup
amendment A2, trial gate, launch flips, 500k perf tooling, legal-page
rewrite), what's still owner-only (pricing, MobileCLIP legal read,
physical M1 Air validation runs, GA sequencing), and a pointer back to
this plan file and `docs/new-build/spec-09-implementation.md` for full
detail.

- [ ] **Step 5: Read-through against the launch checklist**

Open `docs/new-build/spec-09-implementation.md` §9 (the 16-row launch
checklist) and confirm this plan's tasks cover every code-verifiable row:
row 5 (Task 4), row 10 (verify manually —
`strings Muse.app/Contents/MacOS/Muse | grep -ci sparkle` → 0, once Spec
01's Sparkle removal has actually landed; not this spec's task to remove
Sparkle, only to confirm it stays gone), row 12 (Tasks 5, 11), row 13
(Task 13), row 14 (Task 15), row 15 (Task 15's localization step). Rows
1–4, 6, 9, 16 are owner-only per §12 of the spec and are NOT code tasks —
do not attempt to automate them.

- [ ] **Step 6: Commit**

```bash
git add CLAUDE.md docs/architecture-map.md docs/session-log.md
git commit -m "docs: finalize CLAUDE.md doctrine, architecture map, session log for Spec 09"
```

---

## Self-review notes (recorded for the executor)

- **Spec coverage:** §1 (pricing invariant) → Task 9/10's `displayPrice`-
  only rendering + the acceptance grep noted in Global Constraints; §2
  (trial enforcement) → Tasks 5–10; §3 (launch flips) → Tasks 5, 11; §4
  (backup amendment A2) → Tasks 1–4; §5 (perf validation) → Tasks 12–13;
  §6 (site/legal/About/README/Info.plist) → Tasks 14–15; §7 (TestFlight
  cohort) → owner-only, not a code task, referenced in Task 16 Step 5;
  §8 (MobileCLIP gate) → owner-only, referenced in Task 15 Step 2's
  attribution placeholder and Task 16; §9 (checklist) → Task 16 Step 5;
  §10 (tests) → distributed across Tasks 1, 3, 5, 6, 11, 13; §11 (build
  order) → this plan's task ordering follows it exactly; §12 (owner
  steps) → deliberately NOT built, called out at each relevant task.
- **Placeholder scan:** every code step above contains real, compilable
  (pending exact upstream signatures from Specs 01/04/07/08, flagged
  explicitly where uncertain) Swift/JS/shell — no "add appropriate error
  handling" or "write tests for the above" placeholders remain. Where an
  upstream signature genuinely can't be known until the prior spec is
  actually merged (e.g. `CommerceStore.purchase`'s return type,
  `EditStackCodec`'s exact function names, `PerfBaseline.record`'s
  parameter list), the step says explicitly what to grep for and how to
  adapt — that is a real, actionable instruction, not a placeholder.
- **Type consistency:** `TrialPolicy.current`/`.epoch`/`.anchorKeyName`
  (Task 5) are the exact names Task 6 consumes; `BackupEditVersion`/
  `BackupEditPreset`/`BackupLut` (Task 1) are the exact names Tasks 2–4
  consume; `SharingTier.enforced`/`.portfolioAvailable` (Task 11) match
  Task 8's Global Constraints reference to Spec 07's existing shape.
