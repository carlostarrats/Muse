# Grid Faceted Filters (kind / date / size) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a toolbar funnel control that narrows the visible grid tiles by kind, modified-date preset, and size bucket — stacking with the existing tag/collection filters and search.

**Architecture:** A pure, unit-tested `GridFilter` value type + matcher (mirroring `ImageLayout`/`TileBackground`), persisted via `AppSettings` and mirrored on `AppState` as a `@Published` property whose `didSet` invalidates the `visibleFiles` memo. `visibleFiles` applies the matcher as a final narrowing pass on every branch (browse / collection / tag / search). A new `GridFilterPopover` + a funnel toolbar button drive `appState.gridFilter`.

**Tech Stack:** Swift 6, SwiftUI, XCTest. macOS 14.6+. No new dependencies.

## Global Constraints

- **Pure model + AppSettings mirror + AppState `@Published` + memo invalidation** — reuse the exact pattern of `imageLayout` / `tileBackground`. No new architecture.
- **No network, no new entitlements.** Pure local work over data `FileNode` already carries.
- **Files are never deleted** — this is a view-narrowing filter only; it touches no files.
- **`FileNode` already carries `kind: AssetKind`, `sizeBytes: Int64?`, `modifiedAt: Date?`** — the matcher reads these directly. Do NOT add new `resourceValues` reads.
- **Filter applies to search results too** — the funnel button must stay enabled during search (unlike the sort cluster, which is `.disabled(appState.isSearchActive)`).
- **Tests:** pure model only (`GridFilterTests`); SwiftUI popover/toolbar verified by build + manual per convention.
- **Build/test commands** (run from repo root `/Users/carlostarrats/Documents/Projects/Muse/Muse App`):
  - Build: `xcodebuild -project Muse/Muse.xcodeproj -scheme Muse -destination 'platform=macOS' build`
  - Test (one suite): `xcodebuild -project Muse/Muse.xcodeproj -scheme Muse -destination 'platform=macOS' test -only-testing:MuseTests/GridFilterTests`
  - Full suite: `xcodebuild -project Muse/Muse.xcodeproj -scheme Muse -destination 'platform=macOS' test`

---

## File Structure

- **Create** `Muse/Muse/Models/GridFilter.swift` — the pure model: `KindFacet`, `DateFacet`, `SizeFacet` enums + `GridFilter` struct (matcher, `isActive`, Codable, `resolve`).
- **Create** `Muse/MuseTests/GridFilterTests.swift` — pure unit tests.
- **Modify** `Muse/Muse/Settings/AppSettings.swift` — add the `gridFilter` JSON accessor.
- **Modify** `Muse/Muse/Models/AppState.swift` — add `@Published var gridFilter` (persist + memo-invalidate in `didSet`).
- **Modify** `Muse/Muse/Models/AppState+Filters.swift` — apply the matcher as the final narrowing step in `visibleFiles`.
- **Create** `Muse/Muse/Views/GridFilterPopover.swift` — the three-section popover + Clear All.
- **Modify** `Muse/Muse/ContentView.swift` — add the funnel toolbar button (engaged-blue) + popover state.

---

## Task 1: `GridFilter` pure model + matcher

**Files:**
- Create: `Muse/Muse/Models/GridFilter.swift`
- Test: `Muse/MuseTests/GridFilterTests.swift`

**Interfaces:**
- Consumes: `AssetKind` (from `Muse/Muse/Models/AssetKind.swift`, all 16 cases).
- Produces (later tasks rely on these exact names/types):
  - `enum KindFacet: String, CaseIterable, Identifiable, Codable { case image, video, pdf, document, audio, other }` with `var id: String`, `var displayName: String`, `init(from kind: AssetKind)`.
  - `enum DateFacet: String, CaseIterable, Identifiable, Codable { case any, today, week, month, year }` with `var id: String`, `var displayName: String`.
  - `enum SizeFacet: String, CaseIterable, Identifiable, Codable { case any, under1MB, mb1to10, mb10to100, over100MB }` with `var id: String`, `var displayName: String`.
  - `struct GridFilter: Equatable, Codable { var kinds: Set<KindFacet>; var date: DateFacet; var size: SizeFacet }` with `static let none`, `var isActive: Bool`, `func matches(kind:sizeBytes:modified:now:) -> Bool`, `static func resolve(_ raw: String?) -> GridFilter`.

