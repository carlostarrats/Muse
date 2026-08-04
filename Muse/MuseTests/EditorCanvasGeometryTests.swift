//
//  EditorCanvasGeometryTests.swift
//  MuseTests
//
//  The editor canvas's layout, which is now the ONLY place its geometry is
//  computed. The property that matters most is the aspect invariance — that is
//  what makes a live resize a uniform scale rather than a re-fit, and it is the
//  whole reason the canvas stopped spanning the window.
//

import XCTest
import SwiftUI
@testable import Muse

final class EditorCanvasGeometryTests: XCTestCase {

    private let panels = EdgeInsets(top: 86, leading: 320, bottom: 60, trailing: 320)

    // MARK: - Aspect

    func testContentAspectIsTheImageAspect() {
        let a = EditorCanvasGeometry.contentAspect(
            imageSize: CGSize(width: 6000, height: 4000), sideBySide: false)
        XCTAssertEqual(a, 1.5, accuracy: 0.0001)
    }

    func testSideBySideAspectMakesRoomForTwoImagesAndTheGap() {
        let single = CGSize(width: 1000, height: 500)          // 2.0
        let a = EditorCanvasGeometry.contentAspect(imageSize: single, sideBySide: true)
        XCTAssertEqual(a, 2.0 * (2 + EditorCanvasGeometry.sideBySideGapFraction), accuracy: 0.0001)
        XCTAssertGreaterThan(a, 4.0, "two panes must be wider than one")
    }

    func testDegenerateImageDoesNotProduceANaNAspect() {
        XCTAssertEqual(EditorCanvasGeometry.contentAspect(imageSize: .zero, sideBySide: false), 1)
    }

    // MARK: - The invariant the refactor exists for

    /// THE point. The canvas view's aspect must equal the content's aspect at
    /// every window size and every zoom — that is what lets a drawable which
    /// lags a resize be drawn with `.resizeAspect` and land exactly on the new
    /// bounds, differing only in resolution. When the canvas spanned the window
    /// its aspect changed with the window, so a lagging drawable was the wrong
    /// SHAPE and had to be re-fitted, which is what jumped.
    func testContentRectKeepsTheImageAspectAtEveryWindowSizeAndZoom() {
        for w in stride(from: 720.0, through: 2400.0, by: 37.0) {
            for h in stride(from: 480.0, through: 1400.0, by: 53.0) {
                for zoom in [0.7, 1.0, 1.9, 4.0] {
                    let r = EditorCanvasGeometry.contentRect(
                        canvas: CGSize(width: w, height: h), insets: panels,
                        aspect: 1.5, zoom: zoom, pan: .zero)
                    guard r.height > 0 else { continue }
                    XCTAssertEqual(r.width / r.height, 1.5, accuracy: 0.001,
                                   "aspect drifted at \(w)×\(h) zoom \(zoom)")
                }
            }
        }
    }

    // MARK: - Fit and placement

    func testFittedSizeFillsTheFreeWidthForAWideImageInAWideFreeArea() {
        // 1600 - 640 = 960 free width, 900 - 146 = 754 free height.
        // A 1.5 image fitted by width would be 640 tall — fits.
        let s = EditorCanvasGeometry.fittedSize(
            canvas: CGSize(width: 1600, height: 900), insets: panels, aspect: 1.5)
        XCTAssertEqual(s.width, 960, accuracy: 0.001)
        XCTAssertEqual(s.height, 640, accuracy: 0.001)
    }

    func testFittedSizeIsHeightBoundForATallImage() {
        let s = EditorCanvasGeometry.fittedSize(
            canvas: CGSize(width: 1600, height: 900), insets: panels, aspect: 0.5)
        XCTAssertEqual(s.height, 754, accuracy: 0.001)
        XCTAssertEqual(s.width, 377, accuracy: 0.001)
    }

    func testContentIsCentredInTheFreeRectNotTheWindow() {
        // Asymmetric insets: the centre must follow the FREE rect.
        let insets = EdgeInsets(top: 0, leading: 400, bottom: 0, trailing: 0)
        let canvas = CGSize(width: 1000, height: 500)
        let r = EditorCanvasGeometry.contentRect(canvas: canvas, insets: insets,
                                                 aspect: 1, zoom: 1, pan: .zero)
        XCTAssertEqual(r.midX, 700, accuracy: 0.001, "centred in the window, not the free space")
        XCTAssertEqual(r.midY, 250, accuracy: 0.001)
    }

    func testPanMovesTheRectAndZoomScalesItAboutTheSameCentre() {
        let canvas = CGSize(width: 1600, height: 900)
        let base = EditorCanvasGeometry.contentRect(canvas: canvas, insets: panels,
                                                    aspect: 1.5, zoom: 1, pan: .zero)
        let zoomed = EditorCanvasGeometry.contentRect(canvas: canvas, insets: panels,
                                                      aspect: 1.5, zoom: 2, pan: .zero)
        XCTAssertEqual(zoomed.midX, base.midX, accuracy: 0.001)
        XCTAssertEqual(zoomed.midY, base.midY, accuracy: 0.001)
        XCTAssertEqual(zoomed.width, base.width * 2, accuracy: 0.001)

        let panned = EditorCanvasGeometry.contentRect(canvas: canvas, insets: panels,
                                                      aspect: 1.5, zoom: 2,
                                                      pan: CGSize(width: 40, height: -25))
        XCTAssertEqual(panned.midX, zoomed.midX + 40, accuracy: 0.001)
        XCTAssertEqual(panned.midY, zoomed.midY - 25, accuracy: 0.001)
    }

