# Folders as Grid Cards Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Show a folder's immediate subfolders as grid cards (and count them) so Muse matches Finder, with double-click navigating into a subfolder and the sidebar following.

**Architecture:** The non-recursive folder read emits subfolders as `.folder` `FileNode`s (reusing the existing non-image file-card rendering for the native folder icon + caption + mood-contrast); a pure helper orders folders first; the immediate `FolderStat` count includes folders; `GridView` double-click on a `.folder` tile calls a new `AppState.openSubfolder(url:)` that navigates + expands/highlights the sidebar (highlight matched by URL); folders are filtered out of file-only selection actions.

**Tech Stack:** Swift, SwiftUI, AppKit, FileManager, XCTest.

## Global Constraints

- Folder cards appear ONLY in the non-recursive (subfolders-toggle OFF) folder-browse view. The recursive read (`enumerateRecursive`) stays files-only; search results and collection members are files by construction.
- Folder tiles reuse the EXISTING non-image file-card rendering in `GridView` unchanged — `.folder` already maps to the native folder icon (QuickLook `.all`) / `"folder"` SF-symbol fallback. Do NOT write a new tile view.
- Selection mechanics for a folder tile are identical to a file (single-click selects via `applyClick`); only the OPEN gesture differs: double-click on a `.folder` navigates (does NOT set `selectedFile`).
- Folders are excluded from Add to Collection / Add Tag / Share / New-Collection-from-Selection. Reveal in Finder still works. No drag-to-move for folder tiles (v1).
- Sidebar cross-folder highlight suppression is preserved (Collections page / inside a collection / All-scope search hide the highlight).
- Pure logic is unit-tested; SwiftUI views + navigation are build- + manually-verified (project convention).
- Build: `xcodebuild -scheme Muse build`. Tests: `xcodebuild -scheme Muse test -only-testing:MuseTests/<Class>` (add `-destination 'platform=macOS'` if a destination is required; run from `Muse/` or pass `-project Muse/Muse.xcodeproj`). Full unit suite: `-only-testing:MuseTests`.
- SourceKit "Cannot find type … in scope" / "No such module" editor diagnostics are known noise; only `xcodebuild` failures count.
- No new compiler warnings in the touched files (the codebase has pre-existing Swift-6 concurrency warnings elsewhere — out of scope).

---

## File Structure

- **Create** `Muse/Muse/Models/FolderOrdering.swift` — pure folders-first ordering.
- **Create** `Muse/MuseTests/FolderOrderingTests.swift` — tests for the above.
- **Modify** `Muse/Muse/Filesystem/FolderStat.swift` — immediate count includes folders.
- **Modify** `Muse/MuseTests/` — add `FolderStatCountTests.swift` (temp-dir fixture).
- **Modify** `Muse/Muse/Filesystem/FolderTree.swift` — `FolderReader.files(includeFolders:)`.
- **Modify** `Muse/Muse/Models/AppState.swift` — non-recursive read passes `includeFolders: true`; apply `FolderOrdering.foldersFirst`; new `openSubfolder(_:)`; extend `findNode` to load along the path.
- **Modify** `Muse/Muse/Views/GridView.swift` — `handleTileTap` folder branch; omit `.onDrag` payload for folders.
- **Modify** `Muse/Muse/Views/SidebarView.swift` — `isSelected` matches by URL.
- **Modify** `Muse/Muse/Views/SelectionMenu.swift` + `Muse/Muse/Models/AppState+Filters.swift` — exclude folders from file-only actions.

---

## Task 1: Pure folders-first ordering

**Files:**
- Create: `Muse/Muse/Models/FolderOrdering.swift`
- Test: `Muse/MuseTests/FolderOrderingTests.swift`

**Interfaces:**
- Consumes: `FileNode` (existing; has `var kind: AssetKind` and `init(url:kind:)`), `AssetKind` (existing).
- Produces: `enum FolderOrdering { static func foldersFirst(_ nodes: [FileNode]) -> [FileNode] }`

