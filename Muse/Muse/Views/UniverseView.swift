//
//  UniverseView.swift
//  Muse
//
//  Created by Carlos Tarrats on 3/19/26.
//

import SwiftUI
import SceneKit

/// Wraps UniverseScene in an NSViewRepresentable. Shows all collections as
/// floating globes. Clicking a globe flies the camera toward it and transitions
/// to GlobeView.
struct UniverseView: NSViewRepresentable {
    @EnvironmentObject var appState: AppState

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> SCNView {
        // Group images by collection
        var imagesByCollection: [UUID: [MuseImage]] = [:]
        var uncollectedImages: [MuseImage] = []
        for image in appState.images {
            if let collectionID = image.collectionID {
                imagesByCollection[collectionID, default: []].append(image)
            } else {
                uncollectedImages.append(image)
            }
        }

        // Build collections list — include real collections + an "All Images" pseudo-collection for uncollected
        var displayCollections = appState.collections.filter { imagesByCollection[$0.id] != nil }

        // If there are uncollected images, create a virtual collection for them
        let allImagesID = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
        if !uncollectedImages.isEmpty {
            let allCollection = MuseCollection(id: allImagesID, name: "Unsorted", colorHex: "#888888")
            displayCollections.insert(allCollection, at: 0)
            imagesByCollection[allImagesID] = uncollectedImages
        }

        // If still nothing to show, put all images in one globe
        if displayCollections.isEmpty && !appState.images.isEmpty {
            let allCollection = MuseCollection(id: allImagesID, name: "All Images", colorHex: "#5E8BFF")
            displayCollections.append(allCollection)
            imagesByCollection[allImagesID] = appState.images
        }

        let (scene, cameraNode, collectionGlobeMap) = UniverseScene.build(
            collections: displayCollections,
            imagesByCollection: imagesByCollection
        )

        let scnView = SCNView()
        scnView.scene = scene
        scnView.allowsCameraControl = true
        scnView.antialiasingMode = .multisampling4X
        scnView.backgroundColor = NSColor.white

        context.coordinator.scnView = scnView
        context.coordinator.cameraNode = cameraNode
        context.coordinator.collectionGlobeMap = collectionGlobeMap
        context.coordinator.appState = appState

        // Click gesture
        let click = NSClickGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleClick(_:)))
        scnView.addGestureRecognizer(click)

        return scnView
    }

    func updateNSView(_ nsView: SCNView, context: Context) {
        // Scene is rebuilt on makeNSView; no incremental updates needed.
    }

    // MARK: - Coordinator

    @MainActor
    class Coordinator: NSObject {
        weak var scnView: SCNView?
        weak var cameraNode: SCNNode?
        weak var appState: AppState?
        var collectionGlobeMap: [UUID: SCNNode] = [:]

        @objc func handleClick(_ gesture: NSClickGestureRecognizer) {
            guard let scnView = scnView, let cameraNode = cameraNode else { return }
            let location = gesture.location(in: scnView)
            let hitResults = scnView.hitTest(location, options: [.searchMode: SCNHitTestSearchMode.all.rawValue])

            // Walk up from hit node to find a globe container (name matches a collection UUID)
            for hit in hitResults {
                var node: SCNNode? = hit.node
                while let current = node {
                    if let name = current.name,
                       let uuid = UUID(uuidString: name),
                       collectionGlobeMap[uuid] != nil {
                        // Fly camera toward this globe
                        let globePosition = current.position
                        let flyTarget = SCNVector3(
                            globePosition.x,
                            globePosition.y,
                            globePosition.z + 8
                        )

                        CameraController.flyCamera(
                            cameraNode,
                            to: flyTarget,
                            lookAt: globePosition,
                            duration: 0.6
                        ) { [weak self] in
                            self?.appState?.viewMode = .globe(collectionID: uuid)
                        }
                        return
                    }
                    node = current.parent
                }
            }
        }
    }
}
