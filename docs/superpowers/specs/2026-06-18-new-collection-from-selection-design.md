# New Collection from Selection — Design

**Date:** 2026-06-18
**Status:** Approved (design); pending implementation plan

## Summary

Add a right-click (context menu) action that creates a **new** collection from the
currently selected image(s). This complements the existing "Add to Collection"
action, which only adds the selection to an *existing* collection. The feature is
purely additive — no existing behavior changes.

New collections are auto-named using the existing `"Collection N"` framework, so
no new naming logic is introduced.

## User decisions

- **Menu placement:** A separate top-level menu item, `"New Collection from
  Selection"`, placed immediately after the existing `"Add to Collection"`
  submenu (a sibling, not nested inside it).
- **After create:** Stay put — create the collection silently and reload. No view
  navigation. This matches the existing Collections-page "+" button behavior.

## Scope

- **One file touched:** `Muse App/Muse/Muse/Views/SelectionMenu.swift`
  (the `SelectionActionsMenu` view).
- **~12 lines added.** No model, schema, `CollectionStore`, `GridView`, or
  selection-logic changes.

## Design

### Menu change

In `SelectionActionsMenu.body`, immediately after the existing
`Menu("Add to Collection") { … }`, add one button:

```swift
Button("New Collection from Selection") { newCollectionFromSelection() }
```

It appears for both a single right-clicked image and a multi-selection, reusing
the same `urls` computed property (which calls
`appState.effectiveSelectionURLs(fallback: path)`), exactly like the existing
"Add to Collection" item.

### Action

A new private method composes two functions that already exist — no new storage
logic:

```swift
private func newCollectionFromSelection() {
    let paths = urls.map { $0.standardizedFileURL.path }
    Task { @MainActor in
        guard let q = Database.shared.dbQueue else { return }
        let ids = (try? await CollectionStore.fileIDs(queue: q, paths: paths)) ?? []
        guard !ids.isEmpty else { return }   // don't create an empty collection on a failed lookup
        let newID = try await CollectionStore.createManual(queue: q)  // auto-names "Collection N"
        for id in ids {
            try? await CollectionStore.addFile(queue: q, fileID: id, collectionID: newID)
        }
        await CollectionsEngine.shared.reload()
    }
}
```

## Why this is safe and clean

- **Auto-naming reuses the existing framework.** `CollectionStore.createManual`
  already calls `ManualCollectionName.next(...)` inside an atomic GRDB write
  transaction, producing `"Collection 1"`, `"Collection 2"`, … with no collision
  risk under concurrent creation. Nothing new to build.
- **No navigation, no view-state changes.** The action ends with
  `CollectionsEngine.shared.reload()`, identical to today's "+" button flow.
- **One guard the existing add-to-collection path lacks:** if path→fileID
  resolution yields nothing, bail instead of creating an empty collection.

## Reused building blocks (already present)

| Function | File | Purpose |
|----------|------|---------|
| `effectiveSelectionURLs(fallback:)` | `AppState+Selection.swift` | Resolve single-tile vs. multi-selection |
| `CollectionStore.fileIDs(queue:paths:)` | `CollectionStore.swift` | Resolve paths → file IDs (alive only) |
| `CollectionStore.createManual(queue:)` | `CollectionStore.swift` | Create empty manual collection, auto-named, returns new ID |
| `ManualCollectionName.next(existing:)` | `CollectionStore.swift` | `"Collection N"` naming |
| `CollectionStore.addFile(queue:fileID:collectionID:)` | `CollectionStore.swift` | Add a file to a collection, clear exclusions |
| `CollectionsEngine.shared.reload()` | `CollectionsEngine.swift` | Refresh collections UI |

## Testing / verification

- Right-click a single unselected image → "New Collection from Selection" creates
  a new `"Collection N"` containing exactly that image.
- Select several images, right-click → new collection contains all selected
  images.
- New collection's name follows the `"Collection N"` sequence (next available N).
- Existing "Add to Collection" behavior is unchanged.
- Verify in the running app (drive the real app, compare against expectations).
