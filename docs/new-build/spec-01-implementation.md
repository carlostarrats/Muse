# Spec 01 — Foundation & Plumbing: full implementation spec

*Derived from `spec-01-foundation-plumbing.md` + `muse-photo-foundation.md` (§13 decision
log is authoritative). This is the build-level expansion: exact files, exact schema, exact
seams, exact tests. Written before implementation; kept as the record of what was built and
what was deliberately left to the owner.*

> **2026-07-31 amendment:** §1.4 (Sparkle excision), §1.5 (MAS build configuration), and
> the Distribution/Min-macOS doctrine rows in §1.1 are **deferred** at the owner's
> request — the app stays on direct distribution (Sparkle self-update) for now, no fixed
> date for the Mac App Store move. The executable task breakdown for that work now lives
> standalone in `docs/superpowers/plans/deferred-mac-app-store-migration.md`; the
> corresponding tasks were removed from `docs/superpowers/plans/2026-07-30-spec-01-foundation-plumbing.md`.
> Everything else in this spec (§2 onward) is unaffected and does not depend on the MAS
> move landing first.

---

## 0. What this spec does and does not touch

**Does:** doctrine (`CLAUDE.md`, `README.md`, `docs/RELEASING.md`), build settings, Sparkle
excision, a v13 migration, an edit-aware cache/geometry/export seam layer, StoreKit 2
commercial plumbing, the announcements channel, and a performance-baseline harness.

**Does not:** any editor UI, any search UI, places/rediscovery/stacks, faces, sharing
changes. No behaviour visible to a current user changes except the announcement banner and
the (locked-open) trial gate.

**Cannot (owner-only, outside the codebase):** App Store Connect app record, MAS
provisioning profile, TestFlight pipeline, Small Business Program enrolment, sandbox IAP
testing, promo-code redemption. §8 lists these precisely.

---

## 1. Doctrine & housekeeping

### 1.1 `CLAUDE.md` revisions

Four edits, each surgical (the file is loaded every session — keep it lean):

