# Hero Viewer (Polish Phase 2) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the image-viewing overlay with the hero viewer specced in `docs/superpowers/specs/2026-06-10-post-rewrite-polish-design.md` §2 and prototyped in `.superpowers/brainstorm/*/content/open-image-motion-v6.html`: fly-up open from the grid cell, adaptive color-wash + frosted backdrop, card-based info column with no-reflow tag pills, zoom/pan/Fit chrome, arrow-key flipping, Delete-to-Trash with Undo.

**Architecture:** A new `HeroImageViewer` replaces `ImageViewer` in `ViewerRouter` for image kinds only (PDF/video/etc. keep `ViewerChrome`). The open/close motion is explicit rect interpolation (tile frame → fit frame), not `matchedGeometryEffect` — tile frames are reported up via a PreferenceKey. All geometry/pill math is pure and unit-tested; SwiftUI views consume it. Per-file collection membership gets a v3 migration (`added_by` + exclusions) so manual edits survive reclustering.

**Tech Stack:** SwiftUI (macOS 14.6+), GRDB, existing TagStore/CollectionStore/ThumbnailCache, FileManager.trashItem for undo-able delete, XCTest.

**Verified project facts:** Xcode 16 synced folders (new files auto-included; tests in `Muse/MuseTests/`, never repo-root). Build/test from `Muse/` dir: `xcodebuild -scheme Muse build`, `xcodebuild test -scheme Muse -destination 'platform=macOS' -only-testing:MuseTests`. Tile tap currently sets `appState.selectedFile` (GridView.swift:35); overlay shown from ContentView ZStack; Esc handled by hidden button (collections overlay first, then selectedFile). DuplicatesView uses `NSWorkspace.shared.recycle`. TagStore: `tags(for:)/addManualTag(label:for:)/removeTag(_:for:)`. FileRow has `palette` (JSON [String]) and `dominant_color`. The toolbar is AT the 10-item ToolbarContentBuilder limit — any new toolbar item must merge into an existing group.

---

### Task 0: Branch

- [ ] `cd /Users/carlostarrats/Documents/Projects/Muse && git checkout -b feat/hero-viewer`

---

### Task 1: Schema v3 — manual collection membership + exclusions

**Files:** Modify `Muse/Muse/Database/Database.swift`, `Muse/Muse/Database/Records.swift`, `Muse/Muse/Intelligence/Collections/CollectionStore.swift`; Test `Muse/MuseTests/CollectionMembershipTests.swift`.

- [ ] **Step 1 — failing tests** (`CollectionMembershipTests.swift`):

```swift
import XCTest
import GRDB
@testable import Muse

final class CollectionMembershipTests: XCTestCase {
    private func makeQueue() throws -> DatabaseQueue {
        let q = try DatabaseQueue()
        try Database.makeMigrator().migrate(q)
        try q.write { db in
            for id in ["f1", "f2", "f3", "f4", "f5"] {
                try db.execute(sql: "INSERT INTO files (id, kind, last_seen_at) VALUES (?, 'image', 0)",
                               arguments: [id])
            }
        }
        return q
    }

    func testManualAddSurvivesUpsert() async throws {
        let q = try makeQueue()
        try await CollectionStore.upsert(queue: q, id: "c1", name: "Dogs",
                                         memberIDs: ["f1", "f2"], modelVersion: "t")
        try await CollectionStore.addFile(queue: q, fileID: "f5", collectionID: "c1")
        // recluster-style upsert with different auto members
        try await CollectionStore.upsert(queue: q, id: "c1", name: "Dogs",
                                         memberIDs: ["f1", "f3"], modelVersion: "t")
        let all = try await CollectionStore.fetchAll(queue: q)
        XCTAssertEqual(Set(all[0].memberIDs), Set(["f1", "f3", "f5"]),
                       "manual member f5 must survive auto rebuild")
    }

    func testManualRemoveExcludesFromFutureUpserts() async throws {
        let q = try makeQueue()
        try await CollectionStore.upsert(queue: q, id: "c1", name: "Dogs",
                                         memberIDs: ["f1", "f2"], modelVersion: "t")
        try await CollectionStore.removeFile(queue: q, fileID: "f1", collectionID: "c1")
        var all = try await CollectionStore.fetchAll(queue: q)
        XCTAssertEqual(Set(all[0].memberIDs), Set(["f2"]))
        // auto rebuild re-proposes f1 — exclusion must hold
        try await CollectionStore.upsert(queue: q, id: "c1", name: "Dogs",
                                         memberIDs: ["f1", "f2"], modelVersion: "t")
        all = try await CollectionStore.fetchAll(queue: q)
        XCTAssertEqual(Set(all[0].memberIDs), Set(["f2"]))
    }

    func testCollectionsForFile() async throws {
        let q = try makeQueue()
        try await CollectionStore.upsert(queue: q, id: "c1", name: "Dogs",
                                         memberIDs: ["f1"], modelVersion: "t")
        try await CollectionStore.upsert(queue: q, id: "c2", name: "Pets",
                                         memberIDs: ["f1", "f2"], modelVersion: "t")
        let names = try await CollectionStore.collections(queue: q, forFileID: "f1")
            .map(\.name).sorted()
        XCTAssertEqual(names, ["Dogs", "Pets"])
    }
}
```

