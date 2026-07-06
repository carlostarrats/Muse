# In-app File Rename Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let a user rename a single file (base name only; extension locked) from the grid tile's right-click context menu, routing the on-disk rename through the same DB migration seam as in-app moves so tags, collection memberships, and DB identity carry.

**Architecture:** A pure `FileNameSplit` type (split/recombine/validate the name) is tested first. A thin `FileMover.rename` disk primitive is the only sanctioned `FileManager.moveItem` for a rename. `AppState.renameFile` orchestrates: validate → collision-refuse → off-main disk rename → `FileMoveMigration.apply` (reused verbatim, same-dir case already correct) → `reloadAfterMove`. A `FileRenameAlert` SwiftUI modifier (local-`@State` draft, mirroring `CollectionRenameAlert`) drives the UI, wired to a single context-menu item and a parallel accessibility action.

**Tech Stack:** Swift, SwiftUI, AppKit (`FileManager`), GRDB, XCTest. Design spec: `docs/superpowers/specs/2026-07-06-file-rename-design.md`.

## Global Constraints

- **No bare `FileManager.moveItem` in a caller** — the only new `moveItem` is inside `FileMover.rename`; orchestration runs `FileMoveMigration` (CLAUDE.md: in-app relocations go through the migration seam).
- **`FileMoveMigration.apply` is reused unchanged** — no new DB path; same-dir rename is already correct (path repoint, tag re-scope skipped, membership by `file_id`).
- **TextField draft is local `@State`**, never bound to `AppState` (CLAUDE.md TextField rule).
- **Extension is LOCKED** — only the last dot-suffix is preserved and re-appended; no `AssetKind` reclassification.
- **Collision REFUSES** naming the conflicting file — never overwrite, never auto-suffix (Muse never destroys data).
- **Case-only rename is allowed** (`photo.jpg` → `Photo.jpg`) — not a self-collision (mirrors `FolderOps.rename`).
- **Every new user-facing string is localized** (French ships): SwiftUI text literals auto-extract; runtime/`String`-typed strings hand-wrapped in `String(localized:)`.
- **Every mouse-only interaction gets a parallel `.accessibilityAction`.**
- **Tests stay green:** `xcodebuild -scheme Muse test` (503+ unit tests) plus new tests below.

---

### Task 1: `FileNameSplit` pure logic

**Files:**
- Create: `Muse/Muse/Filesystem/FileNameSplit.swift`
- Test: `Muse/MuseTests/FileNameSplitTests.swift`

**Interfaces:**
- Consumes: nothing (pure, no imports beyond `Foundation`).
- Produces:
  - `enum RenameNameError: Error, Equatable { case empty, invalidCharacter, wouldHide }`
  - `enum FileNameSplit { static func split(_ name: String) -> (stem: String, ext: String); static func recombine(stem: String, ext: String) -> String; static func validate(stem: String, ext: String, originalName: String) -> Result<String, RenameNameError> }`

- [ ] **Step 1: Write the failing tests**

Create `Muse/MuseTests/FileNameSplitTests.swift`:

```swift
//
//  FileNameSplitTests.swift
//  MuseTests
//
//  Pure basename/extension split + recombine + shape validation for file rename.
//

import XCTest
@testable import Muse

final class FileNameSplitTests: XCTestCase {

    // MARK: - split

    func testSplitSimpleExtension() {
        let s = FileNameSplit.split("photo.jpg")
        XCTAssertEqual(s.stem, "photo")
        XCTAssertEqual(s.ext, ".jpg")
    }
    func testSplitMultiDotUsesLastSuffixOnly() {
        let s = FileNameSplit.split("archive.tar.gz")
        XCTAssertEqual(s.stem, "archive.tar")
        XCTAssertEqual(s.ext, ".gz")
    }
    func testSplitNoExtension() {
        let s = FileNameSplit.split("README")
        XCTAssertEqual(s.stem, "README")
        XCTAssertEqual(s.ext, "")
    }
    func testSplitLeadingDotDotfileHasNoExtension() {
        let s = FileNameSplit.split(".gitignore")
        XCTAssertEqual(s.stem, ".gitignore")
        XCTAssertEqual(s.ext, "")
    }
    func testSplitTrailingDotIsNotAnExtension() {
        let s = FileNameSplit.split("foo.")
        XCTAssertEqual(s.stem, "foo.")
        XCTAssertEqual(s.ext, "")
    }

    // MARK: - recombine

    func testRecombineReappendsExtension() {
        XCTAssertEqual(FileNameSplit.recombine(stem: "archive.tar", ext: ".gz"), "archive.tar.gz")
    }
    func testRecombineNoExtension() {
        XCTAssertEqual(FileNameSplit.recombine(stem: ".gitignore", ext: ""), ".gitignore")
    }
    func testRecombineDotInStemKeepsLockedExtension() {
        // Typing a dot in the stem is accepted; the real extension stays .jpg.
        XCTAssertEqual(FileNameSplit.recombine(stem: "photo.png", ext: ".jpg"), "photo.png.jpg")
    }

    // MARK: - validate

    func testValidateHappyPath() {
        XCTAssertEqual(
            FileNameSplit.validate(stem: "Invoice — March", ext: ".jpg", originalName: "IMG_1.jpg"),
            .success("Invoice — March.jpg"))
    }
    func testValidateTrimsWhitespace() {
        XCTAssertEqual(
            FileNameSplit.validate(stem: "  Photo  ", ext: ".jpg", originalName: "IMG_1.jpg"),
            .success("Photo.jpg"))
    }
    func testValidateEmptyStem() {
        XCTAssertEqual(
            FileNameSplit.validate(stem: "   ", ext: ".jpg", originalName: "IMG_1.jpg"),
            .failure(.empty))
    }
    func testValidateRejectsSlashAndColon() {
        XCTAssertEqual(
            FileNameSplit.validate(stem: "a/b", ext: ".jpg", originalName: "IMG_1.jpg"),
            .failure(.invalidCharacter))
        XCTAssertEqual(
            FileNameSplit.validate(stem: "a:b", ext: ".jpg", originalName: "IMG_1.jpg"),
            .failure(.invalidCharacter))
    }
    func testValidateRejectsHidingANonDotfile() {
        // A normal file must not be renamed into a hidden dotfile.
        XCTAssertEqual(
            FileNameSplit.validate(stem: ".secret", ext: "", originalName: "notes.txt"),
            .failure(.wouldHide))
    }
    func testValidateAllowsEditingAnExistingDotfile() {
        // .gitignore was already hidden — editing it (still leading-dot) is fine.
        XCTAssertEqual(
            FileNameSplit.validate(stem: ".gitignore-new", ext: "", originalName: ".gitignore"),
            .success(".gitignore-new"))
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild -scheme Muse test -only-testing:MuseTests/FileNameSplitTests`
Expected: FAIL — "Cannot find 'FileNameSplit' in scope".

- [ ] **Step 3: Write the implementation**

Create `Muse/Muse/Filesystem/FileNameSplit.swift`:

```swift
//
//  FileNameSplit.swift
//  Muse
//
//  Pure name logic for in-app file rename: split a filename into an editable
//  stem + a LOCKED extension (the last dot-suffix), recombine them, and validate
//  the shape of a proposed name. No filesystem, no DB — collision is checked at
//  the AppState layer. Mirrors FolderOps.sanitize as a tested pure seam.
//

import Foundation

enum RenameNameError: Error, Equatable { case empty, invalidCharacter, wouldHide }

enum FileNameSplit {

    /// Split `name` (a lastPathComponent) into (stem, ext) where `ext` is the
    /// last dot-suffix INCLUDING its dot, or "" when there is no extension.
    /// Multi-dot names use ONLY the last suffix (archive.tar.gz -> .gz). A
    /// leading-dot dotfile with no other dot (.gitignore) and a trailing-dot
    /// name (foo.) have no extension — the whole name is the stem.
    static func split(_ name: String) -> (stem: String, ext: String) {
        guard let dot = name.lastIndex(of: ".") else { return (name, "") }
        // Leading dot (index 0) => dotfile, no extension.
        if dot == name.startIndex { return (name, "") }
        let afterDot = name.index(after: dot)
        // Trailing dot => empty suffix, not an extension.
        if afterDot == name.endIndex { return (name, "") }
        return (String(name[name.startIndex..<dot]), String(name[dot..<name.endIndex]))
    }

    /// Re-append the locked extension to an edited stem. No trimming here.
    static func recombine(stem: String, ext: String) -> String { stem + ext }

    /// Validate the SHAPE of a proposed name (collision is checked elsewhere).
    /// Returns the final full name on success. `originalName` is the file's
    /// current basename, used to allow an already-hidden dotfile to keep its
    /// leading dot while forbidding a normal file from being hidden.
    static func validate(stem: String, ext: String,
                         originalName: String) -> Result<String, RenameNameError> {
        let trimmed = stem.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return .failure(.empty) }
        let full = recombine(stem: trimmed, ext: ext)
        if full.contains("/") || full.contains(":") { return .failure(.invalidCharacter) }
        if full.hasPrefix(".") && !originalName.hasPrefix(".") { return .failure(.wouldHide) }
        return .success(full)
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcodebuild -scheme Muse test -only-testing:MuseTests/FileNameSplitTests`
Expected: PASS (all 13 tests).