| Section | Change |
|---|---|
| Project identity → persona | "generalist — Downloads/Documents" → the enthusiast-photographer persona (foundation §1: shoots a phone and/or a fun camera, photography is an active interest, wants control Apple Photos won't give without pro-tool cost, wants their best shots shared). Add the non-amputation rule: designers/general users stay valid. |
| Project identity → Distribution | Direct/Sparkle/GitHub Releases → **Mac App Store exclusively** (DECIDED #33). StoreKit 2 for payments; TestFlight for betas; Small Business Program. Note the pivot date and that this supersedes the 2026-06-15 direct-distribution pivot. |
| Project identity → Network policy | Two paths (Sparkle + Drive) → **three app-initiated paths**: (1) Drive share (user-initiated), (2) `announcements.json` (launch, off-able), (3) custom-domain provisioning Worker (future, paid, user-initiated). StoreKit/App Store traffic is OS-level, not an app path. |
| Project identity → Min macOS | 14.6 → **macOS 14.6 + Apple Silicon only (M1 floor)**, with the two-tier scale envelope (design center 10k–50k on M1 Air 8GB; 200k–800k degrades gracefully; **no code may assume RAM-residency**). |
| Conventions → "No editing UI" | Rewrite to the **two-path editing model**: Path A non-destructive in-app stack (originals never touched, edits in DB + sidecars, never written into image files); Path B "Edit a Copy" fork on Open With, copy returns stacked with its parent. The never-modify-user-files and never-write-EXIF/XMP rules are UNCHANGED and restated. |
| Durable constraints | Add three new rules (§3.5 below) for the edit-aware seams, plus one for the frozen `AppState`. |

`AppState` freeze (DECIDED #26) goes in Durable constraints, not just prose: new features
get their own store objects. Everything this spec adds obeys it (`CommerceStore`,
`AnnouncementStore`, `PerfBaseline` are standalone).

### 1.2 Deployment targets

Current state is incoherent:

| Target | Now | After |
|---|---|---|
| project-level | 26.0 | **14.6** |
| Muse (app) | 14.6 | 14.6 |
| MuseTests | 26.2 | 14.6 |
| MuseUITests | (inherits 26.0) | (inherits 14.6) |
| MuseShareExtension | **26.5** | **14.6** |

**The share-extension decision, made deliberately:** the extension is pinned above the host
app. An app extension whose `LSMinimumSystemVersion` exceeds the running OS is not
registered by the system, so **Finder → Share → Muse is silently absent for every user on
macOS 14.6–26.4** — the whole shipped feature is dead for the majority of the supported
range, with no error anywhere. The extension's source uses nothing past 14.6. Reconciling
*down* to 14.6 (rather than raising the app to 26.5, which would abandon the stated floor and
most of the install base) is the only choice consistent with DECIDED #24. Recorded here
because the mismatch was load-bearing-looking and is not.

### 1.3 Apple Silicon only (DECIDED #24)

Project-level build settings: `ARCHS = arm64`, `VALID_ARCHS = arm64`. No Intel slice is
produced; `LSMinimumSystemVersion` stays 14.6 (Apple Silicon Macs all ship ≥ 11, so the
arch restriction is what enforces the M1 floor, not the OS version). Documented in
`CLAUDE.md` and `README.md` requirements.

### 1.4 Sparkle excision (DECIDED #33)

Target dependency count after this: **one** (GRDB).

Delete:
- `Muse/Muse/Updates/Updater.swift` (whole directory)
- `scripts/release.sh`, `scripts/make-dmg.sh`, `scripts/make-dmg-background.sh`, `dmg/`
- `Info.plist`: `SUFeedURL`, `SUPublicEDKey`, `SUEnableAutomaticChecks`,
  `SUEnableInstallerLauncherService`
- `Muse.entitlements` + `Muse-Debug.entitlements`: the
  `com.apple.security.temporary-exception.mach-lookup.global-name` array (Sparkle's XPC
  service names). **MAS-relevant:** temporary-exception entitlements are grounds for App
  Review rejection, so this removal is required, not merely tidy.
- `project.pbxproj`: the `XCRemoteSwiftPackageReference "Sparkle"`, its
  `XCSwiftPackageProductDependency`, the `PBXBuildFile` and its entry in the Frameworks
  build phase, and the `packageReferences` entry
- `Package.resolved`: the Sparkle pin
- `MuseApp.swift`: `@StateObject private var updater`, and `CheckForUpdatesView(...)` +
  its `Divider()` from the `CommandGroup(after: .appInfo)`. The backup/restore items in
  that group stay.

Rewrite:
- `docs/RELEASING.md` → the App Store Connect / TestFlight flow (archive → validate →
  upload → TestFlight → submit), replacing archive → notarize → sign → appcast.
- `README.md` → privacy section lists the three network paths; "Staying up to date"
  becomes the App Store; Tech section drops Sparkle; Requirements gains Apple Silicon;
  Build section drops the Sparkle SPM mention.

### 1.5 MAS build configuration

The app is already sandboxed with security-scoped bookmarks — the hard part is done.
Entitlement audit against MAS rules:

| Entitlement | MAS-compatible? |
|---|---|
| `com.apple.security.app-sandbox` | required ✅ |
| `com.apple.security.network.client` | ✅ |
| `com.apple.security.files.user-selected.read-write` | ✅ |
| `com.apple.security.files.bookmarks.app-scope` | ✅ |
| `com.apple.security.application-groups` | ✅ |
| iCloud container / services / ubiquity | ✅ (needs the capability enabled on the App Store Connect record) |
| `temporary-exception.mach-lookup.global-name` | ❌ **removed with Sparkle** |

No other change is needed to ship to MAS from the codebase side. `ENABLE_HARDENED_RUNTIME`
stays on (harmless for MAS). Signing identity/profile selection is an owner step (§8).

---

## 2. Coordinates persisted — migration `v13_coordinates`

### 2.1 Schema

```sql
ALTER TABLE files ADD COLUMN lat REAL;                 -- signed decimal degrees, WGS-84
ALTER TABLE files ADD COLUMN lon REAL;
ALTER TABLE files ADD COLUMN coords_scanned_hash TEXT; -- content_hash we last read GPS from
CREATE INDEX files_coords_idx ON files(lat, lon) WHERE lat IS NOT NULL;
```

**Why on `files` (content-keyed), not per-location:** GPS lives in the file's own bytes. Two
byte-identical copies in two folders have identical coordinates by definition, and an
edit-in-place already splits the row. This is the same grain as `palette`, `caption`,
`dominant_color`, `feature_print` — and deliberately *not* the tags/notes grain.

**Why `coords_scanned_hash` and not a bare `lat IS NULL` check:** most photos have no GPS.
Without an attempted-marker the backfill would re-open every GPS-less file in the library on
every launch, forever — the exact bug shape as the `analyzed_hash`-NULL retry loop fixed on
2026-07-28. Storing the *hash* rather than a bool means an edit-in-place re-reads (new bytes
may carry new GPS), mirroring `analyzed_hash`. Partial index so a library with no geotagged
photos costs nothing.

`FileRow` gains `lat: Double?`, `lon: Double?`, `coords_scanned_hash: String?`.

### 2.2 Reader — `Filesystem/CoordinateReader.swift`

One nonisolated enum, kind-dispatched, mirroring how `FileMetadata` already reads the same
data (it must not diverge — a viewer showing one location while the DB stores another is
worse than no column):

```swift
enum CoordinateReader {
    static func read(url: URL, kind: AssetKind) async -> Coordinate?
}
```

- `.image/.raw/.psd` → `CGImageSourceCopyPropertiesAtIndex` → `kCGImagePropertyGPSDictionary`
  → the existing pure `FileMetadata.coordinate(latitude:latRef:longitude:longRef:)`. Header
  read only, no decode, so `withinDecodeBudget` is irrelevant here.
- `.video` → `AVURLAsset.noNetwork(url:)` (**never a bare `AVURLAsset`** — durable
  constraint) → `.commonMetadata` → `commonKeyLocation` string → the existing pure
  `FileMetadata.parseISO6709`.
- everything else → nil.
- Dataless iCloud placeholders → nil, never forcing a download (same guard as
  `FileMetadata.load` and `Indexer.isDataless`).
- Rejects non-finite and out-of-range values (`|lat| > 90`, `|lon| > 180`) — a corrupt
  header must not put a pin in the sea. Pure validator `CoordinateReader.sanitize(_:)`,
  unit-tested.

### 2.3 Write points

1. **`AnalyzePipeline.analyzeOne`** — read the coordinate alongside Vision (off-main,
   concurrent with it), and write `lat`/`lon`/`coords_scanned_hash` inside the existing
   guarded write transaction, under the same `file.content_hash == analyzedHash` guard.
   Nothing new about the transaction; three more column assignments.
   **Also runs for `.video`,** which `analyzeOne` currently returns early on — so the
   coordinate write happens *before* the image-kind guard, with its own tiny transaction for
   non-image kinds. A geotagged video must not be invisible to `near:` search in Spec 02
   just because Vision doesn't tag videos.
2. **`Intelligence/CoordinateBackfill.swift`** — launch pass, modelled exactly on
   `IntentBackfill` (fire-and-forget `Task` from `MuseApp`'s `.task`, self-limiting, safe to
   call every launch). Selects files where `coords_scanned_hash IS NULL OR
   coords_scanned_hash != content_hash`, with an alive path, capped per launch
   (`maxPerLaunch = 5_000`) so a 100k cold library spreads over a few launches instead of
   hammering the disk once. Bounded concurrency (4). Writes are one transaction per chunk of
   200, not per file.

No UI in this spec. Consumed by Spec 02 (`.location` smart rule, place-grouped grid).

---

## 3. Edit-aware cache, geometry & export seams

This is the load-bearing part of Spec 01 and the reason the editor is only 3–5 weeks. Three
seams are introduced now, tested now, and are **identity functions today**. Every one exists
so that when Spec 04 lands an edit stack, exactly one implementation changes and every
consumer is already correct.

### 3.1 `Models/EditStackIndex.swift` — the stack-hash seam

```swift
/// The identity of a file's non-destructive edit stack. `nil` = unedited (original bytes).
enum EditStackIndex {
    /// Short, stable digest of the edit stack for a file LOCATION. nil today.
    static func stackHash(for url: URL) -> String?
    /// Post-crop display size, when the stack crops. nil today.
    static func croppedSize(for url: URL) -> CGSize?
    /// Test/Spec-04 seam: install the real provider.
    static func installProvider(_ p: (any EditStackProviding)?)
}

protocol EditStackProviding: Sendable {
    func stackHash(for url: URL) -> String?
    func croppedSize(for url: URL) -> CGSize?
}
```

**Keyed by standardized path, not by `files.id`** — and deliberately **no `files.stack_hash`
column is added.** Foundation §6 puts an edit stack at `(file, parent_dir)` grain,
consistent with tags and notes; `files.content_hash` is UNIQUE, so a column on `files` would
force one edit stack to be shared by the same photo in two folders — the exact defect the
per-location rule for tags and notes exists to prevent. Spec 04 adds the `edits` table at
that grain and installs the provider. Spec 01 deviates from the literal wording of
`spec-01-foundation-plumbing.md` §3 ("a `stack_hash` per file") on purpose, and this
paragraph is the record of why.

Provider access is lock-guarded and `nonisolated(unsafe)` static, same pattern as
`ImageHeaderSizeCache`, because it is read from the thumbnail pipeline off-main.

### 3.2 `ThumbnailCache` — cache key incorporates the stack hash

`cacheKey(url:size:scale:)` gains a stack component, appended **only when a stack hash
exists**:

```
raw = "<standardized path>|<w>x<h>@<scale>"              // unedited (nil hash) — today's string, byte-identical
raw = "<standardized path>|<w>x<h>@<scale>|<stackHash>"  // edited
key = SHA256(raw)                                        // hashed, as today
```

The nil case must leave the raw string untouched — **not** `|<stackHash ?? "">`, which
appends a trailing `|`. The on-disk key is a SHA-256 of the whole raw string
(`ThumbnailCache.cacheKey`, line ~347), so any change to it — even an empty suffix —
re-keys every cached PNG and forces a full-library thumbnail regeneration on upgrade.
`ThumbnailStackKeyTests` pins the nil case to the pre-change key. Because the hash is nil
today, **every existing cached PNG keeps its key** — no mass-regeneration on upgrade. When an edit lands, its thumbnails key differently and the
original's cached bitmaps stay valid (a revert is instant, and the ladder in
`renderedVariants` is unaffected).

`invalidate(_:)` must drop **both** the current-stack and the original-stack variants —
otherwise reverting an edit leaves the pre-edit PNGs orphaned but live. It now loops
`renderedVariants × {current stack hash, nil}`. The existence-probe optimization stays
(measured: 1.5µs probe vs 7µs failed `removeItem`).

The `renderedVariants` discipline is unchanged and still enforced by
`ThumbnailVariantTests`.

### 3.3 `Components/EffectiveDimensions.swift` — the geometry seam

```swift
enum EffectiveDimensions {
    static func cached(_ url: URL) -> CGSize?     // no I/O — safe from a view body
    static func resolve(_ url: URL) -> CGSize?    // may do I/O — off-main only
    static func aspect(_ url: URL) -> CGFloat?    // width ÷ height
}
```

Today: `EditStackIndex.croppedSize(for:) ?? ImageHeaderSizeCache.<same call>`. The
orientation rule is untouched — `ImageHeaderSizeCache` remains the single
orientation-applied truth; `EffectiveDimensions` sits *above* it and is the only thing
layout consumers call.

**Converted consumers** (each currently reads `ImageHeaderSizeCache` directly):

| File | Call site | Why it must be effective, not header |
|---|---|---|
| `Views/GridView.swift` | `TileView.drawnAspectRatio` | a crop changes where the photo draws inside its slot — ring/hover/badge would hug the uncropped rect |
| `Views/Viewer/HeroStage.swift` | `resolveHeaderSize()`, the >40MP mid-res gate | the flight's take-off/landing rect is `fitWithin(effective, tileFrame)`; a crop desyncs it from the tile |
| `Viewers/FileMetadata.swift` | the Dimensions/MP row | the INFO card must state what the user sees |
| `Views/AspectRatioCache.swift` | `imageIOAspect` cold path | masonry/justified packing |
| `Export/CollectionPDFLayout` consumers | via the exporter's decoded sizes | already post-render (§3.4), so correct by construction |

`ImageHeaderSizeCache` keeps its direct callers where the *header* really is what is wanted:
`ThumbnailCache.declaredPixelCount` (decode budget + prewarm — the raw file's pixel count,
not the crop) and `VisionServices.analyze` (analysis reads original bytes;
`files.width/height` describe the original, and `analyzed_hash` is keyed on original bytes —
foundation §6's explicit rule).

`AspectRatioCache`'s **DB** path (`files.width/height`) also stays original-dimensioned for
the same reason, with `EffectiveDimensions` consulted first so a cropped file overrides it.

### 3.4 `Export/OutputRender.swift` — the export choke point

Every path that ships pixels out of the app must render through the edit stack. Today it
passes originals through, but the choke point is **compile-time enforced**, not documented:

```swift
/// Bytes approved for leaving the app. The ONLY way to obtain one is OutputRender.
struct RenderedOutput: Sendable {
    let url: URL          // file to read (the original today; a rendered temp later)
    let stackHash: String?
    fileprivate init(url: URL, stackHash: String?)   // fileprivate to OutputRender.swift
}

enum OutputRender {
    static func forOutput(_ url: URL) throws -> RenderedOutput
    static func forOutput(_ urls: [URL]) throws -> [RenderedOutput]
    /// Decoded, downsampled image for a rendering export (PDF).
    static func image(_ out: RenderedOutput, maxPixel: Int) -> CGImage?
}
```

`RenderedOutput.init` is `fileprivate`, so no other file in the target can fabricate one.
A new export path physically cannot compile without going through `OutputRender`. That is
the test the spec asks for ("export choke point used everywhere") expressed as a type rather
than a grep.

**Converted call sites:**

| Path | Change |
|---|---|
| `Export/CollectionPDFExporter.imageIOThumbnail` | takes `RenderedOutput`; exporter maps its `urls` through `OutputRender.forOutput` once, up front. The QuickLook/video/audio fallbacks are *not* rendering paths (a video frame or type icon carries no edit stack) and keep taking `URL`. |
| `Sharing/Drive/DriveClient.uploadFile` | signature becomes `uploadFile(_ out: RenderedOutput, name:mime:parent:)`; `ImageMetadataStripper.strip(_:mime:)` takes `RenderedOutput`. **The strip still runs on the post-render bytes** — order matters: render first, strip second, so a future edit can't reintroduce metadata past the stripper. Fail-closed behaviour unchanged. |
| `Views/SelectionMenu.swift` share | `NSSharingServicePicker(items: OutputRender.forOutput(fileURLs).map(\.url))` |
| `Views/Viewer/ShareButton.swift` | same |
| `Views/DriveShareForm.swift` | shares a *text* link, not pixels — untouched, noted so a future reader doesn't "fix" it. |

`Backup/` is **not** an export path — a backup restores originals and their metadata by
content hash; rendering edits into it would corrupt the restore. Explicitly out, documented
in `OutputRender`'s header.

### 3.5 New durable constraints (added to `CLAUDE.md`)

1. **Everything that leaves the app goes through `OutputRender`.** `RenderedOutput`'s
   `fileprivate` init is the enforcement; don't relax it, don't add a public initializer,
   and don't let a new share/export/publish path take a bare `URL`. Backup is the one
   deliberate exclusion (it restores originals).
2. **Layout reads `EffectiveDimensions`, analysis and decode budgets read
   `ImageHeaderSizeCache`.** The header cache stays the single orientation truth;
   `EffectiveDimensions` is the crop-aware layer above it. `files.width/height`,
   `analyzed_hash` and `Indexer.reconcile` stay keyed on ORIGINAL bytes — an edit never
   changes content identity.
3. **The thumbnail cache key carries the edit-stack hash, and `invalidate` drops both the
   current and the original stack's variants.** Dropping only one leaves live orphaned PNGs
   that resurface on revert.

---

## 4. Commercial plumbing (StoreKit 2)

New module `Commerce/`, own store object (AppState is frozen).

### 4.1 Products

| Id | Type | Purpose |
|---|---|---|
| `com.tarrats.Muse.unlock` | non-consumable | the app unlock (~$49, price set in App Store Connect) |
| `com.tarrats.Muse.sharing.yearly` | auto-renewable, group `sharing` | sharing tier (~$15–20/yr) |

Ids are constants in `Commerce/CommerceConfig.swift` — the only place they appear.

### 4.2 `Commerce/CommerceStore.swift`

`@MainActor final class CommerceStore: ObservableObject` — a real singleton, injected as an
`@EnvironmentObject` like `GoogleOAuth`.

- `@Published private(set) var entitlements: Entitlements` (`unlocked: Bool`,
  `sharing: Bool`)
- `products()` loads via `Product.products(for:)`, cached; failure is non-fatal
- `purchase(_:)` → `Product.purchase()`, handles `.success(verified)` /
  `.success(unverified)` (rejected) / `.userCancelled` / `.pending`
- `restore()` → `AppStore.sync()` then re-read
- a long-lived `Transaction.updates` listener task started at init (required — StoreKit 2
  delivers Ask-to-Buy/interrupted purchases here) that finishes transactions and re-reads
- `refresh()` walks `Transaction.currentEntitlements`, verified-only
- **Offline-tolerant:** entitlements are mirrored to a local cache
  (`CommerceCache`, `UserDefaults` + a `Keychain`-backed copy of the unlock flag) and read
  synchronously at launch, so a purchased user offline on a plane is never locked out while
  StoreKit warms up. The cache is *permissive only* — it can grant an entitlement StoreKit
  hasn't confirmed yet, and never revokes one StoreKit does confirm. Revocation happens only
  on a verified StoreKit read that lacks the entitlement.
- **Privacy:** no identifiers sent anywhere, no receipt posted to any server, no
  `appAccountToken`. The App Store's own traffic is OS-level and does not change the
  "Data Not Collected" label.

### 4.3 `Commerce/TrialGate.swift` — pure, tested, policy-configurable

MAS has no paid-upfront-with-trial, so the structure is forced: free download → trial →
unlock IAP. The *policy* is OPEN (Spec 09), so the gate is built and the policy is one
struct:

```swift
struct TrialPolicy {
    var duration: TimeInterval        // default 14 days
    var enforced: Bool                // default FALSE in this spec — see below
}

enum TrialGate {
    static func state(now: Date, firstLaunch: Date?, entitled: Bool,
                      policy: TrialPolicy) -> TrialState   // .unlocked / .trial(daysLeft:) / .expired
}
```

Pure function, exhaustively unit-tested (clock skew, missing anchor, `entitled` short-circuit,
day-boundary rounding).

**Anchored server-independently and tamper-resistantly:** first-launch date is written to
the Keychain (`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, same class as the Drive
tokens) rather than `UserDefaults`, so deleting a plist doesn't reset the trial. It is
*earliest-wins*: if a Keychain anchor and a `UserDefaults` mirror disagree, the earlier one
is used, and the anchor is never moved forward.

**`enforced` defaults to `false` until pricing is decided (Spec 09).** The gate computes
state, the UI can read it, and nothing is blocked. That is the honest reading of "build the
gate, leave policy configurable" — shipping a live paywall against undecided pricing would
lock out the current testers.

### 4.4 Gifting

Apple promo codes (100 per IAP per version) need no code. `restore()` and the
`Transaction.updates` listener already handle a redeemed code arriving as a transaction.
**There is no in-app redemption sheet on macOS** (`presentCodeRedemptionSheet` /
`presentOfferCodeRedeemSheet` are iOS-only) — the Settings "Redeem Code" row opens the App
Store's redemption page (`NSWorkspace.open` → `https://apps.apple.com/redeem`), and the
`Transaction.updates` listener picks the unlock up when the user returns to the app.
Verification of the actual redemption flow is an owner step (§8).

### 4.5 Announcements — `Commerce/AnnouncementStore.swift`

DECIDED #28. Static JSON on the existing Cloudflare Pages domain (the same host that serves
the share page — `DriveConfig.shareBaseURL`), so no new infrastructure and no new domain.

- URL: `\(DriveConfig.shareBaseURL)/announcements.json`, constant in `CommerceConfig`
- Fetched **once per launch**, `.reloadIgnoringLocalCacheData` off a `URLSession` with a
  10s timeout; any failure is silent (no retry, no error UI)
- Shape:
  ```json
  { "version": 1,
    "messages": [ { "id": "mobile-2026-08", "title": "…", "body": "…",
                    "url": "https://…", "minAppVersion": "1.6" } ] }
  ```
- Each message shown **once**, tracked by id in `UserDefaults`
  (`announcementsSeenIDs`, capped at 200 ids)
- `AppSettings.announcementsEnabled` (default true) — a Settings toggle disables the fetch
  entirely (not just the display)
- **Nothing is sent.** No query string, no identifiers, no `User-Agent` customization, no
  cookies (`.ephemeral` session configuration). A plain GET of a static file.
- Hardening, mirroring the share page's rules: response capped at 64 KB before decode;
  `id`/`title`/`body` length-capped and run through the same bidi/zero-width/control-char
  sanitization the share page uses; `url` must be `https` and is opened only on explicit
  click; unknown `version` values are ignored rather than guessed at.
- Pure parsing/selection logic (`AnnouncementFeed.parse`, `.unseen(_:seen:appVersion:)`) is
  separated from the fetch so it is fully unit-testable — matching how every other pure
  component in this codebase is structured.
- Presentation: a `ModalMessageCard` at the shell (never `.alert` — durable constraint),
  registered in `AppState.modalPresented`.

### 4.6 Settings surface

One new `Settings` section, "Muse" (above Google Drive):
- entitlement status line + Unlock / Restore Purchases buttons (`ModalButton` — durable
  constraint; no stock SwiftUI buttons, no `.alert`)
- Redeem Code row
- "Show announcements" toggle

---

## 5. Performance baseline harness

`Perf/PerfBaseline.swift` + a `MuseTests/PerfBaselineTests.swift` that records rather than
asserts (a failing perf test on a busy CI machine is noise; a recorded number is evidence).

Measures, against the M1 Air 8GB reference (DECIDED #24):

| Metric | Budget | How measured |
|---|---|---|
| cold start → first grid paint | 1500 ms | existing `PhaseTrace` marks |
| grid scroll frame time | 16.7 ms p95 | `CADisplayLink`-equivalent sampling during a scripted scroll |
| search latency (current FTS + semantic) | 150 ms p95 | direct `SearchService` timing over a synthetic 10k index |
| thumbnail decode (single 24 MP JPEG) | 60 ms | `ThumbnailCache` path, cache cleared |

`PerfBaseline.run()` writes a Markdown report to
`docs/perf-baseline-<date>.md` with machine identifier, OS, library size and each measured
number beside its budget. Deliberately *not* wired into the app UI — it is a developer
command (`MUSE_PERF=1` env var at launch, plus a test-target entry point).

**The two known latent issues, fixed here because they are cheap:**

1. **Semantic search coalescing.** The foundation doc lists "per-keystroke semantic
   search" as a latent issue, but the code has moved since that note was written: the field
   already debounces 250 ms, `searchQuery` commits only when a search runs, and `runSearch`
   already guards its publish with a monotonic `searchRequestToken`
   (`AppState+Search.swift:20–33`) — a superseded pass **cannot** land. What remains is
   wasted work, not a wrong result: two committed queries in flight each run the full
   embedding + cosine walk to completion. Fix: thread the token (or Task cancellation) into
   the semantic leg so a superseded pass exits before/during the expensive walk. Small,
   local, testable; the baseline report records the before/after.
2. **O(n²) clustering time-bucketing.** `HybridClusterer` is already an exact tiled
   `vDSP_mmul` (2026-07-28) — the remaining n² is the *comparison count*, not the inner
   loop. **This spec does not touch it.** Time-bucketing changes clustering *semantics*
   (two similar photos years apart stop merging), which is a product decision belonging with
   near-duplicate stacks in Spec 02, and the existing `SimilarityMatrixTests` equivalence
   guarantee would have to be re-specified. Measuring it into the baseline report is the
   Spec 01 deliverable; changing it is not. Recorded so this reads as a decision, not an
   omission.

---

## 6. Tests

New test files, all pure-logic (the codebase's convention — no UI unit tests):

| File | Covers |
|---|---|
| `CoordinateReaderTests` | `sanitize` bounds/NaN, GPS-dict → signed coordinate for N/S/E/W refs, ISO 6709 reuse, missing-GPS → nil |
| `CoordinateMigrationTests` | v13 runs clean on a v12 library; columns + partial index present; existing rows untouched; idempotent re-migrate |
| `EditStackIndexTests` | nil provider = nil hash/size; installed provider is consulted; provider removal restores identity |
| `ThumbnailStackKeyTests` | key differs when the stack hash differs; key is byte-identical to the pre-change key when the hash is nil (proves no cache-wipe on upgrade); `invalidate` covers both stacks × every `renderedVariants` entry |
| `EffectiveDimensionsTests` | falls back to the header cache; crop overrides it; orientation swap survives the extra layer |
| `OutputRenderTests` | `forOutput` is identity today; `RenderedOutput` cannot be constructed outside the file (compile-time — asserted by a doc-comment + the absence of a public init, verified by the fact that the tests must call `OutputRender`) |
| `TrialGateTests` | every `TrialState` branch, entitled short-circuit, clock rollback, missing anchor, earliest-wins anchor resolution, `enforced: false` never expires |
| `AnnouncementFeedTests` | parse of valid/invalid/oversized JSON, unseen filtering, seen-cap, `minAppVersion` gating, sanitization of hostile title/body, non-https url rejection |
| `CommerceEntitlementTests` | pure entitlement resolution from a transaction set; cache is permissive-only (grants, never revokes) |

Existing suites that must stay green and are touched: `ImageHeaderSizeCacheTests`,
`ThumbnailVariantTests`, `FileMetadataLoadTests`, `CollectionPDFLayoutTests`,
`DriveMultipartTests`.

---

## 7. Build order

1. Doctrine + build settings + Sparkle excision (mechanical; do first so every later build
   is against the target configuration)
2. v13 + `CoordinateReader` + write points + backfill
3. `EditStackIndex` → `EffectiveDimensions` → `ThumbnailCache` key → consumer conversions
4. `OutputRender` + export/share call-site conversions
5. `CommerceStore` / `TrialGate` / `AnnouncementStore` + Settings surface
6. `PerfBaseline` + the semantic-search debounce fix
7. Tests, docs (`architecture-map.md`, `session-log.md`, `CLAUDE.md` phase table)

---

## 8. Owner-only steps (cannot be done from the codebase)

These are the acceptance items in `spec-01-foundation-plumbing.md` that require the owner's
Apple account and are **not** delivered by this build:

1. Create the App Store Connect app record for `com.tarrats.Muse`; enable the iCloud
   capability on it.
2. Create the two IAP records (`…unlock` non-consumable, `…sharing.yearly` in a `sharing`
   subscription group) and set prices. **Until these exist, `Product.products(for:)` returns
   empty and the Settings section shows "unavailable" — that is correct behaviour, not a
   bug.**
3. Enrol in the App Store Small Business Program (15%).
4. Select the MAS distribution certificate + provisioning profile for the Release
   configuration (signing is `Automatic` today; MAS needs a Mac App Distribution identity).
5. Upload a build, verify it installs from TestFlight for Mac.
6. Sandbox-test purchase + restore with a StoreKit sandbox account, and redeem one promo
   code.
7. Run `PerfBaseline` on the actual M1 Air 8GB and commit the produced report.
8. Deploy `announcements.json` to the Cloudflare Pages site (an empty
   `{"version":1,"messages":[]}` is the correct initial state — the app must handle a 404
   silently either way, and does).

---

## 9. Deliberate deviations from the source spec

Recorded so they read as decisions, not drift:

1. **No `files.stack_hash` column** — the edit stack is per `(file, parent_dir)`; a column on
   the content-keyed `files` table would force two folders' copies to share one edit stack.
   §3.1.
2. **Clustering time-bucketing not done** — it changes clustering semantics and belongs with
   Spec 02's near-duplicate stacks. Measured, not changed. §5.
3. **Trial gate ships unenforced** — pricing is OPEN (Spec 09) and a live paywall against
   undecided pricing would lock out current testers. §4.3.
4. **Share-extension target reconciled DOWN to 14.6**, not the app up to 26.5. §1.2.
5. **Backup is excluded from the export choke point** — it restores originals by content
   hash; rendering edits into it would corrupt the restore. §3.4.
