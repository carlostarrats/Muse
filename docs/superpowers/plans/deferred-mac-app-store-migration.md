# Deferred — Mac App Store Migration (Sparkle excision, doctrine, build settings)

> **Status: DEFERRED. Do not run yet.** Split out of
> `2026-07-30-spec-01-foundation-plumbing.md` on 2026-07-31 at the owner's request: the
> app stays on direct distribution (Developer ID + Sparkle self-update) for now. Run
> this plan as its own standalone pass whenever the owner decides to make the Mac App
> Store move — no fixed date, could be a month or more out. It is intentionally
> decoupled from Spec 01: nothing in Spec 01 (coordinates, edit-aware seams, StoreKit 2
> commercial plumbing, announcements, perf baseline) depends on this work landing first,
> and this work does not depend on Spec 01 having landed first either. StoreKit 2's
> trial-gate/purchase plumbing (Spec 01 Section D) already builds and runs fine under
> direct distribution via a local `StoreKit Configuration` file for dev/testing — actual
> App Store product records are an owner step regardless of when this migration runs.
>
> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development
> (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps
> use checkbox (`- [ ]`) syntax for tracking. Before starting, re-verify against the
> live repo state — Sparkle version pins, entitlement contents, and `project.pbxproj`
> line numbers cited below were accurate as of 2026-07-30 and may have drifted by the
> time this actually runs.

**Goal:** Move Muse from direct distribution (Developer ID–signed, notarized, Sparkle
self-update) to Mac App Store exclusive distribution: doctrine + build-setting updates,
full Sparkle excision (code, entitlements, build config, docs), Apple Silicon–only
architecture restriction, and MAS entitlement compliance.

**Tech Stack:** Swift 5, SwiftUI + AppKit, Xcode build settings (`project.pbxproj`,
`Info.plist`, entitlements), Swift Package Manager. Dependency count after this plan:
one (GRDB) — Sparkle is removed.

---

## Tasks

### Task 1: `CLAUDE.md` doctrine revisions

**Files:**
- Modify: `CLAUDE.md` (project root)

**Interfaces:** None — documentation only. No later task depends on exact wording, only
on the facts being present (Mac App Store distribution, three network paths, Apple
Silicon floor, two-path editing model, `AppState` freeze, three new durable-constraint
bullets from Task 17).

- [ ] **Step 1: Update "Project identity" bullets**

  In the "## Project identity" section, make these edits:
  - **Persona**: replace "Primary user persona: **generalist** — managing a Downloads
    folder, Documents, miscellaneous archives..." with the enthusiast-photographer
    persona: shoots a phone and/or a "fun" camera (X100-style compact, mirrorless,
    point-and-shoot); photography is an active interest, not memory-keeping; curious
    about the technical side but not fluent; wants control Apple Photos doesn't give
    without pro-tool cost/complexity; wants best shots to look good and get shared, not
    just filed away. Add: designers and general users remain valid users — do not
    amputate the general-purpose library nature.
  - **Distribution**: replace "Direct — a Developer ID–signed, notarized build that
    self-updates via Sparkle..." with: **Mac App Store exclusively.** No GitHub
    download, no Sparkle, no direct distribution. StoreKit 2 for all payments;
    TestFlight for betas; Small Business Program (15%, under $1M/yr). Note this
    supersedes the 2026-06-15 direct-distribution pivot (keep that pivot's paragraph as
    history but mark it superseded, don't delete it — it explains why Sparkle was there
    at all).
  - **Network policy**: replace the "Update-only, plus one explicit opt-in publish
    path" paragraph's two-path description with **three app-initiated paths**: (1)
    Google Drive collection share (user-initiated, unchanged — keep the existing
    detailed paragraph about `drive.file`/PKCE), (2) `announcements.json` (fetched once
    per launch, off-able in Settings, no query string/identifiers/cookies), (3)
    custom-domain provisioning Worker (future paid feature, user-initiated, not built in
    this spec — mention as reserved). State that StoreKit/App Store traffic is OS-level,
    not an app-initiated path, and does not change the "Data Not Collected" label.
    Delete the Sparkle EdDSA-verification / `SUEnableAutomaticChecks` sentences.
  - **Min macOS**: replace "**14.6**" with "**macOS 14.6, Apple Silicon only (M1
    floor)**" and add the two-tier scale envelope: design center 10k–50k photos on any
    M1 including M1 Air 8GB (must be flawless, reference test machine); accommodated
    edge 200k–800k+ (degrade gracefully, never crash/corrupt/beachball). Add the rule:
    **no code may assume RAM-residency.**

