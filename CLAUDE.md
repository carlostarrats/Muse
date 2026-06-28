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
- Network policy: **Update-only, plus one explicit opt-in publish path.** No
  analytics, no telemetry, no data collection, no remote content fetches. Two
  sanctioned network code paths, both gated by `com.apple.security.network.client`:
  (1) **Sparkle** — fetching its signed appcast feed + downloading the update;
  (2) **Google Drive collection share** (`feat/drive-collection-share`,
  2026-06-25) — when the user signs into Google and presses Publish, the
  selected images + form text upload to **the user's own Drive** (OAuth
  `drive.file`, PKCE). This is opt-in + user-initiated; the developer still
  receives no data (bytes go user → their Drive). Every Sparkle download is
  EdDSA-verified against the embedded `SUPublicEDKey`. `SUEnableAutomaticChecks = true` so Sparkle checks
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
- `docs/search-bar-fill-investigation.md` — **deferred.** Why the center search
  field can't be made to fill the toolbar Safari-style within SwiftUI, every
  approach tried (`.infinity`, width-tracking, `.searchable`) and why each
  failed, and what a real fix (native `NSToolbar` rebuild) would cost. Read it
  before re-attempting "make the search bar fill the space" so the dead ends
  aren't repeated.

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
| Polish 17 — iCloud collection share (backend #1 of a two-backend "share a collection") | ❌ **REMOVED 2026-06-25** | `feat/icloud-collection-share` (merged, then ripped out) |
| → *Why removed:* the whole design rested on the false assumption that `NSSharingServicePicker(items:[folder])` would offer a "Copy Link" service for a folder in the app's iCloud container. **It never does** — the iCloud Drive public-link affordance is Finder-only, not a programmatic `NSSharingService`. So the share sheet only offered file-transfer services; emailing the raw images got bounced by Gmail. Apple exposes no API to mint a public iCloud gallery link. **The Drive backend (Polish 18) is the real link path** — keep that; do NOT re-add an in-app iCloud "Share Link". | | |
| Polish 18 — Google Drive collection share (backend #2, the "magic" path): "Share Drive Link" → OAuth `drive.file`/PKCE sign-in → upload images into a tidy `My Drive/Muse/<collection> — <date>/` → link-share → branded Cloudflare page (`muse-share.pages.dev`; manifest in the URL fragment, images from Drive thumbnails, backdrop switcher light/grey/dark). **PDF = the recipient prints the page** (`window.print()` + print stylesheet, they pick the paper size) — NO app-side PDF generated/uploaded. View-menu "Manage Drive Shares…" (open link / unpublish). Muse-local expiry sweep deletes the folder past its date. **First sanctioned network egress beyond Sparkle** — opt-in, user-initiated. The Drive UI is **NOT** `#if DEBUG`-gated — "Share Drive Link" (`ShareCollectionButton`), the Settings sign-in row, and "Manage Drive Shares…" ship in **release** builds. **OAuth consent screen must be flipped to "In production" in Google Cloud Console** for non-test users to publish — while it's in "Testing" status, only manually-added test users can sign in (everyone else hits Google's "app is being tested" wall) and refresh tokens expire after 7 days. `drive.file` is non-sensitive → production needs NO verification review / CASA audit, only a complete consent screen (homepage + **published privacy policy URL**, served from `web/share/privacy.html`). Privacy + Terms live at `web/share/{privacy,terms}.html` (Cloudflare clean URLs `/privacy` `/terms`), linked from the share-page footer. Pure units (PKCE/manifest/store/expiry/multipart) + JS tests. | ✅ merged | `feat/drive-collection-share` |

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

Hard-won — re-introducing any of these re-introduces a shipped bug. The four
most critical are also Claude memories (linked). Full repro/why is in
`docs/session-log.md` under the cited branch.

- **Grid must stay virtualized.** No custom SwiftUI `Layout` or non-lazy container over the full file set — it materializes every tile + relayouts O(n) per publish (1700-image folders died). Use `MasonryGeometry` frames + a manual viewport window. Memory: `muse-grid-must-stay-virtualized`.
- **Fix the code, not the dev DB.** The user's library is a disposable fixture; never ship one-off migrations to patch a corrupted local DB — fix forward code, validate by clean re-index. Memory: `muse-fix-code-not-my-data`.
- **iCloud change detection = content hash, NOT size/mtime.** iCloud oscillates size/mtime on repeated reads, so a size/mtime fast-path reindexes the whole folder every visit. In-place edits are re-checked via content hashing (FSEvents live + cold-open verify) — deliberate. The zero-byte-hash guard in `HashService.sha256` must stay (its loss welded 900+ files onto one row). Memory: `muse-icloud-content-refresh-override`.
- **Classification never reads dataless iCloud bytes.** `AssetKind`'s ImageIO header sniff (extensionless-image fallback) guards on `.ubiquitousItemDownloadingStatusKey` and skips not-downloaded placeholders — reading bytes would force a download to classify a file the user is just browsing. Reclassifies once local. Same spirit as `Indexer.isDataless` / `HashService` dataless-nil.
- **Tags are per `(file_id, parent_dir)`**, not per content hash. A duplicate in another folder has its own tags; deletes never leak across folders; NO library-wide tag delete. Other content-derived metadata (palette/caption/dims/intent/feature-print/FTS) stays content-hash-keyed. Memory: `muse-tags-are-per-file-not-per-content-hash`.
- **iCloud container is data-loss-sensitive.** Debug builds sign with `*-Debug.entitlements` (production minus the three iCloud keys) so dev churn can't make `bird` purge the production ubiquity container. Ship updates via **Sparkle only** (atomic in-place swap preserves identity) — never tell users to drag a new DMG over the old app.
- **No live SQLite in iCloud** (corruption trap) — sync is per-asset JSON sidecars via `NSFileCoordinator`. CloudKit rejected (adds a network surface; the network paths are Sparkle + the opt-in Drive publish).
- **iCloud collection share was REMOVED (2026-06-25) — do NOT re-add it.** The "Share iCloud Link" backend (per-collection copy into `Documents/Shared Collections/`, `NSMetadataQuery` upload wait, "Manage iCloud Shares…") was ripped out because it could not deliver a link: `NSSharingServicePicker` does not offer iCloud's "Copy Link" service for app-container files (that affordance is Finder-only, with no programmatic API), so the share sheet only attached the raw images and email bounced. The deleted units (`ICloudSharePaths`/`ICloudShareStore`/`UploadTally` + the folder-name-safety guards) are gone with it. **The Drive backend (Polish 18) is the only sanctioned collection-link path** — it has a real API. `ICloudZone` stays (it serves iCloud *sync*, a separate feature).
- **Google Drive share security invariants (DO NOT relax).** Scope is EXACTLY `drive.file` (Muse touches only files it created — never broaden to `drive`/`drive.readonly`; that triggers the CASA audit too). OAuth is **Authorization Code + PKCE S256, NO client secret** in the app; tokens live ONLY in Keychain (`…AfterFirstUnlockThisDeviceOnly`, never UserDefaults/logs/synced); sign-out revokes. The share page is a static file with **no API key and no secret** — the manifest rides the URL **fragment** (`#…`, never sent to the host), rendered via `textContent` only with id-regex validation under a `default-src 'none'` CSP. Network happens ONLY inside an explicit user action (sign-in/Publish/Manage/expiry-sweep). Expiry is **Muse-local** (launch sweep deletes the Drive folder it created). The recipient's PDF is the **printed page** (`window.print()`), no app-side PDF. Files live in `Sharing/Drive/`; the page in `web/share/` (deployed to `muse-share.pages.dev`). **Sign-in/out is a Settings row** (`SettingsView` "Google Drive" section); `prompt=select_account` lets a user switch accounts. **Account-switch leaves the OLD account's share folders orphaned (by design, NOT a bug):** `drive.file` is account-scoped, so once signed into a new account Muse can't see/delete the old account's folders — the expiry sweep + manual delete treat the resulting 404 as success and just drop the local record (the page still soft-expires). To truly clean up, delete shares via Manage Drive Shares BEFORE signing out. `signOut()` clears `driveRootFolderID` so the new account gets a fresh root.
- **Edit-menu "Select All" is the STANDARD item, driven by `AppDelegate.selectAll(_:)` — don't add a custom one.** SwiftUI auto-generates a standard `Select All ⌘A` whose `selectAll:` routes through the AppKit responder chain; the SwiftUI grid is no responder, so the app's lone `NSApplicationDelegate` (`@NSApplicationDelegateAdaptor`, the terminal chain link) implements `selectAll(_:)` → `appState.selectAllVisible()` + `validateMenuItem` (enabled on non-empty `visibleFiles`). A focused search field's field editor still wins ⌘A for its text (it's higher in the chain). A second, custom `Button("Select All")` produced a confusing duplicate (one greyed system item + one working custom) — that's what this replaced; never re-add it, and don't delete the `AppDelegate` (it also returns `applicationSupportsSecureRestorableState = true`). "Deselect All" (⇧⌘A) stays bespoke (no system equivalent).
- **Sidebar rows: never use `.onDrag`.** It installs an AppKit drag source on the shared hosting view and eats single-clicks. Reorder is a live `DragGesture` off a trailing grip + an opaque on-top overlay (both folder + collection lists).
- **`bookmarks.$roots` sink delivers synchronously** — don't add `.receive(on:)`; the non-animated reorder commit relies on synchronous delivery.
- **Fixed-viewport overlay effects:** per-element `.layerEffect`/`.visualEffect` is the wrong tool (breaks containers, only on-screen elements). The gradual-blur attempt was fully reverted.
- **No Metal shaders remain** (water + burn removed); `Effects/` holds only the opacity-fade delete modifier.
- **FSEvents:** the stream needs `kFSEventStreamCreateFlagUseCFTypes` or `eventPaths` is a raw `char**` (crash on first change).
- **The SVG viewer's no-network guard is a `WKContentRuleList`, NOT the nav delegate.** `WKNavigationDelegate.decidePolicyFor` fires ONLY for frame navigations, never subresources — so an attacker-supplied `.svg` with `<image href="https://…">` / `<use href>` / `<feImage>` / CSS `url()`/`@import`/`@font-face` leaked the viewer's IP on mere preview (a real shipped privacy bug — JS-off does NOT stop these passive loads). Fix lives in `SVGViewerView`: a content rule blocks `https?://`, `wss?://`, and host-bearing `file://[^/]` (the protocol-relative `//host` trick) at the *resource* layer; the file load is **deferred until the rule installs** and **fails closed** (don't render) if it can't. Don't "simplify" this back to nav-delegate-only or load before the rule — verified live (a remote `<image>` egress beacon stays unhit while the SVG still renders).
- **Hero close:** the slight search-bar "flash" on close (native toolbar materializing over the fading backdrop) is inherent + accepted. Do NOT reintroduce the always-present-toolbar or return-after-land approaches (both tried). **Escape must fire ONLY `viewerClosing = true`** and let `startClose()` own the whole close (incl. setting `viewerDismissing`), exactly as the X button does — a separate `viewerDismissing` write in the Escape path made Escape need TWO presses.
- **Collection "delete" = `setHidden(true)`** (durable tombstone the recluster never clears), NOT a row delete (silently regenerates).
- **Bulk tag delete leaves `analyzed_hash` untouched** so the auto-tagger never resurrects removed tags; they return only via explicit Regenerate.
- **Duplicates modal never fully deletes a group** — ≥1 copy always kept. A file can be in several groups (byte-exact + filename + visual), so `DuplicateDeleteRules` checks EVERY group it belongs to, not just the first: emptying a group is refused (3+) or swaps (2-copy); cross-group pre-seed conflicts reconciled by `rescued`. Don't reintroduce a per-first-group check.
- **Never drive a perpetual animation with a global `withAnimation(.repeatForever)` in `.onAppear`.** The transaction stays live and leaks into ANY view repositioned in the same update cycle (most visibly the AppKit toolbar — `GridView`'s `ShimmerBand` drifted the toolbar icons). Use value-scoped `.animation(_:value:)` to confine the repeat to its subtree.
- **A `ScrollView` clips to its OWN frame — reserve floating-toolbar clearance ABOVE the scroll view, not as inner padding.** The toolbar background is hidden, so any scroll surface reaching the toolbar edge slides content under it. Inner `.padding(.top:)` scrolls away with content. Every top-level scroll surface (grid AND `CollectionsPage`) needs its own reserve, kept on the shared `TagChipsRow.noTagsTopClearance` constant.
- **Sidebar live-drag reorder must commit the new order SYNCHRONOUSLY, and the reorderable list must be a NON-lazy stack.** (1) The commit clears lift offsets in a `withTransaction(disablesAnimations)` block that ASSUMES the list is already reordered — so the reorder must land in that same synchronous transaction (folders get it free via `$roots`; collections update `CollectionsEngine.collections` sort_order in place synchronously, then persist async). (2) A reorderable `ForEach` must be a plain `VStack` by stable id, NOT `LazyVStack` over `Array(enumerated())` (which makes a reorder read as insert/remove and fly rows in). Animate with a list-scoped `.animation(_:value:)`.
- **`withAnimation` does NOT animate an `@AppStorage`-backed change** — the UserDefaults publish lands outside the transaction (instant). To animate a persisted bool, back it with plain `@State` seeded from/written to `UserDefaults` via `.onChange`, or use value-scoped `.animation(_:value:)`.
- **Never bind a `TextField` (or any per-keystroke control) directly to a `@Published` property on the monolithic `AppState`.** Each keystroke fires `AppState.objectWillChange`, re-evaluating the WHOLE `ContentView` body (sidebar + tag chips + grid) — fast Macs hide it, but on slower Macs typing visibly lags. Hold the draft in LOCAL `@State` inside a small dedicated `ViewModifier`/subview and write to `AppState` only on commit (the alert's Create/Rename button). The dialog alerts do this via `NameCollectionAlert` / `FolderNameAlerts` (seed local `@State` on open with `.onChange`; folder drafts key on the request's `id` since `FolderNode` isn't `Equatable`, and closing always passes through nil so re-targeting the same folder re-seeds).
- **`AnalyzePipeline` passes serialize through `acquirePass()`, NOT a bare `while isRunning` busy-wait.** A sleep-gate wakes all waiters at once → two passes run + `cancelActivePass()` halts the wrong one. The fix: a synchronous `passClaimed` flag claimed with NO `await` between check and set (only the first woken waiter takes it); the claiming wrapper holds it via `defer` for its whole body. `analyze(folder:)`/`analyze(file:)` must NOT consult `passClaimed` (deadlock); cancel returns BEFORE the claim. **Every direct entry point that starts a pass must hold the claim:** the automatic paths go through `analyzePending`/`regenerateTagless`, and the manual menu/App-Intent paths go through `analyzeFolderManual`/`analyzeFileManual` — calling bare `analyze(folder:)`/`analyze(file:)` from a non-claiming caller lets a manual pass run concurrently with the automatic one (the exact bug the gate prevents).
- **Folder/scope path-prefix checks need a trailing `+ "/"`.** A bare `hasPrefix` matches a sibling (`/a/Inspo` ⊂ `/a/Inspo Extra/x.jpg`). Every prefix test guards with `$0 == prefix || $0.hasPrefix(prefix + "/")` (`Housekeeping`, `CollectionStore.isUnderAnyRoot`, `ICloudZone`, `PathReconciler`, `FolderRenameMigration`, `SearchService`). Use the same rule for any new containment check.
- **`BookmarkStore.addRoot` must `activate(root)` BEFORE `roots.append(root)`.** Appending publishes `$roots`, whose sink rebuilds the sidebar synchronously; `rebuildRootNodes` drops any root whose `url(for:)` is nil, and that reads `accessedURLs` (populated only by `activate`). Activate-after-append silently drops the new root's node (last-added vanishes). Don't reorder back.
- **A trailing debounce with NO maxWait cap starves forever under a sustained event stream.** `FolderStatCache` rescheduled its 0.4s recompute on EVERY FSEvents under a root, so iCloud sync churn froze the sidebar count indefinitely. Fix: a 2.0s maxWait cap (pure `StatRecomputeScheduler`) — past the cap, flush immediately instead of rescheduling. Any debounce over an unbounded event source needs this.
- **Folder grid cards are SELECTABLE like files — every file-only destructive/move flow must filter out `.folder` nodes.** In one-level browse, `visibleFiles` contains `.folder` `FileNode`s, so a co-selected folder rides along in any flow built on `effectiveSelectionURLs`. Move-to-Trash + sidebar drop-to-move both skip folders (`kind != .folder`); `SelectionActionsMenu` filters via `fileURLs`. Folder ops live ONLY on the folder card's context menu. Any new selection action must decide explicitly whether it applies to folders (default for file-only/destructive: exclude).
- **Any input that NARROWS `visibleFiles` must clear or prune the selection.** The selection `Set<String>` is independent of `visibleFiles`, and `effectiveSelectionURLs` rebuilds a URL for an off-view selected file (so a hidden file rides into Move/Collection/Tag/Share). Active-tag + collection-removal + collection-scope + folder-select + **search (`runSearch`, after the stale-token guard)** call `clearSelection()`; `gridFilter.didSet` calls `pruneSelectionToVisible()`. A new filter/scope that can hide selected tiles must prune in lockstep. (Entering search was the one narrowing input that historically skipped this — fixed in the post-1.3.3 health pass.)
- **An explicit `.foregroundStyle` overrides SwiftUI's automatic disabled dimming.** `View.moodToolbarIcon` colors glyphs explicitly from the mood, so a `.disabled` control's icon stayed full color. Fix: `moodToolbarIcon` is a `ViewModifier` reading `@Environment(\.isEnabled)` and applying `.opacity(isEnabled ? 1 : 0.4)`. Don't pair a fresh explicit `foregroundStyle` with `.disabled` expecting auto-dimming.
- **A `LazyVStack` row list inside a shared `ScrollView` can de-materialize and not come back — use a plain `VStack` for short sidebar lists.** The FOLDERS section's `LazyVStack` could drop off-screen rows on scroll and leave the section empty (not data loss — `rootNodes` intact). `folderList` is now a plain `VStack` by node id, like `collectionsList`. Short lists sharing a `ScrollView` gain nothing from laziness and risk the vanishing-rows glitch.
- **The tag chip filter is an ORDERED SET, not a scalar — `activeTagPaths` is the INTERSECTION (AND).** `activeTagLabels: [String]` (insertion order drives the banner). Mutate ONLY via `setActiveTags` (core — clears selection, recomputes `activeTagPaths` as the intersection) / `setActiveTag` / `toggleActiveTag`. **`setActiveTags` resolves the WHOLE filter SYNCHRONOUSLY** — it commits `activeTagLabels` AND reads each tag's paths (`pathsForTagSync`, a sync main-thread DB read) to set `activeTagPaths`, all in the click's own runloop turn, so the filter bar and the grid swap land in ONE render. A token-guarded async Task (the old design) committed the labels a frame BEFORE the paths, so the just-appeared bar shoved the still-unfiltered grid DOWN before the query returned — the "slide down, then replace" jag. The sync read can only ever wait behind one per-file write on the serial queue (a few ms; there are NO bulk write transactions to block on), and serial resolution also kills the old fast-Cmd-click stale-read race. Each per-label query stays `parent_dir`-scoped. `singleActiveTag` (count==1?first:nil) gates the single-tag menu commands. Empty intersection is a legitimate empty grid (only the single-tag case falls back to "All"). Chips + filter also mount/apply during SEARCH (search-aware `tagSourceFiles`/`reloadTagChips`). `EscapeResolver` `.clearTags` is ordered after search, before collection back-out. **The active-filter bar (`TagChipsRow`, below the chips) MUST render straight from `activeTagLabels` and show for 1+ tags — NOT gated on the scope's chips or a 2+ threshold.** Tags carry over into collections, so a single tag, or tags ORPHANED into a collection with none of them, would otherwise leave an empty grid with no on-screen sign a filter is active and no way to clear it (owner-reported bug). Each pill's ✕ removes one (`setActiveTags(TagSelection.removing(…))`); Clear all = `setActiveTag(nil)`. Don't re-add a visibility threshold or scope the bar to in-scope chips.
- **The grid's wholesale-swap `.id` must key on the RESOLVED filter (`tagFilterGeneration`), NOT `activeTagLabels`.** `activeTagPaths.didSet` bumps `tagFilterGeneration` in lockstep with the resolved set; the grid keys on that. (Historically labels and `activeTagPaths` landed in different frames — paths via an async query — so keying the `.id` on labels rebuilt the canvas early and flashed the PRIOR tag's files until the query returned, the switch flicker. `setActiveTags` now resolves synchronously so both land in one frame, but keying on the resolved generation is retained as the correct, gap-proof rule.) And the swap is **`.transition(.identity)`, not `.opacity`** — outgoing/incoming canvas read the same global `visibleFiles`, so a symmetric opacity fade dims two identical layers to ~75% and back (a visible blip, not a real cross-fade — shared state can't give one without snapshotting). `.identity` is required (an `.id` change inside `withAnimation` defaults to `.opacity`); don't "simplify" it away. Tag/collection switches are now an instant replace by design. **Folder switches follow the same rule:** the fresh-select reveal in `reloadCurrentFiles` (the `freshSelect` branch) commits `tagChipRows`/`tagRowReady` WITHOUT `withAnimation` so the new folder hard-cuts in (tab-switch feel), not fade in — don't re-wrap it; the fade was a perceived "lag after click." Files + chips still commit in one `MainActor` transaction so the "images appear already in place below the chips" ordering is preserved.
- **Don't put an AppKit `NSViewRepresentable` inside a SwiftUI `.popover` whose CONTENT SIZE changes at runtime.** The grid filter's tri-state "Images" `NSButton` paired with an expand/collapse disclosure left a stale blurred layer snapshot (ghosting) — the AppKit subview blocks the hosting view's size invalidation. Fix: fixed-size popover (show all format checkboxes always). Keep such popovers fixed-size, or use pure SwiftUI for the dynamic part.
- **A mouse-only modifier interaction has NO VoiceOver equivalent — give it a parallel named `.accessibilityAction`.** VO activation can't reproduce a double-click timing window or Cmd/Shift-click. The grid tile's double-click-open + the tag chip's Cmd-click-add were both VO-unreachable until each got an `.accessibilityAction` routing through the same call the mouse makes. Branch by node kind where the mouse path does (tile open = `selectedFile` for a file but `openSubfolder` for a `.folder`). The right-click `contextMenu` is VO-reachable; a bare gesture is not.

### Session index

The full chronological narrative of every working session (2026-06-12 → present),
branch by branch, lives in **`docs/session-log.md`** — read the relevant dated entry
when you need the full "why" behind a specific change. The load-bearing, must-not-break
rules distilled from those sessions are captured in **Durable constraints & gotchas**
above; the **Architecture map** below is the current-state file index.

## Architecture map

The full file-by-file index lives in **`docs/architecture-map.md`** — read it when
locating where something lives. High-level layout of `Muse/Muse/`:

- **`MuseApp.swift` / `ContentView.swift`** — app entry + NavigationSplitView shell (toolbar, sidebar, grid).
- **`Models/`** — `AppState` (@MainActor singleton; state core + `AppState+*` method extensions), plus the pure value types that drive the UI (`AssetKind`, `FileNode`, `Mood`, `ImageLayout`, `TileBackground`, `GridFilter`, sort modes).
- **`Filesystem/`** — roots/bookmarks, folder tree + reader, FSEvents watcher, folder stats, path reconcile, thumbnails, iCloud sidecars.
- **`Database/`** — GRDB queue + migrations, records, FTS5 + tag search, tag scoping/store, housekeeping.
- **`Localization/`** + `Localizable.xcstrings` — display-time localization (storage stays canonical-English).
- **`Indexing/`** — SHA-256 hashing + the identity-reconciling `Indexer`.
- **`Intelligence/`** — Vision (classify/OCR/color), smart sort, dedup, palette/intent, collections engine, the automatic `AnalyzePipeline`.
- **`Viewers/`** — per-kind viewers + the hero image/video viewers (`HeroPalette`, `FileMetadata`, `Viewer/`).
- **`Views/`** — grid, sidebar (+ `Sidebar/`), collections page, tag chips, popovers, sheets, duplicates, backup wizard.
- **`Components/`** — pure UI math (selection, page-scroll, reorder, escape resolver, masonry geometry) — all unit-tested.
- **`Backup/`** + **`Export/`** — library backup/restore (by content hash) + collection PDF export.
- **`Effects/` / `Settings/` / `Agents/AppIntents/`** — delete fade modifier; settings store + modal; Shortcuts/Siri intents.
- **`Muse.entitlements` / `Muse-Debug.entitlements`** — sandbox + iCloud + Sparkle network; Debug drops iCloud keys.
- **`MuseShareExtension/`** — the "Send to Muse" Finder share extension (separate target).

## Conventions

- **Keep docs lean.** This file is loaded every session — record the durable rule + why in one or two lines, not the full narrative. Per-session detail goes in `docs/session-log.md`; the file index is `docs/architecture-map.md`. Prune as you go; don't let it bloat back up.
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
- **No network calls — with exactly ONE sanctioned exception.** If you reach
  for `URLSession`, stop, UNLESS you're in the **Google Drive share** code
  (`Sharing/Drive/`), the only feature allowed network egress (besides
  Sparkle), and only inside an explicit user action (sign-in / Publish /
  Manage / the expiry sweep). Everywhere else the rule holds: the Markdown
  viewer has no web stack, and the SVG viewer hard-blocks remote loads via a
  `WKContentRuleList` (resource-layer — the nav delegate alone misses
  subresources; see the durable-constraints note); new third-party deps must be
  audited for network surface. Drive uses `drive.file` (least privilege),
  PKCE (no client secret), Keychain-only device-only tokens, and the page
  carries its manifest in the URL fragment (no secrets, no API key).
- **AppState is @MainActor**. So is most of the data layer. Background
  work (hashing, Vision) goes through `Task.detached(priority:)` or
  the `Indexer` actor's queues.
- **SourceKit module errors are noise.** During edits you'll see
  "Cannot find type 'FileNode' in scope" and similar — they're cross-
  file resolution issues that disappear at build time. Always verify
  with `xcodebuild ... build` before assuming something's broken.
- **The app is LOCALIZED — every new user-facing string MUST be localized.**
  Muse ships French (`feat/localization-french`, 346 UI strings in
  `Localizable.xcstrings` + 1303 Vision tag terms in
  `Localization/VisionVocabulary.json`); the infra is language-agnostic. As long
  as more than one language exists, **any new feature/UI text is incomplete until
  it's localized** — treat it like a test you must keep green. Rules:
  - **Storage stays canonical-English; localize at DISPLAY time.** Never persist a
    translated string (DB/FTS/collection rows/tags). AI tag labels render via
    `VocabularyLocalizer.shared.display(label)`; the stored label is the canonical
    English key (also the search/dedup identity). A new Vision-derived label that
    should localize needs a row in `VisionVocabulary.json`.
  - **Compiler extraction ONLY sees SwiftUI text-literal positions** —
    `Text("…")`, `Button("…")`, `Label`, `.help("…")`, `.accessibilityLabel("…")`,
    `Section`, `.navigationTitle`, `.alert` titles, `Toggle`/`Picker` titles. Those
    auto-localize and `xcodebuild -exportLocalizations` extracts them.
  - **Anything passed as a `String` is NOT extracted and will ship in English** —
    AppKit setters (`NSSearchField.placeholderString`, `NS*Panel.prompt/.message`,
    `NSMenuItem(title:)`), custom-view `title:`/`label:`/`text:`/`caption:`/
    `placeholder:` params, `ternary ? "a" : "b"`, string concatenation,
    `enum.displayName`/`label` properties, and method return values. **Hand-wrap
    each in `String(localized:)`** (it auto-extracts once wrapped). For a label
    built from a RUNTIME variable (e.g. `Text(row.label)` where `label` is dynamic),
    use `NSLocalizedString(var, comment:)` and add the keys to the catalog manually.
    This applies to VoiceOver too: `.accessibilityLabel/Hint/Value` built dynamically
    are read aloud and must be wrapped.
  - **Workflow for new strings / a new language:** wrap literals → run
    `xcodebuild -exportLocalizations -project Muse/Muse.xcodeproj -localizationPath
    <dir> -exportLanguage <lang>` (it write-backs every key into the source
    `.xcstrings` — a plain build does NOT) → fill the empty `<lang>` values → it
    reports 0 untranslated when done. Add the language to `knownRegions`.
  - **Longer localized text overflows fixed-width controls** — budget ~1.3× the
    English width; use `lineLimit(1)` + `.truncationMode(.tail)` +
    `.minimumScaleFactor(…)` (or a wider frame).
  - **Don't prune `NSLocalizedString(variable)`-reached keys as orphans.** The
    extractor can't see runtime-variable keys, so `-exportLocalizations` marks them
    `extractionState: stale` even though they're used and DO compile to `fr.lproj`
    (the 14 INFO-card metadata labels — `Taken`/`Camera`/… — are the standing case).
    A genuinely orphaned key is one no longer referenced in code at all; verify before
    deleting.
  - **A concatenation only localizes the wrapped part** — `String(localized: "A ") + "B"`
    ships "B" in English (and a remaining-English grep for `String(localized:` won't
    flag it). Wrap the WHOLE phrase as one key. Same trap: a ternary/`??` whose other
    branch has interpolation forces the `String` overload, so literal branches need
    explicit `String(localized:)`.
  - **Run the unit suite in an English host.** Enum-`displayName`/toast tests assert
    the English source; a per-app French override (`defaults write com.tarrats.Muse
    AppleLanguages '("fr")'`) makes them read French and fail — that's expected, not
    a regression. To preview the app in French, launch with
    `open -n <Muse.app> --args -AppleLanguages "(fr)"` (a one-shot arg, no defaults
    write, so it doesn't pollute later test runs).
  - See the `feat/localization-french` session log for the full design (display-time
    layer, `VocabularyLocalizer` seam, search bridge, three removal kill-switches).

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
