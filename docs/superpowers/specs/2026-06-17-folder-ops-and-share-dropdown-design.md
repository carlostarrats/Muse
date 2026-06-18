# Folder operations + hero Share dropdown — design

Date: 2026-06-17
Branch: `feat/folder-ops-and-share`

## Goal

A grab-bag of file/folder management additions, each small but a few with
real data-model implications:

1. **Hero Share → dropdown.** The hero viewer's Share button becomes a menu
   offering **Share** and **Open With**, mirroring the in-collection
   `ShareCollectionButton` dropdown the user pointed at.
2. **New Subfolder.** Right-click a sidebar folder → create a real subfolder
   inside it on disk. Top-level (root) creation stays add-existing-only via the
   **+ Add Folder** button — there is deliberately no "new empty folder at the
   top level."
3. **Rename Folder.** Right-click any user folder → rename it on disk, with the
   index + tags migrated so nothing is orphaned.
4. **Menu-bar equivalents** for the new actions (keyboard / VoiceOver reach).
5. **Info modal** refresh + enlarge to cover everything added since it was last
   written.
6. **Verify** the grid right-click Open With (it already exists — no rebuild).

All work is local-first, sandbox-safe, no network. Decisions locked with the
user up front:

- **Naming UX:** dialog prompts (matches the existing "Rename Tag…" / "Rename
  Collection…" flows), not Finder-style inline edit.
- **Rename scope:** every user folder — roots included — **except** the fixed,
  app-managed iCloud "Muse" home.
- **Rename data:** migrate the DB (path prefixes + tag parent-dir keys) so
  manual tags, collections, and analysis all survive the rename.

## Task 0 — verify grid Open With (no new code expected)

`GridView`'s tile context menu already renders `OpenWithMenu(url:)` for a
single-image effective selection (`Open`, `Reveal in Finder`, `Open With ▸`),
and `GridView` is the shared grid for the main, tag-filtered, and in-collection
views — so all three already have it. The Collections *page* shows collection
cover cards, not images, so Open With does not apply there. Confirm during
implementation; no rebuild planned.

## Task 1 — hero Share dropdown

`Views/Viewer/ShareButton.swift`. Convert the single `Button` into a `Menu`,
styled exactly like `ShareCollectionButton` (`.menuStyle(.button)`,
`.menuIndicator(.hidden)`, `.buttonStyle(.plain)`, `.fixedSize()`), keeping the
existing 38pt white-glass circle and `square.and.arrow.up` icon so the chrome
is visually unchanged at rest.

Menu items:

- **Share** — the existing `NSSharingServicePicker(items: [url])` call.
- **Open With ▸** — submenu: **Open** (`NSWorkspace.open`), **Reveal in
  Finder**, a divider, then each registered app from
  `OpenWithMenu.applications(for: url)` (loaded in a `.task(id: url)`).

Operates on `currentURL`. The app list is `@State private var apps: [URL]`.
No behavior change to the share path itself.

## Task 2 — New Subfolder

### Filesystem

New `Filesystem/FolderOps.swift` (pure, `nonisolated` where possible):

```
enum FolderOps {
    enum OpError: Error { case emptyName, invalidName, collision, ioError }

    /// Create a subfolder. Trims the name; rejects empty, "/" or ":" in the
    /// name, and an existing child of the same name. Returns the new URL.
    static func createSubfolder(named raw: String, in parent: URL) -> Result<URL, OpError>

    /// Rename a folder in place (same parent, new last component). Same
    /// validation + collision check. Returns the new URL. Does NOT touch the DB
    /// — the caller migrates the DB after a successful disk rename.
    static func rename(_ folder: URL, to raw: String) -> Result<URL, OpError>
}
```

Roots already hold read-write security scope for the app's lifetime
(`BookmarkStore`), so `createDirectory` / `moveItem` inside them needs no
per-op scope.

### Sidebar wiring

- `FolderNode` gains `reloadChildren()` — re-reads immediate children even when
  `isLoaded` (the existing `loadChildrenIfNeeded` is guarded and would skip a
  freshly created folder). Implementation = reset `isLoaded`, clear, reload.
- `FolderTreeNode`'s context menu gains **"New Subfolder…"** (shown for every
  folder, including the iCloud "Muse" root — users may nest there). It sets
  `appState.newSubfolderRequest = node` (a request, so the same path serves the
  menu-bar command).
- A single host on `ContentView` presents an `.alert("New Subfolder", …)` with
  a `TextField`. On confirm: call `FolderOps.createSubfolder`; on success
  `node.reloadChildren()`, set `node.isExpanded = true`, and `select` the new
  child; on failure show an error alert.

No top-level creation path is added.

## Task 3 — Rename Folder

### Disk + DB

