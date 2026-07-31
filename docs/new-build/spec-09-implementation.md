# Spec 09 — Launch Readiness: full implementation spec

*Derived from `pre-spec-09-launch-readiness.md` + `muse-photo-foundation.md` (§1, §9, §11,
§13) + `DECISIONS.md` (the build-level layer of Specs 01–08, which this spec must not
contradict). Written before implementation. Prereq: Specs 01–07 shipped; Spec 08 can trail
everything here except the `ALLOW_SANDBOX` flip (which is meaningless until the Worker
exists).*

***Pricing status (owner statement, 2026-07-30): "none of the pricing is decided."***
*Every number in §1 is a WORKING PLACEHOLDER so that App Store Connect products exist and
TestFlight flows run end-to-end. The build is price-agnostic by construction (prices live
only in App Store Connect; every surface renders `Product.displayPrice`), so the final
pricing call requires zero code change and can land as late as the GA submission.*

---

## 0. What this spec does and does not touch

**Does:** trial enforcement (the gate built by Spec 01 goes live, plus the unlock-gate UI
that did not exist anywhere yet), the tier-enforcement flips and their sequencing
(`SharingTier.enforced`, Worker `ALLOW_SANDBOX`, `DriveConfig.consentScreenVerified`),
**Spec 04 amendment A2** (edit data must actually ride the `.muselibrary` archive — a real
discrepancy, §4), the performance-validation tooling and protocol (synthetic 500k library
generator, scale rows in the baseline harness, the launch reports), the `web/share` legal
pages and About-card rewrite for a paid PolyForm-Shield app, ASO drafts, Info.plist
compliance keys, and the launch checklist with a verification per item.

**Does not:** any migration (**none — future specs still continue at v24**), any new
feature surface, the share page (`web/share/index.html`/`share.js` untouched), any search
or editing behavior, any change to the four-path network doctrine.

**Cannot (owner-only, outside the codebase):** the pricing decision itself and ASC price
entry, App Review submission, the TestFlight photographer cohort, the MobileCLIP weights
legal read, Google OAuth consent verification, the marketing-site rewrite (separate repo),
running the validation passes on the physical M1 Air. §12 lists these precisely.

---

## 1. Pricing — structure fixed, numbers OPEN

### 1.1 What is and isn't decided

