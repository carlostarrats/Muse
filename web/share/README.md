# Muse — Drive share page

A single static page that renders a shared Muse collection. New links are short:
the fragment is only `#r:<manifest.json Drive id>`. The manifest contains the
signature text, expiry, ordered image ids, and filenames. A separate public
`layout.json` contains only the sender's Grid/Editorial default, so Manage Shares
can change that default without changing the link or republishing images.

Both JSON files and all images are children of the share's Drive folder. Deleting
the link or expiring it deletes that folder, including both link targets. The page
holds no OAuth token, API key, secret, or server-side share data. A bounded,
credential-free Pages Function bridges the anyone-readable Drive JSON to the
browser without storing it.

Older links remain supported. Their fragment is base64url of either raw JSON or
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
../../functions/drive-json/[id].js  capped, credential-free public-Drive JSON bridge
```

## Deploy to Cloudflare Pages

1. Create a Pages project using `web/share/` as the static assets directory.
   Deploy from the repository root with Wrangler so the root `functions/`
   directory is compiled: `wrangler pages deploy web/share --project-name=muse-share`.
2. Add a **custom domain** (e.g. `share.yourdomain.com`). The page is served at
   that domain's root; Muse builds links as `https://<domain>/#r:<Drive-id>`
   (`DriveConfig.shareBaseURL` is the bare root — no `/s` route needed). The
   `_headers` file applies the CSP automatically.
3. Verify: open a newly published link with a real manifest — the
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
data. This is one of Muse's sanctioned network paths, and its app-side requests
run only when the user explicitly presses Publish / Manage / signs in. The
recipient page's bridge reads only the anyone-readable JSON file named by the
link, caps it at 512 KB, stores nothing, and uses no credential.
