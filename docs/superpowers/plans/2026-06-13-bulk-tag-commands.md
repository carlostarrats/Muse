# Bulk Tag Commands Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add two folder-scoped menu commands — "Delete All Tags" and "Regenerate Tags" — to the Tags menu, so users can bulk-clear a folder's tags and bring back the automatic ones.

**Architecture:** Both commands act only on the current sidebar folder's files (`AppState.currentFiles`). Delete removes every `tags` row for those files but deliberately leaves `analyzed_hash` untouched, so the automatic pipeline never resurrects them. Regenerate re-runs Vision only on current-folder files that have **zero tags** — which makes it both the recovery path (after a wipe, all files qualify) and incremental (already-tagged files are skipped). Wiring follows the existing `tagDeleteRequest` flag + `.alert` + `tagsVersion` bump pattern.

**Tech Stack:** Swift, SwiftUI, GRDB (SQLite), macOS app (Muse). No tests exist in this codebase (test coverage is a separate workstream); verification is by `xcodebuild` build + manual run, per project convention.

---

## File structure

- `Muse/Muse/Database/TagStore.swift` — add `deleteAllTags(forURLs:)` (resolve URLs → file IDs → `DELETE FROM tags`).
- `Muse/Muse/Intelligence/AnalyzePipeline.swift` — add `regenerateTagless(in:)` (resolve URLs → file IDs → keep only tagless → `analyze(folder:)`).
- `Muse/Muse/Models/AppState.swift` — add two `@Published` request flags.
- `Muse/Muse/MuseApp.swift` — add two buttons to `CommandMenu("Tags")`.
- `Muse/Muse/Views/TagChipsRow.swift` — add two `.alert`s + two commit handlers.

There is no test target work here. Each task ends with a build + commit. Build command used throughout:

```bash
xcodebuild -project Muse/Muse.xcodeproj -scheme Muse -destination 'platform=macOS' build
```

Expected: `** BUILD SUCCEEDED **`. (SourceKit cross-file "cannot find type" errors in the editor are noise per CLAUDE.md — only the `xcodebuild` result counts.)

---

### Task 1: `TagStore.deleteAllTags(forURLs:)`

Removes every tag row for a set of file URLs, scoped by resolving each URL to its alive `file_id`. Does NOT touch `files` / `analyzed_hash`.

**Files:**
- Modify: `Muse/Muse/Database/TagStore.swift` (add a method after `deleteLabel`, before `removeTag` — around line 126)

- [ ] **Step 1: Add the method**

Insert this method into `TagStore` (after the existing `deleteLabel(_:)` at `TagStore.swift:126`):

```swift
    /// Delete every tag (manual + vision) for the given file URLs. Scoped by
    /// resolving each URL to its alive file_id. Deliberately does NOT touch
    /// analyzed_hash, so the automatic analysis pipeline will not resurrect
    /// these tags on the next index pass — they only return via an explicit
    /// Regenerate. No FTS cleanup needed: tags aren't stored in files_fts.
    func deleteAllTags(forURLs urls: [URL]) async {
        guard let queue = Database.shared.dbQueue else { return }
        let paths = urls.map { $0.standardizedFileURL.path }
        guard !paths.isEmpty else { return }
        do {
            try await queue.write { db in
                let marks = databaseQuestionMarks(count: paths.count)
                try db.execute(sql: """
                    DELETE FROM tags WHERE file_id IN (
                        SELECT p.file_id FROM paths p
                        WHERE p.is_alive = 1 AND p.absolute_path IN (\(marks))
                    )
                    """, arguments: StatementArguments(paths))
            }
        } catch {
            print("[TagStore] deleteAllTags failed: \(error)")
        }
    }
```

Note: `databaseQuestionMarks(count:)` and `StatementArguments` are already used in this codebase (see `AnalyzePipeline.analyzePending` at `AnalyzePipeline.swift:68`), so no new import is needed beyond the existing `import GRDB`.

- [ ] **Step 2: Build**

Run: `xcodebuild -project Muse/Muse.xcodeproj -scheme Muse -destination 'platform=macOS' build`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit**

```bash
git add Muse/Muse/Database/TagStore.swift
git commit -m "feat: TagStore.deleteAllTags(forURLs:) — folder-scoped bulk tag delete"
```

---

### Task 2: `AnalyzePipeline.regenerateTagless(in:)`

Re-runs analysis only on current-folder files that currently have **zero tags**. Reuses the existing `analyze(folder:)` for the actual work (progress pill, per-file analysis, recluster).

**Files:**
- Modify: `Muse/Muse/Intelligence/AnalyzePipeline.swift` (add a method after `analyzePending(in:)`, around line 81)

