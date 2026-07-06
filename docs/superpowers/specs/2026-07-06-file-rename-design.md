# In-app file rename — design spec

**Date:** 2026-07-06
**Branch context:** off `feat/next-115` (clean, `main`-equivalent)
**Source:** `docs/perf-and-feature-review-2026-07-03.md` Part 2, item 1 ("File
rename") — the binding owner design. All owner decisions below are copied from
that doc plus the delegated open-decision resolutions; none are re-litigated
here.
**Scope:** rename a single FILE from the grid tile's right-click context menu.
Folders already rename (`FolderOps.rename` + `AppState.renameFolder`); this
feature does NOT touch folders.

---

## Problem

Folders can be renamed in-app (sidebar/folder-card context menu →
`FolderOps.rename`, incl. the root parent-grant flow), but files cannot. For the
generalist Downloads/Documents persona this is the most conspicuous gap: a user
who wants `IMG_4821.jpg` to read `Invoice — March.jpg` has to leave Muse, do it
in Finder, and let the indexer reconcile the change as an *external* move (which
inherits vision tags only, not manual tags).

The hard part — carrying the file's manual tags, its manual collection
memberships, and its DB identity across the on-disk rename — is already solved
for in-app moves by `FileMoveMigration` (`Muse/Muse/Filesystem/FileMoveMigration.swift`).
A rename is a move whose destination directory equals the source directory with
a new basename, so it reuses that exact machinery.

---

## The pure basename/extension split logic (isolate + unit-test first)

Owner decision: **the base name ONLY is editable; the extension is LOCKED.** This
sidesteps `AssetKind` reclassification entirely (no `.jpg`→`.png`), so the only
runtime edge case owner acknowledged is name-collision — but the *split itself*
has three edge cases that must be pinned by unit tests before any UI exists.

This logic touches no filesystem and no DB. It lives in a new pure type
`FileNameSplit` (`Muse/Muse/Filesystem/FileNameSplit.swift`) so it is unit-testable
in isolation (mirrors how `FolderOps.sanitize` is a pure, tested seam).

### `split(_ name:) -> (stem: String, ext: String)`

`ext` is the **last dot-suffix INCLUDING its leading dot**, or `""` when there is
no extension. `stem` is everything before it. `name` is a file's
`lastPathComponent` (never a path).

Rule: find the LAST `.` in `name`.
- **No `.`** → `(name, "")`. (`README` → `("README", "")`.)
- **The last `.` is at index 0** (leading-dot dotfile, no other dot) →
  `(name, "")` — the whole name is the editable stem, no extension.
  (`.gitignore` → `(".gitignore", "")`.)
- **The last `.` is the final character** (trailing dot, empty suffix) →
  `(name, "")` — nothing after the dot is not an extension.
  (`foo.` → `("foo.", "")`.)
- **Otherwise** → split at the last dot: `stem` = substring before it, `ext` =
  `"." + <suffix>`.
  - `photo.jpg` → `("photo", ".jpg")`.
  - **Multi-dot** `archive.tar.gz` → `("archive.tar", ".gz")` — ONLY the last
    suffix is the extension (owner-specified).

### `recombine(stem:ext:) -> String`

Returns `stem + ext` (the locked `ext` re-appended). No trimming here — trimming
is validation's job. `recombine("archive.tar", ".gz")` → `"archive.tar.gz"`.

**Accepted behavior (not a bug):** if the user types a dot into the stem
(`photo` → `photo.png`), `recombine("photo.png", ".jpg")` → `"photo.png.jpg"`.
The REAL extension is still `.jpg` (the last suffix), so `AssetKind` never
reclassifies — the "extension locked" guarantee holds; the typed dot is just part
of the base name. No special handling.

### `validate(stem:ext:originalName:) -> Result<String, RenameNameError>`

Shape validation only (collision needs the filesystem — checked at the AppState
layer, see below). Returns the final full name on success.

```
enum RenameNameError: Error, Equatable { case empty, invalidCharacter, wouldHide }
```

Rules, on the recombined final name `full = recombine(trimmedStem, ext)` where
`trimmedStem = stem.trimmingCharacters(in: .whitespacesAndNewlines)`:
- `trimmedStem.isEmpty` → `.empty` (an empty stem with any ext is still empty).
- `full.contains("/") || full.contains(":")` → `.invalidCharacter` (`:` is the
  legacy HFS separator Finder also forbids — same rule as `FolderOps.sanitize`).
- `full.hasPrefix(".")` AND `!originalName.hasPrefix(".")` → `.wouldHide`. A
  non-hidden file must not be renamed into a hidden one (it would vanish from the
  grid, which loads `showHidden: false` — same reasoning `FolderOps.sanitize`
  rejects leading-dot folders). A file that was ALREADY a dotfile (`.gitignore`)
  keeps its leading dot — the user is editing an existing hidden file, so allow
  it.
- Otherwise → `.success(full)`.

> **Contradiction flag (see final report):** the review doc says "the ONLY
> remaining edge case is name-collision." Reading the real code, two more
> shape edges exist and MUST be handled — the leading-dot/hidden case above, and
> the case-only rename below. Neither changes the owner's design; they're gaps
> the "only collision" framing understated.

---

## UI — modal reuse

Owner decision: **reuse the collection-rename modal's UI (`NameCollectionAlert` /
`CollectionRenameAlert` look + the local-`@State` draft pattern), NOT its
behavior.** A collection rename just changes a DB label; a file rename performs a
real on-disk rename, handles a name collision, and routes the relocation through
`FileMoveMigration`.