- [ ] **Step 5: Commit**

```bash
git add Muse/Muse/Filesystem/FileNameSplit.swift Muse/MuseTests/FileNameSplitTests.swift
git commit -m "feat: pure FileNameSplit (stem/ext split, recombine, validate) for file rename"
```

---

### Task 2: `FileMover.rename` disk primitive

**Files:**
- Modify: `Muse/Muse/Filesystem/FileMover.swift` (add `rename`, alongside `move` at `:14-35`)
- Test: `Muse/MuseTests/FileMoverRenameTests.swift` (new)

**Interfaces:**
- Consumes: nothing new (Foundation).
- Produces: `static func rename(_ url: URL, to newName: String) -> Result<URL, Void>` on `enum FileMover`. `.success(newURL)` with the renamed URL (or the unchanged URL for a no-op); `.failure(())` on collision (a different existing item) or an IO/permission error.

- [ ] **Step 1: Write the failing tests**

Create `Muse/MuseTests/FileMoverRenameTests.swift`:

```swift
//
//  FileMoverRenameTests.swift
//  MuseTests
//
//  Disk-level file rename primitive (in a temp dir): renames in place, refuses a
//  collision with a different file, allows a case-only change, no-ops same name.
//

import XCTest
@testable import Muse

final class FileMoverRenameTests: XCTestCase {
    private var tmp: URL!

    override func setUpWithError() throws {
        tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("FileMoverRenameTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    private func makeFile(_ name: String) throws -> URL {
        let u = tmp.appendingPathComponent(name)
        try Data("x".utf8).write(to: u)
        return u
    }

    func testRenamesInPlace() throws {
        let src = try makeFile("old.jpg")
        let dst = try XCTUnwrap(try? FileMover.rename(src, to: "new.jpg").get())
        XCTAssertEqual(dst.lastPathComponent, "new.jpg")
        XCTAssertFalse(FileManager.default.fileExists(atPath: src.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dst.path))
    }
    func testRefusesCollisionWithDifferentFile() throws {
        let src = try makeFile("a.jpg")
        _ = try makeFile("b.jpg")
        if case .success = FileMover.rename(src, to: "b.jpg") {
            XCTFail("expected collision failure")
        }
        // Source is untouched on refusal.
        XCTAssertTrue(FileManager.default.fileExists(atPath: src.path))
    }
    func testAllowsCaseOnlyRename() throws {
        let src = try makeFile("Photo.jpg")
        let dst = try XCTUnwrap(try? FileMover.rename(src, to: "photo.jpg").get())
        XCTAssertEqual(dst.lastPathComponent, "photo.jpg")
        XCTAssertTrue(FileManager.default.fileExists(atPath: dst.path))
    }
    func testSameNameIsNoopSuccess() throws {
        let src = try makeFile("same.jpg")
        let dst = try XCTUnwrap(try? FileMover.rename(src, to: "same.jpg").get())
        XCTAssertEqual(dst.standardizedFileURL, src.standardizedFileURL)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild -scheme Muse test -only-testing:MuseTests/FileMoverRenameTests`
Expected: FAIL — "type 'FileMover' has no member 'rename'".

- [ ] **Step 3: Write the implementation**

