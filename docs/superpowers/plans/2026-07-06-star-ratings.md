# Star Ratings Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let a user rate photos 1–5 stars — set via right-click, a menu-bar command, and the hero panel — with a filled-star tile badge and free filtering, by modeling a rating as a special mutually-exclusive manual tag.

**Architecture:** A rating is a manual `tags` row whose label is a run of `★` (U+2605) glyphs, per `(file_id, parent_dir)`. A pure `StarRating` helper owns all star↔label + mutual-exclusion logic. A `TagStore.setRating` seam makes setting a rating replace any prior one. Chips/filtering come for free from the existing tag system; a batched `RatingLoader` + an `AppState.starRatings` map drives a new top-right tile badge. No schema migration.

**Tech Stack:** Swift, SwiftUI, GRDB, AppKit (macOS 14.6+). Tests: XCTest (`MuseTests`).

## Global Constraints

- **Storage stays canonical-English; localize at DISPLAY time.** Glyph labels are language-neutral — store + display verbatim, NO `VocabularyLocalizer`/`VisionVocabulary.json` row. Verified: `VocabularyLocalizer.display` is identity for non-vocabulary labels (`Localization/VocabularyLocalizer.swift:40`).
- **Tags are per `(file_id, parent_dir)`** — no library-wide rating op. `setRating` goes through the `tagScopes` seam (`Database/TagStore.swift:18`).
- **Manual beats vision (Q32).** Rating rows are `source = "manual"`; reuse the insert/promote branch (`TagStore.swift:80–100`). The tagger never emits glyph runs.
- **`setActiveTags` stays SYNCHRONOUS** (`Models/AppState+Filters.swift:448`) — rating filtering reuses it verbatim; do not touch it.
- **Every tag mutation bumps `tagsVersion`** so chips + the rating map refresh (`ViewerInfoColumn.swift:208`, `AppState+Filters.swift:281`).
- **After any `TagStore` write, call `AnalyzePipeline.shared.exportSidecarsAfterTagEdit(for:)`** (iCloud sidecar currency, `TagStore.swift:108`).
- **Grid must stay virtualized** — the badge is an overlay inside the existing `TileView`; no new container over the full set.
- **Every mouse-only interaction needs a non-mouse parallel** — context menu (VO-reachable) + menu-bar command (⌘0–⌘5) + interactive hero star buttons; the display-only badge folds into the tile's `accessibilityValue`.
- **The one localized string** is the VoiceOver label `"%lld-star rating"` (`NSLocalizedString`, count interpolated). Card/menu/toast literals auto-extract; run `-exportLocalizations` and fill French per CLAUDE.md.
- **Verify runtime, not just tests** — a green `xcodebuild -scheme Muse test` is necessary but not sufficient; exercise rating in the running app.
- Build/test command: `xcodebuild -scheme Muse test` (keep 503+ unit tests green).
- Commit after each task. Do NOT commit until a task's tests pass.

---

## File Structure

- `Muse/Muse/Models/StarRating.swift` (new) — pure star↔label + resolution + front-sort rank. No I/O.
- `Muse/Muse/Database/RatingLoader.swift` (new) — batched per-file rating map (path → stars), `(file_id, parent_dir)`-scoped, chunked `IN`.
- `Muse/Muse/Models/AppState+Rating.swift` (new) — `setRating`, `uniformRating`, `reloadStarRatings`.
- `Muse/Muse/Database/TagStore.swift` (modify) — `setRating(_:forURLs:)`.
- `Muse/Muse/Database/TagChipLoader.swift` (modify) — front-sort ratings in `ordered`.
- `Muse/Muse/Models/AppState.swift` (modify) — `@Published starRatings`, `starRatingsToken`, fresh-select inline rating commit.
- `Muse/Muse/Models/AppState+TagChips.swift` (modify) — call `reloadStarRatings()` from `reloadTagChips`.
- `Muse/Muse/Views/SelectionMenu.swift` (modify) — Rating submenu with checkmarks.
- `Muse/Muse/Views/GridView.swift` (modify) — pass `rating:` to `TileView`, badge overlay, tile `accessibilityValue`.
- `Muse/Muse/MuseApp.swift` (modify) — `CommandMenu("Rating")`.
- `Muse/Muse/Viewers/Viewer/ViewerInfoColumn.swift` (modify) — `ratingCard` under Tags.
- `Muse/Muse/Localizable.xcstrings` (modify) — new strings, French filled.
- Tests: `Muse/MuseTests/StarRatingTests.swift` (new), `Muse/MuseTests/TagChipLoaderOrderTests.swift` (modify).

---

### Task 1: `StarRating` pure helper

**Files:**
- Create: `Muse/Muse/Models/StarRating.swift`
- Test: `Muse/MuseTests/StarRatingTests.swift`

**Interfaces:**
- Produces: `StarRating.maxStars: Int`, `StarRating.glyph: String`, `StarRating.label(for: Int) -> String?`, `StarRating.rating(from: String) -> Int?`, `StarRating.isRating(_: String) -> Bool`, `StarRating.allLabels: [String]`, `StarRating.resolution(existingLabels: [String], newRating: Int?) -> (remove: [String], add: [String])`.

- [ ] **Step 1: Write the failing test**

Create `Muse/MuseTests/StarRatingTests.swift`:

```swift
import XCTest
@testable import Muse

final class StarRatingTests: XCTestCase {

    func testLabelRoundTrip() {
        for n in 1...5 {
            let label = StarRating.label(for: n)
            XCTAssertNotNil(label)
            XCTAssertEqual(StarRating.rating(from: label!), n)
        }
    }

    func testLabelIsFilledGlyphRun() {
        XCTAssertEqual(StarRating.label(for: 3), "\u{2605}\u{2605}\u{2605}")
        XCTAssertEqual(StarRating.label(for: 1), "\u{2605}")
        XCTAssertEqual(StarRating.label(for: 5), "\u{2605}\u{2605}\u{2605}\u{2605}\u{2605}")
    }

    func testLabelOutOfRangeIsNil() {
        XCTAssertNil(StarRating.label(for: 0))
        XCTAssertNil(StarRating.label(for: 6))
        XCTAssertNil(StarRating.label(for: -1))
    }

    func testRatingRejectsNonRatingLabels() {
        XCTAssertNil(StarRating.rating(from: ""))
        XCTAssertNil(StarRating.rating(from: "beach"))
        XCTAssertNil(StarRating.rating(from: "\u{2605} favorite"))   // stars + text
        XCTAssertNil(StarRating.rating(from: "\u{2605}\u{2605}\u{2605}\u{2605}\u{2605}\u{2605}")) // 6
        XCTAssertNil(StarRating.rating(from: "\u{2606}"))            // ☆ hollow star
    }

    func testIsRating() {
        XCTAssertTrue(StarRating.isRating("\u{2605}\u{2605}"))
        XCTAssertFalse(StarRating.isRating("sunset"))
    }

    func testAllLabelsAscending() {
        XCTAssertEqual(StarRating.allLabels,
                       (1...5).map { String(repeating: "\u{2605}", count: $0) })
    }

    func testResolutionAddWhenNoneExisting() {
        let r = StarRating.resolution(existingLabels: ["beach"], newRating: 3)
        XCTAssertEqual(r.remove, [])
        XCTAssertEqual(r.add, ["\u{2605}\u{2605}\u{2605}"])
    }

    func testResolutionChangeRemovesOldAddsNew() {
        let r = StarRating.resolution(
            existingLabels: ["\u{2605}\u{2605}", "beach"], newRating: 5)
        XCTAssertEqual(r.remove, ["\u{2605}\u{2605}"])
        XCTAssertEqual(r.add, ["\u{2605}\u{2605}\u{2605}\u{2605}\u{2605}"])
    }

    func testResolutionSameRatingIsIdempotent() {
        let r = StarRating.resolution(
            existingLabels: ["\u{2605}\u{2605}\u{2605}"], newRating: 3)
        XCTAssertEqual(r.remove, [])
        XCTAssertEqual(r.add, [])
    }

    func testResolutionRemoveClearsAllRatings() {
        let r = StarRating.resolution(
            existingLabels: ["\u{2605}\u{2605}\u{2605}", "beach"], newRating: nil)
        XCTAssertEqual(r.remove, ["\u{2605}\u{2605}\u{2605}"])
        XCTAssertEqual(r.add, [])
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -scheme Muse test -only-testing:MuseTests/StarRatingTests`
Expected: FAIL — "Cannot find 'StarRating' in scope".

- [ ] **Step 3: Write minimal implementation**

Create `Muse/Muse/Models/StarRating.swift`:

```swift
//
//  StarRating.swift
//  Muse
//
//  Star ratings are modeled as a special MANUAL tag whose label is a run of
//  BLACK STAR glyphs (U+2605), 1...5. This pure helper is the single source of
//  truth for star<->label mapping, "is this label a rating", the chip front-sort
//  order, and the mutual-exclusion resolution (exactly one rating per photo).
//  Language-neutral: a glyph run needs no translation, so a rating label carries
//  NO VocabularyLocalizer row. Pure value type; nonisolated so it's callable from
//  any context (DB closures, views, AppState).
//

import Foundation

nonisolated enum StarRating {
    static let maxStars = 5
    static let glyph = "\u{2605}"   // ★ BLACK STAR

    /// Canonical label for a star count, or nil if out of 1...maxStars.
    static func label(for stars: Int) -> String? {
        guard (1...maxStars).contains(stars) else { return nil }
        return String(repeating: glyph, count: stars)
    }

    /// Star count for a label, or nil if the label is NOT a rating. A rating
    /// label is EXACTLY `glyph` repeated 1...maxStars times — a user tag that
    /// merely contains a star, an empty string, or 6+ stars is NOT a rating.
    static func rating(from label: String) -> Int? {
        let count = label.count
        guard (1...maxStars).contains(count),
              label == String(repeating: glyph, count: count) else { return nil }
        return count
    }

    static func isRating(_ label: String) -> Bool { rating(from: label) != nil }

    /// All five canonical rating labels, ascending: ["★", …, "★★★★★"].
    static let allLabels: [String] = (1...maxStars).map { String(repeating: glyph, count: $0) }

    /// Mutual-exclusion resolution. Given the labels a file already carries and
    /// the desired new rating (nil = remove rating), returns which rating labels
    /// to DELETE and which to ADD so the file ends with EXACTLY the desired
    /// rating and no other rating. Non-rating labels are ignored.
    static func resolution(existingLabels: [String], newRating: Int?)
        -> (remove: [String], add: [String]) {
        let desired = newRating.flatMap(label(for:))
        let existingRatings = existingLabels.filter(isRating)
        let remove = existingRatings.filter { $0 != desired }
        let add: [String]
        if let desired, !existingRatings.contains(desired) {
            add = [desired]
        } else {
            add = []
        }
        return (remove, add)
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild -scheme Muse test -only-testing:MuseTests/StarRatingTests`
Expected: PASS (all cases).

