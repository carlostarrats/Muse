# Spec 01 — Foundation & Plumbing

*Hand to Claude Code together with `muse-photo-foundation.md` (the master reference — its §13 decision log overrides any ambiguity here). Build this first; everything else depends on it.*

## Purpose
Prepare the codebase, doctrine, and commercial infrastructure for the photo repositioning. No user-visible features except the announcements channel. Lowest design risk, longest lead times — start immediately.

## In scope

### 1. Doctrine & housekeeping
- Update `CLAUDE.md`: persona changes from "generalist — Downloads/Documents" to the enthusiast-photographer persona (foundation doc §1). Revise the "No editing UI" rule to reflect the two-path editing model (in-app non-destructive + Edit-a-Copy). Document the app-initiated network-path list: (1) Drive share, (2) announcements.json, (3) custom-domain provisioning Worker (future). Everything else stays blocked (StoreKit/App Store traffic is OS-level, not an app path).
- Fix `MuseShareExtension` deployment target (currently 26.5 vs app's 14.6 — reconcile deliberately, document the choice).
- Declare Apple Silicon-only / M1 floor in build settings and docs.
- **Distribution migration (DECIDED #33 — Mac App Store exclusively):** remove the Sparkle dependency and all direct-distribution tooling (DMG scripts, `release.sh`, appcast, GitHub release flow). Target dependency count: ONE (GRDB). Set up App Store Connect app record, MAS provisioning/entitlements build config (app is already sandboxed with security-scoped bookmarks — verify nothing in the current entitlement set is MAS-incompatible), and a TestFlight beta pipeline.

### 2. Coordinates persisted (v13 migration)
- Add `lat`/`lon` (nullable REAL) to `files`; backfill pass in `AnalyzePipeline` reading GPS the way `FileMetadata.coordinate` already does (photos: `kCGImagePropertyGPSDictionary`; videos: ISO 6709). Today coordinates are read on viewer-open and discarded — after this, they persist.
- Indexes for range queries. No UI in this spec (consumed by Spec 02).

### 3. Edit-aware cache & geometry work (isolated, tested, BEFORE any editor code)
The identity/cache layer assumes rendered pixels == original file bytes. Prepare it for non-destructive edits:
- `ThumbnailCache`: cache key must incorporate an edit-stack hash (a `stack_hash` per file, empty/nil = original). Fixed `renderedVariants` discipline stays.
- `ImageHeaderSizeCache` / `AspectRatioCache` / masonry & justified geometry / hero flight geometry / PDF pagination: introduce an "effective dimensions" concept (post-crop) so a future crop cannot desync layout. For now effective == header dimensions; the seam is what matters.
- All export/share paths (`CollectionPDFExporter`, `DriveClient.uploadFile`, share sheet) must go through a single render-for-output function that will later apply the edit stack. For now it passes originals through — but the choke point exists and is tested.
- `Indexer.reconcile` / `analyzed_hash` stay keyed on ORIGINAL bytes (edits never change content identity).
- Tests: cache invalidation on stack-hash change; layout consumers read effective dimensions; export choke point used everywhere.

### 4. Commercial plumbing (StoreKit 2 — DECIDED #33)
- **Products:** one non-consumable IAP (the app unlock, price configurable ~$49) + one auto-renewable subscription group (the sharing tier, ~$15–20/yr). StoreKit 2 purchase/restore/entitlement checking, offline-tolerant, privacy-respecting.
- **Trial gate:** free download runs in trial mode until the unlock IAP (shape OPEN — build the gate, leave policy configurable; time-limited default anchored server-independently). No paid-upfront option exists on MAS — this structure is forced.
- **Gifting:** verified via Apple promo codes (100 per IAP per version) — test the redemption flow.
- Enroll in the App Store Small Business Program (15%).
- **Announcements channel**: fetch `announcements.json` from the existing Cloudflare Pages domain once per launch; each message shown once (tracked by id); Settings toggle to disable; no tracking, no identifiers sent. (App Store "What's New" covers version notes.)

### 5. Performance baseline
- Establish the reference-machine budget harness: M1 Air 8GB targets for cold start, grid scroll, search latency (current search), thumbnail decode. Record baselines now so later phases can regress-test. Fix the two known latent issues if cheap: debounce semantic search; time-bucket the O(n²) clustering (full fix may land in Spec 02/03).

## Out of scope
Any editing UI, any search UI changes, places/rediscovery/stacks (Spec 02), face work, sharing changes.

## Binding decisions (from foundation §13)
#22 analysis always on (don't add analysis toggles while touching the pipeline) · #24/#25 platform floor & scale envelope (no RAM-residency assumptions in new code) · #26 AppState is FROZEN — all new state in new modules · #28 announcements spec as above · #29 gifting via Apple promo codes · #31 repo private / PolyForm Shield · #33 Mac App Store exclusively — no Sparkle, no direct distribution, StoreKit 2 only.

## Acceptance
- v13 migration runs clean on an existing library; backfill completes in background; no UI regression.
- All exports flow through the single render choke point (verified by test).
- Sparkle fully removed; app builds with MAS entitlements; TestFlight build installs and runs.
- Unlock IAP purchasable in sandbox; restore works; trial gate opens/closes correctly; promo-code redemption verified.
- Announcement shows once, respects the off toggle.
- Budget harness produces a written baseline report.
