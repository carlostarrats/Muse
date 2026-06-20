# Muse — Claude project notes

This file is loaded into Claude's context when working in this repo.
It documents the project's identity, current state, and conventions
so a fresh Claude session can pick up productively.

## Project identity

Muse is a **filesystem-native universal file viewer + AI-organized
asset library** for macOS, in the spirit of Adobe Bridge but
local-first, Apple-Intelligence-native, and free forever.

- Distribution: **Direct** — a Developer ID–signed, notarized build that
  self-updates via **Sparkle**, hosted on GitHub Releases (DMG with a
  drag-to-Applications background). **Not the Mac App Store**: Sparkle
  self-update is incompatible with MAS, and shipping directly lets updates
  go out without an App Store submission. Still **sandboxed**. (Pivoted from
  MAS on 2026-06-15 — see that session log. If a MAS build is ever wanted,
  it must be a separate target/config with Sparkle compiled out.) Release
  workflow: `docs/RELEASING.md`.
- Pricing: **Free**, no IAPs, no subscriptions, no ads
- Network policy: **Update-only**. No analytics, no telemetry, no data
  collection, no remote content fetches. The **only** network access is
  Sparkle: fetching its signed appcast feed + downloading the update, gated
  by `com.apple.security.network.client` (added 2026-06-15 for Sparkle, the
  sole network code path). Every download is EdDSA-verified against the
  embedded `SUPublicEDKey`. `SUEnableAutomaticChecks = true` so Sparkle checks
  quietly in the background with no UI unless an update exists (the first-run
  consent prompt was removed 2026-06-15 — it was a confusing first launch and
  its modal stole focus from the main window).
  iCloud Drive *document* sync (the optional single "Muse" iCloud folder) is
  mediated by the OS sync daemon and adds only the iCloud Documents
  entitlement. The developer still receives **no data**, so the "Data Not
  Collected" privacy label is unchanged.
- Data collection: **None**. Privacy nutrition label = "Data Not Collected".
- Min macOS: **14.6** (Vision/PDFKit/AVKit/FSEvents/FTS5 all work).
  Foundation Models is used only to name auto-generated collections,
  capability-gated to Apple Intelligence Macs (macOS 26+); the in-app
  chat panel was retired (see the 2026-06-12 session log).
- Primary user persona: **generalist** — managing a Downloads folder,
  Documents, miscellaneous archives. Defaults bend to fast Quick Look
  + Open With; AI features available but not the front door.

## Plan documents

The full design lives in:

- `docs/superpowers/plans/file-viewer-rewrite.md` — the binding plan.
- `docs/superpowers/specs/2026-06-10-post-rewrite-polish-design.md` — the
  polish-pass spec (all four phases shipped: AI brain ✅, hero viewer ✅,
  spatial views ✅, delights ✅).
  Five rounds of review revisions baked in. All open product questions
  resolved. Implementation status reflected in the phase log below.

Read this before making any non-trivial change. The identity
reconciliation matrix in §4 and the FileNode lifecycle table in §3.1
are the load-bearing reference artifacts.

- `docs/possible-updates.md` — low-priority, non-blocking backlog (cosmetic
  code tidiness + deferred decisions). Nothing here is a problem; fold items in
  opportunistically when shipping something else. Don't cut a release for them.

## Implementation status

| Phase | Status | Branch where it landed |
|---|---|---|
| 0 — strip import-based code paths | ✅ shipped | `feat/file-viewer-rewrite` |
| 0.5 — v0.1 filesystem shell | ✅ shipped | `feat/file-viewer-rewrite` |
| 1 — indexing + read-only viewers + starring | ✅ shipped | `feat/file-viewer-rewrite` |
| 2 — universal viewer fill-out | ✅ shipped | `feat/file-viewer-rewrite` |
| 3 — Vision pipeline + tag panel + smart sort | ✅ shipped | `feat/file-viewer-rewrite` |
| 4 — duplicate finder + delete-to-trash | ✅ shipped | `feat/file-viewer-rewrite` |
| 5 — FTS5 search + scope toggle | ✅ shipped | `feat/file-viewer-rewrite` |
| 6 — App Intents (Shortcuts/Siri/Spotlight) | ✅ shipped | `feat/file-viewer-rewrite` |
| 7 — chat panel (Foundation Models, gated) | ✅ shipped | `feat/file-viewer-rewrite` |
| 8 — Globe rework + water shader on grid tiles | ✅ shipped | `feat/file-viewer-rewrite` |
| Polish 1 — AI brain (protocols, semantic search, living collections) | ✅ shipped | `feat/ai-brain` (merged) |
| Polish 2 — hero viewer (adaptive wash, info cards, zoom/pan, delete+undo) | ✅ shipped | `feat/hero-viewer` (merged) |
| Polish 3 — spatial views (cloud + graph, globe retired) | ✅ shipped | `feat/spatial-views` (merged) |
| Polish 4 — delights (burn-up delete, background moods) | ✅ shipped | `feat/delights` (merged) |
| Polish 5 — cloud rework (3D orbit ball) + galaxy view (similarity cloud, replaces graph) | ✅ shipped | `main` |
| Polish 6 — screenshot intent collections + Galaxy taste-map (color by intent) | ✅ shipped | `main` |
| Polish 7 — grid virtualization (perf) + thumbnail prewarm; cloud/galaxy views removed | ✅ shipped | `main` |
| Polish 8 — iCloud sync folder (portable `.muse` sidecars, no re-Vision) + macOS share (Share button + "Send to Muse" extension) | ✅ shipped | `feat/icloud-sync-share` |
| Polish 9 — Page Up/Down grid scrolling (Fn+Arrow on Mac) | ✅ built, unmerged | `feat/page-scroll` |
| Polish 10 — share a collection as a paginated 11×14 PDF (Save to… / Share menu) | ✅ built, unmerged | `feat/collection-pdf-share` |
| Polish 11 — grid multi-select + actions (collection/tag/share/move), drag-to-move, Reveal in Finder, native search field | ✅ built, unmerged | `feat/multi-select` |
| Polish 12 — folder ops (new subfolder + rename w/ DB migration) + hero Share/Open-With dropdown + Info modal refresh | ✅ built, unmerged | `feat/folder-ops-and-share` |
| Polish 13 — tile background (global grid backdrop None/Auto/Light/Dark Grey/Black) + collection PDF export reflects the grid (ratio + per-image backdrop; paper stays white) + file cards now export | ✅ built, unmerged | `feat/next-22` |
| Polish 14 — Duplicates modal redesign: grid-style tile selection (blue inset ring, no tint, image fits), KEEP badge follows survivors, suggested deletes pre-selected + overridable, reveal-in-Finder per tile, "never delete a whole group" protection (2-copy swap / 3+ lock) | ✅ built, unmerged | `feat/next-23` |
| Polish 15 — synchronized toolbar-icon recolor on mood change (all nav icons flip white↔black together, in lockstep with the background fade; `MoodPalette.iconColor` + `View.moodToolbarIcon`) | ✅ built, unmerged | `feat/next-24` |
| Polish 16 — accessibility pass on features added since `feat/next-17` (next-18→24): VoiceOver labels/traits, a menu-bar "New Collection from Selection…" command, an icon-only-button label sweep across the whole app, and a `CollectionCard` rework (one activatable element w/ name+count label, selected trait, primary + named-Delete actions) | ✅ shipped | `feat/next-25` |

> **2026-06-16 session — three feature branches off `main`, not yet merged.**
> Each has its own spec + plan in `docs/superpowers/`. Merge order is
> independent; reconcile `docs/session-log.md` + this file's architecture map on merge.

`feat/file-viewer-rewrite` was merged to `main` after Phase 8
finished — see the merge commit. The branch was kept around as an
audit trail of the per-phase progression.

## Session history

The full, chronological narrative of every working session (2026-06-12 →
present) lives in **`docs/session-log.md`** — read the relevant entry when you
need the full "why" behind a specific change. The load-bearing decisions and
must-not-break rules from those sessions are distilled below so a fresh session
doesn't have to read the whole archive.

### Durable constraints & gotchas (DO NOT BREAK)

These are hard-won; re-introducing any of them re-introduces a shipped bug.
The four most critical are also saved as Claude memories (linked).

- **Grid must stay virtualized.** Never put a custom SwiftUI `Layout` or any
  non-lazy container over the full file set — it materializes every tile and
  relayouts O(n) on each publish (1700-image folders became unusable). Use
  `MasonryGeometry` precomputed frames + a manual viewport window. Memory:
  `muse-grid-must-stay-virtualized`.
- **Fix the code, not the dev DB.** The user's library is a disposable test
  fixture; never ship one-off data migrations to patch a corrupted local DB —
  fix the forward code and validate by a clean re-index. Memory:
  `muse-fix-code-not-my-data`.
- **iCloud change detection = content hash, NOT size/mtime.** iCloud oscillates
  size/mtime on repeated reads, so a size/mtime fast-path reindexes the whole
  folder every visit — never reintroduce it for iCloud items. In-place edits ARE
  re-checked via **content hashing** (FSEvents-driven live + a background
  verify on cold folder open) — deliberate, don't revert. Memory:
  `muse-icloud-content-refresh-override`. The zero-byte-hash guard in
  `HashService.sha256` must stay (its loss welded 900+ files onto one row).
