# Editor Workspace — customizable module layout

**Date:** 2026-08-03
**Status:** design approved, not yet planned
**Surface:** the (Preview | Edit) editor inside the hero viewer

---

## 1. What this is

The editor's controls are twelve cards in two fixed columns. Which cards, in
what order, on which side, is written into `EditorView.swift` as two hard-coded
`@ViewBuilder` lists. The only thing the editor remembers about them today is
which ones are open (`AppSettings.editorExpandedSections`).

This adds a **workspace**: an ordered list of modules per column plus the set
you have hidden, persisted, with three surfaces to change it — a Default
Layout action, a Customize modal, and a Reorder mode.

Three asks drove it, and they collapse into one model:

1. A one-column layout, everything on one side.
2. A way to hide modules you do not use.
3. A drag-to-reorder mode.

(1) is not a mode. It is the state where one column's list is empty, reached
through (3). There is no Single Column menu item and no second saved
arrangement — see §9.

## 2. The twelve modules

Ids are the existing `EditorView.Section` strings, which are already persisted
for expansion state. Reusing them keeps one identity per card.

| id | Heading | Home side | Default position |
|---|---|---|---|
| `tools` | TOOLS | left | 1 |
| `histogram` | HISTOGRAM | left | 2 |
| `insights` | INSIGHTS | left | 3 |
| `history` | SNAPSHOTS | left | 4 |
| `looks` | STYLES | right | 1 |
| `light` | LIGHT | right | 2 |
| `zones` | TONE ZONES | right | 3 |
| `color` | COLOR | right | 4 |
| `hsl` | COLOR MIX | right | 5 |
| `splitTone` | SPLIT TONE | right | 6 |
| `effects` | EFFECTS | right | 7 |
| `crop` | CROP & STRAIGHTEN | right | 8 |

Granularity is the **card**. Not the groups inside TOOLS, not individual
sliders. One checkbox and one grab handle per card.

`insights` is already conditional — it draws only when the photo has feedback
notes, Lightroom provenance or a RAW decoder version. That stays: a hidden-by-
absence module is not the same as a user-hidden one, and it appears in the
Customize list only when it has something to show.

### Not a module

The **chrome row** — zoom pill, Fit, the hide-UI eye, Share, ✕ — is a viewer
control, not an editing panel. It is pinned to the top-right of the viewer
always. It never reorders, never hides, never moves to the other side, and it
is not listed in Customize. When the right column holds no cards it still draws
there, alone over the canvas — the same thing that already happens when the
hide-UI eye is pressed (`EditorView` draws `hideUIButton` at `.topTrailing`
while `session.uiHidden`).

## 3. Data model

```
EditorModule            enum, 12 cases, String raw values = the ids above
EditorWorkspace         left: [EditorModule]
                        right: [EditorModule]
                        hidden: Set<EditorModule>
```

That is the whole model. Single column is `left.isEmpty` or `right.isEmpty`.
There is no mode flag, no snapshot, no second arrangement.

**Invariant:** every module appears exactly once across `left + right`,
including hidden ones. Hiding does not remove a module from its column — it
sets a flag, so position and visibility are independent facts and unhiding
returns a card to where it was, not to the bottom.

Persisted as JSON in `UserDefaults` under a new `AppSettings.editorWorkspace`
key, beside the existing editor working preferences (backdrop, expanded
sections, styles list mode). It is a working preference, not library data — it
does not go in the database and does not ride a backup.

### Load rules

These are the three ways a saved workspace can disagree with the running build,
and each must be survivable. This is where a "my panels reset themselves" bug
would live, so all three are tested.

1. **Unknown module id** (a card removed in a later version) — the entry is
   dropped, the rest of the workspace loads.
2. **Missing module** (a card added in a later version) — appended to the
   bottom of its home side, **visible**. Never hidden by omission: anyone who
   had ever opened Customize would otherwise silently stop receiving new
   features.
3. **Unreadable or malformed JSON** — falls back to the default workspace.

A new module declares a home side and, optionally, a position. Without a
position it lands at the bottom of its home side. Adding one is a one-line
enum case plus a row in the card builder; it cannot break an existing saved
workspace.

## 4. Where the state lives

`EditorWorkspaceStore`, an `@MainActor` `ObservableObject` singleton, following
`EditorChromeCommand` exactly. That pattern exists because the menu bar is
built in `MuseApp` and the editor is several layers inside `ContentView`'s
viewer overlay, so a command needs somewhere to meet — and because a
`@Published` on `AppState` re-evaluates the whole `ContentView` body, sidebar
and grid included, on every change.

It holds:

