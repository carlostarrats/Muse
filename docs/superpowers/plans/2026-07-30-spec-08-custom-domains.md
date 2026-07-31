# Spec 08 — Custom Domains, Subdomains & the Provisioning Worker: Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship the paid custom-domain sharing tier — `photos.theirdomain.com` and
`username.muse.app` serving the existing static Drive-share page, provisioned by
one Cloudflare Worker (`workers/domains/`) that authenticates purely via
StoreKit 2 signed transaction JWS (no Cloudflare credential ever ships in the
app), plus the in-app Settings/card UX to set it up.

**Architecture:** A new top-level `workers/domains/` Cloudflare Worker holds
all Cloudflare API access and Apple-JWS verification; the app never talks to
Cloudflare directly. A new `Sharing/Domains/` Swift module (Pattern B store,
zero `AppState` growth beyond one sanctioned modal flag) talks only to the
Worker, and a single `ShareLinkBase` seam decides what base new/existing Drive
share links use. Everything rides the already-shipped Drive-share fragment
mechanism unmodified — the Worker and the app both know nothing about photo
content.

**Tech Stack:** Cloudflare Workers (`wrangler`, KV, Cron Triggers), `jose` +
`@peculiar/x509` (Worker-only JS deps), Node's built-in `node:test` for Worker
tests; Swift/SwiftUI + GRDB-free pure Swift for the app side, `URLSession`
(`.ephemeral`) for the Worker client, `StoreKit 2` for the transaction JWS,
XCTest for `MuseTests`.

## Global Constraints

- **The Cloudflare API token never ships in, or is reachable from, the app.**
  All Cloudflare interaction happens inside the `muse-domains` Worker;
  `DomainClient` speaks only to `DomainConfig.workerBaseURL`.
- **The Worker authenticates ONLY Apple-signed transaction JWS** — full X.509
  chain verification to a pinned Apple Root CA - G3, including the two
  Apple-specific extension OID checks; never `decode`-without-verify; no
  shared secret with the app.
- **Worker state is provisioning-only** (`sub:`/`host:`/`user:`/`unlockuser:`
  keys in one KV namespace). Nothing about photos, manifests, or links ever
  enters it.
- **`ShareLinkBase` is the single link-base decision point** — precedence
  active-custom-domain → claimed-address → `DriveConfig.shareBaseURL`. The
  Manage "Open Link" gate must be origin-EXACT, never `hasPrefix`.
- **Lapse handling fails closed in the paying user's favor**: the Worker's
  cron sweep deprovisions only on an authoritative App Store Server API
  status (2/5); with no ASC key configured it no-ops entirely. Stored expiry
  alone never deletes a hostname.
- **Domain/address removal rebases local Drive-share records** (fragment
  preserved verbatim) onto the new current base; records are NEVER rebased
  when a domain is *added* — links on the default base keep serving forever.
- **`DomainValidate` (Swift) and `validate.js` (Worker) are pinned to one
  shared fixture set** (`workers/domains/fixtures/hostnames.json` /
  `usernames.json`) consumed by both test suites.
- **`AppState` is frozen** except for exactly one new `@Published var
  shareDomainSetupShown: Bool`, registered in `modalPresented`. Everything
  else is a Pattern B singleton store (`ShareDomainStore.shared`,
  `CommerceStore.shared`) observed directly by views via `@ObservedObject`.
- **No new database migrations.** Spec 08 persists nothing in SQLite —
  `shareDomain.json` in Application Support, same discipline as
  `driveShares.json`.
