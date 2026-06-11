//
//  GraphView.swift
//  Muse
//
//  Spec §3 graph view (replaces GlobeView). Zoomed out: flat 2D —
//  collections as labeled thumbnail clusters, lines between collections
//  sharing tags. Zooming into a cluster transitions to 3D: images
//  spread by visual similarity (Task 11). One perspective camera,
//  straight-on, so the overview reads flat.
//

import SwiftUI
import SceneKit
import AppKit

struct GraphView: View {
    @EnvironmentObject var appState: AppState
    @State private var data: GraphData?

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color(red: 0.066, green: 0.066, blue: 0.078).ignoresSafeArea() // Ink
                if let data, !data.clusters.isEmpty {
                    GraphSceneRepresentable(
                        data: data,
                        focusedID: appState.graphFocusedCollectionID,
                        onFocus: { id in appState.graphFocusedCollectionID = id },
                        onOpen: { path, localRect in
                            guard let file = fileByPath[path] else { return }
                            let origin = geo.frame(in: .global).origin
                            appState.tileFrames[file.url.path] =
                                localRect.offsetBy(dx: origin.x, dy: origin.y)
                            appState.selectedFile = file
                        }
                    )
                } else if data != nil {
                    emptyState
                } else {
                    ProgressView().controlSize(.large)
                }
            }
        }
        .task(id: scopeIdentity) {
            appState.graphFocusedCollectionID = nil
            await rebuild()
        }
        .onDisappear { appState.graphFocusedCollectionID = nil }
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
        guard let q = Database.shared.dbQueue else {
            data = GraphData(clusters: [], edges: [])
            return
        }
        let paths = imageFiles.map { $0.url.standardizedFileURL.path }
        data = (try? await GraphModel.build(queue: q, scopePaths: paths))
            ?? GraphData(clusters: [], edges: [])
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "point.3.connected.trianglepath.dotted")
                .font(.system(size: 48))
                .foregroundStyle(.tertiary)
            Text("No collections yet")
                .font(.title3)
                .foregroundStyle(.secondary)
            Text("Run Analyze (✨) on a folder of images to build collections.")
                .font(.callout)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Representable

private struct GraphSceneRepresentable: NSViewRepresentable {
    let data: GraphData
    let focusedID: String?
    let onFocus: (String?) -> Void
    let onOpen: (String, CGRect) -> Void

    func makeCoordinator() -> GraphSceneCoordinator { GraphSceneCoordinator() }

    func makeNSView(context: Context) -> GraphSCNView {
        let view = GraphSCNView()
        view.coordinator = context.coordinator
        view.backgroundColor = NSColor(red: 0.066, green: 0.066, blue: 0.078, alpha: 1)
        view.antialiasingMode = .multisampling4X
        view.rendersContinuously = true
        view.allowsCameraControl = false
        context.coordinator.rebuildIfNeeded(data: data, in: view)
        return view
    }

    func updateNSView(_ nsView: GraphSCNView, context: Context) {
        context.coordinator.onFocus = onFocus
        context.coordinator.onOpen = onOpen
        context.coordinator.rebuildIfNeeded(data: data, in: nsView)
        context.coordinator.setFocus(focusedID, in: nsView)
    }
}

// MARK: - Coordinator

@MainActor
final class GraphSceneCoordinator: NSObject {
    var onFocus: (String?) -> Void = { _ in }
    var onOpen: (String, CGRect) -> Void = { _, _ in }

    static let worldSpread: Double = 700      // layout unit -> world units
    static let overviewCameraZ: Double = 1750
    static let focusCameraZ: Double = 950
    static let spreadRadius: Double = 380     // 3D spread (Task 11)
    static let heapVisibleCount = 7

    private(set) var data = GraphData(clusters: [], edges: [])
    private var identity = "<unbuilt>"
    private var clusterNodes: [SCNNode] = []          // parallel to data.clusters
    private var memberNodes: [[SCNNode]] = []         // [cluster][member]
    private var heapTransforms: [[(SIMD3<Float>, simd_quatf, Float)]] = [] // pos, rot, opacity
    private var labelNodes: [SCNNode] = []
    private var edgesNode = SCNNode()
    private var cameraNode = SCNNode()
    private(set) var focusedID: String?
    nonisolated(unsafe) private var thumbnailTask: Task<Void, Never>?

    // 3D similarity spread (Task 11)
    private var spreadCache: [String: [SIMD3<Float>]] = [:]
    private var spreadTask: Task<Void, Never>?

    deinit { thumbnailTask?.cancel() }

