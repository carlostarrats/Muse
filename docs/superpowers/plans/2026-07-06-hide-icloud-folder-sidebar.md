# Hide the iCloud Folder in the Sidebar — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a Settings toggle that hides the app-managed iCloud "Muse" folder from the sidebar — but only when the folder is empty (greyed out with an explanatory note when it has files, or when iCloud isn't configured).

**Architecture:** A pure, unit-tested decision helper (`ICloudSidebarVisibility`) is the single source of truth for both surfaces: the sidebar render gate and the Settings toggle's enabled/footer state. Both read the same live `recursiveFileCount` signal (the one the row's existing empty-dimming already uses), so they can never disagree. A new `@AppStorage` bool (default ON) persists the user's choice.

**Tech Stack:** Swift, SwiftUI, `@AppStorage`/`UserDefaults`, XCTest (`MuseTests`), Xcode 16.

## Global Constraints

- Min macOS **14.6**; the app is sandboxed.
- **Every new user-facing string MUST be localized** (app ships English + French). SwiftUI `Text`/`Toggle` literals auto-extract; run the French export/fill after wiring. Storage stays canonical-English.
- Pure UI-decision math lives in `Muse/Muse/Components/` and is unit-tested; SwiftUI views are not unit-tested.
- Build/verify with `xcodebuild -scheme Muse ...` — SourceKit cross-file errors are noise; only the build is authoritative.
- Toggle framed positively — **"Show iCloud Folder in the Sidebar"**, default **ON** (matches the adjacent "Show Collections in the Sidebar").
- Never hide a non-empty iCloud folder: the render gate reads the live count, not the bare persisted bool.

---

### Task 1: Pure visibility decision helper + tests

**Files:**
- Create: `Muse/Muse/Components/ICloudSidebarVisibility.swift`
- Test: `Muse/MuseTests/ICloudSidebarVisibilityTests.swift`

**Interfaces:**
- Produces:
  - `enum ICloudSidebarVisibility.Presence { case notConfigured, empty, hasFiles, unknown }`
  - `static func presence(configured: Bool, recursiveFileCount: Int?) -> Presence`
  - `static func rowVisible(_ p: Presence, showSetting: Bool) -> Bool`
  - `static func toggleDisabled(_ p: Presence) -> Bool`

- [ ] **Step 1: Write the failing test**

Create `Muse/MuseTests/ICloudSidebarVisibilityTests.swift`:

```swift
import XCTest
@testable import Muse

final class ICloudSidebarVisibilityTests: XCTestCase {
    typealias V = ICloudSidebarVisibility

    func testPresenceMapping() {
        XCTAssertEqual(V.presence(configured: false, recursiveFileCount: nil), .notConfigured)
        XCTAssertEqual(V.presence(configured: false, recursiveFileCount: 5), .notConfigured) // not-configured wins
        XCTAssertEqual(V.presence(configured: true, recursiveFileCount: nil), .unknown)
        XCTAssertEqual(V.presence(configured: true, recursiveFileCount: 0), .empty)
        XCTAssertEqual(V.presence(configured: true, recursiveFileCount: 3), .hasFiles)
    }

    func testRowVisibility() {
        // Not configured: never shown, regardless of the toggle.
        XCTAssertFalse(V.rowVisible(.notConfigured, showSetting: true))
        XCTAssertFalse(V.rowVisible(.notConfigured, showSetting: false))
        // Has files: always shown, even with the toggle OFF.
        XCTAssertTrue(V.rowVisible(.hasFiles, showSetting: false))
        XCTAssertTrue(V.rowVisible(.hasFiles, showSetting: true))
        // Empty: follows the toggle.
        XCTAssertTrue(V.rowVisible(.empty, showSetting: true))
        XCTAssertFalse(V.rowVisible(.empty, showSetting: false))
        // Unknown (count not computed yet): shown, so it never flickers out at launch.
        XCTAssertTrue(V.rowVisible(.unknown, showSetting: false))
        XCTAssertTrue(V.rowVisible(.unknown, showSetting: true))
    }

    func testToggleDisabled() {
        XCTAssertTrue(V.toggleDisabled(.hasFiles))   // can't hide a folder with files
        XCTAssertFalse(V.toggleDisabled(.empty))
        XCTAssertFalse(V.toggleDisabled(.notConfigured))
        XCTAssertFalse(V.toggleDisabled(.unknown))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild -scheme Muse -destination 'platform=macOS' test -only-testing:MuseTests/ICloudSidebarVisibilityTests 2>&1 | tail -20`
Expected: FAIL — `cannot find 'ICloudSidebarVisibility' in scope`.

- [ ] **Step 3: Write minimal implementation**

Create `Muse/Muse/Components/ICloudSidebarVisibility.swift`:

