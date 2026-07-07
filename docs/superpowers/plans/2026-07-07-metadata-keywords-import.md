# Import Keywords & Ratings (Lightroom/Bridge/Capture One) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** File > Import Keywords & Ratings… reads IPTC/XMP keywords + star ratings written by Lightroom/Bridge/Capture One (embedded or `.xmp` sidecar) and turns them into Muse manual tags and ratings — read-only, idempotent, never overwriting a rating the user set in Muse.

**Architecture:** Three tested units (pure rules → ImageIO reader → GRDB apply statics) orchestrated by a thin `@MainActor` model driving a progress sheet. Index first (tags attach to `(file_id, parent_dir)` rows), then read metadata off-main, then batched per-file writes through the existing tag/rating seams.

**Tech Stack:** Swift/SwiftUI, ImageIO (`CGImageMetadata` — no pixel decode), GRDB, XCTest.

**Spec:** `docs/superpowers/specs/2026-07-07-metadata-keywords-import-design.md`

## Global Constraints

- No network code anywhere in this feature.
- Files are READ-ONLY — never write metadata into a user file; never `unlink`.
- Every user-facing string localized: SwiftUI text-literal positions auto-extract; anything passed as `String` (NSOpenPanel `message`/`prompt`) must be hand-wrapped in `String(localized:)`. French values filled via `-exportLocalizations` (Task 6).
- Dataless iCloud files must not be force-downloaded: skip via `.ubiquitousItemDownloadingStatusKey == .notDownloaded` (same guard as `AssetKind`/`FileMetadata`).
- Path containment checks use `path == prefix || path.hasPrefix(prefix + "/")`.
- No fixed-height sheet (`.frame(width:)` only — content-sized like DriveShareForm).
- GRDB rows insert as `var`; async `queue.write`/`queue.read`.
- Tag writes are per `(file_id, parent_dir)` via `TagScope.parentDir(ofPath:)`; manual tier (`source: "manual"`, `confidence: nil`).
- Run tests with `xcodebuild -project Muse/Muse.xcodeproj -scheme Muse test -only-testing:MuseTests/<ClassName>` per task; full `MuseTests` at the end. Suite must run in an English host.
- All new app files go in `Muse/Muse/Import/` (filesystem-synchronized group — no pbxproj edit needed); tests in `Muse/MuseTests/`.
- Work on branch `feat/next-125`.

---

### Task 1: `MetadataImportRules` — pure normalize/conflict rules

**Files:**
- Create: `Muse/Muse/Import/MetadataImportRules.swift`
- Test: `Muse/MuseTests/MetadataImportRulesTests.swift`

**Interfaces:**
- Consumes: `StarRating.maxStars` (existing, = 5).
- Produces: `MetadataImportRules.normalizeKeywords(_: [String]) -> [String]`, `normalizeRating(_: Double?) -> Int?`, `ratingToApply(imported: Int?, existingHasRating: Bool) -> Int?` — used by Tasks 2 and 4.

- [ ] **Step 1: Write the failing tests**

```swift
//
//  MetadataImportRulesTests.swift
//  MuseTests
//
//  Pure conflict/normalize rules for the keywords & ratings import: keyword
//  trim/dedupe, XMP/IPTC rating clamp, and the "never clobber a Muse rating"
//  decision.
//

import XCTest
@testable import Muse

final class MetadataImportRulesTests: XCTestCase {

    // MARK: normalizeKeywords

    func testKeywordsTrimDropEmptyAndDedupeCaseInsensitively() {
        let out = MetadataImportRules.normalizeKeywords(
            ["  Travel ", "japan", "", "   ", "TRAVEL", "Japan", "tokyo"])
        // First spelling wins; order preserved.
        XCTAssertEqual(out, ["Travel", "japan", "tokyo"])
    }

    func testKeywordsEmptyInputIsEmptyOutput() {
        XCTAssertEqual(MetadataImportRules.normalizeKeywords([]), [])
    }

    // MARK: normalizeRating

    func testRatingPassesOneThroughFive() {
        XCTAssertEqual(MetadataImportRules.normalizeRating(1), 1)
        XCTAssertEqual(MetadataImportRules.normalizeRating(5), 5)
        XCTAssertEqual(MetadataImportRules.normalizeRating(3.0), 3)
    }

    func testRatingClampsAboveFive() {
        XCTAssertEqual(MetadataImportRules.normalizeRating(7), 5)
    }

    func testRatingZeroNegativeAndAbsentAreNil() {
        XCTAssertNil(MetadataImportRules.normalizeRating(0))    // unrated
        XCTAssertNil(MetadataImportRules.normalizeRating(-1))   // LR "rejected"
        XCTAssertNil(MetadataImportRules.normalizeRating(nil))
    }

    // MARK: ratingToApply

    func testImportedRatingFillsGapOnly() {
        XCTAssertEqual(MetadataImportRules.ratingToApply(imported: 4, existingHasRating: false), 4)
        XCTAssertNil(MetadataImportRules.ratingToApply(imported: 4, existingHasRating: true))
        XCTAssertNil(MetadataImportRules.ratingToApply(imported: nil, existingHasRating: false))
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd "/Users/carlostarrats/Documents/Projects/Muse/Muse App" && xcodebuild -project Muse/Muse.xcodeproj -scheme Muse test -only-testing:MuseTests/MetadataImportRulesTests 2>&1 | tail -20`
Expected: BUILD FAILED — "cannot find 'MetadataImportRules' in scope".

- [ ] **Step 3: Write the implementation**

