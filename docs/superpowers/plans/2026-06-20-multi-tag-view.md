# Multi-Tag View (AND / intersection) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let the tag chip row filter the grid by more than one tag at once — Cmd-click chips to build a selection, grid shows files carrying ALL selected tags (AND/intersection), a banner names the active set, and tag filtering works over search results too.

**Architecture:** Replace the scalar `AppState.activeTagLabel: String?` with an ordered `activeTagLabels: [String]`, keeping the existing `activeTagPaths: Set<String>?` (now the intersection of each selected label's path set). A new pure `TagSelection` helper holds the transition/banner logic (unit-tested). Plain-click replaces the selection; Cmd-click toggles. The chip row mounts during search and the tag filter narrows search results. `EscapeResolver` gains a `.clearTags` layer.

**Tech Stack:** SwiftUI, GRDB (SQLite), XCTest, AppKit (`NSEvent.modifierFlags` for Cmd detection).

## Global Constraints

- Min macOS 14.6; module default actor isolation is **MainActor** — pure value types used off-main or in nonisolated tests must be marked `nonisolated`.
- Tags are per `(file_id, parent_dir)` — the per-label path query MUST preserve `parent_dir` scoping (a duplicate sharing the file_id in an untagged folder must not be pulled in). Reuse the existing SQL verbatim.
- No network. Files never deleted (Trash only). GRDB reads/writes are `async` (`try await queue.read { }`).
- UI views are not unit-tested (project convention) — pure logic gets tests; SwiftUI behavior is verified by build + driving.
- This is a **view/filter-only** feature: NO multi-select tag delete. Tag deletion stays single (right-click → "Delete Tag…").
- Grep all `activeTagLabel` readers and migrate them together — never leave a half-migrated state (Task 2 is the coordinated rename).

---

### Task 1: Pure `TagSelection` helper

**Files:**
- Create: `Muse/Muse/Models/TagSelection.swift`
- Test: `Muse/MuseTests/TagSelectionTests.swift`

**Interfaces:**
- Produces: `enum TagSelection` with statics:
  - `static func toggling(_ labels: [String], _ label: String) -> [String]`
  - `static func bannerText(for labels: [String]) -> String?`

- [ ] **Step 1: Write the failing test**

Create `Muse/MuseTests/TagSelectionTests.swift`:

```swift
import XCTest
@testable import Muse

final class TagSelectionTests: XCTestCase {

    // MARK: - toggling

    func testToggleAddsAbsentLabelAtEnd() {
        XCTAssertEqual(TagSelection.toggling(["blue"], "screenshot"),
                       ["blue", "screenshot"])
    }

    func testToggleRemovesPresentLabel() {
        XCTAssertEqual(TagSelection.toggling(["blue", "screenshot"], "blue"),
                       ["screenshot"])
    }

    func testToggleRemovingSoleLabelEmptiesSelection() {
        XCTAssertEqual(TagSelection.toggling(["blue"], "blue"), [])
    }

    func testTogglePreservesInsertionOrder() {
        var sel: [String] = []
        sel = TagSelection.toggling(sel, "c")
        sel = TagSelection.toggling(sel, "a")
        sel = TagSelection.toggling(sel, "b")
        XCTAssertEqual(sel, ["c", "a", "b"])
    }

    // MARK: - bannerText (Oxford "and")

    func testNoBannerForZeroLabels() {
        XCTAssertNil(TagSelection.bannerText(for: []))
    }

    func testNoBannerForOneLabel() {
        XCTAssertNil(TagSelection.bannerText(for: ["blue"]))
    }

    func testBannerForTwoLabels() {
        XCTAssertEqual(TagSelection.bannerText(for: ["blue", "screenshot"]),
                       "Viewing blue and screenshot")
    }

    func testBannerForThreeLabelsUsesOxfordAnd() {
        XCTAssertEqual(
            TagSelection.bannerText(for: ["blue", "screenshot", "invoice"]),
            "Viewing blue, screenshot, and invoice")
    }

    func testBannerForFourLabels() {
        XCTAssertEqual(
            TagSelection.bannerText(for: ["a", "b", "c", "d"]),
            "Viewing a, b, c, and d")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -scheme Muse -destination 'platform=macOS' test -only-testing:MuseTests/TagSelectionTests 2>&1 | tail -20`
Expected: FAIL — "Cannot find 'TagSelection' in scope".

- [ ] **Step 3: Write minimal implementation**

Create `Muse/Muse/Models/TagSelection.swift`:

```swift
//
//  TagSelection.swift
//  Muse
//
//  Pure transition + banner-text logic for the multi-tag chip filter. The grid
//  filters by the INTERSECTION (AND) of the selected tags; this type owns the
//  ordered-set mutations and the "Viewing … and …" banner wording so AppState
//  stays a thin caller and the rules are unit-tested. `nonisolated` because the
//  module's default actor isolation is MainActor (used from nonisolated tests).
//

nonisolated enum TagSelection {

    /// Cmd-click toggle: remove `label` if present, else append it at the end
    /// (insertion order drives the banner wording).
    static func toggling(_ labels: [String], _ label: String) -> [String] {
        if let idx = labels.firstIndex(of: label) {
            var out = labels
            out.remove(at: idx)
            return out
        }
        return labels + [label]
    }

    /// The grid-top banner shown for 2+ selected tags. nil for 0 or 1 (a single
    /// filled chip is already clear). Oxford-style "and" before the last label.
    static func bannerText(for labels: [String]) -> String? {
        switch labels.count {
        case 0, 1:
            return nil
        case 2:
            return "Viewing \(labels[0]) and \(labels[1])"
        default:
            let head = labels.dropLast().joined(separator: ", ")
            return "Viewing \(head), and \(labels.last!)"
        }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild -scheme Muse -destination 'platform=macOS' test -only-testing:MuseTests/TagSelectionTests 2>&1 | tail -20`
Expected: PASS (`** TEST SUCCEEDED **`).

- [ ] **Step 5: Commit**

```bash
git add "Muse/Muse/Models/TagSelection.swift" "Muse/MuseTests/TagSelectionTests.swift"
git commit -m "feat: pure TagSelection helper (toggle + Oxford banner text)"
```

---

### Task 2: Scalar → ordered-set migration across AppState + all readers

This is the coordinated rename. After it the app behaves **exactly as today** (single-tag plain-click replace, search still bypasses tag filter, no banner) but the state is now `[String]` driven by a `setActiveTags` core. Build + full existing suite must stay green.

**Files:**
- Modify: `Muse/Muse/Models/AppState.swift` (state decl ~256-260; `select(folder:)` ~769)
- Modify: `Muse/Muse/Models/AppState+Filters.swift` (`setActiveTag` ~318-364; `removeTag` ~207)
- Modify: `Muse/Muse/MuseApp.swift` (Tags menu ~214-243)
- Modify: `Muse/Muse/Views/SelectionMenu.swift` (~56-62)
- Modify: `Muse/Muse/Views/GridView.swift` (`.id` ~160; `gridSignature` ~397)
- Modify: `Muse/Muse/Views/TagChipsRow.swift` (chip `isSelected`/click ~42-53; `commitRename` ~126)

**Interfaces:**
- Consumes: `TagSelection` (Task 1).
- Produces (new AppState API later tasks rely on):
  - `@Published var activeTagLabels: [String]` (ordered; replaces `activeTagLabel`)
  - `var singleActiveTag: String?` — `activeTagLabels.count == 1 ? activeTagLabels.first : nil`
  - `func setActiveTags(_ labels: [String], animated: Bool = true)` — core: replace selection, recompute `activeTagPaths` = intersection
  - `func setActiveTag(_ label: String?, animated: Bool = true)` — delegates to `setActiveTags(label.map { [$0] } ?? [])`
  - `private func pathsForTag(_ label: String) async -> [String]`

- [ ] **Step 1: Replace the stored state in AppState.swift**

In `Muse/Muse/Models/AppState.swift`, replace (around line 255-256):

```swift
    /// Active tag-chip filter; nil = "All". Set via `setActiveTag`.
    @Published var activeTagLabel: String?
```

with:

```swift
    /// Active tag-chip filter as an ORDERED set; empty = "All". Insertion order
    /// drives the banner wording. Mutated via `setActiveTags` / `setActiveTag` /
    /// `toggleActiveTag` in AppState+Filters; the grid filters by the
    /// INTERSECTION of these labels' path sets (`activeTagPaths`).
    @Published var activeTagLabels: [String] = []

    /// The lone selected tag, or nil when 0 or 2+ are selected. Drives the
    /// single-tag menu commands (Rename/Delete/Remove) which are ambiguous for a
    /// multi-tag selection.
    var singleActiveTag: String? {
        activeTagLabels.count == 1 ? activeTagLabels.first : nil
    }
```

The comment on `activeTagPaths` just below (line ~257) — update its wording:

```swift
    /// Alive paths in the INTERSECTION of `activeTagLabels` (files carrying ALL
    /// selected tags); nil = no filter.
    @Published var activeTagPaths: Set<String>? {
        didSet { _visibleFilesValid = false }
    }
```

- [ ] **Step 2: Update `select(folder:)` in AppState.swift**

Around line 769, replace:

```swift
        if activeTagLabel != nil { setActiveTag(nil, animated: false) }
```

with:

```swift
        if !activeTagLabels.isEmpty { setActiveTag(nil, animated: false) }
```

- [ ] **Step 3: Rewrite `setActiveTag` into `setActiveTags` + add `pathsForTag` in AppState+Filters.swift**

In `Muse/Muse/Models/AppState+Filters.swift`, replace the whole `setActiveTag(_:animated:)` method (lines ~316-364) with:

```swift
    /// Per-label alive-path query, scoped per `parent_dir` (tags are
    /// per-location: a duplicate sharing the file_id in an untagged folder must
    /// NOT be pulled in). Returns the absolute paths carrying `label` in their
    /// own folder.
    private func pathsForTag(_ label: String) async -> [String] {
        guard let q = Database.shared.dbQueue else { return [] }
        return (try? await q.read { db -> [String] in
            let rows = try Row.fetchAll(db, sql: """
                SELECT p.absolute_path AS ap, t.parent_dir AS pd
                FROM paths p JOIN tags t ON t.file_id = p.file_id
                WHERE p.is_alive = 1 AND t.label = ?
                """, arguments: [label])
            var out: [String] = []
            for r in rows {
                guard let ap: String = r["ap"] else { continue }
                let pd: String? = r["pd"]
                if pd == TagScope.parentDir(ofPath: ap) { out.append(ap) }
            }
            return out
        }) ?? []
    }

    /// Core tag-filter mutation: set the selection to exactly `labels` (ordered)
    /// and recompute `activeTagPaths` as the INTERSECTION of each label's path
    /// set (files carrying ALL of them). Empty `labels` clears the filter. Same
    /// single-transaction animated swap as the collection filter — labels +
    /// paths land together so the grid cross-fades once. One query per label
    /// (selection sizes are tiny).
    func setActiveTags(_ labels: [String], animated: Bool = true) {
        clearSelection()
        let curve = Animation.easeInOut(duration: AppState.navTransition)
        tagRequestToken += 1
        guard !labels.isEmpty else {
            if animated {
                withAnimation(curve) {
                    activeTagLabels = []
                    activeTagPaths = nil
                }
            } else {
                activeTagLabels = []
                activeTagPaths = nil
            }
            return
        }
        let token = tagRequestToken
        Task { @MainActor in
            var sets: [Set<String>] = []
            for label in labels {
                sets.append(Set(await pathsForTag(label)))
            }
            let inter = sets.dropFirst().reduce(sets.first ?? Set<String>()) {
                $0.intersection($1)
            }
            if token == tagRequestToken {
                withAnimation(curve) {
                    activeTagLabels = labels
                    activeTagPaths = inter
                }
            }
        }
    }

    /// Set (or clear, with nil) a SINGLE active tag — plain-click / clear.
    func setActiveTag(_ label: String?, animated: Bool = true) {
        setActiveTags(label.map { [$0] } ?? [], animated: animated)
    }

    /// Cmd-click toggle: add the label if absent, remove it if present;
    /// recomputes the intersection. Emptying the set clears the filter.
    func toggleActiveTag(_ label: String) {
        setActiveTags(TagSelection.toggling(activeTagLabels, label))
    }
```

- [ ] **Step 4: Update `removeTag` in AppState+Filters.swift**

Replace the `if activeTagLabel == label { … }` block (lines ~207-220) with:

```swift
            if activeTagLabels.contains(label) {
                // The affected files no longer carry `label`, so they leave the
                // intersection — subtract them from activeTagPaths (correct for
                // both single- and multi-tag: a file still in the intersection
                // must carry ALL labels, so any that lost `label` is in `removed`).
                let anyLeft = visibleFiles.contains {
                    !removed.contains($0.url.standardizedFileURL.path)
                }
                // Preserve today's single-tag "fall back to All" so the grid is
                // never stranded empty. A multi-tag intersection that empties is
                // legitimate (honest empty grid; the banner explains the set).
                if !anyLeft && activeTagLabels.count == 1 {
                    setActiveTag(nil)
                    return
                }
                activeTagPaths?.subtract(removed)
            }
```

- [ ] **Step 5: Update the Tags menu in MuseApp.swift**

In `Muse/Muse/MuseApp.swift` (lines ~214-243), the single-tag commands operate on `singleActiveTag`; "Clear Tag Filter" clears the whole set:

```swift
            CommandMenu("Tags") {
                Button("Rename Tag…") {
                    if let label = appState.singleActiveTag {
                        appState.tagRenameRequest = label
                    }
                }
                .disabled(appState.singleActiveTag == nil)

                Button("Delete Tag…") {
                    if let label = appState.singleActiveTag {
                        appState.tagDeleteRequest = label
                    }
                }
                .disabled(appState.singleActiveTag == nil)

                Button("Remove Tag from Selection") {
                    if let label = appState.singleActiveTag {
                        appState.removeTag(label,
                                           fromURLs: appState.effectiveSelectionURLs(fallback: ""))
                    }
                }
                .disabled(appState.singleActiveTag == nil || appState.selectedFiles.isEmpty
                          || appState.isSearchActive)

                Divider()

                Button("Clear Tag Filter") {
                    appState.setActiveTag(nil)
                }
                .disabled(appState.activeTagLabels.isEmpty)
```

(Leave the "Delete All Tags…" / "Regenerate Tags…" items below unchanged.)

- [ ] **Step 6: Update SelectionMenu.swift**

In `Muse/Muse/Views/SelectionMenu.swift` (lines ~56-62), gate the inline "Remove Tag X" on a single active tag (ambiguous for a multi-tag selection):

```swift
        if appState.singleActiveTag != nil || appState.activeCollectionID != nil {
            Divider()
            if let label = appState.singleActiveTag {
                Button("Remove Tag \u{201c}\(label)\u{201d}") {
                    appState.removeTag(label, fromURLs: urls)
                }
            }
```

(Leave the `activeCollectionID` branch below it unchanged.)

- [ ] **Step 7: Update GridView.swift signatures**

Line ~160, replace:

```swift
                            .id("\(appState.activeCollectionID ?? "")|\(appState.activeTagLabel ?? "")")
```

with:

```swift
                            .id("\(appState.activeCollectionID ?? "")|\(appState.activeTagLabels.joined(separator: ","))")
```

Line ~397 in `gridSignature`, replace:

```swift
            appState.activeTagLabel ?? "",
```

with:

```swift
            appState.activeTagLabels.joined(separator: ","),
```

- [ ] **Step 8: Update TagChipsRow.swift readers (behavior preserved for now)**

In `Muse/Muse/Views/TagChipsRow.swift`:

The "All" chip `isSelected` (line ~42):

```swift
                                isSelected: appState.activeTagLabels.isEmpty,
```

The tag chip `isSelected` + click (lines ~49-53):

```swift
                                    isSelected: appState.activeTagLabels.contains(tag.label),
                                    isHovered: hovered == i + 1,
                                    onHover: hover) {
                                appState.setActiveTag(
                                    appState.activeTagLabels == [tag.label] ? nil : tag.label)
                            }
```

`commitRename` (line ~126):

```swift
            if appState.activeTagLabels.contains(old) {
                appState.setActiveTags(
                    appState.activeTagLabels.map { $0 == old ? new : $0 })
            }
```

- [ ] **Step 9: Build and run the full suite to verify parity**

Run: `xcodebuild -scheme Muse -destination 'platform=macOS' build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **` (no remaining `activeTagLabel` references — confirm with `grep -rn "activeTagLabel\b" Muse/Muse` returning nothing).

Run: `xcodebuild -scheme Muse -destination 'platform=macOS' test 2>&1 | tail -10`
Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 10: Commit**

```bash
git add -A
git commit -m "refactor: migrate tag chip filter from scalar to ordered set (no behavior change)"
```

---

### Task 3: Cmd-click toggle in the chip row

Plain-click already replaces (Task 2). Add Cmd-click toggling so 2+ chips can be selected.

**Files:**
- Modify: `Muse/Muse/Views/TagChipsRow.swift` (chip action ~47-54)

**Interfaces:**
- Consumes: `AppState.toggleActiveTag`, `AppState.setActiveTag`, `AppState.activeTagLabels` (Task 2).

- [ ] **Step 1: Route plain vs Cmd-click in the tag chip action**

In `TagChipsRow.swift`, replace the tag chip's action closure (the `appState.setActiveTag(appState.activeTagLabels == [tag.label] ? nil : tag.label)` from Task 2) with a modifier-aware router:

```swift
                                    onHover: hover) {
                                // Cmd-click toggles the chip in/out of the
                                // selection (AND filter); plain click replaces the
                                // selection with just this tag (re-plain-clicking
                                // the sole selected chip clears). Mirrors the
                                // grid's own Cmd-click model (GridView reads
                                // NSEvent.modifierFlags the same way).
                                if NSEvent.modifierFlags.contains(.command) {
                                    appState.toggleActiveTag(tag.label)
                                } else {
                                    appState.setActiveTag(
                                        appState.activeTagLabels == [tag.label] ? nil : tag.label)
                                }
                            }
```

(`import AppKit` is already at the top of the file.)

- [ ] **Step 2: Build**

Run: `xcodebuild -scheme Muse -destination 'platform=macOS' build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Commit**

```bash
git add "Muse/Muse/Views/TagChipsRow.swift"
git commit -m "feat: Cmd-click tag chips to build a multi-tag (AND) selection"
```

---

### Task 4: "Viewing … and …" banner for 2+ tags

**Files:**
- Modify: `Muse/Muse/Models/AppState.swift` (add computed `tagBannerText`)
- Modify: `Muse/Muse/Views/TagChipsRow.swift` (render banner below chips)

**Interfaces:**
- Consumes: `TagSelection.bannerText` (Task 1), `AppState.activeTagLabels` (Task 2).
- Produces: `AppState.tagBannerText: String?`.

- [ ] **Step 1: Add the computed banner text to AppState**

In `Muse/Muse/Models/AppState.swift`, just after the `singleActiveTag` computed property (Task 2), add:

```swift
    /// Banner text for 2+ selected tags ("Viewing a and b" / Oxford for 3+);
    /// nil for 0 or 1 (no banner — a single filled chip is already clear).
    var tagBannerText: String? {
        TagSelection.bannerText(for: activeTagLabels)
    }
```

- [ ] **Step 2: Render the banner in TagChipsRow**

In `Muse/Muse/Views/TagChipsRow.swift`, wrap the existing `ZStack { … }` body in a `VStack(spacing: 0)` and append the banner below it. Replace the outer `var body: some View { ZStack {` … matching `} }` close with:

```swift
    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                // ── existing chips-or-clearance ZStack body, UNCHANGED ──
                if !tags.isEmpty {
                    // … (unchanged ScrollView/ChipFlow block) …
                } else {
                    Color.clear.frame(height: Self.noTagsTopClearance)
                }
            }

            // Banner naming the active set (2+ tags). Reserves its own strip
            // above the grid, below the chips — informational, quiet secondary
            // text. With 0/1 tag it's absent (no banner per the design).
            if let banner = appState.tagBannerText {
                Text(banner)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 10)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: AppState.navTransition), value: appState.activeTagLabels)
        // ── existing .onChange / .alert modifiers, UNCHANGED, stay attached
        //    to the VStack (move them from the old ZStack) ──
        .onChange(of: appState.tagRenameRequest) { _, label in
            if let label { renameText = label }
        }
        // … (all existing .alert modifiers unchanged) …
    }
