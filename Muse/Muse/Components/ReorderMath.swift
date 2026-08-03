//
//  ReorderMath.swift
//  Muse
//
//  Pure reorder arithmetic shared by the sidebar's folder and collection
//  live-drag reorders (feat/next-50). Previously duplicated on SidebarView as
//  rowShift/collectionRowShift, reorderSlot/collectionReorderSlot, and
//  insertionLineY/collectionInsertionLineY — verified line-for-line mirrors.
//  No SwiftUI, no state: SidebarView still owns the @State + gestures + the
//  synchronous commit, and calls these for the math only. Unit-tested, joining
//  the pure-helper family (GridSelection, PageScroll, MasonryGeometry).
//

import CoreGraphics

enum ReorderMath {
    /// How far a non-dragged row at full index `i` slides to part and open a
    /// gap for the dragged row at `dropTarget` (an index among the "others").
    /// `pitch` = measured row height + inter-row spacing. 0 when no drag.
    static func rowShift(forIndex i: Int, draggedIndex: Int?,
                         dropTarget: Int?, pitch: CGFloat) -> CGFloat {
        guard let d = draggedIndex, let target = dropTarget, i != d else { return 0 }
        let removedIndex = i < d ? i : i - 1
        var shift: CGFloat = 0
        if i > d { shift -= pitch }                 // close the dragged row's hole
        if removedIndex >= target { shift += pitch } // open the gap at the target
        return shift
    }

    /// Insertion slot (0...count) for a drag at vertical position `y`, measured
    /// against the ORDERED start-frame snapshots of the "other" rows (the
    /// dragged row excluded). nil frames (unmeasured rows) are skipped.
    static func slot(forY y: CGFloat, orderedStartFrames: [CGRect?]) -> Int {
        for (i, f) in orderedStartFrames.enumerated() {
            guard let f else { continue }
            if y < f.midY { return i }
        }
        return orderedStartFrames.count
    }

    /// Y of the gap at `dropTarget`, measured against the ORDERED LIVE frames of
    /// the "other" rows (which reflect the parting offsets). nil if no target or
    /// no rows. Past-end target → last row's maxY; otherwise the target row's minY.
    static func insertionLineY(dropTarget: Int?, orderedLiveFrames: [CGRect?]) -> CGFloat? {
        guard let target = dropTarget else { return nil }
        guard !orderedLiveFrames.isEmpty else { return nil }
        if target >= orderedLiveFrames.count {
            return orderedLiveFrames.last.flatMap { $0?.maxY }
        }
        return orderedLiveFrames[target]?.minY
    }

    /// Which of two side-by-side columns a drag at horizontal position `x`
    /// belongs to, split at the container's midpoint. Added for the editor's
    /// workspace reorder, which is the sidebar's drag plus this one question.
    ///
    /// Deliberately NOT measured from the columns' own frames, the way `slot`
    /// measures rows: the workspace reorder can EMPTY a column, and an empty
    /// column has no frames to hit-test — you would be unable to drag anything
    /// back into it. The midpoint is always there.
    ///
    /// The midpoint itself resolves right, matching `slot`'s `y < midY`.
    static func isLeftColumn(x: CGFloat, containerWidth: CGFloat) -> Bool {
        x < containerWidth / 2
    }

    /// How far a row slides when the dragged item is ARRIVING from somewhere
    /// else — a different column, in the editor's two-column workspace.
    ///
    /// `rowShift` cannot serve this case. It assumes the dragged row was lifted
    /// out of THIS list, so it nets the hole that left against the gap being
    /// opened; passing it a nil `draggedIndex` (which is what a cross-column
    /// drag produces) makes it return 0, and the destination column would sit
    /// there refusing to part while the insertion line claimed a gap existed.
    /// Here nothing was removed, so the gap is real and unnetted: every row at
    /// or after the target moves down by one pitch.
    static func arrivingRowShift(forIndex i: Int, dropTarget: Int?,
                                 pitch: CGFloat) -> CGFloat {
        guard let target = dropTarget, i >= target else { return 0 }
        return pitch
    }
}
