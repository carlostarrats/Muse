//
//  EditSession.swift
//  Muse
//
//  Per-file editor state — created on entering Edit mode, dropped on leaving.
//  Not a singleton: it belongs to one open photo, and a stale session is worse
//  than no session.
//
//  There is no Done/Cancel. The editor AUTOSAVES (400 ms debounce, plus an
//  immediate save on exit), because the grid updates live while editing and a
//  Cancel button would have to mean "put the grid back", which it can't
//  honestly promise. Undo is the escape hatch, and `edit_versions` is the
//  durable one.
//

import Foundation
import CoreImage

enum CompareMode: Equatable {
    case off
    case sideBySide
    /// Divider position, 0…1 from the left edge.
    case wipe(Double)
}

@MainActor
final class EditSession: ObservableObject {
    /// Long enough that a slider drag is one write, short enough that closing
    /// the lid right after a tweak still persists it.
    static let autosaveDelay: Duration = .milliseconds(400)

    let url: URL
    /// Whether this file's WB/NR/sharpen route through the RAW decoder.
    let isRaw: Bool

    @Published var draft: EditStack {
        didSet {
            guard draft != oldValue else { return }
            scheduleAutosave()
        }
    }
    @Published private(set) var history: EditHistory

    /// Hold-to-peek: the canvas shows the ORIGINAL while true.
    @Published var beforePeek = false
    @Published var compareMode: CompareMode = .off
    /// What "before" means for the wipe/side-by-side — nil is the original,
    /// otherwise a saved snapshot's stack.
    @Published var wipeAgainst: EditStack?

    @Published var canvasZoom: CGFloat = 1
    @Published var canvasPan: CGSize = .zero

    /// The WB eyedropper is armed — the next canvas click samples a pixel
    /// instead of panning.
    @Published var eyedropperArmed = false

    /// The live preview. Never full-res — see `proxyMaxPixel`.
    @Published private(set) var canvasImage: CIImage?
    /// The unedited render of the same proxy, cached so before/after and the
    /// wipe composite don't re-decode per frame.
    @Published private(set) var originalImage: CIImage?

    // MARK: - Readouts (Spec 05)

    /// The shared statistics of the last completed render. One value for
    /// histogram + clipping + zone mass, so a panel can never draw two of them
    /// from different frames.
    @Published private(set) var stats: EditStats?
    /// The smoothed-EV buffer at stats resolution. Deliberately NOT published:
    /// it changes every render and only hover reads it, so publishing it would
    /// re-render every observing panel for nothing.
    private(set) var zoneEVMap: ZoneEVMap?

    /// Statistics are computed ONLY while something is showing them — the Light
    /// or Scopes tab in Edit mode, never Preview.
    @Published var statsVisible = false
    /// Session-scoped, never persisted: zebras are a thing you switch on to
    /// check something, not a preference. Only the THRESHOLDS persist.
    @Published var zebrasOn = false
    /// Direct manipulation on the canvas. Behind an explicit mode because
    /// plain scroll has to keep zooming the canvas.
    @Published var toneZoneTargeting = false
    /// Which zone the cursor is over — drives the strip highlight, the readout
    /// and the canvas hatch.
    @Published var hoveredZone: Int?

    /// Resolution of the statistics tap. Small on purpose: a histogram of a
    /// 256px sample is indistinguishable from one of the full frame, and the
    /// difference in cost per slider tick is everything.
    static let statsSampleLongEdge = 256

    /// Called from the render loop after a completed render. One write for both
    /// fields keeps them mutually consistent for a single frame.
    func applyStats(_ stats: EditStats, zoneEVMap: ZoneEVMap?) {
        self.stats = stats
        self.zoneEVMap = zoneEVMap
    }

    /// Opening a stats panel doesn't change the draft, so no render is coming —
    /// tap the image that's already on screen instead of leaving the panel
    /// empty until the next slider touch.
    func refreshStats() {
        guard statsVisible, let image = canvasImage else { return }
        tapStats(from: image, maxPixel: Int(proxyLongEdge))
    }