- [ ] **Step 2 — migration `v3_membership`** appended in `Database.makeMigrator()`:

```swift
migrator.registerMigration("v3_membership") { db in
    try db.alter(table: "collection_members") { t in
        t.add(column: "added_by", .text).notNull().defaults(to: "auto")  // "auto" | "manual"
    }
    try db.create(table: "collection_exclusions") { t in
        t.column("collection_id", .text).notNull()
            .references("collections", onDelete: .cascade)
        t.column("file_id", .text).notNull()
            .references("files", onDelete: .cascade)
        t.primaryKey(["collection_id", "file_id"])
    }
}
```

Add `var added_by: String` to `CollectionMemberRow` — then fix its construction sites (grep `CollectionMemberRow(`; the SchemaV2 cascade test constructs one: add `added_by: "auto"`).

- [ ] **Step 3 — CollectionStore changes:**
  - `upsert`: change member rebuild to `DELETE FROM collection_members WHERE collection_id = ? AND added_by = 'auto'`; insert incoming ids with `added_by 'auto'` via `INSERT OR IGNORE`, but skip ids present in `collection_exclusions` for that collection (single `NOT IN` subselect or pre-fetch the exclusion set).
  - New:

```swift
static func addFile(queue: DatabaseQueue, fileID: String, collectionID: String) async throws {
    try await queue.write { db in
        try db.execute(sql: """
            INSERT OR REPLACE INTO collection_members (collection_id, file_id, added_by)
            VALUES (?, ?, 'manual')
            """, arguments: [collectionID, fileID])
        try db.execute(sql: "DELETE FROM collection_exclusions WHERE collection_id = ? AND file_id = ?",
                       arguments: [collectionID, fileID])
    }
}

static func removeFile(queue: DatabaseQueue, fileID: String, collectionID: String) async throws {
    try await queue.write { db in
        try db.execute(sql: "DELETE FROM collection_members WHERE collection_id = ? AND file_id = ?",
                       arguments: [collectionID, fileID])
        try db.execute(sql: """
            INSERT OR IGNORE INTO collection_exclusions (collection_id, file_id) VALUES (?, ?)
            """, arguments: [collectionID, fileID])
    }
}

static func collections(queue: DatabaseQueue, forFileID fileID: String) async throws -> [CollectionRow] {
    try await queue.read { db in
        try CollectionRow.fetchAll(db, sql: """
            SELECT c.* FROM collections c
            JOIN collection_members m ON m.collection_id = c.id
            WHERE m.file_id = ? AND c.is_hidden = 0
            """, arguments: [fileID])
    }
}

/// Create a brand-new manual collection containing one file.
static func createManual(queue: DatabaseQueue, name: String, fileID: String) async throws -> String {
    let id = UUID().uuidString
    let now = Int64(Date().timeIntervalSince1970)
    try await queue.write { db in
        try db.execute(sql: """
            INSERT INTO collections (id, name, is_hidden, model_version, created_at, updated_at)
            VALUES (?, ?, 0, 'manual', ?, ?)
            """, arguments: [id, name, now, now])
        try db.execute(sql: """
            INSERT INTO collection_members (collection_id, file_id, added_by) VALUES (?, ?, 'manual')
            """, arguments: [id, fileID])
    }
    return id
}
```

  - One more invariant: `CollectionsEngine.recluster()` deletes collections whose id isn't in the new matched set — manual collections (model_version 'manual') and collections that have any manual members must NOT be deleted as stale. In `CollectionsEngine.recluster()`, change the stale-delete loop to skip collections that have manual members or `model_version = 'manual'` (query: `SELECT DISTINCT collection_id FROM collection_members WHERE added_by = 'manual'`). Add a test in `CollectionMembershipTests`:

```swift
func testStaleDeleteSkipsManualCollections() async throws {
    // covered indirectly: createManual + an upsert of a different collection,
    // then simulate engine stale-delete logic via the new helper
    let q = try makeQueue()
    let id = try await CollectionStore.createManual(queue: q, name: "Faves", fileID: "f1")
    let protected = try await CollectionStore.protectedCollectionIDs(queue: q)
    XCTAssertTrue(protected.contains(id))
}
```

  - Implement `protectedCollectionIDs(queue:) -> Set<String>` (manual model_version OR has manual members) and use it in the engine's stale-delete loop.

- [ ] **Step 4 — run tests (new + ALL existing CollectionStore/SchemaV2 tests) until green; full build. Step 5 — commit** `feat(viewer): schema v3 — manual membership + exclusions`.

---

### Task 2: ViewerGeometry (pure math)

**Files:** Create `Muse/Muse/Views/Viewer/ViewerGeometry.swift`; Test `Muse/MuseTests/ViewerGeometryTests.swift`.

- [ ] **Step 1 — failing tests:**

