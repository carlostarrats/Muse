# Spec 09 — Launch Readiness (Pricing, Trial, Performance Validation, Site)

*Read with `muse-photo-foundation.md` §1, §9, §11. Last spec; mostly decisions + validation, light on code. Prereq: Specs 01–07 shipped (08 can trail).*

## 1. Pricing (OPEN — decide here, with real features in hand; structure fixed by MAS — decision #33)
- **Hard constraint: nothing over $100.** Carlos wants affordable; open to cheaper-yearly AND/OR just-own-it.
- **Structure (forced by Mac App Store — no paid-upfront-with-trial exists):** free download (trial vehicle, NOT a free tier) → **one-time non-consumable IAP unlock** · **sharing tier as auto-renewable subscription IAP**.
- Current leaning (revisit against the shipped feature set): **~$49 unlock** · **sharing tier ~$15–20/YEAR** (the one legitimately recurring piece — vs Savee's $15/MONTH) · `username.muse.app` included with the unlock.
- Fee: 15% via Small Business Program (enrolled in Spec 01). Anchors: Eagle $34.95 one-time (400k users) · Atlas $39 · Darkroom $99.99 lifetime · Nitro $99.99 · Photomator $79.99–119.99 lifetime · Excire $249 (no editing) · Photo Mechanic $299+ ("well out of hobbyist territory" per its own fans). One-time-unlock is the photo-category norm; keep the app itself subscription-free — only the domain/portfolio service recurs.
- Gifting: Apple promo codes (100 per IAP per version).

## 2. Trial mechanics (shape OPEN — pick one, implement on the Spec 01 gate)
Options: 14-day full-featured (simplest, standard) · capacity-limited (e.g. 1,000 photos) · feature-limited (library free forever, editing/sharing paid — a real freemium; NOT chosen so far). Recommendation: 14-day full trial, generous re-trial on major versions. Must be MAS-compliant (locally enforced on the free download; unlock via IAP).

## 3. Performance validation (against foundation §9 envelope)
- Reference machine M1 Air 8GB, 10k–50k library: cold start, grid scroll FPS, token search <100ms, semantic search <300ms perceived, slider-to-render <50ms, compare-mode load — all against the Spec 01 baseline harness; regressions block launch.
- Edge validation: a synthetic 500k library — indexing completes (hours OK, overnight OK), no crash/beachball/corruption, search degrades gracefully (~0.5s OK), memory stays bounded (no RAM-residency assumptions — verify embeddings path). Earns the honest "tested with 500k+ libraries" line.
- Thermal/battery: 100k analyze on battery throttles; on power completes overnight; fanless-Air behavior acceptable.

## 4. Site & positioning copy
- Rewrite around: **photo library for people who take photography seriously — local, one-time, no catalog, no cloud, no subscription.**
- Lead with the no-catalog story (files stay where they are; nothing imported; metadata beside the photo; moving files doesn't orphan them).
- Secondary: works alongside whatever you already use (XMP in/out); the share link that needs no account from recipients; the learning readouts.
- NO Lightroom references in copy (market-sizing only). Plain vocabulary. Screenshots: real library, real photos, the readouts visible.
- Update `web/share` about/terms/privacy for the paid app + announcements + domains paths.

## 5. Validation pass (should ALREADY be running in parallel since phase 1–2 — confirm before launch)
- ~10 real photographers (X100/GR-class shooters) using **TestFlight builds** on their own libraries. Watch: does no-catalog land? Do they notice color search/readouts? Is "I'd pay $49" a real sentence? The learning-readout bets specifically want reality-checking (foundation §16 open question).
- Cheap channels when ready: r/macapps, Product Hunt, "best photo organizer for Mac" roundup authors (emailable individuals), X100/GR YouTube + subreddits (workflow-video audience).

## 6. Launch checklist
- App Store submission passes review; IAP purchase→unlock→restore→promo-code E2E in sandbox and production
- App Store product page: name/subtitle/keywords built around "photo library / photo organizer" search terms (the discoverability rationale for MAS — treat ASO as a real task); screenshots show real library + readouts
- Announcements.json live + off-toggle verified
- Backup/restore verified on an edited library (edit stacks survive .muselibrary round-trip)
- MobileCLIP weights license resolved (or OpenCLIP fallback shipped) — BLOCKER if unresolved
- GeoNames attribution, OSS licenses page current
- CLAUDE.md doctrine final (three app-initiated network paths documented)
- Support/contact path; refunds are Apple's (link users appropriately)
- Sparkle fully absent from the shipping binary; old GitHub releases removed/archived per plan

## Binding decisions
#30 price ceiling $100, structure leaning as above · #3 no-Lightroom copy rule · #24/#25 performance envelope · plus the full §13 table — final consistency read of the shipped app against it.
