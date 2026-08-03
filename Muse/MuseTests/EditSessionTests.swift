import XCTest
@testable import Muse

@MainActor
final class EditSessionTests: XCTestCase {
    private func session(_ stack: EditStack? = nil) -> EditSession {
        EditSession(url: URL(fileURLWithPath: "/tmp/session-fixture.jpg"), stack: stack)
    }

    func testInitSeedsDraftFromProvidedStack() {
        var stack = EditStack.fresh()
        stack.setTone { $0.exposureEV = 1 }
        XCTAssertEqual(session(stack).draft, stack)
    }

    func testInitWithNilStackSeedsFresh() {
        XCTAssertTrue(session().draft.isNeutral)
    }

    /// `commitGesture` is the SINGLE history push site — mutating the draft
    /// (which happens continuously under a slider drag) must not push.
    func testCommitGestureIsTheOnlyHistoryPushSite() {
        let s = session()
        s.draft.setTone { $0.exposureEV = 1 }
        XCTAssertFalse(s.canUndo)
        s.commitGesture()
        XCTAssertTrue(s.canUndo)
    }

    func testUndoRedoUpdateDraft() {
        let s = session()
        s.draft.setTone { $0.exposureEV = 1 }
        s.commitGesture()
        s.undo()
        XCTAssertTrue(s.draft.isNeutral)
        s.redo()
        XCTAssertEqual(s.draft.toneParams?.exposureEV, 1)
    }

    func testCommittingAnUnchangedDraftDoesNotConsumeAnUndoStep() {
        let s = session()
        s.draft.setTone { $0.exposureEV = 1 }
        s.commitGesture()
        s.commitGesture()
        s.undo()
        XCTAssertFalse(s.canUndo)
    }

    func testResetAllReturnsToFresh() {
        let s = session()
        s.draft.setTone { $0.exposureEV = 3 }
        s.commitGesture()
        s.resetAll()
        XCTAssertTrue(s.draft.isNeutral)
    }

    func testResetIsUndoable() {
        let s = session()
        s.draft.setTone { $0.exposureEV = 3 }
        s.commitGesture()
        s.resetAll()
        s.undo()
        XCTAssertEqual(s.draft.toneParams?.exposureEV, 3)
    }

    /// After switching to a saved version the old history is about a stack the
    /// file no longer has, so it's discarded rather than left as a trap.
    func testReseedReplacesDraftAndClearsHistory() {
        let s = session()
        s.draft.setTone { $0.exposureEV = 1 }
        s.commitGesture()
        var other = EditStack.fresh()
        other.setColor { $0.saturation = 0.5 }
        s.reseed(from: other)
        XCTAssertEqual(s.draft, other)
        XCTAssertFalse(s.canUndo)
        XCTAssertFalse(s.canRedo)
    }

    func testDisplayImageFallsBackWhenPeekingWithNoOriginalRendered() {
        let s = session()
        s.beforePeek = true
        XCTAssertNil(s.displayImage)
    }

    /// Preview NEVER decodes full-res: floored at 1600, capped at 4096.
    func testProxyMaxPixelIsBoundedBothWays() {
        XCTAssertEqual(EditSession.proxyMaxPixel(canvasLongEdge: 100, scale: 2), 1600)
        XCTAssertEqual(EditSession.proxyMaxPixel(canvasLongEdge: 100_000, scale: 2), 4096)
        XCTAssertEqual(EditSession.proxyMaxPixel(canvasLongEdge: 1000, scale: 2), 4096)
        // 500 × 2 × 2.5 = 2500 → the rung ABOVE it. Was 2500 exactly, when the
        // formula was continuous.
        XCTAssertEqual(EditSession.proxyMaxPixel(canvasLongEdge: 500, scale: 2), 2560)
    }

    /// The point of the ladder: a live window resize must NOT change the proxy
    /// on every pixel of drag, because each change costs a decode plus a full
    /// edit-stack render. Only rung crossings may — so the cost of a drag is
    /// bounded by the LADDER's length, never by the drag's.
    func testProxyMaxPixelChangesAreBoundedByTheLadderNotTheDrag() {
        // 800 samples across the whole usable canvas range.
        let samples = stride(from: 100.0, through: 900.0, by: 1.0)
            .map { EditSession.proxyMaxPixel(canvasLongEdge: $0, scale: 2) }
        var changes = 0
        for (a, b) in zip(samples, samples.dropFirst()) where a != b { changes += 1 }
        XCTAssertLessThan(changes, EditSession.proxyLadder.count,
                          "the proxy rebuilt \(changes) times across an 800-step drag; "
                          + "with a ladder of \(EditSession.proxyLadder.count) rungs it can "
                          + "cross at most \(EditSession.proxyLadder.count - 1)")
    }