- [ ] **Step 2: Rewrite the "No editing UI" convention**

  In "## Conventions", find the bullet starting `**No editing UI** — every "edit this"
  path goes through Open With…`. Replace with the two-path editing model: **Path A** —
  non-destructive in-app adjustment stack for JPEG/HEIC/PNG/TIFF/RAW/DNG; originals
  never touched; edits live in DB + sidecars, never written into image files. **Path B**
  — "Edit a Copy" fork on Open With when Muse edits exist (Edit Original / Edit a Copy
  with Muse Adjustments); the copy is rendered with adjustments applied, handed to the
  external app, and returns into the library stacked with its parent. State explicitly
  that the never-modify-user-files and never-write-EXIF/XMP rules are unchanged — Path A
  is additive plumbing, not a reversal of existing doctrine. Note Path A's actual editor
  is built in Spec 04; this spec only lands the seams that make it safe to add later.

- [ ] **Step 3: Add the `AppState` freeze as an explicit Durable constraint**

  In "### Durable constraints & gotchas (DO NOT BREAK)", add (if not already adequately
  covered by the existing "Code architecture" bullet under §9 of the foundation doc —
  check first; if `AppState.swift` size is already called out, extend it rather than
  duplicate): a bullet stating new features get their own state objects/modules
  (editing store, search store, commerce store), never a new `@Published` on
  `AppState`. Cite this spec's own `CommerceStore`/`AnnouncementStore` as the
  precedent-following examples once Task 18/22 land (a later doc pass, not blocking —
  see Task 24 for the final doc sweep).

- [ ] **Step 4: Add a build-order phase-table row**

  In the "## Implementation status" table, add a new row: `| Foundation 1 — Spec-01
  foundation & plumbing (Sparkle removal, MAS build config, v13 coordinates, edit-aware
  seams, StoreKit 2 plumbing, announcements) | ✅ shipped (or 🚧 in progress, update at
  merge) | <branch> |`. Leave the status as 🚧 until Task 25 confirms everything is
  merged; flip it in that task.

- [ ] **Step 5: Verify the file still reads cleanly**

  Read the diff back top to bottom. Confirm no contradictions remain (e.g. no leftover
  sentence claiming "two sanctioned network paths" beside the new three-path list; no
  leftover "generalist" persona sentence). `CLAUDE.md` is loaded every session — keep it
  lean per its own "Conventions" rule; don't let this edit exceed roughly the length of
  what it replaced.

- [ ] **Step 6: Commit**

```bash
git add CLAUDE.md
git commit -m "docs: revise CLAUDE.md doctrine for photo-repositioning foundation (persona, MAS distribution, editing model)"
```

---

### Task 2: Deployment target reconciliation + Apple Silicon only

**Files:**
- Modify: `Muse/Muse.xcodeproj/project.pbxproj`
- Modify: `README.md`

**Interfaces:** None — build settings only.

**Context (from research):** current `MACOSX_DEPLOYMENT_TARGET` values are
inconsistent: project level `26.0` (lines 437, 496), Muse app target `14.6` (lines 565,
526), MuseTests `26.2` (lines 612, 591), MuseUITests inherits the project's `26.0`
(no override), MuseShareExtension `26.5` (lines 723, 684). No `ARCHS`/`VALID_ARCHS`
override exists anywhere in the file today.

