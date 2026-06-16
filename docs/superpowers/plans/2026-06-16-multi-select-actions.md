# Multi-select + Selection Actions Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add image selection to the grid (single/Cmd/Shift), a selection-aware right-click menu (add to existing collection, add existing tag, share), drag-to-move onto sidebar folders, and Reveal in Finder on sidebar folders.

**Architecture:** A pure `GridSelection` helper computes selection sets (unit-tested); `AppState` holds the selection. `GridView`'s tile gets an AppKit `TileClickCatcher` for immediate single-click selection + double-click open (avoiding the SwiftUI double-tap delay) and a selection-aware `contextMenu`. A `FileMover` moves files under security scope; sidebar folder rows accept file-URL drops. Reveal-in-Finder is a one-liner.

**Tech Stack:** Swift, SwiftUI, AppKit (NSView click handling, NSSharingServicePicker, NSWorkspace), GRDB, XCTest. macOS 14.6+.

**Spec:** `docs/superpowers/specs/2026-06-16-multi-select-actions-design.md`

**Build/test from** `/Users/carlostarrats/Documents/Projects/Muse/Muse App`:
- Build: `xcodebuild build -project "Muse/Muse.xcodeproj" -scheme Muse -destination 'platform=macOS' 2>&1 | tail -20`
- Test one suite: `xcodebuild test -project "Muse/Muse.xcodeproj" -scheme Muse -destination 'platform=macOS' -only-testing:MuseTests/<Suite> 2>&1 | tail -20`

New `.swift` files under the `Muse` group auto-join the target (synchronized group).

---

## Task 1: GridSelection pure logic + AppState state

**Files:**
- Create: `Muse/Muse/Components/GridSelection.swift`
- Test: `Muse/MuseTests/GridSelectionTests.swift`
- Modify: `Muse/Muse/Models/AppState.swift`

- [ ] **Step 1: Write the failing tests**

Create `Muse/MuseTests/GridSelectionTests.swift`:

```swift
import XCTest
@testable import Muse

final class GridSelectionTests: XCTestCase {
    let order = ["a", "b", "c", "d", "e"]   // grid order (paths)

    func testSingleReplaces() {
        let r = GridSelection.apply(.single("c"), to: ["a", "b"], anchor: nil, order: order)
        XCTAssertEqual(r.selection, ["c"])
        XCTAssertEqual(r.anchor, "c")
    }

    func testToggleAddsAndRemoves() {
        var r = GridSelection.apply(.toggle("c"), to: ["a"], anchor: "a", order: order)
        XCTAssertEqual(r.selection, ["a", "c"]); XCTAssertEqual(r.anchor, "c")
        r = GridSelection.apply(.toggle("a"), to: r.selection, anchor: r.anchor, order: order)
        XCTAssertEqual(r.selection, ["c"])
    }

    func testRangeFromAnchorInclusive() {
        let r = GridSelection.apply(.range("d"), to: ["b"], anchor: "b", order: order)
        XCTAssertEqual(r.selection, ["b", "c", "d"])   // b..d
        XCTAssertEqual(r.anchor, "b")                  // anchor unchanged by range
    }

    func testRangeBackwards() {
        let r = GridSelection.apply(.range("a"), to: ["d"], anchor: "d", order: order)
        XCTAssertEqual(r.selection, ["a", "b", "c", "d"])
    }

    func testRangeWithoutAnchorActsAsSingle() {
        let r = GridSelection.apply(.range("c"), to: [], anchor: nil, order: order)
        XCTAssertEqual(r.selection, ["c"]); XCTAssertEqual(r.anchor, "c")
    }
}
```

- [ ] **Step 2: Run tests, verify they fail**

Run: `xcodebuild test -project "Muse/Muse.xcodeproj" -scheme Muse -destination 'platform=macOS' -only-testing:MuseTests/GridSelectionTests 2>&1 | tail -20`
Expected: FAIL — `GridSelection` not found.

- [ ] **Step 3: Implement GridSelection**

