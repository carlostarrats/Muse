# Spec 07 — Share Page Expansion & Social Export

*Read with `muse-photo-foundation.md` §10. Depends on Spec 04 (exports must render through edit stacks — the Spec 01 choke point makes this automatic).*

## Context: the existing system (do not break)
Drive share is the most differentiated feature in the app: manifest (signature, expiry, Drive image ids, filenames, optional PDF id) is base64url/DEFLATE'd into the **URL fragment** — never touches a server. Static page on Cloudflare Pages; images from the user's own Drive (`drive.file`, OAuth PKCE); EXIF/GPS stripped on upload; decompression-bomb cap (`MAX_INFLATED` — never remove); bidi sanitization; strict CSP; recipient PDF = printed page. Zero infra, zero marginal cost, developer receives no data.

## Decisions in force (do not revisit)
- **Google Drive ONLY.** No iCloud (explored; too complicated), no Dropbox (more friction than Google). Improve the Google on-ramp instead: smooth in-app sign-in/sign-up guidance.
- **No download-originals feature** — the owner's Drive already gates that; explain the option in UI copy, don't build it.
- **No server-side share state, ever.**

## In scope

### 1. Share page layout options
Grid (today) / **contact sheet** / **single-column essay**. Chosen at publish time, encoded in the manifest, rendered by the static page. Keep the page dependency-free and CSP-strict; extend `share.js` tests.

### 2. Portfolio mode
A persistent share: non-expiring, **updatable in place** (re-publish replaces the Drive folder contents + the user re-shares the same link, or link versioning within the fragment — spec the cleanest zero-server approach). Reads as a small site: title, intro, curated set, chosen layout. This is Savee's $15/MONTH tier feature — here it's part of the upsell tier (pricing per foundation §11).

### 3. Social export presets (in the export flow, also usable standalone)
- **Aspect-mismatch UX (DECIDED):** interactive crop step INSIDE the export flow — target frame shown, user positions it, nothing persisted unless explicitly saved ("temporary social version"). Never force a master crop; never auto-accumulate versions.
- **Fit modes per preset:** Crop (interactive) / **Matte** (white/black — the IG "no crop" border look; desktop-underserved, standing Adobe feature request) / Blur-extend.
- All: sRGB, baked orientation, JPEG; output sharpening for downscale; metadata stripped by default EXCEPT photography platforms (toggle):

| Preset | Dims | Quality | Sharpen | Notes |
|---|---|---|---|---|
| IG Feed Portrait (default) | 1080×1350 (4:5) | q88, <1MB target | Standard | 4:5 correct post-2025 grid change; keep key content center-safe (grid previews crop 3:4) |
| IG Grid-optimized | 1080×1440 (3:4) | q88 | Standard | Warn: feed crops to 4:5 |
| IG Square / Landscape | 1080×1080 / 1080×566 | q88 | Standard | |
| IG/Threads Story-Reel | 1080×1920 | q88 | Standard | 250px top/bottom safe zones |
| IG Carousel | 1080×1350 uniform | q88 | Standard | First slide locks ratio — enforce |
| Threads | 1080×1350 | q88 | Standard | |
| X | ≤4096 long edge | q90 | Light | **Target X's no-recompress rule** (≤4096², <5MB, RGB, no EXIF orientation, bytes < W×H) — original bytes served untouched; verify in tests; a marketing line |
| Facebook | 2048 long edge | q85, <1MB | Standard | |
| Pinterest | 1000×1500 (2:3) | q90 | Standard | |
| Flickr / 500px | original size | q95 | None | EXIF toggle default ON |
| Glass | 2560–4096 long edge | q92 | Light | Glass WANTS EXIF (gear display) — ON by default |

IG note baked into the pipeline: IG recompresses everything (~q70–75 at 1080w; PNG/HEIC converted, PNG aggressively) — always deliver finished sRGB JPEG at exactly 1080w, 300–800KB, so its encoder has nothing to do.

### 4. Google on-ramp polish
First-publish flow: clear explanation ("photos upload to YOUR Google Drive; we never see them"), guided sign-in, graceful unverified-scope messaging.

## Out of scope
Custom domains + username subdomains + provisioning Worker (Spec 08). Any new share backend. Any server state. Video export presets (photo-first for now).

## Binding decisions
#19 Google-only, no download-originals, no server state · #21 social export exactly as above · #5-path exports render through edit stacks (Spec 01 choke point).

## Acceptance
- All three layouts render from fragment-only data; existing links keep working (legacy manifest decode preserved); bomb cap intact; share.test.mjs extended and green.
- Portfolio link survives a content update without changing URL (or per spec'd versioning), still zero server state.
- Export of an edited RAW goes out WITH edits applied (choke-point verified).
- X preset output verifiably survives upload without recompression (byte-compare in a manual test protocol).
- Matte export matches target dims exactly; carousel enforces uniform ratio; temporary crop persists nothing.
