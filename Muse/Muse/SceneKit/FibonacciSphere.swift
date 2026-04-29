//
//  FibonacciSphere.swift
//  Muse
//
//  Generates evenly-spaced points on a sphere via the Fibonacci
//  spiral. Used by GlobeView to lay out image thumbnails on a 3D
//  surface.
//

import Foundation
import SceneKit

enum FibonacciSphere {
    /// Returns `count` 3D points on a unit sphere, distributed via the
    /// golden-ratio spiral.
    static func points(count: Int) -> [SCNVector3] {
        guard count > 0 else { return [] }
        let goldenAngle = .pi * (3.0 - sqrt(5.0))
        var result: [SCNVector3] = []
        result.reserveCapacity(count)
        for i in 0..<count {
            let y = 1.0 - (Double(i) / Double(max(count - 1, 1))) * 2.0
            let radius = sqrt(1.0 - y * y)
            let theta = goldenAngle * Double(i)
            let x = cos(theta) * radius
            let z = sin(theta) * radius
            result.append(SCNVector3(x, y, z))
        }
        return result
    }
}
