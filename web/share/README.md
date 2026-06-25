# Muse — Drive share page

A single static page that renders a shared Muse collection. It is **stateless**:
the entire payload (signature text, expiry, ordered Drive image ids, optional
PDF id) is base64url-encoded into the URL **fragment** (`…/s#<payload>`), so it
never reaches the server. Images load from Drive's public thumbnail endpoint;
the page holds no secrets and no API key.

```
index.html   shell (intro + gallery + expired/unavailable states)
share.js     decode + validate manifest, soft-expiry, render (textContent only)
share.css    matches the Muse mockups
_headers     Cloudflare strict CSP + hardening
share.test.mjs   pure-logic unit tests — run: node share.test.mjs
```

## Deploy to Cloudflare Pages

1. Create a Pages project from this `web/share/` directory (or upload it).
2. Add a **custom domain** (e.g. `share.yourdomain.com`). The page is served at
   that domain's root; Muse builds links as `https://<domain>/s#<payload>` — set
   the Pages route so `/s` serves `index.html` (a `_redirects` line
   `/s /index.html 200`, or name the file `s.html`). The `_headers` file applies
   the CSP automatically.
3. Verify: open `https://<domain>/s#<payload>` with a real manifest — the
   signature renders, the grid fills from Drive, **Save** downloads the PDF.

## Google OAuth client (one-time, owner)

1. Google Cloud Console → APIs & Services → enable the **Drive API**.
2. Create an **OAuth client ID**, application type **iOS** (works for macOS
   custom-scheme redirect), bundle id `com.tarrats.Muse`.
3. OAuth consent screen: app name, your **custom domain** as the homepage, a
   **published privacy policy** URL, scope **`.../auth/drive.file`** only.
4. In the app, fill:
   - `DriveConfig.clientID` → your `NNN-xxxx.apps.googleusercontent.com`
   - `DriveConfig.shareBaseURL` → `https://<domain>/s`
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