- [ ] **Step 1: Write the failing test**

Create `Muse/MuseTests/GridFilterTests.swift`:

```swift
import XCTest
@testable import Muse

final class GridFilterTests: XCTestCase {

    // Fixed "now": Wed 2026-06-17 12:00:00 local. Mid-week, mid-month, mid-year.
    private func fixedNow() -> Date {
        var c = DateComponents()
        c.year = 2026; c.month = 6; c.day = 17; c.hour = 12; c.minute = 0; c.second = 0
        return Calendar.current.date(from: c)!
    }

    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 12) -> Date {
        var c = DateComponents()
        c.year = y; c.month = m; c.day = d; c.hour = h
        return Calendar.current.date(from: c)!
    }

    // MARK: - KindFacet mapping

    func testKindFacetBucketing() {
        XCTAssertEqual(KindFacet(from: .image), .image)
        XCTAssertEqual(KindFacet(from: .raw), .image)
        XCTAssertEqual(KindFacet(from: .psd), .image)
        XCTAssertEqual(KindFacet(from: .svg), .image)
        XCTAssertEqual(KindFacet(from: .video), .video)
        XCTAssertEqual(KindFacet(from: .pdf), .pdf)
        XCTAssertEqual(KindFacet(from: .text), .document)
        XCTAssertEqual(KindFacet(from: .markdown), .document)
        XCTAssertEqual(KindFacet(from: .code), .document)
        XCTAssertEqual(KindFacet(from: .office), .document)
        XCTAssertEqual(KindFacet(from: .audio), .audio)
        XCTAssertEqual(KindFacet(from: .model3d), .other)
        XCTAssertEqual(KindFacet(from: .font), .other)
        XCTAssertEqual(KindFacet(from: .archive), .other)
        XCTAssertEqual(KindFacet(from: .folder), .other)
        XCTAssertEqual(KindFacet(from: .unknown), .other)
    }

    // MARK: - isActive

    func testNoneIsInactive() {
        XCTAssertFalse(GridFilter.none.isActive)
        XCTAssertEqual(GridFilter.none.kinds, [])
        XCTAssertEqual(GridFilter.none.date, .any)
        XCTAssertEqual(GridFilter.none.size, .any)
    }

    func testIsActiveWhenAnyFacetSet() {
        XCTAssertTrue(GridFilter(kinds: [.image], date: .any, size: .any).isActive)
        XCTAssertTrue(GridFilter(kinds: [], date: .today, size: .any).isActive)
        XCTAssertTrue(GridFilter(kinds: [], date: .any, size: .over100MB).isActive)
    }

    // MARK: - Kind matching

    func testEmptyKindsMatchesEverything() {
        let f = GridFilter.none
        let now = fixedNow()
        XCTAssertTrue(f.matches(kind: .image, sizeBytes: 5, modified: now, now: now))
        XCTAssertTrue(f.matches(kind: .folder, sizeBytes: 5, modified: now, now: now))
    }

    func testKindConstraintNarrows() {
        let f = GridFilter(kinds: [.pdf], date: .any, size: .any)
        let now = fixedNow()
        XCTAssertTrue(f.matches(kind: .pdf, sizeBytes: 5, modified: now, now: now))
        XCTAssertFalse(f.matches(kind: .image, sizeBytes: 5, modified: now, now: now))
        XCTAssertTrue(GridFilter(kinds: [.image, .video], date: .any, size: .any)
            .matches(kind: .video, sizeBytes: 5, modified: now, now: now))
    }

    // MARK: - Date windows (modified date, against fixedNow)

    func testDateAnyMatchesAnyDateAndNilModified() {
        let f = GridFilter(kinds: [], date: .any, size: .any)
        let now = fixedNow()
        XCTAssertTrue(f.matches(kind: .image, sizeBytes: 5, modified: date(1999, 1, 1), now: now))
        XCTAssertTrue(f.matches(kind: .image, sizeBytes: 5, modified: nil, now: now))
    }

    func testDateToday() {
        let f = GridFilter(kinds: [], date: .today, size: .any)
        let now = fixedNow()
        XCTAssertTrue(f.matches(kind: .image, sizeBytes: 5, modified: date(2026, 6, 17, 0), now: now))
        XCTAssertTrue(f.matches(kind: .image, sizeBytes: 5, modified: date(2026, 6, 17, 23), now: now))
        XCTAssertFalse(f.matches(kind: .image, sizeBytes: 5, modified: date(2026, 6, 16, 23), now: now))
    }

    func testDateThisWeek() {
        let f = GridFilter(kinds: [], date: .week, size: .any)
        let now = fixedNow()
        // Something earlier this same week matches; last week does not.
        XCTAssertTrue(f.matches(kind: .image, sizeBytes: 5, modified: now, now: now))
        XCTAssertFalse(f.matches(kind: .image, sizeBytes: 5, modified: date(2026, 6, 1), now: now))
    }

    func testDateThisMonth() {
        let f = GridFilter(kinds: [], date: .month, size: .any)
        let now = fixedNow()
        XCTAssertTrue(f.matches(kind: .image, sizeBytes: 5, modified: date(2026, 6, 1, 0), now: now))
        XCTAssertFalse(f.matches(kind: .image, sizeBytes: 5, modified: date(2026, 5, 31, 23), now: now))
    }

    func testDateThisYear() {
        let f = GridFilter(kinds: [], date: .year, size: .any)
        let now = fixedNow()
        XCTAssertTrue(f.matches(kind: .image, sizeBytes: 5, modified: date(2026, 1, 1, 0), now: now))
        XCTAssertFalse(f.matches(kind: .image, sizeBytes: 5, modified: date(2025, 12, 31, 23), now: now))
    }

    func testDateConstraintRejectsNilModified() {
        let now = fixedNow()
        for facet in [DateFacet.today, .week, .month, .year] {
            let f = GridFilter(kinds: [], date: facet, size: .any)
            XCTAssertFalse(f.matches(kind: .image, sizeBytes: 5, modified: nil, now: now),
                           "\(facet) must reject a nil modified date")
        }
    }

    // MARK: - Size buckets (decimal MB = 1_000_000 bytes)

    func testSizeBuckets() {
        let now = fixedNow()
        func f(_ s: SizeFacet) -> GridFilter { GridFilter(kinds: [], date: .any, size: s) }

        // < 1 MB
        XCTAssertTrue(f(.under1MB).matches(kind: .image, sizeBytes: 999_999, modified: now, now: now))
        XCTAssertFalse(f(.under1MB).matches(kind: .image, sizeBytes: 1_000_000, modified: now, now: now))
        // 1–10 MB
        XCTAssertTrue(f(.mb1to10).matches(kind: .image, sizeBytes: 1_000_000, modified: now, now: now))
        XCTAssertTrue(f(.mb1to10).matches(kind: .image, sizeBytes: 9_999_999, modified: now, now: now))
        XCTAssertFalse(f(.mb1to10).matches(kind: .image, sizeBytes: 10_000_000, modified: now, now: now))
        // 10–100 MB
        XCTAssertTrue(f(.mb10to100).matches(kind: .image, sizeBytes: 10_000_000, modified: now, now: now))
        XCTAssertFalse(f(.mb10to100).matches(kind: .image, sizeBytes: 100_000_000, modified: now, now: now))
        // > 100 MB
        XCTAssertTrue(f(.over100MB).matches(kind: .image, sizeBytes: 100_000_000, modified: now, now: now))
        XCTAssertFalse(f(.over100MB).matches(kind: .image, sizeBytes: 99_999_999, modified: now, now: now))
    }

    func testSizeConstraintRejectsNilSize() {
        let now = fixedNow()
        for facet in [SizeFacet.under1MB, .mb1to10, .mb10to100, .over100MB] {
            let f = GridFilter(kinds: [], date: .any, size: facet)
            XCTAssertFalse(f.matches(kind: .image, sizeBytes: nil, modified: now, now: now),
                           "\(facet) must reject a nil size")
        }
        // .any tolerates nil size.
        XCTAssertTrue(GridFilter(kinds: [], date: .any, size: .any)
            .matches(kind: .image, sizeBytes: nil, modified: now, now: now))
    }

    // MARK: - Combined facets

    func testAllThreeFacetsTogether() {
        let f = GridFilter(kinds: [.image], date: .month, size: .mb1to10)
        let now = fixedNow()
        // matches all three
        XCTAssertTrue(f.matches(kind: .image, sizeBytes: 5_000_000, modified: date(2026, 6, 10), now: now))
        // wrong kind
        XCTAssertFalse(f.matches(kind: .pdf, sizeBytes: 5_000_000, modified: date(2026, 6, 10), now: now))
        // wrong size
        XCTAssertFalse(f.matches(kind: .image, sizeBytes: 50_000_000, modified: date(2026, 6, 10), now: now))
        // wrong date
        XCTAssertFalse(f.matches(kind: .image, sizeBytes: 5_000_000, modified: date(2026, 4, 1), now: now))
    }

    // MARK: - resolve / Codable round-trip

    func testResolveDefaultsToNone() {
        XCTAssertEqual(GridFilter.resolve(nil), .none)
        XCTAssertEqual(GridFilter.resolve("not json"), .none)
    }

    func testCodableRoundTripViaResolve() throws {
        let original = GridFilter(kinds: [.image, .pdf], date: .week, size: .mb10to100)
        let data = try JSONEncoder().encode(original)
        let json = String(data: data, encoding: .utf8)
        XCTAssertEqual(GridFilter.resolve(json), original)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -project Muse/Muse.xcodeproj -scheme Muse -destination 'platform=macOS' test -only-testing:MuseTests/GridFilterTests`
