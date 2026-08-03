//
//  EditorReorderDrag.swift
//  Muse
//
//  The reorder-mode drag: gesture, parting math, insertion line and the
//  floating copy under the cursor.
//
//  Deliberately the SIDEBAR's reorder, not a second design — same
//  part-and-insert, same insertion rule, same `ReorderMath`. Learn it in one
//  place and you know it in the other. The only new question is which COLUMN
//  the pointer is over, and that is a midpoint split rather than a hit-test
//  against the columns' frames, because this reorder can EMPTY a column and an
//  empty column has no frames to hit.
//

import SwiftUI
import AppKit

extension EditorView {
    // MARK: - Workspace reorder

    /// The drag, mirroring `SidebarView`'s folder reorder exactly: the dragged
    /// bar is hidden in place so its slot stays and the others can part around
    /// it, an opaque copy follows the cursor on top, and a thin accent rule
    /// marks the gap it will land in.
    func reorderGesture(_ module: EditorModule) -> some Gesture {
        DragGesture(coordinateSpace: .named(Self.reorderSpace))
            .onChanged { value in
                if draggingModule != module {
                    // A layout snapshot is needed to compute slots; without one
                    // everything would resolve to "append to end".
                    guard !moduleFrames.isEmpty else { return }
                    draggingModule = module
                    dragStartFrames = moduleFrames
                    NSCursor.closedHand.push()
                    dragCursorPushed = true
                }
                dragTranslation = value.translation
                // A midpoint split, not a hit-test against the columns' frames:
                // a column can be EMPTY here, and an empty column has no frames
                // to hit — you could never drag anything back into it.
                let column: EditorColumn = ReorderMath.isLeftColumn(
                    x: value.location.x, containerWidth: canvasSize.width) ? .left : .right
                let slot = ReorderMath.slot(
                    forY: value.location.y,
                    orderedStartFrames: otherModules(in: column).map { dragStartFrames[$0] })
                if slot != dropTarget || column != dropColumn {
                    // Animate the PARTING only, never the finger-follow offset.
                    withAnimation(.easeInOut(duration: 0.16)) {
                        dropTarget = slot
                        dropColumn = column
                    }
                }
            }
            .onEnded { _ in commitReorder(module) }
    }

    /// The visible modules of `column` EXCLUDING the dragged one — insertion
    /// happens among these, since the dragged bar is conceptually lifted out
    /// and its own frame moves with the drag.
    func otherModules(in column: EditorColumn) -> [EditorModule] {
        workspace.active.visible(in: column).filter { $0 != draggingModule }
    }

    /// How far a non-dragged bar slides to part and open the gap. The pitch is
    /// the bar's height plus the panel VStack's spacing, both known constants
    /// in this mode — every card is collapsed to the same bar.
    ///
    /// TWO cases, and they are not the same sum. When the bar came out of THIS
    /// column there is a hole to close as well as a gap to open, and below the
    /// dragged row those cancel. When it is arriving from the OTHER column
    /// nothing was removed here, so the gap is unnetted. Using the within-column
    /// formula for both is what made cross-column drags refuse to part: it
    /// wants a `draggedIndex`, a cross-column drag has none in this list, and it
    /// answers 0 — leaving the insertion line pointing at a gap that never
    /// opened.
    func rowShift(_ module: EditorModule, in column: EditorColumn, index: Int) -> CGFloat {
        guard let dragging = draggingModule, dragging != module,
              column == dropColumn else { return 0 }
        let pitch = EditorReorderRow.height + 14
        guard let draggedIndex = workspace.active.visible(in: column).firstIndex(of: dragging)
        else {
            return ReorderMath.arrivingRowShift(forIndex: index, dropTarget: dropTarget,
                                                pitch: pitch)
        }
        return ReorderMath.rowShift(forIndex: index, draggedIndex: draggedIndex,
                                    dropTarget: dropTarget, pitch: pitch)
    }

    /// Commit WITHOUT animation: after parting, the bars are already in their
    /// final visual positions, so writing the array and clearing the offsets in
    /// the same frame is seamless. Animating here would double-move them.
    func commitReorder(_ module: EditorModule) {
        defer {
            draggingModule = nil
            dropTarget = nil
            dragStartFrames = [:]
            dragTranslation = .zero
            if dragCursorPushed { dragCursorPushed = false; NSCursor.pop() }
        }
        guard draggingModule == module, let slot = dropTarget else { return }
        var next = workspace.active
        next.move(module, toColumn: dropColumn, visibleSlot: slot)
        workspace.updateDraft(next)
    }

    func moveAll(to column: EditorColumn) {
        var next = workspace.active
        next.moveAll(to: column)
        withAnimation(.easeInOut(duration: 0.2)) { workspace.updateDraft(next) }
    }

    /// A thin accent rule at the gap the bar will land in — an overshoot cue.
    ///
    /// It draws in the `PanelContrast`-resolved accent, the same colour as a
    /// selected tab or an active tool row. The editor backdrop runs white to
    /// black, so a fixed blue is illegible on at least one of the five levels.
    @ViewBuilder
    var insertionLine: some View {
        if draggingModule != nil,
           let y = ReorderMath.insertionLineY(
               dropTarget: dropTarget,
               orderedLiveFrames: otherModules(in: dropColumn).map { moduleFrames[$0] }) {
            RoundedRectangle(cornerRadius: 1)
                .fill(ink.selectionFill)
                .frame(width: ViewerGeometry.columnWidth, height: 2)
                .position(x: columnCentreX(dropColumn), y: y)
                .allowsHitTesting(false)
        }
    }

    /// Where a column's cards are centred, in the reorder space. Derived rather
    /// than measured so it is still right for an EMPTY column, which has no
    /// frames to average.
    func columnCentreX(_ column: EditorColumn) -> CGFloat {
        let margin = ViewerGeometry.columnMargin
        let half = ViewerGeometry.columnWidth / 2
        return column == .left ? margin + half : canvasSize.width - margin - half
    }

    /// An opaque copy of the dragged bar, above every bar it passes — a single
    /// floating copy is simpler and more reliable than per-row zIndex juggling.
    @ViewBuilder
    var draggedModuleOverlay: some View {
        if let module = draggingModule, let start = dragStartFrames[module] {
            EditorReorderRow(module: module, ink: ink, isFloatingCopy: true)
                .frame(width: ViewerGeometry.columnWidth)
                .scaleEffect(1.02)
                .shadow(color: .black.opacity(0.22), radius: 6, y: 3)
                .position(x: start.midX + dragTranslation.width,
                          y: start.midY + dragTranslation.height)
                .allowsHitTesting(false)
        }
    }
}
