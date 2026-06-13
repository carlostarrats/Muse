# Screenshot Intent Collections Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Automatically classify screenshots by intent (recipe, shopping, …) into named collections, on-device, and color the Galaxy view's nodes by that intent.

**Architecture:** A new on-device Foundation Models classifier reads each screenshot's already-extracted OCR text + vision labels and assigns one of 10 fixed intent buckets (or none). Typed screenshots are grouped into stable "intent collections" by `CollectionsEngine` and excluded from the existing emergent clustering (clean two-track). The Galaxy view colors nodes by intent. All gated to Apple-Intelligence Macs with graceful no-op fallback, mirroring the existing FM-gated collection namer. No network, no new UI.

**Tech Stack:** Swift, SwiftUI, GRDB (SQLite), Vision, FoundationModels, SceneKit, XCTest.

**Design spec:** `docs/superpowers/specs/2026-06-13-screenshot-aware-features-design.md`

---

## Before you start

- **Build:** `xcodebuild -scheme Muse -configuration Debug -destination 'platform=macOS' build`
- **Run a single test class:** `xcodebuild test -scheme Muse -destination 'platform=macOS' -only-testing:MuseTests/<ClassName>`
- Working dir for `xcodebuild` is the project dir: `/Users/carlostarrats/Documents/Projects/Muse/Muse` (where `Muse.xcodeproj` lives).
- **New files must be in the right Xcode target.** Source files → the `Muse` target; test files → the `MuseTests` target. If the project uses Xcode 16 synchronized folder groups, files added under `Muse/Muse/...` and `Muse/MuseTests/...` are picked up automatically. If a build can't find a new type, open `Muse.xcodeproj` in Xcode and confirm the file's Target Membership. Verify with a build after each file-creating task.
- **SourceKit cross-file "cannot find type" errors are noise during edits** (per CLAUDE.md). Trust `xcodebuild`.
- **Commits:** every commit message must end with the Co-Authored-By trailer from CLAUDE.md:
  ```
  Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
  ```
- Branch is already `feat/screenshot-intent-collections`.

## File structure

**Create:**
- `Muse/Muse/Intelligence/Core/IntentBucket.swift` — the 10-bucket enum: keys, display names, stable collection ids, raw→bucket validation, galaxy hex color. Pure Foundation. One responsibility: the bucket vocabulary.
- `Muse/Muse/Intelligence/Core/IntentClassifier.swift` — the FM-gated classifier protocol, FM implementation, no-op fallback, factory, and the pure input helpers (`IntentInput`).
- `Muse/Muse/Intelligence/Collections/IntentCollections.swift` — pure logic deciding which buckets qualify as collections (≥ threshold alive members).
- `Muse/Muse/Intelligence/IntentBackfill.swift` — one-time launch pass that classifies pre-existing screenshots without re-running Vision.
- `Muse/MuseTests/IntentBucketTests.swift`
- `Muse/MuseTests/IntentInputTests.swift`
- `Muse/MuseTests/IntentCollectionsTests.swift`

**Modify:**
- `Muse/Muse/Database/Records.swift` — add `intent`, `intent_model_version` to `FileRow`.
- `Muse/Muse/Database/Database.swift` — migration `v5_intent`.
- `Muse/Muse/Intelligence/Core/IntelligenceRegistry.swift` — expose `intentClassifier` + `intentModelVersion`.
- `Muse/Muse/Intelligence/AnalyzePipeline.swift` — classify screenshots in `analyzeOne`, write `intent`.
- `Muse/Muse/Intelligence/Collections/CollectionsEngine.swift` — intent pass + exclude typed screenshots from emergent input.
- `Muse/Muse/MuseApp.swift` — call `IntentBackfill` on launch.
- `Muse/Muse/Views/Spatial/GalaxyModel.swift` — carry `intent` on `GalaxyNode`, fetch it.
- `Muse/Muse/Views/Spatial/GalaxyView.swift` — colored backing plane per node by intent.

---

## Task 1: IntentBucket vocabulary

**Files:**
- Create: `Muse/Muse/Intelligence/Core/IntentBucket.swift`
- Test: `Muse/MuseTests/IntentBucketTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
// Muse/MuseTests/IntentBucketTests.swift
import XCTest
@testable import Muse

final class IntentBucketTests: XCTestCase {
    func testAllTenBucketsExist() {
        XCTAssertEqual(IntentBucket.allCases.count, 10)
    }

    func testStableCollectionID() {
        XCTAssertEqual(IntentBucket.recipe.collectionID, "intent:recipe")
        XCTAssertEqual(IntentBucket.receipt.collectionID, "intent:receipt")
    }

    func testDisplayNames() {
        XCTAssertEqual(IntentBucket.recipe.displayName, "Recipes")
        XCTAssertEqual(IntentBucket.code.displayName, "Code")
        XCTAssertEqual(IntentBucket.places.displayName, "Places")
    }

    func testFromValidKey() {
        XCTAssertEqual(IntentBucket.from("recipe"), .recipe)
    }

    func testFromIsCaseAndPunctuationTolerant() {
        XCTAssertEqual(IntentBucket.from("  Recipe."), .recipe)
        XCTAssertEqual(IntentBucket.from("CODE"), .code)
    }

    func testFromNoneReturnsNil() {
        XCTAssertNil(IntentBucket.from("none"))
        XCTAssertNil(IntentBucket.from(""))
        XCTAssertNil(IntentBucket.from("banana"))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -scheme Muse -destination 'platform=macOS' -only-testing:MuseTests/IntentBucketTests`