    /// Latest-wins, one render in flight. A drag emits changes far faster than
    /// a 24 MP render completes.
    private let coalescer = RenderCoalescer<EditStack, CIImage>()
    private var autosaveTask: Task<Void, Never>?
    private var proxyLongEdge: CGFloat = 0

    init(url: URL, stack: EditStack?, isRaw: Bool = false) {
        self.url = url
        self.isRaw = isRaw
        let seed = stack ?? .fresh()
        self.draft = seed
        self.history = EditHistory(initial: seed)
    }

    // MARK: - History

    /// The SINGLE history push site. Called on gesture END, never per slider
    /// tick — otherwise one drag buries the user's real previous state under a
    /// hundred interpolated ones.
    func commitGesture() {
        history.push(draft)
    }

    func undo() {
        guard let previous = history.undo() else { return }
        draft = previous
    }

    func redo() {
        guard let next = history.redo() else { return }
        draft = next
    }

    var canUndo: Bool { history.canUndo }
    var canRedo: Bool { history.canRedo }

    // MARK: - Persistence

    func save() async {
        autosaveTask?.cancel()
        await EditStore.shared.save(draft, for: url)
    }

    func resetAll() {
        draft = .fresh()
        commitGesture()
        // A reset saves IMMEDIATELY rather than on the debounce: it's the one
        // action a user takes and then expects to see reflected everywhere at
        // once.
        Task { await save() }
    }

    /// Re-seed from storage — after switching to a saved version, where the
    /// stored stack is now the truth and the old history is about a stack the
    /// file no longer has.
    func reseed(from stack: EditStack?) {
        autosaveTask?.cancel()
        let seed = stack ?? .fresh()
        draft = seed
        history = EditHistory(initial: seed)
        autosaveTask?.cancel()
    }

    private func scheduleAutosave() {
        autosaveTask?.cancel()
        autosaveTask = Task { [weak self] in
            try? await Task.sleep(for: Self.autosaveDelay)
            guard !Task.isCancelled, let self else { return }
            await EditStore.shared.save(self.draft, for: self.url)
        }
    }

    // MARK: - Rendering

    /// Preview proxy size — the hero ladder's formula, capped at 4096. Preview
    /// NEVER decodes full-res: on an M1 Air a 60 MP full-res round trip per
    /// slider tick is the difference between an editor and a slideshow.
    static func proxyMaxPixel(canvasLongEdge: CGFloat, scale: CGFloat) -> Int {
        min(max(Int(canvasLongEdge * scale * 2.5), 1600), 4096)
    }

    /// (Re)build the proxy for a new canvas size, then render the draft.
    func updateCanvas(canvasLongEdge: CGFloat, scale: CGFloat) async {
        let maxPixel = Self.proxyMaxPixel(canvasLongEdge: canvasLongEdge, scale: scale)
        guard CGFloat(maxPixel) != proxyLongEdge else { return }
        proxyLongEdge = CGFloat(maxPixel)
        await renderOriginal(maxPixel: maxPixel)
        await renderDraft()
    }

    func renderDraft() async {
        let maxPixel = Int(proxyLongEdge)
        guard maxPixel > 0 else { return }
        let url = self.url
        let rendered = await coalescer.request(draft) { stack in
            await Task.detached(priority: .userInitiated) { () -> CIImage? in
                guard let cg = EditRenderer.render(url: url, stack: stack, maxPixel: maxPixel)
                else { return nil }
                return CIImage(cgImage: cg)
            }.value
        }
        if let rendered { canvasImage = rendered }
        if let rendered, statsVisible { tapStats(from: rendered, maxPixel: maxPixel) }
    }