Create `Muse/Muse/Components/GridSelection.swift`:

```swift
//
//  GridSelection.swift
//  Muse
//
//  Pure selection math for the grid: turn a click (single / Cmd-toggle /
//  Shift-range) plus the current selection + anchor + grid order into the new
//  selection + anchor. No UI — unit tested. Keys are standardized file paths.
//

import Foundation

enum GridSelection {
    enum Click {
        case single(String)   // plain click: select only this
        case toggle(String)   // Cmd-click: add/remove this
        case range(String)    // Shift-click: anchor…this, inclusive
    }

    struct Result { var selection: Set<String>; var anchor: String? }

    static func apply(_ click: Click, to selection: Set<String>,
                      anchor: String?, order: [String]) -> Result {
        switch click {
        case .single(let p):
            return Result(selection: [p], anchor: p)
        case .toggle(let p):
            var s = selection
            if s.contains(p) { s.remove(p) } else { s.insert(p) }
            return Result(selection: s, anchor: p)
        case .range(let p):
            guard let a = anchor,
                  let i = order.firstIndex(of: a),
                  let j = order.firstIndex(of: p) else {
                return Result(selection: [p], anchor: p)
            }
            let lo = min(i, j), hi = max(i, j)
            return Result(selection: Set(order[lo...hi]), anchor: a)
        }
    }
}
```

- [ ] **Step 4: Run tests, verify they pass**

Run: `xcodebuild test -project "Muse/Muse.xcodeproj" -scheme Muse -destination 'platform=macOS' -only-testing:MuseTests/GridSelectionTests 2>&1 | tail -20`
Expected: PASS (5 tests).

- [ ] **Step 5: Add selection state to AppState**

In `Muse/Muse/Models/AppState.swift`, near `selectedFile` (line ~50), add:

```swift
    /// Multi-selection in the grid (standardized file paths). Separate from
    /// `selectedFile`, which is the image OPEN in the hero viewer.
    @Published var selectedFiles: Set<String> = []
    /// Anchor for Shift-range selection.
    @Published var selectionAnchor: String? = nil

    /// Visible files in grid order, keyed by standardized path — the order
    /// Shift-range walks.
    var selectionOrder: [String] {
        visibleFiles.map { $0.url.standardizedFileURL.path }
    }

    func applyClick(_ click: GridSelection.Click) {
        let r = GridSelection.apply(click, to: selectedFiles,
                                    anchor: selectionAnchor, order: selectionOrder)
        selectedFiles = r.selection
        selectionAnchor = r.anchor
    }

    func clearSelection() {
        guard !selectedFiles.isEmpty || selectionAnchor != nil else { return }
        selectedFiles = []
        selectionAnchor = nil
    }

    /// URLs for the effective selection (the selection, or `[fallback]` if the
    /// fallback path isn't part of the selection).
    func effectiveSelectionURLs(fallback path: String) -> [URL] {
        let paths = selectedFiles.contains(path) ? selectedFiles : [path]
        let byPath = Dictionary(uniqueKeysWithValues:
            visibleFiles.map { ($0.url.standardizedFileURL.path, $0.url) })
        return paths.compactMap { byPath[$0] }
    }
```

- [ ] **Step 6: Clear selection on scope changes**

In `AppState.select(folder:)` (line ~513), `setActiveCollection(_:)` (line ~143), and `setActiveTag(_:)` (line ~240), add `clearSelection()` as the first line of each method body.

- [ ] **Step 7: Build, then commit**

Run: `xcodebuild build -project "Muse/Muse.xcodeproj" -scheme Muse -destination 'platform=macOS' 2>&1 | grep -E "error:|BUILD (SUCCEEDED|FAILED)"`
Expected: BUILD SUCCEEDED.

