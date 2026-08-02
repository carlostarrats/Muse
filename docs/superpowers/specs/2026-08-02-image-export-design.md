# Image Export — design

**Date:** 2026-08-02
**Status:** approved, ready to plan
**Supersedes nothing.** Extends Spec 07 (`Export/Social/`) rather than replacing it.

---

## 1. The problem

Muse can render a photograph beautifully and edit it non-destructively, and
then has no plain way to hand you the file. Everything that exists today is a
special case:

| Exit | What it gives you | What it can't do |
|---|---|---|
| **Share** (hero, editor, grid) | `NSSharingServicePicker` on the rendered file | no format, size or quality choice; an unedited RAW leaves as `.CR2` |
| **Export for Social…** | 12 platform presets, crop, sharpen, byte targets | JPEG only; sizes fixed by platform; the name hides it from anyone not posting |
| **Collection ▸ Save to…** | an 11×14 paginated PDF contact sheet | not images |

The gap the owner hit: **there is no way to get a JPEG out of a RAW.** Strictly
that's not true — "Export for Social… ▸ Flickr / 500px" produces a full-size
q0.95 JPEG, because the social card routes through `OutputRender` →
`EditRenderer`, which converts RAW because RAW can't be written back. But no
one would ever find that, and a door nobody finds is a door that isn't there.

**Batch paste adjustments is out of scope** — it already ships
(`SelectionMenu.swift:128`, backed by `EditStore.applyToAll`). The owner didn't
know, which is a discoverability question, not a build.

## 2. Scope

**In:** a general Export card with format, quality, bit depth, resize and
metadata controls; saved presets; batch across a selection or a collection;
WebP via a bundled `libwebp`.

**Out, decided:**

- **DNG.** Needs Adobe's DNG SDK (digiKam bundles it; darktable and
  RawTherapee don't export DNG at all). Worse, it doesn't fit: Muse's edits are
  non-destructive parameters, so an edited RAW could only be written as a
  *linear demosaiced* DNG, which is not what anyone means by "export to DNG".
  The thing people actually want — a lossless CR2 → DNG transcode — is a
  **converter**, unrelated to format/resize/quality, and belongs on its own
  menu item if it is ever built.
- **AVIF.** ImageIO *can* write it (`public.avif` is in
  `CGImageDestinationCopyTypeIdentifiers()`), so it would have been nearly
  free. Cut anyway, on the owner's call: "just because we can doesn't mean we
  should." A format the owner has never encountered isn't one their users will
  ask for. Being cheap is not a reason to ship something.
- **Colour-profile choice.** Always sRGB. RAW is wide-gamut and sRGB is what
  makes an export look the same wherever it lands. A Display P3 option is a
  real photographer control, and also the kind that silently produces wrong
  files when picked without understanding.
- **Filename templates, watermarks, rendering intent, DPI, apply-a-style-on-
  export.** darktable has all of them. Muse has no batch-processing workflow
  for them to serve.

## 3. Verified constraints

Established by running the code, not by memory:

- **`CGImageDestinationCopyTypeIdentifiers()` on macOS 26.5.2 returns 22 types.
  WebP and DNG are in neither.** ImageIO reads both, writes neither. Since that
  machine is far newer than the 14.6 deployment floor, no supported OS can
  write either for free. WebP therefore requires `libwebp`; DNG requires
  Adobe's SDK.
- **`OutputFormat.tiff16` is currently nominal.** The case exists
  (`EditRenderer.swift:439`) but `exportFile` always builds `.RGBA8` and
  `write` sets no depth property, so `.tiff16` produces an 8-bit TIFF today.
  Nothing ships it to a user yet, so nothing is broken; this spec is the first
  caller that has to mean it.
- **The editor already has a share surface.** `EditorView.swift:355` renders
  its own `ShareButton(url:ink:)` inside `chromeRow`. Renaming that menu item
  gives the edit screen its export with no new chrome. (The hero viewer's
  `ShareButton` lives in `rightRail`, which Edit mode replaces wholesale — the
  two are separate instances.)