```swift
//
//  ICloudSidebarVisibility.swift
//  Muse
//
//  Pure decision logic for whether the app-managed iCloud "Muse" root shows
//  in the sidebar, and whether the Settings toggle that governs it is enabled.
//  The single source of truth shared by SidebarView (render gate) and
//  SettingsView (toggle disabled + footer note) so the two can't disagree.
//
//  The user may hide the iCloud row ONLY when the folder is empty. A folder
//  with files always shows (toggle disabled); an un-computed count is treated
//  as visible so the row never flickers out during the launch window before
//  folderStats populates.
//

import Foundation

enum ICloudSidebarVisibility {
    /// The iCloud folder's content state, derived from its recursive file count.
    enum Presence {
        case notConfigured  // no iCloud URL (Debug build / signed out / unavailable)
        case empty          // configured, recursive file count == 0
        case hasFiles       // configured, recursive file count > 0
        case unknown        // configured, count not computed yet (nil)
    }

    /// - Parameters:
    ///   - configured: whether an iCloud folder URL exists.
    ///   - recursiveFileCount: the folder's recursive file count, or nil if not
    ///     yet computed.
    static func presence(configured: Bool, recursiveFileCount: Int?) -> Presence {
        guard configured else { return .notConfigured }
        guard let count = recursiveFileCount else { return .unknown }
        return count == 0 ? .empty : .hasFiles
    }

    /// Should the iCloud row render in the sidebar?
    static func rowVisible(_ p: Presence, showSetting: Bool) -> Bool {
        switch p {
        case .notConfigured: return false      // nothing to show
        case .hasFiles, .unknown: return true  // always show; unknown avoids flicker
        case .empty: return showSetting        // the one case the user controls
        }
    }

    /// Is the Settings toggle disabled (greyed) because the folder can't be hidden?
    static func toggleDisabled(_ p: Presence) -> Bool {
        if case .hasFiles = p { return true }
        return false
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild -scheme Muse -destination 'platform=macOS' test -only-testing:MuseTests/ICloudSidebarVisibilityTests 2>&1 | tail -20`
Expected: PASS (`Test Suite 'ICloudSidebarVisibilityTests' passed`).

- [ ] **Step 5: Commit**

```bash
git add "Muse/Muse/Components/ICloudSidebarVisibility.swift" "Muse/MuseTests/ICloudSidebarVisibilityTests.swift"
git commit -m "feat: pure iCloud sidebar visibility decision helper + tests"
```

> **Note:** the new files must be added to the Xcode project's `Muse` and `MuseTests` targets respectively. If the build in Step 2 fails to find the test file at all (not the "cannot find in scope" error), add both files to their targets in `Muse.xcodeproj` (Xcode's File Inspector → Target Membership) before continuing.

---

### Task 2: Setting accessor + sidebar render gate

