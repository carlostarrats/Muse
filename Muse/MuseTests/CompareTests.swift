//
//  CompareTests.swift
//  MuseTests
//
//  Was CompareCullTests. The CullSummary/CullStore cases went with the cull
//  feature (removed 2026-08-02) — the compare workbench itself stays.
//

import XCTest
import CoreGraphics
@testable import Muse

final class CompareGeometryTests: XCTestCase {
    func testDrawRectFitsAtZoomOne() {
        let rect = CompareGeometry.drawRect(imageSize: CGSize(width: 200, height: 100),
                                             paneSize: CGSize(width: 400, height: 400),
                                             zoom: 1, center: CGPoint(x: 0.5, y: 0.5))
        // A 2:1 landscape image fit into a 400x400 pane → 400x200, centered.
        XCTAssertEqual(rect.width, 400, accuracy: 0.01)
        XCTAssertEqual(rect.height, 200, accuracy: 0.01)
        XCTAssertEqual(rect.midY, 200, accuracy: 0.01)
    }

    func testSharedCenterTracksSameSubjectAcrossDifferingAspects() {
        let landscape = CompareGeometry.drawRect(imageSize: CGSize(width: 300, height: 150),
                                                  paneSize: CGSize(width: 300, height: 300),
                                                  zoom: 2, center: CGPoint(x: 0.5, y: 0.5))
        let portrait = CompareGeometry.drawRect(imageSize: CGSize(width: 150, height: 300),
                                                 paneSize: CGSize(width: 300, height: 300),
                                                 zoom: 2, center: CGPoint(x: 0.5, y: 0.5))
        XCTAssertEqual(landscape.midX, 150, accuracy: 0.5)
        XCTAssertEqual(landscape.midY, 150, accuracy: 0.5)
        XCTAssertEqual(portrait.midX, 150, accuracy: 0.5)
        XCTAssertEqual(portrait.midY, 150, accuracy: 0.5)
    }

    func testCenterOffsetMovesTheDrawnRect() {
        let centered = CompareGeometry.drawRect(imageSize: CGSize(width: 200, height: 200),
                                                 paneSize: CGSize(width: 200, height: 200),
                                                 zoom: 2, center: CGPoint(x: 0.5, y: 0.5))
        let shifted = CompareGeometry.drawRect(imageSize: CGSize(width: 200, height: 200),
                                                paneSize: CGSize(width: 200, height: 200),
                                                zoom: 2, center: CGPoint(x: 0.75, y: 0.5))
        XCTAssertLessThan(shifted.origin.x, centered.origin.x)
    }

    func testClampCenterStaysWithinUnitSquare() {
        let clamped = CompareGeometry.clampCenter(CGPoint(x: -0.5, y: 1.8), zoom: 2)
        XCTAssertGreaterThanOrEqual(clamped.x, 0)
        XCTAssertLessThanOrEqual(clamped.x, 1)
        XCTAssertGreaterThanOrEqual(clamped.y, 0)
        XCTAssertLessThanOrEqual(clamped.y, 1)
    }

    func testClampAtZoomOneCollapsesToCenterOfFrame() {
        let clamped = CompareGeometry.clampCenter(CGPoint(x: 0.1, y: 0.9), zoom: 1)
        XCTAssertEqual(clamped.x, 0.5, accuracy: 0.001)
        XCTAssertEqual(clamped.y, 0.5, accuracy: 0.001)
    }

    func testDegenerateSizesReturnZero() {
        XCTAssertEqual(CompareGeometry.drawRect(imageSize: .zero, paneSize: CGSize(width: 10, height: 10),
                                                 zoom: 1, center: CGPoint(x: 0.5, y: 0.5)), .zero)
    }

    func testZoomRangeBounds() {
        XCTAssertEqual(CompareGeometry.zoomRange, 1...8)
    }
}

@MainActor
final class CompareStoreTests: XCTestCase {
    func testOpenRefusesFewerThanTwo() {
        let store = CompareStore()
        store.open(urls: [URL(fileURLWithPath: "/tmp/a.jpg")])
        XCTAssertNil(store.urls, "fewer than 2 URLs must not open compare")
    }

    func testOpenClampsToMaxPanes() {
        let store = CompareStore()
        store.open(urls: (0..<8).map { URL(fileURLWithPath: "/tmp/\($0).jpg") })
        XCTAssertEqual(store.urls?.count, CompareStore.maxPanes)
    }

    func testOpenWithinRangeKeepsAll() {
        let store = CompareStore()
        store.open(urls: (0..<3).map { URL(fileURLWithPath: "/tmp/\($0).jpg") })
        XCTAssertEqual(store.urls?.count, 3)
    }

    func testCloseResetsState() {
        let store = CompareStore()
        store.open(urls: [URL(fileURLWithPath: "/tmp/a.jpg"), URL(fileURLWithPath: "/tmp/b.jpg")])
        store.zoom = 3
        store.close()
        XCTAssertNil(store.urls)
        XCTAssertEqual(store.zoom, 1)
        XCTAssertFalse(store.isActive)
    }

    func testFocusClampsToValidRange() {
        let store = CompareStore()
        store.open(urls: [URL(fileURLWithPath: "/tmp/a.jpg"), URL(fileURLWithPath: "/tmp/b.jpg")])
        store.focus(5)
        XCTAssertEqual(store.focusedIndex, 1, "out-of-range focus clamps to the last valid pane")
    }

    func testReplaceFocusedSwapsOnlyThatPane() {
        let store = CompareStore()
        store.open(urls: [URL(fileURLWithPath: "/tmp/a.jpg"), URL(fileURLWithPath: "/tmp/b.jpg")])
        store.focus(1)
        store.replaceFocused(with: URL(fileURLWithPath: "/tmp/c.jpg"))
        XCTAssertEqual(store.urls?.map(\.lastPathComponent), ["a.jpg", "c.jpg"])
    }
}

final class SharpnessRankTests: XCTestCase {
    func testMaxScoreIsMarkedSharpest() {
        XCTAssertEqual(SharpnessRank.rank(scores: [3.0, 4.5, 2.0]), [.softer, .sharpest, .softer])
    }

    func testWithinTieBandIsComparable() {
        XCTAssertEqual(SharpnessRank.rank(scores: [4.0, 4.1]), [.comparable, .sharpest])
    }

    func testBeyondTieBandIsSofter() {
        XCTAssertEqual(SharpnessRank.rank(scores: [4.0, 4.0 - SharpnessRank.tieBand - 0.01]),
                       [.sharpest, .softer])
    }

    func testNilScoresAreUnmarked() {
        XCTAssertEqual(SharpnessRank.rank(scores: [3.9, nil, 4.0]), [.comparable, .unmarked, .sharpest])
        XCTAssertEqual(SharpnessRank.rank(scores: [3.0, nil, 4.0]), [.softer, .unmarked, .sharpest])
    }

    func testAllNilProducesAllUnmarked() {
        XCTAssertEqual(SharpnessRank.rank(scores: [nil, nil]), [.unmarked, .unmarked])
    }

    func testEmptyInputReturnsEmpty() {
        XCTAssertTrue(SharpnessRank.rank(scores: []).isEmpty)
    }
}
