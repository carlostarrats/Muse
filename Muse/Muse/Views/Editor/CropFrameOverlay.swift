//
//  CropFrameOverlay.swift
//  Muse
//
//  The crop frame: an outline over the fitted photo with eight grab targets —
//  four thick corner brackets and four shorter mid-edge bars — plus a dim over
//  everything the crop discards. Dragging a handle resizes the window; the
//  photo itself never moves.
//
//  Ported from Surface Camera's overlay of the same name. Its rect convention
//  is ALREADY Muse's — normalized to the displayed image, top-left origin, y
//  down, exactly what `CropRect` and `EditRenderer.applyGeometry` use — so no
//  flip is needed anywhere between this view and the renderer.
//
//  What changed in the port: the input (iOS drag → macOS drag with a hover
//  cursor). The handles are drawn in Muse's own accent — they went white in the
//  port and were hard to find against a light photo.
//
//  All geometry here is POINTS. `EditCanvasView` positions this view over the
//  image's content rect, which `EditorCanvasGeometry` computes in points; this
//  file never sees a pixel, which is the invariant the editor canvas rework
//  established and must keep.
//

import SwiftUI
import AppKit

struct CropFrameOverlay: View {
    @Environment(\.theme) private var theme

    @Binding var rect: CropRect
    /// Locked aspect (width ÷ height, in PIXELS), or nil for freeform.
    var aspect: Double?
    /// The image's own width ÷ height. Required by the lock — a `CropRect`'s
    /// sides are fractions of DIFFERENT pixel extents, so the ratio has to be
    /// converted into normalized space before it can be enforced.
    var imageAspect: Double = 1
    /// Called once per completed drag — exactly one undo step per gesture, the
    /// same rule `EditSlider` follows.
    let onCommit: () -> Void

    /// Corner bracket arm length and bar thickness, matched to Apple's frame.
    private let cornerArm: CGFloat = 22
    private let barThickness: CGFloat = 4
    private let edgeBar: CGFloat = 30
    private let hairline: CGFloat = 1
    /// The drawn marks are thin. The grab area is not.
    private let hitSlop: CGFloat = 22

    @State private var dragStart: CropRect?