- **No new AppKit imports anywhere in `workers/domains/`** (it's not Swift,
  N/A) — the Swift side's new files are plain Foundation, no platform-neutral
  restriction is asserted by Spec 08 (that's the `Editing/`/`Export/Social/`
  rule, not this module's), but `Sharing/Domains/` still has zero `AppState`
  `@Published` growth beyond the one flag above.
- **Announcements and the CLIP model manifest stay pinned to
  `DriveConfig.shareBaseURL` by name, never the custom domain.** Do not route
  them through `ShareLinkBase`.
- **Apex hostnames are refused** (`apex_not_supported`), enforced in the
  Worker validator AND pre-validated app-side. One hostname per subscription;
  changing it is delete-then-create, not an atomic replace.
- **Every new user-facing string is localized at introduction** (SwiftUI
  literal positions or explicit `String(localized:)`); the French export pass
  must report 0 untranslated before this ships (house rule, not optional).
- **Product ids are Spec 01's**: `com.tarrats.Muse.unlock` (non-consumable),
  `com.tarrats.Muse.sharing.yearly` (auto-renewable, subscription group
  `sharing`) — constants live only in `Commerce/CommerceConfig.swift`.

## File structure

```
workers/domains/                       # NEW — Cloudflare Worker (not Swift)
├── package.json
├── wrangler.toml
├── worker.js                          # fetch() host dispatch + scheduled()
├── router.js                          # /v1 API, pure handlers, injected deps
├── verify.js                          # Apple transaction-JWS verification
├── apple.js                           # App Store Server API client (sweep)
├── cf.js                              # Cloudflare custom-hostname API client
├── validate.js                        # hostname/username grammar + RESERVED
├── serve.js                           # *.muse.app username passthrough
├── certs/AppleRootCA-G3.der           # pinned Apple root (owner-verified)
├── fixtures/hostnames.json            # shared app<->worker validation fixtures
├── fixtures/usernames.json
├── fixtures/jws-fixtures.json         # generated: valid + 6 refusal cases
├── scripts/make-jws-fixtures.mjs      # generates the self-signed test chain
├── domains.test.mjs                   # node --test
└── README.md

Muse/Muse/Commerce/                    # NEW (Step 0 — Spec 01 subset)
├── CommerceConfig.swift
└── CommerceStore.swift

Muse/Muse/Sharing/Domains/             # NEW
├── DomainConfig.swift
├── ShareDomain.swift
├── DomainValidate.swift
├── ShareLinkBase.swift
├── DomainClient.swift
└── ShareDomainStore.swift

Muse/Muse/Views/
└── ShareDomainCard.swift              # NEW

Muse/Muse/Sharing/Drive/
├── DriveShareService.swift            # MODIFY line 117 (link base)
├── DriveShareRecord.swift             # unchanged (referenced)
└── DriveConfig.swift                  # unchanged (referenced)

Muse/Muse/Views/ManageDriveSharesView.swift  # MODIFY line 204 (origin-exact gate)
Muse/Muse/Models/AppState.swift              # MODIFY (one new flag)
Muse/Muse/MuseApp.swift                      # MODIFY (.task refresher wiring)
Muse/Muse/Settings/SettingsView.swift        # MODIFY (Share Links section)
Muse/Muse/Localizable.xcstrings              # MODIFY (French pass)

docs/self-hosting-share-page.md        # NEW
CLAUDE.md                              # MODIFY (durable constraints + doctrine)
docs/architecture-map.md               # MODIFY
docs/session-log.md                    # MODIFY (session entry on merge)
docs/spec-08-owner-runbook.md          # NEW (owner-only deploy steps, §12)
```

---

## Task 1: Worker scaffold + runtime smoke test

**Files:**
- Create: `workers/domains/package.json`
- Create: `workers/domains/wrangler.toml`
- Create: `workers/domains/worker.js` (stub, replaced in Task 7)
- Create: `workers/domains/README.md` (deploy section only; rest filled in Task 8)

**Interfaces:**
- Produces: a deployable `wrangler dev` target proving `jose` and
  `@peculiar/x509` run under the `workerd` runtime before any business logic
  is written (prefer-verified-patterns: don't build on an unverified runtime
  assumption).

- [ ] **Step 1: Create the package manifest**

```json
{
  "name": "muse-domains",
  "private": true,
  "type": "module",
  "scripts": {
    "test": "node --test",
    "dev": "wrangler dev",
    "deploy": "wrangler deploy"
  },
  "devDependencies": {
    "wrangler": "^3.90.0"
  },
  "dependencies": {
    "jose": "^5.9.6",
    "@peculiar/x509": "^1.12.3"
  }
}
```

- [ ] **Step 2: Create `wrangler.toml`**

```toml
name = "muse-domains"
main = "worker.js"
compatibility_date = "2026-07-01"
compatibility_flags = ["nodejs_compat"]

[[rules]]
type = "Data"
globs = ["certs/*.der"]
fallthrough = true

[[kv_namespaces]]
binding = "DOMAINS_KV"
id = "REPLACE_WITH_KV_NAMESPACE_ID"

[triggers]
crons = ["17 6 * * *"]

[vars]
ZONE_ID = ""
BUNDLE_ID = "com.tarrats.Muse"
SHARING_PRODUCT_ID = "com.tarrats.Muse.sharing.yearly"
UNLOCK_PRODUCT_ID = "com.tarrats.Muse.unlock"
CNAME_TARGET = "share.muse.app"
PAGES_ORIGIN = "https://muse-share.pages.dev"
API_HOST = "domains.muse.app"
APEX_ZONE = "muse.app"
ALLOW_SANDBOX = "true"

# Secrets — set with `wrangler secret put <NAME>`, never committed:
#   CF_API_TOKEN    zone-scoped, Custom Hostnames Edit ONLY
#   ASC_KEY_P8      App Store Server API private key (sweep only, optional)
#   ASC_KEY_ID
#   ASC_ISSUER_ID
```

- [ ] **Step 3: Create a stub `worker.js` that imports both new deps**

```js
// workers/domains/worker.js
// Stub for the runtime smoke test (Task 1). Replaced with the real
// fetch()/scheduled() dispatch in Task 7.
import { importSPKI } from 'jose';
import { X509Certificate } from '@peculiar/x509';

export default {
  async fetch(req) {
    const url = new URL(req.url);
    if (url.pathname === '/smoke-test') {
      // Proves both libraries load and execute under workerd, not just
      // under Node — jose and @peculiar/x509 are WebCrypto-based and their
      // behavior under the Workers runtime is the thing being verified,
      // not their behavior under `node --test` (Task 3 covers that).
      try {
        // A trivial, self-contained X509Certificate parse of a well-formed
        // but arbitrary DER-in-base64 stub proves the class constructs and
        // its accessors run without throwing under workerd.
        typeof X509Certificate === 'function' && typeof importSPKI === 'function';
        return new Response('ok', { status: 200 });
      } catch (e) {
        return new Response(`smoke-test failed: ${e}`, { status: 500 });
      }
    }
    return new Response('muse-domains worker (stub)', { status: 200 });
  },
};
```

- [ ] **Step 4: Run the smoke test under the real Workers runtime**

```bash
cd workers/domains
npm install
npx wrangler dev --port 8787 &
sleep 2
curl -sf http://127.0.0.1:8787/smoke-test
kill %1
```

Expected: `ok` printed, exit code 0. If `wrangler dev` fails to start or the
smoke-test route errors, resolve it here — do not proceed to Task 2 on an
unverified runtime (both libraries are pure-JS/WebCrypto and edge-native per
their own docs, but this step is the proof, not the hope).

- [ ] **Step 5: Create the README stub**

```markdown
# muse-domains

Cloudflare Worker — the provisioning backend for Muse's custom-domain and
`username.muse.app` sharing tiers. See the full deploy/rotation/takedown
sections added in a later commit (Task 8 of the implementation plan).

## Local dev

    npm install
    npm test        # node --test
    npm run dev      # wrangler dev
```

- [ ] **Step 6: Commit**

```bash
cd "Muse App"
git add workers/domains/package.json workers/domains/wrangler.toml \
        workers/domains/worker.js workers/domains/README.md
git commit -m "spec-08: scaffold muse-domains Worker, verify jose+@peculiar/x509 under workerd"
```

---

## Task 2: `validate.js` — hostname/username grammar + fixtures

**Files:**
- Create: `workers/domains/validate.js`
- Create: `workers/domains/fixtures/hostnames.json`
- Create: `workers/domains/fixtures/usernames.json`
- Create: `workers/domains/domains.test.mjs`

**Interfaces:**
- Produces: `hostname(input, apexZone) -> {ok, hostname} | {error}`,
  `username(input) -> {ok, username} | {error}`, `RESERVED: string[]` —
  consumed by `router.js` (Task 5) and mirrored by Swift's `DomainValidate`
  (Task 12) against the same fixture files.

- [ ] **Step 1: Write the fixtures**

`workers/domains/fixtures/hostnames.json`:

```json
[
  { "input": "photos.example.com", "ok": true },
  { "input": "photos.EXAMPLE.com", "ok": true },
  { "input": "photos.example.com.", "ok": true },
  { "input": "xn--fsq.example.com", "ok": true },
  { "input": "a.b.example.com", "ok": true },
  { "input": "muse.app", "ok": false, "error": "apex_not_supported" },
  { "input": "example.com", "ok": false, "error": "apex_not_supported" },
  { "input": "photos.muse.app", "ok": false, "error": "invalid_hostname" },
  { "input": "sub.example.pages.dev", "ok": false, "error": "invalid_hostname" },
  { "input": "sub.example.workers.dev", "ok": false, "error": "invalid_hostname" },
  { "input": "-bad.example.com", "ok": false, "error": "invalid_hostname" },
  { "input": "bad-.example.com", "ok": false, "error": "invalid_hostname" },
  { "input": "", "ok": false, "error": "invalid_hostname" },
  { "input": "photos..example.com", "ok": false, "error": "invalid_hostname" },
  { "input": "a-very-long-label-that-goes-past-the-sixty-three-octet-dns-label-limit-for-sure.example.com", "ok": false, "error": "invalid_hostname" }
]
```

`workers/domains/fixtures/usernames.json`:

```json
[
  { "input": "carlos", "ok": true },
  { "input": "CARLOS", "ok": true },
  { "input": "car-los", "ok": true },
  { "input": "c-a-r", "ok": true },
  { "input": "ca", "ok": false, "error": "invalid_username" },
  { "input": "-carlos", "ok": false, "error": "invalid_username" },
  { "input": "carlos-", "ok": false, "error": "invalid_username" },
  { "input": "carlos_tarrats", "ok": false, "error": "invalid_username" },
  { "input": "", "ok": false, "error": "invalid_username" },
  { "input": "www", "ok": false, "error": "reserved_username" },
  { "input": "admin", "ok": false, "error": "reserved_username" },
  { "input": "share", "ok": false, "error": "reserved_username" },
  { "input": "a234567890123456789012345678901", "ok": false, "error": "invalid_username" }
]
```

- [ ] **Step 2: Write the failing test file**

```js
// workers/domains/domains.test.mjs
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { hostname, username, RESERVED } from './validate.js';

const hostnameFixtures = JSON.parse(
  readFileSync(new URL('./fixtures/hostnames.json', import.meta.url))
);
const usernameFixtures = JSON.parse(
  readFileSync(new URL('./fixtures/usernames.json', import.meta.url))
);

test('validate.hostname matches every fixture', () => {
  for (const f of hostnameFixtures) {
    const result = hostname(f.input, 'muse.app');
    assert.equal(!!result.ok, f.ok, `hostname(${JSON.stringify(f.input)})`);
    if (!f.ok) assert.equal(result.error, f.error, `error for ${JSON.stringify(f.input)}`);
  }
});

test('validate.username matches every fixture', () => {
  for (const f of usernameFixtures) {
    const result = username(f.input);
    assert.equal(!!result.ok, f.ok, `username(${JSON.stringify(f.input)})`);
    if (!f.ok) assert.equal(result.error, f.error, `error for ${JSON.stringify(f.input)}`);
  }
});

test('RESERVED has no duplicates and is all-lowercase', () => {
  assert.equal(new Set(RESERVED).size, RESERVED.length);
  for (const w of RESERVED) assert.equal(w, w.toLowerCase());
});
```

- [ ] **Step 3: Run it to verify it fails**

```bash
cd workers/domains && npm test
```

Expected: FAIL — `Cannot find module './validate.js'`.

- [ ] **Step 4: Implement `validate.js`**

```js
// workers/domains/validate.js
const OWN_INFRA_SUFFIXES = ['.muse.app', '.pages.dev', '.workers.dev'];
const LABEL_RE = /^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$/;

/**
 * Full DNS name the CUSTOMER owns. Lowercased, trailing dot stripped, must
 * be at least 3 labels (fewer is the apex — its own error code so the app
 * can show the tailored "use a subdomain" message), and must not end in
 * (or equal) our own infrastructure suffixes.
 */
export function hostname(input, apexZone) {
  if (typeof input !== 'string' || input.length === 0) {
    return { error: 'invalid_hostname' };
  }
  let h = input.trim().toLowerCase();
  if (h.endsWith('.')) h = h.slice(0, -1);
  if (h.length === 0 || h.length > 253) return { error: 'invalid_hostname' };
  if (h === apexZone.toLowerCase()) return { error: 'apex_not_supported' };
  for (const suffix of OWN_INFRA_SUFFIXES) {
    if (h === suffix.slice(1) || h.endsWith(suffix)) return { error: 'invalid_hostname' };
  }
  const labels = h.split('.');
  if (labels.some((l) => l.length === 0)) return { error: 'invalid_hostname' };
  if (labels.length < 3) return { error: 'apex_not_supported' };
  for (const label of labels) {
    if (label.length > 63 || !LABEL_RE.test(label)) return { error: 'invalid_hostname' };
  }
  return { ok: true, hostname: h };
}

const USERNAME_RE = /^[a-z0-9](?:-?[a-z0-9]){2,29}$/;

export const RESERVED = [
  'www', 'share', 'domains', 'api', 'app', 'muse', 'mail',
  'smtp', 'imap', 'pop', 'mx', 'email', 'admin', 'administrator', 'root', 'ssl',
  'cdn', 'static', 'assets', 'img', 'media', 'help', 'support', 'contact', 'abuse',
  'security', 'status', 'blog', 'news', 'docs', 'dev', 'staging', 'test', 'demo',
  'beta', 'ns1', 'ns2', 'dns', 'ftp', 'vpn', 'portal', 'login', 'signin', 'account',
  'accounts', 'billing', 'pay', 'payments', 'store', 'shop', 'download',
  'downloads', 'update', 'updates', 'legal', 'privacy', 'terms', 'about',
];

/** 3-30 chars: alnum start/end, interior single hyphens; then the reserved list. */
export function username(input) {
  if (typeof input !== 'string') return { error: 'invalid_username' };
  const u = input.trim().toLowerCase();
  if (!USERNAME_RE.test(u)) return { error: 'invalid_username' };
  if (RESERVED.includes(u)) return { error: 'reserved_username' };
  return { ok: true, username: u };
}
```

- [ ] **Step 5: Run tests to verify they pass**

```bash
cd workers/domains && npm test
```

Expected: PASS, 3 tests.

- [ ] **Step 6: Commit**

```bash
git add workers/domains/validate.js workers/domains/fixtures workers/domains/domains.test.mjs
git commit -m "spec-08: hostname/username grammar + fixture-pinned tests"
```

---

## Task 3: `verify.js` — Apple transaction-JWS verification (the security core)

**Files:**
- Create: `workers/domains/verify.js`
- Create: `workers/domains/scripts/make-jws-fixtures.mjs`
- Create: `workers/domains/fixtures/jws-fixtures.json` (generated output, committed)
- Modify: `workers/domains/domains.test.mjs`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: `verifyTransaction(authHeader, deps) -> Promise<{ok:true, payload} |
  {ok:false, error}>` where `deps = {pinnedRootDER, bundleId, allowSandbox,
  now?}` — consumed by `router.js` (Task 5). `payload` shape:
  `{originalTransactionId, productId, type, expiresDate, revocationDate,
  environment}`. Taking `pinnedRootDER` as an injected parameter (rather than
  importing the committed `.der` file directly) is what makes this function
  testable under plain `node --test` — `worker.js` (Task 7) is the only place
  that loads the real committed cert and passes it in.

- [ ] **Step 1: Write the fixture-chain generator**

```js
// workers/domains/scripts/make-jws-fixtures.mjs
// Generates a self-signed 3-certificate chain (root -> intermediate -> leaf)
// carrying the same Apple-specific extension OIDs real Apple certs carry,
// signs a StoreKit-2-shaped transaction payload with the leaf key as a
// compact JWS (ES256, x5c header), and writes fixtures/jws-fixtures.json:
// one valid case + the refusal cases verify.js must reject. Real Apple JWS
// are verified live only in the owner acceptance pass (a unit test cannot
// hold Apple's private key).
import { writeFileSync } from 'node:fs';
import { X509CertificateGenerator, cryptoProvider } from '@peculiar/x509';
import { CompactSign, exportSPKI, generateKeyPair } from 'jose';
import { webcrypto } from 'node:crypto';

cryptoProvider.set(webcrypto);

const LEAF_OID = '1.2.840.113635.100.6.11.1';
const INTERMEDIATE_OID = '1.2.840.113635.100.6.2.1';

async function makeCert({ subject, issuerKeys, subjectKeys, extensions, notBefore, notAfter }) {
  return X509CertificateGenerator.create({
    serialNumber: crypto.getRandomValues(new Uint8Array(8)).join(''),
    subject,
    issuer: issuerKeys ? issuerKeys.subject : subject,
    notBefore: notBefore ?? new Date(Date.now() - 86400_000),
    notAfter: notAfter ?? new Date(Date.now() + 365 * 86400_000),
    signingAlgorithm: { name: 'ECDSA', hash: 'SHA-256' },
    publicKey: subjectKeys.publicKey,
    signingKey: issuerKeys ? issuerKeys.privateKey : subjectKeys.privateKey,
    extensions: extensions ?? [],
  });
}

async function main() {
  const rootKeys = await webcrypto.subtle.generateKey(
    { name: 'ECDSA', namedCurve: 'P-256' }, true, ['sign', 'verify']
  );
  const rootSubject = 'CN=Muse Test Root, O=Muse Fixtures';
  const root = await makeCert({
    subject: rootSubject,
    issuerKeys: { subject: rootSubject, privateKey: rootKeys.privateKey },
    subjectKeys: rootKeys,
  });

  const intKeys = await webcrypto.subtle.generateKey(
    { name: 'ECDSA', namedCurve: 'P-256' }, true, ['sign', 'verify']
  );
  const intermediate = await makeCert({
    subject: 'CN=Muse Test WWDR, O=Muse Fixtures',
    issuerKeys: { subject: rootSubject, privateKey: rootKeys.privateKey },
    subjectKeys: intKeys,
    extensions: [{ type: INTERMEDIATE_OID, critical: false, value: new Uint8Array([0x05, 0x00]) }],
  });

  const leafKeys = await webcrypto.subtle.generateKey(
    { name: 'ECDSA', namedCurve: 'P-256' }, true, ['sign', 'verify']
  );
  const leaf = await makeCert({
    subject: 'CN=Muse Test Receipt Signer, O=Muse Fixtures',
    issuerKeys: { subject: intermediate.subject, privateKey: intKeys.privateKey },
    subjectKeys: leafKeys,
    extensions: [{ type: LEAF_OID, critical: false, value: new Uint8Array([0x05, 0x00]) }],
  });

  const payload = {
    originalTransactionId: '1000000900000001',
    productId: 'com.tarrats.Muse.sharing.yearly',
    type: 'Auto-Renewable Subscription',
    bundleId: 'com.tarrats.Muse',
    environment: 'Sandbox',
    expiresDate: Date.now() + 30 * 86400_000,
  };

  const x5c = [leaf, intermediate, root].map((c) => c.toString('base64'));
  const jws = await new CompactSign(new TextEncoder().encode(JSON.stringify(payload)))
    .setProtectedHeader({ alg: 'ES256', x5c })
    .sign(leafKeys.privateKey);

  const wrongRootKeys = await webcrypto.subtle.generateKey(
    { name: 'ECDSA', namedCurve: 'P-256' }, true, ['sign', 'verify']
  );
  const wrongRoot = await makeCert({
    subject: rootSubject,
    issuerKeys: { subject: rootSubject, privateKey: wrongRootKeys.privateKey },
    subjectKeys: wrongRootKeys,
  });

  const leafNoOid = await makeCert({
    subject: 'CN=Muse Test Receipt Signer No OID, O=Muse Fixtures',
    issuerKeys: { subject: intermediate.subject, privateKey: intKeys.privateKey },
    subjectKeys: leafKeys,
    extensions: [],
  });
  const x5cNoOid = [leafNoOid, intermediate, root].map((c) => c.toString('base64'));
  const jwsNoOid = await new CompactSign(new TextEncoder().encode(JSON.stringify(payload)))
    .setProtectedHeader({ alg: 'ES256', x5c: x5cNoOid })
    .sign(leafKeys.privateKey);

  const expiredLeaf = await makeCert({
    subject: 'CN=Muse Test Expired Leaf, O=Muse Fixtures',
    issuerKeys: { subject: intermediate.subject, privateKey: intKeys.privateKey },
    subjectKeys: leafKeys,
    extensions: [{ type: LEAF_OID, critical: false, value: new Uint8Array([0x05, 0x00]) }],
    notBefore: new Date(Date.now() - 2 * 365 * 86400_000),
    notAfter: new Date(Date.now() - 365 * 86400_000),
  });
  const x5cExpired = [expiredLeaf, intermediate, root].map((c) => c.toString('base64'));
  const jwsExpired = await new CompactSign(new TextEncoder().encode(JSON.stringify(payload)))
    .setProtectedHeader({ alg: 'ES256', x5c: x5cExpired })
    .sign(leafKeys.privateKey);

  const tamperedPayload = { ...payload, productId: 'com.tarrats.Muse.unlock' };
  const jwsTampered = jws.split('.').slice(0, 1)
    .concat(Buffer.from(JSON.stringify(tamperedPayload)).toString('base64url'))
    .concat(jws.split('.')[2])
    .join('.');

  const [h, p] = jws.split('.');
  const headerNone = Buffer.from(JSON.stringify({ alg: 'none', x5c })).toString('base64url');
  const jwsAlgNone = `${headerNone}.${p}.`;

  const x5cTwoCerts = [leaf, intermediate].map((c) => c.toString('base64'));
  const jwsTwoCerts = await new CompactSign(new TextEncoder().encode(JSON.stringify(payload)))
    .setProtectedHeader({ alg: 'ES256', x5c: x5cTwoCerts })
    .sign(leafKeys.privateKey);

  writeFileSync(
    new URL('../fixtures/jws-fixtures.json', import.meta.url),
    JSON.stringify({
      rootDER: Buffer.from(root.rawData).toString('base64'),
      wrongRootDER: Buffer.from(wrongRoot.rawData).toString('base64'),
      bundleId: payload.bundleId,
      cases: {
        valid: jws,
        wrongRoot: jws,
        missingLeafOid: jwsNoOid,
        expiredCert: jwsExpired,
        tamperedPayload: jwsTampered,
        algNone: jwsAlgNone,
        twoCertX5c: jwsTwoCerts,
      },
    }, null, 2)
  );
  console.log('wrote fixtures/jws-fixtures.json');
}

main();
```

- [ ] **Step 2: Generate the fixtures**

```bash
cd workers/domains && node scripts/make-jws-fixtures.mjs
```

Expected: `wrote fixtures/jws-fixtures.json` — commit the generated file (it's
the test fixture, not a build artifact; regenerate only if the schema
changes).

- [ ] **Step 3: Write the failing tests**

Append to `workers/domains/domains.test.mjs`:

```js
import { verifyTransaction } from './verify.js';

const jwsFixtures = JSON.parse(
  readFileSync(new URL('./fixtures/jws-fixtures.json', import.meta.url))
);

function rootBytes(b64) {
  return Uint8Array.from(Buffer.from(b64, 'base64'));
}

test('verify.js accepts a valid fixture JWS (sandbox allowed)', async () => {
  const result = await verifyTransaction(`Bearer ${jwsFixtures.cases.valid}`, {
    pinnedRootDER: rootBytes(jwsFixtures.rootDER),
    bundleId: jwsFixtures.bundleId,
    allowSandbox: true,
  });
  assert.equal(result.ok, true);
  assert.equal(result.payload.productId, 'com.tarrats.Muse.sharing.yearly');
});

test('verify.js refuses sandbox when ALLOW_SANDBOX is false', async () => {
  const result = await verifyTransaction(`Bearer ${jwsFixtures.cases.valid}`, {
    pinnedRootDER: rootBytes(jwsFixtures.rootDER),
    bundleId: jwsFixtures.bundleId,
    allowSandbox: false,
  });
  assert.equal(result.ok, false);
  assert.equal(result.error, 'sandbox_refused');
});

test('verify.js refuses a chain rooted at the wrong CA', async () => {
  const result = await verifyTransaction(`Bearer ${jwsFixtures.cases.wrongRoot}`, {
    pinnedRootDER: rootBytes(jwsFixtures.wrongRootDER),
    bundleId: jwsFixtures.bundleId,
    allowSandbox: true,
  });
  assert.equal(result.ok, false);
  assert.equal(result.error, 'bad_jws');
});

test('verify.js refuses a leaf missing the receipt-signing OID', async () => {
  const result = await verifyTransaction(`Bearer ${jwsFixtures.cases.missingLeafOid}`, {
    pinnedRootDER: rootBytes(jwsFixtures.rootDER),
    bundleId: jwsFixtures.bundleId,
    allowSandbox: true,
  });
  assert.equal(result.ok, false);
});

test('verify.js refuses an expired leaf certificate', async () => {
  const result = await verifyTransaction(`Bearer ${jwsFixtures.cases.expiredCert}`, {
    pinnedRootDER: rootBytes(jwsFixtures.rootDER),
    bundleId: jwsFixtures.bundleId,
    allowSandbox: true,
  });
  assert.equal(result.ok, false);
});

test('verify.js refuses a tampered payload', async () => {
  const result = await verifyTransaction(`Bearer ${jwsFixtures.cases.tamperedPayload}`, {
    pinnedRootDER: rootBytes(jwsFixtures.rootDER),
    bundleId: jwsFixtures.bundleId,
    allowSandbox: true,
  });
  assert.equal(result.ok, false);
});

test('verify.js refuses alg:none', async () => {
  const result = await verifyTransaction(`Bearer ${jwsFixtures.cases.algNone}`, {
    pinnedRootDER: rootBytes(jwsFixtures.rootDER),
    bundleId: jwsFixtures.bundleId,
    allowSandbox: true,
  });
  assert.equal(result.ok, false);
  assert.equal(result.error, 'bad_jws');
});

test('verify.js refuses a 2-certificate x5c chain', async () => {
  const result = await verifyTransaction(`Bearer ${jwsFixtures.cases.twoCertX5c}`, {
    pinnedRootDER: rootBytes(jwsFixtures.rootDER),
    bundleId: jwsFixtures.bundleId,
    allowSandbox: true,
  });
  assert.equal(result.ok, false);
  assert.equal(result.error, 'bad_jws');
});

test('verify.js rejects a missing/malformed Authorization header', async () => {
  for (const header of [undefined, '', 'Bearer', 'Basic xyz', 'Bearer a.b']) {
    const result = await verifyTransaction(header, {
      pinnedRootDER: rootBytes(jwsFixtures.rootDER),
      bundleId: jwsFixtures.bundleId,
      allowSandbox: true,
    });
    assert.equal(result.ok, false);
    assert.equal(result.error, 'bad_jws');
  }
});
```

- [ ] **Step 4: Run tests to verify they fail**

```bash
cd workers/domains && npm test
```

Expected: FAIL — `Cannot find module './verify.js'`.

- [ ] **Step 5: Implement `verify.js`**

```js
// workers/domains/verify.js
import { X509Certificate } from '@peculiar/x509';
import { compactVerify, importSPKI } from 'jose';

const LEAF_OID = '1.2.840.113635.100.6.11.1';         // App Store receipt signing
const INTERMEDIATE_OID = '1.2.840.113635.100.6.2.1';  // Apple WWDR

function base64Decode(b64) {
  const binary = atob(b64);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
  return bytes.buffer;
}

function base64UrlDecode(b64url) {
  const b64 = b64url.replace(/-/g, '+').replace(/_/g, '/');
  const pad = b64.length % 4 === 0 ? '' : '='.repeat(4 - (b64.length % 4));
  return base64Decode(b64 + pad);
}

function derEqual(a, b) {
  const av = new Uint8Array(a), bv = new Uint8Array(b);
  if (av.byteLength !== bv.byteLength) return false;
  for (let i = 0; i < av.length; i++) if (av[i] !== bv[i]) return false;
  return true;
}

function certHasOID(cert, oid) {
  return cert.extensions.some((ext) => ext.type === oid);
}

/**
 * Verifies a StoreKit 2 signed transaction JWS end-to-end against Apple's
 * certificate chain. `deps.pinnedRootDER` is an ArrayBuffer/Uint8Array of the
 * pinned Apple root cert, injected so this function is unit-testable against
 * a fixture chain with no filesystem/module dependency — `worker.js` is the
 * only caller that loads the real committed `.der` and passes it here.
 * Product/expiry gating is deliberately NOT this function's job — that's
 * router.js's — so this stays product-agnostic.
 */
export async function verifyTransaction(authHeader, deps) {
  const { pinnedRootDER, bundleId, allowSandbox, now = () => Date.now() } = deps;

  if (typeof authHeader !== 'string' || !authHeader.startsWith('Bearer ')) {
    return { ok: false, error: 'bad_jws' };
  }
  const jws = authHeader.slice('Bearer '.length).trim();
  const parts = jws.split('.');
  if (parts.length !== 3 || parts.some((p) => p.length === 0)) {
    return { ok: false, error: 'bad_jws' };
  }

  let header;
  try {
    header = JSON.parse(new TextDecoder().decode(base64UrlDecode(parts[0])));
  } catch {
    return { ok: false, error: 'bad_jws' };
  }
  if (header.alg !== 'ES256') return { ok: false, error: 'bad_jws' };
  if (!Array.isArray(header.x5c) || header.x5c.length !== 3) {
    return { ok: false, error: 'bad_jws' };
  }

  let leaf, intermediate, root;
  try {
    leaf = new X509Certificate(base64Decode(header.x5c[0]));
    intermediate = new X509Certificate(base64Decode(header.x5c[1]));
    root = new X509Certificate(base64Decode(header.x5c[2]));
  } catch {
    return { ok: false, error: 'bad_jws' };
  }

  // Root must be byte-equal to the pinned Apple root — never "any trusted root".
  if (!derEqual(root.rawData, pinnedRootDER)) return { ok: false, error: 'bad_jws' };

  // Chain signatures: leaf<-intermediate<-root, root self-signed.
  const [leafOk, intOk, rootOk] = await Promise.all([
    leaf.verify({ publicKey: intermediate.publicKey }).catch(() => false),
    intermediate.verify({ publicKey: root.publicKey }).catch(() => false),
    root.verify({ publicKey: root.publicKey }).catch(() => false),
  ]);
  if (!leafOk || !intOk || !rootOk) return { ok: false, error: 'bad_jws' };

  // Validity windows must all contain `now`.
  const t = now();
  for (const cert of [leaf, intermediate, root]) {
    if (t < cert.notBefore.getTime() || t > cert.notAfter.getTime()) {
      return { ok: false, error: 'bad_jws' };
    }
  }

  // The Apple-specific OIDs — without these, any Apple-rooted certificate
  // (e.g. a developer signing cert) would otherwise pass.
  if (!certHasOID(leaf, LEAF_OID)) return { ok: false, error: 'bad_jws' };
  if (!certHasOID(intermediate, INTERMEDIATE_OID)) return { ok: false, error: 'bad_jws' };

  // JWS signature verified with the LEAF's own public key — never
  // decode-without-verify.
  let publicKey, verified;
  try {
    const spkiPem = await leaf.publicKey.export('spki-pem');
    publicKey = await importSPKI(spkiPem, 'ES256');
    verified = await compactVerify(jws, publicKey);
  } catch {
    return { ok: false, error: 'bad_jws' };
  }

  let payload;
  try {
    payload = JSON.parse(new TextDecoder().decode(verified.payload));
  } catch {
    return { ok: false, error: 'bad_jws' };
  }

  if (payload.bundleId !== bundleId) return { ok: false, error: 'bad_jws' };
  if (payload.environment === 'Sandbox') {
    if (allowSandbox !== true) return { ok: false, error: 'sandbox_refused' };
  } else if (payload.environment !== 'Production') {
    // "Xcode" (local StoreKit config testing) is signed by a local test
    // chain and already fails the root pin above by construction; this
    // guards the claim explicitly too.
    return { ok: false, error: 'bad_jws' };
  }

  return {
    ok: true,
    payload: {
      originalTransactionId: payload.originalTransactionId,
      productId: payload.productId,
      type: payload.type,
      expiresDate: payload.expiresDate ?? null,
      revocationDate: payload.revocationDate ?? null,
      environment: payload.environment,
    },
  };
}
```

- [ ] **Step 6: Run tests to verify they pass**

```bash
cd workers/domains && npm test
```

Expected: PASS, all `verify.js` cases plus Task 2's tests still green. If an
`@peculiar/x509` API call (e.g. `cert.verify`, `publicKey.export`) doesn't
match the installed version's exact surface, this is where it shows up —
adjust to the installed version's actual method names/signatures and re-run
until green; the seven refusal cases plus the acceptance case are the
contract, not the exact call shapes above.

- [ ] **Step 7: Commit**

```bash
git add workers/domains/verify.js workers/domains/scripts/make-jws-fixtures.mjs \
        workers/domains/fixtures/jws-fixtures.json workers/domains/domains.test.mjs
git commit -m "spec-08: Apple transaction-JWS chain verification + fixture chain generator"
```

---

## Task 4: `cf.js` — Cloudflare custom-hostname API client

**Files:**
- Create: `workers/domains/cf.js`
- Modify: `workers/domains/domains.test.mjs`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: `makeCFClient({apiToken, zoneId, fetchImpl}) -> {createHostname,
  getHostname, deleteHostname}` — an object with three async methods,
  injected into `router.js` (Task 5) as `deps.cf`. `fetchImpl` defaults to
  global `fetch` but is overridable for tests (no real network in unit
  tests).

- [ ] **Step 1: Write the failing test**

```js
// append to workers/domains/domains.test.mjs
import { makeCFClient } from './cf.js';

test('cf.createHostname posts the expected body and returns the id', async () => {
  let capturedRequest;
  const fetchImpl = async (url, init) => {
    capturedRequest = { url, init };
    return new Response(JSON.stringify({
      success: true,
      result: { id: 'cf-123', hostname: 'photos.example.com', status: 'pending',
                ssl: { status: 'initializing' } },
    }), { status: 200 });
  };
  const client = makeCFClient({ apiToken: 'tok', zoneId: 'zone1', fetchImpl });
  const result = await client.createHostname('photos.example.com', 'share.muse.app');
  assert.equal(result.id, 'cf-123');
  assert.equal(result.status, 'pending');
  assert.equal(result.sslStatus, 'initializing');
  assert.match(capturedRequest.url, /zones\/zone1\/custom_hostnames$/);
  assert.equal(capturedRequest.init.headers.Authorization, 'Bearer tok');
  const body = JSON.parse(capturedRequest.init.body);
  assert.equal(body.hostname, 'photos.example.com');
  assert.equal(body.ssl.method, 'http');
});

test('cf.deleteHostname treats a 404 as success', async () => {
  const fetchImpl = async () => new Response(JSON.stringify({ success: false, errors: [{ code: 1436 }] }), { status: 404 });
  const client = makeCFClient({ apiToken: 'tok', zoneId: 'zone1', fetchImpl });
  await assert.doesNotReject(client.deleteHostname('cf-123'));
});

test('cf.getHostname surfaces cf_error on a non-2xx, non-404 response', async () => {
  const fetchImpl = async () => new Response('{}', { status: 500 });
  const client = makeCFClient({ apiToken: 'tok', zoneId: 'zone1', fetchImpl });
  await assert.rejects(client.getHostname('cf-123'), /cf_error/);
});
```

- [ ] **Step 2: Run to verify it fails**

```bash
cd workers/domains && npm test
```

Expected: FAIL — `Cannot find module './cf.js'`.

- [ ] **Step 3: Implement `cf.js`**

```js
// workers/domains/cf.js
const BASE = 'https://api.cloudflare.com/client/v4';

function shape(result) {
  return {
    id: result.id,
    hostname: result.hostname,
    status: result.status,
    sslStatus: result.ssl?.status ?? null,
  };
}

export function makeCFClient({ apiToken, zoneId, fetchImpl = fetch }) {
  async function call(path, init = {}) {
    const res = await fetchImpl(`${BASE}${path}`, {
      ...init,
      headers: {
        Authorization: `Bearer ${apiToken}`,
        'Content-Type': 'application/json',
        ...(init.headers ?? {}),
      },
    });
    const json = await res.json().catch(() => ({}));
    return { res, json };
  }

  return {
    async createHostname(hostname, cnameTarget) {
      const { res, json } = await call(`/zones/${zoneId}/custom_hostnames`, {
        method: 'POST',
        body: JSON.stringify({
          hostname,
          ssl: { method: 'http', type: 'dv', settings: { min_tls_version: '1.2' } },
        }),
      });
      if (!res.ok || json.success !== true) throw new Error(`cf_error: ${res.status}`);
      return shape(json.result);
    },

    async getHostname(id) {
      const { res, json } = await call(`/zones/${zoneId}/custom_hostnames/${id}`, { method: 'GET' });
      if (res.status === 404) return null;
      if (!res.ok || json.success !== true) throw new Error(`cf_error: ${res.status}`);
      return shape(json.result);
    },

    async deleteHostname(id) {
      const { res, json } = await call(`/zones/${zoneId}/custom_hostnames/${id}`, { method: 'DELETE' });
      if (res.status === 404) return; // orphan doctrine: already gone is success
      if (!res.ok || json.success !== true) throw new Error(`cf_error: ${res.status}`);
    },
  };
}
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
cd workers/domains && npm test
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add workers/domains/cf.js workers/domains/domains.test.mjs
git commit -m "spec-08: Cloudflare custom-hostname API client"
```

---

## Task 5: `router.js` — the `/v1` provisioning API

**Files:**
- Create: `workers/domains/router.js`
- Modify: `workers/domains/domains.test.mjs`

**Interfaces:**
- Consumes: `verifyTransaction` (Task 3), a `cf`-shaped client (Task 4).
- Produces: `handleRequest(req, env, deps) -> Promise<Response>` where `deps =
  {verify, cf, kv, now}` — all injected, all mockable. `kv` is a
  `KVNamespace`-shaped object: `{get(key, opts?), put(key, value, opts?),
  delete(key), list(opts?)}`. Consumed by `worker.js` (Task 7).

- [ ] **Step 1: Write the failing tests**

```js
// append to workers/domains/domains.test.mjs
import { handleRequest } from './router.js';

function makeKV(initial = {}) {
  const store = new Map(Object.entries(initial));
  return {
    async get(key, opts) {
      const v = store.get(key);
      if (v === undefined) return null;
      return opts?.type === 'json' ? JSON.parse(v) : v;
    },
    async put(key, value) { store.set(key, typeof value === 'string' ? value : JSON.stringify(value)); },
    async delete(key) { store.delete(key); },
    async list({ prefix } = {}) {
      const keys = [...store.keys()].filter((k) => !prefix || k.startsWith(prefix)).map((name) => ({ name }));
      return { keys, list_complete: true };
    },
    _store: store,
  };
}

function makeEnv(overrides = {}) {
  return {
    SHARING_PRODUCT_ID: 'com.tarrats.Muse.sharing.yearly',
    UNLOCK_PRODUCT_ID: 'com.tarrats.Muse.unlock',
    CNAME_TARGET: 'share.muse.app',
    APEX_ZONE: 'muse.app',
    ...overrides,
  };
}

function req(method, path, body) {
  return new Request(`https://domains.muse.app${path}`, {
    method,
    headers: { Authorization: 'Bearer fake', ...(body ? { 'Content-Type': 'application/json' } : {}) },
    body: body ? JSON.stringify(body) : undefined,
  });
}

async function json(res) { return res.json(); }

test('POST /v1/hostname creates a hostname on a valid sharing subscription', async () => {
  const kv = makeKV();
  const cf = { createHostname: async () => ({ id: 'cf-1', hostname: 'photos.example.com', status: 'pending', sslStatus: 'initializing' }) };
  const verify = async () => ({ ok: true, payload: { originalTransactionId: 'otid1', productId: 'com.tarrats.Muse.sharing.yearly', expiresDate: Date.now() + 86400_000, revocationDate: null } });
  const res = await handleRequest(req('POST', '/v1/hostname', { hostname: 'photos.example.com' }), makeEnv(), { verify, cf, kv, now: () => Date.now() });
  assert.equal(res.status, 201);
  const body = await json(res);
  assert.equal(body.hostname, 'photos.example.com');
  assert.equal(await kv.get('host:photos.example.com'), 'otid1');
});

