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
- Network policy: **Update-only, plus opt-in publish and two static fetches.**
  No analytics, no telemetry, no data collection. **Four** sanctioned network
  code paths, all gated by `com.apple.security.network.client`:
  (1) **Sparkle** — fetching its signed appcast feed + downloading the update;
  (2) **Google Drive collection share** (`feat/drive-collection-share`,
  2026-06-25) — when the user signs into Google and presses Publish, the
  selected images + form text upload to **the user's own Drive** (OAuth
  `drive.file`, PKCE). This is opt-in + user-initiated; the developer still
  receives no data (bytes go user → their Drive);
  (3) **`announcements.json`** (Spec 01) — one GET of a static file per launch,
  ephemeral session, no body sent, off-able in Settings (which disables the
  fetch itself);
  (4) **the on-demand search-model download** (Spec 03) — only when the user
  accepts the offer, SHA-256 verified before unpack, fail-closed.
  The recipient browser's portfolio `manifest.json` fetch is PAGE traffic, not
  an app path. Nothing else may open a socket. Every Sparkle download is
  EdDSA-verified against the embedded `SUPublicEDKey`. `SUEnableAutomaticChecks = true` so Sparkle checks
  quietly in the background with no UI unless an update exists (the first-run
  consent prompt was removed 2026-06-15 — it was a confusing first launch and
  its modal stole focus from the main window).
  iCloud Drive *document* sync (the optional single "Muse" iCloud folder) is
  mediated by the OS sync daemon and adds only the iCloud Documents
  entitlement. The developer still receives **no data**, so the "Data Not
  Collected" privacy label is unchanged.