New `ViewModifier` `FileRenameAlert` in `ContentView.swift`, mirroring
`CollectionRenameAlert` (`ContentView.swift:840-865`) and `FolderNameAlerts`
(`ContentView.swift:875-918`):

- Local `@State private var draft = ""` — **never** bind the `TextField` to an
  `@Published` on `AppState` (per the CLAUDE.md TextField rule: each keystroke
  fires `AppState.objectWillChange`, re-evaluating the whole `ContentView`).
- Presented via `Binding(get: { appState.fileRenameRequest != nil }, set: …)`.
- On open, seed `draft` with the **stem** (not the full name) keyed on the
  request's `id`, exactly like the folder/collection alerts:
  `.onChange(of: appState.fileRenameRequest?.id) { _, id in if id != nil {
  draft = FileNameSplit.split(appState.fileRenameRequest?.basename ?? "").stem } }`.
  Closing always passes through nil first, so re-targeting the same file
  re-seeds (`FileNode.id` is a stable `UUID`).
- Title: `"Rename File"`. Field: `TextField("Name", text: $draft)`.
- Message: shows the LOCKED extension so the user understands what's preserved —
  `Text` with the extension interpolated (auto-localizes). When there is no
  extension, a plain "Renames the file." (see localization).
- Buttons: `Button("Rename") { … }` (commits) and
  `Button("Cancel", role: .cancel) { appState.fileRenameRequest = nil }`.
- On Rename: capture the request, clear it, then call
  `appState.renameFile(request, to: draft)` (the recombine with the locked
  extension happens INSIDE `renameFile`, which re-splits the original basename —
  the alert only ever holds the stem draft).

### Entry point

Owner decision: **"Rename…" on the FILE tile's right-click context menu,
SINGLE-selection only.** No File-menu item (mirrors folder rename being
context-menu-only).

In `GridView.swift` the file-tile branch of `.contextMenu` (`GridView.swift:347-384`)
already computes `let single = !appState.selectedFiles.contains(p) ||
appState.selectedFiles.count <= 1`. Add the Rename button INSIDE the existing
`if single { … }` block (`GridView.swift:355-363`), alongside `OpenWithMenu`:

```swift
Button("Rename…") { appState.requestRenameFile(file) }
```

`single` is true when the right-clicked tile is not part of a multi-selection (or
the selection is ≤ 1), so Rename is present exactly when it targets one file and
absent when 2+ are selected — matching the owner's "rename targets one file."
It always renames the right-clicked `file` (a concrete `FileNode`), never an
ambiguous selection. Folders keep their own branch (`GridView.swift:327-346`,
"Rename Folder…") — untouched.

### Accessibility

Owner blanket rule: every mouse-only interaction needs a parallel
`.accessibilityAction`. The context menu is VoiceOver-reachable, but to match the
folder tiles' named-action treatment, add a `fileTileActions` helper mirroring
`folderCardActions` (`GridView.swift:908-934`):