Expected: BUILD FAILURE / compile error — `GridFilter`, `KindFacet`, etc. are undefined.

- [ ] **Step 3: Write the implementation**

Create `Muse/Muse/Models/GridFilter.swift`:

```swift
//
//  GridFilter.swift
//  Muse
//
//  Pure, unit-testable faceted filter for the grid: narrow the visible tiles by
//  kind (image/video/pdf/document/audio/other), modified-date preset, and size
//  bucket. Mirrors the shape of ImageLayout / TileBackground — a value type +
//  matcher persisted via AppSettings and mirrored on AppState. `matches` takes
//  raw inputs (kind/size/modified) and an injected `now` so date windows are
//  deterministic in tests; the source of those values (FileNode) is an
//  implementation detail of the caller. NOT a sort — it removes non-matching
//  files from whichever set is active (folder / collection / tag / search).
//

import Foundation

/// Grouped kind buckets the filter exposes. Several `AssetKind`s collapse into
/// each bucket (e.g. raw/psd/svg → image); anything unhandled → `.other`.
enum KindFacet: String, CaseIterable, Identifiable, Codable {
    case image, video, pdf, document, audio, other

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .image:    return "Images"
        case .video:    return "Videos"
        case .pdf:      return "PDFs"
        case .document: return "Documents"
        case .audio:    return "Audio"
        case .other:    return "Other"
        }
    }

    init(from kind: AssetKind) {
        switch kind {
        case .image, .raw, .psd, .svg:        self = .image
        case .video:                          self = .video
        case .pdf:                            self = .pdf
        case .text, .markdown, .code, .office: self = .document
        case .audio:                          self = .audio
        case .model3d, .font, .archive, .folder, .unknown:
            self = .other
        }
    }
}

/// Modified-date preset. `.any` = no date constraint.
enum DateFacet: String, CaseIterable, Identifiable, Codable {
    case any, today, week, month, year

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .any:   return "Any"
        case .today: return "Today"
        case .week:  return "This Week"
        case .month: return "This Month"
        case .year:  return "This Year"
        }
    }

    /// Inclusive lower bound of the window relative to `now`, or nil for `.any`.
    func windowStart(now: Date, calendar: Calendar = .current) -> Date? {
        switch self {
        case .any:   return nil
        case .today: return calendar.startOfDay(for: now)
        case .week:  return calendar.dateInterval(of: .weekOfYear, for: now)?.start
        case .month: return calendar.dateInterval(of: .month, for: now)?.start
        case .year:  return calendar.dateInterval(of: .year, for: now)?.start
        }
    }
}

/// Size bucket using decimal MB (1 MB = 1,000,000 bytes, matching Finder).
/// `.any` = no size constraint.
enum SizeFacet: String, CaseIterable, Identifiable, Codable {
    case any, under1MB, mb1to10, mb10to100, over100MB

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .any:       return "Any"
        case .under1MB:  return "< 1 MB"
        case .mb1to10:   return "1–10 MB"
        case .mb10to100: return "10–100 MB"
        case .over100MB: return "> 100 MB"
        }
    }

    private static let MB: Int64 = 1_000_000

    func contains(_ bytes: Int64) -> Bool {
        switch self {
        case .any:       return true
        case .under1MB:  return bytes < 1 * Self.MB
        case .mb1to10:   return bytes >= 1 * Self.MB && bytes < 10 * Self.MB
        case .mb10to100: return bytes >= 10 * Self.MB && bytes < 100 * Self.MB
        case .over100MB: return bytes >= 100 * Self.MB
        }
    }
}

struct GridFilter: Equatable, Codable {
    /// Empty = no kind constraint (all kinds shown).
    var kinds: Set<KindFacet>
    var date: DateFacet
    var size: SizeFacet

    static let none = GridFilter(kinds: [], date: .any, size: .any)

    /// True when any facet constrains the result.
    var isActive: Bool {
        !kinds.isEmpty || date != .any || size != .any
    }

    /// Pure predicate. `now` injected so date windows are deterministic in tests.
    func matches(kind: AssetKind, sizeBytes: Int64?, modified: Date?, now: Date) -> Bool {
        if !kinds.isEmpty {
            guard kinds.contains(KindFacet(from: kind)) else { return false }
        }
        if let start = date.windowStart(now: now) {
            guard let modified, modified >= start else { return false }
        }
        if size != .any {
            guard let sizeBytes, size.contains(sizeBytes) else { return false }
        }
        return true
    }

    /// Decode a persisted JSON string, defaulting to `.none` when missing/invalid.
    static func resolve(_ raw: String?) -> GridFilter {
        guard let raw, let data = raw.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(GridFilter.self, from: data)
        else { return .none }
        return decoded
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild -project Muse/Muse.xcodeproj -scheme Muse -destination 'platform=macOS' test -only-testing:MuseTests/GridFilterTests`
Expected: `** TEST SUCCEEDED **` — all `GridFilterTests` pass.

