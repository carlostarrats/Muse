# Possible future updates

Low-priority, nice-to-have items captured so they aren't lost. **None of these
are problems or blockers** — the app is healthy and shippable as-is (see the code
review notes in the 2026-06-16 session logs). Don't cut a release just for these;
fold any of them into a future release when you're already touching that area or
have other changes worth shipping.

_Last reviewed: 2026-06-16, after the v1.0.7 release._

## Code tidiness (cosmetic only)

- **Split `AppState.swift` (~900 LOC).** It's the central `@MainActor` state
  object and the single largest file. Not a problem, but if it keeps growing,
  pull cohesive chunks into extensions — e.g. `AppState+Filters.swift` for the
  tag-chip + collection filter logic (`setActiveTag` / `setActiveCollection` /
  `removeTag` / `removeFromCollection` / `visibleFiles`). Purely organizational.
- **Rename `Muse/Fluid/` → `Muse/Effects/`.** The directory is a vestige of the
  removed water-ripple effect and now holds only `FadeOutModifier.swift`, so the
  name no longer matches its contents. Trivial (it's a filesystem-synchronized
  group — just move the file and the group name).

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

For the longer-standing product backlog — code syntax highlighting, saved smart
searches, a real Preferences pane, onboarding, archive browse-without-extract —
see **"Known soft spots"** in CLAUDE.md.
