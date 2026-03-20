//
//  FibonacciSphere.swift
//  Muse
//
//  Created by Carlos Tarrats on 3/19/26.
//

import SceneKit
import AppKit

/// Distributes points evenly on a sphere using the golden angle method
/// and builds SceneKit globe nodes from image arrays.
enum FibonacciSphere {

    /// The golden angle in radians.
    private static let goldenAngle = Float.pi * (3.0 - sqrt(5.0))

    // MARK: - Point Generation

    /// Returns `count` positions distributed evenly on a sphere of the given `radius`.
    static func generatePositions(count: Int, radius: Float) -> [SCNVector3] {
        guard count > 0 else { return [] }
        let n = Float(count)
        return (0..<count).map { i in
            let fi = Float(i)
            let theta = goldenAngle * fi
            let y = 1.0 - (2.0 * fi + 1.0) / n
            let r = sqrt(1.0 - y * y)
            let x = r * cos(theta)
            let z = r * sin(theta)
            return SCNVector3(x * radius, y * radius, z * radius)
        }
    }

    // MARK: - Globe Node Builder

    /// Builds a container `SCNNode` with child plane nodes for each image,
    /// positioned on a Fibonacci sphere and oriented to face outward.
    ///
    /// - Parameters:
    ///   - images: The images to place on the sphere.
    ///   - radius: The sphere radius.
    /// - Returns: A container node with all image planes as children.
    static func buildGlobeNode(images: [MuseImage], radius: Float) -> SCNNode {
        let container = SCNNode()
        let positions = generatePositions(count: images.count, radius: radius)

        for (index, image) in images.enumerated() {
            guard index < positions.count else { break }
            let position = positions[index]

            // Plane geometry — roughly 1.3:1 aspect ratio
            let plane = SCNPlane(width: 0.45, height: 0.35)

            // Texture with thumbnail or placeholder
            let material = SCNMaterial()
            material.isDoubleSided = true
            material.lightingModel = .constant
            if let thumbURL = image.resolvedThumbnailURL,
               let nsImage = NSImage(contentsOf: thumbURL) {
                material.diffuse.contents = nsImage
            } else {
                material.diffuse.contents = NSColor.darkGray
            }
            plane.materials = [material]

            let node = SCNNode(geometry: plane)
            node.position = position
            node.name = image.id.uuidString

            // Orient to face outward from sphere center
            let outward = SCNVector3(position.x * 2, position.y * 2, position.z * 2)
            node.look(at: outward)

            // Small random tilt for organic feel
            node.eulerAngles.x += CGFloat.random(in: -0.15...0.15)
            node.eulerAngles.z += CGFloat.random(in: -0.15...0.15)

            container.addChildNode(node)
        }

        return container
    }
}
