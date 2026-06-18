# Folder Ops + Hero Share Dropdown Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add New Subfolder + Rename Folder to the sidebar (right-click and menu bar), make the hero viewer's Share button a Share/Open-With dropdown, and refresh the Info modal — all local-first and sandbox-safe.

**Architecture:** Pure file/DB logic (`FolderOps`, `FolderRenameMigration`) is unit-tested and called by `@MainActor` handlers on `AppState`. Dialogs follow the existing request-property pattern (`AppState.*Request` + a host `.alert`). Folder rename rewrites stored path prefixes in `paths.absolute_path` and `tags.parent_dir` so manual tags / collections / analysis survive; collections, FTS, and analysis are keyed by `file_id` (content hash) and need no migration.

**Tech Stack:** SwiftUI, AppKit, GRDB (SQLite), XCTest, Xcode 16.

## Global Constraints

- Min macOS **14.6**; no network calls (sandbox); files are never deleted, only `NSWorkspace.recycle`.
- **Tags are per `(file_id, parent_dir)`** — derive the folder key via `TagScope`; never leak across folders.
- GRDB writes: `try await queue.write { db in ... }`; reads: `try await queue.read`. `Database.shared.dbQueue` is `nonisolated let dbQueue: DatabaseQueue?`.
- `AppState` is `@MainActor`. Background/disk work off-main where it matters.
- Naming UX = **dialog prompts** (not inline edit). Rename applies to **all user folders except the iCloud "Muse" home** (`node.url == appState.iCloudFolderURL`). New Subfolder is allowed on every folder incl. the iCloud home; no top-level "new empty folder" path is added.
- Curly quotes “ ” in user-facing copy, matching existing dialogs.
- Build check: `xcodebuild -scheme Muse -destination 'platform=macOS' build`. Test: `xcodebuild -scheme Muse -destination 'platform=macOS' test`.

---

### Task 1: Pure folder ops + rename path-rewrite

**Files:**
- Create: `Muse/Muse/Filesystem/FolderOps.swift`
- Create: `Muse/Muse/Filesystem/FolderRenameMigration.swift`
- Test: `Muse/MuseTests/FolderOpsTests.swift`
- Test: `Muse/MuseTests/FolderRenameMigrationTests.swift`

**Interfaces:**
- Produces:
  - `enum FolderOps.OpError: Error, Equatable { case emptyName, invalidName, collision, ioError }`
  - `static func FolderOps.sanitize(_ raw: String) -> Result<String, FolderOps.OpError>`
  - `static func FolderOps.createSubfolder(named raw: String, in parent: URL) -> Result<URL, FolderOps.OpError>`
  - `static func FolderOps.rename(_ folder: URL, to raw: String) -> Result<URL, FolderOps.OpError>`
  - `static func FolderRenameMigration.rewrite(path: String, old: String, new: String) -> String?`

- [ ] **Step 1: Write the failing tests for `FolderRenameMigration.rewrite`**

```swift
//  FolderRenameMigrationTests.swift
//  MuseTests
import XCTest
@testable import Muse

final class FolderRenameMigrationTests: XCTestCase {
    func testExactFolderMatchRewrites() {
        // tags.parent_dir of a file directly in the renamed folder.
        XCTAssertEqual(
            FolderRenameMigration.rewrite(path: "/a/Old", old: "/a/Old", new: "/a/New"),
            "/a/New")
    }
    func testNestedChildRewrites() {
        XCTAssertEqual(
            FolderRenameMigration.rewrite(path: "/a/Old/sub/p.png", old: "/a/Old", new: "/a/New"),
            "/a/New/sub/p.png")
    }
    func testSiblingPrefixIsNotMatched() {
        // "/a/Old" must not catch "/a/OldStuff".
        XCTAssertNil(
            FolderRenameMigration.rewrite(path: "/a/OldStuff/p.png", old: "/a/Old", new: "/a/New"))
    }
    func testUnrelatedPathIsNil() {
        XCTAssertNil(
            FolderRenameMigration.rewrite(path: "/b/x.png", old: "/a/Old", new: "/a/New"))
    }
    func testPathWithSqlWildcardsRewrites() {
        XCTAssertEqual(
            FolderRenameMigration.rewrite(path: "/a/Old/100%_off/p_1.png", old: "/a/Old", new: "/a/New"),
            "/a/New/100%_off/p_1.png")
    }
}
```

- [ ] **Step 2: Run tests, verify they fail**

Run: `xcodebuild -scheme Muse -destination 'platform=macOS' test -only-testing:MuseTests/FolderRenameMigrationTests`
Expected: FAIL — "Cannot find 'FolderRenameMigration' in scope".

- [ ] **Step 3: Implement `FolderRenameMigration`**