## 4. Surfaces

Every existing **"Export for Social…"** item becomes **"Export…"** and opens
the same card, which now has both preset families:

| Where | File | Acts on |
|---|---|---|
| Grid right-click | `SelectionMenu.swift:105` | the effective selection, raster kinds only |
| Hero share menu | `ShareButton.swift:35` | the open photo |
| Editor share menu | same `ShareButton`, via `EditorView.swift:355` | the photo being edited |
| Collection header | `ShareCollectionButton.swift:83` | every reachable member |

No new entry points. The card is presented by the shell, as it is today — the
controls that raise it can't host it (`SocialExportRequest`'s comment explains
why: a card sized against a menu item).

The collection sidebar row's **Save to…** (PDF) and **Share Drive Link** are
untouched. So is Share.

## 5. UI

`SocialExportCard` is renamed `ExportCard`, titled **"Export"**. Its shape does
not change: title row · `[stage | 240pt controls]` · footer with Cancel /
Export / progress. Same `ModalButton`, `SheetCloseButton`, same folder picker
on Export.

**The preset dropdown gains sections** (it is already `.pickerStyle(.menu)`):

```
Format
  Same as original
  JPEG
  PNG
  TIFF
  HEIC
  WebP
Social
  IG Feed Portrait … Glass        ← the existing 12, unchanged
My Presets
  <saved>                          ← section hidden when empty
```

**The controls column branches on the selection.** A Social preset shows
exactly what it shows today (fit mode, matte dots, advisory, EXIF). A Format
preset shows:

- **Quality** — slider, `jpeg` / `heic` / `webp` only. `sameAsOriginal` shows
  it when the container it resolves to is lossy (a JPEG or HEIC source, and
  every RAW, which resolves to JPEG) and hides it when it isn't (PNG, TIFF).
- **Bit depth** — `8` / `16` segmented, `tiff` only.
- **Resize** — a menu: `Original size` / `Long edge` / `Fit within`, with the
  number field(s) appearing only for the latter two.
- **Include camera info (EXIF)** + nested **Include location** — reused as-is.
- **Save Settings as Preset…** — a `ModalButton` under the controls, offered
  **only for a Format selection**. A social platform is already a preset, and a
  saved copy of one would be a second name for the same fixed numbers that
  couldn't track a change to the platform table.

**The stage** shows the crop UI only for fixed-aspect social presets, which is
already how it branches on `preset.isFixed`. Format presets get a plain preview
and the existing pager.

**Advisories reuse the social warning slot.** Two are new:

- Selecting a format for a RAW source: *"RAW can't be written back — this
  exports as \<format\>."* (For "Same as original" this is the whole point of
  the message.)
- 16-bit TIFF where the source will have been through an 8-bit render (see §7):
  *"This photo has edits, which render at 8-bit — 16-bit adds depth the data
  doesn't have."*

The existing never-upscale advisory (`willNotUpscale`) extends to the resize
modes.

### Deliberately absent

- **No filename controls.** Exports keep the source's stem; a collision gets
  `-2`, `-3` via the existing `collisionSafeURL` ladder. **Never an overwrite,
  and no option to.** Overwriting is the one way this feature could destroy
  a user's files, and "Muse never destroys" is the app's spine (`DEL-1` in the
  audit exists for the same reason).
- **No destination control.** Pressing Export opens the folder picker, exactly
  as today.

## 6. Data model

New, all under `Muse/Muse/Export/Image/`, all platform-neutral (Foundation /
CoreGraphics / CoreImage / ImageIO — never AppKit), matching `Export/Social/`.

```swift
enum ExportFormat: String, CaseIterable, Sendable {
    case sameAsOriginal, jpeg, png, tiff, heic, webp
}

enum ExportResize: Equatable, Sendable {
    case original
    case longEdge(Int)
    case fitWithin(width: Int, height: Int)
}

struct ExportSettings: Equatable, Codable, Sendable {
    var format: ExportFormat = .jpeg
    var quality: Double = 0.9
    var tiff16 = false
    var resize: ExportResize = .original
    var includeEXIF = false
    var includeLocation = false
}
```