```swift
//
//  MetadataImportRules.swift
//  Muse
//
//  Pure rules for the keywords & ratings import (File > Import Keywords &
//  Ratings…). Kept UI/DB-free so the conflict semantics are unit-tested:
//  keywords merge, ratings only fill gaps — a rating set in Muse is never
//  clobbered by an import, and re-running an import changes nothing.
//

import Foundation

enum MetadataImportRules {

    /// Trim whitespace, drop empties, dedupe case-insensitively (the first
    /// spelling wins), preserving order. Keywords are stored VERBATIM as
    /// canonical labels — user words, same as hand-typed tags (no
    /// VisionVocabulary row).
    static func normalizeKeywords(_ raw: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for keyword in raw {
            let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if seen.insert(trimmed.lowercased()).inserted { out.append(trimmed) }
        }
        return out
    }

    /// XMP `xmp:Rating` / IPTC star rating → Muse stars. 1–5 pass (above 5
    /// clamps to 5); 0 (unrated), negative (Lightroom's −1 "rejected"), or
    /// absent → nil.
    static func normalizeRating(_ raw: Double?) -> Int? {
        guard let raw else { return nil }
        let rounded = Int(raw.rounded())
        guard rounded >= 1 else { return nil }
        return min(rounded, StarRating.maxStars)
    }

    /// Import fills rating gaps only: returns the stars to write, or nil when
    /// nothing should be written (no imported rating, or the user already
    /// rated the file in Muse).
    static func ratingToApply(imported: Int?, existingHasRating: Bool) -> Int? {
        guard let imported, !existingHasRating else { return nil }
        return imported
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: same command as Step 2.
Expected: `Test Suite 'MetadataImportRulesTests' passed` (7 tests).

- [ ] **Step 5: Commit**

```bash
git add Muse/Muse/Import/MetadataImportRules.swift Muse/MuseTests/MetadataImportRulesTests.swift
git commit -m "feat: pure normalize/conflict rules for metadata keywords import"
```

---

### Task 2: `MetadataKeywordReader` — ImageIO read (sidecar → XMP → IPTC)

**Files:**
- Create: `Muse/Muse/Import/MetadataKeywordReader.swift`
- Test: `Muse/MuseTests/MetadataKeywordReaderTests.swift`

**Interfaces:**
- Consumes: `MetadataImportRules.normalizeKeywords` / `normalizeRating` (Task 1).
- Produces: `MetadataKeywordReader.read(url: URL) throws -> Extracted` where `struct Extracted: Equatable { var keywords: [String]; var rating: Int?; var isEmpty: Bool }` and `enum ReadError: Error { case dataless, unreadable }` — used by Task 4. `read` is `nonisolated`/static, safe to call off-main.

- [ ] **Step 1: Write the failing tests**

Fixture pattern follows `ImageMetadataStripperTests.makeTaggedJPEG` (build tiny JPEGs via ImageIO into `FileManager.default.temporaryDirectory`).

```swift
//
//  MetadataKeywordReaderTests.swift
//  MuseTests
//
//  The import's read half: IPTC keywords/star-rating, embedded XMP
//  (dc:subject + xmp:Rating), and .xmp sidecars (both IMG.xmp and
//  IMG.ext.xmp namings), with sidecar > embedded priority and clean throws
//  for unreadable files. No pixel decode is asserted implicitly: these
//  fixtures are valid images, but the garbage-bytes case must still throw
//  rather than crash.
//

import XCTest
import ImageIO
import UniformTypeIdentifiers
@testable import Muse

final class MetadataKeywordReaderTests: XCTestCase {

    private var tempFiles: [URL] = []

    override func tearDown() {
        for url in tempFiles { try? FileManager.default.removeItem(at: url) }
        tempFiles = []
        super.tearDown()
    }

