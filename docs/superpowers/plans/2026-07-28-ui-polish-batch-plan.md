# UI polish batch — implementation plan (2026-07-28)

Spec: `docs/superpowers/specs/2026-07-28-ui-polish-batch-design.md`
Branch: `feat/next-142`

Seven independent tasks, ordered smallest blast radius first. Each ends with a
build + the unit suite green; the visual ones also need a look in the running
app. Commit per task so any one can be reverted alone.

Verification command used throughout:

```
xcodebuild -project Muse/Muse.xcodeproj -scheme Muse build
xcodebuild -project Muse/Muse.xcodeproj -scheme Muse test
```

---

## Task 1 — Sidebar geometry to match Lineform

**Files:** `Views/SidebarView.swift`, `Views/Sidebar/FolderTreeNode.swift`,
`Views/Sidebar/CollectionSidebarRow.swift`, `Views/Sidebar/SidebarRows.swift`,
`Views/Sidebar/CustomizeCollectionSheet.swift`

1. Add the six metric constants to `SidebarView` (spec §7). Document each with
   the Lineform value it mirrors and the "slot + gap == 18 pins the icon
   column" invariant, so a future edit can't break alignment by changing one.

2. `FolderTreeNode.row`:
   - `HStack(spacing: 8)` → `HStack(spacing: 0)`.
   - Chevron: glyph to `chevronGlyphSize` (9), frame to
     `.frame(width: chevronSlotWidth, alignment: .trailing)`. The `Button`
     wrapper keeps `.contentShape(Rectangle())` over a 12×22 rect so the hit
     target does **not** shrink with the glyph.
   - Invisible placeholder branch (leaf rows) gets the identical slot.
   - Icon: `.padding(.leading, chevronToIconGap)`.
   - Text: `.padding(.leading, 8)` (was the HStack spacing).
   - Indent: `.padding(.leading, CGFloat(depth) * 14)` →
     `CGFloat(max(0, depth - 1)) * treeIndentStep`.
   - Height: `.frame(height: node.isRoot ? rootRowHeight : childRowHeight)`.

3. Same chevron-slot + icon-gap treatment in `CollectionSidebarRow` and
   `StarRow` (both draw an invisible chevron placeholder). Collections are flat
   — **no** indent change there.

4. `CustomizeCollectionSheet.preview` mirrors the new metrics exactly. It is a
   deliberate replica of `CollectionSidebarRow`; if it drifts, the preview lies.

**Verify:** run the app. Roots align with their direct children; grandchildren
step in by 14; chevrons sit tight to their folder icons; clicking a chevron
still expands/collapses reliably (the shrunken glyph must not shrink the target).

---

## Task 2 — Settings button in the toolbar

**Files:** `ContentView.swift`

1. Add `settingsItem(_ placement:)` next to `infoItem`: `gearshape`,
   `.moodToolbarIcon(appState.moodPalette)`, action
   `appState.settingsShown = true`, `.help("Settings")`,
   `.accessibilityLabel("Settings")`.
2. `spacedLeadingB`: insert `settingsItem(.automatic)` directly after
   `infoItem(.automatic)`, **no spacer between** (they fuse into one capsule).
   Element count goes 8 → 9, under the builder's 10 ceiling — confirm it still
   compiles rather than assuming.
3. `plainLeading`: same item, same position.

**Verify:** in the app, About and Settings render as one capsule on macOS 26;
the button opens the same modal ⌘, does; the icon recolors with the mood.

---

## Task 3 — Compact star badge

**Files:** `Components/StarRating.swift` (+ its test file), `Views/GridView.swift`

1. `StarRating.compactLabel(for:)` → `"\(n)★"` for 1…maxStars, nil otherwise.
2. `StarRating.fitsFullRun(_:availableWidth:)` — intrinsic width
   `n × starGlyphWidth + 2 × badgeHorizontalPadding` vs `availableWidth`.
   `starGlyphWidth` is a documented measured constant for the badge font
   (10pt semibold); measure it once with `NSAttributedString.size()` in a
   scratch check and hard-code the value with a comment saying how it was
   obtained.
3. `TileView` gains `slotSize: CGSize`; the call site in `masonryCanvas` passes
   `rect.size` (already in hand).
4. Add a private `drawnWidth` on `TileView`: for a non-image kind, `slotSize.width`;
   for an image kind, the min-scale fit of `drawnAspectRatio` into `slotSize`
   (same arithmetic as `ViewerGeometry.fitWithin`).