```swift
//
//  FolderRenameMigration.swift
//  Muse
//
//  Pure path-prefix rewrite for a folder rename. When a folder is renamed,
//  every stored absolute path under it (paths.absolute_path) and every tag
//  parent-dir key equal to it or under it (tags.parent_dir) must follow.
//  Factored out so the prefix rule is unit-tested independent of SQLite; the
//  GRDB UPDATEs in AppState apply the identical rule in SQL.
//
import Foundation

enum FolderRenameMigration {
    /// New path for `path` when its folder `old` is renamed to `new`.
    /// Returns the rewritten path if `path == old` or lives under `old/`,
    /// otherwise nil (no match — leave the row untouched). A sibling like
    /// "/a/OldStuff" is never matched by old "/a/Old".
    static func rewrite(path: String, old: String, new: String) -> String? {
        if path == old { return new }
        let prefix = old.hasSuffix("/") ? old : old + "/"
        guard path.hasPrefix(prefix) else { return nil }
        return new + String(path.dropFirst(old.count))
    }
}
```

- [ ] **Step 4: Run tests, verify they pass**

Run: `xcodebuild -scheme Muse -destination 'platform=macOS' test -only-testing:MuseTests/FolderRenameMigrationTests`
Expected: PASS (5 tests).

- [ ] **Step 5: Write the failing tests for `FolderOps`**

```swift
//  FolderOpsTests.swift
//  MuseTests
import XCTest
@testable import Muse

final class FolderOpsTests: XCTestCase {
    private var tmp: URL!

    override func setUpWithError() throws {
        tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("FolderOpsTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    func testSanitizeRejectsEmpty() {
        XCTAssertEqual(FolderOps.sanitize("   "), .failure(.emptyName))
    }
    func testSanitizeRejectsSlashAndColon() {
        XCTAssertEqual(FolderOps.sanitize("a/b"), .failure(.invalidName))
        XCTAssertEqual(FolderOps.sanitize("a:b"), .failure(.invalidName))
        XCTAssertEqual(FolderOps.sanitize(".."), .failure(.invalidName))
    }
    func testSanitizeTrimsWhitespace() {
        XCTAssertEqual(FolderOps.sanitize("  Photos  "), .success("Photos"))
    }
    func testCreateSubfolderMakesDirectory() throws {
        let result = FolderOps.createSubfolder(named: "New", in: tmp)
        let url = try XCTUnwrap(try? result.get())
        var isDir: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir))
        XCTAssertTrue(isDir.boolValue)
        XCTAssertEqual(url.lastPathComponent, "New")
    }
    func testCreateSubfolderCollision() throws {
        try FileManager.default.createDirectory(
            at: tmp.appendingPathComponent("Dup"), withIntermediateDirectories: false)
        XCTAssertEqual(FolderOps.createSubfolder(named: "Dup", in: tmp), .failure(.collision))
    }
    func testRenameMovesFolder() throws {
        let src = tmp.appendingPathComponent("Before")
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: false)
        let result = FolderOps.rename(src, to: "After")
        let dst = try XCTUnwrap(try? result.get())
        XCTAssertEqual(dst.lastPathComponent, "After")
        XCTAssertFalse(FileManager.default.fileExists(atPath: src.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dst.path))
    }
    func testRenameCollision() throws {
        let src = tmp.appendingPathComponent("A")
        let other = tmp.appendingPathComponent("B")
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: false)
        XCTAssertEqual(FolderOps.rename(src, to: "B"), .failure(.collision))
    }
    func testRenameToSameNameSucceedsNoop() throws {
        let src = tmp.appendingPathComponent("Same")
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: false)
        let dst = try XCTUnwrap(try? FolderOps.rename(src, to: "Same").get())
        XCTAssertEqual(dst.standardizedFileURL, src.standardizedFileURL)
    }
}
```

- [ ] **Step 6: Run tests, verify they fail**

Run: `xcodebuild -scheme Muse -destination 'platform=macOS' test -only-testing:MuseTests/FolderOpsTests`
Expected: FAIL — "Cannot find 'FolderOps' in scope".

- [ ] **Step 7: Implement `FolderOps`**