```bash
git add Muse/Muse/Components/GridSelection.swift Muse/MuseTests/GridSelectionTests.swift Muse/Muse/Models/AppState.swift
git commit -m "Add grid selection model (pure GridSelection + AppState state)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 2: Tile click handling (select / open) + highlight

**Files:**
- Create: `Muse/Muse/Views/TileClickCatcher.swift`
- Modify: `Muse/Muse/Views/GridView.swift` (the `TileView` body + its tap handling, around lines 134–172)

- [ ] **Step 1: Implement the click catcher**

Create `Muse/Muse/Views/TileClickCatcher.swift`:

```swift
//
//  TileClickCatcher.swift
//  Muse
//
//  Transparent AppKit overlay that reports left-clicks with their click count
//  and modifier flags. First click selects IMMEDIATELY (Finder-like, no
//  double-click delay); a second click within the interval opens. Right-clicks
//  are not handled here, so SwiftUI's .contextMenu still fires.
//

import SwiftUI
import AppKit

struct TileClickCatcher: NSViewRepresentable {
    var onSelect: (_ command: Bool, _ shift: Bool) -> Void
    var onOpen: () -> Void

    func makeNSView(context: Context) -> ClickView {
        let v = ClickView()
        v.onSelect = onSelect; v.onOpen = onOpen
        return v
    }
    func updateNSView(_ nsView: ClickView, context: Context) {
        nsView.onSelect = onSelect; nsView.onOpen = onOpen
    }

    final class ClickView: NSView {
        var onSelect: ((Bool, Bool) -> Void)?
        var onOpen: (() -> Void)?
        override func mouseDown(with event: NSEvent) {
            if event.clickCount >= 2 {
                onOpen?()
            } else {
                let m = event.modifierFlags
                onSelect?(m.contains(.command), m.contains(.shift))
            }
        }
        // Let right-clicks fall through to SwiftUI's context menu.
        override func rightMouseDown(with event: NSEvent) { super.rightMouseDown(with: event) }
    }
}
```

- [ ] **Step 2: Wire it into TileView, replacing the tap gesture**

In `Muse/Muse/Views/GridView.swift`, in `masonryCanvas`, the tile currently has (around line 144–150):

```swift
                    .offset(x: rect.minX, y: rect.minY)
                    .onTapGesture {
                        appState.selectedFile = file
                    }
```

Replace the `.onTapGesture { appState.selectedFile = file }` with an overlay click catcher and a selection highlight. Change the tile to:

```swift
                    .overlay {
                        if appState.selectedFiles.contains(file.url.standardizedFileURL.path) {
                            RoundedRectangle(cornerRadius: 0)
                                .strokeBorder(Color.accentColor, lineWidth: 3)
                        }
                    }
                    .overlay {
                        TileClickCatcher(
                            onSelect: { command, shift in
                                let p = file.url.standardizedFileURL.path
                                if shift { appState.applyClick(.range(p)) }
                                else if command { appState.applyClick(.toggle(p)) }
                                else { appState.applyClick(.single(p)) }
                            },
                            onOpen: { appState.selectedFile = file }
                        )
                    }
                    .offset(x: rect.minX, y: rect.minY)
```

(Keep the existing `.accessibilityElement`, `.contextMenu`, etc. that follow.)

- [ ] **Step 3: Build and run the app to verify**

Run: `xcodebuild build -project "Muse/Muse.xcodeproj" -scheme Muse -destination 'platform=macOS' 2>&1 | grep -E "error:|BUILD (SUCCEEDED|FAILED)"`
Expected: BUILD SUCCEEDED.

Launch the app (Task 6 covers full manual checks). Quick check: single click highlights one tile (accent border); Cmd-click adds/removes; Shift-click selects a range; double-click opens the hero viewer; right-click still shows the menu.

- [ ] **Step 4: Commit**

```bash
git add Muse/Muse/Views/TileClickCatcher.swift Muse/Muse/Views/GridView.swift
git commit -m "Grid tiles: click selects (single/Cmd/Shift), double-click opens

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 3: Selection-aware right-click menu (collection / tag / share)

