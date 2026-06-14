//
//  HeroImageViewer.swift
//  Muse
//
//  The hero image viewer composition (Task 9): ViewerBackdrop +
//  HeroStage + chrome (✕ / zoom pill / Fit) + ViewerInfoColumn +
//  ViewerToast. Opens with a flight from the grid tile, closes with
//  the return flight; arrow keys flip between image-kind files;
//  Delete moves to Trash with an undo toast.
//

import SwiftUI
import AppKit
import ImageIO

struct HeroImageViewer: View {
    @EnvironmentObject var appState: AppState
    let file: FileNode

    @State private var currentURL: URL
    @State private var details: ViewerFileDetails?
    @State private var naturalSize: CGSize?
    @State private var zoom: CGFloat = 1
    @State private var pan: CGSize = .zero
    @State private var isClosing = false
    @State private var chromeVisible = false
    @State private var toast: ToastData?
    @State private var burnProgress: Double = 0
    @State private var burning = false
    @State private var deleteTask: Task<Void, Never>?
    @State private var viewportSize: CGSize = .zero
    /// After the close flight lands with an undo toast still showing, we keep
    /// only the toast mounted so Undo stays clickable; selectedFile is cleared
    /// once the toast dismisses.
    @State private var lingering = false
    @State private var scrollMonitor: Any?
    /// Starts false and flips on appear: the backdrop fades in over the grid
    /// (prototype: 0.45s ease) while the already-opaque stage flies.
    @State private var backdropVisible = false
    /// Palette computed on open when the DB has none (file not yet analyzed).
    /// The prototype always tints the backdrop and shows color swatches —
    /// that can't wait for an explicit Analyze run.
    @State private var computedPalette: [String] = []
    /// False until the current file's palette is known (DB or quick compute);
    /// the info column shows placeholder swatches meanwhile so the actions
    /// row mounts in its final position.
    @State private var paletteResolved = false
    /// Overlay's frame in SwiftUI .global coords; the scroll monitor uses
    /// minX to ignore scrolls over the sidebar.
    @State private var overlayGlobalFrame: CGRect = .zero

    init(file: FileNode) {
        self.file = file
        _currentURL = State(initialValue: file.url)
    }