- [ ] **Step 5: Commit**

```bash
git add "Muse/Muse/Models/GridFilter.swift" "Muse/MuseTests/GridFilterTests.swift"
git commit -m "feat: GridFilter pure model + matcher (kind/date/size facets)"
```

---

## Task 2: Persistence — `AppSettings.gridFilter` + `AppState.gridFilter`

**Files:**
- Modify: `Muse/Muse/Settings/AppSettings.swift`
- Modify: `Muse/Muse/Models/AppState.swift`

**Interfaces:**
- Consumes: `GridFilter` (Task 1).
- Produces:
  - `AppSettings.gridFilter: GridFilter` (UserDefaults key `muse.gridFilter`, JSON-encoded, default `.none`).
  - `AppState.gridFilter: GridFilter` — `@Published`, default `AppSettings.gridFilter`; `didSet` persists to `AppSettings` AND sets `_visibleFilesValid = false`.

- [ ] **Step 1: Add the `AppSettings` accessor**

In `Muse/Muse/Settings/AppSettings.swift`, alongside the existing `imageLayout` / `tileBackground` accessors, add the key constant (with the other key constants) and the accessor (with the other accessors):

```swift
    private static let gridFilterKey = "muse.gridFilter"

    static var gridFilter: GridFilter {
        get { GridFilter.resolve(UserDefaults.standard.string(forKey: gridFilterKey)) }
        set {
            // Persist as a JSON string (GridFilter is Codable, not a single
            // rawValue like imageLayout/tileBackground).
            if let data = try? JSONEncoder().encode(newValue),
               let json = String(data: data, encoding: .utf8) {
                UserDefaults.standard.set(json, forKey: gridFilterKey)
            }
        }
    }
```

