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

Earlier "soft spots" (code syntax highlighting, saved smart searches, a
Preferences pane, onboarding, a top-edge gradual-blur effect) were reviewed on
2026-06-17 and **dropped — not wanted.** CLAUDE.md's only remaining note in that
area is a short list of current iCloud by-design behaviors (not pending work).