```

Note: the `.onChange` and every `.alert` modifier that was on the old `ZStack` must now hang off the new outer `VStack`. Keep their contents byte-for-byte; only the view they attach to changes.

- [ ] **Step 3: Build**

Run: `xcodebuild -scheme Muse -destination 'platform=macOS' build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Commit**

```bash
git add "Muse/Muse/Models/AppState.swift" "Muse/Muse/Views/TagChipsRow.swift"
git commit -m "feat: grid-top banner naming the active multi-tag set (Oxford 'and')"
```

---

### Task 5: Tag filtering over search results + mount the chip row during search

**Files:**
- Modify: `Muse/Muse/Models/AppState+Filters.swift` (`visibleFiles` search branch ~49-50; `tagSourceFiles` ~88-90)
- Modify: `Muse/Muse/Models/AppState.swift` (`runSearch` ~1257-1280; `reloadTagChips` simpleDir guard ~1224)
- Modify: `Muse/Muse/ContentView.swift` (mount TagChipsRow during search ~71-74; `tagSortMenu` enablement ~127)

**Interfaces:**
- Consumes: `AppState.activeTagPaths`, `AppState.reloadTagChips`.

- [ ] **Step 1: Apply the tag filter to the search branch of `visibleFiles`**

In `Muse/Muse/Models/AppState+Filters.swift`, replace the search branch (lines ~49-50):

