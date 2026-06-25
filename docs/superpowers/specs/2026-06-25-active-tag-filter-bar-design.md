# Active-tag filter bar — always-visible & clearable

**Date:** 2026-06-25
**Status:** Design approved, pending spec review → implementation plan
**Area:** `Muse/Muse/Views/TagChipsRow.swift`, `Muse/Muse/Models/TagSelection.swift`, `Localizable.xcstrings`

## Problem

When a tag filter is active but the matching chips aren't representable in the
current scope, the user gets a confusing/stuck state:

1. **Single active tag is invisible across a context switch.** The "Viewing …"
   banner only renders for **2+** tags (`TagSelection.bannerText` returns `nil`
   for 0/1). A single selected tag is represented *only* by a highlighted chip
   in the scope-based chip row.

2. **Orphaned active tags vanish.** The top chip row only shows tags that exist
   in the current scope (`tagChipRows`). Carry a tag into a collection that has
   no images with it, and there's **no chip** for it — and if it's a single tag,
   **no banner either**. The grid is empty with zero on-screen indication a
   filter is active.

3. **No reliable way to clear when stuck.** The only clear affordances are the
   "All" chip (which disappears entirely when the scope has zero tags, i.e.
   `tags.isEmpty`) and the Escape key (undiscoverable). With orphaned tags and no
   "All" chip, the user cannot see the collection in full.

These compound specifically on **collection transitions** (folder→collection,
collection→collection, collection→folder), where active tags are deliberately
**carried over**. Folder→folder already auto-clears tags and is unaffected.

### Confirmed current behavior

| Transition | Active tags | Why |
|---|---|---|
| Folder → folder | **Cleared** (`select(folder:)` → `setActiveTag(nil, animated:false)`) | Deliberate: a fresh folder opens unfiltered. **Unchanged by this work.** |
| Folder → collection | **Kept** | `setActiveCollection` never touches `activeTagLabels`; chips reload to members. |
| Collection → collection | **Kept** | same |
| Collection → folder (back) | **Kept** | same |

`TagChipsRow` is mounted on the main grid **and inside an opened collection**
(`ContentView.swift` ~L64–76); it is hidden only on the collections *list* page
and during search-result-less states. So the bar described below renders in every
context where the bug occurs.

## Decision

Keep the carry-over policy exactly as-is (folder→folder clears; collections keep
tags). Fix the **visibility + clearability** by upgrading the existing
"Viewing …" banner in `TagChipsRow` into an **always-present, interactive
active-filter bar**.

Rejected alternatives:
- **Force orphaned tags into the top chip row** — inherits the confusing
  plain-click-replaces / Cmd-click-removes chip semantics, count-0 chips look
  broken, and "clear everything" stays non-obvious.
- **New dedicated filter-token toolbar** — a whole new component/layout that
  duplicates the banner. Overkill.

## Design

Upgrade the banner block in `TagChipsRow` (currently `TagChipsRow.swift`
L124–158) from a read-only label into an interactive bar.

### Visibility rule

Show the bar whenever **`activeTagLabels.count >= 1`** (was `>= 2`). This is the
deliberately-simple, never-hidden rule: "show only when it adds info" is exactly
the sometimes-invisible trap that caused the bug. The bar reads directly from
`activeTagLabels`, so it renders correctly for single tags, orphaned tags, and
collections whose chip row is empty.

Accepted cost: in a normal folder, a single in-scope tag is shown both as a
highlighted chip up top **and** as a removable pill in the bar. This mild
redundancy is preferred over conditional invisibility.

### Layout

A flat, horizontally-scrollable row (mirrors the existing banner scroll so long
sets scroll instead of squeezing):

```
Viewing   [ red ✕ ]   [ blue ✕ ]   [ landscape ✕ ]            Clear all
```

- Leading quiet **"Viewing"** label (localized, secondary style) — kept from
  today's banner.
- One **removable pill per active tag**, in `activeTagLabels` order. Each pill =
  the localized tag label (`VocabularyLocalizer.shared.display`) + a small **✕**
  affordance. Pills reuse the existing `BannerPill` resting wash so they read as
  the same family.
