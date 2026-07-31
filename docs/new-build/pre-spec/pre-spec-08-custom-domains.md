# Spec 08 — Custom Domains, Subdomains & the Provisioning Worker

*Read with `muse-photo-foundation.md` §10–§11. Depends on Spec 07 (share/portfolio surfaces) and Spec 01 (licensing — entitlements gate this). The only spec with new server-side code: ONE small Cloudflare Worker.*

## Purpose
The paid sharing tier: `photos.theirdomain.com` for shares/portfolio. Savee charges $15/MONTH for portfolio+domain; this tier undercuts ~10× at ~$15–20/YEAR (final pricing OPEN, foundation §11).

## Architecture (DECIDED direction)

### Cloudflare for SaaS (Custom Hostnames) on the existing Pages zone
- Verified pricing: **100 custom hostnames FREE on every plan, then $0.10/hostname/month** ($0 at 100 customers; ~$90/mo at 1,000 — margin-positive at any plausible price).
- Fallback origin → the existing Pages project. The SAME static deployment serves every hostname — fragment-based share data needs zero changes.
- **Subdomains only** (`photos.domain.com`): apex requires CF Enterprise. UI must say so; note the CNAME-flattening workaround for users whose DNS is on Cloudflare.

### The provisioning Worker (~50 lines — the only backend)
- **The CF API token NEVER ships in the app** (it can create/delete hostnames zone-wide). Token lives in a Worker secret.
- Endpoints: create / status / delete custom hostname. **Auth: the app sends its App Store signed subscription transaction (StoreKit 2 JWS for the sharing-tier subscription); the Worker verifies the JWS signature against Apple's certificate chain and checks the subscription is active** (App Store Server API for renewal status if needed). Rate limit: ONE active hostname per subscription. Workers free tier (100k req/day) suffices indefinitely.
- Add to the documented sanctioned network paths (doctrine, Spec 01).

### In-app UX (a modal — no web portal)
1. User purchases the sharing-tier subscription via IAP (StoreKit 2) → app holds the signed transaction.
2. User types `photos.theirdomain.com`.
3. App → Worker → CF API creates the custom hostname → returns CNAME target (e.g. `share.muse.app`) + DCV record.
4. App shows copy-paste DNS instructions (per-registrar hints optional).
5. App polls Worker until hostname + SSL status are `active` (minutes–1 hour) → share links flip to the custom domain. Clear pending-state UI; re-check button; delete/change domain path.

### Free/middle tier: `username.muse.app`
- Wildcard DNS on the app's own zone — zero per-user provisioning cost, doesn't consume custom-hostname quota. Username claim = a Worker KV reservation (tiny; same Worker).
- Gate behind the paid app unlock (abuse control); reserved-word list; a documented takedown path (phishing on one subdomain can get the whole domain flagged by Safe Browsing).

### Documented escape hatch (no build, docs only)
"Bring your own Cloudflare Pages": export the static share site + instructions for self-hosting on the user's own CF account/domain. Power-user path; keeps the local-first promise honest.

## Market anchors (context)
Manual CNAME + verify button is the accepted standard (SmugMug, Adobe Portfolio). Savee bundles portfolio+domain at $15/mo — the willingness-to-pay evidence.

## Out of scope
Apex domains · email/anything else on user domains · analytics of any kind on share pages · multi-hostname per license.

## Binding decisions
#19 zero server state for share CONTENT (the Worker holds provisioning state only — hostname↔subscription, nothing about photos) · #20 architecture as above · #30 pricing final call deferred; build tier-gating against StoreKit entitlements, price configurable · #33 subscription sold ONLY via App Store IAP.

## Acceptance
- End-to-end on a real test domain: subscription purchase (StoreKit sandbox) → enter domain → CNAME instructions → active → share link serves on the custom domain with valid TLS.
- Worker rejects: invalid/expired JWS, lapsed subscription, second hostname on one subscription, malformed domains, apex attempts (clear error).
- Subscription lapse → grace period messaging → hostname deprovisioned; links revert gracefully.
- Token absent from the app binary (verified); Worker secret rotation documented.
- `username.muse.app` claim/release works; reserved names blocked.
- Removing the domain reverts links gracefully; existing fragment links unaffected.