```swift
import XCTest
@testable import Muse

final class ViewerGeometryTests: XCTestCase {
    // viewport 1200x800, column 298 (258 + 40 margin), pad 40, topPad 70, bottomPad 60
    func testFitCentersBetweenEdgeAndColumn() {
        let r = ViewerGeometry.fitRect(imageSize: CGSize(width: 2400, height: 1600),
                                       viewport: CGSize(width: 1200, height: 800))
        let usableRight = 1200 - 298.0
        XCTAssertEqual(r.midX, (usableRight) / 2, accuracy: 0.5)   // centered in viewable space
        XCTAssertLessThanOrEqual(r.maxX, usableRight + 0.5)        // never under the column
        XCTAssertEqual(r.width / r.height, 1.5, accuracy: 0.01)    // aspect preserved
    }
    func testTallImageHeightLimited() {
        let r = ViewerGeometry.fitRect(imageSize: CGSize(width: 800, height: 2400),
                                       viewport: CGSize(width: 1200, height: 800))
        XCTAssertEqual(r.height, 800 - 70 - 60, accuracy: 0.5)
    }
    func testZoomClamp() {
        XCTAssertEqual(ViewerGeometry.clampZoom(0.3), 1.0)
        XCTAssertEqual(ViewerGeometry.clampZoom(9), 4.0)
        XCTAssertEqual(ViewerGeometry.clampZoom(2.2), 2.2)
    }
    func testPanClamp() {
        // zoom 2 on a 600x400 fitted image → max offset (z-1)*size/2 = (300,200)
        let p = ViewerGeometry.clampPan(CGSize(width: 999, height: -999),
                                        fittedSize: CGSize(width: 600, height: 400), zoom: 2)
        XCTAssertEqual(p.width, 300); XCTAssertEqual(p.height, -200)
        let q = ViewerGeometry.clampPan(CGSize(width: 50, height: 50),
                                        fittedSize: CGSize(width: 600, height: 400), zoom: 1)
        XCTAssertEqual(q, .zero)   // no pan at fit
    }
    func testDegenerateInputs() {
        let r = ViewerGeometry.fitRect(imageSize: .zero, viewport: CGSize(width: 100, height: 100))
        XCTAssertFalse(r.width.isNaN); XCTAssertFalse(r.height.isNaN)
    }
}
```

- [ ] **Step 2 — implement:**

```swift
import Foundation

/// Pure geometry for the hero viewer. Constants mirror the approved prototype:
/// info column 258pt + 40pt margin, 40pt side pad, 70pt top, 60pt bottom.
enum ViewerGeometry {
    static let columnWidth: CGFloat = 258
    static let columnMargin: CGFloat = 40
    static let sidePad: CGFloat = 40
    static let topPad: CGFloat = 70
    static let bottomPad: CGFloat = 60
    static let maxZoom: CGFloat = 4
    static let minZoom: CGFloat = 1

    /// Centered in the true viewable space: between the left edge and the info column.
    static func fitRect(imageSize: CGSize, viewport: CGSize) -> CGRect {
        let usableRight = viewport.width - columnWidth - columnMargin * 2
        let availW = max(120, usableRight - sidePad * 2)
        let availH = max(120, viewport.height - topPad - bottomPad)
        guard imageSize.width > 0, imageSize.height > 0 else {
            return CGRect(x: sidePad, y: topPad, width: availW, height: availH)
        }
        let s = min(availW / imageSize.width, availH / imageSize.height)
        let w = imageSize.width * s, h = imageSize.height * s
        return CGRect(x: sidePad + (availW - w) / 2,
                      y: topPad + (availH - h) / 2,
                      width: w, height: h)
    }

    static func clampZoom(_ z: CGFloat) -> CGFloat { min(maxZoom, max(minZoom, z)) }

    static func clampPan(_ offset: CGSize, fittedSize: CGSize, zoom: CGFloat) -> CGSize {
        let maxX = max(0, (zoom - 1) * fittedSize.width / 2)
        let maxY = max(0, (zoom - 1) * fittedSize.height / 2)
        return CGSize(width: min(maxX, max(-maxX, offset.width)),
                      height: min(maxY, max(-maxY, offset.height)))
    }
}
```

(Note: test expects `midX == usableRight/2` — that holds because `sidePad + (availW - w)/2 + w/2 == usableRight/2` when centered; verify algebra against the test, adjust test accuracy if off by pad rounding.)

- [ ] **Step 3 — green + build. Step 4 — commit** `feat(viewer): viewer geometry (fit/zoom/pan math)`.

---

### Task 3: PillRowModel (pure no-reflow hover math)

Port of the prototype's verified algorithm (the one stress-tested in the brainstorm session).

**Files:** Create `Muse/Muse/Views/Viewer/PillRowModel.swift`; Test `Muse/MuseTests/PillRowModelTests.swift`.

- [ ] **Step 1 — failing tests:**