- [ ] **Step 2: Add the `AppState` published property**

In `Muse/Muse/Models/AppState.swift`, next to the existing `imageLayout` / `tileBackground` declarations (around lines 412–422), add:

```swift
    /// The grid faceted filter (kind / date / size). Persisted to AppSettings;
    /// its didSet invalidates the visibleFiles memo exactly like the other
    /// filter inputs (currentFiles / activeCollectionFiles / activeTagPaths).
    @Published var gridFilter: GridFilter = AppSettings.gridFilter {
        didSet {
            AppSettings.gridFilter = gridFilter
            _visibleFilesValid = false
        }
    }
```

- [ ] **Step 3: Build to verify it compiles**

Run: `xcodebuild -project Muse/Muse.xcodeproj -scheme Muse -destination 'platform=macOS' build`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Commit**

```bash
git add "Muse/Muse/Settings/AppSettings.swift" "Muse/Muse/Models/AppState.swift"
git commit -m "feat: persist gridFilter (AppSettings + AppState, memo-invalidating)"
```

---

## Task 3: `visibleFiles` facet narrowing

**Files:**
- Modify: `Muse/Muse/Models/AppState+Filters.swift` (`visibleFiles`, lines 35–55)

**Interfaces:**
- Consumes: `AppState.gridFilter` (Task 2), `GridFilter.matches` (Task 1), `FileNode.kind` / `.sizeBytes` / `.modifiedAt`.
- Produces: a `visibleFiles` that, when `gridFilter.isActive`, removes non-matching nodes on **every** branch (search + browse/collection/tag).

