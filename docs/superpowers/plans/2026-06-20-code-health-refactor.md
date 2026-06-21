# Code-Health Refactor Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Shrink `AppState.swift` (1,404 LOC) and `SidebarView.swift` (1,373 LOC) by moving self-contained methods/types into focused files and centralizing duplicated reorder math — with zero runtime behavior change.

**Architecture:** Part A splits `AppState` along its existing extension seam (`AppState+Selection`/`AppState+Filters`) — methods move to new `@MainActor extension AppState` files; all stored state stays in core. Part B moves `SidebarView`'s already-independent row structs into a new `Views/Sidebar/` folder, then extracts the verified-mirror folder/collection reorder arithmetic into a pure, unit-tested `ReorderMath` enum while leaving all `@State`, gestures, and synchronous commits inline on the view.

**Tech Stack:** Swift 6 / SwiftUI / `xcodebuild` / XCTest (`MuseTests`). macOS 14.6+.

## Global Constraints

- **No runtime behavior change.** Every move is verbatim except documented access-level bumps and the reorder-math delegation. Method bodies are not rewritten.
- **No stored properties in extensions.** Swift forbids it — every `@Published` / `private` stored property, cancellable, token, cache, `FolderWatcher?`, and `Timer?` stays declared in the core `AppState.swift`. Only methods (and computed vars) move.
- **Reorder commit stays inline + synchronous.** `commitReorder` / `commitCollectionReorder` (synchronous order apply inside a `disablesAnimations` transaction) and the reorderable non-lazy `VStack`s are NOT moved or altered. Only the pure arithmetic is extracted.
- **Build command:** `xcodebuild -scheme Muse -destination 'platform=macOS' build`
- **Test command:** `xcodebuild -scheme Muse -destination 'platform=macOS' test`
- **Project file:** Xcode 16 uses synchronized file-system groups (objectVersion 77 / folder references). New files placed inside `Muse/Muse/...` are picked up automatically — verify the build sees them; if the project still uses explicit `PBXFileReference` membership, add each new file to the `Muse` target and each new test file to the `MuseTests` target.
- **Commit trailer (every commit):**
  ```
  Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_016Na7wmStCeHvZrpdXWipLp
  ```
- **Branch:** `feat/next-50` (already checked out).

---

## Pre-flight (do once before Task 1)

Confirm a clean green baseline so every later checkpoint is meaningful.

- [ ] **Step 1: Confirm branch + clean tree**

Run: `git -C "Muse App" status --short && git -C "Muse App" branch --show-current`
Expected: clean tree (only the committed spec), branch `feat/next-50`.

- [ ] **Step 2: Baseline build + test green**

Run: `xcodebuild -scheme Muse -destination 'platform=macOS' build` then `xcodebuild -scheme Muse -destination 'platform=macOS' test`
Expected: `** BUILD SUCCEEDED **` and `** TEST SUCCEEDED **`. If either fails, STOP — the baseline must be green before refactoring.

---

# PART A — Shrink `AppState.swift`

Each Part-A task moves a self-contained group of methods from `Muse/Muse/Models/AppState.swift` into a new extension file, then proves the build + existing tests stay green (the suite is the behavior net — no new tests, because behavior is identical).

**Mechanics for EVERY Part-A task (apply to each one):**
1. Create the new file with this exact preamble (imports copied from what the moved methods actually use — at minimum `Foundation`; add `SwiftUI`, `Combine`, `AppKit` only if the moved bodies reference them):
   ```swift
   import Foundation
   // (+ SwiftUI / Combine / AppKit as the moved methods require)

   @MainActor
   extension AppState {
       // moved methods here, verbatim
   }
   ```
2. **Cut** the listed methods from `AppState.swift` (delete from core) and **paste** them verbatim into the extension — do not edit bodies.
3. Keep each method's access level. If a moved `private func` is called from code still in another file, Swift won't see it across files; in that case drop `private` (it becomes internal — safe for this internal-by-default class). Note which methods needed this.
4. Stored properties referenced by the moved methods stay in core — do not move them.

**MARK comments:** when you cut a method that sat under a `// MARK: -` header in core, leave the header only if other core code remains under it; otherwise remove the now-empty header.

