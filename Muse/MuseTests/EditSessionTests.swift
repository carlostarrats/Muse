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

    /// Preview NEVER decodes full-res: the proxy is the hero ladder's formula,
    /// floored at 1600 and capped at 4096.
    func testProxyMaxPixelIsBoundedBothWays() {
        XCTAssertEqual(EditSession.proxyMaxPixel(canvasLongEdge: 100, scale: 2), 1600)
        XCTAssertEqual(EditSession.proxyMaxPixel(canvasLongEdge: 100_000, scale: 2), 4096)
        XCTAssertEqual(EditSession.proxyMaxPixel(canvasLongEdge: 1000, scale: 2), 4096)
        XCTAssertEqual(EditSession.proxyMaxPixel(canvasLongEdge: 500, scale: 2), 2500)
    }
}
