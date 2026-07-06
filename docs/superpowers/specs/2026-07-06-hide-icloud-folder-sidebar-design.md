# Hide the iCloud folder in the sidebar (when empty) — design

**Date:** 2026-07-06
**Status:** approved, ready for implementation plan

## Problem

The app-managed iCloud "Muse" root is always pinned to the top of the
sidebar FOLDERS section. A user who doesn't use the iCloud sync folder has
a permanent, non-removable row they can't get rid of. We want a Settings
option to hide it — but only when it's safe to (the folder is empty), so we
never hide files.

Inspiration: the same affordance exists in the Lineform app.

## Behavior

A new Settings toggle governs the iCloud row's visibility, gated on the
folder's contents. Three states:

| iCloud state | Sidebar row | Settings toggle | Footer note |
|---|---|---|---|
| **Has files** (recursive count > 0) | always shown | **disabled** (greyed) | "The iCloud folder contains files, so it can't be hidden." |
| **Configured & empty** (count == 0) | shown only if toggle ON | enabled | "Hide the empty iCloud folder from the sidebar. It reappears automatically if files are added." |
| **Not configured** (no iCloud URL — Debug build / signed out / unavailable) | **never shown** | enabled (stays on) | "iCloud isn't set up, so the folder isn't in the sidebar. It'll appear here when iCloud is available." |
| **Unknown** (stat not yet computed) | shown | enabled | (treated as "configured & empty") |

Key rule: **the sidebar render gate reads the live file-count signal, not
just the persisted bool.** So a folder that gains files after the toggle was
flipped still reappears, and the two surfaces (Settings toggle + sidebar
row) can never disagree — both derive from the same
`recursiveFileCount == 0` signal that the row's existing dimming already
uses (`FolderTreeNode.isEmptyICloudRoot`).

The toggle **default is ON** (folder shown), framed positively as
**"Show iCloud Folder in the Sidebar"** to match the adjacent
"Show Collections in the Sidebar" toggle (so "hidden" = off).

## Architecture

### 1. Pure decision helper (new, unit-tested)

A small pure type — `ICloudSidebarVisibility` — in `Muse/Components/`
(the home for pure, testable UI math). It takes the two raw inputs and
returns the render/settings decisions. No SwiftUI, no AppState — just:

```swift
enum ICloudSidebarVisibility {
    /// The folder's content state, derived from the recursive file count.
    enum Presence { case notConfigured, empty, hasFiles, unknown }

    static func presence(configured: Bool, recursiveFileCount: Int?) -> Presence

    /// Should the iCloud row render in the sidebar?
    static func rowVisible(_ p: Presence, showSetting: Bool) -> Bool

    /// Is the Settings toggle disabled (can't hide because files exist)?
    static func toggleDisabled(_ p: Presence) -> Bool
}
```

Decision table (encodes the behavior table above):

- `presence`: `!configured` → `.notConfigured`; `count == nil` →
  `.unknown`; `count == 0` → `.empty`; else `.hasFiles`.
- `rowVisible`: `.notConfigured` → `false`; `.hasFiles` → `true`;
  `.unknown` → `true`; `.empty` → `showSetting`.
- `toggleDisabled`: `.hasFiles` → `true`; everything else → `false`.

This is the single source of truth; both the sidebar and Settings call it.

### 2. The setting (`AppSettings.swift`)

Add, mirroring `showCollectionsInSidebar`:

```swift
static let showICloudFolderInSidebarKey = "showICloudFolderInSidebar"

/// Show the app-managed iCloud "Muse" folder in the sidebar. Default true.
/// Only ever honored when the folder is EMPTY — a non-empty iCloud folder
/// always shows regardless. Unset → on.
static var showICloudFolderInSidebar: Bool {
    UserDefaults.standard.object(forKey: showICloudFolderInSidebarKey) as? Bool ?? true
}
```

### 3. Settings UI (`SettingsView.swift`)

- Inject `AppState` via `@EnvironmentObject` and add
  `.environmentObject(appState)` to the SettingsView sheet in
  `ContentView.swift` (matches how `ImageLayoutSheet` is presented). This
  keeps the toggle's disabled/footer state live if the folder's contents
  change while Settings is open.
- Add a second toggle to the existing **Sidebar** `Section`:
  ```swift
  Toggle("Show iCloud Folder in the Sidebar", isOn: $showICloudFolder)
      .disabled(ICloudSidebarVisibility.toggleDisabled(presence))
  ```
- Compute `presence` from
  `appState.iCloudFolderURL != nil` +
  `appState.folderStats.stat(for: url)?.recursiveFileCount`.
- The footer becomes conditional: pick one of the three note strings based
  on `presence` (`.hasFiles` → contains-files note, `.notConfigured` →
  not-set-up note, else → normal). The existing Collections footer stays;
  the section footer shows both lines (Collections note + the iCloud note),
  or we split into two `Section`s if cleaner. **Decision: keep one Sidebar
  Section with both toggles; the footer shows the Collections sentence
  followed by the iCloud sentence.** (One conditional `Text` for the iCloud
  line.)

### 4. Sidebar render gate (`SidebarView.swift`)

The `if let icloud = iCloudNode` block (lines ~122-125) becomes:

```swift
if let icloud = iCloudNode,
   ICloudSidebarVisibility.rowVisible(
       ICloudSidebarVisibility.presence(
           configured: true,
           recursiveFileCount: appState.folderStats.stat(for: icloud.url)?.recursiveFileCount),
       showSetting: showICloudFolder) {
    FolderTreeNode(...)
}
```

`iCloudNode` non-nil already implies configured, so `configured: true`
there. `showICloudFolder` is a new `@AppStorage` in SidebarView bound to
`AppSettings.showICloudFolderInSidebarKey`.

Because `folderList` is shared by both `foldersScroll` and
`twoSectionScroll`, both layouts get the gate for free.

## Localization

Three new user-facing strings (toggle title + 2 conditional footer notes,
plus the normal iCloud footer sentence). All are SwiftUI `Text`/`Toggle`
literals → auto-extracted. After wiring, run
`xcodebuild -exportLocalizations … -exportLanguage fr` and fill the French
values, per the CLAUDE.md localization workflow. (English ships working
regardless; French is the keep-green obligation.)

## Testing

`MuseTests/ICloudSidebarVisibilityTests.swift` — pure table tests for
`presence`, `rowVisible`, `toggleDisabled` across all four presence states
× both toggle values. Specifically pin:

- not-configured → row hidden regardless of toggle.
- has-files → row shown even when toggle OFF; toggle disabled.
- empty → row follows the toggle; toggle enabled.
- unknown (nil count) → row shown; toggle enabled (no flicker-out on
  launch before stats compute).

No UI-layer tests (consistent with the suite — views aren't unit-tested).

## Out of scope / non-goals

- No change to iCloud sync behavior, entitlements, or the zone itself.
- No per-file or partial hiding — it's the whole iCloud root or nothing.
- No new third sidebar state for "iCloud present but signed out mid-session"
  beyond the `.notConfigured` (nil URL) path already covered.
- The row's existing empty-state dimming (`isEmptyICloudRoot`) is unchanged
  and still applies when the folder is shown-but-empty (toggle ON, empty).

## Risk notes

- **Don't hide a non-empty folder.** The render gate must read the live
  count, never the bare bool — enforced by routing both surfaces through
  the pure helper.
- **`nil` (unknown) count must not hide the row** — treated as visible, so
  the folder never flickers out during the launch window before
  `folderStats` populates. Mirrors existing `isEmptyICloudRoot` semantics.
