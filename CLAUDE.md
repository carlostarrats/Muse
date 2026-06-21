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
  a trailing grip + an opaque on-top overlay (a single floating copy, reliable
  without per-row `.zIndex` juggling; both the folder and collection lists use it).
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
- **`AnalyzePipeline` passes serialize through `acquirePass()`, NOT a bare
  `while isRunning` busy-wait.** A `while isRunning { await Task.sleep }` gate has a
  wake-race: when the running pass clears `isRunning`, every sleeping waiter wakes,
  ALL see `isRunning == false`, and ALL proceed — two passes run at once, clobbering
  the progress counters and letting `cancelActivePass()` (fired on folder removal)
  halt the wrong pass. The fix is a synchronous `passClaimed` flag claimed inside
  `acquirePass()`: the waiter loops on `isRunning || passClaimed` and sets
  `passClaimed = true` with NO `await` between the check and the set, so on the main
  actor only the first woken waiter takes it. The claiming wrapper
  (`analyzePending`/`regenerateTagless`) holds the claim via `defer { passClaimed =
  false }` for its WHOLE body — bridging the window between the inner `analyze(folder:)`
  clearing `isRunning` and the wrapper returning. `analyze(folder:)`/`analyze(file:)`
  must NOT consult `passClaimed` (else a claiming wrapper calling into them
  deadlocks), and the cancel path must return BEFORE the claim. Don't revert to a
  plain `isRunning`-only gate. Fixed 2026-06-19 (`feat/next-35`).
- **Folder/scope path-prefix checks need a trailing `+ "/"`.** A bare
  `path.hasPrefix(folderPath)` matches a sibling (`/a/Inspo` matches
  `/a/Inspo Extra/x.jpg`). Every prefix test in the codebase guards with
  `$0 == prefix || $0.hasPrefix(prefix + "/")` (`Housekeeping`,
  `CollectionStore.isUnderAnyRoot`, `ICloudZone`, `PathReconciler`,
  `FolderRenameMigration`, and — since `feat/next-35` — `SearchService`'s "This
  Folder" scope, which was the one outlier). Use the same rule for any new
  containment check.
- **`BookmarkStore.addRoot` must `activate(root)` BEFORE `roots.append(root)`.**
  Appending publishes `$roots`, whose AppState sink rebuilds the sidebar
  SYNCHRONOUSLY (the documented no-`.receive(on:)` rule). `rebuildRootNodes`
  drops any root whose `bookmarks.url(for:)` is nil, and `url(for:)` reads
  `accessedURLs`, populated only by `activate`. So if `activate` runs AFTER the
  append, the synchronous rebuild can't resolve the just-added root's URL and
  silently drops its node — each later add catches the PREVIOUS folder, so only
  the LAST-added root vanishes (an iCloud folder, in the repro). `pickAndAddRoot`
  masked this with an explicit post-add rebuild; the reconnect wizard (sink-only)
  didn't. Activating first makes the synchronous rebuild resolve every new root.
  Don't reorder back. Fixed 2026-06-20 (`feat/next-37`).
- **A trailing debounce with NO maxWait cap starves forever under a sustained
  event stream.** `FolderStatCache` (sidebar file counts) rescheduled its 0.4s
  recompute debounce on EVERY qualifying FSEvents under a root. A continuous
  stream arriving faster than 0.4s apart reset the timer indefinitely, so the
  recompute never ran and the **sidebar count froze** until the stream stopped
  or the app restarted — which is exactly what an iCloud-synced folder produces
  while syncing newly-imported files (a 48 MP RAW + a 30 s video) during a long
  analysis pass (minutes of upload/metadata FSEvents). The fix is a **maxWait cap
  (2.0 s)** via the pure `StatRecomputeScheduler`: once the current burst has run
  past the cap, flush (recompute) immediately instead of rescheduling, so the
  count refreshes at least every ~2 s even under continuous churn (normal
  single-add behavior keeps the trailing 0.4 s debounce). Any debounce over a
  potentially-unbounded event source needs this cap. Reproduced with a 6 s
  touch-storm (recompute fired 0× during, once after); verified the fix flushes
  every ~2.4 s during an 8 s storm. Fixed 2026-06-20 (`feat/next-39`).
- **Folder grid cards are SELECTABLE like files — every file-only destructive/
  move flow must filter out `.folder` nodes.** In the one-level (subfolders-OFF)
  browse view, `currentFiles`/`visibleFiles` now contain `.folder` `FileNode`s
  (feat/next-41 shows subfolders as grid cards). A folder tile single-click
  selects exactly like a file (`applyClick`), so a folder co-selected with files
  silently rides along in any flow built on `effectiveSelectionURLs` /
  `visibleFiles`. Two such flows leaked and were fixed in QA: the grid tile's
  **Move to Trash** (would `recycle` a whole subfolder tree) and the **sidebar
  drop-to-move** — both now skip folders (`node.kind != .folder` /
  `isDirectory != true`). The `SelectionActionsMenu` file-only actions
  (collection/tag/share/new-collection/move-to-folder) already filter via
  `fileURLs`. Folder operations live ONLY on the folder card's own context menu
  (New Subfolder / Rename / Reveal in Finder, mirroring the sidebar subfolder
  menu). Rule: any NEW selection-based action that can touch files must decide
  explicitly whether it applies to folders; the default for file-only/destructive
  ones is to exclude `.folder`. Fixed 2026-06-20 (`feat/next-41`).
- **Any input that NARROWS `visibleFiles` must clear or prune the selection.**
  The grid multi-selection is a `Set<String>` of paths, INDEPENDENT of
  `visibleFiles`, and `effectiveSelectionURLs` deliberately rebuilds a URL from
  the raw path for a selected file not currently in view (so it's "never silently
  dropped") — which means a hidden-but-still-selected file rides along into Move
  to Folder / Add to Collection / Add Tag / Share / sidebar drop. The active-tag
  and collection-removal paths already call `clearSelection()`; the **grid facet
  filter** (`gridFilter`, feat/next-42) was the one narrowing input that didn't,
  so its `didSet` calls `AppState.pruneSelectionToVisible()` — deselect anything
  the new filter hides ("what you can't see can't be acted on"), with a
  grid-ordered deterministic replacement Shift anchor (a selected folder IS pruned
  if the "Folders" kind facet hid it). Rule: a new filter/scope that can hide
  selected tiles must prune (or clear) the selection in lockstep, not rely on the
  consumer to re-check visibility. Fixed 2026-06-20 (`feat/next-42`).
- **An explicit `.foregroundStyle` overrides SwiftUI's automatic disabled
  dimming.** `View.moodToolbarIcon` colors every toolbar glyph EXPLICITLY from the
  mood (`MoodPalette.iconColor`), which means a `.disabled` toolbar control's icon
  stays full mood color — it looks active even though it's unclickable (reported
  for the grid filter on the Collections card page). The fix: `moodToolbarIcon` is
  a `MoodToolbarIcon: ViewModifier` reading `@Environment(\.isEnabled)` and applying
  `.opacity(isEnabled ? 1 : 0.4)` (0.4 = the house disabled value, cf.
  `MoodPickerView`). `.disabled` propagates into the environment of a control's
  descendants, so each icon dims off its OWN control's `.disabled` (sort cluster /
  subfolders / Collections / Image Layout during search; the filter on the card
  page). Don't pair a fresh explicit `foregroundStyle` with `.disabled` and expect
  auto-dimming — route it through `moodToolbarIcon` (or dim manually). Fixed
  2026-06-20 (`feat/next-42`).
