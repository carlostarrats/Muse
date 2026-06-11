import XCTest
import simd
@testable import Muse

final class CloudMathTests: XCTestCase {
    // CSS rotateZ(+90°): with y pointing DOWN in CSS, the screen-right
    // vector rotates to screen-down. In SceneKit (y up) screen-down is -y.
    func testRotateZ90MatchesCSSClockwiseOnScreen() {
        let q = CloudMath.orientation(rxDeg: 0, ryDeg: 0, rzDeg: 90)
        let v = q.act(SIMD3<Float>(1, 0, 0))
        XCTAssertEqual(v.x, 0, accuracy: 1e-5)
        XCTAssertEqual(v.y, -1, accuracy: 1e-5)
        XCTAssertEqual(v.z, 0, accuracy: 1e-5)
    }

    // CSS rotateX(+90°): the card's bottom edge (y down) swings toward the
    // viewer (+z in CSS, +z in SceneKit too). The card's TOP edge — +y in
    // SceneKit — must therefore swing AWAY from the viewer (-z).
    func testRotateX90TiltsTopEdgeAway() {
        let q = CloudMath.orientation(rxDeg: 90, ryDeg: 0, rzDeg: 0)
        let v = q.act(SIMD3<Float>(0, 1, 0))
        XCTAssertEqual(v.y, 0, accuracy: 1e-5)
        XCTAssertEqual(v.z, -1, accuracy: 1e-5)
    }

    // CSS rotateY(+90°): standard right-handed Ry maps +x -> -z at +90°,
    // and the y-flip conjugation leaves Ry unchanged, so SceneKit agrees.
    func testRotateY90MapsRightEdgeBackward() {
        let q = CloudMath.orientation(rxDeg: 0, ryDeg: 90, rzDeg: 0)
        let v = q.act(SIMD3<Float>(1, 0, 0))
        XCTAssertEqual(v.x, 0, accuracy: 1e-5)
        XCTAssertEqual(v.z, -1, accuracy: 1e-5)
    }

    func testCompositionOrderIsZThenYThenX() {
        // Composite must equal applying X first, then Y, then Z (CSS
        // reads transform lists left-to-right as world-side products).
        let q = CloudMath.orientation(rxDeg: 30, ryDeg: 40, rzDeg: 50)
        let qz = CloudMath.orientation(rxDeg: 0, ryDeg: 0, rzDeg: 50)
        let qy = CloudMath.orientation(rxDeg: 0, ryDeg: 40, rzDeg: 0)
        let qx = CloudMath.orientation(rxDeg: 30, ryDeg: 0, rzDeg: 0)
        let manual = qz * qy * qx
        let v = SIMD3<Float>(0.3, -0.7, 0.2)
        XCTAssertLessThan(simd_length(q.act(v) - manual.act(v)), 1e-5)
    }

    func testStagePositionMapsReferencePixelsToCenteredYUp() {
        let center = CloudMath.position(cx: CloudPose.refW / 2, cy: CloudPose.refH / 2)
        XCTAssertEqual(center, SIMD3<Float>(0, 0, 0))
        let topLeft = CloudMath.position(cx: 0, cy: 0)
        XCTAssertEqual(topLeft.x, Float(-CloudPose.refW / 2), accuracy: 0.001)
        XCTAssertEqual(topLeft.y, Float(CloudPose.refH / 2), accuracy: 0.001)
    }

    func testFOVsShowExactlyTheStageAtCameraDistanceF() {
        // visible height at z=0 = 2 * F * tan(fov/2) == refH
        let vh = 2 * CloudPose.f * tan(CloudMath.verticalFOV * .pi / 180 / 2)
        XCTAssertEqual(vh, CloudPose.refH, accuracy: 0.01)
        let hw = 2 * CloudPose.f * tan(CloudMath.horizontalFOV * .pi / 180 / 2)
        XCTAssertEqual(hw, CloudPose.refW, accuracy: 0.01)
    }
}
