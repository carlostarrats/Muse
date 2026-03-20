//
//  GlobeScene.swift
//  Muse
//
//  Created by Carlos Tarrats on 3/19/26.
//

import SceneKit

/// Builds an SCNScene displaying a single collection's images on a 3D sphere.
enum GlobeScene {

    /// Creates a scene with images arranged on a Fibonacci sphere.
    ///
    /// - Parameter images: The collection's images.
    /// - Returns: A tuple of (scene, globeNode, cameraNode) for external control.
    static func build(images: [MuseImage]) -> (scene: SCNScene, globeNode: SCNNode, cameraNode: SCNNode) {
        let scene = SCNScene()

        // Background
        scene.background.contents = NSColor.white

        // Lighting
        let ambientLight = SCNLight()
        ambientLight.type = .ambient
        ambientLight.intensity = 500
        ambientLight.color = NSColor.white
        let ambientNode = SCNNode()
        ambientNode.light = ambientLight
        scene.rootNode.addChildNode(ambientNode)

        // Globe
        let globeNode = FibonacciSphere.buildGlobeNode(images: images, radius: 3.0)
        globeNode.name = "globe"
        scene.rootNode.addChildNode(globeNode)

        // Auto-rotation (~25 seconds per full rotation)
        let rotation = SCNAction.rotateBy(x: 0, y: .pi * 2, z: 0, duration: 25)
        globeNode.runAction(.repeatForever(rotation), forKey: "autoRotate")

        // Camera
        let camera = SCNCamera()
        camera.zNear = 0.1
        camera.zFar = 100
        let cameraNode = SCNNode()
        cameraNode.camera = camera
        cameraNode.position = SCNVector3(0, 0, 9)
        cameraNode.look(at: SCNVector3Zero)
        scene.rootNode.addChildNode(cameraNode)

        return (scene, globeNode, cameraNode)
    }
}
