# Active-tag filter bar Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Upgrade the read-only "Viewing…" banner in `TagChipsRow` into an always-visible (1+ tags), interactive active-filter bar where each active tag is a removable pill and a "Clear all" wipes the filter — so single tags and orphaned tags (carried into a collection with no matches) are never invisible or unclearable.

**Architecture:** A pure order-preserving `TagSelection.removing(_:_:)` helper (unit-tested) backs per-pill removal; the SwiftUI banner block in `TagChipsRow` is rewritten to render removable token pills + a Clear-all control, shown whenever `activeTagLabels.count >= 1`. No change to carry-over policy, tag storage, or the scope-based discovery chip row.

**Tech Stack:** Swift / SwiftUI / AppKit, GRDB (untouched here), XCTest (`MuseTests`), Xcode 16, `Localizable.xcstrings`.

## Global Constraints

- **Folder→folder still auto-clears tags; collections still keep tags.** Do NOT change `select(folder:)` or `setActiveCollection`. (CLAUDE.md / spec)
- **Localize every new user-facing string.** Literals → `String(localized:)`; runtime-variable strings (the tag label) → `NSLocalizedString(_, comment:)` with the key added to `Localizable.xcstrings` manually. Storage stays canonical-English. (CLAUDE.md)
- **Tags are per `(file_id, parent_dir)`; no library-wide tag mutation here.** This work only changes the *filter* (`activeTagLabels`), never tag rows.
- **Mutate the active set only via `setActiveTags` / `setActiveTag`** — they commit `activeTagLabels` synchronously, recompute `activeTagPaths` (the AND intersection), bump `tagFilterGeneration`, and clear the file selection. Do not write `activeTagLabels` directly.
- **`TagSelection` is `nonisolated`** (called from nonisolated tests) — keep new members nonisolated.
- **Run the unit suite in an English host** (`xcodebuild -scheme Muse test`); enum/banner assertions assert English source.
- Build: `xcodebuild -scheme Muse -project Muse/Muse.xcodeproj build`. Test: `xcodebuild -scheme Muse -project Muse/Muse.xcodeproj test`.

---

### Task 1: Pure `TagSelection.removing` helper

**Files:**
- Modify: `Muse/Muse/Models/TagSelection.swift` (add a member alongside `toggling`/`renaming`)
- Test: `Muse/MuseTests/TagSelectionTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `static func removing(_ labels: [String], _ label: String) -> [String]` — returns `labels` with every occurrence of `label` filtered out, original order preserved; removing the sole label yields `[]`. Used by `TagChipsRow`'s per-pill ✕ in Task 2.

- [ ] **Step 1: Write the failing tests**

Add to `Muse/MuseTests/TagSelectionTests.swift` (inside the existing `TagSelectionTests` class):

```swift
func testRemovingDropsTheLabel() {
    XCTAssertEqual(TagSelection.removing(["blue", "screenshot"], "blue"),
                   ["screenshot"])
}

func testRemovingSoleLabelEmptiesSelection() {
    XCTAssertEqual(TagSelection.removing(["blue"], "blue"), [])
}

func testRemovingAbsentLabelIsNoOp() {
    XCTAssertEqual(TagSelection.removing(["blue", "screenshot"], "navy"),
                   ["blue", "screenshot"])
}

