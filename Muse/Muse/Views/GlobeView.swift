//
//  GlobeView.swift
//  Muse
//
//  Created by Carlos Tarrats on 3/19/26.
//

import SwiftUI
import SceneKit

/// Wraps a GlobeScene in an NSViewRepresentable for displaying a single
/// collection's images on a 3D sphere with drag-to-spin and click-to-focus.
struct GlobeView: NSViewRepresentable {
    @EnvironmentObject var appState: AppState
    let collectionID: UUID

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> SCNView {
        let images = appState.images.filter { $0.collectionID == collectionID }
        let (scene, globeNode, cameraNode) = GlobeScene.build(images: images)

        let scnView = SCNView()
        scnView.scene = scene
        scnView.allowsCameraControl = true
        scnView.antialiasingMode = .multisampling4X
        scnView.backgroundColor = NSColor.white

        context.coordinator.scnView = scnView
        context.coordinator.globeNode = globeNode
        context.coordinator.cameraNode = cameraNode
        context.coordinator.appState = appState

        // Click gesture
        let click = NSClickGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleClick(_:)))
        scnView.addGestureRecognizer(click)

        // Pan gesture for manual spin
        let pan = NSPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handlePan(_:)))
        scnView.addGestureRecognizer(pan)

        return scnView
    }

    func updateNSView(_ nsView: SCNView, context: Context) {
        // Detect when detail panel is dismissed to unfocus
        if !appState.detailPanelVisible && context.coordinator.focusedNodeName != nil {
            context.coordinator.unfocus()
        }
    }

    // MARK: - Coordinator

    @MainActor
    class Coordinator: NSObject {
        weak var scnView: SCNView?
        weak var globeNode: SCNNode?
        weak var cameraNode: SCNNode?
        weak var appState: AppState?

        /// The name (UUID string) of the currently focused image node.
        var focusedNodeName: String?

        /// Original transform of the focused node, for unfocus restoration.
        private var originalPosition: SCNVector3?
        private var originalScale: SCNVector3?
        private var originalEulerAngles: SCNVector3?

        /// Timer to resume auto-rotation after drag ends.
        private var resumeRotationTimer: Timer?

        // MARK: - Click to Focus

        @objc func handleClick(_ gesture: NSClickGestureRecognizer) {
            guard let scnView = scnView else { return }
            let location = gesture.location(in: scnView)
            let hitResults = scnView.hitTest(location, options: [.searchMode: SCNHitTestSearchMode.all.rawValue])

            // Find the first hit node whose name is a valid UUID (an image node)
            for hit in hitResults {
                var node: SCNNode? = hit.node
                while let current = node {
                    if let name = current.name, UUID(uuidString: name) != nil {
                        if focusedNodeName == name {
                            // Clicking the same focused image — unfocus
                            unfocus()
                        } else {
                            focus(node: current)
                        }
                        return
                    }
                    // Don't walk past the globe container
                    if current.name == "globe" { break }
                    node = current.parent
                }
            }

            // Clicked empty space — unfocus if focused
            if focusedNodeName != nil {
                unfocus()
            }
        }

        private func focus(node: SCNNode) {
            guard let globeNode = globeNode, let appState = appState else { return }

            // Unfocus previous if any
            if focusedNodeName != nil {
                restorePreviousFocus(animated: false)
            }

            focusedNodeName = node.name
            originalPosition = node.position
            originalScale = node.scale
            originalEulerAngles = node.eulerAngles

            // Pause auto-rotation
            globeNode.removeAction(forKey: "autoRotate")

            SCNTransaction.begin()
            SCNTransaction.animationDuration = 0.4
            SCNTransaction.animationTimingFunction = CAMediaTimingFunction(name: .easeInEaseOut)

            // Move focused node forward and to the left
            node.position = SCNVector3(-1.5, 0, 5)
            node.scale = SCNVector3(2.2, 2.2, 2.2)
            node.eulerAngles = SCNVector3Zero
            node.look(at: SCNVector3(-1.5, 0, 10))

            // Fade other nodes
            for child in globeNode.childNodes where child.name != node.name {
                child.opacity = 0.08
            }

            SCNTransaction.commit()

            // Update app state
            if let name = node.name, let uuid = UUID(uuidString: name) {
                appState.selectedImage = appState.images.first { $0.id == uuid }
                appState.detailPanelVisible = true
            }
        }

        func unfocus() {
            restorePreviousFocus(animated: true)
            focusedNodeName = nil

            // Dismiss detail panel
            appState?.detailPanelVisible = false
            appState?.selectedImage = nil

            // Resume auto-rotation
            if let globeNode = globeNode {
                let rotation = SCNAction.rotateBy(x: 0, y: .pi * 2, z: 0, duration: 25)
                globeNode.runAction(.repeatForever(rotation), forKey: "autoRotate")
            }
        }

        private func restorePreviousFocus(animated: Bool) {
            guard let globeNode = globeNode,
                  let focusedName = focusedNodeName,
                  let focusedNode = globeNode.childNode(withName: focusedName, recursively: false)
            else { return }

            if animated {
                SCNTransaction.begin()
                SCNTransaction.animationDuration = 0.35
                SCNTransaction.animationTimingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            }

            focusedNode.position = originalPosition ?? focusedNode.position
            focusedNode.scale = originalScale ?? SCNVector3(1, 1, 1)
            focusedNode.eulerAngles = originalEulerAngles ?? SCNVector3Zero

            for child in globeNode.childNodes {
                child.opacity = 1.0
            }

            if animated {
                SCNTransaction.commit()
            }
        }

        // MARK: - Pan to Spin

        @objc func handlePan(_ gesture: NSPanGestureRecognizer) {
            guard let globeNode = globeNode else { return }

            switch gesture.state {
            case .began:
                // Pause auto-rotation during drag
                globeNode.isPaused = true
                resumeRotationTimer?.invalidate()

            case .changed:
                let translation = gesture.translation(in: gesture.view)
                let sensitivity: CGFloat = 0.005
                globeNode.eulerAngles.y += translation.x * sensitivity
                globeNode.eulerAngles.x += translation.y * sensitivity
                gesture.setTranslation(.zero, in: gesture.view)

            case .ended, .cancelled:
                // Resume auto-rotation after a short delay
                globeNode.isPaused = false
                resumeRotationTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: false) { [weak self] _ in
                    Task { @MainActor in
                        self?.globeNode?.isPaused = false
                    }
                }

            default:
                break
            }
        }
    }
}