```swift
//
//  FolderOps.swift
//  Muse
//
//  Create / rename folders on disk. Roots already hold read-write security
//  scope for the app's lifetime (BookmarkStore), so operations inside them
//  need no per-op start/stop access. Pure validation + thin FileManager calls;
//  the DB migration that must accompany a rename lives in AppState (it needs
//  the database queue), keyed off a successful disk move here.
//
import Foundation

enum FolderOps {
    enum OpError: Error, Equatable { case emptyName, invalidName, collision, ioError }

    /// Trim and validate a proposed folder name. Rejects empty names, path
    /// separators ("/" and ":" — the latter is the legacy HFS separator Finder
    /// also forbids), and the "." / ".." specials.
    static func sanitize(_ raw: String) -> Result<String, OpError> {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { return .failure(.emptyName) }
        if name == "." || name == ".." { return .failure(.invalidName) }
        if name.contains("/") || name.contains(":") { return .failure(.invalidName) }
        return .success(name)
    }

    /// Create `name` as a subfolder of `parent`. Fails on a name collision
    /// (never overwrites) or an IO error.
    static func createSubfolder(named raw: String, in parent: URL) -> Result<URL, OpError> {
        switch sanitize(raw) {
        case .failure(let e): return .failure(e)
        case .success(let name):
            let target = parent.appendingPathComponent(name, isDirectory: true)
            if FileManager.default.fileExists(atPath: target.path) { return .failure(.collision) }
            do {
                try FileManager.default.createDirectory(
                    at: target, withIntermediateDirectories: false)
                return .success(target)
            } catch { return .failure(.ioError) }
        }
    }

    /// Rename `folder` in place (same parent, new last component). Renaming to
    /// the current name is a no-op success. Fails on a collision with a
    /// different existing item, or an IO error (e.g. a protected system folder).
    static func rename(_ folder: URL, to raw: String) -> Result<URL, OpError> {
        switch sanitize(raw) {
        case .failure(let e): return .failure(e)
        case .success(let name):
            let parent = folder.deletingLastPathComponent()
            let target = parent.appendingPathComponent(name, isDirectory: true)
            if target.standardizedFileURL == folder.standardizedFileURL {
                return .success(folder)   // no change
            }
            if FileManager.default.fileExists(atPath: target.path) { return .failure(.collision) }
            do {
                try FileManager.default.moveItem(at: folder, to: target)
                return .success(target)
            } catch { return .failure(.ioError) }
        }
    }
}
```

- [ ] **Step 8: Run all new tests, verify they pass**

Run: `xcodebuild -scheme Muse -destination 'platform=macOS' test -only-testing:MuseTests/FolderOpsTests -only-testing:MuseTests/FolderRenameMigrationTests`
Expected: PASS.

- [ ] **Step 9: Commit**

```bash
git add Muse/Muse/Filesystem/FolderOps.swift Muse/Muse/Filesystem/FolderRenameMigration.swift Muse/MuseTests/FolderOpsTests.swift Muse/MuseTests/FolderRenameMigrationTests.swift
git commit -m "Folder ops: pure create/rename + rename path-rewrite (tested)"
```

---

### Task 2: FolderNode reload + BookmarkStore display-name / root-rename support

**Files:**
- Modify: `Muse/Muse/Filesystem/FolderTree.swift` (FolderNode)
- Modify: `Muse/Muse/Filesystem/BookmarkStore.swift`

**Interfaces:**
- Produces:
  - `FolderNode.parent: FolderNode?` (weak, `private(set)`)
  - `func FolderNode.reloadChildren(showHidden: Bool = false)`
  - `func BookmarkStore.rootRenamed(_ root: Root, to newURL: URL) -> Bool`
- Consumes: `FolderOps` (Task 1) is not needed here; this task is independent.

- [ ] **Step 1: Add a weak parent ref + reloadChildren to FolderNode**

In `FolderTree.swift`, add the stored property (after `isExpanded`):

```swift
    /// Parent node, set when this node is created as a child. Lets a rename
    /// refresh the right subtree (`node.parent?.reloadChildren()`).
    private(set) weak var parent: FolderNode?
```

Set it inside `loadChildrenIfNeeded` — change the `children = folders` assignment so each child points back. Replace the existing `let folders = ...` / `children = folders` block with:

```swift
        let folders = entries.compactMap { childURL -> FolderNode? in
            let values = try? childURL.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
            guard values?.isDirectory == true, values?.isPackage != true else { return nil }
            let child = FolderNode(url: childURL)
            child.parent = self
            return child
        }
        .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }

        children = folders
```

Then add `reloadChildren` right after `loadChildrenIfNeeded`:

```swift
    /// Re-read immediate children even if already loaded — used after creating
    /// or renaming a subfolder so the new/renamed row appears. Resets the
    /// guard and reloads; preserves nothing about old child identity (callers
    /// reselect by URL where needed).
    func reloadChildren(showHidden: Bool = false) {
        isLoaded = false
        children = []
        loadChildrenIfNeeded(showHidden: showHidden)
    }
```

- [ ] **Step 2: Add display-name update + root-rename to BookmarkStore**

In `BookmarkStore.swift`, add after `reorder(...)`:

```swift
    // MARK: - Rename

    /// After a ROOT folder is renamed on disk, repoint its bookmark + display
    /// name to the new location. Security-scoped bookmarks are inode-based and
    /// survive a same-volume rename, so the existing active scope still covers
    /// the moved folder; we mint a fresh bookmark from `newURL` (accessible via
    /// that live scope), swap access, and update the stored Root. Returns false
    /// if a new bookmark could not be created (access then stays on the old
    /// URL, which the caller surfaces as an error).
    @discardableResult
    func rootRenamed(_ root: Root, to newURL: URL) -> Bool {
        guard let data = try? newURL.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ) else { return false }

        // Drop the old scope, then build + activate the renamed root.
        if let old = accessedURLs[root.id] {
            old.stopAccessingSecurityScopedResource()
            accessedURLs.removeValue(forKey: root.id)
        }
        let renamed = Root(id: root.id,
                           displayName: newURL.lastPathComponent,
                           bookmarkData: data,
                           addedAt: root.addedAt)
        activate(renamed)   // resolves newURL + starts access + sets accessedURLs
        if let i = roots.firstIndex(of: root) {
            roots[i] = renamed   // @Published willSet → AppState rebuilds the tree
        }
        save()
        return true
    }
```

- [ ] **Step 3: Build to verify it compiles**

Run: `xcodebuild -scheme Muse -destination 'platform=macOS' build`
Expected: BUILD SUCCEEDED.

- [ ] **Step 4: Commit**

```bash
git add Muse/Muse/Filesystem/FolderTree.swift Muse/Muse/Filesystem/BookmarkStore.swift
git commit -m "FolderNode.reloadChildren + parent ref; BookmarkStore.rootRenamed"
```

---

### Task 3: AppState — request properties + create/rename handlers (with DB migration)

**Files:**
- Modify: `Muse/Muse/Models/AppState.swift`

**Interfaces:**
- Consumes: `FolderOps` (Task 1), `FolderRenameMigration` (Task 1), `FolderNode.reloadChildren` / `BookmarkStore.rootRenamed` (Task 2).
- Produces:
  - `@Published var newSubfolderRequest: FolderNode?`
  - `@Published var folderRenameRequest: FolderNode?`
  - `@Published var folderOpError: String?`
  - `func createSubfolder(named name: String, in node: FolderNode)`
  - `func renameFolder(_ node: FolderNode, to name: String)`

- [ ] **Step 1: Add the request + error properties**

In `AppState.swift`, beside the other request properties (after line 234, the `regenerateTagsRequest`):

```swift
    /// Folder-management dialogs (shared by the sidebar context menu and the
    /// menu-bar Edit menu). New Subfolder is allowed on any folder incl. the
    /// iCloud home; Rename is gated to non-iCloud folders by the callers.
    @Published var newSubfolderRequest: FolderNode?
    @Published var folderRenameRequest: FolderNode?
    /// Set to a message to surface a folder-op failure alert.
    @Published var folderOpError: String?
```

- [ ] **Step 2: Add the create handler**

Add these methods to `AppState` (anywhere in the main class body, e.g. near `reloadAfterMove`):

```swift
    // MARK: - Folder management

    /// Create a subfolder inside `node` on disk, then refresh the tree and
    /// drill into the new folder. Surfaces failures via `folderOpError`.
    func createSubfolder(named name: String, in node: FolderNode) {
        switch FolderOps.createSubfolder(named: name, in: node.url) {
        case .failure(let e):
            folderOpError = Self.message(for: e, verb: "create")
        case .success(let newURL):
            node.reloadChildren()
            node.isExpanded = true
            if let child = node.children.first(where: {
                $0.url.standardizedFileURL == newURL.standardizedFileURL
            }) {
                select(folder: child)
            }
        }
    }
```

- [ ] **Step 3: Add the rename handler (disk + DB migration + tree refresh)**