```swift
import XCTest
@testable import Muse

final class PillRowModelTests: XCTestCase {
    // container 230, gap 6
    func testRowAssignmentWraps() {
        let rows = PillRowModel.rows(naturals: [100, 100, 100], container: 230, gap: 6)
        XCTAssertEqual(rows, [0, 0, 1])   // third wraps
    }
    func testHoverStealsFromSlackFirst() {
        // one row with plenty of slack: no shrink needed
        let w = PillRowModel.widths(naturals: [60, 60], container: 230, gap: 6,
                                    hovered: 0, grow: 17, floor: 26)
        XCTAssertEqual(w[0], 77)          // grew fully
        XCTAssertEqual(w[1], 60)          // untouched
    }
    func testHoverShrinksFollowingSameRowOnly() {
        // row0: [100, 100] (slack 230-206=24 ≥ 17+3 → no shrink), force tight:
        let w = PillRowModel.widths(naturals: [120, 104], container: 230, gap: 6,
                                    hovered: 0, grow: 17, floor: 26)
        // slack = 230 - (120+6+104) = 0 → deficit 17+3=20 → shrink pill1 by 20
        XCTAssertEqual(w[0], 137)
        XCTAssertEqual(w[1], 84)
    }
    func testHoverNeverMovesEarlierPillsOrOtherRows() {
        let naturals: [CGFloat] = [100, 100, 100, 100]   // rows [0,0,1,1]
        let w = PillRowModel.widths(naturals: naturals, container: 230, gap: 6,
                                    hovered: 2, grow: 17, floor: 26)
        XCTAssertEqual(w[0], 100); XCTAssertEqual(w[1], 100)   // row 0 untouched
        // hovered grew; row partner shrank by deficit
        XCTAssertEqual(w[2], 117)
        XCTAssertEqual(w[3], 100 - (17 - 24 + 3))   // slack 24 → deficit -4 → no shrink
        // row width never exceeds container
        XCTAssertLessThanOrEqual(w[2] + 6 + w[3], 230)
    }
    func testSelfTruncateWhenSiblingsCantGive() {
        // hovered is last in a full row with no following siblings
        let w = PillRowModel.widths(naturals: [120, 104], container: 230, gap: 6,
                                    hovered: 1, grow: 17, floor: 26)
        // slack 0, no following pills → self-truncate: total width must still fit
        XCTAssertLessThanOrEqual(w[0] + 6 + w[1], 230)
        XCTAssertEqual(w[0], 120)         // earlier pill never moves
    }
}
```

- [ ] **Step 2 — implement:**

```swift
import Foundation

/// No-reflow pill hover math, ported from the approved HTML prototype.
/// All inputs are NATURAL widths (measured once); never live geometry.
enum PillRowModel {
    /// Greedy row assignment by natural widths.
    static func rows(naturals: [CGFloat], container: CGFloat, gap: CGFloat) -> [Int] {
        var out: [Int] = []
        var row = 0, used: CGFloat = 0
        for (i, w) in naturals.enumerated() {
            let add = (used == 0 ? w : used + gap + w)
            if used > 0 && add > container { row += 1; used = w }
            else { used = add }
            out.append(row)
            _ = i
        }
        return out
    }

    /// Width of every pill given a hover. Invariants: pills before the hovered
    /// one (and other rows) keep natural width; the hovered pill grows by
    /// `grow` (stealing end-of-row slack first, then shrinking FOLLOWING
    /// same-row pills down to `floor`, then truncating itself); a row's total
    /// width never exceeds `container`.
    static func widths(naturals: [CGFloat], container: CGFloat, gap: CGFloat,
                       hovered: Int?, grow: CGFloat, floor: CGFloat,
                       buffer: CGFloat = 3) -> [CGFloat] {
        var out = naturals
        guard let h = hovered, naturals.indices.contains(h) else { return out }
        let assignment = rows(naturals: naturals, container: container, gap: gap)
        let myRow = assignment[h]
        let rowIdx = naturals.indices.filter { assignment[$0] == myRow }
        let rowW = rowIdx.reduce(CGFloat(0)) { $0 + naturals[$1] } + gap * CGFloat(rowIdx.count - 1)
        let slack = container - rowW
        var deficit = max(0, grow - slack + buffer)
        var grown = grow
        for i in rowIdx where i > h {
            guard deficit > 0 else { break }
            let take = min(deficit, max(0, naturals[i] - floor))
            out[i] = naturals[i] - take
            deficit -= take
        }
        if deficit > 0 { grown -= deficit }   // self-truncate remainder
        out[h] = naturals[h] + grown
        return out
    }
}
```

Tune nothing in tests; if an assertion fails re-derive the arithmetic (the tests encode the invariants from the stress-tested prototype). 

- [ ] **Step 3 — green + build. Step 4 — commit** `feat(viewer): no-reflow pill row math`.

---

### Task 4: ViewerFileDetails loader

**Files:** Create `Muse/Muse/Views/Viewer/ViewerFileDetails.swift`; Test `Muse/MuseTests/ViewerFileDetailsTests.swift`.

- [ ] **Step 1 — failing test:**

