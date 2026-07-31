import XCTest
@testable import Muse

final class EditHistoryTests: XCTestCase {
    func stack(_ ev: Double) -> EditStack {
        var s = EditStack.fresh()
        var t = ToneParams.neutral; t.exposureEV = ev
        s.adjustments = [.tone(t)]
        return s
    }

    func testPushDedupesIdenticalState() {
        var h = EditHistory(initial: stack(0))
        h.push(stack(1))
        h.push(stack(1))
        XCTAssertTrue(h.canUndo)
        _ = h.undo()
        XCTAssertFalse(h.canUndo)
    }

    func testTruncatesForwardOnPushAfterUndo() {
        var h = EditHistory(initial: stack(0))
        h.push(stack(1))
        h.push(stack(2))
        _ = h.undo()
        XCTAssertTrue(h.canRedo)
        h.push(stack(3))
        XCTAssertFalse(h.canRedo)
    }

    func testUndoRedoEdges() {
        var h = EditHistory(initial: stack(0))
        XCTAssertFalse(h.canUndo)
        XCTAssertFalse(h.canRedo)
        XCTAssertNil(h.undo())
        h.push(stack(1))
        XCTAssertEqual(h.undo(), stack(0))
        XCTAssertEqual(h.redo(), stack(1))
        XCTAssertNil(h.redo())
    }

    func testCapacityDropsOldest() {
        var h = EditHistory(initial: stack(0))
        for i in 1...105 { h.push(stack(Double(i))) }
        var undoCount = 0
        while h.canUndo { _ = h.undo(); undoCount += 1 }
        XCTAssertLessThanOrEqual(undoCount, EditHistory.capacity)
        XCTAssertGreaterThan(undoCount, 0)
    }

    func testCurrentTracksTheCursorAfterCapacityTrim() {
        var h = EditHistory(initial: stack(0))
        for i in 1...150 { h.push(stack(Double(i))) }
        XCTAssertEqual(h.current, stack(150))
    }
}