```swift
    /// Rename `node`'s folder on disk and migrate the index + tags so nothing
    /// is orphaned. Roots repoint their bookmark; subfolders reload from their
    /// parent. The iCloud home is never renamed (callers gate it).
    func renameFolder(_ node: FolderNode, to name: String) {
        let oldURL = node.url
        switch FolderOps.rename(oldURL, to: name) {
        case .failure(let e):
            folderOpError = Self.message(for: e, verb: "rename")
        case .success(let newURL):
            // No-op rename (same name) — FolderOps returns the original URL.
            guard newURL.standardizedFileURL != oldURL.standardizedFileURL else { return }
            migratePaths(old: oldURL.standardizedFileURL.path,
                         new: newURL.standardizedFileURL.path)

            let wasSelected = selectedFolder?.url.standardizedFileURL == oldURL.standardizedFileURL
            if node.isRoot, let root = bookmarks.roots.first(where: {
                bookmarks.url(for: $0) == oldURL
            }) {
                // rootRenamed mutates bookmarks.roots → the $roots sink rebuilds
                // rootNodes with the new URL/name.
                if !bookmarks.rootRenamed(root, to: newURL) {
                    folderOpError = "Couldn’t finish renaming the folder."
                }
            } else {
                node.parent?.reloadChildren()
            }

            // Reselect by URL if the renamed folder was the active one.
            if wasSelected {
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    if let n = self.findNode(withURL: newURL) { self.select(folder: n) }
                }
            }
        }
    }

    /// Find a loaded node by URL across all root trees (best-effort; only walks
    /// already-loaded children). Used to reselect after a rename.
    private func findNode(withURL url: URL) -> FolderNode? {
        let target = url.standardizedFileURL
        func walk(_ n: FolderNode) -> FolderNode? {
            if n.url.standardizedFileURL == target { return n }
            for c in n.children { if let hit = walk(c) { return hit } }
            return nil
        }
        for r in rootNodes { if let hit = walk(r) { return hit } }
        return nil
    }

    /// Rewrite stored path prefixes after a folder rename: paths.absolute_path
    /// and tags.parent_dir for the folder itself and everything beneath it.
    /// file_id-keyed data (files, collections, FTS, embeddings) is unaffected.
    /// Prefix match uses SUBSTR (not LIKE) so "%"/"_" in paths can't break it
    /// and a sibling like "…/OldStuff" is never caught by old "…/Old".
    private func migratePaths(old: String, new: String) {
        guard let queue = Database.shared.dbQueue else { return }
        Task { [weak self] in
            try? await queue.write { db in
                try db.execute(sql: """
                    UPDATE paths
                    SET absolute_path = ? || SUBSTR(absolute_path, LENGTH(?) + 1)
                    WHERE absolute_path = ?
                       OR SUBSTR(absolute_path, 1, LENGTH(?) + 1) = ? || '/'
                    """, arguments: [new, old, old, old, old])
                try db.execute(sql: """
                    UPDATE tags
                    SET parent_dir = ? || SUBSTR(parent_dir, LENGTH(?) + 1)
                    WHERE parent_dir = ?
                       OR SUBSTR(parent_dir, 1, LENGTH(?) + 1) = ? || '/'
                    """, arguments: [new, old, old, old, old])
            }
            self?.tagsVersion &+= 1   // self is @MainActor; this hops back on-main
        }
    }

    /// User-facing folder-op error copy.
    private static func message(for error: FolderOps.OpError, verb: String) -> String {
        switch error {
        case .emptyName:   return "Please enter a folder name."
        case .invalidName: return "A folder name can’t contain “/” or “:”."
        case .collision:   return "A folder with that name already exists here."
        case .ioError:     return "Couldn’t \(verb) the folder. You may not have permission."
        }
    }
```

> NOTE: `AppState` is a `@MainActor` `@StateObject` (not a singleton), so the
> `Task { [weak self] in ... }` above runs its body on the main actor; the GRDB
> `queue.write` is its own async hop, and `self?.tagsVersion` is set back on-main.
> `Task.detached` is intentionally NOT used (it would lose actor isolation).

- [ ] **Step 4: Build to verify it compiles**

Run: `xcodebuild -scheme Muse -destination 'platform=macOS' build`
Expected: BUILD SUCCEEDED.

- [ ] **Step 5: Commit**

```bash
git add Muse/Muse/Models/AppState.swift
git commit -m "AppState: create/rename folder handlers + path/tag DB migration"
```

---

### Task 4: Sidebar context-menu items + dialog host

**Files:**
- Modify: `Muse/Muse/Views/SidebarView.swift` (FolderTreeNode contextMenu)
- Modify: `Muse/Muse/ContentView.swift` (host the alerts)

**Interfaces:**
- Consumes: `AppState.newSubfolderRequest`, `folderRenameRequest`, `folderOpError`, `createSubfolder(named:in:)`, `renameFolder(_:to:)`.

- [ ] **Step 1: Add the two context-menu items**

In `SidebarView.swift`, inside `FolderTreeNode`'s `.contextMenu { ... }`, after the existing Pin/Remove block and before the `Divider()`+"Reveal in Finder", add:

```swift
            Divider()
            Button("New Subfolder…") { appState.newSubfolderRequest = node }
            // The iCloud "Muse" home is app-managed — not renamable.
            if node.url != appState.iCloudFolderURL {
                Button("Rename Folder…") { appState.folderRenameRequest = node }
            }
```

(The existing `Divider()` + `Reveal in Finder` remain after this.)

- [ ] **Step 2: Host the dialogs on ContentView**

In `ContentView.swift`, add a `@State` for each text field near the top of the view struct:

```swift
    @State private var newSubfolderName = ""
    @State private var renameFolderName = ""
```

Attach these modifiers to ContentView's top-level container (the same view that already carries the app chrome — place them alongside any existing `.alert`/`.sheet`; if none, attach to the outermost `ZStack`/`VStack` in `body`):

