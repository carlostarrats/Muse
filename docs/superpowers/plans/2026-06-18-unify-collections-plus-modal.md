# Unify the Collections-page "+" with the Name-Collection Modal — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the Collections-page "+" button create a collection through the shared "Name Collection" modal instead of creating an auto-named empty collection immediately.

**Architecture:** Generalize the existing modal request/confirm so it works with or without a selection. The "+" calls `AppState.requestNewCollection()` with no fallback (empty selection), the grid right-click keeps calling `requestNewCollection(fallback:)`. `confirmNewCollection()` creates the named collection whenever the name is non-empty, adding members only when a selection was captured.

**Tech Stack:** Swift, SwiftUI, GRDB (SQLite). macOS app target `Muse`.

## Global Constraints

- Min macOS 14.6; GRDB writes/reads are async (`try await queue.write/read`).
- `AppState` is `@MainActor`.
- Duplicate collection names allowed (no uniqueness check); validation is non-empty only.
- No new store API; no schema change. Reuse `createManual` + `rename` + `addFile`.
- SourceKit "Cannot find type X" errors are cross-file noise — verify with `xcodebuild`.
- Build dir: `cd "/Users/carlostarrats/Documents/Projects/Muse/Muse App/Muse"`. Git root: `/Users/carlostarrats/Documents/Projects/Muse/Muse App`.

---

### Task 1: Unify the "+" button onto the modal

**Files:**
- Modify: `Muse/Muse/Models/AppState+Filters.swift` (`requestNewCollection` fallback → optional; generalize `confirmNewCollection`)
- Modify: `Muse/Muse/ContentView.swift` (adaptive alert message)
- Modify: `Muse/Muse/Views/CollectionsPage.swift` (`createCollection()` → `appState.requestNewCollection()`)

**Interfaces:**
- Consumes (already exist): `effectiveSelectionURLs(fallback:)`, `CollectionStore.createManual(queue:)`, `CollectionStore.rename(queue:id:name:)`, `CollectionStore.fileIDs(queue:paths:)`, `CollectionStore.addFile(queue:fileID:collectionID:)`, `CollectionsEngine.shared.reload()`, `AppState.newCollectionRequest`/`newCollectionNameDraft`/`pendingNewCollectionPaths`.
- Produces: `AppState.requestNewCollection(fallback path: String? = nil)` (signature change — default nil), unchanged generalized `confirmNewCollection()`.

- [ ] **Step 1: Generalize `requestNewCollection` and `confirmNewCollection` in `AppState+Filters.swift`**

Replace the current `requestNewCollection(fallback path: String)` and `confirmNewCollection()` (the two methods added in the prior feature) with:

```swift
    /// Open the "Name Collection" prompt. With a fallback path, seed the new
    /// collection from the effective selection (grid right-click); with nil,
    /// create an empty collection (Collections-page "+"). No DB write until
    /// confirm.
    func requestNewCollection(fallback path: String? = nil) {
        pendingNewCollectionPaths = path.map { p in
            effectiveSelectionURLs(fallback: p).map { $0.standardizedFileURL.path }
        } ?? []
        newCollectionNameDraft = ""
        newCollectionRequest = true
    }

    /// Create a collection under the typed name. A blank/whitespace name creates
    /// nothing. Seeds it with the captured selection when there is one.
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

Leave `cancelNewCollection()` unchanged.

- [ ] **Step 2: Make the alert message adaptive in `ContentView.swift`**

In the `.alert("Name Collection", …)` block, replace the `message:` closure:

```swift
        } message: {
            Text("Creates a collection from the selected images.")
        }
```

with:

```swift
        } message: {
            Text(appState.pendingNewCollectionPaths.isEmpty
                 ? "Creates a new collection."
                 : "Creates a collection from the selected images.")
        }
```

- [ ] **Step 3: Point the "+" button at the shared request in `CollectionsPage.swift`**

Replace the existing `createCollection()` method body:

```swift
    private func createCollection() {
        Task { @MainActor in
            guard let q = Database.shared.dbQueue else { return }
            _ = try? await CollectionStore.createManual(queue: q)
            await CollectionsEngine.shared.reload()
        }
    }
```

with:

```swift
    /// Open the shared "Name Collection" modal (empty selection → empty named
    /// collection). Unified with the grid's "New Collection from Selection".
    private func createCollection() {
        appState.requestNewCollection()
    }
