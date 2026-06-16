# Multi-select + selection actions — design

**Date:** 2026-06-16
**Status:** Design (pending implementation plan)

## Goal

Introduce image selection in the grid and the actions that hang off it:
multi-select with the standard macOS gestures, a selection-aware right-click
menu (add to an existing collection, add an existing tag, share), drag-to-move
onto sidebar folders, and a "Reveal in Finder" item on sidebar folders.

All four pieces are additive UI wiring over plumbing that already exists
(`CollectionStore.addFile`, `TagStore.addManualTag`, read-write folder
bookmarks, `NSWorkspace`/`NSSharingServicePicker`). Nothing changes the
indexing, analysis, or collection-clustering models.

## 1. Selection model

**Gestures (grid tiles):**
- **Single click** — select only that image (replaces the current selection).
- **Cmd-click** — toggle that image in/out of the selection.
- **Shift-click** — select the range from the anchor to the clicked tile, in
  grid order.
- **Double-click** — open that specific image in the hero viewer (independent
  of selection; only ever one image opens — the one double-clicked).

Selection feels immediate on the first click (Finder-like) — it does not wait
out the double-click interval. Modifier state is read from
`NSEvent.modifierFlags` at click time; click-count distinguishes single vs
double. (The exact AppKit click-handler mechanism is chosen in the plan; the
requirement is: immediate selection, double-click opens, no perceptible lag —
note the project previously removed a double-tap recognizer for exactly this
lag, so the plan must avoid the naive `onTapGesture(count:1)+(count:2)`
disambiguation delay.)

**State (`AppState`):**
- `@Published var selectedFiles: Set<String>` — standardized file paths
  (stable across re-enumeration; the grid keys on path, not the per-enumeration
  `FileNode.id`).
- `@Published var selectionAnchor: String?` — anchor path for range selection.
- `selectedFile: FileNode?` keeps its current meaning: the image **open** in
  the hero viewer (set by double-click). Selection and "what's open" are
  separate concerns.
- Methods: `selectOnly(_:)`, `toggleSelection(_:)`, `selectRange(to:)`
  (computes the inclusive range over `visibleFiles` order between anchor and
  target), `clearSelection()`.
- Selection clears on folder switch, collection switch, tag switch, and search
  scope change (wherever the grid's file set changes).

**Visual:** selected tiles get an accent-colored border (and a subtle scrim or
checkmark badge) so the picked set is obvious. Exact treatment tuned in a
visual pass; default is a 2pt accent `RoundedRectangle` stroke matching the
active-collection card highlight already used in `CollectionCard`.

**Pure logic (testable):** range computation (ordered list + anchor + target →
set of paths) and toggle/replace logic live in a small pure helper
(`GridSelection`) so they're unit-tested without UI.

## 2. Selection-aware right-click menu

The tile context menu acts on the **effective selection**:
`selectedFiles.contains(path) ? selectedFiles : [path]`. Right-clicking a tile
that isn't selected first selects just it (so the menu and a subsequent action
agree with what's highlighted).

Menu items (in addition to today's):
- **Add to Collection** → submenu of existing collections (from
  `CollectionsEngine.collections`, alphabetical). Choosing one calls
  `CollectionStore.addFile(fileID:collectionID:)` for each selected file
  (paths → `file_id` via the existing path lookup). Manual adds already survive
  re-clustering.
- **Add Tag** → submenu of existing tag labels. Choosing one calls
  `TagStore.addManualTag(label:for:)` for each selected URL. (Manual tags beat
  vision tags, per the invariant.)
- **Share** → `NSSharingServicePicker` with the selected image URLs (one or
  many).

Existing items remain: **Open With…** and **Set as Collection Cover** show only
when exactly one image is selected (inherently single-image). **Move to Trash**
applies to the whole effective selection via the existing delete coordinator.

Empty states: submenus show a disabled "No collections" / "No tags" row when
there are none. (Creating a *new* collection/tag from a selection is explicitly
out of scope — add-to-existing only.)

## 3. Drag images → sidebar folder = move

- Grid tiles become draggable (`.onDrag`). The drag payload is the dragged
  file's URL. At drop time the destination resolves the **set to move**: if the
  dragged file is part of `selectedFiles`, move the whole selection; otherwise
  move just the dragged file. (SwiftUI's per-view `onDrag` vends one provider;
  reading the selection at drop time is how one drag moves many.)
- Every sidebar folder row (roots, subfolders, pinned) gains a file-URL drop
  target that **moves** each file into that folder via
  `FileManager.moveItem(at:to:)` under security-scoped access. This is separate
  from the existing root-reorder drop (`RootDropDelegate`, which uses `.text`);
  the new target accepts `.fileURL` and routes by payload type so both coexist.
- **Permissions:** moving requires read-write access to BOTH the source and
  destination folders. The app already uses read-write bookmarks (established
  for move-to-Trash); folders added before that change must be re-added. A drop
  onto a non-writable / unresolved destination is rejected with a brief error.
- **Edge cases:** dropping onto the file's current folder is a no-op; a
  name collision or move failure surfaces a non-blocking alert naming what
  failed (successful files still move); the index reconciles moved files by
  content hash (path updates), and the affected folders refresh.

## 4. Reveal in Finder (sidebar)

Add **Reveal in Finder** to the sidebar folder context menus (root and pinned),
next to "Remove Folder":
`NSWorkspace.shared.activateFileViewerSelecting([node.url])`.

## File / component map

- **Modify** `Models/AppState.swift` — selection state + methods; clear on
  scope changes.
- **Create** `Components/GridSelection.swift` (pure range/toggle logic) + test.
- **Modify** `Views/GridView.swift` (`TileView`) — click handling (select/open),
  selection highlight, `.onDrag`, selection-aware `contextMenu` with the new
  submenus.
- **Create** `Views/SelectionMenu.swift` (or inline) — the Add-to-Collection /
  Add-Tag / Share submenu builders, reused by the tile menu.
- **Modify** `Views/SidebarView.swift` — file-URL move drop on folder rows +
  "Reveal in Finder" menu item.
- **Create** `Filesystem/FileMover.swift` — `move(urls:to:)` with
  security-scoped access, collision/error reporting.
- Reuse: `CollectionStore.addFile`, `TagStore.addManualTag`,
  `DeleteCoordinator`, `NSSharingServicePicker`.

## Testing

- `GridSelectionTests` — single-replace, cmd-toggle, shift-range over an ordered
  list (including anchor reset, range crossing direction, out-of-list targets).
- `FileMover` move logic is verified by build + manual run (filesystem I/O).

## Build order

1. Selection model + gestures + highlight (foundation).
2. Selection-aware menu (collection / tag / share).
3. Drag-to-move onto sidebar folders.
4. Reveal in Finder.

## Out of scope

- Creating a new collection/tag from a selection (add-to-existing only).
- Copy-on-drag (move only).
- Selecting non-image files for these actions (selection is image-grid only;
  the actions target images).
- Marquee/rubber-band selection (gesture-click selection only).