**Files:**
- Modify: `Muse/Muse/Intelligence/Collections/CollectionStore.swift` (add a paths→file_id helper)
- Modify: `Muse/Muse/Database/TagStore.swift` (add `allLabels()`)
- Create: `Muse/Muse/Views/SelectionMenu.swift` (the submenu builders)
- Modify: `Muse/Muse/Views/GridView.swift` (the tile `.contextMenu`)

- [ ] **Step 1: Add a paths→file_id helper to CollectionStore**

In `Muse/Muse/Intelligence/Collections/CollectionStore.swift`, add (mirrors `SmartSorter`'s lookup):

```swift
    /// Resolve standardized absolute paths to their (alive) file_ids.
    static func fileIDs(queue: DatabaseQueue, paths: [String]) async throws -> [String] {
        guard !paths.isEmpty else { return [] }
        return try await queue.read { db in
            let placeholders = paths.map { _ in "?" }.joined(separator: ",")
            let rows = try PathRow.fetchAll(
                db,
                sql: "SELECT * FROM paths WHERE absolute_path IN (\(placeholders)) AND is_alive = 1",
                arguments: StatementArguments(paths))
            return rows.compactMap { $0.file_id }
        }
    }
```

- [ ] **Step 2: Add `allLabels()` to TagStore**

In `Muse/Muse/Database/TagStore.swift`, add an instance method:

```swift
    /// All distinct tag labels in use, alphabetical.
    func allLabels() async -> [String] {
        guard let q = Database.shared.dbQueue else { return [] }
        return (try? await q.read { db in
            try String.fetchAll(db, sql:
                "SELECT DISTINCT label FROM tags ORDER BY label COLLATE NOCASE")
        }) ?? []
    }
```

(If the build reports the column/table name differs, match `TagRow` in `Records.swift`.)

- [ ] **Step 3: Build the selection menu view**

Create `Muse/Muse/Views/SelectionMenu.swift`:

```swift
//
//  SelectionMenu.swift
//  Muse
//
//  The selection-aware actions shared by the grid tile's context menu:
//  add to an existing collection, add an existing tag, and share. Operates on
//  the effective selection (the selection, or just the right-clicked file).
//

import SwiftUI
import AppKit

struct SelectionActionsMenu: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject var engine = CollectionsEngine.shared
    /// Standardized path of the right-clicked tile.
    let path: String

    @State private var labels: [String] = []

    private var urls: [URL] { appState.effectiveSelectionURLs(fallback: path) }

    var body: some View {
        Menu("Add to Collection") {
            if engine.collections.isEmpty {
                Button("No collections") {}.disabled(true)
            } else {
                ForEach(engine.collections.sorted {
                    $0.collection.name.localizedCaseInsensitiveCompare($1.collection.name) == .orderedAscending
                }, id: \.collection.id) { loaded in
                    Button(loaded.collection.name) { addToCollection(loaded.collection.id) }
                }
            }
        }
        Menu("Add Tag") {
            if labels.isEmpty {
                Button("No tags") {}.disabled(true)
            } else {
                ForEach(labels, id: \.self) { label in
                    Button(label) { addTag(label) }
                }
            }
        }
        .task { labels = await TagStore.shared.allLabels() }
        Button("Share") { share() }
    }

    private func addToCollection(_ collectionID: String) {
        let paths = urls.map { $0.standardizedFileURL.path }
        Task { @MainActor in
            guard let q = Database.shared.dbQueue else { return }
            let ids = (try? await CollectionStore.fileIDs(queue: q, paths: paths)) ?? []
            for id in ids { try? await CollectionStore.addFile(queue: q, fileID: id, collectionID: collectionID) }
            await CollectionsEngine.shared.reload()
        }
    }

    private func addTag(_ label: String) {
        let targets = urls
        Task { @MainActor in
            for url in targets { _ = await TagStore.shared.addManualTag(label: label, for: url) }
            appState.tagsVersion &+= 1
        }
    }

    private func share() {
        guard let contentView = NSApp.keyWindow?.contentView, !urls.isEmpty else { return }
        let picker = NSSharingServicePicker(items: urls)
        picker.show(relativeTo: .zero, of: contentView, preferredEdge: .minY)
    }
}
```

(If `AppState` has no `tagsVersion`, drop that line — it exists per the 2026-06-13 session log for hero tag refresh; confirm with `grep -n tagsVersion Muse/Muse/Models/AppState.swift` and keep it only if present.)

- [ ] **Step 4: Insert it into the tile context menu**

In `Muse/Muse/Views/GridView.swift`, the tile `.contextMenu` currently starts with `OpenWithMenu(url: file.url)` then `Add Tag…`/cover/Trash. Update it so selection actions come first and single-only items are gated. Replace the context menu body with:

```swift
                    .contextMenu {
                        let p = file.url.standardizedFileURL.path
                        // Right-clicking an unselected tile selects just it.
                        let single = !appState.selectedFiles.contains(p) || appState.selectedFiles.count <= 1
                        SelectionActionsMenu(path: p)
                        Divider()
                        if single {
                            OpenWithMenu(url: file.url)
                            if appState.activeCollectionID != nil {
                                Button("Set as Collection Cover") {
                                    appState.setCollectionCover(file)
                                }
                            }
                        }
                        Divider()
                        Button("Move to Trash", role: .destructive) {
                            let targets = appState.effectiveSelectionURLs(fallback: p)
                            let byPath = Dictionary(uniqueKeysWithValues:
                                appState.visibleFiles.map { ($0.url.standardizedFileURL.path, $0) })
                            Task { @MainActor in
                                for url in targets {
                                    if let node = byPath[url.standardizedFileURL.path] {
                                        await appState.deletion.deleteWithBurn(node)
                                    }
                                }
                            }
                        }
                    }
```

(This drops the inline "Add Tag…" alert path for the tile — tagging now goes through the selection menu's existing-label submenu, matching the spec's add-to-existing scope. The menu-bar/TagChipsRow tag management is unaffected.)

- [ ] **Step 5: Build and commit**

Run: `xcodebuild build -project "Muse/Muse.xcodeproj" -scheme Muse -destination 'platform=macOS' 2>&1 | grep -E "error:|BUILD (SUCCEEDED|FAILED)"`
Expected: BUILD SUCCEEDED.

```bash
git add Muse/Muse/Intelligence/Collections/CollectionStore.swift Muse/Muse/Database/TagStore.swift Muse/Muse/Views/SelectionMenu.swift Muse/Muse/Views/GridView.swift
git commit -m "Selection-aware tile menu: add to collection / tag / share

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 4: Drag images → sidebar folder = move

**Files:**
- Create: `Muse/Muse/Filesystem/FileMover.swift`
- Modify: `Muse/Muse/Views/GridView.swift` (tile `.onDrag`)
- Modify: `Muse/Muse/Views/SidebarView.swift` (file-URL drop on folder rows)

- [ ] **Step 1: Implement FileMover**

Create `Muse/Muse/Filesystem/FileMover.swift`:

```swift
//
//  FileMover.swift
//  Muse
//
//  Moves user files into a destination folder under security-scoped access.
//  Requires read-write access to both source roots and the destination (the
//  app already uses read-write bookmarks). Returns the URLs that failed.
//

import Foundation
import AppKit

enum FileMover {
    /// Move `urls` into `destination`. Returns paths that could not be moved.
    @discardableResult
    static func move(_ urls: [URL], into destination: URL,
                     bookmarks: BookmarkStore) -> [URL] {
        var failed: [URL] = []
        // Gain access to the destination's owning root for the duration.
        let destAccess = bookmarks.startAccess(forURLContaining: destination)
        defer { destAccess?() }
        for url in urls {
            let target = destination.appendingPathComponent(url.lastPathComponent)
            if target.standardizedFileURL == url.standardizedFileURL { continue } // same place
            let srcAccess = bookmarks.startAccess(forURLContaining: url)
            defer { srcAccess?() }
            do {
                if FileManager.default.fileExists(atPath: target.path) {
                    failed.append(url); continue   // name collision — skip
                }
                try FileManager.default.moveItem(at: url, to: target)
            } catch {
                failed.append(url)
            }
        }
        return failed
    }
}
```

- [ ] **Step 2: Add the access helper to BookmarkStore**

In `Muse/Muse/Filesystem/BookmarkStore.swift`, add a method that finds the owning root for a URL and starts security-scoped access, returning a stop closure (mirrors however roots already start/stop access — check the file for the existing `startAccessingSecurityScopedResource` usage and follow it):

```swift
    /// Start security-scoped access on the root that contains `url`. Returns a
    /// stop closure, or nil if no owning root resolves.
    func startAccess(forURLContaining url: URL) -> (() -> Void)? {
        for root in roots {
            guard let rootURL = self.url(for: root) else { continue }
            if url.path == rootURL.path || url.path.hasPrefix(rootURL.path + "/") {
                guard rootURL.startAccessingSecurityScopedResource() else { return nil }
                return { rootURL.stopAccessingSecurityScopedResource() }
            }
        }
        return nil
    }
```

(Verify `url(for:)` and `roots` names against the file; the survey shows `appState.bookmarks.url(for:)` and `appState.bookmarks.roots` are the right names.)

- [ ] **Step 3: Make tiles draggable**

In `Muse/Muse/Views/GridView.swift`, on the tile (after the click catcher overlay, before `.contextMenu`), add:

```swift
                    .onDrag {
                        let p = file.url.standardizedFileURL.path
                        // Dragging a selected tile drags the whole selection;
                        // an unselected tile drags just itself (read at drop time
                        // via AppState — here we provide the dragged file URL).
                        if !appState.selectedFiles.contains(p) {
                            appState.applyClick(.single(p))
                        }
                        return NSItemProvider(object: file.url as NSURL)
                    }
```

- [ ] **Step 4: Add a file-move drop to sidebar folder rows**

In `Muse/Muse/Views/SidebarView.swift`, on the folder row view (the same row that has `.contextMenu`, around line 322), add a file-URL drop that moves the current selection (or the dropped URL) into `node.url`:

```swift
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            let dest = node.url
            // Move the current selection if any; otherwise the dropped URLs.
            let selectedURLs = appState.effectiveSelectionURLs(
                fallback: "")   // empty fallback → only the selection set
            if !selectedURLs.isEmpty {
                let failed = FileMover.move(selectedURLs, into: dest, bookmarks: appState.bookmarks)
                appState.reloadAfterMove(failed: failed)
                return true
            }
            // No selection — resolve the dropped file URLs and move them.
            var urls: [URL] = []
            let group = DispatchGroup()
            for p in providers {
                group.enter()
                _ = p.loadObject(ofClass: URL.self) { url, _ in
                    if let url { urls.append(url) }
                    group.leave()
                }
            }
            group.notify(queue: .main) {
                let failed = FileMover.move(urls, into: dest, bookmarks: appState.bookmarks)
                appState.reloadAfterMove(failed: failed)
            }
            return true
        }