    /// And within a rung it doesn't move at all.
    func testProxyMaxPixelIsStableWithinARung() {
        // 300pt × 2 × 2.5 = 1500, comfortably inside the 1600 rung.
        let values = Set(stride(from: 300.0, through: 315.0, by: 1.0)
            .map { EditSession.proxyMaxPixel(canvasLongEdge: $0, scale: 2) })
        XCTAssertEqual(values, [1600])
    }

    /// Every rung is on the ladder, and the ladder only ascends — a
    /// non-monotonic step would make a resize flip between two proxies.
    func testProxyMaxPixelIsMonotonicAndOnTheLadder() {
        var previous = 0
        for edge in stride(from: 50.0, through: 2000.0, by: 5.0) {
            let v = EditSession.proxyMaxPixel(canvasLongEdge: edge, scale: 2)
            XCTAssertTrue(EditSession.proxyLadder.contains(v), "\(v) is not a ladder rung")
            XCTAssertGreaterThanOrEqual(v, previous, "proxy size went DOWN as the canvas grew")
            previous = v
        }
    }
}

// MARK: - Spec 05 readouts

extension EditSessionTests {

    private func session() -> EditSession {
        EditSession(url: URL(fileURLWithPath: "/tmp/x.jpg"), stack: nil)
    }

    /// Statistics cost something, so nothing computes until a panel is showing
    /// them — never in Preview.
    func testStatsVisibleDefaultsFalseAndStatsStartEmpty() {
        let s = session()
        XCTAssertFalse(s.statsVisible)
        XCTAssertNil(s.stats)
        XCTAssertNil(s.zoneEVMap)
    }

    /// Zebras are a check you switch on, not a preference — a fresh session
    /// never inherits another's toggle, and nothing is persisted.
    func testZebrasOnIsSessionScoped() {
        let a = session()
        a.zebrasOn = true
        XCTAssertFalse(session().zebrasOn)
    }

    func testToneZoneTargetingAndHoveredZoneDefaults() {
        let s = session()
        XCTAssertFalse(s.toneZoneTargeting)
        XCTAssertNil(s.hoveredZone)
    }

    /// One write for both fields: a panel must never draw a histogram from one
    /// frame beside zone mass from another.
    func testApplyStatsStoresHistogramClippingAndZoneMapTogether() {
        let s = session()
        let hist = HistogramData(r: [1, 0], g: [1, 0], b: [1, 0], luma: [1, 0])
        var clip = ClippingStats.none
        clip.highR = 0.1
        let stats = EditStats(histogram: hist, clipping: clip, zoneMass: [0.5],
                              curveHistogram: CurveHistogram(bins: [1, 0]))
        let map = ZoneEVMap(width: 1, height: 1, values: [-4])
        s.applyStats(stats, zoneEVMap: map)
        XCTAssertEqual(s.stats, stats)
        XCTAssertEqual(s.zoneEVMap?.values, [-4])
    }

    // MARK: - Auto-tone before the first render