- **A `LazyVStack` row list inside a shared `ScrollView` can de-materialize and not
  come back — use a plain `VStack` for short sidebar lists.** The sidebar's FOLDERS
  section (`SidebarView.folderList`) rendered its top-level rows in a `LazyVStack`;
  inside the two-section `ScrollView` (FOLDERS + COLLECTIONS scroll together when
  "Show Collections in the Sidebar" is ON) a scroll cycle could drop the off-screen
  folder rows and fail to re-create them, leaving an **empty FOLDERS section while
  COLLECTIONS stayed intact** (COLLECTIONS was already a plain `VStack`). It is NOT
  data loss — `rootNodes` still held data (the section headers rendered, so `body`
  didn't fall to its `rootNodes.isEmpty && stars.isEmpty` empty state), and nothing
  rebuilds `rootNodes` on scroll. The fix: `folderList` is a plain `VStack` iterated
  directly by node id (`ForEach(displayedReorderableNodes, id: \.id)`), exactly like
  `collectionsList` (which was converted off `LazyVStack` for the sibling reorder
  bug in `feat/next-32`). Top-level roots are few and their children render only when
  expanded (`FolderTreeNode`), so there's no virtualization cost, and
  always-realized rows report their `RootFramePreference` frames even off-screen
  (better drag-reorder math). Rule: don't use `LazyVStack` for a short list sharing a
  `ScrollView` with sibling content — the laziness buys nothing and risks the
  vanishing-rows glitch. Fixed 2026-06-20 (`fix/sidebar-folders-vanish`).
- **The tag chip filter is an ORDERED SET, not a scalar — `activeTagPaths` is the
  INTERSECTION (AND).** `AppState.activeTagLabel: String?` is gone; the filter is
  `activeTagLabels: [String]` (insertion order drives the banner wording). Mutate it
  ONLY via `setActiveTags(_:)` (the core — clears the grid selection, then recomputes
  `activeTagPaths` as the set-intersection of each label's path set) / `setActiveTag(_:)`
  (single/clear, delegates) / `toggleActiveTag(_:)` (Cmd-click). Do NOT compute
  `activeTagPaths` as a SwiftUI computed property — it's set imperatively inside the
  `tagRequestToken`-guarded `Task`. **`setActiveTags` MUST commit `activeTagLabels`
  SYNCHRONOUSLY (before the async path query); only `activeTagPaths` lands in the Task.**
  An earlier version wrote BOTH inside the async block, so `toggleActiveTag` (and the
  plain-click replace-vs-clear check) read a STALE `activeTagLabels` — two fast
  Cmd-clicks both saw the pre-Task set and the first selection was silently dropped, and
  a double plain-click failed to clear. The labels are the source of truth for the next
  toggle decision + the chip highlight + the banner, so they can't lag a click; the paths
  (DB-derived) may trail by a frame (the grid crossfades when they land — imperceptible
  for tiny selections). `removeTag` of a MULTI-tag-set member is always a full-view delete
  (the partial "Remove Tag from Selection" is gated to `singleActiveTag`), so it drops the
  label from the set via `setActiveTags(filter)` rather than leaving a phantom banner entry
  with no chip to clear; the single-tag path keeps its anyLeft/subtract/fall-back-to-All.
  `commitRename` of a selected label routes through `TagSelection.renaming` (dedups, since
  `TagStore.renameLabel` merges on collision — else `["b","b"]` → "Viewing b and b"). Each per-label query MUST stay
  `parent_dir`-scoped (`pathsForTag` reuses the per-location SQL — tags are per
  `(file_id, parent_dir)`, so a duplicate sharing the file_id in an untagged folder must
  not be pulled in). `singleActiveTag` (count==1 ? first : nil) gates the single-tag menu
  commands (Rename/Delete/Remove) — they're ambiguous for a 2+ selection; deletion stays
  single (right-click, per-chip `tag.label`). An empty intersection is a LEGITIMATE empty
  grid (the banner explains the set) — only the single-tag case falls back to "All" to
  avoid stranding. `removeTag` keeps the intersection correct with
  `activeTagPaths?.subtract(removed)` (a file still in the intersection carries ALL labels,
  so any that lost the removed label is in `removed`). The chip row + tag filter now also
  mount/apply during SEARCH (`tagSourceFiles`/`reloadTagChips` are search-aware — chips
  derive from the result set and the per-folder GROUP BY fast path is skipped since
  results span folders). `EscapeResolver` has a `.clearTags` layer ordered AFTER search,
  BEFORE the collection back-out (one press clears the whole set). Built 2026-06-20
  (`feat/next-45`).

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
- **2026-06-19** `feat/next-33` — Collections-page card restyle (visual only,
  `Views/CollectionsRow.swift`'s `CollectionCard`): removed the resting drop
  shadow + fixed grey hairline border; corner radius 10→8 on all four
  RoundedRectangles (cover clip + 3 overlays) to match the grid's selection ring
  (`GridView.ringCornerRadius = 8`); re-added the outline as mood-adaptive ("Auto")
  — `appState.moodPalette.iconColor.opacity(0.05)` (a local per-overlay opacity;
  `iconColor` untouched, so nothing else changes) with
  `.animation(.easeInOut(duration: 0.35), value: moodPalette)` so it crossfades
  with the background like the toolbar icons (next-24) / Image Layout tiles
  (next-31). The mood `.animation(value:)` sits ABOVE the hover-veil + active-accent
  overlays so only the outline follows the mood. No test (pure SwiftUI cosmetic;
  Color equality unreliable). Build + full suite green.
- **2026-06-19** `feat/next-34` — accessibility pass on everything added since the
  last one (`feat/next-25`), i.e. next-26→33. Most of that range is non-UI
  (next-27 classification, next-28 count logic) or visual/layout-only (next-29
  scroll-clip, next-31 mood tiles, next-33 card restyle) with no new controls, and
  next-30's Escape back-out is a keyboard accelerator that's inherently accessible;
  the Settings modal (next-32 QA) is text-labeled `Toggle`s + the already-labeled
  `SheetCloseButton`. The real surface was **Collections in the Sidebar**
  (next-32), which was largely built with a11y in mind but had three gaps, all in
  `Views/SidebarView.swift`: (1) **dead VoiceOver actions** — `CollectionSidebarRow`
  exposed "Move Up"/"Move Down" custom actions unconditionally (no-ops in Name/Date
  sort, and offered at list boundaries), whereas the context menu correctly gates
  them. Replaced the `.accessibilityAction(named:)` chain with a single
  `.accessibilityActions { }` builder that gates the Move actions on `manual` sort
  AND index bounds (`index > 0` / `index < count - 1`) — the exact negation of the
  context menu's `.disabled` conditions over the same `index`/`count` source, so
  VoiceOver omits a Move action exactly when the menu would disable it (omitting a
  dead rotor action is the better a11y behavior). The default activate action (open
  collection) is preserved as a separate `.accessibilityAction { }`. (2) **ambiguous
  sort menus** — next-32 put a second "Sort: …" pop-up in the sidebar; the
  collections one already had `.accessibilityLabel("Sort collections")` but the
  folder one had none, so VoiceOver read two near-identical pop-ups. Added
  `.accessibilityLabel("Sort folders")`. (3) **section headings** — the new
  FOLDERS / COLLECTIONS `SectionHeader` titles weren't exposed as headings; added
  `.accessibilityAddTraits(.isHeader)` to the title `Text` (scoped to the Text, not
  the HStack, so the collapse `Button`'s own label/action is untouched) so the new
  sidebar structure is navigable via VoiceOver's heading rotor. Additive a11y
  annotations only — no layout/behavior change; one file. Build + full suite green
  (`** TEST SUCCEEDED **`); independent review clean (no Critical/Important). The
  rest of next-32's sidebar (rows as single activatable elements with name+count
  labels + `.isButton`/`.isSelected`, mouse-only grips `.accessibilityHidden`,
  labeled collapse buttons / bottom-bar pills / menu-bar Move Collection commands)
  was already correct.
- **2026-06-19** `feat/next-35` — codebase health/security review + 5 fixes. A
  six-dimension read-only audit (memory/leaks, concurrency, security/privacy,
  SQLite/GRDB, filesystem/data-loss, logic/crash) over the whole app, then an
  adversarial review of the diff. Verdict: healthy — every load-bearing invariant
  intact (zero network except Sparkle, Trash-only deletes, remote-load-blocked
  SVG/Markdown, parameterized SQL, sandbox, path-traversal guards, content-hash
  iCloud detection + zero-byte hash guard + PathReconciler false-empty guard); no
  retain cycles, no memory-safety races. **Fixes:** (1) `SearchService` "This Folder"
  scope used a bare `hasPrefix` → leaked sibling-folder hits (`/a/Inspo` matched
  `/a/Inspo Extra`); now `== prefix || hasPrefix(prefix + "/")` (HIGH, real
  wrong-results bug). (2) `AnalyzePipeline` `while isRunning` busy-wait had a
  wake-race letting two passes run at once + `cancelActivePass()` hit the wrong pass;
  added a synchronous `passClaimed` claim via `acquirePass()` (MEDIUM — see durable
  gotcha). (3) `AppState.openStarred` started a security scope never balanced →
  refcount leak across pin re-opens; de-duped to one start per path, recorded only on
  success (LOW). (4) `FontViewerView` registered fonts process-wide without
  unregistering; now unregisters on `.task` teardown (only what it added), via a
  cancellation-poll not `Task.sleep(.max)` (LOW). (5) `Database` set
  `Configuration.foreignKeysEnabled = true` explicitly so Housekeeping's
  cascade-reliant prune can't silently orphan rows if GRDB's default ever changes
  (defensive no-op). Perf items surfaced (semantic search O(n)/keystroke, tag `LIKE`
  scan, `CollectionStore` N+2) left as documented personal-scale scaling concerns,
  not bugs. Build + full unit suite green throughout; adversarial diff review found no
  Critical/High regression (FK change confirmed a runtime no-op, `acquirePass`
  deadlock-free). No new tests (one-line predicate matching an already-tested
  convention, view-lifecycle teardown, DB config). Five files. Spec/audit narrative
  in `docs/session-log.md`.
- **2026-06-20** `feat/next-37` — Library Backup & Restore. Two explicit, legible
  actions in the Muse app menu: **Back Up Muse…** exports one self-contained
  `.muselibrary` JSON file (folders, collections, tags manual+AI, stars, AI-derived
  metadata; excludes thumbnails + heavy OCR text), and **Restore from Backup…**
  opens a locked, `InfoSheet`-sized **Reconnect wizard**. Because the OS-hidden
  `.muse/` sidecars can't be assumed to travel, the backup is the ONLY thing
  carried over and is fully self-contained. Identity is the existing SHA-256
  **content hash**: collection membership/cover/exclusions are re-keyed from the
  per-machine `FileRow.id` (a UUID, not portable) to content hash on export and
  back on import. The wizard lists the backed-up folders; the user locates each
  ONE AT A TIME (folders can live anywhere — there is deliberately NO master
  "point at one parent / Reconnect All", which assumed a single location), and
  locating a folder reconnects it immediately: index through the real `Indexer`
  (creates rows by content hash), match the archive's occurrences by hash
  (filename fallback, surfaced as "N by name — check", not silently trusted),
  apply metadata + tags (re-keyed to the new `parent_dir`, manual-beats-vision),
  then materialize collections + stars and `await CollectionsEngine.shared.reload()`.
  **The live library never shows ghosts:** an auto collection that reconnects to
  zero files is dropped; a hand-made OR hidden (deleted-tombstone) collection is
  preserved; partial collections show only reconnected members. Restore RECONCILES
  (doesn't overwrite): files on disk not in the backup index + analyze fresh via
  the normal pipeline. Pure cores are unit-tested (`BackupArchive` round-trip,
  `BackupBuilder` re-keying, `ReconnectMatcher`, `CollectionMaterializer`,
  `ReconnectApplier`); the wizard/model are integration. Two code-review passes +
  one systematic-debugging session (the iCloud-folder-vanishing bug → the
  `BookmarkStore` activate-before-append fix, see the durable gotcha). Build + full
  suite green. Spec + plan in `docs/superpowers/`; narrative in `docs/session-log.md`.
- **2026-06-20** `feat/next-38` — Hero **INFO card** (first of three browsing
  features brainstormed together; the other two — grid faceted filters + multi-tag
  AND view — have specs in `docs/superpowers/specs/` but are NOT built yet). A new
  card in the hero viewer's right column (below COLORS) showing a file's *extra*
  metadata beyond the subtitle: **photos** Taken/Camera/Lens/Exposure/Location
  (ImageIO EXIF/TIFF/GPS), **PDFs** Pages/Title/Author/Creator (PDFKit), **A/V**
  Duration (AVFoundation), and a **Modified** filesystem date on every file. The
  subtitle line dropped its bare (unlabeled) date — it's now `size · dimensions`
  only — and that date moved into INFO as the labeled **Modified** row, placed
  directly under **Taken** (or at the top when there's no capture date). New pure,
  unit-tested `Viewers/FileMetadata.swift` (formatting) + a thin off-main IO loader
  `load(url:kind:)`; metadata is read **on viewer-open only — no DB column, no
  migration** (mirrors the palette-fallback pattern), with the standard dataless
  iCloud guard so classification/reads never force a download. **Location is text
  coordinates + an "Open in Maps" link-button** (`maps://` via `NSWorkspace`,
  `%.6f`) — deliberately NO inline `MKMapSnapshotter` map (that fetches remote
  tiles, violating the update-only network policy). The card is **hidden entirely
  when it would have zero rows** (rare now that Modified is near-universal; a
  dataless file → `.empty` → no card), and has a **+/× collapse header** reusing
  the TAGS card's `PlusCircleButton` + spring (open by default). The value types
  (`FileMetadata`/`InfoRow`/`Coordinate`) are marked **`nonisolated`** because the
  project's default actor isolation is MainActor — without it their synthesized
  `Equatable`/`Identifiable` conformances are main-actor-isolated and unusable from
  the detached load + nonisolated XCTest methods (this fix removed the only
  warnings the branch's files emitted; the codebase's many other pre-existing
  Swift-6 concurrency warnings are a separate, untouched baseline). Built
  subagent-driven (5 TDD tasks, per-task review + a whole-branch review), then two
  rounds of live polish from driving the app. Build + full suite green (FileMetadata
  20 tests). Spec + plan in `docs/superpowers/`; narrative in `docs/session-log.md`.
- **2026-06-20** `feat/next-39` — fix: **sidebar file count froze under sustained
  FSEvents** (systematic-debugging). After importing iPhone files (a 48 MP RAW + a
  30 s video) into an iCloud-synced folder, the grid updated but the sidebar count
  never refreshed in-session (only on restart). Root cause: `FolderStatCache.handle`
  rescheduled its 0.4 s recompute debounce on EVERY qualifying FSEvents under a root
  with no maxWait cap, so the minutes-long stream of iCloud upload/metadata events
  during the analysis reset it indefinitely and `recompute` never ran. Confirmed by
  instrumenting the count path + a 6 s touch-storm (recompute fired 0× during, once
  ~0.4 s after). Fix: a 2.0 s maxWait cap via the pure, unit-tested
  `StatRecomputeScheduler` — past the cap, flush immediately instead of
  rescheduling, so the count refreshes ~every 2 s even under continuous churn
  (single-add still uses the trailing 0.4 s debounce). Verified the fix flushes
  every ~2.4 s during an 8 s storm. The separate "Organizing" pill running ~7 min
  is just the genuinely heavy 48 MP RAW + video analysis, not part of this bug.
  `FolderStatCache.swift` + new `FolderStatSchedulerTests` (5). MuseTests green.
  Also on this branch: the parked `grid-voiceover-open` spec (built later). See the
  durable gotcha above + `docs/session-log.md`.
- **2026-06-20** `feat/next-41` — **Folders as grid cards.** In the one-level
  (subfolders-toggle OFF) browse view, a folder's immediate subfolders now render
  as grid cards (folders-first, Finder pattern), reusing the existing non-image
  file-card rendering for the native folder icon + caption + mood-contrast — no new
  tile view. Double-clicking a folder card navigates INTO it and the sidebar
  expands + highlights that row (highlight matched by standardized URL, not node
  id). The sidebar's IMMEDIATE file count now includes immediate subfolders (matches
  the grid + Finder); the recursive count stays files-only. A folder card's
  right-click menu equals the sidebar subfolder menu — New Subfolder / Rename /
  Reveal in Finder, nothing else. Folders are excluded from all file-only flows
  (collection/tag/share/new-collection/move-to-folder) and, post-QA, from the
  mixed-selection Move-to-Trash + sidebar drop-to-move (see the durable gotcha
  above). The recursive read, search, and collections stay files-only by
  construction. Built subagent-driven (6 TDD/wiring tasks, per-task review + a
  whole-branch opus review that caught the two mixed-selection destructive leaks,
  then a deep bug-hunt QA pass). New pure `Models/FolderOrdering.swift` (folders-
  first stable partition, unit-tested); `FolderStat` immediate count +
  `FolderReader.files(includeFolders:)` + `AppState.openSubfolder`/`resolveFolderNode`
  (tree-walk that loads children along the path so the resolved node has a parent
  chain — rename/new-subfolder reload via it). New tests: `FolderOrderingTests`,
  `FolderStatCountTests`, `FolderReaderFoldersTests`, `FolderCountGridConsistencyTests`
  (empirical sidebar-count == grid-tile-count across package/symlink/hidden entries).
  Build + full suite green. Spec + plan in `docs/superpowers/`; narrative in
  `docs/session-log.md`. Known-minor (v1, documented): folders' intra-group order is
  arbitrary under Size/Kind sorts (all-tie keys); deterministic under Name/Date/
  Color/Shape. PENDING human GUI verification of the interactive flows (live click
  automation was unavailable — macOS Accessibility not granted to the harness).
- **2026-06-20** `feat/next-42` — **Grid faceted filters (kind / date / size).**
  A funnel toolbar button beside the sort cluster opens a mood-picker-styled
  popover (Kind checkboxes: Images/Videos/PDFs/Documents/Audio/Folders/Other ·
  Date radio: Any/Today/This Week/This Month/This Year, **modified** date · Size
  radio: Any/<1MB/1–10/10–100/>100MB · Clear All). The button inverts to the
  engaged accent (blue) whenever a filter is active. It sits in the sort cluster
  BETWEEN the sort-by menu and the direction arrow (per-control `.disabled`: live
  during search since it narrows results, but disabled on the Collections CARD
  page where cards aren't filtered). The filter is a pure narrowing layer applied
  as the FINAL step of the `visibleFiles` pipeline on EVERY branch (browse /
  collection / tag / search), and PERSISTS across folder switches (held on AppState,
  mirrored to AppSettings — enables a cross-folder "PDFs this week everywhere"
  sweep). Reuses the established pure-model + AppSettings-mirror + AppState
  @Published + memo-invalidation pattern (`imageLayout`/`tileBackground`). New pure
  `Models/GridFilter.swift`: `KindFacet`/`DateFacet`/`SizeFacet` + a `GridFilter`
  value type (`isActive`, deterministic `matches(kind:sizeBytes:modified:now:)`
  with injected `now`, decimal-MB buckets matching `ByteCountFormatter(.file)`,
  Codable `resolve`); `KindFacet(from:)` is an exhaustive 16-case AssetKind switch
  (→`.other` default; `.folder` is its own facet). The matcher reads what
  `FileNode` already carries (kind/sizeBytes/modifiedAt) — no extra
  `resourceValues` — and matches a folder ONLY by the kind facet (date/size never
  hide one). Two QA fixes: **(a)** "Folders" is a first-class Kind facet so
  subfolder cards can be toggled on/off (unchecking hides them; other facets leave
  them alone); **(b)** `gridFilter.didSet` calls
  `pruneSelectionToVisible()` so a filter-hidden selected file can't ride into a
  selection action (see the durable gotcha above). A11y: popover section headers
  get `.isHeader`; the funnel announces state via `.accessibilityValue`. New
  `GridFilterTests` (16), `Views/GridFilterPopover.swift`. Build + full `MuseTests`
  suite green; three-lens review (correctness/concurrency · QA/integration · UI-a11y)
  + a focused prune-fix review, all converged. Accepted/documented: in-collection
  count can exceed the filtered grid (count is correct; funnel is the cue; spec
  lists Collections-card filtering out of scope) and the stale-`now`-across-idle-
  rollover edge (memo + wall-clock, self-corrects on next interaction). Spec + plan
  in `docs/superpowers/`; narrative in `docs/session-log.md`. PENDING human GUI
  verification of the interactive flows (live click automation unavailable).
- **2026-06-20** `feat/next-43` — **disable show-subfolders in the Collections
  world.** The `rectangle.stack` show-subfolders toggle was live everywhere, but a
  collection is a flat membership with no folder tree — toggling it on the
  Collections card page or inside a single collection does nothing. New
  `ContentView.inCollectionsContext` (`showingCollections || activeCollectionID != nil`)
  covers the card page AND a drilled-into collection regardless of entry path
  (page-opened keeps `showingCollections` true; sidebar-opened sets only
  `activeCollectionID`); the toggle's `.disabled` became `isSearchActive ||
  inCollectionsContext`. Deliberately a BROADER predicate than the sort cluster's
  `isCollectionsPage` (card-page only) — `tagSortMenu`/`filterMenu` stay live
  *inside* a collection (tag chips + in-collection filtering are valid) but
  subfolders is dead in the whole Collections world. The icon greys out for free
  via `moodToolbarIcon`'s `@Environment(\.isEnabled)` dim (next-42). One file
  (`ContentView.swift`); build + full `MuseTests` green; no new test (pure
  SwiftUI `.disabled` on a computed bool, like prior toolbar-enablement changes).
  PENDING human GUI confirmation of the grey-out on the card page + inside a
  collection (live click automation unavailable).
- **2026-06-20** `fix/sidebar-folders-vanish` — **FOLDERS sidebar section goes
  transiently empty on scroll.** Reported via screenshot: scrolling back up inside a
  large collection left the FOLDERS section with no rows while COLLECTIONS rendered
  fine; not reproducible on demand. Systematic-debugging ruled out data loss
  (nothing rebuilds `rootNodes` on scroll; the section headers still showed, so
  `body` didn't hit its empty state) and pinpointed the asymmetry: `folderList`
  rendered its top-level rows in a `LazyVStack` while `collectionsList` was already a
  plain `VStack`. Inside the shared two-section `ScrollView`, the `LazyVStack`
  de-materialized off-screen folder rows and failed to re-create them. Fix:
  `folderList` is now a plain `VStack` iterated directly by node id (mirrors
  `collectionsList`; the top-level root list is short, children render only when
  expanded, so no virtualization cost — and always-realized rows report frames even
  off-screen, improving drag-reorder). Covers both the ON (two-section) and OFF
  (folders-only) sidebar paths. Stale `LazyVStack`-justified drag comments updated.
  One file (`Views/SidebarView.swift`); build + full `MuseTests` green; independent
  diff review clean; no new test (SwiftUI rendering race, no testable surface — UI
  views aren't unit-tested). New durable gotcha recorded. Real confirmation is the
  bug ceasing to recur in the live build.
- **2026-06-20** `feat/next-45` — **Multi-tag view (AND / intersection)** — the third
  and most invasive of the three browsing features (after the hero INFO card `next-38`
  and grid faceted filters `next-42`). The tag chip row could filter by exactly one tag;
  it's now an ordered SET. **Plain-click** a chip = view just that tag (today's behavior,
  preserved; re-plain-clicking the sole chip clears). **Cmd-click** toggles a chip in/out;
  the grid shows files carrying ALL selected tags (set **intersection / AND**), which
  monotonically narrows and can legitimately be empty (honest empty grid). A **banner**
  ("Viewing [a] and [b]", Oxford "and" for 3+) names the active set for 2+ tags, sitting
  at the grid top below the chips — the tag labels render as small quiet **pills**
  (`BannerPill`, matching the resting chip wash) so they pop from the connective words,
  in a horizontal scroll that mirrors the chip row (no ugly per-pill truncation on
  overflow); the plain string is the VoiceOver label. Scope expands to **search**: the chip row now mounts over
  search results and the tag filter narrows within them (This-Folder and All scope), chips
  derived from the result set. **Escape** clears the whole set in one press (a new
  `.clearTags` layer ordered after viewer/search, before the collection back-out). The
  scalar→set migration was the real cost: `AppState.activeTagLabel: String?` →
  `activeTagLabels: [String]`, `activeTagPaths` retained as the intersection, all readers
  (Tags menu, SelectionMenu, GridView `.id`/`gridSignature`, TagChipsRow, `select(folder:)`)
  migrated together (no half-state). New pure `Models/TagSelection.swift` (`toggling` +
  Oxford `bannerText`, unit-tested); `setActiveTags` core (token-guarded, per-`parent_dir`
  queries intersected in one transaction); `singleActiveTag` gates the single-tag menu
  commands. **NOT** in scope (per spec): bulk tag delete (deletion stays single,
  right-click), OR/union mode, Collections-card-page filtering. New `TagSelectionTests`
  (15: toggle/banner/segments/rename) + extended `EscapeActionTests` (`tagsActive` param +
  4 ordering cases). A **three-lens QA pass** (correctness/concurrency · UI/a11y ·
  adversarial 12-scenario trace) then fixed: the sync-label-commit race (lost tags on
  rapid Cmd-click / failed double-click clear), the phantom-banner-on-delete, the
  rename-merge duplicate, the banner overflow (horizontal scroll), and an airtight grid
  `.id` separator (`\u{1f}`); a second verification round confirmed all six correct with
  no regression. Build + full `MuseTests` green throughout. New durable gotcha recorded.
  Spec + plan in `docs/superpowers/`. PENDING human GUI verification of the interactive
  flows (live click automation unavailable).
- **2026-06-20** `feat/next-46` — **collection PDF export carries the active tag
  filter.** Exporting a collection (`ShareCollectionButton` → Save to… / Share) now
  reflects the on-screen tag refinement. (1) `exportURLs` switched from
  `activeCollectionFiles` (all members) to `AppState.visibleFiles` minus folders — the
  filtered grid, so an active tag set AND any kind/date/size facet narrow the export;
  the header count follows `urls.count`. Safe because `GridView` mounts the collection
  header (which holds the Share button) only when `!isSearchActive`, so `visibleFiles`
  here never resolves to its global-search branch. (2) `CollectionPDFExporter.makePDF`
  gained `tagLabels: [String] = []`, drawn on page 1 as bare CoreText pills above the
  title — matching the on-screen `BannerPill` (12pt medium, `black @ 8%` wash, 8/2pt
  pad), left→right, NO "Viewing"/"and" words, shown for **1+ tags** (the PDF has no chip
  row, so a single pill is the only refinement cue — a deliberate divergence from the
  banner's 2+ threshold). The page-1 `firstPageHeaderHeight` grows to fit the pill
  block + gap + title (`CollectionPDFLayout.paginate` already takes a variable header);
  no-tags is byte-for-byte the old 46pt title-only header, so an unfiltered export is
  identical. Pills wrap to a second row on overflow. **QA:** two adversarial review
  rounds — round 1 found a **High** (an over-long user-renameable tag overran the page
  margin; the on-screen pill relies on a scroll the PDF lacks) → fixed by clamping each
  pill width to the content width in `layoutPills` and ellipsis-truncating the label in
  `drawPill` (`CTLineCreateTruncatedLine`, mirroring `drawCaption`); round 2 confirmed
  the fix (bounds proof, no residual Critical/High). Plus a **visual render check** —
  rendered real PDFs (none/one/two/long-tag) via a throwaway test harness and eyeballed
  the page-1 headers (all correct), harness deleted after. No new unit tests (CoreText
  drawing has no pure surface; `CollectionPDFLayout` is unchanged). Build + full
  `MuseTests` green. Spec + plan in `docs/superpowers/`. Two files:
  `Views/ShareCollectionButton.swift`, `Export/CollectionPDFExporter.swift`. PENDING
  human GUI confirmation of the live export flow.

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
                                   One-level read passes FolderReader includeFolders
                                   :true + FolderOrdering.foldersFirst (folder cards
                                   first); openSubfolder(_:) navigates into a folder
                                   card (= sidebar click) and resolveFolderNode(_:)
                                   walks/loads the sidebar tree to the URL so the
                                   resolved node has a parent chain (rename/new-
                                   subfolder reload via it) — feat/next-41.
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
                                   effectiveSelectionURLs / selectionOrder.
                                   pruneSelectionToVisible() drops any selected path
                                   the active gridFilter hides (called from
                                   gridFilter.didSet) so a hidden file can't ride
                                   into a selection action — feat/next-42
    AppState+Filters.swift         extension: collection + tag-chip filtering —
                                   visibleFiles / tagSourceFiles / setActive-
                                   Collection / setActiveTag / removeTag /
                                   removeFromCollection / setCollectionCover /
                                   toggleCollectionsPage / bulkTagCommandsAvailable.
                                   visibleFiles applies gridFilter as the FINAL
                                   narrowing step on every branch (search included),
                                   keeping `.folder` cards regardless of facet —
                                   feat/next-42
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
                                   enumeration skips the per-file fileExists stat.
                                   In the one-level browse view a subfolder is a
                                   `.folder` node (feat/next-41) — selectable like
                                   a file; see the durable gotcha on filtering it
                                   from file-only flows
    FolderOrdering.swift           pure folders-first stable partition for the grid
                                   (Finder pattern): foldersFirst([FileNode]) keeps
                                   each group in the caller's sort order; a no-op
                                   when there are no folders (recursive view).
                                   Unit-tested (feat/next-41)
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
    GridFilter.swift               global grid faceted filter (pure, unit-tested):
                                   KindFacet (image/video/pdf/document/audio/
                                   folder/other, from an exhaustive 16-case
                                   AssetKind switch) + DateFacet (any/today/week/
                                   month/year, MODIFIED date, Calendar.current
                                   windows) + SizeFacet (any/<1MB/1–10/10–100/
                                   >100MB, decimal MB) + a GridFilter value type:
                                   isActive, deterministic matches(kind:sizeBytes:
                                   modified:now:) (now injected for tests; a folder
                                   matches by the kind facet ONLY — date/size never
                                   hide one), Codable resolve(_:) default .none.
                                   Persisted via AppSettings.gridFilter
                                   (JSON), mirrored on AppState.gridFilter whose
                                   didSet invalidates the visibleFiles memo + prunes
                                   the selection (feat/next-42)
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
                                   repoints a renamed root's bookmark + display name.
                                   addRoot ACTIVATES before appending so the
                                   synchronous $roots-sink rebuild can resolve the
                                   new root's URL (feat/next-37 — see durable gotcha)
    FolderTree.swift               lazy hierarchical tree + FolderReader; FolderNode
                                   has a weak parent + reloadChildren() (refresh after
                                   create/rename — feat/folder-ops-and-share).
                                   FolderReader.files(in:showHidden:includeFolders:)
                                   — includeFolders:true (default false) emits plain
                                   subfolders as `.folder` nodes for the one-level
                                   grid; packages (.app) always stay files (feat/
                                   next-41)
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
                                   (2026-06-18). The IMMEDIATE count now counts every
                                   non-hidden entry — files, packages, AND subfolders
                                   — to match the one-level grid (which shows folder
                                   cards) + Finder; the recursive count stays
                                   files-only (feat/next-41)
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
                                   changes (2026-06-18). The recompute debounce has
                                   a maxWait CAP (pure StatRecomputeScheduler, 0.4s
                                   trailing / 2.0s cap) so a sustained FSEvents
                                   stream — iCloud sync churn during a long analysis
                                   — can't starve it and freeze the count
                                   (feat/next-39)
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
    FileMetadata.swift             hero INFO-card metadata: pure formatting
                                   (EXIF/TIFF/GPS image · PDF doc attrs · A/V
                                   duration · filesystem Modified date) + a thin
                                   off-main IO loader load(url:kind:). Read on
                                   viewer-open only (NO DB/migration); dataless
                                   iCloud guard. Value types are `nonisolated`
                                   (module default isolation is MainActor) so they
                                   build in the detached load + nonisolated tests.
                                   Unit-tested (feat/next-38)
  Views/
    SidebarView.swift              multi-root OutlineGroup tree + starred section;
                                   file-URL drop on folder rows MOVES the grid
                                   selection there (FileMover, folders filtered out
                                   so a co-selected folder card can't ride along —
                                   feat/next-41) with a drop-target highlight;
                                   Reveal in Finder menu item (feat/multi-select).
                                   Row isSelected matches by standardized URL (so a
                                   folder opened from a grid card lights up — feat/
                                   next-41). No folder shows as selected
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
                                   (feat/multi-select). A `.folder` tile (one-level
                                   browse) selects like a file but double-click
                                   NAVIGATES (openSubfolder, not the viewer), .onDrag
                                   is a no-op, and its contextMenu is the sidebar
                                   subfolder menu (New Subfolder/Rename/Reveal); the
                                   file Move-to-Trash skips folder nodes (feat/
                                   next-41 + QA — see the durable gotcha). A content-level Color.clear
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
                                   selection (feat/multi-select). All file-only
                                   actions consume a folder-filtered `fileURLs`
                                   subset and hide when it's empty — collection/tag/
                                   share/new-collection/move-to-folder never touch a
                                   co-selected folder card (feat/next-41)
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
                                   exportURLs = AppState.visibleFiles minus folders —
                                   the on-screen filtered grid, so an active tag/facet
                                   filter narrows the export; the header count follows
                                   urls.count (feat/next-46, was all members). Passes
                                   the active imageLayout.aspect + effectiveTileBackground
                                   backdrop (sRGB cgColor) AND appState.activeTagLabels
                                   into the exporter so the PDF mirrors the grid (the
                                   tags render as header pills — feat/next-22, next-46).
                                   Safe: GridView mounts this header only when
                                   !isSearchActive, so visibleFiles never resolves to
                                   the search branch here
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
    GridFilterPopover.swift        the funnel-button popover (mood-picker chrome,
                                   ~270): KIND checkboxes incl. Folders (Toggle
                                   .checkbox, "empty == all" sentinel normalized in
                                   toggleKind) / DATE + SIZE radio (Picker
                                   .radioGroup) / Clear All, writing
                                   AppState.gridFilter. Section headers carry
                                   .isHeader. The funnel (ContentView.filterMenu)
                                   lives INSIDE the sort cluster between the sort-by
                                   menu and the direction arrow; per-control
                                   .disabled — live during search (narrows results)
                                   but disabled on the Collections card page (cards
                                   aren't filtered); engaged-blue +
                                   .accessibilityValue when gridFilter.isActive
                                   (feat/next-42)
    InfoSheet.swift                ⓘ About-Muse modal (behavior + privacy); uses
                                   the shared SheetCloseButton (feat/next-21). Has a
                                   "Back Up & Restore" section (feat/next-37)
    Backup/
      ReconnectWizard.swift        the locked Restore sheet (InfoSheet chrome
                                   600×720, no ✕ — Done only, disabled while a folder
                                   is reconnecting). Folder rows with per-row Locate…
                                   (reconnect immediately) + ✓/flagged/failed status;
                                   collections readout in a separated card. Renders
                                   ReconnectModel; matching/applying is all in the
                                   pure Backup/ cores (feat/next-37)
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
                                   PillFlow/PillRowModel). ViewerInfoColumn renders
                                   an INFO card (below COLORS) from FileMetadata —
                                   labeled rows (Taken/Modified/Camera/…, Pages,
                                   Duration), a collapsible +/× header like the
                                   TAGS card (open by default), and a text-only
                                   "Open in Maps" link-button (maps://, no inline
                                   map). The subtitle line is now size · dimensions
                                   only (the date moved into INFO as "Modified").
                                   HeroImageViewer loads FileMetadata on open
                                   (feat/next-38)
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
  Backup/                          (feat/next-37) Library Backup & Restore. Export
                                   one self-contained `.muselibrary` file +
                                   reconnect it on another Mac by content hash.
    BackupArchive.swift            pure Codable model (BackupArchive + BackupRoot/
                                   File/Occurrence/Member/Collection/Star); reuses
                                   Sidecar for content-level per-file metadata.
                                   Membership/cover re-keyed to content_hash here
                                   (FileRow.id UUID isn't portable). Unit-tested
    BackupDocument.swift           encode/decode the archive ↔ Data (JSON);
                                   `.muselibrary`; rejects schema mismatch
    BackupBuilder.swift            DB → BackupArchive (off-main read). Only files
                                   with an alive path are exported; membership/
                                   cover/exclusions re-keyed to content_hash and
                                   gated to backed-up hashes (internally consistent).
                                   Unit-tested
    ReconnectMatcher.swift         pure: classify archive occurrences vs the disk
                                   files the indexer hashed — exact (content hash)
                                   first for ALL occurrences, then filename
                                   fallback, else unmatched; no disk file used
                                   twice. Unit-tested
    CollectionMaterializer.swift   pure: archive collections → rows to create,
                                   re-keying hash→file_id. "No dead collections":
                                   drops empty AUTO+visible; KEEPS empty manual OR
                                   hidden (deleted tombstone, so recluster can't
                                   resurrect). Unit-tested
    ReconnectApplier.swift         DB writer: applyMeta (FileRow meta + tags at the
                                   NEW parent_dir, manual-beats-vision + FTS mirror)
                                   / applyCollections (materialize + upsert, members/
                                   exclusions, ON CONFLICT preserves is_hidden) /
                                   applyStars / currentFileIDForHash. Unit-tested
    ReconnectModel.swift           @MainActor wizard model. Per folder (located one
                                   at a time, anywhere): dedup-add as root, index via
                                   Indexer.indexBatch, read disk files back, match,
                                   applyMeta (capturing failures → .failed status;
                                   name-only surfaced as flagged), applyCollections +
                                   applyStars, CollectionsEngine.reload(), then
                                   analyzePending reconciles new/changed files
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
                                   preserved (feat/next-22). makePDF also takes
                                   tagLabels: [String] = [] — the active tag-filter
                                   labels drawn as bare CoreText pills above the title
                                   on page 1 (capsule matching the on-screen BannerPill,
                                   no "Viewing"/"and" words, 1+ tags); layoutPills packs
                                   them left→right wrapping on overflow + clamps each to
                                   the content width, drawPill ellipsis-truncates an
                                   over-long label (CTLineCreateTruncatedLine). The page-1
                                   firstPageHeaderHeight grows to fit the pill block;
                                   no tags → unchanged 46pt title-only header
                                   (feat/next-46)
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
                                   backdrop, mirrored on AppState — feat/next-22).
                                   Plus gridFilter (JSON, default .none; global grid
                                   faceted filter, mirrored on AppState — feat/next-42)
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
   (flips the active mode's order — newest↔oldest, A↔Z, …) · filter
   (line.3.horizontal.decrease.circle — funnel popover: kind/date/size facets,
   engaged-blue when active, stays live during search) · show-subfolders ·
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