    func rebuildIfNeeded(data newData: GraphData, in view: SCNView) {
        let newIdentity = newData.clusters.map { "\($0.id):\($0.memberPaths.count)" }
            .joined(separator: "|") + "#\(newData.edges.count)"
        guard newIdentity != identity else { return }
        identity = newIdentity
        thumbnailTask?.cancel()
        spreadTask?.cancel()
        spreadCache = [:]
        data = newData
        focusedID = nil

        let scene = SCNScene()
        scene.background.contents = NSColor(red: 0.066, green: 0.066, blue: 0.078, alpha: 1)

        let camera = SCNCamera()
        camera.zNear = 10
        camera.zFar = 8000
        camera.fieldOfView = 50
        cameraNode = SCNNode()
        cameraNode.camera = camera
        cameraNode.position = SCNVector3(0, 0, Self.overviewCameraZ)
        scene.rootNode.addChildNode(cameraNode)

        let layout = GraphLayout.positions(
            nodeCount: data.clusters.count,
            edges: data.edges)
        let worldPositions: [SIMD3<Float>] = layout.map {
            SIMD3(Float($0.x * Self.worldSpread), Float($0.y * Self.worldSpread * 0.62), 0)
        }

        // Edge lines (under the clusters).
        edgesNode = SCNNode()
        for e in data.edges where e.a < worldPositions.count && e.b < worldPositions.count {
            edgesNode.addChildNode(Self.lineNode(
                from: worldPositions[e.a], to: worldPositions[e.b],
                alpha: 0.18 + 0.07 * CGFloat(min(e.sharedTags, 4))))
        }
        scene.rootNode.addChildNode(edgesNode)

        clusterNodes = []
        memberNodes = []
        heapTransforms = []
        labelNodes = []
        for (ci, cluster) in data.clusters.enumerated() {
            let group = SCNNode()
            group.simdPosition = worldPositions[ci] + SIMD3(0, 0, 2)
            group.name = "cluster-\(ci)"
            var rng = SeededRandom(seed: SeededRandom.fnv1a([cluster.id]))
            var nodes: [SCNNode] = []
            var transforms: [(SIMD3<Float>, simd_quatf, Float)] = []
            for (mi, _) in cluster.memberPaths.enumerated() {
                let plane = SCNPlane(width: mi == 0 ? 110 : 80,
                                     height: mi == 0 ? 110 : 80)
                let m = plane.firstMaterial!
                m.lightingModel = .constant
                m.diffuse.contents = NSColor(white: 0.22, alpha: 1)
                m.isDoubleSided = true
                let node = SCNNode(geometry: plane)
                node.name = "member-\(ci)-\(mi)"
                let t = Self.heapTransform(memberIndex: mi, rng: &rng)
                node.simdPosition = t.0
                node.simdOrientation = t.1
                node.opacity = CGFloat(t.2)
                group.addChildNode(node)
                nodes.append(node)
                transforms.append(t)
            }
            let label = Self.labelNode(
                text: "\(cluster.name)  ·  \(cluster.memberPaths.count)")
            label.position = SCNVector3(0, -120, 4)
            group.addChildNode(label)
            labelNodes.append(label)

            scene.rootNode.addChildNode(group)
            clusterNodes.append(group)
            memberNodes.append(nodes)
            heapTransforms.append(transforms)
        }

        view.scene = scene
        view.pointOfView = cameraNode
        loadOverviewThumbnails()
    }

    /// Collage heap: first member large at the center, the next six in a
    /// loose ring with slight in-plane tilts; the rest hidden until the
    /// cluster is focused.
    private static func heapTransform(memberIndex mi: Int,
                                      rng: inout SeededRandom) -> (SIMD3<Float>, simd_quatf, Float) {
        let tilt = Float(Double.random(in: -8...8, using: &rng)) * .pi / 180
        let rot = simd_quatf(angle: tilt, axis: SIMD3(0, 0, 1))
        if mi == 0 { return (SIMD3(0, 0, 1), rot, 1) }
        if mi < heapVisibleCount {
            let angle = Double(mi - 1) / 6 * 2 * .pi + Double.random(in: -0.2...0.2, using: &rng)
            let radius = Double.random(in: 58...74, using: &rng)
            return (SIMD3(Float(cos(angle) * radius), Float(sin(angle) * radius),
                          Float(mi) * 0.5), rot, 1)
        }
        return (SIMD3(0, 0, 0), rot, 0)   // hidden until focus
    }