- `workspace: EditorWorkspace` — the committed truth, persisted on write.
- `reorderMode: Bool`
- `customizeShown: Bool`
- `draft: EditorWorkspace?` — the in-flight arrangement while reordering.
  Cancel discards it; Save commits it to `workspace` and persists.

**Editor presence** is not mirrored again. `EditorChromeCommand.uiHidden` is
already nil exactly when no editor is on screen, and `MuseApp` already observes
it. The workspace menu items gate on the same signal.

## 5. Menu

```
View
  Manage Drive Shares…        ⇧⌘L
  Hide controls               ⌘U
  ────────────────────────────────
  Editor Workspace              ▸
        Default Layout
        Customize Modules…
        Reorder Modules
```

Named **Editor Workspace** — a noun, the editor's workspace. "Edit Workspace"
reads as a verb, which is wrong for a submenu that contains an actual Customize
item.

**Default Layout** restores the table in §2: two columns, original order and
sides, all twelve visible. It is the one action that also clears the hidden
set.

All three items are disabled when no editor is on screen
(`EditorChromeCommand.uiHidden == nil`), while a modal is up
(`appState.modalPresented`), and while reorder mode is active.

No keyboard shortcuts. None of the three is a control you bounce on.

## 6. Customize Modules

An in-window modal in the app's existing style. It registers as a modal
(`appState.modalPresented`), so ⌘U and the menu items go inert while it is up,
and Escape closes it — both required by the standing modal discipline and
covered by the existing `MuseSurfaceDriveTests` Escape sweep.

Twelve rows (eleven when `insights` has nothing to show), each a checkbox and
the card's heading, **listed in panel order** — left column top-to-bottom, then
right — so the list reads like the thing it edits.

**Applies live.** No OK button. Unchecking removes the card from the panel
behind the modal immediately. Cancel/OK on a checkbox list is ceremony.

**The last visible module's checkbox is inert.** An editor with no controls,
recoverable only through the menu bar, is a trap — and "show me only the photo"
is already the hide-UI eye's job, done properly and reversibly.

It does **not** reorder. No handles, no up/down arrows. Reorder is its own mode
with its own gestures; two ways to do one thing in two places drift apart.

## 7. Reorder mode

Entered from the menu. The editor becomes a surface you can only rearrange.

**Cards force-collapse to their heading bar.** This is a display override, not
a write: `AppSettings.editorExpandedSections` is untouched and every card
returns to its previous open/closed state on exit. Nothing inside a card is
reachable, because nothing inside a card is drawn — no sliders, no crop mode,
no Auto, no Reset, no eyedropper, no tone-zone targeting.

**The bars wiggle** — a small continuous rotation, the iOS home-screen tell, so
the mode is unmistakable rather than reading as a broken panel.

**The grab handle replaces the ＋/−** in each heading.

**The pointer says grab** — `NSCursor.openHand` hovering a bar,
`closedHand` while dragging, through the same push/pop discipline `EditorView`
already uses for canvas panning. Mismatched pushes corrupt the cursor stack for
the whole app, so this follows the existing pattern rather than calling
`.set()`.

**The column backing comes up.** Today the solid slab behind a column appears
only while zoomed; the rest of the time cards float translucent over the photo.
In reorder mode the cards are thin bars with gaps between them, so an insertion
line would often be drawn over the photograph and be invisible against a bright
one. The backing makes the whole rearranging area one surface. It already
exists and already animates (`EditorPanel.backingVisible`).

**Dragging** lifts the bar; the others part to open a gap; an insertion line
marks the landing point. Drag across to the other column to change sides,
including into an emptied one.

**The insertion line** draws in the `PanelContrast`-resolved accent — the same
colour as a selected tab or an active tool row, re-resolved when the backdrop
changes. The editor backdrop is user-choosable across five levels from white to
black, so a fixed blue is illegible on at least one of them; nothing in the
editor may hard-code a colour (see the `PanelContrast` rule).

### The floating bar

Over the photo, centred near the bottom, clear of both columns:

```
  ⇤ All Left   All Right ⇥   │   Reset   Cancel   Save
```

Grouped because they are different kinds of thing: the left pair rearranges,
the right three end the mode.

- **All Left / All Right** move every module to that column in **reading
  order** — the left column's list first, then the right column's, whichever
  column is receiving. So All Right yields TOOLS · HISTOGRAM · INSIGHTS ·
  SNAPSHOTS · STYLES · LIGHT · … and All Left yields the same sequence on the
  other side. One rule, symmetric, and it matches the approved single-column
  layout in §8. (An earlier draft said "the receiving column's own list first",
  which would have put STYLES above TOOLS on All Right — contradicting §8.)
  They exist because "everything on one side" is otherwise four to eight drags,
  and both directions exist because dragging is symmetric — the one-column-left
  state is reachable by hand whether or not a button offers it, so it needs a
  rule anyway (§2, chrome row).
