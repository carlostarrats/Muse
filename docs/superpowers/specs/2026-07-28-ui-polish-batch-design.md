# UI polish batch — design (2026-07-28)

Branch: `feat/next-142`

Seven independent UI improvements, batched into one branch because they're
small and touch disjoint files. Each section below is self-contained and can be
built, tested, and reviewed on its own.

Owner decisions locked at brainstorm time are marked **[decided]**.

---

## 1. Emoji as a collection symbol

### Problem

`CustomizeCollectionSheet` ("Symbol & Color") offers 36 curated SF Symbols and
27 color tokens. There's no way to use an emoji, which many users reach for
first when labelling a collection.

### Storage

Stays the single existing `collections.icon` TEXT column — **no migration**.
An emoji is written with an `emoji:` prefix:

```
"star"        → SF Symbol "star"
"emoji:🎨"    → the emoji 🎨
nil           → the kind-appropriate default glyph
```

The prefix is required, not optional: an SF Symbol name is always ASCII
`[a-z0-9.]`, so a bare emoji would be *distinguishable* today, but a prefix
makes the discriminator explicit and survives any future symbol-name grammar
change. Existing rows are untouched.

**Backward compatibility:** an older build reading `"emoji:🎨"` runs it through
`isValidSymbol`, gets false, and falls back to the default stack glyph. Degrades
cleanly; never blank.

### Model

`CollectionAppearance` gains a pure resolution type:

```swift
enum Icon: Equatable {
    case symbol(String)   // an SF Symbol name known to this OS
    case emoji(String)    // exactly one grapheme cluster
}

static func resolve(_ raw: String?, default def: String) -> Icon
static func encodeEmoji(_ e: String) -> String        // "emoji:" + e
static func isValidEmoji(_ s: String) -> Bool         // exactly 1 grapheme cluster, non-ASCII
```

`isValidEmoji` counts **grapheme clusters**, not scalars, so ZWJ sequences
(👨‍👩‍👧), skin-tone modifiers (👋🏽), and flags (🇫🇷) all count as one. It rejects
empty, multi-cluster, and plain-ASCII input.

`resolvedIcon(_:)` (the existing symbol-only resolver) stays for callers that
genuinely need a symbol name, but every *render* site moves to `resolve`.

### Rendering

A new shared view so the four render sites can't drift:

```swift
struct CollectionIconView: View {   // Components/
    let icon: CollectionAppearance.Icon
    var size: CGFloat = 12
    var tint: Color?     // ignored for .emoji
}
```

- `.symbol` → `Image(systemName:)` at `size` semibold, tinted.
- `.emoji` → `Text(e)` at `size + 2` (emoji render optically smaller than a
  semibold SF Symbol at the same point size), **untinted**.

Both occupy the same 18pt-wide slot so row geometry is identical either way.

Call sites migrated: `CollectionSidebarRow`, the Collections page card,
`CustomizeCollectionSheet`'s live preview, and the sheet's own grid cells.

### Picker UI **[decided: segmented tab]**

The Icon column gets a `Picker(.segmented)` above the grid:

```
Icon
[ Symbols | Emoji ]

  (Symbols tab: today's 6×6 grid, unchanged)

  (Emoji tab:)
  🎨 📸 🌊 🔥 🎬 🎵
  🏠 ✈️ 🍔 ⭐️ 💡 👑
  … 48 total, 6 wide × 8 rows …

  [ ▢  Type or paste an emoji ]   [⌘ button → system picker]
```

- The 48-emoji curated grid mirrors the SF Symbol catalog's subject coverage
  (nature, media, travel, food, objects) so the two tabs feel like the same
  set expressed twice.
- The trailing field accepts one grapheme cluster. Its button calls
  `NSApp.orderFrontCharacterPalette(nil)` — the system emoji picker — so any
  emoji is reachable, not just the 48.