```swift
        .onChange(of: appState.newSubfolderRequest) { _, node in
            if node != nil { newSubfolderName = "" }
        }
        .alert("New Subfolder", isPresented: Binding(
            get: { appState.newSubfolderRequest != nil },
            set: { if !$0 { appState.newSubfolderRequest = nil } }
        )) {
            TextField("Folder name", text: $newSubfolderName)
            Button("Create") {
                if let node = appState.newSubfolderRequest {
                    appState.newSubfolderRequest = nil
                    appState.createSubfolder(named: newSubfolderName, in: node)
                }
            }
            Button("Cancel", role: .cancel) { appState.newSubfolderRequest = nil }
        } message: {
            Text("Creates a new folder inside “\(appState.newSubfolderRequest?.displayName ?? "")”.")
        }
        .onChange(of: appState.folderRenameRequest) { _, node in
            if let node { renameFolderName = node.displayName }
        }
        .alert("Rename Folder", isPresented: Binding(
            get: { appState.folderRenameRequest != nil },
            set: { if !$0 { appState.folderRenameRequest = nil } }
        )) {
            TextField("Folder name", text: $renameFolderName)
            Button("Rename") {
                if let node = appState.folderRenameRequest {
                    appState.folderRenameRequest = nil
                    appState.renameFolder(node, to: renameFolderName)
                }
            }
            Button("Cancel", role: .cancel) { appState.folderRenameRequest = nil }
        } message: {
            Text("Renames the folder on disk. Tags and collections are kept.")
        }
        .alert("Folder", isPresented: Binding(
            get: { appState.folderOpError != nil },
            set: { if !$0 { appState.folderOpError = nil } }
        )) {
            Button("OK", role: .cancel) { appState.folderOpError = nil }
        } message: {
            Text(appState.folderOpError ?? "")
        }
```

> NOTE: `FolderNode` is `ObservableObject` (a reference type) and already
> `Identifiable`. `onChange(of:)` requires `Equatable`; reference types compare
> by identity for `===`-style equality only if `Equatable` is synthesized. If
> the compiler complains that `FolderNode` isn't `Equatable`, change the two
> `onChange(of: appState.<request>)` observers to observe a derived `ObjectIdentifier?`
> instead, e.g. `.onChange(of: appState.newSubfolderRequest.map(ObjectIdentifier.init))`,
> and read the node from `appState.newSubfolderRequest` inside the closure.

- [ ] **Step 3: Build, then run and smoke-test**

Run: `xcodebuild -scheme Muse -destination 'platform=macOS' build`
Expected: BUILD SUCCEEDED.

Manual: launch, right-click a folder → New Subfolder… → type a name → it appears and is selected; right-click → Rename Folder… → rename → the row updates and tags on files inside are preserved (open a tagged subfolder, rename it, confirm chips persist).

- [ ] **Step 4: Commit**

```bash
git add Muse/Muse/Views/SidebarView.swift Muse/Muse/ContentView.swift
git commit -m "Sidebar: New Subfolder / Rename Folder context items + dialog host"
```

---

### Task 5: Menu-bar equivalents

**Files:**
- Modify: `Muse/Muse/MuseApp.swift`

**Interfaces:**
- Consumes: `AppState.newSubfolderRequest`, `folderRenameRequest`, `selectedFolder`, `iCloudFolderURL`, `selectedFile`, and `OpenWithMenu.applications(for:)` (Task 6 is independent; `OpenWithMenu` already exists).

- [ ] **Step 1: Add folder commands to the Edit-menu folder block**

In `MuseApp.swift`, inside the second `CommandGroup(after: .pasteboard)` (the one with Pin/Remove/Set-as-Cover), after the `Set as Collection Cover` button add:

```swift
                Divider()

                Button("New Subfolder…") {
                    if let folder = appState.selectedFolder {
                        appState.newSubfolderRequest = folder
                    }
                }
                .disabled(appState.selectedFolder == nil)

                Button("Rename Folder…") {
                    if let folder = appState.selectedFolder {
                        appState.folderRenameRequest = folder
                    }
                }
                .disabled(appState.selectedFolder == nil
                          || appState.selectedFolder?.url == appState.iCloudFolderURL)
```

- [ ] **Step 2: Add Open / Open With for the selected image to the File menu**

In `MuseApp.swift`, inside the `CommandGroup(after: .newItem)` block (currently Find Duplicates), after the existing `Button("Find Duplicates in Folder")` add:

```swift
                Divider()

                Button("Open") {
                    if let url = appState.selectedFile?.url { NSWorkspace.shared.open(url) }
                }
                .disabled(appState.selectedFile == nil)

                Menu("Open With") {
                    if let url = appState.selectedFile?.url {
                        ForEach(OpenWithMenu.applications(for: url), id: \.self) { appURL in
                            Button(appURL.deletingPathExtension().lastPathComponent) {
                                NSWorkspace.shared.open(
                                    [url], withApplicationAt: appURL,
                                    configuration: NSWorkspace.OpenConfiguration()) { _, _ in }
                            }
                        }
                    }
                }
                .disabled(appState.selectedFile == nil)
```