```swift
@ViewBuilder
func fileTileActions(_ isFile: Bool, rename: @escaping () -> Void) -> some View {
    if isFile {
        self.accessibilityAction(named: Text("Rename")) { rename() }
    } else {
        self
    }
}
```

applied on the tile with `.fileTileActions(file.kind != .folder) {
appState.requestRenameFile(file) }`. Named actions are VoiceOver-operable
without the double-click/right-click a bare gesture needs.

---

## Migration routing (the DB seam)

Owner decision: **rename is a KNOWN relocation → route through the same migration
seam class as `AppState.moveFiles` / `FileMoveMigration`, NEVER a bare
`FileManager.moveItem`.**

**Verified in code:** `FileMoveMigration.apply(_ db:, moves:)`
(`FileMoveMigration.swift:25-64`) already handles a same-directory rename
correctly, with NO change needed:
- It repoints the alive `paths.absolute_path` row from `from` to `to`
  (`:35-43`) — exactly what a rename needs.
- It pre-kills any stale alive row sitting at `to` (`:31-33`) so the repoint
  can't trip `paths_alive_unique`.
- For a same-dir rename `oldDir == newDir`, so the `guard oldDir != newDir else
  { continue }` at `:47` correctly SKIPS tag re-scoping — the `(file_id,
  parent_dir)` tag rows stay valid because the parent dir is unchanged. Manual
  collection memberships are keyed on `file_id` (not path), so they carry for
  free.

So the DB follow-through is `FileMoveMigration.apply` reused **verbatim** with a
single `(from, to)` whose two paths share a parent directory.

`AppState.moveFiles(_ urls:into:)` (`AppState.swift:948-980`) cannot be reused
directly: it takes a destination FOLDER and hard-codes the source's
`lastPathComponent` as the new name (`FileMover.move`,
`FileMover.swift:20`) — it has no way to express a new basename. Per the owner's
"spec a thin sibling entry point that reuses the SAME migration machinery," add:

### `FileMover.rename(_ url:to newName:) -> Result<URL, Void>` (disk primitive)

Parallel to `FileMover.move` (`FileMover.swift:14-35`) — a thin `FileManager`
wrapper that is the ONE sanctioned disk-rename call (so callers never touch
`FileManager.moveItem` bare, satisfying the CLAUDE.md invariant):

- `target = url.deletingLastPathComponent().appendingPathComponent(newName)`.
- No-op guard: if `target.standardizedFileURL == url.standardizedFileURL` →
  `.success(url)`.
- **Case-only rename guard** (mirrors `FolderOps.rename` `:90-96` and its
  `testRenameCaseOnly`): on the default case-insensitive volume, `photo.jpg` →
  `Photo.jpg` "collides with itself." Compute `caseOnly =
  target.path.lowercased() == url.path.lowercased()`; only refuse on
  `fileExists(atPath: target.path)` when `!caseOnly`. Collision → `.failure(())`.
- `try FileManager.default.moveItem(at: url, to: target)` → `.success(target)`;
  any throw → `.failure(())`.