func testRemovingPreservesOrderOfSurvivors() {
    XCTAssertEqual(TagSelection.removing(["a", "b", "c"], "b"),
                   ["a", "c"])
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild -scheme Muse -project Muse/Muse.xcodeproj test -only-testing:MuseTests/TagSelectionTests 2>&1 | tail -20`
Expected: FAIL — compile error "type 'TagSelection' has no member 'removing'".

- [ ] **Step 3: Add the implementation**

In `Muse/Muse/Models/TagSelection.swift`, after `toggling(_:_:)` (before `renaming`):

```swift
    /// Per-pill removal from the active-filter bar: drop every occurrence of
    /// `label`, preserving the order of the survivors. Removing the sole label
    /// yields an empty selection (back to "All").
    static func removing(_ labels: [String], _ label: String) -> [String] {
        labels.filter { $0 != label }
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcodebuild -scheme Muse -project Muse/Muse.xcodeproj test -only-testing:MuseTests/TagSelectionTests 2>&1 | tail -20`
Expected: PASS (all `TagSelectionTests`, including the 4 new cases).

- [ ] **Step 5: Commit**

```bash
git add Muse/Muse/Models/TagSelection.swift Muse/MuseTests/TagSelectionTests.swift
git commit -m "feat: TagSelection.removing helper for per-pill tag removal"
```

---

### Task 2: Interactive active-filter bar in `TagChipsRow`

**Files:**
- Modify: `Muse/Muse/Views/TagChipsRow.swift` (the banner block ~L124–158; `BannerPill` ~L349–363)

**Interfaces:**
- Consumes: `TagSelection.removing(_:_:)` (Task 1); `appState.activeTagLabels`, `appState.setActiveTags(_:)`, `appState.setActiveTag(_:)`, `VocabularyLocalizer.shared.display(_:)`.
- Produces: nothing for later tasks (self-contained view change).

This task replaces the read-only banner with an interactive bar shown whenever `appState.activeTagLabels.count >= 1`. The top scope-based chip row (the `if !tags.isEmpty { ScrollView … }` block above) is **unchanged**.

- [ ] **Step 1: Make `BannerPill` carry an inline remove control**

In `Muse/Muse/Views/TagChipsRow.swift`, replace the `BannerPill` struct (~L349–363) with a removable version. It keeps the resting wash but adds a trailing ✕ button:

```swift
/// Removable token used in the active-filter bar ("Viewing [red ✕] [blue ✕]").
/// The label + ✕ share one capsule; tapping ✕ removes just this tag from the
/// filter. `label` is already localized for display; `onRemove` is wired to the
/// canonical label by the caller.
private struct BannerPill: View {
    let label: String
    var onRemove: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
                .foregroundStyle(.primary)
            if let onRemove {
                Button(action: onRemove) {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .contentShape(Rectangle())
                .accessibilityLabel(Text(String(format: NSLocalizedString(
                    "Remove %@ from filter",
                    comment: "VoiceOver: remove one tag from the active filter"),
                    label)))
            }
        }
        .padding(.leading, 8)
        .padding(.trailing, onRemove == nil ? 8 : 6)
        .padding(.vertical, 2)
        .background(Capsule(style: .continuous).fill(.primary.opacity(0.08)))
    }
}
```

- [ ] **Step 2: Rewrite the banner block as the interactive bar**

In `Muse/Muse/Views/TagChipsRow.swift`, replace the whole `if let banner = localizedBannerText { … }` block (~L128–158) with a bar that renders for **1+** tags. Note `localizedActiveLabels` (L39–41) stays the display source; pair each with its canonical label via `appState.activeTagLabels` by index:

```swift
        // Active-filter bar: shown whenever 1+ tags are active (single tags
        // included, unlike the old 2-tag banner). Reads straight from
        // activeTagLabels, so orphaned tags carried into a collection with no
        // matches stay visible and removable. Each pill removes one tag; Clear
        // all wipes the filter back to "All".
        if !appState.activeTagLabels.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    Text("Viewing")
                        .foregroundStyle(.secondary)
                    // Canonical labels drive the action; display labels are shown.
                    ForEach(Array(appState.activeTagLabels.enumerated()),
                            id: \.element) { _, canonical in
                        BannerPill(label: VocabularyLocalizer.shared.display(canonical)) {
                            appState.setActiveTags(
                                TagSelection.removing(appState.activeTagLabels, canonical))
                        }
                    }
                    Button(String(localized: "Clear all")) {
                        appState.setActiveTag(nil)
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 4)
                    .accessibilityLabel(Text(String(localized: "Clear all tag filters")))
                }
                .font(.system(size: 12, weight: .medium))
                .padding(.horizontal, 14)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, 10)
            .transition(.opacity)
        }