- [ ] **Step 1: Write the failing test**

Create `Muse/MuseTests/FolderOrderingTests.swift`:

```swift
import XCTest
@testable import Muse

final class FolderOrderingTests: XCTestCase {
    private func node(_ name: String, _ kind: AssetKind) -> FileNode {
        FileNode(url: URL(fileURLWithPath: "/tmp/\(name)"), kind: kind)
    }

    func testFoldersComeFirstPreservingOrder() {
        let input = [node("a.jpg", .image), node("F1", .folder),
                     node("b.pdf", .pdf), node("F2", .folder)]
        let out = FolderOrdering.foldersFirst(input)
        XCTAssertEqual(out.map { $0.url.lastPathComponent },
                       ["F1", "F2", "a.jpg", "b.pdf"])
    }

    func testStableWithinEachGroup() {
        // Folders keep their incoming relative order; so do files.
        let input = [node("F2", .folder), node("z.jpg", .image),
                     node("F1", .folder), node("a.jpg", .image)]
        let out = FolderOrdering.foldersFirst(input)
        XCTAssertEqual(out.map { $0.url.lastPathComponent },
                       ["F2", "F1", "z.jpg", "a.jpg"])
    }

    func testAllFilesUnchanged() {
        let input = [node("a.jpg", .image), node("b.pdf", .pdf)]
        XCTAssertEqual(FolderOrdering.foldersFirst(input).map { $0.url.lastPathComponent },
                       ["a.jpg", "b.pdf"])
    }

    func testAllFolders() {
        let input = [node("F1", .folder), node("F2", .folder)]
        XCTAssertEqual(FolderOrdering.foldersFirst(input).map { $0.url.lastPathComponent },
                       ["F1", "F2"])
    }

    func testEmpty() {
        XCTAssertTrue(FolderOrdering.foldersFirst([]).isEmpty)
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `xcodebuild -scheme Muse test -only-testing:MuseTests/FolderOrderingTests`
Expected: FAIL — `Cannot find 'FolderOrdering' in scope`.

- [ ] **Step 3: Write the implementation**

Create `Muse/Muse/Models/FolderOrdering.swift`:

```swift
//
//  FolderOrdering.swift
//  Muse
//
//  Pure helper: order folder tiles before file tiles in the grid (Finder
//  pattern). The caller passes an already-sorted list (SmartSorter), so this
//  stable-partition keeps each group in the active sort order. A no-op when
//  there are no folders (e.g. the recursive view).
//

import Foundation

