//
//  SceneProjection.swift
//  Muse
//
//  Projects a SceneKit plane node to its screen-space bounding rect in
//  TOP-LEFT-origin view coordinates (SwiftUI-style). Used to hand the
//  hero viewer its flight source rect via appState.tileFrames.
//

import SceneKit
import AppKit

@MainActor
enum SceneProjection {
    static func screenRect(of node: SCNNode, in view: SCNView) -> CGRect? {
        guard let plane = node.geometry as? SCNPlane else { return nil }
        let hw = plane.width / 2, hh = plane.height / 2
        let corners = [
            SCNVector3(-hw, -hh, 0), SCNVector3(hw, -hh, 0),
            SCNVector3(-hw, hh, 0), SCNVector3(hw, hh, 0),
        ]
        var minX = CGFloat.greatestFiniteMagnitude, minY = CGFloat.greatestFiniteMagnitude
        var maxX = -CGFloat.greatestFiniteMagnitude, maxY = -CGFloat.greatestFiniteMagnitude
        for c in corners {
            let world = node.convertPosition(c, to: nil)
            let p = view.projectPoint(world)
            minX = min(minX, CGFloat(p.x)); maxX = max(maxX, CGFloat(p.x))
            minY = min(minY, CGFloat(p.y)); maxY = max(maxY, CGFloat(p.y))
        }
        guard minX < maxX, minY < maxY else { return nil }
        // SCNView projectPoint y is bottom-left-origin; flip to top-left.
        let rect = CGRect(x: minX, y: view.bounds.height - maxY,
                          width: maxX - minX, height: maxY - minY)
        return rect.isNull || rect.isInfinite ? nil : rect
    }
}