`FolderOps.rename` does the disk move first. Only on success does the caller run
a DB migration in one `queue.write` transaction:

- **`paths.absolute_path`** — for every row whose path equals `oldPath` or
  starts with `oldPath + "/"`, replace that prefix with `newPath`.
- **`tags.parent_dir`** — same prefix rewrite. This is the load-bearing step:
  tags are keyed `(file_id, parent_dir)`, so without it the renamed folder's
  files would lose their manual tags.
- **Collections, FTS, analysis** are keyed by `file_id` (content hash) — not by
  path — so they need no migration and survive automatically.

Prefix matching uses `SUBSTR(col, 1, LENGTH(:old)+1) = :old || '/'` (plus an
exact `col = :old` case), **not** `LIKE`, so paths containing `%` or `_` can't
break the match, and a sibling like `…/AB` is never caught by a rename of
`…/A`. The rewrite itself is `:new || SUBSTR(col, LENGTH(:old)+1)`.

The pure rewrite (old prefix, new prefix, input path) → output path is factored
into a tiny testable function (`FolderRenameMigration.rewrite(path:old:new:)`)
so the prefix logic is unit-tested independent of SQLite; the GRDB UPDATEs
apply the same rule in SQL.

### Sidebar + roots

- `FolderTreeNode` context menu gains **"Rename Folder…"** for every folder
  **except** the iCloud "Muse" home (`node.url == appState.iCloudFolderURL`).
  Sets `appState.folderRenameRequest = node`.
- The same `ContentView` host presents an `.alert` with a `TextField`
  pre-filled with the current name. On confirm: `FolderOps.rename` → DB
  migration → refresh the sidebar.
- **Root rename:** the security-scoped bookmark is inode-based and survives a
  same-volume rename, so access is retained. We update `Root.displayName` (the
  node renders the root's stored displayName) via a new
  `BookmarkStore.setDisplayName(_:for:)` and `rebuildRootNodes()`; if a resolve
  reports `bookmarkDataIsStale`, refresh the stored bookmark data.
- **Subfolder rename:** `reloadChildren()` on the parent node so the row shows
  the new name (the node's `url`/`displayName` are `let`, so the node is
  rebuilt by the reload).
- If the renamed/affected folder is the currently selected folder, reload the
  listing so the grid's live URLs are correct.
- Failure (e.g. a protected system folder) → graceful error alert; nothing is
  partially applied (disk rename precedes the DB migration; on disk failure the
  DB is untouched).

## Task 4 — menu-bar equivalents

`MuseApp` Edit-menu folder block (`CommandGroup(after: .pasteboard)`, beside
Pin / Remove):

- **New Subfolder…** — enabled when a folder is selected; sets
  `newSubfolderRequest` to the selected folder.
- **Rename Folder…** — enabled when a folder is selected and it is not the
  iCloud home; sets `folderRenameRequest`.

Both reuse the AppState request + `ContentView` host (one dialog
implementation, used by context menu and menu command alike).

File menu also gains **Open** and **Open With ▸** for the selected single image
(the menu-bar equivalent of the grid/hero Open With), gated on a single
selected file.

## Task 5 — Info modal

`Views/InfoSheet.swift`. Enlarge to roughly 600×720. Update/extend the copy to
reflect features added since it was written:

- **Library & folders:** add, **New Subfolder**, **Rename**, drag-to-reorder,
  pin, remove.
- **Selecting & acting on images:** multi-select (click / ⌘-click / shift),
  and the right-click actions — move to folder, add to collection, add tag,
  share, Open With.
- **Viewing / sharing:** the hero Share dropdown (Share + Open With), Reveal in
  Finder.
- **Grid options:** show file names, column density.
- **Search:** All vs This Folder scope.
- **Sort:** modes + the direction toggle.
- **Collections:** auto + hand-made (the **+** on the Collections page).
- **Preferences:** the auto-tag / auto-collections opt-outs.
- **Fix** the stale Updates line ("it asks first") — the consent prompt was
  removed; background checks are silent.

## Testing

- `FolderOpsTests` — name trim/validation (empty, "/" , ":"), collision det
  (pure checks where possible without touching disk; disk-touching paths use a
  temp dir).
- `FolderRenameMigrationTests` — the pure prefix rewrite: exact match, nested
  child, sibling-prefix non-match (`…/A` vs `…/AB`), and a path containing
  `%`/`_`.

View/menu wiring is manual-verified, consistent with the repo's convention
(pure logic + stores are unit-tested; SwiftUI views are not).

## Out of scope

- Inline (Finder-style) rename — explicitly rejected in favor of dialogs.
- Top-level "new empty folder" creation.
- Renaming the iCloud "Muse" home.
- Any change to the share *transfer* mechanism (still `NSSharingServicePicker`).