    /// A zoomed photo must be allowed to grow PAST the free rect and run under
    /// the panels — that is the behaviour the full-window canvas provided for
    /// free and the one most at risk from sizing the view to the content.
    func testZoomedContentIsAllowedToExceedTheFreeRect() {
        let canvas = CGSize(width: 1600, height: 900)
        let free = EditorCanvasGeometry.freeRect(canvas: canvas, insets: panels)
        let r = EditorCanvasGeometry.contentRect(canvas: canvas, insets: panels,
                                                 aspect: 1.5, zoom: 4, pan: .zero)
        XCTAssertGreaterThan(r.width, free.width, "zoom was clamped to the panels")
        XCTAssertLessThan(r.minX, free.minX)
    }

    func testZeroZoomCannotCollapseTheRect() {
        let r = EditorCanvasGeometry.contentRect(canvas: CGSize(width: 800, height: 600),
                                                 insets: panels, aspect: 1.5,
                                                 zoom: 0, pan: .zero)
        XCTAssertTrue(r.width.isFinite && r.height.isFinite)
        XCTAssertGreaterThanOrEqual(r.width, 0)
    }

    /// The window minimum has to serve the EDITOR, not just Preview: both modes
    /// share one window, and Edit spends two panels' worth of it. The first
    /// version of `minWindowWidth` was derived from Preview's single info
    /// column and left the editor 60pt of picture at the limit.
    func testEditorHasAUsablePictureAtTheMinimumWindowWidth() {
        let insets = EdgeInsets(top: ViewerGeometry.topPad,
                                leading: ViewerGeometry.editorPanelWidth,
                                bottom: ViewerGeometry.bottomPad,
                                trailing: ViewerGeometry.editorPanelWidth)
        let free = EditorCanvasGeometry.freeRect(
            canvas: CGSize(width: ViewerGeometry.minWindowWidth, height: 800),
            insets: insets)
        XCTAssertGreaterThanOrEqual(
            free.width, ViewerGeometry.columnWidth,
            "at the minimum window width the editor's picture is only \(free.width)pt wide — "
            + "narrower than one of the panels beside it")
    }

    // MARK: - Point mapping

    func testUnitPointIsAPlainDivision() {
        let p = EditorCanvasGeometry.unitPoint(inContentOfSize: CGSize(width: 200, height: 100),
                                               at: CGPoint(x: 50, y: 75))
        XCTAssertEqual(p?.x ?? -1, 0.25, accuracy: 0.0001)
        XCTAssertEqual(p?.y ?? -1, 0.75, accuracy: 0.0001)
    }

    func testUnitPointRefusesPointsOutsideTheContent() {
        let size = CGSize(width: 200, height: 100)
        XCTAssertNil(EditorCanvasGeometry.unitPoint(inContentOfSize: size,
                                                    at: CGPoint(x: -1, y: 50)))
        XCTAssertNil(EditorCanvasGeometry.unitPoint(inContentOfSize: size,
                                                    at: CGPoint(x: 50, y: 101)))
        XCTAssertNil(EditorCanvasGeometry.unitPoint(inContentOfSize: .zero,
                                                    at: CGPoint(x: 0, y: 0)))
    }

    func testUnitPointHitsTheCorners() {
        let size = CGSize(width: 200, height: 100)
        XCTAssertEqual(EditorCanvasGeometry.unitPoint(inContentOfSize: size, at: .zero)?.x, 0)
        let br = EditorCanvasGeometry.unitPoint(inContentOfSize: size,
                                                at: CGPoint(x: 200, y: 100))
        XCTAssertEqual(br?.x ?? -1, 1, accuracy: 0.0001)
        XCTAssertEqual(br?.y ?? -1, 1, accuracy: 0.0001)
    }

    // MARK: - Column-aware panel insets

    @MainActor func testBothColumnsReserveAPanelOnEachSide() {
        let i = EditorCanvasGeometry.panelInsets(leftEmptied: 0, rightEmptied: 0,
                                                 chromeProgress: 1)
        XCTAssertEqual(i.leading, ViewerGeometry.editorPanelWidth, accuracy: 0.01)
        XCTAssertEqual(i.trailing, ViewerGeometry.editorPanelWidth, accuracy: 0.01)
    }

    @MainActor func testAllCardsRightGivesThePhotoTheLeftSide() {
        // Preview's exact geometry — content left, column right — so switching
        // Preview to Edit does not move the photo at all.
        let i = EditorCanvasGeometry.panelInsets(leftEmptied: 1, rightEmptied: 0,
                                                 chromeProgress: 1)
        XCTAssertEqual(i.leading, ViewerGeometry.sidePad, accuracy: 0.01)
        XCTAssertEqual(i.trailing, ViewerGeometry.editorPanelWidth, accuracy: 0.01)
    }