5. Badge site: choose `StarRating.label` vs `compactLabel` on
   `fitsFullRun(rating, availableWidth: drawnWidth - 2 × badgeInset)`. Add
   `.lineLimit(1)` as a backstop. Everything else about the badge is untouched —
   same capsule, colors, placement, fade-in-at-unmount timing,
   `accessibilityHidden` (the rating is announced via the tile's
   `accessibilityValue`, which keeps saying "N-star rating" either way).

**Tests:** `StarRatingTests` — `compactLabel` over 0…6 and nil; `fitsFullRun`
just-fits / just-doesn't per rating; compact is never wider than the full run.

**Verify:** in the app, drag the zoom slider down until tiles are narrow — the
badge swaps to `5★` instead of wrapping, and swaps back on widening.

---

## Task 4 — Sort-direction menu

**Files:** `ContentView.swift`, `Intelligence/Sort/SmartSorter.swift` (test only)

1. `sortDirectionButton` → `sortDirectionMenu`: a `Menu` whose label is today's
   `arrow.up` / `arrow.down` glyph with `.moodToolbarIcon`, containing an inline
   `Picker` bound to a computed `Binding<Bool>` for "ascending".
2. Two items per the active mode, titled by the existing
   `SortMode.directionLabel(ascending:)`, each with its direction's arrow as
   `systemImage`.
3. The binding's setter routes through `toggleSortDirection()` /
   `toggleCollectionSortDirection()` — never a direct `sortReversed` write, so
   `resort()` can't be skipped — and no-ops when the incoming value already
   matches.
4. **Keep `.menuIndicator(.hidden)`.** Durable constraint: a visible chevron
   makes macOS 26 render the Menu as its own isolated glass pill and it stops
   merging into the sort · direction · filter capsule.
5. Keep `.help(...)` and `.accessibilityLabel(...)` as they are.

**Tests:** assert every `SortMode` case yields two distinct, non-empty direction
labels.

**Verify:** the three-control capsule is still fused on macOS 26; picking a
direction re-sorts the grid and flips the arrow; the Collections page drives its
own independent sort.

---

## Task 5 — Menu icons + shortcuts

**Files:** `MuseApp.swift`

1. Convert every custom `Button("…")` in `.commands` to
   `Button { … } label: { Label("…", systemImage: "…") }`. Icon map per spec §3.
2. Add the 11 new shortcuts from the spec table. Leave destructive/rare items
   without one.
3. **Collision check before committing** (not an assumption): grep every
   `keyboardShortcut(` in the codebase, list (key, modifiers), assert no
   duplicates, and cross-check against the standard AppKit menu set (⌘N ⌘O ⌘S
   ⌘W ⌘P ⌘Q ⌘X ⌘C ⌘V ⌘A ⌘Z ⌘F ⌘,). Record the resulting table in the commit
   message.
4. Ratings menu: keep the `★` text labels; add `star.fill` / `star.slash` to
   the set/clear items only.

**Verify:** open every menu in the running app — icons render (no blank slots
from a mistyped symbol name), shortcuts appear beside their items, and each new
shortcut actually fires its action. Check ⌘R and ⌘D specifically while a search
field has focus (the field editor must still win where it should).

---

## Task 6 — Emoji as a collection symbol

**Files:** `Components/CollectionAppearance.swift`, new
`Components/CollectionIconView.swift`, `Views/Sidebar/CustomizeCollectionSheet.swift`,
`Views/Sidebar/CollectionSidebarRow.swift`, the Collections page card,
`MuseTests/CollectionAppearanceTests.swift`

1. **Model** (`CollectionAppearance`): add `Icon` enum, `resolve(_:default:)`,
   `encodeEmoji(_:)`, `isValidEmoji(_:)`, and the `emojiCatalog` (48 entries,
   6-wide grid, subject coverage mirroring the SF Symbol catalog).
   `isValidEmoji` counts **grapheme clusters** (`s.count == 1` on a Swift
   `String` already does this) and rejects pure-ASCII.
2. **Render** — new `CollectionIconView` (spec §1). Migrate
   `CollectionSidebarRow`, the Collections page card, and the sheet's preview
   to it. Emoji draw at `size + 2`, untinted, in the same 18pt slot.
