# Video Hero Viewer Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make movies open in the rich hero experience — color-wash backdrop + right-side info column (tags/collections/colors/INFO) — while still playing with the standard AVPlayer floating controls.

**Architecture:** Add a simpler sibling viewer (`HeroVideoViewer`) that composes the already-extracted `ViewerBackdrop` + `ViewerInfoColumn`, centering an aspect-fit `AVPlayerView` over the backdrop (no black bars, no zoom/pan/flight). The backdrop's wash color comes from a sampled video frame via a new shared palette helper (`HeroPalette`), into which the image viewer's existing histogram is extracted.

**Tech Stack:** Swift / SwiftUI / AppKit / AVFoundation / ImageIO; XCTest (`MuseTests`); GRDB (read-only here).

## Global Constraints

- Min macOS **14.6** — `AVAssetImageGenerator.image(at:)` (macOS 13+) and `track.load(.naturalSize)` async APIs are available; prefer them over deprecated sync variants.
- **Never read dataless iCloud bytes** — guard frame sampling on `.ubiquitousItemDownloadingStatusKey == .notDownloaded`, returning `[]` (mirrors `FileMetadata.load` / `HashService` rules).
- **Files are never deleted, only moved to Trash** via the existing `TrashManager.trash` / `appState.deletion` undo path.
- **No network calls.** Frame sampling is local AVFoundation only.
- Module default actor isolation is **MainActor** — any static used from `Task.detached` or XCTest must be marked `nonisolated`.
- No DB schema change. Palette is computed on viewer-open, exactly like the image no-palette fallback.

---

### Task 1: Extract `HeroPalette` (shared histogram + image/video frame palette)

**Files:**
- Create: `Muse/Muse/Viewers/HeroPalette.swift`
- Test: `MuseTests/HeroPaletteTests.swift`
- Modify: `Muse/Muse/Views/Viewer/HeroImageViewer.swift` (refactor `quickPalette` onto `HeroPalette`)

**Interfaces:**
- Consumes: nothing new.
- Produces:
  - `HeroPalette.paletteHexes(fromRGBA bytes: [UInt8], width: Int, height: Int) -> [String]` (pure, `nonisolated`)
  - `HeroPalette.quickPalette(at url: URL) async -> [String]` (`nonisolated`)
  - `HeroPalette.videoPalette(at url: URL) async -> [String]` (`nonisolated`)

- [ ] **Step 1: Write the failing test**

Create `MuseTests/HeroPaletteTests.swift`:

```swift
import XCTest
@testable import Muse

final class HeroPaletteTests: XCTestCase {
    /// `count` RGBA pixels of one solid color (opaque).
    private func solid(_ r: UInt8, _ g: UInt8, _ b: UInt8, count: Int) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(count * 4)
        for _ in 0..<count { out.append(contentsOf: [r, g, b, 255]) }
        return out
    }

    func testSolidColorYieldsThatColor() {
        let bytes = solid(255, 0, 0, count: 16)   // 4×4 red
        XCTAssertEqual(HeroPalette.paletteHexes(fromRGBA: bytes, width: 4, height: 4),
                       ["#ff0000"])
    }

    func testTwoRegionsYieldBothDarkToLight() {
        // 4×4 = 16 px: 8 black + 8 white. Distinct buckets, ordered dark → light.
        let bytes = solid(0, 0, 0, count: 8) + solid(255, 255, 255, count: 8)
        XCTAssertEqual(HeroPalette.paletteHexes(fromRGBA: bytes, width: 4, height: 4),
                       ["#000000", "#ffffff"])
    }

    func testEmptyDimensionsYieldNothing() {
        XCTAssertEqual(HeroPalette.paletteHexes(fromRGBA: [], width: 0, height: 0), [])
    }

    func testShortBufferYieldsNothing() {
        // Claims 4×4 (needs 64 bytes) but provides only 8.
        let bytes = solid(10, 20, 30, count: 2)
        XCTAssertEqual(HeroPalette.paletteHexes(fromRGBA: bytes, width: 4, height: 4), [])
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd "/Users/carlostarrats/Documents/Projects/Muse/Muse App" && xcodebuild -scheme Muse -only-testing:MuseTests/HeroPaletteTests test 2>&1 | tail -20`
Expected: FAIL — `cannot find 'HeroPalette' in scope`.

- [ ] **Step 3: Write the implementation**

Create `Muse/Muse/Viewers/HeroPalette.swift`:

```swift
//
//  HeroPalette.swift
//  Muse
//
//  Shared on-open palette extraction for the hero viewers. The pure histogram
//  core (`paletteHexes`) is split out so images (ImageIO thumbnail) and videos
//  (a sampled AVAssetImageGenerator frame) share one algorithm; it's also the
//  display-only fallback when the DB has no analyzed palette yet.
//

import Foundation
import CoreGraphics
import ImageIO
import AVFoundation

enum HeroPalette {
    /// Pure: coarse RGB-bucket histogram over premultiplied-last RGBA bytes →
    /// up to 3 distinct dominant colors as "#rrggbb", ordered dark → light.
    /// `bytes` must be at least width*height*4 long (4 bytes/pixel, RGBA).
    nonisolated static func paletteHexes(fromRGBA bytes: [UInt8],
                                         width: Int, height: Int) -> [String] {
        guard width > 0, height > 0, bytes.count >= width * height * 4 else { return [] }
        let limit = width * height * 4
        var counts: [Int: Int] = [:]
        var sums: [Int: (r: Int, g: Int, b: Int)] = [:]
        for i in stride(from: 0, to: limit, by: 4) {
            let r = Int(bytes[i]), g = Int(bytes[i + 1]), b = Int(bytes[i + 2])
            let key = (r >> 4) << 8 | (g >> 4) << 4 | (b >> 4)
            counts[key, default: 0] += 1
            let s = sums[key] ?? (0, 0, 0)
            sums[key] = (s.r + r, s.g + g, s.b + b)
        }
        let top = counts.sorted { $0.value > $1.value }.prefix(12)
            .compactMap { key, c -> (Int, Int, Int)? in
                guard let s = sums[key] else { return nil }
                return (s.r / c, s.g / c, s.b / c)
            }
        var picked: [(Int, Int, Int)] = []
        for c in top where picked.count < 3 {
            if picked.allSatisfy({ abs($0.0 - c.0) + abs($0.1 - c.1) + abs($0.2 - c.2) > 60 }) {
                picked.append(c)
            }
        }
        picked.sort { ($0.0 + $0.1 + $0.2) < ($1.0 + $1.1 + $1.2) }
        return picked.map { String(format: "#%02x%02x%02x", $0.0, $0.1, $0.2) }
    }

    /// Image: a tiny ImageIO thumbnail decoded to RGBA → `paletteHexes`.
    nonisolated static func quickPalette(at url: URL) async -> [String] {
        await Task.detached(priority: .userInitiated) { () -> [String] in
            guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, [
                      kCGImageSourceCreateThumbnailFromImageAlways: true,
                      kCGImageSourceThumbnailMaxPixelSize: 48,
                  ] as CFDictionary) else { return [] }
            return hexes(from: cg)
        }.value
    }

    /// Video: one small frame ~1s in (clamped to duration) → RGBA → `paletteHexes`.
    /// Skips dataless iCloud placeholders (never forces a download just to tint
    /// the backdrop); returns [] on any failure → neutral backdrop.
    nonisolated static func videoPalette(at url: URL) async -> [String] {
        if (try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey]))?
            .ubiquitousItemDownloadingStatus == .notDownloaded {
            return []
        }
        return await Task.detached(priority: .userInitiated) { () -> [String] in
            let asset = AVURLAsset(url: url)
            let gen = AVAssetImageGenerator(asset: asset)
            gen.appliesPreferredTrackTransform = true
            gen.maximumSize = CGSize(width: 48, height: 48)
            var seconds = 0.0
            if let dur = try? await asset.load(.duration) {
                let total = CMTimeGetSeconds(dur)
                if total.isFinite && total > 0 { seconds = min(1.0, total / 2) }
            }
            let time = CMTime(seconds: seconds, preferredTimescale: 600)
            guard let cg = try? await gen.image(at: time).image else { return [] }
            return hexes(from: cg)
        }.value
    }

    /// Draw a CGImage into a width*height RGBA buffer and bucket it.
    nonisolated private static func hexes(from cg: CGImage) -> [String] {
        let w = cg.width, h = cg.height
        guard w > 0, h > 0 else { return [] }
        var data = [UInt8](repeating: 0, count: w * h * 4)
        let drew = data.withUnsafeMutableBytes { buf -> Bool in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h,
                                      bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drew else { return [] }
        return paletteHexes(fromRGBA: data, width: w, height: h)
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd "/Users/carlostarrats/Documents/Projects/Muse/Muse App" && xcodebuild -scheme Muse -only-testing:MuseTests/HeroPaletteTests test 2>&1 | tail -20`
Expected: `** TEST SUCCEEDED **` (4 cases pass).

- [ ] **Step 5: Refactor `HeroImageViewer` onto `HeroPalette`**

In `Muse/Muse/Views/Viewer/HeroImageViewer.swift`:

In `loadDetails()`, change the quick-palette kickoff (currently line ~427):

```swift
        async let quick = Self.quickPalette(at: url)
```
to:
```swift
        async let quick = HeroPalette.quickPalette(at: url)
```

Then delete the now-unused private static `quickPalette(at:)` method entirely — the whole block from its doc comment:

```swift
    /// Fast 3-swatch palette from a tiny downsample: coarse RGB-bucket
    /// histogram, top distinct buckets ordered dark → light (the prototype's
    /// swatch order). Display-only; Analyze still writes the real palette.
    nonisolated private static func quickPalette(at url: URL) async -> [String] {
        ...
    }
```

through its closing brace (the method ending at line ~509). Leave `imagePixelSize(at:)` and everything else untouched.

- [ ] **Step 6: Build to verify the refactor compiles**

Run: `cd "/Users/carlostarrats/Documents/Projects/Muse/Muse App" && xcodebuild -scheme Muse build 2>&1 | tail -15`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 7: Commit**

```bash
cd "/Users/carlostarrats/Documents/Projects/Muse/Muse App"
git add Muse/Muse/Viewers/HeroPalette.swift MuseTests/HeroPaletteTests.swift Muse/Muse/Views/Viewer/HeroImageViewer.swift
git commit -m "feat: extract HeroPalette (shared frame-histogram core; video frame palette)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_016Na7wmStCeHvZrpdXWipLp"
```

---

### Task 2: `HeroVideoViewer` + player tweak + routing

**Files:**
- Create: `Muse/Muse/Views/Viewer/HeroVideoViewer.swift`
- Modify: `Muse/Muse/Viewers/VideoPlayerView.swift` (aspect gravity + clear background)
- Modify: `Muse/Muse/Views/ViewerRouter.swift` (`.video` → `HeroVideoViewer`)

**Interfaces:**
- Consumes: `HeroPalette.videoPalette(at:)` (Task 1); `ViewerBackdrop(hexColor:)`, `ViewerInfoColumn(...)`, `ViewerToast(toast:)`, `ViewerGeometry.fitRect(imageSize:viewport:)`, `ShareButton(url:)`, `ViewerFileDetails.load(queue:path:)`, `FileMetadata.load(url:kind:)`, `TrashManager.trash(_:)`, `appState.deletion` — all existing.
- Produces: `HeroVideoViewer(file: FileNode)`.

- [ ] **Step 1: Update `VideoPlayerView` for the hero stage**

Replace the body of `makeNSView` in `Muse/Muse/Viewers/VideoPlayerView.swift` and add the `AppKit` import. The full file becomes:

```swift
//
//  VideoPlayerView.swift
//  Muse
//
//  AVKit-backed video player. Auto-plays when shown. Sized by its container to
//  the video's aspect-fit rect (the hero stage), so resizeAspect shows no bars;
//  the layer background is clear so the rounded-corner clip reveals the backdrop.
//

import SwiftUI
import AVKit
import AppKit

struct VideoPlayerView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .floating
        view.videoGravity = .resizeAspect
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.clear.cgColor
        view.player = AVPlayer(url: url)
        view.player?.play()
        return view
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        if (nsView.player?.currentItem?.asset as? AVURLAsset)?.url != url {
            nsView.player?.pause()
            nsView.player = AVPlayer(url: url)
            nsView.player?.play()
        }
    }

    // AppKit does not auto-pause an AVPlayer when its view leaves the
    // hierarchy. Without this, closing the viewer leaves audio playing
    // from an invisible player until it eventually deallocs.
    static func dismantleNSView(_ nsView: AVPlayerView, coordinator: ()) {
        nsView.player?.pause()
        nsView.player = nil
    }
}
```

- [ ] **Step 2: Create `HeroVideoViewer`**

Create `Muse/Muse/Views/Viewer/HeroVideoViewer.swift`:

```swift
//
//  HeroVideoViewer.swift
//  Muse
//
//  The hero viewer for videos: ViewerBackdrop (color wash from a sampled frame)
//  + a centered aspect-fit AVPlayerView + ViewerInfoColumn (tags/collections/
//  colors/INFO) + ViewerToast. Deliberately simpler than HeroImageViewer — no
//  zoom/pan, no flight, no arrow-key flipping. Close/Escape just clear
//  selectedFile (EscapeAction.closeViewer); the .opacity transition unmounts it.
//

import SwiftUI
import AppKit
import AVFoundation

struct HeroVideoViewer: View {
    @EnvironmentObject var appState: AppState
    let file: FileNode

    @State private var details: ViewerFileDetails?
    @State private var metadata: FileMetadata?
    @State private var naturalSize: CGSize?
    @State private var computedPalette: [String] = []
    @State private var paletteResolved = false
    @State private var backdropVisible = false
    @State private var chromeVisible = false
    @State private var toast: ToastData?
    @State private var deleting = false
    /// 0 = fully visible, 1 = gone (the delete fade-out).
    @State private var fade: Double = 0

    var body: some View {
        GeometryReader { geo in
            ZStack {
                ViewerBackdrop(hexColor: details?.dominantColor ?? computedPalette.first)
                    .opacity(backdropVisible ? 1 : 0)
                    .animation(.easeOut(duration: 0.4), value: backdropVisible)
                    .contentShape(Rectangle())
                    .onTapGesture { close() }

                stage(viewport: geo.size)
                rightRail
                ViewerToast(toast: $toast)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .opacity(1 - fade)
        }
        .ignoresSafeArea()
        .onAppear {
            backdropVisible = true
            withAnimation(.easeOut(duration: 0.4).delay(0.15)) { chromeVisible = true }
        }
        .task(id: file.url) { await loadDetails() }
        // Reload tag/collection pills when tags mutate library-wide.
        .onChange(of: appState.tagsVersion) { _, _ in
            Task { await loadDetails() }
        }
    }

    // MARK: - Stage

    private func stage(viewport: CGSize) -> some View {
        let size = naturalSize ?? CGSize(width: 16, height: 9)
        let rect = ViewerGeometry.fitRect(imageSize: size, viewport: viewport)
        return VideoPlayerView(url: file.url)
            .frame(width: rect.width, height: rect.height)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .shadow(color: .black.opacity(0.5), radius: 40, y: 24)
            .position(x: rect.midX, y: rect.midY)
    }

    // MARK: - Right rail

    private var rightRail: some View {
        ViewerInfoColumn(url: file.url,
                         details: details,
                         fallbackPalette: computedPalette,
                         paletteLoading: !paletteResolved,
                         metadata: metadata,
                         backing: .black,
                         backingVisible: false,
                         refresh: { await loadDetails() },
                         onTagTap: { label in
                             appState.searchQuery = label
                             Task { await appState.runSearch(label) }
                             close()
                         },
                         onCollectionTap: { id in
                             appState.setActiveCollection(id)
                             close()
                         },
                         onOpenInFinder: {
                             NSWorkspace.shared.activateFileViewerSelecting([file.url])
                         },
                         onDelete: deleteCurrent,
                         toast: $toast,
                         chrome: { chromeRow })
            .contentShape(Rectangle())
            .onTapGesture {}
            .padding(.top, 20)
            .padding(.bottom, 28)
            .padding(.trailing, ViewerGeometry.columnMargin - 12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            .opacity(chromeVisible ? 1 : 0)
            .allowsHitTesting(chromeVisible && !deleting)
    }

    private var chromeRow: some View {
        HStack(spacing: 8) {
            Spacer()
            ShareButton(url: file.url)
            VideoCloseButton(action: close)
        }
        .frame(width: ViewerGeometry.columnWidth)
    }

    // MARK: - Close

    private func close() {
        guard !deleting else { return }
        // Drop the grid selection so closing leaves nothing selected (parity
        // with the hero image close), then unmount via the .opacity transition.
        appState.clearSelection()
        appState.selectedFile = nil
    }

    // MARK: - Delete / undo

    private func deleteCurrent() {
        guard !deleting else { return }
        deleting = true
        let url = file.url
        let node = appState.currentFiles.first { $0.url == url }
        withAnimation(.easeInOut(duration: 0.35)) { fade = 1 }
        Task {
            try? await Task.sleep(nanoseconds: 380_000_000)
            await completeDelete(url: url, node: node)
        }
    }

    private func completeDelete(url: URL, node: FileNode?) async {
        do {
            let ticket = try await TrashManager.trash(url)
            withAnimation(.easeIn(duration: 0.2)) {
                appState.currentFiles.removeAll { $0.url == url }
            }
            // Hand the Undo toast to the always-present GridToastHost so it
            // survives the viewer unmount.
            appState.deletion.toast = ToastData(message: "Moved to Trash",
                                                actionLabel: "Undo") {
                appState.deletion.restore(ticket: ticket,
                                          node: node ?? FileNode(url: url))
            }
            appState.selectedFile = nil
            appState.clearSelection()
        } catch {
            withAnimation(.easeOut(duration: 0.18)) {
                toast = ToastData(message: "Couldn't move to Trash")
                fade = 0
                deleting = false
            }
        }
    }

    // MARK: - Load

    private func loadDetails() async {
        let url = file.url
        // Kick off the frame palette now so swatches/backdrop land while the
        // chrome fades in.
        async let quick = HeroPalette.videoPalette(at: url)
        var loaded: ViewerFileDetails? = nil
        if let queue = Database.shared.dbQueue {
            loaded = try? await ViewerFileDetails.load(queue: queue, path: url.path)
        }
        details = loaded
        metadata = await FileMetadata.load(url: url, kind: .video)
        if naturalSize == nil {
            naturalSize = await Self.videoNaturalSize(at: url)
        }
        if let palette = loaded?.palette, !palette.isEmpty {
            paletteResolved = true
        } else {
            let pal = await quick
            withAnimation(.easeOut(duration: 0.25)) {
                computedPalette = pal
                paletteResolved = true
            }
        }
    }

    /// The video's display size (natural size with the preferred transform
    /// applied), used for the aspect-fit stage rect. nil → caller's 16:9 default.
    nonisolated private static func videoNaturalSize(at url: URL) async -> CGSize? {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let size = try? await track.load(.naturalSize),
              let transform = try? await track.load(.preferredTransform) else { return nil }
        let applied = size.applying(transform)
        let w = abs(applied.width), h = abs(applied.height)
        guard w > 0, h > 0 else { return nil }
        return CGSize(width: w, height: h)
    }
}

/// 38pt circular close button (the ✕), hover-brightening — the only chrome
/// control the video viewer needs (no zoom pill / Fit).
private struct VideoCloseButton: View {
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(hovering ? 1.0 : 0.85))
                .frame(width: 38, height: 38)
                .background(Circle().fill(.white.opacity(hovering ? 0.24 : 0.10)))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Close")
        .onHover { hovering = $0 }
    }
}
```

