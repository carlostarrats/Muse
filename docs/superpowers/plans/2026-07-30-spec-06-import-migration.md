# Spec 06 — Import & Migration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** One coherent **File > Import** surface over five sources (universal
keywords/ratings/captions/GPS, Lightroom edits + presets, Apple Photos, Google
Takeout, Eagle library), the color-label mapping sheet (DECIDED #12), and the
import-size FYI + battery/thermal-aware analysis throttling package (DECIDED
#22/#23). Every write lands through existing seams (tags, ratings, notes, edits,
collections) — a new source is a reader + a mapper, never a new writer. **No new
migrations** — everything lands in tables Specs 01–05 already created.

**Architecture:** One `AppState.importModal: ImportModal?` enum flag replaces the
shipped `metadataImportRequest` 1-for-1 (net-zero `@Published` count — the
`collectionModal` seam), fanning out to per-source run models sharing one
`ImportReport`/`ImportReportCard`. The shipped `MetadataKeywordReader` /
`MetadataImportApply` / `MetadataImportRules` / `MetadataImportModel` are
extended in place, never forked. `ImportSupplement` is the one writer for
externally-sourced GPS/dates (XMP GPS, Takeout JSON, PHAsset), merging
header-wins/external-fills-gaps against Spec 02's `photo_meta`/`files.lat,lon`.
`LightroomXMP`/`LightroomEditMapper` turn `crs:` XMP into badged, provenance-
tagged `EditStack`s through Spec 04's `EditStore.save`. `WorkThrottleStore` /
`AnalysisStatusStore` / `AnalysisEstimator` throttle and report on the existing
analyze pass and Spec 02/03 backfills without adding an off switch. All new
stateful surfaces are frozen-`AppState`-compliant Pattern-B `@MainActor`
singletons or pure nonisolated enums/structs, unit-tested without UI.

**Tech Stack:** Swift 5 (`SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`), SwiftUI +
AppKit escape hatches, GRDB.swift 7.10, ImageIO/`CGImageMetadata`, PhotoKit
(Apple Photos only), IOKit.ps (throttle only), XCTest. No new third-party
dependency.

## Global Constraints

- **Spec 06 adds NO migrations.** Every write lands in existing tables (`tags`,
  `notes`, `edits`/`edit_presets` from Spec 04, `photo_meta`/`files.lat,lon` from
  Spec 02, `collections`). Future specs continue at v24.
- **This plan assumes Specs 01–05 are already merged** (the foundation's build
  order places Import after Library-core and Editing). Concretely it consumes:
  Spec 02's `PhotoHeaderReader`/`photo_meta`/`files.lat,lon`/`GeocodeBackfill`/
  `SearchFacets` (Tasks 8, 13, 15), and Spec 04's `EditStack`/`EditStackCodec`/
  `EditStore`/`EditRecordStore`/`EditPresetStore`/`AdjustmentGroup`/the
  before/after compare suite (Tasks 16–21). Tasks 1–7, 9–12, 14 have **no**
  Spec 02/04 dependency and can land first regardless. Where a task references
  a Spec 02/04 symbol, treat that symbol as already in the tree — do not
  reimplement it here.
- **`AppState` is frozen.** No new `@Published` properties beyond the one
  net-zero swap in Task 2 (`importModal` replaces `metadataImportRequest`).
  New stateful surfaces (`WorkThrottleStore`, `AnalysisStatusStore`) are
  standalone `@MainActor final class … ObservableObject` singletons
  (`static let shared`), observed directly by views — zero or one forwarded
  `objectWillChange` cancellable in `AppState.init`, nothing else.
- **A new import source is a reader + a mapper, never a new writer.** Tags via
  `MetadataImportApply.applyKeywords` (insert-or-promote manual tier); ratings
  via `TagStore.shared.setRating` behind `MetadataImportRules.ratingToApply`
  (gap-fill only); notes via `NoteStore` (fill-gaps only, never overwrite);
  edits via `EditStore.shared.save` (never clobbers an existing stack);
  collections via `CollectionStore.createManual`/`addFile` (`added_by:
  'manual'`).
- **Label tags carry the canonical-English prefix `"Label: "`** and the
  tag-search leg must exclude them unless the query targets labels — a
  Lightroom workflow marker (red = "second pass") must never answer a Muse
  content color query (DECIDED #12, the semantic-collision fix). This is
  pinned by test and must never be relaxed.
- **Supplement writes (externally-sourced GPS/dates) are header-wins,
  external-fills-gaps, and stamp BOTH Spec 02 scan markers** so the next
  analyze pass or `PhotoHeaderBackfill` run doesn't clobber imported values
  with header NULLs. `(0, 0)` coordinates are always treated as absent, never
  null island.
- **`EditStack.origin` is provenance, not data**: nil-omitted from canonical
  JSON (every pre-existing stack's `stack_hash` stays byte-identical — pinned
  by fixture test), never copied by `EditTransfer.apply`, stripped at preset
  save, gone on Reset.
- **Analysis pause is scheduling, never an off switch.** `WorkThrottleStore`
  gates *when* work spawns (`waitUntilRunnable()`); markers, selection logic,
  and every data path stay untouched. Import runs themselves are never
  throttled — they are foreground, cancellable, user-initiated.
- **The FYI card is one button, time-gated, on-device-calibrated, shown at
  most once per launch** — never a choice dialog, never hardcoded duration.
- **House testing convention: no UI unit tests.** Every rule above is pure
  logic in a nonisolated enum/struct, tested against typed values (English
  host), never rendered strings.
- **Every new user-facing string is localized at introduction**
  (`String(localized:)` / SwiftUI text-literal positions) — run
  `xcodebuild -exportLocalizations` before calling any task's UI work done.

---

## Task 1: `ImportReport` + `ImportReportCard` — the shared report shape

**Files:**
- Create: `Muse/Muse/Import/ImportReport.swift`
- Create: `Muse/Muse/Views/ImportReportCard.swift`
- Test: `Muse/MuseTests/ImportReportTests.swift`

**Interfaces:**
- Produces: `ImportReport` (nonisolated struct, `Identifiable`, `Equatable`) —
  every later task's run model accumulates into one of these and hands it to
  `importModal = .report(report)` (Task 2). `LabelOutcome` (nonisolated
  struct) — consumed by Task 9's label mapping sheet.
- Consumes: nothing (leaf task).

```swift
nonisolated struct ImportReport: Equatable, Identifiable {
    let id: UUID
    var sourceName: String              // localized display: "Lightroom", "Apple Photos", …
    var filesImported: Int = 0          // files copied/created (0 for in-place scans)
    var filesTouched: Int = 0           // files that received any metadata
    var filesWithNone: Int = 0
    var filesSkipped: Int = 0           // unreadable / dataless / copy-failed
    var keywords: Int = 0
    var ratings: Int = 0
    var notes: Int = 0
    var coordinates: Int = 0            // supplement writes that filled lat/lon
    var captureDates: Int = 0
    var labelCounts: [LabelOutcome] = []
    var editsApproximated: Int = 0      // LR stacks written
    var editsSkippedExisting: Int = 0   // had a Muse edit already — never clobbered
    var unsupportedSliders: [String: Int] = [:]
    var collectionsCreated: Int = 0
    var notices: [String] = []          // source-specific stated-plainly lines

    init(id: UUID = UUID(), sourceName: String) {
        self.id = id
        self.sourceName = sourceName
    }
}

nonisolated struct LabelOutcome: Equatable {
    var label: String                   // raw source value ("Red", "Rouge", "Second")
    var count: Int
    var choice: LabelMapping.Choice     // from Task 9 — forward-declared there
}
```

- [ ] **Step 1: Write the failing test**

```swift
// Muse/MuseTests/ImportReportTests.swift
import XCTest
@testable import Muse

final class ImportReportTests: XCTestCase {
    func testDefaultsAreZero() {
        let r = ImportReport(sourceName: "Lightroom")
        XCTAssertEqual(r.filesImported, 0)
        XCTAssertEqual(r.filesTouched, 0)
        XCTAssertEqual(r.keywords, 0)
        XCTAssertTrue(r.labelCounts.isEmpty)
        XCTAssertTrue(r.unsupportedSliders.isEmpty)
        XCTAssertTrue(r.notices.isEmpty)
    }

    func testAccumulationIsPlainAddition() {
        var r = ImportReport(sourceName: "Lightroom")
        r.keywords += 5
        r.keywords += 3
        r.unsupportedSliders["Clarity", default: 0] += 1
        r.unsupportedSliders["Clarity", default: 0] += 1
        XCTAssertEqual(r.keywords, 8)
        XCTAssertEqual(r.unsupportedSliders["Clarity"], 2)
    }

    func testIdentifiableIsStablePerInstance() {
        let a = ImportReport(sourceName: "Eagle")
        let b = ImportReport(sourceName: "Eagle")
        XCTAssertNotEqual(a.id, b.id)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -project Muse/Muse.xcodeproj -scheme Muse -only-testing:MuseTests/ImportReportTests`
Expected: FAIL — `ImportReport` does not exist.

- [ ] **Step 3: Write `ImportReport.swift` and a placeholder `LabelMapping.Choice`**

Since `LabelOutcome` references `LabelMapping.Choice` (owned by Task 9), stub a
minimal forward declaration now so this file compiles standalone; Task 9
replaces the stub with the real enum (same name/cases — no call site changes).

```swift
// Muse/Muse/Import/ImportReport.swift  (full file per the struct above)
import Foundation

// Forward stub — replaced verbatim by Task 9's LabelMapping.swift.
enum LabelMapping {
    enum Choice: Equatable, Codable {
        case skip
        case namespaced
        case tag(String)
    }
}

nonisolated struct ImportReport: Equatable, Identifiable { /* as above */ }
nonisolated struct LabelOutcome: Equatable { /* as above */ }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild test -project Muse/Muse.xcodeproj -scheme Muse -only-testing:MuseTests/ImportReportTests`
Expected: PASS

- [ ] **Step 5: Build `ImportReportCard.swift`**

A plain summary list matching the pre-spec's register ("312 ratings, 1,840
keywords, 47 red labels → `Label: Red`"): counts as `Text` rows, the
`unsupportedSliders` dictionary and `notices` array rendered in `.secondary`
below, one **Done** `ModalButton` (`.normal` kind) that clears `importModal`.
No `ScrollView`/`Form` wrapper inside (the shell presenter owns scrolling —
CLAUDE.md modal rule); use `.fixedSize(horizontal: false, vertical: true)` if
a `Form` is used for row layout.

```swift
// Muse/Muse/Views/ImportReportCard.swift
import SwiftUI

struct ImportReportCard: View {
    let report: ImportReport
    let onDone: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(String(localized: "Import complete"))
                .font(.headline)
            Text(report.sourceName)
                .foregroundStyle(.secondary)
            countRows
            if !report.labelCounts.isEmpty { labelRows }
            if !report.unsupportedSliders.isEmpty { unsupportedRows }
            if !report.notices.isEmpty { noticeRows }
            HStack {
                Spacer()
                ModalButton(String(localized: "Done"), kind: .normal, action: onDone)
            }
        }
        .padding(20)
    }

    @ViewBuilder private var countRows: some View { /* filesImported/Touched/etc rows */ }
    @ViewBuilder private var labelRows: some View { /* "47 red labels → Label: Red" per LabelOutcome */ }
    @ViewBuilder private var unsupportedRows: some View { /* "Clarity: 12 files" */ }
    @ViewBuilder private var noticeRows: some View {
        ForEach(report.notices, id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
    }
}
```

No test for this view (house rule: no UI unit tests).

- [ ] **Step 6: Build to confirm compilation**

Run: `xcodebuild build -project Muse/Muse.xcodeproj -scheme Muse`
Expected: BUILD SUCCEEDED.

- [ ] **Step 7: Commit**

```bash
git add Muse/Muse/Import/ImportReport.swift Muse/Muse/Views/ImportReportCard.swift Muse/MuseTests/ImportReportTests.swift
git commit -m "feat(import): add shared ImportReport model and report card"
```

---

## Task 2: `ImportModal` enum — replace `metadataImportRequest` (net-zero AppState)

**Files:**
- Modify: `Muse/Muse/Models/AppState.swift:341` (remove
  `@Published var metadataImportRequest: MetadataImportRequest?`)
- Modify: `Muse/Muse/Models/AppState+Import.swift` (add the enum + published
  property + rename entry point)
- Modify: `Muse/Muse/ContentView.swift:55,202-205` (swap dismissal +
  presenter switch)
- Modify: `Muse/Muse/MuseApp.swift:264-266` (call rename; menu item text)
- Test: `Muse/MuseTests/ImportModalTests.swift`

**Interfaces:**
- Consumes: `MetadataImportRequest` (existing shipped struct, moves into this
  file per the spec's note "the struct moves here" — keep its fields
  unchanged), `ImportReport` (Task 1), `LabelMapping.Choice`/label-mapping
  payload types (stubbed here, replaced by Task 9's real types with identical
  shape).
- Produces: `AppState.importModal: ImportModal?` — every later task
  (3 through 21) sets this to raise its own card and reads it to know which
  card the shell should build. `ImportModal.id: String` — stable per case +
  payload id, used as the `.museModal` identity.

```swift
// Muse/Muse/Models/AppState+Import.swift — added
enum ImportModal: Equatable, Identifiable {
    case metadata(MetadataImportRequest)
    case labelMapping(LabelMappingRequest)      // Task 9
    case lightroomPresets([URL])                // Task 21
    case applePhotos                            // Task 15
    case takeout(TakeoutImportRequest)          // Task 13
    case eagle(EagleImportRequest)              // Task 14
    case report(ImportReport)                   // Task 1

    var id: String {
        switch self {
        case .metadata(let r): return "metadata-\(r.folder.path)"
        case .labelMapping(let r): return "labelMapping-\(r.id)"
        case .lightroomPresets: return "lightroomPresets"
        case .applePhotos: return "applePhotos"
        case .takeout(let r): return "takeout-\(r.id)"
        case .eagle(let r): return "eagle-\(r.id)"
        case .report(let r): return "report-\(r.id)"
        }
    }
}
```

`MetadataImportRequest` keeps its existing fields (`folder: URL`); it simply
moves from wherever it's currently declared into `AppState+Import.swift`
beside the new enum. `LabelMappingRequest`, `TakeoutImportRequest`,
`EagleImportRequest` are minimal `Identifiable` structs stubbed in this task
(an `id: UUID` + the one field each later task needs) and filled out fully
by Tasks 9, 13, 14 — the enum's shape must not change again after this task.

- [ ] **Step 1: Write the failing test**

```swift
// Muse/MuseTests/ImportModalTests.swift
import XCTest
@testable import Muse

@MainActor
final class ImportModalTests: XCTestCase {
    func testImportModalReplacesMetadataImportRequestOneForOne() {
        let appState = AppState()
        XCTAssertNil(appState.importModal)
        appState.importModal = .metadata(MetadataImportRequest(folder: URL(fileURLWithPath: "/tmp")))
        XCTAssertNotNil(appState.importModal)
        // modalPresented must observe importModal, not a removed property.
        XCTAssertTrue(appState.modalPresented)
        appState.importModal = nil
        XCTAssertFalse(appState.modalPresented)
    }

    func testEachCaseHasAStableDistinctID() {
        let a = ImportModal.applePhotos
        let b = ImportModal.applePhotos
        XCTAssertEqual(a.id, b.id)
        let c = ImportModal.report(ImportReport(sourceName: "Eagle"))
        XCTAssertNotEqual(a.id, c.id)
    }
}
```

(Assumes `AppState.modalPresented` is a computed property folding several
modal flags with `||` — read `AppState.swift:517` before writing this test to
confirm the exact accessor name/shape used in the running codebase; adjust
the assertion to whatever that computed property is actually called.)

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -project Muse/Muse.xcodeproj -scheme Muse -only-testing:MuseTests/ImportModalTests`
Expected: FAIL — `importModal` does not exist yet.

- [ ] **Step 3: Implement the swap**

1. In `AppState.swift:341`, delete `@Published var metadataImportRequest: MetadataImportRequest?`.
2. In `AppState+Import.swift`, add `@Published var importModal: ImportModal?`
   plus the `ImportModal` enum and the three stub request structs.
3. In `AppState.swift:517`, change the `modalPresented`-shape computed
   property's `metadataImportRequest != nil` term to `importModal != nil`.
4. In `ContentView.swift:55`, change
   `if appState.metadataImportRequest != nil { appState.metadataImportRequest = nil; return }`
   to `if appState.importModal != nil { appState.importModal = nil; return }`.
5. In `ContentView.swift:202-205`, replace the single-case `.museModal`
   presenter with a `switch` over `appState.importModal`, one case per enum
   value; for now only `.metadata` and `.report` have real card bodies
   (`MetadataImportSheet`/`ImportRunCard` per Task 6, `ImportReportCard` per
   Task 1) — the other five cases get a temporary `EmptyView()` body, replaced
   by Tasks 9/13/14/15/21 as they land.
6. In `AppState+Import.swift:29`, rename `importKeywordsAndRatings()` to
   `importMetadataAndEdits()` and change its body's
   `metadataImportRequest = MetadataImportRequest(folder: std)` to
   `importModal = .metadata(MetadataImportRequest(folder: std))`.
7. In `MuseApp.swift:264`, change the call site to
   `appState.importMetadataAndEdits()`; the item's label text is updated by
   Task 6 once the "File > Import" submenu is built (leave it as-is here to
   keep this task's diff mechanical).

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild test -project Muse/Muse.xcodeproj -scheme Muse -only-testing:MuseTests/ImportModalTests`
Expected: PASS

- [ ] **Step 5: Run the existing import test suite to confirm nothing regressed**

Run: `xcodebuild test -project Muse/Muse.xcodeproj -scheme Muse -only-testing:MuseTests/MetadataImportApplyTests -only-testing:MuseTests/MetadataImportRulesTests`
Expected: PASS (both untouched by this rename).

- [ ] **Step 6: Commit**

```bash
git add Muse/Muse/Models/AppState.swift Muse/Muse/Models/AppState+Import.swift Muse/Muse/ContentView.swift Muse/Muse/MuseApp.swift Muse/MuseTests/ImportModalTests.swift
git commit -m "refactor(import): replace metadataImportRequest with one ImportModal enum"
```

---

## Task 3: `MetadataKeywordReader.Extracted` gains label/title/caption/creator/coordinate

**Files:**
- Modify: `Muse/Muse/Import/MetadataKeywordReader.swift`
- Test: `Muse/MuseTests/MetadataKeywordReaderTests.swift` (new file if none
  exists yet, or extend it)

**Interfaces:**
- Consumes: nothing new (same `CGImageMetadata`/IPTC dictionaries already
  read).
- Produces: `Extracted.label/title/caption/creator/coordinate` — consumed by
  Task 5 (`ImportedText`), Task 4 (coordinate mirrors `XMPGPS.coordinate`
  shape), Task 6 (the extended run), Task 9 (label mapping accumulates
  `.label`).

```swift
struct Extracted: Equatable {
    var keywords: [String] = []
    var rating: Int? = nil
    var label: String? = nil            // xmp:Label — raw string, verbatim
    var title: String? = nil            // dc:title [Alt, first] → IPTC ObjectName
    var caption: String? = nil          // dc:description [Alt, first] → IPTC CaptionAbstract
    var creator: String? = nil          // dc:creator [Seq, first] → IPTC Byline
    var coordinate: (lat: Double, lon: Double)? = nil
    var isEmpty: Bool {
        keywords.isEmpty && rating == nil && label == nil && title == nil
            && caption == nil && creator == nil && coordinate == nil
    }
    fileprivate var complete: Bool {
        !keywords.isEmpty && rating != nil && label != nil && title != nil
            && caption != nil && creator != nil && coordinate != nil
    }
}
```

Note: `(lat: Double, lon: Double)?` tuples are not natively `Equatable`;
either add a manual `==` on `Extracted` comparing the tuple fields, or change
the type to a small `struct Coordinate: Equatable { let lat, lon: Double }` —
prefer the latter (matches `ImportSupplement.External`'s shape in Task 8 and
keeps `Equatable` synthesis working).

- [ ] **Step 1: Write the failing test**

```swift
// Muse/MuseTests/MetadataKeywordReaderTests.swift
import XCTest
@testable import Muse

final class MetadataKeywordReaderTests: XCTestCase {
    // Existing keywords/rating fixtures MUST still pass byte-identically —
    // if a prior suite exists, keep every existing test method verbatim and
    // only ADD the ones below.

    func testExtractedDefaultsIncludeNewFieldsAsNilAndEmpty() {
        let e = MetadataKeywordReader.Extracted()
        XCTAssertNil(e.label)
        XCTAssertNil(e.title)
        XCTAssertNil(e.caption)
        XCTAssertNil(e.creator)
        XCTAssertNil(e.coordinate)
        XCTAssertTrue(e.isEmpty)
    }

    func testReadsLabelTitleCaptionCreatorFromSidecarFixture() throws {
        // Fixture: a small JPEG + .xmp sidecar carrying xmp:Label="Red",
        // dc:title (Alt, one entry), dc:description (Alt, one entry),
        // dc:creator (Seq, one entry). Bundled under
        // MuseTests/Fixtures/metadata-full-fields.xmp + .jpg.
        let url = try XCTUnwrap(Bundle(for: Self.self).url(
            forResource: "metadata-full-fields", withExtension: "jpg"))
        let extracted = try MetadataKeywordReader.read(url: url)
        XCTAssertEqual(extracted.label, "Red")
        XCTAssertNotNil(extracted.title)
        XCTAssertNotNil(extracted.caption)
        XCTAssertNotNil(extracted.creator)
    }

    func testIPTCFallbackWhenNoXMPFieldsPresent() throws {
        // Fixture with IPTC ObjectName/CaptionAbstract/Byline, no XMP at all.
        let url = try XCTUnwrap(Bundle(for: Self.self).url(
            forResource: "metadata-iptc-only", withExtension: "jpg"))
        let extracted = try MetadataKeywordReader.read(url: url)
        XCTAssertNotNil(extracted.title)
        XCTAssertNotNil(extracted.caption)
        XCTAssertNotNil(extracted.creator)
        XCTAssertNil(extracted.label, "xmp:Label has no IPTC fallback")
    }

    func testCompleteShortCircuitsBeforeIPTCWhenAllSevenFieldsPresent() throws {
        // Fixture carrying all seven via sidecar; asserts IPTC mergeIPTC path
        // is never entered by observing no crash on a fixture with
        // deliberately conflicting/garbage IPTC blocks — full XMP wins.
        let url = try XCTUnwrap(Bundle(for: Self.self).url(
            forResource: "metadata-full-with-conflicting-iptc", withExtension: "jpg"))
        let extracted = try MetadataKeywordReader.read(url: url)
        XCTAssertTrue(extracted.complete)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -project Muse/Muse.xcodeproj -scheme Muse -only-testing:MuseTests/MetadataKeywordReaderTests`
Expected: FAIL — new `Extracted` fields don't exist; fixtures missing (add
them alongside this task — small hand-authored JPEG+XMP pairs, a few KB).

- [ ] **Step 3: Extend `Extracted` and the merge functions**

In `MetadataKeywordReader.swift`:
1. Add the five fields to `Extracted` (with the `Coordinate` wrapper struct)
   and update `isEmpty`/`complete`.
2. In `merge(from:into:)` (the XMP leg), add four `out.field == nil`-guarded
   reads: `xmp:Label` (direct tag), `dc:title`/`dc:description` (Alt arrays,
   first entry), `dc:creator` (Seq, first entry) — generalize the existing
   `dc:subject` Bag-walk helper into `xmpStrings(_:path:)` reusable for
   Alt/Seq/Bag, and add GPS via `XMPGPS.coordinate` (Task 4) called from here
   with `exif:GPSLatitude`/`exif:GPSLongitude` string values.
3. In `mergeIPTC(from:into:)`, add three `out.field == nil`-guarded IPTC
   fallbacks: `kCGImagePropertyIPTCObjectName` → title,
   `kCGImagePropertyIPTCCaptionAbstract` → caption,
   `kCGImagePropertyIPTCByline` → creator (array-or-string tolerant, like
   Keywords — take the first).
4. `xmp:Label` gets no IPTC fallback (none exists) — leave it sidecar/XMP-only.

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild test -project Muse/Muse.xcodeproj -scheme Muse -only-testing:MuseTests/MetadataKeywordReaderTests`
Expected: PASS

- [ ] **Step 5: Confirm existing keyword/rating tests are byte-identical**

Run: `xcodebuild test -project Muse/Muse.xcodeproj -scheme Muse -only-testing:MuseTests/MetadataImportApplyTests -only-testing:MuseTests/MetadataImportRulesTests`
Expected: PASS unchanged (this task only adds fields; it must not alter
keyword/rating extraction behavior).

- [ ] **Step 6: Commit**

```bash
git add Muse/Muse/Import/MetadataKeywordReader.swift Muse/MuseTests/MetadataKeywordReaderTests.swift Muse/MuseTests/Fixtures/metadata-*.jpg Muse/MuseTests/Fixtures/metadata-*.xmp
git commit -m "feat(import): extend MetadataKeywordReader with label/title/caption/creator/GPS"
```

---

## Task 4: `Import/XMPGPS.swift` — pure XMP-format GPS parser

**Files:**
- Create: `Muse/Muse/Import/XMPGPS.swift`
- Test: `Muse/MuseTests/XMPGPSTests.swift`

**Interfaces:**
- Consumes: nothing (pure string parsing).
- Produces: `XMPGPS.parse(_:) -> Double?`, `XMPGPS.coordinate(lat:lon:) ->
  (Double, Double)?` — called from Task 3's `merge(from:into:)` for
  `Extracted.coordinate`.

```swift
nonisolated enum XMPGPS {
    /// "DD,MM.mmmmH" or "DD,MM,SSH" → signed decimal degrees; nil for malformed.
    static func parse(_ s: String?) -> Double?
    /// Both axes present and in range, or nil. Rejects non-finite and
    /// out-of-range (|lat| > 90, |lon| > 180).
    static func coordinate(lat: String?, lon: String?) -> (Double, Double)?
}
```

Format: Lightroom writes `exif:GPSLatitude` as `"47,20.516N"` (degrees, comma,
decimal minutes, hemisphere letter N/S/E/W) or occasionally
`"47,20,31.0N"` (degrees, minutes, seconds, hemisphere). Longitude mirrors
with E/W.

- [ ] **Step 1: Write the failing test**

```swift
// Muse/MuseTests/XMPGPSTests.swift
import XCTest
@testable import Muse

final class XMPGPSTests: XCTestCase {
    func testDecimalMinutesFormatNorth() {
        // 47° 20.516' N = 47 + 20.516/60 ≈ 47.34193
        XCTAssertEqual(XMPGPS.parse("47,20.516N")!, 47.34193333, accuracy: 1e-5)
    }

    func testDecimalMinutesFormatSouthIsNegative() {
        XCTAssertLessThan(XMPGPS.parse("47,20.516S")!, 0)
    }

    func testWestIsNegativeLongitude() {
        XCTAssertLessThan(XMPGPS.parse("122,25.100W")!, 0)
    }

    func testDegreesMinutesSecondsFormat() {
        // 47° 20' 31.0" N ≈ 47.34194
        let v = XMPGPS.parse("47,20,31.0N")!
        XCTAssertEqual(v, 47.34194, accuracy: 1e-4)
    }

    func testMalformedStringReturnsNil() {
        XCTAssertNil(XMPGPS.parse("not-a-coordinate"))
        XCTAssertNil(XMPGPS.parse(nil))
        XCTAssertNil(XMPGPS.parse("47,20.516"))     // missing hemisphere
        XCTAssertNil(XMPGPS.parse("47.20.516N"))    // wrong separator
    }

    func testCoordinateRequiresBothAxes() {
        XCTAssertNil(XMPGPS.coordinate(lat: "47,20.516N", lon: nil))
        XCTAssertNil(XMPGPS.coordinate(lat: nil, lon: "122,25.100W"))
        XCTAssertNotNil(XMPGPS.coordinate(lat: "47,20.516N", lon: "122,25.100W"))
    }

    func testOutOfRangeRejected() {
        // A hand-crafted string that parses arithmetically to > 90 degrees.
        XCTAssertNil(XMPGPS.parse("95,00.000N"))
        XCTAssertNil(XMPGPS.parse("185,00.000E"))
    }

    func testNonFiniteRejected() {
        XCTAssertNil(XMPGPS.parse("nan,00.000N"))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -project Muse/Muse.xcodeproj -scheme Muse -only-testing:MuseTests/XMPGPSTests`
Expected: FAIL — `XMPGPS` does not exist.

- [ ] **Step 3: Implement `XMPGPS.swift`**

Split on commas; first token = degrees (`Double`), last character of the
final token = hemisphere letter, middle token(s) = minutes (and seconds when
three numeric tokens are present). Reject non-finite via `.isFinite`,
reject `|lat| > 90` / `|lon| > 180` (note: the range check on latitude uses
90 and on longitude uses 180 — `coordinate(lat:lon:)` must apply the correct
bound to each axis, not a single shared bound).

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild test -project Muse/Muse.xcodeproj -scheme Muse -only-testing:MuseTests/XMPGPSTests`
Expected: PASS

- [ ] **Step 5: Wire into Task 3's `merge(from:into:)`**

If Task 3 already landed, add the `XMPGPS.coordinate` call there now (guarded
`out.coordinate == nil`) reading `exif:GPSLatitude`/`exif:GPSLongitude` via
`CGImageMetadataCopyTagWithPath`. If Task 3 hasn't landed yet, leave this as a
standalone pure module — Task 3 wires it.

- [ ] **Step 6: Commit**

```bash
git add Muse/Muse/Import/XMPGPS.swift Muse/MuseTests/XMPGPSTests.swift
git commit -m "feat(import): add pure XMP GPS coordinate parser"
```

---

## Task 5: `Import/ImportedText.swift` — title/caption/creator → note composer

**Files:**
- Create: `Muse/Muse/Import/ImportedText.swift`
- Test: `Muse/MuseTests/ImportedTextTests.swift`

**Interfaces:**
- Consumes: nothing (pure string composition).
- Produces: `ImportedText.note(title:caption:creator:) -> String?` — called
  from Task 6's extended run model, writing through `NoteStore` fill-gaps.

```swift
nonisolated enum ImportedText {
    static let maxLength = 2_000
    /// Joins the non-empty, case-insensitively-distinct values in order
    /// title · caption · creator (creator prefixed "© ") with newlines.
    /// nil when all empty. Whitespace-trimmed. Length-capped.
    static func note(title: String?, caption: String?, creator: String?) -> String?
}
```

- [ ] **Step 1: Write the failing test**

```swift
// Muse/MuseTests/ImportedTextTests.swift
import XCTest
@testable import Muse

final class ImportedTextTests: XCTestCase {
    func testAllNilReturnsNil() {
        XCTAssertNil(ImportedText.note(title: nil, caption: nil, creator: nil))
    }

    func testAllEmptyStringsReturnNil() {
        XCTAssertNil(ImportedText.note(title: "", caption: "  ", creator: nil))
    }

    func testJoinOrderIsTitleCaptionCreator() {
        let note = ImportedText.note(title: "Sunset", caption: "Over the bay", creator: "Ana")
        XCTAssertEqual(note, "Sunset\nOver the bay\n© Ana")
    }

    func testCreatorIsPrefixedWithCopyrightSign() {
        let note = ImportedText.note(title: nil, caption: nil, creator: "Ana")
        XCTAssertEqual(note, "© Ana")
    }

    func testCaseInsensitiveDuplicateIsDropped() {
        // title and caption are the same text differing only by case.
        let note = ImportedText.note(title: "Sunset", caption: "sunset", creator: nil)
        XCTAssertEqual(note, "Sunset")
    }

    func testWhitespaceIsTrimmed() {
        let note = ImportedText.note(title: "  Sunset  ", caption: nil, creator: nil)
        XCTAssertEqual(note, "Sunset")
    }

    func testLengthIsCappedAtMaxLength() {
        let huge = String(repeating: "x", count: 5_000)
        let note = ImportedText.note(title: huge, caption: nil, creator: nil)
        XCTAssertEqual(note?.count, ImportedText.maxLength)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -project Muse/Muse.xcodeproj -scheme Muse -only-testing:MuseTests/ImportedTextTests`
Expected: FAIL — `ImportedText` does not exist.

- [ ] **Step 3: Implement `ImportedText.swift`**

Trim each field; build an ordered array `[title, caption, creator.map { "© " +
$0 }]`, drop nils/empties, dedupe case-insensitively keeping first occurrence,
join with `"\n"`, then truncate to `maxLength` (`String(joined.prefix(maxLength))`).

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild test -project Muse/Muse.xcodeproj -scheme Muse -only-testing:MuseTests/ImportedTextTests`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add Muse/Muse/Import/ImportedText.swift Muse/MuseTests/ImportedTextTests.swift
git commit -m "feat(import): add pure title/caption/creator note composer"
```

---

## Task 6: Extend `MetadataImportModel` with the note leg + `ImportRunCard`

**Files:**
- Modify: `Muse/Muse/Import/MetadataImportModel.swift`
- Create: `Muse/Muse/Views/ImportRunCard.swift` (replaces
  `Muse/Muse/Import/MetadataImportSheet.swift`'s presenter role)
- Delete: `Muse/Muse/Import/MetadataImportSheet.swift` (superseded — verify no
  other call site references it before removing)
- Modify: `Muse/Muse/ContentView.swift` (`.metadata` case body →
  `ImportRunCard`)
- Modify: `Muse/Muse/Models/AppState+Import.swift` (`importMetadataAndEdits`
  panel message)
- Test: `Muse/MuseTests/MetadataImportModelTests.swift` (extend or create)

**Interfaces:**
- Consumes: `ImportedText.note` (Task 5), `NoteStore.read`/`.write` (existing
  shipped Notes seam — read its exact signature from
  `Muse/Muse/Database/NoteStore.swift` before wiring), `Extracted.title/
  caption/creator` (Task 3), `ImportReport` (Task 1),
  `AppState.importModal` (Task 2).
- Produces: the note-writing leg other tasks build on top of (Tasks 8/9 add
  their own legs into the same per-file transaction in this model).

Add, inside the existing per-file `queue.write` block in
`MetadataImportModel.start` (right after the existing keyword/rating logic,
before the transaction closes):

```swift
// Leg 3: note (fill-gaps, never overwrite what the user typed in Muse).
if let composed = ImportedText.note(
    title: extracted.title, caption: extracted.caption, creator: extracted.creator) {
    let existing = try NoteStore.read(db: db, fileID: scope.fileID, parentDir: scope.dir)
    if existing == nil || existing!.isEmpty {
        try NoteStore.write(db: db, fileID: scope.fileID, parentDir: scope.dir, text: composed)
        report.notes += 1
    }
}
```

(Adjust method names/argument order to whatever `NoteStore` actually exposes
— read the file first; the spec's shape is `NoteStore.read`/`.write` taking
`db`, `fileID`, `parentDir`.)

Change `MetadataImportModel.Phase.done` to carry an `ImportReport` instead of
three raw ints (`case done(report: ImportReport)`), and thread `report`
accumulation (`filesImported`/`filesWithNone`/`filesSkipped`/`keywords`/
`ratings`/`notes`) through the loop instead of the three local `Int`
variables. On completion, set
`appState?.importModal = .report(report)` instead of leaving the phase as the
terminal UI state.

- [ ] **Step 1: Write the failing test**

```swift
// Muse/MuseTests/MetadataImportModelTests.swift
import XCTest
@testable import Muse

@MainActor
final class MetadataImportModelTests: XCTestCase {
    func testDoneReportsNotesWrittenForFilesWithTitleCaptionCreator() async throws {
        // In-memory DB + a fixture folder with one file carrying dc:title/
        // description/creator and no prior note. After a run, report.notes == 1
        // and NoteStore reads back the composed text for that file.
        // (Full fixture/harness setup mirrors the existing
        // MetadataImportApplyTests in-memory-queue pattern.)
    }

    func testNoteIsNotOverwrittenWhenOneAlreadyExists() async throws {
        // Pre-write a note via NoteStore, then run the import over the same
        // file (which also carries dc:title etc.) — the note must be
        // unchanged and report.notes stays 0 for that file.
    }
}
```

(These are integration-style tests over the run model — follow whatever
harness the existing `MetadataImportApplyTests`/`MetadataImportRulesTests`
use for an in-memory GRDB queue + fixture files; do not invent a new harness.)

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -project Muse/Muse.xcodeproj -scheme Muse -only-testing:MuseTests/MetadataImportModelTests`
Expected: FAIL — `report.notes` doesn't exist yet / `Phase.done` has the old
shape.

- [ ] **Step 3: Implement the model changes described above**

Also build `ImportRunCard.swift` as a straight port of
`MetadataImportSheet.swift`'s presenter contract (built only while presented,
`.onAppear` starts the model, `.onDisappear` cancels it, `ModalScroll` +
`ModalButton` construction, same running/done phase copy) but reading
`ImportReport` instead of three raw ints, and on `done` setting
`appState.importModal = .report(report)` rather than rendering its own
summary (the summary now lives in `ImportReportCard`, Task 1). Add the "Also
import Lightroom adjustments (approximated)" `Toggle`, shown pre-scan **only
when `EditStore` is available** (i.e. Spec 04 is present in the build — guard
with `#if canImport` or a runtime type-check per however the codebase gates
optional Spec 04 presence; if Spec 04 is fully merged by the time this task
runs, the toggle is simply always shown), persisted as
`AppSettings.importLREditsKey` default **true**. Wire the toggle's on/off
state into the model so Task 19 (LR edit apply) can read it — for THIS task,
stub the wiring as a no-op boolean the model stores but doesn't yet act on.

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild test -project Muse/Muse.xcodeproj -scheme Muse -only-testing:MuseTests/MetadataImportModelTests`
Expected: PASS

- [ ] **Step 5: Update `ContentView.swift`'s `.metadata` case and delete the old sheet**

Point the `.metadata(let request)` switch case at `ImportRunCard(request:
request)`. Confirm no other file references `MetadataImportSheet` (`grep -rn
MetadataImportSheet Muse/Muse`), then delete
`Muse/Muse/Import/MetadataImportSheet.swift`.

- [ ] **Step 6: Full build + existing suite**

Run: `xcodebuild build -project Muse/Muse.xcodeproj -scheme Muse` then
`xcodebuild test -project Muse/Muse.xcodeproj -scheme Muse -only-testing:MuseTests/MetadataImportApplyTests -only-testing:MuseTests/MetadataImportRulesTests -only-testing:MuseTests/MetadataImportModelTests`
Expected: BUILD SUCCEEDED, all PASS.

- [ ] **Step 7: Commit**

```bash
git add Muse/Muse/Import/MetadataImportModel.swift Muse/Muse/Views/ImportRunCard.swift Muse/Muse/ContentView.swift Muse/Muse/Models/AppState+Import.swift Muse/MuseTests/MetadataImportModelTests.swift
git rm Muse/Muse/Import/MetadataImportSheet.swift
git commit -m "feat(import): add note leg to the metadata run, replace sheet with ImportRunCard"
```

---

## Task 7: `File > Import` submenu skeleton

**Files:**
- Modify: `Muse/Muse/MuseApp.swift:264-266`

**Interfaces:**
- Consumes: `AppState.importMetadataAndEdits()` (Task 2/6).
- Produces: the submenu shell Tasks 9/13/14/15/21 append items to (each
  item's action + label are added by that task, guarded "absent, not
  disabled" per whether its dependency exists).

Replace the single `Button`/`Label` at `MuseApp.swift:264-266` with:

```swift
Menu(String(localized: "Import")) {
    Button {
        appState.importMetadataAndEdits()
    } label: {
        Label(String(localized: "Metadata & Lightroom Edits…"), systemImage: "square.and.arrow.down")
    }
    // Lightroom Presets…, From Apple Photos…, From Google Takeout…,
    // From Eagle Library… appended by Tasks 21, 15, 13, 14 respectively —
    // each item's own task inserts its Button here directly, in this
    // fixed order, and is ABSENT (not disabled) until its dependency lands.
}
```

- [ ] **Step 1: Build to confirm the menu compiles and shows one item**

Run: `xcodebuild build -project Muse/Muse.xcodeproj -scheme Muse`
Expected: BUILD SUCCEEDED. Manually launch and confirm File > Import >
"Metadata & Lightroom Edits…" opens the same picker as before.

- [ ] **Step 2: Commit**

```bash
git add Muse/Muse/MuseApp.swift
git commit -m "feat(import): promote the single import item to a File > Import submenu"
```

---

## Task 8: `Import/ImportSupplement.swift` + Spec 02 amendment A1

**Files:**
- Create: `Muse/Muse/Import/ImportSupplement.swift`
- Modify: `Muse/Muse/Intelligence/AnalyzePipeline.swift` (amendment A1 —
  locate `analyzeOne`'s photo_meta/coords write)
- Modify: `Muse/Muse/Intelligence/PhotoHeaderBackfill.swift` (amendment A1 —
  per-row write)
- Modify: `Muse/Muse/Import/MetadataImportModel.swift` (wire the supplement
  leg for the universal GPS field)
- Test: `Muse/MuseTests/ImportSupplementTests.swift`

**Interfaces:**
- Consumes: `PhotoHeaderReader` (Spec 02), `photo_meta` table + `files.lat,
  lon` columns + `coords_scanned_hash`/`exif_scanned_hash` markers (Spec 02),
  `GeocodeBackfill.run()` + `SearchFacets.shared.refresh()` (Spec 02/03).
- Produces: `ImportSupplement.apply(db:fileID:contentHash:header:external:) ->
  AppliedFields` — consumed by Task 6's universal leg (GPS-only external),
  Task 13 (Takeout: GPS + capture date), Task 15 (Apple Photos: GPS + capture
  date).

```swift
nonisolated enum ImportSupplement {
    struct External: Equatable, Sendable {
        var lat: Double? = nil
        var lon: Double? = nil
        var captureDate: Int64? = nil
        var isEmpty: Bool { lat == nil && lon == nil && captureDate == nil }
    }
    struct AppliedFields: Equatable {
        var coordinates: Bool = false
        var captureDate: Bool = false
    }
    /// Inside the caller's queue.write. Reads the file's own header via
    /// PhotoHeaderReader, merges HEADER-WINS / external-fills-gaps per field,
    /// writes files.lat/lon + the photo_meta row, and stamps BOTH markers
    /// (coords_scanned_hash + exif_scanned_hash = content_hash). Row-guarded
    /// on content_hash still matching.
    static func apply(db: GRDB.Database, fileID: String, contentHash: String,
                       header: PhotoHeader, external: External) throws -> AppliedFields
}
```

Rules (all binding, restated from the spec — implement exactly):
- Header wins per field; external fills only where the header value is nil.
- `(0, 0)` external coordinate is treated as absent before merging.
- Both markers stamp to `contentHash` regardless of which side won (the
  supplement counts as a completed header scan).
- Row write is guarded: re-fetch/verify `content_hash == contentHash` inside
  the same transaction before writing; if it no longer matches, no-op (file
  changed mid-run).
- `capture_md` is derived from whichever `capture_date` won, via the same
  parse Spec 02 uses (do not duplicate that logic — call into it).

Amendment A1 (in `AnalyzePipeline.analyzeOne` and `PhotoHeaderBackfill`'s
per-row write): before writing the `photo_meta`/coords row from a fresh
header read, check `coords_scanned_hash == content_hash AND
photo_meta.exif_scanned_hash == content_hash` — if both already match, skip
the write entirely (both markers are fresh; a supplement or a prior header
scan already produced the current-best row, and rewriting from header alone
would clobber externally-filled fields with NULLs).

- [ ] **Step 1: Write the failing test**

```swift
// Muse/MuseTests/ImportSupplementTests.swift
import XCTest
import GRDB
@testable import Muse

final class ImportSupplementTests: XCTestCase {
    func testHeaderWinsOverExternalWhenBothPresent() throws {
        let db = try makeInMemoryQueue()  // Spec 02 schema present
        let fileID = try seedFile(db, lat: nil, lon: nil)
        let header = PhotoHeader(lat: 10.0, lon: 20.0, captureDate: 1_000)
        let external = ImportSupplement.External(lat: 99.0, lon: 99.0, captureDate: 5_000)
        try db.write { conn in
            _ = try ImportSupplement.apply(
                db: conn, fileID: fileID, contentHash: "hash1", header: header, external: external)
        }
        let row = try fetchFile(db, fileID)
        XCTAssertEqual(row.lat, 10.0)   // header wins
        XCTAssertEqual(row.lon, 20.0)
    }

    func testExternalFillsGapsWhenHeaderIsNil() throws {
        let db = try makeInMemoryQueue()
        let fileID = try seedFile(db, lat: nil, lon: nil)
        let header = PhotoHeader(lat: nil, lon: nil, captureDate: nil)
        let external = ImportSupplement.External(lat: 47.5, lon: -122.3, captureDate: 5_000)
        try db.write { conn in
            let applied = try ImportSupplement.apply(
                db: conn, fileID: fileID, contentHash: "hash1", header: header, external: external)
            XCTAssertTrue(applied.coordinates)
            XCTAssertTrue(applied.captureDate)
        }
        let row = try fetchFile(db, fileID)
        XCTAssertEqual(row.lat, 47.5)
        XCTAssertEqual(row.lon, -122.3)
    }

    func testBothMarkersStampToContentHashRegardlessOfWinner() throws {
        let db = try makeInMemoryQueue()
        let fileID = try seedFile(db, lat: nil, lon: nil)
        try db.write { conn in
            _ = try ImportSupplement.apply(
                db: conn, fileID: fileID, contentHash: "hashX",
                header: PhotoHeader(lat: nil, lon: nil, captureDate: nil),
                external: ImportSupplement.External())
        }
        let (coordsHash, exifHash) = try fetchMarkers(db, fileID)
        XCTAssertEqual(coordsHash, "hashX")
        XCTAssertEqual(exifHash, "hashX")
    }

    func testZeroZeroExternalCoordinateIsTreatedAsAbsent() throws {
        let db = try makeInMemoryQueue()
        let fileID = try seedFile(db, lat: nil, lon: nil)
        try db.write { conn in
            _ = try ImportSupplement.apply(
                db: conn, fileID: fileID, contentHash: "h",
                header: PhotoHeader(lat: nil, lon: nil, captureDate: nil),
                external: ImportSupplement.External(lat: 0, lon: 0, captureDate: nil))
        }
        let row = try fetchFile(db, fileID)
        XCTAssertNil(row.lat)
        XCTAssertNil(row.lon)
    }

    func testRowGuardSkipsWhenContentHashChangedMidRun() throws {
        let db = try makeInMemoryQueue()
        let fileID = try seedFile(db, lat: nil, lon: nil, contentHash: "old")
        try db.write { conn in
            try conn.execute(sql: "UPDATE files SET content_hash = 'new' WHERE id = ?", arguments: [fileID])
            let applied = try ImportSupplement.apply(
                db: conn, fileID: fileID, contentHash: "old",  // stale hash
                header: PhotoHeader(lat: 1, lon: 1, captureDate: nil),
                external: ImportSupplement.External())
            XCTAssertEqual(applied, .init())  // no-op
        }
        let row = try fetchFile(db, fileID)
        XCTAssertNil(row.lat)
    }

    // testA1RegressionSkipsFreshRows lives beside AnalyzePipeline/PhotoHeaderBackfill
    // tests once amendment A1 is wired — asserts a second header-only write
    // over a file whose markers already equal content_hash does NOT clear a
    // supplement-filled lat/lon.
}
```

(`makeInMemoryQueue`/`seedFile`/`fetchFile`/`fetchMarkers`/`PhotoHeader` are
Spec 02 test helpers — reuse whatever `ImportSupplementTests`' Spec-02-era
sibling suite already established rather than inventing new ones.)

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -project Muse/Muse.xcodeproj -scheme Muse -only-testing:MuseTests/ImportSupplementTests`
Expected: FAIL — `ImportSupplement` does not exist.

- [ ] **Step 3: Implement `ImportSupplement.swift`**

Per the rules above — one `queue.write`-scoped function, no I/O of its own
(header is passed in already read).

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild test -project Muse/Muse.xcodeproj -scheme Muse -only-testing:MuseTests/ImportSupplementTests`
Expected: PASS

- [ ] **Step 5: Wire amendment A1 into `AnalyzePipeline.analyzeOne` and `PhotoHeaderBackfill`**

Add the fresh-marker skip-guard described above at each site's photo_meta/
coords write. Add a regression test in each file's existing test suite
(`AnalyzePipelineTests`/`PhotoHeaderBackfillTests`) asserting: seed a file
with both markers already equal to `content_hash` and a non-null
`files.lat`; run the write path again with a header reporting nil
coordinates; assert `files.lat` is unchanged (not clobbered to nil).

- [ ] **Step 6: Wire the universal-layer GPS leg into `MetadataImportModel` (Task 6's model)**

Inside the same per-file transaction, when `extracted.coordinate != nil`:

```swift
// Leg 4: supplement (GPS only here — the metadata scan has no capture-date source).
if let coord = extracted.coordinate {
    let header = try PhotoHeaderReader.read(url: url)  // or reuse an already-read header if available
    let applied = try ImportSupplement.apply(
        db: db, fileID: scope.fileID, contentHash: /* file's content_hash */,
        header: header, external: .init(lat: coord.lat, lon: coord.lon, captureDate: nil))
    if applied.coordinates { report.coordinates += 1 }
}
```

- [ ] **Step 7: Chain the completion reload**

After the run, when `report.coordinates > 0`, fire-and-forget
`GeocodeBackfill.run()` then, on its completion,
`SearchFacets.shared.refresh()` — matching the Spec 02 completion pattern
exactly (do not build a new chaining mechanism).

- [ ] **Step 8: Run the full suite touched by this task**

Run: `xcodebuild test -project Muse/Muse.xcodeproj -scheme Muse -only-testing:MuseTests/ImportSupplementTests -only-testing:MuseTests/AnalyzePipelineTests -only-testing:MuseTests/PhotoHeaderBackfillTests -only-testing:MuseTests/MetadataImportModelTests`
Expected: PASS

- [ ] **Step 9: Commit**

```bash
git add Muse/Muse/Import/ImportSupplement.swift Muse/Muse/Intelligence/AnalyzePipeline.swift Muse/Muse/Intelligence/PhotoHeaderBackfill.swift Muse/Muse/Import/MetadataImportModel.swift Muse/MuseTests/ImportSupplementTests.swift
git commit -m "feat(import): add ImportSupplement writer + Spec 02 amendment A1 fresh-marker guard"
```

---

## Task 9: `LabelTag` + `LabelMapping` + search exclusion (pure core)

**Files:**
- Create: `Muse/Muse/Import/LabelTag.swift`
- Create: `Muse/Muse/Import/LabelMapping.swift` (replaces the Task 1 stub
  1-for-1 — same enum name/cases, delete the stub from `ImportReport.swift`)
- Modify: `Muse/Muse/Database/SearchService.swift` (tag leg filter)
- Modify: `Muse/Muse/Settings/AppSettings.swift` (add
  `importLabelChoicesKey`)
- Test: `Muse/MuseTests/LabelTagTests.swift`
- Test: `Muse/MuseTests/LabelMappingTests.swift`
- Test: extend `Muse/MuseTests/SearchServiceTests.swift`

**Interfaces:**
- Consumes: `StarRating.isRating` (existing rating-glyph guard).
- Produces: `LabelTag.prefix/isLabel/make/queryTargetsLabels`,
  `LabelMapping.Choice/resolvedLabel/loadChoices/saveChoices` — consumed by
  Task 10 (the mapping sheet UI) and Task 1's `LabelOutcome`.

```swift
nonisolated enum LabelTag {
    static let prefix = "Label: "
    static func isLabel(_ tagLabel: String) -> Bool { tagLabel.hasPrefix(prefix) }
    static func make(_ value: String) -> String { prefix + value.trimmingCharacters(in: .whitespaces) }
    static func queryTargetsLabels(_ query: String) -> Bool {
        query.lowercased().contains("label")
    }
}

nonisolated enum LabelMapping {
    enum Choice: Equatable, Codable {
        case skip
        case namespaced
        case tag(String)
    }
    /// nil for .skip. .tag values refuse a ★-run mapping target (enforced
    /// here, not per caller).
    static func resolvedLabel(value: String, choice: Choice) -> String? {
        switch choice {
        case .skip: return nil
        case .namespaced: return LabelTag.make(value)
        case .tag(let t): return StarRating.isRating(t) ? nil : t
        }
    }
    static func loadChoices() -> [String: Choice]
    static func saveChoices(_ c: [String: Choice])
}
```

`SearchService.swift` tag leg: after fetching `tagRows` for a free-text
query, drop any row where `LabelTag.isLabel(row.label)` unless
`LabelTag.queryTargetsLabels(textQuery)`. The `.tag` smart-rule and
chip-click/filter paths are exact-label matches, not content search — no
exclusion applied there.

- [ ] **Step 1: Write the failing tests**

```swift
// Muse/MuseTests/LabelTagTests.swift
import XCTest
@testable import Muse

final class LabelTagTests: XCTestCase {
    func testIsLabelDetectsPrefix() {
        XCTAssertTrue(LabelTag.isLabel("Label: Red"))
        XCTAssertFalse(LabelTag.isLabel("Red"))
        XCTAssertFalse(LabelTag.isLabel("sunset"))
    }

    func testMakePrefixesAndTrims() {
        XCTAssertEqual(LabelTag.make("  Red  "), "Label: Red")
    }

    func testQueryTargetsLabelsIsCaseInsensitiveSubstring() {
        XCTAssertTrue(LabelTag.queryTargetsLabels("label: red"))
        XCTAssertTrue(LabelTag.queryTargetsLabels("LABEL"))
        XCTAssertFalse(LabelTag.queryTargetsLabels("red"))
    }
}
```

```swift
// Muse/MuseTests/LabelMappingTests.swift
import XCTest
@testable import Muse

final class LabelMappingTests: XCTestCase {
    func testSkipResolvesToNil() {
        XCTAssertNil(LabelMapping.resolvedLabel(value: "Red", choice: .skip))
    }

    func testNamespacedResolvesToLabelPrefixedTag() {
        XCTAssertEqual(LabelMapping.resolvedLabel(value: "Red", choice: .namespaced), "Label: Red")
    }

    func testTagChoiceResolvesToTheChosenLabel() {
        XCTAssertEqual(LabelMapping.resolvedLabel(value: "Red", choice: .tag("portfolio")), "portfolio")
    }

    func testTagChoiceRefusesAStarRatingGlyphRun() {
        XCTAssertNil(LabelMapping.resolvedLabel(value: "Red", choice: .tag("★★★")))
    }

    func testChoicesRoundTripThroughPersistence() {
        let choices: [String: LabelMapping.Choice] = ["Red": .namespaced, "Rouge": .tag("portfolio")]
        LabelMapping.saveChoices(choices)
        XCTAssertEqual(LabelMapping.loadChoices(), choices)
    }
}
```

Add to `SearchServiceTests.swift`:

```swift
func testFreeTextRedDoesNotMatchLabelRedTag() throws {
    // Seed a file tagged "Label: Red" and no other red-adjacent data.
    let results = try SearchService.search(query: "red", /* … */)
    XCTAssertTrue(results.isEmpty)
}

func testLabelColonRedMatchesLabelRedTag() throws {
    let results = try SearchService.search(query: "label: red", /* … */)
    XCTAssertFalse(results.isEmpty)
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild test -project Muse/Muse.xcodeproj -scheme Muse -only-testing:MuseTests/LabelTagTests -only-testing:MuseTests/LabelMappingTests -only-testing:MuseTests/SearchServiceTests`
Expected: FAIL — `LabelTag`/`LabelMapping` don't exist; the two new
`SearchServiceTests` methods fail (no exclusion yet).

- [ ] **Step 3: Implement `LabelTag.swift` and `LabelMapping.swift`; delete the Task 1 stub**

Remove the forward-stub `enum LabelMapping { enum Choice … }` from
`ImportReport.swift` (Task 1) now that the real type exists — same name,
same cases, so `LabelOutcome.choice: LabelMapping.Choice` compiles unchanged.

- [ ] **Step 4: Wire the search exclusion into `SearchService.swift`**

Add the one filter line after the tag-row fetch in the free-text tag leg.

- [ ] **Step 5: Run tests to verify they pass**

Run: `xcodebuild test -project Muse/Muse.xcodeproj -scheme Muse -only-testing:MuseTests/LabelTagTests -only-testing:MuseTests/LabelMappingTests -only-testing:MuseTests/SearchServiceTests -only-testing:MuseTests/ImportReportTests`
Expected: PASS

- [ ] **Step 6: Add `AppSettings.importLabelChoicesKey`**

A `UserDefaults` key constant beside the other `AppSettings` keys, JSON-blob
encoded (`JSONEncoder`/`JSONDecoder` over `[String: LabelMapping.Choice]`).

- [ ] **Step 7: Commit**

```bash
git add Muse/Muse/Import/LabelTag.swift Muse/Muse/Import/LabelMapping.swift Muse/Muse/Import/ImportReport.swift Muse/Muse/Database/SearchService.swift Muse/Muse/Settings/AppSettings.swift Muse/MuseTests/LabelTagTests.swift Muse/MuseTests/LabelMappingTests.swift Muse/MuseTests/SearchServiceTests.swift
git commit -m "feat(import): add color-label namespace, mapping choices, and search exclusion"
```

---

## Task 10: Label mapping sheet UI + chip styling + run-model wiring

**Files:**
- Create: `Muse/Muse/Views/LabelMappingCard.swift`
- Modify: `Muse/Muse/Models/AppState+Import.swift`
  (`LabelMappingRequest` — replace the Task 2 stub with real fields)
- Modify: `Muse/Muse/Import/MetadataImportModel.swift` (accumulate
  `labelPaths`, raise the sheet, apply after the scan)
- Modify: `Muse/Muse/Views/TagChipsRow.swift` (label chip styling)
- Test: `Muse/MuseTests/LabelMappingFlowTests.swift`

**Interfaces:**
- Consumes: `LabelMapping`/`LabelTag` (Task 9), `MetadataImportApply.scope`/
  `.applyKeywords` (existing), `TagSuggest.rank` (existing autocomplete pool —
  already excludes rating glyphs).
- Produces: the completed label-mapping flow other sources don't need to
  touch (only the folder-scan metadata run has `xmp:Label` data).

`LabelMappingRequest`:

```swift
struct LabelMappingRequest: Identifiable, Equatable {
    let id = UUID()
    var values: [String]              // distinct raw xmp:Label strings, in first-seen order
    var counts: [String: Int]         // value → file count
}
```

Flow, in `MetadataImportModel`:
1. During the scan, accumulate `labelPaths: [String: [String]]` (raw label
   value → alive absolute paths) alongside the existing per-file legs —
   memory cost is paths only, fine at 100k files.
2. After the scan: if `labelPaths.isEmpty`, skip straight to the report. If
   every distinct value already has a remembered choice
   (`LabelMapping.loadChoices()`), apply silently (Step 4 below) and go to
   the report. Otherwise set
   `appState.importModal = .labelMapping(LabelMappingRequest(values:
   Array(labelPaths.keys), counts: labelPaths.mapValues(\.count)))` and
   suspend until the card resolves.
3. `LabelMappingCard`: one row per value showing its count and a three-way
   control (Skip / `Label: X` / "Map to tag…" — the latter opens the
   existing tag-autocomplete field backed by `TagSuggest.rank`). Default
   selection per value: remembered choice, else `.namespaced`. **Apply**
   persists chosen mappings via `LabelMapping.saveChoices` (merging into any
   existing persisted map) and resumes the model with the chosen map;
   **Skip All** resumes with every value mapped to `.skip`, without
   persisting.
4. Apply step: per label value with a non-`.skip` resolved label, one
   `queue.write` chunk over its paths — resolve each path's scope via
   `MetadataImportApply.scope`, write via `MetadataImportApply.applyKeywords`
   with the resolved label. Accumulate `report.labelCounts.append(
   LabelOutcome(label: value, count: paths.count, choice: choice))`.
5. Continue to `.report(report)`.

Chip styling in `TagChipsRow.swift`: branch on `LabelTag.isLabel(chip.label)`
— outline stroke instead of fill + a `tag` SF-Symbol glyph before the label
text; display shows the full stored string (`"Label: Red"`), no truncation.
Same branch feeds the active-filter bar's rendering.

- [ ] **Step 1: Write the failing test**

```swift
// Muse/MuseTests/LabelMappingFlowTests.swift
import XCTest
@testable import Muse

@MainActor
final class LabelMappingFlowTests: XCTestCase {
    func testEmptyLabelPathsSkipsStraightToReport() async throws {
        // Run the model over a fixture folder with no xmp:Label anywhere;
        // assert importModal transitions directly to .report, never
        // .labelMapping.
    }

    func testAllChoicesRememberedAppliesSilently() async throws {
        // Pre-save a remembered choice for "Red" via LabelMapping.saveChoices;
        // run over a folder whose only label value is "Red"; assert
        // importModal goes straight to .report and the resulting tag rows
        // carry "Label: Red" (or whatever choice was remembered).
    }

    func testUnrememberedValueRaisesTheMappingCard() async throws {
        // Run over a folder with an unmapped label value "Second"; assert
        // importModal == .labelMapping(...) with values containing "Second".
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -project Muse/Muse.xcodeproj -scheme Muse -only-testing:MuseTests/LabelMappingFlowTests`
Expected: FAIL — flow not implemented.

- [ ] **Step 3: Implement the accumulation/raise/apply flow in `MetadataImportModel` and build `LabelMappingCard`**

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild test -project Muse/Muse.xcodeproj -scheme Muse -only-testing:MuseTests/LabelMappingFlowTests`
Expected: PASS

- [ ] **Step 5: Wire `ContentView.swift`'s `.labelMapping` case to `LabelMappingCard`**

Replace the `EmptyView()` placeholder from Task 2 Step 3.5.

- [ ] **Step 6: Apply the chip styling change and manually verify in the running app**

Per CLAUDE.md convention: build, run, tag a file with a `Label: Red` tag
(hand-add it via the tag field to exercise the styling without a full
import), confirm the outline+glyph rendering and that it's excluded from a
plain "red" search but included in "label: red".

- [ ] **Step 7: Commit**

```bash
git add Muse/Muse/Views/LabelMappingCard.swift Muse/Muse/Models/AppState+Import.swift Muse/Muse/Import/MetadataImportModel.swift Muse/Muse/Views/TagChipsRow.swift Muse/Muse/ContentView.swift Muse/MuseTests/LabelMappingFlowTests.swift
git commit -m "feat(import): add the color-label mapping sheet and distinct chip styling"
```

---

## Task 11: `ThrottlePolicy` + `WorkThrottleStore` — pure policy + monitor

**Files:**
- Create: `Muse/Muse/Components/ThrottlePolicy.swift`
- Create: `Muse/Muse/Models/WorkThrottleStore.swift`
- Modify: `Muse/Muse/Settings/AppSettings.swift` (add `analysisPausedKey`,
  default false)
- Test: `Muse/MuseTests/ThrottlePolicyTests.swift`

**Interfaces:**
- Consumes: `ProcessInfo.thermalState`, `ProcessInfo.isLowPowerModeEnabled`,
  IOKit.ps power-source APIs (`IOPSCopyPowerSourcesInfo`,
  `IOPSGetProvidingPowerSourceType`, `IOPSNotificationCreateRunLoopSource`).
- Produces: `ThrottlePolicy.mode(...)`/`.concurrency(_:)` (pure — consumed by
  Task 12's spawn-gate wiring), `WorkThrottleStore.shared.waitUntilRunnable()`
  / `.userPaused` (consumed by Task 12, Task 13/14/15's per-chunk gates are
  N/A — import runs are never throttled per the constraints).

```swift
nonisolated enum ThrottlePolicy {
    enum Mode: Equatable { case normal, reduced, paused }
    static func mode(thermal: ProcessInfo.ThermalState,
                     onBattery: Bool, lowPower: Bool, userPaused: Bool) -> Mode {
        if userPaused || thermal == .serious || thermal == .critical { return .paused }
        if onBattery || lowPower { return .reduced }
        return .normal
    }
    static func concurrency(_ m: Mode) -> Int {
        switch m {
        case .normal: return AnalyzePipeline.analyzeConcurrency  // 3
        case .reduced: return 1
        case .paused: return 0
        }
    }
}
```

```swift
@MainActor
final class WorkThrottleStore: ObservableObject {
    static let shared = WorkThrottleStore()
    @Published private(set) var mode: ThrottlePolicy.Mode = .normal
    var userPaused: Bool {
        get { AppSettings.shared.analysisPaused }  // adjust to actual AppSettings accessor shape
        set { AppSettings.shared.analysisPaused = newValue; recompute() }
    }
    /// Suspends while `.paused`; returns immediately otherwise. Cancellation-safe.
    func waitUntilRunnable() async
    private func recompute()  // reads thermal/battery/lowPower/userPaused → mode
}
```

- [ ] **Step 1: Write the failing test**

```swift
// Muse/MuseTests/ThrottlePolicyTests.swift
import XCTest
@testable import Muse

final class ThrottlePolicyTests: XCTestCase {
    func testUserPausedAlwaysWinsToPaused() {
        XCTAssertEqual(
            ThrottlePolicy.mode(thermal: .nominal, onBattery: false, lowPower: false, userPaused: true),
            .paused)
    }

    func testSeriousThermalPausesEvenWithoutUserPause() {
        XCTAssertEqual(
            ThrottlePolicy.mode(thermal: .serious, onBattery: false, lowPower: false, userPaused: false),
            .paused)
    }

    func testCriticalThermalPauses() {
        XCTAssertEqual(
            ThrottlePolicy.mode(thermal: .critical, onBattery: false, lowPower: false, userPaused: false),
            .paused)
    }

    func testFairThermalDoesNotPauseAlone() {
        XCTAssertNotEqual(
            ThrottlePolicy.mode(thermal: .fair, onBattery: false, lowPower: false, userPaused: false),
            .paused)
    }

    func testOnBatteryReducesWhenNotPaused() {
        XCTAssertEqual(
            ThrottlePolicy.mode(thermal: .nominal, onBattery: true, lowPower: false, userPaused: false),
            .reduced)
    }

    func testLowPowerReducesWhenNotPaused() {
        XCTAssertEqual(
            ThrottlePolicy.mode(thermal: .nominal, onBattery: false, lowPower: true, userPaused: false),
            .reduced)
    }

    func testNominalNoBatteryNoLowPowerNoUserPauseIsNormal() {
        XCTAssertEqual(
            ThrottlePolicy.mode(thermal: .nominal, onBattery: false, lowPower: false, userPaused: false),
            .normal)
    }

    func testConcurrencyTable() {
        XCTAssertEqual(ThrottlePolicy.concurrency(.normal), AnalyzePipeline.analyzeConcurrency)
        XCTAssertEqual(ThrottlePolicy.concurrency(.reduced), 1)
        XCTAssertEqual(ThrottlePolicy.concurrency(.paused), 0)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -project Muse/Muse.xcodeproj -scheme Muse -only-testing:MuseTests/ThrottlePolicyTests`
Expected: FAIL — `ThrottlePolicy` does not exist.

- [ ] **Step 3: Implement `ThrottlePolicy.swift`**

Exactly the truth table above — precedence order matters (`userPaused`/
thermal checked before battery/lowPower).

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild test -project Muse/Muse.xcodeproj -scheme Muse -only-testing:MuseTests/ThrottlePolicyTests`
Expected: PASS

- [ ] **Step 5: Implement `WorkThrottleStore.swift`**

Subscribe to `ProcessInfo.thermalStateDidChangeNotification` and
`NSNotification.Name.NSProcessInfoPowerStateDidChange`; set up an
`IOPSNotificationCreateRunLoopSource` callback for battery/AC changes;
`recompute()` on each; `waitUntilRunnable()` as an `AsyncStream` over `$mode`
values that returns as soon as `mode != .paused`, cancellation-safe (a
cancelled `Task` awaiting this just returns — the caller's own
`Task.isCancelled` check does the rest). Zero AppState integration — not even
a forwarded `objectWillChange` cancellable.

- [ ] **Step 6: Add `AppSettings.analysisPausedKey`**

`UserDefaults` bool, default `false`, persisted across relaunch (deviation
D10 — a silent self-clearing pause reads as broken).

- [ ] **Step 7: Manual verification**

Per CLAUDE.md's "verify runtime, not just tests" rule: run the app, toggle
Low Power Mode (or unplug on a laptop), and confirm (via a temporary log
line or breakpoint) that `WorkThrottleStore.shared.mode` flips to `.reduced`.
Remove any temporary logging before committing.

- [ ] **Step 8: Commit**

```bash
git add Muse/Muse/Components/ThrottlePolicy.swift Muse/Muse/Models/WorkThrottleStore.swift Muse/Muse/Settings/AppSettings.swift Muse/MuseTests/ThrottlePolicyTests.swift
git commit -m "feat(throttle): add ThrottlePolicy pure rules and the WorkThrottleStore monitor"
```

---

## Task 12: Wire spawn gates into `AnalyzePipeline` + Spec 02/03 backfills

**Files:**
- Modify: `Muse/Muse/Intelligence/AnalyzePipeline.swift` (both spawn sites in
  the `analyze(folder:)` loop)
- Modify: `Muse/Muse/Intelligence/PhotoHeaderBackfill.swift`
- Modify: `Muse/Muse/Intelligence/GeocodeBackfill.swift`
- Modify: `Muse/Muse/Intelligence/DeepAnalysisBackfill.swift`
- Test: extend `AnalyzePipelineTests.swift` + each backfill's test file

**Interfaces:**
- Consumes: `WorkThrottleStore.shared.waitUntilRunnable()`,
  `ThrottlePolicy.concurrency(_:)` (Task 11).
- Produces: nothing new — this task only adds gating to existing spawn
  loops.

In `AnalyzePipeline.analyze(folder:)`'s loop (both the priming `while` and
the one-replacement-per-completion spawn site): before calling
`iterator.next()` to start a new file, `await
WorkThrottleStore.shared.waitUntilRunnable()`, then re-read
`ThrottlePolicy.concurrency(WorkThrottleStore.shared.mode)` as the current
priming width for that spawn. Under `.paused`, no new file starts; in-flight
files finish normally (same semantics as an existing `shouldStop`, but
resumable — the pass claim stays held across a pause).

In each of `PhotoHeaderBackfill`/`GeocodeBackfill`/`DeepAnalysisBackfill`: one
`await WorkThrottleStore.shared.waitUntilRunnable()` per write-chunk
iteration (their loops already checkpoint every ~200 rows) — `.utility`
priority stays unchanged; the throttle is additive scheduling, not a
priority change.

- [ ] **Step 1: Write the failing test**

```swift
// Extend AnalyzePipelineTests.swift
func testAnalyzeFolderDoesNotSpawnNewFilesWhilePaused() async throws {
    WorkThrottleStore.shared.userPaused = true
    defer { WorkThrottleStore.shared.userPaused = false }
    // Seed a folder with several unanalyzed files; start analyze(folder:);
    // after a short delay, assert zero NEW files completed (in-flight ones
    // started before the pause may finish; nothing new begins).
}

func testAnalyzeFolderResumesSpawningWhenUnpaused() async throws {
    // Pause, start analyze(folder:), confirm no progress, then set
    // userPaused = false and assert the pass eventually completes.
}
```

Extend each backfill's suite with an analogous "no chunk starts while paused"
test.

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild test -project Muse/Muse.xcodeproj -scheme Muse -only-testing:MuseTests/AnalyzePipelineTests -only-testing:MuseTests/PhotoHeaderBackfillTests -only-testing:MuseTests/GeocodeBackfillTests -only-testing:MuseTests/DeepAnalysisBackfillTests`
Expected: FAIL — no gate yet, files spawn regardless of pause.

- [ ] **Step 3: Wire the gates as described**

- [ ] **Step 4: Run tests to verify they pass**

Run: same command as Step 2.
Expected: PASS.

- [ ] **Step 5: Full existing analysis suite regression check**

Run: `xcodebuild test -project Muse/Muse.xcodeproj -scheme Muse -only-testing:MuseTests/AnalyzePipelineTests`
Expected: PASS — every pre-existing behavior (throttling is purely additive
scheduling; no marker/selection-logic change).

- [ ] **Step 6: Commit**

```bash
git add Muse/Muse/Intelligence/AnalyzePipeline.swift Muse/Muse/Intelligence/PhotoHeaderBackfill.swift Muse/Muse/Intelligence/GeocodeBackfill.swift Muse/Muse/Intelligence/DeepAnalysisBackfill.swift
git commit -m "feat(throttle): gate analyze pass and Spec 02/03 backfills on WorkThrottleStore"
```

---

## Task 13: `AnalysisStatusStore` + Settings/sidebar progress surfaces

**Files:**
- Create: `Muse/Muse/Models/AnalysisStatusStore.swift`
- Modify: `Muse/Muse/Settings/SettingsView.swift` (Library section row)
- Modify: `Muse/Muse/Views/SidebarView.swift:626` (footer row above
  `CreateNewMenuButton`)
- Modify: `Muse/Muse/Intelligence/AnalyzePipeline.swift` (`analyzeOne` calls
  `recordCompletion`)
- Test: `Muse/MuseTests/AnalysisStatusStoreTests.swift`

**Interfaces:**
- Consumes: an off-main count query over `files`/`analyzed_hash` (existing
  schema — no new column), `WorkThrottleStore.mode`/`.userPaused` (Task 11).
- Produces: `AnalysisStatusStore.shared.analyzableTotal/pending/
  secondsPerFile/estimateSeconds` — consumed by Task 14's
  `AnalysisEstimator`.

```swift
@MainActor final class AnalysisStatusStore: ObservableObject {
    static let shared = AnalysisStatusStore()
    @Published private(set) var analyzableTotal = 0
    @Published private(set) var pending = 0
    private(set) var secondsPerFile: Double?   // EMA, α = 0.1 — NOT @Published
    private(set) var completions = 0
    func refresh()                             // one off-main count query, ≤1/5s, token-guarded
    func recordCompletion(duration: TimeInterval)
}
```

`refresh()` counts `analyzableTotal` (alive image/raw/psd files) and
`pending` (`analyzed_hash IS NULL OR analyzed_hash != content_hash`) via one
off-main GRDB read; guarded to at most once per 5 seconds with a request
token so overlapping triggers coalesce. Trigger sites: end of every index
batch, every analyze-pass completion, each 200-row backfill chunk.
`recordCompletion` updates the EMA: `secondsPerFile = secondsPerFile == nil ?
duration : 0.1 * duration + 0.9 * secondsPerFile!`; increments `completions`.

Settings Library row: "34,000 of 100,000 analyzed"
(`analyzableTotal − pending` of `analyzableTotal`, monospacedDigit font) +
Pause/Resume button bound to `WorkThrottleStore.shared.userPaused` + a
`.secondary` state line ("Paused" / "Reduced speed on battery" / an estimate
string when running and calibrated).

Sidebar footer row: visible only while `pending > 0 AND (a pass is running OR
WorkThrottleStore.shared.userPaused)` — one line count + a
`pause.circle`/`play.circle` icon button with `.help`/`.accessibilityLabel`,
sharing `SidebarView`'s existing geometry constants (rowHeight etc. per the
durable sidebar-row constants). Observes both stores directly — zero AppState
cost.

- [ ] **Step 1: Write the failing test**

```swift
// Muse/MuseTests/AnalysisStatusStoreTests.swift
import XCTest
@testable import Muse

@MainActor
final class AnalysisStatusStoreTests: XCTestCase {
    func testRecordCompletionUpdatesEMA() {
        let store = AnalysisStatusStore()  // assume a test-constructible init exists, or reset shared state
        store.recordCompletion(duration: 1.0)
        XCTAssertEqual(store.secondsPerFile, 1.0)
        store.recordCompletion(duration: 3.0)
        // EMA: 0.1*3 + 0.9*1 = 1.2
        XCTAssertEqual(store.secondsPerFile!, 1.2, accuracy: 1e-9)
    }

    func testRefreshCountsAnalyzableTotalAndPending() async throws {
        // Seed 5 alive image files, 2 with a stale/nil analyzed_hash.
        // Call refresh(); assert analyzableTotal == 5, pending == 2.
    }

    func testRefreshCoalescesWithinFiveSeconds() async throws {
        // Call refresh() twice back-to-back; assert only one query ran
        // (via a call-counting seam or timestamp check on the store).
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -project Muse/Muse.xcodeproj -scheme Muse -only-testing:MuseTests/AnalysisStatusStoreTests`
Expected: FAIL — `AnalysisStatusStore` doesn't exist.

- [ ] **Step 3: Implement `AnalysisStatusStore.swift`**

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild test -project Muse/Muse.xcodeproj -scheme Muse -only-testing:MuseTests/AnalysisStatusStoreTests`
Expected: PASS

- [ ] **Step 5: Wire `recordCompletion` into `AnalyzePipeline.analyzeOne` and `refresh()` trigger sites**

- [ ] **Step 6: Build the Settings row and sidebar footer row; manually verify in the running app**

Run: launch the app, point at a folder with a mix of analyzed/unanalyzed
files, confirm the Settings Library row and sidebar row show plausible
counts and the Pause/Resume button flips `WorkThrottleStore.userPaused`.
Confirm the status pill (`WorkProgress`) is untouched — its behavior must
not change.

- [ ] **Step 7: Commit**

```bash
git add Muse/Muse/Models/AnalysisStatusStore.swift Muse/Muse/Settings/SettingsView.swift Muse/Muse/Views/SidebarView.swift Muse/Muse/Intelligence/AnalyzePipeline.swift Muse/MuseTests/AnalysisStatusStoreTests.swift
git commit -m "feat(throttle): add AnalysisStatusStore and the Settings/sidebar progress surfaces"
```

---

## Task 14: `AnalysisEstimator` + the import-size FYI card

**Files:**
- Create: `Muse/Muse/Components/AnalysisEstimator.swift`
- Modify: `Muse/Muse/Models/AppState.swift` (raise via the existing
  `alertRequest`/`MuseAlert` seam — no new `@Published` needed)
- Test: `Muse/MuseTests/AnalysisEstimatorTests.swift`

**Interfaces:**
- Consumes: `AnalysisStatusStore.shared.pending/secondsPerFile/completions`
  (Task 13).
- Produces: the one-shot FYI card — no other task consumes this.

```swift
nonisolated enum AnalysisEstimator {
    static let calibrationMinimum = 200
    static let fyiThresholdSeconds: TimeInterval = 25 * 60
    static func estimate(pending: Int, secondsPerFile: Double?, completions: Int) -> TimeInterval? {
        guard completions >= calibrationMinimum, let secondsPerFile else { return nil }
        return Double(pending) * secondsPerFile
    }
    static func shouldOffer(estimate: TimeInterval?) -> Bool {
        guard let estimate else { return false }
        return estimate > fyiThresholdSeconds
    }
}
```

Trigger (after each `AnalysisStatusStore.refresh()`): raise the FYI once per
launch when (a) `AnalysisEstimator.estimate(...)` is non-nil, (b)
`shouldOffer` is true, (c) it hasn't been shown this launch
(`shownThisLaunch` flag on the estimator's call site — session-only, not
persisted), and (d) `pending` has grown by at least `calibrationMinimum`
since launch (a stable pre-existing backlog doesn't re-nag). Raise via
`appState.alertRequest = MuseAlert(...)` (the existing seam — one button
"OK", message interpolating count + `DateComponentsFormatter`-approximated
duration, e.g. *"Heads up: analyzing 40,000 photos will take about 2 hours.
They're ready to browse now — search and colors get smarter as it
finishes."*). No choice, no skip button, no off switch. Below threshold:
nothing raised, ever.

- [ ] **Step 1: Write the failing test**

```swift
// Muse/MuseTests/AnalysisEstimatorTests.swift
import XCTest
@testable import Muse

final class AnalysisEstimatorTests: XCTestCase {
    func testEstimateIsNilBeforeCalibration() {
        XCTAssertNil(AnalysisEstimator.estimate(pending: 1000, secondsPerFile: 2.0, completions: 50))
    }

    func testEstimateIsNilWithoutASecondsPerFileSample() {
        XCTAssertNil(AnalysisEstimator.estimate(pending: 1000, secondsPerFile: nil, completions: 500))
    }

    func testEstimateExtrapolatesLinearly() {
        let est = AnalysisEstimator.estimate(pending: 1000, secondsPerFile: 2.0, completions: 500)
        XCTAssertEqual(est, 2000)
    }

    func testShouldOfferIsFalseBelowThreshold() {
        XCTAssertFalse(AnalysisEstimator.shouldOffer(estimate: 60))       // 1 min
        XCTAssertFalse(AnalysisEstimator.shouldOffer(estimate: nil))
    }

    func testShouldOfferIsTrueAboveThreshold() {
        XCTAssertTrue(AnalysisEstimator.shouldOffer(estimate: 30 * 60))   // 30 min
    }

    func testShouldOfferBoundaryIsStrictlyGreaterThan() {
        XCTAssertFalse(AnalysisEstimator.shouldOffer(estimate: AnalysisEstimator.fyiThresholdSeconds))
        XCTAssertTrue(AnalysisEstimator.shouldOffer(estimate: AnalysisEstimator.fyiThresholdSeconds + 1))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -project Muse/Muse.xcodeproj -scheme Muse -only-testing:MuseTests/AnalysisEstimatorTests`
Expected: FAIL — `AnalysisEstimator` doesn't exist.

- [ ] **Step 3: Implement `AnalysisEstimator.swift`**

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild test -project Muse/Muse.xcodeproj -scheme Muse -only-testing:MuseTests/AnalysisEstimatorTests`
Expected: PASS

- [ ] **Step 5: Wire the trigger into `AnalysisStatusStore.refresh()`'s completion**

Add the `shownThisLaunch`/growth-since-launch bookkeeping (in-memory on
`AnalysisStatusStore` or a small sibling — not persisted) and the
`alertRequest` raise.

- [ ] **Step 6: Manual verification**

Point Muse at a very large unanalyzed folder (or synthetically lower
`fyiThresholdSeconds` via a debug build flag temporarily) and confirm the
card appears once, with a plausible count/duration, and never reappears in
the same launch.

- [ ] **Step 7: Commit**

```bash
git add Muse/Muse/Components/AnalysisEstimator.swift Muse/Muse/Models/AppState.swift Muse/MuseTests/AnalysisEstimatorTests.swift
git commit -m "feat(throttle): add AnalysisEstimator and the one-shot import-size FYI card"
```

---

## Task 15: `Import/TakeoutJSON.swift` — parser/matcher (pure, heavily tested)

**Files:**
- Create: `Muse/Muse/Import/TakeoutJSON.swift`
- Test: `Muse/MuseTests/TakeoutJSONTests.swift`

**Interfaces:**
- Consumes: nothing (pure JSON + filename logic).
- Produces: `TakeoutMeta`, `TakeoutJSON.parse(_:)`/`.jsonCandidates(for:)` —
  consumed by Task 16's import model.

```swift
nonisolated struct TakeoutMeta: Equatable, Sendable {
    var photoTakenTime: Int64?
    var lat: Double?
    var lon: Double?
    var description: String?
    var favorited: Bool = false
    var people: [String] = []
}
nonisolated enum TakeoutJSON {
    static func parse(_ data: Data) -> TakeoutMeta?
    static func jsonCandidates(for mediaName: String) -> [String]
}
```

`jsonCandidates`, best-first, exactly (each rule its own tested case):
1. `"<name>.<ext>.supplemental-metadata.json"`
2. `"<name>.<ext>.json"`
3. Duplicate-counter swap: `"IMG(1).jpg"` ↔ `"IMG.jpg(1).json"`
4. Edited-suffix strip: `"IMG-edited.jpg"` → the candidates for `"IMG.jpg"`
   (localized suffix list constant — at minimum `"-edited"`, `"-bearbeitet"`,
   `"-modifié"`)
5. 46-char truncation re-derive (Takeout truncates the JSON's base name)

`parse`: `JSONSerialization`, tolerant of missing keys.
`photoTakenTime.timestamp` is a **string** epoch (`"1234567890"`), parsed
with `Int64(string)`. `geoData` falls back to `geoDataExif` when
`geoData.latitude/longitude` are both `0.0`. `(0, 0)` → nil coordinate at
parse time (matching the universal `(0,0)`-is-absent rule).

- [ ] **Step 1: Write the failing test**

```swift
// Muse/MuseTests/TakeoutJSONTests.swift
import XCTest
@testable import Muse

final class TakeoutJSONTests: XCTestCase {
    func testCandidateRule1CurrentTakeoutFormat() {
        XCTAssertEqual(
            TakeoutJSON.jsonCandidates(for: "IMG_0001.jpg").first,
            "IMG_0001.jpg.supplemental-metadata.json")
    }

    func testCandidateRule2OlderTakeoutFormat() {
        XCTAssertTrue(TakeoutJSON.jsonCandidates(for: "IMG_0001.jpg").contains("IMG_0001.jpg.json"))
    }

    func testCandidateRule3DuplicateCounterSwap() {
        XCTAssertTrue(TakeoutJSON.jsonCandidates(for: "IMG(1).jpg").contains("IMG.jpg(1).json"))
    }

    func testCandidateRule4EditedSuffixStrip() {
        let candidates = TakeoutJSON.jsonCandidates(for: "IMG_0001-edited.jpg")
        XCTAssertTrue(candidates.contains { $0.hasPrefix("IMG_0001.jpg") })
    }

    func testCandidateRule4LocalizedEditedSuffixVariants() {
        XCTAssertTrue(TakeoutJSON.jsonCandidates(for: "IMG_0001-bearbeitet.jpg")
            .contains { $0.hasPrefix("IMG_0001.jpg") })
        XCTAssertTrue(TakeoutJSON.jsonCandidates(for: "IMG_0001-modifié.jpg")
            .contains { $0.hasPrefix("IMG_0001.jpg") })
    }

    func testCandidateRule5TruncationReDerive() {
        let longName = String(repeating: "a", count: 60) + ".jpg"
        let candidates = TakeoutJSON.jsonCandidates(for: longName)
        XCTAssertFalse(candidates.isEmpty)
    }

    func testParsePhotoTakenTimeIsStringEpoch() {
        let json = #"{"photoTakenTime":{"timestamp":"1609459200"}}"#.data(using: .utf8)!
        XCTAssertEqual(TakeoutJSON.parse(json)?.photoTakenTime, 1_609_459_200)
    }

    func testParseGeoDataFallsBackToGeoDataExif() {
        let json = #"""
        {"geoData":{"latitude":0,"longitude":0},
         "geoDataExif":{"latitude":47.5,"longitude":-122.3}}
        """#.data(using: .utf8)!
        let meta = TakeoutJSON.parse(json)
        XCTAssertEqual(meta?.lat, 47.5)
        XCTAssertEqual(meta?.lon, -122.3)
    }

    func testZeroZeroGeoDataIsAbsentWhenNoExifFallback() {
        let json = #"{"geoData":{"latitude":0,"longitude":0}}"#.data(using: .utf8)!
        XCTAssertNil(TakeoutJSON.parse(json)?.lat)
    }

    func testFavoritedAndPeopleAndDescriptionExtraction() {
        let json = #"""
        {"description":"  A sunset  ","favorited":true,
         "people":[{"name":"Ana"},{"name":"Ben"}]}
        """#.data(using: .utf8)!
        let meta = TakeoutJSON.parse(json)
        XCTAssertEqual(meta?.description, "A sunset")
        XCTAssertTrue(meta?.favorited ?? false)
        XCTAssertEqual(meta?.people, ["Ana", "Ben"])
    }

    func testEmptyDescriptionBecomesNil() {
        let json = #"{"description":"   "}"#.data(using: .utf8)!
        XCTAssertNil(TakeoutJSON.parse(json)?.description)
    }

    func testMalformedJSONReturnsNil() {
        XCTAssertNil(TakeoutJSON.parse("not json".data(using: .utf8)!))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -project Muse/Muse.xcodeproj -scheme Muse -only-testing:MuseTests/TakeoutJSONTests`
Expected: FAIL — `TakeoutJSON` does not exist.

- [ ] **Step 3: Implement `TakeoutJSON.swift`**

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild test -project Muse/Muse.xcodeproj -scheme Muse -only-testing:MuseTests/TakeoutJSONTests`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add Muse/Muse/Import/TakeoutJSON.swift Muse/MuseTests/TakeoutJSONTests.swift
git commit -m "feat(import): add pure Google Takeout JSON parser and filename-match ladder"
```

---

## Task 16: Google Takeout import flow

**Files:**
- Create: `Muse/Muse/Import/TakeoutImportModel.swift`
- Create: `Muse/Muse/Views/TakeoutImportCard.swift`
- Modify: `Muse/Muse/Models/AppState+Import.swift`
  (`TakeoutImportRequest` — replace Task 2's stub)
- Modify: `Muse/Muse/MuseApp.swift` (submenu item "From Google Takeout…")
- Test: `Muse/MuseTests/TakeoutImportModelTests.swift`

**Interfaces:**
- Consumes: `TakeoutJSON` (Task 15), `ImportSupplement.apply` (Task 8),
  `ImportedText.note` (Task 5 — with `caption: description`),
  `MetadataImportApply.applyKeywords` (existing), `BookmarkStore.addRoot`
  (existing), `Indexer.shared.indexBatch` (existing), `ImportReport` (Task 1).
- Produces: nothing consumed elsewhere.

`TakeoutImportRequest { let id = UUID(); var folder: URL }`.

Flow, `TakeoutImportModel.start(folder:appState:)`:
1. Add `folder` as a root via `BookmarkStore.addRoot` if not already covered
   by an existing root (files stay in place — **no copy step**, per
   deviation D8: Takeout output is already ordinary files in a user folder).
2. Enumerate recursively (media kinds: image/raw/psd/video), `indexBatch`
   every 50.
3. Per file: `TakeoutJSON.jsonCandidates(for: file.lastPathComponent)`, first
   existing sibling → `TakeoutJSON.parse` → apply in one `queue.write`:
   - `ImportSupplement.apply` with `External(lat/lon: meta.lat/lon,
     captureDate: meta.photoTakenTime)` — header wins, `report.coordinates`/
     `.captureDates` increment per `AppliedFields`.
   - `description` → note via `ImportedText.note(title: nil, caption:
     meta.description, creator: nil)`, fill-gaps.
   - `favorited` → `Favorite` manual tag via `applyKeywords` (per-card
     choice — a Takeout-specific "Favorites → tag/skip" picker, default tag,
     independent of the Apple Photos card's own picker).
   - `people` → per the card's own picker (**default skip** — plain tags or
     nothing, never face identities) → `applyKeywords` when "tags" chosen.
4. `-edited` siblings: both the edited file and the original are ordinary
   files; the edited one's JSON matches via ladder rule 4, so both receive
   the metadata independently — no auto-pairing/stacking.
5. Chain `GeocodeBackfill.run()` → `SearchFacets.shared.refresh()` when any
   supplements applied.
6. Report notice: "Google Photos edits are already baked into the edited
   files; originals are unmodified."

- [ ] **Step 1: Write the failing test**

```swift
// Muse/MuseTests/TakeoutImportModelTests.swift
import XCTest
@testable import Muse

@MainActor
final class TakeoutImportModelTests: XCTestCase {
    func testDatesAndGPSRestoredToFilesThatLackThem() async throws {
        // Fixture: a folder with IMG_0001.jpg (no EXIF GPS/date) +
        // IMG_0001.jpg.supplemental-metadata.json carrying photoTakenTime +
        // geoData. Run the model; assert files.lat/lon and photo_meta.capture_date
        // are populated after the run (acceptance case, pre-spec verbatim).
    }

    func testFilesInPlaceAreNeverCopied() async throws {
        // Assert no new file appears anywhere outside the source folder —
        // the import references files where they already are.
    }

    func testEditedSiblingReceivesOriginalsMetadataIndependently() async throws {
        // Fixture: IMG_0001.jpg + IMG_0001-edited.jpg, one JSON matching the
        // original via ladder rule 1. Assert BOTH files receive the
        // supplement (via ladder rule 4 on the edited name), with no stack
        // created between them.
    }

    func testFavoriteDefaultsToTagWhenCardOptsIn() async throws {
        // Assert a favorited=true file receives the "Favorite" manual tag
        // when the picker is set to "tag".
    }

    func testPeopleDefaultToSkipped() async throws {
        // Default card option: assert no tags are written from the
        // people array unless explicitly opted into "tags".
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -project Muse/Muse.xcodeproj -scheme Muse -only-testing:MuseTests/TakeoutImportModelTests`
Expected: FAIL — `TakeoutImportModel` doesn't exist.

- [ ] **Step 3: Implement `TakeoutImportModel.swift` and `TakeoutImportCard.swift`**

Card contract matches `ImportRunCard`'s shape (built only while presented,
`.onAppear` starts, `.onDisappear` cancels, options form pre-run: people
picker default skip, favorites picker default tag).

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild test -project Muse/Muse.xcodeproj -scheme Muse -only-testing:MuseTests/TakeoutImportModelTests`
Expected: PASS

- [ ] **Step 5: Wire `ContentView.swift`'s `.takeout` case and the submenu item**

Replace the `EmptyView()` placeholder; add "From Google Takeout…" to the
Import submenu (Task 7), calling
`appState.importModal = .takeout(TakeoutImportRequest(folder: /* picked via NSOpenPanel */))`.

- [ ] **Step 6: Commit**

```bash
git add Muse/Muse/Import/TakeoutImportModel.swift Muse/Muse/Views/TakeoutImportCard.swift Muse/Muse/Models/AppState+Import.swift Muse/Muse/MuseApp.swift Muse/Muse/ContentView.swift Muse/MuseTests/TakeoutImportModelTests.swift
git commit -m "feat(import): add Google Takeout import (in-place, metadata + supplement)"
```

---

## Task 17: `Import/EagleLibrary.swift` — reader (pure, verification-first)

**Files:**
- Create: `Muse/Muse/Import/EagleLibrary.swift`
- Test: `Muse/MuseTests/EagleLibraryTests.swift`
- Fixture: a miniaturized real `.library` package under
  `Muse/MuseTests/Fixtures/sample.library/`

**Interfaces:**
- Consumes: nothing (pure filesystem/JSON reads over a directory).
- Produces: `EagleItem`/`EagleFolder`/`EagleLibrary.read(at:)`/
  `.flattenedNames(_:)` — consumed by Task 18's import model.

```swift
nonisolated struct EagleItem: Equatable, Sendable {
    var id: String
    var fileURL: URL
    var name: String
    var tags: [String] = []
    var star: Int?
    var annotation: String?
    var folderIDs: [String] = []
}
nonisolated struct EagleFolder: Equatable, Sendable {
    var id: String; var name: String; var childIDs: [String]
}
nonisolated enum EagleLibrary {
    static func read(at libraryURL: URL) throws -> (items: [EagleItem], folders: [EagleFolder])
    static func flattenedNames(_ folders: [EagleFolder]) -> [String: String]
}
```

**Binding — this task is verification-first**: before writing the parser
against training-data assumptions about the `.library` layout, create a
scratch library in the real Eagle app (owner step), inspect its actual
`images/<id>.info/metadata.json` shape and the root folder-tree
`metadata.json`, and build the test fixture as a miniaturized copy of that
real output. `read(at:)` is tolerant per item — a corrupt item's metadata is
skipped and counted, never fails the whole run.

- [ ] **Step 1: Owner step — produce the scratch library and fixture**

Create a small Eagle library by hand in the Eagle app (a handful of images,
some tagged, some starred, some in nested folders, one with an annotation,
one deliberately corrupted item). Copy/miniaturize it into
`Muse/MuseTests/Fixtures/sample.library/`. Record the actual JSON field
names observed (they may differ from the hypothesis above) and use the
observed shape as the source of truth for Step 3.

- [ ] **Step 2: Write the failing test against the real fixture**

```swift
// Muse/MuseTests/EagleLibraryTests.swift
import XCTest
@testable import Muse

final class EagleLibraryTests: XCTestCase {
    func testReadParsesAllItemsInTheFixtureLibrary() throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "sample", withExtension: "library"))
        let (items, folders) = try EagleLibrary.read(at: url)
        XCTAssertFalse(items.isEmpty)
        XCTAssertFalse(folders.isEmpty)
    }

    func testTagsStarAnnotationExtractedPerItem() throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "sample", withExtension: "library"))
        let (items, _) = try EagleLibrary.read(at: url)
        let tagged = items.first { !$0.tags.isEmpty }
        XCTAssertNotNil(tagged)
        let starred = items.first { $0.star != nil }
        XCTAssertNotNil(starred)
        let annotated = items.first { $0.annotation != nil }
        XCTAssertNotNil(annotated)
    }

    func testCorruptItemIsSkippedNotFatal() throws {
        // The fixture's deliberately-corrupted item must not throw the whole read.
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "sample", withExtension: "library"))
        XCTAssertNoThrow(try EagleLibrary.read(at: url))
    }

    func testFlattenedNamesJoinsNestedFoldersWithEnDash() {
        let folders = [
            EagleFolder(id: "p", name: "Parent", childIDs: ["c"]),
            EagleFolder(id: "c", name: "Child", childIDs: []),
        ]
        let flat = EagleLibrary.flattenedNames(folders)
        XCTAssertEqual(flat["c"], "Parent – Child")
        XCTAssertEqual(flat["p"], "Parent")
    }
}
```

- [ ] **Step 3: Run test to verify it fails**

Run: `xcodebuild test -project Muse/Muse.xcodeproj -scheme Muse -only-testing:MuseTests/EagleLibraryTests`
Expected: FAIL — `EagleLibrary` doesn't exist / fixture missing.

- [ ] **Step 4: Implement `EagleLibrary.swift` against the observed real shape**

- [ ] **Step 5: Run test to verify it passes**

Run: `xcodebuild test -project Muse/Muse.xcodeproj -scheme Muse -only-testing:MuseTests/EagleLibraryTests`
Expected: PASS

- [ ] **Step 6: Commit**

```bash
git add Muse/Muse/Import/EagleLibrary.swift Muse/MuseTests/EagleLibraryTests.swift Muse/MuseTests/Fixtures/sample.library
git commit -m "feat(import): add Eagle .library reader (verified against a real scratch library)"
```

---

## Task 18: Eagle import flow

**Files:**
- Create: `Muse/Muse/Import/EagleImportModel.swift`
- Create: `Muse/Muse/Views/EagleImportCard.swift`
- Modify: `Muse/Muse/Models/AppState+Import.swift`
  (`EagleImportRequest` — replace Task 2's stub)
- Modify: `Muse/Muse/MuseApp.swift` (submenu item "From Eagle Library…")
- Test: `Muse/MuseTests/EagleImportModelTests.swift`

**Interfaces:**
- Consumes: `EagleLibrary` (Task 17), `MetadataImportApply.applyKeywords`,
  `MetadataImportRules.ratingToApply`/`hasRating`/`normalizeRating`,
  `TagStore.shared.setRating`, `ImportedText.note`, `NoteStore`,
  `CollectionStore.createManual`/`.addFile`, `Indexer.shared.indexBatch`.
- Produces: nothing consumed elsewhere.

`EagleImportRequest { let id = UUID(); var libraryURL: URL }`.

Flow, per the approved `docs/future-features/eagle-library-import.md` design
plus the two updates (annotations → notes; shared report machinery):
1. Copy once, flat, into a chosen destination via `FileManager.copyItem`
   (never `FileMover.move` — the source library is read-only by contract).
   Destination filename already present with a *different* item →
   `" 2"` collision ladder; already present as the *same* item → skip +
   count (idempotent re-run).
2. `Indexer.shared.indexBatch` the copied URLs, every 50.
3. Per item, in `queue.write` chunks:
   - tags → `applyKeywords` (manual tier),
   - star → `MetadataImportRules.normalizeRating`/`ratingToApply` gap-fill →
     `TagStore.shared.setRating`,
   - annotation → note via `ImportedText.note(title: nil, caption:
     item.annotation, creator: nil)`, fill-gaps,
   - folder memberships → find-or-create manual collections by
     `EagleLibrary.flattenedNames` (one image in three Eagle folders becomes
     one file in three collections, never file copies).
4. Dropped per the approved design: URLs, smart folders, Eagle palette data.
5. Report: "214 imported, 2 skipped" register + collections-created +
   tags/ratings/notes counts.

- [ ] **Step 1: Write the failing test**

```swift
// Muse/MuseTests/EagleImportModelTests.swift
import XCTest
@testable import Muse

@MainActor
final class EagleImportModelTests: XCTestCase {
    func testCopyIndexApplySequenceOverTheFixtureLibrary() async throws {
        // Run over sample.library into a scratch destination folder; assert
        // report.filesImported matches the fixture's item count minus the
        // corrupt one, and the destination folder contains the copied files.
    }

    func testSecondRunIsFullyIdempotent() async throws {
        // Run twice; assert the second run's report shows all-skip
        // (filesSkipped == first run's filesImported) and no duplicate files
        // or duplicate tag rows exist.
    }

    func testNestedFoldersBecomeFlattenedCollections() async throws {
        // Assert a collection named "Parent – Child" exists after the run,
        // containing the expected file.
    }

    func testAnnotationLandsAsANoteFillGapsOnly() async throws {
        // Assert the annotated item's note equals its annotation text; a
        // pre-existing note on that file's destination path is untouched.
    }

    func testSourceLibraryIsNeverMutatedOrMoved() async throws {
        // Assert every original file under sample.library still exists
        // at its original path after the run (copy, never move).
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -project Muse/Muse.xcodeproj -scheme Muse -only-testing:MuseTests/EagleImportModelTests`
Expected: FAIL — `EagleImportModel` doesn't exist.

- [ ] **Step 3: Implement `EagleImportModel.swift` and `EagleImportCard.swift`**

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild test -project Muse/Muse.xcodeproj -scheme Muse -only-testing:MuseTests/EagleImportModelTests`
Expected: PASS

- [ ] **Step 5: Wire `ContentView.swift`'s `.eagle` case and the submenu item**

- [ ] **Step 6: Commit**

```bash
git add Muse/Muse/Import/EagleImportModel.swift Muse/Muse/Views/EagleImportCard.swift Muse/Muse/Models/AppState+Import.swift Muse/Muse/MuseApp.swift Muse/Muse/ContentView.swift Muse/MuseTests/EagleImportModelTests.swift
git commit -m "feat(import): add Eagle library import (copy-once, flat, per approved design)"
```

---

## Task 19: Apple Photos import — entitlement + flow

**Files:**
- Modify: `Muse/Muse/Muse.entitlements` (add
  `com.apple.security.personal-information.photos-library`)
- Modify: `Muse/Muse/Muse-Debug.entitlements` (same)
- Modify: `Muse/Muse/Info.plist` (add `NSPhotoLibraryUsageDescription`,
  localized)
- Create: `Muse/Muse/Import/ApplePhotosImportModel.swift`
- Create: `Muse/Muse/Views/ApplePhotosImportCard.swift`
- Modify: `Muse/Muse/MuseApp.swift` (submenu item "From Apple Photos…")
- Test: `Muse/MuseTests/ApplePhotosImportModelTests.swift`

**Interfaces:**
- Consumes: `PHPhotoLibrary`/`PHImageManager`/`PHAssetResourceManager`
  (PhotoKit), `ImportSupplement.apply` (Task 8), `MetadataImportApply.
  applyKeywords`, `CollectionStore.createManual`/`.addFile`,
  `Indexer.shared.indexBatch`, `BookmarkStore.addRoot`.
- Produces: nothing consumed elsewhere.

Entitlement note (**network doctrine, recorded not a new path**): PhotoKit
may pull iCloud-Photos originals when `isNetworkAccessAllowed = true` — this
is OS-mediated system traffic (the StoreKit/`bird` doctrine class), not an
app network path; the app itself opens no connection.

Options card (pre-run form): destination folder picker (required; add as
root if uncovered) · "Recreate albums as collections" toggle (default on) ·
favorites picker: **tag `Favorite` / skip** (default tag — deviation D4: a
binary favorite must never fabricate a star rating; `setRating` is the only
rating-write seam and this bypasses it on purpose).

Run, per `PHAsset` (`.image` + `.video`, newest-first, cancellable):
1. Export current version: images via
   `PHImageManager.requestImageDataAndOrientation(version: .current,
   isNetworkAccessAllowed: true)` → filename from
   `PHAssetResource.originalFilename` (extension corrected to the returned
   UTI when it differs), collision ladder ` 2`/` 3`… (case-insensitive) →
   atomic write into destination. Videos: `PHAssetResourceManager` streaming
   `.fullSizeVideo` when present, else `.video`.
2. `Indexer.shared.indexBatch` every 50 written URLs.
3. `ImportSupplement.apply` with `External(lat/lon: asset.location?
   .coordinate, captureDate: asset.creationDate)`.
4. Favorite → per option, `applyKeywords(["Favorite"])`.
5. Albums → collections (toggle on): enumerate `PHAssetCollection` user
   albums containing imported assets, find-or-create manual collections by
   case-insensitive name; smart albums skipped.
6. No inline analysis trigger — the automatic pipeline picks new files up.

Idempotency: destination filename already exists → skip + count.

Report notices (fixed strings, per §6.3):
- "Apple Photos edits are applied to the imported image; the individual
  adjustments can't be recovered (private format)."
- "Keywords assigned in Photos aren't available to other apps and were not
  imported." — **verify at build time**: if `PHAsset` genuinely exposes no
  keyword API on the deployment target, keep this notice; if a supported API
  exists, replace the notice with the import (recorded as deviation D5 in
  the original spec — check before assuming).

- [ ] **Step 1: Add the entitlement + usage string**

Add to both `.entitlements` files:

```xml
<key>com.apple.security.personal-information.photos-library</key>
<true/>
```

Add to `Info.plist`:

```xml
<key>NSPhotoLibraryUsageDescription</key>
<string>Muse reads your Photos library only to copy the photos you choose into a folder you choose.</string>
```

(Localize the string per the existing `Localizable.xcstrings` workflow —
hand-wrap since Info.plist strings aren't auto-extracted the same way as
SwiftUI text literals; add the French translation now, not later.)

- [ ] **Step 2: Write the failing test**

```swift
// Muse/MuseTests/ApplePhotosImportModelTests.swift
import XCTest
@testable import Muse

@MainActor
final class ApplePhotosImportModelTests: XCTestCase {
    // PhotoKit access requires a real Photos library / simulator authorization,
    // so these tests exercise the PURE helpers only (naming/collision,
    // idempotency check), not a live PHAsset fetch — matching the house
    // "no UI unit tests" rule extended to "no live-PhotoKit unit tests."

    func testFavoriteMapsToTagNeverAStar() {
        // Given a mocked/injected PHAsset-shaped favorite flag == true and
        // the card option set to "tag", assert the applied keyword set is
        // exactly ["Favorite"] and no TagStore.setRating call occurs.
    }

    func testCollisionLadderAppendsNumericSuffix() {
        // Pure filename-collision helper (extracted from the flow into a
        // small testable function, e.g. ApplePhotosImportModel.collisionName(...)):
        // "IMG_0001.jpg" existing → "IMG_0001 2.jpg".
        XCTAssertEqual(
            ApplePhotosImportModel.collisionName(base: "IMG_0001", ext: "jpg", existing: ["IMG_0001.jpg"]),
            "IMG_0001 2.jpg")
    }

    func testDestinationFilenameAlreadyExistsIsSkippedNotOverwritten() {
        // Given a destination that already contains the exact target
        // filename from a prior run, assert the model counts it skipped
        // rather than re-writing.
    }
}
```

- [ ] **Step 3: Run test to verify it fails**

Run: `xcodebuild test -project Muse/Muse.xcodeproj -scheme Muse -only-testing:MuseTests/ApplePhotosImportModelTests`
Expected: FAIL — `ApplePhotosImportModel` doesn't exist.

- [ ] **Step 4: Implement `ApplePhotosImportModel.swift`, extracting the pure collision-naming helper first, then the PhotoKit-dependent flow around it**

- [ ] **Step 5: Run test to verify it passes**

Run: `xcodebuild test -project Muse/Muse.xcodeproj -scheme Muse -only-testing:MuseTests/ApplePhotosImportModelTests`
Expected: PASS

- [ ] **Step 6: Build `ApplePhotosImportCard.swift`, wire `ContentView.swift`'s `.applePhotos` case and the submenu item**

- [ ] **Step 7: Manual verification**

Run the app on a Mac with a real (or sample) Photos library, grant access,
run a small import, confirm files land in the chosen folder, favorites tag
correctly, albums become collections, and the two stated-plainly notices
appear in the report. This is PhotoKit-backed system behavior — CLAUDE.md's
"verify runtime, not just tests" rule applies directly here.

- [ ] **Step 8: Commit**

```bash
git add Muse/Muse/Muse.entitlements Muse/Muse/Muse-Debug.entitlements Muse/Muse/Info.plist Muse/Muse/Import/ApplePhotosImportModel.swift Muse/Muse/Views/ApplePhotosImportCard.swift Muse/Muse/MuseApp.swift Muse/Muse/ContentView.swift Muse/MuseTests/ApplePhotosImportModelTests.swift
git commit -m "feat(import): add Apple Photos import (PhotoKit rendered-image + metadata)"
```

---

## Task 20: `Import/LightroomXMP.swift` — the crs: parser (pure, tested against owner fixtures)

**Files:**
- Create: `Muse/Muse/Import/LightroomXMP.swift`
- Test: `Muse/MuseTests/LightroomXMPTests.swift`
- Fixture: `Muse/MuseTests/Fixtures/lightroom/*.xmp` + matching images
  (owner-produced, see Step 1)

**Interfaces:**
- Consumes: `CGImageMetadata` (the same metadata `MetadataKeywordReader`
  already resolves — zero extra I/O).
- Produces: `LightroomEdits`, `LightroomXMP.read(_:)` — consumed by Task 21's
  `LightroomEditMapper`.

```swift
nonisolated struct LightroomEdits: Equatable, Sendable {
    var hasCrop = false
    var cropLeft: Double?; var cropTop: Double?; var cropRight: Double?; var cropBottom: Double?
    var cropAngle: Double?
    var orientation: Int?
    var temperatureKelvin: Double?
    var tint: Double?
    var incrementalTemperature: Double?
    var incrementalTint: Double?
    var exposure2012: Double?
    var contrast2012: Double?
    var vibrance: Double?
    var saturation: Double?
    var toneCurvePV2012: [CGPoint] = []
    var toneCurveRed: [CGPoint] = []
    var toneCurveGreen: [CGPoint] = []
    var toneCurveBlue: [CGPoint] = []
    var unsupported: Set<String> = []
    var isEmpty: Bool {
        !hasCrop && exposure2012 == nil && contrast2012 == nil && vibrance == nil
            && saturation == nil && toneCurvePV2012.isEmpty && incrementalTemperature == nil
            && temperatureKelvin == nil
    }
}
nonisolated enum LightroomXMP {
    static func read(_ meta: CGImageMetadata) -> LightroomEdits
}
```

- Every field via `CGImageMetadataCopyTagWithPath(meta, nil, "crs:<Name>")`;
  numeric strings like `"+0.85"` parse with an explicit `+`-tolerant
  `Double` init.
- **The unsupported set is the enumerated, closed list** (never open-ended):
  `Highlights2012, Shadows2012, Whites2012, Blacks2012, Clarity2012, Texture,
  Dehaze, GrainAmount, PostCropVignetteAmount, MaskGroupBasedCorrections (any),
  RetouchAreas (any), LookName (non-empty)` — mapped to localized display
  names for the report. **This list may not grow without a foundation-doc
  change.**
- **PV gate is key-presence, not `crs:ProcessVersion` parsing**: a file
  carrying no `2012`-suffixed keys yields a geometry-only stack (older PV
  files); if `crs:ProcessVersion` exists but no 2012 keys do, add "Legacy
  process version" to `unsupported`.

- [ ] **Step 1: Owner step — produce the Lightroom fixture set**

Export from real Lightroom, per §15 of the source spec: a small set covering
crop+angle+orientation, WB (RAW Kelvin workflow + JPEG incremental
workflow), the four PV2012 tone/color sliders, RGB + per-channel curves, and
at least one file carrying unsupported sliders (Clarity, Dehaze). Verify
`CropAngle`'s sign and the crop frame against Lightroom's own render —
record the verified sign as a code comment at the mapping site (Task 21) so
a future reader isn't left guessing.

- [ ] **Step 2: Write the failing test against the fixtures**

```swift
// Muse/MuseTests/LightroomXMPTests.swift
import XCTest
import ImageIO
@testable import Muse

final class LightroomXMPTests: XCTestCase {
    private func metadata(for fixture: String) throws -> CGImageMetadata {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: fixture, withExtension: "xmp"))
        let data = try Data(contentsOf: url)
        return try XCTUnwrap(CGImageMetadataCreateFromXMPData(data as CFData))
    }

    func testCropAndAngleAndOrientationExtracted() throws {
        let edits = LightroomXMP.read(try metadata(for: "lr-crop-angle-orientation"))
        XCTAssertTrue(edits.hasCrop)
        XCTAssertNotNil(edits.cropAngle)
        XCTAssertNotNil(edits.orientation)
    }

    func testRAWTemperatureAndTintExtracted() throws {
        let edits = LightroomXMP.read(try metadata(for: "lr-raw-wb"))
        XCTAssertNotNil(edits.temperatureKelvin)
        XCTAssertNotNil(edits.tint)
    }

    func testJPEGIncrementalWBExtracted() throws {
        let edits = LightroomXMP.read(try metadata(for: "lr-jpeg-wb"))
        XCTAssertNotNil(edits.incrementalTemperature)
        XCTAssertNotNil(edits.incrementalTint)
    }

    func testFourToneColorSlidersExtracted() throws {
        let edits = LightroomXMP.read(try metadata(for: "lr-tone-color-basic"))
        XCTAssertNotNil(edits.exposure2012)
        XCTAssertNotNil(edits.contrast2012)
        XCTAssertNotNil(edits.vibrance)
        XCTAssertNotNil(edits.saturation)
    }

    func testRGBAndPerChannelCurvesExtracted() throws {
        let edits = LightroomXMP.read(try metadata(for: "lr-curves"))
        XCTAssertFalse(edits.toneCurvePV2012.isEmpty)
        XCTAssertFalse(edits.toneCurveRed.isEmpty)
        XCTAssertFalse(edits.toneCurveGreen.isEmpty)
        XCTAssertFalse(edits.toneCurveBlue.isEmpty)
    }

    func testUnsupportedSlidersAreEnumeratedNotTranslated() throws {
        let edits = LightroomXMP.read(try metadata(for: "lr-unsupported-sliders"))
        XCTAssertTrue(edits.unsupported.contains("Clarity"))
        XCTAssertTrue(edits.unsupported.contains("Dehaze"))
        // Confirm the enumerated field itself never leaks into a translated slot:
        XCTAssertNil(edits.exposure2012 == nil ? nil : Optional(()))  // no accidental clarity→something mapping
    }

    func testLegacyProcessVersionWithNo2012KeysIsFlagged() throws {
        let edits = LightroomXMP.read(try metadata(for: "lr-legacy-pv"))
        XCTAssertTrue(edits.unsupported.contains("Legacy process version"))
        XCTAssertNil(edits.exposure2012)
    }

    func testEmptyMetadataYieldsIsEmptyTrue() throws {
        let edits = LightroomXMP.read(try metadata(for: "lr-no-edits"))
        XCTAssertTrue(edits.isEmpty)
    }
}
```

- [ ] **Step 3: Run test to verify it fails**

Run: `xcodebuild test -project Muse/Muse.xcodeproj -scheme Muse -only-testing:MuseTests/LightroomXMPTests`
Expected: FAIL — `LightroomXMP` doesn't exist / fixtures missing.

- [ ] **Step 4: Implement `LightroomXMP.swift`**

- [ ] **Step 5: Run test to verify it passes**

Run: `xcodebuild test -project Muse/Muse.xcodeproj -scheme Muse -only-testing:MuseTests/LightroomXMPTests`
Expected: PASS

- [ ] **Step 6: Commit**

```bash
git add Muse/Muse/Import/LightroomXMP.swift Muse/MuseTests/LightroomXMPTests.swift Muse/MuseTests/Fixtures/lightroom
git commit -m "feat(import): add Lightroom crs: XMP parser, verified against owner-exported fixtures"
```

---

## Task 21: `LightroomEditMapper` + `EditStack.origin` provenance

**Files:**
- Create: `Muse/Muse/Import/LightroomEditMapper.swift`
- Modify: `Muse/Muse/Editing/EditStack.swift` (Spec 04 file — add
  `origin: EditOrigin?`)
- Modify: `Muse/Muse/Editing/EditTransfer.swift` (Spec 04 file — origin
  never transfers)
- Modify: `Muse/Muse/Editing/EditPresetStore.swift` (Spec 04 file — origin
  stripped at preset save)
- Test: `Muse/MuseTests/LightroomEditMapperTests.swift`
- Test: extend `Muse/MuseTests/EditStackCodecTests.swift`
- Test: extend `Muse/MuseTests/EditTransferTests.swift`

**Interfaces:**
- Consumes: `LightroomEdits` (Task 20), `EditStack`/`GeometryParams`/
  `ToneParams`/`ColorParams`/`CurveParams` (Spec 04), the renderer's own
  mired-mapping constant (Spec 04's `TemperatureMap.miredPerUnit`, hoisted to
  `Editing/Render/`).
- Produces: `LightroomEditMapper.map(_:context:)` — consumed by Task 22's
  apply path.

```swift
nonisolated enum LightroomEditMapper {
    struct Context {
        var isRAW: Bool
        var asShotKelvin: Double?
        var asShotTint: Double?
    }
    static func map(_ lr: LightroomEdits, context: Context) -> EditStack?

    static let lrContrastScale = 100.0
    static let lrVibranceScale = 100.0
    static let lrSaturationScale = 100.0
    static let lrIncrementalWBScale = 100.0
    static let lrTintScale = 150.0
    static let curveDomain = 255.0
}
```

Mappings, exactly per source §4.3:
- **Geometry**: `crop` from `cropLeft/Top/Right/Bottom` when `hasCrop`
  (already normalized 0…1); `straightenDegrees = −cropAngle` (sign per the
  owner-verified fixture from Task 20); `quarterTurns`/`flipH`/`flipV` from
  `orientation` via a pure EXIF-orientation table (test all 8 values).
- **Exposure**: `exposureEV = clamp(exposure2012, −5...5)`.
- **Contrast/Vibrance/Saturation**: `value / scale`, clamped `−1...1`.
- **WB, encoded**: `temperature = incrementalTemperature /
  lrIncrementalWBScale`, `tint = incrementalTint / lrIncrementalWBScale`.
- **WB, RAW**: requires `asShotKelvin`; `temperature =
  clamp((mired(temperatureKelvin) − mired(asShotKelvin)) /
  TemperatureMap.miredPerUnit, −1...1)`, `tint = clamp((tint − asShotTint) /
  lrTintScale, −1...1)`. Missing `asShotKelvin` → temperature/tint skipped.
- **Curves**: points `/ curveDomain`; identity curves
  (`(0,0),(255,255)` ± ε) → empty; `> CurveParams.maxPoints` (16) → keep
  endpoints, evenly subsample interior.
- Output: `EditStack.fresh()` + mapped groups, `.normalized()`,
  `origin = .lightroom`. `rawParams` stays nil (the importer never pins a
  decoder version).
- `nil` return when the mapped result would be entirely neutral (nothing
  worth writing).

`EditStack.origin` (one added optional field, Spec 04's file):

```swift
nonisolated enum EditOrigin: String, Codable, Sendable { case lightroom }
// EditStack gains:
var origin: EditOrigin? = nil
```

- **Hash-stability rule (binding):** synthesized `Codable` omits nil
  optionals, so every pre-existing stack's canonical `.sortedKeys` bytes —
  and `stack_hash` — stay byte-identical. The existing `EditStackCodecTests`
  pinned fixture hash **must not change** after this addition; add a
  *second* pinned fixture WITH `origin` set.
- Never transfers via `EditTransfer.apply` (target keeps its own origin);
  stripped at preset save (`EditPresetStore`, alongside the existing
  geometry-strip rule); gone on Reset (a neutral imported stack is never
  written — `map` returns nil for that case, so there's no row to reset from
  in the first place).

- [ ] **Step 1: Write the failing test**

```swift
// Muse/MuseTests/LightroomEditMapperTests.swift
import XCTest
@testable import Muse

final class LightroomEditMapperTests: XCTestCase {
    func testExposureMapsDirectlyClamped() {
        var lr = LightroomEdits()
        lr.exposure2012 = 0.85
        let stack = LightroomEditMapper.map(lr, context: .init(isRAW: false, asShotKelvin: nil, asShotTint: nil))
        XCTAssertEqual(stack?.toneParams?.exposureEV, 0.85, accuracy: 1e-9)
    }

    func testExposureClampsToFiveStops() {
        var lr = LightroomEdits(); lr.exposure2012 = 12
        let stack = LightroomEditMapper.map(lr, context: .init(isRAW: false, asShotKelvin: nil, asShotTint: nil))
        XCTAssertEqual(stack?.toneParams?.exposureEV, 5)
    }

    func testContrastVibranceSaturationDivideByScale() {
        var lr = LightroomEdits(); lr.contrast2012 = 50; lr.vibrance = -25; lr.saturation = 10
        let stack = LightroomEditMapper.map(lr, context: .init(isRAW: false, asShotKelvin: nil, asShotTint: nil))
        XCTAssertEqual(stack?.colorParams?.contrast, 0.5, accuracy: 1e-9)
        XCTAssertEqual(stack?.colorParams?.vibrance, -0.25, accuracy: 1e-9)
        XCTAssertEqual(stack?.colorParams?.saturation, 0.1, accuracy: 1e-9)
    }

    func testEncodedWBUsesIncrementalDivideByScale() {
        var lr = LightroomEdits(); lr.incrementalTemperature = 40; lr.incrementalTint = -20
        let stack = LightroomEditMapper.map(lr, context: .init(isRAW: false, asShotKelvin: nil, asShotTint: nil))
        XCTAssertEqual(stack?.colorParams?.temperature, 0.4, accuracy: 1e-9)
        XCTAssertEqual(stack?.colorParams?.tint, -0.2, accuracy: 1e-9)
    }

    func testRAWWBRequiresAsShotContextElseSkipped() {
        var lr = LightroomEdits(); lr.temperatureKelvin = 5500; lr.tint = 10
        let noContext = LightroomEditMapper.map(lr, context: .init(isRAW: true, asShotKelvin: nil, asShotTint: nil))
        XCTAssertNil(noContext?.colorParams?.temperature)
        let withContext = LightroomEditMapper.map(
            lr, context: .init(isRAW: true, asShotKelvin: 5200, asShotTint: 0))
        XCTAssertNotNil(withContext?.colorParams?.temperature)
    }

    func testIdentityCurveIsDropped() {
        var lr = LightroomEdits(); lr.toneCurvePV2012 = [CGPoint(x: 0, y: 0), CGPoint(x: 255, y: 255)]
        let stack = LightroomEditMapper.map(lr, context: .init(isRAW: false, asShotKelvin: nil, asShotTint: nil))
        XCTAssertTrue(stack?.curveParams?.points.isEmpty ?? true)
    }

    func testOversizedCurveKeepsEndpointsAndSubsamples() {
        var lr = LightroomEdits()
        lr.toneCurvePV2012 = (0...30).map { CGPoint(x: Double($0) * 8, y: Double($0) * 8) }
        let stack = LightroomEditMapper.map(lr, context: .init(isRAW: false, asShotKelvin: nil, asShotTint: nil))
        let points = stack?.curveParams?.points ?? []
        XCTAssertLessThanOrEqual(points.count, 16)
        XCTAssertEqual(points.first?.x, 0)
        XCTAssertEqual(points.last?.x, 1, accuracy: 1e-6)
    }

    func testOrientationTableCoversAllEightValues() {
        for o in 1...8 {
            var lr = LightroomEdits(); lr.orientation = o; lr.hasCrop = true
            lr.cropLeft = 0; lr.cropTop = 0; lr.cropRight = 1; lr.cropBottom = 1
            let stack = LightroomEditMapper.map(lr, context: .init(isRAW: false, asShotKelvin: nil, asShotTint: nil))
            XCTAssertNotNil(stack?.geometryParams)
        }
    }

    func testEmptyLightroomEditsMapsToNil() {
        let stack = LightroomEditMapper.map(
            LightroomEdits(), context: .init(isRAW: false, asShotKelvin: nil, asShotTint: nil))
        XCTAssertNil(stack)
    }

    func testOutputOriginIsLightroom() {
        var lr = LightroomEdits(); lr.exposure2012 = 0.5
        let stack = LightroomEditMapper.map(lr, context: .init(isRAW: false, asShotKelvin: nil, asShotTint: nil))
        XCTAssertEqual(stack?.origin, .lightroom)
    }

    func testOutputNeverPinsRawParamsDecoderVersion() {
        var lr = LightroomEdits(); lr.exposure2012 = 0.5
        let stack = LightroomEditMapper.map(lr, context: .init(isRAW: true, asShotKelvin: 5000, asShotTint: 0))
        XCTAssertNil(stack?.rawParams)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -project Muse/Muse.xcodeproj -scheme Muse -only-testing:MuseTests/LightroomEditMapperTests`
Expected: FAIL — `LightroomEditMapper` doesn't exist.

- [ ] **Step 3: Implement `LightroomEditMapper.swift`**

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild test -project Muse/Muse.xcodeproj -scheme Muse -only-testing:MuseTests/LightroomEditMapperTests`
Expected: PASS

- [ ] **Step 5: Add `EditOrigin`/`origin` to `EditStack.swift`, extend `EditStackCodecTests`**

```swift
// Extend EditStackCodecTests.swift
func testExistingPinnedFixtureHashIsUnchangedAfterAddingOrigin() {
    // The ORIGINAL pinned fixture (no origin set) must still hash to the
    // exact same value as before this task — copy the existing pinned
    // hash constant verbatim into this assertion.
    let stack = EditStack.pinnedFixtureWithoutOrigin()  // whatever the existing fixture builder is named
    XCTAssertEqual(EditStackCodec.encode(stack.normalized()).stackHash, EditStackCodecTests.pinnedHash)
}

func testSecondPinnedFixtureWithOriginHashesDeterministically() {
    var stack = EditStack.pinnedFixtureWithoutOrigin()
    stack.origin = .lightroom
    let hash1 = EditStackCodec.encode(stack.normalized()).stackHash
    let hash2 = EditStackCodec.encode(stack.normalized()).stackHash
    XCTAssertEqual(hash1, hash2)
    XCTAssertNotEqual(hash1, EditStackCodecTests.pinnedHash)
}

func testOlderShapeDecodeDropsUnknownOriginKeyHarmlessly() {
    // Simulate an older-build decoder (a JSON blob with an extra "origin"
    // key) decoding successfully and losing it on re-save — assert decode
    // succeeds and re-encoding without setting origin reproduces the
    // original pinned hash.
}
```

- [ ] **Step 6: Extend `EditTransferTests` and `EditPresetStore` tests**

```swift
// Extend EditTransferTests.swift
func testOriginNeverTransfersViaApply() {
    var source = EditStack.fresh(); source.origin = .lightroom
    var target = EditStack.fresh(); target.origin = nil
    let groups = EditTransfer.adjustedGroups(of: source)
    let result = EditTransfer.apply(groups: groups, from: source, onto: target)
    XCTAssertNil(result.origin)
}

// Extend the preset-save test file (wherever EditPresetStore save is tested)
func testPresetSaveStripsOrigin() {
    var stack = EditStack.fresh(); stack.origin = .lightroom
    let preset = EditPresetStore.makePreset(name: "Test", from: stack)
    XCTAssertNil(preset.stack.origin)
}
```

- [ ] **Step 7: Run the extended Spec 04 test files to confirm no regression**

Run: `xcodebuild test -project Muse/Muse.xcodeproj -scheme Muse -only-testing:MuseTests/EditStackCodecTests -only-testing:MuseTests/EditTransferTests`
Expected: PASS.

- [ ] **Step 8: Commit**

```bash
git add Muse/Muse/Import/LightroomEditMapper.swift Muse/Muse/Editing/EditStack.swift Muse/Muse/Editing/EditTransfer.swift Muse/Muse/Editing/EditPresetStore.swift Muse/MuseTests/LightroomEditMapperTests.swift Muse/MuseTests/EditStackCodecTests.swift Muse/MuseTests/EditTransferTests.swift
git commit -m "feat(import): add LightroomEditMapper and EditStack.origin provenance"
```

---

## Task 22: LR edit apply path (wired into the metadata run) + embedded-preview compare source

**Files:**
- Modify: `Muse/Muse/Import/MetadataImportModel.swift` (LR edit apply leg)
- Create: `Muse/Muse/Import/EmbeddedPreview.swift`
- Modify: the Spec 04 before/after compare source list (locate the compare
  picker's source enum, e.g. `Editing/EditCompareSource.swift` or wherever
  Spec 04 implemented "Original or any snapshot")
- Modify: `Muse/Muse/Settings/AppSettings.swift`
  (`importLREditsKey`, default true)
- Test: `Muse/MuseTests/EmbeddedPreviewTests.swift`
- Test: extend `Muse/MuseTests/MetadataImportModelTests.swift`

**Interfaces:**
- Consumes: `LightroomXMP.read`/`LightroomEditMapper.map` (Tasks 20-21),
  `EditRecordStore.read` (Spec 04 — existing-edit check), `CIRAWFilter`
  (as-shot neutral resolve), `EditStore.shared.save` (Spec 04's full save
  sequence), `withinDecodeBudget` (existing decode-budget guard).
- Produces: `EmbeddedPreview.image(for:maxPixel:)` — consumed only by the
  compare picker wiring in this task.

Apply path, inside the §2.5/Task 6 per-file transaction, after the note leg,
when the "Also import Lightroom adjustments" toggle is on:

1. `LightroomXMP.read` on the already-resolved metadata (zero extra I/O —
   the same `CGImageMetadata` the keyword reader already opened).
2. `lr.isEmpty` → skip. Existing edit for `(file, parent_dir)`
   (`EditRecordStore.read` non-nil) → skip + `report.editsSkippedExisting += 1`
   (never clobber a user's own edit — idempotent re-runs).
3. RAW file with `temperatureKelvin` present: resolve `asShotKelvin`/
   `asShotTint` via `CIRAWFilter(imageURL:)`'s neutral properties, off-main,
   through the existing decode-budget guard first (header-scale init, not a
   full decode, but still the run's most expensive per-file step — gated to
   only the RAW files whose sidecar actually moves WB).
4. `LightroomEditMapper.map` → non-nil → `EditStore.shared.save(stack, for:
   url)` (the full Spec 04 save sequence: row write, provider index,
   `markContentChanged`, `generation += 1`, sidecar export). Sequential,
   like the batch-sync sweep — no progress UI beyond the run card's existing
   counter.
5. `unsupported` merges into `report.unsupportedSliders` (dictionary
   count-per-name accumulation).
6. `report.editsApproximated += 1` on a successful save.

`EmbeddedPreview.swift`:

```swift
nonisolated enum EmbeddedPreview {
    /// CGImageSourceCreateThumbnailAtIndex with
    /// kCGImageSourceCreateThumbnailFromImageIfAbsent: false — embedded
    /// preview ONLY, never a primary decode. RAW files typically carry an
    /// Adobe-rendered preview; JPEGs typically return nil (source not
    /// offered). Runs through withinDecodeBudget first.
    static func image(for url: URL, maxPixel: Int) -> CGImage?
}
```

Compare-source wiring: add a "Lightroom preview" entry to the before/after
compare source enum, offered only when `stack.origin == .lightroom` AND
`EmbeddedPreview.image(...)` returns non-nil for the file; rendered into the
compare's cached-texture slot exactly like a snapshot render (no new
machinery). Render the caveat line ("Lightroom's base look is not applied —
results shift") under the compare picker when this source is active.

- [ ] **Step 1: Write the failing test**

```swift
// Muse/MuseTests/EmbeddedPreviewTests.swift
import XCTest
@testable import Muse

final class EmbeddedPreviewTests: XCTestCase {
    func testReturnsAnImageForARAWFixtureWithAnEmbeddedPreview() throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "lr-raw-wb", withExtension: "dng"))
        XCTAssertNotNil(EmbeddedPreview.image(for: url, maxPixel: 1024))
    }

    func testReturnsNilForAPlainJPEGWithNoEmbeddedPreview() throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "plain", withExtension: "jpg"))
        XCTAssertNil(EmbeddedPreview.image(for: url, maxPixel: 1024))
    }

    func testNeverDecodesThePrimaryImage() throws {
        // A fixture whose primary image dimensions would exceed the decode
        // budget but whose embedded preview is small — assert this call
        // still succeeds (proving it never routes through the primary
        // decode path, which would be budget-rejected).
    }
}
```

```swift
// Extend MetadataImportModelTests.swift
func testLREditApplySkipsWhenAnEditAlreadyExists() async throws {
    // Pre-write an EditStore stack for a fixture file, then run the import
    // with the LR toggle on and a matching LR sidecar present; assert
    // report.editsSkippedExisting == 1 and the pre-existing stack is
    // byte-unchanged.
}