- [ ] **Step 1: Replace the `visibleFiles` body**

In `Muse/Muse/Models/AppState+Filters.swift`, replace the existing `visibleFiles` computed property (lines 35–55) with:

```swift
    var visibleFiles: [FileNode] {
        // Memoized: recomputed only after one of the inputs changes (they
        // invalidate the cache via didSet in AppState). The grid reads this many
        // times per render; without the cache the tag filter below re-standardized
        // every path on every read. See `_visibleFilesCache`.
        if _visibleFilesValid { return _visibleFilesCache }
        // search results are global; collection/tag filters apply to browsing only
        var base: [FileNode]
        if isSearchActive {
            base = currentFiles
        } else {
            base = activeCollectionFiles ?? currentFiles
            if let tagPaths = activeTagPaths {
                base = base.filter { tagPaths.contains($0.url.standardizedFileURL.path) }
            }
        }
        // Facet filter: the final narrowing step, applied to ALL branches
        // (search included). Reads the values FileNode already carries — no
        // extra resourceValues hit; the memo means this runs only when an
        // input actually changed, not on every grid render.
        let result: [FileNode]
        if gridFilter.isActive {
            let now = Date()
            result = base.filter {
                gridFilter.matches(kind: $0.kind,
                                   sizeBytes: $0.sizeBytes,
                                   modified: $0.modifiedAt,
                                   now: now)
            }
        } else {
            result = base
        }
        _visibleFilesCache = result
        _visibleFilesValid = true
        return result
    }
```

- [ ] **Step 2: Build to verify it compiles**

Run: `xcodebuild -project Muse/Muse.xcodeproj -scheme Muse -destination 'platform=macOS' build`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Run the full test suite to verify no regression**

Run: `xcodebuild -project Muse/Muse.xcodeproj -scheme Muse -destination 'platform=macOS' test`
Expected: `** TEST SUCCEEDED **` — existing suite + `GridFilterTests` all green.

- [ ] **Step 4: Commit**

```bash
git add "Muse/Muse/Models/AppState+Filters.swift"
git commit -m "feat: apply gridFilter as final narrowing step in visibleFiles (all branches)"
```

---

## Task 4: Funnel toolbar button + `GridFilterPopover`

**Files:**
- Create: `Muse/Muse/Views/GridFilterPopover.swift`
- Modify: `Muse/Muse/ContentView.swift` (add popover state + the funnel `ToolbarItem`)

**Interfaces:**
- Consumes: `AppState.gridFilter` (Task 2), `KindFacet` / `DateFacet` / `SizeFacet` (Task 1), `moodToolbarIcon(_:selected:)` (ContentView private extension), `MoodPalette` (Models/Mood.swift).
- Produces: a funnel button in the toolbar that opens `GridFilterPopover` and shows the native accent (blue, white icon) when `gridFilter.isActive`.

- [ ] **Step 1: Create the popover view**

Create `Muse/Muse/Views/GridFilterPopover.swift`:

```swift
//
//  GridFilterPopover.swift
//  Muse
//
//  The funnel-button popover: three stacked sections (Kind checkboxes, Date
//  radio, Size radio) + Clear All, writing AppState.gridFilter. Styled like the
//  mood picker (270 wide, 16pt padding/spacing, dividers between sections).
//

import SwiftUI

struct GridFilterPopover: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // KIND (multi-select checkboxes)
            VStack(alignment: .leading, spacing: 8) {
                sectionHeader("KIND")
                ForEach(KindFacet.allCases) { facet in
                    Toggle(facet.displayName, isOn: kindBinding(facet))
                        .toggleStyle(.checkbox)
                }
            }

            Divider()

            // DATE (single-select radio, modified date)
            VStack(alignment: .leading, spacing: 8) {
                sectionHeader("DATE")
                Picker("", selection: dateBinding) {
                    ForEach(DateFacet.allCases) { Text($0.displayName).tag($0) }
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
            }

            Divider()

            // SIZE (single-select radio)
            VStack(alignment: .leading, spacing: 8) {
                sectionHeader("SIZE")
                Picker("", selection: sizeBinding) {
                    ForEach(SizeFacet.allCases) { Text($0.displayName).tag($0) }
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
            }

            Divider()

            Button("Clear All") { appState.gridFilter = .none }
                .disabled(!appState.gridFilter.isActive)
        }
        .padding(16)
        .frame(width: 270)
    }

    @ViewBuilder
    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.secondary)
    }

    // MARK: - Bindings

    /// A kind reads as checked when the set is empty (the "all = off" sentinel)
    /// or explicitly contains it.
    private func kindBinding(_ facet: KindFacet) -> Binding<Bool> {
        Binding(
            get: { appState.gridFilter.kinds.isEmpty
                   || appState.gridFilter.kinds.contains(facet) },
            set: { _ in toggleKind(facet) })
    }

    private func toggleKind(_ facet: KindFacet) {
        var filter = appState.gridFilter
        // Expand the "empty == all" sentinel to a concrete full set before edit.
        var set = filter.kinds.isEmpty ? Set(KindFacet.allCases) : filter.kinds
        if set.contains(facet) { set.remove(facet) } else { set.insert(facet) }
        // Collapse "all selected" (or "none selected") back to the empty/off
        // sentinel: per the model, empty == no kind constraint == all shown.
        filter.kinds = (set == Set(KindFacet.allCases) || set.isEmpty) ? [] : set
        appState.gridFilter = filter
    }

    private var dateBinding: Binding<DateFacet> {
        Binding(get: { appState.gridFilter.date },
                set: { appState.gridFilter.date = $0 })
    }

    private var sizeBinding: Binding<SizeFacet> {
        Binding(get: { appState.gridFilter.size },
                set: { appState.gridFilter.size = $0 })
    }
}
```

- [ ] **Step 2: Add popover state to `ContentView`**

In `Muse/Muse/ContentView.swift`, alongside the other toolbar `@State` flags (e.g. `imageLayoutShown`, `moodPickerShown`), add:

```swift
    @State private var filterPopoverShown = false
```

- [ ] **Step 3: Add the funnel `ToolbarItem` after the sort cluster**

In `Muse/Muse/ContentView.swift`, immediately **after** the sort-cluster `ToolbarItem` (the `HStack { sortMenu; sortDirectionButton }` at lines 92–102, which is `.disabled(appState.isSearchActive)`), add a separate `ToolbarItem` — deliberately NOT disabled during search, because the filter narrows search results too:

```swift
            ToolbarItem(placement: .navigation) {
                filterMenu
            }
```

Then add the `filterMenu` computed property next to `moodMenu` (around lines 178–192):

```swift
    @ViewBuilder
    private var filterMenu: some View {
        // Native toolbar Toggle in `.button` style: when "on" it gets the
        // standard selected fill (solid accent, white icon). We drive "on" from
        // (popover open) OR (a filter is active) so the engaged blue persists
        // while a filter is set even with the popover closed — the always-visible
        // reminder. The setter ignores the incoming value and only toggles the
        // popover, so a click always opens/closes the popover (never silently
        // clears the filter). NOT disabled during search: the funnel narrows
        // search results too.
        Toggle(isOn: Binding(
            get: { filterPopoverShown || appState.gridFilter.isActive },
            set: { _ in filterPopoverShown.toggle() }
        )) {
            Image(systemName: "line.3.horizontal.decrease.circle")
                .moodToolbarIcon(appState.moodPalette,
                                 selected: filterPopoverShown || appState.gridFilter.isActive)
        }
        .toggleStyle(.button)
        .help("Filter")
        .accessibilityLabel("Filter")
        .popover(isPresented: $filterPopoverShown, arrowEdge: .bottom) {
            GridFilterPopover()
                .environmentObject(appState)
        }
    }
```