- [ ] **Step 1: Reconcile every deployment target to 14.6**

  In `project.pbxproj`, change `MACOSX_DEPLOYMENT_TARGET` at all 8 occurrences (project
  Debug line 437, project Release line 496, Muse app Debug 565 — already 14.6, leave —
  Muse app Release 526 — already 14.6, leave — MuseTests Debug 612, MuseTests Release
  591, MuseShareExtension Debug 723, MuseShareExtension Release 684) to `14.6`. Do this
  with a project-wide find of `MACOSX_DEPLOYMENT_TARGET = ` and replace every value that
  isn't already `14.6`. MuseUITests has no override — leave it inheriting the (now 14.6)
  project default; do not add an explicit override where none exists today.

  This is deliberate for `MuseShareExtension`: reconciling DOWN to 14.6 (not raising the
  app to 26.5) is the only choice consistent with the Apple Silicon / 14.6 floor — an
  extension whose `LSMinimumSystemVersion` exceeds the running OS is silently
  unregistered, meaning Finder → Share → Muse would be dead for the majority of the
  supported OS range today. The extension's source uses nothing past 14.6 (verified in
  research pass — no availability-gated API found requiring 26.5).

- [ ] **Step 2: Add Apple Silicon-only architecture settings**

  In `project.pbxproj`, add `ARCHS = arm64;` and `VALID_ARCHS = arm64;` to both the
  project-level `Debug` and `Release` `XCBuildConfiguration` blocks (the same blocks
  holding lines 437/496 from Step 1). Do not add per-target overrides — the project
  level covers every target including the extension. Leave `LSMinimumSystemVersion` at
  14.6 in `Info.plist` (Apple Silicon Macs all ship ≥ macOS 11, so the arch restriction
  — not the OS version string — is what actually enforces the M1 floor).

- [ ] **Step 3: Build and verify**

  Run: `xcodebuild -project Muse/Muse.xcodeproj -scheme Muse -configuration Debug build`
  Expected: `BUILD SUCCEEDED`, with the build log showing only an `arm64` slice compiled
  (no `x86_64` mentioned). Also run the same for the `MuseShareExtension` scheme if one
  exists, or confirm it builds as part of the `Muse` scheme's dependency graph.

- [ ] **Step 4: Update `README.md` Requirements section**

  Add "Apple Silicon (M1 or later)" to the Requirements section. This is a small,
  additive edit — do not touch the Sparkle-related README content here; that's Task 8.

- [ ] **Step 5: Commit**

```bash
git add "Muse/Muse.xcodeproj/project.pbxproj" README.md
git commit -m "build: reconcile deployment targets to 14.6, restrict to Apple Silicon (arm64)"
```

---

### Task 3: MAS entitlement audit note (no code change — verification task)

**Files:** None modified — this task confirms the entitlement audit table from the spec
is already satisfied and records the confirmation. If Task 5 (Sparkle entitlement
removal) hasn't landed yet, this task's Step 1 will fail — do Task 5 before this one, or
run this as a final check after Task 5.

**Interfaces:** None.

- [ ] **Step 1: Confirm every MAS-relevant entitlement is present and no
  disqualifying entitlement remains**

  Read `Muse/Muse/Muse.entitlements`. Confirm present: `com.apple.security.app-sandbox`
  = true, `com.apple.security.network.client` = true, `com.apple.security.files.user-
  selected.read-write` = true, `com.apple.security.files.bookmarks.app-scope` = true,
  `com.apple.security.application-groups` (if present, unchanged), iCloud
  container/services/ubiquity keys. Confirm ABSENT (after Task 5):
  `com.apple.security.temporary-exception.mach-lookup.global-name`. `ENABLE_HARDENED_RUNTIME`
  stays on — confirm no change was made to it.

- [ ] **Step 2: Record the confirmation**

  No file changes needed if everything checks out — this is a verification gate before
  Task 4's Sparkle work is declared complete. If the temporary-exception key is still
  present, stop and go complete Task 5 first.

---

### Task 4: Delete `Updater.swift` and remove its usage from `MuseApp.swift`

**Files:**
- Delete: `Muse/Muse/Updates/Updater.swift` (and the `Updates/` directory if it becomes
  empty)
- Modify: `Muse/Muse/MuseApp.swift:19` (remove `@StateObject private var updater =
  UpdaterController()`), `MuseApp.swift:138-150` (the `CommandGroup(after: .appInfo)`
  block)

**Interfaces:** None produced — this is a deletion. Confirms no other file references
`UpdaterController`, `CheckForUpdatesViewModel`, or `CheckForUpdatesView`.