- **Reset** restores the standard order and sides. It leaves the hidden set
  alone — visibility belongs to Customize. You stay in the mode, so Cancel can
  still undo the reset.
- **Cancel** restores the workspace as it was on entry and exits. **Escape does
  Cancel**, registered through the app's existing `EscapeAction` resolver so it
  takes priority in the same way every other dismissable state does.
- **Save** commits and persists.

While the mode is active: ⌘U and the workspace menu items are disabled.

**If the editor is dismissed while reorder mode is active, the draft is
discarded** — leaving the mode by any route other than Save is a cancel. A
half-finished arrangement must never be committed by the user closing the
viewer, and there is no confirmation prompt: the cost of losing a rearrangement
is a few seconds of dragging, and a modal asking "save your layout?" on the way
out of a photo viewer is worse than that.

## 8. Canvas geometry

`EditorView.fitInsets` currently reserves `ViewerGeometry.editorPanelWidth` on
both sides unconditionally. An emptied column would leave a dead strip.

**Sides follow the cards, the top stays with the chrome.**

| State | Leading inset | Trailing inset |
|---|---|---|
| Both columns have cards | `editorPanelWidth` | `editorPanelWidth` |
| All cards right | `sidePad` | `editorPanelWidth` |
| All cards left | `editorPanelWidth` | `sidePad` |

All-cards-right is Preview's exact geometry — content left, column right — so
switching Preview ⇄ Edit does not move the photo at all.

The **top** inset stays `topPad` in every case. It already clears the chrome
line, so a photo widening into an emptied right column grows sideways and down
but never runs under the pinned buttons.

The change **animates**. `fitInsets` is already interpolated through
`chromeProgress`, stepped frame by frame because the Metal view reads it once
per render — the same path hiding the UI uses so the photo grows into the freed
space instead of snapping. Emptying a column reuses it.

It settles **on Save only**. Dragging the last card out of a column during
reorder does not re-fit the canvas mid-drag; the photo would pump back and
forth while the user is still deciding.

`ViewerGeometry.minWindowWidth` (`editorPanelWidth * 2 + columnWidth`) is
unchanged. It is a floor, not a requirement — single column simply gets more
room for the photo.

## 9. Rejected

**A Single Column menu toggle.** Considered and dropped. Restoring "your last
two-column arrangement" on uncheck forces Muse to hold two arrangements at
once, one of them always invisible, plus rules for which one Reset applies to
and what happens when you reorder inside one of them. That is state the user
cannot see or inspect, bought for a flip nobody performs — panel layout is set
up once, like Lightroom, and left. Single column is now exactly what it looks
like: a column with nothing in it.

**Finer granularity** (hiding groups inside TOOLS, or individual sliders). The
Customize list becomes a spreadsheet and reorder mode grows nested drags.

**Named saved workspaces** ("Portrait retouch", "Quick crop"). Needs a store,
naming, deletion and a management surface. Not asked for.

**Native SwiftUI drag-and-drop** (`.draggable` / `.dropDestination`). Less drag
code, but it supplies the system's drag imagery instead of Muse's part-and-
insert animation, so reorder would look like nothing else in the app, and a
live insertion gap plus wiggle is awkward to layer on top.

## 10. Files

**New**

- `Components/EditorWorkspace.swift` — the model plus its pure operations:
  default, load-with-repair, move within and across columns, all-to-side,
  hide/show, reset. No SwiftUI, no state. Joins `GridSelection`,
  `MasonryGeometry`, `ReorderMath`, `CropDragMath`.
- `Views/Editor/EditorWorkspaceStore.swift` — the singleton seam.
- `Views/Editor/EditorCustomizeModal.swift`
- `Views/Editor/EditorReorderBar.swift` — the floating bar.

**Changed**

- `Components/ReorderMath.swift` — gains the column-aware slot function. The
  three existing functions are used as-is for within-column drags.
- `Views/Editor/EditorView.swift` — the two hard-coded lists become `ForEach`
  over the workspace's columns; `fitInsets` becomes column-aware; reorder mode
  overrides expansion and swaps the ＋/− for a handle.
- `Views/Editor/EditorPanel.swift` — `EditorSection` gains a reorder
  presentation (forced collapse, handle, wiggle).