**The format list is built at runtime**, not hard-coded:
`ExportFormat.available` intersects the static list with
`CGImageDestinationCopyTypeIdentifiers()`, plus `webp` when the encoder links.
A machine that can't write a format never offers it — the card cannot promise
an output the OS can't produce. This is also what keeps a 14.6 Mac honest if
its writable set turns out to differ from 26.5's.

**Saved presets** are `struct SavedExportPreset: Codable { id: UUID, name:
String, settings: ExportSettings }`, persisted as JSON in `AppSettings` under a
new key. No migration — this is defaults, not the database. `ExportPresetStore`
is an `ObservableObject` mirroring `EditPresetStore`, which already does this
for edit presets.

## 7. Render pipeline

### The shared core

`SocialRender` and the new renderer share five steps verbatim. Rather than copy
~80 lines, extract them into `Export/ExportPipeline.swift`:

- `context` — the non-caching export `CIContext`
- `load(_:decodeLongEdgeMax:)` — budget gate + oriented decode (steps 2–3 of
  the social pipeline), returning source properties, source size and decoded
  image
- `scale(_:to:)` — the exact-dimension Lanczos scale
- `collisionSafeURL(base:ext:in:)` — the `-2`, `-3` ladder
- `RenderError`

`SocialRender` is refactored to call them. **Its behaviour must not change** —
`SocialRenderTests`, `SocialCropMathTests`, `SocialMetadataTests` and
`SocialPresetTests` are the proof, and stay green throughout. `fixedFrame` and
the `Job`/`Result` types keep their current visibility (the card uses them).

### `ImageExportRender`

Ordered, same discipline as `SocialRender` — the order is code, not data:

1. **`OutputRender.forOutput`** — the choke point comes first, so edits ride
   out. (`OUT-1` in the audit.)
2. **`ThumbnailCache.withinDecodeBudget`** — bomb guard before any full raster.
   (`DEC-1`.)
3. **Oriented decode**, bounded by the target size the same way social bounds
   it. Orientation is baked (`…WithTransform`), so no output orientation tag
   can exist.
4. **Resize** — `original` / `longEdge` / `fitWithin`. **Never upscales**, the
   same global rule; a source under the target exports at its own size and the
   card says so.
5. **No sharpen.** This is the one deliberate divergence from `SocialRender`,
   which unsharp-masks on downscale. A general export is a faithful conversion;
   a sharpening pass the user didn't ask for is a surprise in the pixels.
   darktable doesn't sharpen on export either.
6. **Flatten conditionally.** JPEG and HEIC have no usable alpha, so they
   composite over white. **PNG, TIFF and WebP keep alpha** — flattening them
   would be a data loss the social path can afford and this one can't.
7. **Encode** — sRGB 8-bit, except 16-bit TIFF, which builds `.RGBA16`.
   Metadata merges through the existing `SocialMetadata.outputProperties`
   (rename to `ExportMetadata`, since it is no longer social-only).
8. **Verify, then write.** When EXIF is off, `ImageMetadataStripper.isClean`
   must pass or the file fails — the same rule the social path holds, and the
   same one the Drive publish path holds. Then `collisionSafeURL`, atomic
   write.

### The 16-bit wrinkle

`OutputRender.forOutput` renders an edited photo to an **8-bit** temp
(`.matchingSource`, RGBA8). Exporting that as 16-bit TIFF would inflate 8-bit
data and call it 16 — a quality claim the bytes don't support.

Fix: add `OutputRender.forOutput(_:preferring:)` taking an optional
`OutputFormat`, so a 16-bit request renders the temp at 16-bit in the first
place. This **keeps the choke point intact** — it is an added overload, not a
bypass, and `RenderedOutput`'s `fileprivate` init is untouched, so `OUT-1`
still holds. `EditRenderer.exportFile` gains the depth branch that
`OutputFormat.tiff16` has always implied and never had.

