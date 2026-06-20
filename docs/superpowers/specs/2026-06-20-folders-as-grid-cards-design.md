# Folders as Grid Cards — design

**Date:** 2026-06-20
**Status:** Approved (brainstorm complete)
**Ships as:** its own branch (`feat/next-41`)

## Summary

Show a folder's immediate **subfolders as cards in the grid** (and count them), so
Muse matches Finder instead of silently dropping folders. Today the grid and the
sidebar file count are **files-only**: `FolderReader.files()` and
`enumerateRecursive()` skip plain directories, and `FolderStats.compute` counts
only non-folders — so a folder with 34 files + 4 subfolders shows **34** in Muse
but **38** in Finder. This makes folders first-class grid tiles (Adobe-Bridge-like):
they render as standard file cards (native macOS folder icon), sort first, count
toward the total, and **double-click navigates into them** exactly like clicking
the subfolder in the sidebar.

The "show subfolders" toggle keeps its current meaning — it controls whether you
see folder **contents** — so folder cards appear only in the one-level (toggle OFF)
view.

## Behavior

### What shows, per the subfolders toggle

- **Toggle OFF (default, one level):** grid shows immediate files **+ immediate
  subfolders as folder cards**. Count = files + folders (e.g. 38).
- **Toggle ON (recursive):** grid shows the flattened recursive **files only**, no
  folder cards (unchanged from today — you're viewing contents). Count = recursive
  file count (unchanged).

### Ordering — folders first

Folder cards always sort **before** files, each group ordered by the active sort
mode + direction (folders stay grouped on top even when the sort is reversed,
mirroring Finder). Implemented as a pure, stable partition applied after the
existing `SmartSorter.apply` (so per-group order is whatever the sort produced).

### Folder card appearance

Folder tiles reuse the **existing non-image file-card rendering unchanged**
(`GridView`'s `cardIcon` + caption path). A `.folder` `FileNode` already maps to
the native macOS folder icon via `ThumbnailCache`'s QuickLook `.all` request (same
path as zip/PDF/dmg cards), with the SF-symbol `"folder"` only as the loading
fallback. The filename caption (the **Show file names** toggle position) and the
**mood-contrast text color** (`cardNameColor` / `SelectionStyle.relativeLuminance`)
come for free. Works in masonry and all fixed-ratio Image Layouts (folder cards use
the same default aspect as other non-image cards).

### Interaction

Folder tiles behave like every other grid tile for *selection*, and navigate on
open:

- **Single-click** selects the folder tile (selection ring), same mechanism as a
  file (`applyClick(.single/.toggle/.range)`).
- **Double-click** (the grid's "select, then click to open" gesture) **navigates
  into the folder** — calls `AppState.select(folder:)` — instead of setting
  `selectedFile` (no hero/viewer, no back button). This matches how images/files
  open in the grid; the sidebar stays one-click (unchanged).

### Sidebar follows

Navigating into a subfolder from a grid card **auto-expands the sidebar tree to
reveal that subfolder and highlights it**, exactly as if it had been clicked in
the sidebar. Two supporting changes:

- A new `AppState` navigation entry (e.g. `openSubfolder(url:)`) that finds the
  containing root, expands each ancestor down to the target
  (`loadChildrenIfNeeded` + `isExpanded = true`), locates the matching `FolderNode`
  (extending the existing `findNode(withURL:)` to load along the path), and calls
  `select(folder:)`.
- `SidebarView.isSelected` matches by **URL** (`selectedFolder?.url ==
  node.url`, standardized) rather than by `FolderNode.id`, so a folder navigated
  from the grid highlights its sidebar row even if a fresh node instance is used.
  The existing cross-folder suppression rules (Collections page / inside a
  collection / All-scope search hide the highlight) are preserved.

### Folders stay out of file-only flows

A folder is not a taggable/collectable file, so:

- **Add to Collection / Add Tag / Share / New Collection from Selection** operate
  only on the **non-folder** members of the selection; if the effective selection
  is folders-only, those actions are hidden/disabled.
- **Reveal in Finder** works on a folder.
- **Out of scope for v1:** dragging a folder card to move it (no `.onDrag` on
  folder tiles), and folder cards in **search results** or the **Collections
  page** — folders appear only in normal folder browsing. (Search results and
  collection members are files by construction, so this needs no extra guard; the
  folder cards come solely from the folder-browse read.)

## Architecture & data flow

### Reads (`AppState.reloadCurrentFiles` + `FolderReader`)

`reloadCurrentFiles` branches:
```swift
let raw = showSub
    ? Self.enumerateRecursive(at: folderURL, showHidden: showHid)   // files only (unchanged)
    : FolderReader.files(in: folderURL, showHidden: showHid, includeFolders: true)
```
- `FolderReader.files` gains `includeFolders: Bool = false` (default keeps any
  other callers unchanged). When true, plain directories are emitted as
  `FileNode(url:, kind: .folder)` instead of being dropped at the
  `if isDir && !isPackage { return nil }` guard. Opaque bundles still count as
  files (Q33).
- `enumerateRecursive` is **unchanged** (recursive view stays files-only).

### Ordering (new pure helper)

```swift
nonisolated enum FolderOrdering {
    /// Stable-partition: all `.folder` nodes (in their given order) before all
    /// others (in their given order). Caller passes an already-sorted list, so
    /// each group keeps the active sort+direction.
    static func foldersFirst(_ nodes: [FileNode]) -> [FileNode]
}
```
Applied right after the existing sort in `reloadCurrentFiles`:
```swift
let sorted = SmartSorter.apply(mode, to: merged, reversed: reversed)
let ordered = FolderOrdering.foldersFirst(sorted)   // no-op when no folders (recursive view)
```

### Counts (`FolderStat` / `FolderStats.compute`)

- **immediateFileCount → includes folders.** Count every non-hidden immediate
  entry (files + packages + plain folders), i.e. drop the `!isPlainDirectory`
  exclusion for the immediate tally. This makes the toggle-OFF sidebar count match
  the OFF grid (38). Update the doc comment (it currently says "every non-folder
  entry").
- **recursiveFileCount → unchanged** (still skips plain dirs), matching the
  toggle-ON grid (recursive files, no folder tiles).
- `SidebarView` already shows `showSubfolders ? recursiveFileCount :
  immediateFileCount`, so no sidebar-count call-site change is needed — the
  redefinition flows through.

### Interaction (`GridView.handleTileTap`)

Branch the double-click case on kind:
```swift
if lastTapPath == p, now - lastTapAt < window {
    lastTapPath = nil
    if file.kind == .folder { appState.openSubfolder(file.url) }   // navigate
    else { appState.selectedFile = file }                          // open viewer
    return
}
// single-click selection path is identical for files and folders (applyClick)
```
The folder tile's `.onDrag` is omitted (guard on `file.kind != .folder`).

### Selection-actions filtering

`SelectionActionsMenu` / `effectiveSelectionURLs` (used by Add to Collection / Tag
/ Share / New Collection) filter out `.folder` paths; the menu items hide/disable
when the resulting file set is empty. (Reveal in Finder is unaffected.)

## Files (touch list)

- `Filesystem/FolderTree.swift` — `FolderReader.files(includeFolders:)`.
- `Models/AppState.swift` — pass `includeFolders: true` in the non-recursive read;
  apply `FolderOrdering.foldersFirst`; new `openSubfolder(url:)` (expand path +
  `select(folder:)`); extend `findNode(withURL:)` to load along the path.
- `Filesystem/FolderStat.swift` — immediate count includes folders (+ comment).
- `Views/GridView.swift` — `handleTileTap` folder branch; omit `.onDrag` for
  folders. (Card rendering already handles `.folder`.)
- `Views/SidebarView.swift` — `isSelected` matches by URL.
- `Views/SelectionMenu.swift` (+ `AppState+Selection.effectiveSelectionURLs`) —
  exclude folders from file-only actions.
- New `Models/FolderOrdering.swift` (pure) + tests.

## Testing

Pure logic is unit-tested (project convention); views/navigation are integration.

- **`FolderOrderingTests`** (new, pure): folders-first stable partition — folders
  precede files; per-group order preserved; all-files and all-folders and empty
  inputs; mixed order stable.
- **`FolderStat` count test** (extend existing stat tests): a fixture folder with N
  files + M subfolders → `immediateFileCount == N + M`, `recursiveFileCount`
  counts files only. (Use a temp dir fixture.)
- **Manual / integration** (no unit test — view + nav): open a folder containing
  subfolders → grid shows folder cards first, sidebar count matches Finder;
  double-click a folder card → navigates in, no back button, the subfolder is
  revealed + highlighted in the sidebar; single-click selects the tile; turning the
  subfolders toggle ON hides folder cards and shows recursive files; a folder card
  shows the native folder icon + caption with correct mood contrast; selecting a
  folder + files and using Add to Collection/Tag/Share acts only on the files.

## Notes / rationale

- Reusing the non-image file-card path means folder cards inherit the icon,
  caption, Show-file-names, mood-contrast, and layout behaviors with no new tile
  view — the bulk of the visual requirement is free.
- Folders-first + folder-inclusive immediate count keep the **grid and the sidebar
  number in agreement** in each toggle state (the existing FolderStat contract),
  now including folders in the one-level view.
- URL-based sidebar highlight is the minimal way to make grid-initiated navigation
  light up the right row without threading the exact `FolderNode` instance through
  the grid.