Add `import AppKit` at the top of `MuseApp.swift` if not already present (it imports `SwiftUI`; `NSWorkspace` needs AppKit — `import AppKit`).

- [ ] **Step 3: Build to verify it compiles**

Run: `xcodebuild -scheme Muse -destination 'platform=macOS' build`
Expected: BUILD SUCCEEDED.

- [ ] **Step 4: Commit**

```bash
git add Muse/Muse/MuseApp.swift
git commit -m "Menu bar: New Subfolder / Rename Folder + Open / Open With"
```

---

### Task 6: Hero Share dropdown (Share + Open With)

**Files:**
- Modify: `Muse/Muse/Views/Viewer/ShareButton.swift`

**Interfaces:**
- Consumes: `OpenWithMenu.applications(for:)` (existing static).

- [ ] **Step 1: Convert ShareButton to a Menu**

Replace the body of `ShareButton.swift` (keep the file header + `import` lines) with:

```swift
struct ShareButton: View {
    let url: URL
    @State private var hovering = false
    @State private var apps: [URL] = []

    var body: some View {
        Menu {
            Button("Share") { share() }
            Menu("Open With") {
                Button("Open") { NSWorkspace.shared.open(url) }
                Button("Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
                if !apps.isEmpty {
                    Divider()
                    ForEach(apps, id: \.self) { appURL in
                        Button(appURL.deletingPathExtension().lastPathComponent) {
                            NSWorkspace.shared.open(
                                [url], withApplicationAt: appURL,
                                configuration: NSWorkspace.OpenConfiguration()) { _, _ in }
                        }
                    }
                }
            }
        } label: {
            Image(systemName: "square.and.arrow.up")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(hovering ? 1.0 : 0.85))
                .frame(width: 38, height: 38)
                .background(Circle().fill(.white.opacity(hovering ? 0.24 : 0.10)))
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .fixedSize()
        .onHover { hovering = $0 }
        .help("Share")
        .task(id: url) { apps = OpenWithMenu.applications(for: url) }
    }

    private func share() {
        guard let contentView = NSApp.keyWindow?.contentView else { return }
        let picker = NSSharingServicePicker(items: [url])
        picker.show(relativeTo: .zero, of: contentView, preferredEdge: .minY)
    }
}
```

- [ ] **Step 2: Build, then run and smoke-test**

Run: `xcodebuild -scheme Muse -destination 'platform=macOS' build`
Expected: BUILD SUCCEEDED.

Manual: open an image in the hero viewer → click the share circle → menu shows **Share** and **Open With ▸** (with Open, Reveal in Finder, and apps). Share still opens the system sheet.

- [ ] **Step 3: Commit**

```bash
git add Muse/Muse/Views/Viewer/ShareButton.swift
git commit -m "Hero viewer: Share button is a Share / Open With dropdown"
```

---

### Task 7: Info modal refresh + enlarge

**Files:**
- Modify: `Muse/Muse/Views/InfoSheet.swift`

- [ ] **Step 1: Enlarge the sheet**

Change the final frame line:

```swift
        .frame(width: 540, height: 640)
```

to:

```swift
        .frame(width: 600, height: 720)
```

- [ ] **Step 2: Update / extend the section copy**

Edit the section bodies so they reflect current behavior. Make these specific changes:

Replace the **Library & indexing** section body with:

```swift
                    section("Library & folders", """
                        Add folders from the sidebar with the Add Folder \
                        button — Muse indexes them automatically (the status \
                        pills at the bottom show progress). Drag folders up or \
                        down to reorder them. Right-click a folder to make a \
                        New Subfolder, Rename it, Reveal it in Finder, or — \
                        for a buried subfolder — Pin it to the top. Right-click \
                        a top-level folder to Remove it from Muse. Your files \
                        are never modified; deleting means moving to the Trash, \
                        and it's undoable.
                        """)
```

Replace the **Viewing files** section body with:

```swift
                    section("Viewing & selecting", """
                        Muse opens almost anything in place: images, PDFs, \
                        video, audio, fonts, Markdown, and code or text. Click \
                        an image for a full-screen view with zoom, pan, and a \
                        details panel; its Share button also offers Open With. \
                        Select images in the grid with a click, ⌘-click, or \
                        Shift-click, then right-click for actions — move to a \
                        folder, add to a collection, add a tag, share, or Open \
                        With. Anything without a dedicated viewer falls back to \
                        Quick Look.
                        """)
```

Replace the **Search** section body with:

```swift
                    section("Search & sort", """
                        Search by name, tags, captions, and text found inside \
                        images. The magnifier menu scopes the search to the \
                        current folder or your whole library. Sort by date, \
                        name, size, color, or shape, and use the arrow beside \
                        the sort menu to flip the direction.
                        """)
```

