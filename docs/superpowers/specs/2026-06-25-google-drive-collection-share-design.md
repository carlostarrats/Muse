# Google Drive Collection Share — design

**Date:** 2026-06-25
**Status:** draft, pending owner review
**Branch (planned):** `feat/drive-collection-share`

## Context

Backend #2 of the two-backend "share a collection" capability (backend #1,
the plain iCloud helper, shipped on `feat/icloud-collection-share`). This is
the **automated, branded, self-expiring web-page share** — the "magic" path
and the client's (Martin Bruneau / The Project) actual need: their world is
Google Drive, never Apple Cloud.

The flow and need come from the `Desktop/Martin` email thread; the look comes
from the two mockups (`example intro page.png`, `example web page.png`). This
spec is built directly from those — it does not re-derive them.

### The flow (from the email)

In a collection → **"Share Drive Link"** → fill a small form (intro line ·
"Sent by" label · name · a date · an expiry) → **Publish**. Muse:
1. signs the user into Google once (`drive.file`, one approval),
2. auto-creates a Drive folder inside a top-level `Muse` folder,
3. uploads the collection's images,
4. generates a print-quality PDF locally and uploads it too,
5. flips the folder to link-viewable,
6. hands back a single web-page URL.

The recipient gets **only the web page** — no files, can't delete anything.
Self-managing: the page **soft-expires** on the date (client-side), and Muse
**hard-deletes** the Drive folder at expiry so nothing accumulates.

### The page (from the mockups)

One **static file**, personalized entirely by the URL (no backend, no server
state). Two states of the same page:
- **Intro/landing** (`example intro page.png`): signature top-left — intro
  line, then "Sent by" + name — on a light-grey field.
- **Gallery** (`example web page.png`): header bar — left: title +
  `Expires <date>` (small grey) + a **Save** pill (downloads the PDF); right:
  `Sent by <name>`. Below: a responsive portrait **thumbnail grid**.

Images render from Drive's **public thumbnail URLs**
(`https://drive.google.com/thumbnail?id=<id>&sz=w1600`) at a high-res size so
they're crisp, not blurry. The full manifest (text fields, expiry, ordered
image IDs, PDF id) is **base64-encoded into the URL** and read client-side —
no API key, no manifest fetch, nothing server-side. Stays in Cloudflare's free
tier and scales to ~zero cost.

## Identity / privacy change (load-bearing, owner-accepted)

This is the **first network egress beyond Sparkle**. It is an explicit,
**opt-in, user-initiated** action (the user signs in and presses Publish), but
it changes a core positioning line: from "nothing leaves your Mac" to
**"nothing leaves your Mac *unless you publish a collection*."** Consequences,
all to be reflected before ship:
- The CLAUDE.md "No network calls" rule gains a single, scoped exception:
  Google Drive publish/manage, gated behind explicit user action.
- The `com.apple.security.network.client` entitlement (already present for
  Sparkle) now also covers Drive. No new entitlement.
- Privacy nutrition label / privacy policy updated: when the user publishes,
  the selected images + the form text are uploaded to **the user's own Google
  Drive** under their Google account. Muse the developer still receives no
  data; the bytes go user → their Drive.
- This is the only feature permitted to touch the network outside Sparkle.

## Prerequisites (owner setup, not code)

These gate runtime, not the build. The code compiles and is unit-tested
without them; sign-in won't function until they exist.
1. A **Google Cloud OAuth client** (application type: iOS/macOS) for the
   bundle id `com.tarrats.Muse`, scope `drive.file`. Client ID embedded in the
   app (public — no secret, PKCE).
2. A **custom domain on Cloudflare** for the share page + the OAuth consent
   screen homepage/redirect (verification requires a real domain, not
   `*.pages.dev`).
3. A **published privacy policy** at that domain (Google verification + App
   privacy requirements).
4. Google **app verification** for `drive.file` (lightweight, non-CASA). Until
   verified: 100-user cap + an "unverified app" screen; after: unlimited.

## Architecture

Two deliverables that share one contract (the URL/manifest format):

### A. macOS app (Swift)

```
Sharing/Drive/
  GoogleOAuth.swift        OAuth 2.0 Authorization Code + PKCE via
                           ASWebAuthenticationSession; no client secret.
  TokenStore.swift         Keychain-backed access/refresh token store
                           (device-only, not iCloud-synced).
  DriveClient.swift        Minimal Drive REST client over URLSession:
                           ensureMuseRoot, createFolder, uploadFile,
                           setAnyoneReader, deleteFolder, listMuseShares.
  DriveShareManifest.swift Pure value type → base64url payload baked into the
                           page URL. Unit-tested.
  DriveShareService.swift  @MainActor orchestrator: form → ensure root →
                           create folder → upload images → make+upload PDF →
                           set permission → assemble URL. Phase enum.
  DriveShareStore.swift    JSON record store (App Support, NOT Drive/SQLite):
                           folderID, pageURL, expiry, itemCount, createdAt.
  DriveExpirySweeper.swift On launch + a coarse timer, hard-delete folders
                           past expiry via the stored token. Pure decision
                           (which records are expired) is unit-tested.
Views/
  DriveShareForm.swift     The publish form (3 text fields + date + expiry);
                           remembers name/message in settings.
  DriveSharePublishView.swift  progress (sign-in → upload N/M → done) + the
                           finished link (copy / system share sheet).
  ManageDriveSharesView.swift  View-menu "Manage Drive Shares…" — list + open
                           link + Delete-now (unpublish), styled like InfoSheet.
```