    @MainActor func testAllCardsLeftGivesThePhotoTheRightSide() {
        let i = EditorCanvasGeometry.panelInsets(leftEmptied: 0, rightEmptied: 1,
                                                 chromeProgress: 1)
        XCTAssertEqual(i.leading, ViewerGeometry.editorPanelWidth, accuracy: 0.01)
        XCTAssertEqual(i.trailing, ViewerGeometry.sidePad, accuracy: 0.01)
    }

    @MainActor func testTheTopInsetNeverMoves() {
        // The chrome row is pinned, so a photo widening into an emptied right
        // column must still start below it.
        for (l, r) in [(0.0, 0.0), (1.0, 0.0), (0.0, 1.0), (1.0, 1.0)] {
            let i = EditorCanvasGeometry.panelInsets(leftEmptied: l, rightEmptied: r,
                                                     chromeProgress: 1)
            XCTAssertEqual(i.top, ViewerGeometry.topPad, accuracy: 0.01,
                           "top moved for leftEmptied=\(l) rightEmptied=\(r)")
        }
    }

    @MainActor func testHidingTheUIStillCollapsesEverySideToBare() {
        let i = EditorCanvasGeometry.panelInsets(leftEmptied: 0, rightEmptied: 0,
                                                 chromeProgress: 0)
        XCTAssertEqual(i.leading, ViewerGeometry.sidePad, accuracy: 0.01)
        XCTAssertEqual(i.trailing, ViewerGeometry.sidePad, accuracy: 0.01)
        XCTAssertEqual(i.top, ViewerGeometry.sidePad, accuracy: 0.01)
    }

    @MainActor func testMidChromeProgressInterpolatesFromTheColumnAwareTarget() {
        // Emptying a column and hiding the UI must compose: the interpolation
        // runs toward THIS layout's inset, not the two-column one.
        let i = EditorCanvasGeometry.panelInsets(leftEmptied: 1, rightEmptied: 0,
                                                 chromeProgress: 0.5)
        XCTAssertEqual(i.leading, ViewerGeometry.sidePad, accuracy: 0.01,
                       "an emptied side is already bare at any progress")
        let expected = ViewerGeometry.sidePad
            + (ViewerGeometry.editorPanelWidth - ViewerGeometry.sidePad) * 0.5
        XCTAssertEqual(i.trailing, expected, accuracy: 0.01)
    }

    /// The reason `leftEmptied` is a Double and not a Bool: HALFWAY through
    /// emptying, the inset must be halfway too. With Bools this transition had
    /// exactly two states and the photo snapped between them.
    @MainActor func testAColumnHalfEmptiedGivesBackHalfOfItsSpace() {
        let full = EditorCanvasGeometry.panelInsets(leftEmptied: 0, rightEmptied: 0,
                                                    chromeProgress: 1).leading
        let gone = EditorCanvasGeometry.panelInsets(leftEmptied: 1, rightEmptied: 0,
                                                    chromeProgress: 1).leading
        let half = EditorCanvasGeometry.panelInsets(leftEmptied: 0.5, rightEmptied: 0,
                                                    chromeProgress: 1).leading
        XCTAssertEqual(half, (full + gone) / 2, accuracy: 0.01)
        XCTAssertGreaterThan(half, gone)
        XCTAssertLessThan(half, full)
    }

    @MainActor func testEmptiedProgressIsClampedSoAStoppedAnimatorCannotOvershoot() {
        let gone = EditorCanvasGeometry.panelInsets(leftEmptied: 1, rightEmptied: 0,
                                                    chromeProgress: 1).leading
        let over = EditorCanvasGeometry.panelInsets(leftEmptied: 1.4, rightEmptied: 0,
                                                    chromeProgress: 1).leading
        let under = EditorCanvasGeometry.panelInsets(leftEmptied: -0.3, rightEmptied: 0,
                                                     chromeProgress: 1).leading
        let full = EditorCanvasGeometry.panelInsets(leftEmptied: 0, rightEmptied: 0,
                                                    chromeProgress: 1).leading
        XCTAssertEqual(over, gone, accuracy: 0.01)
        XCTAssertEqual(under, full, accuracy: 0.01)
    }

    @MainActor func testAnEmptiedColumnWidensTheFittedPhoto() {
        // The point of the whole rule: the photo actually gets the space back.
        let canvas = CGSize(width: 1600, height: 1000)
        let two = EditorCanvasGeometry.fittedSize(
            canvas: canvas,
            insets: EditorCanvasGeometry.panelInsets(leftEmptied: 0, rightEmptied: 0,
                                                     chromeProgress: 1),
            aspect: 1.5)
        let one = EditorCanvasGeometry.fittedSize(
            canvas: canvas,
            insets: EditorCanvasGeometry.panelInsets(leftEmptied: 1, rightEmptied: 0,
                                                     chromeProgress: 1),
            aspect: 1.5)
        XCTAssertGreaterThan(one.width, two.width)
    }
}