- [ ] **Step 5: Commit**

```bash
git add "Muse/Muse/Models/StarRating.swift" "Muse/MuseTests/StarRatingTests.swift"
git commit -m "feat: StarRating pure helper (label/rating/resolution)"
```

---

### Task 2: Front-sort rating chips in `TagChipLoader.ordered`

**Files:**
- Modify: `Muse/Muse/Database/TagChipLoader.swift:36-52`
- Test: `Muse/MuseTests/TagChipLoaderOrderTests.swift`

**Interfaces:**
- Consumes: `StarRating.isRating(_:)`, `StarRating.rating(from:)` (Task 1).
- Produces: `TagChipLoader.ordered(_:sortMode:)` now emits rating labels first (highest star count first), then non-rating labels in the chosen mode order.

- [ ] **Step 1: Write the failing test**

Append to `Muse/MuseTests/TagChipLoaderOrderTests.swift` (inside the class):

```swift
    func testRatingsSortToFrontHighestFirst() {
        let c = ["beach": 9, "\u{2605}\u{2605}": 2, "\u{2605}\u{2605}\u{2605}\u{2605}\u{2605}": 1, "apple": 3]
        let out = TagChipLoader.ordered(c, sortMode: .count).map(\.label)
        // Ratings first (5★ before 2★), then non-ratings by count (beach 9, apple 3).
        XCTAssertEqual(out, ["\u{2605}\u{2605}\u{2605}\u{2605}\u{2605}", "\u{2605}\u{2605}", "beach", "apple"])
    }

    func testRatingsFrontEvenInAlphabeticalMode() {
        let c = ["zebra": 1, "\u{2605}": 4, "apple": 1]
        let out = TagChipLoader.ordered(c, sortMode: .alphabetical).map(\.label)
        XCTAssertEqual(out, ["\u{2605}", "apple", "zebra"])
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -scheme Muse test -only-testing:MuseTests/TagChipLoaderOrderTests`
Expected: FAIL — ratings sorted among non-ratings, not at front.

- [ ] **Step 3: Write minimal implementation**

In `Muse/Muse/Database/TagChipLoader.swift`, replace the body of `ordered` (lines 36–52) with:

```swift
    static func ordered(_ counts: [String: Int],
                        sortMode: TagSortMode = .count) -> [(label: String, count: Int)] {
        let sorted: [(key: String, value: Int)]
        switch sortMode {
        case .count:
            sorted = counts.sorted {
                $0.value != $1.value
                    ? $0.value > $1.value
                    : $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending
            }
        case .alphabetical:
            sorted = counts.sorted {
                $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending
            }
        }
        // Star-rating chips sort to the FRONT of the row (owner requirement),
        // highest star count first; the rest keep the chosen mode's order.
        let ratings = sorted
            .filter { StarRating.isRating($0.key) }
            .sorted { (StarRating.rating(from: $0.key) ?? 0) > (StarRating.rating(from: $1.key) ?? 0) }
        let rest = sorted.filter { !StarRating.isRating($0.key) }
        return (ratings + rest).map { (label: $0.key, count: $0.value) }
    }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild -scheme Muse test -only-testing:MuseTests/TagChipLoaderOrderTests`
Expected: PASS (including the two pre-existing tests).

- [ ] **Step 5: Commit**

```bash
git add "Muse/Muse/Database/TagChipLoader.swift" "Muse/MuseTests/TagChipLoaderOrderTests.swift"
git commit -m "feat: front-sort star-rating chips in TagChipLoader.ordered"
```

---

### Task 3: `TagStore.setRating` (mutually-exclusive rating write)

**Files:**
- Modify: `Muse/Muse/Database/TagStore.swift` (add method after `deleteAllTags`, ~line 197)

**Interfaces:**
- Consumes: `StarRating.isRating`, `StarRating.resolution`, `StarRating.allLabels` (Task 1); `tagScopes(forPaths:db:)` (`TagStore.swift:18`).
- Produces: `func setRating(_ stars: Int?, forURLs urls: [URL]) async`.

- [ ] **Step 1: Write the implementation**

This task's correctness is pinned by Task 1's `resolution` tests (the decision) plus runtime verification (the SQL). Add to `Muse/Muse/Database/TagStore.swift`, after `deleteAllTags(forURLs:)` (before `removeTag`):

