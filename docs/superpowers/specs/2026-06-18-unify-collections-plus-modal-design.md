# Unify the Collections-page "+" with the Name-Collection Modal — Design

**Date:** 2026-06-18
**Status:** Approved (design); pending implementation
**Builds on:** `2026-06-18-name-collection-modal-design.md`

## Summary

Make the Collections-page **"+"** button create a collection through the same
**"Name Collection"** modal used by the grid's right-click "New Collection from
Selection". Today "+" creates an auto-named empty collection immediately; after
this change it opens the modal so the user names it, giving one consistent
create-a-collection experience.

## Scope

In scope: the Collections-page "+" button (`CollectionsPage.createCollection`).

Out of scope: the hero viewer's "add to a new collection" path
(`ViewerInfoColumn` → `CollectionStore.createManual(queue:name:fileID:)`). It
already has its own inline name field and single-file semantics; the user asked
only about the Collections-page "+".

## Behavior

- Click **"+"** on the Collections page → the **"Name Collection"** modal opens
  with an empty field (placeholder "Collection name"), **Create** (default) /
  **Cancel**.
- **Create** with a non-empty name → a new empty collection with that name
  appears as a card.
- **Cancel** or a blank/whitespace name → nothing is created.
- Right-click "New Collection from Selection" continues to work exactly as
  before (seeds the new collection with the selected images).

## Design

The "+" and the right-click share one modal and one confirm path. The only
generalization needed is that the confirm logic must create a collection even
when there is **no** selection (the "+" case).

### Unified create semantics

`confirmNewCollection()` becomes: **on a non-empty name, always create the named
collection; add the selected images only if there are any.** Dropping the
"refuse to create when the selection is empty" guard is what lets the "+" path
(empty selection) create an empty named collection, while leaving the
right-click path's normal case unchanged. It also makes the right-click path
more forgiving — a named, confirmed collection is created even if the selected
files don't resolve to indexed IDs, rather than silently doing nothing.

### `AppState+Filters.swift`

Make the request method's fallback optional and generalize confirm:

```swift
/// Open the "Name Collection" prompt. With a fallback path, seed the new
/// collection from the effective selection (grid right-click); with nil, create
/// an empty collection (Collections-page "+"). No DB write until confirm.
func requestNewCollection(fallback path: String? = nil) {
    pendingNewCollectionPaths = path.map { p in
        effectiveSelectionURLs(fallback: p).map { $0.standardizedFileURL.path }
    } ?? []
    newCollectionNameDraft = ""
    newCollectionRequest = true
}

/// Create a collection under the typed name. A blank name creates nothing.
/// Seeds it with the captured selection when there is one.
func confirmNewCollection() {
    let paths = pendingNewCollectionPaths
    let name = newCollectionNameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
    newCollectionRequest = false
    pendingNewCollectionPaths = []
    guard !name.isEmpty else { return }
    Task { @MainActor in
        guard let q = Database.shared.dbQueue else { return }
        guard let newID = try? await CollectionStore.createManual(queue: q) else { return }
        try? await CollectionStore.rename(queue: q, id: newID, name: name)
        if !paths.isEmpty {
            let ids = (try? await CollectionStore.fileIDs(queue: q, paths: paths)) ?? []
            for id in ids {
                try? await CollectionStore.addFile(queue: q, fileID: id, collectionID: newID)
            }
        }
        await CollectionsEngine.shared.reload()
    }
}
```

`cancelNewCollection()` is unchanged.

### `ContentView.swift`

Make the alert's message adaptive so it reads correctly for both entry points:

```swift
} message: {
    Text(appState.pendingNewCollectionPaths.isEmpty
         ? "Creates a new collection."
         : "Creates a collection from the selected images.")
}
```

(The title "Name Collection", the `TextField`, and the Create/Cancel buttons are
unchanged from the existing alert.)

### `CollectionsPage.swift`

Replace the body of `createCollection()` (which called `CollectionStore`
directly) with a call into the shared request:

```swift
private func createCollection() {
    appState.requestNewCollection()
}
```

The "+" `AddCollectionButton` and its "New Collection" tooltip are unchanged.

## Why this is safe and clean

- **One modal, one confirm path** for all general collection creation — the
  unification the request asks for.
- **No new store API, no schema change.** Reuses `createManual` + `rename` +
  `addFile` exactly as the right-click path already does.
- **Prompt-first preserved.** No DB write happens until Create with a non-empty
  name, so Cancel/blank still creates nothing from either entry point.
- **Hero-viewer create path untouched** — it keeps its own inline naming UI.

## Reused building blocks (already present)

| Function | File | Purpose |
|----------|------|---------|
| `effectiveSelectionURLs(fallback:)` | `AppState+Selection.swift` | Resolve single-tile vs. multi-selection |
| `CollectionStore.createManual(queue:)` | `CollectionStore.swift` | Create manual collection, returns new ID |
| `CollectionStore.rename(queue:id:name:)` | `CollectionStore.swift` | Rename a collection |
| `CollectionStore.fileIDs(queue:paths:)` | `CollectionStore.swift` | Resolve paths → file IDs (alive only) |
| `CollectionStore.addFile(queue:fileID:collectionID:)` | `CollectionStore.swift` | Add a file to a collection |
| `CollectionsEngine.shared.reload()` | `CollectionsEngine.swift` | Refresh collections UI |
| "Name Collection" `.alert` | `ContentView.swift` | The modal (added in the prior spec) |

## Testing / verification

- Collections page → "+" → modal appears empty; type a name + Create → a new
  empty collection card with that exact name appears.
- "+" → Cancel → no collection created.
- "+" → Create with a blank field → no collection created.
- Right-click "New Collection from Selection" still seeds the collection with the
  selected images and still names via the modal.
- The modal message reads "Creates a new collection." from "+" and "Creates a
  collection from the selected images." from a selection.
- `xcodebuild -scheme Muse build` and the full `test` suite stay green.
- Verify in the running app.
