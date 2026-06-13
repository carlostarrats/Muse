//
//  GalaxyView.swift
//  Muse
//
//  Spatial "galaxy" (replaces the old collection graph). The current folder's
//  images (plus subfolders when that toggle is on) float in a pseudo-3D cloud,
//  positioned by GalaxyModel's blended look + meaning + color similarity.
//  Drag orbits, scroll zooms, click opens the image in the hero viewer.
//  Dominant-tag labels float over clusters; faint lines link nearest matches.
//

import SwiftUI
import SceneKit
import AppKit
import simd

struct GalaxyView: View {
    @EnvironmentObject var appState: AppState
    @State private var data: GalaxyData?

    var body: some View {
        GeometryReader { geo in
            ZStack {
                appState.moodPalette.background.ignoresSafeArea()

                if let data, data.nodes.count > 1 {
                    GalaxySceneRepresentable(
                        data: data,
                        palette: appState.moodPalette,
                        onOpen: { path, localRect in
                            guard let file = fileByPath[path] else { return }
                            let origin = geo.frame(in: .global).origin
                            appState.tileFrames[file.url.path] =
                                localRect.offsetBy(dx: origin.x, dy: origin.y)
                            appState.selectedFile = file
                        }
                    )
                    if data.wasCapped {
                        capBanner(shown: data.nodes.count, total: data.totalInScope)
                    }
                } else if data != nil {
                    emptyState
                } else {
                    ProgressView().controlSize(.large)
                }
            }
        }
        .task(id: scopeIdentity) {
            data = nil
            await rebuild()
        }
    }

    private var imageFiles: [FileNode] {
        appState.visibleFiles.filter {
            $0.kind == .image || $0.kind == .raw || $0.kind == .psd
        }
    }

    private var fileByPath: [String: FileNode] {
        Dictionary(imageFiles.map { ($0.url.standardizedFileURL.path, $0) },
                   uniquingKeysWith: { a, _ in a })
    }

    private var scopeIdentity: String {
        imageFiles.map(\.url.path).joined(separator: "|")
    }

    private func rebuild() async {
        guard let q = Database.shared.dbQueue else { data = .empty; return }
        let paths = imageFiles.map { $0.url.standardizedFileURL.path }
        data = (try? await GalaxyModel.build(queue: q, scopePaths: paths)) ?? .empty
    }

