//
//  UniverseScene.swift
//  Muse
//
//  Created by Carlos Tarrats on 3/19/26.
//

import SceneKit
import AppKit

/// Builds an SCNScene showing all collections as floating globes scattered
/// in 3D space, like planets in a miniature universe.
enum UniverseScene {

    /// Creates the universe scene with globes for each collection.
    ///
    /// - Parameters:
    ///   - collections: All collections to display.
    ///   - imagesByCollection: Images grouped by collection UUID.
    /// - Returns: A tuple of (scene, cameraNode, collectionGlobeMap) where
    ///   collectionGlobeMap maps collection UUIDs to their globe container nodes.
    static func build(
        collections: [MuseCollection],
        imagesByCollection: [UUID: [MuseImage]]
    ) -> (scene: SCNScene, cameraNode: SCNNode, collectionGlobeMap: [UUID: SCNNode]) {
        let scene = SCNScene()

        // Background
        scene.background.contents = NSColor.white

        // Ambient light
        let ambientLight = SCNLight()
        ambientLight.type = .ambient
        ambientLight.intensity = 400
        ambientLight.color = NSColor(white: 0.95, alpha: 1.0)
        let ambientNode = SCNNode()
        ambientNode.light = ambientLight
        scene.rootNode.addChildNode(ambientNode)

        // Directional light
        let directionalLight = SCNLight()
        directionalLight.type = .directional
        directionalLight.intensity = 800
        directionalLight.color = NSColor.white
        let directionalNode = SCNNode()
        directionalNode.light = directionalLight
        directionalNode.eulerAngles = SCNVector3(-Float.pi / 4, Float.pi / 6, 0)
        scene.rootNode.addChildNode(directionalNode)

        // Build globes for each collection
        var collectionGlobeMap: [UUID: SCNNode] = [:]
        let goldenAngle = Float.pi * (3.0 - sqrt(5.0))
        let baseDistance: Float = 12.0

        for (index, collection) in collections.enumerated() {
            let images = imagesByCollection[collection.id] ?? []
            let imageCount = images.count
            let globeRadius = max(2.5, min(5.0, Float(imageCount) * 0.15))

            // Build the globe
            let globeNode = FibonacciSphere.buildGlobeNode(images: images, radius: globeRadius)
            globeNode.name = collection.id.uuidString

            // Scatter using golden angle on XZ plane with Y offset
            let angle = goldenAngle * Float(index)
            let distance = baseDistance + Float(index) * 6.0
            let x = distance * cos(angle)
            let z = distance * sin(angle)
            let y = Float.random(in: -4.0...4.0)
            globeNode.position = SCNVector3(x, y, z)

            // Slow perpetual Y-axis rotation (~30 seconds)
            let rotation = SCNAction.rotateBy(x: 0, y: .pi * 2, z: 0, duration: 30)
            globeNode.runAction(.repeatForever(rotation), forKey: "autoRotate")

            scene.rootNode.addChildNode(globeNode)
            collectionGlobeMap[collection.id] = globeNode

            // Label below the globe
            let text = SCNText(string: collection.name, extrusionDepth: 0.02)
            text.font = NSFont.systemFont(ofSize: 0.4, weight: .medium)
            text.flatness = 0.1
            let textMaterial = SCNMaterial()
            textMaterial.diffuse.contents = NSColor.black.withAlphaComponent(0.75)
            textMaterial.lightingModel = .constant
            text.materials = [textMaterial]

            let textNode = SCNNode(geometry: text)
            // Center the text horizontally under the globe
            let (minBound, maxBound) = textNode.boundingBox
            let textWidth = Float(maxBound.x - minBound.x)
            textNode.position = SCNVector3(
                x - textWidth / 2,
                y - globeRadius - 1.2,
                z
            )
            // Billboard constraint so text always faces camera
            let billboardConstraint = SCNBillboardConstraint()
            billboardConstraint.freeAxes = .Y
            textNode.constraints = [billboardConstraint]
            scene.rootNode.addChildNode(textNode)
        }

        // Camera — far enough back to see all globes
        let maxDistance = baseDistance + Float(collections.count) * 6.0
        let cameraZ = maxDistance * 0.8 + 15.0

        let camera = SCNCamera()
        camera.zNear = 0.1
        camera.zFar = Double(maxDistance * 3)
        let cameraNode = SCNNode()
        cameraNode.camera = camera
        cameraNode.position = SCNVector3(0, 5, cameraZ)
        cameraNode.look(at: SCNVector3Zero)
        scene.rootNode.addChildNode(cameraNode)

        return (scene, cameraNode, collectionGlobeMap)
    }
}
