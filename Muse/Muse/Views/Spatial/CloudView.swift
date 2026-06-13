//
//  CloudView.swift
//  Muse
//
//  Cloud view: the current scope's images as flat cards floating in a loose
//  3D BALL on a calm canvas (editorial moodboard treatment). Move the mouse
//  to orbit around the cluster — cards stay upright (billboarded) while their
//  positions swing around, revealing parallax — with a slow continuous drift.
//  Scroll to zoom; click a card to run the shared hero zoom. One perspective
//  camera; scene units = reference-canvas pixels.
//

import SwiftUI
import SceneKit
import AppKit
import simd

struct CloudView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        GeometryReader { geo in
            CloudSceneRepresentable(
                files: imageFiles,
                palette: appState.moodPalette,
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
                .foregroundStyle(.tertiary)
            Text(appState.selectedFolder == nil ? "Select a folder" : "No images here")
                .font(.title3)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Representable

private struct CloudSceneRepresentable: NSViewRepresentable {
    let files: [FileNode]
    let palette: MoodPalette
    let onOpen: (FileNode, CGRect) -> Void

    func makeCoordinator() -> CloudSceneCoordinator { CloudSceneCoordinator() }

    func makeNSView(context: Context) -> CloudSCNView {
        let view = CloudSCNView()
        view.coordinator = context.coordinator
        view.backgroundColor = palette.backgroundRGB.nsColor
        view.antialiasingMode = .multisampling4X
        view.rendersContinuously = true
        view.allowsCameraControl = false
        context.coordinator.onOpen = onOpen
        context.coordinator.rebuildIfNeeded(files: files, palette: palette, in: view)
        return view
    }

    func updateNSView(_ nsView: CloudSCNView, context: Context) {
        context.coordinator.onOpen = onOpen
        context.coordinator.rebuildIfNeeded(files: files, palette: palette, in: nsView)
        context.coordinator.applyPalette(palette, in: nsView)
    }
}

// MARK: - Coordinator (scene graph owner)

@MainActor
final class CloudSceneCoordinator: NSObject {
    var onOpen: (FileNode, CGRect) -> Void = { _, _ in }

    private(set) var cardNodes: [SCNNode] = []   // parallel to `files`
    private(set) var files: [FileNode] = []
    private var identity: String = "<unbuilt>"
    nonisolated(unsafe) private var thumbnailTask: Task<Void, Never>?

    deinit { thumbnailTask?.cancel() }

    func rebuildIfNeeded(files newFiles: [FileNode], palette: MoodPalette, in view: CloudSCNView) {
        let newIdentity = newFiles.map(\.url.path).joined(separator: "|")
        guard newIdentity != identity else { return }
        identity = newIdentity
        thumbnailTask?.cancel()
        files = newFiles

        let scene = SCNScene()
        scene.background.contents = palette.backgroundRGB.nsColor

        let seed = SeededRandom.fnv1a(newFiles.map(\.url.path))
        let cards = CloudLayout.cards(count: newFiles.count, seed: seed)

        let camera = SCNCamera()
        camera.zNear = 20
        camera.zFar = 20000
        camera.fieldOfView = CloudMath.verticalFOV
        camera.projectionDirection = .vertical
        let camNode = SCNNode()
        camNode.camera = camera
        let distance = Self.framingDistance(for: cards)
        camNode.position = SCNVector3(0, 0, CGFloat(distance))
        scene.rootNode.addChildNode(camNode)

        // All cards live under one cluster node; orbiting rotates this node.
        let cluster = SCNNode()
        scene.rootNode.addChildNode(cluster)

        let billboard = SCNBillboardConstraint()
        billboard.freeAxes = .all

        var rng = SeededRandom(seed: seed &+ 7)
        cardNodes = []
        for (i, card) in cards.enumerated() {
            let node = SCNNode(geometry: Self.cardGeometry(w: card.w, h: card.h))
            node.simdPosition = card.position
            node.constraints = [billboard]
            node.name = "card-\(i)"
            // Each card floats independently (on top of the cluster's
            // rotation), so the whole thing stays alive.
            node.runAction(Self.driftAction(rng: &rng), forKey: "drift")
            cluster.addChildNode(node)
            cardNodes.append(node)
        }

        view.scene = scene
        view.pointOfView = camNode
        view.configure(clusterNode: cluster, cameraNode: camNode,
                       framingDistance: distance)
        loadThumbnails()
    }

    /// Distance that frames the whole ball compactly in the centre of a calm
    /// canvas (generous whitespace), not filling the viewport.
    private static func framingDistance(for cards: [CloudCard]) -> Float {
        guard !cards.isEmpty else { return Float(CloudPose.f) }
        var maxExtent: Float = 0
        for c in cards {
            let d = simd_length(c.position) + Float(max(c.w, c.h)) / 2
            maxExtent = max(maxExtent, d)
        }
        let halfFov = Float(CloudMath.verticalFOV) * .pi / 180 / 2
        return max(Float(CloudPose.f), maxExtent / tan(halfFov) * 2.3)
    }

    func applyPalette(_ palette: MoodPalette, in view: SCNView) {
        view.backgroundColor = palette.backgroundRGB.nsColor
        view.scene?.background.contents = palette.backgroundRGB.nsColor
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

    /// Continuous 3D float — a roaming bob in every axis, unique phase per
    /// card, so the cluster is always in motion. Purely relative: the legs and
    /// their reverses net to zero, returning each card to its home position.
    private static func driftAction(rng: inout SeededRandom) -> SCNAction {
        var legs: [SCNAction] = []
        var reverses: [SCNAction] = []
        for _ in 0..<3 {
            let dx = CGFloat(Double.random(in: -36...36, using: &rng))
            let dy = CGFloat(Double.random(in: -36...36, using: &rng))
            let dz = CGFloat(Double.random(in: -36...36, using: &rng))
            let dur = Double.random(in: 1.8...3.4, using: &rng)
            let a = SCNAction.moveBy(x: dx, y: dy, z: dz, duration: dur)
            a.timingMode = .easeInEaseOut
            legs.append(a)
            reverses.append(a.reversed())
        }
        return .repeatForever(.sequence(legs + reverses.reversed()))
    }
}

// MARK: - SCNView subclass (drag-to-orbit + zoom + click)

/// Click and DRAG to orbit the cluster (with inertia after release); it also
/// drifts slowly on its own so it's never static. Passive mouse movement does
/// nothing. Scroll dollies the camera; a click (no drag) opens the card under
/// the cursor with the hero zoom. Rotation integrates every frame in the
/// render loop.
final class CloudSCNView: SCNView, SCNSceneRendererDelegate {
    weak var coordinator: CloudSceneCoordinator?

    private weak var clusterNode: SCNNode?
    private weak var cameraNode: SCNNode?
    private var framingDistance: Float = 1300

    // Rotation state (read on the render thread, written from the main thread —
    // benign races, visual only).
    nonisolated(unsafe) private var yaw: Float = 0
    nonisolated(unsafe) private var pitch: Float = 0
    nonisolated(unsafe) private var yawVel: Float = 0
    nonisolated(unsafe) private var pitchVel: Float = 0
    nonisolated(unsafe) private var dragging = false

    private static let dragSensitivity: Float = 0.011   // rad per point
    private static let autoSpinPerFrame: Float = 0.0016 // gentle idle spin
    private static let inertiaDecay: Float = 0.94
    private static let maxPitch: Float = 1.25           // ~72°, no flipping

    private var mouseDownPoint: NSPoint?
    private var lastDragPoint: NSPoint?
    private var didDrag = false

    func configure(clusterNode: SCNNode, cameraNode: SCNNode, framingDistance: Float) {
        self.clusterNode = clusterNode
        self.cameraNode = cameraNode
        self.framingDistance = framingDistance
        delegate = self
    }

    // MARK: render loop — integrate drag inertia + idle spin

    nonisolated func renderer(_ renderer: SCNSceneRenderer, updateAtTime time: TimeInterval) {
        if !dragging {
            yaw += yawVel
            pitch += pitchVel
            yawVel *= Self.inertiaDecay
            pitchVel *= Self.inertiaDecay
        }
        yaw += Self.autoSpinPerFrame                 // always a little alive
        pitch = max(-Self.maxPitch, min(Self.maxPitch, pitch))
        clusterNode?.eulerAngles = SCNVector3(CGFloat(pitch), CGFloat(yaw), 0)
    }

    // MARK: drag → orbit

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        mouseDownPoint = p
        lastDragPoint = p
        didDrag = false
        dragging = true
        yawVel = 0
        pitchVel = 0
    }

    override func mouseDragged(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        guard let last = lastDragPoint else { lastDragPoint = p; return }
        let dx = Float(p.x - last.x)
        let dy = Float(p.y - last.y)
        if let down = mouseDownPoint, hypot(p.x - down.x, p.y - down.y) > 4 { didDrag = true }
        yaw += dx * Self.dragSensitivity
        pitch -= dy * Self.dragSensitivity
        yawVel = dx * Self.dragSensitivity           // carry velocity for inertia
        pitchVel = -dy * Self.dragSensitivity
        lastDragPoint = p
    }

    override func mouseUp(with event: NSEvent) {
        dragging = false
        defer { mouseDownPoint = nil; lastDragPoint = nil }
        if didDrag { return }                        // a drag, not a click
        let point = convert(event.locationInWindow, from: nil)
        let hits = hitTest(point, options: [.searchMode: NSNumber(value: SCNHitTestSearchMode.all.rawValue)])
        for hit in hits {
            if let (file, node) = coordinator?.file(forCardNode: hit.node) {
                let rect = SceneProjection.screenRect(of: node, in: self)
                    ?? CGRect(x: bounds.midX - 80, y: bounds.midY - 80, width: 160, height: 160)
                coordinator?.onOpen(file, rect)
                return
            }
        }
    }

    // MARK: scroll / pinch → zoom (dolly)

    override func scrollWheel(with event: NSEvent) {
        dolly(by: -Float(event.scrollingDeltaY) * framingDistance * 0.0018)
    }

    override func magnify(with event: NSEvent) {
        // Pinch out (positive) zooms in.
        dolly(by: -Float(event.magnification) * framingDistance * 1.4)
    }

    /// Move the camera toward/away from the cluster, clamped so you can push
    /// in close to a single card or pull back past the full cluster.
    private func dolly(by deltaZ: Float) {
        guard let cameraNode else { return }
        let z = Float(cameraNode.position.z) + deltaZ
        let minZ = framingDistance * 0.12     // deep zoom-in
        let maxZ = framingDistance * 2.2
        cameraNode.position.z = CGFloat(min(max(z, minZ), maxZ))
    }
}
