# In-Window Modals Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Replace every `.sheet` with an in-window modal — a scrim plus a centred card laid out inside the window's own geometry — so a modal can never open oversized and snap, and every modal shares one look and one dismissal.

**Architecture:** A single host at the top of `ContentView`'s ZStack renders the scrim and the card inside a `GeometryReader`. Because the available size is known during the first layout, the card's height is a `maxHeight` cap rather than a measured-after-the-fact frame — which is what removes the flash. Presentation moves from scattered `.sheet` modifiers to one `AppState.presentedModal: ModalKind?`.

**Tech Stack:** SwiftUI / AppKit, macOS 14.6+. No new dependencies.

## Why

`.sheet` gives the modal its OWN window. Its height can only be capped by reading the parent window, and an AppKit view can't find that parent until it is inserted into a hierarchy — one runloop AFTER the first layout. So frame one draws at the ideal height, spills past a short window's bottom edge, and the measurement then snaps it back (owner-reported on the Info sheet).

Lineform solves this structurally rather than by patching the measurement: its Settings is not a sheet at all but a ZStack layer inside the editor, handed `availableWidth: geometry.size.width` from a `GeometryReader`
(`Lineform/Editor/EditorContainerView.swift` `museModalLayer`, `Lineform/App/SettingsView.swift`). Geometry is known before the first frame, so there is nothing to measure and nothing to snap.

## Global Constraints

- **The Drive publish must still cancel on ANY dismissal.** `DriveShareForm`'s `.onDisappear { service.cancel() }` is a documented security invariant — without it an upload continues headless, `setAnyoneReader` fires, and a share goes public unseen. The card must be genuinely removed from the hierarchy on dismiss (not merely hidden with `.opacity`), and this must be verified in the running app.
- **The hero close path is untouchable.** Escape while a viewer is open must keep firing ONLY `viewerClosing`. The modal layer sits above that in priority but must never fire in the same press.
- **`EscapeResolver` is pure and unit-tested.** Add the modal case there with tests, don't special-case it in `ContentView`.
- Every card keeps its content in a `ScrollView`/`Form`; action rows stay outside the scroll.
- Localization: no new user-facing strings expected. If a title moves into the shared header, it stays localized.

## Accepted behaviour changes

1. **Duplicates stops being user-resizable.** It's currently a resizable sheet window. As a card it takes the window minus a margin — as large as it can be, but the user can't drag its edges. Flagged to the owner.
2. **Modals no longer dim the menu bar / block the window chrome** the way a sheet does. The scrim blocks the app's own UI; the traffic lights and menus stay live.

---

### Task 1: Modal chrome + scrim + host

**Files:**
- Create: `Muse/Muse/Views/Modal/ModalChrome.swift`
- Create: `Muse/Muse/Views/Modal/ModalHost.swift`
- Modify: `Muse/Muse/Models/AppState.swift` (add `presentedModal`)
- Test: `Muse/MuseTests/ModalKindTests.swift`

**Interfaces:**
- Produces `ModalKind` (Equatable, Identifiable), `AppState.presentedModal: ModalKind?`, `ModalChrome` constants, `ModalScrim`, and `View.modalHost(...)`.

Card sizing rule, the whole point of the change:

```swift
card
    .frame(width: min(kind.width, max(280, geo.size.width - 48)))
    .frame(maxHeight: max(160, geo.size.height - 48))
```

No fixed height and no measurement — the card takes its natural height up to the cap, and its inner `ScrollView` scrolls past that.

### Task 2: Escape + keyboard capture

- `EscapeAction.dismissModal`, resolved ABOVE `closeHero` (a modal opened over a viewer is the innermost layer), with tests.
- While `presentedModal != nil`, `PageScrollCatcher` must forward nothing — arrow/page keys currently reach the grid behind a sheet only because the sheet's window takes key focus; an in-window card doesn't.

### Task 3: Convert the seven ContentView modals

Duplicates, Info, Image Layout, Settings, Manage Drive Shares, Metadata Import, Reconnect. Each: drop `.sheet`, present through `presentedModal`, drop `windowFittedSheetHeight`, keep the `ScrollView`.

### Task 4: Hoist and convert the four scattered modals

`CollectionSidebarRow` (Customize, Rules, Drive Share), `CollectionsPage` (New Smart), `ShareCollectionButton` (Drive Share). These are presented from row/button views; their payloads move into `ModalKind`'s associated values so the single host can render them.

### Task 5: Remove the old sizing machinery

`WindowFittedSheetHeight.swift`, `SheetFit.swift` and `SheetFitTests.swift` go once nothing uses them. Update the sheet-sizing durable constraint in `CLAUDE.md` to describe the in-window rule instead.

## Verification

Unit: `EscapeResolver` modal ordering; `ModalKind` identity.

Runtime (the owner's, since UI scripting isn't available here): open each modal on a SHORT window — none may draw oversized for even a frame; Escape and outside-click dismiss each; the Drive form cancels a publish in flight when dismissed by scrim, Escape and close button; arrow keys don't scroll the grid behind an open modal; Return still triggers the default button in Customize Collection.
