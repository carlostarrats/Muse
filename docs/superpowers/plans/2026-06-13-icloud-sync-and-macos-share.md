# iCloud Sync Folder + macOS Share Integration — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a single app-managed iCloud Drive folder whose files carry complete portable `.muse/` sidecar metadata (so any device hydrates without re-running Vision), plus an in-app Share button and a "Send to Muse" Finder share extension — all without adding `network.client` or any CloudKit.

**Architecture:** A two-zone root model: today's user-selected security-scoped folders ("local zone", unchanged) plus one auto-discovered iCloud Drive folder ("iCloud zone"). For files inside the iCloud zone, after Vision analysis Muse writes a per-asset JSON sidecar into a hidden `.muse/` subfolder keyed by content hash. iCloud Drive syncs files + sidecars via the OS daemon (no app network calls). On folder load, Muse hydrates the local SQLite from sidecars before analyzing, so a fresh/iCloud-only device reconstructs tags/intent/caption/color without re-running Vision. Collections and thumbnails re-derive locally as they already do.

**Tech Stack:** Swift, SwiftUI, AppKit (`NSSharingServicePicker`), GRDB (SQLite), Foundation `FileManager` ubiquity container + `NSFileCoordinator`, Vision (existing), XCTest. macOS 14.6+.

**Spec:** `docs/superpowers/specs/2026-06-13-icloud-sync-and-macos-share-design.md`

**Testing note (read first):** This feature mixes pure logic with OS-capability wiring.
- **Unit-testable (full TDD):** the sidecar model codec, the `FileRow`/`TagRow` ↔ sidecar mapping, the conflict merge, and `SidecarStore` file I/O (tested against a `FileManager` temp directory — `NSFileCoordinator` needs no real iCloud).
- **Not unit-testable (build + manual verify):** entitlements, the ubiquity container, the share extension, and `NSSharingServicePicker`. These tasks specify exact configuration and a manual verification step instead of an XCTest. That is expected, not a gap.

**Build/test commands** (run from repo root `/Users/carlostarrats/Documents/Projects/Muse`):
- Build: `xcodebuild -project Muse/Muse.xcodeproj -scheme Muse -destination 'platform=macOS' build`
- Test: `xcodebuild test -project Muse/Muse.xcodeproj -scheme Muse -destination 'platform=macOS' -only-testing:MuseTests`
- Bundle id is `com.tarrats.Muse`; the iCloud container will be `iCloud.com.tarrats.Muse`; the App Group will be `group.com.tarrats.Muse`.

---

## File Structure

**New files:**
- `Muse/Muse/Filesystem/Sidecar.swift` — the portable metadata value type (`Sidecar`, `SidecarTag`) + pure codec, `FileRow`/`TagRow` mapping, and merge. No I/O, no DB. Fully unit-tested.
- `Muse/Muse/Filesystem/SidecarStore.swift` — read/write a `Sidecar` to `<folder>/.muse/<hash>.json` with `NSFileCoordinator`. Thin I/O wrapper. Unit-tested against temp dirs.
- `Muse/Muse/Filesystem/ICloudZone.swift` — discover the one iCloud folder URL (ubiquity container `Documents`), and `contains(_ url:)` membership test. The single source of truth for "is this file in the iCloud zone".
- `Muse/Muse/Filesystem/SidecarHydrator.swift` — on folder load, import any current sidecars into the local DB (FileRow + tags + FTS + `analyzed_hash`) so analysis skips them. Thin DB wrapper over `Sidecar`'s pure mapping.
- `Muse/MuseShareExtension/ShareViewController.swift` (+ `Info.plist`, `MuseShareExtension.entitlements`) — the "Send to Muse" extension target.
- Tests: `Muse/MuseTests/SidecarTests.swift`, `Muse/MuseTests/SidecarStoreTests.swift`.

**Modified files:**
- `Muse/Muse/Muse.entitlements` — add iCloud Documents + ubiquity container + App Group.
- `Muse/Muse/Info.plist` (or target Info settings) — add `NSUbiquitousContainers` so the folder is named "Muse" and visible in iCloud Drive.
- `Muse/Muse/Intelligence/AnalyzePipeline.swift` — after `analyzeOne` writes the DB, write a sidecar for iCloud-zone files.
- `Muse/Muse/Models/AppState.swift` — surface the iCloud zone as a root; call the hydrator before `analyzePending` in `scheduleIndexing`.
- `Muse/Muse/Views/SidebarView.swift` — show the iCloud zone in the sidebar.
- `Muse/Muse/Views/Viewer/` (hero viewer) and/or `Muse/Muse/Views/GridView.swift` — the Share button.
- `CLAUDE.md` — update the network-policy nuance + architecture map + phase log.

---

## Phase 1 — Sidecar value type + pure logic (full TDD)

### Task 1: The `Sidecar` model and JSON round-trip

**Files:**
- Create: `Muse/Muse/Filesystem/Sidecar.swift`
- Test: `Muse/MuseTests/SidecarTests.swift`

- [ ] **Step 1: Write the failing test**

Create `Muse/MuseTests/SidecarTests.swift`:

```swift
import XCTest
@testable import Muse

final class SidecarTests: XCTestCase {
    private func sampleSidecar() -> Sidecar {
        Sidecar(
            schema: 1,
            updated_at: 1000,
            content_hash: "abc123",
            kind: "image",
            width: 1920,
            height: 1080,
            duration_seconds: nil,
            created_at: 10,
            modified_at: 20,
            caption: "a dog on a beach",
            dominant_color: "#11AA33",
            palette: "[\"#11AA33\"]",
            feature_print: Data([1, 2, 3, 4]),
            analyzed_hash: "abc123",
            intent: nil,
            intent_model_version: nil,
            tags: [
                SidecarTag(label: "dog", source: "vision", confidence: 0.9, model_version: "v1"),
                SidecarTag(label: "favorite", source: "manual", confidence: nil, model_version: nil),
            ]
        )
    }

    func testJSONRoundTrip() throws {
        let original = sampleSidecar()
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Sidecar.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    func testFeaturePrintSurvivesAsBase64() throws {
        let original = sampleSidecar()
        let data = try JSONEncoder().encode(original)
        // Foundation encodes Data as a base64 string by default — assert it's
        // textual JSON (no raw bytes), so the sidecar is portable to iOS.
        let json = String(data: data, encoding: .utf8)
        XCTAssertNotNil(json)
        let decoded = try JSONDecoder().decode(Sidecar.self, from: data)
        XCTAssertEqual(decoded.feature_print, Data([1, 2, 3, 4]))
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `xcodebuild test -project Muse/Muse.xcodeproj -scheme Muse -destination 'platform=macOS' -only-testing:MuseTests/SidecarTests`
Expected: FAIL — `cannot find 'Sidecar' in scope`.

- [ ] **Step 3: Write the model**

Create `Muse/Muse/Filesystem/Sidecar.swift`:

```swift
//
//  Sidecar.swift
//  Muse
//
//  Portable per-asset metadata that rides iCloud Drive sync inside a
//  hidden .muse/ folder, so another device (or the eventual iOS app)
//  hydrates the full experience without re-running Vision. Pure value
//  type — no I/O, no DB. Maps to/from FileRow + TagRow.
//