Expected: FAIL/compile error — "cannot find 'IntentBucket' in scope".

- [ ] **Step 3: Write minimal implementation**

```swift
// Muse/Muse/Intelligence/Core/IntentBucket.swift
import Foundation

/// The fixed vocabulary of screenshot intent types. Pure (no AppKit).
enum IntentBucket: String, CaseIterable {
    case recipe, shopping, places, receipt, quote
    case article, conversation, event, design, code

    /// Stable collection id so reclustering updates the same collection.
    var collectionID: String { "intent:\(rawValue)" }

    var displayName: String {
        switch self {
        case .recipe:       return "Recipes"
        case .shopping:     return "Shopping"
        case .places:       return "Places"
        case .receipt:      return "Receipts"
        case .quote:        return "Quotes"
        case .article:      return "Articles"
        case .conversation: return "Conversations"
        case .event:        return "Events"
        case .design:       return "Design"
        case .code:         return "Code"
        }
    }

    /// Distinct hue per bucket for the Galaxy "taste map" trial.
    var galaxyHex: String {
        switch self {
        case .recipe:       return "#5BA85B"
        case .shopping:     return "#5588CC"
        case .places:       return "#CC8855"
        case .receipt:      return "#999999"
        case .quote:        return "#B07AD0"
        case .article:      return "#C0A14E"
        case .conversation: return "#4EB0A8"
        case .event:        return "#D06A8C"
        case .design:       return "#7A6AD0"
        case .code:         return "#6A8FA8"
        }
    }

    /// Comma-separated keys for the classifier prompt.
    static var promptKeys: String { allCases.map(\.rawValue).joined(separator: ", ") }

    /// Validate a raw model response. Off-list / "none" / empty → nil.
    static func from(_ raw: String) -> IntentBucket? {
        let key = raw.lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        return IntentBucket(rawValue: key)
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild test -scheme Muse -destination 'platform=macOS' -only-testing:MuseTests/IntentBucketTests`
Expected: PASS (6 tests).

- [ ] **Step 5: Commit**

```bash
git add Muse/Muse/Intelligence/Core/IntentBucket.swift Muse/MuseTests/IntentBucketTests.swift
git commit -m "feat: add IntentBucket vocabulary for screenshot intent typing"
```

---

## Task 2: Database column + migration

**Files:**
- Modify: `Muse/Muse/Database/Records.swift:13-40`
- Modify: `Muse/Muse/Database/Database.swift:208-216`

- [ ] **Step 1: Add the columns to FileRow**

In `Muse/Muse/Database/Records.swift`, inside `struct FileRow`, immediately after the `analyzed_hash` property (line 32), add:

```swift
    /// One of IntentBucket.rawValue for a classified screenshot, else nil.
    var intent: String?
    /// Classifier model version that last set `intent` (drives one-time backfill).
    var intent_model_version: String?
```

- [ ] **Step 2: Register the migration**

In `Muse/Muse/Database/Database.swift`, immediately after the `v4_auto_analyze` migration block (after line 214, before `return migrator`), add:

```swift
        migrator.registerMigration("v5_intent") { db in
            // Screenshot intent typing: a per-file bucket + the classifier
            // version that produced it. Both nullable; populated lazily by the
            // analyze pipeline and a one-time backfill.
            try db.alter(table: "files") { t in
                t.add(column: "intent", .text)
                t.add(column: "intent_model_version", .text)
            }
        }
```

- [ ] **Step 3: Build to verify the schema + Codable still compile**

