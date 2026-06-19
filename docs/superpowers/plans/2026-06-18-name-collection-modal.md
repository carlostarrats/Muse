# Name-it Modal for "New Collection from Selection" Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the immediate "create on right-click" behavior of "New Collection from Selection" with a prompt-first flow that asks the user to name the collection in a modal, mirroring the sidebar's Rename-Folder alert.

**Architecture:** Capture the effective selection's file paths at right-click time and raise a native SwiftUI `.alert` in `ContentView`, driven by `AppState` flags. The collection is created only when the user confirms a non-empty name (`AppState.confirmNewCollection`); Cancel or a blank name writes nothing. Reuses existing `CollectionStore` functions (`createManual` + `rename` + `addFile`) — no new store API.

**Tech Stack:** Swift, SwiftUI, AppKit, GRDB (SQLite). macOS app target `Muse`.

## Global Constraints

- Min macOS 14.6; GRDB writes/reads are async (`try await queue.write/read`).
- `AppState` is `@MainActor`; UI mutations stay on the main actor.
- Files are never deleted from disk; this feature only writes DB rows.
- Duplicate collection names are allowed (consistent with existing inline collection rename — no uniqueness check). Validation is non-empty only.
- SourceKit "Cannot find type X in scope" errors are cross-file noise — verify with `xcodebuild`, not the editor.
- Build dir: `cd "/Users/carlostarrats/Documents/Projects/Muse/Muse App/Muse"`. Repo root for git: `/Users/carlostarrats/Documents/Projects/Muse/Muse App`.

---

### Task 1: Prompt-first name modal for new collections

**Files:**
- Modify: `Muse/Muse/Models/AppState.swift` (add 3 state members near `folderRenameRequest`/`folderNameDraft`)
- Modify: `Muse/Muse/Models/AppState+Filters.swift` (add `requestNewCollection` / `confirmNewCollection` / `cancelNewCollection`)
- Modify: `Muse/Muse/ContentView.swift` (add the `.alert` beside the Rename-Folder alert)
- Modify: `Muse/Muse/Views/SelectionMenu.swift` (button calls `appState.requestNewCollection(fallback:)`; remove the old `newCollectionFromSelection()` helper)

**Interfaces:**
- Consumes (all already exist):
  - `AppState.effectiveSelectionURLs(fallback path: String) -> [URL]`
  - `CollectionStore.fileIDs(queue: DatabaseQueue, paths: [String]) async throws -> [String]`
  - `CollectionStore.createManual(queue: DatabaseQueue) async throws -> String`
  - `CollectionStore.rename(queue: DatabaseQueue, id: String, name: String) async throws`
  - `CollectionStore.addFile(queue: DatabaseQueue, fileID: String, collectionID: String) async throws`
  - `CollectionsEngine.shared.reload() async`
  - `Database.shared.dbQueue: DatabaseQueue?`
- Produces:
  - `AppState.newCollectionRequest: Bool` (@Published)
  - `AppState.newCollectionNameDraft: String` (@Published)
  - `AppState.pendingNewCollectionPaths: [String]` (stored)
  - `AppState.requestNewCollection(fallback path: String)`
  - `AppState.confirmNewCollection()`
  - `AppState.cancelNewCollection()`

- [ ] **Step 1: Add the modal state to `AppState.swift`**

Find the existing folder-modal state (search for `folderRenameRequest` and `folderNameDraft`) and add these three members immediately after `folderNameDraft`:

```swift
    /// Presentation flag for the "Name Collection" modal (new-collection-from-
    /// selection). The collection is created only on confirm — see
    /// confirmNewCollection() in AppState+Filters.
    @Published var newCollectionRequest = false
    /// Bound to the modal's TextField; starts empty (placeholder shown).
    @Published var newCollectionNameDraft = ""
    /// File paths captured at right-click time, created into a collection on
    /// confirm. Stored (not @Published) — extensions can't add stored props.
    var pendingNewCollectionPaths: [String] = []
```

- [ ] **Step 2: Add the actions to `AppState+Filters.swift`**

Add these three methods inside the `extension AppState { … }` (with the other collection methods):

```swift
    /// Open the "Name Collection" prompt for a new collection built from the
    /// effective selection. Captures the paths now (preserves the right-clicked-
    /// but-unselected-tile case); no DB write happens until confirm.
    func requestNewCollection(fallback path: String) {
        pendingNewCollectionPaths = effectiveSelectionURLs(fallback: path)
            .map { $0.standardizedFileURL.path }
        newCollectionNameDraft = ""
        newCollectionRequest = true
    }

    /// Create the collection from the captured selection under the typed name.
    /// A blank/whitespace name or an empty selection creates nothing.
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

- [ ] **Step 3: Add the `.alert` to `ContentView.swift`**

Find the existing Rename-Folder alert (search for `.alert("Rename Folder"`). Add this alert immediately after that alert's closing (after its `} message: { Text(...) }` block), as a sibling modifier on the same view:

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

- [ ] **Step 4: Point the menu button at the request method in `SelectionMenu.swift`**

Replace the existing button line:

```swift
        Button("New Collection from Selection") { newCollectionFromSelection() }
