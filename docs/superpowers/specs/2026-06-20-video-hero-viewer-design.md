# Video hero viewer — design

**Date:** 2026-06-20
**Status:** Approved, pending implementation plan

## Problem

Movies open in the bare `ViewerChrome` fallback: a filename strip at the top,
a black-boxed `AVPlayerView` with big black side-bars, and nothing else. Images
open in the rich `HeroImageViewer` — a color-wash backdrop plus a right-hand
info column (filename, collections, tags, colors, INFO metadata). Videos should
match that "normal experience" while still playing with the standard AVPlayer
controls.

The black side-bars in the report are the player view's own black background
filling the old chrome content frame; the portrait video is centered inside it.

## Goals

- A video opens with the same color-wash backdrop and the same right-side info
  column as an image.
- The video plays with the approved AVPlayer floating controls (autoplay).
- The video is sized to its aspect-fit rect and floats over the backdrop — no
  black side-bars.

## Non-goals (v1)

- No zoom / pan (image-specific; fights video playback).
- No flight-from-tile open animation (the viewer mounts with the existing
  `.opacity` cross-fade; the backdrop fades in).
- No arrow-key flipping between videos.
- No DB schema change — the wash palette is computed on viewer-open, exactly
  like the image no-palette fallback.
- Audio is untouched (it already has its own `AudioPlayerView` card).

## Approach