```

- [ ] **Step 5: Add reloadAfterMove to AppState**

In `Muse/Muse/Models/AppState.swift`:

```swift
    /// After a move: clear selection, reload the current folder, and (if any
    /// failed) surface a brief alert.
    func reloadAfterMove(failed: [URL]) {
        clearSelection()
        reloadCurrentFilesPublic()
        if !failed.isEmpty {
            moveFailureNames = failed.map { $0.lastPathComponent }
        }
    }
    @Published var moveFailureNames: [String] = []
```

`reloadCurrentFiles` is private; add a thin public caller next to it:

```swift
    func reloadCurrentFilesPublic() { reloadCurrentFiles() }
```

Show the alert in `ContentView` (near the other alerts) — add:

```swift
        .alert("Couldn’t move some files",
               isPresented: Binding(get: { !appState.moveFailureNames.isEmpty },
                                    set: { if !$0 { appState.moveFailureNames = [] } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(appState.moveFailureNames.joined(separator: "\n"))
        }
```

- [ ] **Step 6: Build, then manual-verify the move**

Run: `xcodebuild build -project "Muse/Muse.xcodeproj" -scheme Muse -destination 'platform=macOS' 2>&1 | grep -E "error:|BUILD (SUCCEEDED|FAILED)"`
Expected: BUILD SUCCEEDED. Manual move check is in Task 6.

- [ ] **Step 7: Commit**

```bash
git add Muse/Muse/Filesystem/FileMover.swift Muse/Muse/Filesystem/BookmarkStore.swift Muse/Muse/Views/GridView.swift Muse/Muse/Views/SidebarView.swift Muse/Muse/Models/AppState.swift Muse/Muse/ContentView.swift
git commit -m "Drag grid images onto sidebar folders to move them

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 5: Reveal in Finder (sidebar)

**Files:**
- Modify: `Muse/Muse/Views/SidebarView.swift` (folder `.contextMenu`, around line 322)

- [ ] **Step 1: Add the menu item**

In the folder row `.contextMenu` in `SidebarView.swift`, add (after the Pin/Remove block, so it shows for every folder):

```swift
            Divider()
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([node.url])
            }
```

Ensure `import AppKit` is present at the top of the file (it is — `NSWorkspace` is used elsewhere; confirm).

- [ ] **Step 2: Build and commit**

Run: `xcodebuild build -project "Muse/Muse.xcodeproj" -scheme Muse -destination 'platform=macOS' 2>&1 | grep -E "error:|BUILD (SUCCEEDED|FAILED)"`
Expected: BUILD SUCCEEDED.

```bash
git add Muse/Muse/Views/SidebarView.swift
git commit -m "Sidebar: Reveal in Finder on folders

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 6: Manual verification in the running app

**Files:** none.

- [ ] **Step 1: Build & run** (`run` skill or Xcode ⌘R). Open a folder with several images.
- [ ] **Step 2: Selection** — single click highlights one; Cmd-click adds/removes scattered images; Shift-click selects a contiguous range; double-click opens the clicked image; switching folders clears the selection.
- [ ] **Step 3: Menu** — right-click within a multi-selection → Add to Collection (pick one) → reopen that collection and confirm all were added; Add Tag (pick one) → confirm the tag applied to all; Share → the macOS share sheet lists the selected images. Right-click an unselected tile → acts on just that one.
- [ ] **Step 4: Move** — drag a selection onto another sidebar folder → files leave the source and appear in the destination (verify in Finder). A name collision surfaces the "Couldn’t move some files" alert. (If moves fail with a permission error, remove and re-add the destination folder so it gets a read-write bookmark, per the spec.)
- [ ] **Step 5: Reveal** — right-click a sidebar folder → Reveal in Finder opens it selected in Finder.
- [ ] **Step 6:** Commit any fixes; otherwise done.

---

## Notes for the implementer

- **Selection key is the standardized path** everywhere (`url.standardizedFileURL.path`), so it survives re-enumeration (where `FileNode.id` is a fresh UUID).
- **Immediate selection:** the AppKit `TileClickCatcher` selects on the first `mouseDown` and opens on `clickCount >= 2`, deliberately avoiding SwiftUI's `onTapGesture(count:1)+(count:2)` disambiguation delay the project previously removed.
- **Right-click still works** because `TileClickCatcher` only overrides `mouseDown` (left); confirm the SwiftUI `.contextMenu` still appears in Task 2 — if a transparent NSView swallows the right-click, override `rightMouseDown` to call a closure that sets selection and present the menu via the SwiftUI path.
- **Moving needs read-write bookmarks** on source and destination roots (already the app's default since delete-to-Trash); pre-existing folders may need re-adding.
- **One image opens at a time:** double-click always targets the one tile clicked; selection size is irrelevant to opening.