Roots already hold read-write security scope for the app's lifetime
(`BookmarkStore`), and a FILE rename writes to the file's own parent directory,
which IS in scope (unlike a ROOT-folder rename, which writes the root's parent —
that's why folders need the parent-grant flow and files do NOT). So no
`NSOpenPanel` grant is ever needed for a file rename.

### `AppState.renameFile(_ node:to newStem:)` (orchestration)

New method in a small `AppState+FileOps.swift` (methods only; stored state stays
in `AppState.swift` core, per the codebase convention). Structured like
`moveFiles` (`AppState.swift:948-980`):

1. Split the original basename to get the LOCKED extension:
   `let (_, ext) = FileNameSplit.split(node.basename)`.
2. `FileNameSplit.validate(stem: newStem, ext: ext, originalName: node.basename)`
   — on `.failure`, set `fileRenameError` to the localized copy for that case and
   return (no disk touch).
3. On `.success(full)`: no-op check — if `full == node.basename`, just dismiss
   (nothing to do).
4. **Collision check** (owner: REFUSE, name the conflicting file, never
   overwrite / never auto-suffix): `target = node.url.deletingLastPathComponent()
   .appendingPathComponent(full)`. If `full` is NOT a case-only variant of
   `node.basename` and `FileManager.default.fileExists(atPath: target.path)`,
   set `fileRenameError = String(localized: "A file named “\(full)” already
   exists in this folder.")` and return.
5. Disk rename OFF-MAIN (a rename is intra-volume and fast, but keep the pattern
   symmetric with `moveFiles`, which goes off-main because a cross-volume move
   copies bytes): `let result = await Task.detached { FileMover.rename(node.url,
   to: full) }.value`. On `.failure`, set `fileRenameError = String(localized:
   "Couldn’t rename the file.")` and return.
6. DB follow-through, reusing the move seam verbatim:
   ```swift
   let from = node.url.standardizedFileURL.path
   let to   = newURL.standardizedFileURL.path
   try await queue.write { db in
       try FileMoveMigration.apply(db, moves: [(from, to)])
   }
   ```
   Wrapped in the same do/catch as `moveFiles` (`AppState.swift:962-971`): a
   failed migration only degrades to external-move semantics after the next
   reconcile — log it, don't fail the rename (the disk change already happened).
7. `AnalyzePipeline.shared.exportSidecarsAfterTagEdit(for: [newURL])` — keep the
   iCloud sidecar current if the file lives in the iCloud zone (no-op otherwise;
   same rule `moveFiles` follows at `:975-976`).
8. `reloadAfterMove(failed: [])` — see next section.

### `AppState.requestRenameFile(_ node:)`

Trivial presenter (mirrors `requestRenameFolder`, `AppState+FolderOps.swift:24-26`):
`fileRenameRequest = node`. Guard it to files only (`node.kind != .folder`) so a
folder card can never route here.

New stored state on `AppState.swift` core:
- `@Published var fileRenameRequest: FileNode?` (near `folderRenameRequest`,
  `AppState.swift:379`).
- `@Published var fileRenameError: String?` (near `folderOpError`,
  `AppState.swift:381`).

---

## Collision handling

Owner-delegated resolution: **if the target name already exists in the folder,
REFUSE with an error alert whose message names the conflicting file. NEVER
overwrite, NEVER auto-append a suffix.** Consistent with Muse never destroying
data.

Two-layer check (defense against TOCTOU):
1. `renameFile` checks `fileExists(atPath: target.path)` (step 4 above) and
   surfaces a named-file alert BEFORE any disk touch.
2. `FileMover.rename` re-checks at the actual move and returns `.failure` if the
   file appeared in the gap (→ generic "Couldn't rename the file." alert).

Both respect the case-only exception so `photo.jpg` → `Photo.jpg` is a legit
rename, not a self-collision (verified against `FolderOps.rename`'s identical
guard + `FolderOpsTests.testRenameCaseOnly`).

Error alert in `ContentView.swift`, mirroring the folder error alert
(`ContentView.swift:266-273`):

```swift
.alert("Rename File", isPresented: Binding(
    get: { appState.fileRenameError != nil },
    set: { if !$0 { appState.fileRenameError = nil } }
)) {
    Button("OK", role: .cancel) { appState.fileRenameError = nil }
} message: {
    Text(appState.fileRenameError ?? "")
}
```

The user dismisses and retries (the modal is already closed; they reopen Rename
and pick a different name).

---

## Selection / collection / viewer updates (post-rename)

Owner-delegated resolution: the path changes, so `visibleFiles` / `currentFiles`
and (if a collection is open) `activeCollectionFiles` / `activeCollectionPaths`
must update.

**Verified in code:** `reloadAfterMove(failed:)` (`AppState.swift:984-1002`)
already does ALL of this and is reused verbatim:
- `clearSelection()` (`:985`) — the rename narrowed nothing, but the old path is
  now stale in the selection `Set`, so clearing is correct and matches the CLAUDE.md
  "any input that changes paths prunes selection" spirit.
- Dismisses the hero viewer if its open file no longer exists at its old path
  (`:988-991`) — a renamed open file's old URL is gone, so the viewer closes
  rather than showing a broken image. (Rename is invoked from the grid, so the
  hero is typically closed anyway; this is the safe fallback.)
- Re-resolves the active collection via `setActiveCollection(cid, animated:
  false)` (`:995-997`) — re-reads member paths + reachability so a renamed tile
  isn't a ghost in `activeCollectionFiles`/`Paths` (which the grid, share, and
  PDF-export flows read).