Reuse the already-extracted hero subcomponents and add a simpler sibling viewer,
rather than genericizing the fragile `HeroImageViewer` (which carries
zoom/pan/`HeroStage`/flight state that video doesn't need).

### Components

#### 1. `Views/Viewer/HeroVideoViewer.swift` (new)

A sibling to `HeroImageViewer`, simpler. Composition:

- **Backdrop:** `ViewerBackdrop(hexColor: details?.dominantColor ?? computedPalette.first)`,
  faded in on appear via a `backdropVisible` flag (same pattern/timing as
  `HeroImageViewer`). Tapping the backdrop closes the viewer.
- **Video stage:** `VideoPlayerView(url:)` framed to the video's **aspect-fit
  rect** (computed from the asset's natural size via `ViewerGeometry.fitRect`,
  the same helper the image stage uses), centered in the full viewport, with
  rounded corners + a drop shadow. Because the view is sized to the exact aspect,
  `videoGravity = .resizeAspect` yields no visible bars; the colored backdrop
  shows around it. The info column overlays the trailing side, exactly as it does
  over an image.
- **Info column:** `ViewerInfoColumn(...)` with the same callbacks the image
  viewer uses (tag tap → search + close, collection tap → filter + close, Open in
  Finder, Delete). Its `chrome` row for video is **Share + ✕ only** — no zoom
  pill, no Fit (those are image-only). `backingVisible` is always `false` (no
  zoom), so the column draws directly over the backdrop like an image at fit.
- **Toast:** `ViewerToast` for in-viewer messages (tag/collection mutations).

State (subset of the image viewer's):
`currentURL`, `details: ViewerFileDetails?`, `metadata: FileMetadata?`,
`naturalSize: CGSize?`, `computedPalette: [String]`, `paletteResolved: Bool`,
`backdropVisible: Bool`, `chromeVisible: Bool`, `toast: ToastData?`, and delete
state (`deleting`, a fade progress).

Load (`.task(id: currentURL)`):
1. `ViewerFileDetails.load(...)` for tags/collections/DB palette (videos are
   indexed, so the `fileID` and tag/collection queries work; they typically have
   no auto palette → fall through to the computed one).
2. `FileMetadata.load(url:, kind: .video)` for the INFO card (Duration, Modified).
3. `naturalSize` from the AVAsset's first video track (`naturalSize` applying
   `preferredTransform`), used for the fit rect.
4. If the DB has no palette, `HeroPalette.videoPalette(at:)` computes one; assign
   `computedPalette` + set `paletteResolved`.

Close / delete:
- Close button and backdrop tap set `appState.selectedFile = nil` (the viewer
  unmounts with the existing `.opacity` transition; the toolbar returns because
  `selectedFile == nil`). Escape already resolves to `.closeViewer` →
  `selectedFile = nil` for non-hero kinds — **no `viewerClosing`/flight wiring**.
- Delete fades the viewer out, `TrashManager.trash(url)`, removes the node from
  `currentFiles`, hands an Undo `ToastData` to `appState.deletion.toast`
  (surfaced by the always-present `GridToastHost`), then `selectedFile = nil` and
  `clearSelection()` — mirroring `HeroImageViewer.completeDelete` minus the burn.

#### 2. `Viewers/HeroPalette.swift` (new)

Extract the RGBA-histogram core currently private inside
`HeroImageViewer.quickPalette` so images and videos share one algorithm:

- `paletteHexes(fromRGBA bytes: [UInt8], width: Int, height: Int) -> [String]`
  — pure, deterministic (coarse RGB-bucket histogram → top 3 distinct buckets,
  dark→light order). **Unit-testable** with synthetic byte arrays.
- `quickPalette(at url: URL) async -> [String]` — images: ImageIO 48px thumbnail
  → RGBA bytes → `paletteHexes`.
- `videoPalette(at url: URL) async -> [String]` — `AVAssetImageGenerator`
  (`appliesPreferredTrackTransform = true`, `maximumSize` ~48px) grabs a frame
  ~1s in (clamped to asset duration), → RGBA bytes → `paletteHexes`. **Guards the
  dataless-iCloud case** (`ubiquitousItemDownloadingStatusKey`): a
  not-downloaded placeholder returns `[]` (→ neutral backdrop) rather than
  forcing a download just to tint the wash. Returns `[]` on any generation
  failure.

`HeroImageViewer` is refactored to call `HeroPalette.quickPalette` /
`paletteHexes`; behavior is byte-for-byte identical (same algorithm, same call
site on open).

#### 3. `Viewers/VideoPlayerView.swift` (small change)

- Set `videoGravity = .resizeAspect` (explicit; the view is sized to aspect so no
  bars appear).
- Make the player view's layer background clear so the rounded-corner clip shows
  the backdrop through the corners rather than black.
- Keep autoplay + `dismantleNSView` pause/teardown as-is.

#### 4. `Views/ViewerRouter.swift` (routing change)

```swift
case .video:
    HeroVideoViewer(file: file)
        .id(file.url)
```

(Replaces the `ViewerChrome { VideoPlayerView(...) }` wrap.)

No change to `ContentView`'s transition condition: video stays in the
`.opacity` branch (no flight), which is the correct mount/unmount for it.

## Data flow

```
grid double-click → appState.selectedFile = video node
  → ViewerRouter (.video) → HeroVideoViewer(file:)
     ├─ ViewerBackdrop(hexColor: DB dominant ?? computed frame palette)
     ├─ VideoPlayerView framed to ViewerGeometry.fitRect(naturalSize, viewport)
     └─ ViewerInfoColumn(details, metadata, palette, chrome: Share + ✕)
close/esc/backdrop-tap → selectedFile = nil → unmount (.opacity), toolbar returns
delete → fade + TrashManager.trash → GridToastHost undo toast → selectedFile = nil
```

## Error handling / edge cases

- **No analyzed palette (the common case):** computed from a sampled frame.
- **Dataless iCloud video:** frame grab skipped → neutral backdrop (no forced
  download), consistent with `HashService`/classification dataless rules.
- **Frame generation failure / no video track:** `videoPalette` returns `[]` →
  neutral backdrop; `naturalSize` falls back to a default aspect (e.g. 16:9) so
  the fit rect is still sane.
- **Tags/collections:** work via the existing `fileID`; empty cards show
  "None yet" and the user can add manual tags / add to a collection.

## Testing

- **`HeroPaletteTests`** (new, pure): `paletteHexes(fromRGBA:width:height:)` on
  synthetic buffers — a solid-color buffer yields that color; a two-region buffer
  yields both, dark→light ordered; an empty/degenerate buffer yields `[]`.
- No UI unit tests (consistent with the project — views aren't unit-tested);
  the viewer composition is verified by build + live GUI check.

## Files touched

- `Views/Viewer/HeroVideoViewer.swift` — new
- `Viewers/HeroPalette.swift` — new (extracted core + image/video palette)
- `Views/Viewer/HeroImageViewer.swift` — refactor `quickPalette` onto `HeroPalette`
- `Viewers/VideoPlayerView.swift` — videoGravity + clear layer background
- `Views/ViewerRouter.swift` — `.video` → `HeroVideoViewer`
- `MuseTests/HeroPaletteTests.swift` — new