- [ ] **Step 1: Add the method**

Insert this method into the `AnalyzePipeline` class, immediately after `analyzePending(in urls:)` (ends at `AnalyzePipeline.swift:81`) and before `analyze(folder urls:)`:

```swift
    /// Recovery / gap-fill pass: of `urls` (the current folder), analyze only
    /// those files that currently have NO tags. This is the explicit
    /// "Regenerate Tags" command. The no-tags gate makes it both the recovery
    /// path (after a Delete All, every file qualifies) and incremental
    /// (already-tagged files are skipped, so a fully-tagged folder is a no-op).
    /// Intentionally NOT gated on analyzed_hash, so it doesn't entangle with
    /// the automatic pipeline.
    func regenerateTagless(in urls: [URL]) async {
        guard let queue = Database.shared.dbQueue else { return }
        while isRunning {
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        let paths = urls.map { $0.standardizedFileURL.path }
        guard !paths.isEmpty else { return }
        let tagless: Set<String> = (try? await queue.read { db in
            let marks = databaseQuestionMarks(count: paths.count)
            return try Set(String.fetchAll(db, sql: """
                SELECT p.absolute_path FROM paths p
                WHERE p.is_alive = 1
                  AND p.absolute_path IN (\(marks))
                  AND NOT EXISTS (SELECT 1 FROM tags t WHERE t.file_id = p.file_id)
                """, arguments: StatementArguments(paths)))
        }) ?? []
        guard !tagless.isEmpty else { return }
        let taglessURLs = urls.filter { tagless.contains($0.standardizedFileURL.path) }
        await analyze(folder: taglessURLs)
    }
```

- [ ] **Step 2: Build**

Run: `xcodebuild -project Muse/Muse.xcodeproj -scheme Muse -destination 'platform=macOS' build`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit**

```bash
git add Muse/Muse/Intelligence/AnalyzePipeline.swift
git commit -m "feat: AnalyzePipeline.regenerateTagless(in:) — re-analyze only tagless folder files"
```

---

### Task 3: AppState request flags

Two `@Published` flags that the menu sets and `TagChipsRow` observes, mirroring the existing `tagDeleteRequest` / `collectionDeleteRequest`.

**Files:**
- Modify: `Muse/Muse/Models/AppState.swift` (near the existing tag/collection request flags, around lines 202–207)

- [ ] **Step 1: Add the flags**

After the existing `@Published var collectionDeleteRequest = false` (`AppState.swift:207`), add:

```swift
    @Published var deleteAllTagsRequest = false
    @Published var regenerateTagsRequest = false
```

- [ ] **Step 2: Build**

Run: `xcodebuild -project Muse/Muse.xcodeproj -scheme Muse -destination 'platform=macOS' build`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit**

```bash
git add Muse/Muse/Models/AppState.swift
git commit -m "feat: AppState flags for delete-all/regenerate tag commands"
```

---

### Task 4: Tags menu buttons

Two buttons in the existing `CommandMenu("Tags")`, under a divider below the current items. Enabled only when the current folder has files.

