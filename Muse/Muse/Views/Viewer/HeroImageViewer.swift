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
    @State private var viewportSize: CGSize = .zero
    /// After the close flight lands with an undo toast still showing, we keep
    /// only the toast mounted so Undo stays clickable; selectedFile is cleared
    /// once the toast dismisses.
    @State private var lingering = false
    @State private var scrollMonitor: Any?
    @State private var backdropVisible = true
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
                    ViewerBackdrop(hexColor: details?.dominantColor)
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

                    infoColumn
                    chromeRow
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
            withAnimation(.easeOut(duration: 0.4).delay(0.15)) { chromeVisible = true }
        }
        .onDisappear {
            removeScrollMonitor()
            appState.viewerClosing = false
        }
        .onChange(of: appState.viewerClosing) { _, closing in
            if closing { startClose() }
        }
        .onChange(of: toast?.id) { _, id in
            if lingering && id == nil { reallyFinish() }
        }
        .task(id: currentURL) { await loadDetails() }
    }

    // MARK: - Info column

    private var infoColumn: some View {
        ViewerInfoColumn(url: currentURL,
                         details: details,
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
                         toast: $toast)
            // Catch taps in the gaps between cards so they don't dismiss.
            .contentShape(Rectangle())
            .onTapGesture {}
            .padding(.top, 80)
            .padding(.bottom, 40)
            .padding(.trailing, ViewerGeometry.columnMargin)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            .opacity(chromeVisible ? 1 : 0)
            .allowsHitTesting(chromeVisible && !isClosing)
    }

    // MARK: - Chrome (✕ + zoom pill + Fit)

    private var chromeRow: some View {
        HStack(spacing: 8) {
            zoomPill
            if zoom > 1.001 { fitButton }
            Spacer()
            if zoom <= 1.001 { closeButton }
        }
        .frame(width: ViewerGeometry.columnWidth)
        .padding(.top, 18)
        .padding(.trailing, ViewerGeometry.columnMargin)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        .opacity(chromeVisible ? 1 : 0)
        .allowsHitTesting(chromeVisible && !isClosing)
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
        .background(Capsule(style: .continuous).fill(.black.opacity(0.35)))
        .overlay(Capsule(style: .continuous).stroke(.white.opacity(0.12), lineWidth: 1))
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
        guard !isClosing, !lingering, !burning else { return }
        let images = appState.visibleFiles.filter { isImageKind($0.kind) }
        guard !images.isEmpty,
              let idx = images.firstIndex(where: { $0.url == currentURL }) else { return }
        let next = images[(idx + delta + images.count) % images.count]
        guard next.url != currentURL else { return }
        currentURL = next.url
    }

    private func isImageKind(_ kind: AssetKind) -> Bool {
        kind == .image || kind == .raw || kind == .psd
    }

    // MARK: - Close flight

    private func startClose() {
        guard !isClosing, !burning else { return }
        withAnimation(.easeOut(duration: 0.12)) { chromeVisible = false }
        backdropVisible = false   // fades out during the close flight
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
    }

    // MARK: - Delete / undo

    private func deleteCurrent() {
        guard !burning, !isClosing else { return }
        burning = true
        let url = currentURL
        let node = appState.currentFiles.first { $0.url == url }
        withAnimation(.easeOut(duration: 0.12)) { chromeVisible = false }
        withAnimation(.linear(duration: 0.8)) { burnProgress = 1 }
        Task {
            try? await Task.sleep(nanoseconds: 850_000_000)
            completeDelete(url: url, node: node)
        }
    }

    private func completeDelete(url: URL, node: FileNode?) {
        do {
            let ticket = try TrashManager.trash(url)
            withAnimation(.easeIn(duration: 0.2)) {
                appState.currentFiles.removeAll { $0.url == url }
            }
            withAnimation(.easeOut(duration: 0.18)) {
                toast = ToastData(message: "Moved to Trash", actionLabel: "Undo") {
                    appState.deletion.restore(ticket: ticket,
                                              node: node ?? FileNode(url: url))
                }
            }
            backdropVisible = false
            finishClose()   // image is fully burned out — no return flight
        } catch {
            withAnimation(.easeOut(duration: 0.18)) {
                toast = ToastData(message: "Couldn't move to Trash")
                burnProgress = 0
                burning = false
                chromeVisible = true
            }
        }
    }

    // MARK: - Details loading

    private func loadDetails() async {
        let url = currentURL
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
            guard !isClosing, !lingering,
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
                .foregroundStyle(.white.opacity(hovering ? 1.0 : 0.8))
                .frame(width: 38, height: 38)
                .background(Circle().fill(.black.opacity(hovering ? 0.55 : 0.35)))
                .overlay(Circle().stroke(.white.opacity(0.12), lineWidth: 1))
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
                .background(hovering ? .white.opacity(0.12) : .clear)
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
                .foregroundStyle(.white.opacity(hovering ? 1.0 : 0.8))
                .padding(.horizontal, 14)
                .frame(height: 38)
                .background(Capsule(style: .continuous)
                    .fill(.black.opacity(hovering ? 0.55 : 0.35)))
                .overlay(Capsule(style: .continuous).stroke(.white.opacity(0.12), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