    /// Auto used to bail to nil when `originalImage` was nil, so pressing it
    /// in the window before the first render landed did NOTHING, silently —
    /// and seeding the canvas made that window easier to hit, because the
    /// editor now looks ready on the first frame. It renders the original on
    /// demand instead. `updateCanvas` is never called here, so `originalImage`
    /// is nil for the whole test: this is exactly the pre-render state.
    func testAutoToneMeasuresWithoutWaitingForTheFirstRender() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("autotone-\(UUID().uuidString).png")
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 64, pixelsHigh: 64,
                                   bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false,
                                   isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)!
        // A gradient, not a flat fill: auto-tone measures spread, and a single
        // colour has none — it would pass on a degenerate input.
        for x in 0..<64 {
            for y in 0..<64 {
                let v = CGFloat(x) / 63
                rep.setColor(NSColor(deviceRed: v, green: v, blue: v, alpha: 1), atX: x, y: y)
            }
        }
        try rep.representation(using: .png, properties: [:])!.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let s = EditSession(url: url, stack: nil)
        XCTAssertNil(s.originalImage, "precondition: no render has landed yet")
        let result = await s.autoToneResult()
        XCTAssertNotNil(result, "Auto silently did nothing before the first render")
    }

    /// Cached for the session's life, which is what keeps Auto idempotent —
    /// a second press must measure the same original, not compound the first.
    /// That has to hold for the on-demand render too.
    func testAutoToneResultIsCachedAcrossPresses() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("autotone-\(UUID().uuidString).png")
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 32, pixelsHigh: 32,
                                   bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false,
                                   isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)!
        for x in 0..<32 {
            for y in 0..<32 {
                let v = CGFloat(y) / 31
                rep.setColor(NSColor(deviceRed: v, green: v, blue: v, alpha: 1), atX: x, y: y)
            }
        }
        try rep.representation(using: .png, properties: [:])!.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let s = EditSession(url: url, stack: nil)
        let first = await s.autoToneResult()
        let second = await s.autoToneResult()
        XCTAssertNotNil(first)
        XCTAssertEqual(first, second)
    }

    /// The fallback render is deliberately small — both paths downsample to
    /// `statsSampleLongEdge` before measuring, so a larger one would buy
    /// resampling differences, not information.
    func testAutoToneFallbackRenderIsSmallerThanTheSmallestProxyRung() {
        XCTAssertLessThan(EditSession.autoToneFallbackLongEdge,
                          EditSession.proxyLadder.first!)
        XCTAssertGreaterThan(EditSession.autoToneFallbackLongEdge,
                             EditSession.statsSampleLongEdge)
    }

    // MARK: - Opening canvas

    private func swatch(w: Int, h: Int) -> NSImage {
        let img = NSImage(size: NSSize(width: w, height: h))
        img.lockFocus()
        NSColor.red.setFill()
        NSRect(x: 0, y: 0, width: w, height: h).fill()
        img.unlockFocus()
        return img
    }

    /// Entering Edit used to mount an EMPTY canvas — nothing on screen until a
    /// proxy decode + full stack render landed, which is the photo vanishing
    /// and popping back. The session opens on the hero's decoded pixels instead.
    func testSeedCanvasFillsAnEmptyCanvas() throws {
        let s = session()
        XCTAssertNil(s.canvasImage)
        s.seedCanvas(with: swatch(w: 40, h: 20))
        XCTAssertNotNil(s.canvasImage)
        // Right ASPECT on the first frame too — `contentAspect` otherwise falls
        // back to a 3:2 guess and the canvas snaps shape when the proxy lands.
        // Aspect, not size: the seed carries the image's PIXELS, which on a
        // Retina-backed NSImage are its points times the backing scale. The
        // canvas fits by aspect, so only the ratio has to survive.
        let extent = try XCTUnwrap(s.canvasImage?.extent)
        XCTAssertEqual(extent.width / extent.height, 2, accuracy: 0.001)
    }

    /// It is a placeholder, never an override: a real render always wins.
    func testSeedCanvasNeverReplacesAnExistingCanvas() {
        let s = session()
        s.seedCanvas(with: swatch(w: 40, h: 20))
        let first = s.canvasImage?.extent.width
        s.seedCanvas(with: swatch(w: 400, h: 200))
        XCTAssertEqual(s.canvasImage?.extent.width, first)
    }

    func testSeedCanvasWithNoImageIsANoOp() {
        let s = session()
        s.seedCanvas(with: nil)
        XCTAssertNil(s.canvasImage)
    }

    /// The proxy-rebuild debounce is skipped on the FIRST build (mount) and
    /// applied on resizes; `hasProxy` is that distinction.
    func testHasProxyIsFalseBeforeAnyCanvasBuild() {
        XCTAssertFalse(session().hasProxy)
    }

    func testStatsSampleLongEdgeIsSmallOnPurpose() {
        // A 256px sample's histogram is indistinguishable from the full frame's,
        // and the difference in cost per slider tick is the whole feature.
        XCTAssertEqual(EditSession.statsSampleLongEdge, 256)
    }
}