```swift
        if isSearchActive {
            base = currentFiles
        } else {
```

with:

```swift
        if isSearchActive {
            // Search results are global, but the tag chips now narrow WITHIN the
            // result set (AND). activeTagPaths is library-wide for the selected
            // labels, so it filters correctly across This-Folder and All scope.
            base = currentFiles
            if let tagPaths = activeTagPaths {
                base = base.filter { tagPaths.contains($0.url.standardizedFileURL.path) }
            }
        } else {
```

- [ ] **Step 2: Make `tagSourceFiles` search-aware**

Replace `tagSourceFiles` (lines ~88-90):

```swift
    var tagSourceFiles: [FileNode] {
        if isSearchActive { return currentFiles }
        return activeCollectionFiles ?? currentFiles
    }
```

- [ ] **Step 3: Don't use the simple-folder fast path during search**

In `Muse/Muse/Models/AppState.swift`, `reloadTagChips` (line ~1224), the `simpleDir` fast path keys off a single folder — wrong when search results span folders. Replace:

```swift
        let simpleDir = (!inCollection && !recursive) ? TagScope.parentDir(ofPath: paths[0]) : nil
```

with:

```swift
        // Search results can span folders, so the single-folder GROUP BY fast
        // path doesn't apply — fall to the general per-file-scope query.
        let simpleDir = (!inCollection && !recursive && !isSearchActive)
            ? TagScope.parentDir(ofPath: paths[0]) : nil
```

