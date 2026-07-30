# DECISIONS.md — binding decisions from Specs 01–03

*Extracted 2026-07-30 from `spec-01-implementation.md`, `spec-02-implementation.md` and
`spec-03-implementation.md` (the build-level specs, which supersede the corresponding
`pre-spec-*` files where they deviate), verified against the codebase at `6fdce05`
(`feat/editing`). **Note:** as of that commit no Spec 01/02/03 code exists in the
tree — migrations end at `v12_smart_collections`; the implementation specs are the
settled record, written before build. Product-level decisions live in
`muse-photo-foundation.md` §13 (authoritative decision log); this file is the
build-level layer future specs must not contradict.*

---

## Platform & distribution

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
  Worker (future, paid, user-initiated), (4) search-model download (Spec 03 —
  strictly user-initiated via Settings or the one-time offer card, pinned host,
  manifest SHA-256-verified, fail closed, nothing sent). StoreKit/App Store traffic is
  OS-level and not counted. Everything else stays blocked.
- Reverse geocoding is fully offline (bundled GeoNames + k-d tree). `CLGeocoder` and
  MapKit geocoding are forbidden (network + throttled).
- Map link-outs (`maps://`, `https://www.google.com/maps?q=lat,lon` via
  `NSWorkspace.open`) are browser/app hand-offs, not app network calls — same doctrine
  class; the app never touches those URLs with `URLSession`.

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
  **`enforced: false` until pricing is decided (Spec 09)** — the gate computes state,
  nothing is blocked.
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
  `CullStore`, `NLQuerySuggest`.
- Sanctioned AppState integration cost per store: one stored `objectWillChange`-forwarding
  cancellable in `AppState.init` (the `folderStats` pattern) + a methods-only
  `AppState+<Feature>.swift` extension for orchestration. Nothing else.
- New module folders: `Commerce/`, `Perf/`, `Search/`, `Intelligence/Geo/`,
  `Intelligence/Stacks/`, `Intelligence/Core/` (shared pure helpers, e.g.
  `FeaturePrints`), `Intelligence/Clip/` (model store, tokenizer, engine,
  preprocessing), `Views/Compare/`.
- Database read/write helpers are nonisolated enums of pure `db`-taking funcs in
  `Database/` (`PlaceQueries`, `RediscoveryQueries`, `StackStore` — the `NoteStore`
  shape).
- Pure logic lives in nonisolated enums/structs, unit-tested without UI; `Components/`
  holds pure UI math (`StackDisplay`). House convention: no UI unit tests.
- Shared mutable statics read off-main are lock-guarded `nonisolated(unsafe)` (the
  `ImageHeaderSizeCache` pattern — used by `EditStackIndex`).
- Launch backfills are fire-and-forget `Task`s from `MuseApp`'s `.task`, modelled on
  `IntentBackfill`: self-limiting, safe to call every launch, `PhaseTrace`-marked.
- The semantic-token Theme layer (foundation #27) does **not** exist and is not created
  by Specs 01–02. Until its own spec lands (required before Spec 04's editor UI), new
  surfaces use system semantic colors, the shared `SidebarView` constants, and
  `moodPalette` — no raw hex.
- Mobile-later prerequisites remain design constraints: edit stacks mirrored into
  sidecars; nothing may make the per-field sidecar clock harder.

## Database schema & migrations

- Migration numbering is fixed: **v13 coordinates · v14 `photo_meta` · v15 `places` ·
  v16 `last_viewed_at` · v17 stacks · v18 `clip_embeddings` · v19 `photo_traits`** —
  separate migrations so features land in separate commits without renumbering. Future
  specs continue at v20. Registered at the end of
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
  future edit stack.
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

## Edit-aware seams (identity functions until Spec 04)

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
- Spec 04: the `edits` table, edit stack provider, any editor UI.
- Spec 06: import-scale throttling (battery/Low Power/thermal pausing).
- Spec 09: pricing, trial enforcement policy.
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