    var body: some View {
        GeometryReader { geo in
            let overlayGlobal = geo.frame(in: .global)
            ZStack {
                if !lingering {
                    ViewerBackdrop(hexColor: details?.dominantColor ?? computedPalette.first)
                        .opacity(backdropVisible ? 1 : 0)
                        .animation(.easeOut(duration: 0.4), value: backdropVisible)
                        .contentShape(Rectangle())
                        .onTapGesture { startClose() }

                    HeroStage(url: currentURL,
                              sourceFrame: localSourceFrame(overlayGlobal: overlayGlobal,
                                                            viewport: geo.size),
                              viewport: geo.size,
                              burnProgress: burnProgress,
                              onCloseFinished: finishClose,
                              zoom: $zoom,
                              pan: $pan,
                              isClosing: $isClosing)

                    rightRail
                }
                ViewerToast(toast: $toast)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onAppear {
                viewportSize = geo.size
                overlayGlobalFrame = overlayGlobal
            }
            .onChange(of: geo.size) { _, s in viewportSize = s }
            .onChange(of: overlayGlobal) { _, f in overlayGlobalFrame = f }
        }
        .ignoresSafeArea()
        .background {
            // Detach key/click capture during the delete-linger state so the
            // grid stays fully interactive under the undo toast.
            if !lingering {
                KeyCaptureView(onLeft: { flip(-1) },
                               onRight: { flip(1) },
                               onReturn: {})
            }
        }
        .onAppear {
            installScrollMonitor()
            backdropVisible = true   // animated by the .animation on the backdrop
            withAnimation(.easeOut(duration: 0.4).delay(0.15)) { chromeVisible = true }
        }
        .onDisappear {
            removeScrollMonitor()
            appState.viewerClosing = false
            appState.viewerDismissing = false
            deleteTask?.cancel()
            if burning {
                // Unmounted mid-burn (sidebar navigation, window close):
                // finish the user's delete through the coordinator so the
                // Undo toast survives via GridToastHost.
                let url = currentURL
                let node = appState.currentFiles.first { $0.url == url }
                let appState = self.appState
                Task { @MainActor in
                    do {
                        let ticket = try await TrashManager.trash(url)
                        appState.currentFiles.removeAll { $0.url == url }
                        if appState.selectedFile?.url == url { appState.selectedFile = nil }
                        appState.deletion.toast = ToastData(message: "Moved to Trash",
                                                            actionLabel: "Undo") {
                            appState.deletion.restore(ticket: ticket,
                                                      node: node ?? FileNode(url: url))
                        }
                    } catch {
                        appState.deletion.toast = ToastData(message: "Couldn't move to Trash")
                    }
                }
            }
        }
        .onChange(of: appState.viewerClosing) { _, closing in
            guard closing else { return }
            if lingering || burnProgress > 0 {
                // Mid-burn or lingering after a delete: never run the return
                // flight on a burned image; Esc just dismisses the toast.
                if lingering {
                    withAnimation(.easeOut(duration: 0.18)) { toast = nil }
                }
                appState.viewerClosing = false
            } else {
                startClose()
            }
        }
        .onChange(of: toast?.id) { _, id in
            if lingering && id == nil { reallyFinish() }
        }
        .task(id: currentURL) { await loadDetails() }
    }

    // MARK: - Right rail (chrome row + info column, shared zoom backing)

    /// The chrome row rides inside the column's content stack, and the zoom
    /// backing card is that stack's layout-bound background — so the card
    /// resizes in the exact spring the expanders use, no measuring. The
    /// paddings compensate for the card's 12pt inset: on screen everything
    /// sits where it did (chrome at 32, cards 40 from the right edge).
    private var rightRail: some View {
        ViewerInfoColumn(url: currentURL,
                         details: details,
                         fallbackPalette: computedPalette,
                         paletteLoading: !paletteResolved,
                         backing: infoBackingColor,
                         backingVisible: zoom > 1.001,
                         refresh: { await loadDetails() },
                         onTagTap: { label in
                             appState.searchQuery = label
                             Task { await appState.runSearch(label) }
                             startClose()
                         },
                         onCollectionTap: { id in
                             appState.setActiveCollection(id)
                             startClose()
                         },
                         onOpenInFinder: {
                             NSWorkspace.shared.activateFileViewerSelecting([currentURL])
                         },
                         onDelete: deleteCurrent,
                         toast: $toast,
                         chrome: { chromeRow })
            // Catch taps in the gaps so they don't dismiss.
            .contentShape(Rectangle())
            .onTapGesture {}
            .padding(.top, 20)
            .padding(.bottom, 28)
            .padding(.trailing, ViewerGeometry.columnMargin - 12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            .opacity(chromeVisible ? 1 : 0)
            .allowsHitTesting(chromeVisible && !isClosing)
    }

    /// Dark card color behind the info column while zoomed: the image's
    /// dominant color darkened well past the backdrop's 0.55 wash, so the
    /// white text stays readable but the card still "belongs" to the image.
    private var infoBackingColor: Color {
        guard let hex = details?.dominantColor ?? computedPalette.first,
              let (r, g, b) = NamedColor.parse(hex) else {
            return Color(red: 0.14, green: 0.14, blue: 0.15)
        }
        let k = 0.32
        return Color(red: r * k, green: g * k, blue: b * k)
    }

    // MARK: - Chrome (✕ + zoom pill + Fit)

    private var chromeRow: some View {
        HStack(spacing: 8) {
            zoomPill
            if zoom > 1.001 { fitButton }
            Spacer()
            ShareButton(url: currentURL)
            if zoom <= 1.001 { closeButton }
        }
        .frame(width: ViewerGeometry.columnWidth)
    }

    private var zoomPill: some View {
        HStack(spacing: 0) {
            ChromePillButton(systemName: "minus") { setZoom(zoom / 1.25, animated: true) }
            Text(zoomReadout)
                .font(.system(size: 11, weight: .medium).monospacedDigit())
                .foregroundStyle(.white.opacity(0.85))
                .frame(minWidth: 38)
            ChromePillButton(systemName: "plus") { setZoom(zoom * 1.25, animated: true) }
        }
        .frame(height: 38)
        // Prototype chrome is white-glass: rgba(255,255,255,.10) at rest.
        .background(Capsule(style: .continuous).fill(.white.opacity(0.10)))
        // Segment hover fills are square — keep them inside the capsule ends.
        .clipShape(Capsule(style: .continuous))
    }

    private var fitButton: some View {
        ChromeTextButton(label: "Fit") {
            withAnimation(.easeOut(duration: 0.2)) { zoom = 1; pan = .zero }
        }
    }

    private var closeButton: some View {
        ChromeCircleButton(systemName: "xmark") { startClose() }
    }

    private var zoomReadout: String {
        guard zoom > 1.001 else { return "Fit" }
        if let n = naturalSize, n.width > 0 {
            let fitScale = currentFitRect.width / n.width
            return "\(Int(zoom * fitScale * 100))%"
        }
        return "\(Int(zoom * 100))%"
    }

    // MARK: - Geometry

    private var currentFitRect: CGRect {
        ViewerGeometry.fitRect(imageSize: naturalSize ?? CGSize(width: 1600, height: 1200),
                               viewport: viewportSize)
    }

    /// tileFrames are global (window) coords; the overlay may not start at the
    /// window origin (sidebar / titlebar), so convert via the overlay's own
    /// global frame. Fallback: a centered tile-sized rect.
    private func localSourceFrame(overlayGlobal: CGRect, viewport: CGSize) -> CGRect {
        if let f = appState.tileFrames[currentURL.path] {
            return f.offsetBy(dx: -overlayGlobal.minX, dy: -overlayGlobal.minY)
        }
        let side: CGFloat = 160
        return CGRect(x: (viewport.width - side) / 2,
                      y: (viewport.height - side) / 2,
                      width: side, height: side)
    }

    private func setZoom(_ z: CGFloat, animated: Bool = false) {
        let nz = ViewerGeometry.clampZoom(z)
        let fitted = currentFitRect.size
        if animated {
            withAnimation(.easeOut(duration: 0.15)) {
                zoom = nz
                pan = ViewerGeometry.clampPan(pan, fittedSize: fitted, zoom: nz)
            }
        } else {
            zoom = nz
            pan = ViewerGeometry.clampPan(pan, fittedSize: fitted, zoom: nz)
        }
    }

    // MARK: - Arrow-key flipping

    private func flip(_ delta: Int) {
        guard !isClosing, !lingering, !burning, burnProgress <= 0 else { return }
        let images = appState.visibleFiles.filter { isImageKind($0.kind) }
        guard !images.isEmpty,
              let idx = images.firstIndex(where: { $0.url == currentURL }) else { return }
        let next = images[(idx + delta + images.count) % images.count]
        guard next.url != currentURL else { return }
        computedPalette = []
        paletteResolved = false
        currentURL = next.url
    }

    private func isImageKind(_ kind: AssetKind) -> Bool {
        kind == .image || kind == .raw || kind == .psd
    }

    // MARK: - Close flight

    private func startClose() {
        guard !isClosing, !burning, burnProgress <= 0 else { return }
        withAnimation(.easeOut(duration: 0.12)) { chromeVisible = false }
        backdropVisible = false   // fades out during the close flight
        // Bring the toolbar back now so it fades in with the flight instead
        // of popping after it; the grid shift it causes is retargeted.
        withAnimation(.easeInOut(duration: 0.35)) { appState.viewerDismissing = true }
        isClosing = true
    }

    private func finishClose() {
        // Keep the undo toast alive past the flight; everything else unmounts.
        if toast != nil && toast?.action != nil {
            lingering = true
        } else {
            reallyFinish()
        }
    }

    private func reallyFinish() {
        appState.viewerClosing = false
        appState.selectedFile = nil
        appState.viewerDismissing = false
    }

    // MARK: - Delete / undo

    private func deleteCurrent() {
        guard !burning, !isClosing else { return }
        burning = true
        let url = currentURL
        let node = appState.currentFiles.first { $0.url == url }
        withAnimation(.easeOut(duration: 0.12)) { chromeVisible = false }
        withAnimation(.linear(duration: 0.7)) { burnProgress = 1 }
        deleteTask = Task {
            // Wait past full burn (clears ~0.66s) plus a short empty beat so the
            // image is fully gone before the return-to-grid transition.
            try? await Task.sleep(nanoseconds: 740_000_000)
            guard !Task.isCancelled else { return }
            await completeDelete(url: url, node: node)
        }
    }

    private func completeDelete(url: URL, node: FileNode?) async {
        do {
            let ticket = try await TrashManager.trash(url)
            burning = false
            // The burn has fully finished; now CLOSE back to the grid we came
            // from (main / tag / collection) — never linger on the burned frame
            // and never advance to the next image. The Undo toast is handed to
            // the always-present GridToastHost so it stays clickable over the
            // grid, and selectedFile = nil unmounts the viewer.
            withAnimation(.easeIn(duration: 0.2)) {
                appState.currentFiles.removeAll { $0.url == url }
            }
            appState.deletion.toast = ToastData(message: "Moved to Trash",
                                                actionLabel: "Undo") {
                appState.deletion.restore(ticket: ticket,
                                          node: node ?? FileNode(url: url))
            }
            appState.viewerClosing = false
            appState.viewerDismissing = false
            backdropVisible = false
            appState.selectedFile = nil
        } catch {
            withAnimation(.easeOut(duration: 0.18)) {
                toast = ToastData(message: "Couldn't move to Trash")
                burnProgress = 0
                burning = false
                chromeVisible = true
            }
            appState.viewerClosing = false
        }
    }

    // MARK: - Details loading

    private func loadDetails() async {
        let url = currentURL
        // Kick off the quick palette now (48px decode) rather than after the
        // DB read: swatches should land before the chrome fade-in finishes,
        // so the actions row never visibly shifts.
        async let quick = Self.quickPalette(at: url)
        var loaded: ViewerFileDetails? = nil
        if let queue = Database.shared.dbQueue {
            loaded = try? await ViewerFileDetails.load(queue: queue, path: url.path)
        }
        guard url == currentURL else { return }
        details = loaded
        if let px = loaded?.pixelSize {
            naturalSize = px
        } else {
            let s = await Task.detached(priority: .userInitiated) {
                Self.imagePixelSize(at: url)
            }.value
            if url == currentURL { naturalSize = s }
        }
        // No analysis data yet → derive backdrop tint + swatches right now.
        if let palette = loaded?.palette, !palette.isEmpty {
            paletteResolved = true
        } else {
            let pal = await quick
            if url == currentURL {
                withAnimation(.easeOut(duration: 0.25)) {
                    computedPalette = pal
                    paletteResolved = true
                }
            }
        }
    }

    /// Fast 3-swatch palette from a tiny downsample: coarse RGB-bucket
    /// histogram, top distinct buckets ordered dark → light (the prototype's
    /// swatch order). Display-only; Analyze still writes the real palette.
    nonisolated private static func quickPalette(at url: URL) async -> [String] {
        await Task.detached(priority: .userInitiated) { () -> [String] in
            guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, [
                      kCGImageSourceCreateThumbnailFromImageAlways: true,
                      kCGImageSourceThumbnailMaxPixelSize: 48,
                  ] as CFDictionary) else { return [] }
            let w = cg.width, h = cg.height
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
            var counts: [Int: Int] = [:]
            var sums: [Int: (r: Int, g: Int, b: Int)] = [:]
            for i in stride(from: 0, to: data.count, by: 4) {
                let r = Int(data[i]), g = Int(data[i + 1]), b = Int(data[i + 2])
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
        }.value
    }

    nonisolated private static func imagePixelSize(at url: URL) -> CGSize? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? CGFloat,
              let h = props[kCGImagePropertyPixelHeight] as? CGFloat else { return nil }
        return CGSize(width: w, height: h)
    }

    // MARK: - Scroll-wheel zoom (stage area only)

    /// Local monitor active while the viewer is mounted. Scrolls over the
    /// info column pass through (column keeps scrolling normally); scrolls
    /// over the stage zoom and are consumed.
    private func installScrollMonitor() {
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            guard !isClosing, !lingering, !burning, burnProgress <= 0,
                  let window = event.window, window.isKeyWindow else { return event }
            let width = window.contentView?.bounds.width ?? window.frame.width
            let columnLeft = width - ViewerGeometry.columnWidth - ViewerGeometry.columnMargin
            // locationInWindow is bottom-left origin, but X is unaffected by the
            // Y-flip — comparing against the overlay's global minX keeps scrolls
            // over the sidebar from zooming.
            guard event.locationInWindow.x >= overlayGlobalFrame.minX,
                  event.locationInWindow.x < columnLeft else { return event }
            let dy = event.scrollingDeltaY
            guard dy != 0 else { return event }
            setZoom(zoom * (dy > 0 ? 1.08 : 0.93))
            return nil
        }
    }

