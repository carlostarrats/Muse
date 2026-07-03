# Muse — Drive share page

A single static page that renders a shared Muse collection. It is **stateless**:
the entire payload (signature text, expiry, ordered Drive image ids, per-image
filenames, optional PDF id) is encoded into the URL **fragment**
(`https://<domain>/#<payload>`), so it never reaches the server. Images load from Drive's
public thumbnail endpoint; the page holds no secrets and no API key.

The fragment is base64url of either the raw JSON manifest **or** (when smaller)
`[0x01 marker][raw-DEFLATE of the JSON]` — the app picks whichever is shorter, so
adding filenames doesn't bloat the link. DEFLATE is raw RFC-1951 (Swift
`COMPRESSION_ZLIB` ⇄ fflate `inflateSync`, verified cross-language). Legacy
uncompressed links (first byte `{`) still decode. **Security: the fragment is
unsigned + attacker-suppliable, so `decodeManifest` caps the inflate output
(`MAX_INFLATED`) — a decompression bomb is truncated to garbage and rejected,
never an unbounded allocation. Don't remove that cap.** Filenames (`f`) are
optional and must match the image count 1:1 or they're dropped.

```
index.html         shell (intro + gallery + lightbox + expired/unavailable)
share.js           decode (+inflate) + validate manifest, soft-expiry, render (textContent only)
share.css          matches the Muse mockups
fflate.module.js   vendored DEFLATE decompressor (MIT; pure-compute, no network) — see fflate.LICENSE.txt
_headers           Cloudflare strict CSP + hardening
share.test.mjs     pure-logic unit tests (incl. compression + bomb guard) — run: node share.test.mjs
```

## Deploy to Cloudflare Pages

1. Create a Pages project from this `web/share/` directory (or upload it).
2. Add a **custom domain** (e.g. `share.yourdomain.com`). The page is served at
   that domain's root; Muse builds links as `https://<domain>/#<payload>`
   (`DriveConfig.shareBaseURL` is the bare root — no `/s` route needed). The
   `_headers` file applies the CSP automatically.
3. Verify: open `https://<domain>/#<payload>` with a real manifest — the
   signature renders, the grid fills from Drive, and **Save PDF** opens the
   browser print dialog (the recipient picks the paper size and prints to PDF).

## Google OAuth client (one-time, owner)

1. Google Cloud Console → APIs & Services → enable the **Drive API**.
2. Create an **OAuth client ID**, application type **iOS** (works for macOS
   custom-scheme redirect), bundle id `com.tarrats.Muse`.
3. OAuth consent screen: app name, your **custom domain** as the homepage, a
   **published privacy policy** URL, scope **`.../auth/drive.file`** only.
4. In the app, fill:
   - `DriveConfig.clientID` → your `NNN-xxxx.apps.googleusercontent.com`
   - `DriveConfig.shareBaseURL` → `https://<domain>` (the root, no path)
   - `Info.plist` `CFBundleURLSchemes` → the **reverse client id**
     `com.googleusercontent.apps.NNN-xxxx`
5. Submit for **verification** (drive.file is non-sensitive → lightweight, no
   CASA audit). Until verified: 100-user cap + an "unverified app" screen; after:
   unlimited, clean consent screen.

## Privacy note

Publishing uploads the selected images + the form text to **the user's own
Google Drive** under their Google account. Muse (the developer) receives no
data. This is the only Muse network path besides Sparkle updates, and it only
runs when the user explicitly presses Publish / Manage / signs in.