Add to `Muse/Muse/Filesystem/FileMover.swift`, inside `enum FileMover`, after `move` (`:34`):

```swift
    /// Rename `url` in place (same parent, new last component). No-op on the same
    /// name; a case-only change (Photo.jpg -> photo.jpg) is allowed, not treated
    /// as a self-collision. Refuses a collision with a DIFFERENT existing item
    /// (never overwrites) and reports any IO/permission failure. This is the ONLY
    /// sanctioned FileManager.moveItem for a rename — orchestration goes through
    /// AppState.renameFile so the DB migration always runs.
    static func rename(_ url: URL, to newName: String) -> Result<URL, Void> {
        let target = url.deletingLastPathComponent().appendingPathComponent(newName)
        if target.standardizedFileURL == url.standardizedFileURL { return .success(url) }
        let caseOnly = target.standardizedFileURL.path.lowercased()
            == url.standardizedFileURL.path.lowercased()
        if !caseOnly && FileManager.default.fileExists(atPath: target.path) {
            return .failure(())   // collision — don't overwrite
        }
        do {
            try FileManager.default.moveItem(at: url, to: target)
            return .success(target)
        } catch {
            NSLog("[Muse] file rename failed %@ -> %@: %@",
                  url.path, target.path, String(describing: error))
            return .failure(())
        }
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcodebuild -scheme Muse test -only-testing:MuseTests/FileMoverRenameTests`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add Muse/Muse/Filesystem/FileMover.swift Muse/MuseTests/FileMoverRenameTests.swift
git commit -m "feat: FileMover.rename disk primitive (collision-safe, case-only allowed)"
```

---

### Task 3: Same-dir migration confirmation test

**Files:**
- Test: `Muse/MuseTests/FileMoveMigrationTests.swift:` (add one test to the existing file)

**Interfaces:**
- Consumes: `FileMoveMigration.apply(_ db:, moves:)` (`FileMoveMigration.swift:25`) — unchanged.
- Produces: nothing (a guard test only).

This task adds NO production code — it pins the claim (verified by reading
`FileMoveMigration.swift:26-47`) that a same-directory rename repoints the path
row and leaves the `(file_id, parent_dir)` tags in place, so `renameFile` (Task 4)
can reuse `apply` verbatim.

- [ ] **Step 1: Write the failing test**

Add to `Muse/MuseTests/FileMoveMigrationTests.swift` inside `final class FileMoveMigrationTests`:

```swift
    func testSameDirRenameRepointsPathAndKeepsTagsInPlace() throws {
        let q = try freshQueue()
        try q.write { db in
            try db.execute(sql: "INSERT INTO files (id, content_hash, kind, last_seen_at) VALUES ('f1','h1','image',0)")
            try db.execute(sql: "INSERT INTO paths (id, file_id, absolute_path, is_alive) VALUES ('p1','f1','/a/old.png',1)")
            try db.execute(sql: "INSERT INTO tags (id, file_id, label, source, confidence, parent_dir) VALUES ('t1','f1','blue','manual',NULL,'/a')")

            // A rename is a move whose destination dir equals the source dir.
            try FileMoveMigration.apply(db, moves: [(from: "/a/old.png", to: "/a/new.png")])
        }
        try q.read { db in
            XCTAssertEqual(try String.fetchOne(db, sql: "SELECT absolute_path FROM paths WHERE id='p1'"), "/a/new.png")
            // Same parent dir -> the tag row is untouched (not duplicated, not moved).
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM tags WHERE file_id='f1' AND parent_dir='/a' AND label='blue' AND source='manual'"), 1)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM tags WHERE file_id='f1'"), 1)
        }
    }
