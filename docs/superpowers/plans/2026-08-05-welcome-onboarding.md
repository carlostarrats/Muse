# Welcome onboarding — implementation plan and final record

**Planned:** 2026-08-05
**Completed:** 2026-08-06
**Status:** implemented and automated-verified
**Final design:** `docs/superpowers/specs/2026-08-05-welcome-onboarding-design.md`

This file records the implementation shape and completed QA. The final design
spec supersedes the early 640-point, static-illustration prototype discussed
during planning.

## Goal

Add a short three-page first-open welcome that surfaces Smart Collections,
right-click collection and Compare actions, collection PDF/image export,
portfolio publishing, and the Full Guide without turning onboarding into a
manual. Follow it with a single, clear empty-library Add Folder action.

## Final architecture

### Lifecycle

`WelcomeOnboardingStore` is a dedicated `@StateObject` owned by `MuseApp` and
injected into `ContentView`. It owns:

- automatic versus manual presentation;
- the versioned `welcomeOnboardingSeen1` preference;
- the launch decision for unseen/seen and empty/existing setups;
- one dismissal method for scrim, Escape, and Get Started;
- the launch effect that suppresses announcement fetching when automatic
  onboarding is selected.

The store is intentionally separate from AppState. A non-published AppState
mirror participates in the existing modal keyboard gate, and
`ContentView.dismissTopModal()` routes Escape through the store.

### Presentation

`WelcomeOnboardingView` owns only the current page. It is presented as the
outermost content-column `museModal` at a 760-point ideal width. It uses:

- the existing modal chrome and primary/back buttons;
- top-right progress dots and no close button;
- a fixed left copy/footer column;
- a large right-side native SwiftUI UI demonstration;
- immediate text/button replacement and an artwork-only fade-up transition;
- `@AccessibilityFocusState` for headings and `@FocusState` for controls.

`WelcomeOnboardingArtwork` contains three slow, looping demonstrations of the
actual workflows. Six small photo assets carry through the scenes. Reduce
Motion pauses each scene at a useful completed phase.

### Existing-user and Help behavior

- Unseen, empty setup: present automatically.
- Unseen setup with stored user roots: seed seen without presenting.
- Seen: do not present automatically.
- Help ▸ Welcome to Muse reopens manually without changing the seen state.
- Help presentation is disabled behind another modal, Preview, or Compare.
- `AppLinks.guide` is shared by the onboarding Full Guide button and Muse FAQs.

### Empty library

When no usable library roots are present, `SidebarView` hides its add control
and `GridView` shows one Add Folder CTA. `MuseEmptyStateLogo` is a decorative,
theme-aware wordmark behind that CTA, clipped at the bottom and right edge and
excluded from hit testing and accessibility.

## File map

| File | Responsibility |
|---|---|
| `Muse/Muse/Views/Welcome/WelcomeOnboardingStore.swift` | Launch rules, presentation source, persistence |
| `Muse/Muse/Views/Welcome/WelcomeOnboardingView.swift` | Page model, copy, navigation, focus, footer |
| `Muse/Muse/Views/Welcome/WelcomeOnboardingModal.swift` | Shell modal integration and AppState mirror |
| `Muse/Muse/Views/Welcome/WelcomeOnboardingArtwork.swift` | Three detailed animated UI demonstrations |
| `Muse/Muse/Components/AppLinks.swift` | Shared Full Guide URL |
| `Muse/Muse/MuseApp.swift` | Store ownership, launch effects, Help command |
| `Muse/Muse/ContentView.swift` | Environment injection, Escape and modal gate |
| `Muse/Muse/Models/AppState.swift` | Non-published modal mirror |
| `Muse/Muse/Filesystem/BookmarkStore.swift` | Volatile empty-roots Debug/UI-test seam |
| `Muse/Muse/Views/GridView.swift` | Single empty-library CTA and wordmark |
| `Muse/Muse/Views/SidebarView.swift` | Hide duplicate add action while empty |
| `Muse/Muse/Localizable.xcstrings` | English/French onboarding copy |
| `Muse/MuseTests/WelcomeOnboardingStoreTests.swift` | Lifecycle, page, URL, modal-policy tests |
| `Muse/MuseUITests/MuseWelcomeOnboardingTests.swift` | Isolated first-launch and relaunch flow |

The Xcode project uses filesystem-synchronized groups, so no manual project
file entries were required.

## Implementation sequence

1. Add the versioned preference, pure launch decision, dedicated store, and
   focused unit coverage.
2. Centralize the guide URL and build the three-page native card.
3. Replace the initial abstract/static artwork with detailed Muse UI
   demonstrations and refine layout and motion with owner feedback.
4. Integrate the store with launch, announcement suppression, Help, modal
   gating, and Escape.
5. Refine the empty-library experience to one Add Folder action and the
   supplied Muse wordmark.
6. Add English/French catalog entries and the narrow first-launch/relaunch UI
   test.
7. Review, fix, run full QA, update the final design record, and commit.

## Guardrails

- Do not publish another broad AppState property.
- Do not rewrite or delete production bookmarks in tests.
- A stored but unresolved root still counts as an existing setup.
- Automatic dismissal persists seen; manual dismissal does not.
- Skip the announcement request entirely for the automatic-welcome launch.
- Do not stack the welcome behind another modal surface.
- Keep copy basic and short; do not add implementation, privacy, AI, pricing,
  or permissions explanations.
- Keep artwork decorative to VoiceOver and pause it under Reduce Motion.
- Do not add another empty-library add control or restore the rejected arrow.

## QA record

- Debug app build: succeeded, including asset and localization compilation.
- Focused lifecycle suite: 16 passed, 0 failed.
- Full `MuseTests`: 2,206 executed, 2 skipped, 0 failed; the separate Swift
  Testing smoke also passed.
- First-launch/relaunch XCUITest: 1 passed, 0 failed. The harness handles the
  macOS state-restoration case where the app starts with a menu bar but no
  document window, and asserts semantic onboarding/empty-library content.
- The owner approved the final onboarding UI, motion, copy layout, and
  empty-state wordmark in the running app.
- Repository invariant audit, localization export, and Release/universal build
  are recorded in the session log after their final runs.

## Acceptance result

A new empty setup receives one short three-page welcome, can dismiss it or
reopen it from Help, and then lands on one clear Add Folder action. Existing
setups are not interrupted, automatic onboarding cannot be followed by a
same-launch announcement, and completion survives relaunch.