    private static func lineNode(from a: SIMD3<Float>, to b: SIMD3<Float>,
                                 alpha: CGFloat) -> SCNNode {
        let source = SCNGeometrySource(vertices: [SCNVector3(a), SCNVector3(b)])
        let element = SCNGeometryElement(indices: [Int32(0), Int32(1)],
                                         primitiveType: .line)
        let geometry = SCNGeometry(sources: [source], elements: [element])
        geometry.firstMaterial?.lightingModel = .constant
        geometry.firstMaterial?.diffuse.contents = NSColor(white: 1, alpha: alpha)
        return SCNNode(geometry: geometry)
    }

    private static func labelNode(text: String) -> SCNNode {
        let font = NSFont.systemFont(ofSize: 28, weight: .medium)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: NSColor(white: 1, alpha: 0.85),
        ]
        let textSize = (text as NSString).size(withAttributes: attrs)
        let imageSize = NSSize(width: ceil(textSize.width) + 8,
                               height: ceil(textSize.height) + 8)
        let image = NSImage(size: imageSize)
        image.lockFocus()
        (text as NSString).draw(at: NSPoint(x: 4, y: 4), withAttributes: attrs)
        image.unlockFocus()
        let worldHeight: CGFloat = 34
        let plane = SCNPlane(width: worldHeight * imageSize.width / imageSize.height,
                             height: worldHeight)
        let m = plane.firstMaterial!
        m.lightingModel = .constant
        m.diffuse.contents = image
        m.isDoubleSided = true
        m.blendMode = .alpha
        return SCNNode(geometry: plane)
    }

    private func loadOverviewThumbnails() {
        let work: [(SCNNode, String)] = zip(memberNodes, data.clusters).flatMap { nodes, cluster in
            zip(nodes.prefix(Self.heapVisibleCount), cluster.memberPaths)
                .map { ($0, $1) }
        }
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

    // MARK: focus / unfocus (camera; member spread arrives in Task 11)

    func setFocus(_ id: String?, in view: SCNView) {
        guard id != focusedID else { return }
        let index = id.flatMap { fid in data.clusters.firstIndex { $0.id == fid } }
        // If the requested id no longer exists in the data, treat as unfocus.
        if id != nil, index == nil {
            focusedID = nil
            onFocus(nil)
        } else {
            focusedID = id
        }

        SCNTransaction.begin()
        SCNTransaction.animationDuration = 0.7
        SCNTransaction.animationTimingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        if let index {
            let p = clusterNodes[index].simdPosition
            cameraNode.position = SCNVector3(CGFloat(p.x), CGFloat(p.y),
                                             CGFloat(Self.focusCameraZ))
            edgesNode.opacity = 0.1
            for (ci, node) in clusterNodes.enumerated() where ci != index {
                node.opacity = 0.12
            }
            clusterNodes[index].opacity = 1
            labelNodes[index].opacity = 0
            spread(clusterIndex: index)
        } else {
            cameraNode.position = SCNVector3(0, 0, Self.overviewCameraZ)
            edgesNode.opacity = 1
            for (ci, node) in clusterNodes.enumerated() {
                node.opacity = 1
                labelNodes[ci].opacity = 1
                for (mi, member) in memberNodes[ci].enumerated() {
                    let t = heapTransforms[ci][mi]
                    member.simdPosition = t.0
                    member.simdOrientation = t.1
                    member.opacity = CGFloat(t.2)
                }
            }
        }
        SCNTransaction.commit()
    }

    // MARK: 3D similarity spread

    /// Spec §3: membership = collections, internal arrangement = visual
    /// similarity. Positions are cached per cluster id; computed off-main
    /// (print unarchiving + computeDistance are CPU-bound).
    func spread(clusterIndex: Int) {
        let cluster = data.clusters[clusterIndex]
        if let cached = spreadCache[cluster.id] {
            applySpread(clusterIndex: clusterIndex, positions: cached)
            return
        }
        // Until positions land: reveal everything in the flat heap ring.
        for member in memberNodes[clusterIndex] { member.opacity = 1 }

        spreadTask?.cancel()
        spreadTask = Task { @MainActor in
            guard let q = Database.shared.dbQueue else { return }
            let ids = cluster.memberFileIDs
            let printsByID = (try? await GraphModel.featurePrints(queue: q, fileIDs: ids)) ?? [:]
            let prints: [Data?] = ids.map { printsByID[$0] }
            let seed = SeededRandom.fnv1a(ids)
            let positions = await Task.detached(priority: .userInitiated) {
                let matrix = GraphModel.distanceMatrix(prints: prints)
                return SimilarityLayout.positions(distances: matrix, seed: seed)
                    .map { SIMD3<Float>(Float($0.x), Float($0.y), Float($0.z)) }
            }.value
            guard !Task.isCancelled else { return }
            spreadCache[cluster.id] = positions
            // Still focused on this cluster? Animate into the spread.
            if focusedID == cluster.id {
                SCNTransaction.begin()
                SCNTransaction.animationDuration = 0.7
                SCNTransaction.animationTimingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                applySpread(clusterIndex: clusterIndex, positions: positions)
                SCNTransaction.commit()
            }
        }
        loadAllThumbnails(clusterIndex: clusterIndex)
    }

    private func applySpread(clusterIndex: Int, positions: [SIMD3<Float>]) {
        let radius = Float(Self.spreadRadius)
        for (mi, member) in memberNodes[clusterIndex].enumerated() {
            guard mi < positions.count else { break }
            member.simdPosition = positions[mi] * radius
            member.simdOrientation = simd_quatf(angle: 0, axis: SIMD3(0, 0, 1))
            member.opacity = 1
        }
    }

    /// Focused cluster shows every member — load the tail thumbnails.
    private func loadAllThumbnails(clusterIndex: Int) {
        let cluster = data.clusters[clusterIndex]
        let nodes = memberNodes[clusterIndex]
        Task { @MainActor in
            for (mi, path) in cluster.memberPaths.enumerated()
            where mi >= Self.heapVisibleCount {
                guard mi < nodes.count,
                      let plane = nodes[mi].geometry as? SCNPlane else { continue }
                if let img = await ThumbnailCache.shared.thumbnail(
                    for: URL(fileURLWithPath: path),
                    size: CGSize(width: 128, height: 128)
                ) {
                    CloudSceneCoordinator.applyCover(image: img, to: plane)
                }
            }
        }
    }

    // MARK: hit routing

    func hitTarget(for node: SCNNode) -> (clusterIndex: Int, memberIndex: Int?)? {
        var n: SCNNode? = node
        while let current = n {
            if let name = current.name {
                if name.hasPrefix("member-") {
                    let parts = name.dropFirst(7).split(separator: "-")
                    if parts.count == 2, let ci = Int(parts[0]), let mi = Int(parts[1]) {
                        return (ci, mi)
                    }
                }
                if name.hasPrefix("cluster-"), let ci = Int(name.dropFirst(8)) {
                    return (ci, nil)
                }
            }
            n = current.parent
        }
        return nil
    }

    func openMember(clusterIndex: Int, memberIndex: Int, in view: SCNView) {
        guard data.clusters.indices.contains(clusterIndex),
              data.clusters[clusterIndex].memberPaths.indices.contains(memberIndex),
              memberNodes.indices.contains(clusterIndex),
              memberNodes[clusterIndex].indices.contains(memberIndex) else { return }
        let node = memberNodes[clusterIndex][memberIndex]
        let rect = SceneProjection.screenRect(of: node, in: view)
            ?? CGRect(x: view.bounds.midX - 80, y: view.bounds.midY - 80,
                      width: 160, height: 160)
        onOpen(data.clusters[clusterIndex].memberPaths[memberIndex], rect)
    }
}