```

- [ ] **Step 2: Run the test to verify it passes (guard, not red→green)**

Run: `xcodebuild -scheme Muse test -only-testing:MuseTests/FileMoveMigrationTests`
Expected: PASS — confirms `apply` already handles the same-dir case. (If it FAILS, stop: the reuse assumption in Task 4 is wrong and the spec must be revisited before proceeding.)

- [ ] **Step 3: Commit**

```bash
git add Muse/MuseTests/FileMoveMigrationTests.swift
git commit -m "test: pin same-dir rename reuses FileMoveMigration.apply (path repoint, tags stay)"
```

---

### Task 4: `AppState.renameFile` orchestration + request/error state

**Files:**
- Create: `Muse/Muse/Models/AppState+FileOps.swift`
- Modify: `Muse/Muse/Models/AppState.swift` (add two `@Published` near `:379`/`:381`)

**Interfaces:**
- Consumes: `FileNameSplit.split`/`.validate` (Task 1); `FileMover.rename` (Task 2); `FileMoveMigration.apply` (`FileMoveMigration.swift:25`); `AppState.reloadAfterMove(failed:)` (`AppState.swift:984`); `AnalyzePipeline.shared.exportSidecarsAfterTagEdit(for:)` (`AppState.swift:975`); `Database.shared.dbQueue`; `FileNode` (`kind`, `basename`, `url`).
- Produces: `@Published var fileRenameRequest: FileNode?`; `@Published var fileRenameError: String?`; `func requestRenameFile(_ node: FileNode)`; `func renameFile(_ node: FileNode, to newStem: String)`.

- [ ] **Step 1: Add the stored state to AppState core**

In `Muse/Muse/Models/AppState.swift`, immediately after `@Published var folderRenameRequest: FolderNode?` (`:379`):

```swift
    /// A pending FILE-rename modal target (single file). Seeds the rename field's
    /// stem draft; mirrors folderRenameRequest for folders.
    @Published var fileRenameRequest: FileNode?
```

and after `@Published var folderOpError: String?` (`:381`):

```swift
    /// User-facing file-rename error (collision / invalid name / IO). Drives a
    /// one-button alert; nil when dismissed.
    @Published var fileRenameError: String?
```

- [ ] **Step 2: Write the orchestration extension**

Create `Muse/Muse/Models/AppState+FileOps.swift`:

```swift
//
//  AppState+FileOps.swift
//  Muse
//
//  In-app FILE rename. A rename is a KNOWN relocation (a move whose destination
//  dir equals the source dir with a new basename), so it routes through the same
//  migration seam as moveFiles: disk rename OFF-MAIN via FileMover.rename, then
//  FileMoveMigration.apply (reused verbatim — the same-dir case repoints the path
//  row and leaves the (file_id, parent_dir) tags in place), then reloadAfterMove.
//  The extension is LOCKED (only the base name is editable); collision REFUSES.
//

import Foundation

@MainActor
extension AppState {

    /// Present the rename modal for `node` (files only — a folder card routes to
    /// requestRenameFolder). The alert seeds its local draft with the file's stem
    /// (basename minus locked extension) on open; see FileRenameAlert.
    func requestRenameFile(_ node: FileNode) {
        guard node.kind != .folder else { return }
        fileRenameRequest = node
    }

    /// Rename `node` on disk to `newStem` + its LOCKED extension, then migrate the
    /// path row + carry tags/memberships (FileMoveMigration) and reload. Refuses a
    /// name collision (names the file) and an invalid name; never overwrites.
    func renameFile(_ node: FileNode, to newStem: String) {
        let (_, ext) = FileNameSplit.split(node.basename)
        let full: String
        switch FileNameSplit.validate(stem: newStem, ext: ext, originalName: node.basename) {
        case .failure(let e):
            fileRenameError = Self.renameMessage(for: e)
            return
        case .success(let name):
            full = name
        }
        // No-op: same name, nothing to do.
        guard full != node.basename else { return }

        let target = node.url.deletingLastPathComponent().appendingPathComponent(full)
        // Collision refusal (owner: name the file, never overwrite / auto-suffix).
        // Allow a case-only change (Photo.jpg -> photo.jpg) on a case-insensitive
        // volume, which "collides with itself".
        let caseOnly = target.standardizedFileURL.path.lowercased()
            == node.url.standardizedFileURL.path.lowercased()
        if !caseOnly && FileManager.default.fileExists(atPath: target.path) {
            fileRenameError = String(localized: "A file named “\(full)” already exists in this folder.")
            return
        }

        Task { @MainActor in
            // Disk rename off-main (symmetric with moveFiles).
            let result = await Task.detached(priority: .userInitiated) {
                FileMover.rename(node.url, to: full)
            }.value
            guard case .success(let newURL) = result else {
                fileRenameError = String(localized: "Couldn’t rename the file.")
                return
            }
            let from = node.url.standardizedFileURL.path
            let to = newURL.standardizedFileURL.path
            if from != to, let queue = Database.shared.dbQueue {
                do {
                    try await queue.write { db in
                        try FileMoveMigration.apply(db, moves: [(from, to)])
                    }
                } catch {
                    // The disk rename already happened; a failed migration only
                    // degrades to external-move semantics (vision-only tag inherit
                    // after reconcile) — log it, don't fail the rename.
                    print("[AppState] rename DB migration failed: \(error)")
                }
                // Keep the iCloud sidecar current if the file lives in the zone
                // (no-op otherwise; same rule as moveFiles / every TagStore edit).
                AnalyzePipeline.shared.exportSidecarsAfterTagEdit(for: [newURL])
            }
            // Reuse the move tail: clears selection, dismisses a hero showing the
            // old path, re-resolves the active collection, reloads the folder.
            reloadAfterMove(failed: [])
        }
    }