Run: `xcodebuild -scheme Muse -configuration Debug -destination 'platform=macOS' build`
Expected: BUILD SUCCEEDED. (GRDB's Codable conformance picks up the new optional columns automatically.)

- [ ] **Step 4: Commit**

```bash
git add Muse/Muse/Database/Records.swift Muse/Muse/Database/Database.swift
git commit -m "feat: add intent + intent_model_version columns (migration v5_intent)"
```

---

## Task 3: Classifier input helpers (pure)

**Files:**
- Create: `Muse/Muse/Intelligence/Core/IntentClassifier.swift` (helpers first; FM impl in Task 4)
- Test: `Muse/MuseTests/IntentInputTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
// Muse/MuseTests/IntentInputTests.swift
import XCTest
@testable import Muse

final class IntentInputTests: XCTestCase {
    func testIsScreenshotTrueWhenVisionKindScreenshotTagPresent() {
        let tags = [
            IntelTag(label: "computer screen", confidence: 0.7, source: "vision"),
            IntelTag(label: "screenshot", confidence: nil, source: "vision-kind"),
        ]
        XCTAssertTrue(IntentInput.isScreenshot(tags: tags))
    }

    func testIsScreenshotFalseForOtherKinds() {
        let tags = [
            IntelTag(label: "dog", confidence: 0.9, source: "vision"),
            IntelTag(label: "photo", confidence: nil, source: "vision-kind"),
        ]
        XCTAssertFalse(IntentInput.isScreenshot(tags: tags))
    }

    func testVisionLabelsKeepsOnlyVisionSource() {
        let tags = [
            IntelTag(label: "computer screen", confidence: 0.7, source: "vision"),
            IntelTag(label: "blue", confidence: nil, source: "vision-color"),
            IntelTag(label: "screenshot", confidence: nil, source: "vision-kind"),
        ]
        XCTAssertEqual(IntentInput.visionLabels(tags: tags), ["computer screen"])
    }

    func testOcrSnippetTruncates() {
        let long = String(repeating: "a", count: 1000)
        XCTAssertEqual(IntentInput.ocrSnippet(long).count, 600)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -scheme Muse -destination 'platform=macOS' -only-testing:MuseTests/IntentInputTests`
Expected: FAIL — "cannot find 'IntentInput' in scope".

- [ ] **Step 3: Write minimal implementation**

```swift
// Muse/Muse/Intelligence/Core/IntentClassifier.swift
import Foundation

#if canImport(FoundationModels)
import FoundationModels
#endif

/// Pure helpers turning a TaggerOutput's signals into classifier inputs.
enum IntentInput {
    /// True when Vision's deterministic StyleKind tagged this image a screenshot.
    static func isScreenshot(tags: [IntelTag]) -> Bool {
        tags.contains { $0.source == "vision-kind" && $0.label == "screenshot" }
    }

    /// The Vision classification labels (excludes color/kind tags).
    static func visionLabels(tags: [IntelTag]) -> [String] {
        tags.filter { $0.source == "vision" }.map(\.label)
    }

    /// OCR text capped — recipes/receipts/code declare themselves early.
    static func ocrSnippet(_ ocr: String, max: Int = 600) -> String {
        String(ocr.prefix(max))
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild test -scheme Muse -destination 'platform=macOS' -only-testing:MuseTests/IntentInputTests`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add Muse/Muse/Intelligence/Core/IntentClassifier.swift Muse/MuseTests/IntentInputTests.swift
git commit -m "feat: add pure IntentInput helpers for the intent classifier"
```

---

## Task 4: The FM classifier + factory + registry wiring

**Files:**
- Modify: `Muse/Muse/Intelligence/Core/IntentClassifier.swift` (append)
- Modify: `Muse/Muse/Intelligence/Core/IntelligenceRegistry.swift`

There is no unit test here — Foundation Models can't run in the test harness, and the testable part (raw→bucket validation) is already covered by `IntentBucket.from` in Task 1. Verification is a build.

- [ ] **Step 1: Append the classifier protocol, FM impl, no-op fallback, and factory**

Append to `Muse/Muse/Intelligence/Core/IntentClassifier.swift`:

```swift
/// Classifies a screenshot into an IntentBucket, or nil ("none" / unsure).
protocol IntentClassifying: Sendable {
    func classify(ocrText: String, visionLabels: [String]) async -> IntentBucket?
}

/// Fallback on non-Apple-Intelligence Macs: never classifies.
struct NoIntentClassifier: IntentClassifying {
    func classify(ocrText: String, visionLabels: [String]) async -> IntentBucket? { nil }
}

enum IntentClassifierFactory {
    /// FM-backed classifier on capable Macs, else the no-op fallback.
    static func makeBest() -> IntentClassifying {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *),
           SystemLanguageModel.default.availability == .available {
            return FoundationModelIntentClassifier()
        }
        #endif
        return NoIntentClassifier()
    }

    /// Model version recorded on each classified file.
    static var modelVersion: String {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *),
           SystemLanguageModel.default.availability == .available {
            return "intent-fm-v1"
        }
        #endif
        return "intent-none-v1"
    }
}

#if canImport(FoundationModels)
@available(macOS 26.0, *)
struct FoundationModelIntentClassifier: IntentClassifying {
    private static let instructions = """
    You classify a single screenshot into exactly one category from a fixed list, \
    using its extracted text and image labels. Prefer "none" whenever the screenshot \
    does not clearly belong to a category — a wrong label is worse than none. \
    Reply with ONLY the lowercase category key and nothing else.
    """