```

with:

```swift
        Button("New Collection from Selection") { appState.requestNewCollection(fallback: path) }
```

Then delete the now-unused private helper `newCollectionFromSelection()` (the whole method, including its `///` doc comment) from the same file. Leave `addToCollection(_:)` and all other methods untouched.

- [ ] **Step 5: Build and verify it compiles**

Run: `cd "/Users/carlostarrats/Documents/Projects/Muse/Muse App/Muse" && xcodebuild -scheme Muse -configuration Debug build 2>&1 | tail -3`
Expected: `** BUILD SUCCEEDED **` (ignore any SourceKit "Cannot find type" diagnostics — they're cross-file noise).

- [ ] **Step 6: Run the test suite**

Run: `cd "/Users/carlostarrats/Documents/Projects/Muse/Muse App/Muse" && xcodebuild -scheme Muse test 2>&1 | tail -5`
Expected: build + tests succeed, 0 failures (existing manual-collection naming/visibility tests still pass — no test changed).

- [ ] **Step 7: Manual verification in the running app**

Launch the Debug build, point Muse at a folder with images. Right-click a single image → modal appears empty with the "Collection name" placeholder. Type a name + Create → open Collections page, confirm a collection with that exact name contains that image. Repeat with a ⌘/Shift multi-selection. Press Cancel on the modal → confirm no collection was created. Press Create with an empty field → confirm no collection was created.

- [ ] **Step 8: Commit**

```bash
cd "/Users/carlostarrats/Documents/Projects/Muse/Muse App"
git add Muse/Muse/Models/AppState.swift Muse/Muse/Models/AppState+Filters.swift Muse/Muse/ContentView.swift Muse/Muse/Views/SelectionMenu.swift
git commit -m "feat(collections): prompt for a name when creating a collection from selection"
```

---

### Task 2: Documentation

**Files:**
- Modify: `CLAUDE.md` (refresh the `SelectionMenu.swift` architecture line + add a session-index entry)
- Modify: `docs/session-log.md` (append a session entry)

- [ ] **Step 1: Update the `SelectionMenu.swift` architecture-map line in `CLAUDE.md`**

Reflect that "New Collection from Selection" now opens a name prompt (prompt-first; created on confirm). Keep it to the existing terse style.

- [ ] **Step 2: Update the `feat/next-19` session-index line in `CLAUDE.md`**

Extend the existing `feat/next-19` index line to note the name-prompt addition.

- [ ] **Step 3: Append a session-log entry to `docs/session-log.md`**

Add a `## 2026-06-18 — feat/next-19 — name-it modal` section summarizing: prompt-first flow, mirrors Rename-Folder alert, Cancel/blank creates nothing, reuses createManual+rename+addFile, build+tests green. Reference the spec path.

- [ ] **Step 4: Commit**

```bash
cd "/Users/carlostarrats/Documents/Projects/Muse/Muse App"
git add CLAUDE.md docs/session-log.md
git commit -m "docs: record name-it modal for new-collection-from-selection"
```

---

## Self-Review

**1. Spec coverage:**
- Empty field + placeholder → Task 1 Step 3 `TextField("Collection name", …)` with empty draft (Step 1/2). ✓
- Cancel/blank discards entirely → Task 1 Step 2 `confirmNewCollection` guard + `cancelNewCollection`; no DB write before confirm. ✓
- Prompt-first ordering → Task 1 Steps 2–4. ✓
- Mirror Rename-Folder modal → Task 1 Step 3 `.alert` beside it. ✓
- Capture selection at request time → Task 1 Step 2 `requestNewCollection`. ✓
- Reuse store functions, no new API → Task 1 Step 2 uses existing `createManual`/`rename`/`addFile`. ✓
- Remove old immediate-create helper → Task 1 Step 4. ✓
- Verification (build/test/manual) → Task 1 Steps 5–7. ✓
- Docs updated → Task 2. ✓

**2. Placeholder scan:** No TBD/TODO/"handle edge cases"; all code shown verbatim. ✓

**3. Type consistency:** `newCollectionRequest`/`newCollectionNameDraft`/`pendingNewCollectionPaths`/`requestNewCollection`/`confirmNewCollection`/`cancelNewCollection` used identically across AppState.swift, AppState+Filters.swift, ContentView.swift, and SelectionMenu.swift. Store signatures match the codebase. ✓

> Note: UI views are not unit-tested in this codebase (project convention), and this change is entirely UI/AppState-wired with no new pure logic worth isolating. Verification is build + existing suite + manual drive (Task 1 Steps 5–7), consistent with how the prior new-collection feature was verified.