- [ ] **Step 1: Grep for all references before deleting**

  Run: `grep -rn "UpdaterController\|CheckForUpdatesView\|CheckForUpdatesViewModel" "Muse/Muse" "Muse/MuseTests" "Muse/MuseUITests"`
  Expected: matches only in `Muse/Muse/Updates/Updater.swift` and
  `Muse/Muse/MuseApp.swift`. If anything else matches, note it and handle it in this
  task (there should be nothing else per the research pass).

- [ ] **Step 2: Remove the `MuseApp.swift` usages**

  In `Muse/Muse/MuseApp.swift`:
  - Delete line 19: `@StateObject private var updater = UpdaterController()` (and its
    preceding doc comment on line 17-18 if it exists solely to describe this property).
  - In the `CommandGroup(after: .appInfo) { ... }` block (lines 138-150): delete the
    `CheckForUpdatesView(updater: updater.controller.updater)` line and the `Divider()`
    immediately following it. Keep the Back Up/Restore menu items that follow — they
    must remain inside the same `CommandGroup`.

  The block should read (illustrative — match against the actual surrounding lines,
  keeping the Back Up/Restore items verbatim):
  ```swift
  .commands {
      CommandGroup(after: .appInfo) {
          Button("Back Up Library…") { appState.startBackup() }
          Button("Restore Library…") { appState.startRestore() }
      }
      // ... any other existing CommandGroup blocks, untouched
  }
  ```

- [ ] **Step 3: Delete the Updater directory**

  Run: `rm -rf "Muse/Muse/Updates"`
  Confirm no other file lives in that directory first: `ls "Muse/Muse/Updates"` should
  show only `Updater.swift` before deletion.

- [ ] **Step 4: Build**

  Run: `xcodebuild -project Muse/Muse.xcodeproj -scheme Muse -configuration Debug build`
  Expected: `BUILD SUCCEEDED`. If Xcode's project uses file-system-synchronized groups
  (check `preferredProjectObjectVersion` in `project.pbxproj` — research found `77`,
  which supports synchronized groups), the deleted file and directory disappear from
  the build automatically. If the build fails with a "file not found" reference error
  referencing `Updater.swift`, open the project in Xcode once and remove the stale
  reference manually (`project.pbxproj` has explicit `PBXFileReference`/`PBXBuildFile`
  entries for it in that case — grep `project.pbxproj` for `Updater.swift` and delete
  matching entries plus their build-phase membership lines).

- [ ] **Step 5: Commit**

```bash
git add -A "Muse/Muse/Updates" "Muse/Muse/MuseApp.swift"
git commit -m "chore: remove UpdaterController/CheckForUpdatesView (Sparkle UI surface)"
```

---

### Task 5: Remove Sparkle from Info.plist, entitlements, and the SPM package reference

**Files:**
- Modify: `Muse/Info.plist` (delete lines 5-21)
- Modify: `Muse/Muse/Muse.entitlements` (delete the temporary-exception array + rewrite
  the network.client comment)
- Modify: `Muse/Muse/Muse-Debug.entitlements` (delete the temporary-exception array)
- Modify: `Muse/Muse.xcodeproj/project.pbxproj` (delete 6 Sparkle-related entries)
- Modify (or let regenerate): `Muse/Muse.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`

**Interfaces:** None produced.

- [ ] **Step 1: Delete the Sparkle keys from `Info.plist`**

  Delete lines 5-21 (the `SUFeedURL`, `SUPublicEDKey`, `SUEnableAutomaticChecks`,
  `SUEnableInstallerLauncherService` keys and their preceding Sparkle-explanation
  comment). Leave the Google OAuth comment at line 22 and everything after it untouched.

- [ ] **Step 2: Remove the temporary-exception entitlement from both entitlements files**

  In `Muse/Muse/Muse.entitlements`, delete:
  ```xml
  <key>com.apple.security.temporary-exception.mach-lookup.global-name</key>
  <array>
      <string>com.tarrats.Muse-spks</string>
      <string>com.tarrats.Muse-spki</string>
  </array>
  ```
  and its preceding comment block. Rewrite the `com.apple.security.network.client`
  key's comment to drop the "(1) Sparkle self-update" clause, leaving only the Drive
  share explanation — the key itself (`true`) stays.

  In `Muse/Muse/Muse-Debug.entitlements`, delete the same array (no comment there to
  rewrite).