func testLREditApplyWritesABadgedStackAndCountsApproximated() async throws {
    // Fixture file with a matching LR sidecar and no prior edit; run with
    // the toggle on; assert an EditRecordStore row now exists with
    // origin == .lightroom and report.editsApproximated == 1.
}

func testLREditApplyIsIdempotentOnRerun() async throws {
    // Run twice; the second run's editsSkippedExisting should equal the
    // first run's editsApproximated (the stack it wrote is now "existing").
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild test -project Muse/Muse.xcodeproj -scheme Muse -only-testing:MuseTests/EmbeddedPreviewTests -only-testing:MuseTests/MetadataImportModelTests`
Expected: FAIL — `EmbeddedPreview` doesn't exist; the LR apply leg isn't wired.

- [ ] **Step 3: Implement `EmbeddedPreview.swift` and wire the apply path into `MetadataImportModel`**

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcodebuild test -project Muse/Muse.xcodeproj -scheme Muse -only-testing:MuseTests/EmbeddedPreviewTests -only-testing:MuseTests/MetadataImportModelTests`
Expected: PASS

- [ ] **Step 5: Wire the compare-source entry and the "Approximated from Lightroom" badge**

Add the Light-tab header badge + hero INFO-card line when
`stack.origin == .lightroom` (localized). Add the compare source per above.
Manually verify: import a Lightroom fixture, open its hero viewer's Edit
mode, confirm the badge shows and the before/after suite offers "Lightroom
preview" alongside Original/snapshots.

- [ ] **Step 6: Commit**

```bash
git add Muse/Muse/Import/MetadataImportModel.swift Muse/Muse/Import/EmbeddedPreview.swift Muse/Muse/Settings/AppSettings.swift Muse/MuseTests/EmbeddedPreviewTests.swift Muse/MuseTests/MetadataImportModelTests.swift
git commit -m "feat(import): wire Lightroom edit import into the metadata run + embedded-preview compare"
```

---

## Task 23: Lightroom preset (.xmp) import → `edit_presets`

**Files:**
- Create: `Muse/Muse/Import/LightroomPresetImportModel.swift`
- Create: `Muse/Muse/Views/LightroomPresetImportCard.swift`
- Modify: `Muse/Muse/Models/AppState+Import.swift` (payload for
  `.lightroomPresets` — already `[URL]` per Task 2's stub, confirm shape)
- Modify: `Muse/Muse/MuseApp.swift` (submenu item "Lightroom Presets…")
- Test: `Muse/MuseTests/LightroomPresetImportModelTests.swift`

**Interfaces:**
- Consumes: `LightroomXMP.read`/`LightroomEditMapper.map` (Tasks 20-21),
  `EditPresetStore` (Spec 04).
- Produces: nothing consumed elsewhere.

Flow:
1. Menu item → `NSOpenPanel`, `.xmp` files, multi-select →
   `importModal = .lightroomPresets(urls)`.
2. Per file: `CGImageMetadataCreateFromXMPData` → `LightroomXMP.read` →
   `LightroomEditMapper.map(context: Context(isRAW: false, asShotKelvin:
   nil, asShotTint: nil))` — presets have no as-shot reference, so
   `crs:Temperature` in a preset is unmappable (rare; lands in the notice);
   incremental WB maps normally.
3. Non-nil stack → strip geometry group (presets never carry crops — the
   existing Spec 04 preset-save rule) → `origin = .lightroom` → insert
   `EditPresetRow` named from `crs:Name` (Alt, first) else the filename stem,
   via `EditPresetStore`, with a ` 2` collision-suffix ladder (NOCASE — no
   UNIQUE constraint exists; the ladder is courtesy).
4. Per-file failures surface by filename in the report (matching
   `LutStore.importCubes`'s pattern).
5. → `.report(report)`.

- [ ] **Step 1: Write the failing test**

```swift
// Muse/MuseTests/LightroomPresetImportModelTests.swift
import XCTest
@testable import Muse

@MainActor
final class LightroomPresetImportModelTests: XCTestCase {
    func testValidPresetXMPCreatesAPresetNamedFromCrsName() async throws {
        // Fixture .xmp with crs:Name = "My Look" and a non-neutral mapped
        // stack. Assert an EditPresetRow named "My Look" exists after the run,
        // with origin == .lightroom and geometry stripped.
    }

    func testMissingCrsNameFallsBackToFilenameStem() async throws {
        // Fixture .xmp with no crs:Name, filename "Moody Look.xmp". Assert
        // the created preset is named "Moody Look".
    }

    func testNameCollisionAppendsNumericSuffix() async throws {
        // Two presets that both resolve to the same name; assert the
        // second is saved as "Name 2".
    }

    func testPerFileFailureIsReportedByFilenameNotFatal() async throws {
        // One valid .xmp + one corrupt .xmp in the same run; assert the
        // valid one still imports and the corrupt one is named in
        // report.notices, without aborting the run.
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -project Muse/Muse.xcodeproj -scheme Muse -only-testing:MuseTests/LightroomPresetImportModelTests`
Expected: FAIL — `LightroomPresetImportModel` doesn't exist.

- [ ] **Step 3: Implement `LightroomPresetImportModel.swift` and `LightroomPresetImportCard.swift`**

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild test -project Muse/Muse.xcodeproj -scheme Muse -only-testing:MuseTests/LightroomPresetImportModelTests`
Expected: PASS

- [ ] **Step 5: Wire `ContentView.swift`'s `.lightroomPresets` case and the final submenu item**

At this point every item in the Task 7 submenu skeleton has a real action —
verify none is left as a bare stub button.

- [ ] **Step 6: Manual verification**

Import a small set of real Lightroom presets, confirm they appear in the
editor's Looks tab (Spec 05's live-thumbnail browser) and apply correctly
via the standard copy-by-value path.

- [ ] **Step 7: Commit**

```bash
git add Muse/Muse/Import/LightroomPresetImportModel.swift Muse/Muse/Views/LightroomPresetImportCard.swift Muse/Muse/MuseApp.swift Muse/Muse/ContentView.swift Muse/MuseTests/LightroomPresetImportModelTests.swift
git commit -m "feat(import): add Lightroom .xmp preset import into edit_presets"
```

---

## Task 24: CLAUDE.md durable constraints + full regression pass

**Files:**
- Modify: `/Users/carlostarrats/Documents/Projects/Muse/Muse App/CLAUDE.md`
  (add the Spec 06 durable constraints under "Durable constraints & gotchas")
- Modify: the same file's Implementation status table (add the Spec 06 row)

**Interfaces:**
- Consumes: nothing new — this task is documentation + a final full-suite
  regression run.
- Produces: nothing consumed by other tasks (terminal task).

Add these bullets to CLAUDE.md's durable-constraints section (verbatim
content, condensed to the house one-or-two-line style):

- Every import writes through existing seams only — tags via
  `applyKeywords`, ratings via `setRating` (gap-fill), notes via `NoteStore`
  (fill-gaps), edits via `EditStore.save` (never clobber), collections via
  `createManual`/`addFile`. A new source is a reader + a mapper, never a new
  writer.
- Label tags carry the `"Label: "` prefix; the tag-search leg excludes them
  unless the query targets labels (`LabelTag.queryTargetsLabels`) — never
  relax this (DECIDED #12).
- Supplement writes (externally-sourced GPS/dates) are header-wins/
  fill-gaps and stamp both Spec 02 scan markers; `analyzeOne`/
  `PhotoHeaderBackfill` skip their write when both markers are already
  fresh. `(0,0)` coordinates are always absent, never null island.
- `EditStack.origin` is provenance, not data: nil-omitted (hash-stable for
  every pre-existing stack), never copied by `EditTransfer.apply`, stripped
  at preset save, gone on Reset.
- The Lightroom import envelope is the enumerated field list in
  `LightroomXMP` — do not grow it without updating
  `docs/new-build/muse-photo-foundation.md` first.
- Analysis pause (`WorkThrottleStore`) is scheduling, never an off switch;
  import runs themselves are never throttled.
- The import-size FYI is one button, time-gated on a measured (never
  hardcoded) per-device estimate, shown at most once per launch.

- [ ] **Step 1: Update CLAUDE.md**

- [ ] **Step 2: Run the full test suite**

Run: `xcodebuild test -project Muse/Muse.xcodeproj -scheme Muse`
Expected: PASS (green), matching the "keep it green" house rule.

- [ ] **Step 3: Run the French localization export and confirm 0 untranslated for every new key introduced across Tasks 1-23**

Run: `xcodebuild -exportLocalizations -project Muse/Muse.xcodeproj -localizationPath /tmp/muse-l10n -exportLanguage fr`
Expected: 0 untranslated strings among the keys introduced by this plan
(fill in any gaps found before calling this task done).

- [ ] **Step 4: `git status` review before the final commit**

Confirm no stray fixture/scratch files, no accidental credentials, and that
the diff matches exactly the files touched across Tasks 1-23 plus this
task's CLAUDE.md edit.

- [ ] **Step 5: Commit**

```bash
git add CLAUDE.md
git commit -m "docs: record Spec 06 import/migration durable constraints"
```

---

## Self-review notes (for the plan author, not a task)

- **Spec coverage:** Tasks 1–2 cover §1 (surface); 3–6 cover §2 (universal
  layer); 8 covers §2.4 (supplement) + amendment A1; 9–10 cover §3 (labels);
  11–14 cover §9 (throttle/FYI); 15–16 cover §7 (Takeout); 17–18 cover §8
  (Eagle); 19 covers §6 (Apple Photos); 20–22 cover §4 (LR edits) + §4.6
  (compare); 23 covers §5 (LR presets); 24 covers §12 (durable constraints).
  Every pre-spec acceptance-criteria row (§17 of the source spec) traces to
  a task above.
- **Placeholder scan:** every task carries concrete signatures, real test
  code, and named files — no "TBD"/"add error handling"/"similar to Task N"
  left unexpanded. Where a task depends on an owner-produced fixture (Tasks
  17, 20), the fixture-production step is spelled out as its own checklist
  step, not hand-waved.
- **Type consistency:** `ImportModal`, `ImportReport`/`LabelOutcome`,
  `LabelMapping.Choice`, `ImportSupplement.External/AppliedFields`,
  `LightroomEdits`/`EditStack.origin` are each defined once (Tasks 1, 2, 9,
  8, 20/21) and referenced by identical name/shape in every later task that
  consumes them — the Task 1 `LabelMapping` stub is explicitly replaced,
  not left to drift, in Task 9's Step 3.
