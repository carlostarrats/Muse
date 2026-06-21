//
//  ReorderMathTests.swift
//  MuseTests
//
//  Pure tests for ReorderMath — the de-duplicated sidebar folder/collection
//  reorder arithmetic (feat/next-50 code-health refactor).
//

import XCTest
import CoreGraphics
@testable import Muse

final class ReorderMathTests: XCTestCase {
    // 28 row height + 1 inter-row spacing (matches SidebarView.rowHeight + 1).
    private let pitch: CGFloat = 29

    // MARK: rowShift

    func testRowShiftNoDragIsZero() {
        XCTAssertEqual(ReorderMath.rowShift(forIndex: 2, draggedIndex: nil, dropTarget: nil, pitch: pitch), 0)
    }

    func testRowShiftDraggedRowItselfIsZero() {
        XCTAssertEqual(ReorderMath.rowShift(forIndex: 1, draggedIndex: 1, dropTarget: 3, pitch: pitch), 0)
    }

    func testRowShiftRowBelowDraggedAtOwnSlotStays() {
        // i=3 > d=1 → -pitch; removedIndex=2, target=2 → 2>=2 → +pitch → net 0.
        XCTAssertEqual(ReorderMath.rowShift(forIndex: 3, draggedIndex: 1, dropTarget: 2, pitch: pitch), 0)
    }

    func testRowShiftRowBelowDraggedWithEarlyTargetRises() {
        // i=3 > d=1 → -pitch; removedIndex=2, target=3 → 2>=3 false → net -pitch.
        XCTAssertEqual(ReorderMath.rowShift(forIndex: 3, draggedIndex: 1, dropTarget: 3, pitch: pitch), -pitch)
    }

    func testRowShiftRowAboveDraggedAtTargetSinks() {
        // i=0 < d=2 → no -pitch; removedIndex=0, target=0 → 0>=0 → +pitch.
        XCTAssertEqual(ReorderMath.rowShift(forIndex: 0, draggedIndex: 2, dropTarget: 0, pitch: pitch), pitch)
    }

    // MARK: slot

    private let twoRows: [CGRect?] = [
        CGRect(x: 0, y: 0, width: 100, height: 28),
        CGRect(x: 0, y: 29, width: 100, height: 28)
    ]

    func testSlotAboveFirstReturnsZero() {
        XCTAssertEqual(ReorderMath.slot(forY: 5, orderedStartFrames: twoRows), 0)
    }

    func testSlotBetweenRows() {
        // y=35: not < first.midY(14); < second.midY(43) → slot 1.
        XCTAssertEqual(ReorderMath.slot(forY: 35, orderedStartFrames: twoRows), 1)
    }

    func testSlotPastLastReturnsCount() {
        XCTAssertEqual(ReorderMath.slot(forY: 500, orderedStartFrames: twoRows), 2)
    }

    func testSlotSkipsNilFrames() {
        let frames: [CGRect?] = [nil, CGRect(x: 0, y: 29, width: 100, height: 28)]
        XCTAssertEqual(ReorderMath.slot(forY: 5, orderedStartFrames: frames), 1)
    }

    // MARK: insertionLineY

    func testInsertionLineNoTargetIsNil() {
        XCTAssertNil(ReorderMath.insertionLineY(dropTarget: nil, orderedLiveFrames: twoRows))
    }

    func testInsertionLineEmptyIsNil() {
        XCTAssertNil(ReorderMath.insertionLineY(dropTarget: 0, orderedLiveFrames: []))
    }

    func testInsertionLinePastEndUsesLastMaxY() {
        // target=2 ≥ count=2 → last.maxY = 29 + 28 = 57.
        XCTAssertEqual(ReorderMath.insertionLineY(dropTarget: 2, orderedLiveFrames: twoRows), 57)
    }

    func testInsertionLineMidUsesTargetMinY() {
        // target=1 → frames[1].minY = 29.
        XCTAssertEqual(ReorderMath.insertionLineY(dropTarget: 1, orderedLiveFrames: twoRows), 29)
    }
}