Unedited sources are unaffected: they pass through as their own bytes and
ImageIO decodes whatever depth they carry.

### WebP

`libwebp` — BSD, pure C, no network surface, so it clears the third-party
dependency rule in `CLAUDE.md`. It would be the app's **first bundled binary
dependency**, which is the notable part, not the licence.

Requirements: static linkage (no embedded framework to sign — see the
stale-signed-appex trap in `CLAUDE.md`), and **universal**, because Intel Macs
must keep working. Built from source via SPM, both arches come free; verify
with `-configuration Release` per the arch rule, since a Debug build compiles
only the active arch.

`WebPEncoder.swift` wraps it behind `encode(_ cgImage: CGImage, quality:
Double) throws -> Data`. Everything else in the pipeline is format-agnostic.

**Sequencing:** WebP lands **last**, after the rest of the feature is shipped
and green. If the dependency turns out to be a problem, the owner still has a
complete export feature and `ExportFormat.available` simply won't list WebP.

## 8. Errors

Per-file failures collect rather than abort, exactly as `SocialExportModel`
already does — one undecodable file must not cost the user the other nine. The
existing failure alert is reused. `ExportError` cases: `decodeFailed`,
`tooLarge` (over the decode budget), `encodeFailed`, `verifyFailed` (metadata
not provably clean), `formatUnavailable`.

`formatUnavailable` should be unreachable, since the list is built from what
the OS reports writable — it exists so the impossible case fails loudly instead
of writing a wrong-typed file.

## 9. Localization

Every new string is localized at declaration, French filled in, per the
standing rule. The ones that need care because they are **not** in a SwiftUI
text-literal position and so won't auto-extract:

- `ExportFormat` display names (a property returning `String`) — needs
  `String(localized:)`.
- The `NSOpenPanel` `prompt` and `message` — AppKit setters. The existing
  social call site already wraps these; the pattern carries over.
- The RAW and 16-bit advisories, which interpolate a format name — build the
  whole phrase as one key, never by concatenation.

## 10. Testing

Unit (`MuseTests`), fixtures generated at runtime via the existing
`SocialFixtures` pattern — no binary blobs in git:

- **`ExportFormatTests`** — `available` never lists a type ImageIO can't write;
  extension and UTType mapping per format; `sameAsOriginal` resolves to the
  source's container, and to JPEG for RAW.
- **`ExportResizeTests`** — long-edge and fit-within maths; **never upscales**
  in either mode; aspect preserved; a 1px source doesn't divide by zero.
- **`ImageExportRenderTests`** — output dimensions are exact; alpha survives
  PNG/TIFF/WebP and is flattened for JPEG/HEIC; EXIF-off output passes
  `isClean`; EXIF-on carries camera fields and drops GPS unless location is on;
  16-bit TIFF is actually 16-bit; collision produces `-2` and **never**
  overwrites an existing file.
- **`ExportPresetStoreTests`** — round-trip, rename, delete, and a corrupt
  defaults blob degrades to an empty list rather than throwing.
- **Refactor guard** — the existing four social test files must pass unchanged.
  That is the contract on the `ExportPipeline` extraction.

Then `./scripts/audit-invariants.sh` (OUT-1 and DEC-1 both bear on this work),
and a runtime pass driving the real card, since green tests are not evidence a
sandboxed file-writing feature works — `FEATURE-LEDGER.md` gets its row.

## 11. Migrations

**None.** No schema change. Saved presets are `AppSettings` JSON. The migration
chain stays at v23.

## 12. Risks

| Risk | Handling |
|---|---|
| `libwebp` is the first bundled binary dep | sequenced last; feature ships complete without it |
| Refactoring `SocialRender` regresses Spec 07 | its four test files are the contract, run at every step |
| 16-bit path touches the audited choke point | added overload, never a bypass; `OUT-1` re-run |
| Card grows a second mode and gets tangled | the branch is one `switch` on the selection; if the controls column passes ~150 lines it splits into two subviews |
