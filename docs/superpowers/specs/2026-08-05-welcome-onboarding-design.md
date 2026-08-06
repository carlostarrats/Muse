# Welcome onboarding — final design

**Date:** 2026-08-05
**Finalized:** 2026-08-06
**Status:** built, owner-approved visually, and automated-verified

## Purpose

Muse has several useful workflows that are easy to miss because they live in
menus or right-click actions. The first-open welcome introduces only those
workflows. Ratings, tags, editing, search, and preview are excluded because
they are discoverable during normal use.

The welcome should take less than 30 seconds to read. Copy uses basic,
user-facing language and does not explain implementation details or answer
questions a new user is unlikely to have.

## Final flow and copy

### 1. Welcome to Muse

> Browse and organize photos and other files on your Mac.

> Add a folder to begin.

Button: **Next**

The primary button is left-aligned on this page. The artwork demonstrates a
folder being added and photos appearing in the library.

### 2. More ways to organize

> Smart Collections update automatically using details like rating, date,
> color, or file type.

> Right-click selected photos to add them to a collection or compare them side
> by side.

Buttons: **Back**, **Next**

The artwork demonstrates a Smart Collection being configured and a right-click
Compare action. It mirrors Muse behavior rather than presenting a generic
feature illustration.

### 3. Save and share collections

> Open a collection and use Share to save a PDF, export images, or publish a
> portfolio website.

> Need help? Open Muse FAQs with the ⓘ button.

Buttons: **Full Guide**, **Back**, **Get Started**

**Full Guide** is a distinct secondary button and opens
`https://muse-photo.com/info`. The artwork demonstrates the collection Share
menu and a published portfolio preview.

## Layout and visual behavior

- Use the existing Muse modal chrome, mood palette, typography, scrim, and
  button styles.
- The ideal modal width is 760 points and it must still fit the app's minimum
  window size without scrolling.
- The title and three progress dots share a stable top row. The dots sit at the
  top-right with the same top and right inset as the title's top and left inset.
- Copy and navigation occupy the left column. The detailed UI demonstration
  fills the right column.
- There is no close button. Escape and the scrim remain standard dismissal
  routes.
- Page 1 has no Back placeholder. Its Next button begins at the left edge; when
  Back appears on later pages, the primary button naturally follows it.
- Text and buttons switch immediately when a page changes. The outgoing UI
  demonstration disappears immediately; only the incoming demonstration fades
  upward and in over 0.22 seconds.
- Buttons change tint on hover and do not translate.
- The detailed UI demonstrations loop slowly enough to explain the workflows.
  Reduce Motion pauses each one at a representative completed state and removes
  the upward page-transition offset.
- All three demonstrations use a compact Muse-like header with a fixed,
  single-line search field. Photo tiles must never overlap.

The demonstrations use six bundled photo assets and native SwiftUI surfaces.
They are explanatory representations of Muse, not screenshots and not abstract
decorations. Their children are hidden from VoiceOver because the adjacent copy
conveys the same information.

## Navigation and accessibility

- The card always opens on page 1.
- Next and Back move one page within the fixed three-page range.
- Return activates Next or Get Started.
- Left and right arrows change pages only when no interactive control has
  keyboard focus.
- VoiceOver focus moves to the heading on initial presentation and after page
  changes. The heading announces its position, for example “More ways to
  organize. Page 2 of 3.”
- The progress dots and artwork are silent.
- Full Guide has a visible focus ring, is labeled “Open the Full Guide,” and
  announces that it opens a web page.
- Get Started dismisses the welcome; it does not open a folder picker.

## First-run behavior

Completion is stored under the versioned preference
`welcomeOnboardingSeen1`.

- Unseen and no stored user folder: show automatically and suppress the
  announcement fetch for this launch.
- Unseen and at least one stored user folder: do not show; seed the preference
  as seen so an existing user does not receive onboarding later.
- Seen: do not show.
- An unresolved stored folder still counts as an existing setup.
- The app-managed iCloud Muse folder does not count as a user-added folder.
- Every automatic dismissal persists completion. A manual presentation never
  changes the preference.
- **Help ▸ Welcome to Muse** reopens the card on page 1 and is disabled while
  another modal, Preview, or Compare is active.

The lifecycle belongs to `WelcomeOnboardingStore`, owned by `MuseApp`. A plain
AppState mirror participates in the global modal keyboard gate without adding
another published fan-out source.

## Empty-library follow-through

After onboarding, an empty library has one clear action:

- Hide the sidebar add control while there are no usable library roots, so two
  competing add actions are not shown.
- Center **Get started by adding a folder** above one **Add Folder** button.
- Do not show the previously proposed arrow.
- Show the supplied Muse wordmark only in this empty-library state, behind the
  prompt, clipped at the bottom and lightly at the right edge. Tint it at 3%
  white in dark moods and 2.5% black in light moods. It is decorative and
  ignores hit testing.

## Localization

All user-facing onboarding strings ship in English and French in
`Localizable.xcstrings`. The UI demonstrations are one decorative unit; their
tiny labels do not become accessibility content. Flexible wrapping is used for
copy rather than shrinking type.

## Verification

Automated coverage includes:

- all launch decisions and their announcement-fetch effects;
- automatic and manual persistence behavior;
- idempotent launch preparation;
- page order, bounds, controls, guide URL, modal gating, and Help availability;
- an isolated first-launch UI test that completes all three pages, reaches the
  single empty-library Add Folder action, relaunches with the same preferences,
  and proves the welcome does not return;
- Debug and Release builds, localization compilation, and repository invariant
  audit.

The owner reviewed and approved the final onboarding demonstrations, motion,
copy layout, and empty-state wordmark in the running app. No additional
screenshots are required for handoff.

## Exclusions

Do not add ratings, tags, editing, search syntax, supported-format lists,
analysis, backup, duplicates, import, publishing privacy, pricing, permissions,
Google sign-in, or keyboard-shortcut instruction to this welcome.