```swift
import XCTest
import GRDB
@testable import Muse

final class ViewerFileDetailsTests: XCTestCase {
    func testLoadByPath() async throws {
        let q = try DatabaseQueue()
        try Database.makeMigrator().migrate(q)
        try q.write { db in
            try db.execute(sql: """
                INSERT INTO files (id, kind, last_seen_at, width, height, size_bytes,
                                   dominant_color, palette)
                VALUES ('f1', 'image', 0, 2400, 1600, 1048576, '#4a3320',
                        '["#4a3320","#8a6a42"]')
                """)
            try db.execute(sql: """
                INSERT INTO paths (id, file_id, absolute_path, is_alive)
                VALUES ('p1', 'f1', '/tmp/dog.jpg', 1)
                """)
            try db.execute(sql: """
                INSERT INTO tags (id, file_id, label, source, confidence)
                VALUES ('t1', 'f1', 'dog', 'vision', 0.9)
                """)
        }
        let d = try await ViewerFileDetails.load(queue: q, path: "/tmp/dog.jpg")
        XCTAssertEqual(d?.fileID, "f1")
        XCTAssertEqual(d?.pixelSize, CGSize(width: 2400, height: 1600))
        XCTAssertEqual(d?.palette, ["#4a3320", "#8a6a42"])
        XCTAssertEqual(d?.dominantColor, "#4a3320")
        XCTAssertEqual(d?.tags.map(\.label), ["dog"])
    }
    func testUnindexedReturnsNil() async throws {
        let q = try DatabaseQueue()
        try Database.makeMigrator().migrate(q)
        let d = try await ViewerFileDetails.load(queue: q, path: "/nope.jpg")
        XCTAssertNil(d)
    }
}
```

- [ ] **Step 2 — implement:**

```swift
import Foundation
import GRDB

/// Everything the viewer's info column needs about one file, loaded in one read.
struct ViewerFileDetails {
    var fileID: String
    var pixelSize: CGSize?
    var sizeBytes: Int64?
    var dominantColor: String?
    var palette: [String]
    var tags: [TagRow]
    var collections: [CollectionRow]

    static func load(queue: DatabaseQueue, path: String) async throws -> ViewerFileDetails? {
        try await queue.read { db in
            guard let p = try PathRow
                    .filter(Column("absolute_path") == path && Column("is_alive") == 1)
                    .fetchOne(db),
                  let fid = p.file_id,
                  let f = try FileRow.fetchOne(db, key: fid) else { return nil }
            let palette: [String] = f.palette
                .flatMap { $0.data(using: .utf8) }
                .flatMap { try? JSONDecoder().decode([String].self, from: $0) } ?? []
            let tags = try TagRow.filter(Column("file_id") == fid)
                .order(Column("label")).fetchAll(db)
            let cols = try CollectionRow.fetchAll(db, sql: """
                SELECT c.* FROM collections c
                JOIN collection_members m ON m.collection_id = c.id
                WHERE m.file_id = ? AND c.is_hidden = 0
                """, arguments: [fid])
            var size: CGSize? = nil
            if let w = f.width, let h = f.height { size = CGSize(width: w, height: h) }
            return ViewerFileDetails(fileID: fid, pixelSize: size, sizeBytes: f.size_bytes,
                                     dominantColor: f.dominant_color, palette: palette,
                                     tags: tags, collections: cols)
        }
    }
}
```

- [ ] **Step 3 — green + build. Step 4 — commit** `feat(viewer): file details loader`.

---

### Task 5: TrashManager (undo-able delete)

**Files:** Create `Muse/Muse/Filesystem/TrashManager.swift`; Test `Muse/MuseTests/TrashManagerTests.swift`.

- [ ] **Step 1 — failing test:**

```swift
import XCTest
@testable import Muse

final class TrashManagerTests: XCTestCase {
    func testTrashAndUndo() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("x.txt")
        try "hello".data(using: .utf8)!.write(to: file)

        let ticket = try TrashManager.trash(file)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        try TrashManager.undo(ticket)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "hello")
    }
}
```

- [ ] **Step 2 — implement:**

```swift
import Foundation

/// Trash with undo. Files are NEVER unlinked — FileManager.trashItem moves to
/// the user Trash and reports where it landed so we can move it back.
enum TrashManager {
    struct Ticket {
        var originalURL: URL
        var trashedURL: URL
    }

    static func trash(_ url: URL) throws -> Ticket {
        var trashed: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &trashed)
        guard let t = trashed as URL? else {
            throw CocoaError(.fileWriteUnknown)
        }
        return Ticket(originalURL: url, trashedURL: t)
    }

    static func undo(_ ticket: Ticket) throws {
        try FileManager.default.moveItem(at: ticket.trashedURL, to: ticket.originalURL)
    }
}
```

(Sandbox note: trashItem works on user-selected files within the security scope. The test uses temporaryDirectory which is always writable; on some CI-ish configs trashItem on tmp can fail with "feature unsupported" — if the test errors that way, have the test create the file in `FileManager.default.urls(for: .desktopDirectory...)`? NO — do not write outside tmp. Instead catch that specific failure in the TEST with `try XCTSkipIf(...)` and note it; the app path is exercised in manual QA.)

- [ ] **Step 3 — green (or documented skip) + build. Step 4 — commit** `feat(viewer): undo-able trash manager`.

---

### Task 6: Tile frame reporting (hero source rects)

**Files:** Modify `Muse/Muse/Views/GridView.swift`, `Muse/Muse/Models/AppState.swift`.