- [ ] **Step 4: Reload chips when search results land**

In `runSearch` (line ~1279), after `currentFiles = results`, add `reloadTagChips()`:

```swift
        isSearchActive = true
        // search results keep relevance rank; sort modes apply to folder browsing only
        currentFiles = results
        // Chip labels derive from the search result set (tagSourceFiles is
        // search-aware) so the offered chips are relevant.
        reloadTagChips()
    }
```

- [ ] **Step 5: Mount TagChipsRow during search in ContentView**

In `Muse/Muse/ContentView.swift` (lines ~70-76), remove the `isSearchActive` guard so the chip row stays mounted over search results:

```swift
                            VStack(spacing: 0) {
                                // Chips stay mounted during search too — tags now
                                // narrow within the search result set (AND).
                                TagChipsRow()
                                GridView()
                            }
```

- [ ] **Step 6: Enable the tag-sort menu during search**

In `ContentView.swift` (line ~127), the tag-sort menu was disabled during search because the chips were hidden; they now show, so only the Collections card page should disable it. Replace:

```swift
                        .disabled(isCollectionsPage || appState.isSearchActive)
```

with:

```swift
                        .disabled(isCollectionsPage)
```

- [ ] **Step 7: Build and run the suite**

Run: `xcodebuild -scheme Muse -destination 'platform=macOS' build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`.

