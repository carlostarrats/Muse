//
//  CloudView.swift
//  Muse
//
//  Spec §3 cloud view: the current scope's images as true-3D tilted
//  cards on a fixed-aspect letterboxed stage, matching
//  docs/superpowers/assets/cloud-pose-prototype.html. One perspective
//  camera; scene units = reference-canvas pixels.
//

import SwiftUI
import SceneKit
import AppKit

struct CloudView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        GeometryReader { geo in
            CloudSceneRepresentable(
                files: imageFiles,
                onOpen: { file, localRect in
                    let origin = geo.frame(in: .global).origin
                    appState.tileFrames[file.url.path] =
                        localRect.offsetBy(dx: origin.x, dy: origin.y)
                    appState.selectedFile = file
                }
            )
            .overlay {
                if imageFiles.isEmpty { emptyState }
            }
        }
    }

    private var imageFiles: [FileNode] {
        appState.visibleFiles.filter {
            $0.kind == .image || $0.kind == .raw || $0.kind == .psd
        }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "photo.stack")
                .font(.system(size: 48))
                .foregroundStyle(Color(red: 0.45, green: 0.33, blue: 0.20).opacity(0.5))
            Text(appState.selectedFolder == nil ? "Select a folder" : "No images here")
                .font(.title3)
                .foregroundStyle(Color(red: 0.45, green: 0.33, blue: 0.20).opacity(0.7))
        }
    }
}

// MARK: - Representable

private struct CloudSceneRepresentable: NSViewRepresentable {
    let files: [FileNode]
    let onOpen: (FileNode, CGRect) -> Void

    func makeCoordinator() -> CloudSceneCoordinator { CloudSceneCoordinator() }

    func makeNSView(context: Context) -> CloudSCNView {
        let view = CloudSCNView()
        view.coordinator = context.coordinator
        view.backgroundColor = NSColor(red: 0.902, green: 0.812, blue: 0.710, alpha: 1) // #E6CFB5
        view.antialiasingMode = .multisampling4X
        view.rendersContinuously = true
        view.allowsCameraControl = false
        context.coordinator.rebuildIfNeeded(files: files, in: view)
        return view
    }

    func updateNSView(_ nsView: CloudSCNView, context: Context) {
        context.coordinator.onOpen = onOpen
        context.coordinator.rebuildIfNeeded(files: files, in: nsView)
        nsView.updateProjection()
    }
}

// MARK: - Coordinator (scene graph owner)

@MainActor
final class CloudSceneCoordinator: NSObject {
    var onOpen: (FileNode, CGRect) -> Void = { _, _ in }

    /// pivot node (drift) -> card node (pose/hover). Parallel to `files`.
    private(set) var cardNodes: [SCNNode] = []
    private(set) var files: [FileNode] = []
    private(set) var poses: [CloudPose] = []
    private var identity: String = "<unbuilt>"
    nonisolated(unsafe) private var thumbnailTask: Task<Void, Never>?

    deinit { thumbnailTask?.cancel() }

    static let shadowImage: NSImage = makeShadowImage()

    func rebuildIfNeeded(files newFiles: [FileNode], in view: SCNView) {
        let newIdentity = newFiles.map(\.url.path).joined(separator: "|")
        guard newIdentity != identity else { return }
        identity = newIdentity
        thumbnailTask?.cancel()
        files = newFiles

        let scene = SCNScene()
        scene.background.contents = NSColor(red: 0.902, green: 0.812, blue: 0.710, alpha: 1)

        let camera = SCNCamera()
        camera.zNear = 50
        camera.zFar = 6000
        camera.fieldOfView = CloudMath.verticalFOV
        let camNode = SCNNode()
        camNode.camera = camera
        camNode.position = SCNVector3(0, 0, CloudPose.f)
        scene.rootNode.addChildNode(camNode)

        let seed = SeededRandom.fnv1a(newFiles.map(\.url.path))
        let poses = CloudLayout.poses(count: newFiles.count, seed: seed)
        self.poses = poses
        var rng = SeededRandom(seed: seed &+ 1)

        cardNodes = []
        for (i, pose) in poses.enumerated() {
            let pivot = SCNNode()
            var p = CloudMath.position(cx: pose.cx, cy: pose.cy)
            p.z = CloudMath.stackingZ(cy: pose.cy)
            pivot.simdPosition = p
            pivot.runAction(Self.driftAction(rng: &rng), forKey: "drift")

            let card = SCNNode(geometry: Self.cardGeometry(w: pose.w, h: pose.h))
            card.simdOrientation = CloudMath.orientation(
                rxDeg: pose.rx, ryDeg: pose.ry, rzDeg: pose.rz)
            card.name = "card-\(i)"

            let shadow = SCNNode(geometry: Self.shadowGeometry(w: pose.w, h: pose.h))
            shadow.position = SCNVector3(10, -18, -6)   // CSS 10px right, 18px down
            shadow.renderingOrder = -1
            card.addChildNode(shadow)

            pivot.addChildNode(card)
            scene.rootNode.addChildNode(pivot)
            cardNodes.append(card)
        }

        view.scene = scene
        view.pointOfView = camNode
        loadThumbnails()
    }