nonisolated enum FolderOrdering {
    static func foldersFirst(_ nodes: [FileNode]) -> [FileNode] {
        var folders: [FileNode] = []
        var files: [FileNode] = []
        folders.reserveCapacity(nodes.count)
        files.reserveCapacity(nodes.count)
        for n in nodes {
            if n.kind == .folder { folders.append(n) } else { files.append(n) }
        }
        return folders + files
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `xcodebuild -scheme Muse test -only-testing:MuseTests/FolderOrderingTests`
Expected: PASS (5 tests).

- [ ] **Step 5: Commit**

```bash
git add Muse/Muse/Models/FolderOrdering.swift Muse/MuseTests/FolderOrderingTests.swift
git commit -m "feat: FolderOrdering.foldersFirst pure helper + tests"
```

---

## Task 2: FolderStat immediate count includes folders

**Files:**
- Modify: `Muse/Muse/Filesystem/FolderStat.swift`
- Test: `Muse/MuseTests/FolderStatCountTests.swift`

**Interfaces:**
- Consumes: `FolderStats.compute(folder:showHidden:) -> FolderStat` (existing).
- Produces: same signature; `immediateFileCount` now counts files + immediate subfolders; `recursiveFileCount` unchanged (files only).

- [ ] **Step 1: Write the failing test**

Create `Muse/MuseTests/FolderStatCountTests.swift`:

```swift
import XCTest
@testable import Muse

final class FolderStatCountTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("muse-statcount-\(UUID().uuidString)")
        let fm = FileManager.default
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        // 3 immediate files
        for n in ["a.jpg", "b.pdf", "c.txt"] {
            try Data("x".utf8).write(to: dir.appendingPathComponent(n))
        }
        // 2 immediate subfolders, each with 1 file inside
        for f in ["Sub1", "Sub2"] {
            let sub = dir.appendingPathComponent(f)
            try fm.createDirectory(at: sub, withIntermediateDirectories: true)
            try Data("y".utf8).write(to: sub.appendingPathComponent("inside.jpg"))
        }
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    func testImmediateCountIncludesSubfolders() {
        let stat = FolderStats.compute(folder: dir)
        // 3 files + 2 subfolders = 5
        XCTAssertEqual(stat.immediateFileCount, 5)
    }

    func testRecursiveCountIsFilesOnly() {
        let stat = FolderStats.compute(folder: dir)
        // 3 immediate files + 2 files inside subfolders = 5 files; folders not counted
        XCTAssertEqual(stat.recursiveFileCount, 5)
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `xcodebuild -scheme Muse test -only-testing:MuseTests/FolderStatCountTests`
Expected: FAIL — `testImmediateCountIncludesSubfolders` expects 5, gets 3 (current code excludes the 2 subfolders).

- [ ] **Step 3: Modify the implementation**

In `Muse/Muse/Filesystem/FolderStat.swift`, replace the immediate-count block:

```swift
        var immediate = 0
        if let entries = try? fm.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey],
            options: opts
        ) {
            for url in entries where !isPlainDirectory(url) { immediate += 1 }
        }
```

with (count EVERY non-hidden immediate entry — files, packages, AND folders — so the toggle-OFF sidebar count matches the grid, which now shows folder tiles):

```swift
        // Every non-hidden immediate entry counts: files, packages, AND plain
        // subfolders (the grid shows folder cards in the one-level view, so the
        // count must include them to match — and Finder). The recursive tally
        // below stays files-only, matching the recursive grid (no folder tiles).
        var immediate = 0
        if let entries = try? fm.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: nil,
            options: opts
        ) {
            immediate = entries.count
        }
```

Then delete the now-unused `isPlainDirectory` helper (search the file for `private static func isPlainDirectory` and remove that function — the recursive loop uses its own inline `isDir`/`isPackage` check and does not call it). Update the type doc comment at the top of the file: change "Counts mirror the grid's file notion (every non-folder entry; …)" to note the immediate count includes immediate subfolders (matching the one-level grid), while the recursive count stays files-only.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `xcodebuild -scheme Muse test -only-testing:MuseTests/FolderStatCountTests`
Expected: PASS (both). Also run the existing stat tests if any reference `FolderStats` to confirm no regression: `xcodebuild -scheme Muse test -only-testing:MuseTests` (green).

- [ ] **Step 5: Commit**

```bash
git add Muse/Muse/Filesystem/FolderStat.swift Muse/MuseTests/FolderStatCountTests.swift
git commit -m "feat: FolderStat immediate count includes subfolders (match grid + Finder)"
```

---

## Task 3: FolderReader emits subfolders as `.folder` nodes

**Files:**
- Modify: `Muse/Muse/Filesystem/FolderTree.swift`
- Test: `Muse/MuseTests/FolderReaderFoldersTests.swift`

**Interfaces:**
- Consumes: `FileNode(url:kind:)`, `AssetKind` (existing).
- Produces: `FolderReader.files(in:showHidden:includeFolders:) -> [FileNode]` — new `includeFolders` param (default `false`).

- [ ] **Step 1: Write the failing test**

Create `Muse/MuseTests/FolderReaderFoldersTests.swift`:

```swift
import XCTest
@testable import Muse