Replace the **Sharing** section body with:

```swift
                    section("Sharing", """
                        Share an image from the viewer — AirDrop, Mail, \
                        Messages, or Save to Files — or share a whole \
                        collection as a PDF from its header. From Finder, \
                        right-click any file and choose Share → Muse to send it \
                        into your iCloud folder.
                        """)
```

Replace the **Background** section body with a combined options note (rename the title to "Grid & appearance"):

```swift
                    section("Grid & appearance", """
                        Set the grid density with the slider at the bottom \
                        right, and turn on file names under tiles in Settings. \
                        The palette button sets the background: Light, Dark, \
                        Auto (light by day, dark at night), or a custom color.
                        """)
```

Add a new **Settings** section (insert a `rowDivider` then this section right before the **Updates** section):

```swift
                    section("Settings", """
                        Muse organizes automatically, but you're in control: in \
                        Settings (⌘,) you can turn off automatic tagging or \
                        automatic collections. Existing tags and collections \
                        stay; only future automatic work is paused, and the \
                        manual commands still work.
                        """)
```

Fix the stale **Updates** section body (remove "it asks first"):

```swift
                    section("Updates", """
                        Muse is distributed directly (not via the App Store) \
                        and keeps itself up to date with Sparkle. It checks \
                        quietly in the background, or choose Muse ▸ Check for \
                        Updates… any time. New versions are downloaded over \
                        HTTPS and cryptographically verified before installing.
                        """)
```

(Leave the **What Muse is**, **Analysis**, **Collections**, **Tags**, **Duplicates**, **iCloud sync**, **Open source**, and **Privacy & retention** sections as-is unless a phrase contradicts the above — the section titles changed for Library/Viewing/Search/Background, but each still sits between its existing `rowDivider`s.)

- [ ] **Step 3: Build, then run and visually verify**

Run: `xcodebuild -scheme Muse -destination 'platform=macOS' build`
Expected: BUILD SUCCEEDED.

Manual: open the ⓘ About sheet → it's larger, scrolls cleanly, new sections read correctly, no orphaned/duplicated dividers.

- [ ] **Step 4: Commit**

```bash
git add Muse/Muse/Views/InfoSheet.swift
git commit -m "Info modal: refresh copy for new features + enlarge"
```

---

### Task 8: Verify grid Open With + full suite green

**Files:** none (verification).

- [ ] **Step 1: Confirm grid Open With coverage**

Run: `grep -n "OpenWithMenu" Muse/Muse/Views/GridView.swift`
Expected: `OpenWithMenu(url: file.url)` present in the tile context menu (single-selection branch). `GridView` is the shared grid for the main, tag-filtered, and in-collection views — so all three are covered. The Collections page shows cover cards (no images), so Open With does not apply there. No code change; note the result.

- [ ] **Step 2: Run the full test suite**

Run: `xcodebuild -scheme Muse -destination 'platform=macOS' test`
Expected: TEST SUCCEEDED — all `MuseTests` green, including the new `FolderOpsTests` / `FolderRenameMigrationTests`.

- [ ] **Step 3: Final manual regression pass**

- New Subfolder (local root, subfolder, and the iCloud "Muse" home).
- Rename a tagged subfolder → tags + collections persist (verify chips + a collection still lists the file).
- Rename a top-level root → name updates, folder still browsable, files still indexed.
- Rename collision + invalid name ("a/b") → graceful error alert.
- iCloud "Muse" home shows New Subfolder but NOT Rename (context menu + Edit menu disabled).
- Menu-bar New Subfolder / Rename Folder act on the selected folder.
- Hero Share dropdown: Share + Open With both work.

- [ ] **Step 4: Commit any final doc/status notes (if applicable)**

```bash
git add -A
git commit -m "Folder ops + Share dropdown: verification pass" || echo "nothing to commit"
```

---

## Self-Review notes

- **Spec coverage:** Task 1 (FolderOps + rewrite) ↔ spec Tasks 2/3 logic; Task 2/3 ↔ disk+DB+tree refresh; Task 4 ↔ sidebar + dialogs; Task 5 ↔ menu bar; Task 6 ↔ hero Share dropdown; Task 7 ↔ Info modal; Task 8 ↔ grid Open With verify + tests. All spec items mapped.
- **Type consistency:** `OpError` cases (`emptyName/invalidName/collision/ioError`), `FolderRenameMigration.rewrite(path:old:new:)`, `FolderNode.reloadChildren`, `BookmarkStore.rootRenamed(_:to:)`, and the `AppState` request property names are used identically across tasks.
- **Open risks flagged inline:** `AppState.shared` accessor name (Task 3 note) and `FolderNode` `Equatable` for `onChange` (Task 4 note) — both have concrete fallbacks.