    func classify(ocrText: String, visionLabels: [String]) async -> IntentBucket? {
        do {
            let session = LanguageModelSession(instructions: Self.instructions)
            let prompt = """
            Categories: \(IntentBucket.promptKeys), none.
            Image labels: \(visionLabels.prefix(8).joined(separator: ", ")).
            Extracted text: \(ocrText)

            Reply with ONLY one category key, or "none".
            """
            let response = try await session.respond(to: prompt)
            return IntentBucket.from(response.content)
        } catch {
            return nil
        }
    }
}
#endif
```

- [ ] **Step 2: Wire the classifier into the registry**

In `Muse/Muse/Intelligence/Core/IntelligenceRegistry.swift`, add a property + init assignment:

```swift
final class IntelligenceRegistry {
    static let shared = IntelligenceRegistry()
    let tagger: Tagger
    let embedder: Embedder?
    let clusterer: Clusterer
    let namer: CollectionNamer
    let intentClassifier: IntentClassifying
    let intentModelVersion: String

    private init() {
        tagger = VisionTagger()
        embedder = SentenceEmbedder.makeIfAvailable()
        clusterer = HybridClusterer()
        namer = TagFallbackNamer.makeBest()
        intentClassifier = IntentClassifierFactory.makeBest()
        intentModelVersion = IntentClassifierFactory.modelVersion
    }
}
```

- [ ] **Step 3: Build to verify**

Run: `xcodebuild -scheme Muse -configuration Debug -destination 'platform=macOS' build`
Expected: BUILD SUCCEEDED.

- [ ] **Step 4: Commit**

```bash
git add Muse/Muse/Intelligence/Core/IntentClassifier.swift Muse/Muse/Intelligence/Core/IntelligenceRegistry.swift
git commit -m "feat: add FM-gated IntentClassifier and register it"
```

---

## Task 5: Classify screenshots in the analyze pipeline

**Files:**
- Modify: `Muse/Muse/Intelligence/AnalyzePipeline.swift:101-134`

Integration glue (DB + FM); verified by build, then by running the app in Task 9's final check. No unit test (the testable pieces are already covered).

- [ ] **Step 1: Compute the intent before the write transaction**

In `analyzeOne`, after the line `let taggerVersion = registry.tagger.modelVersion` (line 115) and before the `do { try await queue.write ... }` block, add:

```swift
        // Screenshot intent typing (Option A: screenshots only). On non-AI
        // Macs the classifier is a no-op and intentKey stays nil.
        var intentKey: String? = nil
        var intentVersion: String? = nil
        if IntentInput.isScreenshot(tags: out.tags) {
            intentVersion = registry.intentModelVersion
            let bucket = await registry.intentClassifier.classify(
                ocrText: IntentInput.ocrSnippet(out.ocrText),
                visionLabels: IntentInput.visionLabels(tags: out.tags))
            intentKey = bucket?.rawValue
        }