```swift
    /// Set (or clear, with nil) the star rating for `urls`, scoped per file's
    /// folder. MUTUALLY EXCLUSIVE: removes any existing rating tag, then adds the
    /// new one as a MANUAL tag (manual beats vision, Q32). Other tags untouched.
    /// The decision is `StarRating.resolution`; applied here as SQL. Like every
    /// TagStore mutation it re-exports iCloud sidecars. No-op for an empty set or
    /// a stars value outside 1...StarRating.maxStars (nil clears).
    func setRating(_ stars: Int?, forURLs urls: [URL]) async {
        guard let queue = Database.shared.dbQueue else { return }
        let paths = urls.map { $0.standardizedFileURL.path }
        guard !paths.isEmpty else { return }
        do {
            try await queue.write { db in
                for scope in try tagScopes(forPaths: paths, db: db) {
                    // Current rating labels in THIS (file_id, parent_dir) scope.
                    let existing = try String.fetchAll(db, sql: """
                        SELECT label FROM tags WHERE file_id = ? AND parent_dir = ?
                        """, arguments: [scope.fileID, scope.dir])
                        .filter(StarRating.isRating)
                    let (remove, add) = StarRating.resolution(
                        existingLabels: existing, newRating: stars)
                    for label in remove {
                        try db.execute(sql: """
                            DELETE FROM tags
                            WHERE label = ? AND file_id = ? AND parent_dir = ?
                            """, arguments: [label, scope.fileID, scope.dir])
                    }
                    for label in add {
                        // Insert-or-promote-to-manual (same branch addManualTag
                        // uses): a vision row of this label can't exist for a
                        // glyph run, but stay symmetric with the tag path.
                        if let row = try TagRow
                            .filter(TagRow.Columns.file_id == scope.fileID)
                            .filter(TagRow.Columns.parent_dir == scope.dir)
                            .filter(TagRow.Columns.label == label)
                            .fetchOne(db) {
                            var updated = row
                            updated.source = "manual"
                            updated.confidence = nil
                            try updated.update(db)
                        } else {
                            var t = TagRow(
                                id: UUID().uuidString,
                                file_id: scope.fileID,
                                parent_dir: scope.dir,
                                label: label,
                                source: "manual",
                                confidence: nil,
                                model_version: nil
                            )
                            try t.insert(db)
                        }
                    }
                }
            }
        } catch {
            print("[TagStore] setRating failed: \(error)")
        }
        AnalyzePipeline.shared.exportSidecarsAfterTagEdit(for: urls)
    }
```

- [ ] **Step 2: Build to verify it compiles**

Run: `xcodebuild -scheme Muse build`
Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Run the full unit suite (no regressions)**

Run: `xcodebuild -scheme Muse test`
Expected: PASS (existing tests + Tasks 1–2).

- [ ] **Step 4: Commit**

```bash
git add "Muse/Muse/Database/TagStore.swift"
git commit -m "feat: TagStore.setRating — mutually-exclusive star rating write"
```

---

### Task 4: `RatingLoader` + `AppState.starRatings` map

**Files:**
- Create: `Muse/Muse/Database/RatingLoader.swift`
- Modify: `Muse/Muse/Models/AppState.swift` (add stored props near `tagChipRows`, ~line 146; add fresh-select inline commit ~line 1117–1142)
- Create: `Muse/Muse/Models/AppState+Rating.swift`
- Modify: `Muse/Muse/Models/AppState+TagChips.swift` (call `reloadStarRatings()` from `reloadTagChips`)

**Interfaces:**
- Consumes: `StarRating.rating(from:)` (Task 1); `TagScope.parentDir` (`TagScope.swift:22`); `databaseQuestionMarks` (used across `TagChipLoader`).
- Produces: `RatingLoader.ratings(paths:simpleFolderDir:queue:) -> [String: Int]`; `AppState.starRatings: [String: Int]`; `AppState.reloadStarRatings()`; `AppState.setRating(_:forSelectionFallback:)`; `AppState.uniformRating(forPaths:) -> Int?`.

- [ ] **Step 1: Create the batched loader**

Create `Muse/Muse/Database/RatingLoader.swift`:

```swift
//
//  RatingLoader.swift
//  Muse
//
//  Per-file star rating for the tiles in view: standardized path -> star count
//  (1...5), scoped per (file_id, parent_dir) exactly like tags, so a duplicate's
//  rating in another folder never surfaces here. Modeled on TagChipLoader
//  (chunked IN lists, off-main). The result drives the top-right tile badge.
//

import Foundation
import GRDB

nonisolated enum RatingLoader {

    /// Standardized-path -> star count for the given files. `simpleFolderDir`
    /// non-nil selects the single-folder fast path (one constant parent_dir);
    /// nil uses the general per-file-scope path. Synchronous — call off-main.
    static func ratings(paths: [String], simpleFolderDir: String?,
                        queue: DatabaseQueue) -> [String: Int] {
        guard !paths.isEmpty else { return [:] }
        if let dir = simpleFolderDir {
            return fast(paths: paths, parentDir: dir, queue: queue)
        }
        return general(paths: paths, queue: queue)
    }

    /// One constant parent_dir: join paths->tags in a single GROUP-free scan,
    /// keep the max rating label per path (mutual exclusion means there is only
    /// one, but max is defensive).
    private static func fast(paths: [String], parentDir: String,
                             queue: DatabaseQueue) -> [String: Int] {
        (try? queue.read { db -> [String: Int] in
            var out: [String: Int] = [:]
            for start in stride(from: 0, to: paths.count, by: 800) {
                let chunk = Array(paths[start..<min(start + 800, paths.count)])
                let marks = databaseQuestionMarks(count: chunk.count)
                let rows = try Row.fetchAll(db, sql: """
                    SELECT p.absolute_path AS path, t.label AS label
                    FROM paths p JOIN tags t ON t.file_id = p.file_id
                    WHERE p.is_alive = 1 AND t.parent_dir = ? AND p.absolute_path IN (\(marks))
                    """, arguments: StatementArguments([parentDir] + chunk))
                for r in rows {
                    guard let path: String = r["path"], let label: String = r["label"],
                          let n = StarRating.rating(from: label) else { continue }
                    out[path] = max(out[path] ?? 0, n)
                }
            }
            return out
        }) ?? [:]
    }

    /// Collections / recursive listings: parent_dir varies per file, so scope
    /// each (file_id, parent_dir) individually.
    private static func general(paths: [String], queue: DatabaseQueue) -> [String: Int] {
        var out: [String: Int] = [:]
        for start in stride(from: 0, to: paths.count, by: 500) {
            let chunk = Array(paths[start..<min(start + 500, paths.count)])
            let partial: [String: Int] = (try? queue.read { db -> [String: Int] in
                let marks = databaseQuestionMarks(count: chunk.count)
                let pathRows = try Row.fetchAll(db, sql: """
                    SELECT file_id, absolute_path FROM paths
                    WHERE is_alive = 1 AND file_id IS NOT NULL AND absolute_path IN (\(marks))
                    """, arguments: StatementArguments(chunk))
                // file_id -> [(path, dir)] so we can attribute a scoped rating.
                var byFile: [String: [(path: String, dir: String)]] = [:]
                var fileIDs = Set<String>()
                for r in pathRows {
                    guard let fid: String = r["file_id"],
                          let p: String = r["absolute_path"] else { continue }
                    fileIDs.insert(fid)
                    byFile[fid, default: []].append((p, TagScope.parentDir(ofPath: p)))
                }
                guard !fileIDs.isEmpty else { return [:] }
                let fmarks = databaseQuestionMarks(count: fileIDs.count)
                let tagRows = try Row.fetchAll(db, sql: """
                    SELECT label, file_id, parent_dir FROM tags WHERE file_id IN (\(fmarks))
                    """, arguments: StatementArguments(Array(fileIDs)))
                var result: [String: Int] = [:]
                for tr in tagRows {
                    guard let label: String = tr["label"],
                          let fid: String = tr["file_id"],
                          let dir: String = tr["parent_dir"],
                          let n = StarRating.rating(from: label) else { continue }
                    for entry in byFile[fid] ?? [] where entry.dir == dir {
                        result[entry.path] = max(result[entry.path] ?? 0, n)
                    }
                }
                return result
            }) ?? [:]
            for (k, v) in partial { out[k] = max(out[k] ?? 0, v) }
        }
        return out
    }
}
```