- [ ] **Step 3: Route `.video` to the new viewer**

In `Muse/Muse/Views/ViewerRouter.swift`, replace the `.video` case (currently lines 67–71):

```swift
        case .video:
            ViewerChrome(title: file.basename) {
                VideoPlayerView(url: file.url)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
```
with:
```swift
        case .video:
            HeroVideoViewer(file: file)
                .id(file.url)
```

- [ ] **Step 4: Build**

Run: `cd "/Users/carlostarrats/Documents/Projects/Muse/Muse App" && xcodebuild -scheme Muse build 2>&1 | tail -15`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 5: Run the full test suite (no regressions)**

Run: `cd "/Users/carlostarrats/Documents/Projects/Muse/Muse App" && xcodebuild -scheme Muse test 2>&1 | tail -15`
Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 6: Commit**

```bash
cd "/Users/carlostarrats/Documents/Projects/Muse/Muse App"
git add Muse/Muse/Views/Viewer/HeroVideoViewer.swift Muse/Muse/Viewers/VideoPlayerView.swift Muse/Muse/Views/ViewerRouter.swift
git commit -m "feat: videos open in the hero viewer (color wash + info column, plays in approved design)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_016Na7wmStCeHvZrpdXWipLp"
```

---

## Manual verification (after Task 2)

Build & run, open a folder containing a movie (e.g. a portrait `.MOV`), double-click it:
- Backdrop is a color wash derived from the video (not flat black side-bars).
- The video is centered, aspect-fit, rounded corners, plays automatically with floating controls.
- The right info column shows filename, COLLECTION, TAGS, COLORS (swatches from the frame), and INFO (Duration + Modified).
- Share + ✕ appear in the chrome row; ✕, Escape, and a backdrop tap all close back to the grid with the toolbar returning.
- Delete fades the viewer out, moves the file to Trash, and shows the Undo toast over the grid.

## Self-review notes

- **Spec coverage:** backdrop wash (Task 2 stage + Task 1 `videoPalette`), info column (Task 2 `rightRail`), aspect-fit no-bars stage (Task 2 `stage` + player tweak), routing (Task 2 step 3), shared palette core + image refactor (Task 1), dataless guard (Task 1 `videoPalette`), delete/undo (Task 2), no DB change / no flight / no zoom (by construction). All covered.
- **Type consistency:** `HeroPalette.videoPalette` / `paletteHexes` names match between tasks; `ViewerInfoColumn` argument labels match the existing call in `HeroImageViewer`; `ViewerGeometry.fitRect(imageSize:viewport:)`, `ShareButton(url:)`, `ViewerFileDetails.load(queue:path:)`, `FileMetadata.load(url:kind:)`, `TrashManager.trash(_:)`, `appState.deletion.restore(ticket:node:)`, `ToastData(message:actionLabel:)`/`(message:)`, `FileNode(url:)` all verified against current source.
```
