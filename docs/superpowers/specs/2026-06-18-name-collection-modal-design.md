# Name-it Modal for "New Collection from Selection" — Design

**Date:** 2026-06-18
**Status:** Approved (design); pending implementation
**Builds on:** `2026-06-18-new-collection-from-selection-design.md`

## Summary

Add a name prompt to the right-click **"New Collection from Selection"** action.
After choosing it, the user gets a modal — the same native `.alert` pattern used
by the sidebar's **Rename Folder** dialog — to type the new collection's name.

Because Cancel must discard the collection entirely (user decision), the flow is
**prompt-first**: nothing is written to the database until the user confirms a
non-empty name. This avoids a create-then-delete dance and any stray
hidden-tombstone rows.

## User decisions

- **Text field default:** Empty, with a greyed **"Collection name"** placeholder.
  The user types the name they want (no pre-filled auto name to clear).
- **On Cancel / blank name:** Discard entirely. No collection is created; no DB
  write happens.

## Behavior

1. Right-click a selection (or a single tile) → **"New Collection from
   Selection"**. This captures the effective selection's file paths immediately
   (preserving the right-clicked-but-unselected-tile case), sets an empty name
   draft, and raises the modal. **No DB write yet.**
2. Modal: title **"Name Collection"**, an empty `TextField` with placeholder
   **"Collection name"**, **Create** (default — Return confirms) and **Cancel**.
3. **Create** with a non-empty name → create the collection, rename it to the
   typed name, add the captured images, reload.
4. **Cancel** or a blank/whitespace-only name → clear pending state, do nothing.

## Design

Mirror the folder-rename modal: native SwiftUI `.alert` in `ContentView`, driven
by `AppState` flags. Heavy lifting lives in `AppState` (as `renameFolder` does),
not the view.

### `AppState.swift` — state (next to `folderRenameRequest` / `folderNameDraft`)

```swift
@Published var newCollectionRequest = false        // presentation flag for the modal
@Published var newCollectionNameDraft = ""         // TextField binding
var pendingNewCollectionPaths: [String] = []       // captured at request time (stored; non-published)
```

`pendingNewCollectionPaths` must be a stored property on the class — Swift
extensions can't add stored properties — so it lives in `AppState.swift` even
though the methods below live in the extension.

### `AppState+Filters.swift` — actions (with the other collection methods)

```swift
/// Open the name prompt for a new collection built from the effective selection.
func requestNewCollection(fallback path: String) {
    pendingNewCollectionPaths = effectiveSelectionURLs(fallback: path)
        .map { $0.standardizedFileURL.path }
    newCollectionNameDraft = ""
    newCollectionRequest = true
}

/// Create the collection from the captured selection under the typed name.
/// A blank name or empty selection creates nothing.
func confirmNewCollection() {
    let paths = pendingNewCollectionPaths
    let name = newCollectionNameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
    newCollectionRequest = false
    pendingNewCollectionPaths = []
    guard !name.isEmpty, !paths.isEmpty else { return }
    Task { @MainActor in
        guard let q = Database.shared.dbQueue else { return }
        let ids = (try? await CollectionStore.fileIDs(queue: q, paths: paths)) ?? []
        guard !ids.isEmpty else { return }
        guard let newID = try? await CollectionStore.createManual(queue: q) else { return }
        try? await CollectionStore.rename(queue: q, id: newID, name: name)
        for id in ids {
            try? await CollectionStore.addFile(queue: q, fileID: id, collectionID: newID)
        }
        await CollectionsEngine.shared.reload()
    }
}

/// Dismiss the prompt without creating anything.
func cancelNewCollection() {
    newCollectionRequest = false
    pendingNewCollectionPaths = []
    newCollectionNameDraft = ""
}
```

Capturing `paths`/`name` into locals before clearing the published state means the
alert's auto-dismiss (which also calls `cancelNewCollection` via the binding
setter) can't race the in-flight create — same safety the folder-rename path
relies on.

### `ContentView.swift` — the alert (beside the Rename-Folder alert)

```swift
.alert("Name Collection", isPresented: Binding(
    get: { appState.newCollectionRequest },
    set: { if !$0 { appState.cancelNewCollection() } }
)) {
    TextField("Collection name", text: $appState.newCollectionNameDraft)
    Button("Create") { appState.confirmNewCollection() }
    Button("Cancel", role: .cancel) { appState.cancelNewCollection() }
} message: {
    Text("Creates a collection from the selected images.")
}
```

### `SelectionMenu.swift` — the trigger

```swift
Button("New Collection from Selection") { appState.requestNewCollection(fallback: path) }
```

The previous `newCollectionFromSelection()` helper (which created the collection
immediately) is removed — the create now happens in `confirmNewCollection()`.

## Why this is safe and clean

- **Prompt-first = nothing on Cancel.** No DB write occurs unless the user
  confirms a non-empty name, so Cancel/blank genuinely creates nothing — no
  orphan, no `setHidden` tombstone, no wasted auto-name number.
- **Reuses existing, tested store functions** — `createManual` (atomic
  auto-name + insert, `model_version='manual'`), `CollectionStore.rename` (plain
  UPDATE), `addFile`, `CollectionsEngine.reload`. No new store API.
- **Consistent with the app.** Modal mirrors Rename Folder; duplicate collection
  names are allowed exactly as the existing inline collection-rename allows them
  (no uniqueness check); validation is just non-empty, matching `commitRename` in
  `CollectionsRow`.
- **Selection captured at request time** so the right-clicked-but-unselected-tile
  case and any later selection change can't corrupt which files go in.

## Reused building blocks (already present)

| Function | File | Purpose |
|----------|------|---------|
| `effectiveSelectionURLs(fallback:)` | `AppState+Selection.swift` | Resolve single-tile vs. multi-selection |
| `CollectionStore.fileIDs(queue:paths:)` | `CollectionStore.swift` | Resolve paths → file IDs (alive only) |
| `CollectionStore.createManual(queue:)` | `CollectionStore.swift` | Create manual collection, returns new ID |
| `CollectionStore.rename(queue:id:name:)` | `CollectionStore.swift` | Rename a collection (plain UPDATE) |
| `CollectionStore.addFile(queue:fileID:collectionID:)` | `CollectionStore.swift` | Add a file to a collection |
| `CollectionsEngine.shared.reload()` | `CollectionsEngine.swift` | Refresh collections UI |
| `.alert(... TextField ...)` Rename-Folder pattern | `ContentView.swift` | The modal pattern being mirrored |

## Testing / verification

- Right-click a single image → modal appears empty with the placeholder; type a
  name + Create → a collection with that exact name contains that one image.
- Multi-select → Create → the named collection contains all selected images.
- Cancel → no collection created (Collections page unchanged).
- Create with a blank/whitespace name → no collection created.
- Return key in the field triggers Create (it's the default button).
- Existing "Add to Collection" and folder-rename behavior unchanged.
- `xcodebuild -scheme Muse build` and the full `test` suite stay green.
- Verify in the running app (drive the real app).