    private func capBanner(shown: Int, total: Int) -> some View {
        Text("Showing \(shown) of \(total) — galaxy is capped for performance")
            .font(.caption)
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(Capsule().fill(.ultraThinMaterial))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .padding(.bottom, 16)
            .allowsHitTesting(false)
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "sparkles")
                .font(.system(size: 48))
                .foregroundStyle(.tertiary)
            Text(appState.selectedFolder == nil ? "Select a folder"
                                                : "Not enough analyzed images")
                .font(.title3)
                .foregroundStyle(.secondary)
            if appState.selectedFolder != nil {
                Text("Run Analyze (✨) on this folder to build the galaxy.")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Representable

private struct GalaxySceneRepresentable: NSViewRepresentable {
    let data: GalaxyData
    let palette: MoodPalette
    let onOpen: (String, CGRect) -> Void

    func makeCoordinator() -> GalaxySceneCoordinator { GalaxySceneCoordinator() }

    func makeNSView(context: Context) -> GalaxySCNView {
        let view = GalaxySCNView()
        view.coordinator = context.coordinator
        view.antialiasingMode = .multisampling4X
        view.allowsCameraControl = true
        view.backgroundColor = palette.backgroundRGB.nsColor
        context.coordinator.onOpen = onOpen
        context.coordinator.rebuildIfNeeded(data: data, palette: palette, in: view)
        return view
    }

    func updateNSView(_ nsView: GalaxySCNView, context: Context) {
        context.coordinator.onOpen = onOpen
        context.coordinator.rebuildIfNeeded(data: data, palette: palette, in: nsView)
        context.coordinator.applyPalette(palette, in: nsView)
    }
}

// MARK: - Coordinator

@MainActor
final class GalaxySceneCoordinator: NSObject {
    var onOpen: (String, CGRect) -> Void = { _, _ in }

    static let spreadRadius: Float = 520
    static let tileSize: CGFloat = 46
    static let cameraZ: Float = 1300

    private(set) var nodes: [SCNNode] = []         // parallel to data.nodes
    private(set) var data = GalaxyData.empty
    private var identity = "<unbuilt>"
    private var cameraNode = SCNNode()
    private var edgesNode = SCNNode()
    nonisolated(unsafe) private var thumbnailTask: Task<Void, Never>?

    deinit { thumbnailTask?.cancel() }

    func rebuildIfNeeded(data newData: GalaxyData, palette: MoodPalette, in view: SCNView) {
        guard newData.identity != identity else { return }
        identity = newData.identity
        thumbnailTask?.cancel()
        data = newData

        let scene = SCNScene()
        applySceneBackground(scene, palette: palette)

        let camera = SCNCamera()
        camera.zNear = 10
        camera.zFar = 6000
        camera.fieldOfView = 50
        cameraNode = SCNNode()
        cameraNode.camera = camera
        cameraNode.position = SCNVector3(0, 0, CGFloat(Self.cameraZ))
        scene.rootNode.addChildNode(cameraNode)

        let spread = Self.spreadRadius

        // Constellation lines (under the tiles).
        edgesNode = SCNNode()
        let lineColor = Self.contrastColor(for: palette, alpha: 0.22)
        for e in data.edges where e.a < data.positions.count && e.b < data.positions.count {
            edgesNode.addChildNode(Self.lineNode(
                from: data.positions[e.a] * spread,
                to: data.positions[e.b] * spread,
                color: lineColor))
        }
        scene.rootNode.addChildNode(edgesNode)

        // Image tiles — billboarded so they always face the camera as it orbits.
        nodes = []
        let billboard = SCNBillboardConstraint()
        billboard.freeAxes = .all
        for (i, node) in data.nodes.enumerated() {
            // Intent backing: a slightly larger plane behind the tile, tinted by bucket.
            if let key = node.intent,
               let bucket = IntentBucket(rawValue: key),
               let color = Self.nsColor(hex: bucket.galaxyHex) {
                let backing = SCNPlane(width: Self.tileSize * 1.28, height: Self.tileSize * 1.28)
                let bm = backing.firstMaterial!
                bm.lightingModel = .constant
                bm.diffuse.contents = color
                bm.isDoubleSided = true
                let backingNode = SCNNode(geometry: backing)
                backingNode.simdPosition = data.positions[i] * spread + SIMD3(0, 0, -1)
                backingNode.constraints = [billboard]
                scene.rootNode.addChildNode(backingNode)
            }

            let plane = SCNPlane(width: Self.tileSize, height: Self.tileSize)
            let m = plane.firstMaterial!
            m.lightingModel = .constant
            m.diffuse.contents = NSColor(white: 0.5, alpha: 1)
            m.isDoubleSided = true
            let tile = SCNNode(geometry: plane)
            tile.name = "tile-\(i)"
            tile.simdPosition = data.positions[i] * spread
            tile.constraints = [billboard]
            scene.rootNode.addChildNode(tile)
            nodes.append(tile)
        }

        view.scene = scene
        view.pointOfView = cameraNode
        configureCamera(view)
        loadThumbnails()
    }

    private func configureCamera(_ view: SCNView) {
        let controller = view.defaultCameraController
        controller.interactionMode = .orbitTurntable
        controller.target = SCNVector3(0, 0, 0)
        controller.maximumVerticalAngle = 85
        controller.minimumVerticalAngle = -85
        controller.inertiaEnabled = true
    }

    // MARK: palette / background

    func applyPalette(_ palette: MoodPalette, in view: SCNView) {
        view.backgroundColor = palette.backgroundRGB.nsColor
        if let scene = view.scene { applySceneBackground(scene, palette: palette) }
    }

    private func applySceneBackground(_ scene: SCNScene, palette: MoodPalette) {
        let bg = palette.backgroundRGB.nsColor
        scene.background.contents = bg
        // Depth fade: far tiles dissolve into the background colour.
        scene.fogColor = bg
        scene.fogStartDistance = CGFloat(Self.cameraZ - Self.spreadRadius * 0.3)
        scene.fogEndDistance = CGFloat(Self.cameraZ + Self.spreadRadius * 1.7)
        scene.fogDensityExponent = 1.4
    }

    private func loadThumbnails() {
        let work: [(SCNNode, String)] = zip(nodes, data.nodes.map(\.path)).map { ($0, $1) }
        thumbnailTask = Task { @MainActor in
            for (node, path) in work {
                if Task.isCancelled { return }
                guard let plane = node.geometry as? SCNPlane else { continue }
                if let img = await ThumbnailCache.shared.thumbnail(
                    for: URL(fileURLWithPath: path),
                    size: CGSize(width: 128, height: 128)
                ) {
                    CloudSceneCoordinator.applyCover(image: img, to: plane)
                }
            }
        }
    }

    // MARK: geometry helpers

    private static func lineNode(from a: SIMD3<Float>, to b: SIMD3<Float>,
                                 color: NSColor) -> SCNNode {
        let source = SCNGeometrySource(vertices: [SCNVector3(a), SCNVector3(b)])
        let element = SCNGeometryElement(indices: [Int32(0), Int32(1)],
                                         primitiveType: .line)
        let geometry = SCNGeometry(sources: [source], elements: [element])
        geometry.firstMaterial?.lightingModel = .constant
        geometry.firstMaterial?.diffuse.contents = color
        return SCNNode(geometry: geometry)
    }

    /// "#RRGGBB" -> NSColor (nil if malformed).
    static func nsColor(hex: String) -> NSColor? {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        return NSColor(red: CGFloat((v >> 16) & 0xFF) / 255,
                       green: CGFloat((v >> 8) & 0xFF) / 255,
                       blue: CGFloat(v & 0xFF) / 255, alpha: 1)
    }

    /// White-ish on dark themes, dark on light themes.
    private static func contrastColor(for palette: MoodPalette, alpha: CGFloat) -> NSColor {
        let c = palette.backgroundRGB
        let lum = 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b
        let white: CGFloat = lum < 0.5 ? 1 : 0.1
        return NSColor(white: white, alpha: alpha)
    }

    // MARK: hit routing

    func tileIndex(for node: SCNNode) -> Int? {
        var n: SCNNode? = node
        while let current = n {
            if let name = current.name, name.hasPrefix("tile-"),
               let i = Int(name.dropFirst(5)) {
                return i
            }
            n = current.parent
        }
        return nil
    }

    func openTile(_ index: Int, in view: SCNView) {
        guard nodes.indices.contains(index),
              data.nodes.indices.contains(index) else { return }
        let rect = SceneProjection.screenRect(of: nodes[index], in: view)
            ?? CGRect(x: view.bounds.midX - 80, y: view.bounds.midY - 80,
                      width: 160, height: 160)
        onOpen(data.nodes[index].path, rect)
    }

    func setHovered(_ index: Int?) {
        for (i, node) in nodes.enumerated() {
            node.simdScale = (i == index) ? SIMD3(repeating: 1.18) : SIMD3(repeating: 1)
        }
    }
}

// MARK: - SCNView subclass

/// Keeps SceneKit's built-in orbit/zoom (drag + scroll) while adding
/// click-to-open and a light hover highlight. We call super so the default
/// camera controller still gets its events.
final class GalaxySCNView: SCNView {
    weak var coordinator: GalaxySceneCoordinator?
    private var mouseDownPoint: NSPoint?
    private var trackingArea: NSTrackingArea?
    private var hoveredIndex: Int?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeInActiveApp, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect],
            owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseDown(with event: NSEvent) {
        mouseDownPoint = convert(event.locationInWindow, from: nil)
        super.mouseDown(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        super.mouseUp(with: event)
        defer { mouseDownPoint = nil }
        let up = convert(event.locationInWindow, from: nil)
        // A drag (orbit) is not a click.
        if let down = mouseDownPoint, hypot(up.x - down.x, up.y - down.y) > 6 { return }
        guard let coordinator else { return }
        let hits = hitTest(up, options: [
            .searchMode: NSNumber(value: SCNHitTestSearchMode.all.rawValue)
        ])
        if let index = hits.lazy.compactMap({ coordinator.tileIndex(for: $0.node) }).first {
            coordinator.openTile(index, in: self)
        }
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        guard let coordinator else { return }
        let point = convert(event.locationInWindow, from: nil)
        let hits = hitTest(point, options: [
            .searchMode: NSNumber(value: SCNHitTestSearchMode.closest.rawValue)
        ])
        let index = hits.lazy.compactMap { coordinator.tileIndex(for: $0.node) }.first
        if index != hoveredIndex {
            hoveredIndex = index
            coordinator.setHovered(index)
        }
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        if hoveredIndex != nil {
            hoveredIndex = nil
            coordinator?.setHovered(nil)
        }
    }
}