```

- [ ] **Step 4: Build and verify it compiles**

Run: `cd "/Users/carlostarrats/Documents/Projects/Muse/Muse App/Muse" && xcodebuild -scheme Muse -configuration Debug build 2>&1 | tail -3`
Expected: `** BUILD SUCCEEDED **` (ignore SourceKit cross-file diagnostics).

- [ ] **Step 5: Run the test suite**

Run: `cd "/Users/carlostarrats/Documents/Projects/Muse/Muse App/Muse" && xcodebuild -scheme Muse test 2>&1 | grep -iE "Executed|failed|\*\* TEST" | tail -6`
Expected: `** TEST SUCCEEDED **`, 0 failures.

- [ ] **Step 6: Manual verification in the running app**

Launch the Debug build. Open the Collections page (toolbar `square.stack.3d.up`). Click "+" → modal appears empty; message reads "Creates a new collection." Type a name + Create → an empty collection card with that name appears. Click "+" → Cancel → no card added. Click "+" → Create with blank field → no card added. Then back in the grid, right-click a selection → "New Collection from Selection" → message reads "Creates a collection from the selected images." and seeding still works.

- [ ] **Step 7: Commit**

```bash
cd "/Users/carlostarrats/Documents/Projects/Muse/Muse App"
git add Muse/Muse/Models/AppState+Filters.swift Muse/Muse/ContentView.swift Muse/Muse/Views/CollectionsPage.swift
git commit -m "feat(collections): Collections-page + uses the shared Name Collection modal"
```

---

### Task 2: Documentation

**Files:**
- Modify: `CLAUDE.md` (`CollectionsPage.swift` architecture line + `feat/next-19` session-index line)
- Modify: `docs/session-log.md` (append a session entry)

- [ ] **Step 1: Update the `CollectionsPage.swift` architecture line in `CLAUDE.md`**

It currently says the "+" runs `createManual → "Collection N"`. Change it to note the "+" now opens the shared "Name Collection" modal (`requestNewCollection()`), created on confirm.

- [ ] **Step 2: Extend the `feat/next-19` session-index line in `CLAUDE.md`**

Note that the Collections-page "+" is now unified onto the same modal.

- [ ] **Step 3: Append a session-log entry to `docs/session-log.md`**

Add a `## 2026-06-18 — feat/next-19 — unify "+" onto the name modal` section: "+" now opens the shared modal; `requestNewCollection` fallback made optional; `confirmNewCollection` generalized to create with or without a selection; adaptive alert message; reuses createManual+rename+addFile; build+tests green. Reference the spec + plan paths.

- [ ] **Step 4: Commit**

```bash
cd "/Users/carlostarrats/Documents/Projects/Muse/Muse App"
git add CLAUDE.md docs/session-log.md
git commit -m "docs: record Collections-page + unified onto the Name Collection modal"
```

---

## Self-Review

**1. Spec coverage:**
- "+" opens the shared modal → Task 1 Step 3. ✓
- Create empty named collection with no selection → Task 1 Step 1 (`confirmNewCollection` drops the empty-selection create guard). ✓
- Cancel/blank creates nothing → Task 1 Step 1 (`guard !name.isEmpty`; no write before confirm). ✓
- Right-click path unchanged → Task 1 Step 1 keeps `fallback:` capture; seeding under `if !paths.isEmpty`. ✓
- Adaptive message → Task 1 Step 2. ✓
- No new store API / schema → Task 1 reuses existing functions. ✓
- Hero-viewer path untouched → not modified. ✓
- Verification → Task 1 Steps 4–6. ✓
- Docs → Task 2. ✓

**2. Placeholder scan:** No TBD/TODO/vague steps; all code shown verbatim. ✓

**3. Type consistency:** `requestNewCollection(fallback:)` default-nil signature is compatible with the existing call `appState.requestNewCollection(fallback: path)` in `SelectionMenu.swift` (still valid) and the new `appState.requestNewCollection()` in `CollectionsPage.swift`. `confirmNewCollection`/`cancelNewCollection`/`pendingNewCollectionPaths`/`newCollectionNameDraft`/`newCollectionRequest` names match across files. Store signatures match the codebase. ✓

> Note: UI/AppState-wired change with no new pure logic; verification is build + existing suite + manual drive (project convention — UI views aren't unit-tested).
