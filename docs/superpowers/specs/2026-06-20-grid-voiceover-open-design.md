# Grid VoiceOver "Open" Action — design

**Date:** 2026-06-20
**Status:** Approved (brainstorm complete) — scope: Option A
**Ships as:** its own branch

## Summary

Give grid tiles a VoiceOver-activatable **"Open"** action so a VoiceOver user
can open a file into the viewer. Today a tile is exposed as a labeled button
with its selected state announced, but **activating it only selects** — there is
no keyboard/VoiceOver path to *open* it into the hero/viewer. Opening happens in
exactly one place (`GridView.handleTileTap`, `appState.selectedFile = file`) and
only via the **mouse double-click** timing window, which VoiceOver activation
cannot reproduce. This adds a primary accessibility action that opens, and fixes
the misleading hint.

This is the small, clearly-correct, zero-conflict part of grid accessibility.
**It does not touch the arrow keys at all** — plain ↑/↓ keep scrolling the grid
exactly as today (a deliberate constraint, see below).

## Motivation

A VoiceOver user can already *navigate* the grid: VoiceOver moves its own cursor
tile-to-tile with Control-Option-arrows (independent of the app's key handling),
and each tile announces its filename + selected state. The one missing capability
is **opening** the focused tile. Activating a tile (Control-Option-Space) fires
the tile's `onTapGesture`, which runs the single-tap path = *select*. The
double-click-to-open path is a real-time mouse-timing mechanism with no VoiceOver
equivalent, so opening is effectively **mouse-only** — a real accessibility gap.

## What we are NOT doing (scope boundaries)

- **No arrow-key changes.** Plain ↑/↓ currently scroll the grid (macOS default
  scroll-view line-scroll); the full-page jump is on Page Up/Down (`Fn`+arrow on
  laptops) via `PageScrollCatcher`. Both are preserved unchanged. VoiceOver users
  navigate with Control-Option-arrows, which never reach the app's plain-arrow
  handling, so no repurposing is needed or wanted.
- **No keyboard-only (non-VoiceOver) tile navigation.** Supporting a sighted
  keyboard-only user (Tab into the grid, arrow a focus ring, Space/Return to
  open) is the macOS **Full Keyboard Access** story and a larger piece (focus
  management over the virtualized grid). It is **deferred** — noted here as a
  future add, not built now.
- **No new menu command, no new keyboard shortcut, no mouse-behavior change.**
  The existing single-click-select / double-click-open / right-click-menu mouse
  flow is untouched.

## The change

In `GridView`'s tile (`Views/GridView.swift`, the per-tile modifiers around the
existing `.accessibilityElement(children: .ignore)` / `.accessibilityLabel` /
`.accessibilityAddTraits` / `.accessibilityHint` block):

1. **Add a primary (default) accessibility action that opens the file:**
   ```swift
   .accessibilityAction {
       appState.selectedFile = file
   }
   ```
   `appState.selectedFile = file` is the exact trigger the mouse double-click uses
   (`handleTileTap`, GridView.swift:60), so VoiceOver "open" routes through the
   identical path — the hero viewer for images, `ViewerRouter`/`ViewerChrome` for
   other kinds. The mouse `onTapGesture` is untouched (the accessibility action
   only affects the VoiceOver layer), so single-click-select / double-click-open
   keep working exactly as before.

2. **Fix the misleading hint.** The current hint —
   `"Double-tap to open. Right-click for actions."` — describes a mouse gesture
   and, on macOS VoiceOver, "double-tap" reads oddly (activation is
   Control-Option-Space). Replace it with an accurate one, e.g.:
   ```swift
   .accessibilityHint("Opens in the viewer.")
   ```

3. **Keep** the existing `.accessibilityLabel(file.basename)` and the
   `.isButton` / `.isSelected` traits as-is.

This mirrors the established project pattern from `feat/next-25`'s
`CollectionCard`: a non-`Button` tap target collapsed into one activatable
element with a **primary `.accessibilityAction` for open** plus the
`.isButton`/`.isSelected` traits.

### Applies uniformly to all tile kinds

The accessibility modifiers live on the shared tile in `GridView`'s body, so the
new action applies to **both image tiles and non-image file cards**. Because
`appState.selectedFile = file` is the universal open trigger (the same one
double-click uses for every kind), opening via VoiceOver works for images, PDFs,
video, audio, etc. — downstream routing handles the kind.

## Out-of-scope actions (noted, not built)

The tile's right-click `contextMenu` (`SelectionActionsMenu`: Add to Collection /
New Collection / Add Tag / Share / Move) is reachable to VoiceOver via its
actions support, so the primary "Open" action is the priority gap. Exposing each
context-menu command as a *named* `.accessibilityAction` (the fuller treatment)
is a possible later refinement, deliberately excluded from this scope to keep the
change minimal and focused on the open gap the user asked about.

## Testing

- **No unit test** — this is a SwiftUI accessibility-modifier change (project
  convention: only pure logic is unit-tested).
- **Build:** `xcodebuild -scheme Muse build` → `** BUILD SUCCEEDED **`, no new
  warnings in `GridView.swift`.
- **Manual VoiceOver verification** (the real gate): enable VoiceOver
  (Cmd-F5), navigate the grid with Control-Option-arrows, and on a focused tile
  press Control-Option-Space — confirm the file **opens in the viewer** (image →
  hero; PDF/video/etc. → its viewer). Confirm the filename + selected state are
  still announced, and that the mouse flow (single-click select, double-click
  open, right-click menu) is unchanged. Confirm plain ↑/↓ still scroll the grid.

## Files

- `Muse/Muse/Views/GridView.swift` — add `.accessibilityAction { appState.selectedFile = file }`
  and reword `.accessibilityHint` on the tile. (Single-file change.)

## Notes / rationale

- VoiceOver navigation is already solved by VoiceOver's own cursor; the only gap
  is activation→open, so a single primary action is the complete fix for the
  VoiceOver audience.
- Keeping plain arrows as scroll honors the existing, valued scroll behavior and
  avoids needing to detect "who is an accessibility user" — VoiceOver activation
  is an explicit, detectable signal; sighted keyboard-only navigation (Full
  Keyboard Access) is the separate, deferred piece.