// MARK: - SCNView subclass

final class GraphSCNView: SCNView {
    weak var coordinator: GraphSceneCoordinator?
    private var mouseDownPoint: NSPoint?

    override func mouseDown(with event: NSEvent) {
        mouseDownPoint = convert(event.locationInWindow, from: nil)
    }

    override func mouseUp(with event: NSEvent) {
        defer { mouseDownPoint = nil }
        let up = convert(event.locationInWindow, from: nil)
        if let down = mouseDownPoint, hypot(up.x - down.x, up.y - down.y) > 6 { return }
        guard let coordinator else { return }
        let hits = hitTest(up, options: [.searchMode: NSNumber(value: SCNHitTestSearchMode.all.rawValue)])
        let target = hits.lazy.compactMap { coordinator.hitTarget(for: $0.node) }.first

        if let focusedID = coordinator.focusedID {
            guard let target,
                  let fi = coordinator.data.clusters.firstIndex(where: { $0.id == focusedID })
            else {
                coordinator.onFocus(nil)   // empty space -> zoom out
                return
            }
            if target.clusterIndex == fi, let mi = target.memberIndex {
                coordinator.openMember(clusterIndex: fi, memberIndex: mi, in: self)
            } else if target.clusterIndex != fi {
                coordinator.onFocus(coordinator.data.clusters[target.clusterIndex].id)
            }
        } else if let target {
            coordinator.onFocus(coordinator.data.clusters[target.clusterIndex].id)
        }
    }
}