- [ ] **Step 2: Add the AppState stored properties**

In `Muse/Muse/Models/AppState.swift`, right after `tagChipToken` (the `var tagChipToken = 0` at ~line 149), add:

```swift
    /// Standardized path -> star rating (1...5) for the files in the current
    /// scope. Drives the top-right tile badge. Recomputed by reloadStarRatings()
    /// from the SAME seams that refresh chips (tag edits, collection change,
    /// folder load). A monotonic token drops a stale async result.
    @Published var starRatings: [String: Int] = [:]
    var starRatingsToken = 0
```

- [ ] **Step 3: Create the AppState extension**

Create `Muse/Muse/Models/AppState+Rating.swift`:

```swift
//
//  AppState+Rating.swift
//  Muse
//
//  Star-rating wiring: recompute the per-file rating map for the current scope
//  (drives the tile badge), and set/clear the rating on the effective selection
//  (menu-bar command + context menu). A rating is a manual tag, so mutations go
//  through TagStore.setRating and bump tagsVersion like every tag edit.
//

import Foundation
import SwiftUI

@MainActor
extension AppState {

    /// Recompute `starRatings` for the current scope (active collection members,
    /// else the selected folder) off-main, then publish. Called from
    /// reloadTagChips() (every tag edit / collection change / live reload) and
    /// inline in the fresh-select branch of reloadCurrentFiles.
    func reloadStarRatings() {
        starRatingsToken &+= 1
        let token = starRatingsToken
        let scope = tagSourceFiles
        let recursive = showSubfolders
        let inCollection = activeCollectionID != nil
        guard let queue = Database.shared.dbQueue, !scope.isEmpty else {
            starRatings = [:]
            return
        }
        let paths = scope.map { $0.url.standardizedFileURL.path }
        let simpleDir = (!inCollection && !recursive && !isSearchActive)
            ? TagScope.parentDir(ofPath: paths[0]) : nil
        Task.detached(priority: .userInitiated) {
            let map = RatingLoader.ratings(paths: paths, simpleFolderDir: simpleDir, queue: queue)
            await MainActor.run {
                guard token == self.starRatingsToken else { return }
                self.starRatings = map
            }
        }
    }

    /// The rating shared by ALL of `paths`, or nil if mixed / none. Backs the
    /// context-menu checkmark and the hero panel's current state. Unrated counts
    /// as rating 0; a set that mixes 0 and a rating (or two ratings) → nil.
    func uniformRating(forPaths paths: [String]) -> Int? {
        guard !paths.isEmpty else { return nil }
        let values = Set(paths.map { starRatings[$0] ?? 0 })
        guard values.count == 1, let only = values.first, only > 0 else { return nil }
        return only
    }

    /// Set/clear the star rating on the effective selection (menu-bar + context
    /// menu). Files only (folders can't be tagged). Bumps tagsVersion so chips +
    /// the rating map refresh.
    func setRating(_ stars: Int?, forSelectionFallback fallback: String) {
        let urls = effectiveSelectionURLs(fallback: fallback).filter {
            (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory != true
        }
        guard !urls.isEmpty else { return }
        Task { @MainActor in
            await TagStore.shared.setRating(stars, forURLs: urls)
            tagsVersion &+= 1
        }
    }
}
```

- [ ] **Step 4: Wire `reloadStarRatings` into the chip-refresh seam**

In `Muse/Muse/Models/AppState+TagChips.swift`, in `reloadTagChips`, call `reloadStarRatings()` so ratings track chips one-for-one. Modify the early-return guard and the tail:

Replace the guard block (lines 32–35):

```swift
        guard let queue = Database.shared.dbQueue, !scope.isEmpty else {
            tagChipRows = []
            reloadStarRatings()
            return
        }
```

And add `reloadStarRatings()` as the last statement of the method (after the `Task.detached { … }` block, still inside `reloadTagChips`):