- [ ] **Step 3: Remove the Sparkle package reference from `project.pbxproj`**

  Delete these 6 locations (exact content confirmed by research pass):
  1. `PBXBuildFile` entry: `5BFA00012F00000000000001 /* Sparkle in Frameworks */ = {isa
     = PBXBuildFile; productRef = 5BFA00022F00000000000002 /* Sparkle */; };`
  2. Frameworks build phase list entry: `5BFA00012F00000000000001 /* Sparkle in
     Frameworks */,`
  3. `packageProductDependencies` list entry: `5BFA00022F00000000000002 /* Sparkle */,`
  4. `packageReferences` list entry: `5BFA00032F00000000000003 /*
     XCRemoteSwiftPackageReference "Sparkle" */,`
  5. The `XCRemoteSwiftPackageReference "Sparkle"` definition block (repositoryURL
     `https://github.com/sparkle-project/Sparkle`).
  6. The `XCSwiftPackageProductDependency "Sparkle"` definition block.

  Do **not** touch the parallel GRDB entries (different GUID prefix, `58392B1*`) — they
  must remain exactly as-is. After deleting, grep to confirm: `grep -in sparkle
  "Muse/Muse.xcodeproj/project.pbxproj"` returns nothing.

- [ ] **Step 4: Remove the Sparkle pin from `Package.resolved`**

  Delete the `sparkle` identity entry (`identity: sparkle`, `location:
  https://github.com/sparkle-project/Sparkle`, `revision:
  d46d456107feacc80711b21847b82b07bd9fb46e`, `version: 2.9.3`) from
  `Muse/Muse.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`. This
  file self-regenerates on the next `xcodebuild`/Xcode resolve, so a manual edit is
  optional — but do it explicitly so the committed state doesn't lag the pbxproj change
  by one build.

- [ ] **Step 5: Build clean**

  Run:
  ```bash
  rm -rf ~/Library/Developer/Xcode/DerivedData/Muse-*
  xcodebuild -project Muse/Muse.xcodeproj -scheme Muse -configuration Debug build
  ```
  Expected: `BUILD SUCCEEDED`, no Sparkle package resolution step in the log, no
  "Cannot find 'Sparkle' in scope" or similar errors (would indicate a leftover `import
  Sparkle` outside the already-deleted `Updater.swift` — none expected per the research
  grep, but this build is the real proof).

- [ ] **Step 6: Re-run the MAS entitlement audit (Task 3) now that removal is complete**

  Confirm `com.apple.security.temporary-exception.mach-lookup.global-name` is absent
  from both entitlements files.

- [ ] **Step 7: Commit**

```bash
git add Muse/Info.plist "Muse/Muse/Muse.entitlements" "Muse/Muse/Muse-Debug.entitlements" \
        "Muse/Muse.xcodeproj/project.pbxproj" \
        "Muse/Muse.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
git commit -m "chore: remove Sparkle plist keys, entitlements, and SPM package reference"
```

---

### Task 6: Delete direct-distribution tooling (scripts, dmg assets untouched, docs deferred to Task 8)

**Files:**
- Delete: `scripts/release.sh`

**Interfaces:** None.

**Note:** `scripts/make-dmg.sh` and `scripts/make-dmg-background.sh` have **no Sparkle
coupling** (pure DMG assembly) per the research pass — leave them and the `dmg/`
directory in place. They may still be useful if a DMG is ever produced as a
side-artifact of a TestFlight/App Store build for internal sharing; deleting them isn't
required by this spec and isn't requested by DECIDED #33 (which only mandates removing
Sparkle and GitHub-download distribution, not DMG tooling generally). Only
`release.sh` is Sparkle-coupled (appcast generation via `SPARKLE_BIN`, EdDSA signing)
and unusable post-removal.

- [ ] **Step 1: Delete `scripts/release.sh`**

  Run: `git rm scripts/release.sh`