- [ ] **Step 1:** Add a preference key + plumbing so the viewer can know the tapped tile's frame in GLOBAL coordinates (the existing GeometryReader uses space "gridViewport" — the overlay lives at window level, so capture `.global`):

In `GridView.swift` (inside TileView's existing GeometryReader): also report globally:

```swift
.onAppear { appState.tileFrames[file.url.path] = proxy.frame(in: .global) }
.onChange(of: proxy.frame(in: .global)) { _, f in appState.tileFrames[file.url.path] = f }
```

In `AppState`: `var tileFrames: [String: CGRect] = [:]` (NOT @Published — frames update constantly during scroll; publishing would thrash the UI. Plain stored property is fine: it's read once at open).

- [ ] **Step 2:** Build + existing tests green. **Step 3 — commit** `feat(viewer): tiles report global frames for hero transition`.

---

### Task 7: Backdrop + HeroStage (the motion core)

**Files:** Create `Muse/Muse/Views/Viewer/ViewerBackdrop.swift`, `Muse/Muse/Views/Viewer/HeroStage.swift`.

- [ ] **Step 1 — ViewerBackdrop** (blur + adaptive tint, spec §2 "Background"):

```swift
import SwiftUI

/// Frosted blur of the app content + a translucent wash of the image's
/// dominant color darkened ~45%. Color cross-fades on arrow-key flips.
struct ViewerBackdrop: View {
    var hexColor: String?    // dominant color; nil → neutral dark

    private var tint: Color {
        guard let hex = hexColor, let (r, g, b) = NamedColor.parse(hex) else {
            return Color(red: 0.08, green: 0.08, blue: 0.09)
        }
        let k = 0.55   // darken
        return Color(red: r * k, green: g * k, blue: b * k)
    }

    var body: some View {
        ZStack {
            Rectangle().fill(.ultraThinMaterial)
            tint.opacity(0.78)
        }
        .ignoresSafeArea()
        .animation(.easeInOut(duration: 0.6), value: hexColor)
    }
}
```

- [ ] **Step 2 — HeroStage**: the rect-animated image. State machine: `.opening(from: CGRect)` → `.open` → `.closing(to: CGRect)`. Owns zoom/pan.

```swift
import SwiftUI

/// The flying image: animates from the grid tile rect to the fitted rect and
/// back, then hosts zoom (1–4x) and drag-pan when zoomed.
/// Timings from the approved prototype: open 0.4s gentle ease-out,
/// close 0.34s with a hint of settle.
struct HeroStage: View {
    let url: URL
    let sourceFrame: CGRect          // tile frame, global coords
    let viewport: CGSize
    var onCloseFinished: () -> Void

    @Binding var zoom: CGFloat
    @Binding var pan: CGSize
    @Binding var isClosing: Bool     // set true by parent to run the return flight

    @State private var displayRect: CGRect = .zero
    @State private var image: NSImage?
    @State private var fullResLoaded = false
    @State private var dragStartPan: CGSize? = nil

    private var fitRect: CGRect {
        ViewerGeometry.fitRect(imageSize: image?.size ?? sourceFrame.size,
                               viewport: viewport)
    }

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: displayRect.width, height: displayRect.height)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .shadow(color: .black.opacity(0.5), radius: 40, y: 24)
                    .scaleEffect(zoom)
                    .offset(pan)
                    .position(x: displayRect.midX, y: displayRect.midY)
                    .gesture(panGesture)
            }
        }
        .onAppear { open() }
        .onChange(of: isClosing) { _, closing in if closing { close() } }
        .onChange(of: url) { _, _ in flipTo() }
        .task(id: url) { await loadFullRes() }
    }

    private func open() {
        displayRect = sourceFrame
        // thumbnail immediately so launch is instant
        Task {
            image = await ThumbnailCache.shared.thumbnail(
                for: url, size: CGSize(width: 320, height: 320))
            withAnimation(.timingCurve(0.25, 0.8, 0.25, 1, duration: 0.4)) {
                displayRect = fitRect
            }
        }
    }

    private func close() {
        withAnimation(.timingCurve(0.3, 1.08, 0.35, 1, duration: 0.34)) {
            zoom = 1; pan = .zero
            displayRect = sourceFrame
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.36) { onCloseFinished() }
    }

    private func flipTo() {
        zoom = 1; pan = .zero
        fullResLoaded = false
        Task {
            image = await ThumbnailCache.shared.thumbnail(
                for: url, size: CGSize(width: 320, height: 320))
            withAnimation(.easeOut(duration: 0.2)) { displayRect = fitRect }
            await loadFullRes()
        }
    }

    private func loadFullRes() async {
        let u = url
        let img = await Task.detached(priority: .userInitiated) { NSImage(contentsOf: u) }.value
        if let img, u == url {
            image = img
            fullResLoaded = true
            withAnimation(.easeOut(duration: 0.2)) { displayRect = fitRect }
        }
    }

    private var panGesture: some Gesture {
        DragGesture()
            .onChanged { v in
                guard zoom > 1 else { return }
                let start = dragStartPan ?? pan
                dragStartPan = start
                pan = ViewerGeometry.clampPan(
                    CGSize(width: start.width + v.translation.width,
                           height: start.height + v.translation.height),
                    fittedSize: displayRect.size, zoom: zoom)
            }
            .onEnded { _ in dragStartPan = nil }
    }
}
```

- [ ] **Step 3 — build green. Step 4 — commit** `feat(viewer): backdrop + hero stage motion core`.

---

### Task 8: Info column (cards, pills, expander, colors, actions)

**Files:** Create `Muse/Muse/Views/Viewer/ViewerInfoColumn.swift`, `Muse/Muse/Views/Viewer/PillFlow.swift`, `Muse/Muse/Views/Viewer/ViewerToast.swift`.

- [ ] **Step 1 — PillFlow**: a custom `Layout` consuming `PillRowModel`:

```swift
import SwiftUI

/// Wrapping pill rows with the no-reflow hover behavior. Children must be
/// HoverPill so natural widths are stable; widths come from PillRowModel.
struct PillFlow: Layout {
    var gap: CGFloat = 6
    var hovered: Int?

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let container = proposal.width ?? 230
        let naturals = subviews.map { $0.sizeThatFits(.unspecified).width }
        let rows = PillRowModel.rows(naturals: naturals, container: container, gap: gap)
        let rowCount = (rows.max() ?? -1) + 1
        let h = subviews.first?.sizeThatFits(.unspecified).height ?? 22
        return CGSize(width: container,
                      height: CGFloat(rowCount) * h + CGFloat(max(0, rowCount - 1)) * gap)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize,
                       subviews: Subviews, cache: inout ()) {
        let container = bounds.width
        let naturals = subviews.map { $0.sizeThatFits(.unspecified).width }
        let rows = PillRowModel.rows(naturals: naturals, container: container, gap: gap)
        let widths = PillRowModel.widths(naturals: naturals, container: container, gap: gap,
                                         hovered: hovered, grow: 17, floor: 26)
        let h = subviews.first?.sizeThatFits(.unspecified).height ?? 22
        var x = bounds.minX, y = bounds.minY, row = 0
        for (i, sub) in subviews.enumerated() {
            if rows[i] != row { row = rows[i]; x = bounds.minX; y = bounds.minY + CGFloat(row) * (h + gap) }
            sub.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(width: widths[i], height: h))
            x += widths[i] + gap
        }
    }
}
```

Plus a `HoverPill` view: label truncating tail, reveal-✕ on hover (the ✕ sits inside the grown width; remove action), `onHover` reports its index up via a binding, hover styling (`.background(...opacity)`), animation `.easeOut(duration: 0.18)` applied by the PARENT to the hovered index value so widths animate. Body tap = filter/navigate action; ✕ tap = remove.

- [ ] **Step 2 — ViewerToast**: bottom-center capsule with message + optional Undo action, auto-dismiss after 3.5s (1.4s when no action). Driven by an `@Observable`-style `ToastState` or simple `@Binding (message, action)?`.

- [ ] **Step 3 — ViewerInfoColumn**: width 258, trailing margin 40, top 80. Title (16 semibold) + dim file info line. Three rounded cards (`.background(.white.opacity(0.09))`, radius 14): 
  - **Collection card**: pills of `details.collections` (tap → close viewer + `appState.setActiveCollection(id)`; ✕ → `CollectionStore.removeFile` + reload details + toast). ＋ button expands the card downward (spring `.spring(response: 0.45, dampingFraction: 0.75)`): existing collections as dashed pills (tap → addFile) + "create new" TextField with ＋ submit (→ `CollectionStore.createManual`). ＋ rotates 45° while open.
  - **Tags card**: same pattern with `TagStore.addManualTag/removeTag`; pill tap filters: set `appState.searchQuery = label; appState.isSearchActive = true` …NO — keep scope: tag tap closes the viewer and runs a tag search via the existing search path (`appState.searchQuery = label` + trigger the same search invocation SearchBar uses — read how SearchBar triggers search and call that; if it's debounced-internal, expose a `runSearch(query:)` on AppState if one exists from the search flow — adapt to reality).
  - **Colors card**: swatches from `details.palette` (wrap), tap = copy hex to `NSPasteboard.general` + toast "Copied #…", "copy all" copies comma-joined.
  - **Actions row**: "Open in Finder" → `NSWorkspace.shared.activateFileViewerSelecting([url])`; "Delete" → handled by parent callback (Task 9 wires TrashManager).
  - Column scrolls (`ScrollView` with hidden indicators) when content exceeds viewport.

- [ ] **Step 4 — build green. Step 5 — commit** `feat(viewer): info column with cards, no-reflow pills, expander add-flow`.

---

### Task 9: HeroImageViewer composition + routing

**Files:** Create `Muse/Muse/Views/Viewer/HeroImageViewer.swift`; Modify `Muse/Muse/Views/ViewerRouter.swift`, `Muse/Muse/ContentView.swift`, `Muse/Muse/Models/AppState.swift`.

- [ ] **Step 1 — HeroImageViewer**: composes Backdrop + HeroStage + InfoColumn + chrome:
  - Chrome: ✕ top-RIGHT (38pt circle, right-aligned with the info column, 18pt from top, hover state) — hidden while zoomed; zoom pill (− / readout / ＋, 38pt tall) top-LEFT-aligned with the column; "Fit" button appears next to it when zoom > 1 (click → zoom 1, pan zero). Readout: "Fit" at zoom 1 else percentage = `Int(zoom * fitScale * 100)` where fitScale = fitted/natural width.
  - Scroll-wheel zoom: NSViewRepresentable `ScrollWheelCatcher` overlaying the stage area only (NOT the info column — column scrolls normally): `zoom = ViewerGeometry.clampZoom(zoom * (deltaY > 0 ? 1.08 : 0.93))`, re-clamp pan.
  - Keyboard: arrows flip to next/prev IMAGE-kind file in `appState.visibleFiles` (wrap around; non-image kinds skipped); Esc closes (see Step 3). Use `.onKeyPress(.leftArrow)`/`.rightArrow` (macOS 14) on a focused container, or reuse the KeyCaptureView pattern from CollectionsOverlay — prefer reusing `KeyCaptureView` (extend it with optional up/down/esc handlers if needed, keeping CollectionsOverlay behavior identical).
  - Delete: button → `TrashManager.trash(url)` → start close flight → toast "Moved to Trash" + Undo (Undo: `TrashManager.undo(ticket)`; the FolderWatcher refreshes the grid either way — verify the deleted file disappears from currentFiles via the existing FSEvents path; if the watcher lags, also remove the file from `appState.currentFiles` directly and re-insert on undo).
  - Dismissal contract: parent sets `isClosing = true`; when the flight lands, `onCloseFinished` clears `appState.selectedFile`. Info column + chrome fade OUT fast (0.12s, no delay) the moment closing starts; fade IN slow (0.4s, 0.15s delay) on open — per spec.
- [ ] **Step 2 — routing**: in `ViewerRouter`, image kinds now return `HeroImageViewer(file: file, sourceFrame: appState.tileFrames[file.url.path] ?? centerFallbackRect)`. Keep all other kinds on ViewerChrome. Delete the old `ImageViewer.swift`? NO — keep the file but stop routing to it ONLY if anything else references it (grep; if unreferenced, delete it and note in commit).
- [ ] **Step 3 — Esc integration** in ContentView's hidden Esc button: order becomes (1) collections overlay, (2) if selectedFile is image-kind → trigger the hero CLOSE FLIGHT (set a new `appState.viewerClosing = true` that HeroImageViewer observes) instead of instantly nil-ing selectedFile, (3) other viewer kinds → `selectedFile = nil` as today. Add `@Published var viewerClosing = false` to AppState; HeroImageViewer resets it in onCloseFinished.
- [ ] **Step 4 — build + ALL MuseTests green. Step 5 — commit** `feat(viewer): hero image viewer composition + routing`.

---

### Task 10: Final verification

- [ ] Full suite: `cd Muse && xcodebuild test -scheme Muse -destination 'platform=macOS' -only-testing:MuseTests 2>&1 | grep -E 'TEST|failed'` → SUCCEEDED.
- [ ] Full build, zero new warnings.
- [ ] Dispatch final whole-branch reviewer (spec §2 coverage sweep: every choreography bullet, timings, no-reflow invariants, zoom/pan/Fit behavior, ✕/zoom placement, clickable/removable pills, expander add-flow, copyable colors, Delete→Trash+Undo, never-unlink audit, zero-network audit).
- [ ] Manual QA checklist for Carlos (run the app):
  1. Click an image → flies from its tile to center-left, background washes with its color, grid ghosts through the blur; info column fades in after the image lands.
  2. Esc / ✕ / click-outside → flies back into its exact tile, no flicker, info fades instantly.
  3. ←/→ flips between images; wash cross-fades; non-images skipped.
  4. Scroll/＋ zooms with % readout; ✕ hides and Fit appears; drag pans clamped; Fit recenters.
  5. Tags: hover grows pill without any row reflow; ✕ removes; ＋ expands card with existing tags + create field; tag tap searches.
  6. Collections card: add to existing/new; remove; survives a later Analyze (recluster) — manual adds stay, removals stay removed.
  7. Colors: tap swatch copies hex (toast); copy all.
  8. Delete → toast with Undo; file in macOS Trash; Undo restores it to the folder and grid.
  9. Resize window while open: image re-fits centered, never under the column.

---

## Self-review notes
- Spec §2 coverage: motion/timings (T7, T9), background option C (T7), layout + resize (T2, T9), info cards (T8), no-reflow rule (T3+T8), expander add-flow (T8), colors copy (T8), zoom/pan/Fit/✕ chrome (T9), arrows + cross-fade (T7, T9), Delete→Trash+Undo never-unlink (T5, T9), per-file collection editing with recluster survival (T1).
- Known adapt points: SearchBar's search-trigger mechanism (T8 tag tap), KeyCaptureView extension (T9), FolderWatcher latency after trash/undo (T9), `NamedColor.parse` is already internal (used by backdrop tint).
- Type consistency: `ViewerGeometry`/`PillRowModel`/`ViewerFileDetails`/`TrashManager.Ticket` names used consistently across tasks; `appState.tileFrames`/`viewerClosing` declared in T6/T9 where used.