    private func tempURL(_ name: String) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("muse-import-\(UUID().uuidString)-\(name)")
        tempFiles.append(url)
        return url
    }

    /// Tiny valid JPEG with optional IPTC keywords/rating baked in.
    private func makeJPEG(name: String = "img.jpg",
                          iptcKeywords: [String]? = nil,
                          iptcRating: Int? = nil) throws -> URL {
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: 8, height: 8,
                            bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        let cg = ctx.makeImage()!
        var iptc: [CFString: Any] = [:]
        if let iptcKeywords { iptc[kCGImagePropertyIPTCKeywords] = iptcKeywords }
        if let iptcRating { iptc[kCGImagePropertyIPTCStarRating] = iptcRating }
        let props: [CFString: Any] = iptc.isEmpty ? [:] : [kCGImagePropertyIPTCDictionary: iptc]
        let data = NSMutableData()
        let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, cg, props as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        let url = tempURL(name)
        try (data as Data).write(to: url)
        return url
    }

    private func xmpPacket(subjects: [String], rating: Int?) -> String {
        let items = subjects.map { "<rdf:li>\($0)</rdf:li>" }.joined()
        let ratingAttr = rating.map { " xmp:Rating=\"\($0)\"" } ?? ""
        return """
        <x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF \
        xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">\
        <rdf:Description rdf:about="" \
        xmlns:dc="http://purl.org/dc/elements/1.1/" \
        xmlns:xmp="http://ns.adobe.com/xap/1.0/"\(ratingAttr)>\
        <dc:subject><rdf:Bag>\(items)</rdf:Bag></dc:subject>\
        </rdf:Description></rdf:RDF></x:xmpmeta>
        """
    }

    /// JPEG with an embedded XMP packet (dc:subject + xmp:Rating).
    private func makeXMPJPEG(subjects: [String], rating: Int?) throws -> URL {
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: 8, height: 8,
                            bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        let cg = ctx.makeImage()!
        let packet = xmpPacket(subjects: subjects, rating: rating)
        let meta = CGImageMetadataCreateFromXMPData(packet.data(using: .utf8)! as CFData)!
        let data = NSMutableData()
        let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImageAndMetadata(dest, cg, meta, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        let url = tempURL("xmp.jpg")
        try (data as Data).write(to: url)
        return url
    }

    // MARK: embedded IPTC

    func testReadsIPTCKeywordsAndRating() throws {
        let url = try makeJPEG(iptcKeywords: ["dog", "park"], iptcRating: 3)
        let out = try MetadataKeywordReader.read(url: url)
        XCTAssertEqual(Set(out.keywords), ["dog", "park"])
        XCTAssertEqual(out.rating, 3)
    }

    // MARK: embedded XMP

    func testReadsEmbeddedXMPSubjectsAndRating() throws {
        let url = try makeXMPJPEG(subjects: ["travel", "japan"], rating: 4)
        let out = try MetadataKeywordReader.read(url: url)
        XCTAssertEqual(Set(out.keywords), ["travel", "japan"])
        XCTAssertEqual(out.rating, 4)
    }

    func testXMPRatingClampsThroughNormalize() throws {
        let url = try makeXMPJPEG(subjects: [], rating: 7)
        XCTAssertEqual(try MetadataKeywordReader.read(url: url).rating, 5)
    }

    // MARK: sidecars

    func testSidecarBeatsEmbeddedMetadata() throws {
        // Embedded says one thing; the sidecar (replaced-extension naming,
        // IMG.xmp beside IMG.jpg) says another. Sidecar wins per field.
        let img = try makeJPEG(name: "pic.jpg", iptcKeywords: ["embedded"], iptcRating: 2)
        let sidecar = img.deletingPathExtension().appendingPathExtension("xmp")
        try xmpPacket(subjects: ["sidecar"], rating: 5)
            .write(to: sidecar, atomically: true, encoding: .utf8)
        tempFiles.append(sidecar)
        let out = try MetadataKeywordReader.read(url: img)
        XCTAssertEqual(out.keywords, ["sidecar"])
        XCTAssertEqual(out.rating, 5)
    }

    func testAppendedExtensionSidecarIsFound() throws {
        // Some tools write IMG.jpg.xmp instead of IMG.xmp.
        let img = try makeJPEG(name: "pic2.jpg")
        let sidecar = img.appendingPathExtension("xmp")
        try xmpPacket(subjects: ["appended"], rating: nil)
            .write(to: sidecar, atomically: true, encoding: .utf8)
        tempFiles.append(sidecar)
        XCTAssertEqual(try MetadataKeywordReader.read(url: img).keywords, ["appended"])
    }

    func testSidecarFillsOnlyMissingFields() throws {
        // Sidecar has keywords but no rating → rating falls through to embedded.
        let img = try makeJPEG(name: "pic3.jpg", iptcKeywords: ["embedded"], iptcRating: 2)
        let sidecar = img.deletingPathExtension().appendingPathExtension("xmp")
        try xmpPacket(subjects: ["sidecar"], rating: nil)
            .write(to: sidecar, atomically: true, encoding: .utf8)
        tempFiles.append(sidecar)
        let out = try MetadataKeywordReader.read(url: img)
        XCTAssertEqual(out.keywords, ["sidecar"])
        XCTAssertEqual(out.rating, 2)
    }

    // MARK: nothing / errors

    func testNoMetadataIsEmptyNotError() throws {
        let url = try makeJPEG()
        let out = try MetadataKeywordReader.read(url: url)
        XCTAssertTrue(out.isEmpty)
    }

    func testUnreadableFileThrows() throws {
        let url = tempURL("garbage.jpg")
        try Data([0x00, 0x01, 0x02, 0x03]).write(to: url)
        XCTAssertThrowsError(try MetadataKeywordReader.read(url: url)) { error in
            guard case MetadataKeywordReader.ReadError.unreadable = error else {
                return XCTFail("expected .unreadable, got \(error)")
            }
        }
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd "/Users/carlostarrats/Documents/Projects/Muse/Muse App" && xcodebuild -project Muse/Muse.xcodeproj -scheme Muse test -only-testing:MuseTests/MetadataKeywordReaderTests 2>&1 | tail -20`
Expected: BUILD FAILED — "cannot find 'MetadataKeywordReader' in scope".

- [ ] **Step 3: Write the implementation**

```swift
//
//  MetadataKeywordReader.swift
//  Muse
//
//  Read-only extraction of the keywords + star rating other tools
//  (Lightroom, Bridge, Capture One) wrote into an image. Priority PER FIELD:
//  .xmp sidecar → embedded XMP (dc:subject / xmp:Rating via CGImageMetadata)
//  → embedded IPTC (legacy fallback). Metadata-only reads — never decodes
//  pixels, so the 300 MP decode budget isn't in play — and never touches a
//  dataless iCloud placeholder (reading would force a download; same guard
//  as AssetKind / FileMetadata).
//

import Foundation
import ImageIO

enum MetadataKeywordReader {

    struct Extracted: Equatable {
        var keywords: [String] = []
        var rating: Int? = nil
        var isEmpty: Bool { keywords.isEmpty && rating == nil }
        fileprivate var complete: Bool { !keywords.isEmpty && rating != nil }
    }

    enum ReadError: Error {
        /// Not-downloaded iCloud placeholder — skipped, never force-downloaded.
        case dataless
        /// Neither the file nor a sidecar could be opened as metadata.
        case unreadable
    }

    /// Files with no keywords/rating return an empty `Extracted` (the caller
    /// counts "had none"); dataless placeholders and unopenable files throw
    /// (counted "skipped"). Call off-main.
    static func read(url: URL) throws -> Extracted {
        if (try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey]))?
            .ubiquitousItemDownloadingStatus == .notDownloaded {
            throw ReadError.dataless
        }
        let sidecar = sidecarMetadata(for: url)
        let source = CGImageSourceCreateWithURL(url as CFURL, nil)
        guard sidecar != nil || source != nil else { throw ReadError.unreadable }

        var out = Extracted()
        if let sidecar { merge(from: sidecar, into: &out) }
        if let source, !out.complete {
            if let meta = CGImageSourceCopyMetadataAtIndex(source, 0, nil) {
                merge(from: meta, into: &out)
            }
            if !out.complete { mergeIPTC(from: source, into: &out) }
        }
        return out
    }

    // MARK: - Sidecar

    /// Lightroom/Capture One write `IMG_1234.xmp` beside `IMG_1234.cr2`
    /// (replaced extension); some tools append instead (`IMG_1234.cr2.xmp`).
    /// Checked for every kind, not just RAW — harmless when absent.
    private static func sidecarMetadata(for url: URL) -> CGImageMetadata? {
        let candidates = [
            url.deletingPathExtension().appendingPathExtension("xmp"),
            url.appendingPathExtension("xmp"),
        ]
        for candidate in candidates {
            guard let data = try? Data(contentsOf: candidate),
                  let meta = CGImageMetadataCreateFromXMPData(data as CFData)
            else { continue }
            return meta
        }
        return nil
    }

    // MARK: - XMP (sidecar or embedded)

    /// Fill only the fields still missing — this is what gives the per-field
    /// sidecar → embedded priority.
    private static func merge(from meta: CGImageMetadata, into out: inout Extracted) {
        if out.keywords.isEmpty {
            out.keywords = MetadataImportRules.normalizeKeywords(xmpSubjects(meta))
        }
        if out.rating == nil,
           let tag = CGImageMetadataCopyTagWithPath(meta, nil, "xmp:Rating" as CFString) {
            out.rating = MetadataImportRules.normalizeRating(doubleValue(of: tag))
        }
    }

    /// `dc:subject` is an XMP Bag: its tag value is an array whose elements
    /// are child CGImageMetadataTags (occasionally raw strings — handle both).
    private static func xmpSubjects(_ meta: CGImageMetadata) -> [String] {
        guard let tag = CGImageMetadataCopyTagWithPath(meta, nil, "dc:subject" as CFString),
              let value = CGImageMetadataTagCopyValue(tag) else { return [] }
        if let single = value as? String { return [single] }
        guard let items = value as? [Any] else { return [] }
        return items.compactMap { item in
            let ref = item as CFTypeRef
            if CFGetTypeID(ref) == CGImageMetadataTagGetTypeID() {
                let itemTag = unsafeDowncast(ref as AnyObject, to: CGImageMetadataTag.self)
                return CGImageMetadataTagCopyValue(itemTag) as? String
            }
            return item as? String
        }
    }

    private static func doubleValue(of tag: CGImageMetadataTag) -> Double? {
        guard let value = CGImageMetadataTagCopyValue(tag) else { return nil }
        if let str = value as? String { return Double(str) }
        return (value as? NSNumber)?.doubleValue
    }

    // MARK: - IPTC (legacy fallback)

    /// Header-only properties read (no pixel decode) — the pre-XMP path older
    /// tools wrote: IPTC Keywords + IPTC star rating.
    private static func mergeIPTC(from source: CGImageSource, into out: inout Extracted) {
        guard let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let iptc = props[kCGImagePropertyIPTCDictionary] as? [CFString: Any]
        else { return }
        if out.keywords.isEmpty {
            let raw = (iptc[kCGImagePropertyIPTCKeywords] as? [String])
                ?? (iptc[kCGImagePropertyIPTCKeywords] as? String).map { [$0] }
                ?? []
            out.keywords = MetadataImportRules.normalizeKeywords(raw)
        }
        if out.rating == nil, let n = iptc[kCGImagePropertyIPTCStarRating] as? NSNumber {
            out.rating = MetadataImportRules.normalizeRating(n.doubleValue)
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: same command as Step 2.
Expected: `Test Suite 'MetadataKeywordReaderTests' passed` (9 tests). If `testReadsIPTCKeywordsAndRating` fails because ImageIO surfaces the IPTC dictionary under a synthesized XMP path first, that's fine as long as keywords/rating come out equal — the assertions test the RESULT, not the branch. If a CF-cast crashes in `xmpSubjects`, fix the cast, not the test.

- [ ] **Step 5: Commit**

```bash
git add Muse/Muse/Import/MetadataKeywordReader.swift Muse/MuseTests/MetadataKeywordReaderTests.swift
git commit -m "feat: ImageIO keywords/rating reader (sidecar > XMP > IPTC)"
```

---

### Task 3: `MetadataImportApply` — GRDB write statics

**Files:**
- Create: `Muse/Muse/Import/MetadataImportApply.swift`
- Test: `Muse/MuseTests/MetadataImportApplyTests.swift`

**Interfaces:**
- Consumes: `PathRow`, `TagRow`, `TagScope.parentDir(ofPath:)`, `StarRating.isRating` (all existing).
- Produces (used by Task 4):
  - `struct Scope { let fileID: String; let dir: String }`
  - `MetadataImportApply.scope(db: GRDB.Database, absPath: String) throws -> Scope?` (nil = not indexed → caller counts skipped)
  - `MetadataImportApply.applyKeywords(db: GRDB.Database, scope: Scope, labels: [String]) throws`
  - `MetadataImportApply.hasRating(db: GRDB.Database, scope: Scope) throws -> Bool`

Pattern: pure-SQL statics testable on an in-memory queue, like `Indexer.inheritVisionTags` (see `TagFolderScopeTests`).

- [ ] **Step 1: Write the failing tests**

```swift
//
//  MetadataImportApplyTests.swift
//  MuseTests
//
//  The import's DB half: manual-tag insert-or-promote per (file_id,
//  parent_dir), rating presence check, unknown-path nil scope, and
//  idempotency (running the same import twice changes nothing — no UNIQUE
//  violation, no duplicate rows).
//

import XCTest
import GRDB
@testable import Muse

final class MetadataImportApplyTests: XCTestCase {

    private func migrated() throws -> DatabaseQueue {
        let q = try DatabaseQueue()
        try Database.makeMigrator().migrate(q)
        return q
    }

    private func seed(_ db: GRDB.Database) throws {
        try db.execute(sql: "INSERT INTO files (id, kind, last_seen_at) VALUES ('f1','image',0)")
        try db.execute(sql: "INSERT INTO paths (id, file_id, absolute_path, is_alive) VALUES ('p1','f1','/A/x.jpg',1)")
    }

    func testScopeResolvesAlivePathAndNilForUnknown() throws {
        let q = try migrated()
        try q.write { db in
            try seed(db)
            let scope = try MetadataImportApply.scope(db: db, absPath: "/A/x.jpg")
            XCTAssertEqual(scope?.fileID, "f1")
            XCTAssertEqual(scope?.dir, "/A")
            XCTAssertNil(try MetadataImportApply.scope(db: db, absPath: "/A/nope.jpg"))
        }
    }

    func testScopeIgnoresDeadPaths() throws {
        let q = try migrated()
        try q.write { db in
            try db.execute(sql: "INSERT INTO files (id, kind, last_seen_at) VALUES ('f1','image',0)")
            try db.execute(sql: "INSERT INTO paths (id, file_id, absolute_path, is_alive) VALUES ('p1','f1','/A/x.jpg',0)")
            XCTAssertNil(try MetadataImportApply.scope(db: db, absPath: "/A/x.jpg"))
        }
    }

    func testApplyKeywordsInsertsManualAndPromotesVision() throws {
        let q = try migrated()
        try q.write { db in
            try seed(db)
            // Existing vision tag with the same label → promoted to manual.
            try db.execute(sql: """
                INSERT INTO tags (id, file_id, parent_dir, label, source, confidence)
                VALUES ('t1','f1','/A','dog','vision',0.9)
                """)
            let scope = try MetadataImportApply.scope(db: db, absPath: "/A/x.jpg")!
            try MetadataImportApply.applyKeywords(db: db, scope: scope, labels: ["dog", "park"])
            let rows = try Row.fetchAll(db, sql:
                "SELECT label, source, confidence FROM tags WHERE file_id='f1' AND parent_dir='/A' ORDER BY label")
            XCTAssertEqual(rows.map { $0["label"] as String }, ["dog", "park"])
            XCTAssertEqual(rows.map { $0["source"] as String }, ["manual", "manual"])
            XCTAssertTrue(rows.allSatisfy { ($0["confidence"] as Double?) == nil })
        }
    }

    func testApplyKeywordsTwiceIsIdempotent() throws {
        let q = try migrated()
        try q.write { db in
            try seed(db)
            let scope = try MetadataImportApply.scope(db: db, absPath: "/A/x.jpg")!
            try MetadataImportApply.applyKeywords(db: db, scope: scope, labels: ["dog"])
            try MetadataImportApply.applyKeywords(db: db, scope: scope, labels: ["dog"])
            let count = try Int.fetchOne(db, sql:
                "SELECT COUNT(*) FROM tags WHERE file_id='f1' AND parent_dir='/A' AND label='dog'")
            XCTAssertEqual(count, 1)
        }
    }

    func testHasRatingSeesRatingGlyphRunsOnly() throws {
        let q = try migrated()
        try q.write { db in
            try seed(db)
            let scope = try MetadataImportApply.scope(db: db, absPath: "/A/x.jpg")!
            XCTAssertFalse(try MetadataImportApply.hasRating(db: db, scope: scope))
            try db.execute(sql: """
                INSERT INTO tags (id, file_id, parent_dir, label, source)
                VALUES ('t2','f1','/A','★★★','manual')
                """)
            XCTAssertTrue(try MetadataImportApply.hasRating(db: db, scope: scope))
        }
    }

    func testHasRatingIgnoresOrdinaryTags() throws {
        let q = try migrated()
        try q.write { db in
            try seed(db)
            try db.execute(sql: """
                INSERT INTO tags (id, file_id, parent_dir, label, source)
                VALUES ('t3','f1','/A','starfish','manual')
                """)
            let scope = try MetadataImportApply.scope(db: db, absPath: "/A/x.jpg")!
            XCTAssertFalse(try MetadataImportApply.hasRating(db: db, scope: scope))
        }
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd "/Users/carlostarrats/Documents/Projects/Muse/Muse App" && xcodebuild -project Muse/Muse.xcodeproj -scheme Muse test -only-testing:MuseTests/MetadataImportApplyTests 2>&1 | tail -20`
Expected: BUILD FAILED — "cannot find 'MetadataImportApply' in scope".

- [ ] **Step 3: Write the implementation**

```swift
//
//  MetadataImportApply.swift
//  Muse
//
//  The DB half of the keywords & ratings import: pure-SQL statics testable
//  on an in-memory queue (pattern: Indexer.inheritVisionTags). Insert-or-
//  promote mirrors TagStore.addManualTag exactly — manual tier so the
//  auto-tagger can never undo the imported tags (Q32), scoped per
//  (file_id, parent_dir) like every tag write.
//

import Foundation
import GRDB

enum MetadataImportApply {

    struct Scope {
        let fileID: String
        let dir: String
    }

    /// The tag scope for an ALIVE indexed path — nil when the file isn't in
    /// the index (the import counts it skipped rather than writing tags that
    /// would land nowhere).
    static func scope(db: GRDB.Database, absPath: String) throws -> Scope? {
        guard let path = try PathRow
                .filter(PathRow.Columns.absolute_path == absPath)
                .filter(PathRow.Columns.is_alive == 1)
                .fetchOne(db),
              let fileID = path.file_id else { return nil }
        return Scope(fileID: fileID, dir: TagScope.parentDir(ofPath: absPath))
    }

    /// Insert each label as a MANUAL tag, or promote an existing row (vision
    /// or manual) to manual — the same branch TagStore.addManualTag uses, so
    /// re-importing (or importing over hand-typed tags) is a no-op.
    static func applyKeywords(db: GRDB.Database, scope: Scope, labels: [String]) throws {
        for label in labels {
            if let existing = try TagRow
                .filter(TagRow.Columns.file_id == scope.fileID)
                .filter(TagRow.Columns.parent_dir == scope.dir)
                .filter(TagRow.Columns.label == label)
                .fetchOne(db) {
                var updated = existing
                updated.source = "manual"
                updated.confidence = nil
                try updated.update(db)
            } else {
                var row = TagRow(
                    id: UUID().uuidString,
                    file_id: scope.fileID,
                    parent_dir: scope.dir,
                    label: label,
                    source: "manual",
                    confidence: nil,
                    model_version: nil
                )
                try row.insert(db)
            }
        }
    }

    /// Whether the file already carries a Muse star rating in this folder
    /// scope — the import never overwrites one (rating fills gaps only).
    static func hasRating(db: GRDB.Database, scope: Scope) throws -> Bool {
        let labels = try String.fetchAll(db, sql:
            "SELECT label FROM tags WHERE file_id = ? AND parent_dir = ?",
            arguments: [scope.fileID, scope.dir])
        return labels.contains(where: StarRating.isRating)
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: same command as Step 2.
Expected: `Test Suite 'MetadataImportApplyTests' passed` (6 tests).

- [ ] **Step 5: Commit**

```bash
git add Muse/Muse/Import/MetadataImportApply.swift Muse/MuseTests/MetadataImportApplyTests.swift
git commit -m "feat: GRDB apply statics for metadata import (manual tags + rating gap check)"
```

---

### Task 4: Orchestrator model + progress sheet + menu wiring

**Files:**
- Create: `Muse/Muse/Import/MetadataImportModel.swift`
- Create: `Muse/Muse/Import/MetadataImportSheet.swift`
- Create: `Muse/Muse/Models/AppState+Import.swift`
- Modify: `Muse/Muse/Models/AppState.swift:1247` — change `private nonisolated static func enumerateRecursive` to `nonisolated static func enumerateRecursive` (drop `private`; the import model reuses it; add a comment noting the import is a second caller)
- Modify: `Muse/Muse/MuseApp.swift` — menu item in the `CommandGroup(after: .newItem)` (after "Find Duplicates in Folder")
- Modify: `Muse/Muse/ContentView.swift` — `.sheet(item:)` alongside the existing sheets at ~line 274

**Interfaces:**
- Consumes: Tasks 1–3 (`MetadataImportRules`, `MetadataKeywordReader.read`, `MetadataImportApply.scope/applyKeywords/hasRating`), plus existing `AppState.enumerateRecursive(at:showHidden:)`, `Indexer.shared.indexBatch(_:priority:)`, `Database.shared.dbQueue`, `TagStore.shared.setRating(_:forURLs:)`, `AnalyzePipeline.shared.exportSidecarsAfterTagEdit(for:)`, `BookmarkStore.addRoot(at:)` (via `appState.bookmarks`), `appState.tagsVersion`.
- Produces: `struct MetadataImportRequest: Identifiable { let id: UUID; let folder: URL }`, `AppState.metadataImportRequest: MetadataImportRequest?` (`@Published`), `AppState.importKeywordsAndRatings()`, `MetadataImportModel` (`Phase` enum: `.running(done:total:)` / `.done(imported:none:skipped:)`), `MetadataImportSheet`.

No new unit tests — this task is thin glue over the three tested units, consistent with the codebase's views-untested convention. The build + existing suite must stay green.

- [ ] **Step 1: `MetadataImportModel`**

```swift
//
//  MetadataImportModel.swift
//  Muse
//
//  Orchestrates one run of File > Import Keywords & Ratings…: enumerate the
//  folder (always recursive — the user picked THIS folder, the grid's
//  subfolder toggle is irrelevant here), index it so tags have (file_id,
//  parent_dir) rows to land on, then per file read metadata OFF-MAIN and
//  apply through the tested seams. Idempotent: tags insert-or-promote,
//  ratings fill gaps only. Cancel-safe: work already applied stays (a
//  re-run finishes the rest and changes nothing already done).
//

import Foundation
import SwiftUI

@MainActor
final class MetadataImportModel: ObservableObject {

    enum Phase: Equatable {
        case running(done: Int, total: Int)
        case done(imported: Int, none: Int, skipped: Int)
    }

    @Published private(set) var phase: Phase = .running(done: 0, total: 0)

    private var task: Task<Void, Never>?

    func start(folder: URL, appState: AppState) {
        guard task == nil else { return }
        task = Task { [weak self, weak appState] in
            guard let self else { return }

            // 1. Enumerate (off-main), image kinds only — the kinds that
            //    carry IPTC/XMP. Always recursive; hidden files excluded.
            let files = await Task.detached(priority: .userInitiated) {
                AppState.enumerateRecursive(at: folder, showHidden: false)
                    .filter { $0.kind == .image || $0.kind == .raw || $0.kind == .psd }
            }.value
            if Task.isCancelled { return }
            self.phase = .running(done: 0, total: files.count)

            // 2. Index first: tag writes silently no-op on unknown paths.
            //    indexBatch skips dataless placeholders itself.
            let pairs = files.map { ($0.url, $0.kind) }
            _ = await Indexer.shared.indexBatch(pairs, priority: .high)
            if Task.isCancelled { return }

            guard let queue = Database.shared.dbQueue else {
                self.phase = .done(imported: 0, none: 0, skipped: files.count)
                return
            }

            var imported = 0, none = 0, skipped = 0
            var touched: [URL] = []

            for (index, file) in files.enumerated() {
                if Task.isCancelled { break }
                self.phase = .running(done: index, total: files.count)
                let url = file.url

                let extracted: MetadataKeywordReader.Extracted
                do {
                    extracted = try await Task.detached(priority: .userInitiated) {
                        try MetadataKeywordReader.read(url: url)
                    }.value
                } catch {
                    skipped += 1
                    continue
                }
                if extracted.isEmpty { none += 1; continue }

                let absPath = url.standardizedFileURL.path
                do {
                    var rowMissing = false
                    var ratingToSet: Int? = nil
                    try await queue.write { db in
                        guard let scope = try MetadataImportApply.scope(db: db, absPath: absPath) else {
                            rowMissing = true
                            return
                        }
                        if !extracted.keywords.isEmpty {
                            try MetadataImportApply.applyKeywords(
                                db: db, scope: scope, labels: extracted.keywords)
                        }
                        let has = try MetadataImportApply.hasRating(db: db, scope: scope)
                        ratingToSet = MetadataImportRules.ratingToApply(
                            imported: extracted.rating, existingHasRating: has)
                    }
                    if rowMissing { skipped += 1; continue }
                    if let stars = ratingToSet {
                        // The one rating write seam — mutual exclusion,
                        // manual tier, sidecar export all come with it.
                        await TagStore.shared.setRating(stars, forURLs: [url])
                    }
                    imported += 1
                    touched.append(url)
                } catch {
                    skipped += 1
                }
            }

            // One sidecar re-export for everything touched (iCloud-zone
            // no-op otherwise) + the standard post-tag-edit UI refresh.
            if !touched.isEmpty {
                AnalyzePipeline.shared.exportSidecarsAfterTagEdit(for: touched)
                appState?.tagsVersion += 1
            }
            self.phase = .done(imported: imported, none: none, skipped: skipped)
        }
    }

    func cancel() {
        task?.cancel()
    }
}
```

- [ ] **Step 2: `MetadataImportSheet`**

```swift
//
//  MetadataImportSheet.swift
//  Muse
//
//  Progress + summary for File > Import Keywords & Ratings…. Content-sized
//  (width-only frame — never a fixed height, per the sheet rule). Dismissal
//  cancels the run (like the Drive share sheet): work already applied stays
//  and a re-run is idempotent.
//

import SwiftUI

struct MetadataImportSheet: View {
    let request: MetadataImportRequest
    @EnvironmentObject private var appState: AppState
    @StateObject private var model = MetadataImportModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Import Keywords & Ratings")
                .font(.title3.weight(.semibold))
            Text(request.folder.lastPathComponent)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)

            switch model.phase {
            case .running(let done, let total):
                ProgressView(value: Double(done), total: Double(max(total, 1)))
                Text("Reading \(done) of \(total)…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                HStack {
                    Spacer()
                    Button("Cancel") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                }
            case .done(let imported, let none, let skipped):
                Text("Imported keywords or ratings for \(imported) files.")
                    .font(.callout)
                if none > 0 {
                    Text("\(none) had none to import.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                if skipped > 0 {
                    Text("\(skipped) skipped (unreadable or not downloaded).")
                        .font(.callout).foregroundStyle(.secondary)
                }
                HStack {
                    Spacer()
                    Button("Done") { dismiss() }
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(24)
        .frame(width: 360)
        .onAppear { model.start(folder: request.folder, appState: appState) }
        .onDisappear { model.cancel() }
    }

    private func dismiss() {
        appState.metadataImportRequest = nil
    }
}
```

- [ ] **Step 3: `AppState+Import.swift` (request type, published var, panel)**

```swift
//
//  AppState+Import.swift
//  Muse
//
//  File > Import Keywords & Ratings… — the read-only metadata import
//  (Lightroom / Bridge / Capture One keywords + stars → Muse manual tags +
//  ratings). Spec: docs/superpowers/specs/2026-07-07-metadata-keywords-
//  import-design.md. The Eagle-library import was designed but deferred:
//  docs/future-features/eagle-library-import.md.
//

import AppKit
import Foundation

/// One requested import run; Identifiable so ContentView presents it via
/// .sheet(item:) and a second request is a fresh sheet.
struct MetadataImportRequest: Identifiable, Equatable {
    let id = UUID()
    let folder: URL
}

extension AppState {

    /// Folder-only picker → import. A folder outside every root is added as
    /// a sidebar root first (the standard addRoot flow — it activates before
    /// appending) so the imported tags have rows to land on and the user can
    /// see the result. A folder already under a root is used as-is
    /// (containment via the trailing-slash prefix rule).
    func importKeywordsAndRatings() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = String(localized: "Select a folder of images — keywords and ratings written by Lightroom, Bridge, or Capture One will be imported as Muse tags and ratings.")
        panel.prompt = String(localized: "Import")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let std = url.standardizedFileURL
        let covered = rootNodes.contains {
            let root = $0.url.standardizedFileURL.path
            return std.path == root || std.path.hasPrefix(root + "/")
        }
        if !covered {
            _ = bookmarks.addRoot(at: std)
        }
        metadataImportRequest = MetadataImportRequest(folder: std)
    }
}
```

In `AppState.swift`, next to the other sheet flags (`driveSharesShown` etc. — search for `@Published var driveSharesShown`), add:

```swift
    /// Non-nil while the Import Keywords & Ratings sheet is up (File menu).
    @Published var metadataImportRequest: MetadataImportRequest?
```

And at `AppState.swift:1247`, make the enumerator reusable:

```swift
    /// Shared by the intent paths (analyzableURLs) and the metadata import.
    nonisolated static func enumerateRecursive(at url: URL, showHidden: Bool) -> [FileNode] {
```

(only the `private` keyword is removed; body untouched).

- [ ] **Step 4: Menu item in `MuseApp.swift`**

Inside `CommandGroup(after: .newItem)`, directly after the "Find Duplicates in Folder" button (and before the `Divider()` that precedes "Open"):

```swift
                Button("Import Keywords & Ratings…") {
                    appState.importKeywordsAndRatings()
                }
```

(Always enabled — it operates on a picked folder, not the current view.)

- [ ] **Step 5: Sheet presentation in `ContentView.swift`**

Alongside the existing `.sheet` modifiers (~line 274):

```swift
        .sheet(item: $appState.metadataImportRequest) { request in
            MetadataImportSheet(request: request)
                .environmentObject(appState)
        }
```

(Check how the neighboring sheets inject `appState` — if it's already in the environment at that point, drop the explicit `.environmentObject`.)

- [ ] **Step 6: Build + run the existing suite**

Run: `cd "/Users/carlostarrats/Documents/Projects/Muse/Muse App" && xcodebuild -project Muse/Muse.xcodeproj -scheme Muse build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED.
Run: `xcodebuild -project Muse/Muse.xcodeproj -scheme Muse test -only-testing:MuseTests 2>&1 | tail -5`
Expected: TEST SUCCEEDED (no regressions; SourceKit module errors during editing are noise — trust the build).

- [ ] **Step 7: Commit**

```bash
git add Muse/Muse/Import/ Muse/Muse/Models/AppState+Import.swift Muse/Muse/Models/AppState.swift Muse/Muse/MuseApp.swift Muse/Muse/ContentView.swift
git commit -m "feat: File > Import Keywords & Ratings — panel, progress sheet, orchestration"
```

---

### Task 5: Info modal line

**Files:**
- Modify: `Muse/Muse/Views/InfoSheet.swift` — the `section("Tags", …)` body (~line 88)

**Interfaces:** none (copy-only). The Privacy section was checked 2026-07-07 and ALREADY covers the Drive share + `drive.file` scope — do NOT touch it.

- [ ] **Step 1: Extend the Tags section body**

`section` takes `LocalizedStringKey`, so the edited literal auto-extracts (the changed body becomes a NEW localization key — Task 6 fills its French value). Append to the existing "Tags" body text:

```
 Coming from Lightroom, Bridge, or Capture One? File > Import \
Keywords & Ratings reads the keywords and stars already written \
into your files and turns them into Muse tags and ratings — files \
are only read, never modified, and a rating you set in Muse is \
never overwritten.
```

(One space before "Coming" to continue the paragraph; keep the `\` line-continuation style of the surrounding literals.)

- [ ] **Step 2: Build**

Run: `cd "/Users/carlostarrats/Documents/Projects/Muse/Muse App" && xcodebuild -project Muse/Muse.xcodeproj -scheme Muse build 2>&1 | tail -3`
Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Commit**

```bash
git add Muse/Muse/Views/InfoSheet.swift
git commit -m "docs(ui): info modal mentions the keywords & ratings import"
```

---

### Task 6: Localization (French)

**Files:**
- Modify: `Muse/Muse/Localizable.xcstrings` (via the export round-trip — a plain build does NOT write keys back)

**Interfaces:** none.

- [ ] **Step 1: Export to write-back the new keys**

Run: `cd "/Users/carlostarrats/Documents/Projects/Muse/Muse App" && xcodebuild -exportLocalizations -project Muse/Muse.xcodeproj -localizationPath /tmp/muse-loc -exportLanguage fr 2>&1 | tail -3`
Expected: succeeds; `Localizable.xcstrings` now contains the new keys with empty `fr` values.

- [ ] **Step 2: Fill the French values**

New keys and their translations (edit `Localizable.xcstrings` directly; interpolated keys keep their `%lld`/`%@` placeholders verbatim):

| English key | French |
|---|---|
| `Import Keywords & Ratings…` | `Importer les mots-clés et notes…` |
| `Select a folder of images — keywords and ratings written by Lightroom, Bridge, or Capture One will be imported as Muse tags and ratings.` | `Sélectionnez un dossier d'images — les mots-clés et les notes écrits par Lightroom, Bridge ou Capture One seront importés comme tags et notes Muse.` |
| `Import` | `Importer` |
| `Import Keywords & Ratings` | `Importer les mots-clés et notes` |
| `Reading %lld of %lld…` | `Lecture de %lld sur %lld…` |
| `Imported keywords or ratings for %lld files.` | `Mots-clés ou notes importés pour %lld fichiers.` |
| `%lld had none to import.` | `%lld n'en avaient aucun à importer.` |
| `%lld skipped (unreadable or not downloaded).` | `%lld ignorés (illisibles ou non téléchargés).` |
| `Cancel` / `Done` | already in the catalog — verify, don't duplicate |
| the edited "Tags" info-section body (new key) | re-translate the whole body: existing French text + ` Vous venez de Lightroom, Bridge ou Capture One ? Fichier > Importer les mots-clés et notes lit les mots-clés et les étoiles déjà écrits dans vos fichiers et les convertit en tags et notes Muse — les fichiers sont uniquement lus, jamais modifiés, et une note définie dans Muse n'est jamais écrasée.` |

Also delete the now-orphaned OLD "Tags" body key if the export marks it stale (it's a genuine orphan — the literal changed — unlike the `NSLocalizedString(variable)` keys, which must never be pruned).

- [ ] **Step 3: Verify zero untranslated**

Run the export again (same command). Expected: reports 0 untranslated for fr.
Then: `xcodebuild -project Muse/Muse.xcodeproj -scheme Muse build 2>&1 | tail -3` → BUILD SUCCEEDED.

- [ ] **Step 4: Commit**

```bash
git add Muse/Muse/Localizable.xcstrings
git commit -m "l10n: French strings for the keywords & ratings import"
```

---

### Task 7: Full suite + live verification + docs

**Files:**
- Modify: `CLAUDE.md` (phase table row + a one-line durable note if any gotcha emerged), `docs/session-log.md` (dated entry), `docs/architecture-map.md` (the new `Import/` directory)

- [ ] **Step 1: Full test suite**

Run: `cd "/Users/carlostarrats/Documents/Projects/Muse/Muse App" && xcodebuild -project Muse/Muse.xcodeproj -scheme Muse test 2>&1 | tail -5`
Expected: TEST SUCCEEDED.

- [ ] **Step 2: Live verification (required — green tests alone don't prove a filesystem/sandbox feature)**

Build and launch the real app; prepare a scratch folder with (a) a JPEG tagged in an external tool or a fixture JPEG written by the test helper, (b) a file with an `.xmp` sidecar, (c) an untagged file. Run File > Import Keywords & Ratings… on it and confirm: tags appear as chips, the star shows on the tile, the untagged file counts under "had none", re-running reports the same result with no duplicates, and a file rated in Muse beforehand keeps its rating. Hand the build to the owner for their own pass (per the working loop) — do not claim done from tests alone.

- [ ] **Step 3: Docs**

- `CLAUDE.md`: add Polish-table row (`Polish 18.x / next-125 — Import Keywords & Ratings (LR/Bridge/C1, read-only, idempotent)`), and note the Eagle deferral pointer already exists in `docs/possible-updates.md`.
- `docs/session-log.md`: dated entry — what shipped, the sidecar>XMP>IPTC priority, the fills-gaps-only rating rule, Eagle deferred.
- `docs/architecture-map.md`: add `Import/` (four files) under the directory index.

- [ ] **Step 4: Commit**

```bash
git add CLAUDE.md docs/session-log.md docs/architecture-map.md
git commit -m "docs: record keywords & ratings import (feat/next-125)"
```

---

## Self-review notes (already applied)

- Spec coverage: menu+panel (T4), root-add (T4), sidecar/XMP/IPTC priority (T2), dataless guard (T2), index-first (T4), manual-tier batch write (T3), rating-fills-gaps (T1+T4), idempotency (T3 test), progress/cancel/summary (T4), info modal (T5), localization (T6), fixtures/tests (T1–T3), live verify (T7). The spec's "TagStore.addManualTags wrapper" became `MetadataImportApply` statics + one `queue.write` in the model — same one-write-per-file semantics, more testable (pattern: `Indexer.inheritVisionTags`); noted as an approved deviation.
- The InfoSheet privacy fix in the spec is ALREADY in the shipped code (verified 2026-07-07) — Task 5 only adds the import line.
- Type consistency: `Scope`, `Extracted`, `Phase`, `MetadataImportRequest` names match across tasks.