The **structure** is decided and already built (DECIDED #33, Spec 01): free download →
built-in trial → `com.tarrats.Muse.unlock` (non-consumable) for the app;
`com.tarrats.Muse.sharing.yearly` (auto-renewable, group `sharing`) for the sharing tier
(custom domain + portfolio); `username.muse.app` included with the unlock (the Worker
already requires the unlock JWS on username endpoints — Spec 08); Apple promo codes for
gifting; Small Business Program 15%.

The **numbers** are NOT decided. Working placeholders, entered in App Store Connect so
products load and TestFlight can exercise every purchase path:

| Product | Placeholder | Constraint |
|---|---|---|
| `com.tarrats.Muse.unlock` | **$49.99** | ≤ $100 hard ceiling (DECIDED #30); leaning band $34.95–$59.99 (Eagle/Atlas ↔ Photomator-lifetime anchors) |
| `com.tarrats.Muse.sharing.yearly` | **$19.99/yr** | leaning band $15–20/yr (vs Savee $15/**month**) |

Price changes are pure ASC configuration — no build, no review resubmission required for a
price edit. The final call is deliberately deferred to the end of the TestFlight
validation pass (§7), which exists partly to reality-check "I'd pay $49.99" as a sentence.
When decided, the numbers are recorded in `DECISIONS.md` and the foundation doc's §13
table; nothing in the repo's Swift changes.

### 1.2 The price-agnostic invariant (acceptance-checked)

**No price ever appears in code, resources, or `.xcstrings` values.** Every surface that
shows a price renders `Product.displayPrice` (unlock gate §2.5, ShareDomainCard pitch —
already the Spec 08 rule — and the Settings Muse section). Acceptance: grep the app target
and `Localizable.xcstrings` for `$49`, `$19`, `49.99`, `19.99` → zero hits. Copy that
needs a price interpolates the loaded product's `displayPrice`; if products haven't loaded
(offline), the copy omits the price rather than guessing ("Unlock Muse" with no number —
never a stale or hardcoded one).

### 1.3 ASC configuration (owner, working placeholders)

1. Set the two placeholder prices above on the existing IAP records (created in Spec 01
   owner step 2).
2. Localize IAP display names/descriptions (EN + FR — the app is localized; the App Store
   product metadata should match).
3. Generate one batch of promo codes for the unlock and redeem one end-to-end (Spec 01
   owner step 6 if not yet done).

---

## 2. Trial enforcement

### 2.1 Shape — working default: 14-day full trial

The pre-spec's own recommendation, adopted as the working default: **everything works for
14 days from first launch, then a hard unlock gate**. Owner confirms (or adjusts the
duration constant) at the same moment as the pricing call — a duration change is one
number. The alternatives are deliberately NOT built:

- *Capacity-limited* (e.g. 1,000 photos) — is a permanent free tier for small libraries,
  against "the free download is a TRIAL vehicle, not a free tier" (foundation §11).
- *Feature-limited freemium* — explicitly "NOT chosen so far" in the pre-spec; building it
  would fragment every feature surface behind entitlement checks.

Post-expiry behavior follows from "not a free tier": the whole app sits behind the gate
(§2.5). Nothing is held hostage — the honest reassurance is that Muse never imported
anything: photos stay in the user's folders, and edits/tags/notes live in the DB +
sidecars, all waiting unchanged behind the gate.

### 2.2 `TrialPolicy` goes live + the trial epoch

`Commerce/TrialGate.swift` keeps Spec 01's pure shapes (`TrialGate.state(now:firstLaunch:
entitled:policy:) -> TrialState`, `.unlocked / .trial(daysLeft:) / .expired`) untouched.
Additions:

```swift
struct TrialPolicy {
    var duration: TimeInterval        // unchanged
    var enforced: Bool                // unchanged
    /// Bumping the epoch grants every install a fresh trial (the "generous
    /// re-trial on major versions" mechanism — a future one-constant change).
    static let epoch = 1
    static let current = TrialPolicy(duration: 14 * 86_400, enforced: true)
}
```

**`enforced` flips TRUE in this spec's build** — a deliberate supersession of Spec 01's
"live paywall would lock out testers" rationale: TestFlight purchases are sandbox
purchases (free), so testers are not locked out — they *exercise the gate*, which is
exactly the purchase-flow E2E the launch checklist demands. If a beta round ever needs a
gate-free build, the constant is one line.

**Anchor keying by epoch:** the Keychain first-launch anchor key becomes
`"muse.trial.anchor.e\(TrialPolicy.epoch)"`. For epoch 1, Spec 01's original unnumbered
key (and the UserDefaults mirror) are read as legacy inputs under the existing
earliest-wins rule, so no tester's anchor resets on upgrade. A future epoch bump reads
ONLY its own key — that is what makes the re-trial grant clean. All other anchor rules are
unchanged: Keychain `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, earliest-wins
against the mirror, never moved forward.

Consequence, recorded: long-running TestFlight testers whose epoch-1 anchor predates this
build by > 14 days hit the gate immediately on update. That is intended — they
sandbox-purchase (free) and validate the flow. Public-launch users all start fresh
anchors; **the epoch does NOT bump at GA.**

### 2.3 Gate state on `CommerceStore`

`CommerceStore` (Spec 01) gains trial awareness — no new store, no AppState property:

```swift
@Published private(set) var trialState: TrialState = .trial(daysLeft: 14)
var trialGateActive: Bool {
    if case .expired = trialState { return !entitlements.unlocked }
    return false
}
```

`trialState` is recomputed from `TrialGate.state(...)` at: init (synchronous, from the
cached anchor — the gate must be correct at first paint, same posture as the permissive
entitlement cache), every entitlements change (purchase/restore/`Transaction.updates`),
and `NSApplication.didBecomeActiveNotification`. **No timer** — a trial that expires
mid-session gates on the next app activation, not mid-keystroke (recorded, accepted).
`.unlocked` short-circuits everything, per the existing pure gate.

### 2.4 Key/Escape integration — zero new AppState state

- `AppState.modalPresented` (AppState.swift:514) gains
  `|| CommerceStore.shared.trialGateActive` — the grid's `PageScrollCatcher` and every
  other key consumer is already gated on `modalPresented`, so keys can't drive the grid
  behind the gate. This is a computed read of another store from a computed property —
  no new `@Published`, no forwarding cancellable; re-evaluation is free because
  `ContentView` already observes `CommerceStore` as an `@EnvironmentObject` (Spec 01) and
  key handlers read `modalPresented` at event time.
- **The gate is NOT dismissible and NOT in the Escape peel.** `dismissTopModal` skips it
  explicitly: when the only thing making `modalPresented` true is `trialGateActive`,
  `EscapeAction.dismissModal` resolves to a no-op (return without clearing anything).
  `EscapeResolver`'s order is otherwise unchanged.

### 2.5 `Views/UnlockGateView.swift` — the gate card

Rendered directly in `ContentView`'s detail `ZStack`, attached **after** the
`alertRequest` presenter — nothing may draw above it (while gated, nothing else raises
cards; purchase errors render inline, §below). It reuses the `.museModal` card visuals
(scrim + centered card sized by `GeometryReader`, width 460) but deliberately does NOT go
through `.museModal(isPresented:)` — that machinery exists to dismiss, and this card must
not: no ✕, no scrim-click dismiss, Escape no-op (§2.4). Built only while
`trialGateActive` (so a purchase unmounts it via the entitlements publish).

Content, top to bottom (all `ModalButton`, all copy `String(localized:)`):

1. App icon + title *"Your trial has ended"*.
2. Reassurance body — the no-catalog story doing product duty: *"Your photos, edits, tags
   and collections are untouched — Muse never moved them. Everything is exactly where you
   left it."*
3. One-line pitch + price from `Product.displayPrice` (omitted if products haven't
   loaded — §1.2). Never mentions the sharing tier (separate purchase, separate surface).
4. **Unlock** (`.prominent` → `CommerceStore.purchase(unlock)`) · **Restore Purchases**
   (`restore()`) · **Redeem Code** (opens `https://apps.apple.com/redeem`; the
   `Transaction.updates` listener picks up the result — Spec 01 §4.4).
5. Links row: Privacy Policy · Terms of Use (the `web/share` URLs — required near any
   purchase UI for App Review; shared component §2.7).
6. **Quit Muse** (`.normal`, `NSApp.terminate`) — the honest exit; the gate never traps a
   user in a window they can only force-quit.

Purchase/restore failures render as an inline error line in the card (never the
`alertRequest` seam — nothing presents above the gate). `.pending` (Ask to Buy) renders an
inline "waiting for approval" line and the listener resolves it.

### 2.6 During-trial surfaces (deliberately minimal)

- **Settings → Muse section** (Spec 01 §4.6): the status line becomes state-aware —
  *"Trial — N days left"* / *"Unlocked"* / *"Trial ended"* — above the existing
  Unlock/Restore buttons. This is the always-available place to buy early.
- **Expiry reminder:** when `daysLeft ≤ 3`, once per launch (a per-launch flag, never
  persisted), a confirm-shaped `ModalMessageCard` via the `alertRequest` seam:
  *"Your Muse trial ends in N days."* — **Unlock…** (`.prominent` →
  `CommerceStore.purchase`) / **Later**. Registered nowhere new (`alertRequest` is already
  in `modalPresented`).
- Nothing else. No toolbar badge, no nag on every launch, no watermarks. The status pill
  stays background-work-only.

### 2.7 `Views/SubscriptionLegalLinks.swift` (small shared component)

The Privacy/Terms links row required beside purchase UI, used by `UnlockGateView` AND
added to `ShareDomainCard`'s pitch state (state 1, Spec 08 §6.3 — an addition to that
card, recorded here as **Spec 08 amendment A3**: App Review requires functional
privacy-policy and terms links in apps offering auto-renewable subscriptions; metadata
links alone are not reliably accepted). Two `Link`-styled buttons opening
`\(DriveConfig.shareBaseURL)/privacy` and `/terms` via `NSWorkspace.open`.

### 2.8 Manage Subscription

Settings → Muse section gains a **"Manage Subscription"** row, visible only while
`entitlements.sharing` is true, opening `https://apps.apple.com/account/subscriptions`
(macOS has no in-app manage sheet worth building; this is the standard hand-off). Cancel
flows are Apple's; the Worker's lapse sweep + `DomainConfig.lapseGraceDays` messaging
(Spec 08) already handle the aftermath.

### 2.9 What the gate blocks — and what keeps running

The gate blocks the entire UI (it overlays the shell; keys gated via `modalPresented`).
Launch-time background machinery is deliberately NOT gated: backfills, the
`DriveExpirySweeper`, `ShareDomainRefresher`, and sidecar hydration all run normally —
they are the user's own data maintenance, and freezing them behind a paywall could rot
state (an expiring Drive share should still sweep). Recorded plainly: the trial gates the
*product*, not the user's data hygiene.

---

## 3. Launch flips — one procedure, four switches

The build-time flips land in this spec; the GA-time flips are deploy/ASC actions with no
build. Sequencing is the point — get it wrong and either testers can't test or launch
users hit sandbox refusals:

| Switch | Value | When | Where |
|---|---|---|---|
| `TrialPolicy.current.enforced` | `true` | **this spec's build** (testers exercise the gate; sandbox purchases are free) | `Commerce/TrialGate.swift` |
| `SharingTier.enforced` | `true` | **this spec's build** — portfolio menu items now require `entitlements.sharing`; testers exercise it with sandbox subscriptions | `Commerce/SharingTier.swift` (the constant; the single `ShareCollectionButton` call site is untouched) |
| Worker `ALLOW_SANDBOX` | `"false"` | **GA deploy, not before** — TestFlight needs sandbox JWS accepted for domains/usernames right up to launch | Worker env (Spec 08; a redeploy, no app build) |
| `DriveConfig.consentScreenVerified` | `true` | when Google completes OAuth verification — independent of the other three | `Sharing/Drive/DriveConfig.swift` |
| Final prices | (decision) | GA — ASC only, no build | App Store Connect |

`SharingTierTests` updates with the flip: enforced-path assertions become the live
default (available ⇔ entitled), and the `enforced = false` branch remains covered as the
historical posture. Recorded consequence of the `ALLOW_SANDBOX` flip: TestFlight builds
running after GA can no longer provision domains with sandbox subscriptions — post-GA
TestFlight testing of domains uses real purchases or waits for a re-enabled staging
Worker (a second Worker deployment with sandbox on is the sanctioned way to test after
launch; noted in `workers/domains/README`).

---

## 4. Spec 04 amendment A2 — edit data must actually ride `.muselibrary`

### 4.1 The discrepancy (verified against shipped code)

Spec 04 §5.3 asserted "the `.muselibrary` archive carries the DB, which now contains
`edits`/`edit_versions`/`edit_presets`" (Spec 05 repeated it for `edit_luts`). **That is
factually wrong against the shipped backup:** `.muselibrary` is a JSON encode of the
Codable `BackupArchive` struct (`BackupDocument.encode`, JSONEncoder `.sortedKeys`) —
occurrences carry `tags` + `note`, files carry a content-level `Sidecar`, and nothing
else. The DB file is never copied. Without this amendment, the launch-checklist line
"edit stacks survive a `.muselibrary` round-trip" fails by construction. Restore-side,
`ReconnectApplier.applyMeta` writes tags and the note per matched occurrence at the NEW
`parent_dir` — the pattern the edit fields follow exactly.

### 4.2 Archive shape (schema stays 1; the optional-fields decode pattern)

`BackupArchive.currentSchema` stays **1** — every new field is optional with a nil
default, exactly like `note`/`icon`/`smart_rules` before it ("Optional so pre-X archives
decode"). Pre-A2 archives decode unchanged; post-A2 archives decode on pre-A2 builds
minus the new fields (Codable ignores unknown keys — harmless, recorded).

```swift
// BackupOccurrence — edits are per (file_id, parent_dir), like the note:
var edit_stack: String? = nil            // canonical stack JSON (the CURRENT stack)
var edit_updated_at: Int64? = nil
var edit_versions: [BackupEditVersion]? = nil

nonisolated struct BackupEditVersion: Codable, Equatable, Sendable {
    var kind: String        // "version" | "snapshot"
    var name: String?
    var stack: String
    var created_at: Int64
}

// BackupArchive — library-global edit assets:
var edit_presets: [BackupEditPreset]? = nil
var edit_luts: [BackupLut]? = nil

nonisolated struct BackupEditPreset: Codable, Equatable, Sendable {
    var id: String; var name: String; var stack: String
    var created_at: Int64; var updated_at: Int64
}
nonisolated struct BackupLut: Codable, Equatable, Sendable {
    var id: String          // content hash (edit_luts PK)
    var name: String; var size: Int
    var data: Data          // float32 LE RGB blob (base64 in the JSON, via Codable Data)
}
```

**LUT data is carried, deliberately.** A restored stack referencing an absent LUT renders
as the ORIGINAL everywhere (the Spec 05 unresolvable-LUT rule) — a backup that restores
edits but silently loses every look is a half-restore. Size is bounded
(`CubeLUTParser.maxSize = 128` ⇒ ≤ 25 MB float32 per LUT, +33% base64) and a backup is an
explicit user action; accepted and recorded. Versions/snapshots ride too — they are the
user's virtual copies, and the sidecar "device-local" limitation is a *sync* rule, not a
*backup* rule (a backup's whole job is device recovery).

### 4.3 Builder + applier

- `BackupBuilder`: fetch `EditRow`/`EditVersionRow` keyed `(file_id, parent_dir)`
  alongside the existing `noteRows` pass; `EditPresetRow` + `EditLutRow` library-global.
  Neutral/absent stacks encode nothing (the `edits`-row-absence rule carries into the
  archive).
- `ReconnectApplier.applyMeta`, beside the note write, per matched occurrence at the NEW
  `parent_dir`: `edit_stack` → `EditRecordStore.write` (**restore-wins**, mirroring the
  note line — restore is an explicit recovery action, not a merge); `edit_versions` →
  inserted with **fresh UUIDs** (the carry rule). New
  `ReconnectApplier.applyEditAssets`: presets `INSERT OR IGNORE` by id, LUTs
  `INSERT OR IGNORE` on the content-hash PK (the immutability rule — a re-restore is
  idempotent and can never rewrite LUT bytes).
- After apply, the standard edit-save consequences run once for the restored set:
  `LiveEditStackProvider` index rebuild, `appState.markContentChanged(paths)` (thumbnail
  invalidation — both key variants), `EditStore.generation` bump,
  `LutRegistry.invalidate` for restored LUT ids. No sidecar re-export on restore
  (hydration owns sidecar reconciliation; a restore must not stomp newer on-disk
  sidecars — the non-authoritative rule).

---

## 5. Performance validation

### 5.1 Design-center pass (M1 Air 8 GB, real library)

`PerfBaseline.run()` now contains every recorded row Specs 01–08 added. Owner runs it
(`MUSE_PERF=1`) on the reference M1 Air against a real 10k–50k library; the produced
`docs/perf-baseline-<date>.md` is committed. **The launch gate is a human reading that
report against the budgets** — the record-never-assert discipline is unchanged (CI perf
failures are noise; a signed-off report is evidence). A regression against budget blocks
launch until fixed or the budget is consciously re-signed. Headline budgets restated:
cold start → first grid paint 1500 ms · grid scroll 16.7 ms p95 · token search 100 ms ·
semantic leg 150 ms (< 300 ms perceived) · slider → canvas 50 ms perceived · compare
two-pane sharp 1200 ms · editor enter → first draw 400 ms.

### 5.2 `scripts/make-synthetic-library.swift` — the 500k generator (checked in)

A zero-dependency Swift script (`swift scripts/make-synthetic-library.swift <count>
<outdir> [--seed N]`), ImageIO only, runnable on any Mac:

- Writes `<count>` small JPEGs (64×64 seeded-noise rasters with a counter salt — every
  file a UNIQUE content hash; ~4 KB each ⇒ ~2 GB at 500k), nested ≤ 1,000 files/folder
  (`batch-000/…`), deterministic under `--seed`.
- EXIF variety so every search leg has real distribution: `DateTimeOriginal` spread
  2015–2026; a ~12-entry camera make/model pool (plus lens, ISO 100–12800, f/1.4–f/16,
  shutter, focal length); ~30% of files get GPS from a ~50-entry world-city coordinate
  table (exercises geocoding + `near:`); a few % flagged flash. Written via
  `CGImageDestinationAddImage` property dictionaries — the same keys
  `PhotoHeaderReader` parses.
- Progress line per 10k; target runtime well under an hour for 500k.

### 5.3 Scale rows in the harness — `MUSE_PERF_500K=1`

`PerfBaselineTests` gains an env-gated section (never default CI — it is slow by design):
build a scratch GRDB, synthesize **500k** `photo_meta` rows (same value pools as §5.2)
and **500k** `clip_embeddings` rows (seeded random unit vectors, fp16 via
`ClipVectors.toData`), then record:

| Row | Target (recorded, graceful-degradation tier) |
|---|---|
| three-token intersect (`camera:` + `iso:>1600` + `in:2019`) over 500k | ≤ 500 ms |
| `ClipIndex.matches` full 500k scan | ≤ 1.5 s |
| peak footprint delta during the scan | ≤ 200 MB — the streaming (no-RAM-residency) proof; expected ~chunk-sized |

These are the "search may take ~0.5 s at the 800k tier" numbers made measurable. The
rows land in the same report file.

### 5.4 Owner end-to-end protocol — earning "tested with 500k+ libraries"

Run on the reference machine, recorded in **`docs/launch-validation-<date>.md`**
(template committed with this spec: machine/OS/date, one row per step, outcome + numbers):

1. Generate the 500k library (§5.2); add it as a root.
2. Indexing completes (hours/overnight OK) with the app responsive throughout — no
   beachball, no crash; relaunch mid-index resumes cleanly.
3. Backfills (`PhotoHeaderBackfill`, geocode, deep-analysis) progress across launches
   under their standing per-launch caps.
4. Search: token queries return; degradation graceful (~0.5 s acceptable); grid scroll
   stays fluid.
5. Memory bounded: peak footprint recorded from Activity Monitor during index and during
   search — no RAM-residency blowup, no memory-pressure kill on 8 GB.
6. Integrity: quit, relaunch, `PRAGMA integrity_check` on `muse.sqlite` passes; spot
   check tags/edits on a handful of files.
7. Thermal/battery (Spec 06 machinery): start a large analyze on battery →
   `WorkThrottleStore` reports `.reduced` (concurrency 1); Low Power → same; induced
   thermal pressure → `.paused`, resumes after; Settings Pause/Resume round-trips. On
   power, a 100k analyze completes overnight.

Only after every row passes does the site/App Store copy get the "tested with libraries
of 500,000+ photos" line — the claim is earned by this document, not asserted.

---

## 6. Site, legal pages & in-app copy

The marketing site is a **separate repo** (currently `muse-site-phi.vercel.app`) — out of
scope here beyond the copy brief in §6.6. In-repo, the `web/share` legal/landing pages
and the About card still describe a free open-source Sparkle app and are **false at
launch**; this section makes them true. `index.html`/`share.js` are untouched.

### 6.1 `web/share/about.html`

Repositioned (it doubles as the OAuth consent screen's "App home page" — that role and
the `google-site-verification` meta tag are load-bearing and stay):

- Lede: the foundation §1 sentence — a local-first, Mac-native photo library app for
  people who take photography seriously; photos stay in your folders, nothing is
  imported, no catalog, no cloud, no data collection.
- Drop *"free, open-source software"* (both false). New foot line: available on the Mac
  App Store; source-available under the PolyForm Shield license.
- Links: Mac App Store (owner supplies the final URL at submission; placeholder anchor
  until then) · marketing site · `/privacy` · `/terms`.
- The Drive-share explainer paragraph stays (it is the consent screen's context).
- **No Lightroom mention** (decision #3 applies to every owned surface).

### 6.2 `web/share/privacy.html`

Rewritten to enumerate exactly the shipped surface — nothing more, nothing less:

- **What the app collects: nothing.** No analytics, no telemetry, no accounts. The App
  Store "Data Not Collected" label restated.
- **When the app touches the network** — exactly the four app-initiated paths, each with
  *what is sent*: (1) Google Drive share/portfolio — user-initiated; images go to the
  user's own Drive; (2) `announcements.json` — a plain GET of a static file, once per
  launch, nothing sent, off-able in Settings; (3) the search-model download —
  user-initiated, a static download, nothing sent; (4) custom-domain/username
  provisioning — user-initiated paid feature; the request carries the App Store
  **transaction JWS** (Apple's signed purchase receipt: product id, purchase dates,
  transaction ids — **no name, no email, no Apple ID**), used only to verify the
  subscription and never stored beyond the hostname claim.
- App Store / StoreKit traffic is OS-level (Apple's privacy policy governs it); same for
  iCloud Drive sync.
- **The share page** section gains the portfolio `manifest.json` fetch (recipient-browser
  traffic to `googleapis.com`, CSP-pinned) beside the existing Drive image loads; still
  no analytics of any kind on share pages, ever.
- Purchases/refunds: handled entirely by Apple; Muse never sees payment data.

### 6.3 `web/share/terms.html`

- §1 "The software": *free, open-source* → a commercial app sold on the Mac App Store,
  source-available under **PolyForm Shield 1.0.0**; the license link. Warranty
  disclaimer stays.
- New §: **Purchases & subscriptions** — purchases and refunds are processed by Apple
  (refund requests via `reportaproblem.apple.com`); the sharing subscription auto-renews
  and is managed/cancelled in App Store account settings; if it lapses, custom domains
  are removed after the **30-day** grace period (the number MUST equal
  `DomainConfig.lapseGraceDays` / the Worker's `LAPSE_GRACE_DAYS` — the copy-lies-about-
  enforcement rule, third citation site).
- §2–4 (sharing is yours to operate / acceptable use / reporting & enforcement) extend
  explicitly to **`username.muse.app` addresses and custom-hostname pages**: same
  acceptable-use terms, and the takedown path (documented in `workers/domains/README`)
  is the enforcement mechanism — a violating username/hostname is deprovisioned.
- §5 Availability extends to the provisioning Worker and username serving (best-effort,
  no SLA; distributed links on the default base outlive any of it).

### 6.4 About card (`Views/InfoSheet.swift`)

The line at InfoSheet.swift:200 — *"Muse is open source under the MIT license"* — is
replaced with: PolyForm Shield source-available licensing, plus a compact attributions
list (the OSS-licenses launch-checklist row lives here):

- GRDB.swift (MIT) — the one app dependency
- fflate (MIT) — vendored on the share page
- GeoNames (CC-BY 4.0) — verify Spec 02's attribution line is present (it is required,
  not optional)
- The CLIP model license line, per the §8 resolution (MobileCLIP TOU attribution or
  OpenCLIP/its training-data attribution)
- (Worker deps `jose`/`@peculiar/x509` are not in the app binary — they are credited in
  `workers/domains/README`, not the About card.)

All new strings localized at introduction (EN + FR).

### 6.5 `README.md` + Info.plist compliance

- README: license section → PolyForm Shield; distribution → Mac App Store; drop any
  remaining free/open-source phrasing (final pass over Spec 01's rewrite).
- **`ITSAppUsesNonExemptEncryption = false`** added to Info.plist (HTTPS-only = exempt) —
  kills the export-compliance question on every future upload.

### 6.6 ASO drafts + marketing-site brief (owner finalizes)

App Store metadata drafts, built around the terms people actually search (the entire
rationale for MAS exclusivity — treat ASO as a real task, not an afterthought):

- **Name:** `Muse — Photo Library` · **Subtitle:** `Fast, local photo organizer` ·
  **Category:** Photography.
- **Keyword field draft (≤100 chars):**
  `photo organizer,photo library,culling,raw viewer,photo manager,albums,browser,tags`
- **Description lead:** the no-catalog story (files stay where they are; nothing
  imported; metadata beside the photo; moving files doesn't orphan them), then search,
  editing + readouts, share links needing no recipient account. Plain vocabulary; **no
  Lightroom references anywhere in owned copy** (decision #3).
- **Screenshots:** real library, real photos — grid; editor with the teaching
  histogram/readouts visible; token search mid-query; Places; a share page. The
  readouts are the differentiator; they must be *visible* in the set.
- **Review notes prepared in advance:** Google Drive OAuth is a feature connecting the
  user's own account, not an app login → guideline 4.8 (Sign in with Apple) does not
  apply — stated preemptively with the flow described; demo instructions for reviewers
  (no account needed to evaluate the app itself).
- Marketing-site brief (separate repo): same pillars in long form + "works alongside
  whatever you already use (XMP in/out)" + the learning readouts; site markets, App
  Store distributes; the 500k line only after §5.4 passes.

---

## 7. TestFlight validation pass (owner; should already be running)

~10 real photographers (X100/GR-class shooters) on TestFlight builds against their own
libraries — the standing parallel track, confirmed complete before GA:

- Watch for: does no-catalog land unprompted? Do they *notice* color search and the
  editor readouts (the two differentiation bets that most want reality-checking)? Is
  "I'd pay $49.99" a sentence anyone says without prompting? — **this feeds the final
  pricing decision (§1), which is why pricing stays open until this pass concludes.**
- They exercise, via sandbox: the trial gate + unlock purchase (§2), the sharing
  subscription + portfolio gating (§3), domains against `ALLOW_SANDBOX = true`, promo
  code redemption.
- Launch channels when ready (not before): r/macapps, Product Hunt, "best photo
  organizer for Mac" roundup authors (emailable individuals), X100/GR YouTube +
  subreddit workflow-video audiences.

---

## 8. MobileCLIP license gate (BLOCKER) + the fallback procedure

**Gate:** a legal read of Apple's ML Research Model TOU (the MobileCLIP *weights*; the
code is MIT) for redistribution-via-download in a **paid** app, resolved before GA.
Unresolved at submission time = launch blocker (pre-spec §6; DECIDED — the read gates
*shipping*, never building).

**If cleared:** ship as built; add the model attribution line to the About card (§6.4).

**If refused — the fallback is mechanical by Spec 03's design** (the build is
model-agnostic): run `scripts/make-clip-coreml.py` against self-converted **OpenCLIP
ViT-B/32** weights → edit the one compiled-in descriptor `ClipModel.current` (name,
`generation` **bump**, dimension 512, `imageInputSide`, `downloadBytes`, `manifestURL`)
→ produce/host the new `model.zip` chunks + SHA-256 manifest under
`models/<name>-g<generation>/` → ship. Installed users re-embed automatically via the
standing generation-mismatch backfill (`DeepAnalysisBackfill` under its per-launch cap);
`ClipPromptVectors.refreshAll()` heals `.similar` rules. The outcome (either way) is
recorded in `DECISIONS.md`.

---

## 9. Launch checklist — every row carries its verification

| # | Item | Verified by | Who |
|---|---|---|---|
| 1 | App Review passes; app record has iCloud capability + Photos-library usage string (Spec 06) | submission accepted | owner |
| 2 | IAP E2E: purchase → unlock → restore → promo code, sandbox AND production | §7 sandbox pass + one production purchase/redeem at GA | owner |
| 3 | ASO page live per §6.6 drafts; screenshots show real library + readouts | ASC review of final metadata | owner |
| 4 | `announcements.json` deployed (`{"version":1,"messages":[]}`) + Settings off-toggle verified | curl the URL; toggle test | owner |
| 5 | Backup/restore on an edited library — stacks, versions, presets, LUTs survive | `BackupEditRoundTripTests` green + one manual round-trip on a real edited library | build + owner |
| 6 | MobileCLIP license resolved (or OpenCLIP fallback shipped) | §8 gate; outcome in `DECISIONS.md` | owner (legal) |
| 7 | GeoNames attribution + OSS/license attributions current | §6.4 About card review; French export clean | build |
| 8 | `CLAUDE.md` doctrine final: MAS distribution, photographer persona, **four** app-initiated network paths (the foundation doc's "three" is superseded — `DECISIONS.md` network doctrine is the truth), phase-table + session-log rows | doc review | build |
| 9 | Support/contact path: contact address on `/about`+`/terms`+`/privacy`; ASC support URL set; refunds link (`reportaproblem.apple.com`) in terms | page review | build + owner |
| 10 | Sparkle fully absent from the shipping binary | `strings Muse.app/Contents/MacOS/Muse \| grep -ci sparkle` → 0; entitlements contain no `temporary-exception` (the Spec 08 `api.cloudflare.com` strings-check class) | build |
| 11 | GitHub wind-down: repo private (releases disappear with it); the known direct-install users (~4) told personally that updates now come from the App Store; no appcast remains anywhere reachable | manual sweep | owner |
| 12 | Launch flips per §3 table: `enforced` flags in the build; `ALLOW_SANDBOX=false` deployed at GA; `consentScreenVerified` when Google clears | code + Worker env inspection | build + owner |
| 13 | Perf reports committed: `docs/perf-baseline-<date>.md` (§5.1, §5.3) + `docs/launch-validation-<date>.md` (§5.4), no unexplained budget regression | human read — the gate | owner |
| 14 | `ITSAppUsesNonExemptEncryption = false` present | Info.plist inspection | build |
| 15 | Localization: French export reports 0 untranslated (all §2/§6 strings) | `xcodebuild -exportLocalizations` pass | build |
| 16 | Pricing final call recorded in `DECISIONS.md` + foundation §13; ASC prices set | doc + ASC review | owner |

---

## 10. Tests

New/updated test files, pure-logic per house convention:

| File | Covers |
|---|---|
| `TrialGateTests` (extend) | epoch-keyed anchor resolution (legacy unnumbered key read earliest-wins under epoch 1; epoch 2 ignores it); `TrialPolicy.current` enforced/duration; gate-active derivation (`expired` ∧ ¬unlocked; `unlocked` short-circuit); existing branches stay green with `enforced: true` |
| `SharingTierTests` (update) | enforced default: available ⇔ entitled; the historical unenforced branch still covered |
| `BackupEditRoundTripTests` (new) | archive with stack + versions + presets + LUT encodes → decodes → applies (restore-wins stack, fresh version UUIDs, `INSERT OR IGNORE` presets/LUTs, idempotent re-apply); pre-A2 archive fixture decodes unchanged; LUT bytes byte-identical after round-trip |
| `BackupArchiveCompatTests` (new) | post-A2 archive decodes on the pre-A2 struct shape (unknown keys ignored) — pinned with a raw-JSON fixture |
| `CommerceEntitlementTests` (extend) | trialState recompute on entitlement change; permissive cache still never revokes |
| `PerfBaselineTests` (extend) | the `MUSE_PERF_500K` section (§5.3), env-gated |
| `AnnouncementFeedTests` | unchanged — must stay green (checklist row 4 leans on it) |

No UI unit tests (house rule): `UnlockGateView` logic lives in `CommerceStore`
(`trialGateActive`) and `TrialGate` — both covered above.

---

## 11. Build order

1. §4 A2 backup amendment + tests (independent; unblocks checklist row 5 early)
2. §2 trial enforcement: epoch anchor → `CommerceStore.trialState` → `UnlockGateView` +
   `SubscriptionLegalLinks` + Settings rows → `modalPresented`/Escape integration
3. §3 build-time flips (`TrialPolicy`, `SharingTier`) + test updates
4. §5 tooling: generator script + `MUSE_PERF_500K` rows + the validation-report template
5. §6 pages/About/README/Info.plist + localization pass
6. Docs: `CLAUDE.md` final doctrine, `architecture-map.md`, `session-log.md`,
   `DECISIONS.md` merge
7. Hand to owner: §5 validation runs, §7 cohort confirmation, §8 legal gate, §9 checklist

---

## 12. Owner-only steps

1. **The pricing decision** — after the §7 pass; record per checklist row 16. Until
   then the ASC placeholders ($49.99 / $19.99-yr) stand.
2. Confirm (or adjust) the trial shape/duration alongside it — one constant.
3. ASC: placeholder prices now; IAP metadata localization; promo-code batch + one E2E
   redemption.
4. Run §5.1/§5.4 on the physical M1 Air; commit both reports.
5. MobileCLIP legal read (§8) — start immediately; longest lead time and a hard blocker.
6. Google OAuth consent verification → flip `consentScreenVerified`.
7. GA sequence: final prices in ASC → submit → on approval, release + deploy Worker with
   `ALLOW_SANDBOX = "false"` → GitHub wind-down (row 11) → marketing site live.
8. TestFlight cohort (§7) — confirm it actually ran with ~10 real photographers before
   any of the above become irreversible.

---

## 13. Deliberate deviations & discrepancy resolutions

Recorded so they read as decisions, not drift:

1. **Pricing is NOT decided here** — the pre-spec says "decide here, with real features
   in hand"; the features aren't real yet (no Spec 01–08 code exists at spec time) and
   the owner explicitly kept it open. This spec makes the decision *free* to take late
   (price-agnostic build, ASC-only numbers, §1.2 acceptance) instead of taking it.
2. **`TrialPolicy.enforced` flips in this build**, superseding Spec 01's
   "would lock out current testers" rationale — sandbox purchases are free, so testers
   exercise the gate rather than being locked out by it. The trial-epoch mechanism is an
   addition beyond Spec 01's shape (its anchor key was unnumbered); epoch 1 reads the
   legacy key so no anchor resets.
3. **Spec 04 amendment A2:** Spec 04/05's "the archive carries the DB" was wrong against
   the shipped JSON `BackupArchive`; edit data now rides the archive explicitly (§4).
   Schema stays 1 via the optional-fields pattern.
4. **Spec 08 amendment A3:** `ShareDomainCard`'s pitch state gains the Privacy/Terms
   links row (App Review requirement for subscription UI) via the shared
   `SubscriptionLegalLinks` component.
5. **The launch perf gate is a human reading committed reports**, not CI assertions —
   the record-never-assert discipline holds; "regressions block launch" is a process
   rule, and the reports are its artifact.
6. **The marketing site ships from its own repo** — this spec delivers the in-repo pages
   (§6.1–6.5) and a copy brief (§6.6) only.
7. **The trial gate blocks the UI but not background data maintenance** (§2.9) —
   sweepers/backfills/hydration keep running behind it, deliberately.