```

- [ ] **Step 2: Persist intent in the files-row update**

Inside the `if var file = try FileRow...fetchOne(db) {` block, after the line `file.analyzed_hash = file.content_hash` (line 132) and before `try file.update(db)`, add:

```swift
                    file.intent = intentKey
                    file.intent_model_version = intentVersion
```

- [ ] **Step 3: Build to verify**

Run: `xcodebuild -scheme Muse -configuration Debug -destination 'platform=macOS' build`
Expected: BUILD SUCCEEDED.

- [ ] **Step 4: Commit**

```bash
git add Muse/Muse/Intelligence/AnalyzePipeline.swift
git commit -m "feat: classify screenshot intent during analysis and persist it"
```

---

## Task 6: Qualifying-buckets logic (pure)

**Files:**
- Create: `Muse/Muse/Intelligence/Collections/IntentCollections.swift`
- Test: `Muse/MuseTests/IntentCollectionsTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
// Muse/MuseTests/IntentCollectionsTests.swift
import XCTest
@testable import Muse

final class IntentCollectionsTests: XCTestCase {
    func testBucketAtThresholdQualifies() {
        let members = [
            (fileID: "a", bucket: "recipe"),
            (fileID: "b", bucket: "recipe"),
            (fileID: "c", bucket: "recipe"),
        ]
        let q = IntentCollections.qualifyingBuckets(members: members)
        XCTAssertEqual(q["recipe"]?.sorted(), ["a", "b", "c"])
    }

    func testBucketBelowThresholdDropped() {
        let members = [
            (fileID: "a", bucket: "shopping"),
            (fileID: "b", bucket: "shopping"),
        ]
        XCTAssertNil(IntentCollections.qualifyingBuckets(members: members)["shopping"])
    }

    func testMultipleBucketsSeparated() {
        let members = [
            (fileID: "a", bucket: "recipe"), (fileID: "b", bucket: "recipe"),
            (fileID: "c", bucket: "recipe"), (fileID: "d", bucket: "code"),
            (fileID: "e", bucket: "code"),   (fileID: "f", bucket: "code"),
        ]
        let q = IntentCollections.qualifyingBuckets(members: members)
        XCTAssertEqual(q.count, 2)
        XCTAssertEqual(q["recipe"]?.count, 3)
        XCTAssertEqual(q["code"]?.count, 3)
    }

    func testCustomThreshold() {
        let members = [(fileID: "a", bucket: "places"), (fileID: "b", bucket: "places")]
        XCTAssertEqual(IntentCollections.qualifyingBuckets(members: members, threshold: 2)["places"]?.count, 2)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -scheme Muse -destination 'platform=macOS' -only-testing:MuseTests/IntentCollectionsTests`
Expected: FAIL — "cannot find 'IntentCollections' in scope".

- [ ] **Step 3: Write minimal implementation**

```swift
// Muse/Muse/Intelligence/Collections/IntentCollections.swift
import Foundation

/// Pure logic deciding which intent buckets are big enough to surface as
/// collections. Kept separate from the DB-bound CollectionsEngine so it's
/// unit-testable.
enum IntentCollections {
    /// Minimum alive members before a bucket becomes a visible collection.
    static let threshold = 3

    /// members: (fileID, bucketKey) for ALL alive typed screenshots.
    /// Returns bucketKey -> fileIDs for buckets meeting the threshold.
    static func qualifyingBuckets(
        members: [(fileID: String, bucket: String)],
        threshold: Int = threshold
    ) -> [String: [String]] {
        var byBucket: [String: [String]] = [:]
        for m in members { byBucket[m.bucket, default: []].append(m.fileID) }
        return byBucket.filter { $0.value.count >= threshold }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild test -scheme Muse -destination 'platform=macOS' -only-testing:MuseTests/IntentCollectionsTests`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add Muse/Muse/Intelligence/Collections/IntentCollections.swift Muse/MuseTests/IntentCollectionsTests.swift
git commit -m "feat: add IntentCollections qualifying-buckets logic"
```

---

## Task 7: Intent pass + emergent exclusion in CollectionsEngine

**Files:**
- Modify: `Muse/Muse/Intelligence/Collections/CollectionsEngine.swift:30-78`

Integration glue; verified by build + app run. The decision logic it relies on is unit-tested in Task 6.

- [ ] **Step 1: Replace the body of `recluster()`**

Replace the entire `recluster()` function (lines 30–78) with:

```swift
    func recluster() async {
        guard let q = Database.shared.dbQueue, !isClustering else { return }
        isClustering = true
        defer { isClustering = false }

        let registry = IntelligenceRegistry.shared

        // --- Intent track (typed screenshots) — runs regardless of embeddings.
        let intentMembers: [(fileID: String, bucket: String)] = (try? await q.read { db in
            try Row.fetchAll(db, sql: """
                SELECT f.id AS id, f.intent AS intent FROM files f
                JOIN paths p ON p.file_id = f.id
                WHERE f.intent IS NOT NULL AND p.is_alive = 1
                """).map { (fileID: $0["id"] as String, bucket: $0["intent"] as String) }
        }) ?? []
        let qualifying = IntentCollections.qualifyingBuckets(members: intentMembers)
        var intentLiveIDs = Set<String>()
        for (bucketKey, fileIDs) in qualifying {
            guard let bucket = IntentBucket(rawValue: bucketKey) else { continue }
            let id = bucket.collectionID
            intentLiveIDs.insert(id)
            // Preserve a user rename: reuse the stored name if the collection exists.
            let existing: String? = (try? await q.read { db in
                try String.fetchOne(db, sql: "SELECT name FROM collections WHERE id = ?",
                                    arguments: [id])
            }) ?? nil
            let name = existing ?? bucket.displayName
            try? await CollectionStore.upsert(queue: q, id: id, name: name,
                                              memberIDs: fileIDs, modelVersion: "intent-v1")
        }

        // --- Emergent track — everything EXCEPT typed screenshots.
        let typedIDs: Set<String> = (try? await q.read { db in
            try Set(String.fetchAll(db, sql: "SELECT id FROM files WHERE intent IS NOT NULL"))
        }) ?? []
        let items: [ClusterItem] = (try? await q.read { db in
            let rows = try EmbeddingRow.fetchAll(db)
            return rows.compactMap { row -> ClusterItem? in
                guard !typedIDs.contains(row.file_id) else { return nil }
                return ClusterItem(id: row.file_id,
                                   textVector: VectorMath.fromData(row.vector),
                                   featurePrint: nil)
            }
        }) ?? []

        let old = (try? await CollectionStore.currentMembership(queue: q)) ?? [:]
        var matched: [CollectionIdentity.Matched] = []
        if !items.isEmpty {
            let clusterer = registry.clusterer
            let clusters = await Task.detached(priority: .userInitiated) { clusterer.cluster(items) }.value
            matched = CollectionIdentity.match(old: old,
                                               new: clusters.map { Set($0.memberIDs) })
        }

        // Drop collections that no longer exist — but never manual collections,
        // collections holding manual members, or live intent collections.
        let liveIDs = Set(matched.map(\.id)).union(intentLiveIDs)
        let protected = (try? await CollectionStore.protectedCollectionIDs(queue: q)) ?? []
        for staleID in old.keys where !liveIDs.contains(staleID) && !protected.contains(staleID) {
            try? await q.write { db in
                try db.execute(sql: "DELETE FROM collections WHERE id = ?", arguments: [staleID])
            }
        }

        for m in matched {
            let name: String
            if m.isNew {
                let tags = (try? await topTags(queue: q, fileIDs: Array(m.members))) ?? []
                name = await registry.namer.name(tagsByFrequency: tags)
            } else {
                name = (try? await q.read { db in
                    try String.fetchOne(db, sql: "SELECT name FROM collections WHERE id = ?",
                                        arguments: [m.id])
                }).flatMap { $0 } ?? "Collection"
            }
            try? await CollectionStore.upsert(queue: q, id: m.id, name: name,
                                              memberIDs: Array(m.members),
                                              modelVersion: registry.clusterer.modelVersion)
        }
        await reload()
    }
```

> Note: `CollectionIdentity.match` returns a `Matched` value with `.id`, `.members`, `.isNew` (as used by the original code). If its type name differs, match the original usage — only the surrounding structure changed, not the matched-type API.

- [ ] **Step 2: Build to verify**

Run: `xcodebuild -scheme Muse -configuration Debug -destination 'platform=macOS' build`
Expected: BUILD SUCCEEDED. If the compiler reports the `Matched` type name, open `CollectionIdentity` and use the exact type for the `matched` array declaration.

- [ ] **Step 3: Run the full existing test suite to confirm no regressions**

Run: `xcodebuild test -scheme Muse -destination 'platform=macOS' -only-testing:MuseTests`
Expected: PASS (existing StyleKind tests + the three new test classes).

- [ ] **Step 4: Commit**

```bash
git add Muse/Muse/Intelligence/Collections/CollectionsEngine.swift
git commit -m "feat: two-track reclustering — intent collections + emergent exclusion"
```

---

## Task 8: One-time backfill for pre-existing screenshots

**Files:**
- Create: `Muse/Muse/Intelligence/IntentBackfill.swift`
- Modify: `Muse/Muse/MuseApp.swift`

Pre-existing screenshots already have `analyzed_hash == content_hash`, so the analyze pass won't revisit them. This classifies them once, reading the OCR text already stored in `files_fts` — no re-Vision.

- [ ] **Step 1: Create the backfill**

```swift
// Muse/Muse/Intelligence/IntentBackfill.swift
import Foundation
import GRDB

/// One-time pass: classify screenshots that were analyzed before intent typing
/// existed (intent_model_version IS NULL). Reads stored OCR + vision tags only —
/// never re-runs Vision. Safe to call on every launch; it self-limits.
enum IntentBackfill {
    static func run() async {
        guard let q = Database.shared.dbQueue else { return }
        let registry = IntelligenceRegistry.shared

        // Candidate screenshots: have a 'screenshot' vision-kind tag and no
        // intent_model_version yet.
        struct Candidate { let id: String; let ocr: String; let labels: [String] }
        let candidates: [Candidate] = (try? await q.read { db in
            let ids = try String.fetchAll(db, sql: """
                SELECT f.id FROM files f
                JOIN tags t ON t.file_id = f.id
                WHERE t.source = 'vision-kind' AND t.label = 'screenshot'
                  AND f.intent_model_version IS NULL
                """)
            return try ids.map { id in
                let ocr = (try String.fetchOne(db, sql:
                    "SELECT ocr_text FROM files_fts WHERE file_id = ?", arguments: [id])) ?? ""
                let labels = try String.fetchAll(db, sql:
                    "SELECT label FROM tags WHERE file_id = ? AND source = 'vision'",
                    arguments: [id])
                return Candidate(id: id, ocr: ocr, labels: labels)
            }
        }) ?? []
        guard !candidates.isEmpty else { return }

        let version = registry.intentModelVersion
        var didClassifyAny = false
        for c in candidates {
            let bucket = await registry.intentClassifier.classify(
                ocrText: IntentInput.ocrSnippet(c.ocr),
                visionLabels: c.labels)
            try? await q.write { db in
                try db.execute(sql:
                    "UPDATE files SET intent = ?, intent_model_version = ? WHERE id = ?",
                    arguments: [bucket?.rawValue, version, c.id])
            }
            if bucket != nil { didClassifyAny = true }
        }
        if didClassifyAny {
            await CollectionsEngine.shared.recluster()
        }
    }
}
```

- [ ] **Step 2: Call it on launch**

In `Muse/Muse/MuseApp.swift`, find where launch-time maintenance runs (the same place `Housekeeping` and the `ThumbnailCache` prune are kicked off — search for `Housekeeping` or `.task`). Add a detached call alongside it:

```swift
        Task { await IntentBackfill.run() }
```

Place it after the database is initialized (same scope as the existing Housekeeping launch call). If the existing prune is inside a `.task { }` on the root view, add the line inside that same `.task`.

- [ ] **Step 3: Build to verify**

Run: `xcodebuild -scheme Muse -configuration Debug -destination 'platform=macOS' build`
Expected: BUILD SUCCEEDED.

- [ ] **Step 4: Commit**

```bash
git add Muse/Muse/Intelligence/IntentBackfill.swift Muse/Muse/MuseApp.swift
git commit -m "feat: one-time intent backfill for pre-existing screenshots on launch"
```

---

## Task 9: Color Galaxy nodes by intent (#4 trial)

**Files:**
- Modify: `Muse/Muse/Views/Spatial/GalaxyModel.swift:17-20, 92-120, 220`
- Modify: `Muse/Muse/Views/Spatial/GalaxyView.swift:182-198`

SceneKit/SwiftUI — verified by building and looking at the running app.

- [ ] **Step 1: Carry `intent` on GalaxyNode**

In `GalaxyModel.swift`, change `GalaxyNode` (lines 17–20):

```swift
struct GalaxyNode {
    let path: String
    let fileID: String
    let intent: String?
}
```

- [ ] **Step 2: Fetch intent alongside feature_print/palette**

In `GalaxyModel.build`, the `files` fetch (lines 96–106) currently selects `id, feature_print, palette`. Change the SQL to also select `intent`, and capture it. Replace that inner loop with:

```swift
            var printByID: [String: Data] = [:]
            var paletteByID: [String: String] = [:]
            var intentByID: [String: String] = [:]
            for chunk in chunks(ids, 500) {
                let marks = chunk.map { _ in "?" }.joined(separator: ",")
                let rows = try Row.fetchAll(db, sql: """
                    SELECT id, feature_print, palette, intent FROM files
                    WHERE id IN (\(marks))
                    """, arguments: StatementArguments(chunk))
                for r in rows {
                    let id: String = r["id"]
                    if let d: Data = r["feature_print"] { printByID[id] = d }
                    if let p: String = r["palette"] { paletteByID[id] = p }
                    if let it: String = r["intent"] { intentByID[id] = it }
                }
            }
```

- [ ] **Step 3: Thread intent into the Fetched struct and nodes**

In `private struct Fetched` (lines 140–147) add `var intentByID: [String: String]` and update `.empty`:

```swift
    private struct Fetched {
        var ordered: [(path: String, fileID: String)]
        var printByID: [String: Data]
        var paletteByID: [String: String]
        var vectorByID: [String: Data]
        var intentByID: [String: String]
        static let empty = Fetched(ordered: [], printByID: [:], paletteByID: [:],
                                   vectorByID: [:], intentByID: [:])
    }
```

Update the `return Fetched(...)` constructor in `build` (lines 118–119) to pass `intentByID: intentByID`.

In `assemble`, change the `nodes` construction (line 220) to:

```swift
        let nodes = ordered.map {
            GalaxyNode(path: $0.path, fileID: $0.fileID, intent: fetched.intentByID[$0.fileID])
        }
```

Also update the two early-return `GalaxyNode(...)` constructions:
- Line ~124 (`fetched.ordered.map { GalaxyNode(path: $0.path, fileID: $0.fileID) }`) →
  `fetched.ordered.map { GalaxyNode(path: $0.path, fileID: $0.fileID, intent: fetched.intentByID[$0.fileID]) }`

- [ ] **Step 4: Build to verify the model compiles**

Run: `xcodebuild -scheme Muse -configuration Debug -destination 'platform=macOS' build`
Expected: BUILD SUCCEEDED (GalaxyView doesn't yet use `.intent` — that's next).

- [ ] **Step 5: Add a colored backing plane per node in the scene**

In `GalaxyView.swift`, inside `rebuildIfNeeded`, the tile-creation loop (lines 186–198). The tile's own face gets overwritten by the thumbnail, so the intent color goes on a slightly larger plane placed just behind each tile. Replace the loop body with:

```swift
        for (i, node) in data.nodes.enumerated() {
            // Intent backing: a slightly larger plane behind the tile, tinted by bucket.
            if let key = node.intent,
               let bucket = IntentBucket(rawValue: key),
               let color = Self.nsColor(hex: bucket.galaxyHex) {
                let backing = SCNPlane(width: Self.tileSize * 1.28, height: Self.tileSize * 1.28)
                let bm = backing.firstMaterial!
                bm.lightingModel = .constant
                bm.diffuse.contents = color
                bm.isDoubleSided = true
                let backingNode = SCNNode(geometry: backing)
                backingNode.simdPosition = data.positions[i] * spread + SIMD3(0, 0, -1)
                backingNode.constraints = [billboard]
                scene.rootNode.addChildNode(backingNode)
            }

            let plane = SCNPlane(width: Self.tileSize, height: Self.tileSize)
            let m = plane.firstMaterial!
            m.lightingModel = .constant
            m.diffuse.contents = NSColor(white: 0.5, alpha: 1)
            m.isDoubleSided = true
            let tile = SCNNode(geometry: plane)
            tile.name = "tile-\(i)"
            tile.simdPosition = data.positions[i] * spread
            tile.constraints = [billboard]
            scene.rootNode.addChildNode(tile)
            nodes.append(tile)
        }
```

> Note: the loop variable is now `node` (was `_`). `nodes.append(tile)` keeps the `nodes` array parallel to `data.nodes` exactly as before (only tile nodes are appended; backing planes are not, so hit-testing by `tile-<i>` is unchanged).

- [ ] **Step 6: Add the hex→NSColor helper**

In `GalaxyView.swift`, inside `GalaxySceneCoordinator`, near `contrastColor` (after line 267), add:

```swift
    /// "#RRGGBB" -> NSColor (nil if malformed).
    static func nsColor(hex: String) -> NSColor? {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        return NSColor(red: CGFloat((v >> 16) & 0xFF) / 255,
                       green: CGFloat((v >> 8) & 0xFF) / 255,
                       blue: CGFloat(v & 0xFF) / 255, alpha: 1)
    }
```

- [ ] **Step 7: Build to verify**

Run: `xcodebuild -scheme Muse -configuration Debug -destination 'platform=macOS' build`
Expected: BUILD SUCCEEDED.

- [ ] **Step 8: Manual verification — run the app**

```bash
open "$(xcodebuild -scheme Muse -configuration Debug -destination 'platform=macOS' -showBuildSettings 2>/dev/null | awk -F' = ' '/ BUILT_PRODUCTS_DIR /{d=$2} / FULL_PRODUCT_NAME /{n=$2} END{print d"/"n}')"
```
Then in the app: add a folder containing screenshots → wait for the bottom status pills to finish (Indexing → Analyzing). Verify:
- Intent collections (e.g. "Recipes", "Code") appear in the Collections row once a bucket has ≥3 screenshots, using the normal card design.
- Opening one shows only its screenshots; the same screenshots are not duplicated into an emergent cluster.
- Switch to the Galaxy view (toolbar picker): screenshot nodes show a colored matte behind the thumbnail by bucket; non-screenshot images have none.
- On a pre-26 Mac (or if FM unavailable) the app still indexes/clusters; intent collections simply don't appear.

- [ ] **Step 9: Commit**

```bash
git add Muse/Muse/Views/Spatial/GalaxyModel.swift Muse/Muse/Views/Spatial/GalaxyView.swift
git commit -m "feat: color Galaxy nodes by screenshot intent (taste-map trial)"
```

---

## Self-review notes (verification against the spec)

- **Scope = screenshots only:** Task 5 gates classification behind `IntentInput.isScreenshot`; non-screenshots keep `intent = nil`. ✅
- **Hybrid (fixed + emergent):** Task 7 builds fixed intent collections AND keeps emergent clustering for the rest. ✅
- **10 buckets:** Task 1 enumerates exactly 10; test asserts the count. ✅
- **FM-gated, emergent-only fallback:** Task 4 factory returns `NoIntentClassifier` off-AI; classification yields nil; emergent track unaffected. ✅
- **Clean two-track:** Task 7 excludes typed screenshots from the emergent `items` set. ✅
- **`intent` column + version:** Task 2. ✅
- **Backfill without re-Vision:** Task 8 reads `files_fts.ocr_text` + stored tags only. ✅
- **Identical UI:** no new views; intent collections reuse `CollectionRow`/`CollectionStore`. Rename preserved by reusing the stored name in Task 7. ✅
- **#4 color by intent:** Task 9. ✅
- **No network / on-device / free:** only Vision + FoundationModels + SQLite; no URLSession. ✅
- **Threshold ≥3 tunable:** `IntentCollections.threshold` (Task 6). ✅
```
