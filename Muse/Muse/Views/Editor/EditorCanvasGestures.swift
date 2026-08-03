//
//  EditorCanvasGestures.swift
//  Muse
//
//  Pan, pinch, and the cursor discipline that goes with them — the Preview
//  page's contract, mirrored in Edit.
//
//  The cursor rules are the load-bearing part. A bare `NSCursor.set()` is
//  clobbered by AppKit's per-mouse-move cursor recalculation, so hover and drag
//  states are PUSHED; and a mismatched push/pop corrupts the cursor stack for
//  the whole app, so every push here is tracked by a flag and popped exactly
//  once, with `resetCursorState` unwinding whatever is left when Edit closes.
//

import SwiftUI
import AppKit

extension EditorView {
    // MARK: - Pan

    /// Drag-to-pan while zoomed, with the same open-hand / closed-fist cursors
    /// the Preview page uses — and the same push/pop discipline: a bare
    /// `.set()` is clobbered by AppKit's per-mouse-move cursor recalculation,
    /// and mismatched push/pop corrupts the stack for the whole app. See
    /// HeroStage, which this deliberately mirrors.
    func panGesture(canvas: CGSize) -> some Gesture {
        DragGesture()
            .onChanged { value in
                // The eyedropper and zone targeting own the drag while armed.
                guard isZoomed, !session.eyedropperArmed, !session.toneZoneTargeting
                else { return }
                if dragStartPan == nil {
                    isDraggingPan = true
                    session.cancelCanvasAnimation()
                    NSCursor.closedHand.push()
                }
                let start = dragStartPan ?? session.canvasPan
                dragStartPan = start
                session.canvasPan = ViewerGeometry.clampPan(
                    CGSize(width: start.width + value.translation.width,
                           height: start.height + value.translation.height),
                    fittedSize: fittedSize(in: canvas), zoom: session.canvasZoom)
            }
            .onEnded { _ in
                dragStartPan = nil
                guard isDraggingPan else { return }
                isDraggingPan = false
                NSCursor.pop()
            }
    }

    /// The free space the image FITS into: the window minus the two panels
    /// (and minus the chrome line at the top). Zoom is not clamped to it — the
    /// photo grows past it and under the panels, like Preview's does under the
    /// info column. Hiding the controls gives the whole window back.

    func magnifyGesture(canvas: CGSize) -> some Gesture {
        MagnifyGesture()
            .onChanged { value in
                guard !session.eyedropperArmed, !session.toneZoneTargeting else { return }
                let start = magnifyStartZoom ?? session.canvasZoom
                if magnifyStartZoom == nil { session.cancelCanvasAnimation() }
                magnifyStartZoom = start
                let next = ViewerGeometry.clampZoom(start * value.magnification)
                session.canvasZoom = next
                session.canvasPan = ViewerGeometry.clampPan(session.canvasPan,
                                                           fittedSize: fittedSize(in: canvas),
                                                           zoom: next)
            }
            .onEnded { _ in
                magnifyStartZoom = nil
                if abs(session.canvasZoom - 1) <= 0.001 { session.canvasPan = .zero }
                syncHoverCursor()
            }
    }

    /// The content's drawn size at zoom 1 — what the pan clamp is measured
    /// against, so you can never drag the photo off its own canvas. Shares
    /// `EditorCanvasGeometry` with the layout itself, rather than re-deriving
    /// the same fit a second time.
    func fittedSize(in canvas: CGSize) -> CGSize {
        EditorCanvasGeometry.fittedSize(canvas: canvas, insets: fitInsets,
                                        aspect: contentAspect)
    }

    func syncHoverCursor() {
        guard !isDraggingPan else { return }
        let shouldPush = isHoveringCanvas && isZoomed
            && !session.eyedropperArmed && !session.toneZoneTargeting
        if shouldPush && !isHoverPushed {
            isHoverPushed = true
            NSCursor.openHand.push()
        } else if !shouldPush && isHoverPushed {
            isHoverPushed = false
            NSCursor.pop()
        }
    }

    /// Unwinds this view's cursor pushes in LIFO order, so leaving Edit never
    /// leaves a stale hand haunting the rest of the app.
    func resetCursorState() {
        // The reorder fist is pushed last, so it pops first.
        if dragCursorPushed { dragCursorPushed = false; NSCursor.pop() }
        if isDraggingPan { isDraggingPan = false; NSCursor.pop() }
        if isHoverPushed { isHoverPushed = false; NSCursor.pop() }
        isHoveringCanvas = false
    }
}
