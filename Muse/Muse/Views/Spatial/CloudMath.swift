//
//  CloudMath.swift
//  Muse
//
//  Pure conversion from the prototype's CSS model to SceneKit. CSS space
//  is x-right / y-DOWN / z-toward-viewer with transform list
//  `rotateZ(rz) rotateY(ry) rotateX(rx)` (matrix Rz·Ry·Rx). SceneKit is
//  y-UP; conjugating by diag(1,-1,1) negates the x and z angles and
//  leaves y alone. Scene units = reference-canvas pixels.
//

import Foundation
import simd

enum CloudMath {
    /// SceneKit orientation equivalent of the prototype's CSS rotation.
    static func orientation(rxDeg: Double, ryDeg: Double, rzDeg: Double) -> simd_quatf {
        let d = Float.pi / 180
        let qz = simd_quatf(angle: -Float(rzDeg) * d, axis: SIMD3(0, 0, 1))
        let qy = simd_quatf(angle:  Float(ryDeg) * d, axis: SIMD3(0, 1, 0))
        let qx = simd_quatf(angle: -Float(rxDeg) * d, axis: SIMD3(1, 0, 0))
        return qz * qy * qx   // x applied first, matching CSS list order
    }

    /// Card center in scene space (origin = stage center, y up, z = 0).
    static func position(cx: Double, cy: Double) -> SIMD3<Float> {
        SIMD3(Float(cx - CloudPose.refW / 2), Float(CloudPose.refH / 2 - cy), 0)
    }

    /// Stacking: the prototype paints lower-on-canvas cards in front
    /// (zIndex = 4 + cy/40). A small true-z offset reproduces that
    /// without visibly changing the perspective. Range ≈ ±20 units.
    static func stackingZ(cy: Double) -> Float {
        Float((cy / CloudPose.refH) * 40 - 20)
    }

    /// Vertical FOV (degrees) such that, with the camera at z = F looking
    /// at the origin, the stage height exactly fills the viewport.
    static var verticalFOV: Double {
        2 * atan((CloudPose.refH / 2) / CloudPose.f) * 180 / .pi
    }

    /// Horizontal FOV (degrees) for width-fit (window narrower than stage).
    static var horizontalFOV: Double {
        2 * atan((CloudPose.refW / 2) / CloudPose.f) * 180 / .pi
    }
}