- A trailing **"Clear all"** control (text button / quiet pill), localized.
- The Oxford "and"/comma connective wording (`bannerSegments`'
  `precededByAnd` / `trailingComma`) is **dropped from the visual** — a flat
  token list fits the interactive ×-pill pattern better than prose. See
  Accessibility for what replaces the prose summary.

### Interactions

- **Remove one tag (pill ✕):** `appState.setActiveTags(appState.activeTagLabels.filter { $0 != label })`.
  This is the exact pattern already used in the tag-delete path
  (`AppState+Filters.swift` ~L220). Removing the last tag yields `[]` → resets to
  "All" (full scope). The core `setActiveTags` already commits labels
  synchronously, recomputes `activeTagPaths` (the intersection), bumps
  `tagFilterGeneration`, and clears the file selection — no new selection-pruning
  logic needed.
- **Clear all:** `appState.setActiveTag(nil)` (same call the "All" chip and
  Escape use). Resets to full scope.
- Existing behaviors untouched: the top chip row stays scope-based tag
  *discovery*; the "All" chip, re-click-to-clear, Cmd-click toggle, and the
  Escape `.clearTags` resolver all keep working.

### Animation

Keep the bar inside the existing `.animation(.easeInOut(duration: AppState.navTransition), value: appState.activeTagLabels)`
wrapper and the `.transition(.opacity)` on the bar block, so pills add/remove and
the bar appears/disappears with the current fade. No new animation surface.

### Accessibility

The bar is currently one `.accessibilityElement(children: .ignore)` with a single
combined label. Because pills become individually actionable, rework to:

- Each pill is a button labeled **"Remove *{tag}* from filter"** (localized;
  built from a runtime variable → `NSLocalizedString` / `String(localized:)`
  with the tag interpolated), trait-marked appropriately.
- The **"Clear all"** control is a button labeled **"Clear all tag filters"**
  (localized).
- Keep a readable summary for the bar so VoiceOver users still hear "what am I
  filtering by" — e.g. retain `TagSelection.bannerText(...)` as the container's
  summary label (it already reads naturally), or expose it via the pills'
  individual labels. Either is acceptable; do not regress the current spoken
  summary.

### Localization

Per CLAUDE.md rules (storage canonical-English, localize at display time). New
user-facing strings that must be wrapped + added to `Localizable.xcstrings`:

- `"Clear all"` (the control title) — `String(localized:)` / `Button`.
- `"Clear all tag filters"` (VoiceOver) — `String(localized:)`.
- `"Remove \(label) from filter"` (VoiceOver, runtime variable) —
  `NSLocalizedString` with the tag interpolated; add the key manually since the
  extractor can't see runtime-variable keys.
- Reuse existing localized `"Viewing"`.

After wrapping, run the export-localizations workflow and fill the `fr` values so
the catalog reports 0 untranslated.

## Out of scope

- No change to carry-over policy (folder→folder still clears).
- No change to the top scope-based chip row's discovery behavior.
- No change to tag storage, scoping, or the per-`(file_id, parent_dir)` identity.
- No new menu commands; Escape `.clearTags` stays as the keyboard path.

## Testing

- **Unit (`TagSelection` / pure):** the per-pill removal reduces to
  `activeTagLabels.filter { $0 != label }`; if any helper is added for it, unit
  test order-preservation and last-tag-removal → empty. `bannerText` /
  `bannerSegments` tests: update/relax only if their thresholds are repurposed
  for the new summary (don't break the English-host assertion rule).
- **Manual (the bug repro):**
  1. In a folder, select a single tag → bar shows `Viewing [tag ✕] Clear all`;
     ✕ and Clear all both return to full folder.
  2. Select a tag, open a collection with **no** matching images → grid empty,
     bar still shows the tag with ✕ + Clear all; either restores the full
     collection.
  3. Two+ tags carried into a collection with none of them → bar lists all with
     ✕ each + Clear all; removing them one by one and via Clear all both work.
  4. Collection → collection with the filter active → bar persists and stays
     clearable.
  5. Folder → folder still clears (unchanged).
- **VoiceOver:** each pill announces "Remove {tag} from filter" and activates;
  "Clear all tag filters" activates; bar summary still readable.
- Keep the existing unit suite green (`xcodebuild -scheme Muse test`).