- The field rejects invalid input silently (no error state); the Update button
  simply stays disabled until the draft is valid.

**Color column while Emoji is selected:** disabled and dimmed to 0.4, with a
caption under it — "Emoji use their own colors." Switching back to the Symbols
tab restores the previously chosen color from the draft (the draft keeps both
fields; only the *committed* value drops the color for an emoji).

**Which tab opens:** whichever matches the stored icon. Default/symbol → Symbols;
emoji → Emoji.

**Reset to Default** clears to `(.symbol(default), nil)` and returns to the
Symbols tab. `isDefault` (which disables the Reset button) accounts for the
emoji case.

**Save:** an emoji draft persists `encodeEmoji(e)` and **`color = nil`** (an
emoji's color is its own; storing a dead token would resurrect on a later
switch back to Symbols, which is surprising).

### Localization

`displayName(forEmoji:)` is not a switch — emoji have no useful English name to
translate. VoiceOver reads the emoji cell as `String(localized: "Emoji \(e)")`,
which is what a screen reader announces usefully anyway (VoiceOver speaks the
emoji's own system name). The segmented control's two titles are literals in
`Picker`/`Text` position, so the compiler extracts them.

### Tests (`CollectionAppearanceTests`)

- `resolve` round-trips symbol, emoji, nil, and an unknown symbol name.
- `isValidEmoji`: accepts single emoji, ZWJ family, skin-tone, flag; rejects
  empty, two emoji, `"a"`, `"ab"`.
- A legacy raw symbol name still resolves to `.symbol`.
- `encodeEmoji` output is rejected by `isValidSymbol` (proves an old build
  falls back rather than rendering garbage).

---

## 2. Sort-direction button becomes a menu

### Problem

The toolbar's bare ↓ arrow toggles direction on click. What it will do isn't
discoverable — you have to click and observe.

### Change

`sortDirectionButton` → `sortDirectionMenu`: a `Menu` whose label is the same
arrow glyph as today (`arrow.up` when ascending, `arrow.down` when descending)
and whose content is a two-item inline `Picker` bound to the active
`sortReversed` flag, with each item titled by the **existing**
`SortMode.directionLabel(ascending:)`:

| Mode | Items |
|---|---|
| Date Modified / Created | Newest first · Oldest first |
| Name / Kind | A → Z · Z → A |
| Size | Largest first · Smallest first |
| Shape | Wide → tall · Tall → wide |
| Rating | Highest first · Lowest first |
| Color | Descending · Ascending |

These strings already exist and already ship localized — no new keys, and the
language is already the platform-standard phrasing the owner asked for.

Each item carries its direction's arrow as its `systemImage`; the active one
gets the Picker's native checkmark.

The binding writes through `toggleSortDirection()` /
`toggleCollectionSortDirection()` (never `sortReversed` directly) so the
`resort()` side effect can't be bypassed. Selecting the already-active item is a
no-op — the setter compares before flipping.

### Constraint

**`.menuIndicator(.hidden)` is mandatory.** Per the durable toolbar constraint,
a visible dropdown chevron makes macOS 26 render the Menu as its own isolated
glass pill, breaking the sort · direction · filter capsule. The sort menu beside
it already does this for the same reason.

### Tests

`SortModeTests` already covers `directionLabel`. Add a test that the two
direction items for every `SortMode` case are distinct non-empty strings (guards
a future mode added without a label branch).

---

## 3. Menu icons + keyboard shortcuts **[decided: icons everywhere, shortcuts where sensible]**

### Icons

Every custom item in `MuseApp.commands` becomes `Label(_, systemImage:)`. Full
mapping in the plan; representative: Back Up Muse → `arrow.down.doc`, Find
Duplicates → `square.on.square`, Import Keywords → `square.and.arrow.down`,
Rename Tag → `pencil`, Delete Tag → `trash`, Clear Tag Filter →
`line.3.horizontal.decrease.circle.fill`, Back to Library → `photo.on.rectangle`.

Ratings keep their `★` text labels (the glyph *is* the label) but gain
`star.fill` / `star.slash` on the set/clear items.

### Shortcuts

New assignments, chosen to avoid the system Edit/View menus, the `.searchable`
field editor, and each other:

| Item | Shortcut |
|---|---|
| Find Duplicates in Folder | ⌘D |
| Import Keywords & Ratings… | ⇧⌘I |
| New Subfolder… | ⌃⌘N |
| Rename Folder… | ⌘R |
| Set as Collection Cover | ⌃⌘C |
| New Collection from Selection… | ⌥⌘N |
| Rename Collection… | ⌥⌘R |
| Back to Library | ⌘L |
| Clear Tag Filter | ⌥⌘K |
| Rename Tag… | ⌃⌘R |
| Manage Drive Shares… | ⇧⌘L |

Deliberately **no** shortcut: Delete Tag, Delete Collection, Delete All Tags,
Regenerate Tags, Remove Folder, Move Folder/Collection Up/Down, Restore from
Backup. Destructive or rare — a shortcut on a destructive item invites accidents,
and Apple HIG reserves shortcuts for frequent actions.

Existing shortcuts (⌘, ⇧⌘A ⇧⌘P ⌘0–⌘5) are unchanged.

**Collision check is part of the build**, not an assumption: before committing,
enumerate every `keyboardShortcut` in the codebase plus the standard AppKit menu
set and assert no duplicate (key, modifiers) pair.

### Localization

`Label("Text", systemImage:)` is a text-literal position — the compiler extracts
it. No hand-wrapping needed. `-exportLocalizations` runs at the end of the batch
to write back any new keys.

---

## 4. Settings button in the toolbar

A new `settingsItem` (`gearshape`) placed **immediately after `infoItem`, with
no `ToolbarSpacer` between them**, so on macOS 26 the two fuse into a single
glass capsule and read as an About/Settings pair. Action: `appState.settingsShown
= true` — identical to the ⌘, command, so there is one presentation path.

`spacedLeadingB` goes from 8 to 9 `ToolbarContent` elements, under the
`@ToolbarContentBuilder.buildBlock` ceiling of 10. `plainLeading`
(Sonoma/Sequoia) gets the same item in the same position.

Uses `.moodToolbarIcon(appState.moodPalette)` like every sibling, so it
participates in the synchronized mood recolor.

---

## 5. Autocomplete when adding a tag or a collection **[decided: convert grid alerts to modal cards]**

### Problem

Three surfaces let you attach a tag or collection, and none of them prevents a
near-duplicate:

| Surface | Today |
|---|---|
| Hero viewer `CardExpander` | Shows a **static** top-24 candidate list that does **not** react to typing |
| Grid `.alert("Add Tag")` | Bare `TextField`, no suggestions at all |
| Grid `NameCollectionAlert` | Bare `TextField`, no suggestions at all |

A SwiftUI `.alert` can only host `TextField`s and `Button`s — a suggestion list
is structurally impossible inside one. So the two grid alerts must become
in-window modal cards.

### Shared logic: `TagSuggest` (pure, `Components/`)

```swift
enum TagSuggest {
    struct Candidate: Equatable { let label: String; let count: Int }

    /// Rank + filter existing labels against what the user has typed.
    /// - Empty query → the top `limit` by `count` (today's behavior).
    /// - Non-empty  → case- and diacritic-insensitive match on the DISPLAY
    ///   term, prefix matches ranked above substring matches, then by count,
    ///   then alphabetically (a stable total order — no ties left to chance).
    /// - Always excludes `exclude` (labels already on the file) and any
    ///   `StarRating.isRating` label.
    static func rank(_ all: [Candidate],
                     query: String,
                     exclude: Set<String>,
                     displaying: (String) -> String,
                     limit: Int) -> [Candidate]
}
```

Matching runs against the **localized display term** (what the user sees and
types), while the returned `label` stays the canonical English key that gets
written — the display-time-localization rule.

The rating-glyph exclusion is a hard requirement, not a nicety: `addManualTag`
has no mutual exclusion, so offering `★★★` as an attachable tag would let a file
carry two ratings and break `StarRating.resolution`.

### Hero viewer

`CardExpander` gains live filtering: it takes the full candidate list plus the
current text and renders `TagSuggest.rank(...)`. Empty field → today's top-24.
Typing narrows. No match → only the create affordance, so free-text creation
always still works. The collection card gets the same treatment against
non-member collection names.

Suggestion count is capped (12 while filtering) so the pill flow can't grow
unbounded and push the create field off-card.

### Grid

`.alert("Add Tag")` and `NameCollectionAlert` become `.museModal` cards:

```
┌──────────────────────────────┐
│ Add Tag                    ✕ │
│ To “beach-01.jpg”            │
│ ┌──────────────────────────┐ │
│ │ type a tag…              │ │
│ └──────────────────────────┘ │
│  sunset            48        │
│  sunrise           12        │  ← existing, click or ↑↓+Return
│  sun                4        │
│                              │
│         Cancel      Add      │
└──────────────────────────────┘
```

Modal constraints that apply (all from the durable-constraints list):

- Presented at the **shell** (`ContentView`), never from a row or tile — a card
  is sized from its host's geometry.
- Content is **naturally sized**: no inner `ScrollView`. The suggestion list is
  a plain `VStack` of at most 8 rows; beyond that it truncates with a
  "+N more" line rather than scrolling.
- The draft is **local `@State`** inside the card, written to `AppState` only on
  commit — never a per-keystroke write to a `@Published` on `AppState`.
- Built only while presented, so `.onDisappear` genuinely fires.

Keyboard: ↑/↓ moves a highlight through the suggestions, Return commits the
highlighted one, Return with no highlight creates the typed text, Escape
dismisses (via `EscapeAction.dismissModal`, which already resolves above the
viewer).

The existing `addTagFile` / collection-request state on `AppState` is reused
as the presentation trigger; only the presentation *mechanism* changes.

### Tests (`TagSuggestTests`)

Empty query returns top-N by count; prefix beats substring; the ordering is a
stable total order under equal counts; `exclude` is honoured; rating glyphs
never appear; diacritic-insensitive match ("cafe" finds "café"); a display
transform is applied to matching but not to the returned label.

---

## 6. Compact star badge on narrow tiles **[decided: automatic]**

### Problem

The grid tile's rating badge is `Text("★★★★★")`. On a narrow tile the run wraps
to a second line and the badge grows into a block.

### Change

`StarRating` gains two pure members:

```swift
static func compactLabel(for n: Int) -> String?   // "5★"
static func fitsFullRun(_ n: Int, availableWidth: CGFloat) -> Bool
```

`fitsFullRun` compares the badge's known intrinsic width for `n` stars —
`n × starGlyphWidth + horizontalPadding × 2`, with `starGlyphWidth` a measured
constant for the badge's 10pt semibold font — against the width the badge may
occupy: the tile's **drawn-image** width (the badge lives inside `contentStack`,
which for an image kind is aspect-fitted to the photo, so the slot width would
be wrong for a letterboxed tile in Grid mode).

