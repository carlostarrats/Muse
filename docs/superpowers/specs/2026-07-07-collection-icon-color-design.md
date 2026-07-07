# Collection icon + color customization (sidebar) — design

**Date:** 2026-07-07 · **Branch:** `feat/next-128` · **Status:** approved by owner

## What

Eagle-style per-collection appearance: right-click a sidebar collection →
"Customize…" → a modal with a preset color picker (16 round swatches +
Default) on the left and a curated SF Symbol grid (~36 + Default) on the
right, a live, accurate preview of the sidebar row up top, and
Cancel / Reset to Default / Update buttons. Owner decisions:

- **Color paints the icon only.** Name text + selection highlight stay
  exactly as today (primary / accent-when-selected).
- **Sidebar only.** Collections-page stack cards and hero pills unchanged.
- **~36 curated symbols**, one scroll-free grid; no SF Symbols browser.

## Data & persistence

- Migration `v10_collection_appearance`: `ALTER TABLE collections ADD`
  two nullable TEXT columns — `icon` (SF Symbol name) and `color`
  (canonical token, e.g. `"red"` — never a hex; tokens map to system
  colors that auto-adapt light/dark).
- `CollectionRow` gains `var icon: String?` / `var color: String?`.
- `nil`/`nil` = today's exact look (`square.stack.3d.up`, primary,
  accent when selected). Existing collections untouched; **Reset to
  Default** nulls both.
- A stored symbol that doesn't resolve on this OS falls back to the
  default icon (never a blank).
- Writes: `CollectionStore.setAppearance(queue:id:icon:color:)`
  (same shape as `setCover`); bumps `updated_at`.
- **Backup/restore:** `BackupCollection` gains optional `icon`/`color`
  (old archives decode → nil); `BackupBuilder` copies them out,
  `MaterializedCollection` + `ReconnectApplier`'s collections upsert
  carry them back in.
- Rejected alternative: UserDefaults keyed by collection id — wouldn't
  back up, leaks on delete. DB columns follow the `cover_file_id`
  precedent.

## Pure component

`Components/CollectionAppearance.swift` (unit-tested):

- `colorTokens`: 16 ordered tokens → SwiftUI system colors (red, orange,
  yellow, green, mint, teal, cyan, blue, indigo, purple, pink, brown,
  gray, plus 3 more to fill 16 — all legible on light + dark).
- `symbols`: the curated ~36 SF Symbol names (default stack icon first).
- `color(for token: String?) -> Color?` — nil / unknown token → nil
  (caller uses the default style).
- `resolvedIcon(_ name: String?) -> String` — validates via
  `NSImage(systemSymbolName:)`, falls back to `defaultIcon`.

## UI & behavior

- **Entry:** "Customize…" in `CollectionSidebarRow`'s context menu
  (between Rename and Delete) + a matching VoiceOver
  `accessibilityAction`.
- **Modal:** content-sized sheet (width-fixed, height-to-content — no
  raw fixed height, per the sheet constraint). Top: preview strip
  replicating the sidebar row (chevron spacing, chosen icon in chosen
  color, real name + alive count) on a sidebar-like background. Below,
  two columns: left a 4×4 grid of round swatches + a Default swatch
  (ring = selected); right a 6×6 symbol grid, default icon first
  (highlight = selected). Buttons: Cancel / Reset to Default / Update.
  Nothing persists until Update; Reset only resets the draft.
- **Row rendering:** stored icon replaces the hardcoded symbol; icon
  uses the custom color even when selected; everything else unchanged.
- **Refresh:** after Update, `CollectionsEngine.shared.reload()`.
- **Localization:** every new string wrapped + exported + French filled.

## Tests

- `CollectionAppearanceTests`: token table completeness (16), unknown
  token → nil, icon fallback, symbol list non-empty/valid.
- `CollectionStore` appearance setter + v10 migration column presence
  (mirrors existing store/migration test patterns).
- Backup round-trip: BackupCollection icon/color encode/decode +
  materializer carry.