    func file(forCardNode node: SCNNode) -> (FileNode, SCNNode)? {
        var n: SCNNode? = node
        while let current = n {
            if let name = current.name, name.hasPrefix("card-"),
               let i = Int(name.dropFirst(5)), i < files.count {
                return (files[i], current)
            }
            n = current.parent
        }
        return nil
    }

    // MARK: hover (prototype: flat + scale 1.15, .5s cubic-bezier(.25,.85,.3,1))

    private weak var hoveredCard: SCNNode?

    func setHovered(_ card: SCNNode?) {
        guard card !== hoveredCard else { return }
        SCNTransaction.begin()
        SCNTransaction.animationDuration = 0.5
        SCNTransaction.animationTimingFunction = CAMediaTimingFunction(controlPoints: 0.25, 0.85, 0.3, 1)
        if let old = hoveredCard, let i = cardNodes.firstIndex(where: { $0 === old }) {
            if poses.indices.contains(i) {
                old.simdOrientation = CloudMath.orientation(
                    rxDeg: poses[i].rx, ryDeg: poses[i].ry, rzDeg: poses[i].rz)
            }
            old.simdScale = SIMD3(1, 1, 1)
            old.simdPosition = SIMD3(0, 0, 0)
        }
        if let card {
            card.simdOrientation = simd_quatf(angle: 0, axis: SIMD3(0, 0, 1)) // flat
            card.simdScale = SIMD3(1.15, 1.15, 1.15)
            card.simdPosition = SIMD3(0, 0, 140)   // float up toward the camera
        }
        hoveredCard = card
        SCNTransaction.commit()
    }

    private func loadThumbnails() {
        let nodes = cardNodes
        let toLoad = files
        thumbnailTask = Task { @MainActor in
            for (i, file) in toLoad.enumerated() {
                if Task.isCancelled { return }
                guard i < nodes.count,
                      let plane = nodes[i].geometry as? SCNPlane else { continue }
                if let img = await ThumbnailCache.shared.thumbnail(
                    for: file.url, size: CGSize(width: 256, height: 256)
                ) {
                    Self.applyCover(image: img, to: plane)
                }
            }
        }
    }

    // MARK: geometry + materials

    private static func cardGeometry(w: Double, h: Double) -> SCNPlane {
        let plane = SCNPlane(width: w, height: h)
        let m = plane.firstMaterial!
        m.lightingModel = .constant
        m.isDoubleSided = true
        m.diffuse.contents = NSColor(white: 0.92, alpha: 1)   // until thumbnail lands
        return plane
    }

    /// object-fit: cover — scale the texture so it fills the card and
    /// crop symmetrically via contentsTransform.
    static func applyCover(image: NSImage, to plane: SCNPlane) {
        let m = plane.firstMaterial!
        m.diffuse.contents = image
        let imgAspect = image.size.height > 0 ? image.size.width / image.size.height : 1
        let cardAspect = plane.width / plane.height
        var sx: CGFloat = 1, sy: CGFloat = 1
        if imgAspect > cardAspect { sx = cardAspect / imgAspect } else { sy = imgAspect / cardAspect }
        m.diffuse.contentsTransform = SCNMatrix4Mult(
            SCNMatrix4MakeScale(sx, sy, 1),
            SCNMatrix4MakeTranslation((1 - sx) / 2, (1 - sy) / 2, 0))
        m.diffuse.wrapS = .clamp
        m.diffuse.wrapT = .clamp
    }