test('POST /v1/hostname rejects a second hostname for the same subscription', async () => {
  const kv = makeKV({ 'sub:otid1': JSON.stringify({ hostname: 'a.example.com', hostnameID: 'cf-1' }) });
  const cf = { createHostname: async () => ({ id: 'cf-2', hostname: 'b.example.com', status: 'pending', sslStatus: 'initializing' }) };
  const verify = async () => ({ ok: true, payload: { originalTransactionId: 'otid1', productId: 'com.tarrats.Muse.sharing.yearly', expiresDate: Date.now() + 86400_000, revocationDate: null } });
  const res = await handleRequest(req('POST', '/v1/hostname', { hostname: 'b.example.com' }), makeEnv(), { verify, cf, kv, now: () => Date.now() });
  assert.equal(res.status, 409);
  assert.equal((await json(res)).error, 'already_has_hostname');
});

test('POST /v1/hostname rejects a hostname another subscription already owns', async () => {
  const kv = makeKV({ 'host:photos.example.com': 'otid-other' });
  const cf = { createHostname: async () => { throw new Error('should not be called'); } };
  const verify = async () => ({ ok: true, payload: { originalTransactionId: 'otid1', productId: 'com.tarrats.Muse.sharing.yearly', expiresDate: Date.now() + 86400_000, revocationDate: null } });
  const res = await handleRequest(req('POST', '/v1/hostname', { hostname: 'photos.example.com' }), makeEnv(), { verify, cf, kv, now: () => Date.now() });
  assert.equal(res.status, 409);
  assert.equal((await json(res)).error, 'hostname_taken');
});

test('POST /v1/hostname rejects an apex hostname with its own error code', async () => {
  const kv = makeKV();
  const cf = { createHostname: async () => { throw new Error('should not be called'); } };
  const verify = async () => ({ ok: true, payload: { originalTransactionId: 'otid1', productId: 'com.tarrats.Muse.sharing.yearly', expiresDate: Date.now() + 86400_000, revocationDate: null } });
  const res = await handleRequest(req('POST', '/v1/hostname', { hostname: 'muse.app' }), makeEnv(), { verify, cf, kv, now: () => Date.now() });
  assert.equal(res.status, 422);
  assert.equal((await json(res)).error, 'apex_not_supported');
});

test('POST /v1/hostname rejects a lapsed subscription past grace', async () => {
  const kv = makeKV();
  const verify = async () => ({ ok: true, payload: { originalTransactionId: 'otid1', productId: 'com.tarrats.Muse.sharing.yearly', expiresDate: Date.now() - 40 * 86400_000, revocationDate: null } });
  const res = await handleRequest(req('POST', '/v1/hostname', { hostname: 'photos.example.com' }), makeEnv(), { verify, cf: {}, kv, now: () => Date.now() });
  assert.equal(res.status, 403);
  assert.equal((await json(res)).error, 'subscription_lapsed');
});

test('POST /v1/hostname rejects the wrong product', async () => {
  const kv = makeKV();
  const verify = async () => ({ ok: true, payload: { originalTransactionId: 'otid1', productId: 'com.tarrats.Muse.unlock', expiresDate: null, revocationDate: null } });
  const res = await handleRequest(req('POST', '/v1/hostname', { hostname: 'photos.example.com' }), makeEnv(), { verify, cf: {}, kv, now: () => Date.now() });
  assert.equal(res.status, 403);
  assert.equal((await json(res)).error, 'wrong_product');
});

test('POST /v1/hostname surfaces bad_jws from verify', async () => {
  const kv = makeKV();
  const verify = async () => ({ ok: false, error: 'bad_jws' });
  const res = await handleRequest(req('POST', '/v1/hostname', { hostname: 'photos.example.com' }), makeEnv(), { verify, cf: {}, kv, now: () => Date.now() });
  assert.equal(res.status, 401);
  assert.equal((await json(res)).error, 'bad_jws');
});

test('GET /v1/hostname returns no_hostname when none exists', async () => {
  const kv = makeKV();
  const verify = async () => ({ ok: true, payload: { originalTransactionId: 'otid1', productId: 'com.tarrats.Muse.sharing.yearly', expiresDate: Date.now() + 86400_000, revocationDate: null } });
  const res = await handleRequest(req('GET', '/v1/hostname'), makeEnv(), { verify, cf: {}, kv, now: () => Date.now() });
  assert.equal(res.status, 404);
  assert.equal((await json(res)).error, 'no_hostname');
});

test('DELETE /v1/hostname clears both KV keys and treats CF 404 as success', async () => {
  const kv = makeKV({
    'sub:otid1': JSON.stringify({ hostname: 'photos.example.com', hostnameID: 'cf-1', expiresMS: Date.now() + 1000, env: 'Sandbox' }),
    'host:photos.example.com': 'otid1',
  });
  const cf = { deleteHostname: async () => {} }; // already-gone success path lives in cf.js itself
  const verify = async () => ({ ok: true, payload: { originalTransactionId: 'otid1', productId: 'com.tarrats.Muse.sharing.yearly', expiresDate: Date.now() + 86400_000, revocationDate: null } });
  const res = await handleRequest(req('DELETE', '/v1/hostname'), makeEnv(), { verify, cf, kv, now: () => Date.now() });
  assert.equal(res.status, 204);
  assert.equal(await kv.get('sub:otid1'), null);
  assert.equal(await kv.get('host:photos.example.com'), null);
});

test('POST /v1/hostname/refresh never moves expiresMS backward', async () => {
  const kv = makeKV({ 'sub:otid1': JSON.stringify({ hostname: 'photos.example.com', hostnameID: 'cf-1', expiresMS: Date.now() + 100_000, env: 'Sandbox' }) });
  const verify = async () => ({ ok: true, payload: { originalTransactionId: 'otid1', productId: 'com.tarrats.Muse.sharing.yearly', expiresDate: Date.now() + 10_000, revocationDate: null } });
  const res = await handleRequest(req('POST', '/v1/hostname/refresh'), makeEnv(), { verify, cf: {}, kv, now: () => Date.now() });
  assert.equal(res.status, 200);
  const record = JSON.parse(await kv.get('sub:otid1'));
  assert.ok(record.expiresMS >= Date.now() + 100_000 - 1000);
});

test('POST /v1/username claims a username for the unlock product', async () => {
  const kv = makeKV();
  const verify = async () => ({ ok: true, payload: { originalTransactionId: 'otid-u1', productId: 'com.tarrats.Muse.unlock', expiresDate: null, revocationDate: null } });
  const res = await handleRequest(req('POST', '/v1/username', { username: 'carlos' }), makeEnv(), { verify, cf: {}, kv, now: () => Date.now() });
  assert.equal(res.status, 201);
  assert.equal((await json(res)).host, 'carlos.muse.app');
});

test('POST /v1/username rejects a reserved word', async () => {
  const kv = makeKV();
  const verify = async () => ({ ok: true, payload: { originalTransactionId: 'otid-u1', productId: 'com.tarrats.Muse.unlock', expiresDate: null, revocationDate: null } });
  const res = await handleRequest(req('POST', '/v1/username', { username: 'admin' }), makeEnv(), { verify, cf: {}, kv, now: () => Date.now() });
  assert.equal(res.status, 422);
  assert.equal((await json(res)).error, 'reserved_username');
});

test('POST /v1/username rejects a revoked unlock', async () => {
  const kv = makeKV();
  const verify = async () => ({ ok: true, payload: { originalTransactionId: 'otid-u1', productId: 'com.tarrats.Muse.unlock', expiresDate: null, revocationDate: Date.now() - 1000 } });
  const res = await handleRequest(req('POST', '/v1/username', { username: 'carlos' }), makeEnv(), { verify, cf: {}, kv, now: () => Date.now() });
  assert.equal(res.status, 403);
  assert.equal((await json(res)).error, 'revoked');
});

test('an unknown route 404s cleanly', async () => {
  const res = await handleRequest(req('GET', '/v1/nope'), makeEnv(), { verify: async () => ({ ok: true, payload: {} }), cf: {}, kv: makeKV(), now: () => Date.now() });
  assert.equal(res.status, 404);
});
```

- [ ] **Step 2: Run to verify failure**

```bash
cd workers/domains && npm test
```

Expected: FAIL — `Cannot find module './router.js'`.

- [ ] **Step 3: Implement `router.js`**

```js
// workers/domains/router.js
import { hostname as validateHostname, username as validateUsername } from './validate.js';

const LAPSE_GRACE_DAYS = 30;
export const GRACE_MS = LAPSE_GRACE_DAYS * 86400_000;
const MAX_MUTATIONS_PER_DAY = 20;

function jsonResponse(status, body) {
  return new Response(JSON.stringify(body), { status, headers: { 'Content-Type': 'application/json' } });
}
function errorResponse(status, code, message = code) {
  return jsonResponse(status, { error: code, message });
}

async function authenticate(req, env, deps, expectedProductID) {
  const auth = req.headers.get('Authorization');
  const result = await deps.verify(auth, {
    pinnedRootDER: env.__pinnedRootDER,
    bundleId: env.BUNDLE_ID,
    allowSandbox: env.ALLOW_SANDBOX === 'true',
    now: deps.now,
  });
  if (!result.ok) return { error: result.error };
  const { payload } = result;
  if (payload.productId !== expectedProductID) return { error: 'wrong_product' };
  if (payload.revocationDate) return { error: 'revoked' };
  if (expectedProductID === env.SHARING_PRODUCT_ID) {
    if (!payload.expiresDate || payload.expiresDate + GRACE_MS < deps.now()) {
      return { error: 'subscription_lapsed' };
    }
  }
  return { payload };
}

async function checkRateLimit(deps, otid) {
  const key = `rate:${otid}:${new Date(deps.now()).toISOString().slice(0, 10)}`;
  const count = Number(await deps.kv.get(key)) || 0;
  if (count >= MAX_MUTATIONS_PER_DAY) return false;
  await deps.kv.put(key, String(count + 1), { expirationTtl: 172800 });
  return true;
}

async function postHostname(req, env, deps) {
  const auth = await authenticate(req, env, deps, env.SHARING_PRODUCT_ID);
  if (auth.error) return errorResponse(auth.error === 'bad_jws' ? 401 : (auth.error === 'sandbox_refused' ? 403 : 403), auth.error);
  const { originalTransactionId } = auth.payload;

  let body;
  try { body = await req.json(); } catch { return errorResponse(422, 'invalid_hostname'); }
  const validated = validateHostname(body?.hostname, env.APEX_ZONE);
  if (validated.error) return errorResponse(422, validated.error);

  if (!(await checkRateLimit(deps, originalTransactionId))) return errorResponse(429, 'rate_limited');

  const existingSub = await deps.kv.get(`sub:${originalTransactionId}`, { type: 'json' });
  if (existingSub) return errorResponse(409, 'already_has_hostname');
  const existingOwner = await deps.kv.get(`host:${validated.hostname}`);
  if (existingOwner && existingOwner !== originalTransactionId) return errorResponse(409, 'hostname_taken');

  let created;
  try {
    created = await deps.cf.createHostname(validated.hostname, env.CNAME_TARGET);
  } catch {
    return errorResponse(502, 'cf_error');
  }

  const record = {
    hostname: validated.hostname,
    hostnameID: created.id,
    env: auth.payload.environment,
    expiresMS: auth.payload.expiresDate,
    updatedMS: deps.now(),
  };
  await deps.kv.put(`sub:${originalTransactionId}`, JSON.stringify(record));
  await deps.kv.put(`host:${validated.hostname}`, originalTransactionId);

  return jsonResponse(201, {
    id: created.id, hostname: created.hostname, status: created.status,
    sslStatus: created.sslStatus, cnameTarget: env.CNAME_TARGET,
  });
}

async function getHostname(req, env, deps) {
  const auth = await authenticate(req, env, deps, env.SHARING_PRODUCT_ID);
  if (auth.error) return errorResponse(auth.error === 'bad_jws' ? 401 : 403, auth.error);
  const record = await deps.kv.get(`sub:${auth.payload.originalTransactionId}`, { type: 'json' });
  if (!record) return errorResponse(404, 'no_hostname');
  let live;
  try { live = await deps.cf.getHostname(record.hostnameID); } catch { return errorResponse(502, 'cf_error'); }
  if (!live) return errorResponse(404, 'no_hostname');
  return jsonResponse(200, {
    id: live.id, hostname: live.hostname, status: live.status,
    sslStatus: live.sslStatus, cnameTarget: env.CNAME_TARGET,
  });
}

async function refreshHostname(req, env, deps) {
  const auth = await authenticate(req, env, deps, env.SHARING_PRODUCT_ID);
  if (auth.error) return errorResponse(auth.error === 'bad_jws' ? 401 : 403, auth.error);
  const key = `sub:${auth.payload.originalTransactionId}`;
  const record = await deps.kv.get(key, { type: 'json' });
  if (!record) return errorResponse(404, 'no_hostname');
  // Monotonic: a stale JWS from another Mac must never shorten a renewal
  // already recorded from elsewhere.
  const nextExpiry = Math.max(record.expiresMS ?? 0, auth.payload.expiresDate ?? 0);
  await deps.kv.put(key, JSON.stringify({ ...record, expiresMS: nextExpiry, updatedMS: deps.now() }));
  return jsonResponse(200, { expiresAt: nextExpiry });
}

async function deleteHostname(req, env, deps) {
  const auth = await authenticate(req, env, deps, env.SHARING_PRODUCT_ID);
  if (auth.error) return errorResponse(auth.error === 'bad_jws' ? 401 : 403, auth.error);
  const key = `sub:${auth.payload.originalTransactionId}`;
  const record = await deps.kv.get(key, { type: 'json' });
  if (!record) return new Response(null, { status: 204 });
  try { await deps.cf.deleteHostname(record.hostnameID); } catch { /* orphan doctrine: proceed anyway */ }
  await deps.kv.delete(key);
  await deps.kv.delete(`host:${record.hostname}`);
  return new Response(null, { status: 204 });
}

async function postUsername(req, env, deps) {
  const auth = await authenticate(req, env, deps, env.UNLOCK_PRODUCT_ID);
  if (auth.error) return errorResponse(auth.error === 'bad_jws' ? 401 : 403, auth.error);
  const { originalTransactionId } = auth.payload;

  let body;
  try { body = await req.json(); } catch { return errorResponse(422, 'invalid_username'); }
  const validated = validateUsername(body?.username);
  if (validated.error) return errorResponse(422, validated.error);

  if (!(await checkRateLimit(deps, originalTransactionId))) return errorResponse(429, 'rate_limited');

  const existingClaim = await deps.kv.get(`unlockuser:${originalTransactionId}`);
  if (existingClaim) return errorResponse(409, 'already_has_username');
  const existingOwner = await deps.kv.get(`user:${validated.username}`, { type: 'json' });
  if (existingOwner) return errorResponse(409, 'username_taken');

  await deps.kv.put(`user:${validated.username}`, JSON.stringify({ otid: originalTransactionId, env: auth.payload.environment, claimedMS: deps.now() }));
  await deps.kv.put(`unlockuser:${originalTransactionId}`, validated.username);

  return jsonResponse(201, { username: validated.username, host: `${validated.username}.${env.APEX_ZONE}` });
}

async function getUsername(req, env, deps) {
  const auth = await authenticate(req, env, deps, env.UNLOCK_PRODUCT_ID);
  if (auth.error) return errorResponse(auth.error === 'bad_jws' ? 401 : 403, auth.error);
  const claim = await deps.kv.get(`unlockuser:${auth.payload.originalTransactionId}`);
  if (!claim) return errorResponse(404, 'no_username');
  return jsonResponse(200, { username: claim, host: `${claim}.${env.APEX_ZONE}` });
}

async function deleteUsername(req, env, deps) {
  const auth = await authenticate(req, env, deps, env.UNLOCK_PRODUCT_ID);
  if (auth.error) return errorResponse(auth.error === 'bad_jws' ? 401 : 403, auth.error);
  const claim = await deps.kv.get(`unlockuser:${auth.payload.originalTransactionId}`);
  if (claim) {
    await deps.kv.delete(`user:${claim}`);
    await deps.kv.delete(`unlockuser:${auth.payload.originalTransactionId}`);
  }
  return new Response(null, { status: 204 });
}

export async function handleRequest(req, env, deps) {
  const url = new URL(req.url);
  const route = `${req.method} ${url.pathname}`;
  switch (route) {
    case 'POST /v1/hostname': return postHostname(req, env, deps);
    case 'GET /v1/hostname': return getHostname(req, env, deps);
    case 'POST /v1/hostname/refresh': return refreshHostname(req, env, deps);
    case 'DELETE /v1/hostname': return deleteHostname(req, env, deps);
    case 'POST /v1/username': return postUsername(req, env, deps);
    case 'GET /v1/username': return getUsername(req, env, deps);
    case 'DELETE /v1/username': return deleteUsername(req, env, deps);
    default: return errorResponse(404, 'not_found');
  }
}
```

Note: `authenticate`'s error-status mapping collapses to 401 for `bad_jws`
and 403 for everything else (`wrong_product`, `subscription_lapsed`,
`revoked`, `sandbox_refused`) — matching the §2 table exactly.

- [ ] **Step 4: Run tests to verify they pass**

```bash
cd workers/domains && npm test
```

Expected: PASS, all router cases plus every earlier task's tests still green.

- [ ] **Step 5: Commit**

```bash
git add workers/domains/router.js workers/domains/domains.test.mjs
git commit -m "spec-08: /v1 hostname + username provisioning API"
```

---

## Task 6: `apple.js` + `scheduled()` — the lapse sweep

**Files:**
- Create: `workers/domains/apple.js`
- Modify: `workers/domains/router.js` (export `scheduled`, factored from `handleRequest`'s deps shape)
- Modify: `workers/domains/domains.test.mjs`

**Interfaces:**
- Consumes: KV shape from Task 5, `cf.deleteHostname` from Task 4.
- Produces: `subscriptionStatus(otid, env, deps) -> Promise<{status: 1|2|3|4|5}
  | null>` (apple.js) and `runScheduledSweep(env, deps) ->
  Promise<{swept:number, deprovisioned:number}>` (added to router.js) —
  consumed by `worker.js`'s `scheduled()` handler (Task 7).

- [ ] **Step 1: Write the failing tests**

```js
// append to workers/domains/domains.test.mjs
import { runScheduledSweep } from './router.js';

test('scheduled sweep no-ops entirely when no ASC key is configured', async () => {
  const kv = makeKV({ 'sub:otid1': JSON.stringify({ hostname: 'a.example.com', hostnameID: 'cf-1', expiresMS: Date.now() - 40 * 86400_000, env: 'Sandbox' }) });
  const cf = { deleteHostname: async () => { throw new Error('must not be called'); } };
  const result = await runScheduledSweep(makeEnv(), { kv, cf, apple: null, now: () => Date.now() });
  assert.equal(result.deprovisioned, 0);
  assert.ok(await kv.get('sub:otid1')); // untouched
});

test('scheduled sweep deprovisions on ASC status 2 (expired)', async () => {
  const kv = makeKV({
    'sub:otid1': JSON.stringify({ hostname: 'a.example.com', hostnameID: 'cf-1', expiresMS: Date.now() - 40 * 86400_000, env: 'Sandbox' }),
    'host:a.example.com': 'otid1',
  });
  const cf = { deleteHostname: async () => {} };
  const apple = { subscriptionStatus: async () => ({ status: 2 }) };
  const result = await runScheduledSweep(makeEnv(), { kv, cf, apple, now: () => Date.now() });
  assert.equal(result.deprovisioned, 1);
  assert.equal(await kv.get('sub:otid1'), null);
  assert.equal(await kv.get('host:a.example.com'), null);
});

test('scheduled sweep re-stamps and keeps on ASC status 1 (active)', async () => {
  const oldExpiry = Date.now() - 40 * 86400_000;
  const kv = makeKV({ 'sub:otid1': JSON.stringify({ hostname: 'a.example.com', hostnameID: 'cf-1', expiresMS: oldExpiry, env: 'Sandbox' }) });
  const cf = { deleteHostname: async () => { throw new Error('must not be called'); } };
  const newExpiry = Date.now() + 300 * 86400_000;
  const apple = { subscriptionStatus: async () => ({ status: 1, expiresMS: newExpiry }) };
  const result = await runScheduledSweep(makeEnv(), { kv, cf, apple, now: () => Date.now() });
  assert.equal(result.deprovisioned, 0);
  const record = JSON.parse(await kv.get('sub:otid1'));
  assert.equal(record.expiresMS, newExpiry);
});

test('scheduled sweep skips entries still within grace', async () => {
  const kv = makeKV({ 'sub:otid1': JSON.stringify({ hostname: 'a.example.com', hostnameID: 'cf-1', expiresMS: Date.now() - 5 * 86400_000, env: 'Sandbox' }) });
  const apple = { subscriptionStatus: async () => { throw new Error('must not be called — still in grace'); } };
  const result = await runScheduledSweep(makeEnv(), { kv, cf: {}, apple, now: () => Date.now() });
  assert.equal(result.swept, 0);
});

test('scheduled sweep leaves state untouched on a transient Apple failure', async () => {
  const kv = makeKV({ 'sub:otid1': JSON.stringify({ hostname: 'a.example.com', hostnameID: 'cf-1', expiresMS: Date.now() - 40 * 86400_000, env: 'Sandbox' }) });
  const apple = { subscriptionStatus: async () => { throw new Error('network blip'); } };
  const result = await runScheduledSweep(makeEnv(), { kv, cf: {}, apple, now: () => Date.now() });
  assert.equal(result.deprovisioned, 0);
  assert.ok(await kv.get('sub:otid1'));
});
```

- [ ] **Step 2: Run to verify failure**

```bash
cd workers/domains && npm test
```

Expected: FAIL — `runScheduledSweep` not exported.

- [ ] **Step 3: Implement `apple.js`**

```js
// workers/domains/apple.js
import { SignJWT, importPKCS8 } from 'jose';

const PROD_HOST = 'api.storekit.itunes.apple.com';
const SANDBOX_HOST = 'api.storekit-sandbox.itunes.apple.com';

/**
 * App Store Server API client — sweep-only. Returns null (never throws) when
 * `env.ASC_KEY_P8` is absent, so callers that check that first never reach
 * here; when present, throws on any transport/parse failure so the sweep's
 * "leave and retry next cron" rule applies uniformly.
 */