- **Classification never reads dataless iCloud bytes.** `AssetKind`'s ImageIO
  header sniff (the extensionless/unknown-extension image fallback, feat/next-27)
  guards on `.ubiquitousItemDownloadingStatusKey` and skips not-downloaded
  placeholders — reading their bytes would force a download just to classify a
  file the user is only browsing past. Don't drop the guard; the file
  reclassifies once it's local. Same spirit as `Indexer.isDataless` / the
  `HashService` dataless-nil rule.
- **Tags are per `(file_id, parent_dir)`**, not per content hash. A duplicate in
  another folder has its own tags; deletes never leak across folders; there is
  NO library-wide tag delete. Other content-derived metadata (palette/caption/
  dims/intent/feature-print/FTS/embeddings) stays content-hash-keyed by design.
  Memory: `muse-tags-are-per-file-not-per-content-hash`.
- **iCloud container is data-loss-sensitive.** Debug builds sign with
  `*-Debug.entitlements` (production minus the three iCloud keys) so dev-build
  churn can't make `bird` purge the production ubiquity container. Release/App
  Store keep iCloud. Ship updates via **Sparkle only** (atomic in-place swap
  preserves app identity) — never tell users to drag a new DMG over the old app.
- **No live SQLite in iCloud** (corruption trap) — sync is per-asset JSON
  sidecars written with `NSFileCoordinator`. CloudKit is rejected (it would add
  a network surface; the only network path is Sparkle's appcast).
- **Sidebar rows: never use `.onDrag`.** It installs an AppKit drag source on the
  shared hosting view and eats single-clicks. Reorder is a live `DragGesture` off
  a trailing grip + an opaque on-top overlay (LazyVStack ignores `.zIndex`).
- **`bookmarks.$roots` sink delivers synchronously** — don't add `.receive(on:)`;
  the non-animated reorder commit relies on synchronous delivery.
- **Fixed-viewport overlay effects:** per-element `.layerEffect`/`.visualEffect`
  is the wrong tool (breaks containers, only touches on-screen elements). The
  gradual-blur attempt was fully reverted; only the HTML prototype remains.
- **No Metal shaders remain** (water + burn both removed); `Effects/` holds only
  the opacity-fade delete modifier.
- **FSEvents:** the stream needs `kFSEventStreamCreateFlagUseCFTypes` or
  `eventPaths` is a raw `char**` (crash on first change).
- **Hero close (2026-06-18):** the very slight search-bar "flash" on close is
  the native toolbar/search field materializing over the fading backdrop as the
  nav returns during the flight — inherent to the instant "never gone" return
  (the macOS toolbar can't fade). Accepted. Do NOT reintroduce the
  always-present-toolbar (shows empty item wells over the hero) or the
  return-after-land approach (kills the instant feel) — both were tried.
  **Escape must fire ONLY `viewerClosing = true`** and let `startClose()` (run
  via HeroImageViewer's `viewerClosing` onChange) own the whole close — including
  setting `viewerDismissing` itself, exactly as the X button does. A pass that
  ALSO set `viewerDismissing` up front in ContentView's Escape handler (to shave
  the onChange hop's "beat") made Escape need TWO presses: the nav returned but
  the close didn't complete. Don't add a separate `viewerDismissing` write to the
  Escape path — route everything through the one flag (fixed 2026-06-18).
- **Collection "delete" = `setHidden(true)`** (durable tombstone the recluster
  upserts never clear), NOT a row delete (which silently regenerates).
- **Bulk tag delete leaves `analyzed_hash` untouched** so the auto-tagger never
  resurrects removed tags; they only return via an explicit Regenerate.
- **Duplicates modal never fully deletes a group** — at least one copy of every
  duplicate group is always kept. The delete set is a global `Set<URL>` but a file
  can be in several groups (byte-exact + filename + visual), so the rule
  (`DuplicateDeleteRules`) checks EVERY group a file belongs to, not just the
  first; selecting that would empty a group is refused (3+ copies) or swaps (a
  single 2-copy group), and cross-group pre-seed conflicts are reconciled by
  `rescued`. Don't reintroduce a per-`first`-group check — it lets overlapping
  groups bypass the guarantee.
- **Never drive a perpetual animation with a global `withAnimation(....repeatForever(...))`
  in `.onAppear`.** The repeat-forever transaction stays live and leaks into ANY
  view repositioned in the same update cycle — most visibly the AppKit-hosted
  window toolbar. `GridView`'s `ShimmerBand` (loading sheen) did exactly this, and
  during a grid relayout while thumbnails were still loading (column-slider drag in
  a search) the trailing toolbar icons drifted up/down in a perpetual 1.8s linear
  sawtooth on slow/Intel hardware. Use the value-scoped `.animation(_:value:)`
  modifier (keyed on the animated `@State`) so the repeat is confined to its own
  subtree. Fixed 2026-06-19; see that session log.
- **A `ScrollView` clips to its OWN frame — reserve the floating-toolbar clearance
  ABOVE the scroll view, not as inner content padding.** The window toolbar's
  background is hidden (`.toolbarBackground(.hidden)`), so any scroll surface whose
  frame reaches the toolbar edge lets content slide up UNDER the toolbar/search bar
  on scroll. The grid avoids this because `TagChipsRow` (even its no-tags branch)
  sits above `GridView` and reserves a 10pt strip, dropping the grid's clip
  boundary below the toolbar so content is cut off there. Inner `.padding(.top:)`
  does NOT help — it scrolls away with the content. Every top-level scroll surface
  (the grid AND `CollectionsPage`) needs its own reserve; they're independent
  views. Keep the two reserves on the shared `TagChipsRow.noTagsTopClearance`
  constant so they can't drift. Fixed 2026-06-19 (`feat/next-29`); see that log.
- **Sidebar live-drag reorder must commit the new order SYNCHRONOUSLY, and the
  reorderable list must be a NON-lazy stack.** Two hard-won rules from the sidebar
  Collections reorder (`feat/next-32`), mirroring the folder reorder: (1) the drag
  commit clears its lift offsets in a `withTransaction(disablesAnimations)` block
  that ASSUMES the list is already in the new order — so the reorder has to land in
  that same synchronous transaction. The folder path gets this free because
  `bookmarks.$roots` delivers synchronously; the collection path had to update the
  in-memory `CollectionsEngine.collections` `sort_order` in place SYNCHRONOUSLY
  (then persist to SQLite async, no reload) — an async DB-write-then-reload made the
  dropped row snap/flash a frame late. (2) A reorderable `ForEach` must be a plain
  `VStack` iterated DIRECTLY by a stable id (`id: \.collection.id`), NOT a
  `LazyVStack` over `Array(enumerated())` — the lazy+enumerated combo makes SwiftUI
  treat a sort reorder as insert/remove and fly rows in from the edge instead of
  moving them in place. Animate the reorder with a list-scoped `.animation(_:value:)`
  keyed to the sort mode, never a global `withAnimation` (which animates the whole
  surrounding layout). See the 2026-06-19 `feat/next-32` session log.
- **`withAnimation` does NOT animate an `@AppStorage`-backed change** — the
  UserDefaults publish lands outside the transaction, so the change is instant. If
  a persisted boolean needs to animate (e.g. a sidebar section collapse), back it
  with plain `@State` seeded from / written to `UserDefaults` via `.onChange`, then
  `withAnimation` works; or use a value-scoped `.animation(_:value:)`. (`feat/next-32`.)

### Session index (detail in `docs/session-log.md`)

- **2026-06-12** `main` — post-polish: hero viewer polish, Collections redesign,
  tag chips row, automatic Vision pipeline (Analyze button gone), background
  moods rework, shell cleanup, gradual-blur reverted.
- **2026-06-13** `main` — screenshot intent collections + classifier; Galaxy
  taste-map trial; screenshot→source-link ruled out.
- **2026-06-13** `main` — perf: grid virtualized (MasonryGeometry), thumbnail
  prewarm, Cloud/Galaxy views removed, responsive folder selection, iCloud
  size/mtime oscillation fixed.
- **2026-06-13** `feat/icloud-sync-share` — iCloud sync zone + portable sidecars
  + hydration; in-app Share + "Send to Muse" extension.
- **2026-06-13** `main` — Collections page; water effect removed; tags-in-
  collection fix; nav crossfades.
- **2026-06-13** `feat/next-2` — Delete/Regenerate All Tags menu commands;
  Organizing pill.
- **2026-06-14** `feat/next-6` — hero zoom-out (minZoom 0.7); Duplicates
  redesign; sidebar drag-to-reorder (identity-based).
- **2026-06-15** `feat/next-7` — tagging overhaul: NamedColor neutrals/achromatic
  gate, weighted color dominance, classification curation (no sensitive labels);
  identity de-weld via hash guard + clean re-analyze.
- **2026-06-15** `main` — Sparkle self-update + pivot to direct distribution
  (GitHub Releases, DMG); see `docs/RELEASING.md`. network.client added for
  Sparkle only; sandbox installer-launcher fix.
- **2026-06-16** off `main` — three unmerged branches: page-scroll,
  collection-pdf-share, multi-select.
- **2026-06-16** — tag-chip count overlap fix; all tags shown; remove-from-
  tag/collection.
- **2026-06-16** `safety/icloud-dev-container-isolation` — Debug entitlements
  drop iCloud keys (purge safeguard).
- **2026-06-17** `main` — in-place edit refresh: change-detection overhaul
  (thumbnail invalidate, FSEvents changed-paths, content-hash re-check; iCloud
  override).
- **2026-06-17** `feat/in-place-edit-refresh` — sort-direction toggle; cosmetic
  tidy (AppState split, Fluid→Effects).
- **2026-06-17** `feat/collections-delete-and-settings` — Delete Collection
  (setHidden) replaces Hide; auto-organization opt-outs; hand-made collections.
- **2026-06-17** `feat/per-file-tags` — tags keyed `(file_id, parent_dir)`;
  removed library-wide delete; `v7` migration.
- **2026-06-17** `feat/next-9` — deselect parity; PDF filename captions;
  double-click-on-old-Macs timing fix.
- **2026-06-17** `feat/next-9` — cross-folder views drop sidebar highlight;
  search scope picker (All / This Folder).
- **2026-06-17** `feat/next-10` — transition smoothness; folder-switch perf;
  tag-chip loading moved into the model (`TagChipLoader`); `visibleFiles`
  memoized.
- **2026-06-17** `feat/next-11` — grid file names setting; native macOS
  icons/previews for non-image tiles (QuickLook `.all`).
- **2026-06-17** `feat/next-12` — grid hover veil + padded mood-adaptive
  selection ring (`SelectionStyle`).
- **2026-06-17** `feat/folder-ops-and-share` — New Subfolder / Rename Folder
  (+ DB path-prefix migration); hero Share/Open-With dropdown; Info modal
  refresh.
- **2026-06-17** `feat/next-14` — hero-close deselect (no stray ring flash);
  collection-card hover veil.
- **2026-06-18** `feat/next-15` — sidebar folder-click reliability (no `.onDrag`);
  reorder rebuilt as a live DragGesture.
- **2026-06-18** `feat/next-15` — sidebar folder sort modes + live per-folder
  counts (`FolderStat`/`FolderStatCache`).
- **2026-06-18** `feat/next-16` — ghost-row reconcile on folder load
  (`PathReconciler`, false-empty guard, chunked markDead); tag-chip sort control.
- **2026-06-18** `feat/next-17` — accessibility pass on post-2026-06-13 UI;
  reorder keyboard path (Move Up/Down).
- **2026-06-18** `feat/next-18` — search bar back to fixed 320; both hero-close
  paths return the nav identically (Escape matches X); close-flash decision.
- **2026-06-18** `main` (release v1.1.2) — fix the next-18 regression: Escape
  needed two presses. ContentView's Escape handler now fires only
  `viewerClosing`; `startClose()` owns the whole close (matches X).
- **2026-06-18** `feat/next-19` — right-click "New Collection from Selection":
  create a manual collection from the selected image(s) (additive beside "Add to
  Collection"; reuses createManual + addFile, no navigation). Now prompt-first —
  a "Name Collection" .alert (Rename-Folder pattern) names it on confirm;
  Cancel/blank creates nothing. The Collections-page "+" is unified onto the
  same modal (empty selection → empty named collection).
- **2026-06-18** `feat/next-20` — Collections-page sort: the toolbar sort menu +
  direction arrow are now live on the Collections card grid, showing only the
  modes that apply to a group (Name / Date Created / Date Modified — Size/Kind/
  Color/Shape hidden). New pure `CollectionSort` helper (mirrors `FolderSort`,
  unit-tested); `AppState.collectionSortMode`/`collectionSortReversed`
  (@Published, persisted in `AppSettings`), independent of the grid sort. Spec +
  plan in `docs/superpowers/`.
- **2026-06-18** `feat/next-21` — global Image Layout: a new toolbar grid button
  (between Collections and the mood button) opens an InfoSheet-styled modal that
  picks how images lay out on every grid — masonry (default) or one of 11 fixed
  aspect ratios. New `ImageLayout` enum (unit-tested) + `AppSettings.imageLayout`
  / `AppState.imageLayout` (@Published, persisted). Fixed ratios feed
  `MasonryGeometry` a uniform aspect (which packs an exact row-major grid — no
  new geometry engine), and the tile's existing `tileFill` grey behind a `.fit`
  image letterboxes without cropping. The modal (`ImageLayoutSheet`) mirrors a
  grid tile's selection (square fill shrinks/insets to blue inside a rounded 8pt
  ring). Extracted the shared `SheetCloseButton` (was copied in InfoSheet). Spec
  + plan in `docs/superpowers/`.
- **2026-06-18** `feat/next-22` — tile background: the grey behind images/file
  cards is a global, user-selectable backdrop (`TileBackground` enum: None /
  Auto / Light / Dark Grey / Black; default Auto = follows mood), set in a new
  section of the mood popover. Masonry forces Auto
  (`AppState.effectiveTileBackground`); fixed ratios honor a static pick. Grid
  tiles draw `AppState.tileFill`; the file-card filename auto-contrasts to the
  backdrop (`SelectionStyle.relativeLuminance`). The collection PDF export now
  mirrors the grid — the active ratio + per-image backdrop color, paper page
  always white — and **file cards export** too (QuickLook icon/preview via the
  exporter's bounded-concurrency decode). `ImageLayoutSheet` tiles fixed to a
  mood-independent grey; `ImageLayout.masonry` displayName "Mason" → "Masonry".
  New `Models/TileBackground.swift` (unit-tested) + `AppSettings.tileBackground`.
  Spec + plan in `docs/superpowers/`.
- **2026-06-18** `feat/next-23` — Duplicates modal redesign: each duplicate is a
  grid-style tile (image fits/no-crop on a transparent square that reveals the
  card grey; marking for delete insets the image + draws a blue ring, no tint;
  fixed modal colors, not the mood accent) with a reveal-in-Finder button. The
  finder's suggested keeper is no longer locked — groups open with non-keeper
  copies pre-marked for delete (overridable), and the green KEEP badge tracks
  **survivors** (any tile not marked), so multiple keeps are allowed. A group can
  never be fully deleted: 3+ copy groups lock the last survivor, a 2-copy group
  swaps instead (selecting the survivor frees the other). Because one file can be
  in several groups (byte-exact + filename + visual) over a global delete set, the
  rule checks **every** group a file is in. Pure `Intelligence/Dedup/DuplicateDeleteRules.swift`
  (`seed`/`rescued`/`isLocked`/`selecting`, unit-tested) — mirrors `GridSelection`/
  `CollectionSort`. Only `DuplicatesView.swift` + the helper changed.
- **2026-06-18** `feat/next-24` — synchronized toolbar-icon recolor on mood
  change: the nav toolbar icons inherited the system label color, so a
  `preferredColorScheme` flip recolored each native `NSToolbarItem` on AppKit's
  own per-item crossfade timeline (staggered) and the group lagged the background
  fade. Now each icon is colored EXPLICITLY from the mood (`MoodPalette.iconColor`
  = white in dark scheme / black in light) via a file-private
  `View.moodToolbarIcon(_:selected:)` that pairs it with the SAME
  `.animation(.easeInOut(duration: 0.35), value: moodPalette)` the background uses
  — every icon flips together and in lockstep with the fade. Applied to all eight
  toolbar icons; `selected:` preserves the native white-on-accent look for the two
  `Toggle`s (show-subfolders, mood) while "on". A native `Toggle`'s own AppKit
  crossfade is the irreducible floor (accepted). `ContentView.swift` +
  `Models/Mood.swift`; no test (Color equality is unreliable; trivial one-liner).
- **2026-06-18** `feat/next-25` — accessibility pass on everything added since the
  last one (`feat/next-17`), i.e. next-18→24. Three parts: (1) **new-feature
  VoiceOver gaps** — Image Layout toolbar button label (next-21); Tile Background
  swatches got a disambiguating "Tile background: …" label + `.isSelected` trait
  (next-22; "Auto"/"Light" collided with the mood swatches); the Duplicates tile's
  `.accessibilityElement(children: .ignore)` was hiding its reveal-in-Finder button
  — re-exposed as a named action (next-23). (2) **menu-bar reach** — added
  "New Collection from Selection…" to the Collections menu (next-19 was grid
  right-click only, no keyboard/VoiceOver path); gated on a non-empty selection.
  (3) **app-wide icon-button sweep** — every icon-only `Button`/`Menu`/`Toggle`
  that had only `.help()` (which sets AXHelp, not the VoiceOver *name*) got an
  explicit `.accessibilityLabel`: the toolbar (subfolders, Collections, About,
  Sort, Tag order, Background), Collections header (save/cancel/delete/back),
  Collections "+", hero Share + color swatch ("Copy color #…"), collection-share,
  sheet close ✕, Duplicates reveal/close. Decorative grid-slider min/max icons
  `.accessibilityHidden`; the slider itself labeled "Images per row". The sidebar
  reorder grip is `.accessibilityHidden` (mouse-only; its tap just re-selects, and
  the accessible reorder path is Edit → Move Folder Up/Down). The active tag chip
  got an `.isSelected` trait. Finally the **`CollectionCard`** (a tap target, not a
  `Button`) was collapsed into ONE activatable element: name+count label, `.isButton`
  (+`.isSelected` when active), a primary `.accessibilityAction` for open, and a
  named "Delete Collection" action re-exposing the right-click-only delete. Pitfall
  avoided: never put `.accessibilityElement(children: .ignore)` on a `Button` (it can
  drop the activation) — on a Button, `.accessibilityLabel` alone overrides the name
  and keeps the action; and `.help` + `.accessibilityHint` both write macOS AXHelp,
  so keep one (kept `.help` for the truncation tooltip). Additive a11y annotations
  only — no layout/behavior change. Build + full test suite green.
- **2026-06-19** `fix/toolbar-icon-drift` — toolbar icons drift during grid resize.
  A tester's recording showed three trailing toolbar icons (Image Layout, mood,
  About) drifting vertically in a perpetual ~1.8s linear sawtooth while resizing
  the grid (column slider) mid-search; Collections (the anchor item) stayed put.
  Frame-by-frame measurement matched the waveform to `GridView`'s `ShimmerBand`
  loading sheen, which drove its sweep with a GLOBAL
  `withAnimation(.linear(1.8).repeatForever(autoreverses:false))` in `.onAppear`.
  That repeat-forever transaction stays live and leaks: when the grid relayouts
  while thumbnails are still loading, SwiftUI repositions the AppKit-hosted toolbar
  items in the same update cycle and sweeps their move into the never-ending
  animation (the anchor item has no delta, so it's immune). Intel/slow-hardware
  prone — needs a live shimmer present during a relayout, which warm caches on
  fast Macs avoid. Fix: scoped the sweep to a value-keyed `.animation(_:value:)`
  modifier on the band (`value: phase`), so the repeat can't bleed into the
  toolbar; identical sweep, Reduce-Motion parity preserved. One file
  (`Views/GridView.swift`). Build + full test suite green; independent review
  clean. See the durable gotcha above + that session log.
- **2026-06-19** `feat/next-27` — extensionless images shown as broken "?" file
  cards. A real JPEG saved with an Instagram alt-text filename overran the APFS
  255-byte limit, which truncated off its `.jpg`. With no usable extension macOS
  reports it as `public.data`/"Document", so `AssetKind` classified it `.unknown`:
  the grid drew a generic "?" doc card and a click opened the bare `ViewerChrome`
  fallback (filename title strip + "?" placeholder, no tags/info/Reveal) instead
  of the hero. `AssetKind.swift`'s comment claimed magic-byte sniffing but the
  code only read the OS content-type (which gives up at `public.data`). Fix: a
  last-resort ImageIO header sniff (`CGImageSourceGetType`) in `classifyByUTType`
  when extension + content-type name no handled kind, so a truncated-extension or
  unrecognized-extension image (`.jpg_large`, `.dat`) classifies as `.image` —
  one change fixes BOTH the grid tile (ThumbnailCache also keys off `detect`, so
  `.image` → ImageIO thumbnail) and the hero route. Guards against reading
  dataless iCloud placeholders (`.ubiquitousItemDownloadingStatusKey`) so
  classification never forces a download. User file left untouched (no rename).
  New `AssetKindTests.swift` (7 cases: extensionless/unrecognized-ext image +
  non-image, truncated-Instagram shape, normal `.jpg`). Build + full suite green
  (260); two independent review rounds clean. See the durable gotcha above.
- **2026-06-19** `feat/next-28` — collection "shows N but opens empty": a count-
  vs-contents source split. The badge read `CollectionStore.fetchAll`'s pure
  `is_alive=1` count from a cached `CollectionsEngine` snapshot; the opened grid
  read a live `alivePaths` + `fileExists` set — so a stale snapshot (or an
  out-of-root member the sandbox can't show, e.g. `~/Downloads/social.jpg`) read
  as "15 over empty." **Lever 1 (shipped, TDD):** `fetchAll(rootPaths:)` now counts
  alive member PATHS narrowed to those under an active root (pure
  `CollectionStore.isUnderAnyRoot` prefix rule; empty roots → plain-count
  fallback); `CollectionsEngine.setRoots` holds the roots (pushed by
  `AppState.rebuildRootNodes`) and feeds the count. The grid side
  (`setActiveCollection`) applies the SAME `isUnderAnyRoot` filter before its
  `fileExists` node build, so badge and grid share one predicate (grid ≤ badge via
  the extra `fileExists`); the count is per-PATH (`DISTINCT absolute_path`, matching
  the grid's per-path tiles). So the badge can never claim a number the grid can't
  back up and the out-of-root phantom counts in neither. New
  `CollectionCountReachabilityTests.swift` (8 cases); two review rounds clean.
  **Lever 2 (deferred):** the
  transient churn's leading cause is a partial iCloud enumeration on a post-update
  cold launch dropping not-yet-materialized files from `is_alive` (the existing
  `PathReconciler` `trustworthy` probe guards only the FULLY-empty case). Per the
  spec's gate ("confirm the trigger before hardening this data-loss-sensitive
  path"), only a diagnostic `print("[PathReconciler] …")` on mark-dead was added —
  the partial-materialization guard awaits a confirmed repro. Full suite green
  (259). Spec: `docs/superpowers/specs/2026-06-19-collection-count-vs-contents-mismatch-design.md`.
- **2026-06-19** `feat/next-29` — Collections-page scroll-clip: on the dedicated
  Collections **card page**, scrolling up let cards slide UNDER the floating
  toolbar instead of being cut off at the toolbar edge like the main grid. Cause:
  a `ScrollView` clips to its own frame; the grid sits below `TagChipsRow`, whose
  no-tags branch reserves a 10pt clearance ABOVE the grid's scroll view (its clip
  boundary lands below the toolbar), but `CollectionsPage` (the standalone
  `isCollectionsPage` branch) filled the whole detail pane with no reserve, so its
  clip boundary was at the toolbar edge. Fix: wrap `CollectionsPage`'s body in a
  `VStack(spacing: 0)` with the same `Color.clear` reserve above its
  `GeometryReader`/`ScrollView` (and move `.background` onto the VStack so the
  strip is painted) — clip boundary now matches the grid; the "Collections" title
  also aligns with the in-collection header (both at 10 + 14 = 24pt; were 10pt
  off). The in-collection view already inherited the reserve via `TagChipsRow`, so
  the cutoff is now universal. The shared `10` is one constant
  (`TagChipsRow.noTagsTopClearance`) read by both so they can't drift (review nit).
  Build + full suite green; one review round (ship). `CollectionsPage.swift` +
  `TagChipsRow.swift`; no test (pure SwiftUI layout). See the durable gotcha above.
- **2026-06-19** `feat/next-30` — Escape backs out of a collection / the
  Collections page (keyboard accelerator alongside the visible back buttons).
  A pure `EscapeResolver`/`EscapeAction` (`Components/EscapeAction.swift`, mirrors
  `GridSelection`/`PageScroll`) resolves a peel-one-layer priority chain: hero
  viewer → other viewer → active/typed search → inside a collection (pop to the
  Collections page, = `setActiveCollection(nil)`) → Collections page (back to the
  grid, = `toggleCollectionsPage()`) → plain grid (no-op). `ContentView`'s hidden
  `keyboardShortcut(.escape)` Button is now a thin mapper onto those existing
  calls. The hero-close path is structurally untouched — any selected file
  short-circuits to `.closeHero`/`.closeViewer` BEFORE any back-out case, and
  `.closeHero` still fires ONLY `viewerClosing` (preserves the 2026-06-18 two-press
  fix). QA finding folded in: a search runs WITHOUT clearing the collection/page
  underneath, so search is peeled ABOVE the collection (`.clearSearch` →
  `AppState.clearSearch()` leaves collection state intact, returning to the
  collection's members) — never a dead key. "Search present" =
  `isSearchActive || !searchQuery.isEmpty`, extracted to a tested
  `EscapeResolver.searchPresent(...)`. Modals are a non-issue (SwiftUI
  `.sheet`/`.alert`/`.popover` are separate key windows; the parent's Escape
  Button doesn't fire under them). New `MuseTests/EscapeActionTests.swift` (12
  cases); independent review returned ship (no Critical/Important). Build + full
  suite green. `Components/EscapeAction.swift` + `ContentView.swift`.
- **2026-06-19** `feat/next-31` — Image Layout modal tiles are mood-adaptive. The
  9 layout-selection tiles were a fixed light-grey card (`Mood.paperPalette.tileFill`,
  the deliberately mood-independent choice from feat/next-22), so on a Dark/Custom
  mood — where the sheet chrome already flips via `preferredColorScheme` — they
  read as glaring white cards with black text on a dark sheet. `LayoutTile` now
  takes the active `MoodPalette` (`appState.moodPalette`) and derives everything
  from it: surface `Color(white: 0.95 light / 0.24 dark)` (an elevated card in
  either scheme — light lands at the lighter grey requested, dark lifts above the
  dark sheet), label + icon from `MoodPalette.iconColor` (black-on-light /
  white-on-dark), and the hover veil flips (dark wash on light tiles, light on
  dark). All keyed to `.animation(.easeInOut(duration: 0.35), value: palette)` so
  the tiles crossfade in lockstep with the background mood fade, exactly like the
  toolbar icons (feat/next-24). Selection blue + ring unchanged (system accent).
  Pure SwiftUI cosmetic; one file (`Views/ImageLayoutSheet.swift`); no test (Color
  equality is unreliable). Build + full suite green (260); diff review clean.
- **2026-06-19** `feat/next-32` — Collections in the Sidebar (opt-in). A new
  Preferences toggle **"Show Collections in the Sidebar"** (`AppSettings.
  showCollectionsInSidebar`, default OFF — OFF is byte-for-byte the original
  folders-only sidebar) adds a second section beneath the folders. ON: a gray
  **FOLDERS** and **COLLECTIONS** header, each with the hero viewer's circular
  collapse button (`+` collapsed → 45°-rotated `×` expanded, same spring), and
  both sections live in ONE `ScrollView` so they scroll together (the bottom
  pill row is pinned outside it). Each collection row shows a `square.stack.3d.up`
  icon, name, and the reachability-aware alive count; clicking it activates the
  collection in the grid (`setActiveCollection`) and shows the blue selection
  highlight (folders already suppress theirs while a collection is active). The
  COLLECTIONS section has its OWN sort (`AppState.sidebarCollectionSortMode`:
  Manual / Name / Date Created / Date Modified) **fully independent of the
  Collections-page sort** — even Date Created in the sidebar never reorders the
  page. Manual order is persisted via a new `collections.sort_order` column
  (migration **v8**, deterministic created-at/name back-fill; new collections
  append at `max+1` in `createManual`/`upsert`); `CollectionStore.persistOrder`
  writes a full id order. Reorder is the SAME live drag as folders (trailing grip
  on hover swapping with the count, hidden row + floating overlay, insertion
  line — a flat-list mirror in `SidebarView`) plus right-click **Move Up/Down**
  and app-menu **Move Collection Up/Down** (Collections menu, gated to ON +
  Manual + an active collection). Row context menu: Rename… (activates +
  `collectionRenameRequest`), Delete… (durable `setHidden`, same confirm copy),
  Move Up/Down. Full a11y: one activatable element per row (name+count label,
  `.isButton`/`.isSelected`, named Rename/Delete/Move actions); grip stays
  mouse-only/`accessibilityHidden` like the folder grip. Bottom bar: OFF = the
  single "Add Folder" pill; ON = two compact `+ folder` / `+ stack` pills, the
  stack opening the existing Name Collection modal (`requestNewCollection`),
  appending at the bottom of Manual. New pure `Models/SidebarCollectionSortMode.swift`
  (`SidebarCollectionSort`, unit-tested) + `SidebarCollectionSortTests` /
  `CollectionSortOrderMigrationTests` / `CollectionReorderStoreTests`. The
  Collections PAGE is untouched. Build + full suite green (280 unit cases);
  spec + plan in `docs/superpowers/`. **QA follow-up (same branch):** (1)
  **Settings is now an in-app modal sheet** (dimmed + centered like the About/
  Image-Layout modals), not the native Preferences window — the `Settings {}`
  scene was removed and `CommandGroup(replacing: .appSettings)` opens a `.sheet`
  bound to `AppState.settingsShown` (⌘, preserved); `SettingsView` takes a
  `@Binding isPresented` + `SheetCloseButton`, sized to content at 600 wide.
  (2) **Collapse animates like the hero** — the section collapse flags are plain
  `@State` (seeded from / persisted to UserDefaults) NOT `@AppStorage`, so
  `withAnimation` on the +/× toggle animates the spin AND the content show/hide
  (a withAnimation transaction doesn't carry into an @AppStorage publish — it was
  instant before). (3) **Drag-drop no longer flashes** — `reorderSidebarCollections`
  applies the new order to the in-memory `CollectionsEngine.collections`
  `sort_order` SYNCHRONOUSLY (then persists async, no reload), so the commit's
  non-animated transaction sees the new order immediately (mirrors how the folder
  reorder relies on `bookmarks.$roots` delivering synchronously; the async-then-
  reload version snapped a frame late). (4) **Sort-change no longer flies in** —
  the collections list is a NON-lazy `VStack` iterated DIRECTLY by `collection.id`
  (was `LazyVStack` + `Array(enumerated())`, which made SwiftUI treat a reorder as
  insert/remove and fly rows from the edge), with a list-scoped
  `.animation(value: sidebarCollectionSortMode)` instead of a global withAnimation
  (which animated the whole surrounding VStack). (5) **Sidebar highlight follows
  the active collection** — `CollectionSidebarRow.isSelected` is just
  `activeCollectionID == id` (dropped a `!showingCollections` guard that left a
  collection opened from a Collections-page card un-highlighted). (6) Collection
  rows mirror the folder row layout exactly (leading chevron-width spacer, icon
  width 18, padding 6) so icons/text line up. Independent review clean.

## Architecture map (current — see `docs/session-log.md` for the deltas behind each piece)

```
Muse/Muse/
  MuseApp.swift                    entry point; ThumbnailCache LRU prune +
                                   180-day Housekeeping prune + IntentBackfill
                                   on launch; owns the Sparkle updater +
                                   "Check for Updates…" command (after .appInfo)
  Updates/
    Updater.swift                  Sparkle SPUStandardUpdaterController wrapper +
                                   CheckForUpdatesView (menu item, disables while
                                   a check is in flight). Direct-distribution
                                   self-update; see docs/RELEASING.md
  ContentView.swift                NavigationSplitView shell; floating tag
                                   chips; toolbar; menu-bar Tags/Collections
  Models/
    AppState.swift                 @MainActor singleton — roots, active folder,
                                   current files, selected file, sort mode +
                                   direction, search, mood, watcher, indexing.
                                   The stored @Published state + folder/roots/
                                   search/watcher/indexing logic; filter + grid-
                                   selection methods split into the extensions
                                   below (2026-06-17 tidy-up). reloadAfterMove;
                                   allTagLabels preload (feat/multi-select).
                                   Memoized visibleFiles; navTransition (0.2s
                                   shared nav-crossfade duration); owns the tag-
                                   chip data — tagChipRows + reloadTagChips()
                                   (computed inline by the folder load so files +
                                   chips publish together); tagRowReady gate
                                   (feat/next-10). Owns folderStats
                                   (FolderStatCache) — driven from rebuildRootNodes,
                                   changes forwarded like stars (2026-06-18). Owns
                                   folderSortMode (@Published, persisted via a
                                   Combine sink) so the sidebar + the Edit-menu
                                   Move Up/Down reorder share one reactive source
                                   (feat/next-17). Owns collectionSortMode +
                                   collectionSortReversed (@Published, persisted)
                                   — the Collections-page card sort, independent of
                                   the grid sortMode (feat/next-20). Owns
                                   tileBackground (@Published, persisted) + the
                                   computed effectiveTileBackground (masonry→Auto)
                                   and tileFill (the resolved grid backdrop Color)
                                   — feat/next-22
    AppState+Selection.swift       extension: grid MULTI-selection (selectedFiles:
                                   Set<String> of paths + anchor) — applyClick /
                                   clearSelection / selectAllVisible /
                                   effectiveSelectionURLs / selectionOrder
    AppState+Filters.swift         extension: collection + tag-chip filtering —
                                   visibleFiles / tagSourceFiles / setActive-
                                   Collection / setActiveTag / removeTag /
                                   removeFromCollection / setCollectionCover /
                                   toggleCollectionsPage / bulkTagCommandsAvailable
    AssetKind.swift                kind enum + extension/UTType detection;
                                   classify(url:) skips detect's fileExists stat
                                   (used by FolderReader for fast enumeration).
                                   When extension + OS content-type don't name a
                                   handled kind (empty/unknown ext → public.data),
                                   a last-resort ImageIO header sniff
                                   (CGImageSourceGetType) classifies images that
                                   lost their extension — a truncated 255-byte
                                   filename that dropped ".jpg", or a web save like
                                   ".jpg_large". SKIPS dataless iCloud placeholders
                                   (never force a download to classify) — feat/
                                   next-27
    FileNode.swift                 in-memory enumerated-file value type;
                                   init(url:kind:) takes a precomputed kind so
                                   enumeration skips the per-file fileExists stat
    Root.swift                     security-scoped bookmark wrapper
    DeleteCoordinator.swift        delete state machine (trash + undo toast);
                                   drives a fade-out (internals still named
                                   "burn"; the Metal burn shader is gone)
    Mood.swift                     Light / Dark / Auto (day↔night) / Custom HSB
                                   (AutoTint retired)
    FolderSortMode.swift           sidebar folder sort: FolderSortMode enum
                                   (manual/name/dateModified/size) + pure
                                   FolderSort.order comparator (name tiebreak,
                                   missing-stat last) — 2026-06-18
    TagSortMode.swift              tag-chip sort order: .count (Most Used, default)
                                   / .alphabetical (A→Z). Drives
                                   TagChipLoader.ordered(_:sortMode:) — 2026-06-18
    ImageLayout.swift              global grid image layout: .masonry (default,
                                   displayName "Masonry") + 11 fixed aspect-ratio
                                   cases. Each exposes displayName, aspect (h÷w,
                                   nil for masonry), iconKind (the 4 generic modal
                                   previews) + resolve(_:) default-masonry parse.
                                   Unit-tested (feat/next-21)
    TileBackground.swift           global grid tile BACKDROP (behind images +
                                   non-image cards): None (transparent) / Auto
                                   (follows mood tileFill — default) / Light /
                                   Dark Grey / Black fixed neutrals. backdropRGB(
                                   for:)->MoodRGB? is the single resolver (nil =
                                   transparent); fill(for:)->Color (.clear for
                                   None); resolve(_:) default .auto. Persisted via
                                   AppSettings.tileBackground, mirrored on
                                   AppState. Masonry forces Auto via
                                   AppState.effectiveTileBackground. Unit-tested
                                   (feat/next-22)
  Filesystem/
    FileMover.swift                move(_:into:) via FileManager.moveItem; skips
                                   name collisions, returns failures; roots already
                                   hold RW security scope (feat/multi-select)
    FolderOps.swift                pure create/rename folder on disk (sanitize +
                                   createSubfolder + rename → Result<URL,OpError>);
                                   no overwrite on collision; allows case-only
                                   rename; rejects leading-dot/hidden names
                                   (feat/folder-ops-and-share)
    FolderRenameMigration.swift    folder-rename DB rewrite: pure rewrite() rule +
                                   apply(db:old:new:newName:) running the actual
                                   SQL over paths.absolute_path / tags.parent_dir /
                                   starred_folders in one transaction (clears stale
                                   rows at the destination first to avoid a UNIQUE
                                   rollback). SQL unit-tested in-memory.
    BookmarkStore.swift            UserDefaults-backed root bookmarks; lifecycle
                                   start/stop access for sandbox. rootRenamed(_:to:)
                                   repoints a renamed root's bookmark + display name
    FolderTree.swift               lazy hierarchical tree + FolderReader; FolderNode
                                   has a weak parent + reloadChildren() (refresh after
                                   create/rename — feat/folder-ops-and-share)
    FolderWatcher.swift            FSEvents-backed live watcher; delivers the
                                   changed paths. FolderEventFilter (pure) keeps
                                   only viewable in-folder files (drops hidden/
                                   .muse/out-of-folder) — see 2026-06-17 session.
                                   watch(urls:) overload watches many roots at once
                                   (sidebar folder-stat cache — 2026-06-18)
    FolderStat.swift               pure FolderStat (immediate+recursive file counts,
                                   recursive size, recursive latest mtime) +
                                   FolderStats.compute/root(containing:); mirrors the
                                   grid's file notion so sidebar counts match
                                   (2026-06-18)
    PathReconciler.swift           pure scope/diff + DB ops that mark a folder's
                                   externally-deleted files is_alive=0 on a fresh
                                   folder load (stops ghost rows leaking into
                                   search as blank tiles + inflating collection
                                   counts); guards old-style evicted iCloud
                                   placeholders, markDead chunked at 500. The
                                   caller (AppState) skips reconcile on a
                                   false-empty enumeration (failed/unmaterialized
                                   read) so it can't mass-delete. No data
                                   migration — 2026-06-18
    FolderStatCache.swift          @MainActor cache of FolderStat per top-level
                                   folder; off-main compute, live via FSEvents over
                                   all roots (debounced), set-diff so a reorder
                                   doesn't re-walk, ignores dotfile/.muse changes
                                   (rootForMediaChange); AppState owns + forwards
                                   changes (2026-06-18)
    StarStore.swift                SQLite-backed starred folders
    ThumbnailCache.swift           QLThumbnail + AVAssetImageGenerator (videos);
                                   off-main, ordered (top→bottom) load; 2-tier
                                   cache (NSCache 512MB cost + on-disk LRU 2GB).
                                   Key normalized on standardized path; invalidate(_:)
                                   drops mem+disk for all renderedVariants so an
                                   in-place edit regenerates (2026-06-17). Non-image
                                   path requests QuickLook .all → real macOS type
                                   icon / content preview, not just .thumbnail
                                   (feat/next-11)
    Sidecar.swift                  portable per-asset metadata value type
                                   (Codable); maps to/from FileRow+TagRow;
                                   deterministic conflict merge (manual-tag wins)
    SidecarStore.swift             read/write .muse/<hash>.json with
                                   NSFileCoordinator (no live SQLite in iCloud)
    ICloudZone.swift               discover the single app iCloud Drive folder
                                   (ubiquity container Documents) + membership test
    SidecarHydrator.swift          import current sidecars into local DB on folder
                                   load so a fresh/iCloud-only device skips re-Vision
  Database/
    Database.swift                 GRDB queue + migrations (v1…v5_intent)
    Records.swift                  FileRow (+analyzed_hash, +intent), PathRow, TagRow, etc.
    SearchService.swift            FTS5 + tag-label search (sidebar-folder scope)
    TagScope.swift                 parent-folder key derivation — tags are
                                   per (file_id, parent_dir), not per content
                                   hash (2026-06-17). Single source of truth used
                                   by the migration, TagStore, AnalyzePipeline
    TagStore.swift                 manual/vision tag CRUD scoped by (file_id,
                                   parent_dir); library-wide rename (spelling)
                                   kept, library-wide DELETE removed (2026-06-17)
    TagChipLoader.swift            single shared query logic for the grid's tag-
                                   chip labels (fast single-folder GROUP BY +
                                   general per-file-scope path). Pure/nonisolated;
                                   AppState owns + calls it, the view only renders
                                   the result (feat/next-10)
    Housekeeping.swift             launch prune: index data for files unreachable
                                   from any sidebar folder, unseen >180 days
  Indexing/
    HashService.swift              streaming SHA-256; nil on dataless iCloud reads
    Indexer.swift                  identity reconciliation matrix (§4); size+mtime
                                   fast path; skips not-downloaded iCloud items.
                                   reconcile/indexFile return "content changed",
                                   indexBatch returns changed URLs + force/silent
                                   (re-hash for edits + iCloud verify) (2026-06-17)
  Intelligence/
    Vision/
      VisionServices.swift         classify/OCR/faces/feature print/dom color
                                   + CaptionBuilder (Vision-derived, NOT LLM)
    Sort/
      SmartSorter.swift            7 sort modes; Color + Shape pull FileRow data
    Dedup/
      DuplicateFinder.swift        byte-exact + visual + filename clusterers
                                   with smart-suggest only where signal is strong
      DuplicateDeleteRules.swift   pure delete-selection rules for the Duplicates
                                   modal: seed (pre-mark non-keepers), rescued
                                   (un-mark a survivor for any group left fully
                                   selected — overlapping groups can disagree),
                                   isLocked + selecting (a group is never fully
                                   deleted; one file can be in several groups, so
                                   the rule checks ALL of them; single 2-copy group
                                   swaps). Unit-tested; mirrors GridSelection
                                   (feat/next-23)
    Core/
      PaletteExtractor.swift       k-means palette (RGBA-redraw; BGRA bug fixed)
      CollectionNaming.swift       Foundation Models namer (gated) → tag fallback
      IntentBucket.swift           10 screenshot-intent buckets: keys, display
                                   names, stable collection ids, raw→bucket, color
      IntentClassifier.swift       pure IntentInput helpers + FM-gated classifier
                                   (screenshot OCR+labels → bucket | none)
    Collections/
      CollectionsEngine.swift      two-track recluster: intent collections (typed
                                   screenshots) + emergent (everything else)
      IntentCollections.swift      pure: which intent buckets qualify (≥3 members)
      CollectionSort.swift         pure Collections-page ordering (Name / Date
                                   Created / Date Modified + reverse); mirrors
                                   FolderSort, unit-tested (feat/next-20)
    AnalyzePipeline.swift          AUTOMATIC after indexing — analyzes only stale
                                   analyzed_hash files; writes FileRow, tags, FTS5;
                                   classifies screenshot intent (gated)
    IntentBackfill.swift           one-time launch pass: classify pre-existing
                                   screenshots from stored OCR (no re-Vision)
  Agents/
    AppIntents/
      MuseAppIntents.swift         OpenFolder/FindDuplicates/AnalyzeFolder/
                                   SearchLibrary intents + AppShortcutsProvider
  Viewers/
    PDFViewerView.swift            PDFKit, view-only
    TextViewerView.swift           NSTextView wrapper, isCode/isRTF flags
    MarkdownViewerView.swift       AttributedString markdown
    SVGViewerView.swift            WKWebView, file:// only (no network)
    VideoPlayerView.swift          AVKit AVPlayerView
    AudioPlayerView.swift          AVKit + asset metadata
    ModelViewerView.swift          SCNScene from URL
    FontViewerView.swift           process-scope font registration
    ViewerChrome.swift             dimmed bg + close button + Esc dismiss
  Views/
    SidebarView.swift              multi-root OutlineGroup tree + starred section;
                                   file-URL drop on folder rows MOVES the grid
                                   selection there (FileMover) with a drop-target
                                   highlight; Reveal in Finder menu item
                                   (feat/multi-select). No folder shows as selected
                                   in cross-folder views — Collections page, a
                                   single collection, or an "All"-scope search
                                   (2026-06-17); the drop highlight is independent.
                                   Top-level reorder is a LIVE DragGesture off a
                                   trailing grip (NOT .onDrag, which ate clicks):
                                   the dragged row is hidden in place + drawn as an
                                   opaque on-top overlay following the cursor, the
                                   others part to open a gap, commit is non-animated
                                   (2026-06-18 — see that session log). A "Sort:
                                   <mode> ▾" header (Manual/Name/Date Modified/Size)
                                   orders the top-level folders; Manual is draggable,
                                   sorted modes are read-only; each top-level row
                                   shows a live file count (AppState.folderStats)
                                   that swaps for the grip on hover in Manual
                                   (2026-06-18). Right-click Move Up/Down (+ Edit-
                                   menu Move Folder Up/Down) is the keyboard/
                                   VoiceOver parallel to the mouse-only drag, gated
                                   to Manual sort, indexing the displayed resolved-
                                   bookmark order (feat/next-17)
    GridView.swift                 VIRTUALIZED masonry grid — precomputes tile
                                   frames (MasonryGeometry from AspectRatioCache)
                                   and renders only viewport tiles (+overscan);
                                   column-count slider; tiles fade in as thumbs
                                   land. The ONLY grid view (cloud/galaxy retired
                                   2026-06-13; water effect removed 2026-06-13).
                                   Click = select (instant; Cmd toggles, Shift
                                   ranges), double-click opens (gap timed from the
                                   EVENT's hardware timestamp, not Date() at
                                   handler-run, so a main-thread stall on slow Macs
                                   can't drop it — 2026-06-17); accent wash+border
                                   inside the tile (scales w/ hover); .onDrag carries
                                   the file URL; selection-aware contextMenu
                                   (feat/multi-select). A content-level Color.clear
                                   deselect surface behind the tiles makes the empty
                                   top inset deselect with OR without the tag chips
                                   (2026-06-17). Non-image tiles render the native
                                   macOS icon/preview (cardIcon, SF Symbol only as a
                                   loading fallback); optional "Show file names" caption
                                   below each tile (MasonryGeometry.captionHeight strip;
                                   internal card name when off) — all tiles square-
                                   cornered (feat/next-11). recompute() branches on
                                   AppState.imageLayout: a fixed ratio feeds
                                   MasonryGeometry a UNIFORM aspect array (which
                                   packs an exact row-major grid — no new geometry),
                                   the .fit image letterboxing on tileFill grey
                                   without cropping; masonry uses per-image aspects
                                   as before. The aspects.version onChange is guarded
                                   off in fixed layouts (per-image ratios can't
                                   change a uniform grid) — feat/next-21
    ImageLayoutSheet.swift         the grid-button modal (InfoSheet chrome) that
                                   sets AppState.imageLayout — a 4-col grid of the 12
                                   ImageLayout tiles (LayoutTile mirrors a grid
                                   tile's selection: square fill shrinks/insets to
                                   blue inside a rounded 8pt ring; FlatButtonStyle
                                   kills the pressed darken) over a "Common Sizes"
                                   reference list. LayoutIconView draws the 4 generic
                                   44×44 previews (mason/square/portrait/landscape).
                                   Live-applies behind the open sheet (feat/next-21).
                                   LayoutTile now takes the active MoodPalette and
                                   derives its surface (Color(white:) 0.95 light /
                                   0.24 dark), label/icon (MoodPalette.iconColor),
                                   and hover veil from it, animated in lockstep
                                   with the mood fade — so the modal flips with
                                   Light/Dark/Auto/Custom instead of a fixed white
                                   card on a dark sheet (feat/next-31; reverses the
                                   mood-independent tiles from feat/next-22)
    SheetCloseButton.swift         shared circular hover-✕ for modal sheets (Esc via
                                   cancelAction); used by InfoSheet + ImageLayoutSheet
                                   (extracted from InfoSheet — feat/next-21)
    SelectionMenu.swift            SelectionActionsMenu — Add to Collection /
                                   New Collection from Selection (opens a "Name
                                   Collection" .alert; prompt-first — paths are
                                   captured on right-click and the collection is
                                   created only on confirm via
                                   AppState.confirmNewCollection, Cancel/blank
                                   creates nothing — feat/next-19) / Add Tag /
                                   Share / Move to Folder over the effective
                                   selection (feat/multi-select)
    OutsideClickDeselect.swift     0×0 NSView + window leftMouseDown monitor that
                                   clears the selection on any click outside the
                                   grid's enclosingScrollView (feat/multi-select)
    PageScrollCatcher.swift        first-responder NSView giving the grid +
                                   Collections page native Page Up/Down (Fn+Arrow
                                   or real Page keys) via enclosingScrollView +
                                   PageScroll math (feat/page-scroll)
    ShareCollectionButton.swift    in-collection header menu — Save to… (NSSavePanel,
                                   Desktop) / Share (NSSharingServicePicker); builds
                                   an 11×14 paginated PDF (feat/collection-pdf-share).
                                   exportURLs = all non-folder members (file cards
                                   included, not just images); passes the active
                                   imageLayout.aspect + effectiveTileBackground
                                   backdrop (sRGB cgColor) into the exporter so the
                                   PDF mirrors the grid (feat/next-22)
    AspectRatioCache.swift         per-file aspect (h÷w) for layout: bulk DB
                                   width/height + ImageIO header fallback, off-main
    CollectionsPage.swift          dedicated Collections page (toolbar
                                   square.stack.3d.up): "Collections" header (back
                                   arrow + a far-right "+" New Collection button,
                                   trash-button sized) over a 4-up card grid that
                                   resizes to fit, scrolls vertically; ordered by
                                   the toolbar sort (Name / Date Created / Date
                                   Modified + direction) via CollectionSort,
                                   defaulting to Name A→Z (feat/next-20).
                                   The "+" opens the shared "Name Collection" modal
                                   (appState.requestNewCollection(), empty selection
                                   → empty named collection) — same flow as the grid's
                                   "New Collection from Selection" (feat/next-19)
    CollectionsRow.swift           in-collection header (back/rename/count) +
                                   the CollectionCard (right-click → Delete). Delete
                                   is DURABLE via setHidden — no user-facing Hide
                                   (2026-06-17); the all-collections cards moved to
                                   CollectionsPage 2026-06-13
    TagChipsRow.swift              tag chips; filter + management. A pure RENDERER
                                   of AppState.tagChipRows now (the model loads
                                   them via TagChipLoader — feat/next-10); keeps
                                   hover-count layout (ChipFlow) + rename/delete
                                   dialogs. Scope (collection members vs folder) is
                                   decided by AppState.tagSourceFiles
    MoodPickerView.swift           background popover (Light/Dark/Auto/Custom) +
                                   a "Tile Background" section (None/Auto/Light/
                                   Dark Grey/Black → AppState.tileBackground;
                                   disabled→Auto in masonry with a note) — feat/
                                   next-22
    InfoSheet.swift                ⓘ About-Muse modal (behavior + privacy); uses
                                   the shared SheetCloseButton (feat/next-21)
    KeyCaptureView.swift           NSView arrow/return capture (hero flips)
    BreadcrumbView.swift           path breadcrumb (kept; not in toolbar)
    OpenWithMenu.swift             NSWorkspace registered apps via LaunchServices
    ImageDetailPanel.swift         fit/100% preview overlay
    QuickLookFallback.swift        QLPreviewView wrapper
    ViewerRouter.swift             AssetKind → viewer dispatch
    DuplicatesView.swift           review pane with delete-to-Trash. Each duplicate
                                   is a grid-style tile (DuplicateImageTile: image
                                   fits/no-crop on a transparent square → reveals
                                   the card grey; marking-for-delete insets it +
                                   blue ring, no tint; fixed colors, not the mood
                                   accent) + a reveal-in-Finder button. Opens with
                                   non-keeper copies pre-marked (overridable); the
                                   KEEP badge tracks survivors (multiple keeps ok).
                                   All delete-selection rules + the "never fully
                                   delete a group" guarantee live in the pure
                                   DuplicateDeleteRules; the view is a thin renderer
                                   (observes DuplicateFinder via @ObservedObject)
                                   (feat/next-23)
    Viewer/                        hero image viewer (HeroImageViewer, HeroStage,
                                   ViewerInfoColumn, backdrop, geometry, toast,
                                   PillFlow/PillRowModel)
      ShareButton.swift            macOS share sheet (NSSharingServicePicker)
                                   for the hero image
    Spatial/
      SeededRandom.swift           SplitMix64 + FNV-1a (kept: grid burn seed +
                                   hero). Cloud/Galaxy views + their layout files
                                   (Cloud*/Galaxy*/SimilarityLayout/SceneProjection)
                                   were removed 2026-06-13 — see session log.
  Components/
    SearchBar.swift                debounced FTS5 search. Native NSSearchField
                                   (system focus ring, clear button, accessibility;
                                   appearance follows mood) wrapped in
                                   NSViewRepresentable (feat/multi-select). Magnifier
                                   dropdown picks scope — All vs This Folder (default
                                   This Folder); drives AppState.searchAllFolders +
                                   runSearch (2026-06-17). InsetSearchFieldCell nudges
                                   the text ~4px right
    GridSelection.swift            pure selection math (single / Cmd-toggle /
                                   Shift-range → new set + anchor), unit-tested
                                   (feat/multi-select)
    PageScroll.swift               pure Page Up/Down math (newOriginY: overlap +
                                   clamp), unit-tested (feat/page-scroll)
    EscapeAction.swift             pure Escape priority resolver: peel one focused
                                   layer per press — viewer → search → collection →
                                   Collections page → grid (EscapeResolver.action +
                                   searchPresent glue). ContentView's hidden Escape
                                   button maps the result onto existing AppState
                                   calls; viewer always wins so the hero close is
                                   never disturbed. Unit-tested (feat/next-30)
    MasonryGeometry.swift          pure masonry packing (frames + height) from
                                   aspect ratios — feeds GridView's virtualization
                                   (replaced the old MasonryLayout: Layout, deleted
                                   2026-06-13 — a custom Layout can't virtualize).
                                   captionHeight param reserves a fixed per-tile
                                   caption strip for under-tile file names
                                   (feat/next-11)
  Export/
    CollectionPDFLayout.swift      pure paginated masonry pack for the collection
                                   PDF (no image split across pages), unit-tested;
                                   each tile reserves a captionHeight strip below
                                   the image for its filename (2026-06-17)
    CollectionPDFExporter.swift    ImageIO downsample (off-main) → CGPDFContext;
                                   CoreText 11×14 header (feat/collection-pdf-share)
                                   + a centered, ellipsis-truncated filename caption
                                   under each image (CTLineCreateTruncatedLine,
                                   2026-06-17). makePDF(layoutAspect:tileBackdrop:)
                                   mirrors the grid: fixed ratio → uniform aspect
                                   array; per-image backdrop fill (paper page stays
                                   white); non-image files fall back to QuickLook
                                   (QLThumbnailGenerator .all) so file cards render;
                                   decode runs 8-wide via withTaskGroup, order
                                   preserved (feat/next-22)
  Effects/                         (was Fluid/, renamed 2026-06-17; water ripple
                                   removed 2026-06-13 and the burn-up delete
                                   SHADER removed too — NO Metal shaders remain)
    FadeOutModifier.swift          animatable staggered opacity fade for the
                                   delete sequence (replaced the BurnUp shader)
  Settings/
    AppSettings.swift              UserDefaults accessors for the automatic-
                                   organization opt-outs (autoTag /
                                   autoCollections, both default ON); read by
                                   AnalyzePipeline + CollectionsEngine. Plus
                                   showFileNames (default OFF; read by GridView —
                                   feat/next-11). Plus folderSortMode (default
                                   manual; sidebar folder sort — 2026-06-18). Plus
                                   collectionSortMode (default name) +
                                   collectionSortReversed (default false;
                                   Collections-page card sort — feat/next-20). Plus
                                   imageLayout (default masonry; global grid layout,
                                   mirrored on AppState — feat/next-21). Plus
                                   tileBackground (default auto; global grid tile
                                   backdrop, mirrored on AppState — feat/next-22)
    SettingsView.swift             Settings as an IN-APP MODAL SHEET (not the
                                   native Preferences window) — dimmed + centered
                                   like InfoSheet; opened by AppState.settingsShown
                                   from CommandGroup(replacing: .appSettings) (⌘,),
                                   takes a @Binding isPresented + SheetCloseButton,
                                   sized to content at 600 wide (feat/next-32).
                                   Sections: the two auto-organization toggles
                                   (auto-tag new images / auto-organize into
                                   collections), a "Grid" section with the
                                   "Show file names" toggle (feat/next-11), and a
                                   "Sidebar" section with "Show Collections in the
                                   Sidebar" (feat/next-32). Other settings still
                                   live in the sidebar / toolbar / menus
  Muse.entitlements                app-sandbox + user-selected.read-write +
                                   bookmarks.app-scope + iCloud Documents +
                                   network.client (Sparkle update fetch ONLY —
                                   added 2026-06-15; no other network use) +
                                   mach-lookup temporary-exception for
                                   <bundleid>-spks/-spki (so the sandbox can run
                                   Sparkle's installer XPC — see SUEnableInstaller-
                                   LauncherService in Info.plist). DEBUG builds
                                   sign with Muse-Debug.entitlements (same keys
                                   MINUS iCloud) so dev-build churn can't claim/
                                   purge the production iCloud container — see the
                                   2026-06-16 iCloud isolation session log
  Muse-Debug.entitlements          Debug-only: Muse.entitlements without the three
                                   iCloud keys (Release/App Store keep iCloud)
MuseShareExtension/                (separate app-extension target) "Send to Muse"
                                   — Finder Share-menu extension; copies dropped
                                   files into the single iCloud folder, picked up
                                   by the existing FolderWatcher
```

## Conventions

- **GRDB writes are async** — use `try await queue.write { ... }` and
  `try await queue.read { ... }`. The synchronous overload exists but
  conflicts with the async one inside async contexts; pick one and the
  build will tell you fast.
- **GRDB rows are inserted as `var`** — `MutablePersistableRecord.insert`
  mutates `id` in place. `let` rows fail to compile.
- **Manual tags beat vision tags** on label conflict (Q32). Enforced
  via `UNIQUE(file_id, parent_dir, label)` + branching in
  `Indexer.unionTags` and `AnalyzePipeline.analyzeOne`. This is what makes
  automatic re-analysis safe — it can never undo a user's tag edit.
- **Tags are per-file-LOCATION, not per content hash** (2026-06-17). A tag
  belongs to `(file_id, parent_dir)` — the same content in another folder
  is a different image with its own tags; deletes never leak across
  folders. Derive the folder key via `TagScope`. There is NO library-wide
  tag delete. Content-derived metadata (palette/caption/dims/intent) stays
  content-keyed by design (identical for identical pixels; auto-splits on
  edit). See the 2026-06-17 per-file-tags session log.
- **Analysis is automatic + incremental** — it runs after indexing for
  files whose `analyzed_hash` ≠ `content_hash` (new/changed only); never
  re-processes unchanged files. **Auto-tagging and auto-collections are
  opt-out** in Preferences (⌘, → `AppSettings`, both default ON): off → newly
  added folders stay viewable but aren't auto-processed, while existing data is
  untouched and the manual paths still work (menu-bar Regenerate Tags;
  hand-made collections via the Collections-page **+**). There's no prominent
  "Analyze" toolbar button — the automatic pass is the front door.
- **Files are never deleted, only moved to Trash** via
  `NSWorkspace.shared.recycle`. Don't `unlink` user files. Ever.
- **No editing UI** — every "edit this" path goes through Open With…
  (`NSWorkspace.shared.open(url, withApplicationAt: ...)`).
- **No network calls** — if you find yourself reaching for `URLSession`,
  stop. The sandbox doesn't allow it. Markdown/SVG viewers have hard
  guards against remote loads. New third-party deps must be audited
  for network surface.
- **AppState is @MainActor**. So is most of the data layer. Background
  work (hashing, Vision) goes through `Task.detached(priority:)` or
  the `Indexer` actor's queues.
- **SourceKit module errors are noise.** During edits you'll see
  "Cannot find type 'FileNode' in scope" and similar — they're cross-
  file resolution issues that disappear at build time. Always verify
  with `xcodebuild ... build` before assuming something's broken.

## Open product questions (none currently)

All Q1–Q33 from the plan are locked in, with two superseded by the
2026-06-12 session:

- **Q10 (analysis manual-only)** — superseded. Analysis now runs
  automatically after indexing, incrementally (stale `analyzed_hash`).
- **Q9 / Phase 7 (chat panel)** — retired. The differentiating version
  is tool-calling; the v1 context-prompted panel was removed. History
  holds it for when that phase happens.

Future product decisions should be recorded in
`docs/superpowers/plans/file-viewer-rewrite.md` (or a sibling plan doc)
before implementation.

## How to run

1. Open `Muse/Muse.xcodeproj` in Xcode 16+.
2. Build & run (Cmd+R). The app starts on a clean shell — click
   "Add Folder" in the sidebar to point Muse at any folder on disk.
3. Toolbar (left → right): sidebar toggle · sort · sort-direction arrow
   (flips the active mode's order — newest↔oldest, A↔Z, …) · show-subfolders ·
   search (center) · Collections (square.stack.3d.up) · Image Layout
   (square.grid.2x2) · background mood (paintpalette — popover also holds the
   Tile Background picker) ·
   ⓘ About. (The grid/cloud/galaxy view picker and the water effect were
   removed 2026-06-13; the clear-collection ✕ was removed in favor of back
   arrows.) Find Duplicates lives in the File menu; Pin/Unpin Folder and
   Remove Folder live in the Edit menu; analysis runs automatically.
4. Sandboxed container path:
   `~/Library/Containers/com.tarrats.Muse/Data/Library/Application Support/Muse/`.
   `muse.sqlite` there; wipe it to rebuild the schema on next launch.
5. ThumbnailCache lives beside it; capped at 2GB, LRU-evicted on launch.

## Status as of merge to main

- Branch state: `main` is now at the merged tip; `dev` is preserved at
  the pre-rewrite water-toggle commit (older); `feat/file-viewer-rewrite`
  is the source-of-truth branch for the rewrite progression.
- Test coverage: a real unit-test suite exists (`MuseTests`, ~36 files) —
  pure logic, schema migrations, and store/model behaviors (e.g. tag scoping +
  the `v7` migration, collection identity/membership, manual-collection naming,
  sort/selection/page-scroll math, palette/color/intent). UI views aren't
  unit-tested. Run with `xcodebuild -scheme Muse test`; keep it green.
- Current by-design behaviors (NOT bugs, NOT pending work — documented so a
  future session doesn't mistake them for defects):
  - iCloud Drive: dataless (not-yet-downloaded) files are skipped on
    index/hash until macOS downloads them (avoids empty-hash corruption).
  - iCloud sidecar hydration — two inherent behaviors: (1) **OCR full-text
    search is degraded on hydrate-only devices.** Sidecars don't carry OCR text
    (large; intentionally excluded), so a device that only hydrated a file
    (never ran Vision locally) matches FTS on basename + caption only, not OCR'd
    text. The file is marked analyzed, so it won't re-Vision to recover OCR.
    Intent IS carried, so intent collections are unaffected. (2) **Byte-identical
    content split across subfolders.** Sidecars live in a per-folder `.muse/`
    keyed by content hash; identical files in different subfolders of the iCloud
    zone only get a sidecar beside the copy that was analyzed, so the other copy
    won't hydrate on a fresh device until its own analyze pass runs.

## Working with this codebase

- Use the rewrite plan as the source of truth for "why does it work
  this way" questions.
- When in doubt about a product decision, the plan's locked Q-number
  table answers most of them.
- Keep commits scoped to a single phase or feature; the rewrite log
  is a useful reference and merging clean diffs preserves it.