- `MuseApp.swift` — the Editor Workspace submenu.
- `Settings/AppSettings.swift` — the `editorWorkspace` key.
- `Localizable.xcstrings` — new strings, French filled. Menu titles, the
  twelve module names in the Customize list, the floating bar's five buttons,
  and every `.help`/`.accessibilityLabel` added here. The module names are
  **runtime-variable** in the Customize list, so they need
  `NSLocalizedString(name, comment:)` and manual catalog entries — the
  compiler's extractor cannot see them.

**Extracted** — `EditorView.swift` is 1,682 lines and CLAUDE.md's health list
already flags files like it. This work rewrites every card declaration in it,
so the card bodies come out into their own files at the same time, leaving
`EditorView` as canvas, chrome and layout. Not a separate refactor; just not
adding a thirteenth concern to a file that is already too big.

| File | Now | After |
|---|---|---|
| `EditorView.swift` | 1,682 | ~550 — canvas, gestures, chrome, geometry, workspace wiring |
| `EditorCardsLeft.swift` | — | ~300 — tools, backdrop picker, insights |
| `EditorCardsRight.swift` | — | ~380 — light, color, colour mix, split tone, effects + bindings |
| `EditorCardsCrop.swift` | — | ~260 — crop, straighten, aspect menu, apply |
| `EditorCardBuilder.swift` | — | ~60 — module → card |

**Rule: nothing this work touches ends over 600 lines**, and none of the four
new workspace files exceeds ~250. There is a compile-time reason as well as a
legibility one — the module → card switch nests `_ConditionalContent` twelve
deep inside a `@ViewBuilder`, which type-checks far faster with the branches in
separate files.

## 11. Performance

Net faster. Recorded because the question will come up again.

**Wins**

- **A hidden card is never built.** STYLES is `LooksBrowserView` — 696 lines
  that render a live preview thumbnail per preset. Hiding it removes that work
  entirely, as it does the histogram's stats tap and the curve editor. Customize
  is incidentally a performance feature.
- **Reorder mode is lighter than normal editing**, because force-collapsing
  every card unmounts all card content at once.
- **Single column costs nothing** — the same twelve cards in one scroll view
  instead of two.

**Costs**

- Twelve wiggling bars, only while in reorder mode, on collapsed headings with
  no content. Negligible beside the Metal canvas.
- A `ForEach` over modules diffs by identity where a static `@ViewBuilder` list
  knew the structure at compile time. Unmeasurable at twelve items.

**Rules**

- **Persist on Save only, never per drag frame.** A `UserDefaults` write per
  pointer move is how a smooth drag becomes a stuttering one.
- **The store is not on `AppState`** — see §4. That is the difference between
  re-rendering the editor and re-rendering the sidebar and grid with it.
- Nothing here touches the render chain, the decode budget, the analysis
  pipeline or the grid.

## 12. Testing

**Reused as-is.** Within-column drag math is the sidebar's. `ReorderMathTests`
already covers the three functions with 13 tests — row shift with no drag, the
dragged row itself, rows above and below the target; slot above first, between
rows, past last, skipping unmeasured frames; insertion line with no target, on
an empty list, past the end, and mid-list. The editor calls the same functions
and inherits all of it.

**New unit tests**

- *Load repair* — unknown id dropped; missing module appended visible to its
  home side; malformed JSON falls back to default; a workspace with every
  module hidden is repaired rather than trusted.
- *Move* — within a column, across columns, into an empty column, to the head
  and past the tail; the every-module-exactly-once invariant holds after each.
- *Cross-column slot* — which column a drag position belongs to, at the
  boundary and beyond both edges; the same shape as the existing slot tests.
- *All Left / All Right* — relative order preserved, receiving column's own
  list first, idempotent.
- *Visibility* — hide/show round-trips to the same index; the last visible
  module cannot be hidden; hidden modules keep their position across a reorder.
- *Reset vs Default* — Reset restores order and sides and leaves `hidden`
  alone; Default Layout clears `hidden` too.
- *Cancel* — restores the entry workspace exactly, including after a Reset
  inside the mode, and on dismissal-while-reordering.
- *Geometry* — `fitInsets` yields Preview's insets on the emptied side; the top
  inset is `topPad` in all three states.

**Runtime** (`FEATURE-LEDGER.md` row, driven in the real app — none of this is
provable from a green suite): the wiggle and grab cursor appear and the cursor
stack is clean on exit; a drag parts the bars and the insertion line is visible
against a light *and* a dark backdrop; a cross-column drag lands; Save persists
across a relaunch; Cancel and Escape restore; the photo slides rather than
jumps when a column empties; the Customize modal honours Escape and its last
checkbox is inert.

**Audit.** `./scripts/audit-invariants.sh` before any commit, as always. No new
invariant is introduced here — nothing in this work touches network, export,
decode or the trash path.
