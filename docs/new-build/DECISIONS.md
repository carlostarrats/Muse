# DECISIONS.md — binding decisions from Specs 01–09

*Extracted 2026-07-30 from `spec-01-implementation.md` through
`spec-09-implementation.md` (the build-level specs, which supersede the corresponding
`pre-spec-*` files where they deviate), verified against the codebase at `cefa008`
(`feat/editing`). **Note:** as of that commit no Spec 01–09 code exists in
the tree — migrations end at `v12_smart_collections`; the implementation specs are the
settled record, written before build. Product-level decisions live in
`muse-photo-foundation.md` §13 (authoritative decision log); this file is the
build-level layer future specs must not contradict.*

*Updated 2026-07-31: **Specs 01–07 are built** (branch `new-product-build-1`), so
the "no Spec 01–09 code exists" note above no longer holds for them. Migrations
run through **v23** (Specs 06 and 07 added none); future specs continue at v24. The
"as built" / "as-built" sections below record what shipped, including where each
deviates from the pre-build record; where the two disagree, the as-built section
wins.*

---

## Current state — read this first

*The facts in this block CHANGE as specs land, so they are stated here ONCE and
nowhere else. **This block outranks every other section, including the "as-built"
ones** — those are point-in-time snapshots written by the spec that shipped them and
go stale the moment the next spec lands. Verified against the tree 2026-07-31 after
Spec 07. A spec that changes any of these updates THIS block rather than restating
it in its own section.*

- **Next migration version: `v24`.** The chain ends at `v23_edit_luts`. Per spec:
  v13 (01) · v14–v17 (02) · v18–v19 (03) · v20–v21 (04) · v22–v23 (05) · none (06, 07).
  Note `v22_photo_stats` ALTERs the existing `photo_traits` table rather than creating
  one, despite the name.
- **App-initiated network paths — three states, don't conflate them.** Today (Specs
  01–07 built): (1) Sparkle update check, (2) Google Drive publish, (3)
  `announcements.json`, (4) search-model download. Spec 08 ADDS the custom-domain
  provisioning Worker. The deferred Mac App Store migration REMOVES Sparkle. The
  recipient-browser portfolio `manifest.json` fetch is page traffic, not an app path,
  in all three states. Everything else stays blocked.
- **Distribution today is DIRECT with Sparkle self-update, not the Mac App Store.**
  The MAS move is deferred to `docs/superpowers/plans/deferred-mac-app-store-migration.md`
  and has NOT run: Sparkle is in the tree, the `temporary-exception.mach-lookup`
  entitlements are still present, and `VALID_ARCHS` is `arm64 arm64e i386 x86_64`. The "Platform & distribution" section below describes the POST-migration
  target state, not the current one. StoreKit plumbing is inert scaffolding until it runs.
- **Localization is INCOMPLETE: 992 keys, 146 without an `fr` value** (from Specs 03
  and 06 — Takeout/Lightroom-preset/cull/compare copy). Per CLAUDE.md this makes those
  features unfinished. Any per-spec "all N keys translated" claim below was true only
  when written.
- **The app SHIPS UNIVERSAL and must keep compiling for x86_64** (owner
  correction, 2026-08-01). It is tuned for Apple Silicon but has to run on Intel
  Macs, and it did until Spec 03: `ClipVectors.swift` used `Float16`, which does
  not exist on x86_64, so **a Release (universal) build of this branch was
  impossible** — `xcodebuild -configuration Release` failed outright. It went
  unnoticed for the whole build AND the review because a Debug build compiles
  only the active arch, so on Apple Silicon everything looked fine. Fixed by
  giving `ClipVectors` one wire format (IEEE-754 binary16 LE) and two encoders —
  hardware `Float16` on arm64, a portable bit-twiddle elsewhere — held together
  bit-for-bit by `ClipVectorsPortabilityTests` across all 65,536 half patterns.
  **This supersedes foundation §9 / decision #24's "Apple Silicon only, M1
  floor"**, which is now a TUNING target, not a build target. It also removes
  the `-exportLocalizations` blocker, which had the same single cause.
- **Specs 01–07 have been REVIEWED (2026-08-01) and the review's fixes are on
  `new-product-build-1`.** Findings, per-slice, are in
  `docs/new-build/REVIEW-FINDINGS.md`; the durable rules it established are in
  `docs/durable-constraints.md`. Three things in this block changed as a result:
  (a) the four launch backfills are now ONE serial chain (`LaunchBackfills`),
  throttle-aware and single-flighted through `BackfillCoordinator`; (b) the
  database now runs **WAL + `synchronous = NORMAL`** — `journal_mode` is
  persistent, so every existing library converts on first open; (c) two of Pass
  A's open questions are settled by runtime measurement, not reasoning: a
  sandboxed Muse **can** exec `/usr/bin/unzip` (pinned by
  `SandboxProcessTests`, so `ClipModelStore` works), and `CIImage(contentsOf:)`
  + a scale transform does **not** force a full-resolution decode (measured:
  59 ms at 1024 px vs 70 ms for a bounded ImageIO decode of the same 24 MP
  file, and 73 ms at 4096 px — Core Image fuses the scale into the graph). The
  RAW half of that finding was real and is fixed (`CIRAWFilter.scaleFactor`).
- **What the review could NOT verify at runtime** — everything needing hands on
  the GUI: hero open/close, the editor's sliders/curve/eyedropper/versions/
  presets/Edit-a-Copy, compare and cull, all five import sources, social export,
  Drive share and portfolio, and the backup/restore round trip. Static review
  and the unit suite cover them; nobody has driven them.
- **Backup does not carry edit data.** `BackupOccurrence` has no edit fields and
  `BackupArchive.currentSchema` is 1, so edits, versions, presets and LUTs do NOT
  survive a backup round trip. Spec 09's "Backup amendment A2" closes this; until then
  it is an open gap in shipped Specs 04–05, not a documentation error.

---

## Spec 01 as built (2026-07-31, `new-product-build-1`)

### Scope actually shipped

- Built: v13 coordinates + reader + write points + backfill; the three edit-aware seams;
  StoreKit 2 plumbing; announcements channel; semantic-search cancellation;
  `PerfBaseline`.
- **NOT built — deferred, at the owner's request, to
  `docs/superpowers/plans/deferred-mac-app-store-migration.md`:** the Mac App Store move.
  That covers the doctrine revisions, Sparkle excision, direct-distribution tooling
  removal, and the Apple-Silicon-only / deployment-target build settings. Consequently,
  **as of this commit the app still ships direct with Sparkle self-update and has TWO
  dependencies (GRDB + Sparkle)**. The "Platform & distribution" decisions below remain
  binding as decisions; they are simply not yet in effect. The StoreKit plumbing is
  inert scaffolding until that plan runs.
- Also not built (belongs to later specs, unchanged): any editor or search UI,
  places/rediscovery/stacks, faces, `HybridClusterer` time-bucketing.

### Coordinates (v13) — as built

- v13 schema landed exactly as specified (`files.lat`/`lon`/`coords_scanned_hash` +
  `files_coords_idx`). `FileRow` gained the three fields; no new `Columns` cases.
- Shipped as `Filesystem/CoordinateReader.swift` + `Intelligence/CoordinateBackfill.swift`
  (Spec 02 supersedes both with the single-pass `PhotoHeaderReader`/`PhotoHeaderBackfill`
  — already recorded below; the schema, sanitize rules, caps and video handling carry
  verbatim).
- API: `CoordinateReader.read(url:kind:) async -> Coordinate?` and
  `CoordinateReader.sanitize(_:) -> Coordinate?`. It calls `FileMetadata.coordinate(…)`
  and `FileMetadata.parseISO6709(_:)` rather than reimplementing them — the shared pure
  function is the mechanism that keeps the DB and the viewer from diverging.
- Write seams on `AnalyzePipeline`: `static func writeCoordinates(fileID:hash:coord:queue:)`
  (internal — it is the tested seam, like `markAnalysisAttempted`) and a private
  `writeCoordinatesOnly(fileID:url:kind:)` for the video path.
- **The video path checks `coords_scanned_hash != content_hash` BEFORE opening the
  file.** Videos never receive `analyzed_hash`, so `analyzePending` re-queues them on
  every folder visit; without this check every visit would re-read every video's
  metadata. Any future per-kind work hung off `analyzeOne` for a kind that skips the
  Vision write needs the same guard.
- **The undecodable-image branch stamps coordinates too.** `VisionTagger.analyze`
  returning nil means the PIXELS failed, but the GPS header is usually intact, so that
  branch calls `markAnalysisAttempted` AND `writeCoordinates`.
- `CoordinateBackfill.candidate(id:path:) -> Candidate?` is the pure, tested selection
  predicate; only `.image/.raw/.psd/.video` are admitted, because a kind the reader
  can't handle would never get a scanned hash and would be re-selected forever.
  `maxPerLaunch = 5_000`, `chunkSize = 200`, `concurrency = 4`.

### Edit-aware seams — as built

Everything recorded under "Edit-aware seams (Spec 01…)" below shipped as written. Deltas
and additions:

- All three seam types are declared `nonisolated` (the project builds with
  `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`); `EditStackIndex`'s provider slot is
  `NSLock`-guarded, because these are synchronous reads from view bodies and background
  decode workers where an `await` would sit on the grid's critical path.
- `EditStackIndex` is keyed by the `URL` the caller holds; normalization is each
  consumer's business (`ThumbnailCache` standardizes for its own key). A Spec 04
  provider must therefore standardize internally.
- `ThumbnailCache` gained a private `cacheKey(url:size:scale:stackHash:)` overload —
  `invalidate` needs the key for a stack state that ISN'T the installed one — plus a
  `#if DEBUG` `cacheKeyForTesting`. The public `cacheKey(url:size:scale:)` signature is
  unchanged, so no call site moved.
- **The layout/decode split is by QUESTION, not by file.** `HeroStage`'s >40 MP mid-res
  decode gate deliberately keeps reading `ImageHeaderSizeCache` even though the rest of
  `HeroStage` converted: it asks what the file costs to DECODE, which a crop does not
  change, and the effective size would understate it and skip the mid-res pass on
  exactly the files that need it.
- Converted layout consumers: `GridView.TileView.drawnAspectRatio`,
  `HeroStage.resolveHeaderSize`, `FileMetadata`'s dimensions row, and **both** of
  `AspectRatioCache`'s paths — a crop overrides the `files.width/height` DB map as well
  as the cold header read, since the DB value describes the original bytes.
- `OutputRender` also exposes `image(_:maxPixel:)` (the downsampled decode used by the
  PDF exporter). Decode-budget guarding stays with the caller: `OutputRender` is the
  render step, not the safety step.
- Signatures changed to take `RenderedOutput`: `DriveClient.uploadFile(_:name:mime:parent:)`
  and `ImageMetadataStripper.strip(_:mime:)`. Non-rendering fallbacks (video frame
  extraction, QuickLook type icons) keep taking a bare `URL` — they carry no edit stack.
- The Backup exclusion is documented in `Backup/BackupBuilder.swift`'s header as well as
  `OutputRender.swift`'s, so it is findable from either direction.

### Commerce — as built

- `Commerce/CommerceConfig.swift`: `unlockProductID = "com.tarrats.Muse.unlock"`,
  `sharingYearlyProductID = "com.tarrats.Muse.sharing.yearly"`,
  `sharingSubscriptionGroupID = "sharing"`, `announcementsURL =
  <DriveConfig.shareBaseURL>/announcements.json`, `redeemURL =
  https://apps.apple.com/redeem`. These strings appear nowhere else.
- `struct Entitlements { var unlocked: Bool; var sharing: Bool }` — two independent axes.
- `TrialPolicy(duration: 14 days, enforced: false)` is the shipped default. `TrialGate`
  is pure (`state(now:firstLaunch:entitled:policy:)`): entitled short-circuits to
  `.unlocked`; a missing anchor is day 0; a backwards clock clamps to full duration;
  remaining days round DOWN; exact expiry is `.expired`; an UNENFORCED policy past
  duration reports `.trial(daysLeft: 0)` and never `.expired`. Spec 09 turns it on by
  flipping `enforced`.
- `CommerceCache` is permissive-only: `grant` is one-way (passing `false` is not a
  revoke), `merge(remoteGrants:)` only ever adds, and `revoke` is the sole clearing
  path. `CommerceStore.refresh` calls `revoke` only after a walk of
  `Transaction.currentEntitlements` that COMPLETED — verified absence, not offline.
