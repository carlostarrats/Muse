import XCTest
@testable import Muse

final class ViewerGeometryTests: XCTestCase {
    // viewport 1200x800, column 298 (258 + 40 margin), pad 40, topPad 70, bottomPad 60
    func testFitCentersBetweenEdgeAndColumn() {
        let r = ViewerGeometry.fitRect(imageSize: CGSize(width: 2400, height: 1600),
                                       viewport: CGSize(width: 1200, height: 800))
        let usableRight = 1200 - 298.0
        XCTAssertEqual(r.midX, (usableRight) / 2, accuracy: 0.5)   // centered in viewable space
        XCTAssertLessThanOrEqual(r.maxX, usableRight + 0.5)        // never under the column
        XCTAssertEqual(r.width / r.height, 1.5, accuracy: 0.01)    // aspect preserved
    }
    func testTallImageHeightLimited() {
        let r = ViewerGeometry.fitRect(imageSize: CGSize(width: 800, height: 2400),
                                       viewport: CGSize(width: 1200, height: 800))
        XCTAssertEqual(r.height, 800 - 70 - 60, accuracy: 0.5)
    }
    func testZoomClamp() {
        XCTAssertEqual(ViewerGeometry.clampZoom(0.3), 1.0)
        XCTAssertEqual(ViewerGeometry.clampZoom(9), 4.0)
        XCTAssertEqual(ViewerGeometry.clampZoom(2.2), 2.2)
    }
    func testPanClamp() {
        // zoom 2 on a 600x400 fitted image → max offset (z-1)*size/2 = (300,200)
        let p = ViewerGeometry.clampPan(CGSize(width: 999, height: -999),
                                        fittedSize: CGSize(width: 600, height: 400), zoom: 2)
        XCTAssertEqual(p.width, 300); XCTAssertEqual(p.height, -200)
        let q = ViewerGeometry.clampPan(CGSize(width: 50, height: 50),
                                        fittedSize: CGSize(width: 600, height: 400), zoom: 1)
        XCTAssertEqual(q, .zero)   // no pan at fit
    }
    func testDegenerateInputs() {
        let r = ViewerGeometry.fitRect(imageSize: .zero, viewport: CGSize(width: 100, height: 100))
        XCTAssertFalse(r.width.isNaN); XCTAssertFalse(r.height.isNaN)
    }
}
