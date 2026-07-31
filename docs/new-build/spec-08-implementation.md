# Spec 08 — Custom Domains, Subdomains & the Provisioning Worker: full implementation spec

*Derived from `pre-spec-08-custom-domains.md` + `muse-photo-foundation.md` (§10
sharing / §11 commerce; §13 decision log is authoritative) + `DECISIONS.md` (the
binding build-level layer from Specs 01–07). Build-level expansion: exact
files, exact seams, exact wire formats, exact tests. Written before
implementation. Verified against the codebase at `cefa008` (`feat/editing`) —
as of that commit **no Spec 01–07 code exists in the tree** (migrations end at
`v12_smart_collections`); everything referenced from Specs 01–07 is referenced
exactly as specified there, and every reference to existing code was read from
the actual source (`Sharing/Drive/DriveConfig.swift`, `DriveShareRecord.swift`,
`DriveShareService.swift` (incl. `pageURL(base:)` at DriveShareManifest.swift:61),
`DriveExpirySweeper.swift`, `Views/ManageDriveSharesView.swift` (the
`pageURL.hasPrefix(DriveConfig.shareBaseURL)` Open-Link gate at :204),
`Settings/AppSettings.swift` (`driveRootFolderID`/`driveShareName` pattern),
`MuseApp.swift` (`DriveExpirySweeper.sweep` launch call at :135),
`Models/AppState.swift` (`modalPresented` at :514, `alertRequest` at :534),
`web/share/_headers`, `web/share/` deployment contents).*

---

## 0. What this spec does, does not, and depends on

**Does:** the paid sharing-tier domain feature — `photos.theirdomain.com`
serving the existing static share page via **Cloudflare for SaaS custom
hostnames**, provisioned by **one small Cloudflare Worker** (the app's only
backend, ever); Worker auth by **verifying the StoreKit 2 signed transaction
JWS** against Apple's certificate chain (the app never holds any Cloudflare
credential); the **in-app modal UX** (enter subdomain → copy-paste CNAME
instructions → poll to active → share links flip to the custom domain →
remove/change path); **subscription-lapse deprovisioning** with grace
messaging; the **free/middle tier** `username.muse.app` (Worker-KV claim +
wildcard serving, gated on the app unlock); the **documented escape hatch**
(self-host the static share site — docs only, no build); and the doctrine
update that flips network path (3) from "future" to live.