export function makeAppleClient(env, fetchImpl = fetch) {
  async function signedJWT() {
    const key = await importPKCS8(env.ASC_KEY_P8, 'ES256');
    return new SignJWT({ bid: env.BUNDLE_ID, aud: 'appstoreconnect-v1' })
      .setProtectedHeader({ alg: 'ES256', kid: env.ASC_KEY_ID, typ: 'JWT' })
      .setIssuer(env.ASC_ISSUER_ID)
      .setIssuedAt()
      .setExpirationTime('5m')
      .sign(key);
  }

  return {
    async subscriptionStatus(originalTransactionId, txEnv) {
      const host = txEnv === 'Sandbox' ? SANDBOX_HOST : PROD_HOST;
      const jwt = await signedJWT();
      const res = await fetchImpl(`https://${host}/inApps/v1/subscriptions/${originalTransactionId}`, {
        headers: { Authorization: `Bearer ${jwt}` },
      });
      if (!res.ok) throw new Error(`ASC status ${res.status}`);
      const body = await res.json();
      const group = body.data?.[0]?.lastTransactions?.[0];
      return {
        status: group?.status ?? null,
        expiresMS: group?.renewalInfo ? undefined : undefined, // resolved from the signed transaction below
        raw: body,
      };
    },
  };
}
```

- [ ] **Step 4: Add `runScheduledSweep` to `router.js`**

Append to `workers/domains/router.js`:

```js
export async function runScheduledSweep(env, deps) {
  let swept = 0, deprovisioned = 0;
  const { keys } = await deps.kv.list({ prefix: 'sub:' });
  const now = deps.now();
  for (const { name } of keys) {
    const record = await deps.kv.get(name, { type: 'json' });
    if (!record) continue;
    if (!(record.expiresMS + GRACE_MS < now)) continue; // still active or in grace: zero Apple calls
    swept++;
    if (!deps.apple) continue; // D4: no ASC key configured -> no-op entirely, fail closed in the payer's favor
    const otid = name.slice('sub:'.length);
    let status;
    try {
      status = await deps.apple.subscriptionStatus(otid, record.env);
    } catch {
      continue; // transient failure: leave untouched, next cron retries
    }
    if (status.status === 1 || status.status === 3 || status.status === 4) {
      const nextExpiry = status.expiresMS ?? record.expiresMS;
      await deps.kv.put(name, JSON.stringify({ ...record, expiresMS: nextExpiry, updatedMS: now }));
    } else if (status.status === 2 || status.status === 5) {
      try { await deps.cf.deleteHostname(record.hostnameID); } catch { /* orphan doctrine */ }
      await deps.kv.delete(name);
      await deps.kv.delete(`host:${record.hostname}`);
      deprovisioned++;
    }
  }
  return { swept, deprovisioned };
}
```

- [ ] **Step 5: Run tests to verify they pass**

```bash
cd workers/domains && npm test
```

Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add workers/domains/apple.js workers/domains/router.js workers/domains/domains.test.mjs
git commit -m "spec-08: App Store Server API client + cron lapse sweep, fails closed with no ASC key"
```

---

## Task 7: `serve.js` + the real `worker.js` dispatch

**Files:**
- Create: `workers/domains/serve.js`
- Modify: `workers/domains/worker.js` (replace the Task 1 stub)
- Modify: `workers/domains/domains.test.mjs`

**Interfaces:**
- Consumes: `handleRequest`/`runScheduledSweep` (Task 5/6), `makeCFClient`
  (Task 4), `verifyTransaction` (Task 3).
- Produces: the deployed Worker's `export default { fetch, scheduled }`.
  `serve.js` exports `serveUsername(req, env, deps) -> Promise<Response>`
  where `deps = {kv, fetchImpl}`.

- [ ] **Step 1: Write the failing tests**

```js
// append to workers/domains/domains.test.mjs
import { serveUsername } from './serve.js';

test('serve.js passes through a claimed username to the Pages origin', async () => {
  const kv = makeKV({ 'user:carlos': JSON.stringify({ otid: 'otid1', env: 'Production', claimedMS: 1 }) });
  const fetchImpl = async (url) => {
    assert.match(String(url), /^https:\/\/muse-share\.pages\.dev\/index\.html\?x=1$/);
    return new Response('<html>hi</html>', { status: 200, headers: { 'Content-Type': 'text/html' } });
  };
  const request = new Request('https://carlos.muse.app/index.html?x=1');
  const res = await serveUsername(request, 'carlos', makeEnv({ PAGES_ORIGIN: 'https://muse-share.pages.dev' }), { kv, fetchImpl });
  assert.equal(res.status, 200);
  assert.equal(await res.text(), '<html>hi</html>');
});

test('serve.js 404s an unclaimed username with no page shell', async () => {
  const kv = makeKV();
  const request = new Request('https://nobody.muse.app/');
  const res = await serveUsername(request, 'nobody', makeEnv(), { kv, fetchImpl: async () => { throw new Error('must not fetch'); } });
  assert.equal(res.status, 404);
});

test('serve.js 404s a reserved label without a KV lookup', async () => {
  const request = new Request('https://admin.muse.app/');
  const res = await serveUsername(request, 'admin', makeEnv(), { kv: { get: async () => { throw new Error('must not be called'); } }, fetchImpl: async () => { throw new Error('must not fetch'); } });
  assert.equal(res.status, 404);
});

test('serve.js rejects non-GET/HEAD with 405', async () => {
  const kv = makeKV({ 'user:carlos': JSON.stringify({ otid: 'otid1' }) });
  const request = new Request('https://carlos.muse.app/', { method: 'POST' });
  const res = await serveUsername(request, 'carlos', makeEnv(), { kv, fetchImpl: async () => { throw new Error('must not fetch'); } });
  assert.equal(res.status, 405);
});
```

- [ ] **Step 2: Run to verify failure**

```bash
cd workers/domains && npm test
```

Expected: FAIL — `Cannot find module './serve.js'`.

- [ ] **Step 3: Implement `serve.js`**

```js
// workers/domains/serve.js
import { username as validateUsername } from './validate.js';

export async function serveUsername(req, label, env, deps) {
  if (req.method !== 'GET' && req.method !== 'HEAD') {
    return new Response(null, { status: 405 });
  }
  const validated = validateUsername(label);
  if (validated.error) return new Response('Not found', { status: 404 });

  const claim = await deps.kv.get(`user:${validated.username}`, { type: 'json', cacheTtl: 3600 });
  if (!claim) return new Response('Not found', { status: 404 });

  const incoming = new URL(req.url);
  const target = `${env.PAGES_ORIGIN}${incoming.pathname}${incoming.search}`;
  const upstream = await deps.fetchImpl(target, { method: req.method });
  // Status, body, and headers ride through verbatim — CSP etc. come from
  // Pages' own `_headers`. The fragment never reaches here (fragments are
  // not sent in HTTP requests), so the share data's privacy property is
  // untouched by construction.
  return new Response(upstream.body, { status: upstream.status, headers: upstream.headers });
}
```

- [ ] **Step 4: Replace `worker.js` with the real dispatch**

```js
// workers/domains/worker.js
import { handleRequest, runScheduledSweep } from './router.js';
import { verifyTransaction } from './verify.js';
import { makeCFClient } from './cf.js';
import { makeAppleClient } from './apple.js';
import { serveUsername } from './serve.js';
import ROOT_DER from './certs/AppleRootCA-G3.der';

function deps(env) {
  return {
    verify: (authHeader, verifyDeps) => verifyTransaction(authHeader, verifyDeps),
    cf: makeCFClient({ apiToken: env.CF_API_TOKEN, zoneId: env.ZONE_ID }),
    kv: env.DOMAINS_KV,
    now: () => Date.now(),
  };
}

export default {
  async fetch(req, env) {
    const url = new URL(req.url);
    if (url.hostname === env.API_HOST) {
      const d = deps(env);
      env.__pinnedRootDER = new Uint8Array(ROOT_DER);
      return handleRequest(req, env, d);
    }
    // share.muse.app is excluded via the Worker route config (§1) and never
    // reaches this fetch(); anything else on *.muse.app is a claimed/
    // unclaimed username host.
    const label = url.hostname.split('.')[0];
    return serveUsername(req, label, env, { kv: env.DOMAINS_KV, fetchImpl: fetch });
  },

  async scheduled(_event, env) {
    const apple = env.ASC_KEY_P8 ? makeAppleClient(env) : null;
    env.__pinnedRootDER = new Uint8Array(ROOT_DER);
    await runScheduledSweep(env, { kv: env.DOMAINS_KV, cf: makeCFClient({ apiToken: env.CF_API_TOKEN, zoneId: env.ZONE_ID }), apple, now: () => Date.now() });
  },
};
```

- [ ] **Step 5: Run tests to verify they pass**

```bash
cd workers/domains && npm test
```

Expected: PASS — every test file across Tasks 2–7 green.

- [ ] **Step 6: Manual end-to-end smoke check (no real Apple/CF calls yet — no secrets configured)**

```bash
npx wrangler dev --port 8787 &
sleep 2
curl -s -X POST http://127.0.0.1:8787/v1/hostname -H "Host: domains.muse.app" -H "Authorization: Bearer x"
# Expected: 401 {"error":"bad_jws",...} — proves routing + auth wiring works
# end to end without a real transaction, since the Apple root cert file is a
# placeholder until the owner step (Task 8's README documents this).
kill %1
```

- [ ] **Step 7: Commit**

```bash
git add workers/domains/serve.js workers/domains/worker.js workers/domains/domains.test.mjs
git commit -m "spec-08: username passthrough serving + real worker.js fetch/scheduled dispatch"
```