    private static func shadowGeometry(w: Double, h: Double) -> SCNPlane {
        let plane = SCNPlane(width: w * 1.5, height: h * 1.5)
        let m = plane.firstMaterial!
        m.lightingModel = .constant
        m.diffuse.contents = shadowImage
        m.isDoubleSided = true
        m.writesToDepthBuffer = false
        m.blendMode = .alpha
        return plane
    }

    /// One shared soft warm radial shadow texture
    /// (prototype: box-shadow 10px 18px 34px rgba(95,65,35,.28)).
    private static func makeShadowImage() -> NSImage {
        let size = NSSize(width: 128, height: 128)
        let img = NSImage(size: size)
        img.lockFocus()
        let warm = NSColor(red: 95 / 255, green: 65 / 255, blue: 35 / 255, alpha: 0.28)
        let gradient = NSGradient(colors: [warm, warm.withAlphaComponent(0)])!
        gradient.draw(in: NSBezierPath(ovalIn: NSRect(origin: .zero, size: size)),
                      relativeCenterPosition: .zero)
        img.unlockFocus()
        return img
    }

    /// Barely-there drift, a few px, unique phase per card (spec §3).
    private static func driftAction(rng: inout SeededRandom) -> SCNAction {
        let dx = CGFloat(Double.random(in: 1.5...3.5, using: &rng))
            * (Bool.random(using: &rng) ? 1 : -1)
        let dy = CGFloat(Double.random(in: 1.5...3.5, using: &rng))
            * (Bool.random(using: &rng) ? 1 : -1)
        let duration = Double.random(in: 2.6...4.4, using: &rng)
        let out = SCNAction.moveBy(x: dx, y: dy, z: 0, duration: duration)
        out.timingMode = .easeInEaseOut
        let back = SCNAction.moveBy(x: -dx, y: -dy, z: 0, duration: duration)
        back.timingMode = .easeInEaseOut
        return .repeatForever(.sequence([out, back]))
    }
}

// MARK: - SCNView subclass (letterboxing + hover + click)

final class CloudSCNView: SCNView {
    weak var coordinator: CloudSceneCoordinator?
    private var trackingArea: NSTrackingArea?
    private var mouseDownPoint: NSPoint?

    override func layout() {
        super.layout()
        updateProjection()
    }

    /// Fixed-aspect stage, letterboxed (spec §3): fit the stage HEIGHT
    /// when the view is wider than the stage, fit the WIDTH when
    /// narrower. The beige background fills the spare space seamlessly.
    func updateProjection() {
        guard let cam = pointOfView?.camera, bounds.height > 0 else { return }
        let viewAspect = bounds.width / bounds.height
        let stageAspect = CGFloat(CloudPose.refW / CloudPose.refH)
        if viewAspect >= stageAspect {
            cam.projectionDirection = .vertical
            cam.fieldOfView = CloudMath.verticalFOV
        } else {
            cam.projectionDirection = .horizontal
            cam.fieldOfView = CloudMath.horizontalFOV
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow],
            owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    private func cardHit(_ event: NSEvent) -> (FileNode, SCNNode)? {
        let point = convert(event.locationInWindow, from: nil)
        let hits = hitTest(point, options: [.searchMode: NSNumber(value: SCNHitTestSearchMode.all.rawValue)])
        for hit in hits {
            if let match = coordinator?.file(forCardNode: hit.node) { return match }
        }
        return nil
    }

    override func mouseMoved(with event: NSEvent) {
        coordinator?.setHovered(cardHit(event)?.1)
    }

    override func mouseExited(with event: NSEvent) {
        coordinator?.setHovered(nil)
    }

    override func mouseDown(with event: NSEvent) {
        mouseDownPoint = convert(event.locationInWindow, from: nil)
    }

    override func mouseUp(with event: NSEvent) {
        defer { mouseDownPoint = nil }
        let up = convert(event.locationInWindow, from: nil)
        if let down = mouseDownPoint, hypot(up.x - down.x, up.y - down.y) > 6 { return }
        guard let (file, node) = cardHit(event) else { return }
        let rect = SceneProjection.screenRect(of: node, in: self)
            ?? CGRect(x: bounds.midX - 80, y: bounds.midY - 80, width: 160, height: 160)
        coordinator?.onOpen(file, rect)
    }
}
