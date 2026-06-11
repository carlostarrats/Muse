import SwiftUI

/// The flying image: animates from the grid tile rect to the fitted rect and
/// back, then hosts zoom (1–4x) and drag-pan when zoomed.
/// Timings from the approved prototype: open 0.4s gentle ease-out,
/// close 0.34s with a hint of settle.
struct HeroStage: View {
    let url: URL
    let sourceFrame: CGRect          // tile frame, global coords
    let viewport: CGSize
    var burnProgress: Double = 0
    var onCloseFinished: () -> Void

    @Binding var zoom: CGFloat
    @Binding var pan: CGSize
    @Binding var isClosing: Bool     // set true by parent to run the return flight

    @State private var displayRect: CGRect = .zero
    @State private var image: NSImage?
    @State private var dragStartPan: CGSize? = nil

    private var fitRect: CGRect {
        ViewerGeometry.fitRect(imageSize: image?.size ?? sourceFrame.size,
                               viewport: viewport)
    }

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: displayRect.width, height: displayRect.height)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .modifier(BurnUpModifier(progress: burnProgress,
                                             seed: Double(SeededRandom.fnv1a([url.path]) % 1000) / 1000.0,
                                             size: displayRect.size))
                    .shadow(color: .black.opacity(0.5), radius: 40, y: 24)
                    .scaleEffect(zoom)
                    .offset(pan)
                    .position(x: displayRect.midX, y: displayRect.midY)
                    .gesture(panGesture)
            }
        }
        .onAppear { open() }
        .onChange(of: isClosing) { _, closing in if closing { close() } }
        .onChange(of: url) { _, _ in flipTo() }
        .onChange(of: viewport) { _, _ in
            // spec: re-fit live on window resize (but never mid-burn — the
            // shader's size uniform would jump the char pattern)
            guard !isClosing, burnProgress <= 0 else { return }
            withAnimation(.easeOut(duration: 0.2)) { displayRect = fitRect }
        }
        .task(id: url) { await loadFullRes() }
    }

    private func open() {
        displayRect = sourceFrame
        // thumbnail immediately so launch is instant
        Task {
            image = await ThumbnailCache.shared.thumbnail(
                for: url, size: CGSize(width: 320, height: 320))
            withAnimation(.timingCurve(0.25, 0.8, 0.25, 1, duration: 0.4)) {
                displayRect = fitRect
            }
        }
    }

    private func close() {
        withAnimation(.timingCurve(0.3, 1.08, 0.35, 1, duration: 0.34)) {
            zoom = 1; pan = .zero
            displayRect = sourceFrame
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.36) { onCloseFinished() }
    }

    private func flipTo() {
        zoom = 1; pan = .zero
        // thumbnail swaps in fast; .task(id: url) handles the full-res load
        Task {
            image = await ThumbnailCache.shared.thumbnail(
                for: url, size: CGSize(width: 320, height: 320))
            withAnimation(.easeOut(duration: 0.2)) { displayRect = fitRect }
        }
    }

    private func loadFullRes() async {
        let u = url
        let img = await Task.detached(priority: .userInitiated) { NSImage(contentsOf: u) }.value
        if let img, u == url {
            image = img
            withAnimation(.easeOut(duration: 0.2)) { displayRect = fitRect }
        }
    }

    private var panGesture: some Gesture {
        DragGesture()
            .onChanged { v in
                guard zoom > 1, burnProgress <= 0 else { return }
                let start = dragStartPan ?? pan
                dragStartPan = start
                pan = ViewerGeometry.clampPan(
                    CGSize(width: start.width + v.translation.width,
                           height: start.height + v.translation.height),
                    fittedSize: displayRect.size, zoom: zoom)
            }
            .onEnded { _ in dragStartPan = nil }
    }
}
