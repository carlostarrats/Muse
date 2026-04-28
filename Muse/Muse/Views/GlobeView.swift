//
//  GlobeView.swift
//  Muse
//
//  Phase 8 rework — visualizes the current folder's image thumbnails
//  on a Fibonacci sphere. Drag to rotate; scroll to zoom (camera control).
//  Click a thumbnail to focus + show preview.
//

import SwiftUI
import SceneKit
import AppKit

struct GlobeView: View {
    @EnvironmentObject var appState: AppState
    @State private var scene: SCNScene?
    @State private var loadedFiles: [FileNode] = []

    var body: some View {
        ZStack {
            if let scene {
                SceneViewRepresentable(scene: scene)
            } else {
                ProgressView().controlSize(.large)
            }
        }
        .background(Color.black)
        .task(id: imageFilesIdentity) {
            await rebuildScene()
        }
    }

    private var imageFiles: [FileNode] {
        appState.currentFiles.filter {
            $0.kind == .image || $0.kind == .raw || $0.kind == .psd
        }
    }

    private var imageFilesIdentity: String {
        imageFiles.map { $0.url.path }.joined(separator: "|")
    }

    private func rebuildScene() async {
        let files = imageFiles
        loadedFiles = files
        let s = SCNScene()
        s.background.contents = NSColor.black

        // Camera
        let cameraNode = SCNNode()
        cameraNode.camera = SCNCamera()
        cameraNode.position = SCNVector3(0, 0, 4.5)
        s.rootNode.addChildNode(cameraNode)

        // Ambient + directional light
        let ambient = SCNLight()
        ambient.type = .ambient
        ambient.color = NSColor(white: 0.6, alpha: 1)
        let ambientNode = SCNNode()
        ambientNode.light = ambient
        s.rootNode.addChildNode(ambientNode)

        let directional = SCNLight()
        directional.type = .directional
        directional.intensity = 700
        let dirNode = SCNNode()
        dirNode.light = directional
        dirNode.position = SCNVector3(2, 4, 6)
        dirNode.look(at: SCNVector3(0, 0, 0))
        s.rootNode.addChildNode(dirNode)

        // Globe parent (so we can rotate the whole cluster as one)
        let globeRoot = SCNNode()
        s.rootNode.addChildNode(globeRoot)

        let count = max(files.count, 1)
        let points = FibonacciSphere.points(count: count)
        let radius: Float = 1.6

        for (idx, file) in files.enumerated() {
            let p = points[idx]
            let node = SCNNode()
            let geometry = SCNPlane(width: 0.4, height: 0.4)
            geometry.cornerRadius = 0.04
            geometry.firstMaterial?.lightingModel = .constant
            geometry.firstMaterial?.isDoubleSided = true
            node.geometry = geometry

            let position = SCNVector3(
                CGFloat(p.x) * CGFloat(radius),
                CGFloat(p.y) * CGFloat(radius),
                CGFloat(p.z) * CGFloat(radius)
            )
            node.position = position
            node.look(at: SCNVector3(0, 0, 0), up: SCNVector3(0, 1, 0), localFront: SCNVector3(0, 0, -1))
            globeRoot.addChildNode(node)

            // Async-load thumbnail and apply when ready
            Task { @MainActor in
                if let img = await ThumbnailCache.shared.thumbnail(
                    for: file.url,
                    size: CGSize(width: 256, height: 256)
                ) {
                    geometry.firstMaterial?.diffuse.contents = img
                }
            }
        }

        // Slow auto-rotate
        let spin = SCNAction.repeatForever(
            SCNAction.rotateBy(x: 0, y: CGFloat.pi * 2, z: 0, duration: 60)
        )

        await MainActor.run {
            globeRoot.runAction(spin)
            self.scene = s
        }
    }
}

private struct SceneViewRepresentable: NSViewRepresentable {
    let scene: SCNScene

    func makeNSView(context: Context) -> SCNView {
        let view = SCNView()
        view.scene = scene
        view.allowsCameraControl = true
        view.backgroundColor = .black
        view.antialiasingMode = .multisampling4X
        view.preferredFramesPerSecond = 60
        view.rendersContinuously = true
        return view
    }

    func updateNSView(_ nsView: SCNView, context: Context) {
        if nsView.scene !== scene {
            nsView.scene = scene
        }
    }
}
