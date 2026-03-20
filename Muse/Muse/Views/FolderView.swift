//
//  FolderView.swift
//  Muse
//
//  Created by Carlos Tarrats on 3/19/26.
//

import SwiftUI
import SceneKit

/// Wraps a FolderScene in an NSViewRepresentable. Shows collections as 3D folders
/// with open/close animation and image grid reveal.
struct FolderView: NSViewRepresentable {
    @EnvironmentObject var appState: AppState

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    /// Builds the list of displayable collections, including an "Unsorted" pseudo-collection
    /// for images without a collection.
    static func displayCollections(from appState: AppState) -> [MuseCollection] {
        let unsortedID = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
        var result = appState.collections
        let hasUnsorted = appState.images.contains { $0.collectionID == nil }
        if hasUnsorted {
            result.insert(MuseCollection(id: unsortedID, name: "Unsorted", colorHex: "#888888"), at: 0)
        }
        if result.isEmpty && !appState.images.isEmpty {
            result.append(MuseCollection(id: unsortedID, name: "All Images", colorHex: "#5E8BFF"))
        }
        return result
    }

    func makeNSView(context: Context) -> SCNView {
        let displayCollections = Self.displayCollections(from: appState)
        let collection = displayCollections.first ?? MuseCollection(name: "Empty")
        let folderNodes = FolderScene.build(collection: collection)

        let scnView = SCNView()
        scnView.scene = folderNodes.scene
        scnView.allowsCameraControl = false
        scnView.antialiasingMode = .multisampling4X
        scnView.backgroundColor = NSColor.white

        context.coordinator.scnView = scnView
        context.coordinator.folderNodes = folderNodes
        context.coordinator.appState = appState
        context.coordinator.currentCollection = collection
        context.coordinator.allImages = appState.images

        // Click gesture
        let click = NSClickGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleClick(_:)))
        scnView.addGestureRecognizer(click)

        return scnView
    }

    func updateNSView(_ nsView: SCNView, context: Context) {}

    // MARK: - Coordinator

    @MainActor
    class Coordinator: NSObject {
        weak var scnView: SCNView?
        var folderNodes: FolderScene.FolderNodes?
        weak var appState: AppState?
        var currentCollection: MuseCollection?
        var allImages: [MuseImage] = []

        var isOpen = false
        var imageNodes: [SCNNode] = []

        @objc func handleClick(_ gesture: NSClickGestureRecognizer) {
            guard let scnView = scnView else { return }
            let location = gesture.location(in: scnView)
            let hitResults = scnView.hitTest(location, options: nil)

            for hit in hitResults {
                let nodeName = hit.node.name ?? ""

                // Check if we hit an image node
                if UUID(uuidString: nodeName) != nil {
                    if let uuid = UUID(uuidString: nodeName) {
                        appState?.selectedImage = allImages.first { $0.id == uuid }
                        appState?.detailPanelVisible = true
                    }
                    return
                }

                // Check if we hit the folder covers
                if nodeName == "frontCover" || nodeName == "backCover" {
                    if isOpen {
                        closeFolder()
                    } else {
                        openFolder()
                    }
                    return
                }
            }
        }

        private func openFolder() {
            guard let folderNodes = folderNodes, let collection = currentCollection else { return }
            isOpen = true

            // Animate front cover opening (rotate backward on X axis)
            SCNTransaction.begin()
            SCNTransaction.animationDuration = 0.6
            SCNTransaction.animationTimingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            folderNodes.frontCover.eulerAngles.x = -CGFloat.pi * 0.75 // -135 degrees
            SCNTransaction.commit()

            // After a short delay, animate images appearing
            let unsortedID = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
            let images: [MuseImage]
            if collection.id == unsortedID {
                images = allImages.filter { $0.collectionID == nil }
            } else {
                images = allImages.filter { $0.collectionID == collection.id }
            }
            let nodes = FolderScene.buildImageNodes(images: images)
            let positions = FolderScene.gridPositions(count: nodes.count)
            imageNodes = nodes

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let self = self else { return }
                for (index, node) in nodes.enumerated() {
                    guard index < positions.count else { break }
                    folderNodes.folderContainer.addChildNode(node)

                    // Tiny random Z rotation for organic feel
                    let targetRotation = CGFloat.random(in: -0.05...0.05)

                    // Stagger animation
                    let delay = Double(index) * 0.04
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                        SCNTransaction.begin()
                        SCNTransaction.animationDuration = 0.45
                        SCNTransaction.animationTimingFunction = CAMediaTimingFunction(name: .easeOut)
                        node.position = positions[index]
                        node.opacity = 1.0
                        node.eulerAngles.z = targetRotation
                        SCNTransaction.commit()
                    }
                }
            }
        }

        private func closeFolder() {
            guard let folderNodes = folderNodes else { return }
            isOpen = false

            // Remove image nodes
            for node in imageNodes {
                node.removeFromParentNode()
            }
            imageNodes = []

            // Animate front cover closing
            SCNTransaction.begin()
            SCNTransaction.animationDuration = 0.45
            SCNTransaction.animationTimingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            folderNodes.frontCover.eulerAngles.x = 0
            SCNTransaction.commit()
        }

        /// Switches to a different collection's folder.
        func switchCollection(_ collection: MuseCollection) {
            guard let scnView = scnView, let appState = appState else { return }

            // Close current folder
            closeFolder()

            // Rebuild scene for new collection
            let newFolderNodes = FolderScene.build(collection: collection)
            scnView.scene = newFolderNodes.scene
            folderNodes = newFolderNodes
            currentCollection = collection
            allImages = appState.images
        }
    }
}

// MARK: - Folder Collection Tabs (SwiftUI overlay)

/// A sidebar overlay showing collection tabs for switching folders.
struct FolderCollectionTabs: View {
    @EnvironmentObject var appState: AppState
    let onSelect: (MuseCollection) -> Void
    @State private var selectedID: UUID?

    private var displayCollections: [MuseCollection] {
        FolderView.displayCollections(from: appState)
    }

    var body: some View {
        VStack(spacing: 2) {
            ForEach(displayCollections) { collection in
                Button {
                    selectedID = collection.id
                    onSelect(collection)
                } label: {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(Color(nsColor: NSColor(hex: collection.colorHex)))
                            .frame(width: 8, height: 8)
                        Text(collection.name)
                            .font(.caption)
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        selectedID == collection.id
                        ? Color.accentColor.opacity(0.2)
                        : Color.clear
                    )
                    .cornerRadius(4)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(8)
        .frame(width: 140)
        .background(.ultraThinMaterial)
        .cornerRadius(8)
        .onAppear {
            selectedID = displayCollections.first?.id
        }
    }
}
