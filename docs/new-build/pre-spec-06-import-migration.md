# Spec 06 — Import & Migration (Lightroom, Apple Photos, Google, Eagle) + Import-Size FYI

*Read with `muse-photo-foundation.md` §7. Depends on Spec 04 for the approximated-edit application (can ship metadata-only earlier if sequenced ahead of editing).*

## Purpose
One coherent "Import from…" surface. Philosophy (DECIDED): **never pretend a translation is lossless; always show what happened; always leave the user able to redo it their way.**

## In scope

### 1. Universal lossless layer (all sources; extends existing `MetadataKeywordReader`)
`xmp:Rating` → stars · `dc:subject` + `lr:hierarchicalSubject` → tags · IPTC caption/title/creator → caption/notes · EXIF GPS → coordinates (Spec 01 columns). Always on, no ceremony.

### 2. Lightroom import (.xmp sidecars / embedded XMP, crs: namespace — publicly documented)
- **Edits, imported as badged "approximated" starting points** into the Muse edit stack: crop/CropAngle/orientation (EXACT — pure geometry) · Temperature/Tint · Exposure2012 (≈ fraction of a stop) · Contrast2012, Vibrance, Saturation (directional) · ToneCurvePV2012 point curves (portable as curves; caveat noted in UI: applied without Adobe's base look, results shift).
- **Do NOT attempt**: Highlights/Shadows/Whites/Blacks 2012, Clarity2012, Dehaze, local corrections, spot removal — adaptive Adobe-engine operators; the industry envelope (darktable skips them; Capture One approximates ~6 global sliders; Luminar disclaims visible drift). Matching the envelope is defensible; exceeding it is not.
- Each imported edit carries an "Approximated from Lightroom" badge + one-click compare against the file's embedded rendered preview.
- **Lightroom PRESET (.xmp) import** uses the same parser → user presets (Spec 04 copy-by-value rules).

### 3. Color labels — the mapping sheet (DECIDED #12; the semantic-collision fix)
- LR color labels (`xmp:Label`) are workflow markers; Muse "red" is a content attribute. **Never merge silently.**
- Import sheet, per color present in the source: **Skip** / **Import as namespaced label** (`Label: Red` — visually distinct chip style, excluded from content-flavored search) / **Map to a tag of the user's choosing** (their own `portfolio` etc.). Remember choices for next import.
- Post-import report: "312 ratings, 1,840 keywords, 47 red labels → `Label: Red`."
- Note: LR pick/reject flags do NOT export to XMP — nothing to handle; do not invent handling.

### 4. Apple Photos import
- AAE/`PHAdjustmentData` is Apple-private (zlib'd binary plist, no spec; only crop maybe recoverable and fragile — do NOT parse). **Supported path: PhotoKit current-version request → import the RENDERED edited image + metadata (albums→collections optional, keywords, favorites→star?, dates, GPS).** UI states plainly: "Apple Photos edits are applied to the imported image; the individual adjustments can't be recovered (private format)."

### 5. Google Photos (Takeout)
- Edits are server-side — treat the edited JPEG as the picture. Merge Takeout JSON per photo: photoTakenTime, geoData, description, favorited, people names (→ plain tags or skip — user choice; NOT face identities). Handle the JSON-beside-file layout and its known filename quirks.

### 6. Eagle import
- .library format per existing `docs/future-features/eagle-library-import.md`; folders/tags/annotations mapped; same report pattern.

### 7. Import-size FYI (DECIDED #22/#23 — exact behavior)
- Analysis is ALWAYS ON — no off switch, no skip path, not a choice dialog.
- Import is instant (browsable immediately); analysis runs in background: throttled on battery/Low Power Mode, paused under thermal pressure.
- **One-button FYI notice, gated on ESTIMATED TIME > ~20–30 min (never on count):** "Heads up: analyzing 40,000 photos will take about 2 hours. They're ready to browse now — search and colors get smarter as it finishes." Below threshold: fully silent.
- Estimate measured on-device: analyze first ~200 files, measure throughput, extrapolate (hardware varies 3–4×; no hardcoded constants).
- Progress findable: "34,000 of 100,000 analyzed" in Settings/sidebar footer with pause/resume. Unanalyzed photos still match on filename/date/EXIF immediately; semantic/color join as the index fills.

## Out of scope
Capture One `.costyle` (deferred) · face identity from any source · any write-back to source apps.

## Binding decisions
#11 edit-import envelope · #12 label mapping · #13/#14 no new taxonomies, info ≠ tags · #22/#23 analysis + FYI exactly as above.

## Acceptance
- LR test set: ratings/keywords/captions/GPS lossless; crop pixel-exact; tone approximations land visually close on the basic set and are badged; unsupported sliders untouched and disclosed in the report.
- Label sheet: each mapping choice works; choices remembered; report accurate.
- Apple import brings rendered edits + metadata; message displayed.
- Takeout: dates/GPS restored to files that lack them.
- 100k-photo import: browsable in seconds; FYI appears with a calibrated estimate; pause/resume works; battery throttle observable.
