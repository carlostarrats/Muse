# Possible future updates

Low-priority, nice-to-have items captured so they aren't lost. **None of these
are problems or blockers** — the app is healthy and shippable as-is (see the code
review notes in the 2026-06-16 session logs). Don't cut a release just for these;
fold any of them into a future release when you're already touching that area or
have other changes worth shipping.

_Last reviewed: 2026-06-17. Both code-tidiness items below were completed on
2026-06-17 (see that CLAUDE.md session log)._

## Code tidiness (cosmetic only) — ✅ DONE 2026-06-17

- ~~**Split `AppState.swift` (~900 LOC).**~~ ✅ Pulled the grid-selection helpers
  into `AppState+Selection.swift` and the tag/collection filter logic into
  `AppState+Filters.swift` (the two request tokens became internal so the moved
  methods can reach them). Core file 1012 → 782 LOC.
- ~~**Rename `Muse/Fluid/` → `Muse/Effects/`.**~~ ✅ Renamed (it held only
  `FadeOutModifier.swift`); no code/pbxproj references needed updating since it's
  a filesystem-synchronized group.

## Health watch list (not problems — areas to watch for complexity creep)

From a 2026-06-19 codebase-health rating (overall ~8.5/10, **healthy**). None of
these are bugs or blockers. They're the three places where future complexity will
hurt *first*, captured so that when work starts touching one of them we make a
conscious choice to split/refactor rather than letting it sprawl. The intent is to
**flag the interaction at the moment a change adds complexity here**, not to
refactor preemptively.

1. **A couple of files are getting heavy.**
   - `Muse/Views/SidebarView.swift` (~1,359 LOC) — the largest. Its live-drag
     reorder logic is the prime candidate to extract into its own model/component
     before the file reaches ~1,500 LOC.
   - `Muse/Models/AppState.swift` (~1,258 LOC) — already partially split into
     `AppState+Selection.swift` / `AppState+Filters.swift`. Keep splitting along
     those seams as new state lands; don't pile back onto the core file.
2. **Known O(n)/keystroke + scan scaling items** (flagged by the feat/next-35 audit
   as "personal-scale concerns, not bugs"): semantic search runs O(n) per keystroke,
   tag search does a `LIKE` table scan, and `CollectionStore` has an N+2 query
   pattern. Fine at the user's personal library size; latent debt if Muse is ever
   pointed at a ~50k-file library. When new work touches these paths, note the
   scaling cost instead of silently extending it.
3. **Test coverage is logic-deep but UI-shallow** (inherent + accepted). Pure logic
   helpers are well-tested; SwiftUI view wiring is not. This is the right tradeoff,
   but it means view-wiring regressions (the class behind the Escape two-press fix
   and the toolbar-icon drift) can only be caught by hand. When changing view wiring,
   remember there's no automated net under it — manual verification is the safeguard.

## Features / decisions deferred

- **Separate `.dev` iCloud container for Debug builds.** Debug builds currently
  carry NO iCloud (`Muse-Debug.entitlements`) so their churn can't claim/purge
  the production container — but that also means you can't see or test the iCloud
  "Muse" folder feature in a dev build. If you want dev iCloud testing later,
  register an `iCloud.com.tarrats.Muse.dev` container and point the Debug
  entitlements at it (instead of omitting iCloud entirely). That keeps dev fully
  isolated from production while still exercising the sync path. See the
  2026-06-16 "iCloud dev-container isolation" session log in CLAUDE.md.

---

Earlier "soft spots" (code syntax highlighting, saved smart searches,
onboarding, a top-edge gradual-blur effect) were reviewed on 2026-06-17 and
**dropped — not wanted.** CLAUDE.md's only remaining note in that area is a
short list of current iCloud by-design behaviors (not pending work).

A focused **Preferences pane DID ship** 2026-06-17 (app menu → Settings…, ⌘,) —
just the auto-tag / auto-collections opt-out toggles (`AppSettings` /
`SettingsView`). A broader settings pane beyond those toggles is still not
planned; other settings continue to live in the sidebar / toolbar / menus.