### B. Static share page (`web/share/`)

```
web/share/
  index.html   the page shell (intro + gallery states)
  share.js     parse+validate base64 manifest from URL → render; soft-expiry;
               Save button → PDF link. All text via textContent (no innerHTML).
  share.css    matches the mockups (light-grey field, top-left signature bar,
               responsive portrait grid).
  _headers     Cloudflare headers: strict CSP, X-Content-Type-Options, etc.
  README.md    how to deploy to Cloudflare Pages + set the custom domain.
```

### Drive folder structure (tidy)

```
My Drive /
  Muse /                         ← single top-level folder (created once, reused)
    <Collection> — <YYYY-MM-DD> / ← one folder per share (de-duped/refreshed)
      image-001.jpg …
      <Collection>.pdf            ← print-quality PDF (Save button target)
```

`ensureMuseRoot` finds-or-creates the `Muse` folder (drive.file sees only
folders Muse itself created, so it tracks the root's id in `DriveShareStore`).

### Data flow (publish)

1. Form → `DriveShareService.publish(form, urls)`.
2. Ensure signed in (`GoogleOAuth.validAccessToken()` — refresh if needed).
3. `ensureMuseRoot()` → root folder id.
4. `createFolder(name, parent: root)` → share folder id.
5. Upload each image (`uploadFile`, multipart) in grid order → file ids.
6. `CollectionPDFExporter.makePDF(...)` from **originals** (print quality) →
   `uploadFile(pdf)` → pdf id.
7. `setAnyoneReader(folderId)` (covers children) → link-viewable.
8. Build `DriveShareManifest{ intro, label, name, date, expiry, imageIds[],
   pdfId }` → base64url → `https://<domain>/s#<payload>` (fragment, so the
   manifest never hits Cloudflare logs/servers).
9. Persist a `DriveShareStore` record (folderId, url, expiry, count).
10. Show the link (copy / share sheet).

### Data flow (page render)

1. `share.js` reads `location.hash`, base64url-decodes → manifest.
2. Validate: every image/pdf id matches `^[A-Za-z0-9_-]{20,}$`; expiry is a
   date; reject otherwise (show a neutral "unavailable").
3. If `now > expiry` → show **expired** state (no grid, no Save).
4. Else render signature (via `textContent`), the grid (`<img>` →
   `…/thumbnail?id=<id>&sz=w1600`), and the Save pill → the PDF
   (`…/uc?export=download&id=<pdfId>`).

Putting the payload in the URL **fragment** (`#…`, not `?…`) means it is never
sent to Cloudflare — the personalization stays purely in the browser.

## Expiry (Muse-local, no backend)

`DriveExpirySweeper` runs on launch and on a coarse in-app timer. For each
`DriveShareStore` record with `expiry < now`: `DriveClient.deleteFolder` (the
folder Muse created — `drive.file` covers it), then drop the record. If the
user never reopens Muse the folder lingers, but the page already soft-expired,
so the recipient sees "expired" regardless. Deleting the folder also removes
the PDF + images, so any still-open page degrades to "unavailable" — consistent.

## Security (must adhere to best practices)

- **Least privilege:** `drive.file` only. Muse can touch *only* the files/
  folders it created — never the user's other Drive content. No `drive`,
  no `drive.readonly`.
- **OAuth:** Authorization Code + **PKCE** (S256), `state` (CSRF) validated,
  `ASWebAuthenticationSession` with `prefersEphemeralWebBrowserSession`
  consideration, custom-scheme redirect. **No client secret in the app**
  (public client). Request the minimal scope; incremental.
- **Token storage:** access + refresh tokens in **Keychain** with
  `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` (never iCloud-synced).
  Never in UserDefaults, never logged. Refresh tokens never leave Keychain.
- **Sign-out:** revoke the token at Google's revocation endpoint and purge
  Keychain.
- **Transport:** TLS only; App Transport Security with no exceptions; pin to
  `https://oauth2.googleapis.com` / `https://www.googleapis.com` /
  `https://accounts.google.com` hosts. Reject non-HTTPS.
- **No secrets in the web page:** the URL-fragment manifest design means the
  page needs no API key and no token. The only data in the page is what the
  user chose to publish (public-by-intent image ids + display text).
- **Web page XSS hardening:** every manifest string rendered via `textContent`
  (never `innerHTML`); image/pdf ids regex-validated before use; the Save/href
  targets validated to the `drive.google.com` host; a strict **CSP**
  (`default-src 'none'; img-src https://drive.google.com https://*.googleusercontent.com; script-src 'self'; style-src 'self'`),
  `X-Content-Type-Options: nosniff`, `Referrer-Policy: no-referrer`.
- **Link exposure:** anyone with the link can view the folder (intended). The
  share URL is unguessable (random Drive ids). Document that "anyone with the
  link can view" — same model as every link-share.
- **Input from Drive:** treat all Drive API responses as untrusted; validate
  ids/shapes before use. Handle token-expiry/revoked/quota errors explicitly.
- **No background network:** Drive calls happen ONLY inside an explicit
  publish/manage/expiry-sweep action — never speculative. The sweep only runs
  if there are stored unexpired-past records AND a valid token; otherwise no
  network at all.

## PDF (print quality)

Generated **locally from the original files** via the existing
`CollectionPDFExporter` (ImageIO downsample from originals — sharp, print-
ready, NOT the web thumbnails), at the default 11×14 (the existing paper-size
choice can be surfaced later). Uploaded into the share's Drive folder; the
page's **Save** pill links to it for download. Deleted with the folder at
expiry.

## UI surfaces

- **"Share Drive Link"** in the existing `ShareCollectionButton` menu (beside
  "Share iCloud Link").
- **`DriveShareForm`** sheet: intro line · "Sent by" label · name · date ·
  expiry; name/message remembered between shares.
- **`DriveSharePublishView`** sheet: sign-in (first time) → progress → the
  finished link (copy / share sheet).
- **"Manage Drive Shares…"** in the **View menu** (beside "Manage iCloud
  Shares…"): list of live shares (name · count · expiry), open link, and
  **Delete now** (unpublish = delete the folder immediately). Styled like
  `InfoSheet`, matching the iCloud manage modal.

## Components & isolation

| Unit | Responsibility | Testable as |
|---|---|---|
| `DriveShareManifest` | model ↔ base64url payload; validation | pure unit |
| `DriveExpiryDecision` | which records are expired now | pure unit |
| `DriveSharePaths`/naming | folder name (collection + date), de-dup | pure unit |
| `TokenStore` | Keychain read/write/delete | logic unit (mock keychain) |
| `GoogleOAuth` | PKCE/token exchange/refresh | integration |
| `DriveClient` | REST calls | integration |
| `DriveShareService` | orchestration | integration |
| `share.js` parse/validate/expiry | pure functions | JS unit (fixtures) |
| SwiftUI sheets / page render | UI | not unit-tested (repo convention) |

## Error handling

- **Not signed in / sign-in cancelled:** form stays; clear message; no folder
  created.
- **Token refresh fails / revoked:** prompt re-sign-in; abort cleanly.
- **Upload fails partway:** delete the partial folder (no orphan), surface a
  retryable error.
- **Quota exceeded (15GB free Drive):** explicit message ("Google Drive is
  full"), delete partial folder.
- **Offline:** detected up front; "No internet connection"; nothing created.
- **Manifest too large for URL** (very large collection): cap the share at a
  sensible image count with a clear notice (log what was dropped — no silent
  truncation), or fall back to a manifest.json in the folder (deferred; note
  the limit for v1).
- **Page: malformed/oversized manifest, bad ids, past expiry:** neutral
  "unavailable"/"expired" state, never an error dump, never script execution.

## Testing

- Pure units (`DriveShareManifest` round-trip + validation, `DriveExpiry`,
  naming, `TokenStore` against a mock) in `MuseTests`.
- `share.js` pure functions (decode, validate, expiry, id-regex) tested with a
  tiny JS harness + fixtures under `web/share/`.
- OAuth + Drive REST + the publish orchestration are **integration-only**,
  verified manually against a real Google account once the OAuth client exists
  (mirrors the iCloud "integration-only" stance). A manual checklist is part
  of the plan's final task.
- Full `MuseTests` stays green.

## Localization

Every new user-facing string localized (`String(localized:)`; the app ships
French). The **web page** is separate from the app's xcstrings — its few
strings ("Sent by", "Expires", "Save", "This share has expired") come from the
manifest where possible (so "Sent by"/label is whatever the user typed) or are
localized in `share.js` by a `lang` param if needed (deferred; v1 page strings
follow the manifest + English fallbacks).

## Out of scope (this spec)

- Email/Gmail send integration (the page link is shared however the user
  likes — Mail, Messages, etc.).
- A branded gallery that re-hosts bytes on Muse infrastructure (the bytes stay
  in the user's Drive — that's the whole point).
- Live re-sync of a published collection when the local collection changes (a
  share is a snapshot; re-publish to update).
- Per-recipient permissions/tracking (it's a public link by design).
- manifest.json-in-folder fallback for very large collections (note the URL
  cap; revisit if needed).

## Open questions

None blocking. Two owner setup items are tracked under **Prerequisites**
(OAuth client + domain/privacy-policy); they gate runtime, not the build.