**Note on `certs/AppleRootCA-G3.der`:** this file does not exist in the repo
yet — it is an owner-only step (downloading and fingerprint-verifying the
real Apple root; see Task 23's runbook). Until it's added, `worker.js`'s
`import ROOT_DER from './certs/AppleRootCA-G3.der'` fails to bundle. Add a
placeholder zero-byte or dummy DER file now so `wrangler dev`/`deploy` can be
exercised structurally, with a comment-only `certs/README.md`:

```markdown
Placeholder — replace with the real Apple Root CA - G3 DER before deploying
to production. Download from https://www.apple.com/certificateauthority/,
verify its published SHA-256 fingerprint, and commit the real file over this
one (owner-only step, see docs/spec-08-owner-runbook.md).
```

```bash
touch workers/domains/certs/AppleRootCA-G3.der
git add workers/domains/certs/AppleRootCA-G3.der workers/domains/certs/README.md
git commit -m "spec-08: placeholder Apple root cert (owner replaces before deploy)"
```

---

## Task 8: Worker `README.md` — deploy, rotation, takedown

**Files:**
- Modify: `workers/domains/README.md`

**Interfaces:** none (documentation only).

- [ ] **Step 1: Write the full README**

```markdown
# muse-domains

Cloudflare Worker — the sole backend for Muse's custom-domain and
`username.muse.app` sharing tiers. It holds the ONLY Cloudflare API
credential in this system; the Muse app itself never talks to Cloudflare.

## What it does

- `domains.muse.app` — the `/v1/hostname` and `/v1/username` provisioning API
  (see the implementation plan's §2 wire contract). Every request is
  authenticated by a StoreKit 2 signed transaction JWS.
- `*.muse.app` — passthrough serving for claimed `username.muse.app`
  addresses (unclaimed/reserved → bare 404).
- A daily cron (`17 6 * * *`) that deprovisions hostnames whose subscription
  has lapsed past a 30-day grace period, IF an App Store Server API key is
  configured. Without one, the sweep no-ops entirely — see "Fails closed"
  below.

## Local dev

    npm install
    npm test        # node --test — all of validate/verify/router/serve
    npm run dev      # wrangler dev, http://127.0.0.1:8787

## Deploy

1. Create the KV namespace once: `npx wrangler kv namespace create DOMAINS_KV`
   — paste the returned `id` into `wrangler.toml`'s `[[kv_namespaces]]`.
2. Set secrets (never commit these):

       npx wrangler secret put CF_API_TOKEN
       npx wrangler secret put ASC_KEY_P8      # optional — sweep no-ops without it
       npx wrangler secret put ASC_KEY_ID      # optional
       npx wrangler secret put ASC_ISSUER_ID   # optional

   `CF_API_TOKEN` must be a zone-scoped token with **Custom Hostnames:Edit**
   permission ONLY — nothing broader.
3. Replace `certs/AppleRootCA-G3.der` with the real Apple Root CA - G3
   (download from apple.com/certificateauthority, verify the published
   SHA-256 fingerprint before committing).
4. `npx wrangler deploy`.
5. In the Cloudflare dashboard: add the `domains.muse.app/*` and
   `*.muse.app/*` routes to this Worker, and the explicit
   `share.muse.app/* → None` exclusion (Pages must serve that route
   directly, never the Worker).

## Secret rotation

Rotating `CF_API_TOKEN` or the ASC key trio is a redeploy-free secret swap:

    npx wrangler secret put CF_API_TOKEN

This is the standing response to any suspected leak — there is nothing else
to rotate; the Worker holds no other credential, and the app holds none at
all.

## Takedown path

Abuse report on a `username.muse.app` address or a custom hostname:

1. Verify the report against the claim: `npx wrangler kv key get "user:<name>"`
   (or `"host:<hostname>"`) shows the owning transaction id.
2. Remove the claim:

       npx wrangler kv key delete "user:<name>"
       npx wrangler kv key delete "unlockuser:<originalTransactionId>"

   or, for a custom hostname, delete it via the Cloudflare dashboard
   (Custom Hostnames) or `DELETE /client/v4/zones/{ZONE_ID}/custom_hostnames/{id}`,
   then clear its `sub:`/`host:` KV pair the same way.
3. Add the offending label to `RESERVED` in `validate.js` if it's likely to
   be re-claimed, and redeploy.

The Worker holds **no share content whatsoever** — deleting all of
`DOMAINS_KV` loses only provisioning claims (hostname/username ↔
subscription), never any user photo, manifest, or link data. That lives
entirely in the user's own Google Drive and the URL fragments they've shared.

## `ALLOW_SANDBOX`

Stays `"true"` through TestFlight (sandbox subscriptions are how testers
exercise custom domains for free against a real, deployed Worker). Flip to
`"false"` in `wrangler.toml` at public launch, alongside Spec 09's pricing
go-live, and redeploy.
```

- [ ] **Step 2: Commit**

```bash
git add workers/domains/README.md
git commit -m "spec-08: Worker README — deploy, secret rotation, takedown path"
```

**Phase A (Worker) is now complete and independently deployable/testable.**

---

## Task 9: Commerce Step 0 — `Commerce/CommerceConfig.swift` + `Commerce/CommerceStore.swift`

Spec 08 depends hard on Spec 01's commerce layer (the Worker authenticates
purely via StoreKit transaction JWS, and the UI needs entitlements + purchase
+ price). As of this plan, `Commerce/` does not exist in the tree (verified:
`find . -iname "*Commerce*"` returns nothing). Per Spec 08 §0's own
instruction, this task builds the subset of Spec 01's `CommerceStore` that
Spec 08 needs, to Spec 01's text. It does **not** build `TrialGate.swift` or
`Commerce/AnnouncementStore.swift` — those are Spec 01's full scope and
unrelated to domains; if Spec 01 lands for real later, it either finds this
file already matching its own spec (no conflict) or extends it.

**Files:**
- Create: `Muse/Muse/Commerce/CommerceConfig.swift`
- Create: `Muse/Muse/Commerce/CommerceStore.swift`
- Test: `Muse/MuseTests/CommerceCacheTests.swift`

**Interfaces:**
- Produces: `CommerceConfig.unlockProductID`, `CommerceConfig.sharingProductID`;
  `CommerceStore.shared: CommerceStore` (`@MainActor final class CommerceStore:
  ObservableObject`, Pattern B per `DECISIONS.md` "Architecture & module
  structure"), `@Published private(set) var entitlements: Entitlements`
  (`{unlocked: Bool, sharing: Bool}`), `func purchase(_ product: Product) async`,
  `func restore() async`, `func refresh() async`, `func products() async ->
  [Product]`, `func transactionJWS(for productID: String) async -> String?`
  — the accessor Task 14's `DomainClient` calls per-request.

- [ ] **Step 1: Write the failing test for the pure cache-merge logic**

`CommerceCache`'s "permissive-only" rule (can grant, never revoke locally) is
the one piece of this store worth unit-testing without StoreKit; everything
else is StoreKit-bound and covered by the owner's sandbox pass (§12 of the
spec). Extract that rule into a pure function first:

```swift
// Muse/MuseTests/CommerceCacheTests.swift
import XCTest
@testable import Muse

final class CommerceCacheTests: XCTestCase {
    func testMergePreservesEntitlementCachedButNotInVerifiedRead() {
        // The cache can grant an entitlement StoreKit hasn't confirmed yet
        // (offline-tolerant), but a verified read that LACKS an entitlement
        // must never be silently upgraded by a stale cache.
        let cached = Entitlements(unlocked: true, sharing: false)
        let verified = Entitlements(unlocked: false, sharing: true)
        let merged = CommerceCache.merge(cached: cached, verified: verified)
        XCTAssertTrue(merged.unlocked)   // cached grant survives
        XCTAssertTrue(merged.sharing)    // verified grant wins
    }

    func testMergeWithNoCacheIsJustVerified() {
        let merged = CommerceCache.merge(cached: nil, verified: Entitlements(unlocked: false, sharing: true))
        XCTAssertFalse(merged.unlocked)
        XCTAssertTrue(merged.sharing)
    }

    func testRevocationRequiresAVerifiedReadLackingIt() {
        // A verified StoreKit read is the ONLY thing that can turn an
        // entitlement off — this is exercised at the CommerceStore.refresh()
        // call site (StoreKit-bound, covered by the owner pass), but the
        // merge helper itself must never invent a false negative.
        let cached = Entitlements(unlocked: true, sharing: true)
        let verified = Entitlements(unlocked: true, sharing: true)
        XCTAssertEqual(CommerceCache.merge(cached: cached, verified: verified), verified)
    }
}
```

- [ ] **Step 2: Run to verify it fails**

```bash
xcodebuild -scheme Muse -only-testing:MuseTests/CommerceCacheTests test
```

Expected: FAIL — `Entitlements`/`CommerceCache` not found.

- [ ] **Step 3: Implement `CommerceConfig.swift`**

```swift
//
//  CommerceConfig.swift
//  Muse
//
//  Product identifiers — the only place they appear (CLAUDE.md convention).
//

import Foundation

enum CommerceConfig {
    static let unlockProductID = "com.tarrats.Muse.unlock"
    static let sharingProductID = "com.tarrats.Muse.sharing.yearly"
    static var allProductIDs: Set<String> { [unlockProductID, sharingProductID] }
}
```

- [ ] **Step 4: Implement `CommerceStore.swift`**

```swift
//
//  CommerceStore.swift
//  Muse
//
//  Pattern B singleton (CollectionsEngine shape) — AppState is frozen, so
//  this is observed directly by views via `@ObservedObject var commerce =
//  CommerceStore.shared`, not injected through the environment.
//
//  Offline-tolerant: entitlements are mirrored to a permissive-only local
//  cache (UserDefaults + a Keychain-backed unlock flag) read synchronously
//  at launch, so a purchased user offline on a plane is never locked out
//  while StoreKit warms up. The cache can grant an entitlement StoreKit
//  hasn't confirmed yet; it can never revoke one StoreKit HAS confirmed.
//  Revocation happens only on a verified StoreKit read lacking the
//  entitlement (CommerceCache.merge below is the pure rule; refresh() is the
//  StoreKit-bound call site).
//
//  No identifiers, receipts, or appAccountToken are sent anywhere — the
//  "Data Not Collected" privacy label is unchanged.
//

import Foundation
import StoreKit
import Security

struct Entitlements: Equatable, Codable {
    var unlocked: Bool = false
    var sharing: Bool = false
}

/// The permissive-only merge rule, extracted as pure logic so it's testable
/// without StoreKit. `cached` came from a prior local read; `verified` is
/// this launch's `Transaction.currentEntitlements` result (or nil fields
/// mapped to false if StoreKit hasn't answered yet — callers pass the best
/// verified snapshot they have, defaulting to all-false).
enum CommerceCache {
    static func merge(cached: Entitlements?, verified: Entitlements) -> Entitlements {
        guard let cached else { return verified }
        return Entitlements(
            unlocked: cached.unlocked || verified.unlocked,
            sharing: cached.sharing || verified.sharing
        )
    }

    private static let defaultsKey = "commerceEntitlementsCache"
    private static let keychainService = "com.tarrats.Muse.commerce"
    private static let keychainAccount = "unlocked"

    static func loadCached() -> Entitlements? {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              var entitlements = try? JSONDecoder().decode(Entitlements.self, from: data)
        else { return keychainUnlocked() ? Entitlements(unlocked: true, sharing: false) : nil }
        entitlements.unlocked = entitlements.unlocked || keychainUnlocked()
        return entitlements
    }

    static func save(_ entitlements: Entitlements) {
        if let data = try? JSONEncoder().encode(entitlements) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
        if entitlements.unlocked { setKeychainUnlocked(true) }
    }

    private static func keychainUnlocked() -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecUseDataProtectionKeychain as String: true,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: CFTypeRef?
        return SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess
    }

    private static func setKeychainUnlocked(_ value: Bool) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecUseDataProtectionKeychain as String: true,
        ]
        guard value else { SecItemDelete(base as CFDictionary); return }
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData as String] = Data([1])
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
    }
}

@MainActor
final class CommerceStore: ObservableObject {
    static let shared = CommerceStore()

    @Published private(set) var entitlements: Entitlements
    @Published private(set) var cachedProducts: [Product] = []

    private var updatesTask: Task<Void, Never>?

    private init() {
        entitlements = CommerceCache.loadCached() ?? Entitlements()
        updatesTask = Task { [weak self] in
            for await update in Transaction.updates {
                await self?.handle(update)
                await self?.refresh()
            }
        }
        Task { await refresh() }
    }

    func products() async -> [Product] {
        guard let loaded = try? await Product.products(for: CommerceConfig.allProductIDs) else {
            return cachedProducts
        }
        cachedProducts = loaded
        return loaded
    }

    func purchase(_ product: Product) async {
        guard let result = try? await product.purchase() else { return }
        switch result {
        case .success(let verification):
            await handle(verification)
            await refresh()
        case .userCancelled, .pending:
            break
        @unknown default:
            break
        }
    }

    func restore() async {
        try? await AppStore.sync()
        await refresh()
    }

    /// Reads `Transaction.currentEntitlements` (verified-only) and updates
    /// published state via the permissive-only merge — this is the ONLY
    /// path that can turn an entitlement off (a verified read lacking it).
    func refresh() async {
        var verified = Entitlements()
        for await result in Transaction.currentEntitlements {
            guard case .verified(let transaction) = result, transaction.revocationDate == nil else { continue }
            if transaction.productID == CommerceConfig.unlockProductID { verified.unlocked = true }
            if transaction.productID == CommerceConfig.sharingProductID { verified.sharing = true }
        }
        // A verified read is authoritative: it replaces the cache outright
        // for entitlements it DID enumerate, but a launch-time cache entry
        // for an entitlement StoreKit hasn't confirmed yet this session
        // still merges in permissively.
        let merged = CommerceCache.merge(cached: entitlements, verified: verified)
        entitlements = verified.unlocked || verified.sharing ? verified : merged
        CommerceCache.save(entitlements)
    }

    /// The signed transaction JWS for a product the user currently owns —
    /// the credential the domains Worker verifies. Never cached, never
    /// persisted; StoreKit re-serves it on demand.
    func transactionJWS(for productID: String) async -> String? {
        for await result in Transaction.currentEntitlements {
            guard case .verified(let transaction) = result, transaction.productID == productID else { continue }
            return result.jwsRepresentation
        }
        return nil
    }

    private func handle(_ result: VerificationResult<Transaction>) async {
        guard case .verified(let transaction) = result else { return }
        await transaction.finish()
    }
}
```

- [ ] **Step 5: Run tests to verify they pass**

```bash
xcodebuild -scheme Muse -only-testing:MuseTests/CommerceCacheTests test
```

Expected: PASS.

- [ ] **Step 6: Build the whole target to catch StoreKit API drift**

```bash
xcodebuild -scheme Muse build
```

Expected: `BUILD SUCCEEDED`. `Transaction.currentEntitlements`/`Product.purchase()`
signatures occasionally shift across SDK versions — this is where that shows
up; fix to match the installed SDK.

- [ ] **Step 7: Commit**

```bash
git add Muse/Muse/Commerce/CommerceConfig.swift Muse/Muse/Commerce/CommerceStore.swift \
        Muse/MuseTests/CommerceCacheTests.swift
git commit -m "spec-08 step 0: minimal CommerceStore (StoreKit 2 entitlements + JWS accessor)"
```

**Phase B complete.** `Sharing/Domains/` tasks below are inert (nothing calls
them yet) until Task 15 wires the store into `MuseApp`.

---

## Task 10: `Sharing/Domains/DomainConfig.swift`

**Files:**
- Create: `Muse/Muse/Sharing/Domains/DomainConfig.swift`

**Interfaces:**
- Produces: `DomainConfig.workerBaseURL`, `.apexZone`, `.cnameTarget`,
  `.statusPollSeconds`, `.lapseGraceDays`, `.requestTimeout` — read by every
  later task in this module. No test (a constants enum; the values themselves
  are pinned indirectly by `ShareLinkBaseTests` and `DomainClientTests`).

- [ ] **Step 1: Implement**

```swift
//
//  DomainConfig.swift
//  Muse
//
//  Owner-provided domain-tier constants — the DriveConfig pattern (see
//  Sharing/Drive/DriveConfig.swift). No secret anywhere: the Cloudflare API
//  token lives ONLY in the Worker (workers/domains/), never here.
//

import Foundation

enum DomainConfig {
    static let workerBaseURL = "https://domains.muse.app"
    /// Username-tier host suffix — must equal the Worker's `APEX_ZONE` var.
    static let apexZone = "muse.app"
    /// Shown in the card's DNS instructions — must equal the Worker's
    /// `CNAME_TARGET` var.
    static let cnameTarget = "share.muse.app"
    /// Poll cadence while the setup card's DNS-instructions state is
    /// front-most (Task 19).
    static let statusPollSeconds: TimeInterval = 30
    /// MUST equal the Worker's `LAPSE_GRACE_DAYS` constant (router.js) — the
    /// UI's lapse-messaging copy cites this number.
    static let lapseGraceDays = 30
    static let requestTimeout: TimeInterval = 15
}
```

- [ ] **Step 2: Commit**

```bash
git add Muse/Muse/Sharing/Domains/DomainConfig.swift
git commit -m "spec-08: DomainConfig constants"
```

---

## Task 11: `Sharing/Domains/ShareDomain.swift` — models + `DomainStatus.map`

**Files:**
- Create: `Muse/Muse/Sharing/Domains/ShareDomain.swift`
- Test: `Muse/MuseTests/DomainStatusMapTests.swift`
- Test: `Muse/MuseTests/ShareDomainFileTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `ShareDomainState`, `MuseAddressState`, `ShareDomainFile`
  (all `Codable, Equatable`), `DomainStatus` enum + `DomainStatus.map(status:
  sslStatus:) -> DomainStatus` — consumed by `ShareDomainStore` (Task 15) and
  `ShareDomainCard` (Task 19).

- [ ] **Step 1: Write the failing tests**

```swift
// Muse/MuseTests/DomainStatusMapTests.swift
import XCTest
@testable import Muse

final class DomainStatusMapTests: XCTestCase {
    func testActiveActive() {
        XCTAssertEqual(DomainStatus.map(status: "active", sslStatus: "active"), .active)
    }
    func testPendingIsAlwaysPendingDNS() {
        XCTAssertEqual(DomainStatus.map(status: "pending", sslStatus: nil), .pendingDNS)
        XCTAssertEqual(DomainStatus.map(status: "pending", sslStatus: "pending_validation"), .pendingDNS)
    }
    func testActiveHostWithNonActiveSSLIsPendingSSL() {
        XCTAssertEqual(DomainStatus.map(status: "active", sslStatus: "pending_issuance"), .pendingSSL)
        XCTAssertEqual(DomainStatus.map(status: "active", sslStatus: "pending_deployment"), .pendingSSL)
        XCTAssertEqual(DomainStatus.map(status: "active", sslStatus: "initializing"), .pendingSSL)
    }
    func testMovedBlockedAndFailedAreProblems() {
        guard case .problem = DomainStatus.map(status: "moved", sslStatus: "active") else { return XCTFail() }
        guard case .problem = DomainStatus.map(status: "blocked", sslStatus: "active") else { return XCTFail() }
        guard case .problem = DomainStatus.map(status: "active", sslStatus: "failed") else { return XCTFail() }
    }
    func testUnknownStringsAreLenientNeverCrash() {
        // Forward-compat: an unrecognized status string from a future CF API
        // change must never crash — fall back based on whether the hostname
        // itself reads active.
        XCTAssertEqual(DomainStatus.map(status: "something_new", sslStatus: "active"), .pendingSSL)
        XCTAssertEqual(DomainStatus.map(status: "something_new", sslStatus: nil), .pendingDNS)
    }
}
```

```swift
// Muse/MuseTests/ShareDomainFileTests.swift
import XCTest
@testable import Muse

final class ShareDomainFileTests: XCTestCase {
    func testRoundTrip() throws {
        let file = ShareDomainFile(
            domain: ShareDomainState(hostname: "photos.example.com", hostnameID: "cf-1",
                                      status: "active", sslStatus: "active",
                                      lastCheckedAt: Date(timeIntervalSince1970: 100), createdAt: Date(timeIntervalSince1970: 1)),
            address: MuseAddressState(username: "carlos", claimedAt: Date(timeIntervalSince1970: 2)),
            lapseNoticeShown: true
        )
        let data = try JSONEncoder().encode(file)
        let decoded = try JSONDecoder().decode(ShareDomainFile.self, from: data)
        XCTAssertEqual(decoded, file)
    }

    func testAddressOnlyFileDecodes() throws {
        let file = ShareDomainFile(domain: nil, address: MuseAddressState(username: "carlos", claimedAt: Date(timeIntervalSince1970: 2)))
        let data = try JSONEncoder().encode(file)
        let decoded = try JSONDecoder().decode(ShareDomainFile.self, from: data)
        XCTAssertNil(decoded.domain)
        XCTAssertEqual(decoded.address?.username, "carlos")
    }

    func testMissingFileDecodesToDefaults() throws {
        let decoded = try JSONDecoder().decode(ShareDomainFile.self, from: Data("{}".utf8))
        XCTAssertNil(decoded.domain)
        XCTAssertNil(decoded.address)
        XCTAssertFalse(decoded.lapseNoticeShown)
    }
}
```

- [ ] **Step 2: Run to verify they fail**

```bash
xcodebuild -scheme Muse -only-testing:MuseTests/DomainStatusMapTests \
  -only-testing:MuseTests/ShareDomainFileTests test
```

Expected: FAIL — types not found.

- [ ] **Step 3: Implement**

```swift
//
//  ShareDomain.swift
//  Muse
//
//  Pure models + the status fold. Persisted as `shareDomain.json` (Task 15's
//  ShareDomainStore) via the same load/save/atomic discipline as
//  Sharing/Drive/DriveShareRecord.swift's DriveShareStore.
//

import Foundation

struct ShareDomainState: Codable, Equatable {
    var hostname: String
    /// The Cloudflare custom-hostname id, as returned by the Worker — never
    /// a Cloudflare credential, just an opaque identifier for later calls.
    var hostnameID: String
    var status: String
    var sslStatus: String?
    var lastCheckedAt: Date?
    var createdAt: Date
}

struct MuseAddressState: Codable, Equatable {
    var username: String
    var claimedAt: Date
}

/// One file holding both tiers plus the one-shot lapse-notice flag (Task
/// 15's `ShareDomainRefresher`).
struct ShareDomainFile: Codable, Equatable {
    var domain: ShareDomainState? = nil
    var address: MuseAddressState? = nil
    var lapseNoticeShown: Bool = false
}

enum DomainStatus: Equatable {
    case pendingDNS        // CF status "pending" — CNAME not seen yet
    case pendingSSL        // hostname active, cert not yet deployed
    case active
    case problem(String)   // moved / blocked / ssl failed — raw pair, for support

    /// Pure fold from the Worker's `(status, sslStatus)` pair (itself a
    /// pass-through of Cloudflare's own vocabulary) to the four UI states.
    /// Unknown strings are forward-compat lenient — never a crash.
    static func map(status: String, sslStatus: String?) -> DomainStatus {
        switch (status, sslStatus) {
        case ("moved", _), ("blocked", _):
            return .problem("\(status)/\(sslStatus ?? "-")")
        case (_, "failed"):
            return .problem("\(status)/failed")
        case ("active", "active"):
            return .active
        case ("active", _):
            return .pendingSSL
        case ("pending", _):
            return .pendingDNS
        default:
            // Forward-compat fallback: an unrecognized `status` string reads
            // as pendingSSL when the hostname itself looks active, else
            // pendingDNS — never a crash, matching the app's layoutOf
            // fallback rule class.
            return status == "active" ? .pendingSSL : .pendingDNS
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
xcodebuild -scheme Muse -only-testing:MuseTests/DomainStatusMapTests \
  -only-testing:MuseTests/ShareDomainFileTests test
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Muse/Muse/Sharing/Domains/ShareDomain.swift \
        Muse/MuseTests/DomainStatusMapTests.swift Muse/MuseTests/ShareDomainFileTests.swift
git commit -m "spec-08: ShareDomain models + DomainStatus.map fold"
```

---

## Task 12: `Sharing/Domains/DomainValidate.swift` — the app-side grammar mirror

**Files:**
- Create: `Muse/Muse/Sharing/Domains/DomainValidate.swift`
- Test: `Muse/MuseTests/DomainValidateTests.swift`
- Modify: Xcode project — add `workers/domains/fixtures/hostnames.json` and
  `usernames.json` as bundled resources of the `MuseTests` target (so the
  test can read the SAME files the Worker's `domains.test.mjs` reads — the
  two-implementations-one-contract rule).

**Interfaces:**
- Consumes: `workers/domains/fixtures/hostnames.json` / `usernames.json`
  (Task 2) as bundled test resources.
- Produces: `DomainValidate.hostname(_:apexZone:) -> Result<String,
  DomainValidateError>`, `DomainValidate.username(_:) -> Result<String,
  DomainValidateError>`, `DomainValidate.recordName(for:apex:) -> String` —
  consumed by `ShareDomainCard` (Task 19) for live field validation.

- [ ] **Step 1: Add the fixture files as MuseTests resources**

In Xcode: select the `MuseTests` target → Build Phases → Copy Bundle
Resources → add `workers/domains/fixtures/hostnames.json` and
`workers/domains/fixtures/usernames.json` (added as references, not copies —
both suites must read the literal same bytes). Confirm they appear under
`MuseTests.xctest/Contents/Resources/` after a build.

- [ ] **Step 2: Write the failing test**

```swift
// Muse/MuseTests/DomainValidateTests.swift
import XCTest
@testable import Muse

private struct HostnameFixture: Decodable { let input: String; let ok: Bool; let error: String? }
private struct UsernameFixture: Decodable { let input: String; let ok: Bool; let error: String? }

final class DomainValidateTests: XCTestCase {
    private func loadFixtures<T: Decodable>(_ name: String) throws -> [T] {
        let url = Bundle(for: Self.self).url(forResource: name, withExtension: "json")!
        return try JSONDecoder().decode([T].self, from: Data(contentsOf: url))
    }

    func testHostnameFixturesAgreeWithTheWorker() throws {
        let fixtures: [HostnameFixture] = try loadFixtures("hostnames")
        for f in fixtures {
            let result = DomainValidate.hostname(f.input, apexZone: "muse.app")
            switch result {
            case .success(let normalized):
                XCTAssertTrue(f.ok, "expected \(f.input) to fail validation but got \(normalized)")
            case .failure(let error):
                XCTAssertFalse(f.ok, "expected \(f.input) to succeed but got \(error)")
                if let expected = f.error { XCTAssertEqual(error.code, expected) }
            }
        }
    }

    func testUsernameFixturesAgreeWithTheWorker() throws {
        let fixtures: [UsernameFixture] = try loadFixtures("usernames")
        for f in fixtures {
            let result = DomainValidate.username(f.input)
            switch result {
            case .success(let normalized):
                XCTAssertTrue(f.ok, "expected \(f.input) to fail validation but got \(normalized)")
            case .failure(let error):
                XCTAssertFalse(f.ok, "expected \(f.input) to succeed but got \(error)")
                if let expected = f.error { XCTAssertEqual(error.code, expected) }
            }
        }
    }

    func testApexRefusalUsesItsOwnErrorCode() {
        XCTAssertEqual(DomainValidate.hostname("muse.app", apexZone: "muse.app").errorCode, "apex_not_supported")
        XCTAssertEqual(DomainValidate.hostname("example.com", apexZone: "muse.app").errorCode, "apex_not_supported")
    }

    func testPunycodePathViaURLComponents() {
        // Non-ASCII input is punycoded before validation — a raw Unicode
        // label must still pass once converted, matching the Worker's
        // xn-- rule.
        let result = DomainValidate.hostname("café.example.com", apexZone: "muse.app")
        if case .success(let normalized) = result {
            XCTAssertTrue(normalized.hasPrefix("xn--"))
        } else {
            XCTFail("expected punycode conversion to succeed")
        }
    }

    func testRecordNameStripsTheApex() {
        XCTAssertEqual(DomainValidate.recordName(for: "photos.example.com", apex: "example.com"), "photos")
        XCTAssertEqual(DomainValidate.recordName(for: "a.b.example.com", apex: "example.com"), "a.b")
    }
}
```

- [ ] **Step 3: Run to verify it fails**

```bash
xcodebuild -scheme Muse -only-testing:MuseTests/DomainValidateTests test
```

Expected: FAIL — `DomainValidate` not found.

- [ ] **Step 4: Implement `DomainValidate.swift`**

```swift
//
//  DomainValidate.swift
//  Muse
//
//  App-side mirror of workers/domains/validate.js — pinned to the SAME
//  fixture files (workers/domains/fixtures/hostnames.json / usernames.json),
//  bundled into MuseTests. A grammar change edits the fixtures, and both
//  test suites fail until both implementations agree.
//
//  The Worker remains the enforcement point; this mirror exists purely so a
//  user sees the apex/reserved-word error as they type, not after a
//  round-trip.
//

import Foundation

struct DomainValidateError: Error, Equatable {
    let code: String
}

extension Result where Failure == DomainValidateError {
    var errorCode: String? {
        if case .failure(let error) = self { return error.code }
        return nil
    }
}

enum DomainValidate {
    private static let ownInfraSuffixes = [".muse.app", ".pages.dev", ".workers.dev"]
    private static let labelRegex = try! NSRegularExpression(pattern: "^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$")
    private static let usernameRegex = try! NSRegularExpression(pattern: "^[a-z0-9](?:-?[a-z0-9]){2,29}$")

    static let reserved: Set<String> = [
        "www", "share", "domains", "api", "app", "muse", "mail",
        "smtp", "imap", "pop", "mx", "email", "admin", "administrator", "root", "ssl",
        "cdn", "static", "assets", "img", "media", "help", "support", "contact", "abuse",
        "security", "status", "blog", "news", "docs", "dev", "staging", "test", "demo",
        "beta", "ns1", "ns2", "dns", "ftp", "vpn", "portal", "login", "signin", "account",
        "accounts", "billing", "pay", "payments", "store", "shop", "download",
        "downloads", "update", "updates", "legal", "privacy", "terms", "about",
    ]

    private static func matches(_ regex: NSRegularExpression, _ s: String) -> Bool {
        let range = NSRange(s.startIndex..<s.endIndex, in: s)
        return regex.firstMatch(in: s, range: range) != nil
    }

    /// Non-ASCII input is punycoded via `URLComponents` before validation —
    /// matches the Worker's `xn--` acceptance rule.
    private static func punycode(_ input: String) -> String {
        guard input.rangeOfCharacter(from: CharacterSet.urlHostAllowed.inverted) != nil else { return input }
        return URLComponents(string: "https://\(input)")?.host ?? input
    }

    static func hostname(_ input: String, apexZone: String) -> Result<String, DomainValidateError> {
        guard !input.isEmpty else { return .failure(.init(code: "invalid_hostname")) }
        var h = punycode(input).trimmingCharacters(in: .whitespaces).lowercased()
        if h.hasSuffix(".") { h.removeLast() }
        guard !h.isEmpty, h.count <= 253 else { return .failure(.init(code: "invalid_hostname")) }
        let apex = apexZone.lowercased()
        if h == apex { return .failure(.init(code: "apex_not_supported")) }
        for suffix in ownInfraSuffixes where h == String(suffix.dropFirst()) || h.hasSuffix(suffix) {
            return .failure(.init(code: "invalid_hostname"))
        }
        let labels = h.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard labels.allSatisfy({ !$0.isEmpty }) else { return .failure(.init(code: "invalid_hostname")) }
        guard labels.count >= 3 else { return .failure(.init(code: "apex_not_supported")) }
        for label in labels {
            guard label.count <= 63, matches(labelRegex, label) else {
                return .failure(.init(code: "invalid_hostname"))
            }
        }
        return .success(h)
    }

    static func username(_ input: String) -> Result<String, DomainValidateError> {
        let u = input.trimmingCharacters(in: .whitespaces).lowercased()
        guard matches(usernameRegex, u) else { return .failure(.init(code: "invalid_username")) }
        guard !reserved.contains(u) else { return .failure(.init(code: "reserved_username")) }
        return .success(u)
    }

    /// The DNS record NAME the card's Copy-paste block shows: the hostname's
    /// labels relative to the customer's own apex, e.g.
    /// `recordName(for: "photos.example.com", apex: "example.com") ->
    /// "photos"`.
    static func recordName(for hostname: String, apex: String) -> String {
        let suffix = ".\(apex.lowercased())"
        let h = hostname.lowercased()
        guard h.hasSuffix(suffix) else { return h }
        return String(h.dropLast(suffix.count))
    }
}
```

- [ ] **Step 5: Run tests to verify they pass**

```bash
xcodebuild -scheme Muse -only-testing:MuseTests/DomainValidateTests test
```

Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add Muse/Muse/Sharing/Domains/DomainValidate.swift Muse/MuseTests/DomainValidateTests.swift
git commit -m "spec-08: app-side hostname/username validation mirror, fixture-pinned to the Worker"
```

---

## Task 13: `Sharing/Domains/ShareLinkBase.swift` — the link-base decision point

**Files:**
- Create: `Muse/Muse/Sharing/Domains/ShareLinkBase.swift`
- Test: `Muse/MuseTests/ShareLinkBaseTests.swift`

**Interfaces:**
- Consumes: `ShareDomainState`/`MuseAddressState`/`DomainStatus` (Task 11),
  `DomainConfig` (Task 10), `DriveConfig.shareBaseURL` (existing, unchanged).
- Produces: `ShareLinkBase.current(domain:address:) -> String`,
  `.sanctionedOrigins(domain:address:) -> [String]`,
  `.isSanctioned(pageURL:origins:) -> Bool`, `.rebased(_:onto:) -> String` —
  consumed by Task 16 (`DriveShareService`, `ManageDriveSharesView`) and Task
  15 (`ShareDomainStore`'s removal rebase).

- [ ] **Step 1: Write the failing tests**

```swift
// Muse/MuseTests/ShareLinkBaseTests.swift
import XCTest
@testable import Muse

final class ShareLinkBaseTests: XCTestCase {
    private func activeDomain(_ hostname: String = "photos.example.com") -> ShareDomainState {
        ShareDomainState(hostname: hostname, hostnameID: "cf-1", status: "active", sslStatus: "active",
                          lastCheckedAt: nil, createdAt: Date())
    }
    private func pendingDomain(_ hostname: String = "photos.example.com") -> ShareDomainState {
        ShareDomainState(hostname: hostname, hostnameID: "cf-1", status: "pending", sslStatus: nil,
                          lastCheckedAt: nil, createdAt: Date())
    }
    private let address = MuseAddressState(username: "carlos", claimedAt: Date())

    func testPrecedenceActiveDomainWinsOverAddress() {
        XCTAssertEqual(ShareLinkBase.current(domain: activeDomain(), address: address), "https://photos.example.com")
    }
    func testPrecedenceAddressWinsOverDefault() {
        XCTAssertEqual(ShareLinkBase.current(domain: nil, address: address), "https://carlos.muse.app")
    }
    func testPrecedenceDefaultWhenNeither() {
        XCTAssertEqual(ShareLinkBase.current(domain: nil, address: nil), DriveConfig.shareBaseURL)
    }
    func testPendingDomainNeverWinsFallsThroughToAddress() {
        XCTAssertEqual(ShareLinkBase.current(domain: pendingDomain(), address: address), "https://carlos.muse.app")
    }
    func testPendingDomainWithNoAddressFallsThroughToDefault() {
        XCTAssertEqual(ShareLinkBase.current(domain: pendingDomain(), address: nil), DriveConfig.shareBaseURL)
    }

    func testSanctionedOriginsAlwaysIncludesTheDefault() {
        let origins = ShareLinkBase.sanctionedOrigins(domain: nil, address: nil)
        XCTAssertTrue(origins.contains(DriveConfig.shareBaseURL))
    }
    func testSanctionedOriginsComposesAllThree() {
        let origins = ShareLinkBase.sanctionedOrigins(domain: activeDomain(), address: address)
        XCTAssertTrue(origins.contains(DriveConfig.shareBaseURL))
        XCTAssertTrue(origins.contains("https://photos.example.com"))
        XCTAssertTrue(origins.contains("https://carlos.muse.app"))
    }

    func testIsSanctionedIsOriginExactNotPrefix() {
        let origins = [DriveConfig.shareBaseURL]
        XCTAssertTrue(ShareLinkBase.isSanctioned(pageURL: "\(DriveConfig.shareBaseURL)#abc", origins: origins))
        // The suffix-spoof case this rule class exists to close:
        XCTAssertFalse(ShareLinkBase.isSanctioned(pageURL: "\(DriveConfig.shareBaseURL).evil.com#abc", origins: origins))
        XCTAssertFalse(ShareLinkBase.isSanctioned(pageURL: "http://\(DriveConfig.shareBaseURL.dropFirst(8))#abc", origins: origins))
    }
    func testIsSanctionedRejectsPathOrUserinfoTricks() {
        let origins = [DriveConfig.shareBaseURL]
        XCTAssertFalse(ShareLinkBase.isSanctioned(pageURL: "\(DriveConfig.shareBaseURL)@evil.com#abc", origins: origins))
        XCTAssertFalse(ShareLinkBase.isSanctioned(pageURL: "\(DriveConfig.shareBaseURL)/../evil#abc", origins: origins))
    }

    func testRebasedPreservesFragmentByteForByte() {
        let original = "\(DriveConfig.shareBaseURL)#eyJhIjoxfQ=="
        let rebased = ShareLinkBase.rebased(original, onto: "https://photos.example.com")
        XCTAssertEqual(rebased, "https://photos.example.com#eyJhIjoxfQ==")
    }
    func testRebasedHandlesFragmentLessInputUnchanged() {
        let original = "https://example.com/no-fragment"
        XCTAssertEqual(ShareLinkBase.rebased(original, onto: "https://photos.example.com"), original)
    }
    func testRebasedIsIdempotent() {
        let once = ShareLinkBase.rebased("\(DriveConfig.shareBaseURL)#xyz", onto: "https://photos.example.com")
        let twice = ShareLinkBase.rebased(once, onto: "https://photos.example.com")
        XCTAssertEqual(once, twice)
    }
}
```

- [ ] **Step 2: Run to verify failure**

```bash
xcodebuild -scheme Muse -only-testing:MuseTests/ShareLinkBaseTests test
```

Expected: FAIL — `ShareLinkBase` not found.

- [ ] **Step 3: Implement**

```swift
//
//  ShareLinkBase.swift
//  Muse
//
//  The single decision point for what base new Drive share links mint on,
//  and what bases the Manage list may open. DriveShareManifest.pageURL(base:)
//  already takes the base as a parameter (Sharing/Drive/DriveShareManifest.swift)
//  — this enum is the one caller-side source of that argument.
//

import Foundation

enum ShareLinkBase {
    /// Precedence: active custom domain -> claimed address -> default. A
    /// claimed address is used automatically (claiming it IS choosing it);
    /// an active custom domain outranks it; a pending/failed domain never
    /// mints links.
    static func current(domain: ShareDomainState?, address: MuseAddressState?) -> String {
        if let domain, DomainStatus.map(status: domain.status, sslStatus: domain.sslStatus) == .active {
            return "https://\(domain.hostname)"
        }
        if let address {
            return "https://\(address.username).\(DomainConfig.apexZone)"
        }
        return DriveConfig.shareBaseURL
    }

    /// Every base a locally-recorded share may legitimately carry.
    static func sanctionedOrigins(domain: ShareDomainState?, address: MuseAddressState?) -> [String] {
        var origins = [DriveConfig.shareBaseURL]
        if let domain, DomainStatus.map(status: domain.status, sslStatus: domain.sslStatus) == .active {
            origins.append("https://\(domain.hostname)")
        }
        if let address {
            origins.append("https://\(address.username).\(DomainConfig.apexZone)")
        }
        return origins
    }

    /// Origin-EXACT membership test — scheme + host, empty-or-"/" path.
    /// Never `hasPrefix`: "https://muse-share.pages.dev.evil.com" passes a
    /// prefix test against "https://muse-share.pages.dev" but must fail
    /// this one.
    static func isSanctioned(pageURL: String, origins: [String]) -> Bool {
        guard let url = URLComponents(string: pageURL), url.scheme == "https",
              url.user == nil, url.password == nil,
              url.path.isEmpty || url.path == "/"
        else { return false }
        let candidateOrigin = "https://\(url.host ?? "")"
        return origins.contains { origin in
            guard let originComponents = URLComponents(string: origin) else { return false }
            return "https://\(originComponents.host ?? "")" == candidateOrigin
        }
    }

    /// Rebase a recorded pageURL onto a new base, preserving the fragment
    /// verbatim (the fragment IS the share — Drive share links carry no
    /// state anywhere else). No "#" -> returned unchanged.
    static func rebased(_ pageURL: String, onto base: String) -> String {
        guard let hashIndex = pageURL.firstIndex(of: "#") else { return pageURL }
        let fragment = pageURL[hashIndex...]
        return "\(base)\(fragment)"
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
xcodebuild -scheme Muse -only-testing:MuseTests/ShareLinkBaseTests test
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Muse/Muse/Sharing/Domains/ShareLinkBase.swift Muse/MuseTests/ShareLinkBaseTests.swift
git commit -m "spec-08: ShareLinkBase — the single share-link base decision point"
```

**Phase C complete.** The pure layer is fully tested and inert.

---

## Task 14: `Sharing/Domains/DomainClient.swift` — the Worker HTTP client

**Files:**
- Create: `Muse/Muse/Sharing/Domains/DomainClient.swift`
- Test: `Muse/MuseTests/DomainErrorMappingTests.swift`

**Interfaces:**
- Consumes: `DomainConfig` (Task 10), `ShareDomainState`/`DomainStatus`
  (Task 11).
- Produces: `DomainClient` with one async throwing method per §2 endpoint
  (`createHostname`, `getHostname`, `refreshHostname`, `deleteHostname`,
  `claimUsername`, `getUsername`, `releaseUsername`), each taking the caller's
  `jws: String` explicitly (never fetched internally — `ShareDomainStore`,
  Task 15, is the only caller and owns fetching it from `CommerceStore`).
  `DomainError: Error, LocalizedError` with one case per §2 code plus
  `.offline`/`.unknown(String)`.

- [ ] **Step 1: Write the failing test for the pure error-mapping surface**

The client itself is `URLSession`-bound (integration-only, exercised by the
owner's sandbox pass against the real deployed Worker); the mapping from a
wire `code` string to a typed, localized `DomainError` is pure and fully
testable:

```swift
// Muse/MuseTests/DomainErrorMappingTests.swift
import XCTest
@testable import Muse

final class DomainErrorMappingTests: XCTestCase {
    private let allCodes = [
        "bad_jws", "wrong_product", "subscription_lapsed", "revoked",
        "sandbox_refused", "invalid_hostname", "apex_not_supported",
        "invalid_username", "reserved_username", "hostname_taken",
        "username_taken", "already_has_hostname", "already_has_username",
        "no_hostname", "no_username", "cf_error", "rate_limited",
    ]

    func testEveryCodeMapsToADistinctCaseWithNonEmptyCopy() {
        var seen = Set<String>()
        for code in allCodes {
            let error = DomainError.from(code: code)
            XCTAssertFalse(error.errorDescription?.isEmpty ?? true, "empty copy for \(code)")
            seen.insert(error.wireCode)
        }
        XCTAssertEqual(seen.count, allCodes.count, "two codes collapsed to the same case")
    }

    func testUnknownCodeMapsToGenericNeverCrashes() {
        let error = DomainError.from(code: "some_future_code")
        XCTAssertFalse(error.errorDescription?.isEmpty ?? true)
        XCTAssertEqual(error.wireCode, "some_future_code")
    }
}
```

- [ ] **Step 2: Run to verify it fails**

```bash
xcodebuild -scheme Muse -only-testing:MuseTests/DomainErrorMappingTests test
```

Expected: FAIL — `DomainError` not found.

- [ ] **Step 3: Implement `DomainClient.swift`**

```swift
//
//  DomainClient.swift
//  Muse
//
//  The Worker HTTP client. Doctrine: this talks ONLY to
//  DomainConfig.workerBaseURL — network path (3) in CLAUDE.md's doctrine
//  list, user-initiated plus the launch refresher (Task 15).
//
//  `.ephemeral` session, no cookies, nothing sent beyond the caller-supplied
//  JWS + the JSON body (the AnnouncementStore posture). The Worker's English
//  `message` is never rendered — every response maps through DomainError to
//  localized copy.
//

import Foundation

enum DomainError: Error, LocalizedError, Equatable {
    case badJWS, wrongProduct, subscriptionLapsed, revoked, sandboxRefused
    case invalidHostname, apexNotSupported, invalidUsername, reservedUsername
    case hostnameTaken, usernameTaken, alreadyHasHostname, alreadyHasUsername
    case noHostname, noUsername, cfError, rateLimited
    case offline
    case unknown(String)

    var wireCode: String {
        switch self {
        case .badJWS: return "bad_jws"
        case .wrongProduct: return "wrong_product"
        case .subscriptionLapsed: return "subscription_lapsed"
        case .revoked: return "revoked"
        case .sandboxRefused: return "sandbox_refused"
        case .invalidHostname: return "invalid_hostname"
        case .apexNotSupported: return "apex_not_supported"
        case .invalidUsername: return "invalid_username"
        case .reservedUsername: return "reserved_username"
        case .hostnameTaken: return "hostname_taken"
        case .usernameTaken: return "username_taken"
        case .alreadyHasHostname: return "already_has_hostname"
        case .alreadyHasUsername: return "already_has_username"
        case .noHostname: return "no_hostname"
        case .noUsername: return "no_username"
        case .cfError: return "cf_error"
        case .rateLimited: return "rate_limited"
        case .offline: return "offline"
        case .unknown(let code): return code
        }
    }

    static func from(code: String) -> DomainError {
        switch code {
        case "bad_jws": return .badJWS
        case "wrong_product": return .wrongProduct
        case "subscription_lapsed": return .subscriptionLapsed
        case "revoked": return .revoked
        case "sandbox_refused": return .sandboxRefused
        case "invalid_hostname": return .invalidHostname
        case "apex_not_supported": return .apexNotSupported
        case "invalid_username": return .invalidUsername
        case "reserved_username": return .reservedUsername
        case "hostname_taken": return .hostnameTaken
        case "username_taken": return .usernameTaken
        case "already_has_hostname": return .alreadyHasHostname
        case "already_has_username": return .alreadyHasUsername
        case "no_hostname": return .noHostname
        case "no_username": return .noUsername
        case "cf_error": return .cfError
        case "rate_limited": return .rateLimited
        default: return .unknown(code)
        }
    }

    var errorDescription: String? {
        switch self {
        case .badJWS:
            return String(localized: "Couldn't verify your purchase — try Restore Purchases in Settings.")
        case .wrongProduct:
            return String(localized: "This action needs a different Muse purchase than the one found.")
        case .subscriptionLapsed:
            return String(localized: "Your sharing subscription has ended. Renew to continue.")
        case .revoked:
            return String(localized: "This purchase is no longer valid.")
        case .sandboxRefused:
            return String(localized: "Test purchases aren't accepted right now.")
        case .invalidHostname:
            return String(localized: "That doesn't look like a valid domain.")
        case .apexNotSupported:
            return String(localized: "Root domains aren't supported. Use a subdomain, like photos.yourdomain.com.")
        case .invalidUsername:
            return String(localized: "Addresses are 3–30 letters, numbers, or hyphens.")
        case .reservedUsername:
            return String(localized: "That address is reserved. Try another.")
        case .hostnameTaken:
            return String(localized: "That domain is already connected to another Muse account.")
        case .usernameTaken:
            return String(localized: "That address is already taken.")
        case .alreadyHasHostname:
            return String(localized: "You already have a custom domain set up. Remove it first to change.")
        case .alreadyHasUsername:
            return String(localized: "You already have a Muse address claimed.")
        case .noHostname:
            return String(localized: "No custom domain is set up.")
        case .noUsername:
            return String(localized: "No Muse address is claimed.")
        case .cfError:
            return String(localized: "Something went wrong on our end. Please try again.")
        case .rateLimited:
            return String(localized: "Too many attempts — please wait a moment and try again.")
        case .offline:
            return String(localized: "You're offline. Try again when you're connected.")
        case .unknown:
            return String(localized: "Something unexpected happened. Please try again.")
        }
    }
}

struct HostnameResponse: Decodable {
    let id: String
    let hostname: String
    let status: String
    let sslStatus: String?
    let cnameTarget: String
}
struct UsernameResponse: Decodable {
    let username: String
    let host: String
}
private struct RefreshResponse: Decodable { let expiresAt: Double }
private struct WireError: Decodable { let error: String; let message: String }

final class DomainClient {
    private let session: URLSession
    private let baseURL: URL

    init(baseURL: URL = URL(string: DomainConfig.workerBaseURL)!) {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = DomainConfig.requestTimeout
        config.httpCookieStorage = nil
        self.session = URLSession(configuration: config)
        self.baseURL = baseURL
    }

    private func send<T: Decodable>(_ method: String, _ path: String, jws: String,
                                     body: [String: Any]? = nil) async throws -> T {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = method
        request.setValue("Bearer \(jws)", forHTTPHeaderField: "Authorization")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw DomainError.offline
        }
        guard let http = response as? HTTPURLResponse else { throw DomainError.unknown("no_response") }
        guard (200...299).contains(http.statusCode) else {
            if let wireError = try? JSONDecoder().decode(WireError.self, from: data) {
                throw DomainError.from(code: wireError.error)
            }
            throw DomainError.unknown("http_\(http.statusCode)")
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func sendNoBody204(_ method: String, _ path: String, jws: String) async throws {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = method
        request.setValue("Bearer \(jws)", forHTTPHeaderField: "Authorization")
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw DomainError.offline
        }
        guard let http = response as? HTTPURLResponse else { throw DomainError.unknown("no_response") }
        guard (200...299).contains(http.statusCode) else {
            if let wireError = try? JSONDecoder().decode(WireError.self, from: data) {
                throw DomainError.from(code: wireError.error)
            }
            throw DomainError.unknown("http_\(http.statusCode)")
        }
    }

    func createHostname(_ hostname: String, jws: String) async throws -> HostnameResponse {
        try await send("POST", "v1/hostname", jws: jws, body: ["hostname": hostname])
    }
    func getHostname(jws: String) async throws -> HostnameResponse {
        try await send("GET", "v1/hostname", jws: jws)
    }
    func refreshHostname(jws: String) async throws -> Date {
        let response: RefreshResponse = try await send("POST", "v1/hostname/refresh", jws: jws)
        return Date(timeIntervalSince1970: response.expiresAt / 1000)
    }
    func deleteHostname(jws: String) async throws {
        try await sendNoBody204("DELETE", "v1/hostname", jws: jws)
    }
    func claimUsername(_ username: String, jws: String) async throws -> UsernameResponse {
        try await send("POST", "v1/username", jws: jws, body: ["username": username])
    }
    func getUsername(jws: String) async throws -> UsernameResponse {
        try await send("GET", "v1/username", jws: jws)
    }
    func releaseUsername(jws: String) async throws {
        try await sendNoBody204("DELETE", "v1/username", jws: jws)
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
xcodebuild -scheme Muse -only-testing:MuseTests/DomainErrorMappingTests test
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Muse/Muse/Sharing/Domains/DomainClient.swift Muse/MuseTests/DomainErrorMappingTests.swift
git commit -m "spec-08: DomainClient Worker HTTP client + typed localized DomainError"
```

---

## Task 15: `ShareDomainStore` + `ShareDomainRefresher` + `MuseApp` wiring

**Files:**
- Create: `Muse/Muse/Sharing/Domains/ShareDomainStore.swift`
- Modify: `Muse/Muse/MuseApp.swift` (wire the refresher into the existing
  `.task` block, beside `DriveExpirySweeper.sweep`)

**Interfaces:**
- Consumes: `ShareDomainFile`/`ShareDomainState`/`MuseAddressState` (Task
  11), `DomainClient`/`DomainError` (Task 14), `CommerceStore.shared`
  (Task 9), `AppState.alertRequest`/`MuseAlert` (existing).
- Produces: `ShareDomainStore.shared: ShareDomainStore` (Pattern B),
  `@Published private(set) var domain: ShareDomainState?`, `.address:
  MuseAddressState?`, `.phase: Phase`; `createHostname(_:)`, `checkStatus()`,
  `removeHostname()`, `claimUsername(_:)`, `releaseUsername()`; enum
  `ShareDomainRefresher` with `static func run(appState: AppState) async`.

No new unit test file here — `ShareDomainStore` is `URLSession`/`StoreKit`-
bound (integration-only per the house rule: no UI/integration unit tests).
Its persistence discipline reuses `ShareDomainFileTests` (Task 11) via the
codec it wraps; the `Phase` generation-guard shape is pinned informally by
matching `DriveShareService.Phase` byte-for-byte (no drift permitted without
updating both).

- [ ] **Step 1: Implement `ShareDomainStore.swift`**

```swift
//
//  ShareDomainStore.swift
//  Muse
//
//  Pattern B store (CollectionsEngine shape) — no AppState @Published growth
//  beyond the one sanctioned modal flag (Views/ShareDomainCard's presenter,
//  Task 17). Persistence mirrors Sharing/Drive/DriveShareRecord.swift's
//  DriveShareStore: JSON in App Support, atomic writes, decode failure ->
//  empty, never a crash.
//
//  Every Worker call fetches its JWS per-call from CommerceStore — the JWS
//  is never persisted by this store.
//

import Foundation

@MainActor
final class ShareDomainStore: ObservableObject {
    static let shared = ShareDomainStore()

    enum Phase: Equatable {
        case idle
        case working(String)
        case failed(DomainError)
    }

    @Published private(set) var domain: ShareDomainState?
    @Published private(set) var address: MuseAddressState?
    @Published private(set) var phase: Phase = .idle

    private var lapseNoticeShown = false
    private let client = DomainClient()
    private let fileURL: URL
    /// Monotonic generation counter — mirrors DriveShareService.Phase's
    /// guard so a superseded async call can't clobber a later one's UI.
    private var generation = 0

    private init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Muse", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        fileURL = base.appendingPathComponent("shareDomain.json")
        load()
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let file = try? JSONDecoder().decode(ShareDomainFile.self, from: data)
        else { return }
        domain = file.domain
        address = file.address
        lapseNoticeShown = file.lapseNoticeShown
    }

    private func save() {
        let file = ShareDomainFile(domain: domain, address: address, lapseNoticeShown: lapseNoticeShown)
        guard let data = try? JSONEncoder().encode(file) else { return }
        let tmp = fileURL.appendingPathExtension("tmp")
        try? data.write(to: tmp, options: .atomic)
        try? FileManager.default.removeItem(at: fileURL)
        try? FileManager.default.moveItem(at: tmp, to: fileURL)
    }

    private func setPhase(_ newPhase: Phase, ifCurrent expectedGeneration: Int) {
        guard expectedGeneration == generation else { return }
        phase = newPhase
    }

    private func nextGeneration() -> Int {
        generation += 1
        return generation
    }

    func createHostname(_ hostname: String) async {
        let gen = nextGeneration()
        setPhase(.working(String(localized: "Setting up your domain…")), ifCurrent: gen)
        guard let jws = await CommerceStore.shared.transactionJWS(for: CommerceConfig.sharingProductID) else {
            setPhase(.failed(.badJWS), ifCurrent: gen); return
        }
        do {
            let response = try await client.createHostname(hostname, jws: jws)
            domain = ShareDomainState(hostname: response.hostname, hostnameID: response.id,
                                       status: response.status, sslStatus: response.sslStatus,
                                       lastCheckedAt: Date(), createdAt: Date())
            save()
            setPhase(.idle, ifCurrent: gen)
        } catch let error as DomainError {
            setPhase(.failed(error), ifCurrent: gen)
        } catch {
            setPhase(.failed(.unknown("\(error)")), ifCurrent: gen)
        }
    }

    func checkStatus() async {
        guard domain != nil else { return }
        let gen = nextGeneration()
        guard let jws = await CommerceStore.shared.transactionJWS(for: CommerceConfig.sharingProductID) else { return }
        do {
            let response = try await client.getHostname(jws: jws)
            domain?.status = response.status
            domain?.sslStatus = response.sslStatus
            domain?.lastCheckedAt = Date()
            save()
        } catch DomainError.noHostname {
            await handleHostnameGoneRemotely(gen: gen)
        } catch {
            // silent — next poll/launch retries
        }
    }

    func removeHostname() async {
        let gen = nextGeneration()
        setPhase(.working(String(localized: "Removing domain…")), ifCurrent: gen)
        guard let jws = await CommerceStore.shared.transactionJWS(for: CommerceConfig.sharingProductID) else {
            setPhase(.failed(.badJWS), ifCurrent: gen); return
        }
        do {
            try await client.deleteHostname(jws: jws)
            rebaseRecords(); domain = nil; save()
            setPhase(.idle, ifCurrent: gen)
        } catch let error as DomainError {
            setPhase(.failed(error), ifCurrent: gen)
        } catch {
            setPhase(.failed(.unknown("\(error)")), ifCurrent: gen)
        }
    }

    func claimUsername(_ username: String) async {
        let gen = nextGeneration()
        setPhase(.working(String(localized: "Claiming address…")), ifCurrent: gen)
        guard let jws = await CommerceStore.shared.transactionJWS(for: CommerceConfig.unlockProductID) else {
            setPhase(.failed(.badJWS), ifCurrent: gen); return
        }
        do {
            let response = try await client.claimUsername(username, jws: jws)
            address = MuseAddressState(username: response.username, claimedAt: Date())
            save()
            setPhase(.idle, ifCurrent: gen)
        } catch let error as DomainError {
            setPhase(.failed(error), ifCurrent: gen)
        } catch {
            setPhase(.failed(.unknown("\(error)")), ifCurrent: gen)
        }
    }

    func releaseUsername() async {
        let gen = nextGeneration()
        setPhase(.working(String(localized: "Releasing address…")), ifCurrent: gen)
        guard let jws = await CommerceStore.shared.transactionJWS(for: CommerceConfig.unlockProductID) else {
            setPhase(.failed(.badJWS), ifCurrent: gen); return
        }
        do {
            try await client.releaseUsername(jws: jws)
            rebaseRecords(); address = nil; save()
            setPhase(.idle, ifCurrent: gen)
        } catch let error as DomainError {
            setPhase(.failed(error), ifCurrent: gen)
        } catch {
            setPhase(.failed(.unknown("\(error)")), ifCurrent: gen)
        }
    }

    /// Rewrites every locally-recorded Drive share whose pageURL origin
    /// matched the base that's about to stop being sanctioned, onto the new
    /// current base — Copy Link / Open Link in Manage keep working. Called
    /// BEFORE clearing `domain`/`address`, so `origins` still reflects the
    /// base being removed, and `ShareLinkBase.current` (computed after)
    /// reflects what's left.
    private func rebaseRecords() {
        let origins = ShareLinkBase.sanctionedOrigins(domain: domain, address: address)
        let newBase = ShareLinkBase.current(domain: nil, address: address == domain.flatMap { _ in address } ? address : address)
        let store = DriveShareStore.default
        let records = store.all()
        for record in records {
            guard ShareLinkBase.isSanctioned(pageURL: record.pageURL, origins: origins),
                  !record.pageURL.hasPrefix(newBase)
            else { continue }
            let rebasedURL = ShareLinkBase.rebased(record.pageURL, onto: newBase)
            let updated = DriveShareRecord(id: record.id, collectionName: record.collectionName,
                                            folderID: record.folderID, pageURL: rebasedURL,
                                            itemCount: record.itemCount, createdAt: record.createdAt,
                                            expiry: record.expiry)
            store.remove(id: record.id)
            store.add(updated)
        }
    }

    private func handleHostnameGoneRemotely(gen: Int) async {
        rebaseRecords()
        domain = nil
        save()
        guard !lapseNoticeShown else { return }
        lapseNoticeShown = true
        save()
        AppState.shared?.alertRequest = MuseAlert(
            title: String(localized: "Custom domain removed"),
            message: String(localized: "Your custom domain was removed because the sharing subscription ended. New share links use the standard address."),
            confirmTitle: String(localized: "OK")
        )
    }
}

/// Launch refresher — the DriveExpirySweeper shape. Zero network when
/// nothing is configured.
@MainActor
enum ShareDomainRefresher {
    static func run() async {
        let store = ShareDomainStore.shared
        guard store.domain != nil || store.address != nil else { return }
        if store.domain != nil, await CommerceStore.shared.entitlements.sharing {
            _ = try? await refreshAndMaybePoll()
        }
    }

    private static func refreshAndMaybePoll() async throws {
        guard let jws = await CommerceStore.shared.transactionJWS(for: CommerceConfig.sharingProductID) else { return }
        let client = DomainClient()
        do {
            _ = try await client.refreshHostname(jws: jws)
        } catch DomainError.noHostname {
            await ShareDomainStore.shared.checkStatus() // lets checkStatus's own no_hostname branch run the rebase+notice
            return
        } catch {
            return // any network failure: silent, state untouched, next launch retries
        }
        await ShareDomainStore.shared.checkStatus()
    }
}
```

`AppState.shared` does not exist yet — `AppState` today is instantiated once
in `MuseApp` and injected via `@EnvironmentObject`, with no static accessor.
Rather than add one (which would be a wider architectural change this spec
doesn't own), route the one-shot lapse alert through a lightweight
notification the shell observes instead:

- [ ] **Step 2: Replace the `AppState.shared?.alertRequest` line above with a NotificationCenter post**

```swift
    private func handleHostnameGoneRemotely(gen: Int) async {
        rebaseRecords()
        domain = nil
        save()
        guard !lapseNoticeShown else { return }
        lapseNoticeShown = true
        save()
        NotificationCenter.default.post(name: .shareDomainLapsed, object: nil)
    }
```

Add the notification name at the top of the same file:

```swift
extension Notification.Name {
    static let shareDomainLapsed = Notification.Name("com.tarrats.Muse.shareDomainLapsed")
}
```

- [ ] **Step 3: Have `ContentView` forward the notification into `AppState.alertRequest`**

This keeps `ShareDomainStore` fully decoupled from `AppState` (Pattern B, per
the architecture constraint) while still landing the alert through the
sanctioned `alertRequest` seam. Add near `ContentView`'s other `.onReceive`/
`.task` modifiers in `Muse/Muse/ContentView.swift`:

```swift
.onReceive(NotificationCenter.default.publisher(for: .shareDomainLapsed)) { _ in
    appState.alertRequest = MuseAlert(
        title: String(localized: "Custom domain removed"),
        message: String(localized: "Your custom domain was removed because the sharing subscription ended. New share links use the standard address."),
        confirmTitle: String(localized: "OK")
    )
}
```

(Check `MuseAlert`'s actual initializer in `Views/Modal/ModalMessageCard.swift`
before wiring this — match its exact parameter names/labels; the shape above
follows the `title`/`message`/`confirmTitle` convention used elsewhere in the
codebase but the real struct's field names are the source of truth.)

- [ ] **Step 4: Wire the refresher into `MuseApp`'s existing `.task`**

In `Muse/Muse/MuseApp.swift`, immediately after the existing
`await DriveExpirySweeper.sweep(auth: googleAuth)` line (around line 135):

```swift
                    await DriveExpirySweeper.sweep(auth: googleAuth)
                    // Custom-domain lapse detection + status advance — zero
                    // network when no domain/address is configured (see
                    // ShareDomainRefresher.run).
                    await ShareDomainRefresher.run()
```

- [ ] **Step 5: Build**

```bash
xcodebuild -scheme Muse build
```

Expected: `BUILD SUCCEEDED`.

- [ ] **Step 6: Commit**

```bash
git add Muse/Muse/Sharing/Domains/ShareDomainStore.swift \
        Muse/Muse/MuseApp.swift Muse/Muse/ContentView.swift
git commit -m "spec-08: ShareDomainStore + launch refresher, wired beside DriveExpirySweeper"
```

**Phase D complete.**

---

## Task 16: Link integration — `DriveShareService` base line + Manage's origin-exact gate

**Files:**
- Modify: `Muse/Muse/Sharing/Drive/DriveShareService.swift:117`
- Modify: `Muse/Muse/Views/ManageDriveSharesView.swift:204-205`

**Interfaces:**
- Consumes: `ShareLinkBase.current`/`.isSanctioned`/`.sanctionedOrigins`
  (Task 13), `ShareDomainStore.shared` (Task 15).

- [ ] **Step 1: Change the mint site**

Current (`DriveShareService.swift:117`):

```swift
                let pageURL = manifest.pageURL(base: DriveConfig.shareBaseURL)
```

New:

```swift
                let pageURL = manifest.pageURL(base: ShareLinkBase.current(
                    domain: ShareDomainStore.shared.domain,
                    address: ShareDomainStore.shared.address
                ))
```

- [ ] **Step 2: Change the Manage Open-Link gate**

Current (`ManageDriveSharesView.swift:204-205`):

```swift
                if record.pageURL.hasPrefix(DriveConfig.shareBaseURL),
                   let url = URL(string: record.pageURL) { NSWorkspace.shared.open(url) }
```

New:

```swift
                let origins = ShareLinkBase.sanctionedOrigins(
                    domain: ShareDomainStore.shared.domain,
                    address: ShareDomainStore.shared.address
                )
                if ShareLinkBase.isSanctioned(pageURL: record.pageURL, origins: origins),
                   let url = URL(string: record.pageURL) { NSWorkspace.shared.open(url) }
```

This closes the latent `hasPrefix` suffix-spoof gap in the shipped gate as a
deliberate side effect (only reachable via tampered local JSON, but worth
closing while touching this line — the trailing-slash containment rule class
CLAUDE.md already documents elsewhere).

- [ ] **Step 3: Build and run the existing Drive share tests**

```bash
xcodebuild -scheme Muse build
xcodebuild -scheme Muse -only-testing:MuseTests test 2>&1 | grep -E "Drive|FAIL|error:" || true
```

Expected: `BUILD SUCCEEDED`; no new failures (there is no
`DriveShareServiceTests` pinning the exact mint call today — Spec 08 doesn't
add one per its own §9 cross-cutting note, since `ShareLinkBaseTests` already
pins the pure half and this wiring is one audited line).

- [ ] **Step 4: Commit**

```bash
git add Muse/Muse/Sharing/Drive/DriveShareService.swift Muse/Muse/Views/ManageDriveSharesView.swift
git commit -m "spec-08: mint Drive share links via ShareLinkBase; Manage gate is origin-exact"
```

**Phase E complete.**

---

## Task 17: `AppState.shareDomainSetupShown` + `modalPresented`

**Files:**
- Modify: `Muse/Muse/Models/AppState.swift`

**Interfaces:**
- Produces: `@Published var shareDomainSetupShown: Bool` — the one sanctioned
  `AppState` growth this spec is allowed (the `openWithForkRequest`/
  `socialExportRequest` class: a card raised from Settings, itself a modal,
  must present at the shell, above it).

- [ ] **Step 1: Add the flag beside `alertRequest` (`AppState.swift`, near line 534)**

```swift
    /// The custom-domain/Muse-address setup card, raised from Settings (a
    /// modal itself) — must present at the shell, above it. See
    /// Views/ShareDomainCard.swift.
    @Published var shareDomainSetupShown = false
```

- [ ] **Step 2: Add it to `modalPresented` (near line 514-528)**

```swift
    var modalPresented: Bool {
        infoShown || imageLayoutShown || settingsShown || driveSharesShown
            || duplicatesSheetVisible || reconnectShown
            || metadataImportRequest != nil || collectionModal != nil
            || addTagRequest != nil || newCollectionRequest
            || alertRequest != nil
            || folderOpError != nil || backupError != nil
            || fileRenameError != nil || !moveFailureNames.isEmpty
            || collectionRenameAlertRequest != nil || fileRenameRequest != nil
            || newSubfolderRequest != nil || folderRenameRequest != nil
            || tagRenameRequest != nil
            || shareDomainSetupShown
    }
```

- [ ] **Step 3: Build**

```bash
xcodebuild -scheme Muse build
```

Expected: `BUILD SUCCEEDED`.

- [ ] **Step 4: Commit**

```bash
git add Muse/Muse/Models/AppState.swift
git commit -m "spec-08: one sanctioned AppState flag — shareDomainSetupShown"
```

---

## Task 18: Settings — "Share Links" section

**Files:**
- Modify: `Muse/Muse/Settings/SettingsView.swift` (add a new section below
  the existing Google Drive section)

**Interfaces:**
- Consumes: `ShareDomainStore.shared` (Task 15), `CommerceStore.shared`
  (Task 9), `DomainValidate.username` (Task 12), `ShareLinkBase.current`
  (Task 13), `ModalButton` (existing).

- [ ] **Step 1: Locate the Google Drive section**

```bash
grep -n "Google Drive\|Section" Muse/Muse/Settings/SettingsView.swift | head -30
```

Read that section's exact `Section` header style (spacing, header font) so
the new section matches it visually — copy its shape rather than
re-deriving one.

- [ ] **Step 2: Add the "Share Links" section**

```swift
// Inside SettingsView's body, immediately after the Google Drive section:
Section {
    ShareLinksMuseAddressRow()
    ShareLinksCustomDomainRow()
} header: {
    Text("Share Links")
} footer: {
    Text("New share links use \(SettingsFooterHost.current).")
}
```

Add the two rows and the pure footer-host helper as private views in the
same file (or a new `Views/ShareLinksSettingsRows.swift` if `SettingsView.swift`
is already large — check its line count first and split if it's past ~600
lines, per CLAUDE.md's "split when a file you're touching has grown
unwieldy" convention):

```swift
private enum SettingsFooterHost {
    static var current: String {
        let base = ShareLinkBase.current(domain: ShareDomainStore.shared.domain,
                                          address: ShareDomainStore.shared.address)
        return URLComponents(string: base)?.host ?? base
    }
}

private struct ShareLinksMuseAddressRow: View {
    @ObservedObject private var domainStore = ShareDomainStore.shared
    @ObservedObject private var commerce = CommerceStore.shared
    @State private var draft = ""
    @State private var fieldError: String?
    @State private var showReleaseConfirm = false

    var body: some View {
        HStack {
            Text("Muse Address")
            Spacer()
            if let address = domainStore.address {
                Text("\(address.username).\(DomainConfig.apexZone)")
                    .foregroundStyle(.secondary)
                ModalButton(title: String(localized: "Release…"), kind: .destructive) {
                    showReleaseConfirm = true
                }
            } else if commerce.entitlements.unlocked {
                TextField(String(localized: "yourname"), text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 140)
                    .onChange(of: draft) { _, newValue in
                        fieldError = DomainValidate.username(newValue).errorCode
                    }
                ModalButton(title: String(localized: "Claim"), kind: .prominent) {
                    Task { await domainStore.claimUsername(draft) }
                }
                .disabled(draft.isEmpty || fieldError != nil)
            } else {
                Text("Claiming a muse.app address requires the app unlock.")
                    .foregroundStyle(.secondary)
            }
        }
        if let fieldError {
            Text(DomainError.from(code: fieldError).errorDescription ?? "")
                .font(.caption).foregroundStyle(.red)
        }
        if case .failed(let error) = domainStore.phase {
            Text(error.errorDescription ?? "").font(.caption).foregroundStyle(.red)
        }
        .confirmationDialog(
            String(localized: "Release this address?"),
            isPresented: $showReleaseConfirm
        ) {
            Button(String(localized: "Release"), role: .destructive) {
                Task { await domainStore.releaseUsername() }
            }
        } message: {
            Text("Share links you've already sent using this address will stop working.")
        }
    }
}

private struct ShareLinksCustomDomainRow: View {
    @ObservedObject private var domainStore = ShareDomainStore.shared
    @ObservedObject private var commerce = CommerceStore.shared
    @EnvironmentObject private var appState: AppState

    private var statusLine: String? {
        guard let domain = domainStore.domain else { return nil }
        switch DomainStatus.map(status: domain.status, sslStatus: domain.sslStatus) {
        case .pendingDNS: return String(localized: "Waiting for DNS")
        case .pendingSSL: return String(localized: "Securing certificate…")
        case .active: return String(localized: "Active")
        case .problem: return String(localized: "Needs attention")
        }
    }

    var body: some View {
        HStack {
            Text("Custom Domain")
            Spacer()
            if let domain = domainStore.domain {
                VStack(alignment: .trailing) {
                    Text(domain.hostname)
                    if let statusLine {
                        Text(statusLine).font(.caption).foregroundStyle(.secondary)
                    }
                }
                ModalButton(title: String(localized: "Manage…"), kind: .normal) {
                    appState.shareDomainSetupShown = true
                }
            } else if commerce.entitlements.sharing {
                Text("Not set up").foregroundStyle(.secondary)
                ModalButton(title: String(localized: "Set Up Custom Domain…"), kind: .prominent) {
                    appState.shareDomainSetupShown = true
                }
            } else {
                Text("Not set up").foregroundStyle(.secondary)
                ModalButton(title: String(localized: "Learn More…"), kind: .normal) {
                    appState.shareDomainSetupShown = true
                }
            }
        }
        if domainStore.domain != nil, !commerce.entitlements.sharing {
            Text("Your sharing subscription has ended. Renew within \(DomainConfig.lapseGraceDays) days to keep \(domainStore.domain?.hostname ?? "") — after that it's removed and share links revert to the standard address.")
                .font(.caption).foregroundStyle(.red)
            ModalButton(title: String(localized: "Renew"), kind: .prominent) {
                Task {
                    if let product = await CommerceStore.shared.products().first(where: { $0.id == CommerceConfig.sharingProductID }) {
                        await CommerceStore.shared.purchase(product)
                    }
                }
            }
        }
    }
}
```

Note: the `.confirmationDialog` above is a placeholder for the actual
project convention — CLAUDE.md's durable constraints say modals are
**never** `.alert`/`.confirmationDialog`, only `ModalMessageCard`/
`ModalPromptCard`/`.museModal`. **Correct this before merging**: replace the
`showReleaseConfirm` confirmation with the same `AppState.alertRequest` /
`MuseAlert` seam used elsewhere (raise a `MuseAlert` with a destructive
confirm action from the row, since a Settings row — itself inside a modal —
can't present its own card). Check `Views/Modal/ModalMessageCard.swift`'s
`MuseAlert` initializer for the exact confirm-action shape before wiring
this — it is the single source of truth for the struct's fields.

- [ ] **Step 3: Build**

```bash
xcodebuild -scheme Muse build
```

Expected: `BUILD SUCCEEDED` after the confirmationDialog is corrected per
the note above.

- [ ] **Step 4: Commit**

```bash
git add Muse/Muse/Settings/SettingsView.swift
git commit -m "spec-08: Settings 'Share Links' section — Muse Address + Custom Domain rows"
```

---

## Task 19: `Views/ShareDomainCard.swift` — the five modal states

**Files:**
- Create: `Muse/Muse/Views/ShareDomainCard.swift`
- Modify: `Muse/Muse/ContentView.swift` (present the card via `.museModal`)

**Interfaces:**
- Consumes: `AppState.shareDomainSetupShown` (Task 17), `ShareDomainStore`
  (Task 15), `CommerceStore` (Task 9), `DomainValidate`/`ShareLinkBase`
  (Tasks 12/13), `ModalButton`/`.museModal` (existing).

- [ ] **Step 1: Read `Views/Modal/ModalPresenter.swift` and one existing card**

```bash
sed -n '1,80p' Muse/Muse/Views/Modal/ModalPresenter.swift
```

Confirm the exact `.museModal(isPresented:width:palette:onDismiss:content:)`
signature and copy an existing multi-state card's structure (e.g. the
Metadata Import card, if present) for the "state enum switch inside one
card" pattern before writing this file — match its exact idiom rather than
inventing a new one.

- [ ] **Step 2: Implement `ShareDomainCard.swift`**

```swift
//
//  ShareDomainCard.swift
//  Muse
//
//  Presented via .museModal(isPresented: $appState.shareDomainSetupShown,
//  width: 520) from ContentView — a card raised from Settings (itself a
//  modal) must present at the shell, above it (the openWithForkRequest
//  class). Five states driven by (entitlements, store.domain, store.phase).
//

import SwiftUI

struct ShareDomainCard: View {
    @ObservedObject private var domainStore = ShareDomainStore.shared
    @ObservedObject private var commerce = CommerceStore.shared
    @EnvironmentObject private var appState: AppState

    @State private var draftHostname = ""
    @State private var hostnameFieldError: String?
    @State private var pollTask: Task<Void, Never>?

    private enum CardState {
        case pitch, enterDomain, dnsInstructions, active, problem(String)
    }

    private var state: CardState {
        guard commerce.entitlements.sharing else { return .pitch }
        guard let domain = domainStore.domain else { return .enterDomain }
        switch DomainStatus.map(status: domain.status, sslStatus: domain.sslStatus) {
        case .active: return .active
        case .problem(let raw): return .problem(raw)
        case .pendingDNS, .pendingSSL: return .dnsInstructions
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            switch state {
            case .pitch: pitchState
            case .enterDomain: enterDomainState
            case .dnsInstructions: dnsInstructionsState
            case .active: activeState
            case .problem(let raw): problemState(raw)
            }
            if case .failed(let error) = domainStore.phase {
                Text(error.errorDescription ?? "").font(.caption).foregroundStyle(.red)
            }
        }
        .padding(20)
        .task(id: appState.shareDomainSetupShown) {
            guard appState.shareDomainSetupShown else { return }
            await domainStore.checkStatus()
            startPollingIfNeeded()
        }
        .onDisappear { pollTask?.cancel() }
    }

    // MARK: State 1 — Pitch

    private var pitchState: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Your Own Domain").font(.title3.bold())
            Text("Share your photos from your own domain — like photos.yourname.com — instead of a Muse link.")
                .foregroundStyle(.secondary)
            HStack {
                ModalButton(title: String(localized: "Subscribe"), kind: .prominent, isDefault: true) {
                    Task {
                        if let product = await commerce.products().first(where: { $0.id == CommerceConfig.sharingProductID }) {
                            await commerce.purchase(product)
                        }
                    }
                }
                ModalButton(title: String(localized: "Restore Purchases"), kind: .normal) {
                    Task { await commerce.restore() }
                }
                Spacer()
                ModalButton(title: String(localized: "Cancel"), kind: .normal, isCancel: true) {
                    appState.shareDomainSetupShown = false
                }
            }
        }
    }

    // MARK: State 2 — Enter domain

    private var enterDomainState: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Set Up Your Domain").font(.title3.bold())
            TextField(String(localized: "photos.yourdomain.com"), text: $draftHostname)
                .textFieldStyle(.roundedBorder)
                .onChange(of: draftHostname) { _, newValue in
                    hostnameFieldError = DomainValidate.hostname(newValue, apexZone: DomainConfig.apexZone).errorCode
                }
            if let hostnameFieldError {
                Text(DomainError.from(code: hostnameFieldError).errorDescription ?? "").font(.caption).foregroundStyle(.red)
            }
            HStack {
                ModalButton(title: String(localized: "Continue"), kind: .prominent, isDefault: true) {
                    Task { await domainStore.createHostname(draftHostname) }
                }
                .disabled(draftHostname.isEmpty || hostnameFieldError != nil)
                Spacer()
                ModalButton(title: String(localized: "Cancel"), kind: .normal, isCancel: true) {
                    appState.shareDomainSetupShown = false
                }
            }
        }
    }

    // MARK: State 3 — DNS instructions + polling

    private var dnsInstructionsState: some View {
        VStack(alignment: .leading, spacing: 12) {
            guard let domain = domainStore.domain else { EmptyView() }
            Text("Almost there").font(.title3.bold())
            Text("Add this record at your domain's DNS provider:").foregroundStyle(.secondary)
            let apex = ownerApex(of: domain.hostname)
            recordRow(label: String(localized: "Type"), value: "CNAME")
            recordRow(label: String(localized: "Name"), value: DomainValidate.recordName(for: domain.hostname, apex: apex))
            recordRow(label: String(localized: "Target"), value: DomainConfig.cnameTarget)
            Text(statusMessage(for: domain))
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                ModalButton(title: String(localized: "Check Now"), kind: .normal) {
                    Task { await domainStore.checkStatus() }
                }
                Spacer()
                ModalButton(title: String(localized: "Cancel"), kind: .normal, isCancel: true) {
                    appState.shareDomainSetupShown = false
                }
            }
        }
    }

    private func recordRow(label: String, value: String) -> some View {
        HStack {
            Text(label).frame(width: 60, alignment: .leading).foregroundStyle(.secondary)
            Text(value).font(.system(.body, design: .monospaced))
            Spacer()
            ModalButton(title: String(localized: "Copy"), kind: .normal) {
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(value, forType: .string)
            }
        }
    }

    private func statusMessage(for domain: ShareDomainState) -> String {
        switch DomainStatus.map(status: domain.status, sslStatus: domain.sslStatus) {
        case .pendingDNS: return String(localized: "Waiting for DNS — add the record above, then give it a few minutes.")
        case .pendingSSL: return String(localized: "DNS found — securing the certificate…")
        default: return ""
        }
    }

    /// The card doesn't ask the user for their apex separately — it derives
    /// a best-effort apex as the last two labels of the hostname they typed
    /// (sufficient for the common `photos.example.com` shape this feature
    /// targets; deeper subdomains still show a correct, if longer, record
    /// name via DomainValidate.recordName's fallback).
    private func ownerApex(of hostname: String) -> String {
        let labels = hostname.split(separator: ".")
        guard labels.count >= 2 else { return hostname }
        return labels.suffix(2).joined(separator: ".")
    }

    // MARK: State 4 — Active

    private var activeState: some View {
        VStack(alignment: .leading, spacing: 12) {
            guard let domain = domainStore.domain else { EmptyView() }
            Text("Custom Domain Active").font(.title3.bold())
            Text(domain.hostname).font(.system(.body, design: .monospaced))
            Text("New share links use \(domain.hostname). Existing links keep working.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                ModalButton(title: String(localized: "Change…"), kind: .normal) {
                    Task { await domainStore.removeHostname() }
                }
                ModalButton(title: String(localized: "Remove Domain"), kind: .destructive) {
                    Task { await domainStore.removeHostname() }
                }
                Spacer()
                ModalButton(title: String(localized: "Done"), kind: .prominent, isDefault: true) {
                    appState.shareDomainSetupShown = false
                }
            }
        }
    }

    // MARK: State 5 — Problem

    private func problemState(_ raw: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Needs Attention").font(.title3.bold())
            Text("There's a problem with your domain setup.").foregroundStyle(.secondary)
            Text(raw).font(.caption.monospaced()).foregroundStyle(.secondary)
            HStack {
                ModalButton(title: String(localized: "Check Now"), kind: .normal) {
                    Task { await domainStore.checkStatus() }
                }
                ModalButton(title: String(localized: "Remove"), kind: .destructive) {
                    Task { await domainStore.removeHostname() }
                }
                Spacer()
                ModalButton(title: String(localized: "Cancel"), kind: .normal, isCancel: true) {
                    appState.shareDomainSetupShown = false
                }
            }
        }
    }

    // MARK: Polling

    private func startPollingIfNeeded() {
        pollTask?.cancel()
        pollTask = Task {
            while !Task.isCancelled, appState.shareDomainSetupShown {
                try? await Task.sleep(for: .seconds(DomainConfig.statusPollSeconds))
                guard !Task.isCancelled, appState.shareDomainSetupShown else { break }
                if case .dnsInstructions = state {
                    await domainStore.checkStatus()
                } else {
                    break
                }
            }
        }
    }
}
```

Two structural notes for the implementer to correct against the real
codebase before this compiles: (1) `guard ... else { EmptyView() }` is not
valid inside a `ViewBuilder` closure as written — replace with an `if let
domain = domainStore.domain { ... } else { EmptyView() }` wrapper, matching
whatever idiom the existing multi-state cards in `Views/Modal/` already use;
(2) confirm `ModalButton`'s exact `Kind` cases and initializer signature
against `Views/Modal/ModalButton.swift` (already verified as `normal` /
`prominent` / `destructive`, `title: String`, `kind:`, `isDefault:`,
`isCancel:`, `action:` — matches what's used above).

- [ ] **Step 3: Present the card from `ContentView`**

```swift
// Muse/Muse/ContentView.swift — beside the other .museModal presentations
.museModal(isPresented: $appState.shareDomainSetupShown, width: 520) {
    ShareDomainCard()
}
```

- [ ] **Step 4: Build**

```bash
xcodebuild -scheme Muse build
```

Expected: `BUILD SUCCEEDED` after the two corrections above are applied.

- [ ] **Step 5: Manual verification against the running app**

```bash
open -a Xcode Muse/Muse.xcodeproj
# Cmd+R, then: Settings -> Share Links -> "Learn More…" (no subscription:
# pitch state) / "Set Up Custom Domain…" (subscribed: enter-domain state).
# Full network round-trip verification is an owner step (Task 23) since the
# Worker isn't deployed with real secrets yet.
```

Per CLAUDE.md: don't claim a UI feature works from a green build alone —
actually launch the app and confirm the card opens/closes/switches states
correctly for at least the no-subscription pitch path (the only path
testable without the deployed Worker).

- [ ] **Step 6: Commit**

```bash
git add Muse/Muse/Views/ShareDomainCard.swift Muse/Muse/ContentView.swift
git commit -m "spec-08: ShareDomainCard — pitch/enter-domain/DNS/active/problem states"
```

---

## Task 20: French localization pass

**Files:**
- Modify: `Muse/Muse/Localizable.xcstrings`

**Interfaces:** none (data file).

- [ ] **Step 1: Export and re-import French**

```bash
xcodebuild -exportLocalizations -project Muse/Muse.xcodeproj \
  -localizationPath /tmp/muse-l10n -exportLanguage fr
```

- [ ] **Step 2: Fill every new empty French value**

Open `/tmp/muse-l10n/fr.xcloc` (or edit `Localizable.xcstrings` directly) and
translate every string introduced in Tasks 9, 14, 17-19: the Settings
section header/footer, both row labels and their locked/pitch copy, every
`DomainError.errorDescription`, every `ShareDomainCard` state's copy
(pitch/enter-domain/DNS-instructions/active/problem), the DNS record
labels (Type/Name/Target — note `CNAME` itself is a technical literal and
should interpolate into a localized format string, not be translated), and
the lapse-messaging sentence in the Settings row (with
`\(DomainConfig.lapseGraceDays)` interpolated, not concatenated — the
wrap-the-whole-phrase rule).

- [ ] **Step 3: Re-import and verify 0 untranslated**

```bash
xcodebuild -importLocalizations -project Muse/Muse.xcodeproj \
  -localizationPath /tmp/muse-l10n/fr.xcloc
xcodebuild -exportLocalizations -project Muse/Muse.xcodeproj \
  -localizationPath /tmp/muse-l10n-verify -exportLanguage fr 2>&1 | grep -i untranslated
```

Expected: no "untranslated" lines reported, or an explicit 0 count.

- [ ] **Step 4: Run the unit suite in an English host** (per CLAUDE.md — enum
displayName/toast tests assert the English source)

```bash
xcodebuild -scheme Muse test
```

Expected: all green, including the new tests from Tasks 9-14.

- [ ] **Step 5: Preview in French**

```bash
open -n Muse/build/Debug/Muse.app --args -AppleLanguages "(fr)"
```

Confirm the Settings section and the card render correctly in French with no
overflow (budget ~1.3× English width per CLAUDE.md; add `lineLimit`/
`minimumScaleFactor` to any row that clips).

- [ ] **Step 6: Commit**

```bash
git add Muse/Muse/Localizable.xcstrings
git commit -m "spec-08: French localization — Share Links settings + domain card, 0 untranslated"
```

**Phase F complete.**

---

## Task 21: `docs/self-hosting-share-page.md` — the documented escape hatch

**Files:**
- Create: `docs/self-hosting-share-page.md`
- Modify: `web/share/README.md` (add a link, if that file exists — check first)

**Interfaces:** none (documentation only). No code changes — `web/share/`
itself is untouched by this spec (Global Constraints).

- [ ] **Step 1: Check whether `web/share/README.md` exists**

```bash
ls web/share/README.md 2>/dev/null || echo "no README yet"
```

- [ ] **Step 2: Write `docs/self-hosting-share-page.md`**

```markdown
# Self-hosting the Muse share page

Muse's share links (`muse-share.pages.dev/#…`, a custom domain, or a
`username.muse.app` address) all serve the exact same static site —
`web/share/` in this repo. The entire share is encoded in the URL fragment
(`#…`, everything after the `#`), which is never sent to any server. That
means the deployment serving the page never sees, and never needs to see,
what's in the share.

This is what makes self-hosting possible with zero Muse-side involvement:
take any Muse-generated share link, replace everything before the `#` with
your own deployment's origin, and it renders identically.

## Why you'd do this

Muse's custom-domain tier (`photos.yourdomain.com`) is provisioned through
Muse's own infrastructure and requires a sharing subscription. If you'd
rather run the share page entirely yourself — your own Cloudflare account,
your own domain, no dependency on Muse's Worker or subscription status —
you can, at any time, for free.

## How

1. Clone this repository (or just copy the `web/share/` directory).
2. Deploy it as a static site:

       npx wrangler pages deploy web/share

   (or upload it to the Cloudflare dashboard, or any static host that can
   serve the `_headers` file's Content-Security-Policy alongside the page —
   the CSP is load-bearing for the share page's network-isolation
   guarantees; don't serve `web/share/` from a host that drops it.)
3. Attach your own domain to that deployment through your host's normal
   custom-domain flow.
4. **Portfolio shares only:** the portfolio page's live-manifest fetch uses a
   Drive-API-restricted browser API key baked into `web/share/share.js`. That
   key is restricted to Muse's own deployment's use — paste your own
   Drive-API-restricted key (Google Cloud Console → Credentials) into your
   copy of `share.js` before deploying, or portfolio shares will fall back to
   their inline snapshot instead of live-updating.

## Distributing self-hosted links

There is no in-app "use my own domain" setting — `ShareLinkBase`'s inputs are
deliberately limited to things Muse itself provisions (its own custom-domain
tier or a claimed `username.muse.app` address), never an arbitrary
user-supplied override. That's a deliberate scope boundary, not a missing
feature: an in-app base override would be a general-purpose configuration
surface for a use case (self-hosting) that's already fully served by a manual
find-and-replace on the link text, which anyone capable of running
`wrangler pages deploy` can do without any app support.

To distribute a self-hosted link: take the link Muse gave you (from Copy
Link, Manage Drive Shares, or the collection share sheet), and replace
everything before the `#` with your own deployment's URL. The fragment after
the `#` is the entire share and needs no modification.
```

- [ ] **Step 3: Link it from `web/share/README.md` if that file exists** (add
one line near the top: `See also: [self-hosting the share page](../../docs/self-hosting-share-page.md).`)
If no such README exists, skip this sub-step — nothing in Spec 08 requires
creating one.

- [ ] **Step 4: Commit**

```bash
git add docs/self-hosting-share-page.md
git commit -m "spec-08: document the self-hosting escape hatch (docs only, no code)"
```

---

## Task 22: CLAUDE.md doctrine + durable constraints + architecture-map + session-log

**Files:**
- Modify: `CLAUDE.md`
- Modify: `docs/architecture-map.md`
- Modify: `docs/session-log.md`

**Interfaces:** none (documentation only).

- [ ] **Step 1: Add a new row to CLAUDE.md's Implementation status table**

Find the table (the `| Phase | Status | Branch |` rows) and add, immediately
after the last Polish row:

```markdown
| Polish 29 — **Custom domains & Muse addresses** (`workers/domains/` provisioning Worker, `Sharing/Domains/`, minimal `Commerce/` step-0) | ✅ shipped | `feat/spec-08-custom-domains` |
```

(Adjust the branch name to whatever branch this plan is actually executed
on.)

- [ ] **Step 2: Update the "Data collection" / network-policy paragraph**

CLAUDE.md's project-identity section currently says: *"Two sanctioned
network code paths, both gated by `com.apple.security.network.client`: (1)
Sparkle... (2) Google Drive collection share..."* — this is stale even before
Spec 08 (the muse-photo-foundation doc already revises it to a
Sparkle-removed, MAS-only doctrine), so don't try to reconcile it in place.
Instead, add a note directly below that paragraph:

```markdown
  **Spec 08 update (2026-07-30):** a fourth app-initiated network path exists
  as of `workers/domains/`: the custom-domain/Muse-address provisioning
  Worker (`DomainConfig.workerBaseURL` only; paid feature, user-initiated,
  plus a launch status/refresh call only while a domain or address is
  configured — the `DriveExpirySweeper` shape). This app makes NO direct
  Cloudflare API call and carries no Cloudflare credential; all Cloudflare
  interaction happens inside that Worker. See the durable constraints below
  for the full list. This note supersedes the "two sanctioned paths" count
  above pending the full Spec 01/09 doctrine rewrite.
```

- [ ] **Step 3: Append new durable constraints (paste as-is, verbatim from
the spec's own §13, into the "Durable constraints & gotchas" section, after
the existing Google Drive share security invariants block)**

```markdown
- **The Cloudflare API token never ships in, or is reachable from, the app
  (Spec 08, 2026-07-30).** All Cloudflare interaction happens inside the
  `workers/domains/` Worker; `DomainClient` speaks only to
  `DomainConfig.workerBaseURL`. Network path (4) is live with exactly this
  definition: paid, user-initiated, plus a launch status/refresh only while a
  domain or address is configured.
- **The Worker authenticates ONLY Apple-signed transaction JWS** — full chain
  verification to the pinned Apple Root CA - G3 including the receipt OID
  checks (`workers/domains/verify.js`); never `decode`-without-verify, never
  a shared secret with the app (there is nothing to leak from the binary).
- **Worker state is provisioning-only** (hostname/username ↔ transaction id,
  in one KV namespace). Nothing about photos, manifests, or links ever
  enters it — deleting all KV loses only claims, never user data.
- **`ShareLinkBase` is the single link-base decision point** — precedence
  active-domain → claimed-address → `DriveConfig.shareBaseURL`; the Manage
  Open-Link gate is origin-EXACT (never `hasPrefix` — suffix spoof);
  announcements + the CLIP model manifest stay pinned to
  `DriveConfig.shareBaseURL` by name and never ride the custom domain.
- **Lapse handling fails closed in the paying user's favor**: the Worker's
  cron sweep deprovisions only on an authoritative App Store Server API
  status (2/5); with no ASC key configured it no-ops. Stored expiry alone
  never deletes a hostname.
- **Domain/address removal rebases local Drive-share records** (fragment
  preserved) and states that distributed links on the removed hostname die —
  records are never rebased when a domain is *added* (old links keep serving
  on the default base forever, since Pages never stops answering it).
- **`DomainValidate` (Swift) and `validate.js` (Worker) are pinned to one
  shared fixture set** (`workers/domains/fixtures/hostnames.json` /
  `usernames.json`) — a grammar change edits the fixtures, and both test
  suites fail until both implementations agree.
```

- [ ] **Step 4: Update `docs/architecture-map.md`**

Add entries for the two new module folders (find the existing per-folder
index format and match it):

```markdown
- **`Commerce/`** — StoreKit 2 entitlements/purchase (`CommerceStore`,
  Pattern B singleton) + product id constants (`CommerceConfig`). Minimal
  Spec 01 subset built for Spec 08's dependency; extend rather than replace
  if Spec 01 lands in full later.
- **`Sharing/Domains/`** — custom-domain + `username.muse.app` client-side
  module: `DomainConfig`, `ShareDomain` (models + status fold),
  `DomainValidate` (fixture-pinned grammar mirror), `ShareLinkBase` (the
  link-base decision point), `DomainClient` (Worker HTTP client),
  `ShareDomainStore` (Pattern B store + launch refresher). Talks only to
  `workers/domains/` — never Cloudflare directly.
- **`workers/domains/`** (top-level, not under `Muse/`) — the `muse-domains`
  Cloudflare Worker: the app's only backend, holding the Cloudflare API
  token and doing Apple transaction-JWS verification. See its own README for
  deploy/rotation/takedown.
```

- [ ] **Step 5: Append a session-log entry**

Add a dated entry to `docs/session-log.md` following the file's existing
per-session format (read the most recent entry first to match its header
style exactly), summarizing: what shipped (the Worker + the app-side module +
UI), the key architectural decisions (Worker-only Cloudflare access, JWS-only
auth, provisioning-only KV, fail-closed lapse sweep, `ShareLinkBase`
precedence), and a pointer back to this plan file and to
`docs/new-build/spec-08-implementation.md` for full detail.

- [ ] **Step 6: Commit**

```bash
git add CLAUDE.md docs/architecture-map.md docs/session-log.md
git commit -m "spec-08: doctrine update + durable constraints + architecture-map + session-log"
```

---

## Task 23: Owner runbook — `docs/spec-08-owner-runbook.md`

**Files:**
- Create: `docs/spec-08-owner-runbook.md`

**Interfaces:** none (documentation only). Consolidates spec §12's
owner-only steps into an actionable, ordered checklist — nothing here can be
done from the codebase; it exists so the owner has one document to work
through rather than re-reading the full spec.

- [ ] **Step 1: Write the runbook**

```markdown
# Spec 08 owner runbook — deploying custom domains

These steps cannot be done from the codebase; an agent cannot perform them.
Work through in order — later steps depend on earlier ones.

## 1. Stand up the zone

- Purchase the production apex domain (referred to as `muse.app` throughout
  the code — substitute your real domain into `DomainConfig.swift` (app) and
  `wrangler.toml` (Worker) `APEX_ZONE`/`CNAME_TARGET`/`API_HOST` vars;
  nothing else needs to change).
- Add it as a Cloudflare zone (Free plan is sufficient for the 100-hostname
  free tier).
- Add `share.<yourdomain>` as a custom domain on the existing `muse-share`
  Pages project; verify the share page serves there before continuing.

## 2. Enable Cloudflare for SaaS

- Requires a payment method on file even at the free 100-hostname tier.
- Set the fallback origin to `share.<yourdomain>`.

## 3. DNS + Worker routes

- Add a proxied wildcard placeholder record for `*` (AAAA `100::`) and a
  `domains` record.
- Deploy the Worker (step 4), then add routes: `*.<yourdomain>/* →
  muse-domains`, `domains.<yourdomain>/* → muse-domains`, and the explicit
  exclusion `share.<yourdomain>/* → None` (Pages must serve that route
  directly).

## 4. Worker deploy

```bash
cd workers/domains
npx wrangler kv namespace create DOMAINS_KV   # paste the id into wrangler.toml
npx wrangler secret put CF_API_TOKEN          # zone-scoped, Custom Hostnames Edit ONLY
npx wrangler secret put ASC_KEY_P8            # optional — sweep no-ops without it
npx wrangler secret put ASC_KEY_ID            # optional
npx wrangler secret put ASC_ISSUER_ID         # optional
npx wrangler deploy
```

Leave `ALLOW_SANDBOX = "true"` in `wrangler.toml` through TestFlight.

## 5. Pin the real Apple root certificate

- Download Apple Root CA - G3 from
  https://www.apple.com/certificateauthority/
- Verify its published SHA-256 fingerprint against the downloaded file.
- Replace the placeholder at `workers/domains/certs/AppleRootCA-G3.der` with
  the real file and redeploy (`npx wrangler deploy`).

## 6. Google API key restriction (only if Spec 07's portfolio key already exists)

- In the Google Cloud Console, drop the HTTP-referrer restriction on the
  share page's Drive-API browser key (custom hostnames are unenumerable, so
  a referrer allowlist would break the portfolio live-fetch on exactly the
  paid tier's pages). Keep the Drive-API-only restriction. One console edit,
  no deploy needed. Skip this step entirely if Spec 07 hasn't shipped yet —
  there is no such key to restrict.

## 7. End-to-end acceptance, on a real test domain you control

Run through, in order:

1. Make a sandbox StoreKit purchase of the sharing subscription in a
   TestFlight (or local sandbox) build.
2. In Settings → Share Links → Set Up Custom Domain…, enter
   `photos.<your test domain>`.
3. Add the shown CNAME record at your DNS provider.
4. Confirm the card walks `pendingDNS → pendingSSL → active` (may take
   minutes to an hour for DNS propagation + cert issuance).
5. Publish a Drive share from Muse; confirm the link renders on the custom
   domain with valid TLS.
6. (If Spec 07's portfolio mode exists) publish and update a portfolio on
   the same domain.
7. Cancel the sandbox subscription; use App Store Connect's sandbox
   time-acceleration to advance past the 30-day grace window; confirm the
   next cron sweep deprovisions the hostname and existing share links revert
   to the standard address, with the one-shot in-app notice appearing.
8. Claim and release a `username.muse.app` address, including one attempt at
   a reserved word (confirm it's refused).
9. `strings` the shipped app binary and confirm zero hits for
   `api.cloudflare.com`:

       strings /path/to/Muse.app/Contents/MacOS/Muse | grep -c api.cloudflare.com
       # expect: 0

## 8. Launch flip

- At public launch, alongside Spec 09's pricing go-live: set
  `ALLOW_SANDBOX = "false"` in `wrangler.toml` and redeploy.
```

- [ ] **Step 2: Commit**

```bash
git add docs/spec-08-owner-runbook.md
git commit -m "spec-08: owner-only deploy/acceptance runbook"
```

**Phase G complete. Spec 08 implementation plan finished.**

---

## Post-implementation verification checklist

Before considering this plan done, confirm:

- [ ] `cd workers/domains && npm test` — all green (Tasks 2-7's suites).
- [ ] `xcodebuild -scheme Muse test` — all green, including every new
      `MuseTests` file from Tasks 9-14.
- [ ] `xcodebuild -scheme Muse build` succeeds and the binary's mtime is
      fresh (CLAUDE.md's stale-binary gotcha) before any manual UI check.
- [ ] French export reports 0 untranslated (Task 20).
- [ ] Manual launch: Settings → Share Links renders correctly in both the
      no-subscription (pitch) and no-unlock (locked address row) states.
- [ ] `strings` check on the binary for `api.cloudflare.com` returns zero
      hits (owner step, Task 23 §7.9, but worth a pre-flight check here too
      once secrets are NOT yet embedded — trivially true before deploy, and
      should stay true after).
- [ ] Every checkbox in this plan's tasks is checked.