Run: `xcodebuild -scheme Muse -destination 'platform=macOS' test 2>&1 | tail -10`
Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 8: Commit**

```bash
git add -A
git commit -m "feat: multi-tag filter over search results + mount chip row during search"
```

---

### Task 6: `EscapeResolver` clears the whole tag set

The current `EscapeResolver` has NO tag layer (the spec's "currently peels a single active tag" describes intent, not the present code). Add a `.clearTags` layer ordered AFTER search and BEFORE exiting a collection — one Escape empties the whole tag set.

**Files:**
- Modify: `Muse/Muse/Components/EscapeAction.swift` (add `.clearTags` case + `tagsActive` param)
- Modify: `Muse/Muse/ContentView.swift` (Escape handler ~261-298)
- Test: `Muse/MuseTests/EscapeActionTests.swift` (update call sites + new ordering tests)

**Interfaces:**
- Produces: `EscapeAction.clearTags`; `EscapeResolver.action(hasSelectedFile:selectedFileIsHero:searchActive:tagsActive:insideCollection:showingCollectionsPage:)`.

- [ ] **Step 1: Write the failing tests**

In `Muse/MuseTests/EscapeActionTests.swift`, every existing `EscapeResolver.action(...)` call must gain `tagsActive: false`. Add these new tests:

```swift
    // MARK: - Tag set is peeled after search, before collection

    func testTagsActiveClearsTags() {
        let action = EscapeResolver.action(hasSelectedFile: false,
                                           selectedFileIsHero: false,
                                           searchActive: false,
                                           tagsActive: true,
                                           insideCollection: false,
                                           showingCollectionsPage: false)
        XCTAssertEqual(action, .clearTags)
    }

    func testSearchBeatsTags() {
        // Search is peeled first (per the existing priority chain); tags next.
        let action = EscapeResolver.action(hasSelectedFile: false,
                                           selectedFileIsHero: false,
                                           searchActive: true,
                                           tagsActive: true,
                                           insideCollection: false,
                                           showingCollectionsPage: false)
        XCTAssertEqual(action, .clearSearch)
    }

    func testTagsBeatCollectionExit() {
        // Inside a collection with a tag set: Escape clears the tags first,
        // leaving the collection's full members; the next press exits it.
        let action = EscapeResolver.action(hasSelectedFile: false,
                                           selectedFileIsHero: false,
                                           searchActive: false,
                                           tagsActive: true,
                                           insideCollection: true,
                                           showingCollectionsPage: true)
        XCTAssertEqual(action, .clearTags)
    }

    func testViewerBeatsTags() {
        let action = EscapeResolver.action(hasSelectedFile: true,
                                           selectedFileIsHero: true,
                                           searchActive: false,
                                           tagsActive: true,
                                           insideCollection: false,
                                           showingCollectionsPage: false)
        XCTAssertEqual(action, .closeHero)
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild -scheme Muse -destination 'platform=macOS' test -only-testing:MuseTests/EscapeActionTests 2>&1 | tail -20`
Expected: FAIL — extra-argument / missing `.clearTags` compile errors.

- [ ] **Step 3: Add the `.clearTags` case + `tagsActive` param**

In `Muse/Muse/Components/EscapeAction.swift`, add the case to the enum (after `.clearSearch`):

```swift
    /// An active multi-tag chip selection — clear the WHOLE set (setActiveTag(nil)).
    case clearTags
```

Update `action(...)`:

```swift
    static func action(hasSelectedFile: Bool,
                       selectedFileIsHero: Bool,
                       searchActive: Bool,
                       tagsActive: Bool,
                       insideCollection: Bool,
                       showingCollectionsPage: Bool) -> EscapeAction {
        if hasSelectedFile {
            return selectedFileIsHero ? .closeHero : .closeViewer
        }
        if searchActive { return .clearSearch }
        if tagsActive { return .clearTags }
        if insideCollection { return .exitCollection }
        if showingCollectionsPage { return .exitCollectionsPage }
        return .none
    }
```

Update the doc comment above `action` to mention the tag layer sits between search and collection.

- [ ] **Step 4: Wire it in ContentView**

In `Muse/Muse/ContentView.swift`, the Escape handler (line ~264) — pass `tagsActive` and handle `.clearTags`:

```swift
                switch EscapeResolver.action(
                    hasSelectedFile: selected != nil,
                    selectedFileIsHero: isHero,
                    searchActive: searchPresent,
                    tagsActive: !appState.activeTagLabels.isEmpty,
                    insideCollection: appState.activeCollectionID != nil,
                    showingCollectionsPage: appState.showingCollections
                ) {
```

Add the case in the switch (after `.clearSearch`):

```swift
                case .clearTags:
                    // Clear the whole tag set in one press (not one tag at a time).
                    appState.setActiveTag(nil)
```

- [ ] **Step 5: Run the EscapeAction tests, then the full suite**

Run: `xcodebuild -scheme Muse -destination 'platform=macOS' test -only-testing:MuseTests/EscapeActionTests 2>&1 | tail -10`
Expected: `** TEST SUCCEEDED **`.

Run: `xcodebuild -scheme Muse -destination 'platform=macOS' test 2>&1 | tail -10`
Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 6: Commit**

```bash
git add "Muse/Muse/Components/EscapeAction.swift" "Muse/Muse/ContentView.swift" "Muse/MuseTests/EscapeActionTests.swift"
git commit -m "feat: Escape clears the whole multi-tag set (peeled after search)"
```

---

### Task 7: Manual verification + docs

**Files:**
- Modify: `CLAUDE.md` (phase log + durable notes), `docs/session-log.md` (narrative entry)

- [ ] **Step 1: Drive the app to verify the interactive flows**

Build & run; verify each:
- **Folder:** plain-click a chip → single-tag view (today's behavior). Cmd-click a second chip → grid narrows to the AND; banner reads "Viewing a and b". Cmd-click a third → "Viewing a, b, and c". An unrelated combination → empty grid (honest), banner still names the set.
- **Re-plain-click** the sole selected chip, or click **All** → clears.
- **Inside a collection:** chips filter within the collection's members; banner shows.
- **Search:** run a search → chip row stays mounted; Cmd-click chips narrows within the results (This-Folder and All scope); banner shows.
- **Escape:** with 2+ tags, one Escape clears the whole set. With search + tags, first Escape clears search, second clears tags. Viewer/collection ordering unchanged.
- **Delete Tag…** (right-click) still works and is single-tag only; menu-bar Rename/Delete/Remove enabled only with exactly one tag selected.

- [ ] **Step 2: Update CLAUDE.md and session-log.md**

Add a phase-log row (the multi-tag view is the third of the three 2026-06-20 browsing features) and a durable note if any non-obvious invariant emerged (e.g. "the per-label path query stays parent_dir-scoped; the intersection is computed in `setActiveTags`"). Add a dated `docs/session-log.md` entry mirroring the existing format.

- [ ] **Step 3: Commit**

```bash
git add CLAUDE.md docs/session-log.md
git commit -m "docs: record multi-tag view (AND/intersection) session"
```

---

## Self-Review

**1. Spec coverage:**
- Multi-select chips (plain replace / Cmd toggle) + AND filtering → Tasks 2, 3.
- "Viewing … and …" banner (2+) → Tasks 1, 4.
- Tag filtering over search + chip row mounted during search → Task 5.
- `EscapeResolver` clears full set → Task 6.
- Scope: folder / collection / search → Tasks 2 (folder+collection unchanged shape), 5 (search). Collections **card** page excluded (chip row not mounted there — unchanged).
- Out-of-scope confirmed: no bulk tag delete (deletion stays single, Tasks 2/6 keep Delete Tag single), no OR/AND toggle, no card-page filtering, no save-as-collection.
- Testing: pure selection/intersection/banner (Task 1), EscapeActionTests (Task 6), drive-verify (Task 7).

**2. Placeholder scan:** No TBDs; every code step shows complete code. The one "unchanged block" reference (Task 4 Step 2) explicitly says keep the existing ScrollView/alerts byte-for-byte and only re-parent them — that's a structural move, not a placeholder.

**3. Type consistency:** `activeTagLabels: [String]`, `singleActiveTag: String?`, `setActiveTags`, `setActiveTag`, `toggleActiveTag`, `pathsForTag`, `tagBannerText`, `TagSelection.toggling`, `TagSelection.bannerText`, `EscapeAction.clearTags`, `tagsActive:` param — all referenced consistently across tasks. `activeTagPaths` retained as the intersection. Note the intersection is computed in `setActiveTags` (the spec's `activeTagPaths` "computed as the intersection" is satisfied imperatively per mutation, not as a SwiftUI computed property — equivalent and matches the existing token/transaction pattern).