- Data collection: **None**. Privacy nutrition label = "Data Not Collected".
- Universal build — **Intel Macs must keep working**; Apple Silicon is the tuning target (owner correction 2026-08-01, superseding the foundation's "Apple Silicon only"). A Debug build compiles only the active arch, so arch-specific code must be verified with `-configuration Release`.
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
| Polish 1 — AI brain (protocols, semantic search, living collections) | ✅ shipped | `feat/ai-brain` |
| Polish 2 — hero viewer (adaptive wash, info cards, zoom/pan, delete+undo) | ✅ shipped | `feat/hero-viewer` |
| Polish 3 — spatial views (cloud + graph; globe retired) | ✅ shipped | `feat/spatial-views` |
| Polish 4 — delights (burn-up delete, background moods) | ✅ shipped | `feat/delights` |
| Polish 5 — cloud 3D orbit ball + galaxy view | ✅ shipped | `main` |
| Polish 6 — screenshot intent collections + Galaxy taste-map | ✅ shipped | `main` |
| Polish 7 — grid virtualization + thumbnail prewarm; cloud/galaxy removed | ✅ shipped | `main` |
| Polish 8 — iCloud sync folder (`.muse` sidecars) + macOS share + "Send to Muse" extension | ✅ shipped | `feat/icloud-sync-share` |
| Polish 9 — Page Up/Down grid scrolling (Fn+Arrow) | ✅ shipped | `feat/page-scroll` |
| Polish 10 — collection → paginated 11×14 PDF share | ✅ shipped | `feat/collection-pdf-share` |
| Polish 11 — grid multi-select + actions, drag-to-move, Reveal in Finder, native search field | ✅ shipped | `feat/multi-select` |
| Polish 12 — folder ops (new subfolder + rename w/ migration) + hero Share/Open-With dropdown + Info modal | ✅ shipped | `feat/folder-ops-and-share` |
| Polish 13 — tile background (global grid backdrop) + PDF export reflects the grid | ✅ shipped | `feat/next-22` |
| Polish 14 — Duplicates modal redesign (tile selection, KEEP badge, never-delete-a-whole-group) | ✅ shipped | `feat/next-23` |
| Polish 15 — synchronized toolbar-icon recolor on mood change | ✅ shipped | `feat/next-24` |
| Polish 16 — accessibility pass (VoiceOver, icon-button labels, `CollectionCard` rework) | ✅ shipped | `feat/next-25` |
| Polish 17 — iCloud collection share | ❌ **REMOVED 2026-06-25** — no API to mint a public iCloud link; Drive (P18) is the real path, do NOT re-add | `feat/icloud-collection-share` |
| Polish 18 — **Google Drive collection share** (OAuth `drive.file`/PKCE → upload to user's Drive → branded share page; metadata-stripped, fail-closed). See Drive security invariants in Durable constraints. | ✅ shipped | `feat/drive-collection-share` |
| Polish 19 — **Import Keywords & Ratings** (read IPTC/XMP from Lightroom/Bridge → manual tags + ratings) + "XMP Sidecars" filter row | ✅ shipped | `feat/next-125` |
| Polish 20 — **Collection icon + color** (sidebar; `v10_collection_appearance`) | ✅ shipped | `feat/next-128` |
| Polish 21 — **Per-file Note** (hero viewer; `notes` table, `v11_file_note`) | ✅ shipped | `feat/next-129` |
| Polish 22 — **Collapsible Colors card** (hero viewer; global last-choice) | ✅ shipped | `feat/next-130` |
| Polish 23 — **Color search** (hex/palette token → perceptual CIEDE2000 match on `palette`) | ✅ shipped | `feat/next-133` |
| Polish 24 — **Smart collections** (rule-driven live membership; `v12_smart_collections`) | ✅ shipped | `feat/next-134` |
| Polish 25 — **Analysis performance** (bounded Vision raster, sRGB colour fix, single decode, concurrent pass, exact vectorized clustering, recluster gate, size-aware thumbnail permits) | ✅ shipped | `feat/next-140` |
| Polish 26 — **Grid layout modes** (Columns/Rows/Grid; tile card + Tile Background deleted; spacing slider; one orientation truth) | ✅ shipped | `feat/grid-layout-modes` |
| Polish 27 — **UI polish batch** (emoji collection symbols; sort-direction menu; menu icons + shortcuts; toolbar Settings; tag/collection autocomplete; compact star badge; sidebar geometry/colour rework; scope-bar-over-viewer fix; duplicate-root fix) | ✅ shipped | `feat/next-142` |
| Polish 28 — **visual polish pass** (collection glyph → `rectangle.on.rectangle.angled`; smaller section headers + intrinsic sort glyph; Lineform selection fill; hero open bounce + staggered close converge; grid margins track spacing; one “+ Create New” menu) | ✅ merged, unreleased | `feat/collection-icon-cards` |
| Foundation 1 — **Spec-01 foundation & plumbing** (v13 coordinates + backfill; the three edit-aware seams `EditStackIndex`/`EffectiveDimensions`/`OutputRender`, all identity functions today; StoreKit 2 plumbing with an UNENFORCED trial gate; announcements channel; semantic-search cancellation + `PerfBaseline`) | ✅ merged, unreleased | `new-product-build-1` |
| Foundation 2 — **Spec-02 photo library core** (v14–v17; `PhotoHeaderReader` one-pass GPS+EXIF; offline GeoNames reverse geocoding + Places page; rediscovery surfaces; near-duplicate stacks; phase-1 token search; `.location` smart rule; dead visual-duplicate fix) | ✅ merged, unreleased | `new-product-build-1` |
| Foundation 3 — **Spec-03 culling & search phase 2** (v18–v19; CLIP engine/index/model-store; faces/pets/`is:`/`similar:` tokens; compare workbench + focus peaking; ephemeral cull; `.similar` smart rule; NL suggestions) | ✅ merged, unreleased | `new-product-build-1` |
| Foundation 4 — **Spec-04 editing engine** (v20–v21; platform-neutral `Editing/` model + codec + history + transfer; Core Image/Metal render chain; `EditStore` + live provider + consumer sweep; (Preview \| Edit) editor in the hero viewer; curve, WB eyedropper, before/after, versions, presets, copy/paste, Edit-a-Copy) | ✅ merged, unreleased | `new-product-build-1` |
| Foundation 5 — **Spec-05 editing readouts & learning layer** (v22–v23; live stats tap → teaching histogram + plain-English clipping copy; zebras; the tone-zone control + zone overlay; deterministic "Why it looks this way"; `.cube` LUT import; live-thumbnail Looks browser; reference pane) | ✅ merged, unreleased | `new-product-build-1` |
| Foundation 6 — **Spec-06 import & migration** (no migrations; one File > Import surface over five sources; `ImportSupplement`; color-label namespace + mapping sheet; Lightroom `crs:` edits + presets; `WorkThrottleStore`/`AnalysisStatusStore`/import-size FYI) | ✅ merged, unreleased | `new-product-build-1` |
| Foundation 7 — **Spec-07 sharing & social export** (no migrations; manifest v2 `y`/`s`/`m` + three page layouts; portfolio mode — a live `manifest.json` in the user's Drive behind a URL that never changes; `Export/Social/` + the social export card; Google on-ramp copy) | ✅ merged, unreleased | `new-product-build-1` |

| Polish 31 — **editor adjustments batch** (the two orphaned halves — crop/straighten/rotate/flip UI and the vignette card — plus auto-tone, HSL/COLOR MIX, split toning and grain; three appended `Adjustment` cases at 8/9/10, no migration, no version bump) | ✅ merged to `main` 2026-08-02 (`ceaea7e`), unreleased; unit-tested (1,952) + reviewed (round 10, 6 bugs fixed); **runtime PARTIAL — see FEATURE-LEDGER Part 3** | `feat/next-151` |

| **Review — Specs 01–07** | ✅ reviewed + fixed 2026-08-01 (7 rounds) | `new-product-build-1` |
| Polish 29 — **General image export** (one card, two preset families: Format — Same-as-original/JPEG/PNG/TIFF 8&16-bit/HEIC/WebP — above Spec 07's 12 Social presets, plus saved presets; quality, resize with never-upscale, EXIF/location toggles; `ExportPipeline` shared with `SocialRender`; real `.tiff16` at last; WebP via a statically-linked `libwebp`, the app's **first bundled binary dependency**; no filename controls and **no overwrite, ever**) | ✅ built + tested; **card runtime-verified** (XCUITest drives it — opens from grid/hero/editor, size fields, live estimate, format menu, social preset; plus owner review of the layout 2026-08-02). **A full export-to-disk run is still unconfirmed** — no test writes a file and picks it up. | ✅ merged to `main` 2026-08-02 (`c2e5f95`), unreleased |
| Editor UX pass — **Edit becomes the Preview page in a second mode** (shared cards/chrome/margins; zoom + pan + pinch in Edit, which had none; Side by Side actually renders; editor modals hoisted above the viewer; Scopes→Histogram, Looks→Styles, Insights, INFO dropped; versions folded into snapshots; Styles grid/list + Original + applied-preset detection; `PanelContrast` resolves every editor colour against WCAG AA) | ✅ merged 2026-08-02 (round-8 reviewed), unreleased | `testing-new-features` |
| Polish 30 — **owner UI pass** (export readouts regrouped + `≈` dropped; social crop-drag removed for an automatic centred crop; aspect-lock fills when on; context-menu icons everywhere; smart collections finally draw their cover pile; window minimum + non-overlapping hero fit; blue edit badge; sidebar chevron takes the selection ink; pager hover; **live-resize work on both viewer stages** — Preview fixed; Edit rebuilt so the canvas is sized to the image, see below). **Two features REMOVED on owner call: culling and the editor's reference photo.** | ✅ merged to `main` 2026-08-02 (`c2e5f95`), unreleased | `feat/next-150` |
| Polish 32 — **HDR gain maps** (one `HDRDecode` seam; 10-bit PQ HEIC thumbnail cache; headroom through the edit chain; headroom-aware histogram/clipping; byte-copy unedited exports + gain-map HEIC on macOS 15+; audit check HDR-1) | ✅ built + tested (2,002), **runtime OPEN** — needs a real gain-map HEIC on an EDR display, plan in `FEATURE-LEDGER.md` | `feat/next-153` |
| Polish 33 — **editor workspace** (the 12 cards become a persisted per-column ordered list + hidden set; View ▸ Editor Workspace ▸ Default Layout / Customize Modules / Reorder Modules; drag-reorder within and across columns reusing the sidebar's `ReorderMath`; **single column is NOT a mode** — it's the state where a column is empty; canvas insets follow the cards while the chrome row stays pinned; `EditorView` 1,682 → 656 lines) | ✅ built + tested (2,083), audit 15/15; **runtime BLOCKED** — the drive suite can't run on this machine (pre-existing), nothing has been seen working; per-item check-list in `FEATURE-LEDGER.md` Part 4 | `feat/next-155` |

> **Polish 29 + 30 were MERGED TO `main` on 2026-08-02** (fast-forward from
> `feat/next-150`, tip `c2e5f95`) and are **not in any release** — `v1.5` still
> predates everything from Foundation 1 onward. Verified at the merge: Release
> build warning-free, `MuseTests` 1,870, `MuseSurfaceDriveTests` 12/12,
> `MuseExportDriveTests` 7/7, `audit-invariants.sh` 14/14.
>
> **Polish 31 was MERGED TO `main` on 2026-08-02** (fast-forward from
> `feat/next-151`, tip `ceaea7e`), also unreleased. Verified at the merge:
> Release build warning-free, `MuseTests` 1,952, 0 untranslated,
> `audit-invariants.sh` 14/14. **Its runtime state is PARTIAL and the open check
> is specific** — the crop card has never been driven on a ROTATED photo, which
> is exactly where review round 10's coordinate-space fix lives
> (`docs/new-build/FEATURE-LEDGER.md` step 6b). Unit tests cover all four turns
> and both flips; nobody has watched it happen.
>
> **The editor canvas is SIZED TO THE IMAGE'S FITTED RECT, and that is
> load-bearing (2026-08-02).** It used to span the window and re-fit internally,
> converting panel insets from points to drawable pixels with a `pixelScale`
> read off the drawable — which lags the bounds during a live resize, so that
> scale was wrong on most frames (measured 3.32 vs 2.0) and the photo jumped.
> Now `EditorCanvasGeometry` owns the geometry in POINTS, zoom scales the view's
> frame and pan moves it, and the renderer only fills whatever drawable it is
> handed. **The invariant: the view's aspect equals the image's aspect and never
> changes on resize**, so a lagging drawable is a correctly-SHAPED texture and
> `contentsGravity = .resizeAspect` maps it exactly — only resolution differs,
> for one frame. Verified by trace: geometry error went from 3× to ±0.3%, and
> stale frames now measure the same aspect range as fresh ones.
> `EditorCanvasGeometryTests` pins the aspect invariance, the
> zoom-past-the-panels behaviour, and the point mapping. **Don't put the canvas
> back to spanning the window, and don't reintroduce a point→pixel conversion in
> the renderer.** Two consequences worth knowing: the eyedropper and the EV
> hover were sampling the wrong pixel whenever panels showed (they fitted
> against the whole window while the renderer fitted against the free rect) and
> are now correct; and `CanvasPointMath` is deleted, since nothing re-derives
> fit/zoom/pan any more (`WBEyedropper` moved to its own file). Also here:
> `EditSession.proxyLadder` quantizes the preview proxy, because a continuous
> size rebuilt it — decode plus full edit-stack render — on every pixel of drag.
>
> **Two more features were DROPPED on owner review 2026-08-02, on `feat/next-150`:
> culling (Spec 03) and the editor's reference photo (Spec 05).** Both are fully
> deleted — stores, views, key hooks, badges, tests and 20 strings. Cancelled,
> not gaps; do not re-file or re-add. **Culling**: marking rejects and trashing
> them at Finish is what select + Move to Trash already does, and Muse's persona
> is a generalist with a Downloads folder, not someone working a 2,000-frame
> shoot. Note what went with it — the ONLY bulk keyboard rating path in the app
> (the resolve card's "rate the keepers"); the grid still has no number-key
> rating. Spec 03 deviation D8 (Escape must not end a cull session) is moot.
> **Reference photo**: the editor's row was `isEnabled: referenceStore.url != nil`
> with a tooltip reading "Right-click a photo in the grid → Use as Reference
> Photo" — a permanently-disabled control advertising a gesture in another view.
> Before/after and Side by Side cover comparison; "show me ones like this" is
> already `similar:` search via right-click ▸ Find Similar Photos, which writes
> a removable token into the real search field.
>
> The **Editor UX pass** and the two feature-removal commits before it were
> merged to `main` on **2026-08-02** (fast-forward from `testing-new-features`),
> reviewed in round 8 — see `docs/new-build/REVIEW-LENSES.md` and the 2026-08-02
> session-log entry. Not in any release.
>
> Every row through Polish 27 is merged to `main` and shipped in release **`v1.5`**;
> Polish 28 is merged to `main` but NOT yet in a release (`v1.5` is still the
> current released build; Polish 25–27 landed in it after `v1.4`). **Foundation 1–7
> (Specs 01–07) were MERGED TO `main` on 2026-08-01** (fast-forward from
> `new-product-build-1`, tip `d0f2e52`) and are **not in any release** — `v1.5`
> predates all of them, so `main` is now well ahead of what ships. All seven
> were built 2026-07-31; migrations run through **v23**, so the next spec starts at
> v24. **They have since been reviewed in six rounds** (all 2026-08-01):
> round 1 (`docs/new-build/REVIEW-FINDINGS.md`) — ten systematic sweeps, eight
> slices, 23 findings fixed, suite 1,748 → 1,775; round 2
> (`docs/new-build/FEATURE-LEDGER.md`) — regression of the PRE-branch features
> under this branch's three new seams, 4 findings fixed, suite → 1,783; round 3
> — closed the two gaps round 2 recorded rather than fixed, suite → 1,795; round 4
> — lenses rounds 1–3 hadn't run (SQL construction, crash-on-user-data, resource
> lifecycle, remote-body bounds), 4 findings fixed, suite → 1,802; round 5
> — lenses rounds 1–4 hadn't run (time-zone correctness of SQL date parts, path
> prefixes, Unicode normalization, comparator ordering, transaction atomicity,
> task-group bounds), 2 findings fixed, suite → 1,806; round 6
> — lenses rounds 1–5 hadn't run (arithmetic traps on file-declared numbers,
> untrusted metadata → filesystem path, bounds on the model download's PAYLOAD
> leg, local log leakage), 4 findings fixed, suite → 1,818 (now **1,811** — the 7
> `RegionMathTests` went with the dropped Spec 03 §5 feature, plus **20 UI tests**); round 7
> — changed the METHOD instead of adding a seventh set of angles, because six
> rounds of inventing fresh lenses had no exit criterion. **Read
> `docs/new-build/REVIEW-LENSES.md` before starting any review**: it lists every
> lens ever run plus the ones not yet run, so a round means "run the registry",
> and static review is DONE when the unrun list is empty and the audit is green.
> **Run `./scripts/audit-invariants.sh` (15 checks, all negative-tested) before
> any commit** — it mechanizes the durable rules a grep can enforce (AV
> no-network, QuickLook exclusion, the four network paths, remote-body bounds,
> `Int(exactly:)`, trash-not-unlink, the `OutputRender` choke point, decode
> budgets, Debug entitlements, `Editing/` neutrality, `Float16` arch guard, HDR hard-clip). It
> is a shell script, NOT an XCTest, on purpose: an in-suite grep test SKIPS here,
> since the test host is the sandboxed app and this checkout is in `~/Documents`.
> Round 7's one real finding: **Spec 03 §5 "region similarity" was specified and
> never built** — the branch's third "testable half lands, UI never does" gap
> (after the grid cull badge and the missing Escape branches). **The owner DROPPED
> the feature 2026-08-01** and its orphaned helper `RegionMath` was deleted:
> whole-photo Find Similar already ships and named things are reachable by
> typing them, so region mode only covered visual qualities with no word. Spec 03
> §5 is cancelled — don't re-file it as a gap. **Two more Spec 02 features were
> dropped 2026-08-01 on owner review of the running app**: the LIBRARY sidebar
> section (Places / On This Day / Rarely Seen / Shuffle — never approved, not in
> the spec) and near-duplicate stacks (the tile badge was unwanted). Both are
> fully deleted, tests and strings included; the geocoding under Places stays for
> `near:`/`in:`/`.location`, and migrations v15–v17 stay in the append-only chain
> with their tables unused. Cancelled, not gaps. Still
> true, though, that almost none of it
> has been exercised in the RUNNING app — launch, migrations and the backfill
> chain were confirmed with `MUSE_TRACE=1` against the real library, but the
> editor, compare, import, share and backup surfaces need someone to drive
> them. **`docs/new-build/FEATURE-LEDGER.md` is the standing feature × verification
> ledger** — one row per feature area with separate automated / static / runtime
> states, and the Runtime column doubles as the written GUI test plan. Read and
> update it with any feature work. **G1 (nobody has driven the GUI) is now
> PARTIALLY CLOSED** — `MuseUITests/MuseSurfaceDriveTests.swift` drives the real
> app and confirms by screenshot that the editor, Spec 05 readouts, compare,
> duplicates, all five import panels, backup and settings open and respond,
> and that every modal honours Escape. **Drive the GUI with XCUITest, not
> osascript**: the test runner carries automation rights, while a terminal needs
> Automation/Accessibility TCC permission and is otherwise refused (-1743). Two
> traps it caught in its own tests: a UI test asserting only "the window exists"
> passes while doing nothing (the hero test pressed Return, which merely selects
> — `handleTileTap` opens on DOUBLE-click), and on the ragged masonry grid a
> click between tiles clears the selection, so click tile CENTRES measured from a
> real screenshot. **Still open:** feature correctness (no slider moved, no render
> compared), social export, Drive publish, restore/delete, and running an import
> to completion. Also **quit all but one Muse instance
> before driving it**, since GRDB's `busyMode` is `.immediateError` and two
> instances against one DB manufacture phantom "my edit didn't save" bugs.
> Everything else the reviews recorded
> is closed: localization is COMPLETE (1,002 keys, 0 untranslated), **backup now
> carries edit data** (Spec 09 amendment A2 — stacks, versions, presets and LUT
> bytes ride `.muselibrary`), and the **442 Swift 6 concurrency warnings are
> gone — the Release build is warning-free, keep it that way**. The binding
> build-level record is
> `docs/new-build/DECISIONS.md` — but treat it as a decision ARCHIVE ("why X was
> chosen"), NOT as status: its volatile-facts block was deleted 2026-08-01 after
> going stale three ways, and its "as built" and Spec 08/09 sections are labelled
> in place as historical or never-built. Current facts live in THIS file and in
> `FEATURE-LEDGER.md`. **Distribution is
> unchanged** — the Mac App Store move (doctrine revisions, Sparkle excision,
> Apple-Silicon-only build settings) was split out of Spec 01 at the owner's
> request into `docs/superpowers/plans/deferred-mac-app-store-migration.md` and
> has NOT been run: the app still ships direct with Sparkle, and the StoreKit
> plumbing is inert scaffolding until it does. Polish-row detail (the full
> "why/how" per feature) lives in `docs/durable-constraints.md` and, in full, in
> `docs/session-log.md` under each cited branch. Keep new rows to one line here;
> put the narrative there.

Each feature has its own spec + plan in `docs/superpowers/`; all are merged to
`main`. `feat/file-viewer-rewrite` was merged after Phase 8 and kept as an audit
trail of the per-phase progression. The current release tag is `v1.5`.

## Session history

The full chronological narrative of every working session (2026-06-12 → present),
branch by branch, lives in **`docs/session-log.md`** — read the relevant dated
entry when you need the full "why" behind a specific change. The load-bearing,
must-not-break rules distilled from those sessions live in
**`docs/durable-constraints.md`** (pointer + the critical dozen below); the
**Architecture map** further down is the current-state file index.

### Durable constraints & gotchas (DO NOT BREAK)

**The full set of 187 rules lives in `docs/durable-constraints.md`. READ THE
RELEVANT SECTION BEFORE ANY NON-TRIVIAL CHANGE** — each one is hard-won, and
re-introducing it re-introduces a shipped bug. Sections there:

> Network egress & viewer security · Google Drive share & the share page ·
> Export & the output choke point · Import & migration · Editing engine · Photo
> metadata, geocoding & stacks · Indexing & file identity · iCloud sync &
> sidecars · Tags, ratings & notes · Search · Analysis pipeline · Thumbnails &
> decode budgets · Grid & layout · Hero viewer · Sidebar · Collections · Modals,
> toolbar & menus · SwiftUI patterns, animation & AppState · Filesystem, roots &
> sandbox · Selection, duplicates, App Intents & accessibility · Working practice

Full repro/why for each is in `docs/session-log.md` under the cited branch. The
four most critical are also Claude memories (linked below).

**Drive share security (summary — the full invariant list is the longest single
rule in `docs/durable-constraints.md` § Google Drive share; read it before
touching `Sharing/Drive/`):** scope is EXACTLY `drive.file`; OAuth is PKCE with
NO client secret; tokens live only in Keychain (device-only, never synced); the
share page carries no secret and no OAuth credential; **every uploaded image is
metadata-stripped and re-verified clean, fail-closed** (a file that can't be
verified aborts the whole publish); network happens ONLY inside an explicit user
action. Don't relax any of these.

The rest of these twelve are kept inline because breaking one means data loss,
network egress, or a permanent delete:

- **The SVG viewer's no-network guard is a `WKContentRuleList`, NOT the nav delegate.** `WKNavigationDelegate.decidePolicyFor` fires ONLY for frame navigations, never subresources — so an attacker-supplied `.svg` with `<image href="https://…">` / `<use href>` / `<feImage>` / CSS `url()`/`@import`/`@font-face` leaked the viewer's IP on mere preview (a real shipped privacy bug — JS-off does NOT stop these passive loads). Fix lives in `SVGViewerView`: a content rule blocks `https?://`, `wss?://`, and host-bearing `file://[^/]` (the protocol-relative `//host` trick) at the *resource* layer; the file load is **deferred until the rule installs** and **fails closed** (don't render) if it can't. Don't "simplify" this back to nav-delegate-only or load before the rule — verified live (a remote `<image>` egress beacon stays unhit while the SVG still renders).
- **Every AVFoundation asset MUST be built via `AVURLAsset.noNetwork(url:)` / `AVPlayer.noNetwork(url:)` (`AVURLAsset+NoNetwork.swift`), NEVER bare `AVURLAsset(url:)`/`AVPlayer(url:)`.** A QuickTime *reference movie* (`rmra`/`rdrf` remote data-ref atom) or an HLS playlist can point a track at a remote URL; without `AVURLAssetReferenceRestrictionsKey = .forbidAll` AVFoundation resolves it on open, beaconing the viewer's IP — and video assets open on mere FOLDER OPEN (thumbnail prewarm) + hero/metadata, so a planted file leaks with no click. `.forbidAll` is inert for legit self-contained local files. **Relatedly, neither a video NOR an AUDIO file may reach QuickLook** (`QLThumbnailGenerator`/`QLPreviewView`): QuickLook's own out-of-process AVFoundation is UNRESTRICTED, so `ThumbnailCache.generate` returns an `NSWorkspace` type icon (not the QL fallback) for a `.video` whose restricted `videoFrame` failed, and `CollectionPDFExporter` frame-extracts videos via `.noNetwork` (never `quickLookThumbnail`). `ViewerRouter` routes `.video`/`.audio` to the restricted players, never `QuickLookFallback`. Don't add a new AV entry point or a video→QuickLook fallback.
- **The QuickLook exclusion covers AUDIO too, and is enforced by `ThumbnailCache.mayUseQuickLook` (2026-07-28).** The video rule stopped at `kind == .video`, but `.m4a` (and the rest of the MPEG-4 family) is the SAME ISO-BMFF/QuickTime container that carries an `rdrf` remote data reference — and audio fell straight through both thumbnail paths (`ThumbnailCache.generate` and `CollectionPDFExporter.fallbackThumbnail`) into QuickLook's unrestricted out-of-process AVFoundation. Thumbnails run on mere FOLDER OPEN, so a planted `.m4a` beaconed with no click: exactly the egress `.noNetwork` closes, through the neighbouring kind. Audio now reads embedded cover art through the reference-RESTRICTED asset (`audioArtwork` / `restrictedAudioArtwork`, bounded by `withinDecodeBudget` so a huge embedded cover can't OOM), falling back to the static type icon — so artwork tiles survive without handing the file to QuickLook. The rule is a predicate both sites consult, not a comment asking callers to behave; a NEW AVFoundation-backed kind must be added to it.
- **Everything that leaves the app goes through `OutputRender` (2026-07-31).** PDF export, Drive publish, and both share-sheet paths take a `RenderedOutput`, never a bare `URL`; `RenderedOutput`'s `fileprivate` init is the enforcement — a new export/share/publish path physically cannot compile without going through the choke point. It's an identity function today (originals pass through unrendered); Spec 04 renders the edit stack in that ONE place and every call site is already correct. Don't relax the init, don't add a public one, and don't let a new path take a `URL`. The Drive path renders FIRST and strips SECOND (`ImageMetadataStripper.strip(_:mime:)`), so no future edit can reintroduce metadata past the stripper. **Backup is the one deliberate exclusion** — it restores originals matched by content hash, and baking edits into the archive would corrupt the restore (noted in `BackupBuilder.swift` too, so the exclusion is findable from either direction). Non-rendering fallbacks (a video frame, a QuickLook type icon) legitimately keep taking a `URL` — they carry no edit stack.
- **Image decode is bounded by `ThumbnailCache.withinDecodeBudget` (300 MP header check) at every AUTOMATIC (no-click) full-raster decode site** — grid thumbnail (`imageIOThumbnail`), hero full-res, and the auto-analysis pipeline (`PaletteExtractor.downsampledRGB`, `VisionServices.loadCGImage`, `CollectionPDFExporter.imageIOThumbnail`). A tiny file can declare enormous dimensions (a few-KB PNG at 40000×40000 ≈ 1.6 Gpx); formats ImageIO can't stream-downsample (PNG/TIFF/BMP) materialize the full raster → OOM on folder open (prewarm) or on index (auto-tag). Header-only pre-check, overflow-safe, missing-dims→allow. A NEW auto-triggered decode of a user file must call this guard.
- **`Housekeeping.pruneUnreachable` is a PERMANENT DELETE — it must fail closed on root visibility (2026-07-03).** The launch call site skips the prune unless EVERY persisted bookmark root resolves (an unplugged volume / stale bookmark would read as "unreachable" and purge its whole subtree), and the iCloud "Muse" root — never a bookmark root — is resolved directly and passed via the `icloudRoot` param; when THAT can't resolve (signed out, Debug build), any `/Mobile Documents/` path is protected wholesale. Same guard class as `PathReconciler.rootReachable`, stricter because rows don't come back. `HousekeepingTests` pins all of it.
- **`PathReconciler.reconcileByExistence` MUST fail closed on an unreachable root.** It clears deep ghost `is_alive` rows a browsed-depth `reconcile` can't reach (files whose whole subfolder was deleted — e.g. leftover `Documents/Shared Collections/` copies from the removed iCloud-share feature) by per-file `fileExists`, dataless-safe. But if the ROOT is transiently unreachable (unplugged volume, un-materialized iCloud container on cold launch, stale bookmark) EVERY child reports gone → the whole subtree would mass-flip `is_alive=0`, and it runs PROACTIVELY at launch on every root incl. the never-selected iCloud one (deep files it kills are never revived by browsing). The `rootReachable` gate (`contentsOfDirectory` succeeds) is load-bearing — returns `ExistenceResult(reachable:false)` and touches nothing when the root can't be listed; the caller releases its once-per-launch `existenceReconciledRoots` claim on `!reachable` so it self-heals on a later rebuild. Don't remove the gate, and keep it FIRE-AND-FORGET (`Task {…}`) off the grid's critical path — awaiting the full-subtree stat sweep stalls the folder-load publish (`PathReconcilerTests.testReconcileByExistenceBailsClosedOnUnreachableRoot` guards this).
- **A shared `files` row must SPLIT on edit-in-place, never be rewritten.** Two byte-identical files in different folders dedupe onto one `content_hash`-UNIQUE row. `Indexer.reconcile`'s edit-in-place branch only rewrites the row in place when it's the SOLE alive path; when >1 alive path shares it, it splits (new row for the edited path, carrying that location's tags AND its manual collection memberships) so the untouched sibling isn't corrupted and the two copies don't ping-pong the shared hash. Don't collapse the split branch back into an unconditional in-place update (`IndexerReconcileTests` guards both directions + the membership carry). **The hash-COLLISION edit branch (new bytes match a different existing row) follows the same rule** (2026-07-03): when the old row is shared, only THIS path's folder-scoped tags carry to the target (copy-vs-move by the same same-dir-sibling rule) and manual memberships copy — an unscoped `unionTags` stripped the untouched sibling's tags. `unionTags(parentDir:deleteOriginals:)` is the scoped seam; +3 collision tests guard it.
- **A control that writes into the edit stack must work in the RENDERER's coordinate space, not the screen's (2026-08-02).** `EditRenderer.applyGeometry` crops FIRST and then flips and quarter-turns, so `GeometryParams.crop` is in SOURCE coordinates — while the editor shows the photo with those turns already applied. The crop overlay stored what the user drew straight into `crop`, so rotating a landscape photo 90° and cropping the top of what you see stored the LEFT band of the original. `CropDragMath.sourceRect(fromDisplay:)` / `displayRect(fromSource:)` / `displayAspect(source:quarterTurns:)` are the conversion, applied at every boundary (Apply, preset fitting, the aspect lock, re-entry) and round-tripped in tests over all four turns × both flips. The general rule: before a new control writes a value the render chain later interprets, check it against that chain's ORDER of operations. A duplication sweep cannot find this class — there is only ONE calculation, in the wrong frame of reference.
- **Only one thing may own the editor canvas at a time (2026-08-02).** Crop, the compare modes, the WB eyedropper and tone-zone targeting all claim it, and side-by-side makes the canvas twice as wide as the photo (`EditorCanvasGeometry.contentAspect`) — so a crop frame drawn over it spans both panes and maps to nothing real. Each of the four clears the others in `didSet`; the guards are one-directional so they cannot recurse.
- **Tags are per `(file_id, parent_dir)`**, not per content hash. A duplicate in another folder has its own tags; deletes never leak across folders; NO library-wide tag delete. Other content-derived metadata (palette/caption/dims/intent/feature-print/FTS) stays content-hash-keyed. Memory: `muse-tags-are-per-file-not-per-content-hash`.
- **iCloud container is data-loss-sensitive.** Debug builds sign with `*-Debug.entitlements` (production minus the three iCloud keys) so dev churn can't make `bird` purge the production ubiquity container. Ship updates via **Sparkle only** (atomic in-place swap preserves identity) — never tell users to drag a new DMG over the old app.
- **Grid must stay virtualized.** No custom SwiftUI `Layout` or non-lazy container over the full file set — it materializes every tile + relayouts O(n) per publish (1700-image folders died). Use `MasonryGeometry` frames + a manual viewport window. Memory: `muse-grid-must-stay-virtualized`.
- **Fix the code, not the dev DB.** The user's library is a disposable fixture; never ship one-off migrations to patch a corrupted local DB — fix forward code, validate by clean re-index. Memory: `muse-fix-code-not-my-data`.

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

- **Keep this file lean — it has a hard context budget and blew past it once (2026-08-01, 157 KB).** It is loaded every session. A new durable rule goes in `docs/durable-constraints.md` under its section, NOT here; inline it here only if breaking it means data loss, network egress, or a permanent delete. Per-session narrative goes in `docs/session-log.md`; the file index is `docs/architecture-map.md`. Prune as you go; don't let it bloat back up.
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
- **Editing is non-destructive and in-app for `.image`/`.raw` only (Path A).**
  The (Preview | Edit) editor lives inside the hero viewer; the stack is
  parameters in `edits`, never modified pixels — Muse still never writes over a
  user's file. Everything else (`.psd`, video, documents) is Path B: Open With…
  (`NSWorkspace.shared.open(url, withApplicationAt: ...)`), and a file that
  carries Muse edits forks through `OpenWithFork` (Edit Original / Edit a Copy)
  rather than silently handing over the unedited original.
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
- **`BUILD SUCCEEDED` is NOT proof the running app has your change — `stat` the
  binary's mtime before handing the owner a build to look at.** An incremental
  `xcodebuild` can print success while the `.app` executable stays weeks old (a
  stale *signed* copy of the embedded share extension in DerivedData fails
  codesign; the full log says `Embedded binary is not signed with the same
  certificate` → `BUILD FAILED`, the filtered/incremental path does not). Cost a
  whole session of visual iteration against a three-week-old binary once
  (2026-07-28) — every round of owner feedback judged code that never ran. Fix is
  `rm -rf` the built `Muse.app` and rebuild; signing settings and certs are fine,
  don't touch them.
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
3. Toolbar — controls left-aligned, **search alone at the far right** (native
   `.searchable`, collapses to a magnifier on a narrow window). Order (left →
   right): sidebar toggle · **[sort · sort-direction · filter]** · tag-sort ·
   show-subfolders · **[Collections · Image Layout · Manage Drive Links]** ·
   background mood · **[About · Settings]** · search. The two bracketed clusters are grouped glass capsules on macOS 26.
   Full plumbing (two-variant Tahoe/Sequoia builder, why sort's `.menuIndicator`
   is `.hidden`) is in the ToolbarSpacer durable constraint. Find Duplicates and
   Import Keywords & Ratings… are in the File menu; Pin/Unpin + Remove Folder in
   the Edit menu; analysis runs automatically.
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
  unit-tested. Run with `xcodebuild -scheme Muse test -only-testing:MuseTests`
  (~40 s); keep it green. **Scope the run to the change** — while iterating use
  `-only-testing:MuseTests/<TheAffectedTests>`, take the whole unit target at a
  checkpoint, and reach for `MuseUITests` only when the claim needs the running
  app (each of those launches Muse and costs minutes). Plain
  `xcodebuild -scheme Muse test` runs BOTH targets. See the test-tier rule in
  `docs/durable-constraints.md` § Working practice.
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