**Files:**
- Modify: `Muse/Muse/MuseApp.swift` (inside `CommandMenu("Tags")`, after the "Clear Tag Filter" button at lines 99–102, before the menu's closing brace at line 103)

- [ ] **Step 1: Add the buttons**

Inside `CommandMenu("Tags")`, after the existing `Button("Clear Tag Filter") { ... }.disabled(...)` block (ends `MuseApp.swift:102`) and before the closing `}` of the menu (line 103), insert:

```swift
                Divider()

                Button("Delete All Tags…") {
                    appState.deleteAllTagsRequest = true
                }
                .disabled(appState.currentFiles.isEmpty)

                Button("Regenerate Tags…") {
                    appState.regenerateTagsRequest = true
                }
                .disabled(appState.currentFiles.isEmpty)
```

- [ ] **Step 2: Build**

Run: `xcodebuild -project Muse/Muse.xcodeproj -scheme Muse -destination 'platform=macOS' build`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit**

```bash
git add Muse/Muse/MuseApp.swift
git commit -m "feat: Tags menu — Delete All Tags / Regenerate Tags commands"
```

---

### Task 5: Confirmation alerts + handlers in TagChipsRow

Two `.alert`s bound to the new flags, plus two commit handlers, following the exact shape of the existing Delete-tag alert/`commitDelete`.

**Files:**
- Modify: `Muse/Muse/Views/TagChipsRow.swift` (add two `.alert`s after the existing Delete alert at lines 81–89; add two handlers after `commitDelete()` at line 112)

- [ ] **Step 1: Add the two alerts**

Immediately after the existing Delete alert block (the `.alert("Delete "\(appState.tagDeleteRequest ?? "")"?", ...)` that ends at `TagChipsRow.swift:89`), and before the closing `}` of the `body`/view modifier chain at line 90, add:

```swift
        .alert("Delete all tags in this folder?", isPresented: $appState.deleteAllTagsRequest) {
            Button("Delete All", role: .destructive) { commitDeleteAllTags() }
            Button("Cancel", role: .cancel) { appState.deleteAllTagsRequest = false }
        } message: {
            Text("This removes every tag on the images in this folder — both automatic tags and ones you've added yourself. Tags you added by hand can't be recovered. Your images stay on disk.")
        }
        .alert("Regenerate tags for this folder?", isPresented: $appState.regenerateTagsRequest) {
            Button("Regenerate") { commitRegenerateTags() }
            Button("Cancel", role: .cancel) { appState.regenerateTagsRequest = false }
        } message: {
            Text("Looks for images in this folder that have no tags and generates tags for them in the background. Images that already have tags are left alone. Only automatic tags are created — tags you added by hand aren't restored.")
        }
```

- [ ] **Step 2: Add the two handlers**

After the existing `commitDelete()` method (ends `TagChipsRow.swift:112`), add:

```swift
    private func commitDeleteAllTags() {
        appState.deleteAllTagsRequest = false
        let urls = appState.currentFiles.map { $0.url }
        Task { @MainActor in
            await TagStore.shared.deleteAllTags(forURLs: urls)
            appState.setActiveTag(nil)
            appState.tagsVersion += 1
        }
    }

    private func commitRegenerateTags() {
        appState.regenerateTagsRequest = false
        let urls = appState.currentFiles.map { $0.url }
        Task { @MainActor in
            await AnalyzePipeline.shared.regenerateTagless(in: urls)
            appState.tagsVersion += 1
        }
    }
```

- [ ] **Step 3: Build**

Run: `xcodebuild -project Muse/Muse.xcodeproj -scheme Muse -destination 'platform=macOS' build`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4: Commit**

```bash
git add Muse/Muse/Views/TagChipsRow.swift
git commit -m "feat: confirmation alerts + handlers for bulk tag commands"
```

---

### Task 6: Manual verification

No automated tests exist; verify by running the app.

**Files:** none (manual run)

- [ ] **Step 1: Run the app**

Build & run from Xcode (Cmd+R), or:

```bash
xcodebuild -project Muse/Muse.xcodeproj -scheme Muse -destination 'platform=macOS' build
```

- [ ] **Step 2: Verify Delete All Tags**

1. Add a folder of images and let analysis finish (tag chips appear above the grid).
2. Menu bar → **Tags → Delete All Tags…** → confirm.
3. Expect: the tag chip row empties for this folder; any active tag filter clears. Revisit the folder — tags do NOT come back on their own.

- [ ] **Step 3: Verify Regenerate Tags**

1. With the just-cleared folder selected, Menu bar → **Tags → Regenerate Tags…** → confirm.
2. Expect: the bottom-center "Analyzing N of M" pill appears; when it finishes, automatic tags reappear in the chip row. Manual tags you'd typed are NOT restored.
3. Run **Regenerate Tags…** again on the now-tagged folder → expect no pill / a near-instant no-op (already-tagged files are skipped).

- [ ] **Step 4: Verify menu enablement**

With no folder selected (empty grid), both new Tags commands are disabled.

- [ ] **Step 5: Commit (if any fixups were needed)**

```bash
git add -A
git commit -m "fix: bulk tag command verification fixups" || echo "no fixups needed"
```

---

## Self-review notes

- **Spec coverage:** Delete All Tags (Task 1 + 4 + 5), Regenerate Tags (Task 2 + 4 + 5), folder-scoping via `currentFiles` (Tasks 4–5), no `analyzed_hash` reset (Task 1 comment + omission), no-tags gate (Task 2), no FTS cleanup (Task 1 comment), confirmation modals with the spec's copy (Task 5), menu wiring under a divider (Task 4), enablement on `!currentFiles.isEmpty` (Task 4). All spec sections covered.
- **Type consistency:** `deleteAllTags(forURLs:)` and `regenerateTagless(in:)` are defined in Tasks 1–2 and called with identical signatures in Task 5. Flags `deleteAllTagsRequest` / `regenerateTagsRequest` defined in Task 3, used in Tasks 4–5. `tagsVersion`, `setActiveTag(nil)`, `currentFiles`, `AnalyzePipeline.shared`, `TagStore.shared` all verified to exist in the current source.
- **No placeholders:** every code step shows complete code; every build/commit step shows the exact command.