### Task A1: Extract Backup & Restore

**Files:**
- Create: `Muse/Muse/Models/AppState+Backup.swift`
- Modify: `Muse/Muse/Models/AppState.swift` (remove `// MARK: - Backup & restore` block, ~lines 709–765)

**Interfaces:**
- Produces: `AppState.exportBackup()`, `AppState.beginRestorePicker()` (unchanged signatures, now in the extension).
- Consumes (stays in core): `bookmarks`, `stars`, `reconnectModel`, `reconnectShown`, and any `@Published` they set.

- [ ] **Step 1: Create the extension file and move the methods**

Move `exportBackup()` and `beginRestorePicker()` verbatim into `AppState+Backup.swift` using the preamble above. These bodies use `NSSavePanel`/`NSOpenPanel` (AppKit), `BackupBuilder`, `BackupDocument`, `DateFormatter`, `Bundle` → imports: `Foundation`, `AppKit`. Delete both from `AppState.swift`.

- [ ] **Step 2: Build**

Run: `xcodebuild -scheme Muse -destination 'platform=macOS' build`
Expected: `** BUILD SUCCEEDED **`. If "cannot find X in scope" appears, the moved method referenced a `private` core member — make that member internal (drop `private`) and rebuild.

- [ ] **Step 3: Test**

Run: `xcodebuild -scheme Muse -destination 'platform=macOS' test`
Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 4: Commit**

```bash
git -C "Muse App" add Muse/Muse/Models/AppState.swift Muse/Muse/Models/AppState+Backup.swift Muse/Muse.xcodeproj/project.pbxproj
git -C "Muse App" commit -m "refactor(appstate): extract backup/restore into AppState+Backup"
```
(Include `project.pbxproj` only if the project required explicit target membership; harmless to add if unchanged. Use the global commit trailer.)

### Task A2: Extract Folder Operations

**Files:**
- Create: `Muse/Muse/Models/AppState+FolderOps.swift`
- Modify: `Muse/Muse/Models/AppState.swift` (remove `// MARK: - Folder management` block, ~lines 976–1088)

**Interfaces:**
- Produces: `createSubfolder(named:in:)`, `renameFolder(_:to:)`, `migratePaths(old:new:...)` (static), `findNode(withURL:)`, `requestNewSubfolder(_:)`, `requestRenameFolder(_:)`.
- Consumes (core): `selectedFolder`, `rootNodes`, `folderNameDraft`, `folderOpError`, `newSubfolderRequest`, `folderRenameRequest`, `Database.shared`, `Indexer.shared`, `FolderOps`, `FolderRenameMigration`.

- [ ] **Step 1: Move the methods**

Move `createSubfolder`, `renameFolder`, the `private static func migratePaths` (the `renameFolder` body calls `Self.migratePaths`), `findNode`, `requestNewSubfolder`, `requestRenameFolder` verbatim into `AppState+FolderOps.swift`. Imports: `Foundation` (+ `AppKit` only if a body references it). Delete them from core. `requestNewSubfolder`/`requestRenameFolder` currently sit near the top (~lines 327–337) — move those too so all folder-op methods live together.

- [ ] **Step 2: Build → Expected `** BUILD SUCCEEDED **`** (fix any cross-file `private` as in A1.)
- [ ] **Step 3: Test → Expected `** TEST SUCCEEDED **`**
- [ ] **Step 4: Commit**

```bash
git -C "Muse App" add -A
git -C "Muse App" commit -m "refactor(appstate): extract folder ops into AppState+FolderOps"
```

### Task A3: Extract Indexing & Analyze

**Files:**
- Create: `Muse/Muse/Models/AppState+Indexing.swift`
- Modify: `Muse/Muse/Models/AppState.swift` (remove `scheduleIndexing` ~870–916, `findDuplicatesInCurrentFolder` ~842, `analyzeCurrentFolder`/`analyzeSelected`/`enumerateRecursive` ~1313–1352)

