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
// AppKit for `seedCanvas`'s NSImage only. This file lives in Views/, not in
// the platform-neutral `Editing/` module the audit guards.
import AppKit

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
            // The pending crop frame is expressed in DISPLAY space, which is
            // defined by the draft's own rotation and flips. Any change to the
            // geometry therefore invalidates it — and the draft is replaced
            // wholesale by more paths than the crop card can know about
            // (applying a preset, pasting adjustments, restoring a snapshot,
            // Reset, undo/redo). Resyncing HERE is the only place that catches
            // all of them.
            if cropMode, draft.geometryParams != oldValue.geometryParams {
                pendingCrop = displayCrop
            }
        }
    }
    @Published private(set) var history: EditHistory

    /// Hold-to-peek: the canvas shows the ORIGINAL while true.
    @Published var beforePeek = false
    /// Compare owns the canvas the same way crop does — side-by-side makes it
    /// twice as wide as the photo, so a crop frame drawn over it would span
    /// both panes. Whichever mode is turned on last wins, in both directions.
    @Published var compareMode: CompareMode = .off {
        didSet {
            guard compareMode != oldValue, compareMode != .off else { return }
            cropMode = false
        }
    }
    /// What "before" means for the wipe/side-by-side — nil is the original,
    /// otherwise a saved snapshot's stack.
    @Published var wipeAgainst: EditStack?
    /// Compare against the preview Lightroom baked into the file, rather than
    /// against Muse's own render of a stack. Offered only for a stack whose
    /// origin is `.lightroom` and only when the file actually carries one —
    /// Muse's mapping is directional, and holding it up against Adobe's own
    /// render is worth more than any amount of reassurance in a report.
    @Published var compareEmbeddedPreview = false

    @Published var canvasZoom: CGFloat = 1
    @Published var canvasPan: CGSize = .zero

    /// Drives `canvasZoom`/`canvasPan` frame by frame.
    ///
    /// SwiftUI can't animate these: the canvas is an MTKView behind an
    /// NSViewRepresentable, and a `withAnimation` on a published value only
    /// re-renders it once, at the final value — so zooming jumped while the
    /// Preview page (a plain Image with `.scaleEffect`) glided. The frames are
    /// produced here instead.
    private var zoomAnimation: Task<Void, Never>?

    func animateCanvas(zoom target: CGFloat, pan targetPan: CGSize? = nil,
                       duration: Double = 0.18) {
        zoomAnimation?.cancel()
        let fromZoom = canvasZoom
        let fromPan = canvasPan
        let toPan = targetPan ?? canvasPan
        guard abs(target - fromZoom) > 0.0001 || toPan != fromPan else { return }
        let frames = max(1, Int(duration * 60))
        zoomAnimation = Task { @MainActor [weak self] in
            for frame in 1...frames {
                if Task.isCancelled { return }
                let t = Double(frame) / Double(frames)
                let eased = 1 - pow(1 - t, 3)          // easeOut, the viewer's curve
                self?.canvasZoom = fromZoom + (target - fromZoom) * eased
                self?.canvasPan = CGSize(
                    width: fromPan.width + (toPan.width - fromPan.width) * eased,
                    height: fromPan.height + (toPan.height - fromPan.height) * eased)
                try? await Task.sleep(for: .milliseconds(16))
            }
            guard !Task.isCancelled else { return }
            self?.canvasZoom = target
            self?.canvasPan = toPan
        }
    }

    func cancelCanvasAnimation() { zoomAnimation?.cancel() }

    /// Everything except the image is hidden. Lives on the session rather than
    /// in EditorView because the Preview | Edit switch belongs to the hero
    /// viewer, and "only see the image" has to mean that one too.
    @Published var uiHidden = false

    /// The WB eyedropper is armed — the next canvas click samples a pixel
    /// instead of panning.
    @Published var eyedropperArmed = false {
        didSet {
            guard eyedropperArmed, eyedropperArmed != oldValue else { return }
            cropMode = false
        }
    }

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
    @Published var toneZoneTargeting = false {
        didSet {
            guard toneZoneTargeting, toneZoneTargeting != oldValue else { return }
            cropMode = false
        }
    }
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

    // MARK: - Crop mode

    /// While true the canvas renders the image with its crop forced to FULL and
    /// the frame drawn over it, so you frame against the whole picture and can
    /// pull the frame back OUT to reclaim area you cut earlier. That is Apple
    /// Photos' behaviour, and the same trick Surface uses via
    /// `CropGeometry.withFullRect()`.
    @Published var cropMode = false {
        didSet {
            guard cropMode != oldValue else { return }
            if cropMode {
                // Compare and crop are BOTH canvas modes, and side-by-side
                // makes the canvas twice as wide as the photo
                // (`EditorCanvasGeometry.contentAspect`) — the crop frame would
                // span both panes and map to nothing real. One owner at a time.
                compareMode = .off
                beforePeek = false
                eyedropperArmed = false
                toneZoneTargeting = false
                hoveredZone = nil
            }
            // Entering snapshots the stored rect (mapped into the space the
            // user is LOOKING at); leaving discards the pending copy wholesale.
            // Abandoning the frame must cost nothing.
            pendingCrop = cropMode ? displayCrop : nil
            Task { await renderDraft() }
        }
    }

    /// The stored crop, placed on the DISPLAYED image.
    ///
    /// `applyGeometry` crops before it flips and turns, so `crop` is in SOURCE
    /// coordinates while the editor shows the photo already turned. Everything
    /// the crop card touches works in display space and converts on the way in
    /// and out — see `CropDragMath`'s note.
    var displayCrop: CropRect {
        let g = draft.geometryParams ?? .neutral
        return CropDragMath.displayRect(fromSource: g.crop ?? .full,
                                        quarterTurns: g.quarterTurns,
                                        flipH: g.flipH, flipV: g.flipV)
    }

    /// The pending display rect converted back for storage.
    var pendingCropInSourceSpace: CropRect? {
        guard let pendingCrop else { return nil }
        let g = draft.geometryParams ?? .neutral
        return CropDragMath.sourceRect(fromDisplay: pendingCrop,
                                       quarterTurns: g.quarterTurns,
                                       flipH: g.flipH, flipV: g.flipV)
    }

    /// The aspect the user is LOOKING at — the source's, transposed by an odd
    /// number of quarter turns. Preset fitting and the aspect lock both need
    /// this rather than the raw source aspect.
    var displayAspect: Double {
        CropDragMath.displayAspect(source: imageAspect,
                                   quarterTurns: draft.geometryParams?.quarterTurns ?? 0)
    }

    /// The crop RECTANGLE being framed. Committed into `draft` only on Apply,
    /// so an abandoned drag never reaches the autosave or the grid.
    ///
    /// Only the rectangle is transactional, and deliberately: it is the one
    /// control you set up over several drags before you mean it. Straighten,
    /// rotate and flip are direct actions — rotating a photo is not a crop, and
    /// gating them behind entering crop mode made the card feel like a mode
    /// switch rather than a set of tools.
    @Published var pendingCrop: CropRect?

    /// True once the pending frame differs from what is stored — what makes
    /// Apply live. Choosing the shape you are already on is not an edit.
    var cropHasPendingChange: Bool {
        guard cropMode, let pendingCrop else { return false }
        // Both sides in DISPLAY space — comparing a display rect against a
        // stored source rect would report a change on every rotated photo.
        return pendingCrop != displayCrop
    }

    /// The stack to RENDER right now.
    ///
    /// In crop mode the crop is forced full, so you frame against the whole
    /// photo and can pull the frame back out to reclaim area you cut earlier.
    /// That is Apple Photos' behaviour. Straighten and rotation still show
    /// live, because those are not pending.
    var renderStack: EditStack {
        guard cropMode else { return draft }
        var s = draft
        s.setGeometry { $0.crop = .full }
        return s
    }

    /// The source image's aspect (width ÷ height), for fitting a preset and for
    /// the straighten inset. Falls back to 1 before the first render lands.
    var imageAspect: Double {
        guard let extent = originalImage?.extent,
              extent.width > 0, extent.height > 0,
              extent.width.isFinite, extent.height.isFinite else { return 1 }
        return Double(extent.width / extent.height)
    }

    // MARK: - Auto tone

    /// Cached for the life of the session, which is what makes Auto
    /// IDEMPOTENT: it always measures the same original, so a second press
    /// computes the same answer instead of compounding the first one.
    ///
    /// `originalImage` is the unedited render of the proxy the session already
    /// keeps for before/after, so this costs one small downsample and no extra
    /// decode. Deliberately NOT `stats`, which describes the DRAFT and only
    /// exists while a stats panel is open.
    private var autoToneCache: AutoToneStats.Result?

    /// The long edge of the on-demand original render used when Auto is
    /// pressed before the proxy exists. Small on purpose: `rgba8Sample`
    /// downsamples to `statsSampleLongEdge` (256) either way, so both paths
    /// measure a 256px frame and a bigger render would buy resampling
    /// differences, not information — the same reasoning that sets the sample
    /// size in the first place. Not bit-identical to the proxy path (the
    /// resampler starts from a different source size), which does not matter:
    /// these are histogram statistics of the same picture, and whichever runs
    /// first is cached for the session, so Auto stays idempotent.
    static let autoToneFallbackLongEdge = 1024

    func autoToneResult() async -> AutoToneStats.Result? {
        if let autoToneCache { return autoToneCache }
        // Auto used to `return nil` when `originalImage` was nil — a SILENT
        // no-op if you pressed it before the first render landed. The window
        // was always there and got easier to hit once entering Edit started
        // seeding the canvas, because the editor now looks ready on the first
        // frame instead of sitting empty: nothing on screen says "not yet".
        // Rendering the original on demand makes the press always do
        // something. It costs nothing in the normal case, where the render has
        // landed and this branch never runs.
        let image: CIImage
        if let originalImage {
            image = originalImage
        } else {
            let url = self.url
            let edge = Self.autoToneFallbackLongEdge
            guard let fallback = await Task.detached(priority: .userInitiated,
                                                     operation: { () -> CIImage? in
                guard let cg = EditRenderer.render(url: url, stack: .fresh(), maxPixel: edge)
                else { return nil }
                return CIImage(cgImage: cg)
            }).value else { return nil }
            image = fallback
        }
        let sampleEdge = Self.statsSampleLongEdge
        let result = await Task.detached(priority: .userInitiated) {
            () -> AutoToneStats.Result? in
            guard let sample = Self.rgba8Sample(of: image, longEdge: sampleEdge,
                                                context: RenderContexts.preview)
            else { return nil }
            return AutoToneStats.compute(rgba8: sample.bytes,
                                         width: sample.width, height: sample.height)
        }.value
        autoToneCache = result
        return result
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
        let wanted = CGFloat(canvasLongEdge * scale * 2.5)
        return proxyLadder.first { CGFloat($0) >= wanted } ?? proxyLadder[proxyLadder.count - 1]
    }

    /// Proxy sizes, quantized — the same lesson as `ThumbnailCache`'s hero
    /// fallback ladder, for a different reason.
    ///
    /// This used to be a continuous `min(max(edge * scale * 2.5, 1600), 4096)`,
    /// and `EditorView` rebuilds the proxy from a `.task(id: canvasSize)`. So
    /// during a live window resize EVERY pixel of drag changed the target by a
    /// few pixels, which cleared the `!=` guard in `updateCanvas` and kicked off
    /// a fresh `renderOriginal` + `renderDraft` — a decode and a full
    /// edit-stack render, per frame, at up to 4096px. `.task(id:)` cancels the
    /// previous one, but the `Task.detached` inside doesn't check cancellation,
    /// so a fast drag queued dozens of full renders that all ran to completion.
    /// That is the jagged motion: the canvas wasn't slow to re-fit, it was
    /// competing with its own backlog.
    ///
    /// On a ladder, a drag crosses a rung a handful of times at most; between
    /// rungs the proxy is reused and resizing is pure geometry. The rungs are
    /// close enough that the visible resolution never drops noticeably — the
    /// proxy is already 2.5× the canvas.
    nonisolated static let proxyLadder: [Int] = [1600, 2048, 2560, 3072, 4096]

    /// Whether a proxy has ever been built for this session — i.e. whether the
    /// next `updateCanvas` is the FIRST one (mount) or a resize.
    var hasProxy: Bool { proxyLongEdge > 0 }

    /// Open the canvas on the image the Preview page is already showing.
    ///
    /// Synchronous and best-effort: it is a placeholder for the ~200–400 ms it
    /// takes the real proxy to decode and render, not a substitute for it. Only
    /// ever fills an EMPTY canvas, so it can never override a real render.
    ///
    /// The image handed in is the hero's own decode, which `HeroStage` already
    /// renders through the saved stack — so this is the same photo with the
    /// same edits, and `contentAspect` (which otherwise falls back to a 3:2
    /// guess) is right on the first frame too.
    func seedCanvas(with placeholder: NSImage?) {
        guard canvasImage == nil, let placeholder,
              let cg = placeholder.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else { return }
        canvasImage = CIImage(cgImage: cg)
    }

    /// (Re)build the proxy for a new canvas size, then render the draft.
    func updateCanvas(canvasLongEdge: CGFloat, scale: CGFloat) async {
        let maxPixel = Self.proxyMaxPixel(canvasLongEdge: canvasLongEdge, scale: scale)
        guard CGFloat(maxPixel) != proxyLongEdge else {
            return
        }
        proxyLongEdge = CGFloat(maxPixel)
        await renderOriginal(maxPixel: maxPixel)
        await renderDraft()
    }

    func renderDraft() async {
        let maxPixel = Int(proxyLongEdge)
        guard maxPixel > 0 else { return }
        let url = self.url
        // `renderStack`, not `draft`: in crop mode the crop is forced full so
        // you frame against the WHOLE photo. Identical to `draft` otherwise,
        // and it stays the coalescer's key so a crop-mode toggle re-renders.
        let rendered = await coalescer.request(renderStack) { stack in
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
            // Read HERE, not before the hop. This opens the file and reads its
            // properties, and `tapStats` runs on every completed render while a
            // readout panel is showing — so on the main actor it was sync file
            // I/O per slider frame.
            let headroom = EditRenderer.sourceHeadroom(url: url)
            // An HDR photo is sampled in FLOAT. `rgba8Sample` renders through
            // `.RGBA8`/sRGB, which clamps before the statistics even run — so
            // every specular highlight landed at 255 and the panel reported it
            // as clipped. See `HistogramCompute.compute(rgbaFloat:…)`.
            let histogram: HistogramData
            let clipping: ClippingStats
            if headroom > HDRDecode.hdrThreshold,
               let sample = Self.rgbaFloatSample(of: displayImage, longEdge: sampleEdge,
                                                 context: context) {
                (histogram, clipping) = HistogramCompute.compute(
                    rgbaFloat: sample.values, width: sample.width, height: sample.height,
                    headroom: headroom,
                    highThreshold: highThreshold, lowThreshold: lowThreshold)
            } else {
                guard let sample = Self.rgba8Sample(of: displayImage, longEdge: sampleEdge,
                                                    context: context)
                else { return }
                (histogram, clipping) = HistogramCompute.compute(
                    rgba8: sample.bytes, width: sample.width, height: sample.height,
                    highThreshold: highThreshold, lowThreshold: lowThreshold)
            }

            // The zone tap reads the chain at position 2b — the tone-zone
            // stage's own input — so the mass bars and the hover readout
            // describe exactly the pixels the gains act on.
            // Bound as `let`s: the `MainActor.run` closure below is @Sendable,
            // so capturing mutable locals across it is a data race (an error
            // under the Swift 6 language mode).
            let evMap: ZoneEVMap? = EditRenderer
                .toneStageImage(url: url, stack: stack, maxPixel: max(sampleEdge, 1))
                .flatMap { ToneZoneFilter.evBuffer(for: $0, longEdge: sampleEdge,
                                                   context: context) }
            let zoneMass: [Double] = evMap.map {
                HistogramCompute.zoneMass(evMap: $0.values, width: $0.width, height: $0.height)
            } ?? []

            let stats = EditStats(histogram: histogram, clipping: clipping, zoneMass: zoneMass,
                                  curveHistogram: HistogramCompute.curveHistogram(from: histogram))
            await MainActor.run { [weak self] in
                self?.applyStats(stats, zoneEVMap: evMap)
            }
        }
    }

    /// Downsample to `longEdge` and read back RGBA8 — the histogram's input.
    /// Internal rather than private: the auto-tone tap above reads the ORIGINAL
    /// through this same downsample.
    nonisolated static func rgba8Sample(of image: CIImage, longEdge: Int,
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

    /// The HDR sibling of `rgba8Sample`. Renders half-float in extended linear
    /// so values above 1.0 survive to the statistics — `.RGBA8`/sRGB clamps
    /// them first, which is what made every HDR highlight read as clipped.
    nonisolated static func rgbaFloatSample(of image: CIImage, longEdge: Int,
                                            context: CIContext)
        -> (values: [Float], width: Int, height: Int)? {
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
        var values = [Float](repeating: 0, count: width * height * 4)
        values.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return }
            context.render(scaled, toBitmap: base,
                           rowBytes: width * 4 * MemoryLayout<Float>.size,
                           bounds: CGRect(x: rect.minX, y: rect.minY,
                                          width: CGFloat(width), height: CGFloat(height)),
                           format: .RGBAf,
                           colorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB))
        }
        return (values, width, height)
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

    /// The embedded preview at proxy scale, or nil when the file carries none.
    func renderEmbeddedPreview() async -> CIImage? {
        let url = self.url
        let maxPixel = Int(proxyLongEdge)
        guard maxPixel > 0 else { return nil }
        return await Task.detached(priority: .userInitiated) { () -> CIImage? in
            guard let cg = EmbeddedPreview.image(for: url, maxPixel: maxPixel) else { return nil }
            return CIImage(cgImage: cg)
        }.value
    }

    /// What the canvas should draw right now, accounting for peek.
    var displayImage: CIImage? {
        beforePeek ? (originalImage ?? canvasImage) : canvasImage
    }
}
