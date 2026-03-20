//
//  FolderScene.swift
//  Muse
//
//  Created by Carlos Tarrats on 3/19/26.
//

import SceneKit
import AppKit

/// Builds an SCNScene that renders a 3D folder for a collection, with open/close
/// animation and image grid reveal.
enum FolderScene {

    struct FolderNodes {
        let scene: SCNScene
        let frontCover: SCNNode
        let backCover: SCNNode
        let folderContainer: SCNNode
        let cameraNode: SCNNode
    }

    /// Creates a scene with a 3D folder for the given collection.
    static func build(collection: MuseCollection) -> FolderNodes {
        let scene = SCNScene()

        // Background
        scene.background.contents = NSColor.white

        // Lighting
        let ambientLight = SCNLight()
        ambientLight.type = .ambient
        ambientLight.intensity = 600
        let ambientNode = SCNNode()
        ambientNode.light = ambientLight
        scene.rootNode.addChildNode(ambientNode)

        let directionalLight = SCNLight()
        directionalLight.type = .directional
        directionalLight.intensity = 800
        let directionalNode = SCNNode()
        directionalNode.light = directionalLight
        directionalNode.eulerAngles = SCNVector3(-Float.pi / 3, Float.pi / 6, 0)
        scene.rootNode.addChildNode(directionalNode)

        let folderColor = NSColor(hex: collection.colorHex)

        // Container for the whole folder
        let folderContainer = SCNNode()
        folderContainer.name = "folderContainer"
        folderContainer.position = SCNVector3(0, -0.5, 0)
        scene.rootNode.addChildNode(folderContainer)

        // Back cover
        let backGeometry = SCNBox(width: 6, height: 4.5, length: 0.05, chamferRadius: 0.06)
        let backMaterial = SCNMaterial()
        backMaterial.diffuse.contents = folderColor
        backMaterial.lightingModel = .phong
        backMaterial.specular.contents = NSColor.white.withAlphaComponent(0.3)
        backGeometry.materials = [backMaterial]
        let backCover = SCNNode(geometry: backGeometry)
        backCover.name = "backCover"
        backCover.position = SCNVector3(0, 0, -0.03)
        folderContainer.addChildNode(backCover)

        // Front cover — hinged at the top edge
        let frontGeometry = SCNBox(width: 6, height: 4.5, length: 0.05, chamferRadius: 0.06)
        let frontMaterial = SCNMaterial()
        frontMaterial.diffuse.contents = folderColor.blended(withFraction: 0.15, of: .white) ?? folderColor
        frontMaterial.lightingModel = .phong
        frontMaterial.specular.contents = NSColor.white.withAlphaComponent(0.3)
        frontGeometry.materials = [frontMaterial]

        // Pivot at top edge so the cover opens upward like a folder flap
        let frontCover = SCNNode(geometry: frontGeometry)
        frontCover.name = "frontCover"
        frontCover.pivot = SCNMatrix4MakeTranslation(0, 2.25, 0) // pivot at top edge
        frontCover.position = SCNVector3(0, 2.25, 0.03)
        folderContainer.addChildNode(frontCover)

        // Tab on top
        let tabGeometry = SCNBox(width: 1.2, height: 0.35, length: 0.04, chamferRadius: 0.03)
        let tabMaterial = SCNMaterial()
        tabMaterial.diffuse.contents = folderColor
        tabMaterial.lightingModel = .phong
        tabGeometry.materials = [tabMaterial]
        let tabNode = SCNNode(geometry: tabGeometry)
        tabNode.position = SCNVector3(-1.5, 2.45, 0)
        folderContainer.addChildNode(tabNode)

        // Tab label
        let tabText = SCNText(string: collection.name, extrusionDepth: 0.01)
        tabText.font = NSFont.systemFont(ofSize: 0.18, weight: .medium)
        tabText.flatness = 0.1
        let textMaterial = SCNMaterial()
        textMaterial.diffuse.contents = NSColor.white.withAlphaComponent(0.9)
        textMaterial.lightingModel = .constant
        tabText.materials = [textMaterial]
        let tabTextNode = SCNNode(geometry: tabText)
        let (textMin, _) = tabTextNode.boundingBox
        tabTextNode.position = SCNVector3(-1.5 - 0.5, 2.42, 0.03)
        _ = textMin // suppress unused warning
        folderContainer.addChildNode(tabTextNode)

        // Slight initial tilt for natural resting look
        folderContainer.eulerAngles = SCNVector3(-0.15, 0.05, 0)

        // Camera
        let camera = SCNCamera()
        camera.zNear = 0.1
        camera.zFar = 50
        let cameraNode = SCNNode()
        cameraNode.camera = camera
        cameraNode.position = SCNVector3(0, 1, 8)
        cameraNode.look(at: SCNVector3(0, 0, 0))
        scene.rootNode.addChildNode(cameraNode)

        return FolderNodes(
            scene: scene,
            frontCover: frontCover,
            backCover: backCover,
            folderContainer: folderContainer,
            cameraNode: cameraNode
        )
    }

    /// Creates image plane nodes for display inside an open folder.
    /// Returns the nodes (not yet added to the scene) at position zero with opacity 0.
    static func buildImageNodes(images: [MuseImage], maxVisible: Int = 20) -> [SCNNode] {
        let visibleImages = Array(images.prefix(maxVisible))
        var nodes: [SCNNode] = []

        for image in visibleImages {
            let plane = SCNPlane(width: 1.2, height: 0.9)
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
            node.name = image.id.uuidString
            node.position = SCNVector3(0, 0, 0.1)
            node.opacity = 0
            nodes.append(node)
        }

        return nodes
    }

    /// Calculates grid positions for image nodes inside the open folder.
    /// 4 columns, ~1.6 spacing, rows going downward.
    static func gridPositions(count: Int) -> [SCNVector3] {
        let columns = 4
        let spacingX: Float = 1.6
        let spacingY: Float = 1.2
        let startX: Float = -Float(columns - 1) / 2.0 * spacingX
        let startY: Float = 1.5

        return (0..<count).map { i in
            let col = i % columns
            let row = i / columns
            return SCNVector3(
                startX + Float(col) * spacingX,
                startY - Float(row) * spacingY,
                0.15
            )
        }
    }
}