    /// User-facing copy for a rename shape-validation failure.
    private static func renameMessage(for error: RenameNameError) -> String {
        switch error {
        case .empty:            return String(localized: "Please enter a name.")
        case .invalidCharacter: return String(localized: "A file name can’t contain “/” or “:”.")
        case .wouldHide:        return String(localized: "That name would hide the file. A name starting with a dot makes the file hidden.")
        }
    }
}
```

- [ ] **Step 3: Build to verify it compiles**

Run: `xcodebuild -scheme Muse build`
Expected: BUILD SUCCEEDED. (SourceKit cross-file "cannot find" noise is not a build error — trust the build.)

- [ ] **Step 4: Run the full suite to confirm nothing regressed**

Run: `xcodebuild -scheme Muse test`
Expected: PASS (existing 503+ plus Tasks 1-3's new tests). No new test in this task — `renameFile` is `@MainActor` + async + filesystem + DB orchestration, exercised end-to-end via the running-app verify in Task 6; its pure pieces (`FileNameSplit`, `FileMover.rename`, `FileMoveMigration`) are already unit-covered.

- [ ] **Step 5: Commit**

```bash
git add Muse/Muse/Models/AppState.swift Muse/Muse/Models/AppState+FileOps.swift
git commit -m "feat: AppState.renameFile — validate, collision-refuse, migrate via FileMoveMigration"
```

---

### Task 5: UI — context menu item, rename modal, error alert, accessibility

**Files:**
- Modify: `Muse/Muse/Views/GridView.swift` (context-menu item `~:355`; new `fileTileActions` helper near `:908`; apply it near `:391`)
- Modify: `Muse/Muse/ContentView.swift` (add `FileRenameAlert` modifier + `fileRenameError` alert)

**Interfaces:**
- Consumes: `appState.requestRenameFile(_:)`, `appState.renameFile(_:to:)`, `appState.fileRenameRequest`, `appState.fileRenameError` (Task 4); `FileNameSplit.split` (Task 1); `FileNode.id`/`.basename`/`.kind`.
- Produces: the visible Rename affordance (menu + accessibility + modal + error alert).

- [ ] **Step 1: Add the context-menu item (single-selection only)**

In `Muse/Muse/Views/GridView.swift`, inside the file-tile `.contextMenu`'s `if single {` block (`:355-363`), after `OpenWithMenu(url: file.url)` (`:356`):

```swift
                                Button("Rename…") { appState.requestRenameFile(file) }
```

(It renames the right-clicked `file`. `single` is already `!appState.selectedFiles.contains(p) || appState.selectedFiles.count <= 1`, so the item is absent when 2+ files are selected.)

- [ ] **Step 2: Add the `fileTileActions` accessibility helper**

In `Muse/Muse/Views/GridView.swift`, inside `private extension View` (after `folderCardActions`, `:933`):

```swift
    /// Adds Rename as a named VoiceOver action on FILE tiles (a no-op for folder
    /// cards, which carry their own folderCardActions). Gives the mouse-only
    /// right-click Rename a keyboard/VoiceOver-reachable parallel.
    @ViewBuilder
    func fileTileActions(_ isFile: Bool, rename: @escaping () -> Void) -> some View {
        if isFile {
            self.accessibilityAction(named: Text("Rename")) { rename() }
        } else {
            self
        }
    }
```

- [ ] **Step 3: Apply the helper on the tile**

In `Muse/Muse/Views/GridView.swift`, immediately after the `.folderCardActions(…)` modifier chain closes (`:408`, the closing `})`), add:

```swift
                    .fileTileActions(file.kind != .folder) {
                        appState.requestRenameFile(file)
                    }