    /// The statistics tap, piggybacked on the render that just completed — one
    /// small extra pass, never a second render loop and never full resolution.
    ///
    /// Gated on `statsVisible`, so the cost exists only while a panel is
    /// actually showing the numbers.
    private func tapStats(from displayImage: CIImage, maxPixel: Int) {
        let url = self.url
        let stack = draft
        let sampleEdge = Self.statsSampleLongEdge
        let highThreshold = AppSettings.editorZebraHigh
        let lowThreshold = AppSettings.editorZebraLow
        Task.detached(priority: .userInitiated) { [weak self] in
            let context = RenderContexts.preview
            guard let sample = Self.rgba8Sample(of: displayImage, longEdge: sampleEdge,
                                                context: context)
            else { return }
            let (histogram, clipping) = HistogramCompute.compute(
                rgba8: sample.bytes, width: sample.width, height: sample.height,
                highThreshold: highThreshold, lowThreshold: lowThreshold)

            // The zone tap reads the chain at position 2b — the tone-zone
            // stage's own input — so the mass bars and the hover readout
            // describe exactly the pixels the gains act on.
            var zoneMass: [Double] = []
            var evMap: ZoneEVMap?
            if let toneStage = EditRenderer.toneStageImage(url: url, stack: stack,
                                                           maxPixel: max(sampleEdge, 1)),
               let buffer = ToneZoneFilter.evBuffer(for: toneStage, longEdge: sampleEdge,
                                                    context: context) {
                zoneMass = HistogramCompute.zoneMass(evMap: buffer.values,
                                                     width: buffer.width, height: buffer.height)
                evMap = buffer
            }

            let stats = EditStats(histogram: histogram, clipping: clipping, zoneMass: zoneMass,
                                  curveHistogram: HistogramCompute.curveHistogram(from: histogram))
            await MainActor.run { [weak self] in
                self?.applyStats(stats, zoneEVMap: evMap)
            }
        }
    }

    /// Downsample to `longEdge` and read back RGBA8 — the histogram's input.
    private nonisolated static func rgba8Sample(of image: CIImage, longEdge: Int,
                                                context: CIContext)
        -> (bytes: [UInt8], width: Int, height: Int)? {
        let extent = image.extent
        guard extent.width > 0, extent.height > 0, extent.width.isFinite, extent.height.isFinite
        else { return nil }
        let scale = min(CGFloat(longEdge) / max(extent.width, extent.height), 1)
        let scaled = scale < 1
            ? image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            : image
        let rect = scaled.extent
        let width = Int(rect.width.rounded(.down)), height = Int(rect.height.rounded(.down))
        guard width > 0, height > 0 else { return nil }
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        bytes.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return }
            context.render(scaled, toBitmap: base, rowBytes: width * 4,
                           bounds: CGRect(x: rect.minX, y: rect.minY,
                                          width: CGFloat(width), height: CGFloat(height)),
                           format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        }
        return (bytes, width, height)
    }

    /// The original render is refreshed only when the PROXY changes, not per
    /// slider tick — it can't change under an edit, and re-rendering it during
    /// a drag would double the work for nothing.
    private func renderOriginal(maxPixel: Int) async {
        let url = self.url
        originalImage = await Task.detached(priority: .userInitiated) { () -> CIImage? in
            guard let cg = EditRenderer.render(url: url, stack: .fresh(), maxPixel: maxPixel)
            else { return nil }
            return CIImage(cgImage: cg)
        }.value
    }

    /// Render an arbitrary stack at the current proxy size — the compare
    /// picker's "against this snapshot" case.
    func renderComparison(_ stack: EditStack) async -> CIImage? {
        let maxPixel = Int(proxyLongEdge)
        guard maxPixel > 0 else { return nil }
        let url = self.url
        return await Task.detached(priority: .userInitiated) { () -> CIImage? in
            guard let cg = EditRenderer.render(url: url, stack: stack, maxPixel: maxPixel)
            else { return nil }
            return CIImage(cgImage: cg)
        }.value
    }

    /// What the canvas should draw right now, accounting for peek.
    var displayImage: CIImage? {
        beforePeek ? (originalImage ?? canvasImage) : canvasImage
    }
}
