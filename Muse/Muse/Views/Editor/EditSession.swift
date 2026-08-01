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