    private func removeScrollMonitor() {
        if let m = scrollMonitor {
            NSEvent.removeMonitor(m)
            scrollMonitor = nil
        }
    }
}

// MARK: - Chrome building blocks

/// 38pt circular button (the ✕), hover-brightening.
private struct ChromeCircleButton: View {
    let systemName: String
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(hovering ? 1.0 : 0.85))
                .frame(width: 38, height: 38)
                // Hover lightens, like every other chrome control (prototype:
                // rest .10 white, hover .24).
                .background(Circle().fill(.white.opacity(hovering ? 0.24 : 0.10)))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// − / ＋ segments inside the zoom pill.
private struct ChromePillButton: View {
    let systemName: String
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(hovering ? 1.0 : 0.7))
                .frame(width: 34, height: 38)
                .contentShape(Rectangle())
                // Explicit shape, not the bare-ShapeStyle background — that
                // overload ignores safe-area edges and smears the hover fill
                // into a full-height band beside the hidden toolbar area.
                .background(Rectangle().fill(hovering ? .white.opacity(0.20) : .clear))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// 38pt-tall capsule text button ("Fit").
private struct ChromeTextButton: View {
    let label: String
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(hovering ? 1.0 : 0.85))
                .padding(.horizontal, 14)
                .frame(height: 38)
                .background(Capsule(style: .continuous)
                    .fill(.white.opacity(hovering ? 0.24 : 0.10)))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