- Persistence: UserDefaults `commerce.unlocked` / `commerce.sharing` /
  `commerce.firstLaunch`, mirrored for the unlock flag and the anchor into
  `KeychainCommerceStore` (service `com.tarrats.Muse.commerce`, accounts `unlock-flag`
  and `first-launch`, `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` — the Drive
  token store's access class). The unlock flag is the OR of both mirrors; **the anchor
  is earliest-wins and never moves forward**, so a defaults wipe can't restart a trial.
- `CommerceStore.init()` is synchronous and cheap: the cache is read before the first
  frame, StoreKit refreshes after. `products()` returns `[]` until App Store Connect
  records exist and must not throw or hang.
- Settings gains a "Muse" `Section` placed BEFORE "Google Drive": entitlement/trial
  line, Unlock, Restore Purchases, Redeem Code… (opens `CommerceConfig.redeemURL`), and
  the announcements toggle. Buttons are `ModalButton`, with a `purchaseBusy` guard
  mirroring the existing `authBusy`.

### Announcements — as built

- `AppSettings.announcementsEnabledKey = "announcementsEnabled"`, default true. OFF
  disables the FETCH, not just the display.
- Feed shape: `{ "version": 1, "messages": [{ id, title, body, url, minAppVersion }] }`.
  `AnnouncementFeed.parse` is pure and fail-soft — 64 KB payload cap applied BEFORE
  decode, unknown `version` rejected outright, id required and ≤100 chars, title capped
  at 200, body at 2000, non-https urls dropped (the message survives; only its url
  goes). `AnnouncementSanitizer.strip` removes bidi overrides (U+202A–202E), bidi
  isolates (U+2066–2069), zero-width (U+200B–200D, U+FEFF) and control characters.
- `AnnouncementFeed.unseen(_:seen:appVersion:)` gates on `minAppVersion` with
  `.compare(_:options: .numeric)`, so "1.10" correctly outranks "1.6".
- `AnnouncementStore.fetchIfNeeded()` runs once per launch on an EPHEMERAL,
  cookie-less `URLSession`, 10 s timeout, no query string, no identifiers. Every
  failure is silent — a launch with no feed deployed must produce no UI. Seen ids
  persist in `announcementsSeenIDs`, capped at 200.
- Presentation is `Views/Modal/AnnouncementCard.swift` via `.museModal` at
  `ContentView` — never `.alert`, never `.sheet`, like every other modal. The url is
  re-checked for `https` at the point of `NSWorkspace.open`, not only at parse.
- **`AppState` gained one PLAIN, non-`@Published` stored property,
  `announcementPresented`**, OR'd into `modalPresented` so the grid's key catcher and
  the Escape resolver treat the card as a modal. `ContentView` is its only writer (via
  `.onChange` on the store's `pending`). This is the reading of "AppState is frozen"
  that this build settled on and that future specs should follow: **the freeze is on
  the `@Published` re-render surface, not on stored properties**. A feature store that
  needs to participate in a global gate mirrors into a plain property rather than
  publishing from `AppState`.

### Performance — as built

- `Database/SearchCancellation.swift`: a lock-guarded, one-way `@unchecked Sendable`
  flag. It is an explicit object rather than `Task.isCancelled` because **task-local
  cancellation does not propagate into a GRDB `queue.read` closure** (GRDB runs it on
  its own thread behind a continuation) — and that closure is exactly where the
  expensive semantic walk happens.
- `SearchService.search(query:scope:cancellation:)` — the parameter defaults to nil, so
  existing callers (App Intents, tests) are unchanged. Checked at entry, before query
  embedding, before the read, and immediately before the semantic leg.
- `AppState.inFlightSearchCancellation` is plain and non-`@Published` (same rule as
  above). `searchRequestToken` remains the guard on the RESULT; this is the guard on
  the WORK. Superseded by `runSearch`, `clearSearch`, and the folder-selection teardown.
- `PhaseTrace` gained `timelineEnabled` (`MUSE_TRACE=1` OR `MUSE_PERF=1`), an in-memory
  **first-occurrence-wins** mark timeline, and `elapsed(from:to:) -> TimeInterval?`.
  First-occurrence-wins is load-bearing: a repeated phase must not move a baseline's
  start or end. New marks: `app.start` (in `PhaseTrace.begin`) and `grid.firstPaint`
  (first non-empty `currentFiles` publish).
- `Perf/PerfBaseline.swift` runs at launch under `MUSE_PERF=1`. `PerfMeasurement` carries
  an `unavailable` flag so a measurement that couldn't be taken renders as "not
  measured" rather than a 0 that reads like a spectacular result — used by cold start
  with no marks, the 24 MP decode with no `MUSE_PERF_FIXTURE_24MP` fixture, and grid
  scroll frame time (which needs a scripted scroll against a mounted view and is
  emitted budget-only). The report goes to `docs/perf-baseline-<date>.md`, falling back
  to the sandbox tmp dir, and the path is always printed. **The suite asserts report
  FORMATTING, never timing numbers** — a perf assertion on a busy machine is noise.
- The thumbnail-decode probe size must be a `ThumbnailCache.renderedVariants` entry, or
  `invalidate` can't clear it and the measurement silently times a cache hit.

---

## Spec 02 as built (2026-07-31, `new-product-build-1`)

*Where this disagrees with the pre-build sections below, this section wins.*

### Scope actually shipped

- Built: the feature-print fix; v14–v17; `PhotoHeaderReader`/`PhotoHeaderBackfill`;
  offline geocoding + Places; rediscovery (Rarely Seen / On This Day / Shuffle);
  near-duplicate stacks; phase-1 token search + native autocomplete + chip-bar
  rendering via `TagChipsRow`'s parse-only path; the `.location` smart rule.
- **NOT built:** the token-search `PerfBaseline` metric (the plan's own conditional
  Task 15 — it needs a 50k synthetic `photo_meta` fixture; deferred to the harness).
- **v13 already existed** (Spec 01), so this spec added v14–v17 only. (Next migration
  version: see Current state.)

### Superseded Spec 01 units

- `Filesystem/CoordinateReader.swift` and `Intelligence/CoordinateBackfill.swift` are
  **deleted**, along with `AnalyzePipeline.writeCoordinates` and their two test files.
  `PhotoHeaderReader` / `PhotoHeaderBackfill` / `AnalyzePipeline.writePhotoHeader`
  replace them. The v13 schema, sanitize rules, caps (5 000/launch, 200/transaction,
  4-wide) and the pure `candidate(id:path:)` selection predicate carried over verbatim.

### Header pass — as built

- `PhotoHeaderReader.read(url:kind:) async -> PhotoHeader` + pure
  `sanitize(_:)`, `exifFields(exif:tiff:)`, `parseExifDate(_:)`, `monthDay(_:)`.
  Key handling uses the SAME prefix-stripping `sub()` shape as
  `FileMetadata.loadImage`, so both see bare keys ("FNumber", "Make", "Latitude").
- **Two write forms.** `writePhotoHeader(fileID:hash:header:queue:)` opens its own
  transaction; `writePhotoHeader(db:fileID:hash:header:)` runs inside a caller's. Both
  are **`nonisolated`** (the backfill is a nonisolated enum). The analyze pass uses the
  `db:` form inside the transaction that already guards on `analyzedHash`, so the
  header lands atomically with tags/caption/palette; the backfill uses it to batch 200
  rows per write.
- Both attempted-markers are stamped even on an empty header; the whole write is
  skipped when both already equal this content hash (amendment A1, built in from the
  start rather than retrofitted).
- The video branch (`writePhotoHeaderOnly`) checks BOTH markers before opening the
  file, and runs before the image-kind guard.

### Geocoding — as built

- **`GeoNamesDataset` does NOT cache the parsed cities.** The pre-build sketch's weak
  box was illusory (its only strong reference was the returned array), so `cities()`
  parses on demand and the caller holds it for exactly one pass. The tiny admin1 map
  IS process-cached. `maxInflatedBytes = 64_000_000`; a size/decode mismatch, an empty
  parse, or a missing resource all return nil — fail closed.
- `GeoBounds.boxes` returns ONE `-180...180` box when the radius wraps the globe
  (rather than two overlapping boxes); latitude is clamped to ±90 and `cos(lat)` to
  0.01 so a polar query can't produce an infinite span.
- `ReverseGeocoder.placeKey(city:admin:country:)` is the single declaration of the
  lowercased `"city|admin|country"` key — `PhotoSearch`, `PlaceQueries` and the
  `.location` rule all match against what it produced.
- `GeocodeBackfill` loads the dataset only AFTER finding candidates, and releases it on
  return. It chains `PlacesStore.reload()` + `SearchFacets.refresh()` when it wrote.
- **The bundled `Resources/geonames-cities.tsv.zlib` / `geonames-admin1.tsv` are
  9-city PLACEHOLDERS.** Byte-format correct (the bounded-inflate tests run against
  them), but Places stays near-empty for a real library until the owner runs
  `scripts/make-geonames.sh` and bumps `GeoNamesDataset.version`.

### Places — as built

- `PlaceQueries.groups(db:)` fetches flat rows and groups in SWIFT (count, cover =
  most-recent member, `latestAt` = `COALESCE(capture_date, modified_at, created_at)`).
  The pre-build `HAVING coverPath = (correlated subquery)` shape was dropped: it is
  quadratic per group for no benefit at this scale.
- `PlacesStore` holds its own `rootPaths`, pushed by `AppState.rebuildRootNodes` (the
  `CollectionsEngine.setRoots` pattern) — the store never reaches back into AppState.
  Empty roots means no filtering, matching `CollectionStore.fetchAll`'s fallback.
- `PlacesPage` reuses the existing 320×320 `renderedVariants` entry; no new variant.

### Rediscovery — as built

- `RediscoveryQueries.defaultLimit = 500`. `onThisDay`'s fallback leg admits a file
  with a `photo_meta` row whose `capture_md` is NULL (not only one with no row at all).
- `RediscoveryStore.activate` runs its resolve in a `Task` on the main actor under a
  request token; `dismiss()` is a no-op when nothing is active (so the teardown calls
  sprinkled through `select(folder:)`/`removeRoot` don't publish spuriously).
- `markViewed` dedupe window is 5 s (`RediscoveryStore.viewedDedupeWindow`). Hooks:
  `ContentView`'s `.onChange(of: appState.selectedFile?.url)` plus both hero viewers'
  existing `.task(id:)` (arrow-key flips).
- `AppState.rootPathList` (on `AppState+Rediscovery`) is the shared standardized-root
  accessor these surfaces use.

### Stacks — as built

- `StackStore.idChunk = 800` is the shared `IN (...)` chunk size (also used by
  `AutoStacker` and `StacksStore`'s path→file_id map).
- **`BurstClusterer`'s oversized-session split breaks ties toward the MIDPOINT.** With
  evenly-spaced frames every gap is equal, so a plain "largest gap" split lands at
  index 1 and peels one item at a time, bounding nothing.
- `AutoStacker` accumulates `claimedNow` across clusters inside its write transaction,
  so two clusters can't both claim a file. It is limited to `image/raw/psd`.
- `StacksStore.reload(for:)` is triggered from `AppState.currentFiles.didSet` (skipped
  during search / inside a collection) — the lazy per-folder trigger, no launch pass.
  `entries` excludes dissolved stacks; `badges` is a plain var.
- Collapse runs LAST in `visibleFiles`, after the facet filter, and only when
  `!isSearchActive && activeCollectionFiles == nil && RediscoveryStore.shared.files == nil`.

### Search tokens — as built

- `SearchToken.NumericFilter`/`DateToken` carry `displayLabel`, and `SearchToken` a
  `displayLabel`, so the chip bar has no formatting logic of its own.
- The parser also accepts `≥`/`≤` prefixes, rejects out-of-range `star:`/`in:` values
  (they stay in free text), and requires a non-empty key.
- `SearchQueryParser.keys` is the single list of canonical keys, read by
  `SearchSuggest`.
- `PhotoSearch.isIntersectable` names the `.text`/`.color` exclusion explicitly;
  `filter` returns nil when no intersectable token is present.
- `PhotoSearch.countryCode(forDisplayName:)` is the shared localized-country →
  ISO resolver, reused by the `.location` smart rule.
- `SearchService` gained: `parsed`/`hasTokens`/`effectiveQuery` at the top (a `text:`
  value folds into the free-text leg, a `color:` value into the existing palette leg
  via `SmartRule.parsedHex`/`SmartColor.rgb`), a token leg that short-circuits an
  empty intersection, a token-only branch resolving `tok.ids` directly, the
  `tok.idSet` intersection AFTER the existing legs, dir-restriction merge AFTER the
  relaxation loop, and `!hasTokens` added to the unindexed-extras guard.
- Autocomplete quotes a facet value containing spaces so it re-parses as one token.
  `SearchFacets.facetLimit = 50`; refreshed from the analyze pass and both backfills.

### `.location` — as built

- `SmartRule.location(LocationTerm)` with `LocationTerm = .place(String) |
  .near(lat:lon:radiusKM:)`; `isValid` for `.near` reuses `PhotoHeaderReader.sanitize`.
- The rules editor gains a Location kind whose default is `.place("")`; `.near` has no
  editor (the `ColorTerm.hex` precedent) and renders a static "radius rule" label.

### AppState integration — as built

- Three new forwarded cancellables in `AppState.init` (`rediscoveryCancellable`,
  `placesCancellable`, `stacksCancellable`). The rediscovery and stacks ones also call
  the new `AppState.invalidateVisibleFiles()` — both stores participate in the memo.
- No new `@Published` property on `AppState`. `EscapeResolver.action` gained
  `rediscoveryActive:` and `showingPlacesPage:` (both defaulted, so existing tests and
  callers are unchanged).
- `StarRating.labels(atLeast:)` was added as the shared "≥ N stars" label list (the
  resolver's private `qualifyingRatingLabels` stays private and unchanged).

### Docs & localization

- `scripts/make-geonames.sh` is checked in and executable. GeoNames CC BY 4.0
  attribution is in README.md and a new "Places" section of the About card.
- French export reports **0 untranslated** (49 new keys filled, including the Spec 01
  commerce/announcement strings that had never been translated).

---

## Platform & distribution

> **TARGET STATE, NOT CURRENT.** This section describes where the app lands after the
> deferred Mac App Store migration runs. It has not run. What ships today — direct
> distribution with Sparkle, non-arm64-only `VALID_ARCHS`, the mach-lookup entitlements
> still in place — is in Current state at the top of this file.

- Distribution is Mac App Store exclusively. No Sparkle, no DMG/appcast/GitHub-release
  tooling, no direct distribution. StoreKit 2 for all payments; TestFlight for betas;
  Small Business Program (15%).
- Apple Silicon only, M1 floor: `ARCHS = arm64`, `VALID_ARCHS = arm64`.
  `LSMinimumSystemVersion` stays 14.6 — the arch restriction enforces the M1 floor, not
  the OS version.
- Deployment target is **14.6 for every target**, including `MuseShareExtension`
  (reconciled down from 26.5 — an extension pinned above the running OS is silently
  unregistered) and `MuseTests` (down from 26.2). Project-level 26.0 → 14.6.
- Dependency count target: **one** (GRDB). New dependencies require justification;
  ML models are downloaded on demand, never bundled in the binary.
- Sandbox entitlements are MAS-clean once the Sparkle `temporary-exception.mach-lookup`
  array is removed (that removal is required for App Review, not optional).
  `ENABLE_HARDENED_RUNTIME` stays on.
- License: PolyForm Shield; repo private. GPL/LGPL code never (also MAS-incompatible).

## Network doctrine

- Exactly four app-initiated network paths: (1) Google Drive share (user-initiated),
  (2) `announcements.json` (once per launch, off-able), (3) custom-domain provisioning
  Worker (Spec 08, live: `DomainConfig.workerBaseURL` ONLY; paid; user-initiated, plus
  a launch status/refresh call only while a domain or address is configured — the
  `DriveExpirySweeper` class), (4) search-model download (Spec 03 —
  strictly user-initiated via Settings or the one-time offer card, pinned host,
  manifest SHA-256-verified, fail closed, nothing sent). StoreKit/App Store traffic is
  OS-level and not counted. Everything else stays blocked.
- Reverse geocoding is fully offline (bundled GeoNames + k-d tree). `CLGeocoder` and
  MapKit geocoding are forbidden (network + throttled).
- Map link-outs (`maps://`, `https://www.google.com/maps?q=lat,lon` via
  `NSWorkspace.open`) are browser/app hand-offs, not app network calls — same doctrine
  class; the app never touches those URLs with `URLSession`.
- The share PAGE (recipient's browser, Spec 07) makes exactly one kind of network
  fetch: the portfolio `manifest.json` GET to `https://www.googleapis.com`,
  `connect-src`-pinned in the CSP, bounded (`MAX_MANIFEST_BYTES` 512 KB, 6 s timeout),
  re-validated, never chained. It is recipient-browser traffic, not an app network
  path — the four-path app list above is unchanged. The page carries a
  Drive-API-restricted, quota-only API key for this fetch — **the referrer
  restriction is dropped by Spec 08** (custom hostnames are unenumerable, and the
  restriction would break the portfolio fetch on exactly the paid tier's pages); an
  API key for public data is NOT a secret, and this **revises the older "no API key
  on the page" wording** — the binding invariant is *no secret and no OAuth
  credential on the page*, plus classic (non-portfolio) shares still touch no
  network beyond Drive image loads.

## Commerce

- Product ids: `com.tarrats.Muse.unlock` (non-consumable app unlock) and
  `com.tarrats.Muse.sharing.yearly` (auto-renewable, subscription group `sharing`).
  Ids appear only in `Commerce/CommerceConfig.swift`.
- `Commerce/CommerceStore.swift`: `@MainActor final class CommerceStore: ObservableObject`,
  injected as `@EnvironmentObject`. Entitlements = `{unlocked: Bool, sharing: Bool}`.
  A long-lived `Transaction.updates` listener starts at init. `refresh()` reads
  `Transaction.currentEntitlements`, verified-only.
- Entitlement cache is **permissive-only**: mirrored to UserDefaults + a Keychain-backed
  unlock flag, read synchronously at launch; it can grant, never revoke. Revocation only
  on a verified StoreKit read lacking the entitlement.
- No identifiers, receipts, or `appAccountToken` sent anywhere; "Data Not Collected"
  label unchanged.
- Trial: MAS forces free download → trial → unlock IAP. `Commerce/TrialGate.swift` is a
  pure function of `(now, firstLaunch, entitled, TrialPolicy)`. Policy default: 14 days,
  `enforced: false` at Spec 01 time — **superseded by Spec 09, which flips it true**
  (see "Pricing & trial (Spec 09)"; sandbox purchases mean testers exercise the gate
  rather than being locked out).
- Trial anchor: first-launch date in Keychain
  (`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`), earliest-wins against any
  UserDefaults mirror, never moved forward.
- Gifting: Apple promo codes only. macOS has no in-app redemption sheet
  (`presentCodeRedemptionSheet` is iOS-only) — the Settings "Redeem Code" row opens
  `https://apps.apple.com/redeem`; the `Transaction.updates` listener picks up the result.
- Announcements: static JSON at `\(DriveConfig.shareBaseURL)/announcements.json`
  (constant in `CommerceConfig`), fetched once per launch, `.ephemeral` session,
  10 s timeout, silent on any failure. Shape:
  `{ "version": 1, "messages": [{ "id", "title", "body", "url", "minAppVersion" }] }`.
  Each message shown once by id (`announcementsSeenIDs` in UserDefaults, capped 200).
  `AppSettings.announcementsEnabled` (default true) disables the fetch itself.
  Hardening: 64 KB response cap, length caps + bidi/zero-width/control-char
  sanitization on all displayed fields, `url` must be https and opens only on click,
  unknown `version` ignored. Pure parse/selection (`AnnouncementFeed`) separated from
  the fetch. Presented as `ModalMessageCard` at the shell, registered in
  `AppState.modalPresented`.

## Scale & performance

- Two-tier envelope: design center 10k–50k photos, flawless on the reference machine
  (**M1 Air 8 GB**); 200k–800k accommodated gracefully. **No code may assume the
  library fits in RAM** — big-library support must be a tuning pass, not a rewrite.
- Query time touches ONLY precomputed data. Every search token resolves against an
  indexed column written at analyze/backfill time; no token may open a file, call
  Vision, or geocode. New search capability = new indexed column + backfill, never
  query-time work.
- `Perf/PerfBaseline.swift` + `PerfBaselineTests` **record** numbers, never assert
  (CI perf failures are noise). Budgets: cold start → first grid paint 1500 ms; grid
  scroll 16.7 ms p95; search 150 ms p95; single 24 MP thumbnail decode 60 ms; token
  search over 50k synthetic `photo_meta` 100 ms. Report written to
  `docs/perf-baseline-<date>.md`; triggered by `MUSE_PERF=1` or the test target, never
  app UI.
- Backfill posture: `.utility` priority + per-launch cap is the "background, throttled"
  baseline. Battery/thermal-aware pausing is Spec 06's work, not assumed earlier.
- Analysis is always on — no off switch, no skip state, no new analysis toggles.

## Architecture & module structure

- **`AppState` is frozen**: no new `@Published` properties, ever. New features get their
  own `@MainActor` singleton store observed directly by views (Pattern B, like
  `CollectionsEngine`): `CommerceStore`, `AnnouncementStore`, `PlacesStore`,
  `RediscoveryStore`, `StacksStore`, `SearchFacets`, `ClipModelStore`, `CompareStore`,
  `CullStore`, `NLQuerySuggest`, `EditStore`, `EditPresetStore`, `EditClipboard`,
  `LutStore`, `EditReferenceStore`, `WorkThrottleStore`, `AnalysisStatusStore`,
  `ShareDomainStore`
  (plus the per-file, non-singleton `EditSession` created on entering Edit mode, and
  the per-run, non-singleton import models in `Import/` and `SocialExportModel`
  (Spec 07) — the shipped `MetadataImportModel` shape).
- Sanctioned AppState integration cost per store: one stored `objectWillChange`-forwarding
  cancellable in `AppState.init` (the `folderStats` pattern) + a methods-only
  `AppState+<Feature>.swift` extension for orchestration. Nothing else.
- New module folders: `Commerce/`, `Perf/`, `Search/`, `Intelligence/Geo/`,
  `Intelligence/Stacks/`, `Intelligence/Core/` (shared pure helpers, e.g.
  `FeaturePrints`), `Intelligence/Clip/` (model store, tokenizer, engine,
  preprocessing), `Views/Compare/`, `Editing/` + `Editing/Render/` (Spec 04 —
  platform-neutral: Foundation/CoreGraphics/CoreImage/Metal only, NEVER AppKit,
  enforced by `EditingModuleImportTests`), `Views/Editor/`, `Views/Theme/`,
  `Export/Social/` (Spec 07 — platform-neutral: Foundation/CoreGraphics/CoreImage/
  ImageIO/UniformTypeIdentifiers only, never AppKit) + `Views/Export/`,
  `Sharing/Domains/` (Spec 08). Non-app deployables live top-level beside `web/`:
  `workers/domains/` (Spec 08 — the provisioning Worker).
- Database read/write helpers are nonisolated enums of pure `db`-taking funcs in
  `Database/` (`PlaceQueries`, `RediscoveryQueries`, `StackStore`, `EditRecordStore` —
  the `NoteStore` shape).
- Pure logic lives in nonisolated enums/structs, unit-tested without UI; `Components/`
  holds pure UI math (`StackDisplay`). House convention: no UI unit tests.
- Shared mutable statics read off-main are lock-guarded `nonisolated(unsafe)` (the
  `ImageHeaderSizeCache` pattern — used by `EditStackIndex`).
- Launch backfills are fire-and-forget `Task`s from `MuseApp`'s `.task`, modelled on
  `IntentBackfill`: self-limiting, safe to call every launch, `PhaseTrace`-marked.
- The semantic-token Theme layer (foundation #27) is created **minimally by Spec 04**:
  `Views/Theme/Theme.swift`, an Environment value (role-named colors/spacing/radius/
  fonts) resolved from `moodPalette` + system semantics, injected once in
  `ContentView`. Every NEW editor-adjacent surface must read `@Environment(\.theme)`;
  pre-existing surfaces are NOT migrated (opportunistic later). Non-editor surfaces
  keep the prior rule: system semantic colors, shared `SidebarView` constants,
  `moodPalette` — no raw hex anywhere.
- Mobile-later prerequisites remain design constraints: edit stacks mirrored into
  sidecars; nothing may make the per-field sidecar clock harder.

## Database schema & migrations

- Migration numbering is fixed (v13–v17 are BUILT as of 2026-07-31 — see "Spec 02 as
  built"): **v13 coordinates · v14 `photo_meta` · v15 `places` ·
  v16 `last_viewed_at` · v17 stacks · v18 `clip_embeddings` · v19 `photo_traits` ·
  v20 `edits` + `edit_versions` · v21 `edit_presets` · v22 `photo_traits`
  capture-stats columns · v23 `edit_luts`** — separate migrations so features land in
  separate commits without renumbering. Future specs continue at
  v24. Registered at the end of
  `Database.makeMigrator()`, GRDB DSL, matching record structs in
  `Database/Records.swift` (snake_case fields, `Codable` + `FetchableRecord` +
  `MutablePersistableRecord`, inserted as `var`). Every new child table cascades on
  file delete (`Housekeeping.pruneUnreachable` stays unchanged).
- **v13**: `files.lat REAL`, `files.lon REAL` (signed decimal degrees, WGS-84),
  `files.coords_scanned_hash TEXT`; partial index
  `files_coords_idx ON files(lat, lon) WHERE lat IS NOT NULL`.
- **v14**: `photo_meta` table — `file_id TEXT PRIMARY KEY REFERENCES files ON DELETE
  CASCADE`, `exif_scanned_hash`, `capture_date` (unix seconds, local-time
  DateTimeOriginal), `capture_md` ("MM-DD", materialized on-this-day key),
  `camera_make`, `camera_model`, `lens`, `iso`, `f_number`, `exposure_seconds`,
  `focal_length` (mm), `focal_length_35mm`, `flash_fired` (EXIF Flash bit 0; nil =
  unknown). Indexes: capture_date, capture_md, (camera_make, camera_model), lens, iso,
  f_number, focal_length. EXIF is a **separate table, not columns on `files`** (keeps
  `SELECT *` fetch paths lean).
- `capture_md` is materialized because `strftime` in a WHERE clause can't use an index —
  the query-time-only-precomputed rule applied at schema level.
- **v15**: `places` table — `file_id` PK cascade, `geocoded_hash TEXT NOT NULL`,
  `dataset_version INTEGER NOT NULL`, `city`, `admin`, `country`, `place_key`
  (all nullable); index on `place_key`. `place_key` = lowercased
  `"city|admin|country"`. A row with NULL place fields means "geocoded, nothing within
  range" — the row is the attempted-marker. `country` stores the **ISO 3166-1 alpha-2
  code**; display names resolve at render time via
  `Locale.current.localizedString(forRegionCode:)` (display-time-localization rule).
  Re-geocode when the row is missing, `geocoded_hash != content_hash`, or
  `dataset_version != GeoNamesDataset.version`.
- **v16**: `files.last_viewed_at INTEGER` (unix seconds). No index — rediscovery
  queries run once per surface activation, never per keystroke.
- **v17**: `stacks` (`id` TEXT UUID PK, `kind` "auto"|"manual", `dissolved` BOOL
  default false, `pick_file_id` nullable, `created_at`) + `stack_members`
  (`stack_id`/`file_id`, composite PK, both cascade; index on `file_id`).
- **No `files.stack_hash` column, ever.** The edit stack is per `(file, parent_dir)`
  (tags/notes grain); `files.content_hash` is UNIQUE, so a column on `files` would
  force two folders' copies to share one edit stack. Spec 04 adds the `edits` table at
  that grain.
- Records: `PhotoMetaRow`, `PlaceRow`, `StackRow`, `StackMemberRow`; `FileRow` gains
  `lat`, `lon`, `coords_scanned_hash`, `last_viewed_at`.

## Data-grain rules

- Content-keyed (on `files`, shared by byte-identical copies): coordinates, EXIF
  (`photo_meta`), places, `last_viewed_at`, stacks. Rationale: the data lives in (or
  derives from) the bytes; edit-in-place already splits the row.
- Per `(file_id, parent_dir)` (never content-keyed): tags, ratings, notes, and the
  edit stack (`edits`/`edit_versions`, Spec 04).
- Sidecars carry none of the new data: `photo_meta`/`places` are derived and recompute
  locally for free (same rule as OCR text); `last_viewed_at` is device-local behavioral
  data — never exported, never synced, never sent anywhere.
- Attempted-markers for all header-derived data: `coords_scanned_hash`,
  `photo_meta.exif_scanned_hash`, and the `places` row itself. Storing the *hash* (not
  a bool) makes an edit-in-place re-read; never replace one with a bare NULL-column
  check (the `analyzed_hash`-NULL retry-loop bug shape). Dataless iCloud files are
  skipped **without stamping**.
- Rating data is per-location, so anything resolving rating matches (e.g. the `star:`
  search token) must carry `parent_dir` restrictions; content-derived matches stay
  folder-unrestricted.

## Edit-aware seams (Spec 01; made live by Spec 04)

- `Models/EditStackIndex.swift`: `stackHash(for url:) -> String?`,
  `croppedSize(for url:) -> CGSize?`, `installProvider(_ p: (any EditStackProviding)?)`.
  Keyed by standardized path. Returns nil until Spec 04 installs the real provider.
- `ThumbnailCache.cacheKey` appends `|<stackHash>` to the raw key string **only when a
  stack hash exists** — the nil case stays byte-identical to the pre-change key (any
  change, even an empty suffix, re-keys every cached PNG and forces a full-library
  thumbnail regeneration). `invalidate(_:)` drops both the current-stack and nil-stack
  variants × every `renderedVariants` entry. The `renderedVariants` discipline is
  unchanged.
- `Components/EffectiveDimensions.swift` (`cached`/`resolve`/`aspect`) =
  `EditStackIndex.croppedSize ?? ImageHeaderSizeCache`. **Layout reads
  `EffectiveDimensions`; analysis and decode budgets read `ImageHeaderSizeCache`
  directly** (`declaredPixelCount`, `VisionServices.analyze`). `ImageHeaderSizeCache`
  remains the single orientation-applied truth; `EffectiveDimensions` sits above it.
- `files.width/height`, `analyzed_hash`, and `Indexer.reconcile` stay keyed on
  ORIGINAL bytes — an edit never changes content identity.
- `Export/OutputRender.swift` is the export choke point: `RenderedOutput` has a
  `fileprivate` init, so no other file can fabricate one — every path shipping pixels
  out of the app (`CollectionPDFExporter`, `DriveClient.uploadFile`, share sheet)
  compiles only through `OutputRender.forOutput`. Metadata stripping runs on the
  **post-render** bytes (render first, strip second). **Backup is the one deliberate
  exclusion** — it restores originals by content hash; rendering edits into it would
  corrupt the restore. Drive's text-link form shares no pixels and stays untouched.

## Analysis pipeline & backfills

- One header pass: `Filesystem/PhotoHeaderReader.swift` reads coordinates AND EXIF from
  a single `CGImageSourceCopyPropertiesAtIndex` call (supersedes Spec 01's separate
  `CoordinateReader`/`CoordinateBackfill` — deviation recorded; the v13 schema,
  sanitize rules, caps, and video handling carry verbatim).
- Key handling mirrors `FileMetadata.imageMetadata` exactly (prefix-stripped keys,
  `ISOSpeedRatings` array-or-scalar tolerance) — the reader and the viewer **must not
  diverge**.
- Video: `AVURLAsset.noNetwork(url:)` only (durable constraint), `asset.load(.metadata)`
  (follow the code — `FileMetadata.loadVideo` reads `.metadata`, not
  `.commonMetadata`); `commonKeyLocation` → ISO 6709, `commonKeyCreationDate` →
  capture date; all other EXIF fields nil.
- Dataless-iCloud guard is the first statement: `.notDownloaded` → empty header, never
  forcing a download.
- Coordinate sanitize: reject non-finite and out-of-range (`|lat| > 90`, `|lon| > 180`).
- EXIF dates: `"yyyy:MM:dd HH:mm:ss"`, `en_US_POSIX`, interpreted in the current local
  time zone (EXIF carries no zone; Photos-app convention; recorded limitation).
  `capture_md` derives from the same parse so the two can't disagree.
- Write points: `AnalyzePipeline.analyzeOne` reads the header **before the image-kind
  guard** — video gets its own small hash-guarded transaction (a geotagged/dated video
  must not be invisible to `near:`/`in:`/On This Day); image kinds ride the existing
  `content_hash == analyzedHash` guarded transaction. Header read runs concurrent with
  Vision (`async let`).
- `Intelligence/PhotoHeaderBackfill.swift`: launch pass, `maxPerLaunch = 5_000`,
  concurrency 4, writes chunked 200/transaction, each row hash-guarded. Selection is
  stale-by-either-marker (coords or EXIF). On completion chains
  `GeocodeBackfill.run()` then `SearchFacets.refresh()`.

## Geocoding & places

- Dataset: GeoNames **cities1000** (not cities15000 — villages are where travel photos
  happen), CC-BY 4.0. Attribution required in the About card and README.
- Bundled artifacts are produced by the checked-in `scripts/make-geonames.sh` and
  committed: `Resources/geonames-cities.tsv.zlib` (5 columns, raw DEFLATE with the
  expected inflated byte count as the first 4 bytes) + `Resources/geonames-admin1.tsv`.
  The app never fetches them.
- Bounded decompress: `GeoNamesDataset.load` allocates exactly the declared size and
  treats a short/overflowing decode as corrupt → dataset unavailable, fail closed.
- `GeoNamesDataset.version` (Int) is bumped on regeneration; a version bump re-geocodes
  the library (pure CPU over DB rows, no file I/O).
- The dataset (~7 MB resident) is held only while a geocode pass runs (`weak` in the
  singleton) — browsing carries zero standing cost.
- `Intelligence/Geo/GeoKDTree.swift`: 3-D k-d tree over unit-sphere coordinates
  (exact nearest-neighbor, no antimeridian/pole bugs). Shared pure helpers in the same
  file: `GreatCircle.distanceKM`, `GeoBounds.boxes` (splits a radius box crossing ±180°
  into two range queries).
- `ReverseGeocoder.maxDistanceKM = 150`; beyond → NULL-place attempted-marker row.
- Places page: `Models/PlacesStore.swift` (Pattern B) + `Views/PlacesPage.swift`
  modelled tile-for-tile on `CollectionsPage`; cover thumbnails reuse the existing
  320×320 grid variant (no new `renderedVariants` entry). NULL `place_key` rows are
  excluded — no "Unknown" group.
- Place click-through is a **programmatic `near:` token search** — no fourth
  `visibleFiles` substitution; one navigation system; Places dog-foods the token
  engine. Lost sort-control inside a place is accepted (same tradeoff as search).
- Sidebar gains a **LIBRARY** section between FOLDERS and COLLECTIONS (rows: Places /
  On This Day / Rarely Seen / Shuffle), gated identically to COLLECTIONS plus
  `AppSettings.showLibraryInSidebarKey` (default true, Settings toggle). Rows copy the
  `StarRow` template (fixed, non-reorderable, shared geometry constants).
- Viewer INFO card shows the place name when one exists (coordinates move to tooltip)
  and renders two link-outs: existing Apple Maps + new `OpenInGoogleMapsButton`.

## Rediscovery

- `RediscoverySurface`: `rarelySeen`, `onThisDay`, `shuffle`. `RediscoveryStore`
  (Pattern B) resolves off-main under a request token (the `setActiveCollection`
  stale-guard shape).
- Surfaces cap at 500 items — browse surfaces, not archives; Shuffle re-samples on
  demand via the existing `SeededRandom` with a fresh seed.
- Rarely Seen order: never-viewed first (`last_viewed_at IS NOT NULL, last_viewed_at
  ASC, created_at ASC`). On This Day: `capture_md = today` with year < current;
  files without a `photo_meta` row fall back to the same month-day test on
  `files.created_at`; Feb 29 shows on Feb 29 only (no Mar 1 remap). Kinds limited to
  image/raw/psd/video; root-filtered via `CollectionStore.isUnderAnyRoot`.
- `markViewed` write path: view-layer hooks only (a `ContentView` `.onChange` on
  `selectedFile?.url` + the hero image/video viewers' `.task(id:)` for arrow flips) —
  `AppState.selectedFile` keeps no `didSet`. In-memory 5 s dedupe window absorbs
  double-fires.
- The `visibleFiles` seam is one line:
  `base = activeCollectionFiles ?? RediscoveryStore.shared.files ?? currentFiles`.
- Context-switch teardown parity is mandatory: `select(folder:)` dismisses
  rediscovery/places; `removeRoot` re-resolves an active surface; activate/dismiss
  clear selection (the narrows-visibleFiles rule); burn-delete routes through
  `dropFromActiveCollection` → `RediscoveryStore.drop(path:)`.
- Escape order (tested): modal → **compare** → viewer → search → tags → collection →
  **rediscovery** → collections page → **places page** → none. A rediscovery surface
  behaves like a collection context; pages are outermost. Compare and the hero viewer
  never coexist; the resolver still keeps a total order.

## Near-duplicate stacks

- `files.feature_print` stores **raw `VNFeaturePrintObservation.data`** (bare Float32
  buffer) — never `NSKeyedUnarchiver` it (unarchiving returns nil; that was the shipped
  dead visual-duplicates bug). All comparisons go through
  `Intelligence/Core/FeaturePrints.floats/distance` (vDSP Euclidean), which returns nil
  for length-mismatched pairs — prints from different Vision revisions must never pair.
- `BurstClusterer` constants: `sessionGapSeconds = 10`, `similarityThreshold = 0.45`
  (named constant; never validated live — owner validation step outstanding),
  `maxSessionSize = 256` (oversized sessions split at their largest internal gaps).
  Algorithm: sort by `captureAt` (`capture_date ?? created_at`), split sessions at the
  gap, union-find on similarity within a session — **time bucket first, similarity
  second**; nil-print items never cluster.
- Stacks are **presentation-only, content-keyed sets of `file_id`** — no `parent_dir`,
  no path. Stacking writes only `stacks`/`stack_members`; tags, ratings, notes,
  collection memberships, paths, and `analyzed_hash` are untouched.
- `dissolved` is a permanent tombstone (the collection-`setHidden` pattern): unstacking
  keeps the row + members so the auto-stacker never re-forms it. **The auto-stacker
  only touches virgin files** — any `stack_members` row, dissolved included, makes a
  file off-limits. Don't "clean up" dissolved rows.
- Auto-stack triggers: end of an analyze pass (over that pass's file ids) +
  lazily per-folder from `StacksStore.reload(for:)` — no global launch pass.
- Collapse applies **only in plain folder browsing** — never in search (a matching
  frame must not hide under a non-matching representative), collections, or
  rediscovery. Collapse/expand prunes the grid selection; `gridSignature` includes the
  stacks generation. `StacksStore.badges` is a plain (non-`@Published`) var written
  inside the memoized `visibleFiles` computation — it must not publish.
- Stack badge: top-leading capsule (star badge owns top-trailing), and unlike the star
  badge it IS a click target (expand/collapse) with a named `.accessibilityAction`.
- Manual stacking v1: "Stack Selection" appears only when ≥2 image-kind files are
  selected and none is already stacked (no merging into existing stacks; the item is
  hidden, not disabled). `.folder` and non-image kinds never see the Stack section.
- Deleting a representative needs no bookkeeping: the next `visibleFiles` pass
  recollapses and the next member becomes representative; a `pick_file_id` pointing at
  a dead file simply stops matching.
- Exports/share operate on `visibleFiles`, so a collapsed view exports representatives
  — expand first to export all (matches what the user sees; by design).

## Search (token phase)

- Module: `Search/` — `SearchToken.swift` (model + parser), `PhotoSearch.swift`
  (token → SQL), `SearchFacets.swift` (autocomplete facets).
- v1 token set (exactly the foundation list): `camera:`, `lens:`, `iso:`, `f:`,
  `in:` (YYYY / YYYY-MM / YYYY-MM-DD), `near:`, `text:` (FTS-only), `color:`,
  `star:`/`★` forms, `kind:`. Shutter/focal/flash are **indexed but have no v1
  token** — adding `shutter:`/`mm:`/`flash:` later is grammar-only.
- Grammar: `key:value`, no space before the colon; double-quoted values carry spaces;
  numeric ops `>`, `>=`, `<`, `<=`, `a-b`, bare = equals; `star:N` means ≥ N (exact is
  `star:=N`); a literal `★`-run parses as ≥ its length and is stripped before the FTS
  leg. An unknown key or invalid value is NOT a token — it stays in free text verbatim
  (typed text is never silently dropped). Keys are canonical English, matched
  case-insensitively (French key aliases are a follow-up; values are language-neutral).
- Token AND semantics = set intersection (mirroring `SmartRuleSet.all`). Token-only
  queries order by capture date DESC. Rating tokens carry per-`(file_id, parent_dir)`
  dir restrictions; every other token is content-derived and unrestricted; token dir
  restrictions are applied AFTER the FTS/semantic relaxation step so a text match
  cannot un-restrict a rating token.
- A tokenless query is **byte-identical to the pre-token pipeline** (pinned by test),
  including legacy bare-hex color behavior. A `color:` token routes into the existing
  palette leg — not re-implemented. The unindexed-extras (basename-scan) leg is skipped
  whenever tokens are present.
- The committed field text is the single source of truth for tokens. The chip bar
  renders `SearchQueryParser.parse(searchQuery)` in the existing `TagChipsRow`
  active-filter row, holds no state of its own, and edits tokens by rewriting the query
  text (`ParsedQuery.removing(tokenAt:)` → re-run through the programmatic search
  path). **In-field NSTokenField-style tokens are explicitly not built** — the native
  `.searchable` toolbar field is a durable constraint; suggestions ride native
  `.searchSuggestions`/`.searchCompletion`.
- Autocomplete: `SearchFacets` (Pattern B store, four `DISTINCT` selects off-main,
  refreshed after backfills and analyze passes) + pure `SearchSuggest.suggestions`
  (cap 8; key-prefix → key, `key:partial` → real facet values; plain free text gets no
  suggestions; completion replaces only the trailing token-in-progress).
- "Works with tags off" holds by construction: only the rating token reads `tags`, and
  ratings are tag-implemented by design.
- Debounce (250 ms) and the whole existing search stack (`SemanticSearch`,
  `SearchBridge`, note legs, scope filter, `AppState+Search`) are unchanged except the
  token integration; the semantic-cancellation improvement remains Spec 01's
  deliverable.

## `.location` smart rule

- `SmartRule` gains `case location(LocationTerm)`;
  `LocationTerm = .place(String) | .near(lat:lon:radiusKM:)`. Codable stays fully
  synthesized (house style); the accepted consequence is that a rule set containing
  `.location` decodes as empty on older builds (the collection itself survives).
- `.place` matches city OR admin OR country, with a localized country display name
  resolved back to its ISO code in Swift before the query (user types "Portugal", DB
  stores "PT").
- `.near` evaluates via bounding-box prefilter on the v13 partial index (box split in
  two across ±180°) + exact haversine in Swift. **`.near` decodes and evaluates but has
  no rule editor in v1** (the `ColorTerm.hex` precedent).

## CLIP semantic engine & model delivery (Spec 03)

- The build is model-agnostic: `Intelligence/Clip/ClipModel.swift` holds one compiled-in
  descriptor `ClipModel.current` (`name`, `generation`, `dimension` 512,
  `imageInputSide`, `downloadBytes`, `manifestURL`). Swapping models = edit the constant
  + bump `generation`. Primary: MobileCLIP-S2 (weights TOU legal read gates *shipping*,
  never building); fallback: self-converted OpenCLIP ViT-B/32.
- Artifacts are fp16 Core ML (`ImageEncoder.mlmodelc`, `TextEncoder.mlmodelc`) + CLIP
  BPE `vocab.json`/`merges.txt`, produced by the checked-in
  `scripts/make-clip-coreml.py`. CLIP input normalization is baked into the image
  encoder's input layer — the app supplies plain RGB and cannot drift from training
  preprocessing.
- Hosting: one `model.zip` split into ≤ 20 MiB chunks + `manifest.json`
  (`{version, name, generation, totalBytes, sha256, chunks}`) under
  `\(DriveConfig.shareBaseURL)/models/<name>-g<generation>/` (Pages caps assets at
  25 MiB; an R2 bucket under the same manifest contract is the sanctioned alternative).
- Install: reassemble → verify whole-file SHA-256 → unzip to
  `Application Support/Muse/Models/<name>-g<generation>/` → load-test both encoders →
  write a `verified` marker. Any failure deletes the partial directory (fail closed).
  Older generation directories are deleted after the new one verifies. Manifest fetch:
  pinned host, 16 KB cap, unknown `version` refused, `.ephemeral` session.
- Download is strictly user-initiated: Settings "Search" section (status row +
  Download/Cancel/Remove) plus a ONE-TIME `ModalMessageCard` offer — shown at the first
  committed tokenless search of ≥ 3 words while the model is absent, never again after
  "Not Now" (`AppSettings.clipOfferSeenKey`). Registered in `AppState.modalPresented`.
- `ClipModelStore` (Pattern B): `state = .absent/.downloading(progress)/.installed/
  .failed(message)`; `isReady` is the single gate every CLIP feature checks. On
  `.installed`: kick `DeepAnalysisBackfill.run()` + `ClipPromptVectors.refreshAll()`,
  then `SearchFacets.refresh()` on backfill completion. Zero AppState integration.
- `ClipEngine` is an `actor` (`embedImage`/`embedText`/`unload`), lazy-loading with
  `.all` compute units; residency is pass-scoped (`retain()`/`release()` tokens,
  `unload()` when none outstanding — the `GeoNamesDataset` weak-residency pattern).
  Outputs are 512-d **L2-normalized at the engine boundary** (cosine = dot product
  downstream); zero-norm/empty input → nil.
- `ClipTokenizer` is pure Swift BPE (~150 LOC, no dependency), 77-token context,
  unit-tested against fixture pairs the conversion script generates from the Python
  tokenizer — the two implementations must not diverge (the `PhotoHeaderReader` /
  `FileMetadata` rule class).
- `ClipPreprocess.pixelBuffer(from:side:)`: aspect-FILL scale + center crop, pure and
  unit-tested.

## Spec 03 schema (v18–v19)

- **v18 `clip_embeddings`**: `file_id` TEXT PK cascade, `embedded_hash TEXT NOT NULL`,
  `model_generation INTEGER NOT NULL`, `vector BLOB` nullable. Content-keyed (same
  grain as `palette`/`feature_print`/`photo_meta`). **A NULL vector is the
  attempted-marker for an undecodable file** (the `places` NULL-place pattern);
  dataless iCloud files are skipped without stamping. Re-embed when the row is missing,
  `embedded_hash != content_hash`, or `model_generation != ClipModel.current.generation`
  (a model upgrade re-embeds the library via the backfill cap).
- Vectors are stored as 512 × Float16 LE (1024 bytes), fp16 per the platform budget.
  Converters live in `Intelligence/Core/ClipVectors.swift`
  (`toData`/`fromData`); `fromData` refuses wrong-length blobs — vectors from
  different generations must never pair (the `FeaturePrints.distance` rule class).
  Centroid math (`ClipCentroid`) lives in the same file: mean then re-normalize.
- **v19 `photo_traits`**: `file_id` TEXT PK cascade, `traits_scanned_hash TEXT NOT
  NULL`, `traits_version INTEGER NOT NULL`, `face_count`, `largest_face_frac`,
  `face_quality`, `pet_count`, `sharpness` (all nullable); indexes on `face_count` and
  `pet_count` only. Faces + pets + sharpness deliberately share ONE table, marker and
  backfill (all derived from one bounded decode); a future trait bumps
  `PhotoTraits.currentVersion` (re-scan) rather than adding a parallel marker.
- A missing `photo_traits` row means "never scanned", and `face_count = 0` means
  "scanned, faceless" — trait tokens (incl. `faces:0`) match scanned files only.
- Records: `ClipEmbeddingRow`, `PhotoTraitsRow`.

## Analysis pipeline additions (Spec 03)

- **The `embeddings` table (NLEmbedding text vectors) is NOT retired by CLIP** — it
  remains clustering's input (`CollectionsEngine` reads `EmbeddingRow` as
  `ClusterItem.textVector`) and feeds `SimilarTagSuggestions`. CLIP replaces the
  semantic *search* leg only, behind `ClipModelStore.isReady`, with the NLEmbedding
  path as the model-absent fallback. `AnalyzePipeline.embeddingsWritten` /
  `ReclusterGate` count TEXT embeddings only — CLIP writes never bump them.
- `VisionServices` runs seven concurrent requests on the one bounded 4096px raster
  (adds `VNDetectFaceCaptureQualityRequest` + `VNRecognizeAnimalsRequest`); every new
  request goes through the single-resume `runRequest` wrapper. `largest_face_frac` =
  max normalized bbox area product; `pet_count` counts observations ≥
  `VisionServices.petConfidenceFloor = 0.5`. Face-quality scores are comparable only
  within a Vision revision — used relatively within one session on one machine
  (recorded limitation).
- `TaggerOutput` gains `traits: TraitFields?` and a `decodedImage: CGImage?`
  passthrough — the analyze pass's raster is reused for traits AND the CLIP embed;
  never decode the same file twice in one pass.
- `SharpnessScore` (`Intelligence/Core/`): log10 variance-of-Laplacian over luminance
  downsampled to `normalizedLongEdge = 1024` — the fixed long edge is what makes scores
  comparable across resolutions. Buckets `softCeiling = 2.5` / `sharpFloor = 3.5`
  (owner-validated).
- The CLIP embedding write is a separate small transaction after the committed guard,
  itself guarded on `content_hash` still matching (the `markAnalysisAttempted` shape).
- `Intelligence/DeepAnalysisBackfill.swift`: launch pass (`maxPerLaunch = 5_000`,
  `concurrency = 2`, `writeChunk = 200`, `decodeMaxPixel = 1024`) — ONE decode per file
  feeds traits + optional CLIP embed. Selection is stale-by-any-marker (traits or,
  when the model is installed, clip). Triggers: launch (chained after
  `PhotoHeaderBackfill`) + model install. Completion with writes chains
  `SearchFacets.refresh()` + `CollectionsEngine.reload()`. Undecodable → NULL-field
  traits row + NULL-vector clip row; dataless → no stamp.

## Retrieval & similarity search (Spec 03)

- `Search/ClipIndex.swift` streams `chunkRows = 4_096` rows per cursor chunk
  (Float16→Float32 unpack + one `vDSP_mmul` per chunk) — memory ceiling is
  chunk-sized, independent of library size; **the no-RAM-residency rule is satisfied by
  streaming now, not by a future rewrite**. sqlite-vec/mmap at the 800k tier swaps this
  enum's body only. **No in-memory vector cache in v1** (measured optimization later).
- Named constants, never validated live (owner validation outstanding):
  `textMinScore = 0.20`, `imageMinScore = 0.55`, `topK = 400`.
- **The semantic merge floor and the `matchedDirs` relaxation floor are one
  engine-selected parameter** (`ClipIndex.textMinScore` when CLIP is ready, else
  `SearchService.semanticThreshold = 0.45`) passed to both — two constants drifting
  apart re-opens the folder-restriction bleed. The CLIP text encode is `await`ed off
  the main actor before the `queue.read`.
- A query with no Spec 03 token and the model absent runs the pre-Spec-03 pipeline
  byte-identically (pinned by test).
- **A similarity query rides the field text as a `similar:<handle>` token** against the
  session-scoped `SimilarityRegistry` (`@MainActor`, handles `s<digits>`, entries carry
  vector + display label) — the committed field text stays the single source of truth.
  Shape-valid parses as a token; an unresolvable handle **matches nothing** (visible
  empty result + removable "Similar (expired)" chip), never silently drops the
  constraint. Handles are session-scoped, never persisted.
- `PhotoSearch.filter` takes a `TokenContext { similarVectors: [String: [Float]] }`
  (amendment to the Spec 02 signature — nothing to migrate). When a `similar` token is
  present, similarity score DESC is the result order (replacing capture DESC); other
  tokens intersect into it. Similar/faces/pets/is tokens are content-derived → no dir
  restrictions.
- All similarity entry points funnel through
  `AppState+Similarity.runSimilarSearch(vector:label:)` (stash → `searchAllFolders =
  true` → programmatic `searchQuery` + `runSearch` seam). Entry points: grid
  context-menu "Find Similar Photos" (single image-kind selection, hidden unless
  `isReady`; stored vector, else a user-initiated 1024px on-the-spot embed), hero
  viewer "Similar" action, and image-drop of a file onto the grid
  (`.onDrop(of: [.fileURL])`, overlay hint; a self-drop from Muse's own grid also
  triggers it — accepted). The native `.searchable` field takes no drops.
- Region similarity: hero-viewer chrome `viewfinder` button (image-kind + `isReady`
  only) enters region mode — marquee ≥ `RegionSearch.minSide = 24` pt; crop is taken
  from a fresh bounded decode of the ORIGINAL at `RegionSearch.decodeMaxPixel = 2048`
  (never the displayed thumbnail); mapping via pure `Components/RegionMath.swift`.
  **Region-mode Escape consumes `viewerClosing` inside the hero's onChange handler and
  returns before `startClose()`** — the hero close sequence is untouched;
  `EscapeResolver` is unchanged by region mode.

## `.similar` smart rule (Spec 03)

- `SmartRule` gains `case similar(SimilarTerm)`; `SimilarTerm = { anchorIDs: [String],
  prompt: String?, promptVector: [Float]?, promptGeneration: Int?, threshold: Double }`.
  Codable fully synthesized (same older-build decode-empty consequence as `.location`).
  `thresholdRange = 0.40…0.80`, `defaultThreshold = 0.55`, `maxAnchors = 20` (all
  owner-validated).
- **Prompt vectors are encoded at rule-SAVE time and stamped with the model
  generation; `SmartCollectionResolver` never runs the model.** No resolvable vector
  (model absent, anchors unembedded, stale generation) → the rule evaluates EMPTY and
  heals via `ClipPromptVectors.refreshAll()` (re-encodes stale prompts on model
  install/upgrade). Anchor evaluation: PK-fetch vectors → `ClipCentroid` → 
  `ClipIndex.matches(minScore: threshold)`.
- Re-evaluation as new photos are analyzed comes free from the existing reload chain
  (analyze → recluster → `CollectionsEngine.reload()` → `fetchAll` re-resolves) plus
  the backfill-completion reload — no new machinery.
- Editor: rules-card Kind "Looks Like" (plain vocabulary), offered only when
  `isReady`; prompt `TextField` + Broad↔Exact threshold `Slider`. Anchor-driven rules
  show "N reference photos" + slider — **the anchor list has no editor in v1** (the
  `ColorTerm.hex` precedent). Anchors are minted by grid context-menu "New Smart
  Collection from Selection" (1–20 image-kind selected AND `isReady`; opens the rules
  card via the `AppState.collectionModal` seam).

## Natural-language search layer (Spec 03)

- macOS 26+ only, gated exactly like `FoundationModelNamer`
  (`#if canImport(FoundationModels)` + `#available` + `SystemLanguageModel.default
  .availability == .available`). Below the gate the path is inert — free text goes to
  CLIP + FTS as normal.
- `@Generable NLSearchIntent` (year/month/place/camera/minStars/subject) → pure
  `NLTokenComposer.compose` → **token text round-tripped through `SearchQueryParser`**
  — the parser stays the single source of truth; a composed text that parses to zero
  tokens is dropped silently.
- **Suggestion-only**: `NLQuerySuggest` (Pattern B, request-token-guarded) fires after
  a committed search with zero tokens and ≥ `minWords = 3` words, never blocks the
  search, and never rewrites the query unclicked. Surface: one `sparkles` pill in the
  `TagChipsRow` active-filter row ("Try: …"); clicking runs the composed text through
  the programmatic search path (tokens then individually editable/removable).

## Compare & focus peaking (Spec 03)

- `Models/CompareStore.swift` (Pattern B): `urls: [URL]?` (2…`maxPanes = 4`),
  `focusedIndex`, shared `zoom` (1…8) + normalized `center`, `peaking`. Compare never
  coexists with the hero viewer; it is a full-screen surface, NOT a modal card — it
  gates `PageScrollCatcher.isActive` directly and Escape resolves `.closeCompare`
  (modal cards raised over compare still win).
- Entry: grid context-menu "Compare Side by Side" (2–4 image-kind selected, hidden
  otherwise) + menu-bar command ⌘⇧C. Cull: menu-bar "Start Culling" ⌘⇧K.
- Pane decode ladder = the hero's exact formula (`min(max(dim × scale × 2.5, 1600),
  4096)`) through `withinDecodeBudget` first — compare gets full-window-class decode
  targets, not grid thumbnails. Panes decode directly (no new `renderedVariants`
  entry; only the existing 320 quick-thumb is used).
- Synchronized zoom/pan is pure math (`Components/CompareGeometry.swift`): a
  NORMALIZED center (not points) is what keeps differing aspects looking at the same
  subject region.
- Keyboard (a `KeyCaptureView`-pattern catcher): ←/→ swap the focused pane's candidate
  through `visibleFiles`; Tab cycles focus; 1–5/0 rate via `TagStore.setRating` (the
  only rating seam); K/X cull-mark when a session is active; P toggles peaking.
  Panes call `RediscoveryStore.markViewed` in `.task(id:)`.
- Sharpness badge is RELATIVE within the compared set (`Components/SharpnessRank`,
  `tieBand = 0.15` log10 units); face-quality best-face badge only when every compared
  photo has faces; missing traits row → no badge, never a fake neutral. The hero INFO
  card shows the bucketed sharpness row. No absolute sharpness badge on the grid.
- `Viewers/PeakingOverlay.swift` ports Surface Camera's enum with constants intact
  (`edgeThreshold 0.03`, `highPassRadius 1.5`, `boundaryInset 3`) and two binding
  adaptations: **the `CILinearToSRGBToneCurve` pre-encode is dropped** (Muse's decoded
  input is already display-referred; re-adding it de-tunes the threshold) and **the
  chain runs at `workingLongEdge = 1080`** (the scale the constants were tuned at),
  scaled onto the pane by `align(_:to:)`. Accent = `moodPalette` accent, no raw hex.
  Toggles live in compare chrome + hero chrome (`scope` glyph).
- Spec 04 forward note: compare panes decode originals today and MUST join the
  edit-stack render/`EffectiveDimensions` consumer sweep when the editor lands.

## Ephemeral cull state (Spec 03)

- **Cull state is memory-only by construction**: `Models/CullStore.swift` (Pattern B,
  `marks: [standardized path: .keep/.reject]`) — no table, no UserDefaults key, no
  sidecar field, ever. Quit mid-session = marks gone. A persistence surface for
  keep/reject violates DECIDED #13.
- Marks apply from grid (`PageScrollCatcher` gains a `onCullKey` branch — K/X/U,
  empty-modifier, active-session only; keycode paging/arrow rules untouched), hero
  viewer (`KeyCaptureView` passthrough), and compare.
- Tile badge: **bottom-leading** (top-leading belongs to the stack badge, top-trailing
  to the star badge), rendered only while a session is active, with a named
  `.accessibilityAction` toggle.
- **The cull session is NOT in the Escape chain** — sessions end only via the HUD's
  Finish/Cancel; Cancel confirms with a `ModalMessageCard` when marks exist.
- Resolution: `CullResolveCard` via `.museModal` at the shell, registered in
  `modalPresented`; kept → optional rating via `TagStore.setRating` (default None);
  rejected → `deletion.deleteWithBurn` per file (the grid multi-delete seam — undo
  toast, `dropFromActiveCollection`, selection pruning inherited). No other write
  paths. URLs for off-view marked paths are rebuilt from the standardized path.

## Faces/pets tokens (Spec 03)

- `SearchToken` gains `faces(NumericFilter)`, `pets(NumericFilter)`,
  `traitIs(.portrait|.group)` (keys `faces:`, `pets:`, `is:`). `is:` with any other
  value stays in free text verbatim.
- `Intelligence/Core/PortraitHeuristic.swift`: `portraitMaxFaces = 2`,
  `portraitMinFaceFrac = 0.05`, `groupMinFaces = 3` (owner-validated; single
  declaration site). `is:portrait` = 1…2 faces AND frac ≥ floor; `is:group` = ≥ 3.
- Suggestions: `faces:`/`pets:`/`is:` join the key list; `is:` values are the fixed
  pair; numeric keys suggest static op-form hints (no facet query).
- Trait tokens read no `tags` — "works with tags off" holds.

## Perf baseline additions (Spec 03)

- New recorded rows: CLIP text encode 40 ms · image embed 15 ms · `ClipIndex` 50k scan
  100 ms · semantic leg end-to-end 150 ms (supports < 300 ms perceived) · `.similar`
  rule resolve 120 ms · compare two-pane sharp 1200 ms · backfill ≥ 8 files/s.

## Edit model & storage (Spec 04)

- `EditStack { schemaVersion, processVersion, rawParams: RawParams?, adjustments:
  [Adjustment], masks: [Mask] }`; `currentSchemaVersion = 1`,
  `currentProcessVersion = 1`. Decoding NEVER bumps either version — only newly
  constructed stacks stamp current. `masks` is always `[]` in v1 (reserved slot that
  round-trips in the JSON shape from day one).
- `Adjustment` is enum-tagged with one typed params struct per group, cases in
  canonical order **tone · color · presence · curve · geometry · vignette · toneZone ·
  lut** (the last two from Spec 05), at most
  one per case; `EditStack.normalized()` sorts/dedupes; the renderer iterates its OWN
  fixed chain, never the array's order — reorderability is unrepresentable. JSON via
  an explicit keyed wrapper `{"type": …, "params": …}`; an unknown `type` fails the
  whole-stack decode (detectably), never misparses. **New cases must always APPEND at
  the enum end** — canonical order is declaration order, so mid-list insertion re-keys
  every edited thumbnail and breaks `stack_hash` stability (the pinned fixture hash is
  the tripwire). Neither `schemaVersion` nor `processVersion` bumps for a new case:
  the unknown-`type` whole-stack decode failure IS the forward mechanism (an older
  build renders a new-case stack as the ORIGINAL, blob preserved, detectably).
- Stored units: `ToneParams.exposureEV` in real EV (−5…+5); other scalars −1…+1 (or
  0…1) with `neutral`/`isNeutral`/`clamped()` per struct. Temperature/tint map in
  MIRED, never raw Kelvin. `GeometryParams.crop` is a normalized unit rect in
  display-oriented, straightened coordinates; `appliedDisplaySize(to:)` is the pure
  post-geometry size function layout consumes. `RawParams` holds only what has no
  encoded-source equivalent (`lensCorrection`, `decoderVersion` pinned at first
  edit); the WB/NR/sharpen sliders are stored ONCE (ColorParams/PresenceParams) and
  ROUTED by the renderer per source kind — copy/paste/presets work across RAW↔JPEG
  with one model.
- `EditStackCodec`: canonical bytes = `.sortedKeys` JSON of the normalized stack;
  `stack_hash` = full SHA-256 hex of those bytes (stability pinned by a fixture
  test). `decode` → nil for corrupt JSON or `schemaVersion > current`;
  `processVersion > current` decodes but `EditRenderer.canRender` is false.
- Unrenderable-blob rule: a stack the renderer can't honor renders as the ORIGINAL
  image — never a partial stack — and the stored blob is never rewritten or deleted
  by the render path; only an explicit user edit or Reset overwrites it.
- `EditHistory` is a session-only value type (Surface Camera port: push-dedupe,
  truncate-forward on push, undo/redo), capacity 100, pushed on gesture END only
  (`EditSession.commitGesture` is the single push site). Cross-session persistence is
  the stack + snapshots/versions, never the history.

## Spec 04 schema (v20–v21)

- **v20 `edits`**: composite PK `(file_id, parent_dir)` (`file_id` cascades on file
  delete), `stack` TEXT (canonical JSON), `stack_hash` TEXT NOT NULL,
  `process_version` INTEGER NOT NULL (denormalized), `updated_at` INTEGER NOT NULL.
  One row per (file, folder) = the CURRENT stack. **A neutral stack DELETES the
  row** — "no edit" is the absence of a row (the `NoteStore.write` blank-deletes
  rule), which reverts the thumbnail key to the nil-stack variant.
- **v20 `edit_versions`**: `id` UUID PK, `(file_id, parent_dir)` scope (cascade),
  `kind` `"version"` | `"snapshot"`, `name`, `stack`, `created_at`; index on
  `(file_id, parent_dir)`. Versions and snapshots share one table, differing only in
  surface (version switcher + grid badge vs the before/after compare picker).
- **v21 `edit_presets`**: `id` PK, `name` (no UNIQUE; NOCASE ordering), `stack`
  (geometry group excluded at save), `created_at`, `updated_at`. Library-global.
- Records: `EditRow`, `EditVersionRow`, `EditPresetRow`.
- A virtual copy/version is a SWITCHABLE stack: exactly one current stack (the
  `edits` row) renders everywhere; switching copies the chosen version into the
  current row (auto-preserving the previous current as a version first). Never a
  parallel grid tile — path-keyed identity cannot show one path twice. Reset clears
  the current stack only; versions/snapshots survive a reset.

## Edit carry & identity (Spec 04)

- `EditRecordStore.carry`/`carryAll` mirror `NoteStore.carry`/`carryAll` (INSERT OR
  IGNORE — never clobbers a destination edit; copy-vs-move by the same
  same-dir-sibling rule) and are called BESIDE the existing `NoteStore` call at all
  five rewrite sites: Indexer hash-collision sole-path (`carryAll`), hash-collision
  shared-row, shared-row split, `FileMoveMigration.apply`, and
  `FolderRenameMigration.apply` — which also gives `edits`/`edit_versions` the same
  stale-target pre-clear + `SUBSTR`-prefix `parent_dir` rewrite as tags/notes. Any
  NEW path rewriting `file_id` or `parent_dir` must carry `edits` too. Carried
  `edit_versions` rows get fresh UUIDs.
- Pure edit-in-place (external overwrite, sole alive path) KEEPS the stack —
  parameters are normalized, so they still apply; discarding user edits because the
  bytes changed is the worse failure.
- `analyzed_hash`, `files.width/height`, `content_hash`, and every analysis input
  stay keyed on ORIGINAL bytes; an edit never changes content identity and never
  triggers re-analysis.

## Edit store, provider & save sequence (Spec 04)

- `EditStore` (Pattern B) has ZERO AppState integration — not even a forwarded
  `objectWillChange` cancellable; the grid reads `EditStore.generation` through
  `gridSignature`.
- `LiveEditStackProvider` implements Spec 01's `EditStackProviding` over a
  lock-guarded `nonisolated(unsafe)` static index (the `ImageHeaderSizeCache`
  pattern) keyed by standardized alive path; entries hold
  `(stackHash, geometry, processRenderable)` + a lazily decoded stack. The provider
  does NO I/O, ever; `croppedSize(for:)` =
  `geometry.appliedDisplaySize(to: ImageHeaderSizeCache.cached(url))`, nil when
  either side is unknown. Installed in `MuseApp`'s `.task` before the backfills;
  full index rebuild at launch, `warmIndex(paths:)` per folder load, rebuild after
  move/rename.
- The save sequence, one place, in order: resolve scope via alive path →
  `EditRecordStore.write`/`delete` → update the index entry →
  `appState.markContentChanged([path])` — **the tile-refresh seam for edit saves**
  (it already invalidates both thumbnail-key variants and bumps the tile task token;
  no parallel edits-version channel) → `generation += 1` (relayout — a crop changes
  tile aspect) → `exportSidecarsAfterEditChange`.
- The editor autosaves (400 ms debounce + save on exit/close/flip); there is no
  Done/Cancel — the grid updates live while editing.

## Edit sidecars (Spec 04)

- `Sidecar` gains `edit_stack: String?` + `edit_updated_at: Int64?` (defaults nil —
  pre-edit sidecars decode unchanged). Only the CURRENT stack rides sidecars;
  versions/snapshots are device-local (recorded limitation).
- `Sidecar.merge` resolves edits by the `edit_updated_at` field clock: the greater
  non-nil clock wins; nil never clobbers (union-never-deletes).
- `Sidecar.resolveForWrite` gains `editAuthoritative: Bool = false`; ONLY the
  edit-save/reset export path (`AnalyzePipeline.exportSidecarsAfterEditChange`,
  mirroring `exportSidecarsAfterTagEdit`) passes true — fresh wins including a
  clear; every other export preserves the on-disk edit field.
- `SidecarHydrator` applies incoming edits via `EditRecordStore.applyHydrated`
  (row-level LWW, strictly-newer local wins — the `NoteStore.applyHydrated` shape),
  then refreshes the provider index and invalidates the path's thumbnails.

## Render pipeline (Spec 04)

- Core Image + Metal, zero third-party image dependencies. Working space: extended
  linear sRGB, explicit on every context. Surface's `EncodedImage`/`LinearImage`
  type-safety wrapper ports as `Editing/Render/WorkingImage.swift`: the single
  decode crossing is `EncodedImage.toLinearWorkingSpace()`;
  `CIImage(contentsOf:)` sources enter via `LinearImage.alreadyDecodedFromFile`;
  adjustment methods exist only on `LinearImage` (an encoded image cannot be
  adjusted, by type).
- Fixed chain order (code, never data): decode/orient (RAW via `CIRAWFilter`) →
  geometry → tone (exposure → temp/tint [encoded sources only] → toneBands →
  contrast) → **toneZone** (scene-referred, un-clamped linear, single hue-preserving
  gain — Spec 05) → curve → color (vibrance → saturation) → **lut** (display-referred
  pocket like the curve — Spec 05) → presence (NR → clarity →
  texture → sharpen) → vignette → consumer-side display transform. Scene-referred:
  un-clamped linear until the curve/display stage; highlight recovery must actually
  work (test-pinned).
- The curve is the deliberate display-referred exception: CPU monotone-cubic
  (Fritsch–Carlson) spline → 1024-entry LUT → `CIColorCurves` with an explicit sRGB
  space. `CIToneCurve` is never used anywhere in the app.
- Highlights/Shadows/Whites/Blacks = one custom `[[stitchable]]` Metal
  `CIColorKernel` (luminance-band exposure-space gains, hue-preserving, exact
  identity at 0); Clarity/Texture = one shared stitchable blend kernel
  (midtone-weighted local contrast) invoked at two radius/weight settings. Kernels
  live in `Editing/Render/EditKernels.metal`, compile into the default metallib (no
  `-fcikernel`), load via `CIColorKernel(functionName:fromMetalLibraryData:)`, and a
  load-by-name smoke test gates the build phase. Never CIKL.
- RAW: neutralize Apple's default look (`baselineExposure = 0, shadowBias = 0,
  boostAmount = 0, localToneMapAmount = 0, isGamutMappingEnabled = false`); every
  property set gated on `isSupported(option:)` through one `setIfSupported` helper;
  WB happens ONLY at demosaic (`neutralTemperature`/`neutralTint`, mired offsets
  from the as-shot neutral) — never `CITemperatureAndTint` on a RAW source's output;
  NR/sharpen route to the filter; the decoder version is pinned at first edit
  (`rawParams.decoderVersion`, prefer `.version9`), substituted-not-hidden when no
  longer supported.
- Every scale-dependent parameter (clarity/texture/sharpen radii, vignette feather)
  is a fraction of the SOURCE long edge scaled by the decode ratio;
  `EditRenderConsistencyTests` (one all-groups stack × 2 fixtures × 3 resolutions,
  downsampled agreement) is the permanent gate on any renderer change.
- Contexts: one long-lived preview `CIContext` (`cacheIntermediates: true`, extended
  linear sRGB) + a per-export context (`cacheIntermediates: false`, `memoryLimit`
  1 GB); export sources are lazy `CIImage(contentsOf:)` (CI tiles internally).
  There is NO Extended Virtual Addressing entitlement on macOS (iOS-only). Preview
  never decodes full-res: proxy = the hero ladder formula, capped 4096.
- Slider rendering goes through `RenderCoalescer` (actor): at most one render in
  flight, latest params win, no queue.
- HDR: load `.expandToHDR`; `CIToneMapHeadroom` before display; export writes HDR
  HEIF with gain map on macOS 15+, tone-mapped SDR on 14.6 (recorded limitation);
  unedited files always export original bytes.
- The editor canvas (`EditCanvasView`, MTKView + `CIRenderDestination`) and the CI
  kernels are the app's sanctioned Metal surface (supersedes "no Metal shaders
  remain").

## Edit-aware consumers & exports (Spec 04)

- Binding sweep rule: EVERY surface that displays or ships a photo's pixels consults
  `EditStackIndex` and renders via `EditRenderer.render(url:stack:maxPixel:)` when a
  stack exists — grid thumbnails (`ThumbnailCache.generate` image branch), the hero
  decode ladder (both rungs; every HeroStage guard/curve untouched), compare panes,
  and `OutputRender` (PDF via direct bounded render; Drive/share sheet via a
  full-res rendered temp file). Render failure falls back to original pixels. Backup
  stays the one exclusion (its DB now carries edits/versions/presets).
- Edited thumbnails render at the SAME `renderedVariants` sizes — no new variant.
- `OutputRender` formats are named constants: same container for JPEG (q 0.92) /
  PNG / TIFF / HEIC (q 0.9); RAW renders JPEG q 0.92 sRGB on share paths. Rendered
  temps live in `tmp/muse-render/` with a >1-day launch sweep. The metadata strip
  still runs on POST-render bytes (render first, strip second).
- Grid badge corners are fully assigned: top-leading stack · top-trailing star ·
  bottom-leading cull · **bottom-trailing edited** (`slider.horizontal.3`, count
  appended when versions exist; NOT a click target). `gridSignature` folds in
  `EditStore.generation`; `TileView.drawnAspectRatio` reads `EffectiveDimensions`.

## Editor UI & Theme (Spec 04)

- Editable kinds (Path A) are `.image` and `.raw` ONLY — `.psd` is excluded (its
  flat composite is a preview; editing it is Path B's job).
- The editor lives INSIDE the hero viewer: a (Preview | Edit) segmented control
  top-center; Edit mode swaps the STAGE content and hides the info column — the
  hero open/close choreography is untouched. Edit-mode Escape is consumed in the
  hero's `viewerClosing` onChange (first branch, before region mode) and exits to
  Preview; `EscapeResolver` is unchanged. Arrow-key file flips are DISABLED in Edit
  mode.
- Editor backdrop: flat neutral, five named levels (white 1.0 / light 0.85 /
  **mid 0.48 default** / dark 0.18 / black 0), right-click to switch, persisted as
  `AppSettings.editorBackdropKey`.
- Panels are anchored floating cards (draggable with snap-back; nothing persisted).
  Right card tabs **Light / Color / Looks** (Looks hosts user presets in v1; Spec 05
  replaces the rows with the live-thumbnail browser + LUTs); left card tabs
  **Info / History (+ Snapshots) / Scopes** (Scopes is an empty scaffold — Spec 05's
  mount point). The tone-zone slot is reserved above the Light sliders.
- `CurveEditorView(histogram: CurveHistogram?)` — a 64-bin value type drawn behind
  the curve when non-nil; Spec 04 always passes nil (Spec 05 fills it). This is the
  histogram-behind seam.
- WB eyedropper: encoded sources solve the mired/tint offset from the sampled proxy
  pixel (pure, tested); RAW uses `CIRAWFilter.neutralLocation`, then stores the
  equivalent slider offsets — the stack stays declarative, never a click location.
- Before/after: hold-`\` (or the Before button) peek · ⌘Y side-by-side · split-wipe
  with draggable divider, comparable against Original or any snapshot; implemented
  over cached rendered textures.
- `EditSlider` is the one scalar control: per-slider reset (double-click label/
  value), option-drag fine steps, history push on gesture end.
- New shell modal flags registered in `AppState.modalPresented`:
  `openWithForkRequest` and the copy/paste group-selection card.

## Copy/paste/sync & presets (Spec 04)

- `AdjustmentGroup` = tone / color / presence / curve / geometry / vignette / raw /
  toneZone / lut (rawValues `"toneZone"`/`"lut"`, Spec 05).
  `EditTransfer.adjustedGroups(of:)` (non-neutral groups — the auto-select default;
  never a checkbox wall) and `apply(groups:from:onto:)` are pure; apply is
  COPY-BY-VALUE and a group absent in the source CLEARS it in the target.
- `EditClipboard` is in-memory only — never `NSPasteboard`, never persisted.
- Surfaces: editor chrome + Edit-menu commands (⌥⌘C / ⌥⌘V) + grid context-menu
  "Paste Adjustments" (batch sync over the effective selection; each file runs the
  full save sequence; no progress UI — the status pill stays background-work-only).
- Presets store stacks MINUS the geometry group (a stored crop ambushes every
  applied photo); copy/paste DOES offer geometry. Presets MAY carry the lut group
  (a look is often LUT + tweaks) — geometry stays the ONLY preset exclusion.
  Copy/paste of the lut group copies the reference + strength (safe: LUT data is
  immutable). Application is copy-by-value; a
  stack stores no preset reference; preset mutation happens only via the explicit
  "Update Preset from This Photo" / "Save as New" actions.

## Edit-a-Copy (Spec 04)

- EVERY external hand-off of a file with Muse edits (any Open / Open With path)
  routes through the single `OpenWithItems.open(with:)` seam and presents the fork
  card (`AppState.openWithForkRequest`, shell `.museModal`): Edit a Copy with Muse
  Adjustments (prominent) / Edit Original / Cancel.
- Copy naming: `EditCopyNaming.candidate` — `<stem>-Edit.<ext>`, collision ladder
  `-Edit-2`… (case-insensitive). RAW/DNG copies render 16-bit TIFF (an editing
  master — external editors can't write RAW); other formats keep their container.
- The copy keeps the original's EXIF/IPTC minus orientation — metadata stripping is
  a Drive-share rule, not a local one.
- Flow (ordered, fail-closed): full-res render → move beside the original →
  `Indexer.indexFile` (deterministic — never wait for FSEvents) →
  `StackStore.createStack(kind: "manual", [parentID, copyID], pick: parent)` when
  v17 exists (skipped and recorded until then) → folder reload →
  `NSWorkspace.open` with the chosen app. A render/write failure aborts with an
  alert and writes nothing.
- The copy is a fresh asset: no inherited stack, normal analysis; later external
  saves to it are ordinary edit-in-place.

## Perf baseline additions (Spec 04)

- New recorded rows: slider→canvas render (24 MP, warm context) 50 ms perceived /
  ~16 ms steady-state · edited 320@2x thumbnail 120 ms · 60 MP export < 20 s with no
  memory-pressure kill on the M1 Air 8 GB · editor enter → first draw 400 ms ·
  stack decode + hash < 1 ms.

## Spec 05 schema (v22–v23)

- **v22 `photo_stats`**: adds to `photo_traits` — `clip_high_r`, `clip_high_g`,
  `clip_high_b`, `clip_low`, `noise_sigma` (all REAL nullable);
  `PhotoTraits.currentVersion` 1 → 2, so existing rows are version-behind and
  `DeepAnalysisBackfill` re-scans them under the standing per-launch cap. No new
  table, marker, or index — the Spec 03 version-bump mechanism used as designed.
  `TraitFields`/`VisionResult` gain the five fields; both compute sites ride the
  existing single decode (never a second decode).
- Stored capture stats use FIXED thresholds `ClippingStats.storedHighThreshold =
  254/255` / `storedLowThreshold = 2/255` — never the user's zebra prefs (DB rows
  must not change meaning when a pref moves).
- `Intelligence/Core/NoiseEstimate.swift`: noise sigma = MAD (×1.4826) of the 3×3
  Laplacian over the flattest half of 32×32 luminance tiles, `normalizedLongEdge =
  1024` (the `SharpnessScore` normalization), nil on degenerate input.
- **v23 `edit_luts`**: `id` TEXT PK = content hash (`CubeLUT.hash`, SHA-256 of the
  canonical float bytes), `name`, `size`, `data` BLOB (float32 LE RGB,
  R fastest-varying), `created_at`. Library-global like `edit_presets`, no file
  cascade. Record: `EditLutRow`.

## Edit model additions (Spec 05)

- `ToneZoneParams`: `zoneCount = 9` gains, −1…+1 each, zones spanning −8…0 EV one
  stop apart (`gains[0]` = deepest shadows); `clamped()` also pads/truncates a
  wrong-length array. The EV mapping is renderer-side: `ToneZoneMath.maxZoneEV =
  2.0` (±1 ↦ ±2 EV, owner-tuned constant).
- `LutParams { lutHash, name, strength }`: `lutHash` = the `edit_luts` PK — a
  REFERENCE, never embedded data (a 64³ table is ~3 MB; the stack rides sidecars and
  is hashed per edit); `name` is the display fallback for the missing-LUT notice;
  `strength` 0…1, neutral at 0. At most one `lut` case per stack (no LUT stacking).

## LUT rules (Spec 05)

- LUT rows are IMMUTABLE: import is INSERT OR IGNORE on the content hash (re-import
  dedupes), rename touches `name` only, there is no update path — a `lutHash`
  resolves to byte-identical data or nothing, restoring value guarantees to the
  reference.
- `EditRenderer.canRender` = `processVersion ≤ current` AND every `lut` reference
  resolves. An unresolvable LUT renders the ORIGINAL everywhere (thumbnails / hero /
  exports via `OutputRender`'s identity branch), NEVER a partial stack; the blob is
  never rewritten; importing the matching `.cube` heals every referencing photo
  (thumbnail invalidation + `EditStore.generation` bump). The editor shows the
  original plus a notice row naming the missing LUT with an Import button.
- `Editing/LutRegistry.swift`: nonisolated, LRU cache (`cacheLimit = 8` decoded
  LUTs — never library-resident), miss = one sync `queue.read` of the blob;
  render-path-only — NEVER call it on the main thread. `invalidate(id)` on
  import/delete.
- `CubeLUTParser` (`Editing/CubeLUT.swift`): `maxFileBytes` 64 MB, `maxSize` 128;
  `TITLE` → default display name; non-default `DOMAIN_MIN/MAX` refused
  (`unsupportedDomain` — resampling would misrepresent the look); `LUT_1D_SIZE`
  refused; R fastest-varying pinned by an asymmetric fixture; parse errors carry
  line numbers.
- Render: `CIFilter.colorCubeWithColorSpace` with an EXPLICIT sRGB space (never bare
  `CIColorCube` — P3 shift) + `extrapolate = true` (HDR headroom); strength via the
  `lutMix` kernel.
- `edit_luts` data never rides sidecars (it is in backups via the DB). Recorded
  limitation: a hydrated stack referencing an un-imported LUT renders as the
  original on that device until the same `.cube` is imported there (hash-keyed
  heal, filename-independent).
- `Models/LutStore.swift` (Pattern B): listings only resident (no blobs);
  `importCubes` surfaces per-file failures by filename via the `MuseAlert` seam;
  delete confirms with `referenceCount` (LIKE on the 64-hex id across
  `edits`/`edit_versions`/`edit_presets`).

## Editor readouts & statistics (Spec 05)

- One shared stats tap, piggybacked on `RenderCoalescer` at `statsSampleLongEdge =
  256`, two extra renders per completed frame: display-referred RGBA8 (histogram +
  clipping) and the smoothed-EV zone map. Computed ONLY while a consumer is visible
  (`EditSession.statsVisible` — Light or Scopes tab, Edit mode), never in Preview,
  never full-res, never a second render loop.
- `Editing/HistogramCompute.swift` is pure over raw buffers: `HistogramData` (64
  bins × r/g/b/luma), `ClippingStats` (per-channel high fractions, low fraction,
  clip-mass row centroids), `zoneMass`, and the `CurveHistogram` fill — Spec 04's
  `CurveEditorView(histogram:)` seam is closed by this data.
- `EditSession.stats` is `@Published`; the `zoneEVMap` buffer is NON-published
  (hover sampling reads it imperatively — publishing a per-render buffer would
  re-render panels for nothing).
- **Zebras, the live clipping stats, and the Scopes messages read the SAME two
  AppSettings thresholds** (`editorZebraHighKey`/`editorZebraLowKey`, defaults
  0.98/0.02) — their agreement is structural; never fork the constant. The zebra
  toggle itself is session-scoped (`session.zebrasOn` + the J key in Edit mode),
  never persisted; only the thresholds persist.
- Zebras and the zone overlay are single `[[stitchable]]` kernel passes on the
  ≤-canvas-res display-referred image. New kernels in `EditKernels.metal`, all
  covered by `EditKernelLoadTests`: `zebraStripes`, `zoneHatch`, `toneZoneGain`,
  `tzSquare`, `tzLinearCoeffs`, `tzApplyCoeffs`, `lutMix`.
- Raw-sensor (pre-demosaic) clipping is SKIPPED, never approximated — `CIRAWFilter`
  exposes no cheap pre-demosaic tap; display clipping is what the zebras mean.
- `Editing/ClippingMessages.swift`: deterministic, stats-only (`messageFloor =
  0.001`, `channelDominanceRatio = 3.0`); spatial hints come from the clip-mass row
  centroid → top/middle/bottom phrasing — NEVER scene semantics.
- Histogram drag-to-adjust: left third → blacks, right third → exposure, middle
  inert; live draft writes with `commitGesture()` on gesture end (the `EditSlider`
  contract); the accessible parallel path is the Light sliders themselves.
- The Scopes-tab scaffold is replaced by `Views/Editor/ScopesPanel.swift` +
  `Views/Editor/HistogramView.swift`.

## Tone-zone control (Spec 05)

- Render stage 2b (`Editing/Render/ToneZoneFilter.swift`): log2-luminance guide at
  ≤ 1024 px, self-guided guided filter (`guidedRadiusFraction = 0.05` × long edge —
  scale-normalized like every pipeline radius; `guidedEpsilon = 0.25`), application
  = `exp2(Σ weight_i · gain_i · maxZoneEV)` as a single gain on RGB. Exact identity
  at zero gains.
- Pure math in `Editing/ToneZoneMath.swift` (raised-cosine partition-of-unity
  weights, end-zone clamping); the Metal kernel mirrors it, pinned through the
  consistency/neutrality goldens.
- `smoothedEVMap` is ONE pipeline serving the render stage, the stats tap, and the
  zone overlay — three consumers, one mask, by construction.
- The zone strip (`Views/Editor/ToneZoneStrip.swift`) mounts in Spec 04's reserved
  Light-tab slot; per-cell vertical drag adjusts gains; the accessible fallback is a
  disclosure of 9 standard `EditSlider`s (that IS the VoiceOver path — the strip
  drag needs no parallel accessibility action).
- Scroll-to-adjust lives behind an explicit TARGET MODE (the WB-eyedropper pattern —
  plain scroll keeps zooming the canvas); the hover readout samples the SMOOTHED
  mask EV so the number shown is the number scrolled; Escape consumes targeting
  INSIDE the hero's edit-mode branch before exiting to Preview — `EscapeResolver`
  unchanged.
- Zone overlay: `zoneHatch` where the hovered zone's weight ≥ `overlayWeightFloor =
  0.5`; hover-scoped, Edit mode only.
- **`EditRenderConsistencyTests`' all-groups fixture must include every renderable
  group, current and future** — a new chain stage lands inside the standing
  3-resolution thumbnail/screen/export gate in the same commit (toneZone + lut are
  in it now; tolerance unchanged).

## Photo feedback (Spec 05)

- `Editing/PhotoFeedback.swift` is a DETERMINISTIC rule table, Swift-declared —
  never an external data file (xcstrings extraction can't see one) and NEVER an
  LLM. Inputs come only from precomputed columns (`photo_meta` + `photo_traits`,
  read by `Database/PhotoStatsQueries.feedbackInputs` inside the hero's existing
  details load) — the surface must never trigger a decode or query-time analysis.
- Fixed severity order clipping → shadows → motion blur → noise → soft → thin
  focus; `maxNotes = 3`; an empty result renders NO card (silence is a feature).
  Flash suppresses the motion-blur note; motion blur suppresses the soft note
  (cause beats symptom). Named thresholds, one declaration site each:
  `clipNoteFloor 0.002`, `shadowNoteFloor 0.02`, `noiseISOFloor 3200`,
  `thinApertureCeiling 2.0`, `handheldFallbackFocal 50`, `noiseSigmaQuiet`
  (owner-tuned). Absent input fields never fire a rule.
- Surfaces: a hero INFO-column card "WHY IT LOOKS THIS WAY" (global last-choice
  collapse via `AppSettings.feedbackCardExpandedKey`, the colorsCard
  @State-seeded pattern) + the editor Info tab — which also shows the RAW process
  line (pinned decoder vs live support, substitution stated; the Spec 04
  recorded-not-hidden promise surfaced).
- Localized display text lives on the typed cases via `String(localized:)` format
  keys; tests assert typed notes, not strings (English-host rule).

## Looks browser & reference view (Spec 05)

- The Looks-tab rows are replaced by the browser grid (Presets + LUTs sections),
  every look rendered live on the CURRENT photo: base proxy decoded ONCE at 200 pt
  × 2 through `withinDecodeBudget`, the draft's geometry applied, then one
  `EditRenderer.apply` per look; latest-wins sweep with `looksRefreshDebounce =
  400 ms`. Thumbs are session-memory only — never `ThumbnailCache`, never disk, no
  `renderedVariants` entry. The strength slider appears only for the applied
  LUT-based look.
- A preset click is `EditTransfer.apply` copy-by-value; a LUT click writes
  `LutParams`; either is exactly one `commitGesture()` undo step.
- `Models/EditReferenceStore.swift` (Pattern B): `{ url, paneVisible }`,
  memory-only, never persisted. Set via the grid context menu "Use as Reference
  Photo" (single image-kind selection); no in-editor picker in v1. The pane renders
  the reference THROUGH ITS OWN edit stack via `EditRenderer.render` (the
  consumer-sweep rule), fit-only, no zoom sync; any active before/after compare
  mode hides the pane until it returns to `.off`.
- The status pill stays background-work-only: stats taps, looks sweeps, and LUT
  imports report nothing to it. Spec 05 adds zero AppState `@Published` properties.

## Perf baseline additions (Spec 05)

- New recorded rows: stats tap ≤ 3 ms per coalesced render · zebra pass ≤ 4 ms ·
  toneZone stage ≤ 15 ms on a 24 MP proxy · zone overlay ≤ 8 ms · 30-look browser
  refresh < 1 s · 64³ `.cube` import < 300 ms · warm LUT stage ≤ 5 ms ·
  `DeepAnalysisBackfill` v2 throughput ≥ 8 files/s.

## Import surface (Spec 06)

- **Spec 06 adds NO migrations** — every write lands in existing tables (`tags`,
  `notes`, `edits`/`edit_presets`, `photo_meta`/`files.lat/lon`, `collections`).
  Future specs still continue at v24.
- One **File > Import submenu** (five items: Metadata & Lightroom Edits · Lightroom
  Presets · Apple Photos · Google Takeout · Eagle Library). Items whose spec
  dependency is unbuilt are ABSENT, not disabled.
- `AppState.importModal: ImportModal?` (enum payload: `.metadata` / `.labelMapping`
  / `.lightroomPresets` / `.applePhotos` / `.takeout` / `.eagle` / `.report`)
  **replaces** `metadataImportRequest` 1-for-1 — one shell-modal flag for all import
  UI, net-zero AppState property count, registered in `modalPresented`; card swaps
  (run → label sheet → report) are phase changes of the one flag, never stacked
  modals.
- Every import run card: built only while presented, `.onAppear` starts the model,
  `.onDisappear` cancels it; applied work stays; re-runs are idempotent (the
  shipped `MetadataImportSheet` contract, kept for all five sources).
- One shared `ImportReport` + `ImportReportCard` for every source: counts,
  per-label outcomes, `unsupportedSliders` disclosure, stated-plainly `notices`.
  Models accumulate; the card computes nothing.
- **Every import writes through existing seams only**: tags via
  `MetadataImportApply.applyKeywords` (insert-or-promote manual; rating-glyph
  labels dropped), ratings via `TagStore.setRating` behind
  `MetadataImportRules.ratingToApply` (gap-fill), notes via `NoteStore` (fill-gaps),
  edits via `EditStore.save` (never clobbers), collections via
  `CollectionStore.createManual(name:fileID:)`/`addFile` (added_by `'manual'`).
  A new source is a reader + a mapper, never a new writer.
- Destination/root handling for every source: a picked folder outside all roots is
  added via `BookmarkStore.addRoot` first (the shipped trailing-slash containment
  check); copied files are indexed deterministically via
  `Indexer.indexBatch(priority: .high)` in ≤ 50-file batches — never wait for
  FSEvents.

## Universal metadata layer (Spec 06)

- `MetadataKeywordReader` keeps its name, entry point, and guarantees;
  `Extracted` gains `label`, `title`, `caption`, `creator`, `coordinate`. Per-field
  priority stays sidecar → embedded XMP → embedded IPTC; existing keywords/rating
  behavior is pinned byte-identical by test.
- `XMPGPS` (pure): parses XMP-format `exif:GPSLatitude/Longitude` strings
  ("DD,MM.mmmH") — the one coordinate source `PhotoHeaderReader` structurally
  cannot reach (sidecar-only RAW workflows); rejects non-finite/out-of-range.
- Title/caption/creator land in the per-`(file_id, parent_dir)` **note** via pure
  `ImportedText.note` (order title · caption · "© creator", newline-joined,
  case-insensitive dedupe, 2 000-char cap), **fill-gaps only** — an import never
  overwrites an existing note; sidecar export rides the NON-authoritative path.
  Never `files.caption` (Vision-owned, content-keyed).
- `ImportSupplement.apply(db:fileID:contentHash:header:external:)` is the one
  writer for externally-sourced GPS/dates (XMP GPS, Takeout JSON, PHAsset):
  **header-wins / external-fills-gaps per field**, writes `files.lat/lon` +
  `photo_meta`, stamps BOTH markers (`coords_scanned_hash` +
  `exif_scanned_hash` = content_hash), row-guarded on the hash. `(0,0)`
  coordinates are absent, never null island.
- **Spec 02 amendment A1**: `AnalyzePipeline.analyzeOne` and `PhotoHeaderBackfill`
  SKIP their photo_meta/coords write when both markers already equal
  `content_hash` — else the first analyze pass clobbers supplement-imported
  GPS/dates with header NULLs. Recorded limitation: an edit-in-place stales the
  markers, the header is re-read, and supplement values drop until re-import.
- Runs that applied supplements chain `GeocodeBackfill.run()` then
  `SearchFacets.refresh()` (when built), fire-and-forget.

## Color labels (Spec 06)

- Label tags are ordinary manual tags stored with the canonical-English prefix
  **`"Label: "`** (`LabelTag.prefix`); chips render visually distinct (outline +
  `tag` glyph). Rename/delete/filter/smart-`.tag` behavior is standard.
- **The tag-search leg excludes `LabelTag.isLabel` rows** unless
  `LabelTag.queryTargetsLabels(query)` (query contains "label") — a workflow
  marker must never answer a content color query. Pinned by test: "red" ∌
  `Label: Red`; "label: red" ∋.
- `LabelMapping.Choice` = `.skip` / `.namespaced` / `.tag(String)`; default
  `.namespaced`; mapping targets refuse ★-runs (enforced inside
  `resolvedLabel`, not per caller). Choices persist in UserDefaults
  (`AppSettings.importLabelChoicesKey`) keyed by the RAW source string (localized
  LR label names are distinct keys, deliberately). All values remembered → the
  sheet is skipped and choices apply silently.
- Labels are accumulated during the scan (value → alive paths) and applied after
  the mapping decision, in `queue.write` chunks through `applyKeywords`.

## Lightroom import (Spec 06)

- **The import envelope is the enumerated field list in `LightroomXMP`**: crop /
  CropAngle / orientation (exact); WB, Exposure2012, Contrast2012, Vibrance,
  Saturation (directional); ToneCurvePV2012 + per-channel (as curves). Presence of
  the `2012`-suffixed keys IS the process-version gate — no `crs:ProcessVersion`
  parsing. Everything else (Highlights/Shadows/Whites/Blacks 2012, Clarity,
  Texture, Dehaze, grain, post-crop vignette, local corrections, retouch, looks)
  is parse-detected ONLY for the report's unsupported disclosure. The list may not
  grow without a foundation-doc change.
- Conversions (named constants, single declaration site): Exposure2012 →
  `exposureEV` clamped ±5 · Contrast/Vibrance/Saturation ÷ 100 · encoded WB =
  `Incremental*` ÷ 100 · RAW WB = (mired(crs:Temperature) − mired(as-shot)) /
  `TemperatureMap.miredPerUnit`, where that constant is the RENDERER's own mired
  mapping hoisted into `Editing/Render/` and shared by renderer and importer —
  the imported number means what the slider means. As-shot neutral comes from
  `CIRAWFilter` off-main; absent → WB skipped + report notice. Curves ÷ 255;
  identity curves dropped; > `CurveParams.maxPoints` keeps endpoints and evenly
  subsamples the interior. EXIF orientation 1–8 → quarterTurns/flips via a pure
  table; the CropAngle sign is pinned by an owner-verified fixture.
- **`EditStack` gains `origin: EditOrigin?`** (case `lightroom`), nil-omitted from
  the canonical JSON — every pre-existing stack's canonical bytes and `stack_hash`
  are byte-identical (the original pinned fixture hash must never change; a second
  fixture pins the origin shape). Origin is provenance, not data: never copied by
  `EditTransfer.apply` (target keeps its own), stripped at preset save, gone on
  Reset; rides sidecars via the stack JSON; older builds decode it away harmlessly.
- The LR importer **never clobbers an existing Muse edit** (existing `edits` row →
  skip + count; re-runs idempotent), never pins `rawParams.decoderVersion` (first
  USER edit does), never writes a neutral mapped stack, and applies via the full
  `EditStore.save` sequence per file (sequential; no progress UI beyond the run
  card — the status pill stays background-only).
- The before/after suite gains a **"Lightroom preview"** compare source when
  `stack.origin == .lightroom` and an embedded preview exists —
  `EmbeddedPreview.image` uses `CGImageSourceCreateThumbnailAtIndex` with
  `ThumbnailFromImageIfAbsent: false` (embedded bytes only, never a primary
  decode), through `withinDecodeBudget` first.
- **LR preset `.xmp` import** (the Spec 05 deferral, landed): same parser/mapper
  with no as-shot context; geometry stripped; `origin = .lightroom`; named from
  `crs:Name` else the filename stem with a ` 2` collision ladder (courtesy —
  `edit_presets` has no UNIQUE); per-file failures surfaced by filename.

## Apple Photos import (Spec 06)

- Entitlement `com.apple.security.personal-information.photos-library` in BOTH
  entitlement files + `NSPhotoLibraryUsageDescription`; authorization
  `.readWrite` (PhotoKit's read level); `.limited` selections handled
  transparently.
- PhotoKit's iCloud-Photos fetches (`isNetworkAccessAllowed = true`) are
  OS-mediated system traffic — the StoreKit/`bird` doctrine class, NOT an app
  network path.
- Supported path is current-version render only: images via
  `requestImageDataAndOrientation(version: .current)` (extension corrected to the
  returned UTI), videos via `PHAssetResource` `.fullSizeVideo` else `.video`;
  filenames from `PHAssetResource.originalFilename` with a case-insensitive
  collision ladder; copied into a user-chosen destination.
- Metadata carried: `PHAsset.creationDate`/`location` via `ImportSupplement`;
  favorites → the `Favorite` manual tag or skip (per-card choice; **never a
  star** — a binary flag must not fabricate a rating); user albums →
  find-or-create manual collections by case-insensitive name; smart albums
  skipped. Idempotent: existing destination filename → skip + count.
- **Apple Photos keywords are not importable** (PhotoKit exposes no keyword API) —
  stated plainly in the card and report. AAE/`PHAdjustmentData` is never parsed;
  the "edits applied, adjustments unrecoverable (private format)" message is
  required UI.

## Google Takeout import (Spec 06)

- Takeout folders are imported **in place** (no copy) — the extracted archive is
  ordinary files; Muse references them where they live (added as root if
  uncovered).
- `TakeoutJSON.jsonCandidates` ladder, best-first, each rule test-pinned:
  `<name>.<ext>.supplemental-metadata.json` → `<name>.<ext>.json` →
  duplicate-counter swap (`IMG(1).jpg` ↔ `IMG.jpg(1).json`) → edited-suffix strip
  (localized suffix list constant) → 46-char truncation re-derive.
  `photoTakenTime.timestamp` is a STRING epoch; `geoData` falls back to
  `geoDataExif`; `(0,0)` → absent.
- Apply: supplement (dates/GPS) · `description` → note (fill-gaps) · `favorited` →
  `Favorite` tag (per-card choice) · people names → plain tags or skip, default
  SKIP, never face identities. `-edited` siblings both receive the original's
  JSON metadata; no auto-pairing/stacking of edited↔original.

## Eagle import (Spec 06)

- **Verification-first is binding**: the parser is written against a real scratch
  `.library` created in Eagle; the test fixture is a miniaturized real library.
- Copy once, flat, via `FileManager.copyItem` (source read-only, never
  `FileMover.move`); destination-name-exists → skip (idempotent); ` 2` ladder for
  distinct-item collisions; sequence copy → indexBatch → apply.
- Eagle folders → find-or-create manual collections, nested names flattened
  "Parent – Child"; tags → manual tags; star → gap-fill rating via
  `TagStore.setRating`; **annotation → note** (fill-gaps — supersedes the
  2026-07-07 future-features doc's "dropped", which predated v11 notes). Dropped:
  URLs, smart folders, Eagle palette data.

## Analysis throttling & import-size FYI (Spec 06)

- `ThrottlePolicy` (pure): `userPaused` OR thermal `.serious`/`.critical` →
  `.paused`; on-battery OR Low Power → `.reduced`; else `.normal`. Concurrency:
  normal = `AnalyzePipeline.analyzeConcurrency` (3), reduced = 1, paused = 0.
- `WorkThrottleStore` (Pattern B, ZERO AppState integration): monitors
  thermal-state / power-state notifications + IOKit power sources (public
  `IOPS*` API, no entitlement); `waitUntilRunnable()` suspends while paused,
  cancellation-safe.
- `userPaused` persists (`AppSettings.analysisPausedKey`, default false) across
  relaunch; thermal/battery states are live-only, never persisted. **Pause is
  scheduling, never an off switch** — markers, selection logic, and data paths
  are untouched (DECIDED #22 intact); there is still no analysis toggle.
- Spawn gates: `AnalyzePipeline.analyze(folder:)` gates BOTH spawn sites on
  `waitUntilRunnable()` and re-reads concurrency per spawn — in-flight files
  finish, the pass claim is held across a pause, cancel still works.
  `PhotoHeaderBackfill`/`GeocodeBackfill`/`DeepAnalysisBackfill` gate once per
  write chunk; their `.utility` priority is unchanged. **Import runs themselves
  are never throttled** (foreground, cancellable).
- `AnalysisStatusStore` (Pattern B): `analyzableTotal`/`pending` `@Published`;
  `secondsPerFile` EMA (α = 0.1) deliberately NON-published; `refresh()` is one
  off-main count query, ≤ 1 per 5 s, token-guarded, triggered by index batches,
  analyze completions, and backfill chunks; `analyzeOne` reports per-file
  durations via `recordCompletion`.
- Progress surfaces: a Settings **Library** row ("X of Y analyzed" +
  Pause/Resume + state line) and a sidebar footer row above
  `CreateNewMenuButton`, visible only while `pending > 0` AND (running OR
  paused). **The status pill is untouched** (background-work-only rule and
  inputs unchanged).
- `AnalysisEstimator`: `calibrationMinimum = 200` completions before any estimate
  exists (measured on-device EMA — never hardcoded); `fyiThresholdSeconds =
  25 × 60` (owner-tunable). The FYI is a one-button `ModalMessageCard` via the
  `alertRequest` seam: shown at most once per launch, only when pending grew ≥
  `calibrationMinimum` since launch AND the estimate exceeds the threshold;
  below threshold fully silent; never a choice dialog, never a skip path.

## Perf baseline additions (Spec 06)

- New recorded rows: metadata scan ≥ 30 files/s · `LightroomXMP` read + map
  < 2 ms/file (RAW as-shot resolve recorded separately, < 80 ms, WB-carrying RAW
  only) · Takeout match + parse < 1 ms/file · `AnalysisStatusStore.refresh` at
  100k rows < 30 ms · Apple-export and Eagle-copy throughput recorded with no
  target (PhotoKit/disk-bound).

## Spec 06 as built (2026-07-31, `new-product-build-1`)

*Where this disagrees with the "Import surface (Spec 06)" sections above, this
section wins.*

### Scope actually shipped

- Built: the whole plan. One `File > Import` submenu over five sources;
  `ImportModal` replacing `metadataImportRequest`; the extended
  `MetadataKeywordReader`; `XMPGPS`; `ImportedText`; `ImportSupplement`;
  `LabelTag`/`LabelMapping` + the search exclusion + the mapping card + chip
  styling; `ThrottlePolicy`/`WorkThrottleStore` + the four spawn gates;
  `AnalysisStatusStore`/`AnalysisEstimator` + the Settings/sidebar surfaces and
  the FYI; `TakeoutJSON` + the Takeout flow; `EagleLibrary` + the Eagle flow;
  the Apple Photos flow (entitlement + usage string); `LightroomXMP` +
  `LightroomEditMapper` + `EditStack.origin` + the apply leg +
  `EmbeddedPreview` and its compare source; LR preset import.
- **Spec 06 added NO migrations**, as specified. Future specs continue at v24.
- **NOT done: the French localization pass.** New user-facing strings are
  localizable (SwiftUI text literals / `String(localized:)`) but the `fr` values
  are unfilled, so the export does not report 0 untranslated. This is the one
  outstanding checklist row from the plan's Task 24.
- Not done (plan steps that require the running app or the owner): the manual
  runtime verifications (Low Power → `.reduced`, a real Photos library import, a
  real Eagle/Lightroom round trip).

### Fixtures — deviation from the plan

- The plan asked for owner-produced binary fixtures (a real Eagle scratch
  library, real Lightroom exports) bundled under `MuseTests/Fixtures/`. **That
  directory does not exist in this repo and no test in the shipped suite uses a
  bundled resource** — every fixture is code-generated. Spec 06 follows the
  house pattern instead: the Lightroom fixtures are XMP authored INLINE in
  `LightroomImportTests` (XMP is a text format, so the exact `crs:` shape being
  asserted stays visible in the test), and the Eagle fixture is a miniature
  `.library` written to a temp directory by the test itself.
- Consequence, recorded honestly: `LightroomXMP`/`EagleLibrary` are verified
  against the DOCUMENTED formats, not against output captured from the real
  apps. Two things in particular are unverified against a real render and should
  be checked when the owner has the apps to hand: **the `crs:CropAngle` sign**
  (mapped as `straightenDegrees = −cropAngle`) and the real Eagle
  `metadata.json` field names.
- The XMP fixtures must be written in ELEMENT form (`<crs:Exposure2012>…`), not
  RDF attribute shorthand — `CGImageMetadataCreateFromXMPData` returned nil for
  the attribute form in this suite.

### Import surface — as built

- `ImportModal` cases carry a request struct each (`MetadataImportRequest`,
  `LabelMappingRequest`, `LightroomPresetImportRequest`,
  `ApplePhotosImportRequest`, `TakeoutImportRequest`, `EagleImportRequest`,
  `ImportReport`); `id` is `<case>-<request.id>`. `ContentView.importCard(_:)` is
  the single case→card map, one `.museModal` at width 420.
- **Every run card has an explicit `.options` phase with its own Import button.**
  The plan's "toggle shown pre-scan" is unreachable under the shipped
  `.onAppear`-starts contract (the scan begins before the user can touch the
  toggle), so cards that carry choices — metadata (LR edits), Takeout (people /
  favorites), Apple Photos (albums / favorites), Eagle (confirm) — start on
  options and run on the button. `.onDisappear` still cancels; the preset card,
  which has no choices, still starts on appear.
- `AppState.coveredFolder(_:)` is the shared "standardize + add as root when
  uncovered" helper all five pickers use (the shipped trailing-slash rule).
- The metadata run's report notices name the approximation explicitly; an empty
  count row is OMITTED from `ImportReportCard` rather than rendered as "0".

### Universal layer — as built

- `MetadataKeywordReader.read(url:)` is unchanged; the new work rides
  `readFull(url:includingLightroom:)`, which returns `(Extracted,
  LightroomEdits?)` from the SAME metadata resolve — one pass, zero extra I/O.
  Sidecar `crs:` wins over embedded (Lightroom writes current develop settings
  to the sidecar; an embedded block can be an older export).
- `Extracted.coordinate` is a nested `MetadataKeywordReader.Coordinate` struct,
  not a tuple (tuples break `Equatable` synthesis) — the plan's own preferred
  option.
- `XMPGPS.parse` bounds magnitude at 180 and `coordinate(lat:lon:)` applies the
  PER-AXIS bound (90 / 180). The plan's test expecting `parse("95,00.000N") ==
  nil` was internally inconsistent — `parse` cannot know which axis it holds —
  so the axis rule is asserted through `coordinate` instead.
- Amendment A1 needed NO new code: `AnalyzePipeline.writePhotoHeader(db:…)`
  already returns early when both markers equal the content hash (it shipped
  that way in Spec 02), and `PhotoHeaderBackfill` calls the same function.

### Lightroom — as built

- `LightroomXMP.unsupportedFields` is the closed detection list; a zero-valued
  slider is NOT reported. `presetName` (`crs:Name`) rides the same struct so the
  preset importer needs no second parser.
- The renderer's mired constant was NOT hoisted into a new `TemperatureMap`
  type — `MiredMapping` already lives in `Editing/Render/RawSource.swift` and is
  the single declaration site, so the importer reads it directly.
- Contrast maps to `ToneParams.contrast` (where it lives), not `ColorParams`;
  curves map to `CurveParams.rgb/red/green/blue` (there is no `.points`). The
  plan's test snippets named both incorrectly.
- `RawAsShot.neutral(for:)` (in `MetadataImportModel.swift`) reads
  `CIRAWFilter.neutralTemperature`/`neutralTint` off-main, gated to RAW files
  whose sidecar actually moves WB. Missing → WB skipped + a report notice.
- `EditPresetStore.createImported(name:stack:)` is the preset-import write path:
  geometry excluded (the shipped rule) but origin KEPT, with a case-insensitive
  ` 2` name ladder via the pure `EditPresetStore.uniqueName`.
- The before/after "Lightroom preview" source is `EditSession
  .compareEmbeddedPreview` + `renderEmbeddedPreview()`, offered in
  `EditVersionsList` only when `draft.origin == .lightroom` AND
  `EmbeddedPreview.image` is non-nil, with the base-look caveat rendered under
  it. The editor Info tab shows an "Approximated from Lightroom" badge.

### Apple Photos / Takeout / Eagle — as built

- Apple Photos: `INFOPLIST_KEY_NSPhotoLibraryUsageDescription` is set on both app
  build configs (the target uses a GENERATED Info.plist — there is no
  `Info.plist` file to edit); the entitlement is in both `.entitlements` files.
  `ApplePhotosImportModel.collisionName` and `.Phase.denied` are the tested
  pure/observable seams. Videos stream via `PHAssetResourceManager`; images use
  `requestImageDataAndOrientation(version: .current)` with the returned UTI
  correcting the extension. Album recreation is user albums only.
- Takeout is in-place (no copy) and the sidecar match runs through
  `TakeoutImportModel.sidecarMeta`, which walks `TakeoutJSON.jsonCandidates` and
  takes the first existing, non-empty sibling.
- Eagle copies flat with `FileManager.copyItem`, skips a destination filename
  that already exists (idempotent re-run) and still applies that item's
  metadata, and uses `EagleImportModel.uniqueName` for distinct-item collisions.
  Star → gap-fill rating through `hasRating` + `MetadataImportRules
  .ratingToApply`; annotation → note; folders → find-or-create manual
  collections by flattened name.

### Throttle & status — as built

- `WorkThrottleStore` parks continuations while `.paused` and releases them all
  when the mode lifts; `currentConcurrency` is re-read per spawn.
  `AnalyzePipeline.analyze(folder:)`'s priming loop was restructured into a
  `while !shouldStop` that gates, then checks width and pulls the next item.
- `AnalysisStatusStore` takes a weak `host: AppState` installed in `MuseApp`
  (the `EditStore.installHost` shape) — there is no `AppState.shared` — and
  raises the FYI through the existing `alertRequest` seam. `secondsPerFile` is
  fed by a `defer` in `analyzeOne`.
- Both stores are observed directly by `SettingsView` and `SidebarView`; neither
  has an AppState cancellable. Spec 06 added zero `@Published` properties to
  `AppState` (the `importModal` swap is net-zero).

## Share manifest v2 & page layouts (Spec 07)

- **Spec 07 adds NO migrations** — social export persists nothing (an explicitly
  saved crop rides Spec 04's `edit_versions`); portfolio records ride the existing
  `driveShares.json` (`DriveShareStore`), never SQLite. Future specs still continue
  at v24.
- `DriveShareManifest` v2 keys: `y` = layout (`DriveShareLayout.rawValue`:
  `"grid"`/`"sheet"`/`"essay"`; absent = grid), `s` = bodyText (intro paragraph),
  `m` = manifestID (portfolio pointer, Drive file id). **Every new manifest field is
  optional with a nil default** — a manifest not using a feature encodes none of the
  new keys, and legacy fragments decode forever (pinned by tests on both the Swift
  and node sides).
- `DriveShareLayout` raw values are the wire values; the page's `layoutOf` must match
  them exactly (the two-implementations-one-contract rule class); unknown/absent `y`
  renders grid (forward-compat fallback, never a rejection).
- App-side publish guards mirror the page validator: `DriveShareManifest.maxImages =
  1000`, `maxFieldLength = 4096` (filenames 1024) — the app may never mint a link its
  own page rejects.
- `validateManifest(m, opts)`: `e` (strict date-only) stays REQUIRED for
  non-portfolio manifests — the fail-open guard is never loosened. `m` present ⇒
  portfolio ⇒ never expires, `e` ignored; manifests fetched from Drive validate with
  `{portfolio: true}` and get full structural validation otherwise.
- The three layouts are CSS off one `data-layout` attribute; ONE tile-builder DOM
  path serves all of them (captions, lightbox, sanitize, deterrents inherit). The
  grid sizer is layout-parameterized (`SIZER_BY_LAYOUT`) and hidden in essay.
- `DriveShareManifest.jsonData()` is the plain-JSON encoding used for the uploaded
  `manifest.json`; the fragment keeps `encoded()` (base64url + optional DEFLATE)
  unchanged.
- `AppSettings.driveShareLayout` (default `"grid"`) remembers the last layout; the
  intro paragraph is per-collection prose and is never remembered.

## Portfolio mode (Spec 07)

- A portfolio share = Drive folder (images + `manifest.json`) + a page URL whose
  fragment carries the manifest file's id (`m`) AND a full inline snapshot. The
  Drive-hosted `manifest.json` (same object minus `m`) is the live truth; the page
  fetches it and falls back to the inline snapshot on ANY failure. Updates rewrite
  the manifest via `files.update` — the file id, and therefore the URL, never
  changes. State lives only in the user's Drive; zero server-side share state.
- The fetched manifest's own `m` is stripped before use — exactly one fetch, no
  chaining, no recursion.
- `DriveClient` contract additions: `uploadManifest(_ json: Data, parent: String) ->
  String` (**the only non-image upload path, JSON-typed and narrowly named** —
  image bytes reach Drive exclusively through `uploadFile`'s strip-verified
  fail-closed path), `updateManifest(id:json:)` (PATCH `uploadType=media`),
  `listChildren(of:) -> [(id, name)]` (drive.file sees only Muse-created files; one
  page suffices under the 1000-image cap).
- `DriveShareRecord` grows OPTIONAL fields only: `kind` (`"portfolio"`; nil =
  classic), `manifestFileID`, `collectionID`, `layout`, `introTitle`, `bodyText`.
  `expiry` stays non-optional; portfolios store the sentinel
  `DriveShareRecord.neverExpires` (2100-01-01) — **never an optional Date**, which
  would make new records undecodable by the prior build (whose failed `load()`
  silently drops the whole share list on next save). `DriveExpirySweeper` and
  `DriveExpiry` are byte-untouched; the sentinel is the design.
- `DriveShareStore.portfolio(forCollectionID:)` is the lookup seam binding
  "Update Portfolio…" to its collection.
- Publish order (fail-closed): folder → images (unchanged strip path) →
  `uploadManifest` → `setAnyoneReader` on the FOLDER (children inherit — the single
  permission call) → fragment + record. Any failure after folder creation →
  `cleanupFolder`.
- **Update order is binding: upload-new → `updateManifest` (the atomic cutover) →
  delete-old** (list-driven; per-file delete failures are non-fatal and retried by
  the next update's sweep). Reordering shows recipients a manifest whose images are
  gone. v1 re-uploads every image — no content diffing. The record is upserted in
  place (same `pageURL`, same `manifestFileID`, same `createdAt`).
- Recorded limitation: after an update, an OLD copy of the link rendered offline
  (inline-snapshot fallback) shows last-published state with dead image ids; the
  live-fetch path never has this problem.
- A 404 on the portfolio folder at update time is terminal ("publish a new one") —
  the drive.file account-switch orphan doctrine applies to portfolios too.
- `CollectionModal.driveShare` carries a `DriveShareRequest { title, urls, mode,
  collectionID }`; `DriveShareMode` = `.share` / `.portfolioNew` /
  `.portfolioUpdate(DriveShareRecord)`. Portfolio menu items (Publish / Update /
  Copy Link) are absent-not-disabled and share the raster-kinds-only URL filter.
- `Commerce/SharingTier.swift` (pure): `enforced = false` until Spec 09;
  `portfolioAvailable(entitledToSharing:)` computes but never blocks; the single
  call site is menu-item visibility.
- `DriveConfig.consentScreenVerified` is a compiled constant (not a Settings key)
  gating the "unverified app" guidance copy; the signed-out publish explainer is
  additive (sign-in runnable before the form is filled) and the
  download-originals question is answered in copy only, never built.

## Social export (Spec 07)

- Module: `Export/Social/` — `SocialPreset.swift` (the preset table as data),
  `SocialRender.swift` (pipeline), `SocialMetadata.swift` (output properties);
  pure crop math in `Components/SocialCropMath.swift`; UI in
  `Views/Export/SocialExportCard.swift` with a per-run, non-singleton
  `SocialExportModel`.
- `AppState.socialExportRequest: SocialExportRequest?` is the one new shell-modal
  flag (the sanctioned `openWithForkRequest` class), registered in
  `modalPresented`. Entry points: grid context menu, hero `ShareButton` menu,
  collection `ShareCollectionButton` menu — raster kinds only
  (`.image`/`.raw`/`.psd`).
- The preset table is 12 presets pinned entry-by-entry by `SocialPresetTests`
  (ids, dims, quality, byte targets, sharpen levels, EXIF defaults) — the table
  cannot drift from the spec silently. IG-family byte target is 800 KB.
- Fit modes (`SocialFit`: crop / matte / blurExtend) exist for fixed-dimension
  presets only; long-edge/original presets have no crop step. Matte output dims
  exactly equal preset dims. `blurExtendRadiusFraction = 0.04`.
- Pipeline order (code, fixed): `OutputRender.forOutput` FIRST (edited pixels ride
  the choke point) → `withinDecodeBudget` → ImageIO thumbnail decode with
  orientation BAKED (`kCGImageSourceCreateThumbnailWithTransform`; no output
  orientation tag can exist) at `min(source, max(4096, 4 × output long edge))` →
  fit compose → `CILanczosScaleTransform` → `CIUnsharpMask` ONLY when a downscale
  happened (standard 1.2/0.5, light 0.8/0.25) → alpha flattened → 8-bit sRGB →
  JPEG with byte-target quality ladder (step 0.05, floor 0.70; X floor 0.55) →
  write with the `EditCopyNaming`-style collision ladder,
  `<stem>-<preset.id>.jpg`.
- **Never upscale**, globally: a source smaller than the target exports at native
  cropped size, stated in the card.
- X preset invariants, test-pinned (`XPresetRuleTests`), all five required before
  write: ≤ 4096², < 5 MB, RGB/no-alpha, no orientation tag, bytes < W×H. Failing
  even at the floor fails that file, never ships a recompressible one. End-to-end
  survival is a manual owner byte-compare protocol, not a unit test.
- Metadata: default output writes NO source properties and must pass
  `ImageMetadataStripper.isClean` (verify, don't trust construction). EXIF-on
  keeps EXIF/TIFF/IPTC and ALWAYS drops orientation keys, thumbnail/preview
  dicts, and maker notes; **GPS is a separate opt-in sub-toggle, default OFF,
  never remembered**. The EXIF choice is remembered per preset id
  (`AppSettings.socialExifChoices`); matte shade in `AppSettings.socialMatteShade`.
- **Nothing in the card persists unless the user explicitly saves**: crop
  positions, zooms, fit modes, and the location toggle die with the card. The one
  opt-in — "Save Crop as Version" (absent without Spec 04) — composes the social
  rect via `SocialCropMath.composedCrop` and writes ONE `edit_versions` row
  through `EditStore.saveVersion(name:kind:stack:for:)` with kind `"version"`;
  the current stack is untouched. No new write path.
- The crop-stage preview decodes DIRECTLY at ≤ 2048 through `withinDecodeBudget` —
  no `ThumbnailCache` entry, no `renderedVariants` change (the compare-pane
  rule). Carousel locks every image to the uniform 4:5 frame; story presets draw
  250/1920-fraction safe-zone guides.
- Exports run in the foreground card with their own progress; per-file failures
  surface by filename via the `MuseAlert` seam; the status pill stays
  background-work-only.

## Perf baseline additions (Spec 07)

- New recorded rows: 24 MP → IG Feed Portrait export 1.5 s · 24 MP → X export
  4 s · 10-image carousel 15 s · crop-stage preview decode 250 ms · byte-target
  ladder ≤ 3 encodes · portfolio update of 30 images recorded with no target
  (network-bound) · fetched-manifest page render recorded manually, not CI.

## Spec 07 as built (2026-07-31, `new-product-build-1`)

*Where this disagrees with the "Share manifest v2 & page layouts (Spec 07)",
"Portfolio mode (Spec 07)" or "Social export (Spec 07)" sections above, this section
wins.*

### Scope actually shipped

- Built: the whole plan. Manifest v2 (`y`/`s`/`m`, `jsonData()`, `DriveShareLayout`,
  the publish caps) · three page layouts off `data-layout` · `DriveSharePublishGuard` ·
  the signed-out explainer + `DriveConfig.consentScreenVerified` + Settings copy ·
  portfolio mode (`uploadManifest`/`updateManifest`/`listChildren`, the record growth,
  the page fetch + `connect-src`, `publishPortfolio`/`updatePortfolio`, the UI seams,
  `SharingTier`) · social export (`Export/Social/`, `Components/SocialCropMath.swift`,
  `Views/Export/SocialExportCard.swift`, three entry points).
- **No migrations** — as specified. Future specs continue at **v24**.
- The plan's Phase 0 (`EditStackIndex`, `OutputRender`) was ALREADY in the tree from
  Spec 01 and made live by Spec 04, so it was consumed rather than built. Spec 04's
  presence also promoted the plan's Task 4.9 from an absent-until-then seam to real
  code — see "Save Crop as Version" below.

### Manifest & page — as built

- `validateManifest(m, opts = {})` is the shipped signature; `layoutOf`,
  `manifestFetchURL`, `acceptFetchedManifest` and `SIZER_BY_LAYOUT` are exported for
  tests. `share.test.mjs` is a PLAIN assert script (not `node:test`) — new tests follow
  that shipped style.
- The page's render glue was refactored into `renderLive(m)` + `buildGrid(m)`; a
  portfolio re-fetch is a SECOND CALL to those, never a second DOM construction path.
  `setupGridSizer` is re-entrant: it wires its listeners once (`slider.dataset.wired`)
  and reads bounds from a module-scoped `sizerBounds`, so a layout change after a
  re-fetch can't leave the drag/key handlers on the first call's captured range.
- `SIZER_BY_LAYOUT` is COLUMN COUNTS, matching the shipped sizer (grid 1–6 default 4 —
  unchanged; sheet 3–10 default 6; essay disabled, `max <= min`), not the tile-size
  ranges the plan sketched.
- The page's caption class is `.tile-name` (shipped), and the frame number in the
  contact-sheet layout is `.tile::after` — `::before` is the shipped loading skeleton.
- A portfolio page shows no expiry line at all (`#expires` is set empty) rather than a
  date it doesn't have.

### Portfolio — as built

- The fragment manifest keeps `m`; the Drive-hosted copy carries none. On a successful
  fetch the page re-attaches the ORIGINAL `m` to the fetched object so it still knows
  it's a portfolio (the fetched copy's own `m` is deleted first — exactly one fetch,
  never a chain).
- The sweep-failure notice is a `Phase` case, `.doneWithSweepWarning(String)` — the
  plan's own preferred option. `DriveShareService` still holds no `AppState` reference.
- A failed update rolls back by deleting just-uploaded files via a fresh unstructured
  `Task` (`DriveShareService.rollback`) — the same reason `cleanupFolder` does: a
  cancelled task's URLSession throws before reaching the network.
- Per-file deletes reuse the shipped `DriveClient.deleteFolder(id:)` (Drive's DELETE is
  id-based and kind-agnostic); no new delete method was added.
- `SharingTier`'s single call site passes the REAL entitlement
  (`CommerceStore.entitlements.sharing`) — `CommerceStore` exists in this tree, contrary
  to the plan's assumption. Behavior is identical while `enforced == false`.
- `CollectionModal.driveShare(DriveShareRequest)`'s `id` includes a mode tag, so a plain
  share and a portfolio publish of the same collection are distinct modals.

### Social export — as built

- **The X quality ladder is driven by the INVARIANTS, not by a byte target.** X has no
  `byteTargetKB`, and stepping down only for `bytes < W×H` left a busy 4096² image over
  5 MB. The loop now runs until BOTH byte invariants hold or the 0.55 floor is reached.
- **A source that can't meet the X invariants even at the floor FAILS that file** and
  writes nothing. Measured: per-pixel random noise at 4096² is ~11 MB at 0.55 — far
  beyond any real photograph. `XPresetRuleTests` pins both directions (a full-size
  detailed source lands under 5 MB; a pathological one throws).
- **Never-upscale applies to FIXED presets too**, via `SocialRender.fixedFrame`: a
  source that can't fill the frame shrinks the whole frame proportionally (exact preset
  ASPECT preserved) rather than exporting at the declared size. The card states it
  (`SocialExportModel.willNotUpscale`).
- Source dimensions are read from the header and TRANSPOSED for EXIF orientations 5–8
  before any aspect reasoning — the header reports stored, not display, dimensions.
- `SocialRender.scale` crops to the integral target after `CILanczosScaleTransform`,
  because Lanczos alone lands a fraction of a pixel off on some ratios and exact output
  dims are a requirement for matte AND crop alike.
- One long-lived `CIContext` per process for export (`cacheIntermediates: false`) — not
  the editor's live context.
- `blurExtend` composites the fitted image over an aspect-FILL, Gaussian-blurred copy of
  the same picture at `blurExtendRadiusFraction = 0.04` × long edge.
- **"Save Crop as Version" IS implemented** (Spec 04 exists): it composes via
  `SocialCropMath.composedCrop` into `stack.geometryParams?.crop` and writes ONE
  `edit_versions` row through `EditStore.saveVersion(name:kind:stack:for:)` with kind
  `"version"`. The current stack is untouched; no new write path.
- `SocialPreset` gained two derived conveniences used by the card and the renderer:
  `isFixed` and `targetAspect` (nil for non-fixed) plus `preset(id:)`.
- The card is presented by its own `SocialExportModal: ViewModifier`, not inline in
  `ContentView` — that modifier chain is already at the type-checker's limit and an
  inline `.museModal` tipped it over.
- **Test fixtures are GENERATED, not checked in** (`MuseTests/SocialFixtures.swift`,
  fixed-seed LCG). The app target uses file-system-synchronized groups, so a checked-in
  binary would enter the test bundle by inference rather than declaration, and a 4096²
  noise JPEG is a multi-MB blob in git for something ImageIO reproduces exactly.

### Localization & tooling notes

- Every Spec 07 string is translated to French, including the 12 preset display names
  and the three advisories — those are reached through runtime-variable keys the
  extractor can't see, so they were added to `Localizable.xcstrings` by hand (the
  standing rule for `NSLocalizedString(variable)`-reached keys).
- **RESOLVED 2026-08-01 (was: `-exportLocalizations` needs `ARCHS=arm64 ONLY_ACTIVE_ARCH=YES`)** — the cause was `ClipVectors`' unconditional `Float16`, now portable; the universal build works, so the workaround below is no longer needed. Kept for the record:
- **`xcodebuild -exportLocalizations` needed `ARCHS=arm64 ONLY_ACTIVE_ARCH=YES`** —
  without it the extraction build fails in `Intelligence/Core/ClipVectors.swift`
  (`Float16.bitPattern`) on a non-arm64 slice. Pre-existing since Spec 03; recorded, not
  fixed here.
- 162 strings remain untranslated in French, all pre-existing Spec 03/06 debt (Google
  Takeout / Lightroom-preset import / cull / compare copy). Not Spec 07's.
- The first `-exportLocalizations` run reformatted `Localizable.xcstrings` into Xcode's
  canonical `" : "` separator style — a whole-file diff independent of the values added.

### Owner-only steps still outstanding

- Create the Drive-API-restricted, quota-only browser key and paste it over
  `DRIVE_API_KEY = 'REPLACE_AT_DEPLOY'` at deploy time. **Never committed.**
- Deploy `web/share/` to Cloudflare Pages (layouts + the `connect-src` CSP + the
  portfolio fetch).
- Run the X no-recompress byte-compare protocol once (post → download `?name=orig` →
  `cmp`) and record the result. Not unit-testable — it verifies X's SERVER behavior.
- Flip `DriveConfig.consentScreenVerified` when Google's OAuth review completes; flip
  `SharingTier.enforced` when Spec 09 decides pricing.

## Domain-tier infrastructure (Spec 08)

- **Spec 08 adds NO migrations** — future specs still continue at v24 — and changes
  **nothing in `web/share/`**: the same static deployment serves every hostname (the
  manifest rides the fragment, origin-independent by construction).
- Topology (owner-provisioned; the apex domain is a prerequisite, not "the existing
  Pages zone" — `muse-share.pages.dev` is not a zone): production apex zone (working
  name `muse.app`; the real domain substitutes via `DomainConfig` + Worker env
  constants only, no code change). `share.muse.app` = Pages custom domain on the
  muse-share project, doubling as the customer CNAME target AND the
  Cloudflare-for-SaaS fallback origin, with an explicit Worker route exclusion
  (`share.muse.app/* → None`). `domains.muse.app` = the provisioning API.
  `*.muse.app` wildcard route → the Worker (username serving).
- Custom hostnames (Cloudflare for SaaS): `photos.customer.com` CNAME →
  `share.muse.app`; per-hostname DV certs (`ssl.method "http"`, min TLS 1.2, no TXT
  record in the common path); custom-hostname traffic never touches the Worker.
  Apex hostnames are refused (`apex_not_supported`, its own error code), enforced in
  the Worker validator AND pre-validated app-side.

## Provisioning Worker (Spec 08)

- `workers/domains/`: `worker.js` (host dispatch + scheduled), `router.js` (pure
  handlers taking injected `{verify, cf, kv, now}`), `verify.js`, `apple.js`,
  `cf.js`, `validate.js`, `serve.js`, `certs/AppleRootCA-G3.der` (pinned root),
  shared fixtures, `domains.test.mjs` (`node --test`), README (deploy / secret
  rotation / takedown path).
- Worker dependencies: exactly two — `jose` + `@peculiar/x509` (pure-JS/WebCrypto,
  edge-native, MIT, exact-pinned, bundled at deploy, no runtime fetch). Apple JWS
  chain verification is never hand-rolled ASN.1. The app-target dependency count
  (one — GRDB) is untouched.
- API contract: JSON, HTTPS, EVERY endpoint authenticated by
  `Authorization: Bearer <StoreKit 2 transaction JWS>`; no anonymous endpoints
  (claiming IS the availability probe). Endpoints: `POST`/`GET`/`DELETE`
  `/v1/hostname`, `POST /v1/hostname/refresh`, `POST`/`GET`/`DELETE` `/v1/username`.
  Errors are `{error: <code>, message}` with a closed, test-pinned code set
  (`bad_jws`, `wrong_product`, `subscription_lapsed`, `revoked`, `sandbox_refused`,
  `invalid_hostname`, `apex_not_supported`, `invalid_username`, `reserved_username`,
  `hostname_taken`, `username_taken`, `already_has_hostname`, `already_has_username`,
  `no_hostname`, `no_username`, `cf_error`, `rate_limited`); the app maps codes to
  localized copy and never renders the Worker's English message.
- `verify.js` requires ALL of: ES256 + exactly-3-cert `x5c`; chain signatures +
  validity windows; root byte-equal to the pinned Apple Root CA - G3; leaf OID
  `1.2.840.113635.100.6.11.1` + intermediate OID `1.2.840.113635.100.6.2.1`; JWS
  signature by the leaf key; `bundleId` match; environment `Production` (Sandbox
  only while `ALLOW_SANDBOX`, which flips false at launch). OCSP/CRL deliberately
  skipped. Product/expiry gating is the ROUTER's job — verify.js stays
  product-agnostic. Hostname endpoints require the sharing subscription (active +
  grace, unrevoked); username endpoints require the unlock (non-consumable,
  unrevoked, never lapse-swept).
- KV is the ONLY server-side state and is provisioning-only:
  `sub:<originalTransactionId>`, `host:<hostname>`, `user:<username>`,
  `unlockuser:<otid>` — pairs always written and cleared together; nothing about
  photos, manifests, or links ever enters KV (#19 intact).
- One hostname per subscription; change = DELETE then POST (no atomic replace
  endpoint). `refresh` re-stamps stored expiry MONOTONICALLY (never backward — a
  stale JWS from one Mac must not shorten a recorded renewal). Worker DELETE treats
  CF 404 as success (the orphan-doctrine class). `LAPSE_GRACE_DAYS = 30`, and
  `DomainConfig.lapseGraceDays` MUST equal it (the UI copy cites the number).
- Lapse sweep (cron): only entries past expiry + grace are checked, against the App
  Store Server API (status 1/3/4 → re-stamp; 2/5 → deprovision; transient failure →
  leave, retry next cron). **No ASC key configured → the sweep no-ops entirely** —
  stored expiry alone never deletes a hostname (fail closed in the paying user's
  favor).
- Username tier: grammar `^[a-z0-9](?:-?[a-z0-9]){2,29}$` + a RESERVED list, both
  fixture-pinned. Serving is Worker-gated, never bare wildcard DNS: KV claim lookup
  (`cacheTtl: 3600` — a released name may serve up to an hour, recorded), claimed →
  GET/HEAD passthrough to the Pages origin with status/body/headers verbatim;
  unclaimed/reserved → bare 404 (no page shell to phish with). Takedown path
  documented in the Worker README. Rate limit: `MAX_MUTATIONS_PER_DAY = 20` per
  transaction id (churn brake; the JWS is the security boundary).

## App domain module & link base (Spec 08)

- `Sharing/Domains/`: `DomainConfig.swift` (`workerBaseURL`, `apexZone`,
  `cnameTarget`, `statusPollSeconds = 30`, `lapseGraceDays = 30`, `requestTimeout =
  15` — the DriveConfig no-secret pattern), `ShareDomain.swift`
  (`ShareDomainState` / `MuseAddressState` / `ShareDomainFile` incl. the persisted
  one-shot `lapseNoticeShown`, + pure `DomainStatus.map` folding
  status × sslStatus to `.pendingDNS/.pendingSSL/.active/.problem`,
  unknown-string-lenient), `DomainClient.swift` (`.ephemeral` session, talks ONLY
  to `workerBaseURL`), `DomainValidate.swift`, `ShareLinkBase.swift`,
  `ShareDomainStore.swift` (Pattern B + `ShareDomainRefresher`).
- Persistence: `shareDomain.json` in App Support (the `DriveShareStore`
  load/save/atomic discipline). The transaction JWS is never persisted — fetched per
  call from `CommerceStore`.
- **`ShareLinkBase` is the single link-base decision point**: precedence
  active-custom-domain → claimed-address → `DriveConfig.shareBaseURL`;
  pending/failed domains never mint links. `DriveShareService` (and the portfolio
  publish/update) mint via the existing `pageURL(base:)` parameter with
  `ShareLinkBase.current(…)`.
- The Manage Open-Link gate is origin-EXACT via `ShareLinkBase.isSanctioned`
  (URLComponents scheme + exact-host compare) — never `hasPrefix` (suffix-spoof:
  `https://muse-share.pages.dev.evil.com` passes a prefix test).
  `sanctionedOrigins` always includes `DriveConfig.shareBaseURL`.
- Domain/address removal REBASES local share records onto the new current base with
  the fragment preserved verbatim (`ShareLinkBase.rebased`); records are NEVER
  rebased when a domain is added (default-base links serve forever — Pages never
  stops answering). Distributed links on a removed hostname die; the removal
  confirm says so.
- Announcements and the model-download manifest stay pinned to
  `DriveConfig.shareBaseURL` by name — the custom domain is a share-LINK base, never
  a fetch origin; the pinned-host fail-closed rule never acquires a
  user-configurable host.
- `ShareDomainRefresher` (launch, `DriveExpirySweeper` shape, beside it in
  `MuseApp`'s `.task`): ZERO network when nothing is configured; refresh + status
  poll while pending; `no_hostname` from the Worker → clear state, rebase records,
  one-shot `MuseAlert` via the `alertRequest` seam (guarded by `lapseNoticeShown`);
  any network failure is silent, state untouched.
- `DomainValidate` (app) and `validate.js` (Worker) are pinned to ONE shared fixture
  set — `workers/domains/fixtures/hostnames.json` / `usernames.json`, consumed by
  both test suites (the two-implementations-one-contract rule class). Non-ASCII
  hostname input is punycoded app-side before validation.
- UI: one sanctioned shell-modal flag `AppState.shareDomainSetupShown` (registered
  in `modalPresented`; a card raised from Settings must present at the shell, above
  it); `Views/ShareDomainCard.swift` (`.museModal`, width 520) with
  pitch / enter-domain / DNS-instructions-with-polling / active / problem states.
  Card polling rides a `.task(id:)` bound to presentation — never a free-running
  timer. Settings gains a "Share Links" section (below Google Drive): Muse Address
  row + Custom Domain row + a footer stating the effective base. Subscription price
  always renders from `Product.displayPrice`, never hardcoded (Spec 09 owns the
  number).
- Domains gate on transaction POSSESSION (`CommerceStore.entitlements` + Worker-side
  JWS verification), NOT on `SharingTier.enforced` — `SharingTier` keeps its single
  portfolio call site and its computes-never-blocks posture until Spec 09. Sandbox
  purchases against `ALLOW_SANDBOX = true` are the TestFlight path; Xcode-environment
  (local StoreKit config) JWS fail chain verification by construction and cannot
  exercise the Worker.
- `CommerceStore` gains `transactionJWS(for productID:) async -> String?` — returns
  `VerificationResult.jwsRepresentation` from `Transaction.currentEntitlements` for
  an owned product; never cached, never persisted.
- Escape hatch is docs-only: `docs/self-hosting-share-page.md` (self-host
  `web/share/` on the user's own account/domain; a link's fragment is the entire
  share, so swapping the origin ahead of `#` re-targets any link). No in-app base
  override is built.
- The app binary carries no Cloudflare credential and makes no Cloudflare API call —
  acceptance includes a `strings` check for `api.cloudflare.com` (zero hits).

## Perf baseline additions (Spec 08)

- New recorded rows: Worker `POST /v1/hostname` end-to-end recorded with no target
  (network-bound) · `verify.js` fixture verification recorded manually, not CI ·
  launch refresher with nothing configured = zero network calls (code-shape fact,
  noted in the report).

## Pricing & trial (Spec 09)

- **Pricing is NOT decided** (owner statement 2026-07-30: "none of the pricing is
  decided"). ASC working placeholders — unlock **$49.99**, sharing **$19.99/yr** — exist
  only so products load and TestFlight flows run E2E. The final call lands after the
  TestFlight photographer pass, is recorded here + foundation §13, and requires ZERO code
  change (prices are ASC-side only).
- **No price literal ever appears in code, resources, or `.xcstrings` values** — every
  price renders `Product.displayPrice`; products not loaded → the copy omits the number,
  never guesses or hardcodes. Acceptance: grep for `$49`/`49.99` etc. → zero hits.
- Trial working shape: **14-day full trial, hard gate at expiry** (the pre-spec's own
  recommendation; owner-confirmable alongside pricing — duration is one constant).
  Capacity-limited and feature-limited shapes are deliberately NOT built.
- `TrialPolicy.current = (duration: 14 d, enforced: true)` — **enforced flips true in
  Spec 09's build**, superseding Spec 01's tester-lockout rationale: sandbox purchases
  are free, so testers exercise the gate instead of being locked out by it.
- `TrialPolicy.epoch = 1`; the Keychain anchor key is `"muse.trial.anchor.e<epoch>"`.
  Epoch 1 also reads Spec 01's legacy unnumbered key + the UserDefaults mirror,
  earliest-wins, so no existing anchor resets. A future epoch bump reads ONLY its own
  key — that IS the "generous re-trial on major versions" mechanism. **The epoch does
  NOT bump at GA** (long-running testers hitting the gate is the intended E2E).
- `CommerceStore` gains `@Published trialState` + computed `trialGateActive`
  (`.expired` ∧ ¬unlocked). Recompute at: init (synchronous, from the cached anchor —
  correct at first paint), every entitlement change, and
  `didBecomeActiveNotification`. **No timer** — mid-session expiry gates on the next
  activation (recorded).
- Gate integration adds ZERO AppState state: `modalPresented` gains
  `|| CommerceStore.shared.trialGateActive` (keys stay gated behind the card). **The
  gate is not dismissible and not in the Escape peel** — `dismissTopModal` skips it;
  when only the gate is presented, Escape is a no-op. `EscapeResolver` order unchanged.
- `Views/UnlockGateView.swift`: shell overlay attached ABOVE the `alertRequest`
  presenter, width 460, reusing `.museModal` card visuals but never the `.museModal`
  machinery (that machinery exists to dismiss); built only while `trialGateActive`, so
  a purchase unmounts it via the entitlements publish. Contents: reassurance body
  (no-catalog story),
  price via `displayPrice`, Unlock / Restore / Redeem Code
  (`https://apps.apple.com/redeem`) / Privacy+Terms links / **Quit Muse**. Purchase and
  restore errors render INLINE in the card — nothing presents above the gate. The card
  never mentions the sharing tier.
- During trial: the Settings Muse-section status line is state-aware ("Trial — N days
  left"), and at `daysLeft ≤ 3` a once-per-launch (never persisted) confirm
  `ModalMessageCard` fires via the `alertRequest` seam (Unlock… / Later). Nothing else —
  no toolbar badge, no per-launch nag; the status pill stays background-work-only.
- **The gate blocks the UI, never background data maintenance** — backfills,
  `DriveExpirySweeper`, `ShareDomainRefresher`, and sidecar hydration run behind it
  (freezing them could rot the user's own state).
- `Views/SubscriptionLegalLinks.swift` (Privacy/Terms links beside purchase UI) is
  shared by `UnlockGateView` and `ShareDomainCard`'s pitch state — **Spec 08 amendment
  A3** (App Review requires working policy links next to subscription purchase UI).
- Settings Muse section gains a **Manage Subscription** row
  (`https://apps.apple.com/account/subscriptions`), visible only while
  `entitlements.sharing`.

## Launch flips (Spec 09)

- Build-time flips (land in Spec 09's build): `TrialPolicy.current.enforced = true` and
  `SharingTier.enforced = true` (its single `ShareCollectionButton` call site is
  untouched; `SharingTierTests` updated).
- GA-deploy-time flip: Worker `ALLOW_SANDBOX = "false"` — **never before GA**
  (TestFlight domain testing needs sandbox JWS accepted). Post-GA domain testing uses a
  second staging Worker with sandbox on (noted in `workers/domains/README`).
- Independent flip: `DriveConfig.consentScreenVerified = true` when Google completes
  OAuth verification.
- `ITSAppUsesNonExemptEncryption = false` added to Info.plist (HTTPS-only exemption).

## Backup amendment A2 (Spec 09 → Spec 04)

- **Spec 04/05's "the `.muselibrary` archive carries the DB" was factually wrong** —
  the shipped backup is a JSON encode of `BackupArchive` (occurrences carry tags +
  note; the DB file is never copied), so edit data did not survive a round trip.
  Corrected in Spec 09: `BackupOccurrence` gains optional `edit_stack` /
  `edit_updated_at` / `edit_versions`; `BackupArchive` gains optional `edit_presets` /
  `edit_luts`. **`BackupArchive.currentSchema` stays 1** — the optional-fields decode
  pattern (pre-A2 archives decode unchanged; post-A2 archives decode on older builds
  minus the new fields).
- **LUT bytes are carried** (base64 `Data`): a restored stack referencing an absent LUT
  renders as the ORIGINAL (Spec 05 rule) — a backup restoring edits but losing looks is
  a half-restore. Bounded by `CubeLUTParser.maxSize = 128`; accepted. Versions/snapshots
  ride too — "device-local" is a *sidecar sync* limitation, not a *backup* rule.
- Restore semantics: the stack applies via `EditRecordStore.write` **restore-wins** at
  the matched NEW `parent_dir` (mirrors the existing `NoteStore.write` restore line —
  recovery, not merge); versions insert with fresh UUIDs (the carry rule); presets and
  LUTs are `INSERT OR IGNORE` (LUT immutability preserved; re-restore idempotent). Then
  the standard edit-save consequences run once: provider index rebuild,
  `markContentChanged` (both thumbnail key variants), `EditStore.generation` bump,
  `LutRegistry.invalidate`. **No sidecar re-export on restore** (hydration owns sidecar
  reconciliation; restore must not stomp newer on-disk sidecars).
- Records: `BackupEditVersion` (`kind` `"version"`|`"snapshot"`, `name`, `stack`,
  `created_at`), `BackupEditPreset` (`id`, `name`, `stack`, `created_at`,
  `updated_at`), `BackupLut` (`id` = the `edit_luts` content-hash PK, `name`, `size`,
  `data` — float32 LE RGB, base64 via Codable `Data`). Decode compatibility is pinned
  both directions: a raw-JSON post-A2 fixture decodes on the pre-A2 struct shape
  (`BackupArchiveCompatTests`) and a pre-A2 archive fixture decodes unchanged
  (`BackupEditRoundTripTests`).

## Launch validation (Spec 09)

- `scripts/make-synthetic-library.swift`: checked-in, zero-dependency, seeded generator
  of N unique-content-hash 64×64 JPEGs (≤ 1,000/folder) with EXIF/GPS variety written
  through the same property keys `PhotoHeaderReader` parses; ~2 GB at 500k.
- `PerfBaselineTests` gains a **`MUSE_PERF_500K=1`**-gated section (never default CI):
  500k synthetic `photo_meta` + `clip_embeddings` rows; recorded targets — three-token
  intersect ≤ 500 ms · full `ClipIndex` scan ≤ 1.5 s · scan footprint delta ≤ 200 MB
  (the streaming/no-RAM-residency proof made measurable).
- **The launch perf gate is a human reading committed reports**
  (`docs/perf-baseline-<date>.md` + `docs/launch-validation-<date>.md`), never a CI
  assertion — record-never-assert holds; "regressions block launch" is a process rule.
- The "tested with 500,000+ libraries" marketing line may appear ONLY after the
  end-to-end owner protocol (index/search/memory/integrity/thermal on the M1 Air 8 GB)
  passes and is recorded in the validation doc — earned, never asserted first.

## Site & metadata (Spec 09)

- `web/share` `about`/`privacy`/`terms` are rewritten for a paid PolyForm-Shield app
  (they currently claim "free, open-source" — false at launch). `about.html` keeps its
  OAuth-consent-home role and the `google-site-verification` meta (load-bearing).
  `privacy.html` enumerates exactly the four app-initiated network paths WITH what each
  sends — the domain-provisioning calls carry the App Store **transaction JWS** (product
  id, dates, transaction ids — no name/email/Apple ID) — plus the share PAGE's portfolio
  `manifest.json` fetch. `terms.html` gains purchases/subscriptions (the 30-day grace
  number MUST equal `DomainConfig.lapseGraceDays` — a third citation site of that
  constant) and extends acceptable-use/takedown to usernames + custom hostnames.
- `InfoSheet`'s "open source under the MIT license" line is replaced: PolyForm Shield +
  attributions (GRDB MIT · fflate MIT · GeoNames CC-BY 4.0 · the CLIP model license line
  per the resolution below). Worker deps (`jose`/`@peculiar/x509`) are credited in
  `workers/domains/README`, not the About card (they are not in the app binary).
- ASO drafts (owner finalizes): name "Muse — Photo Library" · subtitle "Fast, local
  photo organizer" · category Photography · keyword field built around "photo
  organizer/photo library" terms · screenshots MUST show the editor readouts · review
  notes pre-state the guideline-4.8 position (Drive OAuth connects the user's own
  account; it is not an app login). **No Lightroom references in any owned copy.**
- **MobileCLIP license gate is a GA blocker**: legal read of Apple's ML Research Model
  TOU before shipping paid. Refusal → the mechanical Spec 03 swap (self-converted
  OpenCLIP ViT-B/32 through `make-clip-coreml.py`, `ClipModel.current` edit +
  `generation` bump, hosted chunks; installed users re-embed via the standing
  generation-mismatch backfill). Outcome recorded here when made.
- Trial-gate + legal-page strings are localized at introduction; launch requires the
  French export pass at 0 untranslated (checklist row).

## Naming & test conventions

- Migrations: `vN_snake_case`, registered in order at the end of `makeMigrator()`.
- Records: `<Thing>Row`, snake_case properties matching column names.
- Pure logic: nonisolated `enum` (or struct) with static funcs; stores:
  `@MainActor final class <Thing>Store: ObservableObject` with `static let shared`.
- AppState extensions are methods-only: `AppState+<Feature>.swift`.
- Constants live on the type they govern (thresholds, caps, product ids) — one
  declaration site, referenced everywhere.
- Every feature ships with pure-logic test files (`<Thing>Tests`), including migration
  tests (runs clean on the prior version's library, idempotent re-migrate, existing
  rows untouched). Behavioral pins are tests (e.g. tokenless search byte-identical;
  thumbnail nil-stack key byte-identical).
- Every new user-facing string is localized at introduction (SwiftUI literal positions
  or explicit `String(localized:)`); a feature is incomplete until the French export
  pass reports 0 untranslated.

## Out of scope / deferred / never

- Face identity/clustering/naming: deferred project (AuraFace Apache-2.0 path when
  demanded); InsightFace/EdgeFace never (non-commercial licenses).
- Spec 05 deferrals (v2 candidates, do not build now): waveform/RGB parade scopes,
  ΔE spot adjustment, 3-way grade wheels, HSL chips with eyedropper, film-negative
  inversion. LR `.xmp` PRESET import rides Spec 06's crs: work (specified there).
  No `lut:`/`edited:` search tokens and no new smart-rule cases in v1.
- v1 editing exclusions (Spec 04): no `edited:` search token, no `.edited` smart
  rule, no analyze-the-edit mode; `masks` always empty; `.psd`/video/non-image kinds
  never editable in-app. Masking/healing/layers/AI selection/dehaze/parametric
  curve/reorderable stack/own demosaic remain NEVER (foundation §6).
- Spec 06 exclusions: Capture One `.costyle` (still deferred) · face identity from
  any import source (people names are plain tags or skipped) · any write-back to
  source apps · AAE/`PHAdjustmentData` parsing · translation of adaptive LR
  operators (Highlights/Shadows/Whites/Blacks/Clarity/Dehaze/local/retouch —
  disclosed, never attempted) · pick/reject flags (LR doesn't export them; no
  handling invented) · auto-pairing Takeout `-edited` siblings · new search
  tokens, smart-rule cases, analysis modes, or analysis toggles.
- Spec 07 exclusions: custom domains, `username.muse.app` subdomains, and the
  provisioning Worker (Spec 08) · video social-export presets (photo-first) ·
  portfolio content diffing on update (v1 re-uploads all images).
- Spec 08 exclusions: apex custom hostnames (CF Enterprise — refused with
  `apex_not_supported`) · multi-hostname per subscription · anonymous availability
  endpoints · an atomic hostname-replace endpoint (change = delete-then-create) ·
  an in-app link-base override for self-hosters (the escape hatch is docs-only) ·
  email/anything else on user domains · per-registrar DNS walkthrough UI (generic
  CNAME copy only) · analytics of any kind on share pages (never).
- Spec 09 exclusions: the pricing DECISION itself (still open — ASC placeholders
  $49.99 / $19.99-yr stand until the TestFlight photographer pass concludes) ·
  capacity-limited and feature-limited trial shapes (not built) · the marketing site
  (separate repo — Spec 09 ships the in-repo `web/share` pages + a copy brief only) ·
  CI-asserted perf gates (human-read committed reports, by design) · any migration
  (future specs still continue at v24).
- `HybridClusterer` time-bucketing: NOT done — it changes clustering semantics and the
  `SimilarityMatrixTests` equivalence guarantee; time-bucketing landed in
  `BurstClusterer` instead. Measured in the baseline, not changed.
- No in-app map (deferred: MKMapView + ClusterMap when wanted); globe never.
- Photo info never becomes tags — all search attributes are derived, indexed metadata.
- No new permanent taxonomies (stacks are grouping, not taxonomy; stars stay
  tag-implemented; no pick/reject flags — only the future ephemeral cull state).
- No server-side share state ever; Google Drive is the only share backend; no
  download-originals feature.
- Rediscovery adds no new analysis — queries over existing/backfilled data only.

## Spec 03 as-built (culling & search phase 2)

Binding facts from the actual implementation. Where this differs from the plan,
this section wins.

### Schema

- `v18_clip_embeddings` then `v19_photo_traits`, both registered in that order
  after `v17_stacks`. (This bullet formerly claimed the chain ended at v19 and that
  this superseded the v24 note — true when Spec 03 shipped, wrong since Spec 04. Next
  migration version: see Current state.)
- `photo_traits(file_id PK cascade, traits_scanned_hash, traits_version,
  face_count, largest_face_frac, face_quality, pet_count, sharpness)` + indexes on
  `face_count` and `pet_count`. Content-keyed, NOT `(file_id, parent_dir)`.
  A row with NULL trait fields is an ATTEMPTED-MARKER (reached, undecodable);
  ABSENCE of the row means unscanned — which is why `faces:0` matches only files
  that have a row. A new trait bumps `PhotoTraits.currentVersion` rather than
  adding a parallel marker or table.
- `clip_embeddings(file_id PK cascade, embedded_hash, model_generation, vector)`.
  fp16, L2-normalized, content-keyed. NULL vector at the CURRENT generation is an
  attempted-marker and is never reselected by the backfill.

### CLIP

- `ClipVectors.toData/fromData` — fp16 LE; `fromData` refuses an ODD-length blob
  (the plan said "wrong length"; length is only knowable against a query, so the
  real length check lives in `ClipIndex`, which skips any vector whose count
  differs from the query's — the FeaturePrints rule, applied where it can be).
- `ClipModel.current` is the single descriptor (name/generation/dimension/
  imageInputSide/manifestURL) + `ClipModel.directory()`. Swapping models = edit it
  and bump `generation`, which invalidates every stored vector by construction.
- `ClipEngine` is an actor with `retain()/release()/unload()/canLoad()`; encoder
  input/output feature names are read from `MLModel.modelDescription` rather than
  hard-coded, so the conversion script's naming isn't a build-time contract.
  `MLModel.prediction(from:)` is AWAITED (it is async on this SDK).
- `ClipIndex.matches(query:minScore:db:)` streams `chunkRows = 4096` — the
  no-RAM-residency rule is satisfied here, not deferred. `textMinScore = 0.20`,
  `imageMinScore = 0.55`, `topK = 400`. Never validated live.
- `ClipModelStore` download is user-initiated only; fail-closed at every step
  (manifest cap 16 KB, unknown version refused, SHA-256 verify, load-test both
  encoders BEFORE writing the `.verified` marker, delete the directory on any
  failure). Older generation directories are removed only after the new one
  verifies. On success it chains `DeepAnalysisBackfill.run()` +
  `ClipPromptVectors.refreshAll()`.
- Adds the search-model download as an app-initiated network path. (The full
  path list, and how it differs before/after Spec 08 and the MAS migration, is in
  Current state — do not count paths from this bullet alone.)

### Search

- New tokens: `faces:<numeric>`, `pets:<numeric>`, `is:portrait|group`,
  `similar:s<N>`. `faces`/`pets`/`is` are in `SearchQueryParser.keys` (so they
  autocomplete); `similar` deliberately is NOT — its handles are generated, not
  typed. An unrecognized `is:` value or an off-shape `similar:` value stays free
  text, per the standing grammar rule.
- `PhotoSearch.filter` gained `context: TokenContext` (default `.init()`, so
  every existing call site is unchanged). `.similar` is resolved AHEAD of the
  per-token switch, where the context is in scope; `matchIDs` keeps an explicit
  unreachable `.similar` case. An unresolvable handle returns an EMPTY result,
  never the unfiltered set.
- When a `similar:` token is present, SIMILARITY SCORE DESC replaces capture DESC
  as the result order; other tokens still intersect via `idSet`.
- `SimilarityRegistry` is a lock-based `nonisolated final class`, NOT a
  `@MainActor ObservableObject` — `SearchToken.displayLabel` is a nonisolated read
  and must be able to resolve a handle's label ("Similar: IMG_1234" vs
  "Similar (expired)").
- `SearchService`: `clipReady = ClipModelStore.shared.isReady` selects the
  semantic engine (CLIP `embedText` + `ClipIndex.matches`, else NLEmbedding +
  `SemanticSearch.semanticIDs`). `semanticFloor` is ONE threaded value used by
  both `SemanticSearch.merge` and the `matchedDirs` relaxation — never two
  constants kept in sync by hand. With the model absent, every value is
  byte-identical to the pre-CLIP path.

### Traits

- `VisionServices.analyze(url:)` now delegates to a new
  `VisionServices.analyze(cgImage:)` seam; the per-file live pass and
  `DeepAnalysisBackfill` share it so face/pet/sharpness logic can never fork.
  `analyze(url:)` still overwrites width/height from the HEADER.
- `VisionServices.petConfidenceFloor = 0.5`; `VNRecognizeAnimalsRequest` counts
  only observations with a label at or above it.
- `SharpnessScore` = log10(variance of a 3×3 Laplacian) over luminance,
  downsampled to a fixed 1024px long edge first. The convolution uses divisor 1
  and bias 128 (the signed result must stay representable in UInt8; a constant
  bias cancels out of the variance), and reads row-by-row honouring
  `vImage_Buffer.rowBytes`. Zero variance returns `-Double.greatestFiniteMagnitude`
  (not `-.infinity`, which XCTest arithmetic can't compare).
- `TraitFields` + `TaggerOutput.traits` + `TaggerOutput.decodedImage` carry the
  scalars and the already-decoded raster from `VisionTagger` into `analyzeOne`,
  which writes the `photo_traits` row INSIDE its existing guarded transaction.
- `DeepAnalysisBackfill` decodes at **1024px** (traits and CLIP's 256px input
  both need far less than the 4096px Vision pass), 2-wide, 200-row write chunks,
  5000/launch. It unions the traits and CLIP candidate sets so a file needing
  either is scanned ONCE. Every flush re-checks `content_hash` before saving.
  Wired into `MuseApp`'s `.task` after `PhotoHeaderBackfill`.
- `PortraitHeuristic`: portrait = 1–2 faces AND largest face ≥ 5% of frame;
  group = ≥3 faces. A nil `largestFaceFrac` is never a portrait.

### Compare / cull

- `CompareStore` (Pattern B, `maxPanes = 4`, minimum 2), `CompareGeometry`
  (normalized center is what keeps differing aspects on the same subject;
  `zoomRange = 1...8`; zoom 1 collapses the center to 0.5/0.5).
- `EscapeAction.closeCompare` resolves BELOW `.dismissModal` and ABOVE the viewer
  cases. Order is now: modal → **compare** → viewer → search → tags → collection
  → rediscovery → collectionsPage → placesPage → none.
- `PageScrollCatcher` gained `onCullKey: (Character) -> Bool`, checked FIRST and
  purely additive — the keycode-only paging rule and the plain-arrow modifier
  intersection are untouched. Its `isActive` gate also requires
  `!CompareStore.shared.isActive`.
- `CompareKeyCatcher` is a NEW sibling of `KeyCaptureView`, not an extension —
  that view's three fixed closures back the hero's arrow-flip/return path.
- `ComparePane` decodes the ORIGINAL via `VisionServices.boundedDecode` rather
  than `ThumbnailCache`, deliberately: a pane-sized variant would have to be
  listed in `renderedVariants` or it would survive an in-place edit forever.
  Compare therefore adds NO new thumbnail variant.
- `SharpnessRank.tieBand = 0.15` log10 units; ranking is relative WITHIN the
  compared set only. The face-quality badge shows only when EVERY pane has a face.
- `CullStore` is memory-only — no table, no defaults key, no sidecar field.
  `setMark` is a no-op while inactive. The session is deliberately NOT in the
  Escape chain; Finish/Cancel are the only exits, and Cancel with marks present
  raises a discard confirm. Resolution writes go through `TagStore.setRating` and
  `deletion.deleteWithBurn` only.
- `AppState` grew exactly two `@Published` flags (`cullResolveShown`,
  `clipOfferShown`), both in `modalPresented`. Everything else is a Pattern B
  store read directly.
- `AssetKind.isPhotoKind` is the new shared predicate for image/raw/psd.

### Smart rules

- `SmartRule.similar(SimilarTerm)` is the 8th case. `SimilarTerm`:
  `thresholdRange 0.40...0.80`, `defaultThreshold 0.55`, `maxAnchors 20`.
  Anchors are FILE IDS (vectors stay in `clip_embeddings`, averaged via
  `ClipCentroid` at evaluation); a prompt's vector is encoded at rule-SAVE time
  and stamped with `promptGeneration`. Evaluation NEVER runs the model — a
  generation mismatch (anchor or prompt) evaluates to EMPTY and heals via
  `ClipPromptVectors.refreshAll()`.
- The "Looks Like" `Kind` case is offered only when the model is installed, but an
  EXISTING `.similar` rule still renders its row (it decodes fine without it).
- Same Codable consequence as `.location`: a rule set containing `.similar`
  decodes as empty on an older build.

### Natural language

- `NLTokenComposer.compose` emits `in:YYYY[-MM]`, `near:"..."`, `camera:"..."`,
  `star:N` — the REAL grammar (the plan's sketched `★≥N` fragment was one of two
  accepted forms; `star:N` is the canonical key). Multi-word values are quoted.
  Out-of-range months/stars and blank strings are dropped.
- `NLQuerySuggest.minWords = 3`; it fires only when the parse yields ZERO tokens,
  is token-guarded against supersession, and DROPS a composition that doesn't
  round-trip into at least one token. Gated on the exact
  `canImport + @available(macOS 26) + SystemLanguageModel.default.availability`
  triple.

### Not built in this pass (deliberate, tracked)

- Hero-viewer region similarity (marquee mode), the hero peaking chrome button,
  hero K/X/U cull marking, and the grid image-DROP similarity search. `RegionMath`
  and `PeakingOverlay` — the pure halves both need — ARE built and tested; only
  the `HeroImageViewer` wiring is outstanding. That file is under the
  diagnose-by-instrumenting-the-running-app rule, so it was left for a pass that
  can exercise the running app rather than reasoned into.
- The grid cull-mark tile BADGE (compare panes do show it).
- The hero INFO card's Sharpness row.
- `scripts/make-clip-coreml.py` and the tokenizer fixtures — owner-only steps.
  `ClipTokenizer` is written and compiles; it is unexercised until they exist.
- `PerfBaseline` rows for the seven spec-03 measurements.
- The French localization export pass for this spec's new strings.

---

## Spec 04 as-built (editing engine)

*2026-07-31, `new-product-build-1`. Where this disagrees with the pre-build
"Spec 04" sections above, this section wins.*

### Scope

- Built: v20 `edits`/`edit_versions` + v21 `edit_presets`; the platform-neutral
  `Editing/` core; the Core Image + Metal render pipeline; `EditStore` +
  `LiveEditStackProvider` + the consumer sweep; the (Preview | Edit) editor inside
  the hero viewer; curve editor, WB eyedropper, before/after suite, versions and
  snapshots, presets, copy/paste + batch sync, Edit-a-Copy.
- **Phase 0 was already in the tree** — Spec 01 shipped `EditStackIndex`,
  `EffectiveDimensions`, `OutputRender` and the stack-aware `ThumbnailCache` key as
  identity functions. This spec made them live; it did not build them.
- **NOT built:** the `PerfBaseline` rows for this spec's five measurements (the
  harness gap Spec 03 also left).
- (Next migration version: see Current state. This bullet formerly said v22, true only
  until Spec 05 took v22–v23.)

### Model — as built

- `Adjustment`'s canonical order is its DECLARATION order and new cases must APPEND;
  `EditStack.normalized()` sorts/dedupes by `canonicalIndex` (last occurrence wins).
- `EditStack` exposes typed accessors (`toneParams`/`colorParams`/…) plus
  find-or-insert mutators (`setTone`/`setColor`/`setPresence`/`setCurve`/
  `setGeometry`/`setVignette`/`setRaw`). Editor bindings go through these, so a first
  non-neutral write creates the case and nothing else knows the stack's shape.
- A case that is PRESENT but neutral still leaves `EditStack.isNeutral` true — the
  editor creates cases the moment a slider is touched, and returning it to zero must
  delete the row, not store a no-op.
- `EditStackCodec.hashOfRawBytes(_:)` exists alongside `hash(_:)`: an UNDECODABLE
  blob (a stack from a newer schema, arriving by sidecar) still needs a stable,
  distinct-from-unedited cache key and must round-trip byte-identical.
- `CurveParams` carries four channels (`rgb`/`red`/`green`/`blue`), `maxPoints = 16`.
  `RawParams` is `lensCorrection` + `decoderVersion`. `CropRect` is a top-level type.
- Pinned fixture hash (tone `exposureEV 0.5`, `contrast 0.2`):
  `349a57c39e0aa139dc06baef4dc690d00d8d6d47b17bb6abb3e565242280356a`.

### Storage & carry — as built

- `EditRecordStore` adds three functions beyond the plan's list:
  `allWithAlivePaths(db:)` and `versionCounts(db:)` (the index + grid-badge bulk
  loads, each filtered to the alive path whose `parent_dir` matches the edit's — a
  file alive at two paths must not render the other copy's stack), and
  `rewriteParentDirPrefix(oldPrefix:newPrefix:db:)`, which owns BOTH tables' folder
  rename so `FolderRenameMigration` gains one call rather than four SQL statements.
- `applyHydrated` takes `json: String?`; **nil is a synced RESET** (delete the row).
- `carryAll` sweeps `edit_versions` in scopes the `edits` table no longer mentions —
  a reset clears the stack but keeps its versions.

### Sidecars — as built

- `SidecarHydrator` SKIPS the edit apply entirely when `edit_updated_at` is nil: a
  sidecar with no edit clock says nothing about edits, and treating it as a synced
  reset would delete them. Only a non-nil clock reaches `EditRecordStore.applyHydrated`.
- After a hydrated edit lands, `EditStore.applyHydratedConsequences(for:)` runs the
  save consequences MINUS the sidecar re-export (which would bounce the edit back at
  the device that sent it).

### Render pipeline — as built

- Stitchable Core Image kernels are declared `extern "C" [[stitchable]] float4 name(…)`
  — the attribute goes before the RETURN TYPE. After it, the Metal compiler reports
  "'stitchable' attribute cannot be applied to types" and the kernels silently fail to
  load at runtime.
- Kernel loading is LAZY and NON-fatal (`CIColorKernel?`/`CIKernel?`): a nil kernel
  SKIPS its stage rather than crashing the app on first slider drag.
  `EditKernelLoadTests` is what makes a broken Metal build phase fail in CI.
- `MiredMapping.maxMiredOffset = d65Mired - miredFloor` (≈129 mired) and slider ±1 maps
  linearly onto it. The warm target Kelvin (~3540 K) is DERIVED from that, not chosen:
  choosing it independently (the spec's 3000 K) runs the cool side past the floor,
  clamps, and reproduces the warm/cool asymmetry mired space exists to remove.
- `EditRenderer` skips its own temperature/tint, noise-reduction and sharpen stages
  when `stack.rawParams != nil` — `RawSource` already routed those sliders into the
  decoder, and applying them again doubles them.
- Radii scale with the POST-geometry frame, not the source: a crop changes what "1% of
  the long edge" means on screen, and the user tunes clarity against what they see.
- `OutputFormat` (JPEG q0.92 / PNG / TIFF / HEIC q0.9 / `tiff16`) lives on
  `EditRenderer`, with `matchingSource(_:)` and `fileExtension`.
- `RenderCoalescer` drains its pending slot in a LOOP, not by recursing — a long drag
  hands off hundreds of times.

### Provider & consumers — as built

- **`EditStackIndex` reads its provider OUTSIDE the lock.** `NSLock` is not recursive
  and `LiveEditStackProvider` reads the same index, so holding the lock across the
  provider call deadlocks on the first edited tile (main thread). Only the provider
  REFERENCE read is guarded.
- Index entries are pre-resolved at rebuild (`hash`, decoded stack, geometry,
  `renderable`). `stackHash` is returned even for an UNRENDERABLE stack so its
  thumbnail key stays distinct; `resolvedStack` returns nil for it, so the original
  renders.
- `EditStackIndex.merge(entries:clearingScope:)` is the incremental path — the scope
  clear is what makes a RESET take effect; without it the entry lingers until the next
  full rebuild.
- `EditStore` holds a **weak `host: AppState`** installed at launch
  (`installHost(_:)`), used solely to call `markContentChanged`. `AppState.shared`
  does not exist. This is a one-way reference, not an integration: no forwarded
  `objectWillChange`, and the two AppState additions are shell modal-request flags
  (`editPromptRequest`, `openWithForkRequest`) following the `alertRequest` precedent.
- `OutputRender` gains `renderedImage(url:maxPixel:)` (pixels without a temp file),
  `sweepRenderTemps()` (age-based, `tempMaxAge` 1 day, `tempDirectoryName`
  `muse-render`), and falls back to the ORIGINAL when a render fails rather than
  aborting the share.
- The grid badge is passed DOWN as `TileView.editedVersionCount: Int?` (nil =
  unedited, 0 = edited with no versions), like `rating` — a virtualized grid must not
  mount one store observer per tile. Rating + edit state are announced together via
  `tileAccessibilityValue(for:)`.

### Editor — as built

- `EditSession` is the per-file, non-singleton state object: `draft`, `history`,
  compare state, `eyedropperArmed`, the coalescer, and both cached renders
  (`canvasImage`, `originalImage`). `reseed(from:)` replaces the draft AND clears
  history — after switching versions the old history is about a stack the file no
  longer has. `proxyMaxPixel(canvasLongEdge:scale:)` is the hero ladder's formula,
  floored at 1600 and capped at 4096; preview never decodes full-res.
- Autosave debounce is `EditSession.autosaveDelay` (400 ms); exiting Edit mode saves
  immediately. There is no Done/Cancel.
- Editor tabs shipped as specified: right Light / Color / Looks, left Info / History /
  Scopes (Scopes is an empty scaffold). `CurveEditorView(histogram:)` always receives
  nil — the seam Spec 05 fills.
- Curve monotonicity is enforced BY CONSTRUCTION: a point's x is clamped between its
  neighbours, so points cannot cross.
- `WBEyedropper.solve` (in `Components/CanvasPointMath.swift`) is the pure encoded-path
  solve: green is the reference channel, offsets are log2 ratios halved and clamped to
  ±1. The eyedropper is a one-shot MODE — it disarms after the click it consumes.
- `Theme` ships `panelFill`/`panelStroke`/`controlAccent`/`textPrimary`/`textSecondary`
  + spacing/radius/fonts, with `controlAccent = NSColor.systemBlue` (NOT
  `Color.accentColor`, which doesn't adapt between appearances).
- `EditorBackdropLevel.default` is `.mid`; the setting key is
  `AppSettings.editorBackdropKey`.

### Edit-a-Copy — as built

- `OpenWithFork.open(url:appURL:appState:)` is the single seam; `appURL: nil` means
  the default app. Both `OpenWithMenu`'s "Open" and `OpenWithItems`' per-app rows go
  through it, and both views now take `@EnvironmentObject var appState`.
- `EditCopyFlow.run(originalURL:)` renders to a TEMP first, forwards metadata, moves,
  then calls `Indexer.shared.indexFile(at:kind:)`. Stacking with the parent
  (`StackStore`, v17) is **not wired** — recorded, not stubbed.
- `EditCopyMetadata.copyMetadata(from:to:)` forwards EXIF/IPTC minus the orientation
  keys (top-level and TIFF) via `CGImageDestinationAddImageFromSource`.
- `EditCopyNaming.targetExtension(for:isRaw:)` is the RAW → `tif` mapping seam.

### Presets & clipboard — as built

- `EditPresetStore.presetJSON(from:)` is the single geometry-exclusion seam (both
  create and update go through it) and is `nonisolated`.
- `EditClipboard` lives in `Models/EditPresetStore.swift` beside the preset store.
- The batch sweep SNAPSHOTS the clipboard's stack + groups before starting, so a
  clipboard change mid-run can't apply two different looks. It runs through
  `EditStore.applyToAll(_:urls:)`, which executes the full save sequence per file.

### Tests & tooling

- `EditingModuleImportTests` SKIPS (via `XCTSkip`) when the sandbox denies reading the
  source tree — the test host is the sandboxed app, so the grep only runs on a
  checkout OUTSIDE `~/Documents`/`~/Desktop`/`~/Downloads`. It also bans `SwiftUI`,
  not just `AppKit` (SwiftUI pulls AppKit in transitively on macOS).
- `EditRenderConsistencyTests` GENERATES its fixtures into the temp directory rather
  than bundling them (same sandbox constraint), compares on an exact square grid
  (aspect-preserving rounding at three decode scales lands on off-by-one heights), and
  runs at a 6/255 tolerance.
- `HighlightRecoveryTests` fixtures must be FLOAT bitmaps: `CIImage(color:)` clamps its
  components to 0…1, which makes the whole file pass vacuously.
- **`-exportLocalizations` cannot build this project.**
  `Intelligence/Core/ClipVectors.swift` uses `Float16`, which does not exist on
  x86_64, and the extractor builds universal. Pre-existing Spec-03 breakage; Spec 04's
  French strings were written into `Localizable.xcstrings` directly (all 728 keys then
  in the catalog had an `fr` value — that was a point-in-time count, not a standing
  claim; current translation status is in Current state). Fix `ClipVectors` before
  relying on the export workflow again.

## Spec 05 as-built (editing readouts, learning layer, looks & LUTs)

*2026-07-31, `new-product-build-1`. Where this disagrees with the pre-build
"Spec 05" sections above, this section wins.*

### Scope

- Built: v22 `photo_stats` + v23 `edit_luts`; `toneZone`/`lut` appended to `Adjustment`;
  the shared statistics tap; `ScopesPanel`/`HistogramView` + `ClippingMessages`; zebras;
  the tone-zone control (math, guided filter, render stage 2b, strip, target mode) and
  the zone hatch overlay; `NoiseEstimate` + the capture-stat wiring; `PhotoFeedback` +
  `PhotoStatsQueries` + both surfaces; `.cube` import (parser, registry, store, render
  stage 4b, missing-LUT notice); `LooksBrowserView`; the reference pane.
- **NOT built:** the `PerfBaseline` rows for this spec's measurements (the same harness
  gap Specs 03 and 04 left).
- Future specs continue at **v24**.

### Model — as built

- `Adjustment.toneZone` is `canonicalIndex` 6, `.lut` is 7 — appended after `.vignette`.
  `EditStack` gained `toneZoneParams`/`lutParams` accessors, a `setToneZone` mutator in
  the existing find-or-insert family, and `setLut(_:)`, which takes an OPTIONAL: a stack
  carries at most one LUT and "no LUT" is the ABSENCE of the case, never a
  zero-strength one left for the codec to encode.
- `ToneZoneParams.clamped()` pads/truncates as well as bounding. Decoding does NOT
  normalize (the blob round-trips byte-identical); the renderer calls `clamped()`.
- `AdjustmentGroup` gained `toneZone` and `lut` AFTER `raw`. `raw` is not an
  `Adjustment` case, so its position carries no hashing consequence.
- `currentSchemaVersion`/`currentProcessVersion` both stay 1, and the Spec 04 pinned
  fixture hash is unchanged (asserted).

### Render chain — as built

- Order: `1 geometry → 2 tone/WB → 2b toneZone → 3 curve → 4 color → 4b lut →
  5 presence → 6 vignette`. Stage 2b sits after WB because WB already lived between
  tone and curve in Spec 04's code; the spec's "after tone, before curve" is satisfied.
- **`EditRenderer.applyThroughTone` is a new private seam** returning the chain state at
  position 2b plus the radius scale, used by `apply` AND by the new
  `EditRenderer.toneStageImage(url:stack:maxPixel:)`. That entry point is what lets the
  stats tap and the zone overlay sample the SAME pixels the gains act on rather than a
  second approximation. `EditRenderer.decodedProxy(url:stack:maxPixel:)` exposes the
  existing private decode for the Looks browser's one-decode-many-looks sweep.
- Kernel loading follows Spec 04's lazy/non-fatal rule (`CIColorKernel?`, nil skips the
  stage). New kernels: `zebraStripes`, `tzLog2Luma`, `tzSquare`, `tzLinearCoeffs`,
  `tzApplyCoeffs`, `toneZoneGain`, `zoneHatch`, `lutMix` — all covered by
  `EditKernelLoadTests`.
- `tzLog2Luma` is a kernel the plan did not name (it called out the gap): the guide MUST
  be log-domain, because the zone weights are defined over EV and a linear-luminance
  guide bunches eight of nine zones into the bottom stop.
- `ToneZoneFilter.smoothedEVMap(for:longEdge:)` takes a CGFloat long edge (not an Int),
  and `evBuffer(for:longEdge:context:)` is the CPU readback (RGBAf, row-flipped
  top-down so callers index it like a screen buffer).
- `EditRenderer.canRender` now also requires every non-neutral `lut` reference to
  resolve. **Consequence: `canRender` may do a synchronous DB read** — never call it on
  the main thread for a LUT-bearing stack.

### Statistics & readouts — as built

- The tap lives in `EditSession.renderDraft` (not `EditCanvasView`): the session is
  where the completed render already lands, so the tap is a passenger on it rather than
  a second call site. `EditSession.refreshStats()` exists for the case where a panel
  APPEARS without a render coming (opening the Scopes tab).
- `EditSession.statsSampleLongEdge = 256`. `statsVisible` is driven from `EditorView`'s
  `updateStatsVisibility()` — true when the right tab is Light or the left tab is
  Scopes — and is cleared on disappear along with `hoveredZone`/`toneZoneTargeting`.
- `CurveHistogram` MOVED from `Views/Editor/CurveEditorView.swift` to
  `Editing/HistogramCompute.swift` (it needs to be `nonisolated`/`Sendable` for
  `EditStats`, and it belongs beside the code that produces it). `EditStats` and
  `ZoneEVMap` live there too.
- `HistogramData.empty` / `ClippingStats.none` are declared constants — degenerate input
  returns them rather than crashing.
- The Scopes panel says "Nothing is clipping." when the message list is empty: silence
  is the good outcome, but a blank panel reads as broken.

### LUTs — as built

- `LutRegistry.preload(id:size:rgb:)` was added beside `invalidate`: the import path has
  the parsed cube in hand, so the first render must not read it back off disk. It is
  also how `EditRenderConsistencyTests` registers its fixture LUT WITHOUT writing to the
  user's library.
- `LutStore.init(queue:)` is injectable (defaults to `Database.shared.dbQueue`) so its
  tests run against an isolated in-memory database. `importCubes` reloads the listing
  itself; callers don't have to remember to.
- `CubeLUT.canonicalData` is float32 NATIVE-endian. The blob never leaves the device
  (LUTs don't ride sidecars), so byte order is not a portability concern.
- The missing-LUT notice lives at the TOP of `LooksBrowserView`, not in `EditorView`'s
  right card generally — that is where a user goes to fix it.

### Feedback — as built

- `PhotoStatsQueries` has TWO entry points: `feedbackInputs(fileID:db:)` (the hero, which
  already has the id from `ViewerFileDetails`) and `feedbackInputs(path:db:)` (the
  editor, which has only a URL). The data is content-derived, so resolving through the
  alive path needs no `parent_dir` scoping.
- `photo_meta.focal_length_35mm` is an INTEGER column; `PhotoFeedback.Inputs`
  `focalLength35` is a Double, converted at the query seam.
- The editor's Info tab shows the notes AND the RAW process line; the line compares the
  pinned `RawParams.decoderVersion` against `RawSource.currentDecoderVersion(for:)` and
  states the substitution rather than hiding it.

### UI — as built

- `EditCanvasView` gained `zebrasOn` / `zoneMask` / `hoveredZone` / `onScrollWhileTargeting`
  and a `CanvasMTKView` subclass whose only job is intercepting `scrollWheel` during
  target mode. Overlays composite AFTER the fit, so they are screen-space patterns at
  canvas resolution — a zebra scaled with the image moirés on a downscaled proxy.
- The zone hatch's mask is built LAZILY in `EditorView` on first hover and dropped on
  every draft change (a stale mask would hatch pixels the gains no longer act on).
- Zebra + reference toggles live in the existing compare chrome capsule, not a new row.
  The thresholds popover hangs off the zebra button's context menu.
- `EditPresetsTab` was DELETED; its file is now `Views/Editor/WBEyedropperButton.swift`
  (the eyedropper was the only other thing in it). `LooksBrowserView` carries the
  copy/paste buttons the old tab had.
- `KeyCaptureView` gained an `onKey: ((UInt16) -> Bool)?` passthrough (return true to
  consume); the three hardcoded arrow/return handlers stay.
- The Escape order inside the hero's edit-mode branch is now: target mode → editor →
  viewer. `EscapeResolver` is untouched.
- `EditReferenceStore.url` is set from `SelectionMenu` for a single editable-kind
  selection; there is no toast (the app has no general toast seam at that call site) —
  the editor's reference button enabling is the feedback.

### Tests & tooling

- New pure-logic suites: `ToneZoneMathTests`, `HistogramComputeTests`,
  `ClippingMessagesTests`, `CubeLUTParserTests`, `LutRegistryTests`, `LutStoreTests`,
  `PhotoFeedbackTests`, `NoiseEstimateTests`, `PhotoStatsMigrationTests`,
  `EditLutMigrationTests`, `PhotoStatsQueriesTests`; extensions to
  `EditStackNormalizeTests`, `EditStackCodecTests`, `EditTransferTests`,
  `EditSessionTests`, `EditKernelLoadTests`, `EditRenderConsistencyTests`,
  `EditRenderNeutralityTests`.
- **`CIColor` interprets its components as sRGB AND clamps them to 0…1** — both bite
  tone-zone fixtures. A "0.5 grey" `CIImage(color:)` is ≈ −2.2 EV, not −1, so a test
  that sets one zone's gain on it tests nothing; and a negative-EV guide fixture
  silently becomes 0. The neutrality golden therefore asserts the EQUAL-GAINS property
  (equal gains everywhere == a plain `exposureEV` shift, which the partition of unity
  guarantees), and the kernel test probes zone 8 (0 EV). Don't "improve" either back to
  a single-zone fixture.
- `paths` has NO `parent_dir` column (it is derived from `absolute_path`); a test
  inserting a path row needs `id`, `file_id`, `absolute_path`, `is_alive`.
- Localization: `-exportLocalizations` still cannot build this project (the Spec-03
  `Float16`/x86_64 breakage). Spec 05's 56 new keys were written into
  `Localizable.xcstrings` directly with French values; the catalog is now 784 keys.
  **Interpolated keys were hand-written in `%@`/`%lld` form and have NOT been verified
  against extractor output** — a key that doesn't match falls back to the English source
  at runtime, so this degrades gracefully, but fix `ClipVectors` before trusting the
  French build.
