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
}