final class FolderReaderFoldersTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("muse-reader-\(UUID().uuidString)")
        let fm = FileManager.default
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: dir.appendingPathComponent("a.jpg"))
        try fm.createDirectory(at: dir.appendingPathComponent("Sub"),
                               withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    func testExcludesFoldersByDefault() {
        let nodes = FolderReader.files(in: dir)
        XCTAssertEqual(nodes.map { $0.url.lastPathComponent }, ["a.jpg"])
    }

    func testIncludesFoldersWhenRequested() {
        let nodes = FolderReader.files(in: dir, includeFolders: true)
        let names = Set(nodes.map { $0.url.lastPathComponent })
        XCTAssertEqual(names, ["a.jpg", "Sub"])
        let sub = nodes.first { $0.url.lastPathComponent == "Sub" }
        XCTAssertEqual(sub?.kind, .folder)
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `xcodebuild -scheme Muse test -only-testing:MuseTests/FolderReaderFoldersTests`
Expected: FAIL — `testIncludesFoldersWhenRequested` fails to compile (`includeFolders` arg doesn't exist).

- [ ] **Step 3: Modify the implementation**

In `Muse/Muse/Filesystem/FolderTree.swift`, change `FolderReader.files` signature and the directory branch. Replace:

```swift
    static func files(in url: URL, showHidden: Bool = false) -> [FileNode] {
```
with:
```swift
    static func files(in url: URL, showHidden: Bool = false,
                      includeFolders: Bool = false) -> [FileNode] {
```

And replace the compactMap body's directory guard:

```swift
            // Skip plain directories; treat packages (like .app) as files.
            if isDir && !isPackage { return nil }
            // We already know this is a file/package, so classify directly and
            // skip AssetKind.detect's redundant fileExists stat.
            return FileNode(url: url, kind: AssetKind.classify(url: url, fallback: .unknown))
```
with:
```swift
            // Plain directories: emit as a folder tile when asked (the one-level
            // grid), else skip. Packages (like .app) always count as files.
            if isDir && !isPackage {
                return includeFolders ? FileNode(url: url, kind: .folder) : nil
            }
            // We already know this is a file/package, so classify directly and
            // skip AssetKind.detect's redundant fileExists stat.
            return FileNode(url: url, kind: AssetKind.classify(url: url, fallback: .unknown))
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `xcodebuild -scheme Muse test -only-testing:MuseTests/FolderReaderFoldersTests`
Expected: PASS (both).

- [ ] **Step 5: Commit**

```bash
git add Muse/Muse/Filesystem/FolderTree.swift Muse/MuseTests/FolderReaderFoldersTests.swift
git commit -m "feat: FolderReader can emit subfolders as .folder nodes (includeFolders)"
```

---

## Task 4: Wire folder tiles into the grid load

**Files:**
- Modify: `Muse/Muse/Models/AppState.swift:1069-1080`

**Interfaces:**
- Consumes: `FolderReader.files(in:showHidden:includeFolders:)` (Task 3), `FolderOrdering.foldersFirst(_:)` (Task 1), `SmartSorter.apply` (existing).
- Produces: `currentFiles` (folder-browse) now contains immediate subfolders as `.folder` nodes, ordered folders-first, in the non-recursive view.

> No new unit test (view-model wiring over already-tested pure pieces). Verified by build + Task 6's manual checks.

- [ ] **Step 1: Pass `includeFolders` in the non-recursive read**

In `reloadCurrentFiles`, change:
```swift
            let raw = showSub
                ? Self.enumerateRecursive(at: folderURL, showHidden: showHid)
                : FolderReader.files(in: folderURL, showHidden: showHid)
```
to:
```swift
            let raw = showSub
                ? Self.enumerateRecursive(at: folderURL, showHidden: showHid)
                : FolderReader.files(in: folderURL, showHidden: showHid, includeFolders: true)
```

- [ ] **Step 2: Order folders first after the sort**

Change:
```swift
            let sorted = SmartSorter.apply(mode, to: merged, reversed: reversed)
```
to:
```swift
            // Folders first (Finder pattern), each group in the active sort order.
            // No-op in the recursive view (no folder nodes there).
            let sorted = FolderOrdering.foldersFirst(
                SmartSorter.apply(mode, to: merged, reversed: reversed))
```

> Note: the `reconciledDead` block below uses `raw` (the present set) to mark externally-deleted files. Subfolders now appear in `raw` as `.folder` nodes with valid paths, so they're counted as "present" and won't be marked dead — correct (they're real on disk). No change needed there.

- [ ] **Step 3: Also order folders-first in the in-place re-sort path**

`AppState.swift:1188` re-sorts `currentFiles` after a sort-mode change without re-reading. Keep folders-first there too. Change:
```swift
        currentFiles = SmartSorter.apply(sortMode, to: currentFiles, reversed: sortReversed)
```
to:
```swift
        currentFiles = FolderOrdering.foldersFirst(
            SmartSorter.apply(sortMode, to: currentFiles, reversed: sortReversed))
```
(Leave the `activeCollectionFiles` re-sort on the next line unchanged — collections never contain folders.)

- [ ] **Step 4: Build**

Run: `xcodebuild -scheme Muse build`
Expected: `** BUILD SUCCEEDED **`, no new warnings in `AppState.swift`.

- [ ] **Step 5: Run the full unit suite (no regression)**

Run: `xcodebuild -scheme Muse test -only-testing:MuseTests`
Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 6: Commit**

```bash
git add Muse/Muse/Models/AppState.swift
git commit -m "feat: include subfolders (folders-first) in the one-level grid load"
```

---

## Task 5: Navigate into a folder tile + sidebar follows

**Files:**
- Modify: `Muse/Muse/Models/AppState.swift` (new `openSubfolder`, extend `findNode`)
- Modify: `Muse/Muse/Views/GridView.swift` (`handleTileTap` folder branch; folder `.onDrag` no-op)
- Modify: `Muse/Muse/Views/SidebarView.swift` (`isSelected` by URL)

**Interfaces:**
- Consumes: `AppState.select(folder: FolderNode)` (existing), `FolderNode` (existing; `init(url:)`, `loadChildrenIfNeeded(showHidden:)`, `@Published var isExpanded`, `var children`, `var url`), `appState.showHidden` (existing).
- Produces: `AppState.openSubfolder(_ url: URL)`.

> No new unit test (navigation + SwiftUI). Verified by build + the manual checklist in Step 6.

- [ ] **Step 1: Add `openSubfolder` and extend `findNode` to load along the path**

In `Muse/Muse/Models/AppState.swift`, add this method (place it right after `select(folder:)`, ending near line 767):

```swift
    /// Navigate into a subfolder chosen from a grid folder card: expand the
    /// sidebar tree down to it (so its row is visible), then select it exactly
    /// like a sidebar click. Highlight is URL-based (see SidebarView.isSelected),
    /// so even the FolderNode-build fallback lights up the right row.
    func openSubfolder(_ url: URL) {
        let target = url.standardizedFileURL.path
        guard let root = rootNodes.first(where: { r in
            let rp = r.url.standardizedFileURL.path
            return target == rp || target.hasPrefix(rp + "/")
        }) else { return }

        var node = root
        node.loadChildrenIfNeeded(showHidden: showHidden)
        node.isExpanded = true
        while node.url.standardizedFileURL.path != target {
            guard let next = node.children.first(where: { c in
                let cp = c.url.standardizedFileURL.path
                return target == cp || target.hasPrefix(cp + "/")
            }) else { break }
            next.loadChildrenIfNeeded(showHidden: showHidden)
            next.isExpanded = true
            node = next
        }

        if node.url.standardizedFileURL.path == target {
            select(folder: node)
        } else {
            // Path not fully resolvable in the tree (rare) — still navigate; the
            // URL-based highlight will match if the row later loads.
            select(folder: FolderNode(url: url))
        }
    }
```

(No change needed to `findNode` itself — `openSubfolder` does its own load-along-the-path walk. Leave `findNode(withURL:)` as is.)

- [ ] **Step 2: Branch the grid tap on `.folder`**

In `Muse/Muse/Views/GridView.swift`, in `handleTileTap`, change the double-click branch:
```swift
        if lastTapPath == p, now - lastTapAt < window {
            lastTapPath = nil
            appState.selectedFile = file          // double-click → open
            return
        }
```
to:
```swift
        if lastTapPath == p, now - lastTapAt < window {
            lastTapPath = nil
            if file.kind == .folder {
                appState.openSubfolder(file.url)  // double-click → navigate in
            } else {
                appState.selectedFile = file      // double-click → open viewer
            }
            return
        }
```
(The single-click selection path below is unchanged — a folder tile selects like a file.)

- [ ] **Step 3: Make folder tiles carry no drag payload (v1: not draggable to move)**

In `Muse/Muse/Views/GridView.swift`, in the tile's `.onDrag` closure (around line 260), add a guard at the top so a folder drag carries nothing:
```swift
                    .onDrag {
                        guard file.kind != .folder else { return NSItemProvider() }
                        let p = file.url.standardizedFileURL.path
                        if !appState.selectedFiles.contains(p) {
                            appState.applyClick(.single(p))
                        }
                        return NSItemProvider(object: file.url as NSURL)
                    }
```

- [ ] **Step 4: Sidebar highlight by URL**

In `Muse/Muse/Views/SidebarView.swift`, in the `isSelected` computed property, change the final line:
```swift
        return appState.selectedFolder?.id == node.id
```
to:
```swift
        return appState.selectedFolder?.url.standardizedFileURL
            == node.url.standardizedFileURL
```
(Keep the cross-folder suppression guards above it unchanged.)

- [ ] **Step 5: Build**

Run: `xcodebuild -scheme Muse build`
Expected: `** BUILD SUCCEEDED **`, no new warnings in the three files.

- [ ] **Step 6: Manual verification (run the app)**

Build & run. Open a folder that has subfolders (e.g. `~/Desktop/INSPO` has subfolders):
1. Grid shows **folder cards first**, then files; the count matches Finder.
2. Folder card shows the **native macOS folder icon** + filename caption; with the mood set to Dark/Custom the caption text stays readable (mood contrast).
3. **Single-click** a folder card → it shows the selection ring (like a file).
4. **Double-click** a folder card → the grid navigates INTO that subfolder (its contents), no back button, and the **sidebar expands + highlights** that subfolder row.
5. Turn the **subfolders toggle ON** → folder cards disappear, recursive files show (as before).
6. Confirm a normal **file** still: single-click selects, double-click opens the viewer.

- [ ] **Step 7: Commit**

```bash
git add Muse/Muse/Models/AppState.swift Muse/Muse/Views/GridView.swift Muse/Muse/Views/SidebarView.swift
git commit -m "feat: double-click a folder card to navigate in; sidebar expands + highlights"
```

---

## Task 6: Exclude folders from file-only selection actions

**Files:**
- Modify: `Muse/Muse/Views/SelectionMenu.swift`
- Modify: `Muse/Muse/Models/AppState+Filters.swift` (`requestNewCollection`)

**Interfaces:**
- Consumes: `appState.effectiveSelectionURLs(fallback:)` (existing), `appState.requestNewCollection(fallback:)` (existing).
- Produces: file-only actions operate on non-folder URLs; folders-only selection hides them.

> No new unit test (SwiftUI menu + view-model). Verified by build + manual check in Step 4.

- [ ] **Step 1: Filter folders for the file-only actions in the menu**

In `Muse/Muse/Views/SelectionMenu.swift`, add a computed property beside the existing `urls` (around line 20):
```swift
    private var urls: [URL] { appState.effectiveSelectionURLs(fallback: path) }
    /// File-only subset (folders can't be tagged / collected / shared as files).
    private var fileURLs: [URL] {
        urls.filter {
            (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory != true
        }
    }
```
Then, for the **Add to Collection**, **Add Tag**, and **Share** menu items (the ones that act on the selected files), use `fileURLs` instead of `urls`, and wrap them so they only show when `!fileURLs.isEmpty`. Concretely, gate that group:
```swift
        if !fileURLs.isEmpty {
            // … Add to Collection / Add Tag / Share items, using fileURLs …
        }
```
(Reveal in Finder and any folder-safe items stay on `urls`/`path`. Match the existing item bodies — only the URL list they consume and the surrounding `if` change.)

- [ ] **Step 2: Filter folders out of New-Collection-from-Selection**

In `Muse/Muse/Models/AppState+Filters.swift`, in `requestNewCollection(fallback:)`, the line that captures paths:
```swift
        pendingNewCollectionPaths = path.map { p in
            effectiveSelectionURLs(fallback: p).map { $0.standardizedFileURL.path }
        } ?? []
```
change to drop folder paths (a folder can't be a collection member):
```swift
        pendingNewCollectionPaths = path.map { p in
            effectiveSelectionURLs(fallback: p)
                .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory != true }
                .map { $0.standardizedFileURL.path }
        } ?? []
```
And gate the grid's "New Collection from Selection" menu item in `SelectionMenu.swift` on `!fileURLs.isEmpty` (same group as Step 1, or its own `if`).

- [ ] **Step 3: Build**

Run: `xcodebuild -scheme Muse build`
Expected: `** BUILD SUCCEEDED **`, no new warnings.

- [ ] **Step 4: Manual verification**

Build & run. In a folder showing folder cards:
1. Select a mix of files + a folder card (Cmd-click), right-click → **Add to Collection / Add Tag / Share** act on the files only (the folder is ignored).
2. Select ONLY a folder card, right-click → those file-only actions are **hidden**; **Reveal in Finder** still works.

- [ ] **Step 5: Commit**

```bash
git add Muse/Muse/Views/SelectionMenu.swift Muse/Muse/Models/AppState+Filters.swift
git commit -m "feat: exclude folder tiles from collection/tag/share/new-collection actions"
```

---

## Self-Review

**1. Spec coverage** (against `docs/superpowers/specs/2026-06-20-folders-as-grid-cards-design.md`):
- Subfolders shown as cards in one-level view → Tasks 3, 4. ✓
- Recursive view stays files-only → Task 4 (only the non-recursive branch passes `includeFolders`). ✓
- Folders-first ordering → Tasks 1, 4. ✓
- Folder card appearance (native icon, caption, mood contrast) → reuses existing rendering, no change needed (Global Constraints). ✓
- Count includes folders (immediate) / recursive files-only → Task 2. ✓
- Single-click selects, double-click navigates → Task 5 Step 2. ✓
- Sidebar auto-expand + highlight (URL-based) → Task 5 Steps 1, 4. ✓
- Folders out of collection/tag/share/new-collection; Reveal works → Task 6. ✓
- No folder drag (v1) → Task 5 Step 3. ✓
- Folders only in folder browsing (not search/collections) → inherent (search/collection sets are files; only the folder-browse read sets `includeFolders`). ✓
- Pure tests for ordering + count; rest build/manual → Tasks 1–3 tests; 4–6 build/manual. ✓

**2. Placeholder scan:** No TBD/TODO; every code step shows full before/after; commands have expected output. The only "match the existing item bodies" instruction (Task 6 Step 1) refers to concrete existing code the implementer is editing, with the exact change named (URL list + surrounding `if`). ✓

**3. Type consistency:** `FolderOrdering.foldersFirst(_:) -> [FileNode]`, `FolderReader.files(in:showHidden:includeFolders:)`, `AppState.openSubfolder(_:)`, `FileNode(url:kind:)`, `AssetKind.folder`, `FolderStats.compute(folder:)` are used identically across tasks. `FolderNode(url:)` / `loadChildrenIfNeeded(showHidden:)` / `isExpanded` / `children` match the existing API quoted in the spec exploration. ✓