`TileView` doesn't currently know its slot size — the `.frame(width:height:)` is
applied by the caller. It gains a `slotSize: CGSize` parameter, passed straight
from the `rect` the call site already has, and derives the drawn width by the
same min-scale fit as `ViewerGeometry.fitWithin` against `drawnAspectRatio`.
That's pure arithmetic on values the tile already holds — **no measurement pass
and no `GeometryReader`**. For non-image kinds the card fills the slot, so drawn
width is the slot width.

Below the threshold the badge renders `compactLabel` instead. `lineLimit(1)`
is added as a backstop so a future font change can't reintroduce wrapping.

Everything else about the badge is unchanged: same near-white capsule, same
black glyphs, same placement, same fade-in-at-unmount timing, same
`accessibilityHidden` (the rating is announced through the tile's
`accessibilityValue`, which always speaks the full "N-star rating" regardless of
which visual form is drawn).

No new setting. The existing `showStarsOnGrid` toggle still governs visibility.

### Tests (`StarRatingTests`)

`compactLabel` for 1…5 and nil/out-of-range; `fitsFullRun` at the boundary
width for each rating (just-fits and just-doesn't); the compact form is never
longer than the full run.

---

## 7. Sidebar chevrons, spacing, and indentation → Lineform

### Reference

Read from `Lineform/Outline/OutlineSidebarView.swift` (a sibling project by the
same owner, whose sidebar is the target look):

| | Muse today | Lineform | Action |
|---|---|---|---|
| chevron glyph | 10pt semibold | **9pt semibold** | change |
| chevron slot | 10pt, centered | **12pt, right-aligned** | change |
| chevron → icon gap | 8 (HStack spacing) | **6** (explicit padding) | change |
| slot + gap | 18 | 18 | **unchanged** — icon column holds |
| first child indent | 14 | **0** | change |
| deeper levels | +14 each | +14 each | unchanged |
| root row height | 28 | 28 | unchanged |
| child row height | 28 | **26** | change |

Two real differences. The chevron is smaller and **right-aligned in a wider
slot**, so it sits close to the icon it discloses rather than centered in dead
space. And a root's direct children sit at the **same x as the root**, with only
grandchildren stepping in — `depth * 14` becomes `max(0, depth - 1) * 14`.
Because slot + gap still sums to 18, the icon column doesn't move; only the
chevron and the indent do.

### Implementation

The metrics become named constants on `SidebarView` so the surfaces can't drift:

```swift
static let chevronSlotWidth: CGFloat = 12
static let chevronToIconGap: CGFloat = 6
static let chevronGlyphSize: CGFloat = 9
static let treeIndentStep: CGFloat = 14
static let rootRowHeight: CGFloat = 28
static let childRowHeight: CGFloat = 26
```

The row `HStack` moves from `spacing: 8` to `spacing: 0` with explicit per-element
leading padding — that's what lets the chevron occupy a wider right-aligned slot
without moving the icon.

Applied to all four surfaces that draw this row shape:

1. `FolderTreeNode.row` — chevron, indent, and the root-vs-child height split.
2. `CollectionSidebarRow` — chevron placeholder + icon slot (collections are
   flat, so no indent change).
3. `StarRow` — chevron placeholder + icon slot.
4. `CustomizeCollectionSheet.preview` — **must** track, or the live preview
   stops being an accurate replica of the row it previews.

### Risk

Purely visual, no state or data involved. The one thing to watch: the row's
`.contentShape(Rectangle())` and the disclosure `Button`'s own contentShape must
still cover their new slot widths, or the chevron's hit target shrinks with its
glyph. The chevron button keeps a 12×22 hit rect regardless of the 9pt glyph.

---

## Build order

Independent; sequenced by blast radius, smallest first:

1. §7 sidebar geometry (visual only, 4 files)
2. §4 settings toolbar button (1 file)
3. §6 compact star badge (2 files + tests)
4. §2 sort-direction menu (2 files)
5. §3 menu icons + shortcuts (1 file, wide)
6. §1 emoji symbols (3 files + tests)
7. §5 autocomplete (5 files + tests — the largest)

Each step: build, run the unit suite, verify in the running app.

## Out of scope

- No DB migration (§1 reuses the existing `icon` column).
- No change to how tags/collections are *stored* — §5 is purely an input affordance.
- No new user settings.
- Search-field autocomplete is unchanged (§5 is about the add-tag/collection
  inputs only).