- `reloadCurrentFilesPublic()` (`:998`) — re-enumerates the folder (the renamed
  file re-appears under its new name) and re-indexes.

Because the collection membership is keyed on `file_id` and `FileMoveMigration`
repointed the path row while preserving identity, the renamed file stays in every
collection it was in — the reload just re-resolves it under the new path.

---

## Accessibility + localization

- **Accessibility:** parallel `.accessibilityAction(named: Text("Rename"))` via
  the `fileTileActions` helper (above), so the rename is reachable without a
  right-click.
- **Localization (French ships — every new user-facing string wrapped):**
  - Auto-extracted SwiftUI text-literal positions (no manual wrapping): the
    context-menu `Button("Rename…")`, the alert titles `"Rename File"`, the
    field `TextField("Name", …)`, `Button("Rename")`, `Button("Cancel")`,
    `Button("OK")`, and the accessibility `Text("Rename")`.
  - Hand-wrapped `String(localized:)` (built from runtime values / returned as
    `String`): every `fileRenameError` message —
    `String(localized: "A file named “\(full)” already exists in this folder.")`,
    `String(localized: "Couldn’t rename the file.")`, and the three
    `RenameNameError` → copy mappings (empty / invalid character / would-hide),
    e.g. `String(localized: "A file name can’t contain “/” or “:”.")` (reuse the
    folder wording pattern), `String(localized: "Please enter a name.")`,
    `String(localized: "That name would hide the file. Renaming a file to start
    with a dot hides it.")`.
  - The alert message showing the locked extension is a `Text` with interpolation
    (auto-localizes the format string): `Text(ext.isEmpty ? "Renames the file."
    : "The “\(ext)” extension is kept.")`.
  - Workflow: wrap literals → `xcodebuild -exportLocalizations -project
    Muse/Muse.xcodeproj -localizationPath <dir> -exportLanguage fr` (write-backs
    every key into `Localizable.xcstrings`) → fill the empty `fr` values → confirm
    0 untranslated. No storage strings change (rename touches paths, which stay
    canonical; no translated string is ever persisted).

---

## Invariants preserved (do NOT break)

- **No bare `FileManager.moveItem` in a caller.** The only new `moveItem` call is
  inside `FileMover.rename` (the sanctioned disk primitive, parallel to
  `FileMover.move`); orchestration goes through `AppState.renameFile`, which runs
  `FileMoveMigration` — satisfying "in-app relocations go through the migration
  seam."
- **`FileMoveMigration.apply` is reused unchanged** — no new DB code path; the
  same-dir case is already correct (path repoint, tag re-scope skipped, membership
  by `file_id`).
- **TextField draft is local `@State`** in `FileRenameAlert`, never bound to
  `AppState` (CLAUDE.md TextField rule).
- **Extension locked** — no `AssetKind` reclassification; the last dot-suffix is
  preserved and re-appended.
- **Never destroy data** — collision refuses (names the file), never overwrites,
  never auto-suffixes; files are never `unlink`ed.
- **Selection / collection / hero updated** via the existing `reloadAfterMove`.
- **Folders untouched** — the folder-card branch keeps its own "Rename Folder…"
  and parent-grant flow; `requestRenameFile` guards `kind != .folder`.
- **Localized** — French kept green.

---

## Out of scope (explicitly)

- **Editing the extension** (`.jpg`→`.png`) — owner-locked; would open the
  `AssetKind` reclassification path. Not this feature.
- **Batch / multi-select rename** — owner: rename targets one file; the menu item
  is single-selection only. (The review doc lists "batch rename" as DROPPED.)
- **Renaming folders** — already shipped (`FolderOps.rename`); this feature does
  not modify it.
- **A File-menu / menu-bar rename command** — owner: context-menu only, mirroring
  folder rename.
- **Reclassifying / re-Visioning on rename** — the content hash is unchanged, so
  no re-analysis; the reload re-enumerates under the new path only.