**Interfaces:**
- Produces: `scheduleIndexing(for:verifyICloud:)`, `findDuplicatesInCurrentFolder()`, `analyzeCurrentFolder()`, `analyzeSelected()`, `enumerateRecursive(at:showHidden:)` (nonisolated static).
- Consumes (core): `currentFiles`, `iCloudFolderURL`, `indexingTask` (stored — stays in core), `duplicatesSheetVisible`, `Indexer.shared`, `ThumbnailCache`, `AnalyzePipeline`.

- [ ] **Step 1: Move the methods.** Keep `private var indexingTask` declared in core (stored property). Move only the listed methods. `enumerateRecursive` is `private nonisolated static` — keep `nonisolated static`, drop `private` only if referenced cross-file (it's called by `analyzeSelected`, which moves with it, so it can stay `private`). Imports: `Foundation`.
- [ ] **Step 2: Build → `** BUILD SUCCEEDED **`**
- [ ] **Step 3: Test → `** TEST SUCCEEDED **`**
- [ ] **Step 4: Commit** `refactor(appstate): extract indexing/analyze into AppState+Indexing`

### Task A4: Extract Search

**Files:**
- Create: `Muse/Muse/Models/AppState+Search.swift`
- Modify: `Muse/Muse/Models/AppState.swift` (remove `// MARK: - Search` block ~1272–1311)

**Interfaces:**
- Produces: `runSearch(_:) async`, `clearSearch()`.
- Consumes (core): `searchQuery`, `isSearchActive`, `searchAllFolders`, `currentFiles`, `selectedFolder`, `SearchService`, the visible-files memo invalidation.

- [ ] **Step 1: Move `runSearch` + `clearSearch` verbatim.** Imports: `Foundation`.
- [ ] **Step 2: Build → `** BUILD SUCCEEDED **`**
- [ ] **Step 3: Test → `** TEST SUCCEEDED **`**
- [ ] **Step 4: Commit** `refactor(appstate): extract search into AppState+Search`

### Task A5: Extract Mood

**Files:**
- Create: `Muse/Muse/Models/AppState+Mood.swift`
- Modify: `Muse/Muse/Models/AppState.swift` (remove `moodPalette` computed var + `setMood` + `updateAutoMoodTimer`, ~lines 391–424; keep the `@Published` mood state + `autoMoodTimer` stored prop in core)

**Interfaces:**
- Produces: `var moodPalette: MoodPalette` (computed), `setMood(_:)`, `updateAutoMoodTimer()`.
- Consumes (core, stays): `mood`, `customHue/Saturation/Brightness`, `autoMoodIsDay`, `autoMoodTimer` (stored `Timer?`).

- [ ] **Step 1: Move the computed `moodPalette` var and the two methods.** Leave all `@Published`/stored mood state in core. Imports: `Foundation`, `SwiftUI` (for `Color`/`MoodPalette`).
- [ ] **Step 2: Build → `** BUILD SUCCEEDED **`**
- [ ] **Step 3: Test → `** TEST SUCCEEDED **`**
- [ ] **Step 4: Commit** `refactor(appstate): extract mood into AppState+Mood`

### Task A6: Extract Watcher

**Files:**
- Create: `Muse/Muse/Models/AppState+Watcher.swift`
- Modify: `Muse/Muse/Models/AppState.swift` (remove `// MARK: - Watcher` methods `startWatching` ~1361 + `handleFolderEvent` ~1378; keep `private var watcher: FolderWatcher?` in core)

**Interfaces:**
- Produces: `startWatching(_:)`, `handleFolderEvent(changedPaths:)`.
- Consumes (core, stays): `watcher` (stored), `currentFiles`, `markContentChanged`, `contentVersion`, `reloadCurrentFiles`.

- [ ] **Step 1: Move both methods.** If `handleFolderEvent` calls a `private` core method (e.g. `markContentChanged`, `reloadCurrentFiles`), drop `private` on that core method so it's visible cross-file. Note which. Imports: `Foundation`.
- [ ] **Step 2: Build → `** BUILD SUCCEEDED **`**
- [ ] **Step 3: Test → `** TEST SUCCEEDED **`**
- [ ] **Step 4: Commit** `refactor(appstate): extract watcher into AppState+Watcher`

### Task A7: Extract Tag-Chips + Starring

**Files:**
- Create: `Muse/Muse/Models/AppState+TagChips.swift`
- Create: `Muse/Muse/Models/AppState+Starring.swift`
- Modify: `Muse/Muse/Models/AppState.swift` (remove `reloadTagChips` ~1231 + `bumpTagChipToken` ~1260; remove `toggleStar` ~920 + `openStarred` ~935; keep `startedStarredScopes` + `tagChipToken` stored props in core)

**Interfaces:**
- Produces: `reloadTagChips(sortModeOverride:)`, `bumpTagChipToken()` (TagChips); `toggleStar(folder:)`, `openStarred(_:)` (Starring).
- Consumes (core, stays): `tagChipRows`, `tagChipToken` (stored), `tagSourceFiles`, `stars`, `startedStarredScopes` (stored), `TagChipLoader`.

- [ ] **Step 1: Move tag-chip methods into `AppState+TagChips.swift`.** `bumpTagChipToken` is `private` and only used by tag-chip code that moves with it → can stay `private`. Imports: `Foundation`.
- [ ] **Step 2: Move starring methods into `AppState+Starring.swift`.** Keep `private var startedStarredScopes` in core; drop `private` only if `openStarred` (which moves) is the sole user — it is, so it can stay `private` IF declared in the same file; but it's a stored property and stays in core, so it must become internal. Drop `private` on `startedStarredScopes`. Imports: `Foundation`, `AppKit` (if `openStarred` opens panels/workspace).
- [ ] **Step 3: Build → `** BUILD SUCCEEDED **`**
- [ ] **Step 4: Test → `** TEST SUCCEEDED **`**
- [ ] **Step 5: Commit** `refactor(appstate): extract tag-chips + starring extensions`

### Task A8: Part-A verification gate

- [ ] **Step 1: Confirm core file shrank**

Run: `wc -l Muse App/Muse/Muse/Models/AppState*.swift`
Expected: core `AppState.swift` now ~950–1,050 LOC; the new extension files present.

- [ ] **Step 2: Full build + test green**

Run: `xcodebuild -scheme Muse -destination 'platform=macOS' build && xcodebuild -scheme Muse -destination 'platform=macOS' test`
Expected: `** BUILD SUCCEEDED **` + `** TEST SUCCEEDED **`.

- [ ] **Step 3: Diff audit — no body changed**

Run: `git -C "Muse App" diff <pre-flight-commit>..HEAD -- Muse/Muse/Models/AppState.swift | grep '^[-+]' | grep -v '^[-+][-+]'` and review that removed lines reappear verbatim in the new files (only access-level keywords differ where noted). No method body logic changed.

---

# PART B — Shrink `SidebarView.swift`

### Task B1: Move sidebar row/support types into `Views/Sidebar/`

**Files:**
- Create: `Muse/Muse/Views/Sidebar/FolderTreeNode.swift`
- Create: `Muse/Muse/Views/Sidebar/CollectionSidebarRow.swift`
- Create: `Muse/Muse/Views/Sidebar/SidebarRows.swift`
- Create: `Muse/Muse/Views/Sidebar/SidebarReorderSupport.swift`
- Modify: `Muse/Muse/Views/SidebarView.swift` (remove the moved `private struct`s; promote `reorderSpace`/`rowHeight` visibility)

**Interfaces:**
- Produces (now in own files, internal visibility): `FolderTreeNode`, `CollectionSidebarRow`, `StarRow`, `AddFolderPillButton`, `AddPillButton`, `SectionHeader`, `RootFramePreference`, `CollectionFramePreference`, `SidebarReorderingKey` (+ `EnvironmentValues.sidebarReordering` accessor), `ReorderContext`.
- Consumes: `SidebarView.reorderSpace` (String), `SidebarView.rowHeight` (CGFloat) — must be reachable cross-file.

- [ ] **Step 1: Promote shared constants.** In `SidebarView.swift`, change `fileprivate static let reorderSpace` → `static let reorderSpace` and `fileprivate static let rowHeight: CGFloat = 28` → `static let rowHeight: CGFloat = 28` (line ~64, 67) so the moved types can read `SidebarView.rowHeight` / `SidebarView.reorderSpace`.

- [ ] **Step 2: Move `FolderTreeNode`** (lines ~770–1013) verbatim into `FolderTreeNode.swift`. Change `private struct FolderTreeNode` → `struct FolderTreeNode` (internal). File preamble: `import SwiftUI` (+ any others its body uses, e.g. `AppKit`). Delete from `SidebarView.swift`.

- [ ] **Step 3: Move `CollectionSidebarRow`** (lines ~1179–1330) verbatim into `CollectionSidebarRow.swift`, `private` → internal. `import SwiftUI`.

- [ ] **Step 4: Move `StarRow`, `AddFolderPillButton`, `AddPillButton`, `SectionHeader`** verbatim into `SidebarRows.swift`, each `private` → internal. `import SwiftUI`.

- [ ] **Step 5: Move `RootFramePreference`, `CollectionFramePreference`, `SidebarReorderingKey` + its `EnvironmentValues` extension, `ReorderContext`** verbatim into `SidebarReorderSupport.swift`, each `private` → internal. `import SwiftUI`.

- [ ] **Step 6: Build**

Run: `xcodebuild -scheme Muse -destination 'platform=macOS' build`
Expected: `** BUILD SUCCEEDED **`. Common fixes: a moved type referenced another still-`private` member of `SidebarView` (e.g. `cardColor`) — those are accessed only inside `SidebarView`'s own methods, not the moved types, so this should be clean. If a moved type used a `fileprivate` helper, promote that helper to internal.

- [ ] **Step 7: Test → `** TEST SUCCEEDED **`** (pure type moves; SwiftUI rendering unchanged.)

- [ ] **Step 8: Commit**

```bash
git -C "Muse App" add -A
git -C "Muse App" commit -m "refactor(sidebar): move row/support types into Views/Sidebar/"
```

### Task B2: Add the pure `ReorderMath` helper (TDD)

**Files:**
- Create: `Muse/Muse/Components/ReorderMath.swift`
- Create: `Muse/MuseTests/ReorderMathTests.swift`

**Interfaces:**
- Produces:
  - `ReorderMath.rowShift(forIndex: Int, draggedIndex: Int?, dropTarget: Int?, pitch: CGFloat) -> CGFloat`
  - `ReorderMath.slot(forY: CGFloat, orderedStartFrames: [CGRect?]) -> Int`
  - `ReorderMath.insertionLineY(dropTarget: Int?, orderedLiveFrames: [CGRect?]) -> CGFloat?`
- Consumed by: Task B3 (the `SidebarView` call sites).

The three functions are the de-duplicated form of the verified-mirror folder/collection math. Exact bodies (ported from `SidebarView`):

```swift
import CoreGraphics

/// Pure reorder arithmetic shared by the sidebar's folder and collection
/// live-drag reorders (previously duplicated as rowShift/collectionRowShift,
/// reorderSlot/collectionReorderSlot, insertionLineY/collectionInsertionLineY).
/// No SwiftUI, no state — the view owns @State + gestures and calls these.
enum ReorderMath {
    /// How far a non-dragged row at full index `i` slides to part and open a
    /// gap for the dragged row at `dropTarget` (an index among the "others").
    /// `pitch` = measured row height + inter-row spacing. 0 when no drag.
    static func rowShift(forIndex i: Int, draggedIndex: Int?,
                         dropTarget: Int?, pitch: CGFloat) -> CGFloat {
        guard let d = draggedIndex, let target = dropTarget, i != d else { return 0 }
        let removedIndex = i < d ? i : i - 1
        var shift: CGFloat = 0
        if i > d { shift -= pitch }
        if removedIndex >= target { shift += pitch }
        return shift
    }

    /// Insertion slot (0...count) for a drag at vertical position `y`, measured
    /// against the ORDERED start-frame snapshots of the "other" rows (dragged
    /// row excluded). nil frames (unmeasured rows) are skipped.
    static func slot(forY y: CGFloat, orderedStartFrames: [CGRect?]) -> Int {
        for (i, f) in orderedStartFrames.enumerated() {
            guard let f else { continue }
            if y < f.midY { return i }
        }
        return orderedStartFrames.count
    }

    /// Y of the gap at `dropTarget`, measured against the ORDERED LIVE frames of
    /// the "other" rows (which reflect the parting offsets). nil if no target or
    /// no rows. Past-end target → last row's maxY; otherwise target row's minY.
    static func insertionLineY(dropTarget: Int?, orderedLiveFrames: [CGRect?]) -> CGFloat? {
        guard let target = dropTarget else { return nil }
        guard !orderedLiveFrames.isEmpty else { return nil }
        if target >= orderedLiveFrames.count {
            return orderedLiveFrames.last.flatMap { $0?.maxY }
        }
        return orderedLiveFrames[target]?.minY
    }
}
```

- [ ] **Step 1: Write the failing tests**

Create `ReorderMathTests.swift`:

```swift
import XCTest
import CoreGraphics
@testable import Muse

final class ReorderMathTests: XCTestCase {
    // pitch used throughout
    private let pitch: CGFloat = 29  // 28 row height + 1 spacing

    // MARK: rowShift
    func testRowShiftNoDragIsZero() {
        XCTAssertEqual(ReorderMath.rowShift(forIndex: 2, draggedIndex: nil, dropTarget: nil, pitch: pitch), 0)
    }
    func testRowShiftDraggedRowItselfIsZero() {
        XCTAssertEqual(ReorderMath.rowShift(forIndex: 1, draggedIndex: 1, dropTarget: 3, pitch: pitch), 0)
    }
    func testRowShiftRowBelowDraggedRisesToCloseHole() {
        // i=3 > d=1, removedIndex=2; target=2 → removedIndex>=target adds pitch,
        // i>d subtracts pitch → net 0 (stays put when target is its own slot)
        XCTAssertEqual(ReorderMath.rowShift(forIndex: 3, draggedIndex: 1, dropTarget: 2, pitch: pitch), 0)
    }
    func testRowShiftRowBelowDraggedWithEarlyTargetRises() {
        // i=3 > d=1 → -pitch; removedIndex=2, target=3 → 2>=3 false → net -pitch
        XCTAssertEqual(ReorderMath.rowShift(forIndex: 3, draggedIndex: 1, dropTarget: 3, pitch: pitch), -pitch)
    }
    func testRowShiftRowAboveDraggedAtTargetSinks() {
        // i=0 < d=2 → no -pitch; removedIndex=0, target=0 → 0>=0 → +pitch
        XCTAssertEqual(ReorderMath.rowShift(forIndex: 0, draggedIndex: 2, dropTarget: 0, pitch: pitch), pitch)
    }

    // MARK: slot
    func testSlotAboveFirstReturnsZero() {
        let frames: [CGRect?] = [CGRect(x: 0, y: 0, width: 100, height: 28),
                                 CGRect(x: 0, y: 29, width: 100, height: 28)]
        XCTAssertEqual(ReorderMath.slot(forY: 5, orderedStartFrames: frames), 0)
    }
    func testSlotBetweenRows() {
        let frames: [CGRect?] = [CGRect(x: 0, y: 0, width: 100, height: 28),
                                 CGRect(x: 0, y: 29, width: 100, height: 28)]
        // y=35 < second.midY(29+14=43) but not < first.midY(14) → slot 1
        XCTAssertEqual(ReorderMath.slot(forY: 35, orderedStartFrames: frames), 1)
    }
    func testSlotPastLastReturnsCount() {
        let frames: [CGRect?] = [CGRect(x: 0, y: 0, width: 100, height: 28),
                                 CGRect(x: 0, y: 29, width: 100, height: 28)]
        XCTAssertEqual(ReorderMath.slot(forY: 500, orderedStartFrames: frames), 2)
    }
    func testSlotSkipsNilFrames() {
        let frames: [CGRect?] = [nil, CGRect(x: 0, y: 29, width: 100, height: 28)]
        XCTAssertEqual(ReorderMath.slot(forY: 5, orderedStartFrames: frames), 1)
    }

    // MARK: insertionLineY
    func testInsertionLineNoTargetIsNil() {
        XCTAssertNil(ReorderMath.insertionLineY(dropTarget: nil, orderedLiveFrames: [CGRect(x: 0, y: 0, width: 1, height: 28)]))
    }
    func testInsertionLineEmptyIsNil() {
        XCTAssertNil(ReorderMath.insertionLineY(dropTarget: 0, orderedLiveFrames: []))
    }
    func testInsertionLinePastEndUsesLastMaxY() {
        let frames: [CGRect?] = [CGRect(x: 0, y: 0, width: 100, height: 28),
                                 CGRect(x: 0, y: 29, width: 100, height: 28)]
        XCTAssertEqual(ReorderMath.insertionLineY(dropTarget: 2, orderedLiveFrames: frames), 57)  // 29+28
    }
    func testInsertionLineMidUsesTargetMinY() {
        let frames: [CGRect?] = [CGRect(x: 0, y: 0, width: 100, height: 28),
                                 CGRect(x: 0, y: 29, width: 100, height: 28)]
        XCTAssertEqual(ReorderMath.insertionLineY(dropTarget: 1, orderedLiveFrames: frames), 29)
    }
}
```

- [ ] **Step 2: Run tests to verify they FAIL**

Run: `xcodebuild -scheme Muse -destination 'platform=macOS' test -only-testing:MuseTests/ReorderMathTests`
Expected: FAIL — "cannot find 'ReorderMath' in scope" (helper not created yet).

- [ ] **Step 3: Create `ReorderMath.swift`** with the exact body shown in the Interfaces block above.

- [ ] **Step 4: Run tests to verify they PASS**

Run: `xcodebuild -scheme Muse -destination 'platform=macOS' test -only-testing:MuseTests/ReorderMathTests`
Expected: PASS (12 tests).

- [ ] **Step 5: Commit**

```bash
git -C "Muse App" add Muse/Muse/Components/ReorderMath.swift Muse/MuseTests/ReorderMathTests.swift Muse/Muse.xcodeproj/project.pbxproj
git -C "Muse App" commit -m "feat(sidebar): add pure ReorderMath helper with tests"
```

### Task B3: Route `SidebarView` reorder math through `ReorderMath`

**Files:**
- Modify: `Muse/Muse/Views/SidebarView.swift` (folder math ~lines 612–693 + collection math ~lines 337–365)

**Interfaces:**
- Consumes: `ReorderMath.rowShift/slot/insertionLineY` (Task B2).
- Behavior: identical output to the current private methods.

Replace each private math method's body with a thin call to `ReorderMath`, gathering the per-path inputs. Keep the method names/signatures so all call sites (`rowShift(forIndex:)`, `reorderSlot(forY:)`, `insertionLineY()`, and the three `collection*` twins) are untouched.

- [ ] **Step 1: Rewrite the folder math methods** in `SidebarView.swift`:

```swift
    private func rowShift(forIndex i: Int) -> CGFloat {
        let pitch = (draggingRoot.flatMap { dragStartFrames[$0.id]?.height } ?? Self.rowHeight) + 1
        return ReorderMath.rowShift(forIndex: i, draggedIndex: draggedIndex,
                                    dropTarget: dropTarget, pitch: pitch)
    }

    private func reorderSlot(forY y: CGFloat) -> Int {
        ReorderMath.slot(forY: y,
                         orderedStartFrames: otherReorderRoots.map { dragStartFrames[$0.id] })
    }

    private func insertionLineY() -> CGFloat? {
        ReorderMath.insertionLineY(dropTarget: dropTarget,
                                   orderedLiveFrames: otherReorderRoots.map { rootFrames[$0.id] })
    }
```

- [ ] **Step 2: Rewrite the collection math methods** in `SidebarView.swift`:

```swift
    private func collectionRowShift(forIndex i: Int) -> CGFloat {
        let pitch = (draggingCollectionID.flatMap { collectionDragStartFrames[$0]?.height } ?? Self.rowHeight) + 1
        return ReorderMath.rowShift(forIndex: i, draggedIndex: draggedCollectionIndex,
                                    dropTarget: collectionDropTarget, pitch: pitch)
    }

    private func collectionReorderSlot(forY y: CGFloat) -> Int {
        ReorderMath.slot(forY: y,
                         orderedStartFrames: otherCollectionIDs.map { collectionDragStartFrames[$0] })
    }

    private func collectionInsertionLineY() -> CGFloat? {
        ReorderMath.insertionLineY(dropTarget: collectionDropTarget,
                                   orderedLiveFrames: otherCollectionIDs.map { collectionFrames[$0] })
    }
```

Leave `commitReorder`, `commitCollectionReorder`, `resetDrag`, `resetCollectionDrag`, the overlays, `draggedIndex`, `draggedCollectionIndex`, `otherReorderRoots`, `otherCollectionIDs`, and all `@State` exactly as they are.

- [ ] **Step 3: Build → `** BUILD SUCCEEDED **`**
- [ ] **Step 4: Test → `** TEST SUCCEEDED **`** (full suite incl. `ReorderMathTests`).
- [ ] **Step 5: Commit**

```bash
git -C "Muse App" add Muse/Muse/Views/SidebarView.swift
git -C "Muse App" commit -m "refactor(sidebar): route folder + collection reorder math through ReorderMath"
```

### Task B4: Part-B verification gate (incl. manual GUI)

- [ ] **Step 1: Confirm file shrank**

Run: `wc -l "Muse App/Muse/Muse/Views/SidebarView.swift"`
Expected: well under 1,000 LOC.

- [ ] **Step 2: Full build + test green**

Run: `xcodebuild -scheme Muse -destination 'platform=macOS' build && xcodebuild -scheme Muse -destination 'platform=macOS' test`
Expected: `** BUILD SUCCEEDED **` + `** TEST SUCCEEDED **`.

- [ ] **Step 3: MANUAL GUI verification (required — no automated net for drag wiring).**

Build & run the app. With **Manual** folder sort:
- Drag a top-level folder up one slot — parting + insertion line track the cursor; drop lands in place with no snap-back/flash.
- Drag down one slot; drag to the very top; drag to the very bottom; overshoot past the last row.
Then enable **Show Collections in the Sidebar**, set the collections section to **Manual**, and repeat the same five drags on a collection row.
Expected: identical feel to before the refactor. If anything snaps a frame late or the insertion line is misplaced, STOP and review B3 (the synchronous commit / frame inputs).

- [ ] **Step 4: Final diff audit**

Run: `git -C "Muse App" diff <pre-flight-commit>..HEAD --stat`
Confirm only expected files changed; spot-check that moved bodies are verbatim and the math delegation matches the spec.

---

## Self-Review (completed during authoring)

- **Spec coverage:** Part A tasks A1–A7 cover all eight extension files named in the spec table (backup, folder-ops, indexing, search, mood, watcher, tag-chips, starring). Part B: B1 covers the four `Views/Sidebar/` files; B2 creates `ReorderMath` + tests; B3 routes both reorder paths through it; B4 is the manual-GUI gate the spec requires. All spec verification checkpoints map to A8/B4.
- **Placeholder scan:** no TBD/TODO; every code step shows full code; commit messages are concrete.
- **Type consistency:** `ReorderMath.rowShift/slot/insertionLineY` signatures are identical in B2 (definition + tests) and B3 (call sites). `orderedStartFrames` / `orderedLiveFrames` / `pitch` / `draggedIndex` / `dropTarget` parameter names match across definition and both call sites.
- **Constraint:** stored-property-stays-in-core rule is restated per task; synchronous-commit-stays-inline restated in Global Constraints + B3 Step 2.

## Notes for the executor

- The `<pre-flight-commit>` placeholder in audit steps = the spec commit hash (run `git -C "Muse App" rev-parse HEAD` at pre-flight and substitute).
- If `xcodebuild` test runs are slow, the per-task gate may run build-only and defer the full `test` to the A8/B4 gates — but A-tasks that touch behavior-adjacent code should still run the suite. When in doubt, run tests.
- Xcode project membership: if a new `.swift` file builds without editing `project.pbxproj`, the project uses synchronized groups — don't fight it. If you get "no such file" / the file isn't compiled, add it to the `Muse` (or `MuseTests`) target in Xcode or via the pbxproj.