```

- [ ] **Step 4: Add the `FileRenameAlert` modifier**

In `Muse/Muse/ContentView.swift`, after `CollectionRenameAlert` (`:865`), add:

```swift
/// The FILE rename prompt — same local-`@State` draft trick as the folder/
/// collection prompts so typing doesn't re-evaluate the whole ContentView. The
/// field holds only the STEM (base name); the locked extension is re-appended
/// inside AppState.renameFile. Seeded with the file's stem on open, keyed on the
/// request's `id` so re-targeting the same file re-seeds (closing passes nil).
private struct FileRenameAlert: ViewModifier {
    @EnvironmentObject private var appState: AppState
    @State private var draft = ""

    func body(content: Content) -> some View {
        content
            .alert("Rename File", isPresented: Binding(
                get: { appState.fileRenameRequest != nil },
                set: { if !$0 { appState.fileRenameRequest = nil } }
            )) {
                TextField("Name", text: $draft)
                Button("Rename") {
                    if let node = appState.fileRenameRequest {
                        appState.fileRenameRequest = nil
                        appState.renameFile(node, to: draft)
                    }
                }
                Button("Cancel", role: .cancel) { appState.fileRenameRequest = nil }
            } message: {
                let ext = FileNameSplit.split(appState.fileRenameRequest?.basename ?? "").ext
                Text(ext.isEmpty ? "Renames the file." : "The “\(ext)” extension is kept.")
            }
            .onChange(of: appState.fileRenameRequest?.id) { _, id in
                if id != nil {
                    draft = FileNameSplit.split(appState.fileRenameRequest?.basename ?? "").stem
                }
            }
    }
}
```

- [ ] **Step 5: Wire the modifier + error alert into the body**

In `Muse/Muse/ContentView.swift`, after `.modifier(CollectionRenameAlert())` (`:283`), add:

```swift
        .modifier(FileRenameAlert())
        .alert("Rename File", isPresented: Binding(
            get: { appState.fileRenameError != nil },
            set: { if !$0 { appState.fileRenameError = nil } }
        )) {
            Button("OK", role: .cancel) { appState.fileRenameError = nil }
        } message: {
            Text(appState.fileRenameError ?? "")
        }
```

- [ ] **Step 6: Build + run the full suite**

Run: `xcodebuild -scheme Muse build && xcodebuild -scheme Muse test`
Expected: BUILD SUCCEEDED; tests PASS.

- [ ] **Step 7: Commit**

```bash
git add Muse/Muse/Views/GridView.swift Muse/Muse/ContentView.swift
git commit -m "feat: file rename UI — context-menu item, rename modal, error alert, a11y action"
```

---

### Task 6: Localization (French) + running-app verification

**Files:**
- Modify: `Muse/Muse/Localizable.xcstrings` (write-back via export, then fill `fr`)

**Interfaces:**
- Consumes: all strings introduced in Tasks 4-5.
- Produces: a green French catalog (0 untranslated) + a verified runtime.

- [ ] **Step 1: Export localizations (write-back the new keys)**

Run:
```bash
xcodebuild -exportLocalizations -project Muse/Muse.xcodeproj \
  -localizationPath /tmp/muse-loc -exportLanguage fr
