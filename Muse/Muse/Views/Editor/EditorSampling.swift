//
//  EditorSampling.swift
//  Muse
//
//  What the editor READS off the photo, as opposed to what it writes onto it:
//  the statistics gate, the tone-zone EV mask and its hover/scroll targeting,
//  the Insights feedback query, and the white-balance eyedropper.
//
//  Two of these share a hard-won correction. Both the eyedropper and the EV
//  hover used to rebuild a fit against the WHOLE window while the renderer
//  fitted against the window minus the panels — so they sampled the wrong pixel
//  whenever the panels were showing. They now map through
//  `EditorCanvasGeometry.unitPoint`, against the content rect the canvas view
//  actually occupies.
//

import SwiftUI
import AppKit
import CoreImage

extension EditorView {
    // MARK: - Readouts, target mode, feedback

    /// Statistics cost something, so they run only while a panel is showing
    /// them — the Light card (curve backdrop + zone mass) or Scopes. Collapsing
    /// both stops the pass, which is the point of making the cards collapsible.
    func updateStatsVisibility() {
        let visible = expanded.contains(Section.light)
            || expanded.contains(Section.zones)      // the strip draws zone mass
            || expanded.contains(Section.histogram)
        session.statsVisible = visible
        if visible {
            session.refreshStats()
        } else {
            session.hoveredZone = nil
        }
    }

    /// Build the hatch overlay's mask for the current draft. Lazy — most
    /// sessions never hover a zone, and this is a decode.
    func buildZoneMaskIfNeeded() async {
        guard zoneMask == nil || zoneMaskStack != session.draft else { return }
        let url = session.url
        let stack = session.draft
        let edge = max(Int(max(canvasSize.width, canvasSize.height)), 1)
        let mask = await Task.detached(priority: .userInitiated) { () -> CIImage? in
            guard let toneStage = EditRenderer.toneStageImage(url: url, stack: stack,
                                                              maxPixel: edge)
            else { return nil }
            return ToneZoneFilter.smoothedEVMap(for: toneStage, longEdge: CGFloat(edge))
        }.value
        guard session.draft == stack else { return }
        zoneMask = mask
        zoneMaskStack = stack
    }

    /// Target mode: hovering the canvas reads the SMOOTHED mask's EV, so the
    /// number shown is the number the scroll wheel then moves.
    func handleTargetHover(_ phase: HoverPhase, content: CGRect) {
        guard session.toneZoneTargeting else { return }
        switch phase {
        case .active(let location):
            NSCursor.crosshair.set()
            // The hover point is in the WINDOW-sized gesture surface; shift it
            // into the content's own coordinates before mapping.
            let local = CGPoint(x: location.x - content.minX, y: location.y - content.minY)
            guard let ev = sampleEV(at: local, content: content.size) else { return }
            hoveredEV = ev
            session.hoveredZone = ToneZoneMath.zoneIndex(forEV: ev)
        case .ended:
            NSCursor.arrow.set()
            hoveredEV = nil
            session.hoveredZone = nil
        @unknown default:
            break
        }
    }

    func sampleEV(at point: CGPoint, content: CGSize) -> Double? {
        guard let map = session.zoneEVMap, map.width > 0, map.height > 0,
              session.canvasImage != nil else { return nil }
        // A division, because the content rect IS the image's rect. This used
        // to rebuild a fit from the FULL window while the renderer fitted into
        // the window minus the panels, so it read the wrong pixel whenever the
        // panels were showing.
        guard let unit = EditorCanvasGeometry.unitPoint(inContentOfSize: content, at: point)
        else { return nil }
        let x = min(max(Int(unit.x * Double(map.width)), 0), map.width - 1)
        let y = min(max(Int(unit.y * Double(map.height)), 0), map.height - 1)
        return Double(map.values[y * map.width + x])
    }

    /// Scroll adjusts the hovered zone while targeting, and is CONSUMED so the
    /// canvas doesn't zoom underneath the gesture.
    func handleTargetScroll(_ event: NSEvent) -> Bool {
        guard session.toneZoneTargeting, let zone = session.hoveredZone else { return false }
        let scrollGainPerTick = 0.02
        let deltaY = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.deltaY
        session.draft.setToneZone { params in
            var gains = params.clamped().gains
            gains[zone] = min(max(gains[zone] + Double(deltaY) * scrollGainPerTick, -1), 1)
            params = ToneZoneParams(gains: gains)
        }
        // One history entry per burst of scrolling, matching the slider's
        // push-on-gesture-end contract.
        targetCommitTask?.cancel()
        targetCommitTask = Task {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            session.commitGesture()
        }
        return true
    }

    func loadFeedback() async {
        let path = session.url.path
        feedbackNotes = await Task.detached(priority: .utility) { () -> [PhotoFeedback.Note] in
            guard let queue = Database.shared.dbQueue,
                  let inputs = try? queue.read({ db in
                      try PhotoStatsQueries.feedbackInputs(path: path, db: db)
                  }) ?? nil
            else { return [] }
            return PhotoFeedback.notes(for: inputs)
        }.value
    }

    // MARK: - Eyedropper

    /// Sample the PROXY the canvas is already showing, map the pixel to a
    /// temperature/tint pair, and store those as ordinary slider values.
    ///
    /// The stack stays declarative: what's stored is the resulting offsets,
    /// never the click location. A stored location would have to be re-sampled
    /// on every render and would point somewhere else the moment a crop moved.
    func sampleWhiteBalance(at location: CGPoint, content: CGSize) {
        session.eyedropperArmed = false
        guard let image = session.originalImage ?? session.canvasImage else { return }
        let extent = image.extent
        guard extent.width > 0, extent.height > 0 else { return }
        // `location` is already in the canvas view's own space — the overlay
        // sits ON the canvas, which is the image's rect. Same correction as
        // sampleEV: the old path fitted against the whole window.
        guard let unit = EditorCanvasGeometry.unitPoint(inContentOfSize: content, at: location)
        else { return }   // clicked the backdrop: sampling it would set WB from grey

        // CIImage's origin is bottom-left; the click's is top-left.
        let px = extent.minX + CGFloat(unit.x) * extent.width
        let py = extent.minY + CGFloat(1 - unit.y) * extent.height
        var bytes = [UInt8](repeating: 0, count: 4)
        RenderContexts.preview.render(
            image, toBitmap: &bytes, rowBytes: 4,
            bounds: CGRect(x: px, y: py, width: 1, height: 1),
            format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        let solved = WBEyedropper.solve(sampledColor: (r: Double(bytes[0]) / 255,
                                                       g: Double(bytes[1]) / 255,
                                                       b: Double(bytes[2]) / 255))
        session.draft.setColor {
            $0.temperature = solved.temperature
            $0.tint = solved.tint
        }
        session.commitGesture()
    }
}