```swift
        reloadStarRatings()
    }
```

- [ ] **Step 5: Commit the fresh-select inline recompute in reloadCurrentFiles**

In `Muse/Muse/Models/AppState.swift`, the fresh-select branch commits `tagChipRows` in a MainActor transaction (~lines 1132–1142). Add a rating refresh there so badges appear with the folder. Inside `if freshSelect { … }`, after `self.tagRowReady = true`, add:

```swift
                    self.reloadStarRatings()
```

(The non-fresh branch calls `reloadTagChips()`, which now calls `reloadStarRatings()` — so both paths are covered.)

- [ ] **Step 6: Build + full suite**

Run: `xcodebuild -scheme Muse test`
Expected: BUILD SUCCEEDED, all tests PASS (no behavior test yet — the map is exercised at runtime in Task 5's verification).

- [ ] **Step 7: Commit**

```bash
git add "Muse/Muse/Database/RatingLoader.swift" \
        "Muse/Muse/Models/AppState.swift" \
        "Muse/Muse/Models/AppState+Rating.swift" \
        "Muse/Muse/Models/AppState+TagChips.swift"
git commit -m "feat: RatingLoader + AppState.starRatings map + setRating wiring"
```

---

### Task 5: Right-click Rating submenu

**Files:**
- Modify: `Muse/Muse/Views/SelectionMenu.swift` (add to the `if !fileURLs.isEmpty` block, after "Share", ~line 51)

**Interfaces:**
- Consumes: `StarRating.label(for:)`, `StarRating.maxStars` (Task 1); `appState.setRating(_:forSelectionFallback:)`, `appState.uniformRating(forPaths:)` (Task 4); `appState.effectiveSelectionURLs` / `path` (existing).
- Produces: a `Menu("Rating")` with five checkable star options.

- [ ] **Step 1: Add the submenu**

In `Muse/Muse/Views/SelectionMenu.swift`, inside `body`, in the `if !fileURLs.isEmpty { … }` block, after `Button("Share") { share() }` (line 51), add:

```swift
            Menu("Rating") {
                ForEach(Array((1...StarRating.maxStars).reversed()), id: \.self) { n in
                    let label = StarRating.label(for: n) ?? ""
                    Button {
                        // Pick the currently-checked rating to REMOVE it (no
                        // "Remove" verb); pick another to change.
                        appState.setRating(currentRating == n ? nil : n,
                                           forSelectionFallback: path)
                    } label: {
                        if currentRating == n {
                            Label(label, systemImage: "checkmark")
                        } else {
                            Text(label)
                        }
                    }
                    .accessibilityLabel(Text(ratingA11yLabel(n)))
                }
            }
```

- [ ] **Step 2: Add the supporting computed props / helper**

Still in `SelectionActionsMenu`, add near `fileURLs` (after line 26):

```swift
    /// The rating shared by the effective selection (the checkmark target), or
    /// nil if mixed / unrated.
    private var currentRating: Int? {
        appState.uniformRating(forPaths: fileURLs.map { $0.standardizedFileURL.path })
    }

    /// Localized VoiceOver label for an N-star menu item (a bare glyph reads
    /// poorly). The number is interpolated.
    private func ratingA11yLabel(_ n: Int) -> String {
        String(format: NSLocalizedString("%lld-star rating",
                                         comment: "VoiceOver: star rating of a photo"),
               n)
    }
```

- [ ] **Step 3: Build**

Run: `xcodebuild -scheme Muse build`
Expected: BUILD SUCCEEDED.

- [ ] **Step 4: Runtime verify**

Launch the app on a folder of images. Right-click a tile → Rating → pick ★★★. Confirm: the chip row gains a `★★★` chip at the FRONT; clicking it filters to that photo; right-click again shows the checkmark on ★★★; picking ★★★ again removes it. Multi-select several tiles, right-click → Rating → ★★★★★ rates all.

- [ ] **Step 5: Commit**

```bash
git add "Muse/Muse/Views/SelectionMenu.swift"
git commit -m "feat: right-click Rating submenu (checkmark, no Remove verb, batch)"
```

---

### Task 6: On-tile badge

**Files:**
- Modify: `Muse/Muse/Views/GridView.swift` (pass `rating:` into `TileView` at the call site ~line 277–284; add badge overlay in `TileView.imageContent` ~line 683–715; add `accessibilityValue` on the tile ~line 304–308)

**Interfaces:**
- Consumes: `StarRating.label(for:)` (Task 1); `appState.starRatings` (Task 4).
- Produces: a display-only top-right badge on rated tiles; the tile's a11y value announces the rating.

- [ ] **Step 1: Pass the rating into `TileView`**

In `Muse/Muse/Views/GridView.swift`, add a stored property to `TileView` (after `captionHeight`, ~line 573):

```swift
    /// Star rating (1...5) for this file, or nil when unrated. Drives the
    /// top-right badge. Passed from GridView so the tile re-renders when its
    /// rating changes without subscribing to the whole starRatings map.
    var rating: Int? = nil
```

At the `TileView(...)` construction site in GridView's body (~line 275, where `showFileNames:`/`captionHeight:` are passed), add:

```swift
                         rating: appState.starRatings[file.url.standardizedFileURL.path],
```

- [ ] **Step 2: Draw the badge**

In `TileView.imageContent`'s `ZStack` (`GridView.swift:683`), after the selection ring block (after the `if isSelected { RoundedRectangle… }`, ~line 714), add:

```swift
            // Star-rating badge: top-right, filled glyphs, BLACK on a translucent
            // WHITE backing (no yellow — high-contrast, colorblind-safe, mood-
            // independent). Shown only when rated. Display-only (never clickable —
            // a tap would fight tile select/open); the rating is announced via the
            // tile's accessibilityValue in GridView (this overlay is a11y-hidden).
            if let rating, let label = StarRating.label(for: rating) {
                Text(label)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Capsule(style: .continuous).fill(.white.opacity(0.85)))
                    .padding(6)
                    .frame(maxWidth: .infinity, maxHeight: .infinity,
                           alignment: .topTrailing)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
```

- [ ] **Step 3: Announce the rating to VoiceOver**

In `GridView.swift`, on the per-tile view (where `.accessibilityLabel(...)` and `.accessibilityAddTraits(...)` are set, ~line 303–308), add an `.accessibilityValue` reflecting the rating. After the `.accessibilityAddTraits(...)` call, add:

```swift
                    .accessibilityValue(
                        appState.starRatings[file.url.standardizedFileURL.path].map {
                            Text(String(format: NSLocalizedString(
                                "%lld-star rating",
                                comment: "VoiceOver: star rating of a photo"), $0))
                        } ?? Text(""))
```

- [ ] **Step 4: Build + runtime verify**

Run: `xcodebuild -scheme Muse build`
Expected: BUILD SUCCEEDED.
Launch: rate a photo ★★★ → a black `★★★` badge appears top-right on its tile; unrated tiles have none; changing/removing the rating updates/clears the badge live; VoiceOver on the tile announces "…, 3-star rating".

- [ ] **Step 5: Commit**

```bash
git add "Muse/Muse/Views/GridView.swift"
git commit -m "feat: on-tile star-rating badge (top-right, display-only, a11y)"
```

---

### Task 7: Menu-bar Rating command

**Files:**
- Modify: `Muse/Muse/MuseApp.swift` (add a `CommandMenu("Rating")` in `.commands`, after the `Collections` `CommandMenu` ~line 356)

**Interfaces:**
- Consumes: `StarRating.label(for:)`, `StarRating.maxStars` (Task 1); `appState.setRating(_:forSelectionFallback:)` (Task 4); `appState.selectedFiles` (existing).
- Produces: a "Rating" menu with No Rating (⌘0) + ★1–★5 (⌘1–⌘5) over the current selection.

- [ ] **Step 1: Add the command menu**

In `Muse/Muse/MuseApp.swift`, inside `.commands { … }`, after the `CommandMenu("Collections") { … }` block (closes ~line 356), add:

```swift
            // Menu-bar equivalent of the tile's Rating context menu so rating
            // isn't mouse/right-click-only (keyboard + VoiceOver). Targets the
            // current selection, mirroring "New Collection from Selection…".
            // ⌘0 clears, ⌘1–⌘5 set (Apple Photos convention).
            CommandMenu("Rating") {
                Button("No Rating") {
                    appState.setRating(nil, forSelectionFallback: "")
                }
                .keyboardShortcut("0", modifiers: .command)
                .disabled(appState.selectedFiles.isEmpty)

                Divider()

                ForEach(1...StarRating.maxStars, id: \.self) { n in
                    Button(StarRating.label(for: n) ?? "") {
                        appState.setRating(n, forSelectionFallback: "")
                    }
                    .keyboardShortcut(KeyEquivalent(Character("\(n)")), modifiers: .command)
                    .disabled(appState.selectedFiles.isEmpty)
                    .accessibilityLabel(Text(String(format: NSLocalizedString(
                        "%lld-star rating",
                        comment: "VoiceOver: star rating of a photo"), n)))
                }
            }
```

- [ ] **Step 2: Build + runtime verify**

Run: `xcodebuild -scheme Muse build`
Expected: BUILD SUCCEEDED.
Launch: select one or more tiles → menu bar "Rating" → ★★★ (or ⌘3); confirm the badge + chip appear. ⌘0 clears. With nothing selected the items are disabled.

- [ ] **Step 3: Commit**

```bash
git add "Muse/Muse/MuseApp.swift"
git commit -m "feat: menu-bar Rating command (No Rating + 1-5 stars over selection)"
```

---

### Task 8: Hero viewer — Rating card under Tags

**Files:**
- Modify: `Muse/Muse/Viewers/Viewer/ViewerInfoColumn.swift` (add `ratingCard` between `tagsCard` and the colors card in `body`, ~line 64–65; define `ratingCard`)

**Interfaces:**
- Consumes: `StarRating.rating(from:)`, `StarRating.label(for:)`, `StarRating.maxStars` (Task 1); `TagStore.shared.setRating` (Task 3); `details?.tags`, `refresh`, `appState.tagsVersion`, `toast`/`show` (existing).
- Produces: a "RATING" card that shows + sets the current file's rating.

- [ ] **Step 1: Insert the card in the column**

In `Muse/Muse/Viewers/Viewer/ViewerInfoColumn.swift` `body`, between `tagsCard` and the colors block (line 64), add:

```swift
                ratingCard
```

- [ ] **Step 2: Define `ratingCard`**

Add to `ViewerInfoColumn` (after `tagsCard` / `loadTagSuggestions`, before "Colors card"):

```swift
    // MARK: - Rating card

    /// Current rating derived from the file's tags (the first rating-glyph tag).
    private var currentRating: Int? {
        (details?.tags ?? []).compactMap { StarRating.rating(from: $0.label) }.max()
    }

    /// Shows the rating UNDER Tags (owner). Interactive: tap star N to set N; tap
    /// the current rating to remove it (mirrors the context menu). Mutually
    /// exclusive via TagStore.setRating; bumps tagsVersion like every hero tag
    /// edit so the grid chips + badge refresh.
    private var ratingCard: some View {
        InfoCard {
            VStack(alignment: .leading, spacing: 10) {
                CardLabel(text: String(localized: "RATING"))
                HStack(spacing: 4) {
                    ForEach(1...StarRating.maxStars, id: \.self) { n in
                        let filled = (currentRating ?? 0) >= n
                        Button {
                            setRating(currentRating == n ? nil : n)
                        } label: {
                            Image(systemName: filled ? "star.fill" : "star")
                                .font(.system(size: 15, weight: .medium))
                                .foregroundStyle(.white.opacity(filled ? 0.95 : 0.35))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(Text(String(format: NSLocalizedString(
                            "%lld-star rating",
                            comment: "VoiceOver: star rating of a photo"), n)))
                    }
                }
            }
        }
    }

    private func setRating(_ stars: Int?) {
        Task {
            await TagStore.shared.setRating(stars, forURLs: [url])
            await refresh()
            appState.tagsVersion &+= 1
            show(stars == nil
                 ? String(localized: "Rating removed")
                 : String(localized: "Rated \(stars!) stars"))
        }
    }
```

- [ ] **Step 3: Build + runtime verify**

Run: `xcodebuild -scheme Muse build`
Expected: BUILD SUCCEEDED.
Launch: open a photo in the hero viewer → the RIGHT column shows a RATING card UNDER Tags. Tap the 4th star → filled through 4, toast "Rated 4 stars"; close the viewer → the tile badge shows ★★★★. Re-open, tap the 4th star again → cleared, toast "Rating removed". Confirm NO star renders over the image itself.

- [ ] **Step 4: Commit**

```bash
git add "Muse/Muse/Viewers/Viewer/ViewerInfoColumn.swift"
git commit -m "feat: hero viewer Rating card (under Tags, display + set)"
```

---

### Task 9: Localization pass

**Files:**
- Modify: `Muse/Muse/Localizable.xcstrings` (via `-exportLocalizations` write-back + fill French)

**Interfaces:**
- Consumes: every user-facing string added in Tasks 5–8.

- [ ] **Step 1: Export localizations (write-back into the catalog)**

Run:
```bash
xcodebuild -exportLocalizations -project Muse/Muse.xcodeproj \
  -localizationPath /tmp/muse-loc -exportLanguage fr
```
Expected: writes the new SwiftUI text-literal keys (`Rating`, `No Rating`, `RATING`, `Rated %lld stars`, `Rating removed`) into `Localizable.xcstrings` with empty `fr` values.

- [ ] **Step 2: Add the runtime-variable key by hand**

The `NSLocalizedString("%lld-star rating", …)` key is reached only via a runtime variable, so the extractor won't add it. Add it to `Localizable.xcstrings` manually (English + French), e.g. French `"note de %lld étoiles"`. (Per CLAUDE.md: `NSLocalizedString(variable)` keys are marked `stale` but DO compile — do not prune.)

- [ ] **Step 3: Fill the French values**

Fill each empty `fr` value: `Rating` → `Note`; `No Rating` → `Aucune note`; `RATING` → `NOTE`; `Rated %lld stars` → `Noté %lld étoiles`; `Rating removed` → `Note supprimée`.

- [ ] **Step 4: Verify 0 untranslated**

Re-run the export command from Step 1; expected: it reports 0 untranslated for the new keys.

- [ ] **Step 5: Full suite (English host)**

Run: `xcodebuild -scheme Muse test`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add "Muse/Muse/Localizable.xcstrings"
git commit -m "i18n: French for star-rating strings"
```

---

## Self-Review

**Spec coverage:**
- §2.3 pure helper → Task 1. §2.1 glyph-through-display verified in spec (no code needed). §2.2 filled-only → Task 1/`label`. 
- §3 mutual-exclusion store → Task 3 (decision pinned by Task 1 resolution tests). §4 front-sort → Task 2. §4 per-location scope → Task 3 via `tagScopes`.
- §5 context menu (checkmark, no Remove verb, batch) → Task 5. §6 badge (top-right, black-on-white, display-only, a11y) + data map → Tasks 4 & 6. §7 menu-bar command → Task 7. §8 hero card → Task 8. §9 filter-for-free → free (Tasks 2 + existing `setActiveTag`, no code). §10 localization → Task 9. §11 invariants → Global Constraints + per-task notes. §12 out-of-scope → nothing built.

**Placeholder scan:** every code step shows complete code; no TBD/TODO.

**Type consistency:** `setRating(_:forURLs:)` (TagStore, Task 3), `setRating(_:forSelectionFallback:)` (AppState, Task 4), `reloadStarRatings()` (Task 4), `uniformRating(forPaths:)` (Task 4), `starRatings` (Task 4), `RatingLoader.ratings(paths:simpleFolderDir:queue:)` (Task 4), `StarRating.label(for:)`/`rating(from:)`/`isRating`/`allLabels`/`maxStars`/`resolution(existingLabels:newRating:)` (Task 1) — names used identically across Tasks 3–8.

## Execution Handoff

Plan complete and saved to `docs/superpowers/plans/2026-07-06-star-ratings.md`. Two execution options:

1. **Subagent-Driven (recommended)** — dispatch a fresh subagent per task, review between tasks.
2. **Inline Execution** — execute tasks in this session with checkpoints.

Which approach?