```

Notes for the implementer:
- `id: \.element` is safe — `activeTagLabels` is a de-duplicated ordered set (enforced by `setActiveTags`/`toggling`/`renaming`), so labels are unique.
- Leave the `localizedBannerText` / `localizedActiveLabels` / `localizedActiveLabels`-based computed props in place only if still referenced; if `localizedBannerText` and `bannerSegments` usage is now dead in this file, remove the now-unused `localizedBannerText` computed property (L45–49) to avoid a dead-code warning. Keep `localizedActiveLabels` only if used; otherwise inline the display call (it is now inlined above) and delete it. `TagSelection.bannerText`/`bannerSegments` themselves stay in the model (still unit-tested) — only this view's usage changes.
- Do NOT touch the `.animation(.easeInOut(duration: AppState.navTransition), value: appState.activeTagLabels)` modifier at the end of `body` (~L160) — pills animate in/out under it.

- [ ] **Step 3: Build**

Run: `xcodebuild -scheme Muse -project Muse/Muse.xcodeproj build 2>&1 | tail -25`
Expected: `** BUILD SUCCEEDED **`, no unused-variable/dead-code warnings from `TagChipsRow.swift`.

- [ ] **Step 4: Manual smoke test (the bug repro)**

Build & run (Cmd+R) and verify:
1. Folder + one tag selected → bar shows `Viewing [tag ✕]  Clear all`; ✕ and Clear all each return to the full folder.
2. Select a tag, open a collection with **no** matching images → grid empty, bar still shows `[tag ✕]  Clear all`; either restores the full collection.
3. 2+ tags carried into a collection with none of them → bar lists each with ✕ + Clear all; one-by-one removal and Clear all both work.
4. Collection → collection with filter active → bar persists, stays clearable.
5. Folder → folder → tags clear (unchanged).

- [ ] **Step 5: Commit**

```bash
git add Muse/Muse/Views/TagChipsRow.swift
git commit -m "feat: always-visible, clearable active-tag filter bar"
```

---

### Task 3: Localize the new strings (French)

**Files:**
- Modify: `Muse/Muse/Localizable.xcstrings` (write-back via export tool, then fill `fr`)

**Interfaces:**
- Consumes: the wrapped strings introduced in Task 2 — `"Clear all"`, `"Clear all tag filters"`, and the `NSLocalizedString("Remove %@ from filter", …)` key. `"Viewing"` already exists in the catalog.
- Produces: nothing for later tasks.

- [ ] **Step 1: Export localizations to write the new keys into the catalog**

Run:
```bash
xcodebuild -exportLocalizations -project Muse/Muse.xcodeproj \
  -localizationPath /tmp/muse-loc -exportLanguage fr 2>&1 | tail -5
```
Expected: completes; the compiler-visible keys `Clear all` and `Clear all tag filters` are written back into `Muse/Muse/Localizable.xcstrings` with empty `fr` values.

- [ ] **Step 2: Add the runtime-variable key manually**

The extractor cannot see `NSLocalizedString("Remove %@ from filter", …)` (runtime variable). Add it by hand to `Muse/Muse/Localizable.xcstrings` with the same shape as other manually-added keys (a `"Remove %@ from filter"` entry with an English `en` value `"Remove %@ from filter"` and a `fr` translation). Match an existing `%@`-format entry's JSON structure in the file.

- [ ] **Step 3: Fill the French values**

In `Muse/Muse/Localizable.xcstrings`, set:
- `Clear all` → `Tout effacer`
- `Clear all tag filters` → `Effacer tous les filtres de tags`
- `Remove %@ from filter` → `Retirer %@ du filtre`

- [ ] **Step 4: Verify catalog has no untranslated new keys + build**

Run:
```bash
xcodebuild -exportLocalizations -project Muse/Muse.xcodeproj -localizationPath /tmp/muse-loc2 -exportLanguage fr 2>&1 | tail -5
xcodebuild -scheme Muse -project Muse/Muse.xcodeproj build 2>&1 | tail -5
```
Expected: export reports the three keys translated (0 newly untranslated); `** BUILD SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add Muse/Muse/Localizable.xcstrings
git commit -m "i18n: French strings for the active-tag filter bar"
```

---

## Self-Review

**Spec coverage:**
- Visibility rule (show when 1+) → Task 2 Step 2 (`if !appState.activeTagLabels.isEmpty`). ✅
- Removable pill per tag → Task 2 Steps 1–2 + Task 1 helper. ✅
- Clear all → Task 2 Step 2 (`setActiveTag(nil)`). ✅
- Orphan-safe (reads `activeTagLabels`, not scope chips) → Task 2 Step 2. ✅
- Carry-over policy unchanged → Global Constraints; no task touches `select(folder:)`/`setActiveCollection`. ✅
- VoiceOver per-pill + Clear-all labels → Task 2 Steps 1–2. ✅
- Localization (3 strings, runtime-var key manual) → Task 3. ✅
- Drop Oxford prose from the visual → Task 2 Step 2 (flat token list). ✅
- Tests: pure removal unit-tested (Task 1); manual repro (Task 2 Step 4); suite stays green. ✅

**Placeholder scan:** none — every code step shows full code. ✅

**Type consistency:** `TagSelection.removing(_:_:) -> [String]` defined Task 1, called Task 2 with `(appState.activeTagLabels, canonical)`. `setActiveTags(_:)` / `setActiveTag(_:)` match `AppState+Filters.swift`. `BannerPill(label:onRemove:)` defined and called within Task 2. ✅