- [ ] **Step 4: Build to verify it compiles**

Run: `xcodebuild -project Muse/Muse.xcodeproj -scheme Muse -destination 'platform=macOS' build`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 5: Run the full test suite**

Run: `xcodebuild -project Muse/Muse.xcodeproj -scheme Muse -destination 'platform=macOS' test`
Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 6: Manual verification checklist** (per convention — SwiftUI not unit-tested)

Build & run the app, then confirm:
- Funnel button appears in the toolbar next to the sort direction arrow.
- Opening it shows Kind checkboxes (all checked initially), Date radio (Any), Size radio (Any), and a disabled "Clear All".
- Checking only "PDFs" narrows a folder to PDFs; the funnel button turns blue (white icon) and stays blue with the popover closed.
- "This Week" narrows by modified date; "10–100 MB" narrows by size; combining facets narrows further.
- The filter persists across folder switches, into a collection, and narrows a search's results.
- "Clear All" resets every facet and the button returns to neutral.
- The empty state shows when a filter removes everything; "Clear All" restores.

- [ ] **Step 7: Commit**

```bash
git add "Muse/Muse/Views/GridFilterPopover.swift" "Muse/Muse/ContentView.swift"
git commit -m "feat: funnel toolbar button + GridFilterPopover (engaged-blue when active)"
```

---

## Self-Review

**Spec coverage:**
- Funnel button in the sort grouping, engaged-blue when active → Task 4 (placed adjacent to the sort cluster; kept enabled during search so it can narrow results).
- Popover: Kind checkboxes / Date radio / Size radio / Clear all, ~270 wide → Task 4.
- `GridFilter` pure model + matcher → Task 1.
- `AssetKind`→`KindFacet` mapping (unhandled → `.other`) → Task 1 (`KindFacet(from:)`).
- Date windows from `now` via `Calendar` → Task 1 (`DateFacet.windowStart`).
- Size buckets, nil size never matches a non-`.any` constraint → Task 1.
- `AppSettings.gridFilter` (JSON) + `AppState.gridFilter` (persist + memo-invalidate) → Task 2.
- `visibleFiles` narrowing on all branches (browse / collection / tag / search) → Task 3.
- Persistence across folder switches → Task 2 (AppSettings mirror; `gridFilter` lives on AppState, not reset on folder load).
- Empty result → normal empty state (no code needed; GridView already renders empty `visibleFiles`) → covered, verified in Task 4 Step 6.
- `GridFilterTests` covering kind buckets, each date window near boundaries, each size bucket incl. nil, combined facets, `isActive`/`resolve` default + round-trip → Task 1.
- Out of scope (custom ranges, tag facet, Collections-card filtering, saved filters, sort changes) → not implemented. ✓

**Placeholder scan:** No TBD / "handle edge cases" / "similar to" — all code is literal. ✓

**Type consistency:** `GridFilter`, `KindFacet`/`DateFacet`/`SizeFacet`, `matches(kind:sizeBytes:modified:now:)`, `isActive`, `resolve(_:)`, `KindFacet(from:)`, `DateFacet.windowStart(now:calendar:)`, `SizeFacet.contains(_:)`, `AppSettings.gridFilter`, `AppState.gridFilter`, `_visibleFilesValid`, `GridFilterPopover`, `filterPopoverShown`, `filterMenu` — names used consistently across Tasks 1–4. `FileNode` fields `kind`/`sizeBytes`/`modifiedAt` match the verified struct. ✓

**Edge note (intended, per spec model):** `kinds` empty = "no constraint = all shown". The popover normalizes both "all checked" and "none checked" back to empty, so unchecking the last kind reverts to showing all — the spec's model (`empty = no kind constraint`) does not represent "show nothing", which no user wants.