import Foundation

/// One manual or vision tag, mirrored from TagRow's portable columns.
struct SidecarTag: Codable, Equatable {
    var label: String
    var source: String            // "manual" | "vision" | "vision-*"
    var confidence: Double?
    var model_version: String?
}

/// Complete portable record for one asset, keyed by content hash. Must
/// stay platform-neutral (no AppKit types) so iOS can read it unchanged.
struct Sidecar: Codable, Equatable {
    var schema: Int               // = 1
    /// When this metadata was last written (epoch seconds). Drives
    /// last-writer-wins conflict resolution — NOT the file's mtime.
    var updated_at: Int64
    var content_hash: String
    var kind: String
    var width: Int?
    var height: Int?
    var duration_seconds: Double?
    var created_at: Int64?
    var modified_at: Int64?
    var caption: String?
    var dominant_color: String?
    var palette: String?
    var feature_print: Data?      // JSONEncoder serializes Data as base64
    var analyzed_hash: String?
    var intent: String?
    var intent_model_version: String?
    var tags: [SidecarTag]

    static let currentSchema = 1
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `xcodebuild test -project Muse/Muse.xcodeproj -scheme Muse -destination 'platform=macOS' -only-testing:MuseTests/SidecarTests`
Expected: PASS (both tests).

- [ ] **Step 5: Commit**

```bash
git add Muse/Muse/Filesystem/Sidecar.swift Muse/MuseTests/SidecarTests.swift
git commit -m "feat: add portable Sidecar metadata value type"
```

---

### Task 2: Map `Sidecar` ↔ `FileRow` + `TagRow`

**Files:**
- Modify: `Muse/Muse/Filesystem/Sidecar.swift`
- Test: `Muse/MuseTests/SidecarTests.swift`

- [ ] **Step 1: Write the failing test**

Append to `SidecarTests.swift`:

```swift
extension SidecarTests {
    func testBuildFromFileRowAndTags() {
        let file = FileRow(
            id: "f1", content_hash: "abc123", kind: "image",
            size_bytes: 100, width: 1920, height: 1080,
            duration_seconds: nil, created_at: 10, modified_at: 20,
            last_seen_at: 999, caption: "a dog", dominant_color: "#112233",
            feature_print: Data([9, 9]), palette: "[]",
            analyzed_hash: "abc123", intent: "recipe", intent_model_version: "iv1"
        )
        let tags = [
            TagRow(id: "t1", file_id: "f1", label: "dog", source: "vision",
                   confidence: 0.8, model_version: "v1"),
            TagRow(id: "t2", file_id: "f1", label: "fav", source: "manual",
                   confidence: nil, model_version: nil),
        ]
        let sc = Sidecar.build(from: file, tags: tags, updatedAt: 555)
        XCTAssertEqual(sc?.content_hash, "abc123")
        XCTAssertEqual(sc?.caption, "a dog")
        XCTAssertEqual(sc?.intent, "recipe")
        XCTAssertEqual(sc?.updated_at, 555)
        XCTAssertEqual(sc?.tags.count, 2)
        XCTAssertEqual(sc?.tags.first(where: { $0.source == "manual" })?.label, "fav")
    }

    func testBuildReturnsNilWithoutContentHash() {
        let file = FileRow(
            id: "f1", content_hash: nil, kind: "image",
            size_bytes: nil, width: nil, height: nil, duration_seconds: nil,
            created_at: nil, modified_at: nil, last_seen_at: 0, caption: nil,
            dominant_color: nil, feature_print: nil, palette: nil,
            analyzed_hash: nil, intent: nil, intent_model_version: nil
        )
        XCTAssertNil(Sidecar.build(from: file, tags: [], updatedAt: 1))
    }

    func testApplyOntoFileRowPreservesIdentityColumns() {
        let sc = sampleSidecar()                       // content_hash "abc123"
        var existing = FileRow(
            id: "keep-me", content_hash: "abc123", kind: "image",
            size_bytes: 42, width: nil, height: nil, duration_seconds: nil,
            created_at: nil, modified_at: nil, last_seen_at: 7, caption: nil,
            dominant_color: nil, feature_print: nil, palette: nil,
            analyzed_hash: nil, intent: nil, intent_model_version: nil
        )
        sc.apply(onto: &existing)
        XCTAssertEqual(existing.id, "keep-me")         // id never overwritten
        XCTAssertEqual(existing.size_bytes, 42)        // local-only column kept
        XCTAssertEqual(existing.last_seen_at, 7)       // device-local, kept
        XCTAssertEqual(existing.caption, "a dog on a beach")  // hydrated
        XCTAssertEqual(existing.analyzed_hash, "abc123")
    }

    func testTagRowsFactory() {
        let sc = sampleSidecar()
        var counter = 0
        let rows = sc.tagRows(fileID: "f1") { counter += 1; return "id\(counter)" }
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0].file_id, "f1")
        XCTAssertEqual(Set(rows.map(\.id)), ["id1", "id2"])
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `xcodebuild test ... -only-testing:MuseTests/SidecarTests`
Expected: FAIL — `value of type 'Sidecar' has no member 'build'`.

- [ ] **Step 3: Add the mapping to `Sidecar.swift`**

Append to `Sidecar.swift`:

```swift
extension Sidecar {
    /// Build a sidecar from a fully-analyzed file row + its tags. Returns
    /// nil if the file has no content hash (its identity isn't established).
    static func build(from file: FileRow, tags: [TagRow], updatedAt: Int64) -> Sidecar? {
        guard let hash = file.content_hash else { return nil }
        return Sidecar(
            schema: Sidecar.currentSchema,
            updated_at: updatedAt,
            content_hash: hash,
            kind: file.kind,
            width: file.width,
            height: file.height,
            duration_seconds: file.duration_seconds,
            created_at: file.created_at,
            modified_at: file.modified_at,
            caption: file.caption,
            dominant_color: file.dominant_color,
            palette: file.palette,
            feature_print: file.feature_print,
            analyzed_hash: file.analyzed_hash,
            intent: file.intent,
            intent_model_version: file.intent_model_version,
            tags: tags.map {
                SidecarTag(label: $0.label, source: $0.source,
                           confidence: $0.confidence, model_version: $0.model_version)
            }
        )
    }