```
Expected: the export write-backs every new key into `Muse/Muse/Localizable.xcstrings`. New keys to expect (auto-extracted SwiftUI literals): `"Rename…"`, `"Rename File"`, `"Name"`, `"Rename"`, `"Cancel"`, `"OK"`, `"Rename"` (a11y), `"Renames the file."`, `"The “%@” extension is kept."`; and the hand-wrapped `String(localized:)` keys: `"A file named “%@” already exists in this folder."`, `"Couldn’t rename the file."`, `"Please enter a name."`, `"A file name can’t contain “/” or “:”."`, `"That name would hide the file. A name starting with a dot makes the file hidden."`.

- [ ] **Step 2: Fill the French values**

Edit `Muse/Muse/Localizable.xcstrings`, setting each new key's `fr` value (translated), e.g.:
- `"Rename…"` → `"Renommer…"`
- `"Rename File"` → `"Renommer le fichier"`
- `"Name"` → `"Nom"`
- `"Rename"` → `"Renommer"`
- `"Renames the file."` → `"Renomme le fichier."`
- `"The “%@” extension is kept."` → `"L’extension « %@ » est conservée."`
- `"A file named “%@” already exists in this folder."` → `"Un fichier nommé « %@ » existe déjà dans ce dossier."`
- `"Couldn’t rename the file."` → `"Impossible de renommer le fichier."`
- `"Please enter a name."` → `"Veuillez saisir un nom."`
- `"A file name can’t contain “/” or “:”."` → `"Un nom de fichier ne peut pas contenir « / » ni « : »."`
- `"That name would hide the file. A name starting with a dot makes the file hidden."` → `"Ce nom masquerait le fichier. Un nom commençant par un point rend le fichier invisible."`
(`"Cancel"`, `"OK"` already exist in the catalog — reuse; the export marks them translated.)

- [ ] **Step 3: Confirm the catalog is complete**

Re-run the export from Step 1; expected: it reports 0 untranslated for `fr`.

- [ ] **Step 4: Verify in the running app (repo rule — green tests are necessary but not sufficient)**

Build & run (Cmd+R or `xcodebuild -scheme Muse build` then launch the app). Point Muse at a test folder with a few files and confirm:
1. Right-click a single file tile → **Rename…** appears; right-click with 2+ selected → it's absent.
2. Rename `photo.jpg`: the field shows `photo` (extension hidden); commit `sunset` → the tile becomes `sunset.jpg`; the file is renamed on disk (verify in Finder / Reveal in Finder).
3. Multi-dot: `archive.tar.gz` → field shows `archive.tar`; commit `backup` → `backup.gz`... confirm the field shows `archive.tar` and only `.gz` is locked.
4. Collision: try renaming to a name that already exists → error alert names the conflicting file; nothing changes on disk.
5. Tags/collections carry: tag a file, add it to a collection, rename it → the renamed file keeps its tag and stays in the collection (open the collection; check the tag chip).
6. VoiceOver: the tile exposes a "Rename" action.
7. Launch French (`open -n <Muse.app> --args -AppleLanguages "(fr)"`): the menu item, modal, and errors read in French.

- [ ] **Step 5: Commit**

```bash
git add Muse/Muse/Localizable.xcstrings
git commit -m "i18n: French for file rename strings"
```

---

## Self-Review

**Spec coverage:**
- Pure split/recombine/validate + multi-dot + dotfile + trailing-dot edges → Task 1.
- Disk rename primitive, collision refusal, case-only allowance → Task 2 + Task 4 (collision copy).
- Migration reuse (same-dir) confirmed → Task 3; wired → Task 4.
- Modal reuse (local-`@State`, seed stem, keyed on id) → Task 5 Step 4.
- Context-menu single-selection entry point → Task 5 Step 1.
- Post-rename selection/collection/hero updates via `reloadAfterMove` → Task 4 Step 2.
- Accessibility parallel action → Task 5 Steps 2-3.
- Localization → Task 6.
- Error alert → Task 5 Step 5.

**Type consistency:** `FileNameSplit.split/recombine/validate` and `RenameNameError` (Task 1) are used identically in Tasks 4-5. `FileMover.rename(_:to:) -> Result<URL, Void>` (Task 2) is consumed in Task 4. `fileRenameRequest`/`fileRenameError`/`requestRenameFile`/`renameFile` (Task 4) are consumed in Task 5. No name drift.

**Placeholder scan:** every code step contains complete code; no TBD/"handle errors"/"similar to".

## Execution Handoff

**Plan complete and saved to `docs/superpowers/plans/2026-07-06-file-rename.md`. Two execution options:**

**1. Subagent-Driven (recommended)** — dispatch a fresh subagent per task, review between tasks.

**2. Inline Execution** — execute tasks in this session with checkpoints.

**Which approach?**