**Does not:** apex domains (CF Enterprise — refused with a clear error) ·
email or anything else on user domains · analytics of any kind on share pages
· multi-hostname per subscription · any server-side state about share
CONTENT (the Worker holds provisioning state only: hostname ↔ subscription,
username ↔ unlock — nothing about photos, DECIDED #19) · any new share
backend · pricing/tier enforcement (Spec 09 — `SharingTier.enforced` stays
false; domains are gated by *transaction possession*, not by that flag, see
§5.4) · migrations (**NONE** — future specs still continue at v24) · new
AppState `@Published` properties beyond the one sanctioned shell-modal flag
(§6.1, the `openWithForkRequest`/`socialExportRequest` class).

**Depends on:**

| Dependency | Needed by | Nature |
|---|---|---|
| Shipped Drive share (`Sharing/Drive/`, `web/share/`) | everything — the page the domains serve; `pageURL(base:)` is the link seam | **Hard** — in the tree. All security invariants carry (§8). |
| Spec 01 commerce (`CommerceStore`, `CommerceConfig` product ids) | §5 (the JWS the Worker verifies; entitlement-driven UI states) | **Hard.** The Worker authenticates *only* App Store signed transactions. If Spec 08 builds before Spec 01, it builds `Commerce/CommerceConfig.swift` + the `CommerceStore` JWS accessor to Spec 01's text verbatim as step 0 (the Spec 07 §0 convention). |
| Spec 07 (portfolio, manifest v2, page API key) | §2.6 (API-key restriction change), §4.2 (portfolio links ride the new base for free) | **Soft/severable.** Domains serve classic fragment shares with zero Spec 07 code; the §2.6 key-restriction deviation only applies once the key exists. |
| Spec 09 | nothing (it consumes this: pricing + `SharingTier.enforced`) | None. |
| Specs 02–06 | nothing | None. |

**Independently shippable:** each numbered build-order step (§11) leaves the
app releasable; the Worker deploys and versions independently of app releases.

**A scope note on the "~50-line Worker."** The pre-spec's estimate covers the
CF-API forwarding. The Worker's real bulk is the security-critical part the
estimate omits — X.509 chain verification of Apple's transaction JWS — plus
the username host serving and the lapse sweep. Honest sizing: ~500–700 lines
across five small modules (§3), with the crypto done by two pure-JS,
edge-native, MIT libraries rather than hand-rolled ASN.1 (§3.3, deviation D3).

---

## 1. Infrastructure topology (the one-time shape; owner provisions it, §12)

Nothing here is app code, but every constant in §4 refers to it, so it is
specified precisely. The production apex domain is written as **`muse.app`**
throughout (the pre-spec's working name); the actual purchased domain
substitutes into `DomainConfig` (§4.1) and the Worker env — nothing else
changes. **Deviation D7:** the pre-spec says "the existing Pages zone," but
`muse-share.pages.dev` is not a zone — Cloudflare for SaaS and
`username.muse.app` both require a real registered domain on a Cloudflare
zone. Standing that zone up is a hard prerequisite, recorded as owner step 1.

```
muse.app (Cloudflare zone, Free plan + Cloudflare for SaaS enabled)
│
├── share.muse.app        Pages custom domain on the existing muse-share
│                         project. Doubles as:
│                         (a) the CNAME TARGET customers point at, and
│                         (b) the Cloudflare-for-SaaS FALLBACK ORIGIN.
│                         Worker route "share.muse.app/*" → None (explicit
│                         exclusion so Pages serves it directly).
│
├── domains.muse.app      DNS: proxied placeholder (AAAA 100::).
│                         Served entirely by the muse-domains Worker (§3):
│                         the provisioning API.
│
├── *.muse.app            DNS: proxied wildcard placeholder (AAAA 100::).
│                         Worker route "*.muse.app/*" → muse-domains.
│                         The Worker's host dispatch (§3.6) serves claimed
│                         usernames by passing through to the Pages
│                         deployment; unclaimed/reserved hosts → 404.
│                         TLS: Universal SSL's *.muse.app wildcard cert
│                         covers every first-level label for free.
│
└── Custom hostnames      photos.customer.com CNAME → share.muse.app.
    (Cloudflare for SaaS) Edge terminates TLS with a per-hostname DV cert
                          (ssl.method "http" — auto-validates once the CNAME
                          resolves; no TXT record in the common path), then
                          serves the fallback origin = the same Pages
                          deployment. The customer's Host header doesn't
                          match any *.muse.app Worker route, so custom-
                          hostname traffic never touches the Worker.
```

Load-bearing consequences:

- **One deployment serves every hostname.** `web/share/` is untouched by this
  spec (§8) — the manifest rides the URL fragment, so the same static bytes
  render on `muse-share.pages.dev`, `carlos.muse.app`, and
  `photos.customer.com` identically. `_headers` (CSP etc.) apply on all of
  them (Pages serves them; the Worker passthrough forwards them verbatim).
- **Pricing floor verified in the pre-spec:** 100 custom hostnames free on
  every CF plan, then $0.10/hostname/month — $0 at 100 customers.
- **Apex is refused** (`ssl_for_saas` apex needs Enterprise). The refusal is
  enforced in the Worker's validator AND pre-validated app-side (§4.5), with
  UI copy suggesting `photos.` and a docs footnote noting the
  CNAME-flattening option for users whose own DNS is on Cloudflare
  (they can flatten `photos.theirdomain.com` however they like — the target
  is still `share.muse.app`; apex itself stays unsupported).

---

## 2. Wire contract — the provisioning API (`domains.muse.app`)

All endpoints: JSON in/out, HTTPS only, and **every request is
authenticated** — `Authorization: Bearer <StoreKit 2 transaction JWS>`
(§3.3). There are no anonymous endpoints (no availability probe: a claim
attempt IS the probe). Errors are `{ "error": "<code>", "message": "<en>" }`
with a stable machine `code` the app maps to localized copy (§4.4) — the app
never renders the Worker's English `message`.

| Method + path | Auth product | Body | Success |
|---|---|---|---|
| `POST /v1/hostname` | `com.tarrats.Muse.sharing.yearly` (active + grace) | `{"hostname": "photos.example.com"}` | `201 {"id","hostname","status","sslStatus","cnameTarget"}` |
| `GET /v1/hostname` | same | — | `200` same shape, live CF status (`404 no_hostname` when none) |
| `POST /v1/hostname/refresh` | same | — | `200 {"expiresAt": <ms>}` — re-stamps the stored subscription expiry from the presented JWS (the renewal signal, §3.5) |
| `DELETE /v1/hostname` | same | — | `204` (CF delete + KV clear; 404 from CF treated as success — the orphan doctrine) |
| `POST /v1/username` | `com.tarrats.Muse.unlock` (non-consumable, unrevoked) | `{"username": "carlos"}` | `201 {"username","host": "carlos.muse.app"}` |
| `GET /v1/username` | same | — | `200 {"username","host"}` / `404 no_username` |
| `DELETE /v1/username` | same | — | `204` |

Error codes (closed set, test-pinned both sides): `bad_jws` (401 — signature/
chain/claims failure), `wrong_product` (403), `subscription_lapsed` (403 —
expiry + grace passed), `revoked` (403), `sandbox_refused` (403 — sandbox JWS
while `ALLOW_SANDBOX` is off), `invalid_hostname` (422), `apex_not_supported`
(422 — its own code so the app shows the tailored message), `invalid_username`
(422), `reserved_username` (422), `hostname_taken` (409 — another subscription
owns it), `username_taken` (409), `already_has_hostname` (409 — one per
subscription; change = DELETE then POST), `already_has_username` (409),
`no_hostname`/`no_username` (404), `cf_error` (502 — CF API failure, message
opaque), `rate_limited` (429).

**Status vocabulary** (`status` × `sslStatus`, passed through from CF but
reduced to a closed set the app can pin): `status` ∈
`pending | active | moved | blocked | deleted`; `sslStatus` ∈
`initializing | pending_validation | pending_issuance | pending_deployment |
active | failed`. The app's pure `DomainStatus.map` (§4.3) folds the pair.

---

## 3. The Worker — `workers/domains/`

New top-level directory beside `web/` (the repo's existing precedent for
non-app deployables). Checked-in files:

```
workers/domains/
├── wrangler.toml          # name muse-domains; kv binding DOMAINS_KV;
│                          # [triggers] crons = ["17 6 * * *"]; route notes
├── worker.js              # entry: fetch() host dispatch + scheduled() sweep
├── router.js              # the /v1 API — pure handlers taking injected deps
├── verify.js              # Apple transaction-JWS verification (§3.3)
├── apple.js               # App Store Server API client (sweep only, §3.5)
├── cf.js                  # Cloudflare custom-hostname API client
├── validate.js            # hostname/username grammar + reserved list (§3.4)
├── serve.js               # *.muse.app username passthrough (§3.6)
├── certs/AppleRootCA-G3.der   # pinned Apple root (owner-verified fingerprint)
├── fixtures/hostnames.json    # shared app↔worker validation fixtures (§4.5)
├── fixtures/usernames.json
├── scripts/make-jws-fixtures.mjs  # generates a self-signed 3-cert chain +
│                                  # signed test JWS for verify.test.mjs
├── domains.test.mjs       # node --test, the share.test.mjs convention
└── README.md              # deploy, secret rotation, takedown path (§3.7)
```

Bindings and secrets (README-documented; owner step §12): secrets
`CF_API_TOKEN` (zone-scoped: Custom Hostnames Edit — **the token that must
never ship in the app**), `ASC_KEY_P8` + `ASC_KEY_ID` + `ASC_ISSUER_ID`
(App Store Server API, sweep only — optional, §3.5); vars `ZONE_ID`,
`BUNDLE_ID` (`com.tarrats.Muse`), `SHARING_PRODUCT_ID`, `UNLOCK_PRODUCT_ID`,
`CNAME_TARGET` (`share.muse.app`), `PAGES_ORIGIN`
(`https://muse-share.pages.dev`), `API_HOST` (`domains.muse.app`),
`APEX_ZONE` (`muse.app`), `ALLOW_SANDBOX` (`"true"` until launch, then
`"false"`); KV namespace `DOMAINS_KV`.

### 3.1 KV schema (the ONLY server-side state, provisioning-only by design)

```
sub:<originalTransactionId>  → {"hostname","hostnameID","env","expiresMS","updatedMS"}
host:<hostname>              → <originalTransactionId>        (uniqueness lock)
user:<username>              → {"otid","env","claimedMS"}     (unlock's otid)
unlockuser:<originalTransactionId> → <username>               (one per unlock)
```

Two keys per claim so both directions are O(1) and uniqueness is checked
before any CF call. Writes always update both (claim: check `host:`/`user:`
absent → write both; release: delete both). Nothing about photos, manifests,
links, or emails ever enters KV — binding decision #19's "provisioning state
only" line, enforced by the schema having nowhere to put anything else.

### 3.2 `router.js` — handlers

Pure async functions `(req, env, deps) → Response` where `deps = {verify, cf,
kv, now}` are injected (tests pass mocks; `worker.js` passes the real ones —
the `PhotoSearch`-style testable seam). Flow for `POST /v1/hostname`:

1. `verify.transaction(authHeader, env)` → payload or a typed error (§3.3).
2. Product gate: `payload.productId == env.SHARING_PRODUCT_ID`, no
   `revocationDate`, `payload.expiresDate + GRACE_MS > now` else
   `subscription_lapsed`. `GRACE_MS = 30 days` (named constant
   `LAPSE_GRACE_DAYS = 30` — covers Apple's ≤16-day billing-retry window with
   margin; owner-tunable).
3. `validate.hostname(body.hostname, env.APEX_ZONE)` (§3.4).
4. One-per-subscription: `sub:<otid>` present → `already_has_hostname`.
   `host:<hostname>` present with a different otid → `hostname_taken`.
5. `cf.createHostname(hostname)` → `POST
   /client/v4/zones/{ZONE_ID}/custom_hostnames` with
   `{"hostname", "ssl": {"method": "http", "type": "dv",
   "settings": {"min_tls_version": "1.2"}}}`.
6. Write both KV keys (`expiresMS` from the JWS, `env` Production/Sandbox) →
   `201` with `{id, hostname, status, sslStatus, cnameTarget:
   env.CNAME_TARGET}`.

`GET` proxies `cf.getHostname(id)` and reduces to the §2 closed status set.
`DELETE` calls `cf.deleteHostname(id)` (CF 404 → success — the account/state
orphan doctrine, same rule as `DriveClient.deleteFolder`) then clears both KV
keys. `refresh` re-stamps `expiresMS`/`updatedMS` from the presented JWS —
monotonic: **`expiresMS` never moves backward** (a stale cached JWS on one
Mac must not shorten a renewal already recorded from another).

Username handlers mirror the shape with the unlock product gate (no expiry —
non-consumables don't lapse; `revocationDate` present → `revoked`) and
`validate.username`. Rate limiting beyond auth: a fixed
`MAX_MUTATIONS_PER_DAY = 20` per otid (a counter key with a daily TTL) →
`rate_limited`; every endpoint already requires a paid transaction, so this
is a churn brake, not the security boundary.

### 3.3 `verify.js` — Apple transaction-JWS verification (the security core)

**Dependencies (the Worker's only two, deviation D3): `jose` and
`@peculiar/x509`** — both pure-JS on WebCrypto, built for edge runtimes, MIT.
Hand-rolling ASN.1/X.509 chain validation is the one place "no dependencies"
loses to "don't write your own crypto"; the app-target dependency count
(one — GRDB) is untouched. Both are pinned exact-version in `package.json`
and vendored into the deployed bundle by `wrangler deploy` (no CDN, no
runtime fetch — the fflate posture).

`verify.transaction(authHeader, env)` performs, in order, all of:

1. Parse `Bearer <jws>`; decode the protected header: `alg == "ES256"`,
   `x5c` present with exactly 3 certificates.
2. Build the chain with `@peculiar/x509`: leaf ← intermediate ← root.
   Verify each signature; verify every cert's validity window contains
   `now`; verify the ROOT's DER is **byte-equal to the pinned
   `certs/AppleRootCA-G3.der`** (never "any trusted root").
3. Verify the Apple-specific extension OIDs — without this, any
   Apple-rooted certificate (e.g. a developer signing cert) would pass:
   leaf must carry OID `1.2.840.113635.100.6.11.1` (App Store receipt
   signing), intermediate must carry `1.2.840.113635.100.6.2.1` (Apple
   WWDR). (The checks Apple's own server library performs.)
4. Verify the JWS signature with the LEAF's public key (`jose.compactVerify`
   with the imported key — never `decode` without verify).
5. Claims: `bundleId == env.BUNDLE_ID`; `environment` is `"Production"`, or
   `"Sandbox"` only while `ALLOW_SANDBOX == "true"` (else
   `sandbox_refused`) — `"Xcode"`-environment JWS are signed by a local test
   chain and fail step 2 by construction (recorded: local StoreKit-config
   testing cannot exercise the Worker; use sandbox/TestFlight).
6. Return the typed payload `{originalTransactionId, productId, type,
   expiresDate?, revocationDate?, environment}` — product/expiry gating is
   the ROUTER's job (§3.2), so verify.js stays product-agnostic.

Deliberately skipped, recorded: OCSP/CRL revocation checks on the chain
(Apple's library defaults `enableOnlineChecks` off for exactly this offline
posture; certificate revocation of Apple's receipt-signing chain is a
platform-catastrophe scenario, not a per-request one). Replay: a JWS is a
bearer credential carried over TLS, the same trust class as the app's Drive
OAuth token; the freshness that matters is `expiresDate`, which is checked.

`domains.test.mjs` pins verify.js against **checked-in fixtures generated by
`scripts/make-jws-fixtures.mjs`** (a self-signed 3-cert chain + JWS signed
with it; the test injects the fixture root as the pin): valid JWS accepted;
wrong root refused; missing leaf OID refused; expired cert refused; tampered
payload refused; `alg:none` refused; 2-cert x5c refused. Real Apple JWS are
verified live in the owner acceptance pass (§12) — a unit test cannot hold
Apple's private key.

### 3.4 `validate.js` — grammar + reserved list

```js
// Hostname: full DNS name the CUSTOMER owns. Rules, each its own error:
//  - lowercase; trailing dot stripped; total ≤ 253; labels 1–63,
//    [a-z0-9-], no leading/trailing hyphen; ≥ 3 labels (apex → its own code)
//  - IDN: accepted only in punycode form (xn--…); raw non-ASCII refused
//    (the app pre-converts display input via URLComponents, §4.5)
//  - must NOT end in .muse.app, .pages.dev, .workers.dev (our own infra),
//    and must not BE muse.app (apex_not_supported)
export function hostname(input, apexZone)   // → {ok} | {error: code}

// Username: ^[a-z0-9](?:-?[a-z0-9]){2,29}$  (3–30 chars, alnum + interior
// single hyphens), then the reserved list.
export function username(input)             // → {ok} | {error: code}

export const RESERVED = [ 'www','share','domains','api','app','muse','mail',
  'smtp','imap','pop','mx','email','admin','administrator','root','ssl',
  'cdn','static','assets','img','media','help','support','contact','abuse',
  'security','status','blog','news','docs','dev','staging','test','demo',
  'beta','ns1','ns2','dns','ftp','vpn','portal','login','signin','account',
  'accounts','billing','pay','payments','store','shop','download',
  'downloads','update','updates','legal','privacy','terms','about' ]
```

Both grammars are pinned by `fixtures/hostnames.json` / `usernames.json` —
arrays of `{input, ok, error?}` consumed by BOTH `domains.test.mjs` and the
Swift `DomainValidateTests` (§9), the two-implementations-one-contract rule
class (`ClipTokenizer` fixtures; `PhotoHeaderReader`/`FileMetadata`).

### 3.5 `scheduled()` — the lapse sweep (cron `17 6 * * *`)

The enforcement half of "subscription lapse → hostname deprovisioned":

1. List `sub:` keys. For each entry where `expiresMS + GRACE_MS < now` —
   and ONLY those (an active subscription costs zero Apple calls):
2. **If the App Store Server API key is configured** (`ASC_KEY_P8` present):
   `apple.subscriptionStatus(otid, env)` — a `jose`-signed ES256 JWT
   (`kid`/`iss`, aud `appstoreconnect-v1`, `bid` = BUNDLE_ID) against
   `GET /inApps/v1/subscriptions/{otid}` on
   `api.storekit.itunes.apple.com` (or the sandbox host when the entry's
   `env == "Sandbox"`). Status 1 (active) / 3 (billing retry) / 4 (billing
   grace) → re-stamp `expiresMS` from the response, keep the hostname.
   Status 2 (expired) / 5 (revoked) → `cf.deleteHostname` + clear both KV
   keys. Transient Apple/CF failure → leave untouched, next cron retries.
3. **If the key is NOT configured, the sweep no-ops entirely.** Fail closed
   *in the paying user's favor* (deviation D4): the stored `expiresMS` is
   only as fresh as the user's last launch (`/v1/hostname/refresh`, called
   by the app's launch refresher §4.6), so deleting on it alone would
   deprovision a paid-up customer whose Mac has been closed for a month.
   Without the key, lapse enforcement degrades to app-initiated
   refresh/delete — hostnames of truly-lapsed silent users persist, which
   costs $0.10/mo each, not correctness.

Usernames never sweep (non-consumables don't lapse); a refunded unlock's
username is handled by the manual takedown path (§3.7), recorded.

### 3.6 `serve.js` — the `username.muse.app` tier's serving path

`worker.js`'s fetch dispatch, by `Host`: `env.API_HOST` → `router.js`;
otherwise the request matched the `*.muse.app` route → `serve.js`:

1. Extract the first label; must match `validate.username` grammar and not
   be reserved (reserved/system labels fall through to 404 — `share.` and
   `domains.` never reach here anyway: `share` has an explicit None route,
   `domains` is API_HOST).
2. `DOMAINS_KV.get("user:" + label, {cacheTtl: 3600})` — the edge-cached
   read keeps a viral share page from burning KV's free-tier read quota;
   claims/releases are rare, so an hour of staleness on the *serving* gate
   is acceptable (a released username keeps serving up to an hour —
   recorded). Unclaimed → minimal `404` text (no page shell, nothing to
   phish with).
3. Claimed → `fetch(env.PAGES_ORIGIN + url.pathname + url.search)` and
   return the response verbatim — status, body, and headers (CSP,
   `X-Content-Type-Options`, referrer policy all ride through from Pages'
   `_headers`). GET/HEAD only; anything else → 405. The fragment never
   reaches the Worker (fragments are not sent in requests) — the share
   data's privacy property is untouched by construction.

This is the abuse surface the pre-spec flags (phishing on one subdomain can
get `muse.app` Safe-Browsing-flagged): mitigations are the paid-unlock gate
(claims cost $49 of identity), the reserved list, the KV gate (unclaimed
hosts serve nothing), and the documented takedown (§3.7).

### 3.7 `README.md` — deploy, rotation, takedown

Required content, verbatim topics: `wrangler deploy` + route setup; secret
rotation (`wrangler secret put CF_API_TOKEN` — rotating the CF token or the
ASC key is a redeploy-free secret swap, documented as the standing response
to any suspected leak); the **takedown path** (abuse report → verify →
`wrangler kv key delete user:<name>` + `unlockuser:<otid>`, or
`DELETE /custom_hostnames/<id>` via the CF dashboard for a custom hostname;
reserved-list additions ship as a Worker redeploy); `ALLOW_SANDBOX` flip at
launch; and the note that the Worker holds **no share content** — deleting
all KV loses only provisioning claims, never user data.

---

## 4. App module — `Sharing/Domains/`

New folder; Pattern B store, ZERO AppState integration beyond the one
sanctioned modal flag (§6.1). Files:

### 4.1 `DomainConfig.swift`

```swift
/// Owner-provided domain-tier constants (the DriveConfig pattern — no
/// secret anywhere; the CF API token lives ONLY in the Worker, §3).
enum DomainConfig {
    static let workerBaseURL = "https://domains.muse.app"
    static let apexZone = "muse.app"                 // username host suffix
    static let cnameTarget = "share.muse.app"        // shown in DNS instructions
    /// Poll cadence while the setup card is front-most.
    static let statusPollSeconds: TimeInterval = 30
    static let requestTimeout: TimeInterval = 15
}
```

### 4.2 `ShareLinkBase.swift` (pure) — the link seam

The single decision point for what base new share links mint on, and what
bases the Manage list may open. `DriveShareManifest.pageURL(base:)` already
takes the base as a parameter (DriveShareManifest.swift:61) — this enum is
the one caller-side source of that argument:

```swift
enum ShareLinkBase {
    /// Precedence: active custom domain → claimed username → default.
    /// A claimed address is used automatically (claiming it IS choosing it);
    /// a custom domain outranks it; pending/failed domains never mint links.
    static func current(domain: ShareDomainState?, address: MuseAddressState?)
        -> String
        // active domain  → "https://\(domain.hostname)"
        // address        → "https://\(address.username).\(DomainConfig.apexZone)"
        // neither        → DriveConfig.shareBaseURL

    /// Every base a locally-recorded share may legitimately carry. Used by
    /// the Manage Open-Link gate — full-ORIGIN comparison via URLComponents
    /// (scheme https + exact host + empty-or-"/" path), never hasPrefix:
    /// "https://muse-share.pages.dev.evil.com" passes a prefix test.
    static func sanctionedOrigins(domain: ShareDomainState?,
                                  address: MuseAddressState?) -> [String]
    static func isSanctioned(pageURL: String, origins: [String]) -> Bool

    /// Rebase a recorded pageURL onto a new base, preserving the fragment
    /// verbatim (the fragment IS the share). No "#" → returned unchanged.
    static func rebased(_ pageURL: String, onto base: String) -> String
}
```

Integration (three call sites, each one line):

- **`DriveShareService.run`** (:117): `manifest.pageURL(base:
  ShareLinkBase.current(domain:address:))` reading
  `ShareDomainStore.shared` — and identically in Spec 07's
  `publishPortfolio`/`updatePortfolio` when they exist. A portfolio minted
  on a custom domain works with zero extra code: the fragment and the Drive
  manifest are origin-independent.
- **`ManageDriveSharesView`** (:204): the Open-Link gate becomes
  `ShareLinkBase.isSanctioned(pageURL: record.pageURL, origins:
  ShareLinkBase.sanctionedOrigins(…))`. `sanctionedOrigins` always includes
  `DriveConfig.shareBaseURL` (pre-domain records) plus the live
  domain/address origins. Side effect, deliberate: the origin-exact
  comparison also closes the latent `hasPrefix` suffix-spoof gap in the
  shipped gate (only reachable via tampered local JSON; still worth
  closing — the trailing-slash containment rule class).
- **Removal rebase** (§4.6): when a domain (or address) stops being
  sanctioned, every record whose pageURL origin matched it is rewritten via
  `rebased(_:onto: ShareLinkBase.current(…))` — Copy Link / Open Link in
  Manage keep working. Links already distributed on the dead hostname stop
  resolving (the hostname is gone at the edge) — inherent, disclosed in the
  removal confirm (§6.3). Records are NEVER rebased when a domain becomes
  active (old links on the default base still serve — Pages never stops
  answering `muse-share.pages.dev`).

**Pinned-host paths are exempt by name:** `announcements.json` (Spec 01) and
the CLIP model manifest (Spec 03) stay on `DriveConfig.shareBaseURL`
literally — the custom domain is a *share-link* base, never a fetch origin;
the model download's pinned-host fail-closed rule must not acquire a
user-configurable host. Stated here so nobody "helpfully" routes them
through `ShareLinkBase`.

### 4.3 `ShareDomain.swift` (pure models + status fold)

```swift
struct ShareDomainState: Codable, Equatable {
    var hostname: String            // "photos.example.com"
    var hostnameID: String          // CF custom-hostname id (via the Worker)
    var status: String              // §2 closed set, as received
    var sslStatus: String?
    var lastCheckedAt: Date?
    var createdAt: Date
}
struct MuseAddressState: Codable, Equatable {
    var username: String
    var claimedAt: Date
}
/// One file, both tiers + the one-shot lapse-notice flag (§4.6).
struct ShareDomainFile: Codable, Equatable {
    var domain: ShareDomainState? = nil
    var address: MuseAddressState? = nil
    var lapseNoticeShown: Bool = false
}

enum DomainStatus: Equatable {
    case pendingDNS        // status pending — CNAME not seen yet
    case pendingSSL        // hostname active, cert not yet deployed
    case active
    case problem(String)   // moved / blocked / ssl failed — raw pair for support
    static func map(status: String, sslStatus: String?) -> DomainStatus
}
```

`DomainStatus.map`, pure and pinned: `("active","active") → .active`;
`("pending", _) → .pendingDNS`; `("active", not-active-ssl) → .pendingSSL`;
`moved`/`blocked`/`(_, "failed")` → `.problem(raw)`. Unknown strings →
`.pendingSSL` when hostname is `active`, else `.pendingDNS` — forward-compat
lenient, never a crash (the `layoutOf`-fallback rule class).

### 4.4 `DomainClient.swift` — the Worker HTTP client

`URLSession` (`.ephemeral`, `DomainConfig.requestTimeout`, no cookies,
nothing sent beyond the JWS + the JSON body — the AnnouncementStore posture),
one method per §2 endpoint, `DomainError` mapping the §2 `code` strings to a
typed enum with `String(localized:)` user messages (`bad_jws` → "Couldn't
verify your purchase — try Restore Purchases in Settings." ·
`apex_not_supported` → "Root domains aren't supported. Use a subdomain like
photos.\(domain)." · `hostname_taken`, `subscription_lapsed`, `cf_error`,
offline… each its own copy). **Doctrine:** this client talks ONLY to
`DomainConfig.workerBaseURL` — network path (3), now live: user-initiated,
plus the launch refresher (§4.6) only while a domain/address is configured
(the `DriveExpirySweeper` precedent).

### 4.5 `DomainValidate.swift` (pure) — the app-side grammar mirror

Mirrors `validate.js` exactly (hostname rules incl. apex/own-infra refusal,
username grammar + `RESERVED`), used for live field validation in the card so
a user gets the apex error as they type, not after a round-trip. Non-ASCII
input is punycoded via `URLComponents(string: "https://\(input)")?.host`
before validation (matching the Worker's xn-- rule). **Pinned against the
same `fixtures/hostnames.json` / `usernames.json`** the node tests consume
(the Swift test target adds the fixture files as resources) — the two
implementations cannot drift silently. The Worker remains the enforcement
point; the mirror is UX.

### 4.6 `ShareDomainStore.swift` — Pattern B store + launch refresher

`@MainActor final class ShareDomainStore: ObservableObject`, `static let
shared`. `@Published private(set) var domain: ShareDomainState?`, `address:
MuseAddressState?`, `phase: Phase` (`.idle / .working(String) /
.failed(DomainError)` — one phase enum for the card, the
`DriveShareService.Phase` shape with its generation guard: every phase write
goes through `setPhase(_:ifCurrent:)`). Persistence: `shareDomain.json` in
App Support beside `driveShares.json`, atomic writes, the exact
`DriveShareStore` load/save discipline (decode failure → empty, never a
crash). All Worker calls go `store → DomainClient` with the JWS fetched per
call from `CommerceStore` (§5.1) — the JWS is never persisted by this store.

Operations (each maps 1:1 to a §2 endpoint, updates state + saves):
`createHostname(_:)`, `checkStatus()`, `removeHostname()`,
`claimUsername(_:)`, `releaseUsername()`. `removeHostname()` and
`releaseUsername()` run the **record rebase** (§4.2) after clearing state.

**`ShareDomainRefresher`** (same file, `@MainActor enum`, the
`DriveExpirySweeper` shape) — called from `MuseApp`'s `.task` beside the
expiry sweep; **zero network when no domain/address is configured**:

1. Domain configured + `entitlements.sharing` → `POST /v1/hostname/refresh`
   (re-stamps the Worker's `expiresMS` — the renewal signal §3.5 depends
   on), then, only while local status ≠ active, one `GET /v1/hostname` to
   advance pending state.
2. Worker answers `no_hostname` (the sweep or another Mac removed it) →
   clear `domain`, rebase records, and — once, via the persisted
   `lapseNoticeShown` flag — raise one `MuseAlert` through the
   `AppState.alertRequest` seam: *"Your custom domain was removed because
   the sharing subscription ended. New share links use the standard
   address."* (`alertRequest` is the sanctioned raise-from-anywhere modal
   seam, AppState.swift:534.)
3. Any network failure → silent, state untouched, next launch retries (the
   sweeper's leave-and-retry rule).

---

## 5. Commerce integration (Spec 01 surface growth)

### 5.1 The JWS accessor — `CommerceStore.transactionJWS(for:)`

```swift
/// The signed StoreKit 2 transaction for a product the user currently owns —
/// the credential the domains Worker verifies (§3.3). Reads
/// Transaction.currentEntitlements (verified-only) and returns the raw
/// jwsRepresentation. nil when unowned. Never cached, never persisted —
/// StoreKit re-serves it on demand and renewals refresh it automatically.
func transactionJWS(for productID: String) async -> String?
```

Implementation: iterate `Transaction.currentEntitlements`; for the
`VerificationResult` whose transaction's `productID` matches, return
`result.jwsRepresentation` (the *verification result's* JWS — the full
signed representation, not a re-encoding). `DomainClient` callers pass
`CommerceConfig.sharingProductID` for hostname endpoints and
`CommerceConfig.unlockProductID` for username endpoints.

### 5.2 Entitlement-driven UI states (not SharingTier)

`SharingTier` keeps its Spec 07 contract — **single call site, portfolio
menu visibility, `enforced = false` until Spec 09.** Domains do NOT ride it:
the Worker hard-requires a valid subscription JWS regardless of any app-side
flag, so the card's states branch on *transaction possession*
(`CommerceStore.shared.entitlements.sharing` / `.unlocked`), and the
"unenforced until Spec 09" posture is preserved in the only way it
truthfully can be — TestFlight testers exercise the flow with **sandbox**
purchases (free) against the Worker's `ALLOW_SANDBOX = true`. Recorded
plainly: there is no "domains without a subscription transaction" state to
leave open; pricing (Spec 09) sets the number, not the gate.

### 5.3 Lapse messaging (the grace-period acceptance line)

When `domain != nil` && `entitlements.sharing == false`, the Settings row
(§6.2) and the card both show, computed from nothing but those two facts:
*"Your sharing subscription has ended. Renew within \(LAPSE_GRACE_DAYS) days
to keep \(hostname) — after that it's removed and share links revert to the
standard address."* with a Renew button (`CommerceStore.purchase`). The
constant is surfaced from `DomainConfig.lapseGraceDays = 30`, which MUST
equal the Worker's `LAPSE_GRACE_DAYS` (both cite this section; a mismatch is
copy lying about enforcement).

### 5.4 What Spec 09 gets

Untouched here, listed for the record: the price of
`com.tarrats.Muse.sharing.yearly`; `SharingTier.enforced`; whether the
username tier requires the unlock at launch pricing (the gate exists and is
flippable by changing the Worker's product check + the card's entitlement
branch — one line each).

---

## 6. UI — Settings rows + the setup card

### 6.1 The shell-modal flag (deviation D2, the sanctioned class)

```swift
// Models/AppState.swift — the openWithForkRequest/socialExportRequest class:
// a card raised from Settings (itself a modal) must be presented at the
// shell, above it.
@Published var shareDomainSetupShown = false
// modalPresented (AppState.swift:514) gains: || shareDomainSetupShown
```

Presented from `ContentView` via `.museModal(isPresented:width: 520)`, built
only while presented, Escape → standard `dismissTopModal` resolution
(`EscapeAction.dismissModal` already peels the topmost card; no resolver
change). The card is `Views/ShareDomainCard.swift`.

### 6.2 Settings — one new "Share Links" section (below Google Drive)

`SettingsView` gains a section with two rows + a footer, reading
`ShareDomainStore.shared` + `CommerceStore.shared` (both already observable):

- **Muse Address row.** Unclaimed + unlocked: inline `TextField` (local
  `@State` draft — never a `@Published` binding, durable constraint) +
  "Claim" `ModalButton`, live-validated by `DomainValidate.username`, error
  text under the field on 409/422. Claimed: `carlos.muse.app` + "Release…"
  (destructive, confirm via `.museAlert` — releasing breaks distributed
  links, the confirm says so). Locked (no unlock): a single explanatory line
  — *"Claiming a muse.app address requires the app unlock."* (row visible,
  action absent — the pitch IS the row; the absent-not-disabled rule applies
  to actions, not explanations).
- **Custom Domain row.** No domain + no subscription: status text "Not set
  up" + "Learn More…" button → the card (which opens on its pitch state).
  No domain + subscribed: "Set Up Custom Domain…" → the card. Domain
  present: `photos.example.com` + a status dot/line
  (`DomainStatus.map` → "Waiting for DNS" / "Securing certificate…" /
  "Active" / "Needs attention") + "Manage…" → the card. Lapsed: the §5.3
  message + Renew.
- **Footer:** *"New share links use \(host-of ShareLinkBase.current(…))."*
  — the one place the effective base is always visible.

### 6.3 `Views/ShareDomainCard.swift` — the modal states

One card, five states driven by `(entitlements, store.domain, store.phase)`;
all buttons `ModalButton`, all copy `String(localized:)`, width 520:

1. **Pitch** (no subscription): what the tier is (your own domain on your
   share pages + portfolio, per foundation §11), the yearly price from
   `Product.displayPrice` (never hardcoded — Spec 09 owns the number), a
   prominent Subscribe button (`CommerceStore.purchase`), Restore Purchases,
   Cancel. Purchase success → state 2 automatically (entitlements publish).
2. **Enter domain** (subscribed, no domain): `TextField` ("photos.yourdomain.com"),
   live `DomainValidate.hostname` feedback (apex input → the tailored
   suggestion using their typed apex), Continue → `store.createHostname` →
   state 3. A `.problem`/error phase renders inline (`DomainError` copy).
3. **DNS instructions + polling** (domain present, not `.active`): a
   copy-paste block — *record type* `CNAME`, *name* = the hostname's first
   label(s) relative to their apex (pure `DomainValidate.recordName(for:)`,
   e.g. `photos`), *target* = `DomainConfig.cnameTarget` — each with a Copy
   button (NSPasteboard); the live status line ("Waiting for DNS — add the
   record above, then give it a few minutes" / "DNS found — securing the
   certificate…"); a "Check Now" button; auto-poll every
   `DomainConfig.statusPollSeconds` via a `.task(id:)` bound to the card's
   presentation (dies with the card — never a free-running timer, the
   status-pill tick rule). The registrar hints stay generic copy (one line:
   "In your DNS provider's dashboard, add a CNAME record") — per-registrar
   walkthroughs are docs, not UI. On `.active`: state 4 + the footer note
   *"New share links now use \(hostname). Existing links keep working."*
4. **Active** (domain `.active`): hostname + Active status, the §6.2 footer
   fact, "Change…" (→ confirm, then `removeHostname` + state 2 — change =
   delete-then-create, matching the Worker's one-per-subscription contract)
   and "Remove Domain" (destructive; confirm via `.museAlert` states the
   consequence: *"Share links you've already sent from this domain will stop
   working. Saved shares switch back to the standard address."* — the
   rebase, §4.2).
5. **Problem** (`.problem(raw)`): plain-language line per case (moved /
   blocked / cert failed), the raw pair in secondary text for support, Check
   Now + Remove.

Sandbox note rendered in states 2–4 while the build's receipt environment is
sandbox: *"Test mode — using your sandbox subscription."* (TestFlight
clarity; one line, `#if DEBUG`-independent since TestFlight is Release).

### 6.4 Localization

Every string in §5–§6 lands in the catalog at introduction (SwiftUI literal
positions or explicit `String(localized:)` — DNS instruction labels, status
lines, every `DomainError` message, the confirm bodies). Brand/technical
literals (`CNAME`, hostnames) interpolate into localized format strings, not
concatenations (the wrap-the-whole-phrase rule). The feature is incomplete
until the French export pass reports 0 untranslated (house rule).

---

## 7. The documented escape hatch (docs only — no build)

`docs/self-hosting-share-page.md`, new, linked from `web/share/README.md`:

- What it is: the share site is static; a power user can deploy `web/share/`
  to their OWN Cloudflare Pages account (or any static host that can send
  the `_headers` CSP) and serve share pages on their own domain with no
  Muse-side involvement — the local-first promise kept honest.
- How: clone → `wrangler pages deploy web/share` (or dashboard upload) →
  attach their domain. Portfolio note: the Drive manifest fetch needs THEIR
  OWN browser API key (Drive-API-restricted) pasted into their copy of
  `share.js` (§2.6's key is restricted to our deployment's use).
- The load-bearing fact that makes it work: **a share link's fragment is the
  entire share** — take any Muse-generated link, replace everything before
  `#` with their deployment's origin, and it renders identically. The app's
  minted links keep pointing at the standard base; distributing self-hosted
  links is a manual find-and-replace, stated plainly (no in-app base
  override is built — that would be a config surface for a power-user path,
  and `ShareLinkBase`'s inputs are deliberately only things Muse provisions).

---

## 8. What Spec 08 explicitly does NOT change

- **`web/share/` — nothing.** No page code, no CSP change, no new origin
  (the §2.6 API-key restriction change is Google-console config, not page
  bytes). The same deployment serves every hostname by construction (§1).
- **Every shipped Drive security invariant** (the Spec 07 §5 list carries
  verbatim), the fragment privacy property, the strip pipeline, the expiry
  sweeper, `DriveShareStore`'s format (no record fields added — the base
  lives in `pageURL` as it always has).
- **Network doctrine count:** still four app-initiated paths — path (3) flips
  from "future" to live with this definition: *custom-domain provisioning
  Worker (`DomainConfig.workerBaseURL` only; paid; user-initiated, plus a
  launch status/refresh call only while a domain or address is configured)*.
  Announcements and model downloads stay pinned to
  `DriveConfig.shareBaseURL` — never the custom domain (§4.2).
- **`AppState`** beyond the one sanctioned flag; the status pill (domain
  polling is card-owned foreground work); search; analysis;
  `ThumbnailCache.renderedVariants`; migrations.
- **`SharingTier`** — contract, call-site count, and `enforced = false`
  untouched (§5.2).
- **The app binary carries no Cloudflare credential and makes no Cloudflare
  API call** — `DomainClient` speaks only to the Worker. (Acceptance:
  `strings` the shipped binary for `api.cloudflare.com` → zero hits; owner
  step §12.)

---

## 9. Tests

**Swift (`MuseTests`, pure-logic house rule):**

- `DomainValidateTests` — consumes `fixtures/hostnames.json` +
  `usernames.json` (bundled resources): every fixture row agrees with the
  Swift mirror; apex → `apex_not_supported`; own-infra suffixes refused;
  punycode path; `recordName(for:)` label math.
- `ShareLinkBaseTests` — precedence (domain > address > default; pending
  domain never wins); `sanctionedOrigins` composition; `isSanctioned` is
  origin-exact (the `…pages.dev.evil.com` suffix spoof fails; path/userinfo
  tricks fail; http fails); `rebased` preserves the fragment byte-for-byte,
  handles fragment-less input, and is idempotent.
- `DomainStatusMapTests` — the §4.3 fold table, incl. unknown-string
  leniency both ways.
- `ShareDomainFileTests` — round-trip; a file with only `address` decodes;
  a pre-Spec-08 EMPTY file (missing) → defaults; `lapseNoticeShown`
  round-trips.
- `DomainErrorMappingTests` — every §2 error code maps to a distinct typed
  case with non-empty localized copy; unknown codes → the generic case,
  never a crash.
- `CommerceStore.transactionJWS` is StoreKit-bound and not unit-testable
  (recorded); its use is covered by the owner sandbox pass (§12).

**Node (`workers/domains/domains.test.mjs`, the `share.test.mjs`
convention — `node --test`, no framework):**

- `validate.js` against the same fixtures (the cross-pin).
- `verify.js` against the generated fixture chain (§3.3's seven refusal
  cases + the acceptance case; root pin injected).
- `router.js` handlers with mocked `{verify, cf, kv, now}`: every §2 error
  code reachable and correct; one-hostname-per-subscription; `host:` /
  `user:` uniqueness; `refresh` monotonic (never moves `expiresMS`
  backward); DELETE treats CF-404 as success; KV pairs always written and
  cleared together.
- `scheduled()` with mocked apple/cf/kv: grace window respected; status
  1/3/4 re-stamp; 2/5 deprovision; **no ASC key → no-op** (the D4 pin);
  transient failure leaves state.
- `serve.js`: claimed label passes through with headers verbatim; unclaimed
  and reserved → 404; non-GET → 405; API_HOST dispatches to the router.

**Cross-cutting:** `DriveShareServiceTests` (if the service gains a
seam-level test target with Spec 07) pins that the minted `pageURL` uses
`ShareLinkBase.current` — at minimum, `ShareLinkBaseTests` pins the pure
half and the wiring is one audited line (:117).

---

## 10. Performance (recorded, never asserted — `PerfBaseline` rows)

| Row | Budget (recorded) |
|---|---|
| Worker `POST /v1/hostname` end-to-end (incl. JWS verify + CF call) | recorded, no target (network-bound) |
| `verify.js` JWS verification alone (fixture chain, workerd) | recorded manually, not CI |
| Launch refresher with no domain configured | 0 network calls (asserted by code shape, noted here) |

---

## 11. Build order (each step leaves the app releasable)

1. **Worker, complete** (`workers/domains/`: validate → verify (+ fixture
   generator) → cf → router → serve → sweep → tests → README). Deployable
   and testable with `curl` + a sandbox JWS before any app code exists.
   First task inside this step: a miniflare/`wrangler dev` smoke test that
   `jose` + `@peculiar/x509` run under workerd (they are edge-native; the
   smoke test is the proof, not the hope — prefer-verified-patterns rule).
2. **Step 0 if Spec 01 is unbuilt:** `CommerceConfig` + the `CommerceStore`
   subset needed for `transactionJWS(for:)` to Spec 01's text.
3. **App pure layer:** `DomainConfig` / `ShareDomain` / `DomainValidate` /
   `ShareLinkBase` + all Swift tests (fixtures shared with the Worker).
   Inert — nothing calls it yet.
4. **`DomainClient` + `ShareDomainStore` + refresher wiring** in `MuseApp`
   `.task` beside `DriveExpirySweeper.sweep`.
5. **Link integration:** `DriveShareService` base line + Manage
   origin-exact gate + removal rebase.
6. **UI:** Settings "Share Links" section → `shareDomainSetupShown` flag →
   `ShareDomainCard` states 1–5 → French pass.
7. **Username tier end-to-end** (worker `serve.js` is already live from
   step 1; this step is the claim UI, which step 6 included — listed
   separately so steps 1–6 can ship custom-domains-only if the owner
   sequences it that way).
8. **Docs:** `docs/self-hosting-share-page.md`; CLAUDE.md doctrine flip +
   §13 durable constraints; architecture-map + session-log entries.

---

## 12. Owner-only steps (cannot be done from the codebase)

1. **Stand up the zone** (D7): purchase the production domain; add it as a
   Cloudflare zone (Free plan); add `share.muse.app` as a custom domain on
   the `muse-share` Pages project; verify the share page serves there.
2. **Enable Cloudflare for SaaS** on the zone (requires a payment method on
   file even at the free 100-hostname tier); set fallback origin =
   `share.muse.app`.
3. **DNS + routes:** wildcard `*` proxied placeholder record + `domains`
   record; Worker routes `*.muse.app/* → muse-domains` and
   `share.muse.app/* → None` (the explicit exclusion, §1).
4. **Worker deploy:** create the KV namespace; set secrets (`CF_API_TOKEN` —
   a zone-scoped token with Custom Hostnames Edit ONLY; the ASC In-App
   Purchase API key trio for the sweep); `wrangler deploy`;
   `ALLOW_SANDBOX = true`.
5. **Pin the Apple root:** download Apple Root CA - G3 from
   apple.com/certificateauthority, verify its published SHA-256 fingerprint,
   commit `certs/AppleRootCA-G3.der`.
6. **API-key restriction change** (with Spec 07's key, deviation D1): in the
   Google console, drop the HTTP-referrer restriction; keep the
   Drive-API-only restriction (§2.6 rationale). One console edit, no
   deploy.
7. **End-to-end acceptance on a real test domain** (the pre-spec's
   acceptance list, run in order): sandbox subscription purchase → enter
   `photos.<testdomain>` → CNAME instructions → status walks
   pendingDNS → pendingSSL → active → publish a share → the link serves on
   the custom domain with valid TLS → portfolio publish + update on the
   same base → cancel the sandbox subscription → (accelerated sandbox
   expiry) refresh shows the lapse message → sweep deprovisions → links
   revert; claim/release a username incl. a reserved word; `strings` the
   binary for `api.cloudflare.com` (zero hits).
8. **Launch flips:** `ALLOW_SANDBOX = false` at public launch (with Spec
   09's pricing go-live).

---

## 13. New durable constraints (added to `CLAUDE.md` on merge)

1. **The Cloudflare API token never ships in, or is reachable from, the
   app.** All Cloudflare interaction happens inside the muse-domains Worker;
   `DomainClient` speaks only to `DomainConfig.workerBaseURL`. Network path
   (3) is live with exactly this definition: paid, user-initiated, plus a
   launch status/refresh only while a domain or address is configured.
2. **The Worker authenticates ONLY Apple-signed transaction JWS** — full
   chain verification to the pinned Apple Root CA - G3 including the receipt
   OID checks; never `decode`-without-verify, never a shared secret with the
   app (there is nothing to leak from the binary).
3. **Worker state is provisioning-only** (hostname/username ↔ transaction
   id, in KV). Nothing about photos, manifests, or links ever enters it —
   deleting all KV loses claims, never user data (#19 intact).
4. **`ShareLinkBase` is the single link-base decision point** — precedence
   active-domain → claimed-address → `DriveConfig.shareBaseURL`; the Manage
   Open-Link gate is origin-EXACT (never `hasPrefix` — suffix spoof);
   announcements + model downloads stay pinned to `DriveConfig.shareBaseURL`
   by name and never ride the custom domain.
5. **Lapse handling fails closed in the paying user's favor**: the sweep
   deprovisions only on an authoritative App Store Server API status (2/5);
   with no ASC key configured it no-ops. Stored expiry alone never deletes a
   hostname.
6. **Removal rebases local records (fragment preserved) and states that
   distributed links on the removed hostname die** — records are never
   rebased when a domain is added (old links keep serving on the default
   base forever).
7. **The app-side grammar mirror (`DomainValidate`) and the Worker's
   `validate.js` are pinned to one shared fixture set** — a grammar change
   edits the fixtures, and both test suites fail until both implementations
   agree.

---

## 14. Deliberate deviations (recorded, per house convention)

- **D1 — the share-page API key's HTTP-referrer restriction is dropped**
  (API-restriction-only). Spec 07 restricted the key to enumerable share
  origins; custom hostnames are unbounded and unenumerable, and keeping the
  restriction would break the portfolio live-fetch on exactly the paid
  tier's pages (silent fallback to stale snapshots). The binding invariant
  was never the referrer list — it is *no secret and no OAuth credential on
  the page* (DECISIONS network-doctrine wording), which is unchanged; the
  key stays Drive-API-restricted and quota-only, and rotation is a one-line
  console step. Supersedes Spec 07 §10's "plus the Spec 08 domains when
  they exist."
- **D2 — one new AppState `@Published`** (`shareDomainSetupShown`), the
  sanctioned shell-modal-flag class, registered in `modalPresented`.
- **D3 — the Worker takes two dependencies (`jose`, `@peculiar/x509`)** and
  is ~10× the pre-spec's "~50 lines." The delta is Apple JWS chain
  verification, which must not be hand-rolled ASN.1; both libraries are
  pure-JS/WebCrypto, edge-native, MIT, pinned and bundled at deploy (no
  runtime fetch). The app-target dependency count (one — GRDB) is
  untouched.
- **D4 — automatic deprovisioning requires the App Store Server API key**;
  without it the cron no-ops rather than delete on stale app-reported
  expiry. A lapsed-but-silent user's hostname persisting costs $0.10/mo; a
  paying user's domain vanishing because their Mac was closed is a trust
  failure. The pre-spec's "App Store Server API for renewal status if
  needed" — it is needed.
- **D5 — `username.muse.app` serves through the Worker's wildcard route
  with a KV gate** (unclaimed → 404), not bare wildcard DNS to the page:
  an unclaimed subdomain rendering the share shell is free phishing
  surface, and the claim gate is the cheap mitigation the takedown path
  builds on. Edge-cached KV reads (1 h TTL) keep it within free-tier
  quotas; a released username can serve for up to an hour after release
  (recorded).
- **D6 — no anonymous availability endpoint**: claiming is the probe. Every
  Worker endpoint requires a paid transaction, which is the abuse posture
  the free tier's Safe-Browsing risk demands.
- **D7 — the zone is a prerequisite, not "the existing Pages zone"**:
  `muse-share.pages.dev` is not a zone; the apex domain must be purchased
  and stood up (owner step 1). All names are `DomainConfig`/Worker-env
  constants so the actual domain substitutes without code changes.
- **D8 — the change-domain path is delete-then-create**, not an atomic
  replace endpoint. A failure between the two calls leaves the user
  domain-less but retryable (state 2 of the card); an atomic replace on the
  Worker would double the CF-interaction surface for a rare path.

---

## 15. Acceptance mapping (from `pre-spec-08-custom-domains.md` §Acceptance)

| Pre-spec acceptance line | Where satisfied |
|---|---|
| End-to-end on a real test domain: sandbox purchase → enter domain → CNAME instructions → active → share link serves with valid TLS | §1 topology + §2/§3 Worker + §6.3 card; executed as owner step §12.7 |
| Worker rejects invalid/expired JWS, lapsed subscription, second hostname, malformed domains, apex (clear error) | §3.3 verification + §3.2 gates + §3.4 validator; every code test-pinned (§9 node) and app-mapped (§4.4) |
| Subscription lapse → grace messaging → deprovision → links revert gracefully | §5.3 messaging · §3.5 sweep (authoritative Apple status) · §4.6 refresher discovery + one-shot notice + §4.2 record rebase |
| Token absent from the app binary (verified); secret rotation documented | §8 last bullet + §12.7 `strings` check · §3.7 README rotation section |
| `username.muse.app` claim/release works; reserved names blocked | §2 username endpoints + §3.4 RESERVED + §3.6 serving + §6.2 row; fixtures pin the list both sides |
| Removing the domain reverts links gracefully; existing fragment links unaffected | §4.2 rebase (fragment preserved) + the never-rebase-on-add rule; default-base links serve forever (Pages never stops answering) |