    var body: some View {
        GeometryReader { geo in
            let frame = pointFrame(in: geo.size)
            ZStack(alignment: .topLeading) {
                dimming(frame: frame, in: geo.size)
                Rectangle()
                    .strokeBorder(Color.white.opacity(0.9), lineWidth: hairline)
                    .frame(width: frame.width, height: frame.height)
                    .offset(x: frame.minX, y: frame.minY)
                    .allowsHitTesting(false)
                thirdsGuides(frame: frame)
                marks(frame: frame)
                handles(frame: frame, bounds: geo.size)
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Crop frame"))
    }

    private func pointFrame(in size: CGSize) -> CGRect {
        CGRect(x: rect.x * size.width, y: rect.y * size.height,
               width: rect.w * size.width, height: rect.h * size.height)
    }

    /// Everything OUTSIDE the window, dimmed, via an even-odd fill — so the
    /// kept area is never darkened and at full frame this paints nothing at all.
    private func dimming(frame: CGRect, in size: CGSize) -> some View {
        Path { p in
            p.addRect(CGRect(origin: .zero, size: size))
            p.addRect(frame)
        }
        .fill(Color.black.opacity(0.55), style: FillStyle(eoFill: true))
        .allowsHitTesting(false)
    }

    /// Rule-of-thirds guides — the standard framing aid, and the reason the
    /// frame is worth looking at rather than just dragging.
    private func thirdsGuides(frame: CGRect) -> some View {
        Path { p in
            for i in 1...2 {
                let fx = frame.minX + frame.width * CGFloat(i) / 3
                p.move(to: CGPoint(x: fx, y: frame.minY))
                p.addLine(to: CGPoint(x: fx, y: frame.maxY))
                let fy = frame.minY + frame.height * CGFloat(i) / 3
                p.move(to: CGPoint(x: frame.minX, y: fy))
                p.addLine(to: CGPoint(x: frame.maxX, y: fy))
            }
        }
        .stroke(Color.white.opacity(0.25), lineWidth: hairline)
        .allowsHitTesting(false)
    }

    private func marks(frame: CGRect) -> some View {
        ForEach(Array(CropDragMath.Handle.allCases.enumerated()), id: \.offset) { _, handle in
            markShape(for: handle, frame: frame)
                // The app's accent, not white: white brackets vanish into the
                // bright edge of a photo, which is exactly where you go looking
                // for them. The shadow stays — it's a legibility scrim that
                // keeps the accent readable over a light subject too.
                .fill(theme.controlAccent)
                .shadow(color: .black.opacity(0.4), radius: 1)
                .allowsHitTesting(false)
        }
    }

    private func markShape(for handle: CropDragMath.Handle, frame: CGRect) -> Path {
        let c = center(of: handle, in: frame)
        var p = Path()
        switch handle {
        case .topLeft, .topRight, .bottomLeft, .bottomRight:
            // Arms run INWARD from the corner, so the bracket sits inside the
            // frame rather than straddling it.
            let x = handle.movesLeftEdge ? c.x : c.x - cornerArm
            let y = handle.movesTopEdge ? c.y : c.y - cornerArm
            p.addRect(CGRect(x: x, y: c.y - barThickness / 2,
                             width: cornerArm, height: barThickness))
            p.addRect(CGRect(x: c.x - barThickness / 2, y: y,
                             width: barThickness, height: cornerArm))
        case .top, .bottom:
            p.addRect(CGRect(x: c.x - edgeBar / 2, y: c.y - barThickness / 2,
                             width: edgeBar, height: barThickness))
        case .left, .right:
            p.addRect(CGRect(x: c.x - barThickness / 2, y: c.y - edgeBar / 2,
                             width: barThickness, height: edgeBar))
        }
        return p
    }

    private func center(of handle: CropDragMath.Handle, in f: CGRect) -> CGPoint {
        let x = handle.movesLeftEdge ? f.minX : (handle.movesRightEdge ? f.maxX : f.midX)
        let y = handle.movesTopEdge ? f.minY : (handle.movesBottomEdge ? f.maxY : f.midY)
        return CGPoint(x: x, y: y)
    }

    private func handles(frame: CGRect, bounds: CGSize) -> some View {
        ForEach(Array(CropDragMath.Handle.allCases.enumerated()), id: \.offset) { _, handle in
            let c = center(of: handle, in: frame)
            Color.clear
                .contentShape(Rectangle())
                .frame(width: hitSlop * 2, height: hitSlop * 2)
                .offset(x: c.x - hitSlop, y: c.y - hitSlop)
                .onHover { inside in
                    // A crosshair is the honest cursor here: the handle resizes
                    // in both axes for a corner and one for an edge, and macOS
                    // has no single resize cursor that covers both.
                    if inside { NSCursor.crosshair.push() } else { NSCursor.pop() }
                }
                .gesture(dragGesture(for: handle, bounds: bounds))
        }
    }

    private func dragGesture(for handle: CropDragMath.Handle,
                             bounds: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                // Anchor to the rect the gesture STARTED from, so the frame
                // tracks the cursor instead of accelerating away from it —
                // `translation` is cumulative, not incremental.
                if dragStart == nil { dragStart = rect }
                guard let start = dragStart else { return }
                let delta = CGSize(width: value.translation.width / max(bounds.width, 1),
                                   height: value.translation.height / max(bounds.height, 1))
                rect = CropDragMath.resize(start, handle: handle, by: delta,
                                           aspect: aspect, imageAspect: imageAspect)
            }
            .onEnded { _ in
                dragStart = nil
                onCommit()
            }
    }
}
