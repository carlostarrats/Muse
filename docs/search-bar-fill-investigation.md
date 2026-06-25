# Search-bar "fill the space" investigation (2026-06-25)

Status: **deferred, not shipped.** Working tree was reverted to clean; no code
changed. This doc preserves the findings so a future session doesn't repeat the
dead ends.

## The ask

Make the center search field behave like Safari's address bar: **fill the
toolbar and keep balanced margins on both sides**, growing/shrinking with the
window — instead of sitting at a small fixed width centered with large empty
gaps on either side. The user explicitly did **not** care about Safari's
collapse-to-a-magnifier-icon trick; the goal was just "better fill the space,
balanced on both sides." Hard constraint: **do not change the look, behavior, or
overflow of the other toolbar buttons.**

## Why it currently looks the way it does

The field lives in SwiftUI's centered toolbar slot:

- `ContentView.swift` — `ToolbarItem(placement: .principal) { SearchBar() }`
- `Components/SearchBar.swift` — `.frame(minWidth: 320, maxWidth: 640)`

`.principal` **centers** its item and sizes it to its content clamped to
`minWidth`. The centered slot does **not** stretch with the window, so the field
sits at ~320pt regardless of window width (the `maxWidth: 640` is effectively
dead — nothing ever offers the item more than its content width). That's the
empty-gaps-on-both-sides look.

The field itself is a native `NSSearchField` (`NativeSearchField`,
`NSViewRepresentable`) with a scope dropdown (All / This Folder), mood-matched
light/dark appearance, a 250ms debounce, and programmatic-query injection. Any
replacement must preserve all of that.

## Approaches tried, and why each failed

1. **`maxWidth: .infinity` on the `.principal` item.**
   Result: the field **hugs the right edge** (big gap on the left, not centered)
   and **pushes the trailing button group — Collections/Layout/Mood/Info — into
   the `»` overflow menu.** Violates the "don't touch other buttons" constraint.
   Rejected. (This is exactly what the original `SearchBar.swift` code comment
   warned about.)

2. **Wider fixed `minWidth` (e.g. 520).**
   Fills a bit more but is still a fixed centered width — doesn't track the
   window, so a wide monitor still shows large gaps, and a large fixed width
   risks crowding the side buttons on a narrow window. Doesn't meet the goal.

3. **Measure the live window width and compute the field width.**
   Plan: a `GeometryReader` background + `PreferenceKey` on the outer `ZStack`
   feeds `windowWidth` into `ContentView`, then
   `searchFieldWidth = max(320, windowWidth - reserve)` is passed to
   `SearchBar(width:)` which applies `.frame(width:)`. Reserve (~660pt) is meant
   to keep room for the leading + trailing button groups so they never overflow.
   - Conceptual problems: brittle — it depends on hand-guessed reserve constants
     for the button-group widths, and `.principal` centering gives slightly
     off-balance margins (leading group is wider than trailing).
   - Practical problem: in testing the measured `windowWidth` came back **0** and
     never updated (the preference didn't propagate as expected), so the field
     fell back to 320 — i.e. effectively unchanged. Not pursued to a fix because
     even working it's a fragile hack.

4. **SwiftUI's native `.searchable(placement: .toolbar)`.**
   This *is* a native `NSSearchToolbarItem` under the hood and gives real
   Safari-style fill/collapse for free, touching **zero** other buttons. BUT the
   system **places it in the far-right corner, after the trailing buttons**, at a
   modest fixed size — it does **not** center or fill the middle. Wrong
   aesthetic for this ask. Rejected. (Worth remembering it exists if the
   right-aligned native field ever becomes acceptable — it's by far the
   cheapest, lowest-risk option.)

## Root cause / conclusion

SwiftUI's `.principal` toolbar slot **fundamentally cannot do a centered,
window-filling, flexible-width item.** The only thing that produces the
centered-and-fills layout is a **native `NSToolbar` with an
`NSSearchToolbarItem` between two flexible spaces.** And SwiftUI's `WindowGroup`
owns the window's toolbar (built from the `.toolbar { }` block) — you can't drop
one native flexible item into it. So getting the desired look requires replacing
the entire SwiftUI toolbar with a hand-built `NSToolbar`.

## What a real fix would entail (the deferred work)

A new ~300–500 line AppKit toolbar controller (`NSToolbarDelegate` + a window
accessor) replacing the whole SwiftUI `.toolbar`:

- Re-host all 8 buttons (sort, filter, tag-sort, subfolders, collections,
  layout, mood, info) as `NSToolbarItem`s wrapping their **existing SwiftUI
  views** via `NSHostingView(rootView: theView.environmentObject(appState))`, so
  menus, popovers, `moodToolbarIcon` recolor, and `.disabled` states keep
  working. (Helper views live in `ContentView.swift`: `sortMenu`,
  `tagSortMenu`, `sortDirectionButton`, `filterMenu`, `moodMenu`, plus the
  inline subfolders Toggle and the Collections/Layout/Info buttons.)
- Re-create the **sidebar-toggle** button (today it's free from
  `NavigationSplitView`); wire it to the `toggleSidebar(_:)` responder action.
- Re-create the **transparent titlebar/background** (the sidebar card flows up
  to the window corner — currently `.toolbarBackground(.hidden, for:
  .windowToolbar)`).
- Re-create the **viewer-hide** behavior (toolbar vanishes when an image hero
  viewer is open — currently the `.toolbar(... .hidden ...)` keyed on
  `selectedFile`/`viewerDismissing`).
- Then add the centered `NSSearchToolbarItem` (porting `NativeSearchField`'s
  scope menu, mood appearance, debounce, and query injection onto its
  `searchField`) between two `.flexibleSpace` items.

### Risk assessment

This is the **single most constraint-dense area of the app** — see the toolbar
gotchas in CLAUDE.md "Durable constraints & gotchas":
- the `ShimmerBand`/`repeatForever` transaction leak that drifted toolbar icons,
- the filter popover's "no AppKit `NSViewRepresentable` inside a size-changing
  SwiftUI `.popover`" rule (the filter funnel),
- `moodToolbarIcon` explicit-color vs `.disabled` auto-dimming,
- the hero-close / Escape single-trigger choreography that interacts with the
  toolbar show/hide.

Each becomes a regression candidate when re-implemented in AppKit. **High effort
+ high regression risk for a purely cosmetic gain.** That trade is why this was
deferred. If revisited, build it incrementally and verify each piece visually
(search item fills first, then confirm every button's menu/popover/recolor/
disabled/overflow still behaves, then the transparent background and viewer-hide).

## Key files

- `Muse/Muse/ContentView.swift` — the `.toolbar { }` block + the button helper
  vars; the `.principal` search item; `.toolbarBackground(.hidden)`; the
  viewer-hide `.toolbar(...)`.
- `Muse/Muse/Components/SearchBar.swift` — `SearchBar` + `NativeSearchField`
  (`NSSearchField` wrapper, scope menu, mood appearance, debounce). The
  `.frame(minWidth: 320, maxWidth: 640)` is the current fixed width.
- `Muse/Muse/MuseApp.swift` — `WindowGroup` (SwiftUI owns the window/toolbar).