3. **Sheet**: `@State private var iconTab` seeded from the stored icon's kind.
   Segmented `Picker` above the grid. Emoji tab = catalog grid + a one-cluster
   `TextField` + a button calling `NSApp.orderFrontCharacterPalette(nil)`.
   Color column `.disabled` + `.opacity(0.4)` + caption while on the Emoji tab.
   `isDefault` and Reset account for the emoji case.
4. **Save**: emoji persists `encodeEmoji(e)` with `color = nil`.
5. Localize the two segment titles and the caption (text-literal positions, so
   the compiler extracts them). VoiceOver label for an emoji cell is
   `String(localized: "Emoji \(e)")`.

**Tests:** per spec §1 — resolve round-trips, `isValidEmoji` accept/reject set
(single, ZWJ family, skin tone, flag / empty, double, ASCII), legacy raw symbol
still resolves to `.symbol`, and an encoded emoji is rejected by `isValidSymbol`
(proving an older build falls back rather than rendering garbage).

**Verify:** set an emoji on a collection — it shows in the sidebar row, the
Collections page card, and the live preview; the color swatches grey out;
Update persists across a relaunch; Reset returns to the stack glyph.

---

## Task 7 — Autocomplete for tags and collections

**Files:** new `Components/TagSuggest.swift` (+ tests), new
`Views/Modal/AddTagCard.swift`, new `Views/Modal/NameCollectionCard.swift`,
`Views/GridView.swift`, `ContentView.swift`,
`Views/Viewer/ViewerInfoColumn.swift`

1. **`TagSuggest`** (pure, per spec §5): `rank(_:query:exclude:displaying:limit:)`.
   Matching runs against the **display** term (diacritic- and case-insensitive),
   the returned label stays the canonical English key. Prefix beats substring,
   then count, then alphabetical — a stable total order. Always excludes
   `exclude` and any `StarRating.isRating` label.
2. **Hero viewer**: `CardExpander` takes the full candidate list and filters
   through `TagSuggest.rank` against its own `text`. Empty → today's top-24;
   typing narrows, capped at 12 so the pill flow can't push the create field off
   the card; no match → create affordance only. Same for the collection card
   against non-member names.
3. **Grid cards**: build `AddTagCard` and `NameCollectionCard` as `.museModal`
   content. Per the modal durable constraints:
   - presented at the **shell** (`ContentView`), never from a tile;
   - **naturally sized** — no inner `ScrollView`; at most 8 suggestion rows,
     then a "+N more" line;
   - draft in **local `@State`**, written to `AppState` only on commit;
   - built only while presented so `.onDisappear` fires.
   Keyboard: ↑/↓ highlight, Return commits highlighted or creates typed text,
   Escape dismisses through the existing `EscapeAction.dismissModal`.
4. **Remove** the `.alert("Add Tag")` from `GridView` and the
   `NameCollectionAlert` modifier from `ContentView`, replacing each with the
   card. Reuse the existing `addTagFile` / collection-request state as the
   trigger — only the presentation mechanism changes.
5. Every tag mutation still bumps `appState.tagsVersion` (grid-side paths all
   do; the viewer path historically forgot and it must not regress).

**Tests:** `TagSuggestTests` per spec §5 — empty-query top-N, prefix over
substring, stable total order under equal counts, `exclude` honoured, rating
glyphs never offered, diacritic-insensitive match, display transform applied to
matching but not to the returned label.

**Verify:** in the app — grid right-click → Add Tag shows existing tags filtered
as you type; picking one attaches it; typing a brand-new name still creates it;
↑/↓/Return/Escape all behave; the same in the hero viewer's tag and collection
cards; a rating (`★★★`) never appears as a suggestion anywhere.

---

## Close-out

1. `xcodebuild -exportLocalizations` to write new keys back into
   `Localizable.xcstrings`, then fill the French values. Per the localization
   convention, the feature isn't done until French is filled — treat it like a
   failing test.
2. Run the full unit suite in an **English** host (a French `AppleLanguages`
   override makes the `displayName`/toast tests read French and fail — expected,
   not a regression).
3. Update `CLAUDE.md`: one Polish-27 row in the status table, plus durable
   constraints for anything hard-won (the icon-column invariant in §7, the
   `emoji:` prefix in §1, the rating-glyph exclusion in §5's suggestions).
4. Add the session narrative to `docs/session-log.md` under `feat/next-142`.
