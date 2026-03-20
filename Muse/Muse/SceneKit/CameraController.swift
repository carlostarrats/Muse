//
//  CameraController.swift
//  Muse
//
//  Created by Carlos Tarrats on 3/19/26.
//

import SceneKit

/// Shared camera animation helpers for Universe and Globe views.
enum CameraController {

    /// Animates a camera node to a new position and look-at target.
    ///
    /// - Parameters:
    ///   - cameraNode: The camera node to animate.
    ///   - position: The destination position.
    ///   - target: The point the camera should look at after moving.
    ///   - duration: Animation duration in seconds.
    ///   - completion: Called on the main thread when the animation finishes.
    static func flyCamera(
        _ cameraNode: SCNNode,
        to position: SCNVector3,
        lookAt target: SCNVector3,
        duration: TimeInterval,
        completion: (() -> Void)? = nil
    ) {
        SCNTransaction.begin()
        SCNTransaction.animationDuration = duration
        SCNTransaction.animationTimingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        SCNTransaction.completionBlock = {
            DispatchQueue.main.async { completion?() }
        }

        cameraNode.position = position
        cameraNode.look(at: target)

        SCNTransaction.commit()
    }
}