    /// Apply this sidecar's portable fields onto an existing file row,
    /// leaving identity/device-local columns (id, size_bytes, last_seen_at,
    /// content_hash) untouched.
    func apply(onto file: inout FileRow) {
        file.width = width
        file.height = height
        file.duration_seconds = duration_seconds
        file.created_at = created_at
        file.modified_at = modified_at
        file.caption = caption
        file.dominant_color = dominant_color
        file.palette = palette
        file.feature_print = feature_print
        file.analyzed_hash = analyzed_hash
        file.intent = intent
        file.intent_model_version = intent_model_version
    }

    /// Materialize TagRows for a given file id. `makeID` supplies unique row
    /// ids (UUID in production, deterministic in tests).
    func tagRows(fileID: String, makeID: () -> String) -> [TagRow] {
        tags.map {
            TagRow(id: makeID(), file_id: fileID, label: $0.label,
                   source: $0.source, confidence: $0.confidence,
                   model_version: $0.model_version)
        }
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `xcodebuild test ... -only-testing:MuseTests/SidecarTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Muse/Muse/Filesystem/Sidecar.swift Muse/MuseTests/SidecarTests.swift
git commit -m "feat: map Sidecar to/from FileRow and TagRow"
```

---

### Task 3: Conflict merge (last-writer-wins + manual-tag preservation)

**Files:**
- Modify: `Muse/Muse/Filesystem/Sidecar.swift`
- Test: `Muse/MuseTests/SidecarTests.swift`

iCloud Drive resolves conflicts by keeping multiple file versions; when Muse sees two sidecars for one hash it must merge them deterministically. Scalar fields take the newer `updated_at`; tags union, and a `manual` tag always wins over a `vision` tag of the same label (preserving invariant Q32).

- [ ] **Step 1: Write the failing test**

Append to `SidecarTests.swift`:

```swift
extension SidecarTests {
    private func make(updated: Int64, caption: String, tags: [SidecarTag]) -> Sidecar {
        var s = sampleSidecar()
        s.updated_at = updated
        s.caption = caption
        s.tags = tags
        return s
    }

    func testMergeScalarsTakeNewer() {
        let older = make(updated: 100, caption: "old", tags: [])
        let newer = make(updated: 200, caption: "new", tags: [])
        XCTAssertEqual(Sidecar.merge(older, newer).caption, "new")
        XCTAssertEqual(Sidecar.merge(newer, older).caption, "new")  // order-independent
        XCTAssertEqual(Sidecar.merge(older, newer).updated_at, 200)
    }

    func testMergeManualTagBeatsVision() {
        let a = make(updated: 200, caption: "x",
                     tags: [SidecarTag(label: "dog", source: "vision", confidence: 0.9, model_version: "v1")])
        let b = make(updated: 100, caption: "y",
                     tags: [SidecarTag(label: "dog", source: "manual", confidence: nil, model_version: nil)])
        let merged = Sidecar.merge(a, b)
        let dog = merged.tags.first { $0.label == "dog" }
        XCTAssertEqual(dog?.source, "manual")        // manual wins even though a is newer
        XCTAssertEqual(merged.tags.count, 1)         // unioned, not duplicated
    }

    func testMergeUnionsDistinctTags() {
        let a = make(updated: 100, caption: "x",
                     tags: [SidecarTag(label: "dog", source: "vision", confidence: 0.9, model_version: "v1")])
        let b = make(updated: 100, caption: "x",
                     tags: [SidecarTag(label: "beach", source: "vision", confidence: 0.7, model_version: "v1")])
        XCTAssertEqual(Set(Sidecar.merge(a, b).tags.map(\.label)), ["dog", "beach"])
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `xcodebuild test ... -only-testing:MuseTests/SidecarTests`
Expected: FAIL — `type 'Sidecar' has no member 'merge'`.

- [ ] **Step 3: Add merge to `Sidecar.swift`**

Append to `Sidecar.swift`:

```swift
extension Sidecar {
    /// Deterministically merge two sidecars for the same content hash.
    /// Scalar fields come from whichever has the greater `updated_at`
    /// (ties → `a`). Tags union by label; a "manual" source always wins
    /// over a non-manual one for the same label (invariant Q32).
    static func merge(_ a: Sidecar, _ b: Sidecar) -> Sidecar {
        var winner = (b.updated_at > a.updated_at) ? b : a
        winner.updated_at = max(a.updated_at, b.updated_at)
        winner.tags = mergeTags(a.tags, b.tags)
        return winner
    }

    private static func mergeTags(_ a: [SidecarTag], _ b: [SidecarTag]) -> [SidecarTag] {
        var byLabel: [String: SidecarTag] = [:]
        for tag in a + b {
            if let existing = byLabel[tag.label] {
                let incomingManual = tag.source == "manual"
                let existingManual = existing.source == "manual"
                if incomingManual && !existingManual {
                    byLabel[tag.label] = tag
                }
                // else keep existing (manual stays, or first-seen vision stays)
            } else {
                byLabel[tag.label] = tag
            }
        }
        return byLabel.values.sorted { $0.label < $1.label }
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `xcodebuild test ... -only-testing:MuseTests/SidecarTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Muse/Muse/Filesystem/Sidecar.swift Muse/MuseTests/SidecarTests.swift
git commit -m "feat: deterministic Sidecar conflict merge (manual-tag wins)"
```

---

## Phase 2 — SidecarStore file I/O (TDD against temp dirs)

### Task 4: Read/write sidecars to `<folder>/.muse/<hash>.json`

`NSFileCoordinator` works on any local URL, so this is testable in a `FileManager` temp directory with no iCloud account.

**Files:**
- Create: `Muse/Muse/Filesystem/SidecarStore.swift`
- Test: `Muse/MuseTests/SidecarStoreTests.swift`

- [ ] **Step 1: Write the failing test**

Create `Muse/MuseTests/SidecarStoreTests.swift`:

```swift
import XCTest
@testable import Muse

final class SidecarStoreTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("muse-sidecar-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func sample(hash: String) -> Sidecar {
        Sidecar(schema: 1, updated_at: 1, content_hash: hash, kind: "image",
                width: 1, height: 1, duration_seconds: nil, created_at: nil,
                modified_at: nil, caption: "c", dominant_color: nil, palette: nil,
                feature_print: nil, analyzed_hash: hash, intent: nil,
                intent_model_version: nil, tags: [])
    }

    func testWriteThenReadRoundTrip() throws {
        let asset = tempDir.appendingPathComponent("photo.jpg")
        try Data([0]).write(to: asset)
        let sc = sample(hash: "hash1")
        try SidecarStore.write(sc, forAsset: asset)
        let back = SidecarStore.read(forAsset: asset, contentHash: "hash1")
        XCTAssertEqual(back, sc)
    }

    func testSidecarLandsInHiddenMuseDir() throws {
        let asset = tempDir.appendingPathComponent("photo.jpg")
        try Data([0]).write(to: asset)
        try SidecarStore.write(sample(hash: "hash1"), forAsset: asset)
        let expected = tempDir.appendingPathComponent(".muse/hash1.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: expected.path))
    }

    func testReadMissingReturnsNil() {
        let asset = tempDir.appendingPathComponent("nope.jpg")
        XCTAssertNil(SidecarStore.read(forAsset: asset, contentHash: "absent"))
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `xcodebuild test ... -only-testing:MuseTests/SidecarStoreTests`
Expected: FAIL — `cannot find 'SidecarStore' in scope`.

- [ ] **Step 3: Implement `SidecarStore.swift`**

Create `Muse/Muse/Filesystem/SidecarStore.swift`:

```swift
//
//  SidecarStore.swift
//  Muse
//
//  Reads/writes a Sidecar to a hidden `.muse/<content_hash>.json` file
//  beside the asset, coordinated with NSFileCoordinator so it plays nice
//  with the iCloud sync daemon. Never holds a live SQLite handle in iCloud.
//

import Foundation

enum SidecarStore {
    /// `<asset's folder>/.muse/<content_hash>.json`
    static func sidecarURL(forAsset assetURL: URL, contentHash: String) -> URL {
        assetURL.deletingLastPathComponent()
            .appendingPathComponent(".muse", isDirectory: true)
            .appendingPathComponent("\(contentHash).json", isDirectory: false)
    }

    static func write(_ sidecar: Sidecar, forAsset assetURL: URL) throws {
        let target = sidecarURL(forAsset: assetURL, contentHash: sidecar.content_hash)
        let museDir = target.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: museDir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(sidecar)

        var coordError: NSError?
        var writeError: Error?
        NSFileCoordinator().coordinate(writingItemAt: target, options: .forReplacing,
                                       error: &coordError) { url in
            do { try data.write(to: url, options: .atomic) }
            catch { writeError = error }
        }
        if let coordError { throw coordError }
        if let writeError { throw writeError }
    }

    /// Returns the sidecar if present and decodable, else nil.
    static func read(forAsset assetURL: URL, contentHash: String) -> Sidecar? {
        let target = sidecarURL(forAsset: assetURL, contentHash: contentHash)
        guard FileManager.default.fileExists(atPath: target.path) else { return nil }
        var result: Sidecar?
        var coordError: NSError?
        NSFileCoordinator().coordinate(readingItemAt: target, options: [],
                                       error: &coordError) { url in
            guard let data = try? Data(contentsOf: url) else { return }
            result = try? JSONDecoder().decode(Sidecar.self, from: data)
        }
        return result
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `xcodebuild test ... -only-testing:MuseTests/SidecarStoreTests`
Expected: PASS (all four).

- [ ] **Step 5: Commit**

```bash
git add Muse/Muse/Filesystem/SidecarStore.swift Muse/MuseTests/SidecarStoreTests.swift
git commit -m "feat: SidecarStore — coordinated .muse/<hash>.json read/write"
```

---

## Phase 3 — In-app Share button (independent, build + manual verify)

This phase is independent of iCloud and can be implemented at any point. It's the outbound "share an image" direction.

### Task 5: Add a Share button to the hero viewer

**Files:**
- Modify: hero viewer chrome. Find the exact file first.

- [ ] **Step 1: Locate the hero viewer toolbar/controls file**

Run: `grep -rln "PillRow\|HeroImageViewer\|ViewerInfoColumn" Muse/Muse/Views/Viewer/`
Read the file that renders the viewer's action controls (where delete/close live). Identify the SwiftUI view that holds the selected file's `URL` (call it `fileURL` below — confirm the actual property name when you read it).

- [ ] **Step 2: Add an AppKit share helper**

Create a small helper at the top of that view's file (or a new `Muse/Muse/Views/Viewer/ShareButton.swift`):

```swift
import SwiftUI
import AppKit

/// Presents the standard macOS share sheet (AirDrop, Mail, Messages,
/// Save to Files, …) anchored to the button. The OS owns the transfer —
/// no entitlement, no network surface for the app.
struct ShareButton: View {
    let url: URL

    var body: some View {
        Button {
            present()
        } label: {
            Image(systemName: "square.and.arrow.up")
        }
        .help("Share")
    }

    private func present() {
        guard let contentView = NSApp.keyWindow?.contentView else { return }
        let picker = NSSharingServicePicker(items: [url])
        picker.show(relativeTo: .zero, of: contentView, preferredEdge: .minY)
    }
}
```

- [ ] **Step 3: Place the button next to the existing viewer controls**

In the viewer's controls row, add `ShareButton(url: <the selected file URL>)` beside the existing close/delete controls. Match the surrounding control styling (same `Image(systemName:)` + modifiers the neighbors use).

- [ ] **Step 4: Build and manually verify**

Run: `xcodebuild -project Muse/Muse.xcodeproj -scheme Muse -destination 'platform=macOS' build`
Expected: `** BUILD SUCCEEDED **`.

Then run the app (Cmd+R in Xcode), open an image into the hero viewer, click the Share button. Expected: the macOS share sheet appears with AirDrop / Mail / Messages / Save to Files; choosing Mail composes a message with the image attached.

- [ ] **Step 5: Commit**

```bash
git add Muse/Muse/Views/Viewer/
git commit -m "feat: Share button in hero viewer (NSSharingServicePicker)"
```

---

## Phase 4 — iCloud zone discovery + entitlements (build + manual verify)

### Task 6: Add iCloud entitlements, container, and App Group

**Files:**
- Modify: `Muse/Muse/Muse.entitlements`
- Modify: target Info settings (`NSUbiquitousContainers`)
- Xcode project: enable iCloud (iCloud Documents) + App Groups capabilities

- [ ] **Step 1: Enable capabilities in Xcode**

In Xcode → target **Muse** → Signing & Capabilities:
1. **+ Capability → iCloud.** Check **iCloud Documents**. Add container `iCloud.com.tarrats.Muse`.
2. **+ Capability → App Groups.** Add group `group.com.tarrats.Muse`.

This rewrites `Muse.entitlements`. Confirm it now contains (alongside the existing sandbox keys):

```xml
<key>com.apple.developer.icloud-container-identifiers</key>
<array><string>iCloud.com.tarrats.Muse</string></array>
<key>com.apple.developer.icloud-services</key>
<array><string>CloudDocuments</string></array>
<key>com.apple.developer.ubiquity-container-identifiers</key>
<array><string>iCloud.com.tarrats.Muse</string></array>
<key>com.apple.security.application-groups</key>
<array><string>group.com.tarrats.Muse</string></array>
```

Note: `com.apple.security.network.client` must **NOT** appear. iCloud Drive document sync is daemon-mediated and needs no network entitlement.

- [ ] **Step 2: Name the iCloud folder "Muse" and make it visible in iCloud Drive**

In the target's Info (Info.plist), add:

```xml
<key>NSUbiquitousContainers</key>
<dict>
  <key>iCloud.com.tarrats.Muse</key>
  <dict>
    <key>NSUbiquitousContainerIsDocumentScopePublic</key><true/>
    <key>NSUbiquitousContainerName</key><string>Muse</string>
    <key>NSUbiquitousContainerSupportedFolderLevels</key><string>Any</string>
  </dict>
</dict>
```

This makes the container's `Documents` directory appear in iCloud Drive as a top-level "Muse" folder the user can open in Finder.

- [ ] **Step 3: Build**

Run: `xcodebuild -project Muse/Muse.xcodeproj -scheme Muse -destination 'platform=macOS' build`
Expected: `** BUILD SUCCEEDED **`. (Code signing must resolve the iCloud container; if signing fails locally, confirm the Apple ID team has the container registered.)

- [ ] **Step 4: Commit**

```bash
git add Muse/Muse/Muse.entitlements Muse/Muse/Info.plist
git commit -m "feat: add iCloud Documents + App Group entitlements (no network.client)"
```

---

### Task 7: `ICloudZone` — discover the folder + membership test

**Files:**
- Create: `Muse/Muse/Filesystem/ICloudZone.swift`

The ubiquity-container call can block on first use, so it's `async`/off-main. No XCTest (depends on a live container); verified by build + manual.

- [ ] **Step 1: Implement `ICloudZone.swift`**

Create `Muse/Muse/Filesystem/ICloudZone.swift`:

```swift
//
//  ICloudZone.swift
//  Muse
//
//  The single app-managed iCloud Drive folder. Files placed in its
//  `Documents` directory sync across the user's devices via the OS daemon
//  (no app network calls). One folder only — the user may create their
//  own subfolders inside it.
//

import Foundation

enum ICloudZone {
    static let containerID = "iCloud.com.tarrats.Muse"

    /// The synced "Muse" folder URL (the container's Documents dir), creating
    /// it if needed. Returns nil if the user isn't signed into iCloud or the
    /// container is unavailable. Call off the main thread — first access can
    /// block while the daemon resolves the container.
    static func folderURL() -> URL? {
        guard let container = FileManager.default
                .url(forUbiquityContainerIdentifier: containerID) else { return nil }
        let docs = container.appendingPathComponent("Documents", isDirectory: true)
        try? FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
        return docs
    }

    /// True if `url` lives inside the iCloud zone. Cheap path-prefix test
    /// against a resolved folder URL (pass the cached `folderURL()` in).
    static func contains(_ url: URL, folder: URL?) -> Bool {
        guard let folder else { return false }
        let f = folder.standardizedFileURL.path
        let p = url.standardizedFileURL.path
        return p == f || p.hasPrefix(f + "/")
    }
}
```

- [ ] **Step 2: Build**

Run: `xcodebuild -project Muse/Muse.xcodeproj -scheme Muse -destination 'platform=macOS' build`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Commit**

```bash
git add Muse/Muse/Filesystem/ICloudZone.swift
git commit -m "feat: ICloudZone — discover the single iCloud folder + membership"
```

---

### Task 8: Surface the iCloud zone as a sidebar root

**Files:**
- Modify: `Muse/Muse/Models/AppState.swift`
- Modify: `Muse/Muse/Views/SidebarView.swift`

The iCloud folder is auto-discovered (not a bookmark). On launch, if `ICloudZone.folderURL()` resolves, add it to the sidebar as a root alongside bookmarked local roots.

- [ ] **Step 1: Add an iCloud root holder to AppState**

In `AppState.swift`, near the roots section, add:

```swift
/// The auto-discovered iCloud zone folder URL, resolved off-main at launch.
/// nil when the user isn't signed into iCloud. Cached so membership tests
/// (ICloudZone.contains) don't re-hit the daemon.
@Published var iCloudFolderURL: URL?

/// Resolve the iCloud folder once at launch and surface it in the sidebar.
func discoverICloudZone() {
    Task.detached(priority: .utility) {
        let url = ICloudZone.folderURL()
        await MainActor.run {
            self.iCloudFolderURL = url
            if let url { self.addICloudRootNode(url) }
        }
    }
}
```

Add `addICloudRootNode(_:)` that builds a `FolderNode` for the URL and appends it to `rootNodes` if not already present (mirror however local roots build their `FolderNode` — read the existing `rootNodes` construction in this file and follow it exactly).

- [ ] **Step 2: Call discovery at launch**

Find where AppState first loads roots (init or an `onAppear`/bootstrap path used by `ContentView`). Add a call to `discoverICloudZone()` there.

- [ ] **Step 3: Show it in the sidebar**

In `SidebarView.swift`, render the iCloud root node like local roots, with an iCloud SF Symbol (`icloud`) to distinguish it. Follow the existing root-row layout.

- [ ] **Step 4: Build and manually verify**

Run: build command. Expected: `** BUILD SUCCEEDED **`.
Run the app while signed into iCloud. Expected: a "Muse" folder appears in the sidebar with an iCloud glyph; selecting it shows its contents (empty initially). Confirm the same "Muse" folder is visible in Finder under iCloud Drive.

- [ ] **Step 5: Commit**

```bash
git add Muse/Muse/Models/AppState.swift Muse/Muse/Views/SidebarView.swift
git commit -m "feat: surface the iCloud zone as a sidebar root"
```

---

## Phase 5 — Hydration + sidecar writes (integration)

### Task 9: Write a sidecar after analyzing an iCloud-zone file

**Files:**
- Modify: `Muse/Muse/Intelligence/AnalyzePipeline.swift`

After `analyzeOne` writes the DB, if the file is in the iCloud zone, build a sidecar from the just-written row + tags and persist it.

- [ ] **Step 1: Add a sidecar-write helper to AnalyzePipeline**

In `AnalyzePipeline.swift`, add a method:

```swift
/// If `url` is in the iCloud zone, export the file's current metadata to a
/// `.muse/<hash>.json` sidecar so it syncs to other devices. No-op for
/// local-zone files. Reads the freshly-written FileRow + tags back out.
private func writeSidecarIfICloud(fileID: String, url: URL) async {
    let folder = await AppState.shared.iCloudFolderURL
    guard ICloudZone.contains(url, folder: folder) else { return }
    guard let queue = Database.shared.dbQueue else { return }
    let now = Int64(Date().timeIntervalSince1970)
    let bundle: (FileRow, [TagRow])? = try? await queue.read { db in
        guard let file = try FileRow.filter(FileRow.Columns.id == fileID).fetchOne(db)
        else { return nil }
        let tags = try TagRow.filter(TagRow.Columns.file_id == fileID).fetchAll(db)
        return (file, tags)
    }
    guard let (file, tags) = bundle,
          let sidecar = Sidecar.build(from: file, tags: tags, updatedAt: now) else { return }
    do { try SidecarStore.write(sidecar, forAsset: url) }
    catch { print("[AnalyzePipeline] sidecar write failed: \(error)") }
}
```

(Confirm `AppState.shared` exists; the file header says AppState is a `@MainActor` singleton. If the singleton accessor has a different name, use it.)

- [ ] **Step 2: Call it at the end of `analyzeOne`**

At the very end of `analyzeOne(fileID:url:)` (after the embedding write), add:

```swift
await writeSidecarIfICloud(fileID: fileID, url: url)
```

- [ ] **Step 3: Build and manually verify**

Run: build command. Expected: `** BUILD SUCCEEDED **`.
Run the app, drop an image into the iCloud "Muse" folder, let analysis run, then in Finder reveal the folder and enable "show hidden files" (Cmd+Shift+.). Expected: a `.muse/` folder containing `<hash>.json`; opening it shows the caption/tags/intent JSON.

- [ ] **Step 4: Commit**

```bash
git add Muse/Muse/Intelligence/AnalyzePipeline.swift
git commit -m "feat: write .muse sidecar after analyzing iCloud-zone files"
```

---

### Task 10: Hydrate from sidecars before analysis

**Files:**
- Create: `Muse/Muse/Filesystem/SidecarHydrator.swift`
- Modify: `Muse/Muse/Models/AppState.swift` (`scheduleIndexing`)

On folder load, for iCloud-zone images that have a sidecar whose `analyzed_hash` matches the file's current `content_hash`, import the sidecar into the DB and set `analyzed_hash` — so the subsequent `analyzePending` provably skips them (no re-Vision). Must run **after** `indexBatch` (so `content_hash` exists) and **before** `analyzePending`.

- [ ] **Step 1: Implement `SidecarHydrator.swift`**

Create `Muse/Muse/Filesystem/SidecarHydrator.swift`:

```swift
//
//  SidecarHydrator.swift
//  Muse
//
//  On folder load, imports current `.muse/<hash>.json` sidecars into the
//  local SQLite (FileRow + tags + FTS + analyzed_hash) so the automatic
//  analysis pass skips already-described files. This is what lets an
//  iCloud-only / fresh device reconstruct the experience without re-running
//  Vision. Pure mapping lives in Sidecar; this is the thin DB writer.
//

import Foundation
import GRDB

enum SidecarHydrator {
    /// For each url in the iCloud zone, if a matching sidecar exists and is
    /// current (sidecar.analyzed_hash == the file's content_hash), apply it.
    static func hydrate(urls: [URL], folder: URL?) async {
        guard folder != nil, let queue = Database.shared.dbQueue else { return }
        for url in urls {
            guard ICloudZone.contains(url, folder: folder) else { continue }
            let absPath = url.standardizedFileURL.path
            // Resolve the file id + current content hash.
            let info: (id: String, hash: String)? = try? await queue.read { db in
                guard let path = try PathRow
                        .filter(PathRow.Columns.absolute_path == absPath)
                        .filter(PathRow.Columns.is_alive == 1).fetchOne(db),
                      let fid = path.file_id,
                      let file = try FileRow.filter(FileRow.Columns.id == fid).fetchOne(db),
                      let hash = file.content_hash else { return nil }
                // Already analyzed at this content — nothing to import.
                if file.analyzed_hash == hash { return nil }
                return (fid, hash)
            } ?? nil
            guard let info else { continue }
            guard let sidecar = SidecarStore.read(forAsset: url, contentHash: info.hash),
                  sidecar.analyzed_hash == info.hash else { continue }
            await apply(sidecar, fileID: info.id, basename: url.lastPathComponent, queue: queue)
        }
    }

    private static func apply(_ sidecar: Sidecar, fileID: String,
                              basename: String, queue: DatabaseQueue) async {
        try? await queue.write { db in
            if var file = try FileRow.filter(FileRow.Columns.id == fileID).fetchOne(db) {
                sidecar.apply(onto: &file)
                try file.update(db)
            }
            // Tags: insert sidecar tags, honoring manual-beats-vision (Q32).
            for t in sidecar.tagRows(fileID: fileID, makeID: { UUID().uuidString }) {
                if let existing = try TagRow
                    .filter(TagRow.Columns.file_id == fileID)
                    .filter(TagRow.Columns.label == t.label).fetchOne(db) {
                    if existing.source != "manual" && t.source == "manual" {
                        var u = existing; u.source = "manual"; u.confidence = nil
                        u.model_version = nil; try u.update(db)
                    }
                } else {
                    var row = t; try row.insert(db)
                }
            }
            // FTS5 — mirror AnalyzePipeline's keying.
            try db.execute(sql: "DELETE FROM files_fts WHERE file_id = ?", arguments: [fileID])
            try db.execute(sql: """
                INSERT INTO files_fts(file_id, basename, ocr_text, caption)
                VALUES (?, ?, ?, ?)
            """, arguments: [fileID, basename, "", sidecar.caption ?? ""])
        }
    }
}
```

Note: OCR text is not carried in the sidecar (it's large and only feeds FTS + intent, both reconstructable); FTS gets basename + caption on hydrate, which is sufficient for search. If full-text OCR search on hydrated-only files proves necessary later, add `ocr_text` to the sidecar — out of scope for v1 (matches the spec's "what travels" list).

- [ ] **Step 2: Call the hydrator in `scheduleIndexing`**

In `AppState.swift`, in `scheduleIndexing(for:)`, between `indexBatch` and `analyzePending`, add:

```swift
await SidecarHydrator.hydrate(urls: imageURLs, folder: self.iCloudFolderURL)
```

(`imageURLs` is already computed in that method; `self.iCloudFolderURL` is read inside the detached task — capture it on the main actor as the method already hops actors. If the compiler flags actor isolation, read `iCloudFolderURL` into a local before the `Task.detached` and capture the local.)

- [ ] **Step 3: Build and manually verify the round-trip**

Run: build command. Expected: `** BUILD SUCCEEDED **`.

Manual end-to-end (the core promise):
1. On Mac A, drop an image into the iCloud "Muse" folder; let it analyze (a `.muse/<hash>.json` appears).
2. Wipe the local DB only: quit the app, delete `~/Library/Containers/com.tarrats.Muse/Data/Library/Application Support/Muse/muse.sqlite`, relaunch.
3. Open the iCloud folder. Expected: the image's tags/caption/intent are present **without** the "Analyzing N of M" pill running over it — proof it hydrated from the sidecar instead of re-running Vision.

- [ ] **Step 4: Commit**

```bash
git add Muse/Muse/Filesystem/SidecarHydrator.swift Muse/Muse/Models/AppState.swift
git commit -m "feat: hydrate DB from .muse sidecars before analysis (no re-Vision)"
```

---

## Phase 6 — "Send to Muse" share extension (build + manual verify)

### Task 11: Create the share extension target

**Files:**
- Create: `Muse/MuseShareExtension/` target (`ShareViewController.swift`, `Info.plist`, `MuseShareExtension.entitlements`)

- [ ] **Step 1: Add the target in Xcode**

Xcode → File → New → Target → **Share Extension**. Name it `MuseShareExtension`. This creates the folder, a `ShareViewController`, and `Info.plist`.

- [ ] **Step 2: Give the extension the iCloud container + App Group**

On the **MuseShareExtension** target → Signing & Capabilities:
1. **iCloud → iCloud Documents**, container `iCloud.com.tarrats.Muse` (same as the app).
2. **App Groups**, group `group.com.tarrats.Muse`.

Confirm `MuseShareExtension.entitlements` mirrors the app's iCloud + app-group keys. Do **not** add `network.client`.

- [ ] **Step 3: Declare which content types the extension accepts**

In the extension's `Info.plist`, set `NSExtensionActivationRule` to accept files/images. Use a predicate so it appears for image and generic file shares:

```xml
<key>NSExtension</key>
<dict>
  <key>NSExtensionPointIdentifier</key>
  <string>com.apple.share-services</string>
  <key>NSExtensionPrincipalClass</key>
  <string>$(PRODUCT_MODULE_NAME).ShareViewController</string>
  <key>NSExtensionAttributes</key>
  <dict>
    <key>NSExtensionActivationRule</key>
    <dict>
      <key>NSExtensionActivationSupportsFileWithMaxCount</key><integer>20</integer>
      <key>NSExtensionActivationSupportsImageWithMaxCount</key><integer>20</integer>
    </dict>
  </dict>
</dict>
```

- [ ] **Step 4: Implement `ShareViewController` to copy items into the iCloud folder**

Replace the generated `Muse/MuseShareExtension/ShareViewController.swift`:

```swift
//
//  ShareViewController.swift
//  MuseShareExtension
//
//  "Send to Muse" — copies shared files into the single Muse iCloud folder.
//  The main app's FolderWatcher then indexes/analyzes them and writes the
//  sidecar via the normal pipeline. No network, no UI beyond confirmation.
//

import Cocoa
import UniformTypeIdentifiers

final class ShareViewController: NSViewController {
    private let containerID = "iCloud.com.tarrats.Muse"

    override func loadView() {
        // Minimal headless view; we complete immediately after copying.
        self.view = NSView(frame: NSRect(x: 0, y: 0, width: 1, height: 1))
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        Task { await handleShare() }
    }

    private func icloudFolder() -> URL? {
        guard let c = FileManager.default
                .url(forUbiquityContainerIdentifier: containerID) else { return nil }
        let docs = c.appendingPathComponent("Documents", isDirectory: true)
        try? FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
        return docs
    }

    private func handleShare() async {
        defer { extensionContext?.completeRequest(returningItems: nil) }
        guard let dest = icloudFolder(),
              let items = extensionContext?.inputItems as? [NSExtensionItem] else { return }
        for item in items {
            for provider in item.attachments ?? [] {
                guard provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
                        || provider.hasItemConformingToTypeIdentifier(UTType.image.identifier)
                else { continue }
                if let url = try? await loadFileURL(provider) {
                    copyIn(url, to: dest)
                }
            }
        }
    }

    private func loadFileURL(_ provider: NSItemProvider) async throws -> URL? {
        try await withCheckedThrowingContinuation { cont in
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { item, error in
                if let error { cont.resume(throwing: error); return }
                if let data = item as? Data,
                   let url = URL(dataRepresentation: data, relativeTo: nil) {
                    cont.resume(returning: url)
                } else if let url = item as? URL {
                    cont.resume(returning: url)
                } else {
                    cont.resume(returning: nil)
                }
            }
        }
    }

    private func copyIn(_ src: URL, to dest: URL) {
        let target = uniqueDestination(for: src.lastPathComponent, in: dest)
        var coordError: NSError?
        NSFileCoordinator().coordinate(readingItemAt: src, options: [],
                                       writingItemAt: target, options: .forReplacing,
                                       error: &coordError) { readURL, writeURL in
            try? FileManager.default.copyItem(at: readURL, to: writeURL)
        }
    }

    /// Avoid clobbering an existing file: append " 2", " 3", … if needed.
    private func uniqueDestination(for name: String, in dir: URL) -> URL {
        let fm = FileManager.default
        var candidate = dir.appendingPathComponent(name)
        guard fm.fileExists(atPath: candidate.path) else { return candidate }
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var n = 2
        repeat {
            let newName = ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)"
            candidate = dir.appendingPathComponent(newName)
            n += 1
        } while fm.fileExists(atPath: candidate.path)
        return candidate
    }
}
```

- [ ] **Step 5: Build and manually verify**

Run: `xcodebuild -project Muse/Muse.xcodeproj -scheme Muse -destination 'platform=macOS' build`
Expected: `** BUILD SUCCEEDED **` (both app and extension targets).

Run the app once (so the extension registers). Then in Finder, right-click an image on the desktop → **Share → Send to Muse** (or use the system share sheet from another app). Expected: the file appears in the iCloud "Muse" folder; switching to Muse, the new file shows up (FolderWatcher picks it up), gets indexed/analyzed, and a `.muse/` sidecar is written. On a second signed-in device, the file + sidecar sync down.

- [ ] **Step 6: Commit**

```bash
git add Muse/MuseShareExtension/
git commit -m "feat: 'Send to Muse' share extension → iCloud folder"
```

---

## Phase 7 — Docs

### Task 12: Update CLAUDE.md

**Files:**
- Modify: `CLAUDE.md`

- [ ] **Step 1: Update the network-policy nuance**

In the "Project identity" section's network bullet, append: iCloud Drive document sync is OS-daemon-mediated and adds the iCloud Documents entitlement but **no** `network.client`; the app still makes zero network calls and the developer receives no data, so "Data Not Collected" holds.

- [ ] **Step 2: Add to the architecture map**

Under `Filesystem/`, add `Sidecar.swift`, `SidecarStore.swift`, `ICloudZone.swift`, `SidecarHydrator.swift` with one-line descriptions. Add a top-level note for the `MuseShareExtension/` target. Note the Share button in the viewer section.

- [ ] **Step 3: Add a phase-log entry**

Add a dated session entry summarizing: two-zone model, complete `.muse/` sidecar (what travels vs re-derives), iCloud Drive (not CloudKit) rationale, Share button, "Send to Muse" extension.

- [ ] **Step 4: Commit**

```bash
git add CLAUDE.md
git commit -m "docs: record iCloud sync folder + macOS share integration"
```

---

## Self-Review

**Spec coverage:**
- Two-zone model → Tasks 6–8. ✅
- Complete portable sidecar (what travels / re-derives) → Tasks 1–4, 9; OCR-exclusion noted in Task 10. ✅
- Hydration / iCloud-only cold start → Task 10 (+ manual round-trip verifying no re-Vision). ✅
- Conflict merge (manual-tag preservation) → Task 3. ✅
- Identity/privacy (iCloud Documents, no `network.client`) → Task 6 step 1, Task 12. ✅
- In-app Share button → Task 5. ✅
- "Send to Muse" extension → Task 11. ✅
- No CloudKit, no live SQLite in iCloud → honored throughout (sidecar is JSON snapshots). ✅
- Collections/thumbnails re-derive → unchanged existing code; no task needed (correct per spec). ✅

**Placeholder scan:** No "TBD"/"handle edge cases"/"similar to". Integration tasks that can't be unit-tested specify exact config + a concrete manual verification instead — intentional, per the testing note.

**Type consistency:** `Sidecar` fields are consistent across Tasks 1–3, 9, 10. `Sidecar.build(from:tags:updatedAt:)`, `apply(onto:)`, `tagRows(fileID:makeID:)`, `merge(_:_:)`, `SidecarStore.write(_:forAsset:)` / `read(forAsset:contentHash:)` / `sidecarURL(forAsset:contentHash:)`, `ICloudZone.folderURL()` / `contains(_:folder:)`, `SidecarHydrator.hydrate(urls:folder:)` are used with matching signatures everywhere they appear.

**Known integration unknowns (flagged for the implementer, not placeholders):** the hero viewer's selected-file property name (Task 5 step 1), the exact `rootNodes`/`FolderNode` construction for the iCloud root (Task 8 step 1), and the AppState singleton accessor name (Task 9 step 1) — each task says to read the surrounding code and follow the existing pattern, because the precise local symbol can't be quoted without opening those specific lines during implementation.