- [ ] **Step 2: Grep for any other reference to it**

  Run: `grep -rln "release.sh" --include="*.md" --include="*.yml" --include="*.yaml" .`
  Expected: only `docs/RELEASING.md` (rewritten in Task 8) and possibly CI config —
  if a CI workflow references it, note it for a follow-up (out of scope for this
  codebase-only spec per §0's "Cannot" list — CI/App Store Connect pipeline setup is an
  owner step, §8 of the spec).

- [ ] **Step 3: Commit**

```bash
git add -A scripts/release.sh
git commit -m "chore: remove release.sh (Sparkle appcast/EdDSA tooling, superseded by App Store Connect)"
```

---

### Task 7: Verify Sparkle is fully gone (grep sweep + dependency count check)

**Files:** None modified — verification only.

- [ ] **Step 1: Full-repo grep**

  Run: `grep -rin "sparkle" --include="*.swift" --include="*.plist" --include="*.entitlements" --include="*.pbxproj" . | grep -v "docs/session-log.md\|docs/new-build\|docs/superpowers/plans"`
  Expected: no matches in source/build-config files. Matches in
  `docs/session-log.md`/`docs/new-build/*`/plan docs are fine (historical record).

- [ ] **Step 2: Confirm dependency count is 1**

  Run: `grep -c "XCRemoteSwiftPackageReference" "Muse/Muse.xcodeproj/project.pbxproj"`
  Expected: `1` (GRDB only).

- [ ] **Step 3: Full test suite still green**

  Run: `xcodebuild -project Muse/Muse.xcodeproj -scheme Muse test`
  Expected: all existing suites pass (nothing in this section touches test-target
  code, so this is a regression check on the build-setting and deletion changes).

  This is the checkpoint for the whole Sparkle-excision section — do not proceed to
  Section B until this is green.

---

### Task 8: Rewrite `docs/RELEASING.md` and `README.md` for App Store distribution

**Files:**
- Modify: `docs/RELEASING.md` (full rewrite of the update-mechanism sections)
- Modify: `README.md` (lines ~105, 122, 128, 135 per research: features list, build
  instructions, RELEASING.md pointer)

**Interfaces:** None.

- [ ] **Step 1: Rewrite `docs/RELEASING.md`**

  Replace the title "Releasing Muse (direct distribution + Sparkle)" with "Releasing
  Muse (Mac App Store)". Replace the appcast-generation / EdDSA-signing / `SPARKLE_BIN`
  discovery sections with the App Store Connect flow: archive (`xcodebuild archive` or
  Xcode Organizer) → validate → upload → TestFlight (internal, then external for the
  10-photographer validation pass) → submit for review. Keep any DMG-assembly
  instructions that are still accurate (Task 6 left `make-dmg.sh` in place) but note
  they're now optional/internal-sharing-only, not the release mechanism. Remove the
  sandboxed-XPC-installer notes (Sparkle-specific, no longer applicable).

- [ ] **Step 2: Update `README.md`**

  - Features list: replace "Updates: Sparkle" with "Updates: Mac App Store" (or remove
    the line if the features list is being trimmed — match the surrounding list's
    style).
  - Build instructions: replace "GRDB and Sparkle are..." with "GRDB is the only
    third-party dependency (resolved automatically by Xcode via Swift Package
    Manager)."
  - Requirements: this was already touched in Task 2 Step 4 (Apple Silicon line) — no
    duplicate edit here, just confirm it's present.
  - Any "Staying up to date" section: replace Sparkle self-update description with "The
    app updates automatically through the Mac App Store."
  - The RELEASING.md pointer sentence: confirm it still resolves (no broken link, no
    stale description of what that doc covers).

- [ ] **Step 3: Read both files back for consistency**

  No leftover Sparkle mentions, no leftover GitHub-download language describing current
  distribution as a fact (historical mentions describing the pre-2026-07 state are fine
  if clearly marked as history, matching how `CLAUDE.md` itself keeps the 2026-06-15
  pivot as marked history).

- [ ] **Step 4: Commit**

```bash
git add docs/RELEASING.md README.md
git commit -m "docs: rewrite release docs for Mac App Store distribution, drop Sparkle references"
```

---