**Files:**
- Modify: `Muse/Muse/Settings/AppSettings.swift` (add after the `showCollectionsInSidebar` accessor, ~line 140)
- Modify: `Muse/Muse/Views/SidebarView.swift` (the `folderList` iCloud block, ~lines 122-125; add an `@AppStorage` property near the view's other state)

**Interfaces:**
- Consumes: `ICloudSidebarVisibility.presence/rowVisible` (Task 1).
- Produces: `AppSettings.showICloudFolderInSidebarKey` (String), `AppSettings.showICloudFolderInSidebar` (Bool).

- [ ] **Step 1: Add the setting accessor**

In `AppSettings.swift`, immediately after the `showCollectionsInSidebar` computed var (~line 140), add:

```swift
    static let showICloudFolderInSidebarKey = "showICloudFolderInSidebar"

    /// Show the app-managed iCloud "Muse" folder in the sidebar. Default true.
    /// Only ever honored when the folder is EMPTY — a non-empty iCloud folder
    /// always shows regardless of this flag. Unset → on.
    static var showICloudFolderInSidebar: Bool {
        UserDefaults.standard.object(forKey: showICloudFolderInSidebarKey) as? Bool ?? true
    }
```

- [ ] **Step 2: Add the `@AppStorage` binding to SidebarView**

In `SidebarView.swift`, find the view's existing `@AppStorage`/`@State` declarations (near the top of the struct). Add:

```swift
    @AppStorage(AppSettings.showICloudFolderInSidebarKey) private var showICloudFolder = true
```

(If SidebarView has no existing `@AppStorage`, place it alongside its `@EnvironmentObject var appState` / `@State` properties.)

- [ ] **Step 3: Gate the iCloud row render**

In `SidebarView.swift`, replace the `folderList` iCloud block (currently):

```swift
            if let icloud = iCloudNode {
                FolderTreeNode(node: icloud, depth: 0,
                               topLevelCount: topLevelCount(for: icloud))
            }
```

with:

```swift
            // The iCloud "Muse" folder is the fixed home — always on top, not
            // reorderable. The user may hide it from the sidebar ONLY while it's
            // empty (Settings → Sidebar); a folder with files always shows. The
            // gate reads the live recursive count, not just the persisted flag,
            // so a folder that gains files reappears on its own.
            if let icloud = iCloudNode,
               ICloudSidebarVisibility.rowVisible(
                   ICloudSidebarVisibility.presence(
                       configured: true,
                       recursiveFileCount: appState.folderStats.stat(for: icloud.url)?.recursiveFileCount),
                   showSetting: showICloudFolder) {
                FolderTreeNode(node: icloud, depth: 0,
                               topLevelCount: topLevelCount(for: icloud))
            }
```

(`iCloudNode` being non-nil already means iCloud is configured, so `configured: true`.)

- [ ] **Step 4: Build to verify it compiles**

Run: `xcodebuild -scheme Muse -destination 'platform=macOS' build 2>&1 | tail -15`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add "Muse/Muse/Settings/AppSettings.swift" "Muse/Muse/Views/SidebarView.swift"
git commit -m "feat: gate the iCloud sidebar row on the new show-iCloud setting"
```

---

### Task 3: Settings toggle + footer + AppState injection

**Files:**
- Modify: `Muse/Muse/Settings/SettingsView.swift` (add `@EnvironmentObject appState`, an `@AppStorage`, a second toggle in the Sidebar `Section`, a conditional footer line; update the `#Preview`)
- Modify: `Muse/Muse/ContentView.swift:245` (inject `.environmentObject(appState)` into the SettingsView sheet)

**Interfaces:**
- Consumes: `ICloudSidebarVisibility.presence/toggleDisabled` (Task 1), `AppSettings.showICloudFolderInSidebarKey` (Task 2), `AppState.iCloudFolderURL` + `AppState.folderStats` (existing).

- [ ] **Step 1: Inject AppState into the SettingsView sheet**

In `ContentView.swift`, change (line ~245):

```swift
        .sheet(isPresented: $appState.settingsShown) {
            SettingsView(isPresented: $appState.settingsShown)
        }
```

to:

```swift
        .sheet(isPresented: $appState.settingsShown) {
            SettingsView(isPresented: $appState.settingsShown)
                .environmentObject(appState)
        }
```

- [ ] **Step 2: Add AppState + the setting binding to SettingsView**

In `SettingsView.swift`, add below the existing `@EnvironmentObject private var googleAuth` (line 16) and `@AppStorage` block (lines 17-21):

```swift
    @EnvironmentObject private var appState: AppState
    @AppStorage(AppSettings.showICloudFolderInSidebarKey) private var showICloudFolder = true
```

- [ ] **Step 3: Add a computed presence + the toggle & footer**

In `SettingsView.swift`, add a computed property inside the struct (e.g. above `var body`):

```swift
    /// Live iCloud folder state, driving the Show-iCloud toggle's enabled state
    /// and footer note.
    private var iCloudPresence: ICloudSidebarVisibility.Presence {
        ICloudSidebarVisibility.presence(
            configured: appState.iCloudFolderURL != nil,
            recursiveFileCount: appState.iCloudFolderURL
                .flatMap { appState.folderStats.stat(for: $0)?.recursiveFileCount })
    }
```

Replace the Sidebar `Section` (lines 68-76) with:

```swift
            Section {
                Toggle("Show Collections in the Sidebar", isOn: $showCollectionsInSidebar)
                Toggle("Show iCloud Folder in the Sidebar", isOn: $showICloudFolder)
                    .disabled(ICloudSidebarVisibility.toggleDisabled(iCloudPresence))
            } header: {
                Text("Sidebar")
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Show your collections as a collapsible section beneath the folders, with their own sort order.")
                    iCloudFooterNote
                }
                .font(.callout)
                .foregroundStyle(.secondary)
            }
```

Add the conditional footer note as a computed view inside the struct:

```swift
    @ViewBuilder private var iCloudFooterNote: some View {
        switch iCloudPresence {
        case .hasFiles:
            Text("The iCloud folder contains files, so it can't be hidden.")
        case .notConfigured:
            Text("iCloud isn't set up, so the folder isn't in the sidebar. It'll appear here when iCloud is available.")
        case .empty, .unknown:
            Text("Hide the empty iCloud folder from the sidebar. It reappears automatically if files are added.")
        }
    }
```

- [ ] **Step 4: Update the Preview**

In `SettingsView.swift`, update `#Preview` (lines 119-122) so it supplies an `AppState`:

```swift
#Preview {
    SettingsView(isPresented: .constant(true))
        .environmentObject(GoogleOAuth())
        .environmentObject(AppState.shared)
}
```

(If `AppState` has no `.shared` singleton, use the same construction other previews in the codebase use — grep `#Preview` for an existing `AppState` in an environment object; if none exists, `AppState()` if the initializer is accessible.)

- [ ] **Step 5: Build to verify it compiles**

Run: `xcodebuild -scheme Muse -destination 'platform=macOS' build 2>&1 | tail -15`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 6: Commit**

```bash
git add "Muse/Muse/Settings/SettingsView.swift" "Muse/Muse/ContentView.swift"
git commit -m "feat: Settings toggle to show/hide the iCloud sidebar folder"
```

---

### Task 4: Localize the new strings (French)

**Files:**
- Modify: `Muse/Muse/Localizable.xcstrings` (auto-populated by the export tool, then French values filled)

**Interfaces:**
- Consumes: the four new `Text`/`Toggle` literals from Tasks 2-3 ("Show iCloud Folder in the Sidebar" + the three footer notes).

- [ ] **Step 1: Export localizations to write-back the new keys**

Run:
```bash
xcodebuild -exportLocalizations -project Muse/Muse.xcodeproj \
  -localizationPath /tmp/muse-loc -exportLanguage fr 2>&1 | tail -5
```
Expected: completes; the new English keys are now present in `Localizable.xcstrings` with empty `fr` values.

- [ ] **Step 2: Fill the French translations**

Edit `Muse/Muse/Localizable.xcstrings` — set the `fr` string for each new key:

| English key | French |
|---|---|
| `Show iCloud Folder in the Sidebar` | `Afficher le dossier iCloud dans la barre latérale` |
| `The iCloud folder contains files, so it can't be hidden.` | `Le dossier iCloud contient des fichiers, il ne peut donc pas être masqué.` |
| `iCloud isn't set up, so the folder isn't in the sidebar. It'll appear here when iCloud is available.` | `iCloud n'est pas configuré, le dossier n'apparaît donc pas dans la barre latérale. Il s'affichera ici lorsque iCloud sera disponible.` |
| `Hide the empty iCloud folder from the sidebar. It reappears automatically if files are added.` | `Masquer le dossier iCloud vide de la barre latérale. Il réapparaît automatiquement si des fichiers y sont ajoutés.` |

(If a different translation reads better in context, prefer it — these are the baseline. Match the tone of the existing French footers.)

- [ ] **Step 3: Verify no untranslated keys remain**

Re-run the export from Step 1; expected: it reports 0 untranslated `fr` strings for these keys.

- [ ] **Step 4: Build to confirm the catalog still compiles**

Run: `xcodebuild -scheme Muse -destination 'platform=macOS' build 2>&1 | tail -8`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add "Muse/Muse/Localizable.xcstrings"
git commit -m "i18n: French for the show-iCloud-folder sidebar setting"
```

---

### Task 5: Full test suite + manual QA gate

**Files:** none (verification only)

- [ ] **Step 1: Run the full unit suite**

Run: `xcodebuild -scheme Muse -destination 'platform=macOS' test 2>&1 | tail -25`
Expected: all `MuseTests` pass (existing ~574 + the new `ICloudSidebarVisibilityTests`).

- [ ] **Step 2: Manual QA checklist (run the app)**

Verify in the running app (build + run, per the "verify runtime, not just tests" rule):
- [ ] Settings → Sidebar shows the new "Show iCloud Folder in the Sidebar" toggle, default ON.
- [ ] With an **empty** iCloud folder: toggling OFF removes the iCloud row from the sidebar; ON restores it. Footer shows the "Hide the empty…" note, toggle enabled.
- [ ] With a **non-empty** iCloud folder (drop a file into the Muse iCloud folder): the toggle is **greyed out**, footer shows "contains files, so it can't be hidden", and the row stays visible even if the persisted flag is OFF.
- [ ] Removing all files from the iCloud folder re-enables the toggle and re-honors OFF (row hides again).
- [ ] Debug build / no iCloud (URL nil): no iCloud row in the sidebar; Settings toggle enabled with the "iCloud isn't set up…" note.

- [ ] **Step 3: Commit any QA fixes**

If QA surfaces a fix, commit it with a descriptive message; otherwise nothing to commit here.

---

## Self-Review notes

- **Spec coverage:** helper (Task 1) ✓, setting + render gate (Task 2) ✓, Settings UI + injection (Task 3) ✓, localization (Task 4) ✓, testing/QA (Tasks 1 & 5) ✓. All three presence states + unknown covered in tests.
- **Type consistency:** `presence`/`rowVisible`/`toggleDisabled` + `Presence` cases used identically across Tasks 1-3. `showICloudFolderInSidebarKey` used verbatim in Tasks 2-3.
- **Risk pins:** render gate reads live count (Task 2 Step 3), not the bare bool; `unknown` → visible (Task 1) prevents launch flicker.
